import Combine
import Foundation
import MosemoAPI

@MainActor
final class FocusSessionViewModel: ObservableObject {
    enum Phase { case ready, running, paused, review }

    struct CompletedSession {
        let seconds: TimeInterval
        let label: LabelCatalogEntry
        let description: String
    }

    @Published private(set) var phase: Phase = .ready
    @Published var timeInput = "00:00:00"
    @Published var selectedLabelID: UUID?
    @Published var description = ""
    @Published private(set) var labels: [LabelCatalogEntry] = []
    @Published private(set) var isLoadingLabels = false
    @Published private(set) var labelError: String?
    @Published private(set) var workSeconds: TimeInterval = 0
    @Published private(set) var targetSeconds: TimeInterval = 0
    @Published private(set) var lastCompleted: CompletedSession?

    private var accumulatedSeconds: TimeInterval = 0
    private var startedAt: TimeInterval?
    private let clock: () -> TimeInterval
    private let fetchLabels: @Sendable () async throws -> [LabelCatalogEntry]
    private let authenticationFailed: @MainActor () -> Void

    init(
        fetchLabels: @escaping @Sendable () async throws -> [LabelCatalogEntry],
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        authenticationFailed: @escaping @MainActor () -> Void = {}
    ) {
        self.fetchLabels = fetchLabels
        self.clock = clock
        self.authenticationFailed = authenticationFailed
    }

    var canStart: Bool { phase == .ready && Self.parseTime(timeInput) != nil }
    var canComplete: Bool {
        phase == .review && labels.contains { $0.id == selectedLabelID }
    }
    var displaySeconds: TimeInterval {
        if phase == .ready || phase == .review { return 0 }
        return targetSeconds > 0 ? max(0, targetSeconds - workSeconds) : workSeconds
    }

    func loadLabels() async {
        guard !isLoadingLabels else { return }
        isLoadingLabels = true
        defer { isLoadingLabels = false }
        do {
            let entries = try await fetchLabels()
            labels = entries.filter { $0.archivedAt == nil }
            if let selectedLabelID, !labels.contains(where: { $0.id == selectedLabelID }) {
                self.selectedLabelID = nil
            }
            labelError = nil
        } catch {
            if error is CancellationError { return }
            labelError = "라벨을 불러오지 못했습니다. 다시 시도해주세요."
            if case MosemoAPIError.authenticationRequired = error { authenticationFailed() }
        }
    }

    func start() {
        guard phase == .ready, let seconds = Self.parseTime(timeInput) else { return }
        targetSeconds = seconds
        timeInput = Self.format(seconds)
        accumulatedSeconds = 0
        workSeconds = 0
        startedAt = clock()
        phase = .running
        lastCompleted = nil
    }

    func tick() {
        guard phase == .running, let startedAt else { return }
        let seconds = accumulatedSeconds + max(0, clock() - startedAt)
        workSeconds = targetSeconds > 0 ? min(seconds, targetSeconds) : seconds
        if targetSeconds > 0 && seconds >= targetSeconds {
            accumulatedSeconds = workSeconds
            self.startedAt = nil
            phase = .review
        }
    }

    func pause() {
        guard phase == .running else { return }
        tick()
        guard phase == .running else { return }
        accumulatedSeconds = workSeconds
        startedAt = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        startedAt = clock()
        phase = .running
    }

    func end() {
        guard phase == .running || phase == .paused else { return }
        tick()
        accumulatedSeconds = workSeconds
        startedAt = nil
        phase = .review
    }

    func reset() {
        guard phase == .ready else { return }
        clearTimer()
        selectedLabelID = nil
        description = ""
        lastCompleted = nil
    }

    func complete() {
        guard phase == .review,
              let label = labels.first(where: { $0.id == selectedLabelID }) else { return }
        lastCompleted = CompletedSession(seconds: workSeconds, label: label, description: description)
        clearTimer()
        description = ""
        phase = .ready
    }

    private func clearTimer() {
        timeInput = "00:00:00"
        targetSeconds = 0
        accumulatedSeconds = 0
        workSeconds = 0
        startedAt = nil
    }

    static func parseTime(_ text: String) -> TimeInterval? {
        let components = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              (1...2).contains(components[0].count),
              components[1].count == 2, components[2].count == 2,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "0123456789".contains($0) } }),
              let hours = Int(components[0]), let minutes = Int(components[1]), let seconds = Int(components[2]),
              minutes < 60, seconds < 60 else { return nil }
        return TimeInterval(hours * 3600 + minutes * 60 + seconds)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
