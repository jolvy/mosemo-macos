import XCTest
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
}

@MainActor
final class LabelReviewViewModelTests: XCTestCase {
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
}

private enum LabelReviewFetchFailure: Error, Sendable {
    case offline
}

private actor SequenceLabelReviewFetcher: LabelReviewFetching {
    private var results: [Result<LabelReviewSnapshot, LabelReviewFetchFailure>]

    init(results: [Result<LabelReviewSnapshot, LabelReviewFetchFailure>]) {
        self.results = results
    }

    func fetchLabelReview() async throws -> LabelReviewSnapshot {
        guard !results.isEmpty else { throw LabelReviewFetchFailure.offline }
        return try results.removeFirst().get()
    }
}
