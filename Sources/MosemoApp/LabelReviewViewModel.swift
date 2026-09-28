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

struct LabelReviewConflictedDraft: Identifiable, Equatable {
    let id: UUID
    let title: String
    let confirmedSelection: LabelReviewSelection?
    let selection: LabelReviewSelection
}

@MainActor
final class LabelReviewViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var review: LabelReviewState?
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var selectedDate: TimelineDate
    @Published private(set) var selectedSegmentIDs: Set<UUID> = []
    @Published private(set) var expandedGroupIDs: Set<UUID> = []
    @Published private var draftOverrides: [UUID: LabelReviewSelection] = [:]
    @Published private(set) var isSubmitting = false
    @Published private(set) var submissionMessage: String?
    @Published private(set) var canRetrySubmission = false
    @Published private(set) var conflictedDrafts: [LabelReviewConflictedDraft] = []

    private let fetcher: any LabelReviewFetching
    private let writer: any LabelConfirmationWriting
    let timeZone: TimeZone
    private var requestID = UUID()
    private var retryDecisions: [LabelConfirmationDecision]?
    private var retryAvailableAt: Date?
    private var retryConflictReview: LabelReviewState?

    init(
        fetcher: any LabelReviewFetching,
        writer: any LabelConfirmationWriting,
        timeZone: TimeZone = .current,
        now: Date = .now
    ) {
        self.fetcher = fetcher
        self.writer = writer
        self.timeZone = timeZone
        selectedDate = TimelineDate(now, timeZone: timeZone)
    }

    var groups: [LabelReviewGroup] { review?.groups ?? [] }
    var labels: [LabelReviewLabel] { review?.labels ?? [] }
    var segmentCount: Int { review?.pendingSegments.count ?? 0 }

    var selectedGroups: [LabelReviewGroup] {
        groups.filter { group in group.segments.contains { selectedSegmentIDs.contains($0.id) } }
    }

    var selectedSegments: [LabelReviewSegment] {
        review?.pendingSegments.filter { selectedSegmentIDs.contains($0.id) } ?? []
    }

    var selectedSegmentCount: Int {
        selectedSegments.count
    }

    var retryActionTitle: String {
        retryConflictReview == nil ? "다시 제출" : "최신 상태 다시 조회"
    }

    var allGroupsSelected: Bool {
        segmentCount > 0 && selectedSegmentIDs.count == segmentCount
    }

    var missingChoiceCount: Int {
        selectedSegments.filter { segment in
            guard let selection = selection(for: segment) else { return true }
            return review?.canSelect(selection) != true
        }.count
    }

    func load() async {
        guard !isSubmitting else { return }
        let id = UUID()
        requestID = id
        loadState = .loading
        submissionMessage = nil
        retryDecisions = nil
        retryAvailableAt = nil
        retryConflictReview = nil
        canRetrySubmission = false
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
        guard !isSubmitting, selectedDate != date else { return }
        selectedDate = date
        requestID = UUID()
        review = nil
        selectedSegmentIDs = []
        expandedGroupIDs = []
        draftOverrides = [:]
        conflictedDrafts = []
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
        guard !isSubmitting else { return }
        if allGroupsSelected {
            selectedSegmentIDs.removeAll()
        } else {
            selectedSegmentIDs = Set(review?.pendingSegments.map(\.id) ?? [])
        }
    }

    func toggleSelection(for group: LabelReviewGroup) {
        guard !isSubmitting else { return }
        let ids = Set(group.segments.map(\.id))
        if ids.isSubset(of: selectedSegmentIDs) {
            selectedSegmentIDs.subtract(ids)
        } else {
            selectedSegmentIDs.formUnion(ids)
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
        draftOverrides[segment.id] ?? segment.proposal.selection
    }

    func setSelection(_ selection: LabelReviewSelection, for segment: LabelReviewSegment) {
        guard !isSubmitting else { return }
        draftOverrides[segment.id] = selection
        if retryConflictReview == nil {
            retryDecisions = nil
            retryAvailableAt = nil
            canRetrySubmission = false
        }
    }

    func title(for selection: LabelReviewSelection?) -> String {
        selection?.title(in: labels) ?? "라벨 선택"
    }

    func canConfirm(_ segments: [LabelReviewSegment]) -> Bool {
        guard let review, loadState == .loaded, retryConflictReview == nil,
              !segments.isEmpty, !isSubmitting else { return false }
        return segments.allSatisfy { segment in
            guard review.pendingSegments.contains(where: {
                $0.id == segment.id && $0.version == segment.version
            }) else { return false }
            guard let selection = selection(for: segment) else { return false }
            return review.canSelect(selection)
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
        return unchanged ? "\(group.segments.count)건 확정" : "\(group.segments.count)건 선택대로 확정"
    }

    func confirmSelectedGroups() async {
        await confirm(selectedSegments)
    }

    func confirm(_ group: LabelReviewGroup) async {
        await confirm(group.segments)
    }

    func confirm(_ segment: LabelReviewSegment) async {
        await confirm([segment])
    }

    private func confirm(_ segments: [LabelReviewSegment]) async {
        guard let review, canConfirm(segments) else { return }
        let decisions = segments.compactMap { segment -> LabelConfirmationDecision? in
            guard let selection = selection(for: segment) else { return nil }
            return LabelConfirmationDecision(
                segmentID: segment.id,
                segmentVersion: segment.version,
                selection: selection.remote
            )
        }
        guard decisions.count == segments.count else { return }
        await submit(decisions, to: review)
    }

    func retrySubmission() async {
        guard let retryDecisions, let review, canRetrySubmission, !isSubmitting else { return }
        isSubmitting = true
        let id = requestID
        if let conflictReview = retryConflictReview {
            canRetrySubmission = false
            await refreshAfterConflict(decisions: retryDecisions, previous: conflictReview, requestID: id)
            if requestID == id { isSubmitting = false }
            return
        }
        if let retryAvailableAt {
            let delay = retryAvailableAt.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        guard requestID == id, canRetrySubmission else {
            if requestID == id { isSubmitting = false }
            return
        }
        await submit(retryDecisions, to: review)
    }

    private func submit(_ decisions: [LabelConfirmationDecision], to originalReview: LabelReviewState) async {
        let id = requestID
        isSubmitting = true
        submissionMessage = nil
        canRetrySubmission = false
        do {
            try await writer.confirmSegmentLabels(decisions)
            guard requestID == id else { return }
            let localDecisions = decisions.map { decision -> LabelReviewDecision in
                return LabelReviewDecision(
                    segmentID: decision.segmentID,
                    segmentVersion: decision.segmentVersion,
                    selection: LabelReviewSelection(remote: decision.selection)
                )
            }
            let confirmedReview = originalReview.applying(localDecisions)
            self.review = confirmedReview
            retryDecisions = nil
            retryAvailableAt = nil
            retryConflictReview = nil
            conflictedDrafts = []
            reconcileInteractionState()
            do {
                let snapshot = try await fetcher.fetchLabelReview(day: selectedDate)
                guard requestID == id else { return }
                self.review = confirmedReview.replacing(with: snapshot)
                reconcileInteractionState()
            } catch {
                guard requestID == id else { return }
                submissionMessage = "확정은 완료됐지만 최신 목록을 불러오지 못했습니다. 새로고침해 주세요."
            }
        } catch {
            guard requestID == id else { return }
            retryDecisions = decisions
            if let delay = (error as? LabelConfirmationRejection)?.retryAfter {
                retryAvailableAt = Date().addingTimeInterval(delay)
            } else {
                retryAvailableAt = nil
            }
            if let rejection = error as? LabelConfirmationRejection,
               [
                   .priorConfirmationConflict,
                   .segmentChanged,
                   .segmentNotFound,
                   .segmentNotLabelable,
                   .labelNotAvailable,
               ].contains(rejection.reason) {
                retryConflictReview = originalReview
                await refreshAfterConflict(decisions: decisions, previous: originalReview, requestID: id)
            } else {
                canRetrySubmission = true
                let item = (error as? LabelConfirmationRejection)?.failedIndex.map { "\($0 + 1)번째 기록: " } ?? ""
                submissionMessage = "\(item)확정하지 못했습니다. 선택은 유지됩니다. 다시 시도해 주세요."
            }
        }
        if requestID == id { isSubmitting = false }
    }

    private func refreshAfterConflict(
        decisions: [LabelConfirmationDecision],
        previous: LabelReviewState,
        requestID id: UUID
    ) async {
        do {
            let snapshot = try await fetcher.fetchLabelReview(day: selectedDate)
            guard requestID == id else { return }
            review = LabelReviewState(snapshot: snapshot)
            let pendingIDs = Set(snapshot.segments.map(\.id))
            var drafts: [LabelReviewConflictedDraft] = []
            for decision in decisions {
                guard !pendingIDs.contains(decision.segmentID),
                      let segment = previous.pendingSegments.first(where: { $0.id == decision.segmentID }) else {
                    continue
                }
                let confirmedSelection = try? await fetcher.confirmedSelection(segmentID: decision.segmentID)
                guard requestID == id else { return }
                drafts.append(LabelReviewConflictedDraft(
                    id: decision.segmentID,
                    title: segment.title,
                    confirmedSelection: confirmedSelection,
                    selection: LabelReviewSelection(remote: decision.selection)
                ))
            }
            conflictedDrafts = drafts
            retryDecisions = nil
            retryAvailableAt = nil
            retryConflictReview = nil
            reconcileInteractionState()
            submissionMessage = "라벨 또는 기록 상태가 변경되어 최신 목록을 불러왔습니다. 남은 선택을 확인해 주세요."
        } catch {
            guard requestID == id else { return }
            canRetrySubmission = true
            submissionMessage = "상태 변경 후 최신 목록을 불러오지 못했습니다. 다시 조회해 주세요."
        }
    }

    private func reconcileInteractionState() {
        let validGroupIDs = Set(groups.map(\.id))
        expandedGroupIDs.formIntersection(validGroupIDs)

        let validSegmentIDs = Set((review?.pendingSegments ?? []).map(\.id))
        selectedSegmentIDs.formIntersection(validSegmentIDs)
        draftOverrides = draftOverrides.filter { validSegmentIDs.contains($0.key) }
    }
}
