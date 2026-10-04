import XCTest
import MosemoAPI
@testable import MosemoApp

final class LabelReviewStateTests: XCTestCase {
    func testGroupsContiguousSegmentsWithMatchingProposals() {
        let review = LabelReviewState(snapshot: LabelReviewSnapshot(response: MockLabelReviewFetcher.demo.response))

        XCTAssertEqual(review.pendingSegments.count, 10)
        XCTAssertEqual(review.groups.map { $0.segments.count }, [3, 2, 1, 1, 1, 1, 1])
        XCTAssertEqual(review.groups[0].proposal, .ready(.label(id: review.labels[0].id)))
        XCTAssertEqual(review.groups[2].proposal, .ready(.unclassified))
        XCTAssertEqual(review.groups[3].proposal, .processing)
        XCTAssertEqual(review.groups[4].proposal, .failed)
        XCTAssertEqual(review.groups[6].proposal, .waiting)
    }

    func testPinnedGroupDoesNotAbsorbNewAdjacentSegmentAndCanBeUnpinned() {
        let response = MockLabelReviewFetcher.demo.response
        let review = LabelReviewState(snapshot: LabelReviewSnapshot(response: response))
        let pinned = review.pinning(review.groups[0])
        let first = response.segments[0]
        let inserted = LabelReviewSegmentDTO(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            version: "new", startedAt: first.endedAt, endedAt: first.endedAt,
            appName: "New app", context: first.context, proposal: first.proposal
        )
        var segments = response.segments
        segments.insert(inserted, at: 1)
        let refreshed = pinned.replacing(with: LabelReviewSnapshot(
            response: LabelReviewResponseDTO(labels: response.labels, segments: segments)
        ))

        XCTAssertEqual(refreshed.groups.prefix(3).map { $0.segments.count }, [1, 1, 2])
        let unlocked = refreshed.keepingPinnedGroups(intersecting: [])
        XCTAssertEqual(unlocked.groups[0].segments.count, 4)
    }

    func testConfirmingGroupRemovesOnlyMatchingVersionsAndSurvivesRefresh() {
        let response = MockLabelReviewFetcher.demo.response
        let review = LabelReviewState(snapshot: LabelReviewSnapshot(response: response))
        let firstGroup = review.groups[0]
        let decisions = firstGroup.segments.map {
            LabelReviewDecision(
                segmentID: $0.id,
                segmentVersion: $0.version,
                selection: $0.proposal.selection!
            )
        }

        let confirmed = review.applying(decisions)
        XCTAssertEqual(review.pendingSegments.count, 10)
        XCTAssertEqual(confirmed.pendingSegments.count, 7)
        XCTAssertEqual(confirmed.replacing(with: LabelReviewSnapshot(response: response)).pendingSegments.count, 7)

        var changedSegments = response.segments
        let changed = changedSegments[0]
        changedSegments[0] = LabelReviewSegmentDTO(
            id: changed.id,
            version: String(repeating: "f", count: 64),
            startedAt: changed.startedAt,
            endedAt: changed.endedAt,
            appName: changed.appName,
            context: changed.context,
            proposal: changed.proposal
        )
        let changedResponse = LabelReviewResponseDTO(labels: response.labels, segments: changedSegments)

        XCTAssertEqual(confirmed.replacing(with: LabelReviewSnapshot(response: changedResponse)).pendingSegments.count, 8)
    }

    func testArchivedProposalKeepsItsNameButCannotBeChosenAndServerGroupsStaySeparate() {
        let archived = LabelReviewLabelDTO(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "옛 라벨",
            archivedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let first = MockLabelReviewFetcher.demo.response.segments[0]
        let second = MockLabelReviewFetcher.demo.response.segments[1]
        func inGroup(_ segment: LabelReviewSegmentDTO, _ group: String) -> LabelReviewSegmentDTO {
            LabelReviewSegmentDTO(
                id: segment.id,
                version: segment.version,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                appName: segment.appName,
                context: segment.context,
                proposal: segment.proposal,
                sourceGroupVersion: group
            )
        }
        let response = LabelReviewResponseDTO(
            labels: [archived],
            segments: [
                inGroup(first, "group-a"),
                inGroup(second, "group-b"),
            ]
        )
        let review = LabelReviewState(snapshot: LabelReviewSnapshot(response: response))

        XCTAssertEqual(review.groups.map { $0.segments.count }, [1, 1])
        XCTAssertEqual(review.groups[0].proposal.selection?.title(in: review.labels), "옛 라벨")
        XCTAssertFalse(review.canSelect(.label(id: archived.id)))
    }
}

@MainActor
final class LabelReviewViewModelTests: XCTestCase {
    func testUploadDuringSubmissionRefreshesAfterConfirmationFinishes() async {
        let fetcher = RecordingLabelReviewFetcher(response: MockLabelReviewFetcher.demo.response)
        let writer = SuspendedLabelConfirmationWriter()
        let model = LabelReviewViewModel(fetcher: fetcher, writer: writer)
        await model.load()
        let submission = Task { await model.confirm(model.groups[0].segments[0]) }
        await waitUntil { model.isSubmitting }
        while !(await writer.isPending()) { await Task.yield() }
        await model.activityUploaded()
        let before = await fetcher.dates()
        XCTAssertEqual(before.count, 1)
        await writer.succeed()
        await submission.value
        for _ in 0..<100 {
            if await fetcher.dates().count == 3 { break }
            await Task.yield()
        }
        let after = await fetcher.dates()
        XCTAssertEqual(after.count, 3)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertEqual(model.segmentCount, 9)
    }

    func testProposalPollingDoesNotRaceWithAnUploadRefresh() async {
        let fetcher = SuspendedPollingFetcher()
        var waits = 0
        let model = LabelReviewViewModel(fetcher: fetcher, writer: RecordingLabelConfirmationWriter(),
            pollingSleep: { _ in
                waits += 1
                if waits > 1 { throw CancellationError() }
            })
        await model.load()
        let refresh = Task { await model.activityUploaded() }
        await fetcher.waitForPollingRequest()
        await model.pollProposals()
        let requests = await fetcher.requestCount()
        XCTAssertEqual(requests, 2)
        await fetcher.finishPolling()
        await refresh.value
        XCTAssertTrue(model.groups.isEmpty)
    }

    func testUploadsDuringRefreshAreCombinedIntoAFollowupQuery() async {
        let fetcher = SuspendedPollingFetcher()
        let model = LabelReviewViewModel(fetcher: fetcher, writer: RecordingLabelConfirmationWriter())
        await model.load()
        let refresh = Task { await model.activityUploaded() }
        await fetcher.waitForPollingRequest()
        await model.activityUploaded()
        await model.activityUploaded()
        await fetcher.finishPolling()
        await refresh.value
        XCTAssertFalse(model.groups.isEmpty)
        XCTAssertFalse(model.hasOutstandingProposals)
    }

    func testUploadRefreshDiscoversNewSegmentsAndPreservesDraftSelection() async {
        let response = MockLabelReviewFetcher.demo.response
        let initial = LabelReviewResponseDTO(labels: response.labels, segments: [response.segments[0]])
        let fetcher = SnapshotSequenceLabelReviewFetcher(responses: [initial, response], confirmedByID: [:])
        let model = LabelReviewViewModel(fetcher: fetcher, writer: RecordingLabelConfirmationWriter())
        await model.load()
        let segment = model.groups[0].segments[0]
        model.toggleSelection(for: segment)
        model.setSelection(.unclassified, for: segment)
        await model.activityUploaded()
        XCTAssertEqual(model.segmentCount, 10)
        XCTAssertEqual(model.selectedSegmentIDs, [segment.id])
        XCTAssertEqual(model.selection(for: segment), .unclassified)
        XCTAssertEqual(model.loadState, .loaded)
    }

    func testExpandedGroupStaysPinnedAcrossRefreshAndNewAdjacentSegmentIsSeparate() async {
        let response = MockLabelReviewFetcher.demo.response
        let first = response.segments[0]
        let inserted = LabelReviewSegmentDTO(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            version: "new", startedAt: first.endedAt, endedAt: first.endedAt,
            appName: "새 앱", context: first.context, proposal: first.proposal
        )
        var refreshedSegments = response.segments
        refreshedSegments.insert(inserted, at: 1)
        let fetcher = SnapshotSequenceLabelReviewFetcher(responses: [
            response, LabelReviewResponseDTO(labels: response.labels, segments: refreshedSegments)
        ], confirmedByID: [:])
        let model = LabelReviewViewModel(fetcher: fetcher, writer: RecordingLabelConfirmationWriter())
        await model.load()
        let originalIDs = Set(model.groups[0].segments.map(\.id))
        model.toggleExpansion(for: model.groups[0])

        await model.activityUploaded()

        XCTAssertEqual(model.groups.prefix(3).map { $0.segments.count }, [1, 1, 2])
        XCTAssertFalse(model.expandedGroupIDs.contains(inserted.id))
        XCTAssertEqual(Set(model.groups.filter { model.expandedGroupIDs.contains($0.id) }
            .flatMap { $0.segments.map(\.id) }), originalIDs)

        for group in model.groups where model.expandedGroupIDs.contains(group.id) {
            model.toggleExpansion(for: group)
        }
        XCTAssertEqual(model.groups[0].segments.count, 4)
        XCTAssertFalse(model.expandedGroupIDs.contains(model.groups[0].id))
    }

    func testAutomaticRefreshFailureKeepsReviewAndCanRetry() async {
        let snapshot = LabelReviewSnapshot(response: MockLabelReviewFetcher.demo.response)
        let fetcher = SequenceLabelReviewFetcher(results: [
            .success(snapshot), .failure(.offline), .success(snapshot)
        ])
        let model = LabelReviewViewModel(fetcher: fetcher, writer: RecordingLabelConfirmationWriter())
        await model.load()
        let originalGroupCount = model.groups.count

        await model.activityUploaded()
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.groups.count, originalGroupCount)
        XCTAssertNotNil(model.refreshError)

        await model.load()
        XCTAssertNil(model.refreshError)
        XCTAssertEqual(model.groups.count, originalGroupCount)
    }

    func testAutomaticRefreshWaitsTwoSecondsAndStopsWhenProposalsComplete() async {
        let first = MockLabelReviewFetcher.demo.response
        let finished = LabelReviewResponseDTO(labels: first.labels, segments: first.segments.map {
            LabelReviewSegmentDTO(
                id: $0.id, version: $0.version, startedAt: $0.startedAt, endedAt: $0.endedAt,
                appName: $0.appName, context: $0.context,
                proposal: .ready(.unclassified), sourceGroupVersion: $0.sourceGroupVersion
            )
        })
        let fetcher = SnapshotSequenceLabelReviewFetcher(responses: [first, finished], confirmedByID: [:])
        var delays: [UInt64] = []
        let model = LabelReviewViewModel(
            fetcher: fetcher, writer: RecordingLabelConfirmationWriter(),
            pollingSleep: { delays.append($0) }
        )
        await model.load()
        await model.pollProposals()
        XCTAssertEqual(delays, [2_000_000_000])
        XCTAssertEqual(model.segmentCount, 10)
        XCTAssertTrue(model.groups.flatMap(\.segments).allSatisfy { $0.proposal == .ready(.unclassified) })
        XCTAssertEqual(model.loadState, .loaded)
    }

    func testAutomaticRefreshDoesNotWaitOrFetchForReadyOrFailedProposals() async {
        let response = MockLabelReviewFetcher.demo.response
        let terminal = LabelReviewResponseDTO(labels: response.labels, segments: response.segments.filter {
            switch $0.proposal {
            case .ready, .failed: true
            case .waiting, .processing: false
            }
        })
        let model = LabelReviewViewModel(
            fetcher: SnapshotSequenceLabelReviewFetcher(responses: [terminal], confirmedByID: [:]),
            writer: RecordingLabelConfirmationWriter(),
            pollingSleep: { _ in XCTFail("Completed proposals must not schedule polling") }
        )
        await model.load()
        await model.pollProposals()
        XCTAssertEqual(model.segmentCount, 8)
    }

    func testCancelledAutomaticFetchCannotReplaceVisibleReview() async {
        let fetcher = SuspendedPollingFetcher()
        let model = LabelReviewViewModel(
            fetcher: fetcher, writer: RecordingLabelConfirmationWriter(), pollingSleep: { _ in }
        )
        await model.load()
        let polling = Task { await model.pollProposals() }
        await fetcher.waitForPollingRequest()
        polling.cancel()
        await fetcher.finishPolling()
        await polling.value
        XCTAssertEqual(model.segmentCount, 10)
        XCTAssertEqual(model.loadState, .loaded)
    }

    func testManualRefreshSupersedesOlderAutomaticResponseAndKeepsDrafts() async {
        let fetcher = SuspendedPollingFetcher()
        let model = LabelReviewViewModel(
            fetcher: fetcher, writer: RecordingLabelConfirmationWriter(), pollingSleep: { _ in }
        )
        await model.load()
        let segment = model.groups[0].first
        model.toggleSelection(for: segment)
        model.setSelection(.unclassified, for: segment)
        let polling = Task { await model.pollProposals() }
        await fetcher.waitForPollingRequest()
        await model.load()
        await fetcher.finishPolling()
        await polling.value
        XCTAssertEqual(model.segmentCount, 8)
        XCTAssertEqual(model.selectedSegmentIDs, [segment.id])
        XCTAssertEqual(model.selection(for: model.groups[0].first), .unclassified)
    }

    func testConfirmationSupersedesInFlightAutomaticResponse() async {
        let fetcher = SuspendedPollingFetcher()
        let model = LabelReviewViewModel(
            fetcher: fetcher, writer: RecordingLabelConfirmationWriter(), pollingSleep: { _ in }
        )
        await model.load()
        let polling = Task { await model.pollProposals() }
        await fetcher.waitForPollingRequest()
        await model.confirm(model.groups[0])
        await fetcher.finishPolling()
        await polling.value
        XCTAssertEqual(model.segmentCount, 5)
        XCTAssertFalse(model.isSubmitting)
    }

    func testAutomaticRefreshRetriesFailureWithoutHidingReviewOrClearingDraft() async {
        let response = MockLabelReviewFetcher.demo.response
        let terminal = LabelReviewResponseDTO(labels: response.labels, segments: response.segments.filter {
            switch $0.proposal {
            case .ready, .failed: true
            case .waiting, .processing: false
            }
        })
        let fetcher = SequenceLabelReviewFetcher(results: [
            .success(LabelReviewSnapshot(response: response)), .failure(.offline),
            .success(LabelReviewSnapshot(response: terminal)),
        ])
        var waits = 0
        let model = LabelReviewViewModel(
            fetcher: fetcher, writer: RecordingLabelConfirmationWriter(),
            pollingSleep: { _ in waits += 1 }
        )
        await model.load()
        let segment = model.groups[0].first
        model.toggleSelection(for: segment)
        model.setSelection(.unclassified, for: segment)
        await model.pollProposals()
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.selectedSegmentIDs, [segment.id])
        XCTAssertEqual(model.selection(for: model.groups[0].first), .unclassified)
    }

    func testIndividualSelectionCountsCollapsedSegmentsAndSubmitsOnlyCheckedDraft() async {
        let writer = RecordingLabelConfirmationWriter()
        let model = LabelReviewViewModel(fetcher: MockLabelReviewFetcher.demo, writer: writer)
        await model.load()
        let group = model.groups[0]
        let segment = group.segments[1]
        XCTAssertEqual(model.selectionState(for: group), .none)
        model.toggleSelection(for: segment)
        XCTAssertEqual(model.selectionState(for: group), .partial)
        XCTAssertEqual(model.allSelectionState, .partial)
        XCTAssertEqual(model.selectedSegmentCount, 1)
        XCTAssertTrue(model.expandedGroupIDs.isEmpty)
        model.setSelection(.unclassified, for: segment)
        XCTAssertEqual(model.unclassifiedCount(in: group), 1)
        XCTAssertEqual(model.selectedSegmentCount, 1)
        await model.confirmSelectedGroups()
        let requests = await writer.recordedRequests()
        XCTAssertEqual(requests, [[LabelConfirmationDecision(segmentID: segment.id, segmentVersion: segment.version, selection: .unclassified)]])
        XCTAssertEqual(model.segmentCount, 9)
    }

    func testPartialSelectionTogglesToAllAndDraftDoesNotCheckSegment() async {
        let model = LabelReviewViewModel(fetcher: MockLabelReviewFetcher.demo, writer: RecordingLabelConfirmationWriter())
        await model.load()
        let group = model.groups[0]
        model.setSelection(.unclassified, for: group.first)
        XCTAssertEqual(model.allSelectionState, .none)
        model.toggleSelection(for: group.first)
        model.toggleSelection(for: group)
        XCTAssertEqual(model.selectionState(for: group), .all)
        XCTAssertEqual(model.selectedSegmentCount, 3)
        model.toggleAllGroups()
        XCTAssertEqual(model.allSelectionState, .all)
        XCTAssertEqual(model.selectedSegmentCount, 10)
        model.toggleAllGroups()
        XCTAssertEqual(model.allSelectionState, .none)
        model.toggleSelection(for: group)
        model.toggleSelection(for: group)
        XCTAssertEqual(model.selectionState(for: group), .none)
    }

    func testDateChangeFetchesSelectedDayAndRetainsLocallyConfirmedSegments() async {
        let fetcher = RecordingLabelReviewFetcher(response: MockLabelReviewFetcher.demo.response)
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let today = TimelineDate(year: 2026, month: 9, day: 27)
        let model = LabelReviewViewModel(
            fetcher: fetcher,
            writer: RecordingLabelConfirmationWriter(),
            timeZone: zone,
            now: today.startOfDay(timeZone: zone)
        )

        await model.load()
        await model.confirm(model.groups[0])
        XCTAssertEqual(model.segmentCount, 7)

        await model.load()
        XCTAssertEqual(model.segmentCount, 7)
        model.selectDate(TimelineDate(year: 2026, month: 9, day: 26))
        await waitUntil { model.loadState == .loaded && model.selectedDate.day == 26 }

        let dates = await fetcher.dates()
        XCTAssertEqual(dates, [today, today, today, TimelineDate(year: 2026, month: 9, day: 26)])
    }

    func testOldDateResponseCannotReplaceNewDate() async {
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let oldDay = TimelineDate(year: 2026, month: 9, day: 27)
        let newDay = TimelineDate(year: 2026, month: 9, day: 26)
        let model = LabelReviewViewModel(
            fetcher: DelayedLabelReviewFetcher(slowDay: oldDay),
            writer: RecordingLabelConfirmationWriter(),
            timeZone: zone,
            now: oldDay.startOfDay(timeZone: zone)
        )

        let oldRequest = Task { await model.load() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        model.selectDate(newDay)
        await waitUntil { model.loadState == .loaded && model.selectedDate == newDay }
        await oldRequest.value

        XCTAssertEqual(model.selectedDate, newDay)
        XCTAssertEqual(model.segmentCount, 0)
    }

    func testFetchFailureCanRetryAndGroupConfirmationUpdatesSelection() async {
        let response = MockLabelReviewFetcher.demo.response
        let fetcher = SequenceLabelReviewFetcher(results: [
            .failure(.offline),
            .success(LabelReviewSnapshot(response: response)),
        ])
        let viewModel = LabelReviewViewModel(fetcher: fetcher, writer: RecordingLabelConfirmationWriter())

        await viewModel.load()
        XCTAssertEqual(viewModel.loadState, .failed("라벨 제안을 불러오지 못했습니다. 다시 시도해 주세요."))

        await viewModel.load()
        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.segmentCount, 10)

        viewModel.toggleAllGroups()
        XCTAssertTrue(viewModel.allGroupsSelected)
        await viewModel.confirm(viewModel.groups[0])

        XCTAssertEqual(viewModel.segmentCount, 7)
        XCTAssertEqual(viewModel.selectedGroups.count, 6)
    }

    func testIndividualOverrideCanBeConfirmedAndDisappearsFromReview() async {
        let response = MockLabelReviewFetcher.demo.response
        let viewModel = LabelReviewViewModel(
            fetcher: MockLabelReviewFetcher(response: response),
            writer: RecordingLabelConfirmationWriter()
        )
        await viewModel.load()

        let segment = viewModel.groups[0].segments[0]
        let alternateLabel = viewModel.labels[2]
        viewModel.setSelection(.label(id: alternateLabel.id), for: segment)
        XCTAssertEqual(viewModel.title(for: viewModel.selection(for: segment)), "학습")

        await viewModel.confirm(segment)

        XCTAssertEqual(viewModel.segmentCount, 9)
        XCTAssertFalse(viewModel.groups.flatMap(\.segments).contains { $0.id == segment.id })
    }

    func testArchivedProposalMustBeChangedBeforeLocalCompletion() async {
        let archivedLabelID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let activeLabelID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        let segment = LabelReviewSegmentDTO(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            version: String(repeating: "b", count: 64),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_300),
            appName: "Xcode",
            context: .app(title: "Editor.swift"),
            proposal: .ready(.label(id: archivedLabelID))
        )
        let response = LabelReviewResponseDTO(
            labels: [
                LabelReviewLabelDTO(
                    id: archivedLabelID,
                    displayName: "옛 라벨",
                    archivedAt: Date(timeIntervalSince1970: 1_800_000_100)
                ),
                LabelReviewLabelDTO(id: activeLabelID, displayName: "활성 라벨"),
            ],
            segments: [segment]
        )
        let viewModel = LabelReviewViewModel(fetcher: MockLabelReviewFetcher(response: response), writer: RecordingLabelConfirmationWriter())
        await viewModel.load()

        XCTAssertEqual(viewModel.title(for: viewModel.selection(for: viewModel.groups[0].segments[0])), "옛 라벨")
        viewModel.toggleAllGroups()
        XCTAssertEqual(viewModel.missingChoiceCount, 1)
        XCTAssertFalse(viewModel.canConfirm([viewModel.groups[0].segments[0]]))

        await viewModel.confirmSelectedGroups()
        XCTAssertEqual(viewModel.segmentCount, 1)

        viewModel.setSelection(.label(id: activeLabelID), for: viewModel.groups[0].segments[0])
        XCTAssertEqual(viewModel.missingChoiceCount, 0)
        XCTAssertTrue(viewModel.canConfirm([viewModel.groups[0].segments[0]]))
        await viewModel.confirmSelectedGroups()
        XCTAssertEqual(viewModel.segmentCount, 0)
    }

    func testSelectedGroupsCanBeConfirmedTogether() async {
        let writer = RecordingLabelConfirmationWriter()
        let viewModel = LabelReviewViewModel(
            fetcher: MockLabelReviewFetcher(response: MockLabelReviewFetcher.demo.response),
            writer: writer
        )
        await viewModel.load()

        viewModel.toggleSelection(for: viewModel.groups[0])
        viewModel.toggleSelection(for: viewModel.groups[1])
        await viewModel.confirmSelectedGroups()

        XCTAssertEqual(viewModel.segmentCount, 5)
        XCTAssertTrue(viewModel.selectedGroups.isEmpty)
        let requests = await writer.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].map(\.segmentID), Array(MockLabelReviewFetcher.demo.response.segments.prefix(5)).map(\.id))
    }

    func testAtomicFailureKeepsSelectionsAndRetrySendsIdenticalRequest() async {
        let writer = RecordingLabelConfirmationWriter(failures: [
            LabelConfirmationRejection(reason: .timelineBusy, failedIndex: 1, retryAfter: 1)
        ])
        let model = LabelReviewViewModel(fetcher: MockLabelReviewFetcher.demo, writer: writer)
        await model.load()
        let segment = model.groups[0].segments[1]
        let choice = LabelReviewSelection.label(id: model.labels[2].id)
        model.setSelection(choice, for: segment)
        model.toggleSelection(for: model.groups[0])

        await model.confirmSelectedGroups()

        XCTAssertEqual(model.segmentCount, 10)
        XCTAssertEqual(model.selectedSegmentCount, 3)
        XCTAssertEqual(model.selection(for: segment), choice)
        XCTAssertTrue(model.canRetrySubmission)
        XCTAssertTrue(model.submissionMessage?.contains("2번째 기록") == true)

        await model.retrySubmission()

        XCTAssertEqual(model.segmentCount, 7)
        let requests = await writer.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(requests[0][1].selection, .label(model.labels[2].id))
    }

    func testSingleSegmentStaysPendingUntilServerConfirms() async {
        let writer = SuspendedLabelConfirmationWriter()
        let model = LabelReviewViewModel(fetcher: MockLabelReviewFetcher.demo, writer: writer)
        await model.load()
        let segment = model.groups[0].segments[0]

        let submission = Task { await model.confirm(segment) }
        await waitUntil { model.isSubmitting }
        while !(await writer.isPending()) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(model.segmentCount, 10)
        XCTAssertFalse(model.canConfirm([segment]))

        await writer.succeed()
        await submission.value

        XCTAssertEqual(model.segmentCount, 9)
        let requests = await writer.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].map(\.segmentID), [segment.id])
    }

    func testRefreshCannotInterruptInFlightSubmission() async {
        let fetcher = RecordingLabelReviewFetcher(response: MockLabelReviewFetcher.demo.response)
        let writer = SuspendedLabelConfirmationWriter()
        let model = LabelReviewViewModel(fetcher: fetcher, writer: writer)
        await model.load()
        let segment = model.groups[0].segments[0]

        let submission = Task { await model.confirm(segment) }
        await waitUntil { model.isSubmitting }
        while !(await writer.isPending()) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await model.load()
        model.moveDate(by: -1)
        XCTAssertTrue(model.isSubmitting)
        XCTAssertEqual(model.segmentCount, 10)
        let datesBeforeCompletion = await fetcher.dates()
        XCTAssertEqual(datesBeforeCompletion.count, 1)

        await writer.succeed()
        await submission.value
        XCTAssertEqual(model.segmentCount, 9)
        let completedRequests = await writer.recordedRequests()
        XCTAssertEqual(completedRequests.count, 1)
    }

    func testSuccessfulSubmissionFetchesLatestAndPreservesChangedVersionChoice() async {
        let first = MockLabelReviewFetcher.demo.response
        var latestSegments = Array(first.segments.dropFirst())
        let changed = latestSegments[0]
        latestSegments[0] = LabelReviewSegmentDTO(
            id: changed.id, version: String(repeating: "f", count: 64),
            startedAt: changed.startedAt, endedAt: changed.endedAt,
            appName: changed.appName, context: changed.context, proposal: changed.proposal
        )
        let fetcher = SnapshotSequenceLabelReviewFetcher(responses: [
            first, LabelReviewResponseDTO(labels: first.labels, segments: latestSegments)
        ], confirmedByID: [:])
        let model = LabelReviewViewModel(fetcher: fetcher, writer: RecordingLabelConfirmationWriter())
        await model.load()
        let target = model.groups[0].segments[1]
        let choice = LabelReviewSelection.label(id: model.labels[2].id)
        model.setSelection(choice, for: target)

        await model.confirm(model.groups[0].segments[0])

        XCTAssertEqual(model.segmentCount, 9)
        XCTAssertEqual(model.groups[0].segments[0].version, String(repeating: "f", count: 64))
        XCTAssertEqual(model.selection(for: model.groups[0].segments[0]), choice)
    }

    func testConflictRefreshFailureRetriesFetchWithoutResendingSubmission() async {
        let first = MockLabelReviewFetcher.demo.response
        let latest = LabelReviewResponseDTO(labels: first.labels, segments: Array(first.segments.dropFirst()))
        let fetcher = SequenceLabelReviewFetcher(results: [
            .success(LabelReviewSnapshot(response: first)),
            .failure(.offline),
            .success(LabelReviewSnapshot(response: latest)),
        ])
        let writer = RecordingLabelConfirmationWriter(failures: [
            LabelConfirmationRejection(reason: .priorConfirmationConflict, failedIndex: 0)
        ])
        let model = LabelReviewViewModel(fetcher: fetcher, writer: writer)
        await model.load()
        let target = model.groups[0].segments[1]
        let choice = LabelReviewSelection.label(id: model.labels[2].id)
        model.setSelection(choice, for: target)
        model.toggleSelection(for: model.groups[0])

        await model.confirmSelectedGroups()
        XCTAssertEqual(model.retryActionTitle, "최신 상태 다시 조회")
        XCTAssertTrue(model.canRetrySubmission)
        XCTAssertEqual(model.selection(for: target), choice)

        await model.retrySubmission()
        XCTAssertEqual(model.segmentCount, 9)
        XCTAssertEqual(model.selectedSegmentCount, 2)
        XCTAssertEqual(model.selection(for: model.groups[0].segments[0]), choice)
        XCTAssertFalse(model.canRetrySubmission)
        let requests = await writer.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testTerminalSegmentRejectionsRefreshInsteadOfRetryingStaleDecision() async {
        let first = MockLabelReviewFetcher.demo.response
        let latest = LabelReviewResponseDTO(labels: first.labels, segments: Array(first.segments.dropFirst()))
        for reason: LabelConfirmationRejectionReason in [.segmentNotFound, .segmentNotLabelable] {
            let fetcher = SnapshotSequenceLabelReviewFetcher(responses: [first, latest], confirmedByID: [:])
            let writer = RecordingLabelConfirmationWriter(failures: [
                LabelConfirmationRejection(reason: reason, failedIndex: 0)
            ])
            let model = LabelReviewViewModel(fetcher: fetcher, writer: writer)
            await model.load()

            await model.confirm(model.groups[0].segments[0])

            XCTAssertEqual(model.segmentCount, 9)
            XCTAssertEqual(model.conflictedDrafts.map(\.id), [first.segments[0].id])
            XCTAssertFalse(model.canRetrySubmission)
            let requests = await writer.recordedRequests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testUnavailableLabelRejectionRefreshesCatalogAndKeepsChoiceVisible() async {
        let first = MockLabelReviewFetcher.demo.response
        let unavailableID = first.labels[0].id
        let latest = LabelReviewResponseDTO(
            labels: first.labels.map { label in
                LabelReviewLabelDTO(
                    id: label.id,
                    displayName: label.displayName,
                    archivedAt: label.id == unavailableID ? Date() : label.archivedAt
                )
            },
            segments: first.segments
        )
        let fetcher = SnapshotSequenceLabelReviewFetcher(responses: [first, latest], confirmedByID: [:])
        let writer = RecordingLabelConfirmationWriter(failures: [
            LabelConfirmationRejection(reason: .labelNotAvailable, failedIndex: 0)
        ])
        let model = LabelReviewViewModel(fetcher: fetcher, writer: writer)
        await model.load()
        let segment = model.groups[0].segments[0]

        await model.confirm(segment)

        XCTAssertEqual(model.segmentCount, 10)
        XCTAssertEqual(model.selection(for: model.groups[0].segments[0]), .label(id: unavailableID))
        XCTAssertFalse(model.canConfirm([model.groups[0].segments[0]]))
        XCTAssertFalse(model.canRetrySubmission)
        let requests = await writer.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testPriorConfirmationRefreshPreservesRemainingChoicesAcrossVersionChange() async {
        let first = MockLabelReviewFetcher.demo.response
        var refreshedSegments = first.segments
        refreshedSegments.removeFirst()
        let changed = refreshedSegments[0]
        refreshedSegments[0] = LabelReviewSegmentDTO(
            id: changed.id, version: String(repeating: "e", count: 64),
            startedAt: changed.startedAt, endedAt: changed.endedAt,
            appName: changed.appName, context: changed.context, proposal: changed.proposal
        )
        let fetcher = SnapshotSequenceLabelReviewFetcher(responses: [
            first, LabelReviewResponseDTO(labels: first.labels, segments: refreshedSegments)
        ], confirmedByID: [first.segments[0].id: .label(id: first.labels[1].id)])
        let writer = RecordingLabelConfirmationWriter(failures: [
            LabelConfirmationRejection(reason: .priorConfirmationConflict, failedIndex: 0)
        ])
        let model = LabelReviewViewModel(fetcher: fetcher, writer: writer)
        await model.load()
        let target = model.groups[0].segments[1]
        let choice = LabelReviewSelection.label(id: model.labels[2].id)
        model.setSelection(choice, for: target)
        model.toggleSelection(for: model.groups[0])

        await model.confirmSelectedGroups()

        XCTAssertEqual(model.segmentCount, 9)
        XCTAssertEqual(model.selectedSegmentCount, 2)
        XCTAssertEqual(model.selection(for: model.groups[0].segments[0]), choice)
        XCTAssertEqual(model.groups[0].segments[0].version, String(repeating: "e", count: 64))
        XCTAssertEqual(model.conflictedDrafts.count, 1)
        XCTAssertEqual(model.conflictedDrafts[0].id, first.segments[0].id)
        XCTAssertEqual(model.conflictedDrafts[0].confirmedSelection, .label(id: model.labels[1].id))
        XCTAssertEqual(model.conflictedDrafts[0].selection, .label(id: model.labels[0].id))
        XCTAssertFalse(model.canRetrySubmission)
        XCTAssertTrue(model.submissionMessage?.contains("최신 목록") == true)
    }

    func testEmptyFetchProducesLoadedEmptyModel() async {
        let response = LabelReviewResponseDTO(labels: [], segments: [])
        let viewModel = LabelReviewViewModel(fetcher: MockLabelReviewFetcher(response: response), writer: RecordingLabelConfirmationWriter())

        await viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertTrue(viewModel.groups.isEmpty)
        XCTAssertEqual(viewModel.segmentCount, 0)
    }

    private func waitUntil(
        condition: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds - start < 1_000_000_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }
}

private enum LabelReviewFetchFailure: Error, Sendable {
    case offline
}

private actor RecordingLabelConfirmationWriter: LabelConfirmationWriting {
    private var requests: [[LabelConfirmationDecision]] = []
    private var failures: [LabelConfirmationRejection]

    init(failures: [LabelConfirmationRejection] = []) { self.failures = failures }

    func confirmSegmentLabels(_ decisions: [LabelConfirmationDecision]) async throws {
        requests.append(decisions)
        if !failures.isEmpty { throw failures.removeFirst() }
    }

    func recordedRequests() -> [[LabelConfirmationDecision]] { requests }
}

private actor SuspendedLabelConfirmationWriter: LabelConfirmationWriting {
    private var requests: [[LabelConfirmationDecision]] = []
    private var continuation: CheckedContinuation<Void, Error>?

    func confirmSegmentLabels(_ decisions: [LabelConfirmationDecision]) async throws {
        requests.append(decisions)
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func succeed() {
        continuation?.resume()
        continuation = nil
    }

    func recordedRequests() -> [[LabelConfirmationDecision]] { requests }

    func isPending() -> Bool { continuation != nil }
}

private actor SnapshotSequenceLabelReviewFetcher: LabelReviewFetching {
    private var responses: [LabelReviewResponseDTO]
    private let confirmedByID: [UUID: LabelReviewSelection]

    init(responses: [LabelReviewResponseDTO], confirmedByID: [UUID: LabelReviewSelection]) {
        self.responses = responses
        self.confirmedByID = confirmedByID
    }

    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot {
        LabelReviewSnapshot(response: responses.removeFirst())
    }

    func confirmedSelection(segmentID: UUID) async throws -> LabelReviewSelection? {
        confirmedByID[segmentID]
    }
}

private actor SequenceLabelReviewFetcher: LabelReviewFetching {
    private var results: [Result<LabelReviewSnapshot, LabelReviewFetchFailure>]

    init(results: [Result<LabelReviewSnapshot, LabelReviewFetchFailure>]) {
        self.results = results
    }

    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot {
        guard !results.isEmpty else { throw LabelReviewFetchFailure.offline }
        return try results.removeFirst().get()
    }

    func confirmedSelection(segmentID: UUID) async throws -> LabelReviewSelection? { nil }
}

private actor RecordingLabelReviewFetcher: LabelReviewFetching {
    let response: LabelReviewResponseDTO
    private var requestedDates: [TimelineDate] = []

    init(response: LabelReviewResponseDTO) { self.response = response }

    func dates() -> [TimelineDate] { requestedDates }

    func confirmedSelection(segmentID: UUID) async throws -> LabelReviewSelection? { nil }

    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot {
        requestedDates.append(day)
        return LabelReviewSnapshot(response: response)
    }
}

private struct DelayedLabelReviewFetcher: LabelReviewFetching {
    let slowDay: TimelineDate

    func confirmedSelection(segmentID: UUID) async throws -> LabelReviewSelection? { nil }

    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot {
        try? await Task.sleep(nanoseconds: day == slowDay ? 250_000_000 : 10_000_000)
        let response = day == slowDay
            ? MockLabelReviewFetcher.demo.response
            : LabelReviewResponseDTO(labels: [], segments: [])
        return LabelReviewSnapshot(response: response)
    }
}

final class LiveLabelReviewFetcherTests: XCTestCase {
    func testRawWebContextSurvivesReviewFetching() async throws {
        let id = UUID()
        let segment = PendingLabelTimelineSegment(id: id, version: "v1", sourceGroupVersion: "g1", startedAt: .now, endedAt: .now, appName: "Browser", context: .web(title: nil, url: "https://Example.com/path?q=1"))
        let reader = FixedLabelReviewReader(labels: [], segments: [segment], states: [id: .pending(id: id, version: "v1", proposal: .readyUnclassified)])
        let snapshot = try await LiveLabelReviewFetcher(reader: reader).fetchLabelReview(day: TimelineDate(year: 2026, month: 9, day: 26))
        XCTAssertEqual(snapshot.segments.first?.context, .web(title: nil, url: "https://Example.com/path?q=1"))
    }

    func testMapsCatalogAndEveryPendingProposalState() async throws {
        let labelID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let labels = [LabelCatalogEntry(id: labelID, displayName: "옛 라벨", archivedAt: archivedAt)]
        let segments = (1...5).map { index in
            PendingLabelTimelineSegment(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                version: String(repeating: String(index), count: 64),
                sourceGroupVersion: "group-\(index)",
                startedAt: Date(timeIntervalSince1970: Double(index * 600)),
                endedAt: Date(timeIntervalSince1970: Double(index * 600 + 300)),
                appName: "App \(index)",
                context: .app(title: "Title \(index)")
            )
        }
        let proposals: [RemoteLabelProposal] = [
            .readyLabel(labelID), .readyUnclassified, .waiting, .processing, .failed
        ]
        let states = Dictionary(uniqueKeysWithValues: zip(segments, proposals).map {
            ($0.id, RemoteSegmentLabelState.pending(id: $0.id, version: $0.version, proposal: $1))
        })
        let reader = FixedLabelReviewReader(labels: labels, segments: segments, states: states)
        let day = TimelineDate(year: 2026, month: 9, day: 27)

        let snapshot = try await LiveLabelReviewFetcher(reader: reader).fetchLabelReview(day: day)

        XCTAssertEqual(snapshot.labels.map(\.displayName), ["옛 라벨"])
        XCTAssertEqual(snapshot.labels.first?.archivedAt, archivedAt)
        XCTAssertEqual(snapshot.segments.map(\.id), segments.map(\.id))
        XCTAssertEqual(snapshot.segments.map(\.version), segments.map(\.version))
        XCTAssertEqual(snapshot.segments.map(\.sourceGroupVersion), segments.map(\.sourceGroupVersion))
        XCTAssertEqual(snapshot.segments.map(\.proposal), [
            .ready(.label(id: labelID)), .ready(.unclassified), .waiting, .processing, .failed
        ])
    }

    func testChangedSegmentVersionRefetchesTimelineOnce() async throws {
        let reader = ChangingLabelReviewReader()
        let snapshot = try await LiveLabelReviewFetcher(reader: reader).fetchLabelReview(
            day: TimelineDate(year: 2026, month: 9, day: 27)
        )

        XCTAssertEqual(snapshot.segments.count, 1)
        XCTAssertEqual(snapshot.segments[0].version, String(repeating: "b", count: 64))
        let fetchCount = await reader.timelineFetchCount()
        XCTAssertEqual(fetchCount, 2)
    }

    func testSegmentDisappearingDuringFetchRetriesWithCurrentTimeline() async throws {
        let reader = DisappearingLabelReviewReader()

        let snapshot = try await LiveLabelReviewFetcher(reader: reader).fetchLabelReview(
            day: TimelineDate(year: 2026, month: 9, day: 27)
        )

        XCTAssertTrue(snapshot.segments.isEmpty)
        let fetchCount = await reader.timelineFetchCount()
        XCTAssertEqual(fetchCount, 2)
    }
}

private struct FixedLabelReviewReader: LabelReviewReading {
    let labels: [LabelCatalogEntry]
    let segments: [PendingLabelTimelineSegment]
    let states: [UUID: RemoteSegmentLabelState]

    func listLabels() async throws -> [LabelCatalogEntry] { labels }
    func pendingLabelSegments(day: TimelineDate) async throws -> [PendingLabelTimelineSegment] { segments }
    func labelState(segmentID: UUID) async throws -> RemoteSegmentLabelState {
        states[segmentID]!
    }
}

private actor ChangingLabelReviewReader: LabelReviewReading {
    private let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private var fetchCount = 0

    func timelineFetchCount() -> Int { fetchCount }
    func listLabels() async throws -> [LabelCatalogEntry] { [] }

    func pendingLabelSegments(day: TimelineDate) async throws -> [PendingLabelTimelineSegment] {
        fetchCount += 1
        return [PendingLabelTimelineSegment(
            id: id,
            version: String(repeating: fetchCount == 1 ? "a" : "b", count: 64),
            sourceGroupVersion: "group",
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 60),
            appName: "Xcode",
            context: .app(title: "Editor")
        )]
    }

    func labelState(segmentID: UUID) async throws -> RemoteSegmentLabelState {
        .pending(id: id, version: String(repeating: "b", count: 64), proposal: .waiting)
    }
}

private actor DisappearingLabelReviewReader: LabelReviewReading {
    private let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private var fetchCount = 0

    func timelineFetchCount() -> Int { fetchCount }
    func listLabels() async throws -> [LabelCatalogEntry] { [] }

    func pendingLabelSegments(day: TimelineDate) async throws -> [PendingLabelTimelineSegment] {
        fetchCount += 1
        guard fetchCount == 1 else { return [] }
        return [PendingLabelTimelineSegment(
            id: id, version: String(repeating: "a", count: 64), sourceGroupVersion: "group",
            startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 60),
            appName: "Xcode", context: .app(title: "Editor")
        )]
    }

    func labelState(segmentID: UUID) async throws -> RemoteSegmentLabelState {
        throw MosemoAPIError.unexpectedResponse(statusCode: 404)
    }
}

// The second response deliberately ignores cancellation to simulate an already received response.
private actor SuspendedPollingFetcher: LabelReviewFetching {
    private var count = 0
    private var continuation: CheckedContinuation<LabelReviewSnapshot, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func confirmedSelection(segmentID: UUID) async throws -> LabelReviewSelection? { nil }

    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot {
        count += 1
        let response = MockLabelReviewFetcher.demo.response
        if count == 2 {
            return await withCheckedContinuation {
                continuation = $0
                waiter?.resume()
                waiter = nil
            }
        }
        let segments = count == 1 ? response.segments : response.segments.filter {
            switch $0.proposal {
            case .ready, .failed: true
            case .waiting, .processing: false
            }
        }
        return LabelReviewSnapshot(response: LabelReviewResponseDTO(labels: response.labels, segments: segments))
    }

    func requestCount() -> Int { count }

    func waitForPollingRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finishPolling() {
        continuation?.resume(returning: LabelReviewSnapshot(response: LabelReviewResponseDTO(labels: [], segments: [])))
        continuation = nil
    }
}
