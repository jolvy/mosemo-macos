import Foundation
import SQLite3

private final class SQLiteDatabase: @unchecked Sendable {
    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    private let lock = NSLock()
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var openedHandle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &openedHandle, flags, nil) == SQLITE_OK,
              let openedHandle else {
            if let openedHandle {
                sqlite3_close(openedHandle)
            }
            throw MosemoAPIError.credentialStorageFailed
        }

        handle = openedHandle
        do {
            try execute("PRAGMA busy_timeout = 5000")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS access_tokens (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    value TEXT NOT NULL,
                    expires_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS device_registration_states (
                    account_id TEXT PRIMARY KEY,
                    device_id TEXT,
                    pending_idempotency_key TEXT
                );
                """
            )
        } catch {
            sqlite3_close(openedHandle)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func loadToken() throws -> StoredAccessToken? {
        try withLock {
            let statement = try prepare(
                "SELECT value, expires_at FROM access_tokens WHERE id = 1"
            )
            defer { sqlite3_finalize(statement) }

            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return nil
            case SQLITE_ROW:
                guard let valuePointer = sqlite3_column_text(statement, 0) else {
                    throw MosemoAPIError.credentialStorageFailed
                }
                return StoredAccessToken(
                    value: String(cString: valuePointer),
                    expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                )
            default:
                throw MosemoAPIError.credentialStorageFailed
            }
        }
    }

    func saveToken(_ token: StoredAccessToken) throws {
        try withLock {
            let statement = try prepare(
                """
                INSERT INTO access_tokens (id, value, expires_at)
                VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    value = excluded.value,
                    expires_at = excluded.expires_at
                """
            )
            defer { sqlite3_finalize(statement) }

            try bind(token.value, to: statement, at: 1)
            guard sqlite3_bind_double(
                statement,
                2,
                token.expiresAt.timeIntervalSince1970
            ) == SQLITE_OK else {
                throw MosemoAPIError.credentialStorageFailed
            }
            try step(statement)
        }
    }

    func deleteToken() throws {
        try withLock {
            let statement = try prepare("DELETE FROM access_tokens WHERE id = 1")
            defer { sqlite3_finalize(statement) }
            try step(statement)
        }
    }

    func loadDeviceState(for accountID: UUID) throws -> DeviceRegistrationState {
        try withLock {
            let statement = try prepare(
                """
                SELECT device_id, pending_idempotency_key
                FROM device_registration_states
                WHERE account_id = ?
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(accountID.uuidString.lowercased(), to: statement, at: 1)

            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                return DeviceRegistrationState()
            case SQLITE_ROW:
                let deviceID = try uuid(from: statement, column: 0)
                let pendingKey = try uuid(from: statement, column: 1)
                return DeviceRegistrationState(
                    deviceID: deviceID,
                    pendingIdempotencyKey: pendingKey
                )
            default:
                throw MosemoAPIError.credentialStorageFailed
            }
        }
    }

    func saveDeviceState(
        _ state: DeviceRegistrationState,
        for accountID: UUID
    ) throws {
        try withLock {
            let statement = try prepare(
                """
                INSERT INTO device_registration_states (
                    account_id,
                    device_id,
                    pending_idempotency_key
                )
                VALUES (?, ?, ?)
                ON CONFLICT(account_id) DO UPDATE SET
                    device_id = excluded.device_id,
                    pending_idempotency_key = excluded.pending_idempotency_key
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(accountID.uuidString.lowercased(), to: statement, at: 1)
            try bind(state.deviceID?.uuidString.lowercased(), to: statement, at: 2)
            try bind(
                state.pendingIdempotencyKey?.uuidString.lowercased(),
                to: statement,
                at: 3
            )
            try step(statement)
        }
    }

    private func execute(_ sql: String) throws {
        try withLock {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
            defer { sqlite3_free(errorMessage) }
            guard status == SQLITE_OK else {
                throw MosemoAPIError.credentialStorageFailed
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MosemoAPIError.credentialStorageFailed
        }
        return statement
    }

    private func bind(
        _ value: String?,
        to statement: OpaquePointer,
        at index: Int32
    ) throws {
        let status: Int32
        if let value {
            status = sqlite3_bind_text(
                statement,
                index,
                value,
                -1,
                Self.transient
            )
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else {
            throw MosemoAPIError.credentialStorageFailed
        }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MosemoAPIError.credentialStorageFailed
        }
    }

    private func uuid(
        from statement: OpaquePointer,
        column: Int32
    ) throws -> UUID? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        guard let pointer = sqlite3_column_text(statement, column),
              let value = UUID(uuidString: String(cString: pointer)) else {
            throw MosemoAPIError.credentialStorageFailed
        }
        return value
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

public enum MosemoAPIStorage: Sendable {
    case keychain
    case sqlite(databaseURL: URL)

    public func makeDeviceRegistrationStateStore()
        throws -> any DeviceRegistrationStateStoring
    {
        switch self {
        case .keychain:
            return KeychainDeviceRegistrationStateStore()
        case .sqlite(let databaseURL):
            return try SQLiteDeviceRegistrationStateStore(databaseURL: databaseURL)
        }
    }
}

actor SQLiteAccessTokenStore: AccessTokenStoring {
    private let database: SQLiteDatabase

    init(databaseURL: URL) throws {
        database = try SQLiteDatabase(url: databaseURL)
    }

    func load() throws -> StoredAccessToken? {
        try database.loadToken()
    }

    func save(_ token: StoredAccessToken) throws {
        try database.saveToken(token)
    }

    func delete() throws {
        try database.deleteToken()
    }
}

public actor SQLiteDeviceRegistrationStateStore: DeviceRegistrationStateStoring {
    private let database: SQLiteDatabase

    public init(databaseURL: URL) throws {
        database = try SQLiteDatabase(url: databaseURL)
    }

    public func load(for accountID: UUID) throws -> DeviceRegistrationState {
        try database.loadDeviceState(for: accountID)
    }

    public func save(
        _ state: DeviceRegistrationState,
        for accountID: UUID
    ) throws {
        try database.saveDeviceState(state, for: accountID)
    }
}

extension MosemoAPIStorage {
    func makeAccessTokenStore() throws -> any AccessTokenStoring {
        switch self {
        case .keychain:
            return KeychainAccessTokenStore()
        case .sqlite(let databaseURL):
            return try SQLiteAccessTokenStore(databaseURL: databaseURL)
        }
    }
}
