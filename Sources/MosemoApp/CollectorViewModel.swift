import AppKit
import CollectorCore
import Combine
import Foundation

enum AutomationPermissionStatus: String {
    case notRequested = "요청 전"
    case granted = "허용됨"
    case denied = "거부됨"
    case unavailable = "관찰 불가"
}

private enum ExpectedTransitionKind {
    case application
    case chrome
    case firefox

    func matches(_ transition: ActivityTransitionType) -> Bool {
        switch self {
        case .application:
            return transition == .appSwitch
        case .chrome:
            return [
                .chromeWindowSwitch,
                .chromeTabSwitch,
                .chromeURLChange,
                .chromeSurfaceChange,
                .chromeRestart,
            ].contains(transition)
        case .firefox:
            return [.firefoxWindowSwitch, .firefoxPageChange].contains(transition)
        }
    }
}

struct DiagnosticActivityEvent: Equatable {
    let safeEvent: SafeActivityEvent
    let browserContext: TransientBrowserContext?

    init(safeEvent: SafeActivityEvent, browserContext: TransientBrowserContext?) {
        self.safeEvent = safeEvent
        self.browserContext = safeEvent.protectedContext ? nil : browserContext
    }
}

@MainActor
final class CollectorViewModel: ObservableObject {
    @Published var intentionDraft = ""
    @Published private(set) var session = FocusSessionStateMachine()
    @Published private(set) var events: [DiagnosticActivityEvent] = []
    @Published private(set) var statistics = DetectionStatistics()
    @Published private(set) var currentAnchor: ReturnAnchorDescriptor?
    @Published private(set) var statusMessage = "집중 세션을 시작하지 않았습니다."
    @Published private(set) var automaticPauseReason: String?
    @Published private(set) var systemEventsAutomationPermission: AutomationPermissionStatus = .notRequested
    @Published private(set) var chromeAutomationPermission: AutomationPermissionStatus = .notRequested
    @Published private(set) var systemEventsPermissionRequestInFlight = false
    @Published private(set) var chromeAutomationPermissionRequestInFlight = false
    @Published private(set) var currentCPUPercent = 0.0
    @Published private(set) var averageCPUPercent = 0.0
    @Published private(set) var currentMemoryBytes: UInt64 = 0
    @Published private(set) var maximumMemoryBytes: UInt64 = 0

    private let chrome = ChromeAppleEventClient()
    private let systemEvents = SystemEventsClient()
    private let workspaceObserver = WorkspaceObserver()
    private let performanceSampler = PerformanceSampler()
    private let chromeQueue = DispatchQueue(label: "io.mosemo.collector.chrome-apple-events")
    private let firefoxQueue = DispatchQueue(label: "io.mosemo.collector.firefox-system-events")
    private lazy var anchorStore = ReturnAnchorStore(chrome: chrome)

    private var eventBuffer = RingBuffer<DiagnosticActivityEvent>(capacity: 600)
    private var chromeObservation: ChromeObservationIdentity?
    private var firefoxObservation: FirefoxObservationIdentity?
    private var chromePollInFlight = false
    private var firefoxPollInFlight = false
    private var chromeRestartPending = false
    private var lastChromePollCompletedAt: Date?
    private var lastFirefoxPollCompletedAt: Date?
    private var lastObservationFailure: String?
    private var pendingExpectedTransition: (kind: ExpectedTransitionKind, date: Date)?
    private var pollTimer: Timer?
    private var performanceTimer: Timer?
    private var cpuSampleSum = 0.0
    private var cpuSampleCount = 0
    private var automaticPauseReasons: Set<String> = []

    init() {
        configureCallbacks()
        workspaceObserver.start()
        startTimers()
    }

    var collectionAllowed: Bool {
        session.allowsCollection && automaticPauseReason == nil
    }

    var currentAnchorText: String {
        guard let anchor = currentAnchor else { return "없음" }
        if anchor.protectedContext { return "보호된 활동" }
        return "\(anchor.appBundleID) · \(anchor.kind.rawValue)"
    }

    func startSession() {
        do {
            try session.start(intention: intentionDraft)
        } catch {
            statusMessage = "집중 의도를 입력한 뒤 시작해 주세요."
            return
        }

        automaticPauseReason = nil
        automaticPauseReasons.removeAll()
        eventBuffer.removeAll()
        events = []
        statistics.reset()
        anchorStore.removeAll()
        currentAnchor = anchorStore.captureCurrent()
        chromeObservation = nil
        firefoxObservation = nil
        lastChromePollCompletedAt = nil
        lastFirefoxPollCompletedAt = nil
        lastObservationFailure = nil
        observeCurrentApplication(initial: true)
        statusMessage = currentAnchor == nil
            ? "집중을 시작했지만 최초 복귀 지점을 저장하지 못했습니다."
            : "집중 중입니다."
    }

    func beginIntendedRest() {
        do {
            try session.beginIntendedRest()
            stopActiveCollection()
            statusMessage = "의도된 휴식 중입니다. 활동 이벤트를 만들지 않습니다."
        } catch {
            statusMessage = "활성 집중 세션에서만 휴식을 시작할 수 있습니다."
        }
    }

    func resumeSession() {
        do {
            try session.resume()
            automaticPauseReason = nil
            automaticPauseReasons.removeAll()
            resumeActiveCollection()
            statusMessage = "집중 관찰을 재개했습니다."
        } catch {
            statusMessage = "의도된 휴식 중일 때만 재개할 수 있습니다."
        }
    }

    func endSession() {
        do {
            try session.end()
            stopActiveCollection()
            statusMessage = "집중 세션을 종료했습니다. 이후 활동 이벤트는 생성하지 않습니다."
        } catch {
            statusMessage = "종료할 집중 세션이 없습니다."
        }
    }

    func markCurrentAsReturnPoint() {
        guard collectionAllowed else {
            statusMessage = "집중 관찰 중에만 복귀 지점을 지정할 수 있습니다."
            return
        }
        guard let anchor = anchorStore.captureCurrent() else {
            statusMessage = "현재 화면을 복귀 지점으로 식별하지 못했습니다."
            return
        }
        currentAnchor = anchor
        statusMessage = anchor.protectedContext
            ? "보호된 활동은 상세 복귀 지점으로 저장하지 않았습니다."
            : "현재 작업 화면을 복귀 지점으로 지정했습니다."
    }

    func runReturnTest() {
        guard collectionAllowed else {
            statusMessage = "집중 관찰 중에만 복귀 테스트를 실행할 수 있습니다."
            return
        }
        guard let anchor = currentAnchor else {
            emitReturnWithoutAnchor()
            return
        }

        let attempt = ReturnAttemptTracker.begin(anchor: anchor, at: Date())
        append(SafeActivityEvent(
            eventType: .returnAttempt,
            appBundleID: anchor.appBundleID,
            registeredDomain: nil,
            surfaceType: .returnTarget,
            transitionType: .returnAttempt,
            observationState: .observed,
            inputOccurred: nil,
            occurredAt: attempt.attemptedAt,
            detectionLatencyMilliseconds: 0,
            protectedContext: anchor.protectedContext
        ))

        let outcome = anchorStore.activate(anchor)
        let result = ReturnAttemptTracker.finish(attempt: attempt, outcome: outcome, at: Date())
        let succeeded = result.outcome == .success
        append(SafeActivityEvent(
            eventType: .returnResult,
            appBundleID: anchor.appBundleID,
            registeredDomain: nil,
            surfaceType: .returnTarget,
            transitionType: succeeded ? .returnSuccess : .returnFailure,
            observationState: succeeded ? .observed : .unavailable,
            inputOccurred: nil,
            occurredAt: result.completedAt,
            detectionLatencyMilliseconds: milliseconds(from: attempt.attemptedAt, to: result.completedAt),
            protectedContext: anchor.protectedContext
        ))

        switch outcome {
        case .success:
            statusMessage = "복귀 시도와 활성화 요청이 성공했습니다."
        case let .failure(reason):
            statusMessage = "복귀 실패: \(reason.rawValue)"
        }
    }

    func markExpectedAppTransition() {
        markExpectedTransition(kind: .application)
    }

    func markExpectedChromeTransition() {
        markExpectedTransition(kind: .chrome)
    }

    func markExpectedFirefoxTransition() {
        markExpectedTransition(kind: .firefox)
    }

    private func markExpectedTransition(kind: ExpectedTransitionKind) {
        guard collectionAllowed else {
            statusMessage = "집중 관찰 중에만 전환 기준점을 기록할 수 있습니다."
            return
        }
        statistics.expectTransition()
        pendingExpectedTransition = (kind, Date())
        switch kind {
        case .application:
            statusMessage = "다음 앱 전환의 수동 기준점을 기록했습니다. 바로 전환하세요."
        case .chrome:
            statusMessage = "다음 Chrome 내부 전환의 수동 기준점을 기록했습니다. 바로 전환하세요."
        case .firefox:
            statusMessage = "다음 Firefox 화면 변화의 수동 기준점을 기록했습니다. 바로 전환하세요."
        }
    }

    func resetMeasurementStatistics() {
        statistics.reset()
        pendingExpectedTransition = nil
        statusMessage = "전환 측정 통계를 초기화했습니다."
    }

    func requestSystemEventsAutomationPermission() {
        guard !systemEventsPermissionRequestInFlight else { return }

        systemEventsPermissionRequestInFlight = true
        statusMessage = "System Events 자동화 권한을 요청하는 중입니다. macOS 확인 창에 응답해 주세요."
        let systemEvents = systemEvents
        firefoxQueue.async { [weak self, systemEvents] in
            guard let self else { return }
            let result = systemEvents.requestAutomationPermission()
            DispatchQueue.main.async {
                Task { @MainActor in self.handleSystemEventsAutomationPermissionResult(result) }
            }
        }
    }

    func requestChromeAutomationPermission() {
        guard !chromeAutomationPermissionRequestInFlight else { return }

        chromeAutomationPermissionRequestInFlight = true
        statusMessage = "Chrome 자동화 권한을 요청하는 중입니다. macOS 확인 창에 응답해 주세요."
        let chrome = chrome
        chromeQueue.async { [weak self, chrome] in
            guard let self else { return }
            let result = chrome.requestAutomationPermission()
            DispatchQueue.main.async {
                Task { @MainActor in self.handleChromeAutomationPermissionResult(result) }
            }
        }
    }

    func copySafeDiagnostics() {
        let text = diagnosticSnapshot()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "허용 필드만 포함한 진단 스냅샷을 클립보드에 복사했습니다."
    }

    func diagnosticSnapshot() -> String {
        let p95 = statistics.p95LatencyMilliseconds.map(String.init) ?? "n/a"
        let lines = events.map { safeLine($0.safeEvent) }
        return ([
            "sessionPhase=\(session.phase.rawValue)",
            "observationState=\(collectionAllowed ? "observed" : "paused")",
            "systemEventsAutomationPermission=\(systemEventsAutomationPermission.rawValue)",
            "chromeAutomationPermission=\(chromeAutomationPermission.rawValue)",
            "cpuCurrentPercent=\(String(format: "%.2f", currentCPUPercent))",
            "cpuAveragePercent=\(String(format: "%.2f", averageCPUPercent))",
            "memoryCurrentMB=\(String(format: "%.1f", Double(currentMemoryBytes) / 1_048_576))",
            "memoryMaximumMB=\(String(format: "%.1f", Double(maximumMemoryBytes) / 1_048_576))",
            "detectedTransitions=\(statistics.detectedTransitions)",
            "expectedTransitions=\(statistics.expectedTransitions)",
            "matchedExpectedTransitions=\(statistics.matchedExpectedTransitions)",
            "missedTransitions=\(statistics.missedTransitions)",
            "p95LatencyMs=\(p95)",
            "observationFailures=\(statistics.observationFailures)",
            "events:",
        ] + lines).joined(separator: "\n")
    }

    private func configureCallbacks() {
        workspaceObserver.onActivatedApplication = { [weak self] application in
            self?.handleActivatedApplication(application)
        }
        workspaceObserver.onChromeLifecycleChange = { [weak self] in
            guard let self, self.collectionAllowed else { return }
            self.chromeRestartPending = true
            self.chromeObservation = nil
            self.lastChromePollCompletedAt = nil
            self.pollChromeIfNeeded()
        }
        workspaceObserver.onAutomaticPause = { [weak self] reason in
            self?.handleAutomaticPause(reason: reason)
        }
        workspaceObserver.onAutomaticResume = { [weak self] reason in
            self?.handleAutomaticResume(reason: reason)
        }
    }

    private func handleSystemEventsAutomationPermissionResult(
        _ result: SystemEventsAutomationPermissionResult
    ) {
        systemEventsPermissionRequestInFlight = false

        switch result {
        case .granted:
            systemEventsAutomationPermission = .granted
            statusMessage = "System Events 자동화 권한이 허용되었습니다."
        case .denied:
            systemEventsAutomationPermission = .denied
            if systemEvents.openAutomationSettings() {
                statusMessage = "System Events 자동화 요청이 거부되었습니다. 열린 자동화 설정에서 Mosemo의 System Events 토글을 허용해 주세요."
            } else {
                statusMessage = "System Events 자동화 요청이 거부되었습니다. 시스템 설정의 개인정보 보호 및 보안 → 자동화에서 허용해 주세요."
            }
        case .firefoxNotRunning:
            systemEventsAutomationPermission = .unavailable
            statusMessage = "Firefox를 먼저 실행한 뒤 System Events 자동화 권한 요청을 다시 눌러 주세요."
        case .unavailable:
            systemEventsAutomationPermission = .unavailable
            statusMessage = "System Events 자동화 권한을 확인하지 못했습니다. Firefox가 실행 중인지 확인해 주세요."
        }
    }

    private func handleChromeAutomationPermissionResult(
        _ result: ChromeAutomationPermissionResult
    ) {
        chromeAutomationPermissionRequestInFlight = false

        switch result {
        case .granted:
            chromeAutomationPermission = .granted
            statusMessage = "Chrome 자동화 권한이 허용되었습니다."
        case .denied:
            chromeAutomationPermission = .denied
            if chrome.openAutomationSettings() {
                statusMessage = "Chrome 자동화 요청이 거부되었습니다. 열린 자동화 설정에서 Mosemo의 Google Chrome 토글을 허용해 주세요."
            } else {
                statusMessage = "Chrome 자동화 요청이 거부되었습니다. 시스템 설정의 개인정보 보호 및 보안 → 자동화에서 허용해 주세요."
            }
        case .chromeNotRunning:
            chromeAutomationPermission = .unavailable
            statusMessage = "Google Chrome을 먼저 실행한 뒤 Chrome 자동화 권한 요청을 다시 눌러 주세요."
        case .unavailable:
            chromeAutomationPermission = .unavailable
            statusMessage = "Chrome 자동화 권한을 확인하지 못했습니다. Chrome 정식 버전이 실행 중인지 확인해 주세요."
        }
    }

    private func startTimers() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.collectionAllowed {
                    self.pollChromeIfNeeded()
                    self.pollFirefoxIfNeeded()
                }
            }
        }
        performanceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.samplePerformance() }
        }
        samplePerformance()
    }

    private func observeCurrentApplication(initial: Bool) {
        guard collectionAllowed, let application = NSWorkspace.shared.frontmostApplication else { return }
        handleActivatedApplication(application, initial: initial)
    }

    private func handleActivatedApplication(_ application: NSRunningApplication, initial: Bool = false) {
        guard collectionAllowed, let bundleID = application.bundleIdentifier else { return }
        chromeObservation = nil
        firefoxObservation = nil
        lastChromePollCompletedAt = nil
        lastFirefoxPollCompletedAt = nil

        emitTransition(SafeActivityEvent(
            eventType: .activity,
            appBundleID: bundleID,
            registeredDomain: nil,
            surfaceType: .application,
            transitionType: initial ? .initialContext : .appSwitch,
            observationState: .observed,
            inputOccurred: nil,
            occurredAt: Date(),
            detectionLatencyMilliseconds: 0,
            protectedContext: false
        ), countsAsDetection: !initial)

        if bundleID == ChromeAppleEventClient.bundleID {
            pollChromeIfNeeded()
        } else if bundleID == SystemEventsClient.firefoxBundleID {
            pollFirefoxIfNeeded()
        }
    }

    private func pollChromeIfNeeded() {
        guard
            collectionAllowed,
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ChromeAppleEventClient.bundleID,
            !chromePollInFlight
        else { return }

        chromePollInFlight = true
        let chrome = chrome
        chromeQueue.async { [weak self, chrome] in
            guard let self else { return }
            let result = chrome.readFrontmostContext()
            DispatchQueue.main.async {
                Task { @MainActor in self.handleChromeResult(result, completedAt: Date()) }
            }
        }
    }

    private func handleChromeResult(
        _ result: Result<ChromeReadResult, ChromeReadFailure>,
        completedAt date: Date
    ) {
        chromePollInFlight = false
        guard collectionAllowed else { return }

        switch result {
        case let .success(.observation(observation)):
            chromeAutomationPermission = .granted
            lastObservationFailure = nil
            let identity = observation.identity
            var transition = ChromeTransitionDetector.transition(from: chromeObservation, to: identity)
            if chromeRestartPending {
                transition = .chromeRestart
                chromeRestartPending = false
            }
            let upperBoundLatency = lastChromePollCompletedAt.map { milliseconds(from: $0, to: date) } ?? 0
            lastChromePollCompletedAt = date
            chromeObservation = identity
            guard let transition else { return }

            let classification = identity.classification
            emitTransition(SafeActivityEvent(
                eventType: .activity,
                appBundleID: ChromeAppleEventClient.bundleID,
                registeredDomain: classification.registeredDomain,
                surfaceType: classification.surfaceType,
                transitionType: transition,
                observationState: classification.observationState,
                inputOccurred: nil,
                occurredAt: date,
                detectionLatencyMilliseconds: upperBoundLatency,
                protectedContext: classification.protectedContext
            ), browserContext: observation.diagnosticContext, countsAsDetection: transition != .initialContext)
        case .success(.notRunning):
            chromeAutomationPermission = .unavailable
            emitObservationUnavailable(reason: "chrome_not_running")
        case .success(.noWindow):
            emitObservationUnavailable(reason: "chrome_no_window")
        case let .failure(error):
            chromeAutomationPermission = error == .automationPermissionDenied ? .denied : .unavailable
            emitObservationUnavailable(
                reason: error == .automationPermissionDenied ? "automation_permission" : "chrome_apple_event"
            )
        }
    }

    private func pollFirefoxIfNeeded() {
        guard
            collectionAllowed,
            let application = NSWorkspace.shared.frontmostApplication,
            application.bundleIdentifier == SystemEventsClient.firefoxBundleID,
            !firefoxPollInFlight
        else { return }

        firefoxPollInFlight = true
        let systemEvents = systemEvents
        firefoxQueue.async { [weak self, systemEvents] in
            guard let self else { return }
            let result = systemEvents.readFirefoxFrontmostContext()
            DispatchQueue.main.async {
                Task { @MainActor in self.handleFirefoxResult(result, completedAt: Date()) }
            }
        }
    }

    private func handleFirefoxResult(
        _ result: Result<FirefoxObservation, SystemEventsReadFailure>,
        completedAt date: Date
    ) {
        firefoxPollInFlight = false
        guard collectionAllowed else { return }

        switch result {
        case let .success(observation):
            lastObservationFailure = nil
            let transition = FirefoxTransitionDetector.transition(
                from: firefoxObservation,
                to: observation.identity
            )
            let upperBoundLatency = lastFirefoxPollCompletedAt.map {
                milliseconds(from: $0, to: date)
            } ?? 0
            lastFirefoxPollCompletedAt = date
            firefoxObservation = observation.identity
            guard let transition else { return }

            let classification = observation.classification
            emitTransition(SafeActivityEvent(
                eventType: .activity,
                appBundleID: SystemEventsClient.firefoxBundleID,
                registeredDomain: classification.registeredDomain,
                surfaceType: classification.surfaceType,
                transitionType: transition,
                observationState: classification.observationState,
                inputOccurred: nil,
                occurredAt: date,
                detectionLatencyMilliseconds: upperBoundLatency,
                protectedContext: classification.protectedContext
            ), browserContext: observation.diagnosticContext, countsAsDetection: transition != .initialContext)
        case let .failure(error):
            let reason: String
            switch error {
            case .automationPermissionDenied:
                reason = "system_events_automation_permission"
            case .noFocusedWindow:
                reason = "firefox_no_focused_window"
            case .pageContextUnavailable:
                reason = "firefox_page_context"
            case .malformedResponse, .unavailable:
                reason = "system_events_firefox_context"
            }
            emitObservationUnavailable(reason: reason)
        }
    }

    private func emitObservationUnavailable(reason: String) {
        guard collectionAllowed, lastObservationFailure != reason else { return }
        lastObservationFailure = reason
        statistics.recordObservationFailure()
        append(SafeActivityEvent(
            eventType: .activity,
            appBundleID: nil,
            registeredDomain: nil,
            surfaceType: .unavailable,
            transitionType: .observationUnavailable,
            observationState: .unavailable,
            inputOccurred: nil,
            occurredAt: Date(),
            detectionLatencyMilliseconds: 0,
            protectedContext: false
        ))
        statusMessage = "관찰 불가: \(reason)"
    }

    private func emitTransition(
        _ event: SafeActivityEvent,
        browserContext: TransientBrowserContext? = nil,
        countsAsDetection: Bool
    ) {
        guard collectionAllowed else { return }
        guard countsAsDetection else {
            append(event, browserContext: browserContext)
            return
        }

        let matchesExpected = pendingExpectedTransition?.kind.matches(event.transitionType) == true
        let measuredLatency: Int
        if matchesExpected, let pendingExpectedTransition {
            measuredLatency = milliseconds(from: pendingExpectedTransition.date, to: event.occurredAt)
            self.pendingExpectedTransition = nil
        } else {
            measuredLatency = event.detectionLatencyMilliseconds
        }
        let measuredEvent = SafeActivityEvent(
            eventType: event.eventType,
            appBundleID: event.appBundleID,
            registeredDomain: event.registeredDomain,
            surfaceType: event.surfaceType,
            transitionType: event.transitionType,
            observationState: event.observationState,
            inputOccurred: event.inputOccurred,
            occurredAt: event.occurredAt,
            detectionLatencyMilliseconds: measuredLatency,
            protectedContext: event.protectedContext
        )
        statistics.recordDetection(
            latencyMilliseconds: measuredLatency,
            matchesExpectedTransition: matchesExpected
        )
        append(measuredEvent, browserContext: browserContext)
    }

    private func emitReturnWithoutAnchor() {
        let date = Date()
        append(SafeActivityEvent(
            eventType: .returnResult,
            appBundleID: nil,
            registeredDomain: nil,
            surfaceType: .returnTarget,
            transitionType: .returnFailure,
            observationState: .unavailable,
            inputOccurred: nil,
            occurredAt: date,
            detectionLatencyMilliseconds: 0,
            protectedContext: false
        ))
        statusMessage = "복귀 실패: noAnchor"
    }

    private func append(
        _ event: SafeActivityEvent,
        browserContext: TransientBrowserContext? = nil
    ) {
        guard session.allowsCollection else { return }
        eventBuffer.append(DiagnosticActivityEvent(
            safeEvent: event,
            browserContext: browserContext
        ))
        events = eventBuffer.elements
    }

    private func handleAutomaticPause(reason: String) {
        guard session.allowsCollection else { return }
        let wasActive = automaticPauseReasons.isEmpty
        automaticPauseReasons.insert(reason)
        automaticPauseReason = automaticPauseReasons.sorted().joined(separator: ",")
        if wasActive { stopActiveCollection() }
        statusMessage = "필수 관찰 조건 상실로 자동 일시정지했습니다: \(reason)"
    }

    private func handleAutomaticResume(reason: String) {
        guard session.allowsCollection, automaticPauseReasons.contains(reason) else { return }
        automaticPauseReasons.remove(reason)
        automaticPauseReason = automaticPauseReasons.isEmpty
            ? nil
            : automaticPauseReasons.sorted().joined(separator: ",")
        guard automaticPauseReasons.isEmpty else { return }
        resumeActiveCollection()
        statusMessage = "필수 관찰 조건이 돌아와 관찰을 재개했습니다."
    }

    private func stopActiveCollection() {
        chromeObservation = nil
        firefoxObservation = nil
        lastChromePollCompletedAt = nil
        lastFirefoxPollCompletedAt = nil
        pendingExpectedTransition = nil
    }

    private func resumeActiveCollection() {
        observeCurrentApplication(initial: true)
    }

    private func samplePerformance() {
        guard let sample = performanceSampler.sample() else { return }
        currentCPUPercent = sample.cpuPercent
        currentMemoryBytes = sample.residentMemoryBytes
        maximumMemoryBytes = max(maximumMemoryBytes, sample.residentMemoryBytes)
        if cpuSampleCount > 0 || sample.cpuPercent > 0 {
            cpuSampleSum += sample.cpuPercent
            cpuSampleCount += 1
            averageCPUPercent = cpuSampleSum / Double(cpuSampleCount)
        }
    }

    private func safeLine(_ event: SafeActivityEvent) -> String {
        let timestamp = ISO8601DateFormatter().string(from: event.occurredAt)
        if event.protectedContext {
            return "\(timestamp) observationState=protected"
        }
        return [
            timestamp,
            "eventType=\(event.eventType.rawValue)",
            "appBundleID=\(event.appBundleID ?? "-")",
            "registeredDomain=\(event.registeredDomain ?? "-")",
            "surfaceType=\(event.surfaceType.rawValue)",
            "transitionType=\(event.transitionType.rawValue)",
            "observationState=\(event.observationState.rawValue)",
            "inputOccurred=\(event.inputOccurred.map(String.init) ?? "-")",
            "latencyMs=\(event.detectionLatencyMilliseconds)",
        ].joined(separator: " ")
    }

    private func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }
}
