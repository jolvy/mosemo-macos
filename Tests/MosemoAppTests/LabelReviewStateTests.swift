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
            title: changed.title,
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
                title: segment.title,
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
    func testDateChangeFetchesSelectedDayAndRefreshRestoresServerState() async {
        let fetcher = RecordingLabelReviewFetcher(response: MockLabelReviewFetcher.demo.response)
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let today = TimelineDate(year: 2026, month: 9, day: 27)
        let model = LabelReviewViewModel(
            fetcher: fetcher,
            timeZone: zone,
            now: today.startOfDay(timeZone: zone)
        )

        await model.load()
        model.confirm(model.groups[0])
        XCTAssertEqual(model.segmentCount, 7)

        await model.load()
        XCTAssertEqual(model.segmentCount, 10)
        model.selectDate(TimelineDate(year: 2026, month: 9, day: 26))
        await waitUntil { model.loadState == .loaded && model.selectedDate.day == 26 }

        let dates = await fetcher.dates()
        XCTAssertEqual(dates, [today, today, TimelineDate(year: 2026, month: 9, day: 26)])
    }

    func testOldDateResponseCannotReplaceNewDate() async {
        let zone = TimeZone(identifier: "Asia/Seoul")!
        let oldDay = TimelineDate(year: 2026, month: 9, day: 27)
        let newDay = TimelineDate(year: 2026, month: 9, day: 26)
        let model = LabelReviewViewModel(
            fetcher: DelayedLabelReviewFetcher(slowDay: oldDay),
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
        let viewModel = LabelReviewViewModel(fetcher: fetcher)

        await viewModel.load()
        XCTAssertEqual(viewModel.loadState, .failed("라벨 제안을 불러오지 못했습니다. 다시 시도해 주세요."))

        await viewModel.load()
        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.segmentCount, 10)

        viewModel.toggleAllGroups()
        XCTAssertTrue(viewModel.allGroupsSelected)
        viewModel.confirm(viewModel.groups[0])

        XCTAssertEqual(viewModel.segmentCount, 7)
        XCTAssertEqual(viewModel.selectedGroups.count, 6)
    }

    func testIndividualOverrideCanBeConfirmedAndDisappearsFromReview() async {
        let response = MockLabelReviewFetcher.demo.response
        let viewModel = LabelReviewViewModel(
            fetcher: MockLabelReviewFetcher(response: response)
        )
        await viewModel.load()

        let segment = viewModel.groups[0].segments[0]
        let alternateLabel = viewModel.labels[2]
        viewModel.setSelection(.label(id: alternateLabel.id), for: segment)
        XCTAssertEqual(viewModel.title(for: viewModel.selection(for: segment)), "학습")

        viewModel.confirm(segment)

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
            title: "Editor.swift",
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
        let viewModel = LabelReviewViewModel(fetcher: MockLabelReviewFetcher(response: response))
        await viewModel.load()

        XCTAssertEqual(viewModel.title(for: viewModel.selection(for: viewModel.groups[0].segments[0])), "옛 라벨")
        viewModel.toggleAllGroups()
        XCTAssertEqual(viewModel.missingChoiceCount, 1)
        XCTAssertFalse(viewModel.canConfirm([viewModel.groups[0].segments[0]]))

        viewModel.confirmSelectedGroups()
        XCTAssertEqual(viewModel.segmentCount, 1)

        viewModel.setSelection(.label(id: activeLabelID), for: viewModel.groups[0].segments[0])
        XCTAssertEqual(viewModel.missingChoiceCount, 0)
        XCTAssertTrue(viewModel.canConfirm([viewModel.groups[0].segments[0]]))
        viewModel.confirmSelectedGroups()
        XCTAssertEqual(viewModel.segmentCount, 0)
    }

    func testSelectedGroupsCanBeConfirmedTogether() async {
        let viewModel = LabelReviewViewModel(
            fetcher: MockLabelReviewFetcher(response: MockLabelReviewFetcher.demo.response)
        )
        await viewModel.load()

        viewModel.toggleSelection(for: viewModel.groups[0])
        viewModel.toggleSelection(for: viewModel.groups[1])
        viewModel.confirmSelectedGroups()

        XCTAssertEqual(viewModel.segmentCount, 5)
        XCTAssertTrue(viewModel.selectedGroups.isEmpty)
    }

    func testEmptyFetchProducesLoadedEmptyModel() async {
        let response = LabelReviewResponseDTO(labels: [], segments: [])
        let viewModel = LabelReviewViewModel(fetcher: MockLabelReviewFetcher(response: response))

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

private actor SequenceLabelReviewFetcher: LabelReviewFetching {
    private var results: [Result<LabelReviewSnapshot, LabelReviewFetchFailure>]

    init(results: [Result<LabelReviewSnapshot, LabelReviewFetchFailure>]) {
        self.results = results
    }

    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot {
        guard !results.isEmpty else { throw LabelReviewFetchFailure.offline }
        return try results.removeFirst().get()
    }
}

private actor RecordingLabelReviewFetcher: LabelReviewFetching {
    let response: LabelReviewResponseDTO
    private var requestedDates: [TimelineDate] = []

    init(response: LabelReviewResponseDTO) { self.response = response }

    func dates() -> [TimelineDate] { requestedDates }

    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot {
        requestedDates.append(day)
        return LabelReviewSnapshot(response: response)
    }
}

private struct DelayedLabelReviewFetcher: LabelReviewFetching {
    let slowDay: TimelineDate

    func fetchLabelReview(day: TimelineDate) async throws -> LabelReviewSnapshot {
        try? await Task.sleep(nanoseconds: day == slowDay ? 250_000_000 : 10_000_000)
        let response = day == slowDay
            ? MockLabelReviewFetcher.demo.response
            : LabelReviewResponseDTO(labels: [], segments: [])
        return LabelReviewSnapshot(response: response)
    }
}

final class LiveLabelReviewFetcherTests: XCTestCase {
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
                title: "Title \(index)"
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
            title: "Editor"
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
            appName: "Xcode", title: "Editor"
        )]
    }

    func labelState(segmentID: UUID) async throws -> RemoteSegmentLabelState {
        throw MosemoAPIError.unexpectedResponse(statusCode: 404)
    }
}
