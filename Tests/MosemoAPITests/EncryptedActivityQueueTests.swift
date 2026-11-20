import Foundation
import XCTest
@testable import MosemoAPI

final class EncryptedActivityQueueTests: XCTestCase {
    func testPrivacyFilterUsesUTF8LimitsAndRedactsEmbeddedContentURLs() {
        XCTAssertEqual(ActivityPrivacyFilter.url("data:text/plain,secret"), .redacted(reason: "embedded_content_scheme"))
        let urlPrefix = "https://e/"
        let maximumURL = urlPrefix + String(repeating: "a", count: ActivityPrivacyFilter.maximumURLBytes - urlPrefix.utf8.count)
        XCTAssertEqual(ActivityPrivacyFilter.url(maximumURL), .captured(maximumURL))
        XCTAssertEqual(ActivityPrivacyFilter.url(maximumURL + "a"), .redacted(reason: "length_exceeded"))
        XCTAssertEqual(ActivityPrivacyFilter.url("https://example.test/?token=a#part"), .captured("https://example.test/?token=a#part"))
        let maximumTitle = String(repeating: "a", count: ActivityPrivacyFilter.maximumTitleBytes)
        XCTAssertFalse(ActivityPrivacyFilter.title(maximumTitle).truncated)
        let title = ActivityPrivacyFilter.title(String(repeating: "한", count: 1_367))
        XCTAssertEqual(title.value.utf8.count, 4_095)
        XCTAssertTrue(title.truncated)
        XCTAssertEqual(title.originalByteLength, 4_101)
        let emojiTitle = ActivityPrivacyFilter.title(String(repeating: "😀", count: 1_025))
        XCTAssertEqual(emojiTitle.value, String(repeating: "😀", count: 1_024))
        XCTAssertEqual(emojiTitle.originalByteLength, 4_100)
        XCTAssertTrue(emojiTitle.truncated)
    }

    func testEncryptedQueueRestoresFIFOAndDoesNotReuseAcknowledgedSequence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("queue.sqlite")
        let keyStore = TestActivityQueueKeyStore()
        let accountID = UUID()
        let deviceID = UUID()
        let firstQueue = try EncryptedActivityQueue(databaseURL: databaseURL, keyStore: keyStore)

        let first = try await enqueue(firstQueue, accountID: accountID, deviceID: deviceID, reason: "first")
        let second = try await enqueue(firstQueue, accountID: accountID, deviceID: deviceID, reason: "second")
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
        let firstRestored = try await firstQueue.first(accountID: accountID, deviceID: deviceID)
        XCTAssertEqual(first, firstRestored)

        let reopened = try EncryptedActivityQueue(databaseURL: databaseURL, keyStore: keyStore)
        try await reopened.acknowledge(accountID: accountID, deviceID: deviceID, sequence: 1, eventID: first.eventID)
        let secondRestored = try await reopened.first(accountID: accountID, deviceID: deviceID)
        XCTAssertEqual(second, secondRestored)
        let third = try await enqueue(reopened, accountID: accountID, deviceID: deviceID, reason: "third")
        XCTAssertEqual(third.sequence, 3)
        let count = try await reopened.count(accountID: accountID)
        XCTAssertEqual(count, 2)
    }

    func testQueueSeparatesAccountsAndRejectsWrongKeyWithoutDeletingRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("queue.sqlite")
        let accountID = UUID()
        let deviceID = UUID()
        let keyStore = TestActivityQueueKeyStore(key: Data(repeating: 1, count: 32))
        let queue = try EncryptedActivityQueue(databaseURL: databaseURL, keyStore: keyStore)
        _ = try await enqueue(queue, accountID: accountID, deviceID: deviceID, reason: "private-body-marker")
        let databaseBytes = try Data(contentsOf: databaseURL)
        XCTAssertNil(databaseBytes.range(of: Data("private-body-marker".utf8)))
        let otherAccount = try await queue.first(accountID: UUID(), deviceID: deviceID)
        XCTAssertNil(otherAccount)

        let wrongKeyQueue = try EncryptedActivityQueue(
            databaseURL: databaseURL,
            keyStore: TestActivityQueueKeyStore(key: Data(repeating: 2, count: 32))
        )
        do {
            _ = try await wrongKeyQueue.first(accountID: accountID, deviceID: deviceID)
            XCTFail("Expected an unreadable encrypted record")
        } catch {
            XCTAssertEqual(error as? MosemoAPIError, .activityQueueStorageFailed)
        }
        let count = try await queue.count(accountID: accountID)
        XCTAssertEqual(count, 1)
    }

    func testKeyFailureDoesNotConsumeSequence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"), keyStore: TestActivityQueueKeyStore(fails: true))
        do {
            _ = try await enqueue(queue, accountID: UUID(), deviceID: UUID(), reason: "no save")
            XCTFail("Expected key storage failure")
        } catch {
            XCTAssertEqual(error as? MosemoAPIError, .activityQueueStorageFailed)
        }
    }

    // AC-M1
    func testPrepareBatchDropsRecordsOlderThan24HoursAndFutureRecords() async throws {
        let (queue, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = UUID(), deviceID = UUID()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await enqueue(queue, accountID: accountID, deviceID: deviceID, reason: "stale", observedAt: now.addingTimeInterval(-25 * 3_600))
        let kept = try await enqueue(queue, accountID: accountID, deviceID: deviceID, reason: "kept", observedAt: now.addingTimeInterval(-3_600))
        _ = try await enqueue(queue, accountID: accountID, deviceID: deviceID, reason: "future", observedAt: now.addingTimeInterval(1))

        let prepared = try await queue.prepareBatch(accountID: accountID, deviceID: deviceID, batchID: UUID(), now: now, drainBacklog: true)

        guard case .ready(let batch) = prepared else { return XCTFail("Expected a ready batch, got \(prepared)") }
        XCTAssertEqual(batch.items, [kept])
        let count = try await queue.count(accountID: accountID)
        XCTAssertEqual(count, 1)
    }

    // AC-M2
    func testAcceptanceWindowLowerBoundIsInclusive() async throws {
        let (queue, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = UUID(), deviceID = UUID()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await enqueue(queue, accountID: accountID, deviceID: deviceID, reason: "just-outside",
                              observedAt: now.addingTimeInterval(-24 * 3_600 - 0.001))
        let boundary = try await enqueue(queue, accountID: accountID, deviceID: deviceID, reason: "boundary",
                                         observedAt: now.addingTimeInterval(-24 * 3_600))
        let atNow = try await enqueue(queue, accountID: accountID, deviceID: deviceID, reason: "now", observedAt: now)

        let prepared = try await queue.prepareBatch(accountID: accountID, deviceID: deviceID, batchID: UUID(), now: now, drainBacklog: true)

        guard case .ready(let batch) = prepared else { return XCTFail("Expected a ready batch, got \(prepared)") }
        XCTAssertEqual(batch.items, [boundary, atNow])
    }

    // AC-M3
    func testStoredBatchWithExpiredRecordIsReplacedByNewBatchIDWithRemainingRecords() async throws {
        let (queue, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = UUID(), deviceID = UUID()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await enqueue(queue, accountID: accountID, deviceID: deviceID, reason: "first", observedAt: start)
        let second = try await enqueue(queue, accountID: accountID, deviceID: deviceID, reason: "second",
                                       observedAt: start.addingTimeInterval(2 * 3_600))
        let originalID = UUID()
        let stored = try await queue.prepareBatch(accountID: accountID, deviceID: deviceID, batchID: originalID, now: start.addingTimeInterval(3 * 3_600))
        guard case .ready(let original) = stored else { return XCTFail("Expected a stored batch, got \(stored)") }
        XCTAssertEqual(original.items.count, 2)

        let later = start.addingTimeInterval(25 * 3_600)
        let unchanged = try await queue.prepareBatch(accountID: accountID, deviceID: deviceID, batchID: UUID(), now: start.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(unchanged, .ready(original))
        let replacementID = UUID()
        let prepared = try await queue.prepareBatch(accountID: accountID, deviceID: deviceID, batchID: replacementID, now: later)

        guard case .ready(let replacement) = prepared else { return XCTFail("Expected a replacement batch, got \(prepared)") }
        XCTAssertEqual(replacement.id, replacementID)
        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertEqual(replacement.items, [second])
        let restored = try await queue.prepareBatch(accountID: accountID, deviceID: deviceID, batchID: UUID(), now: later)
        XCTAssertEqual(restored, .ready(replacement))
    }

    func testRejectedIndicesAreDroppedAndPendingBatchIsCleared() async throws {
        let (queue, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountID = UUID(), deviceID = UUID()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var items: [QueuedActivity] = []
        for reason in ["a", "b", "c"] {
            items.append(try await enqueue(queue, accountID: accountID, deviceID: deviceID, reason: reason, observedAt: now))
        }
        let prepared = try await queue.prepareBatch(accountID: accountID, deviceID: deviceID, batchID: UUID(), now: now, drainBacklog: true)
        guard case .ready(let batch) = prepared else { return XCTFail("Expected a ready batch, got \(prepared)") }

        for invalid in [[], [3], [-1]] {
            do {
                try await queue.dropRecordsOutsideAcceptanceWindow(batch, indices: invalid)
                XCTFail("Expected invalid indices \(invalid) to keep the batch")
            } catch {
                XCTAssertEqual(error as? MosemoAPIError, .activityQueueStorageFailed)
            }
        }
        let untouched = try await queue.count(accountID: accountID)
        XCTAssertEqual(untouched, 3)

        try await queue.dropRecordsOutsideAcceptanceWindow(batch, indices: [1])
        let next = try await queue.prepareBatch(accountID: accountID, deviceID: deviceID, batchID: UUID(), now: now, drainBacklog: true)
        guard case .ready(let remaining) = next else { return XCTFail("Expected a new batch, got \(next)") }
        XCTAssertNotEqual(remaining.id, batch.id)
        XCTAssertEqual(remaining.items, [items[0], items[2]])
    }

    private func makeQueue() throws -> (EncryptedActivityQueue, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try EncryptedActivityQueue(databaseURL: directory.appendingPathComponent("queue.sqlite"),
                                           keyStore: TestActivityQueueKeyStore()), directory)
    }

    private func enqueue(_ queue: EncryptedActivityQueue, accountID: UUID, deviceID: UUID, reason: String,
                         observedAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) async throws -> QueuedActivity {
        try await queue.enqueue(accountID: accountID, deviceID: deviceID, observedAt: observedAt,
                                timezoneID: "Asia/Seoul", utcOffsetMinutes: 540, enqueuedAt: observedAt) { metadata in
            .collectionStateChanged(CollectionStateChange(metadata: metadata, state: .active, reason: reason))
        }
    }
}

private actor TestActivityQueueKeyStore: ActivityQueueKeyStoring {
    private let key: Data
    private let fails: Bool
    init(key: Data = Data(repeating: 7, count: 32), fails: Bool = false) { self.key = key; self.fails = fails }
    func loadOrCreateKey() throws -> Data {
        if fails { throw MosemoAPIError.activityQueueStorageFailed }
        return key
    }
}
