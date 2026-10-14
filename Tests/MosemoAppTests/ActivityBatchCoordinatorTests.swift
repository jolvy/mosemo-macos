import Foundation
import SQLite3
import XCTest
@testable import MosemoAPI
@testable import MosemoApp

@MainActor
final class ActivityBatchCoordinatorTests: XCTestCase {
    func testFreshBatchWaitsTenSecondsThenSendsOriginalRecords() async throws {
        let fixture = try BatchFixture()
        defer { fixture.remove() }
        let clock = BatchTestClock()
        let sleeper = BatchSleepGate()
        let client = ControlledBatchClient(holds: false)
        _ = try await fixture.enqueue(at: clock.now())
        let coordinator = fixture.coordinator(client: client, clock: clock, sleeper: sleeper)
        await coordinator.activate(fixture.account)
        await eventually { await sleeper.count() == 1 }
        let sentBefore = await client.batches()
        XCTAssertTrue(sentBefore.isEmpty)
        let waits = await sleeper.delays()
        XCTAssertEqual(waits, [10])
        clock.advance(10)
        await sleeper.release()
        await eventually { (try? await fixture.queue.count()) == 0 }
        let sent = await client.batches()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.items.count, 1)
        await coordinator.activate(nil)
    }

    func testEnqueueReaching200WakesBatchWaitBeforeTenSeconds() async throws {
        let fixture = try BatchFixture()
        defer { fixture.remove() }
        let clock = BatchTestClock()
        let sleeper = BatchSleepGate()
        let client = ControlledBatchClient(holds: true)
        for _ in 0..<199 { _ = try await fixture.enqueue(at: clock.now()) }
        let coordinator = fixture.coordinator(client: client, clock: clock, sleeper: sleeper)
        await coordinator.activate(fixture.account)
        await eventually { await sleeper.count() == 1 }
        coordinator.recordCollectionState(.active, reason: "count-threshold")
        await eventually { await client.batches().count == 1 }
        let sent = await client.batches()
        XCTAssertEqual(sent.first?.items.count, 200)
        await client.release()
        await eventually { (try? await fixture.queue.count()) == 0 }
        await coordinator.activate(nil)
    }

    func testLateOldAccountResponseCannotACKOrOverlapNewAccountRequest() async throws {
        for oldError in [nil, MosemoAPIError.authenticationRequired] {
            let fixture = try BatchFixture()
            defer { fixture.remove() }
            let clock = BatchTestClock()
            let sleeper = BatchSleepGate()
            let client = ControlledBatchClient(holds: true)
            _ = try await fixture.enqueue(at: clock.now().addingTimeInterval(-20))
            let other = Account(id: UUID(), provider: .kakao, createdAt: .now, lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
            _ = try await fixture.enqueue(accountID: other.id, at: clock.now().addingTimeInterval(-20))
            var authFailures: [UUID] = []
            let coordinator = fixture.coordinator(client: client, clock: clock, sleeper: sleeper, auth: { authFailures.append($0) })
            await coordinator.activate(fixture.account)
            await eventually { await client.batches().count == 1 }
            await coordinator.activate(other)
            for _ in 0..<100 { await Task.yield() }
            let before = await client.batches()
            XCTAssertEqual(before.count, 1)
            await client.release(error: oldError)
            await eventually { await client.batches().count == 2 }
            let oldCount = try await fixture.queue.count(accountID: fixture.account.id)
            XCTAssertEqual(oldCount, 1)
            XCTAssertTrue(authFailures.isEmpty)
            await client.release()
            await eventually { (try? await fixture.queue.count(accountID: other.id)) == 0 }
            let maximum = await client.maximum()
            XCTAssertEqual(maximum, 1)
            await coordinator.activate(nil)
        }
    }

    func testResponseLossAndNewEnqueueRetryIdenticalIDAndBodyThenDrainBacklog() async throws {
        let fixture = try BatchFixture()
        defer { fixture.remove() }
        let clock = BatchTestClock()
        let sleeper = BatchSleepGate()
        let client = ControlledBatchClient(holds: true)
        let first = try await fixture.enqueue(at: clock.now().addingTimeInterval(-20))
        let coordinator = fixture.coordinator(client: client, clock: clock, sleeper: sleeper)
        await coordinator.activate(fixture.account)
        await eventually { await client.batches().count == 1 }
        _ = try await fixture.enqueue(at: clock.now())
        await client.release(error: .networkUnavailable)
        await eventually { await sleeper.count() == 1 }
        await sleeper.release()
        await eventually { await client.batches().count == 2 }
        let attempts = await client.batches()
        XCTAssertEqual(attempts[0], attempts[1])
        XCTAssertEqual(attempts[1].items, [first])
        await client.release()
        await eventually { await client.batches().count == 3 }
        let backlog = await client.batches()
        XCTAssertEqual(backlog[2].items.map(\.sequence), [2])
        await client.release()
        await eventually { (try? await fixture.queue.count()) == 0 }
        await coordinator.activate(nil)
    }

    func testACKDatabaseFailurePreservesSameBatchForRetry() async throws {
        let fixture = try BatchFixture()
        defer { fixture.remove() }
        let clock = BatchTestClock()
        let sleeper = BatchSleepGate()
        let client = ControlledBatchClient(holds: false)
        _ = try await fixture.enqueue(at: clock.now().addingTimeInterval(-20))
        try fixture.sql("CREATE TRIGGER fail_ack BEFORE DELETE ON activity_queue_records BEGIN SELECT RAISE(ABORT,'test failure'); END")
        var accepted = 0
        let coordinator = fixture.coordinator(client: client, clock: clock, sleeper: sleeper, accepted: { _ in accepted += 1 })
        await coordinator.activate(fixture.account)
        await eventually { await sleeper.count() == 1 }
        XCTAssertEqual(accepted, 0)
        let count = try await fixture.queue.count()
        XCTAssertEqual(count, 1)
        try fixture.sql("DROP TRIGGER fail_ack")
        await sleeper.release()
        await eventually { (try? await fixture.queue.count()) == 0 }
        let attempts = await client.batches()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], attempts[1])
        XCTAssertEqual(accepted, 1)
        await coordinator.activate(nil)
    }

    func testExplicit413RepackagesWithNewIDAndNoRawMutation() async throws {
        let fixture = try BatchFixture()
        defer { fixture.remove() }
        let clock = BatchTestClock()
        let sleeper = BatchSleepGate()
        let client = ControlledBatchClient(holds: true)
        var originals: [QueuedActivity] = []
        for _ in 0..<4 { originals.append(try await fixture.enqueue(at: clock.now().addingTimeInterval(-20))) }
        let coordinator = fixture.coordinator(client: client, clock: clock, sleeper: sleeper)
        await coordinator.activate(fixture.account)
        await eventually { await client.batches().count == 1 }
        await client.release(error: .activityBatchRejectedTooLarge)
        await eventually { await client.batches().count == 2 }
        var batches = await client.batches()
        XCTAssertNotEqual(batches[0].id, batches[1].id)
        XCTAssertEqual(batches[1].items, Array(originals.prefix(2)))
        await client.release()
        await eventually { await client.batches().count == 3 }
        batches = await client.batches()
        XCTAssertEqual(batches[2].items, Array(originals.suffix(2)))
        await client.release()
        await eventually { (try? await fixture.queue.count()) == 0 }
        await coordinator.activate(nil)
    }

    private func eventually(_ condition: () async -> Bool) async {
        for _ in 0..<3_000 { if await condition() { return }; await Task.yield() }
        XCTFail("Controlled operation did not finish")
    }
}

private struct BatchFixture {
    let directory: URL
    let queue: EncryptedActivityQueue
    let account = Account(id: UUID(), provider: .kakao, createdAt: .now, lastAuthenticatedAt: .now, timeZoneID: "Asia/Seoul")
    let device = UUID()
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: CoordinatorBatchKey())
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func enqueue(accountID: UUID? = nil, at now: Date) async throws -> QueuedActivity {
        try await queue.enqueue(accountID: accountID ?? account.id, deviceID: device, observedAt: now,
            timezoneID: "Asia/Seoul", utcOffsetMinutes: 540, enqueuedAt: now) { .observation(.init(metadata: $0, context: .opaque)) }
    }
    func sql(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("queue.sqlite").path, &database) == SQLITE_OK else { throw MosemoAPIError.activityQueueStorageFailed }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw MosemoAPIError.activityQueueStorageFailed }
    }
    @MainActor func coordinator(client: ControlledBatchClient, clock: BatchTestClock, sleeper: BatchSleepGate,
                               auth: @escaping @MainActor (UUID) -> Void = { _ in },
                               accepted: @escaping @MainActor (UUID) -> Void = { _ in }) -> OfflineActivityCoordinator {
        OfflineActivityCoordinator(queue: queue, client: client, deviceStateStore: CoordinatorBatchDevice(device: device),
            batchClock: { clock.now() }, sleepBeforeBatch: { await sleeper.wait($0) },
            sleepBeforeRetry: { await sleeper.wait($0) }, retryJitter: { 1 },
            onAuthenticationFailure: auth, onActivityAccepted: accepted, onStatus: { _, _ in })
    }
}
private final class BatchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}
private actor BatchSleepGate {
    private var values: [Double] = []
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    func count() -> Int { values.count }
    func delays() -> [Double] { values }
    func wait(_ seconds: Double) async {
        let id = UUID()
        values.append(seconds)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { continuations[id] = continuation }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { continuations.removeValue(forKey: id)?.resume() }
    func release() {
        guard let id = continuations.keys.first else { return }
        continuations.removeValue(forKey: id)?.resume()
    }
}
private struct CoordinatorBatchKey: ActivityQueueKeyStoring { func loadOrCreateKey() async throws -> Data { Data(repeating: 6, count: 32) } }
private struct CoordinatorBatchDevice: DeviceRegistrationStateStoring {
    let device: UUID
    func load(for accountID: UUID) async throws -> DeviceRegistrationState { .init(deviceID: device) }
    func save(_ state: DeviceRegistrationState, for accountID: UUID) async throws {}
}
private actor ControlledBatchClient: MosemoAPIClient {
    let holds: Bool
    private var sent: [ActivityBatch] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var active = 0
    private var peak = 0
    init(holds: Bool) { self.holds = holds }
    func batches() -> [ActivityBatch] { sent }
    func maximum() -> Int { peak }
    func release(error: MosemoAPIError? = nil) {
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
    func createActivityBatch(_ batch: ActivityBatch) async throws -> ActivityBatchResult {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        sent.append(batch)
        if holds { try await withCheckedThrowingContinuation { continuation = $0 } }
        return .init(batchID: batch.id)
    }
    nonisolated func makeKakaoLoginURL(codeChallenge: String) throws -> URL { fatalError("unused") }
    func authenticate(authorizationCode: String, codeVerifier: String) async throws -> Account { fatalError("unused") }
    func currentAccount() async throws -> Account { fatalError("unused") }
    func registerDevice(idempotencyKey: UUID) async throws -> Device { fatalError("unused") }
    func signOut() async throws {}
    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay { fatalError("unused") }
}
