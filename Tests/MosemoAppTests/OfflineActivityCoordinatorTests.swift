import CollectorCore
import Foundation
import XCTest
@testable import MosemoAPI
@testable import MosemoApp

@MainActor
final class OfflineActivityCoordinatorTests: XCTestCase {
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
        let coordinator = OfflineActivityCoordinator(queue: queue, client: QueueTestClient(),
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
