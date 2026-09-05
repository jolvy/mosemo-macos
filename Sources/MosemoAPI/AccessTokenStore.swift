import Foundation
import Security

struct StoredAccessToken: Codable, Equatable, Sendable {
    let value: String
    let expiresAt: Date
}

protocol AccessTokenStoring: Sendable {
    func load() async throws -> StoredAccessToken?
    func save(_ token: StoredAccessToken) async throws
    func delete() async throws
}

actor KeychainAccessTokenStore: AccessTokenStoring {
    private let service: String
    private let account: String

    init(
        service: String = "io.mosemo.app.authentication",
        account: String = "access-token"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> StoredAccessToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MosemoAPIError.credentialStorageFailed
        }

        do {
            return try JSONDecoder().decode(StoredAccessToken.self, from: data)
        } catch {
            _ = SecItemDelete(baseQuery as CFDictionary)
            throw MosemoAPIError.credentialStorageFailed
        }
    }

    func save(_ token: StoredAccessToken) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(token)
        } catch {
            throw MosemoAPIError.credentialStorageFailed
        }

        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MosemoAPIError.credentialStorageFailed
        }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw MosemoAPIError.credentialStorageFailed
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MosemoAPIError.credentialStorageFailed
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
