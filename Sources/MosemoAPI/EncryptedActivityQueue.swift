import CryptoKit
import Foundation
import Security
import SQLite3

public struct QueuedActivity: Codable, Equatable, Sendable {
    public let accountID: UUID
    public let deviceID: UUID
    public let sequence: Int
    public let eventID: UUID
    public let record: ActivityRecord

    public init(accountID: UUID, deviceID: UUID, sequence: Int, eventID: UUID, record: ActivityRecord) {
        self.accountID = accountID
        self.deviceID = deviceID
        self.sequence = sequence
        self.eventID = eventID
        self.record = record
    }
}

public protocol ActivityQueueKeyStoring: Sendable {
    func loadOrCreateKey() async throws -> Data
}

public actor KeychainActivityQueueKeyStore: ActivityQueueKeyStoring {
    private let service: String
    private let account: String

    public init(service: String = "io.mosemo.app.activity-queue", account: String = "encryption-key") {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let key = result as? Data, key.count == 32 { return key }
        guard status == errSecItemNotFound else { throw MosemoAPIError.activityQueueStorageFailed }

        var key = Data(count: 32)
        guard key.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
            throw MosemoAPIError.activityQueueStorageFailed
        }
        var item = query
        item.removeValue(forKey: kSecReturnData as String)
        item.removeValue(forKey: kSecMatchLimit as String)
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess { return key }
        if addStatus == errSecDuplicateItem { return try loadOrCreateKey() }
        throw MosemoAPIError.activityQueueStorageFailed
    }
}

public actor EncryptedActivityQueue {
    private let database: ActivityQueueDatabase
    private let keyStore: any ActivityQueueKeyStoring

    public init(databaseURL: URL, keyStore: any ActivityQueueKeyStoring = KeychainActivityQueueKeyStore()) throws {
        database = try ActivityQueueDatabase(url: databaseURL)
        self.keyStore = keyStore
    }

    @discardableResult
    public func enqueue(
        accountID: UUID,
        deviceID: UUID,
        observedAt: Date,
        timezoneID: String,
        utcOffsetMinutes: Int,
        makeRecord: @Sendable (ActivityRecordMetadata) -> ActivityRecord
    ) async throws -> QueuedActivity {
        let key = try await keyStore.loadOrCreateKey()
        guard key.count == 32 else { throw MosemoAPIError.activityQueueStorageFailed }
        return try database.enqueue(accountID: accountID, deviceID: deviceID, observedAt: observedAt,
                                    timezoneID: timezoneID, utcOffsetMinutes: utcOffsetMinutes,
                                    key: key, makeRecord: makeRecord)
    }

    public func first(accountID: UUID, deviceID: UUID) async throws -> QueuedActivity? {
        let key = try await keyStore.loadOrCreateKey()
        return try database.first(accountID: accountID, deviceID: deviceID, key: key)
    }

    public func count(accountID: UUID? = nil) throws -> Int {
        try database.count(accountID: accountID)
    }

    public func acknowledge(accountID: UUID, deviceID: UUID, sequence: Int, eventID: UUID) throws {
        try database.acknowledge(accountID: accountID, deviceID: deviceID, sequence: sequence, eventID: eventID)
    }
}

private final class ActivityQueueDatabase: @unchecked Sendable {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let lock = NSLock()
    private var handle: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw MosemoAPIError.activityQueueStorageFailed
        }
        do {
            try execute("PRAGMA busy_timeout=5000")
            try execute("""
                CREATE TABLE IF NOT EXISTS activity_queue_next (
                    account_id TEXT NOT NULL, device_id TEXT NOT NULL, next_sequence INTEGER NOT NULL,
                    PRIMARY KEY(account_id, device_id));
                CREATE TABLE IF NOT EXISTS activity_queue_records (
                    account_id TEXT NOT NULL, device_id TEXT NOT NULL, sequence INTEGER NOT NULL,
                    event_id TEXT NOT NULL, nonce BLOB NOT NULL, ciphertext BLOB NOT NULL, tag BLOB NOT NULL,
                    PRIMARY KEY(account_id, device_id, sequence), UNIQUE(account_id, device_id, event_id));
                """)
        } catch {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func enqueue(accountID: UUID, deviceID: UUID, observedAt: Date, timezoneID: String, utcOffsetMinutes: Int,
                 key: Data, makeRecord: (ActivityRecordMetadata) -> ActivityRecord) throws -> QueuedActivity {
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                let sequence = try nextSequence(accountID: accountID, deviceID: deviceID)
                let eventID = UUID()
                let metadata = ActivityRecordMetadata(deviceRegistrationID: deviceID, eventID: eventID,
                                                      sequence: sequence, observedAt: observedAt,
                                                      timezoneID: timezoneID, utcOffsetMinutes: utcOffsetMinutes)
                let record = makeRecord(metadata)
                let encoded = try JSONEncoder().encode(record)
                let aad = Self.aad(accountID: accountID, deviceID: deviceID, sequence: sequence, eventID: eventID)
                guard let sealed = try AES.GCM.seal(encoded, using: SymmetricKey(data: key), authenticating: aad).combined,
                      sealed.count > 28 else { throw MosemoAPIError.activityQueueStorageFailed }
                let statement = try prepare("INSERT INTO activity_queue_records(account_id,device_id,sequence,event_id,nonce,ciphertext,tag) VALUES(?,?,?,?,?,?,?)")
                defer { sqlite3_finalize(statement) }
                try bind(accountID.uuidString, statement, 1); try bind(deviceID.uuidString, statement, 2)
                try bind(sequence, statement, 3); try bind(eventID.uuidString, statement, 4)
                try bind(Data(sealed.prefix(12)), statement, 5); try bind(Data(sealed.dropFirst(12).dropLast(16)), statement, 6)
                try bind(Data(sealed.suffix(16)), statement, 7); try step(statement)
                try setNextSequence(sequence + 1, accountID: accountID, deviceID: deviceID)
                try execute("COMMIT")
                return QueuedActivity(accountID: accountID, deviceID: deviceID, sequence: sequence, eventID: eventID, record: record)
            } catch {
                try? execute("ROLLBACK")
                throw error is MosemoAPIError ? error : MosemoAPIError.activityQueueStorageFailed
            }
        }
    }

    func first(accountID: UUID, deviceID: UUID, key: Data) throws -> QueuedActivity? {
        try locked {
            let statement = try prepare("SELECT sequence,event_id,nonce,ciphertext,tag FROM activity_queue_records WHERE account_id=? AND device_id=? ORDER BY sequence LIMIT 1")
            defer { sqlite3_finalize(statement) }
            try bind(accountID.uuidString, statement, 1); try bind(deviceID.uuidString, statement, 2)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw MosemoAPIError.activityQueueStorageFailed }
            let sequence = Int(sqlite3_column_int64(statement, 0))
            guard let eventText = sqlite3_column_text(statement, 1), let eventID = UUID(uuidString: String(cString: eventText)),
                  let nonce = blob(statement, 2), let ciphertext = blob(statement, 3), let tag = blob(statement, 4) else {
                throw MosemoAPIError.activityQueueStorageFailed
            }
            let aad = Self.aad(accountID: accountID, deviceID: deviceID, sequence: sequence, eventID: eventID)
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
                let record = try JSONDecoder().decode(ActivityRecord.self, from: AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad))
                return QueuedActivity(accountID: accountID, deviceID: deviceID, sequence: sequence, eventID: eventID, record: record)
            } catch { throw MosemoAPIError.activityQueueStorageFailed }
        }
    }

    func count(accountID: UUID?) throws -> Int {
        try locked {
            let statement = try prepare(accountID == nil ? "SELECT COUNT(*) FROM activity_queue_records" : "SELECT COUNT(*) FROM activity_queue_records WHERE account_id=?")
            defer { sqlite3_finalize(statement) }
            if let accountID { try bind(accountID.uuidString, statement, 1) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw MosemoAPIError.activityQueueStorageFailed }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func acknowledge(accountID: UUID, deviceID: UUID, sequence: Int, eventID: UUID) throws {
        try locked {
            let statement = try prepare("DELETE FROM activity_queue_records WHERE account_id=? AND device_id=? AND sequence=? AND event_id=?")
            defer { sqlite3_finalize(statement) }
            try bind(accountID.uuidString, statement, 1); try bind(deviceID.uuidString, statement, 2)
            try bind(sequence, statement, 3); try bind(eventID.uuidString, statement, 4); try step(statement)
            guard sqlite3_changes(handle) == 1 else { throw MosemoAPIError.activityQueueStorageFailed }
        }
    }

    private func nextSequence(accountID: UUID, deviceID: UUID) throws -> Int {
        let statement = try prepare("SELECT next_sequence FROM activity_queue_next WHERE account_id=? AND device_id=?")
        defer { sqlite3_finalize(statement) }; try bind(accountID.uuidString, statement, 1); try bind(deviceID.uuidString, statement, 2)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return Int(sqlite3_column_int64(statement, 0)) }
        if result == SQLITE_DONE { return 1 }
        throw MosemoAPIError.activityQueueStorageFailed
    }

    private func setNextSequence(_ sequence: Int, accountID: UUID, deviceID: UUID) throws {
        let statement = try prepare("INSERT INTO activity_queue_next VALUES(?,?,?) ON CONFLICT(account_id,device_id) DO UPDATE SET next_sequence=excluded.next_sequence")
        defer { sqlite3_finalize(statement) }; try bind(accountID.uuidString, statement, 1); try bind(deviceID.uuidString, statement, 2)
        try bind(sequence, statement, 3); try step(statement)
    }

    private static func aad(accountID: UUID, deviceID: UUID, sequence: Int, eventID: UUID) -> Data {
        Data("\(accountID.uuidString):\(deviceID.uuidString):\(sequence):\(eventID.uuidString)".utf8)
    }
    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw MosemoAPIError.activityQueueStorageFailed }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MosemoAPIError.activityQueueStorageFailed }
        return statement
    }
    private func bind(_ value: String, _ statement: OpaquePointer, _ index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, Self.transient) == SQLITE_OK else { throw MosemoAPIError.activityQueueStorageFailed }
    }
    private func bind(_ value: Int, _ statement: OpaquePointer, _ index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, sqlite3_int64(value)) == SQLITE_OK else { throw MosemoAPIError.activityQueueStorageFailed }
    }
    private func bind(_ value: Data, _ statement: OpaquePointer, _ index: Int32) throws {
        let status = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), Self.transient) }
        guard status == SQLITE_OK else { throw MosemoAPIError.activityQueueStorageFailed }
    }
    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MosemoAPIError.activityQueueStorageFailed }
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}
