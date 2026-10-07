import CollectorCore
import Foundation
import XCTest
@testable import MosemoAPI
@testable import MosemoApp

@MainActor
final class OfflineActivityCoordinatorTests: XCTestCase {
    func testOnlyMatchingAcceptedUploadPublishesAccountAfterRetry() async throws {
        for mismatch in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                                  lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
            let device = UUID()
            let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                                   keyStore: QueueTestKeyStore())
            _ = try await queue.enqueue(accountID: account.id, deviceID: device, observedAt: .now,
                                        timezoneID: "Asia/Seoul", utcOffsetMinutes: 540) { metadata in
                .observation(ActivityObservation(metadata: metadata, context: .opaque))
            }
            var acceptedAccounts: [UUID] = []
            var statuses: [String] = []
            let coordinator = OfflineActivityCoordinator(queue: queue,
                client: QueueTestClient(firstError: .networkUnavailable, mismatchedAcknowledgement: mismatch),
                deviceStateStore: QueueTestDeviceStore(deviceID: device), sleepBeforeRetry: { _ in },
                onActivityAccepted: { acceptedAccounts.append($0) },
                onStatus: { _, status in statuses.append(status) })
            await coordinator.activate(account)
            XCTAssertTrue(acceptedAccounts.isEmpty)
            for _ in 0..<100 {
                if statuses.contains(mismatch ? "수락 확인 필요" : "동기화 완료") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(acceptedAccounts, mismatch ? [] : [account.id])
        }
    }

    func testCoordinatorPersistsRapidInterleavedInputsInCallOrderWhileFirstWriteIsDelayed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let keyStore = ControllableQueueTestKeyStore()
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: keyStore)
        var statuses: [String] = []
        let coordinator = OfflineActivityCoordinator(
            queue: queue,
            client: QueueTestClient(firstError: .validationFailed),
            deviceStateStore: QueueTestDeviceStore(deviceID: device),
            onStatus: { _, status in statuses.append(status) }
        )
        await coordinator.activate(account)
        for _ in 0..<100 {
            if statuses.contains("동기화 완료") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))

        await keyStore.delayNextLoad()
        coordinator.record(makeActivityEvent(appBundleID: "com.example.first"), browserContext: nil)
        for _ in 0..<100 {
            if await keyStore.hasBlockedLoad() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let hasBlockedLoad = await keyStore.hasBlockedLoad()
        XCTAssertTrue(hasBlockedLoad)

        coordinator.recordCollectionState(.suspended, reason: "test_pause")
        coordinator.record(makeActivityEvent(appBundleID: "com.example.second"), browserContext: nil)
        try await Task.sleep(for: .milliseconds(30))
        let loadCountBeforeRelease = await keyStore.loadCount()
        XCTAssertEqual(loadCountBeforeRelease, 2, "Only the first write should have reached the queue")

        await keyStore.releaseBlockedLoad()
        for _ in 0..<100 {
            if try await queue.count(accountID: account.id) == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let records = try await drainRecords(from: queue, accountID: account.id, deviceID: device)
        XCTAssertEqual(records.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(records.map(\.kind), [
            .observation(bundleID: "com.example.first"),
            .collectionState(state: .suspended, reason: "test_pause"),
            .observation(bundleID: "com.example.second"),
        ])
    }

    func testFirstWriteFailureStopsAcceptingRecordsAndReportsStorageFailureOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let keyStore = FailingQueueTestKeyStore(failingLoad: 2)
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: keyStore)
        var failureCount = 0
        var statuses: [String] = []
        let coordinator = OfflineActivityCoordinator(
            queue: queue,
            client: QueueTestClient(),
            deviceStateStore: QueueTestDeviceStore(deviceID: device),
            onStorageFailure: { failureCount += 1 },
            onStatus: { _, status in statuses.append(status) }
        )
        await coordinator.activate(account)
        try await Task.sleep(for: .milliseconds(50))

        coordinator.record(makeActivityEvent(appBundleID: "com.example.failed"), browserContext: nil)
        for _ in 0..<100 {
            if failureCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        coordinator.record(makeActivityEvent(appBundleID: "com.example.ignored"), browserContext: nil)
        coordinator.recordCollectionState(.suspended, reason: "ignored_after_failure")
        try await Task.sleep(for: .milliseconds(30))

        let keyLoads = await keyStore.loadCount()
        let pendingCount = try await queue.count(accountID: account.id)
        XCTAssertEqual(failureCount, 1)
        XCTAssertEqual(keyLoads, 2)
        XCTAssertEqual(pendingCount, 0)
        XCTAssertTrue(statuses.contains("저장소 복구 필요 · 기록되지 않음"))
    }

    func testAcceptedWriteKeepsCapturedAccountAcrossAccountChangeWithoutSendingOldGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstAccount = Account(id: UUID(), provider: .kakao, createdAt: .now,
                                   lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let secondAccount = Account(id: UUID(), provider: .kakao, createdAt: .now,
                                    lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let keyStore = ControllableQueueTestKeyStore()
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: keyStore)
        let client = QueueTestClient(firstError: .validationFailed)
        let coordinator = OfflineActivityCoordinator(
            queue: queue,
            client: client,
            deviceStateStore: QueueTestDeviceStore(deviceID: device),
            onStatus: { _, _ in }
        )
        await coordinator.activate(firstAccount)
        try await Task.sleep(for: .milliseconds(50))

        await keyStore.delayNextLoad()
        coordinator.record(makeActivityEvent(appBundleID: "com.example.first-account"), browserContext: nil)
        for _ in 0..<100 {
            if await keyStore.hasBlockedLoad() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await coordinator.activate(secondAccount)
        coordinator.record(makeActivityEvent(appBundleID: "com.example.second-account"), browserContext: nil)
        await keyStore.releaseBlockedLoad()

        for _ in 0..<100 {
            let firstCount = try await queue.count(accountID: firstAccount.id)
            let secondCount = try await queue.count(accountID: secondAccount.id)
            if firstCount == 1 && secondCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let firstRecords = try await drainRecords(from: queue, accountID: firstAccount.id, deviceID: device)
        let secondRecords = try await drainRecords(from: queue, accountID: secondAccount.id, deviceID: device)
        let sentRecords = await client.records()
        XCTAssertEqual(firstRecords.map(\.kind), [.observation(bundleID: "com.example.first-account")])
        XCTAssertEqual(secondRecords.map(\.kind), [.observation(bundleID: "com.example.second-account")])
        XCTAssertEqual(sentRecords.count, 1)
        guard case .observation(let sentObservation) = sentRecords[0],
              case .detailed(let sentDetails) = sentObservation.context else {
            return XCTFail("Expected the current account observation to be sent")
        }
        XCTAssertEqual(sentDetails.app.bundleID, .captured("com.example.second-account"))
    }

    func testOrdinaryUnavailableObservationRemainsDiagnosticOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: QueueTestKeyStore())
        let coordinator = OfflineActivityCoordinator(
            queue: queue,
            client: QueueTestClient(),
            deviceStateStore: QueueTestDeviceStore(deviceID: device),
            onStatus: { _, _ in }
        )
        await coordinator.activate(account)

        coordinator.record(SafeActivityEvent(
            eventType: .activity,
            appBundleID: nil,
            registeredDomain: nil,
            surfaceType: .unavailable,
            transitionType: .observationUnavailable,
            observationState: .unavailable,
            inputOccurred: nil,
            occurredAt: .now,
            detectionLatencyMilliseconds: 0,
            protectedContext: false
        ), browserContext: nil)
        try await Task.sleep(for: .milliseconds(30))

        let pendingCount = try await queue.count(accountID: account.id)
        XCTAssertEqual(pendingCount, 0)
    }

    func testSynchronizationUnavailableStopsCollectionAndShowsPersistentRecoveryStatus() {
        let preferenceKey = "io.mosemo.activityTrackingEnabled"
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: preferenceKey)
        defaults.set(true, forKey: preferenceKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
        }
        let viewModel = CollectorViewModel()
        XCTAssertTrue(viewModel.collectionAllowed)

        viewModel.synchronizationUnavailable()

        XCTAssertFalse(viewModel.collectionAllowed)
        XCTAssertEqual(viewModel.synchronizationStatus, "저장소 복구 필요 · 기록되지 않음")
        XCTAssertTrue(viewModel.activityTrackingStatusText.contains("저장소 복구 필요"))
        XCTAssertTrue(viewModel.statusMessage.contains("기록되지 않습니다"))

        viewModel.setActivityTrackingEnabled(false)
        viewModel.setActivityTrackingEnabled(true)
        XCTAssertFalse(viewModel.collectionAllowed)
        XCTAssertEqual(viewModel.synchronizationStatus, "저장소 복구 필요 · 기록되지 않음")
        XCTAssertTrue(viewModel.statusMessage.contains("기록되지 않습니다"))
    }

    func testCoordinatorSendsOnlyPersistedRecordsInSequenceAndRemovesAcknowledgedItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let client = QueueTestClient()
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: QueueTestKeyStore())
        let coordinator = OfflineActivityCoordinator(queue: queue, client: client,
            deviceStateStore: QueueTestDeviceStore(deviceID: device), onStatus: { _, _ in })

        _ = try await queue.enqueue(accountID: account.id, deviceID: device, observedAt: .now,
                                    timezoneID: "Asia/Seoul", utcOffsetMinutes: 540) { metadata in
            .collectionStateChanged(CollectionStateChange(metadata: metadata, state: .active, reason: "test"))
        }
        await coordinator.activate(account)
        coordinator.record(SafeActivityEvent(eventType: .activity, appBundleID: "com.example.editor",
            registeredDomain: nil, surfaceType: .application, transitionType: .appSwitch,
            observationState: .observed, inputOccurred: nil, occurredAt: .now,
            detectionLatencyMilliseconds: 0, protectedContext: false), browserContext: nil)

        for _ in 0..<100 {
            let sent = await client.sequences()
            let pending = try await queue.count(accountID: account.id)
            if sent.count == 2 && pending == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sequences = await client.sequences()
        let pendingCount = try await queue.count(accountID: account.id)
        let maximumInFlight = await client.maximumConcurrentRequests()
        XCTAssertEqual(sequences, [1, 2])
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(maximumInFlight, 1)
    }

    func testCoordinatorRetriesIdenticalHeadAndHonorsLongerRetryAfter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let retryWaits = RetryWaitRecorder()
        let client = QueueTestClient(firstError: .retryableServerError(statusCode: 503, retryAfter: 3))
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: QueueTestKeyStore())
        _ = try await queue.enqueue(accountID: account.id, deviceID: device, observedAt: .now,
                                    timezoneID: "Asia/Seoul", utcOffsetMinutes: 540) { metadata in
            .collectionStateChanged(CollectionStateChange(metadata: metadata, state: .active, reason: "test"))
        }
        let coordinator = OfflineActivityCoordinator(queue: queue, client: client,
            deviceStateStore: QueueTestDeviceStore(deviceID: device),
            sleepBeforeRetry: { seconds in await retryWaits.append(seconds) },
            retryJitter: { 0.5 }, onStatus: { _, _ in })

        await coordinator.activate(account)
        for _ in 0..<100 {
            let pending = try await queue.count(accountID: account.id)
            if pending == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let records = await client.records()
        let delays = await retryWaits.delays()
        let pending = try await queue.count(accountID: account.id)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0], records[1])
        XCTAssertEqual(delays, [3])
        XCTAssertEqual(pending, 0)
    }

    func testCoordinatorPreservesRecordWhenAcknowledgementEventIDDoesNotMatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let client = QueueTestClient(mismatchedAcknowledgement: true)
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: QueueTestKeyStore())
        _ = try await queue.enqueue(accountID: account.id, deviceID: device, observedAt: .now,
                                    timezoneID: "Asia/Seoul", utcOffsetMinutes: 540) { metadata in
            .collectionStateChanged(CollectionStateChange(metadata: metadata, state: .active, reason: "test"))
        }
        var statuses: [String] = []
        let coordinator = OfflineActivityCoordinator(queue: queue, client: client,
            deviceStateStore: QueueTestDeviceStore(deviceID: device), onStatus: { _, status in statuses.append(status) })

        await coordinator.activate(account)
        for _ in 0..<100 {
            if statuses.contains("수락 확인 필요") { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let pending = try await queue.count(accountID: account.id)
        let sequences = await client.sequences()
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(sequences, [1])
        XCTAssertTrue(statuses.contains("수락 확인 필요"))

        coordinator.record(SafeActivityEvent(eventType: .activity, appBundleID: "com.example.editor",
            registeredDomain: nil, surfaceType: .application, transitionType: .appSwitch,
            observationState: .observed, inputOccurred: nil, occurredAt: .now,
            detectionLatencyMilliseconds: 0, protectedContext: false), browserContext: nil)
        try await Task.sleep(for: .milliseconds(40))
        let sequencesAfterNewRecord = await client.sequences()
        let pendingAfterNewRecord = try await queue.count(accountID: account.id)
        XCTAssertEqual(sequencesAfterNewRecord, [1])
        XCTAssertEqual(pendingAfterNewRecord, 2)
        XCTAssertEqual(statuses.last, "수락 확인 필요")
    }

    func testProtectedActivityPersistsOnlyOpaqueContext() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: QueueTestKeyStore())
        let coordinator = OfflineActivityCoordinator(queue: queue, client: QueueTestClient(firstError: .validationFailed),
            deviceStateStore: QueueTestDeviceStore(deviceID: device), onStatus: { _, _ in })
        await coordinator.activate(account)

        coordinator.record(SafeActivityEvent(eventType: .activity, appBundleID: "com.google.Chrome",
            registeredDomain: nil, surfaceType: .browserPage, transitionType: .chromeTabSwitch,
            observationState: .observed, inputOccurred: nil, occurredAt: .now,
            detectionLatencyMilliseconds: 0, protectedContext: true),
            browserContext: TransientBrowserContext(title: "private title", url: "https://private.test/path"))
        for _ in 0..<100 {
            if try await queue.count(accountID: account.id) == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let saved = try await queue.first(accountID: account.id, deviceID: device)
        guard case .observation(let observation)? = saved?.record else {
            return XCTFail("Expected a saved observation")
        }
        XCTAssertEqual(observation.context, .opaque)
    }

    func testApplicationWindowTitleIsPersistedForGenericAppObservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: QueueTestKeyStore())
        let coordinator = OfflineActivityCoordinator(
            queue: queue,
            client: QueueTestClient(firstError: .validationFailed),
            deviceStateStore: QueueTestDeviceStore(deviceID: device),
            onStatus: { _, _ in }
        )
        await coordinator.activate(account)

        coordinator.record(
            makeActivityEvent(appBundleID: "com.kakao.KakaoTalkMac"),
            browserContext: nil,
            windowTitle: "KakaoTalk - Example conversation"
        )
        for _ in 0..<100 {
            if try await queue.count(accountID: account.id) == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let saved = try await queue.first(accountID: account.id, deviceID: device)
        guard case .observation(let observation)? = saved?.record,
              case .detailed(let detail) = observation.context else {
            return XCTFail("Expected a detailed application observation")
        }
        XCTAssertEqual(detail.app.bundleID, .captured("com.kakao.KakaoTalkMac"))
        XCTAssertEqual(
            detail.window,
            .captured(title: ActivityPrivacyFilter.title("KakaoTalk - Example conversation"))
        )
        XCTAssertEqual(detail.web, .notApplicable)
    }

    func testQueueReadFailureStopsSendingAndPreservesPendingRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let databaseURL = directory.appendingPathComponent("queue.sqlite")
        let writeQueue = try EncryptedActivityQueue(databaseURL: databaseURL, keyStore: QueueTestKeyStore())
        _ = try await writeQueue.enqueue(accountID: account.id, deviceID: device, observedAt: .now,
                                         timezoneID: "Asia/Seoul", utcOffsetMinutes: 540) { metadata in
            .collectionStateChanged(CollectionStateChange(metadata: metadata, state: .active, reason: "test"))
        }
        let unreadableQueue = try EncryptedActivityQueue(databaseURL: databaseURL, keyStore: QueueTestKeyStore(fails: true))
        var statuses: [String] = []
        let client = QueueTestClient()
        let coordinator = OfflineActivityCoordinator(queue: unreadableQueue, client: client,
            deviceStateStore: QueueTestDeviceStore(deviceID: device), onStatus: { _, status in statuses.append(status) })

        await coordinator.activate(account)
        for _ in 0..<100 {
            if statuses.contains("복구 필요 · 기록 보존 중") { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let sequences = await client.sequences()
        let pending = try await unreadableQueue.count(accountID: account.id)
        XCTAssertEqual(sequences, [])
        XCTAssertEqual(pending, 1)
        XCTAssertTrue(statuses.contains("복구 필요 · 기록 보존 중"))
    }

    func testEmbeddedContentURLIsPersistedAsRedactedEvenWhenClassifierMarkedItUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: QueueTestKeyStore())
        let coordinator = OfflineActivityCoordinator(queue: queue, client: QueueTestClient(firstError: .validationFailed),
            deviceStateStore: QueueTestDeviceStore(deviceID: device), onStatus: { _, _ in })
        await coordinator.activate(account)

        coordinator.record(SafeActivityEvent(eventType: .activity, appBundleID: "com.google.Chrome",
            registeredDomain: nil, surfaceType: .unavailable, transitionType: .observationUnavailable,
            observationState: .unavailable, inputOccurred: nil, occurredAt: .now,
            detectionLatencyMilliseconds: 0, protectedContext: false),
            browserContext: TransientBrowserContext(title: "private", url: "javascript:secret()"))
        for _ in 0..<100 {
            if try await queue.count(accountID: account.id) == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let saved = try await queue.first(accountID: account.id, deviceID: device)
        guard case .observation(let observation)? = saved?.record,
              case .detailed(let detail) = observation.context,
              case .browser(let browser) = detail.web else {
            return XCTFail("Expected a detailed browser observation")
        }
        XCTAssertEqual(browser.url, .redacted(reason: "embedded_content_scheme"))
        XCTAssertEqual(detail.app.bundleID, .absent)
        XCTAssertEqual(browser.tabTitle, .unavailable(reason: "observation_unavailable"))
    }

    func testRestartAfterLostResponseReplaysTheExactPersistedRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("queue.sqlite")
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let keyStore = QueueTestKeyStore()
        let originalQueue = try EncryptedActivityQueue(databaseURL: databaseURL, keyStore: keyStore)
        let original = try await originalQueue.enqueue(accountID: account.id, deviceID: device, observedAt: .now,
            timezoneID: "Asia/Seoul", utcOffsetMinutes: 540) { metadata in
                .observation(ActivityObservation(metadata: metadata, context: .opaque))
            }
        let retryWaits = RetryWaitRecorder()
        let firstClient = QueueTestClient(firstError: .networkUnavailable)
        let firstCoordinator = OfflineActivityCoordinator(queue: originalQueue, client: firstClient,
            deviceStateStore: QueueTestDeviceStore(deviceID: device),
            sleepBeforeRetry: { seconds in
                await retryWaits.append(seconds)
                try? await Task.sleep(for: .seconds(seconds))
            }, retryJitter: { 0.5 }, onStatus: { _, _ in })

        await firstCoordinator.activate(account)
        for _ in 0..<100 {
            if !(await retryWaits.delays()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await firstCoordinator.activate(nil)

        let firstAttempt = await firstClient.records()
        let reopenedQueue = try EncryptedActivityQueue(databaseURL: databaseURL, keyStore: keyStore)
        let replayClient = QueueTestClient()
        let restartedCoordinator = OfflineActivityCoordinator(queue: reopenedQueue, client: replayClient,
            deviceStateStore: QueueTestDeviceStore(deviceID: device), onStatus: { _, _ in })
        await restartedCoordinator.activate(account)
        for _ in 0..<100 {
            if try await reopenedQueue.count(accountID: account.id) == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let replay = await replayClient.records()
        let pending = try await reopenedQueue.count(accountID: account.id)
        XCTAssertEqual(firstAttempt, [original.record])
        XCTAssertEqual(replay, [original.record])
        XCTAssertEqual(pending, 0)
    }

    func testEmptyQueueDoesNotStartARequestOrRetryTimer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(id: UUID(), provider: .kakao, createdAt: .now,
                              lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
        let device = UUID()
        let client = QueueTestClient()
        let retryWaits = RetryWaitRecorder()
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                               keyStore: QueueTestKeyStore())
        let coordinator = OfflineActivityCoordinator(queue: queue, client: client,
            deviceStateStore: QueueTestDeviceStore(deviceID: device),
            sleepBeforeRetry: { seconds in await retryWaits.append(seconds) },
            retryJitter: { 0.5 }, onStatus: { _, _ in })

        await coordinator.activate(account)
        try await Task.sleep(for: .milliseconds(40))

        let sequences = await client.sequences()
        let delays = await retryWaits.delays()
        XCTAssertEqual(sequences, [])
        XCTAssertEqual(delays, [])
    }
}

private func makeActivityEvent(appBundleID: String) -> SafeActivityEvent {
    SafeActivityEvent(
        eventType: .activity,
        appBundleID: appBundleID,
        registeredDomain: nil,
        surfaceType: .application,
        transitionType: .appSwitch,
        observationState: .observed,
        inputOccurred: nil,
        occurredAt: .now,
        detectionLatencyMilliseconds: 0,
        protectedContext: false
    )
}

private struct SavedRecordSummary: Equatable {
    enum Kind: Equatable {
        case observation(bundleID: String?)
        case collectionState(state: CollectionStateChange.State, reason: String)
    }

    let sequence: Int
    let kind: Kind
}

private func drainRecords(
    from queue: EncryptedActivityQueue,
    accountID: UUID,
    deviceID: UUID
) async throws -> [SavedRecordSummary] {
    var records: [SavedRecordSummary] = []
    while let item = try await queue.first(accountID: accountID, deviceID: deviceID) {
        let kind: SavedRecordSummary.Kind
        switch item.record {
        case .observation(let observation):
            let bundleID: String?
            if case .detailed(let details) = observation.context,
               case .captured(let value) = details.app.bundleID {
                bundleID = value
            } else {
                bundleID = nil
            }
            kind = .observation(bundleID: bundleID)
        case .collectionStateChanged(let state):
            kind = .collectionState(state: state.state, reason: state.reason)
        }
        records.append(SavedRecordSummary(sequence: item.sequence, kind: kind))
        try await queue.acknowledge(
            accountID: accountID,
            deviceID: deviceID,
            sequence: item.sequence,
            eventID: item.eventID
        )
    }
    return records
}

private actor QueueTestClient: MosemoAPIClient {
    private var sentSequences: [Int] = []
    private var activeRequests = 0
    private var maximumRequests = 0
    private var firstError: MosemoAPIError?
    private var sentRecords: [ActivityRecord] = []
    private let mismatchedAcknowledgement: Bool

    init(firstError: MosemoAPIError? = nil, mismatchedAcknowledgement: Bool = false) {
        self.firstError = firstError
        self.mismatchedAcknowledgement = mismatchedAcknowledgement
    }

    nonisolated func makeKakaoLoginURL(codeChallenge: String) throws -> URL { fatalError("unused") }
    func authenticate(authorizationCode: String, codeVerifier: String) async throws -> Account { fatalError("unused") }
    func currentAccount() async throws -> Account { fatalError("unused") }
    func registerDevice(idempotencyKey: UUID) async throws -> Device { fatalError("unused") }
    func signOut() async throws { fatalError("unused") }
    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay { fatalError("unused") }

    func createActivity(_ record: ActivityRecord) async throws -> ActivityCreateResult {
        let metadata: ActivityRecordMetadata
        switch record {
        case .observation(let value): metadata = value.metadata
        case .collectionStateChanged(let value): metadata = value.metadata
        }
        sentSequences.append(metadata.sequence)
        sentRecords.append(record)
        activeRequests += 1
        maximumRequests = max(maximumRequests, activeRequests)
        try await Task.sleep(for: .milliseconds(20))
        activeRequests -= 1
        if let firstError {
            self.firstError = nil
            throw firstError
        }
        return ActivityCreateResult(eventID: mismatchedAcknowledgement ? UUID() : metadata.eventID,
                                    receivedAt: metadata.observedAt)
    }

    func sequences() -> [Int] { sentSequences }
    func maximumConcurrentRequests() -> Int { maximumRequests }
    func records() -> [ActivityRecord] { sentRecords }
}

private actor RetryWaitRecorder {
    private var values: [TimeInterval] = []
    func append(_ value: TimeInterval) { values.append(value) }
    func delays() -> [TimeInterval] { values }
}

private actor QueueTestDeviceStore: DeviceRegistrationStateStoring {
    private let deviceID: UUID
    init(deviceID: UUID) { self.deviceID = deviceID }
    func load(for accountID: UUID) async throws -> DeviceRegistrationState {
        DeviceRegistrationState(deviceID: deviceID)
    }
    func save(_ state: DeviceRegistrationState, for accountID: UUID) async throws {}
}

private actor QueueTestKeyStore: ActivityQueueKeyStoring {
    private let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    func loadOrCreateKey() async throws -> Data {
        if fails { throw MosemoAPIError.activityQueueStorageFailed }
        return Data(repeating: 9, count: 32)
    }
}

private actor ControllableQueueTestKeyStore: ActivityQueueKeyStoring {
    private var shouldDelayNextLoad = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var loads = 0

    func delayNextLoad() {
        shouldDelayNextLoad = true
    }

    func loadOrCreateKey() async -> Data {
        loads += 1
        if shouldDelayNextLoad {
            shouldDelayNextLoad = false
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        return Data(repeating: 9, count: 32)
    }

    func hasBlockedLoad() -> Bool { blockedContinuation != nil }
    func loadCount() -> Int { loads }

    func releaseBlockedLoad() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor FailingQueueTestKeyStore: ActivityQueueKeyStoring {
    private let failingLoad: Int
    private var loads = 0

    init(failingLoad: Int) {
        self.failingLoad = failingLoad
    }

    func loadOrCreateKey() throws -> Data {
        loads += 1
        if loads == failingLoad {
            throw MosemoAPIError.activityQueueStorageFailed
        }
        return Data(repeating: 9, count: 32)
    }

    func loadCount() -> Int { loads }
}
