import Foundation
import Security

public struct DeviceRegistrationState: Codable, Equatable, Sendable {
    public let deviceID: UUID?
    public let pendingIdempotencyKey: UUID?

    public init(
        deviceID: UUID? = nil,
        pendingIdempotencyKey: UUID? = nil
    ) {
        self.deviceID = deviceID
        self.pendingIdempotencyKey = pendingIdempotencyKey
    }
}

public protocol DeviceRegistrationStateStoring: Sendable {
    func load(for accountID: UUID) async throws -> DeviceRegistrationState
    func save(
        _ state: DeviceRegistrationState,
        for accountID: UUID
    ) async throws
}

public actor KeychainDeviceRegistrationStateStore: DeviceRegistrationStateStoring {
    private let service: String

    public init(
        service: String = "io.mosemo.app.device-registration"
    ) {
        self.service = service
    }

    public func load(for accountID: UUID) throws -> DeviceRegistrationState {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return DeviceRegistrationState()
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MosemoAPIError.credentialStorageFailed
        }

        do {
            return try JSONDecoder().decode(DeviceRegistrationState.self, from: data)
        } catch {
            _ = SecItemDelete(baseQuery(for: accountID) as CFDictionary)
            throw MosemoAPIError.credentialStorageFailed
        }
    }

    public func save(
        _ state: DeviceRegistrationState,
        for accountID: UUID
    ) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(state)
        } catch {
            throw MosemoAPIError.credentialStorageFailed
        }

        let query = baseQuery(for: accountID)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MosemoAPIError.credentialStorageFailed
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw MosemoAPIError.credentialStorageFailed
        }
    }

    private func baseQuery(for accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString.lowercased(),
        ]
    }
}

public struct DeviceRegistrationManager: Sendable {
    private let stateStore: any DeviceRegistrationStateStoring

    public init(stateStore: any DeviceRegistrationStateStoring) {
        self.stateStore = stateStore
    }

    @discardableResult
    public func ensureRegistered(
        for account: Account,
        using client: any MosemoAPIClient
    ) async throws -> Device {
        let state = try await stateStore.load(for: account.id)
        if let deviceID = state.deviceID {
            if state.pendingIdempotencyKey != nil {
                try await stateStore.save(
                    DeviceRegistrationState(deviceID: deviceID),
                    for: account.id
                )
            }
            return Device(id: deviceID)
        }

        let idempotencyKey = state.pendingIdempotencyKey ?? UUID()
        if state.pendingIdempotencyKey == nil {
            try await stateStore.save(
                DeviceRegistrationState(pendingIdempotencyKey: idempotencyKey),
                for: account.id
            )
        }

        let device = try await client.registerDevice(
            idempotencyKey: idempotencyKey
        )
        try await stateStore.save(
            DeviceRegistrationState(deviceID: device.id),
            for: account.id
        )
        return device
    }
}
