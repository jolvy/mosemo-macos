import CryptoKit
import Foundation
import XCTest
import SQLite3
@testable import MosemoAPI

final class ActivityBatchTests: XCTestCase {
    private let account = UUID()
    private let device = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPureSelectionCountsActualUTF8EnvelopeAndPreservesOriginals() throws {
        let items = (1...201).map { item($0, reason: "한글😀") }
        let id = UUID()
        let selection = try ActivityBatchPolicy.select(items, batchID: id)
        XCTAssertEqual(selection?.batch.items, Array(items.prefix(200)))
        XCTAssertEqual(selection?.isFull, true)
        let body = try XCTUnwrap(selection?.batch.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["accountId"])
        XCTAssertEqual(json["deviceId"] as? String, device.uuidString)
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 200)
        XCTAssertNil(records[0]["deviceId"])
        XCTAssertEqual(records[0]["reason"] as? String, "한글😀")
        XCTAssertEqual(records[0]["sequence"] as? Int, 1)
        let exact = try XCTUnwrap(ActivityBatchPolicy.select(Array(items.prefix(2)), batchID: id))
        let limited = try XCTUnwrap(ActivityBatchPolicy.select(items, batchID: id, maximumBytes: exact.batch.body.count))
        XCTAssertEqual(limited.batch.items.count, 2)
        XCTAssertEqual(limited.batch.body.count, exact.batch.body.count)
        XCTAssertThrowsError(try ActivityBatchPolicy.select(items, batchID: id, maximumBytes: 1))
        XCTAssertThrowsError(try ActivityBatchPolicy.select([items[1], items[0]], batchID: id))
        XCTAssertThrowsError(try ActivityBatchPolicy.select([items[0], item(2, accountID: UUID())], batchID: id))
    }

    func testEncryptedBatchSurvivesRestartAndNewEnqueueAndACKIsScoped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.sqlite")
        let queue = try EncryptedActivityQueue(databaseURL: url, keyStore: BatchKey())
        let first = try await enqueue(queue)
        let id = UUID()
        let initial = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: id, now: now)
        guard case .waiting(let delay) = initial else { return XCTFail("Expected batching delay") }
        XCTAssertEqual(delay, 10)
        let prepared = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: id, now: now.addingTimeInterval(10))
        guard case .ready(let batch) = prepared else { return XCTFail("Expected durable batch") }
        _ = try await enqueue(queue)
        let other = UUID()
        _ = try await enqueue(queue, accountID: other)
        let reopened = try EncryptedActivityQueue(databaseURL: url, keyStore: BatchKey())
        let restored = try await reopened.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: now)
        XCTAssertEqual(restored, .ready(batch))
        XCTAssertEqual(batch.items, [first])
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("batch-private-marker".utf8)))
        do {
            try await reopened.acknowledgeBatch(batchID: UUID(), accountID: account, deviceID: device, eventIDs: [first.eventID])
            XCTFail("Wrong batch must not ACK")
        } catch {}
        let before = try await reopened.count()
        XCTAssertEqual(before, 3)
        try await reopened.acknowledgeBatch(batchID: id, accountID: account, deviceID: device, eventIDs: [first.eventID])
        let after = try await reopened.count()
        XCTAssertEqual(after, 2)
        let otherCount = try await reopened.count(accountID: other)
        XCTAssertEqual(otherCount, 1)
    }

    func testACKFailureRollsBackAllDeletesAndKeepsExactBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.sqlite")
        let queue = try EncryptedActivityQueue(databaseURL: url, keyStore: BatchKey())
        _ = try await enqueue(queue)
        _ = try await enqueue(queue)
        let id = UUID()
        let prepared = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: id, now: now, drainBacklog: true)
        guard case .ready(let batch) = prepared else { return XCTFail("Expected batch") }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER fail_ack BEFORE DELETE ON activity_queue_records WHEN OLD.sequence=2 BEGIN SELECT RAISE(ABORT,'test failure'); END", nil, nil, nil), SQLITE_OK)
        do {
            try await queue.acknowledgeBatch(batchID: id, accountID: account, deviceID: device, eventIDs: batch.items.map(\.eventID))
            XCTFail("Expected failed transaction")
        } catch {}
        let count = try await queue.count()
        XCTAssertEqual(count, 2)
        let retry = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: now)
        XCTAssertEqual(retry, .ready(batch))
    }

    func testExplicit413SplitsWithNewIDAndKeepsAllOriginalRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: BatchKey())
        for _ in 0..<4 { _ = try await enqueue(queue) }
        let prepared = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: now, drainBacklog: true)
        guard case .ready(let batch) = prepared else { return XCTFail("Expected batch") }
        _ = try await enqueue(queue)
        let split = try await queue.splitRejectedBatch(batch, newBatchID: UUID())
        XCTAssertNotEqual(split.id, batch.id)
        XCTAssertEqual(split.items, Array(batch.items.prefix(2)))
        let count = try await queue.count()
        XCTAssertEqual(count, 5)
        try await queue.acknowledgeBatch(batchID: split.id, accountID: account, deviceID: device, eventIDs: split.items.map(\.eventID))
        let next = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: now, drainBacklog: true)
        guard case .ready(let backlog) = next else { return XCTFail("Backlog should not wait again") }
        XCTAssertEqual(Array(backlog.items.prefix(2)), Array(batch.items.suffix(2)))
    }

    func testOldAuthorizationCannotACKAfterLogoutOrNewSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: BatchKey())
        _ = try await enqueue(queue)
        let prepared = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: now, drainBacklog: true)
        guard case .ready(let batch) = prepared else { return XCTFail("Expected batch") }
        let oldAuthorization = UUID()
        await queue.authorizeBatchAcknowledgements(oldAuthorization)
        await queue.authorizeBatchAcknowledgements(UUID())
        do {
            try await queue.acknowledgeBatch(batchID: batch.id, accountID: account, deviceID: device,
                eventIDs: batch.items.map(\.eventID), authorizationID: oldAuthorization)
            XCTFail("Stale auth response must not delete")
        } catch { XCTAssertEqual(error as? MosemoAPIError, .authenticationRequired) }
        let count = try await queue.count()
        XCTAssertEqual(count, 1)
    }

    func testFullJitterCapsAndRetryAfter() {
        let caps: [Double] = [1, 2, 4, 8, 16, 32, 60, 60]
        for (index, cap) in caps.enumerated() {
            XCTAssertEqual(ActivityBatchRetryPolicy.delay(attempt: index, jitter: 0), 0)
            XCTAssertEqual(ActivityBatchRetryPolicy.delay(attempt: index, jitter: 1), cap)
            XCTAssertEqual(ActivityBatchRetryPolicy.delay(attempt: index, jitter: 0.25), cap * 0.25)
        }
        XCTAssertEqual(ActivityBatchRetryPolicy.delay(attempt: 0, jitter: 0, retryAfter: 20), 20)
    }

    func testCountLimitSendsImmediatelyAndRemainingBacklogDoesNotWait() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: BatchKey())
        var items: [QueuedActivity] = []
        for _ in 0..<201 { items.append(try await enqueue(queue)) }
        let prepared = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: now)
        guard case .ready(let batch) = prepared else { return XCTFail("Count threshold must not wait") }
        XCTAssertEqual(batch.items, Array(items.prefix(200)))
        try await queue.acknowledgeBatch(batchID: batch.id, accountID: account, deviceID: device, eventIDs: batch.items.map(\.eventID))
        let next = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: now, drainBacklog: true)
        guard case .ready(let backlog) = next else { return XCTFail("Backlog must drain immediately") }
        XCTAssertEqual(backlog.items, [items[200]])
    }

    func testMetadataMismatchDoesNotSaveOrConsumeSequence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: BatchKey())
        let incorrect = item(99)
        do {
            _ = try await queue.enqueue(accountID: account, deviceID: device, observedAt: now,
                timezoneID: "Asia/Seoul", utcOffsetMinutes: 540) { _ in incorrect.record }
            XCTFail("Metadata must match authenticated local columns")
        } catch { XCTAssertEqual(error as? MosemoAPIError, .activityQueueStorageFailed) }
        let saved = try await enqueue(queue)
        XCTAssertEqual(saved.sequence, 1)
    }

    func testLegacyEncryptedRowsMigrateWithoutReencodingAndKeepSequence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("queue.sqlite")
        let original = item(7, reason: "legacy-original")
        let aad = Data("\(account.uuidString):\(device.uuidString):7:\(original.eventID.uuidString)".utf8)
        let box = try AES.GCM.seal(JSONEncoder().encode(original.record), using: SymmetricKey(data: Data(repeating: 4, count: 32)), authenticating: aad)
        func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
        let nonce = box.nonce.withUnsafeBytes { Data($0) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let sql = """
            CREATE TABLE activity_queue_next(account_id TEXT NOT NULL,device_id TEXT NOT NULL,next_sequence INTEGER NOT NULL,PRIMARY KEY(account_id,device_id));
            CREATE TABLE activity_queue_records(account_id TEXT NOT NULL,device_id TEXT NOT NULL,sequence INTEGER NOT NULL,event_id TEXT NOT NULL,nonce BLOB NOT NULL,ciphertext BLOB NOT NULL,tag BLOB NOT NULL,PRIMARY KEY(account_id,device_id,sequence),UNIQUE(account_id,device_id,event_id));
            INSERT INTO activity_queue_next VALUES('\(account)','\(device)',8);
            INSERT INTO activity_queue_records VALUES('\(account)','\(device)',7,'\(original.eventID)',X'\(hex(nonce))',X'\(hex(box.ciphertext))',X'\(hex(box.tag))');
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let migrated = try EncryptedActivityQueue(databaseURL: url, keyStore: BatchKey())
        let first = try await migrated.first(accountID: account, deviceID: device)
        XCTAssertEqual(first, original)
        let prepared = try await migrated.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: now)
        guard case .ready(let batch) = prepared else { return XCTFail("Legacy backlog must be immediately eligible") }
        XCTAssertEqual(batch.items, [original])
        let next = try await enqueue(migrated)
        XCTAssertEqual(next.sequence, 8)
    }

    func testActual512KiBUTF8LimitAndOversizedRawRemainIntact() async throws {
        let reason = String(repeating: "한", count: 30_000)
        let selected = try XCTUnwrap(ActivityBatchPolicy.select((1...10).map { item($0, reason: reason) }, batchID: UUID()))
        XCTAssertEqual(selected.batch.items.count, 5)
        XCTAssertTrue(selected.isFull)
        XCTAssertLessThanOrEqual(selected.batch.body.count, 512 * 1024)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: BatchKey())
        let oversized = String(repeating: "한", count: 180_000)
        let original = try await queue.enqueue(accountID: account, deviceID: device, observedAt: now,
            timezoneID: "Asia/Seoul", utcOffsetMinutes: 540) { .collectionStateChanged(.init(metadata: $0, state: .active, reason: oversized)) }
        do {
            _ = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: now, drainBacklog: true)
            XCTFail("Oversized single must require action")
        } catch { XCTAssertEqual(error as? MosemoAPIError, .activityBatchRecordTooLarge) }
        let count = try await queue.count()
        let retained = try await queue.first(accountID: account, deviceID: device)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(retained, original)
    }

    func testAtomicACKCannotRemoveOtherDeviceOrAccount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: BatchKey())
        let target = try await enqueue(queue)
        let otherAccount = UUID(), otherDevice = UUID()
        _ = try await enqueue(queue, accountID: otherAccount)
        _ = try await queue.enqueue(accountID: account, deviceID: otherDevice, observedAt: now,
            timezoneID: "Asia/Seoul", utcOffsetMinutes: 540) { .observation(.init(metadata: $0, context: .opaque)) }
        let prepared = try await queue.prepareBatch(accountID: account, deviceID: device, batchID: UUID(), now: now, drainBacklog: true)
        guard case .ready(let batch) = prepared else { return XCTFail("Expected target scope") }
        XCTAssertEqual(batch.items, [target])
        try await queue.acknowledgeBatch(batchID: batch.id, accountID: account, deviceID: device, eventIDs: [target.eventID])
        let count = try await queue.count()
        let otherAccountHead = try await queue.first(accountID: otherAccount, deviceID: device)
        let otherDeviceHead = try await queue.first(accountID: account, deviceID: otherDevice)
        XCTAssertEqual(count, 2)
        XCTAssertNotNil(otherAccountHead)
        XCTAssertNotNil(otherDeviceHead)
    }

    private func item(_ sequence: Int, reason: String = "test", accountID: UUID? = nil) -> QueuedActivity {
        let event = UUID()
        let metadata = ActivityRecordMetadata(deviceRegistrationID: device, eventID: event, sequence: sequence,
            observedAt: now, timezoneID: "Asia/Seoul", utcOffsetMinutes: 540)
        return QueuedActivity(accountID: accountID ?? account, deviceID: device, sequence: sequence,
            eventID: event, record: .collectionStateChanged(.init(metadata: metadata, state: .active, reason: reason)))
    }

    private func enqueue(_ queue: EncryptedActivityQueue, accountID: UUID? = nil) async throws -> QueuedActivity {
        try await queue.enqueue(accountID: accountID ?? account, deviceID: device, observedAt: now,
            timezoneID: "Asia/Seoul", utcOffsetMinutes: 540, enqueuedAt: now) {
                .collectionStateChanged(.init(metadata: $0, state: .active, reason: "batch-private-marker"))
            }
    }
}

private struct BatchKey: ActivityQueueKeyStoring {
    func loadOrCreateKey() async throws -> Data { Data(repeating: 4, count: 32) }
}
