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

    @Published private(set) var phase: Phase = .ready {
        didSet { if isAttached { activitySessionChanged(phase == .running ? sessionID : nil) } }
    }
    @Published private(set) var isSaving = false
    @Published private(set) var persistenceError: String?
    @Published private(set) var history: [FocusSessionRecord] = []
    @Published private(set) var historyError: String?
    @Published var historyDate: Date = .now
    @Published private(set) var isLoadingHistory = false
    var displayTimeZone: TimeZone { timeZone }
    private var isAttached = true
    private var lifecycleGeneration = 0
    private var loadedHistoryDate: TimelineDate?
    private var historyRequestID: UUID?
    private var labelNames: [UUID: String] = [:]
    private let service: (any FocusSessionServing)?
    private let deviceID: UUID?
    private let timeZone: TimeZone
    private let wallClock: () -> Date
    private let activitySessionChanged: @MainActor (UUID?) -> Void
    private var sessionID: UUID?
    private var endedDate: Date?
    private var pendingStart: (id: UUID, startedAt: Date, target: Int)?
    private var pendingCompletion: (id: UUID, endedAt: Date, seconds: Int, labelID: UUID, description: String)?
    var persistsSessions: Bool { service != nil }
    var canEditInputs: Bool { !isSaving && pendingCompletion == nil && pendingStart == nil }

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
        service: (any FocusSessionServing)? = nil,
        deviceID: UUID? = nil,
        timeZone: TimeZone = .current,
        wallClock: @escaping () -> Date = { .now },
        activitySessionChanged: @escaping @MainActor (UUID?) -> Void = { _ in },
        authenticationFailed: @escaping @MainActor () -> Void = {}
    ) {
        self.service = service
        self.deviceID = deviceID
        self.timeZone = timeZone
        self.wallClock = wallClock
        self.activitySessionChanged = activitySessionChanged
        self.fetchLabels = fetchLabels
        self.clock = clock
        self.authenticationFailed = authenticationFailed
    }

    var canStart: Bool { phase == .ready && !isSaving && Self.parseTime(timeInput) != nil }
    var canComplete: Bool {
        phase == .review && !isSaving && (pendingCompletion != nil || labels.contains { $0.id == selectedLabelID })
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
            labelNames = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.displayName) })
            labels = entries.filter { $0.archivedAt == nil }
            if let selectedLabelID, !labels.contains(where: { $0.id == selectedLabelID }) {
                self.selectedLabelID = nil
            }
            labelError = nil
        } catch {
            if error is CancellationError { return }
            labelError = "라벨을 불러오지 못했습니다. 다시 시도해주세요."
            if isAttached, case MosemoAPIError.authenticationRequired = error { authenticationFailed() }
        }
    }

    func labelName(for id: UUID?) -> String { id.flatMap { labelNames[$0] } ?? "알 수 없는 라벨" }

    func loadHistory() async {
        guard let service else { return }
        let requestID = UUID()
        historyRequestID = requestID
        let requested = TimelineDate(historyDate, timeZone: timeZone)
        if loadedHistoryDate != requested { history = [] }
        isLoadingHistory = true
        defer { if historyRequestID == requestID { isLoadingHistory = false } }
        do {
            let records = try await service.listFocusSessions(date: requested)
            if historyRequestID == requestID && TimelineDate(historyDate, timeZone: timeZone) == requested { history = records; loadedHistoryDate = requested; historyError = nil }
        } catch {
            if error is CancellationError { return }
            guard historyRequestID == requestID else { return }
            historyError = "기록을 불러오지 못했습니다. 다시 시도해주세요."
            handleAuthentication(error)
        }
    }

    func startPersisted() async {
        guard canStart else { return }
        guard let service else { start(); return }
        guard let deviceID else { persistenceError = "기기 등록 후 시작할 수 있습니다."; return }
        if pendingStart == nil { pendingStart = (UUID(), wallClock(), Int(Self.parseTime(timeInput)!)) }
        guard let request = pendingStart else { return }
        let expectedGeneration = lifecycleGeneration
        isSaving = true
        defer { isSaving = false }
        do {
            let record = try await service.startFocusSession(id: request.id, deviceID: deviceID, startedAt: request.startedAt, targetSeconds: request.target)
            guard lifecycleGeneration == expectedGeneration, isAttached else { return }
            guard record.id == request.id else { throw MosemoAPIError.unexpectedResponse(statusCode: 201) }
            sessionID = record.id
            timeInput = Self.format(TimeInterval(request.target))
            pendingStart = nil
            persistenceError = nil
            start()
        } catch {
            guard lifecycleGeneration == expectedGeneration, isAttached else { return }
            persistenceError = "세션을 시작하지 못했습니다. 시작을 눌러 다시 시도해주세요."
            handleAuthentication(error)
        }
    }

    func completePersisted() async {
        guard canComplete else { return }
        guard let service else { complete(); return }
        if pendingCompletion == nil, let sessionID, let endedDate, let selectedLabelID {
            pendingCompletion = (sessionID, endedDate, Int(workSeconds.rounded(.down)), selectedLabelID, description)
        }
        guard let request = pendingCompletion else { return }
        let expectedGeneration = lifecycleGeneration
        isSaving = true
        defer { isSaving = false }
        do {
            let record = try await service.completeFocusSession(id: request.id, endedAt: request.endedAt, workSeconds: request.seconds, labelID: request.labelID, description: request.description)
            guard lifecycleGeneration == expectedGeneration, isAttached else { return }
            guard record.id == request.id, record.endedAt != nil, record.labelID == request.labelID else { throw MosemoAPIError.unexpectedResponse(statusCode: 200) }
            historyDate = record.startedAt
            history.removeAll { $0.id == record.id }
            history.insert(record, at: 0)
            pendingCompletion = nil
            persistenceError = nil
            let label = labels.first { $0.id == request.labelID } ?? LabelCatalogEntry(id: request.labelID, displayName: labelName(for: request.labelID), archivedAt: .now)
            prepareNextSession(label: label, seconds: TimeInterval(record.workSeconds ?? request.seconds), description: request.description)
            await loadHistory()
        } catch {
            guard lifecycleGeneration == expectedGeneration, isAttached else { return }
            // Retain the exact body for a safe retry after an ambiguous network failure.
            persistenceError = "기록을 저장하지 못했습니다. 완료를 눌러 같은 기록으로 다시 시도해주세요."
            if let apiError = error as? MosemoAPIError, [.validationFailed, .focusSessionNotFound].contains(apiError) { pendingCompletion = nil }
            handleAuthentication(error)
        }
    }

    func detachActivitySession() {
        if phase == .running { pause() }
        isAttached = false
        lifecycleGeneration += 1
        activitySessionChanged(nil)
    }

    func attachActivitySession() {
        isAttached = true
        activitySessionChanged(phase == .running ? sessionID : nil)
    }

    private func handleAuthentication(_ error: Error) {
        if isAttached, case MosemoAPIError.authenticationRequired = error { authenticationFailed() }
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
            endedDate = wallClock()
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
        endedDate = endedDate ?? wallClock()
        phase = .review
    }

    func reset() {
        guard phase == .ready, !isSaving else { return }
        clearTimer()
        persistenceError = nil
        selectedLabelID = nil
        description = ""
        lastCompleted = nil
    }

    func complete() {
        guard phase == .review,
              let label = labels.first(where: { $0.id == selectedLabelID }) else { return }
        prepareNextSession(label: label, seconds: workSeconds, description: description)
    }

    private func prepareNextSession(label: LabelCatalogEntry, seconds: TimeInterval, description: String) {
        lastCompleted = CompletedSession(seconds: seconds, label: label, description: description)
        clearTimer()
        self.description = ""
        selectedLabelID = labels.contains { $0.id == label.id } ? label.id : nil
        phase = .ready
    }

    private func clearTimer() {
        timeInput = "00:00:00"
        targetSeconds = 0
        accumulatedSeconds = 0
        workSeconds = 0
        startedAt = nil
        sessionID = nil
        endedDate = nil
        pendingStart = nil
        pendingCompletion = nil
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
