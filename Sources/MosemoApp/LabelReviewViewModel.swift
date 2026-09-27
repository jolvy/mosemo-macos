import Combine
import Foundation
import MosemoAPI

extension LabelReviewSelection {
    func title(in labels: [LabelReviewLabel]) -> String {
        switch self {
        case .label(let id):
            labels.first(where: { $0.id == id })?.displayName ?? "사용할 수 없는 라벨"
        case .unclassified:
            "미분류"
        }
    }
}

extension LabelReviewProposal {
    func title(in labels: [LabelReviewLabel]) -> String {
        switch self {
        case .ready(let selection): "AI 제안 · \(selection.title(in: labels))"
        case .waiting: "제안 대기 중"
        case .processing: "제안 처리 중"
        case .failed: "제안 실패"
        }
    }
}

@MainActor
final class LabelReviewViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private struct SegmentKey: Hashable {
        let id: UUID
        let version: String

        init(_ segment: LabelReviewSegment) {
            id = segment.id
            version = segment.version
        }
    }

    @Published private(set) var review: LabelReviewState?
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var selectedDate: TimelineDate
    @Published private(set) var selectedGroupIDs: Set<UUID> = []
    @Published private(set) var expandedGroupIDs: Set<UUID> = []
    @Published private var draftOverrides: [SegmentKey: LabelReviewSelection] = [:]

    private let fetcher: any LabelReviewFetching
    let timeZone: TimeZone
    private var requestID = UUID()

    init(
        fetcher: any LabelReviewFetching,
        timeZone: TimeZone = .current,
        now: Date = .now
    ) {
        self.fetcher = fetcher
        self.timeZone = timeZone
        selectedDate = TimelineDate(now, timeZone: timeZone)
    }

    var groups: [LabelReviewGroup] { review?.groups ?? [] }
    var labels: [LabelReviewLabel] { review?.labels ?? [] }
    var segmentCount: Int { review?.pendingSegments.count ?? 0 }

    var selectedGroups: [LabelReviewGroup] {
        groups.filter { selectedGroupIDs.contains($0.id) }
    }

    var selectedSegmentCount: Int {
        selectedGroups.reduce(0) { $0 + $1.segments.count }
    }

    var allGroupsSelected: Bool {
        !groups.isEmpty && selectedGroups.count == groups.count
    }

    var missingChoiceCount: Int {
        selectedGroups.flatMap(\.segments).filter { segment in
            guard let selection = selection(for: segment) else { return true }
            return review?.canLocallyComplete(segment, with: selection) != true
        }.count
    }

    func load() async {
        let id = UUID()
        requestID = id
        loadState = .loading
        review = nil
        selectedGroupIDs = []
        expandedGroupIDs = []
        draftOverrides = [:]
        do {
            let snapshot = try await fetcher.fetchLabelReview(day: selectedDate)
            guard requestID == id else { return }
            review = LabelReviewState(snapshot: snapshot)
            loadState = .loaded
            reconcileInteractionState()
        } catch {
            guard requestID == id else { return }
            loadState = .failed("라벨 제안을 불러오지 못했습니다. 다시 시도해 주세요.")
        }
    }

    func selectDate(_ date: TimelineDate) {
        guard selectedDate != date else { return }
        selectedDate = date
        requestID = UUID()
        loadState = .loading
        Task { await load() }
    }

    func selectDate(_ date: Date) {
        selectDate(TimelineDate(date, timeZone: timeZone))
    }

    func moveDate(by days: Int) {
        selectDate(selectedDate.adding(days: days, timeZone: timeZone))
    }

    func toggleAllGroups() {
        if allGroupsSelected {
            selectedGroupIDs.removeAll()
        } else {
            selectedGroupIDs = Set(groups.map(\.id))
        }
    }

    func toggleSelection(for group: LabelReviewGroup) {
        if selectedGroupIDs.contains(group.id) {
            selectedGroupIDs.remove(group.id)
        } else {
            selectedGroupIDs.insert(group.id)
        }
    }

    func toggleExpansion(for group: LabelReviewGroup) {
        if expandedGroupIDs.contains(group.id) {
            expandedGroupIDs.remove(group.id)
        } else {
            expandedGroupIDs.insert(group.id)
        }
    }

    func selection(for segment: LabelReviewSegment) -> LabelReviewSelection? {
        draftOverrides[SegmentKey(segment)] ?? segment.proposal.selection
    }

    func setSelection(_ selection: LabelReviewSelection, for segment: LabelReviewSegment) {
        draftOverrides[SegmentKey(segment)] = selection
    }

    func title(for selection: LabelReviewSelection?) -> String {
        selection?.title(in: labels) ?? "라벨 선택"
    }

    func canConfirm(_ segments: [LabelReviewSegment]) -> Bool {
        guard let review, !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            guard let selection = selection(for: segment) else { return false }
            return review.canLocallyComplete(segment, with: selection)
        }
    }

    func selectionSummary(for segments: [LabelReviewSegment]) -> String {
        var counts: [(LabelReviewSelection, Int)] = []
        for segment in segments {
            guard let selection = selection(for: segment) else { continue }
            if let index = counts.firstIndex(where: { $0.0 == selection }) {
                counts[index].1 += 1
            } else {
                counts.append((selection, 1))
            }
        }
        return counts.isEmpty
            ? "선택 전"
            : counts.map { "\(title(for: $0.0)) \($0.1)건" }.joined(separator: " · ")
    }

    func groupActionTitle(_ group: LabelReviewGroup) -> String {
        let unchanged = group.segments.allSatisfy {
            $0.proposal.selection != nil && selection(for: $0) == $0.proposal.selection
        }
        return unchanged ? "\(group.segments.count)건 로컬 완료" : "\(group.segments.count)건 선택대로 로컬 완료"
    }

    func confirmSelectedGroups() {
        confirm(selectedGroups.flatMap(\.segments))
    }

    func confirm(_ group: LabelReviewGroup) {
        confirm(group.segments)
    }

    func confirm(_ segment: LabelReviewSegment) {
        confirm([segment])
    }

    private func confirm(_ segments: [LabelReviewSegment]) {
        guard let review, canConfirm(segments) else { return }
        let decisions = segments.compactMap { segment -> LabelReviewDecision? in
            guard let selection = selection(for: segment) else { return nil }
            return LabelReviewDecision(
                segmentID: segment.id,
                segmentVersion: segment.version,
                selection: selection
            )
        }
        guard decisions.count == segments.count else { return }
        self.review = review.applying(decisions)
        reconcileInteractionState()
    }

    private func reconcileInteractionState() {
        let validGroupIDs = Set(groups.map(\.id))
        selectedGroupIDs.formIntersection(validGroupIDs)
        expandedGroupIDs.formIntersection(validGroupIDs)

        let validSegmentKeys = Set((review?.pendingSegments ?? []).map(SegmentKey.init))
        draftOverrides = draftOverrides.filter { validSegmentKeys.contains($0.key) }
    }
}
