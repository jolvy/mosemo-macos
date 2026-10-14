import Foundation

public struct ActivityBatch: Codable, Equatable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let deviceID: UUID
    public let items: [QueuedActivity]
    /// The exact uncompressed UTF-8 request, encrypted at rest before its first send.
    public let body: Data
}

public enum ActivityBatchPreparation: Equatable, Sendable {
    case empty
    case waiting(TimeInterval)
    case ready(ActivityBatch)
}

public enum ActivityBatchPolicy {
    public static let maximumCount = 200
    public static let maximumBytes = 512 * 1024
    public static let maximumWait: TimeInterval = 10

    public struct Selection: Sendable {
        public let batch: ActivityBatch
        public let isFull: Bool
    }

    /// Inputs must already be ordered within a single account/device. No clock or UUID generation here.
    public static func select(_ items: [QueuedActivity], batchID: UUID,
                              maximumCount: Int = maximumCount,
                              maximumBytes: Int = maximumBytes) throws -> Selection? {
        guard let first = items.first else { return nil }
        guard (1...Self.maximumCount).contains(maximumCount), (1...Self.maximumBytes).contains(maximumBytes) else {
            throw MosemoAPIError.validationFailed
        }
        var previous: Int?
        for item in items {
            try item.validateMetadata()
            guard item.accountID == first.accountID, item.deviceID == first.deviceID,
                  previous.map({ item.sequence > $0 }) ?? true else { throw MosemoAPIError.activityQueueStorageFailed }
            previous = item.sequence
        }
        let prefix = Data("{\"batchId\":\"\(batchID.uuidString)\",\"deviceId\":\"\(first.deviceID.uuidString)\",\"records\":[".utf8)
        let suffix = Data("]}".utf8)
        var body = prefix
        var selected: [QueuedActivity] = []
        var full = false
        for item in items.prefix(maximumCount) {
            let encoded = try recordBody(item.record)
            if body.count + (selected.isEmpty ? 0 : 1) + encoded.count + suffix.count > maximumBytes {
                guard !selected.isEmpty else { throw MosemoAPIError.activityBatchRecordTooLarge }
                full = true
                break
            }
            if !selected.isEmpty { body.append(0x2C) }
            body.append(encoded)
            selected.append(item)
        }
        body.append(suffix)
        return Selection(batch: ActivityBatch(id: batchID, accountID: first.accountID, deviceID: first.deviceID,
            items: selected, body: body), isFull: full || selected.count == maximumCount || body.count == maximumBytes)
    }

    private static func recordBody(_ record: ActivityRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(MosemoDateTranscoder().encode(date))
        }
        let payload = try ActivityRequestMapper.request(from: record).payload
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

extension QueuedActivity {
    func validateMetadata() throws {
        let metadata: ActivityRecordMetadata
        switch record {
        case .observation(let value): metadata = value.metadata
        case .collectionStateChanged(let value): metadata = value.metadata
        }
        guard metadata.deviceRegistrationID == deviceID, metadata.eventID == eventID,
              metadata.sequence == sequence else { throw MosemoAPIError.activityQueueStorageFailed }
    }
}

public enum ActivityBatchRetryPolicy {
    /// Zero-based failure count. Randomness and sleeping belong to the sending shell.
    public static func delay(attempt: Int, jitter: Double, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let cap = min(60, pow(2, Double(min(6, max(0, attempt)))))
        return max(max(0, retryAfter ?? 0), cap * min(1, max(0, jitter)))
    }
}
