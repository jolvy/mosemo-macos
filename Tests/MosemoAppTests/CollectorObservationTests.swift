import CollectorCore
import Foundation
import MosemoAPI
import XCTest
@testable import MosemoApp

@MainActor
final class CollectorObservationTests: XCTestCase {
    func testUnchangedApplicationProducesFreshObservationsEveryFiveSeconds() async {
        let source = ObservationSource()
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        source.advance(to: 4.9)
        model.pollCurrentActivity()
        XCTAssertEqual(model.events.count, 1)

        for (index, second) in [5.0, 10.0, 15.0].enumerated() {
            source.advance(to: second)
            model.pollCurrentActivity()
            await waitUntil { model.events.count == index + 2 }
        }

        XCTAssertEqual(model.events.map { $0.safeEvent.occurredAt }, [0, 5, 10, 15].map(source.date))
        XCTAssertEqual(model.events.map { $0.safeEvent.appBundleID }, Array(repeating: "com.example.editor", count: 4))
        XCTAssertEqual(model.statistics.detectedTransitions, 0)
    }

    func testUnchangedChromeProducesFreshBrowserObservationsEveryFiveSeconds() async throws {
        let source = ObservationSource()
        source.bundleID = ChromeAppleEventClient.bundleID
        let model = source.makeCollector()
        await waitUntil { model.chromeAutomationPermission == .granted }
        XCTAssertEqual(model.events.count, 1)
        XCTAssertEqual(model.events.first?.safeEvent.surfaceType, .browserPage)

        source.advance(to: 4.9)
        model.pollCurrentActivity()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.events.count, 1)
        for (index, second) in [5.0, 10.0, 15.0].enumerated() {
            source.advance(to: second)
            model.pollCurrentActivity()
            await waitUntil { model.events.count == index + 2 }
        }
        XCTAssertEqual(model.events.map { $0.safeEvent.occurredAt }, [0, 5, 10, 15].map(source.date))
        XCTAssertTrue(model.events.allSatisfy { $0.safeEvent.surfaceType == .browserPage })
        XCTAssertEqual(model.statistics.detectedTransitions, 0)
    }

    func testUnchangedFirefoxProducesFreshObservationsAndPageChangesResetTheInterval() async throws {
        let source = ObservationSource()
        source.bundleID = SystemEventsClient.firefoxBundleID
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        XCTAssertEqual(model.events.first?.safeEvent.surfaceType, .browserPage)
        source.advance(to: 5)
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 2 }

        source.advance(to: 6)
        source.firefoxResult = .success(source.firefoxObservation(content: 2))
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 3 }
        source.advance(to: 10)
        model.pollCurrentActivity()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.events.count, 3)
        source.advance(to: 11)
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 4 }
        XCTAssertEqual(model.events.map { $0.safeEvent.occurredAt }, [0, 5, 6, 11].map(source.date))
        XCTAssertEqual(model.events.map { $0.safeEvent.transitionType }, [.initialContext, .periodicObservation, .firefoxPageChange, .periodicObservation])
        XCTAssertEqual(model.statistics.detectedTransitions, 1)
    }

    func testChromeFailureDoesNotExtendActivityAndRecoveryObservesImmediately() async throws {
        let source = ObservationSource()
        source.bundleID = ChromeAppleEventClient.bundleID
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        let successfulResult = source.chromeResult
        source.advance(to: 1)
        source.chromeResult = .failure(.automationPermissionDenied)
        model.pollCurrentActivity()
        await waitUntil { model.chromeAutomationPermission == .denied }
        source.advance(to: 20)
        model.pollCurrentActivity()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.events.filter { $0.safeEvent.observationState == .observed }.count, 1)

        source.chromeResult = successfulResult
        source.advance(to: 21)
        model.pollCurrentActivity()
        await waitUntil { model.chromeAutomationPermission == .granted }
        source.advance(to: 22)
        source.chromeResult = .failure(.unavailable)
        model.pollCurrentActivity()
        await waitUntil { model.chromeAutomationPermission == .unavailable }
        source.chromeResult = successfulResult
        source.advance(to: 23)
        model.pollCurrentActivity()
        await waitUntil { model.chromeAutomationPermission == .granted }
        XCTAssertEqual(model.events.filter { $0.safeEvent.observationState == .observed }.map { $0.safeEvent.occurredAt }, [0, 21, 23].map(source.date))
    }

    func testChromeResultFromBeforePauseIsDiscardedAfterResume() async throws {
        let source = ObservationSource()
        source.bundleID = ChromeAppleEventClient.bundleID
        source.holdChromeReads = true
        let model = source.makeCollector()
        await waitUntil { source.pendingChromeReads.count == 1 }
        source.workspace.onAutomaticPause?("system_sleep")
        source.advance(to: 1)
        source.workspace.onAutomaticResume?("system_sleep")
        source.completeChromeRead()
        await waitUntil { source.pendingChromeReads.count == 1 }
        XCTAssertTrue(model.events.isEmpty, "A read started before suspension must not become a fresh observation")
        source.advance(to: 2)
        source.completeChromeRead()
        await waitUntil { model.events.count == 1 }
        XCTAssertEqual(model.events.first?.safeEvent.occurredAt, source.date(2))
    }

    func testMissingFrontmostApplicationDoesNotExtendActivityAndRecoveryObservesImmediately() async {
        let source = ObservationSource()
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        source.bundleID = nil
        source.advance(to: 1)
        model.pollCurrentActivity()
        XCTAssertEqual(model.events.filter { $0.safeEvent.observationState == .observed }.count, 1)
        source.bundleID = "com.example.editor"
        source.advance(to: 2)
        model.pollCurrentActivity()
        await waitUntil { model.events.filter { $0.safeEvent.observationState == .observed }.count == 2 }
        XCTAssertEqual(model.events.filter { $0.safeEvent.observationState == .observed }.map { $0.safeEvent.occurredAt }, [0, 2].map(source.date))
    }

    func testReadEmbeddedContentUsesFiveSecondCadenceWithoutClaimingSuccessfulObservation() async throws {
        let source = ObservationSource()
        source.bundleID = ChromeAppleEventClient.bundleID
        source.chromeResult = .success(.observation(ChromeObservation(
            identity: ChromeObservationIdentity(windowID: 1, tabID: 1, urlFingerprint: 1,
                classification: SurfaceClassifier.classify(urlString: "javascript:secret()", protectedContext: false)),
            diagnosticContext: TransientBrowserContext(title: "Hidden", url: "javascript:secret()")
        )))
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        source.advance(to: 1)
        model.pollCurrentActivity()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.events.count, 1)
        source.advance(to: 5)
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 2 }
        XCTAssertTrue(model.events.allSatisfy { $0.safeEvent.observationState == .unavailable })
        XCTAssertEqual(model.events.map { $0.safeEvent.occurredAt }, [0, 5].map(source.date))
    }

    func testWallClockChangesDoNotChangeCadenceAndDelayedPollDoesNotBackfill() async {
        let source = ObservationSource()
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        source.time = 4
        source.wallTime = 500
        model.pollCurrentActivity()
        XCTAssertEqual(model.events.count, 1)
        source.time = 5
        source.wallTime = -200
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 2 }
        source.time = 35
        source.wallTime = 100
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 3 }
        source.time = 36
        model.pollCurrentActivity()
        XCTAssertEqual(model.events.map { $0.safeEvent.occurredAt }, [0, -200, 100].map(source.date))
    }

    func testDisabledAndAutomaticallyPausedCollectionOnlyObservesAfterAllPauseReasonsClear() async {
        let source = ObservationSource()
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        model.setActivityTrackingEnabled(false)
        source.advance(to: 20)
        model.pollCurrentActivity()
        source.workspace.onAutomaticPause?("system_sleep")
        model.setActivityTrackingEnabled(true)
        model.pollCurrentActivity()
        XCTAssertEqual(model.events.count, 1)
        source.workspace.onAutomaticResume?("system_sleep")
        await waitUntil { model.events.count == 2 }
        XCTAssertEqual(model.events.last?.safeEvent.occurredAt, source.date(20))

        source.workspace.onAutomaticPause?("screen_sleep")
        source.workspace.onAutomaticPause?("system_sleep")
        source.advance(to: 40)
        source.workspace.onAutomaticResume?("screen_sleep")
        model.pollCurrentActivity()
        XCTAssertEqual(model.events.count, 2)
        source.workspace.onAutomaticResume?("system_sleep")
        await waitUntil { model.events.count == 3 }
        XCTAssertEqual(model.events.map { $0.safeEvent.occurredAt }, [0, 20, 40].map(source.date))
        model.synchronizationUnavailable()
        source.advance(to: 60)
        model.pollCurrentActivity()
        model.setActivityTrackingEnabled(false)
        model.setActivityTrackingEnabled(true)
        XCTAssertEqual(model.events.count, 3)
        XCTAssertFalse(model.collectionAllowed)
    }

    func testSwitchingAwayFromChromeDiscardsItsPendingResult() async throws {
        let source = ObservationSource()
        source.bundleID = ChromeAppleEventClient.bundleID
        source.holdChromeReads = true
        let model = source.makeCollector()
        await waitUntil { source.pendingChromeReads.count == 1 }
        source.bundleID = "com.example.editor"
        source.advance(to: 1)
        model.pollCurrentActivity()
        source.advance(to: 2)
        source.completeChromeRead()
        await waitUntil { model.events.count == 1 }
        XCTAssertEqual(model.events.map { $0.safeEvent.appBundleID }, ["com.example.editor"])
        XCTAssertEqual(model.events.first?.safeEvent.occurredAt, source.date(2))
    }

    func testChromeRestartDiscardsPendingReadAndObservesTheRestartedBrowser() async {
        let source = ObservationSource()
        source.bundleID = ChromeAppleEventClient.bundleID
        source.holdChromeReads = true
        let model = source.makeCollector()
        await waitUntil { source.pendingChromeReads.count == 1 }
        source.workspace.onChromeLifecycleChange?()
        source.completeChromeRead()
        await waitUntil { source.pendingChromeReads.count == 1 }
        XCTAssertTrue(model.events.isEmpty)
        source.advance(to: 1)
        source.completeChromeRead()
        await waitUntil { model.events.count == 1 }
        XCTAssertEqual(model.events.first?.safeEvent.transitionType, .chromeRestart)
        XCTAssertEqual(model.events.first?.safeEvent.occurredAt, source.date(1))
    }

    func testPeriodicBrowserRecordsAreFilteredPersistedAndSentOnlyAfterHeadAcceptance() async throws {
        let source = ObservationSource()
        source.bundleID = ChromeAppleEventClient.bundleID
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: ObservationQueueKeyStore())
        let client = ObservationAPIClient()
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now, lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let deviceID = UUID()
        model.configureSynchronization(client: client, deviceStateStore: ObservationDeviceStore(deviceID: deviceID), queue: queue)
        await model.synchronizationAccountChanged(account)
        try await waitUntilAsync { await client.observations().count == 1 }

        source.chromeResult = .success(.observation(ChromeObservation(
            identity: ChromeObservationIdentity(windowID: 1, tabID: 1, urlFingerprint: 1,
                classification: SurfaceClassifier.classify(urlString: "https://example.com/page", protectedContext: false)),
            diagnosticContext: TransientBrowserContext(
                title: String(repeating: "a", count: 5_000),
                url: "https://example.com/page",
                windowTitle: "Example browser window"
            )
        )))
        source.advance(to: 5)
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 3 }
        source.advance(to: 10)
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 4 }
        try await waitUntilAsync { try await queue.count(accountID: account.id) == 3 }
        let sentBeforeAcceptance = await client.observations()
        XCTAssertEqual(sentBeforeAcceptance.count, 1)
        let head = try await queue.first(accountID: account.id, deviceID: deviceID)
        XCTAssertEqual(head?.record, .observation(sentBeforeAcceptance[0]))

        await client.finishNextObservation(error: .networkUnavailable)
        try await waitUntilAsync { await client.observations().count == 2 }
        let retried = await client.observations()
        XCTAssertEqual(retried[0], retried[1], "Response loss must replay the exact persisted record")
        let pendingAfterResponseLoss = try await queue.count(accountID: account.id)
        XCTAssertEqual(pendingAfterResponseLoss, 3)

        await client.finishNextObservation()
        try await waitUntilAsync { await client.observations().count == 3 }
        let sentAfterAcceptance = await client.observations()
        let periodic = sentAfterAcceptance[2]
        XCTAssertEqual(periodic.metadata.observedAt, source.date(5))
        guard case .detailed(let detail) = periodic.context, case .browser(let browser) = detail.web else {
            return XCTFail("Expected a complete browser snapshot")
        }
        XCTAssertEqual(detail.app.bundleID, .captured(ChromeAppleEventClient.bundleID))
        XCTAssertEqual(browser.url, .captured("https://example.com/page"))
        XCTAssertEqual(browser.tabTitle, .captured(ActivityCapturedText(value: String(repeating: "a", count: 4_096), truncated: true, originalByteLength: 5_000)))
        XCTAssertEqual(detail.window, .captured(title: ActivityPrivacyFilter.title("Example browser window")))
        XCTAssertFalse(model.diagnosticSnapshot().contains(String(repeating: "a", count: 100)))

        await client.finishNextObservation()
        try await waitUntilAsync { await client.observations().count == 4 }
        await client.finishNextObservation()
        try await waitUntilAsync { try await queue.count(accountID: account.id) == 0 }
        let sent = await client.observations()
        XCTAssertEqual(sent.map { $0.metadata.sequence }, [2, 2, 3, 4])
        XCTAssertEqual(sent.map { $0.metadata.observedAt }, [0, 0, 5, 10].map(source.date))
        XCTAssertEqual(Set(sent.map { $0.metadata.eventID }).count, 3)
        let maximumConcurrentRequests = await client.maximumConcurrentRequests()
        XCTAssertEqual(maximumConcurrentRequests, 1)
        source.advance(to: 10.5)
        model.pollCurrentActivity()
        try await Task.sleep(for: .milliseconds(20))
        let requestsWithEmptyQueue = await client.observations().count
        XCTAssertEqual(requestsWithEmptyQueue, 4)
        await model.synchronizationAccountChanged(nil)
    }

    func testPeriodicProtectedBrowserObservationsPersistOnlyOpaqueContext() async throws {
        let source = ObservationSource()
        source.bundleID = ChromeAppleEventClient.bundleID
        source.chromeResult = .success(.observation(ChromeObservation(
            identity: ChromeObservationIdentity(windowID: 1, tabID: -1, urlFingerprint: 0,
                classification: SurfaceClassifier.classify(urlString: nil, protectedContext: true)),
            diagnosticContext: TransientBrowserContext(title: "Private title", url: "https://private.example/secret")
        )))
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: ObservationQueueKeyStore())
        let client = ObservationAPIClient()
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now, lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let deviceID = UUID()
        model.configureSynchronization(client: client, deviceStateStore: ObservationDeviceStore(deviceID: deviceID), queue: queue)
        await model.synchronizationAccountChanged(account)
        try await waitUntilAsync { await client.observations().count == 1 }
        source.advance(to: 5)
        model.pollCurrentActivity()
        try await waitUntilAsync { try await queue.count(accountID: account.id) == 2 }
        let saved = try await queue.first(accountID: account.id, deviceID: deviceID)
        guard case .observation(let observation)? = saved?.record else {
            return XCTFail("Expected a persisted protected observation")
        }
        XCTAssertEqual(observation.context, .opaque)
        await client.finishNextObservation()
        try await waitUntilAsync { await client.observations().count == 2 }
        let sent = await client.observations()
        XCTAssertEqual(sent.map(\.context), [.opaque, .opaque])
        XCTAssertEqual(sent.map { $0.metadata.observedAt }, [0, 5].map(source.date))
        XCTAssertTrue(model.events.allSatisfy { $0.safeEvent.appBundleID == nil && $0.safeEvent.observationState == .protected })
        XCTAssertFalse(model.diagnosticSnapshot().contains("Private title"))
        XCTAssertFalse(model.diagnosticSnapshot().contains("private.example"))
        await client.finishNextObservation()
        try await waitUntilAsync { try await queue.count(accountID: account.id) == 0 }
        await model.synchronizationAccountChanged(nil)
    }

    func testApplicationSwitchIsImmediateAndResetsFiveSecondInterval() async {
        let source = ObservationSource()
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        source.advance(to: 4)
        source.bundleID = "com.example.other"
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 2 }
        source.advance(to: 5)
        model.pollCurrentActivity()
        XCTAssertEqual(model.events.count, 2)
        source.advance(to: 9)
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 3 }
        XCTAssertEqual(model.events.map { $0.safeEvent.occurredAt }, [0, 4, 9].map(source.date))
        XCTAssertEqual(model.events.map { $0.safeEvent.transitionType }, [.initialContext, .appSwitch, .periodicObservation])
    }

    func testFirefoxFailureRecoveryAndLateResultAfterAppSwitch() async throws {
        let source = ObservationSource()
        source.bundleID = SystemEventsClient.firefoxBundleID
        let model = source.makeCollector()
        await waitUntil { model.events.count == 1 }
        source.firefoxResult = .failure(.pageContextUnavailable)
        source.advance(to: 1)
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 2 }
        source.firefoxResult = .success(source.firefoxObservation())
        source.advance(to: 2)
        model.pollCurrentActivity()
        await waitUntil { model.events.count == 3 }
        XCTAssertEqual(model.events.filter { $0.safeEvent.observationState == .observed }.map { $0.safeEvent.occurredAt }, [0, 2].map(source.date))

        source.holdFirefoxReads = true
        model.pollCurrentActivity()
        await waitUntil { source.pendingFirefoxReads.count == 1 }
        source.bundleID = "com.example.editor"
        source.advance(to: 3)
        model.pollCurrentActivity()
        source.pendingFirefoxReads.removeFirst().resume(returning: source.firefoxResult)
        await waitUntil { model.events.count == 4 }
        XCTAssertEqual(model.events.count, 4)
        XCTAssertEqual(model.events.last?.safeEvent.appBundleID, "com.example.editor")
    }

    func testLateApplicationReadPreservesLatestAppSwitch() async throws {
        let source = ObservationSource()
        source.holdApplicationReads = true
        let model = source.makeCollector()
        await waitUntil { source.pendingApplicationReads.count == 1 }
        source.bundleID = "com.example.second"
        source.advance(to: 1)
        model.pollCurrentActivity()
        source.pendingApplicationReads.removeFirst().resume(returning: .captured(
            ApplicationWindowContext(title: "Old window", browserURL: nil)))
        await waitUntil { source.pendingApplicationReads.count == 1 }
        source.pendingApplicationReads.removeFirst().resume(returning: .captured(
            ApplicationWindowContext(title: "New window", browserURL: nil)))
        await waitUntil { model.events.count == 1 }
        XCTAssertEqual(model.events.last?.safeEvent.appBundleID, "com.example.second")
        XCTAssertEqual(model.events.last?.safeEvent.transitionType, .appSwitch)
    }

    func testFirefoxSchemeLessAddressRemainsObservedWithoutRewriting() {
        let observation = SystemEventsClient().observation(for: ApplicationWindowContext(
            title: "Example", browserURL: "example.com/path?query=value#section"))
        XCTAssertEqual(observation.classification.observationState, .observed)
        XCTAssertEqual(observation.diagnosticContext?.url, "example.com/path?query=value#section")
    }

    func testFirefoxUnknownPrivateStateSuppressesDetailedContext() {
        for title: String? in [nil, ""] {
            let observation = SystemEventsClient().observation(for: ApplicationWindowContext(
                title: title, browserURL: "https://example.com/private"))
            XCTAssertTrue(observation.classification.protectedContext)
            XCTAssertNil(observation.diagnosticContext)
        }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for collector output", file: file, line: line)
    }

    private func waitUntilAsync(_ condition: () async throws -> Bool,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the observation pipeline", file: file, line: line)
    }
}

@MainActor
private final class ObservationSource {
    var time: TimeInterval = 0
    var wallTime: TimeInterval = 0
    var bundleID: String? = "com.example.editor"
    let workspace = WorkspaceObserver()
    var chromeReads = 0
    var holdChromeReads = false
    var pendingChromeReads: [CheckedContinuation<Result<ChromeReadResult, ChromeReadFailure>, Never>] = []
    var holdApplicationReads = false
    var pendingApplicationReads: [CheckedContinuation<ApplicationWindowReadResult, Never>] = []
    var holdFirefoxReads = false
    var pendingFirefoxReads: [CheckedContinuation<Result<FirefoxObservation, SystemEventsReadFailure>, Never>] = []
    var chromeResult: Result<ChromeReadResult, ChromeReadFailure> = .success(.observation(ChromeObservation(
        identity: ChromeObservationIdentity(windowID: 1, tabID: 1, urlFingerprint: 1,
            classification: SurfaceClassifier.classify(urlString: "https://example.com/page", protectedContext: false)),
        diagnosticContext: TransientBrowserContext(title: "Page", url: "https://example.com/page")
    )))
    lazy var firefoxResult: Result<FirefoxObservation, SystemEventsReadFailure> = .success(firefoxObservation())

    func completeChromeRead() {
        guard !pendingChromeReads.isEmpty else { return }
        pendingChromeReads.removeFirst().resume(returning: chromeResult)
    }

    func firefoxObservation(content: Int = 1) -> FirefoxObservation {
        FirefoxObservation(identity: FirefoxObservationIdentity(windowFingerprint: 1, contentFingerprint: content),
            classification: SurfaceClassifier.classify(urlString: "https://example.com/page", protectedContext: false),
            diagnosticContext: TransientBrowserContext(title: "Page", url: "https://example.com/page"))
    }

    func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000 + seconds)
    }

    func advance(to seconds: TimeInterval) {
        time = seconds
        wallTime = seconds
    }

    func makeCollector() -> CollectorViewModel {
        CollectorViewModel(environment: CollectorObservationEnvironment(
            now: { self.date(self.wallTime) },
            uptime: { self.time },
            frontmostBundleID: { self.bundleID },
            readChrome: {
                self.chromeReads += 1
                if self.holdChromeReads {
                    return await withCheckedContinuation { self.pendingChromeReads.append($0) }
                }
                return self.chromeResult
            },
            readFirefox: {
                if self.holdFirefoxReads {
                    return await withCheckedContinuation { self.pendingFirefoxReads.append($0) }
                }
                return self.firefoxResult
            },
            readApplicationWindow: { _ in
                if self.holdApplicationReads {
                    return await withCheckedContinuation { self.pendingApplicationReads.append($0) }
                }
                return .captured(ApplicationWindowContext(title: "Example window", browserURL: nil))
            },
            captureReturnAnchor: { nil },
            initialTrackingEnabled: true,
            persistTrackingPreference: false
        ), workspaceObserver: workspace, startAutomatically: false)
    }
}

private actor ObservationQueueKeyStore: ActivityQueueKeyStoring {
    func loadOrCreateKey() async throws -> Data { Data(repeating: 7, count: 32) }
}

private actor ObservationDeviceStore: DeviceRegistrationStateStoring {
    let deviceID: UUID
    init(deviceID: UUID) { self.deviceID = deviceID }
    func load(for accountID: UUID) async throws -> DeviceRegistrationState {
        DeviceRegistrationState(deviceID: deviceID)
    }
    func save(_ state: DeviceRegistrationState, for accountID: UUID) async throws {}
}

private actor ObservationAPIClient: MosemoAPIClient {
    private var sent: [ActivityObservation] = []
    private var pending: [CheckedContinuation<Void, Error>] = []
    private var activeRequests = 0
    private var maximumRequests = 0

    nonisolated func makeKakaoLoginURL(codeChallenge: String) throws -> URL { fatalError("unused") }
    func authenticate(authorizationCode: String, codeVerifier: String) async throws -> Account { fatalError("unused") }
    func currentAccount() async throws -> Account { fatalError("unused") }
    func registerDevice(idempotencyKey: UUID) async throws -> Device { fatalError("unused") }
    func signOut() async throws { fatalError("unused") }
    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay { fatalError("unused") }

    func createActivity(_ record: ActivityRecord) async throws -> ActivityCreateResult {
        switch record {
        case .collectionStateChanged(let state):
            return ActivityCreateResult(eventID: state.metadata.eventID, receivedAt: state.metadata.observedAt)
        case .observation(let observation):
            sent.append(observation)
            activeRequests += 1
            maximumRequests = max(maximumRequests, activeRequests)
            defer { activeRequests -= 1 }
            try await withCheckedThrowingContinuation { pending.append($0) }
            return ActivityCreateResult(eventID: observation.metadata.eventID, receivedAt: observation.metadata.observedAt)
        }
    }

    func finishNextObservation(error: MosemoAPIError? = nil) {
        guard !pending.isEmpty else { return }
        let continuation = pending.removeFirst()
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    func observations() -> [ActivityObservation] { sent }
    func maximumConcurrentRequests() -> Int { maximumRequests }
}
