import Foundation
import OpenAPIRuntime
import XCTest
import HTTPTypes
@testable import MosemoAPI

final class SQLiteStorageTests: XCTestCase {
    func testAccessTokenStoreRoundTripAndDelete() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteAccessTokenStore(databaseURL: databaseURL)
        let token = StoredAccessToken(
            value: "sqlite-test-token",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try await store.save(token)
        let loadedToken = try await store.load()
        XCTAssertEqual(loadedToken, token)

        try await store.delete()
        let deletedToken = try await store.load()
        XCTAssertNil(deletedToken)
    }

    func testDeviceRegistrationStoreScopesStateByAccount() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteDeviceRegistrationStateStore(databaseURL: databaseURL)
        let firstAccount = UUID()
        let secondAccount = UUID()
        let state = DeviceRegistrationState(
            deviceID: UUID(),
            pendingIdempotencyKey: UUID()
        )

        try await store.save(state, for: firstAccount)

        let loadedState = try await store.load(for: firstAccount)
        let secondAccountState = try await store.load(for: secondAccount)
        XCTAssertEqual(loadedState, state)
        XCTAssertEqual(secondAccountState, DeviceRegistrationState())
    }

    func testTokenAndDeviceStoresShareOneDatabase() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let tokenStore = try SQLiteAccessTokenStore(databaseURL: databaseURL)
        let deviceStore = try SQLiteDeviceRegistrationStateStore(databaseURL: databaseURL)
        let token = StoredAccessToken(
            value: "shared-database-token",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let accountID = UUID()
        let state = DeviceRegistrationState(deviceID: UUID())

        try await tokenStore.save(token)
        try await deviceStore.save(state, for: accountID)

        let loadedToken = try await tokenStore.load()
        let loadedState = try await deviceStore.load(for: accountID)
        XCTAssertEqual(loadedToken, token)
        XCTAssertEqual(loadedState, state)
    }

    func testExpiredSQLiteTokenIsDeletedByBearerMiddleware() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteAccessTokenStore(databaseURL: databaseURL)
        try await store.save(StoredAccessToken(
            value: "expired-token",
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let middleware = BearerAuthenticationMiddleware(
            tokenStore: store,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        do {
            _ = try await middleware.intercept(
                HTTPRequest(
                    method: .get,
                    scheme: "https",
                    authority: "api.test",
                    path: "/me"
                ),
                body: nil,
                baseURL: URL(string: "https://api.test")!,
                operationID: "get-me"
            ) { _, _, _ in
                XCTFail("Expired credentials must stop before transport")
                return (HTTPResponse(status: .ok), nil)
            }
            XCTFail("Expected authenticationRequired")
        } catch {
            XCTAssertEqual(error as? MosemoAPIError, .authenticationRequired)
        }

        let remainingToken = try await store.load()
        XCTAssertNil(remainingToken)
    }

    func testDeviceStateSurvivesManagerRecreationAfterResponseLoss() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let account = makeAccount()
        let store = try SQLiteDeviceRegistrationStateStore(databaseURL: databaseURL)
        let device = Device(id: UUID())
        let client = SQLiteDeviceClient(device: device)
        let manager = DeviceRegistrationManager(stateStore: store)

        do {
            _ = try await manager.ensureRegistered(for: account, using: client)
            XCTFail("Expected the first response to be lost")
        } catch {
            XCTAssertEqual(error as? MosemoAPIError, .networkUnavailable)
        }

        let pendingState = try await store.load(for: account.id)
        let pendingKey = try XCTUnwrap(pendingState.pendingIdempotencyKey)

        let retryManager = DeviceRegistrationManager(stateStore: store)
        let registeredDevice = try await retryManager.ensureRegistered(
            for: account,
            using: client
        )
        let registrationKeys = await client.keys()
        let registeredState = try await store.load(for: account.id)
        XCTAssertEqual(registeredDevice, device)
        XCTAssertEqual(registrationKeys, [pendingKey, pendingKey])
        XCTAssertEqual(registeredState, DeviceRegistrationState(deviceID: device.id))
    }

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .kakao,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAuthenticatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mosemo-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }
}

private actor SQLiteDeviceClient: MosemoAPIClient {
    private let device: Device
    private var registrationKeys: [UUID] = []

    init(device: Device) {
        self.device = device
    }

    nonisolated func makeKakaoLoginURL(codeChallenge: String) throws -> URL {
        fatalError("Not used by SQLite storage tests")
    }

    func authenticate(
        authorizationCode: String,
        codeVerifier: String
    ) async throws -> Account {
        fatalError("Not used by SQLite storage tests")
    }

    func currentAccount() async throws -> Account {
        fatalError("Not used by SQLite storage tests")
    }

    func registerDevice(idempotencyKey: UUID) async throws -> Device {
        registrationKeys.append(idempotencyKey)
        if registrationKeys.count == 1 {
            throw MosemoAPIError.networkUnavailable
        }
        return device
    }

    func createActivity(_ record: ActivityRecord) async throws -> ActivityCreateResult {
        fatalError("Not used by SQLite storage tests")
    }

    func signOut() async throws {
        fatalError("Not used by SQLite storage tests")
    }

    func keys() -> [UUID] {
        registrationKeys
    }
}
