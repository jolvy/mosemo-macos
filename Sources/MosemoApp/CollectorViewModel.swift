import AppKit
import CollectorCore
import Combine
import Foundation
import MosemoAPI

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
}

@MainActor
struct CollectorObservationEnvironment {
    var now: () -> Date = { Date() }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var frontmostBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var readChrome: (() async -> Result<ChromeReadResult, ChromeReadFailure>)? = nil
    var readFirefox: (() async -> Result<FirefoxObservation, SystemEventsReadFailure>)? = nil
    var readApplicationWindow: ((String) async -> ApplicationWindowReadResult)? = nil
    var captureReturnAnchor: (() -> ReturnAnchorDescriptor?)? = nil
    var initialTrackingEnabled: Bool? = nil
    var persistTrackingPreference = true
}

@MainActor
final class CollectorViewModel: ObservableObject {
    @Published private(set) var isActivityTrackingEnabled: Bool
    @Published private(set) var events: [DiagnosticActivityEvent] = []
    @Published private(set) var statistics = DetectionStatistics()
    @Published private(set) var currentAnchor: ReturnAnchorDescriptor?
    @Published private(set) var statusMessage = "활동 추적 상태를 확인하는 중입니다."
    @Published private(set) var automaticPauseReason: String?
    @Published private(set) var accessibilityPermission: AutomationPermissionStatus = .notRequested
    @Published private(set) var chromeAutomationPermission: AutomationPermissionStatus = .notRequested
    @Published private(set) var chromeAutomationPermissionRequestInFlight = false
    @Published private(set) var currentCPUPercent = 0.0
    @Published private(set) var averageCPUPercent = 0.0
    @Published private(set) var currentMemoryBytes: UInt64 = 0
    @Published private(set) var maximumMemoryBytes: UInt64 = 0
    @Published private(set) var pendingActivityCount = 0
    @Published private(set) var synchronizationStatus = "동기화 준비 안 됨"

    private let chrome = ChromeAppleEventClient()
    private let systemEvents = SystemEventsClient()
    private let workspaceObserver: WorkspaceObserver
    private let environment: CollectorObservationEnvironment
    private let performanceSampler = PerformanceSampler()
    private let chromeQueue = DispatchQueue(label: "io.mosemo.collector.chrome-apple-events")
    private let firefoxQueue = DispatchQueue(label: "io.mosemo.collector.firefox-system-events")
    private let applicationWindowQueue = DispatchQueue(label: "io.mosemo.collector.application-window-context")
    private let applicationWindowClient = ApplicationWindowContextClient()
    private lazy var anchorStore = ReturnAnchorStore(chrome: chrome)
    let acceptedActivityUploads = PassthroughSubject<UUID, Never>()
    private var synchronization: OfflineActivityCoordinator?

    private var eventBuffer = RingBuffer<DiagnosticActivityEvent>(capacity: 600)
    private var chromeObservation: ChromeObservationIdentity?
    private var firefoxObservation: FirefoxObservationIdentity?
    private var chromePollInFlight = false
    private var firefoxPollInFlight = false
    private var applicationWindowPollInFlight = false
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
    private var activityStorageUnavailable = false
    private var activeBundleID: String?
    private var lastFullObservationUptime: TimeInterval?
    private var browserApplicationTransition: ActivityTransitionType?
    private var observationGeneration = 0

    private static let activityTrackingPreferenceKey = "io.mosemo.activityTrackingEnabled"
    private static let activityStoragePauseReason = "저장소 복구 필요"

    init(environment: CollectorObservationEnvironment? = nil,
         workspaceObserver: WorkspaceObserver = WorkspaceObserver(),
         startAutomatically: Bool = true) {
        let environment = environment ?? CollectorObservationEnvironment()
        self.environment = environment
        self.workspaceObserver = workspaceObserver
        accessibilityPermission = AXIsProcessTrusted() ? .granted : .denied
        let savedTrackingPreference = UserDefaults.standard.object(forKey: Self.activityTrackingPreferenceKey) as? Bool
        isActivityTrackingEnabled = environment.initialTrackingEnabled ?? savedTrackingPreference ?? true
        configureCallbacks()
        if startAutomatically {
            workspaceObserver.start()
            startTimers()
        }
        if isActivityTrackingEnabled {
            statusMessage = savedTrackingPreference == nil
                ? "앱 시작과 함께 활동 추적을 시작했습니다."
                : "활동 추적 설정을 복원했습니다."
            resumeActiveCollection()
        } else {
            statusMessage = "활동 추적 설정이 꺼져 있습니다."
        }
    }

    var collectionAllowed: Bool {
        isActivityTrackingEnabled && automaticPauseReason == nil
    }

    var activityTrackingStatusText: String {
        guard isActivityTrackingEnabled else { return "활동 추적 꺼짐" }
        if let automaticPauseReason {
            return "활동 추적 일시정지 · \(automaticPauseReason)"
        }
        return "활동 추적 중"
    }

    func setActivityTrackingEnabled(_ enabled: Bool) {
        guard isActivityTrackingEnabled != enabled else { return }
        isActivityTrackingEnabled = enabled
        if environment.persistTrackingPreference {
            UserDefaults.standard.set(enabled, forKey: Self.activityTrackingPreferenceKey)
        }
        guard !activityStorageUnavailable else {
            stopActiveCollection()
            publishActivityStorageFailureStatus()
            return
        }

        if enabled {
            lastObservationFailure = nil
            stopActiveCollection()
            if automaticPauseReason == nil {
                synchronization?.recordCollectionState(.active, reason: "user_enabled")
                resumeActiveCollection()
                statusMessage = "활동 추적을 시작했습니다."
            } else {
                synchronization?.recordCollectionState(.suspended, reason: automaticPauseReason ?? "automatic_pause")
                statusMessage = "활동 추적을 켰습니다. 자동 일시정지가 해제되면 수집을 재개합니다."
            }
        } else {
            synchronization?.recordCollectionState(.suspended, reason: "user_disabled")
            stopActiveCollection()
            statusMessage = "활동 추적을 중지했습니다."
        }
    }

    func configureSynchronization(client: any MosemoAPIClient,
                                  deviceStateStore: any DeviceRegistrationStateStoring,
                                  queue: EncryptedActivityQueue) {
        synchronization = OfflineActivityCoordinator(queue: queue, client: client,
            deviceStateStore: deviceStateStore,
            onStorageFailure: { [weak self] in
                self?.handleActivityStorageFailure()
            }, onActivityAccepted: { [weak self] accountID in
                self?.acceptedActivityUploads.send(accountID)
            }) { [weak self] count, status in
                self?.pendingActivityCount = count
                if self?.activityStorageUnavailable == false {
                    self?.synchronizationStatus = status
                }
            }
    }

    func synchronizationAccountChanged(_ account: Account?) async {
        await synchronization?.activate(account)
        guard account != nil else { return }
        if !activityStorageUnavailable {
            synchronization?.recordCollectionState(
                collectionAllowed ? .active : .suspended,
                reason: collectionAllowed ? "application_started" : (automaticPauseReason ?? "user_disabled")
            )
        }
        if collectionAllowed { resumeActiveCollection() }
    }

    func synchronizationUnavailable() {
        handleActivityStorageFailure()
    }

    var currentAnchorText: String {
        guard let anchor = currentAnchor else { return "없음" }
        if anchor.protectedContext { return "보호된 활동" }
        return "\(anchor.appBundleID) · \(anchor.kind.rawValue)"
    }

    func markCurrentAsReturnPoint() {
        guard collectionAllowed else {
            statusMessage = "활동 추적 중에만 복귀 지점을 지정할 수 있습니다."
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
            statusMessage = "활동 추적 중에만 복귀 테스트를 실행할 수 있습니다."
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
            statusMessage = "활동 추적 중에만 전환 기준점을 기록할 수 있습니다."
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

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        accessibilityPermission = isTrusted ? .granted : .denied
        if !isTrusted,
           let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(settingsURL)
        }
        statusMessage = isTrusted
            ? "앱 접근성 권한이 허용되었습니다."
            : "시스템 설정의 개인정보 보호 및 보안 → 손쉬운 사용에서 Mosemo를 허용해 주세요."
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
            "activityTrackingEnabled=\(isActivityTrackingEnabled)",
            "observationState=\(collectionAllowed ? "observed" : "paused")",
            "accessibilityPermission=\(accessibilityPermission.rawValue)",
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
            self.observationGeneration += 1
            self.lastFullObservationUptime = nil
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
                self.pollCurrentActivity()
            }
        }
        performanceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.samplePerformance() }
        }
        samplePerformance()
    }

    private func observeCurrentApplication(initial: Bool) {
        guard collectionAllowed, let bundleID = environment.frontmostBundleID() else { return }
        handleActivatedApplication(bundleID: bundleID, initial: initial)
    }

    private func handleActivatedApplication(_ application: NSRunningApplication, initial: Bool = false) {
        guard collectionAllowed, let bundleID = application.bundleIdentifier else { return }
        handleActivatedApplication(bundleID: bundleID, initial: initial)
    }

    private func handleActivatedApplication(bundleID: String, initial: Bool) {
        observationGeneration += 1
        lastFullObservationUptime = nil
        lastObservationFailure = nil
        activeBundleID = bundleID
        chromeObservation = nil
        firefoxObservation = nil
        lastChromePollCompletedAt = nil
        lastFirefoxPollCompletedAt = nil

        let transition: ActivityTransitionType = initial ? .initialContext : .appSwitch
        if bundleID == ChromeAppleEventClient.bundleID {
            browserApplicationTransition = transition
            pollChromeIfNeeded()
        } else if bundleID == SystemEventsClient.firefoxBundleID {
            browserApplicationTransition = transition
            pollFirefoxIfNeeded()
        } else {
            browserApplicationTransition = nil
            pollApplicationWindow(bundleID: bundleID, transition: transition)
        }
    }

    private func emitApplicationObservation(
        bundleID: String,
        transition: ActivityTransitionType,
        windowTitle: String?,
        windowCaptureFailure: String? = nil
    ) {
        emitTransition(SafeActivityEvent(
            eventType: .activity,
            appBundleID: bundleID,
            registeredDomain: nil,
            surfaceType: .application,
            transitionType: transition,
            observationState: .observed,
            inputOccurred: nil,
            occurredAt: environment.now(),
            detectionLatencyMilliseconds: 0,
            protectedContext: false
        ), windowTitle: windowTitle, windowCaptureFailure: windowCaptureFailure,
           countsAsDetection: transition == .appSwitch)
    }

    private func pollApplicationWindow(bundleID: String, transition: ActivityTransitionType) {
        guard collectionAllowed,
              environment.frontmostBundleID() == bundleID,
              !applicationWindowPollInFlight else { return }

        applicationWindowPollInFlight = true
        let generation = observationGeneration
        Task { [weak self] in
            guard let self else { return }
            let result = await self.readApplicationWindow(bundleID: bundleID)
            self.applicationWindowPollInFlight = false
            guard self.collectionAllowed,
                  self.observationGeneration == generation,
                  self.environment.frontmostBundleID() == bundleID else {
                self.pollCurrentActivity()
                return
            }

            switch result {
            case let .captured(context):
                self.accessibilityPermission = .granted
                self.emitApplicationObservation(
                    bundleID: bundleID,
                    transition: transition,
                    windowTitle: context.title
                )
            case let .unavailable(reason):
                if reason == "accessibility_permission" {
                    self.accessibilityPermission = .denied
                }
                self.emitApplicationObservation(
                    bundleID: bundleID,
                    transition: transition,
                    windowTitle: nil,
                    windowCaptureFailure: reason
                )
            }
        }
    }

    private func readApplicationWindow(bundleID: String) async -> ApplicationWindowReadResult {
        if let readApplicationWindow = environment.readApplicationWindow {
            return await readApplicationWindow(bundleID)
        }
        let client = applicationWindowClient
        return await withCheckedContinuation { continuation in
            applicationWindowQueue.async {
                continuation.resume(returning: client.read(bundleID: bundleID))
            }
        }
    }

    private func pollChromeIfNeeded() {
        guard
            collectionAllowed,
            environment.frontmostBundleID() == ChromeAppleEventClient.bundleID,
            !chromePollInFlight
        else { return }

        chromePollInFlight = true
        let generation = observationGeneration
        Task { [weak self] in
            guard let self else { return }
            let result = await self.readChromeContext()
            self.chromePollInFlight = false
            guard self.collectionAllowed,
                  self.observationGeneration == generation,
                  self.environment.frontmostBundleID() == ChromeAppleEventClient.bundleID else {
                self.pollCurrentActivity()
                return
            }
            self.handleChromeResult(result, completedAt: self.environment.now())
        }
    }

    private func readChromeContext() async -> Result<ChromeReadResult, ChromeReadFailure> {
        if let readChrome = environment.readChrome { return await readChrome() }
        let chrome = chrome
        return await withCheckedContinuation { continuation in
            chromeQueue.async {
                continuation.resume(returning: chrome.readFrontmostContext())
            }
        }
    }

    private func handleChromeResult(
        _ result: Result<ChromeReadResult, ChromeReadFailure>,
        completedAt date: Date
    ) {
        guard collectionAllowed else { return }

        switch result {
        case let .success(.observation(observation)):
            chromeAutomationPermission = .granted
            lastObservationFailure = nil
            let identity = observation.identity
            var transition = browserApplicationTransition ?? ChromeTransitionDetector.transition(from: chromeObservation, to: identity)
            if chromeRestartPending {
                transition = .chromeRestart
                chromeRestartPending = false
            }
            let upperBoundLatency = lastChromePollCompletedAt.map { milliseconds(from: $0, to: date) } ?? 0
            lastChromePollCompletedAt = date
            chromeObservation = identity
            if transition == nil, periodicObservationDue { transition = .periodicObservation }
            guard let transition else { return }
            browserApplicationTransition = nil

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
            ), browserContext: observation.diagnosticContext,
               windowTitle: observation.diagnosticContext?.windowTitle ?? observation.diagnosticContext?.title,
               countsAsDetection: transition != .initialContext && transition != .periodicObservation)
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
            environment.frontmostBundleID() == SystemEventsClient.firefoxBundleID,
            !firefoxPollInFlight
        else { return }

        firefoxPollInFlight = true
        let generation = observationGeneration
        Task { [weak self] in
            guard let self else { return }
            let result = await self.readFirefoxContext()
            self.firefoxPollInFlight = false
            guard self.collectionAllowed,
                  self.observationGeneration == generation,
                  self.environment.frontmostBundleID() == SystemEventsClient.firefoxBundleID else {
                self.pollCurrentActivity()
                return
            }
            self.handleFirefoxResult(result, completedAt: self.environment.now())
        }
    }

    private func readFirefoxContext() async -> Result<FirefoxObservation, SystemEventsReadFailure> {
        if let readFirefox = environment.readFirefox { return await readFirefox() }
        let systemEvents = systemEvents
        return await withCheckedContinuation { continuation in
            firefoxQueue.async {
                continuation.resume(returning: systemEvents.readFirefoxFrontmostContext())
            }
        }
    }

    private func handleFirefoxResult(
        _ result: Result<FirefoxObservation, SystemEventsReadFailure>,
        completedAt date: Date
    ) {
        guard collectionAllowed else { return }

        switch result {
        case let .success(observation):
            accessibilityPermission = .granted
            lastObservationFailure = nil
            var transition = browserApplicationTransition ?? FirefoxTransitionDetector.transition(
                from: firefoxObservation,
                to: observation.identity
            )
            let upperBoundLatency = lastFirefoxPollCompletedAt.map {
                milliseconds(from: $0, to: date)
            } ?? 0
            lastFirefoxPollCompletedAt = date
            firefoxObservation = observation.identity
            if transition == nil, periodicObservationDue { transition = .periodicObservation }
            guard let transition else { return }
            browserApplicationTransition = nil

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
            ), browserContext: observation.diagnosticContext,
               windowTitle: observation.diagnosticContext?.windowTitle ?? observation.diagnosticContext?.title,
               countsAsDetection: transition != .initialContext && transition != .periodicObservation)
        case let .failure(error):
            let reason: String
            switch error {
            case .accessibilityPermissionDenied:
                accessibilityPermission = .denied
                reason = "accessibility_permission"
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
        guard collectionAllowed else { return }
        chromeObservation = nil
        firefoxObservation = nil
        lastChromePollCompletedAt = nil
        lastFirefoxPollCompletedAt = nil
        lastFullObservationUptime = nil
        guard lastObservationFailure != reason else { return }
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
            occurredAt: environment.now(),
            detectionLatencyMilliseconds: 0,
            protectedContext: false
        ))
        statusMessage = "관찰 불가: \(reason)"
    }

    private func emitTransition(
        _ event: SafeActivityEvent,
        browserContext: TransientBrowserContext? = nil,
        windowTitle: String? = nil,
        windowCaptureFailure: String? = nil,
        countsAsDetection: Bool
    ) {
        guard collectionAllowed else { return }
        lastFullObservationUptime = environment.uptime()
        guard countsAsDetection else {
            append(event, browserContext: browserContext, windowTitle: windowTitle, windowCaptureFailure: windowCaptureFailure)
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
        append(measuredEvent, browserContext: browserContext, windowTitle: windowTitle, windowCaptureFailure: windowCaptureFailure)
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
        browserContext: TransientBrowserContext? = nil,
        windowTitle: String? = nil,
        windowCaptureFailure: String? = nil
    ) {
        guard collectionAllowed else { return }
        eventBuffer.append(DiagnosticActivityEvent(
            safeEvent: event
        ))
        events = eventBuffer.elements
        synchronization?.record(
            event,
            browserContext: browserContext,
            windowTitle: windowTitle,
            windowCaptureFailure: windowCaptureFailure
        )
    }

    private func handleAutomaticPause(reason: String) {
        let wasActive = collectionAllowed
        automaticPauseReasons.insert(reason)
        automaticPauseReason = automaticPauseReasons.sorted().joined(separator: ",")
        if wasActive { stopActiveCollection() }
        if wasActive { synchronization?.recordCollectionState(.suspended, reason: reason) }
        if isActivityTrackingEnabled {
            statusMessage = "필수 관찰 조건 상실로 자동 일시정지했습니다: \(reason)"
        }
    }

    private func handleAutomaticResume(reason: String) {
        guard !activityStorageUnavailable else { return }
        guard automaticPauseReasons.contains(reason) else { return }
        automaticPauseReasons.remove(reason)
        automaticPauseReason = automaticPauseReasons.isEmpty
            ? nil
            : automaticPauseReasons.sorted().joined(separator: ",")
        guard automaticPauseReasons.isEmpty, isActivityTrackingEnabled else { return }
        resumeActiveCollection()
        synchronization?.recordCollectionState(.active, reason: reason)
        statusMessage = "필수 관찰 조건이 돌아와 활동 추적을 재개했습니다."
    }

    private func stopActiveCollection() {
        observationGeneration += 1
        browserApplicationTransition = nil
        chromeRestartPending = false
        lastObservationFailure = nil
        activeBundleID = nil
        lastFullObservationUptime = nil
        chromeObservation = nil
        firefoxObservation = nil
        lastChromePollCompletedAt = nil
        lastFirefoxPollCompletedAt = nil
        pendingExpectedTransition = nil
        currentAnchor = nil
        anchorStore.removeAll()
    }

    private func handleActivityStorageFailure() {
        guard !activityStorageUnavailable else { return }
        activityStorageUnavailable = true
        automaticPauseReasons.insert(Self.activityStoragePauseReason)
        automaticPauseReason = automaticPauseReasons.sorted().joined(separator: ",")
        stopActiveCollection()
        stopCollectionTimers()
        publishActivityStorageFailureStatus()
    }

    private func publishActivityStorageFailureStatus() {
        synchronizationStatus = "저장소 복구 필요 · 기록되지 않음"
        statusMessage = "활동 저장소를 사용할 수 없어 수집을 중단했습니다. 새 활동은 기록되지 않습니다."
    }

    private func stopCollectionTimers() {
        pollTimer?.invalidate()
        pollTimer = nil
        performanceTimer?.invalidate()
        performanceTimer = nil
    }

    private func resumeActiveCollection() {
        if let captureReturnAnchor = environment.captureReturnAnchor {
            currentAnchor = captureReturnAnchor()
        } else {
            currentAnchor = anchorStore.captureCurrent()
        }
        observeCurrentApplication(initial: true)
    }

    func pollCurrentActivity() {
        guard collectionAllowed else { return }
        guard let bundleID = environment.frontmostBundleID() else {
            if activeBundleID != nil { observationGeneration += 1 }
            activeBundleID = nil
            browserApplicationTransition = nil
            emitObservationUnavailable(reason: "frontmost_application_unavailable")
            return
        }
        if bundleID != activeBundleID {
            handleActivatedApplication(bundleID: bundleID, initial: activeBundleID == nil)
        } else if bundleID == ChromeAppleEventClient.bundleID {
            pollChromeIfNeeded()
        } else if bundleID == SystemEventsClient.firefoxBundleID {
            pollFirefoxIfNeeded()
        } else if periodicObservationDue {
            pollApplicationWindow(bundleID: bundleID, transition: .periodicObservation)
        }
    }

    private var periodicObservationDue: Bool {
        guard let lastFullObservationUptime else { return true }
        return environment.uptime() - lastFullObservationUptime >= 5
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
