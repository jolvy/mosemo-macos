import Combine
import Foundation

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

    @Published private(set) var data: LabelReviewData?
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var selectedGroupIDs: Set<UUID> = []
    @Published private(set) var expandedGroupIDs: Set<UUID> = []
    @Published private var draftOverrides: [SegmentKey: LabelReviewSelection] = [:]

    private let fetcher: any LabelReviewFetching

    init(fetcher: any LabelReviewFetching) {
        self.fetcher = fetcher
    }

    var groups: [LabelReviewGroup] { data?.groups ?? [] }
    var labels: [LabelReviewLabel] { data?.labels ?? [] }
    var segmentCount: Int { data?.pendingSegments.count ?? 0 }

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
            return data?.canSelect(selection) != true
        }.count
    }

    func load() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            let response = try await fetcher.fetchLabelReview()
            if let data {
                self.data = data.replacing(with: response)
            } else {
                data = LabelReviewData(response: response)
            }
            loadState = .loaded
            reconcileInteractionState()
        } catch {
            loadState = .failed("라벨 제안을 불러오지 못했습니다. 다시 시도해 주세요.")
        }
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
        guard let data, !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            guard let selection = selection(for: segment) else { return false }
            return data.canSelect(selection)
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
        return unchanged ? "\(group.segments.count)건 모두 승인" : "\(group.segments.count)건 선택대로 확정"
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
        guard let data, canConfirm(segments) else { return }
        let decisions = segments.compactMap { segment -> LabelReviewDecision? in
            guard let selection = selection(for: segment) else { return nil }
            return LabelReviewDecision(
                segmentID: segment.id,
                segmentVersion: segment.version,
                selection: selection
            )
        }
        guard decisions.count == segments.count else { return }
        self.data = data.applying(decisions)
        reconcileInteractionState()
    }

    private func reconcileInteractionState() {
        let validGroupIDs = Set(groups.map(\.id))
        selectedGroupIDs.formIntersection(validGroupIDs)
        expandedGroupIDs.formIntersection(validGroupIDs)

        let validSegmentKeys = Set((data?.pendingSegments ?? []).map(SegmentKey.init))
        draftOverrides = draftOverrides.filter { validSegmentKeys.contains($0.key) }
    }
}
