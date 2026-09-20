import Foundation
import XCTest
@testable import MosemoApp
@testable import MosemoAPI

@MainActor
final class AuthCoordinatorTests: XCTestCase {
    func testRestoreSessionRegistersDeviceForAuthenticatedAccount() async {
        let account = makeAccount()
        let device = Device(id: UUID())
        let client = AuthClient(
            currentAccountResult: .success(account),
            registrationResult: .success(device)
        )
        let coordinator = AuthCoordinator(
            client: client,
            deviceRegistrationStateStore: MemoryDeviceRegistrationStateStore()
        )

        await coordinator.restoreSession()

        XCTAssertEqual(coordinator.account, account)
        XCTAssertEqual(coordinator.statusMessage, "로그인되어 있습니다.")
        let registrationCallCount = await client.registrationCallCount()
        XCTAssertEqual(registrationCallCount, 1)
    }

    func testRestoreSessionDoesNotRegisterWithoutValidSession() async {
        let client = AuthClient(
            currentAccountResult: .failure(.authenticationRequired),
            registrationResult: .success(Device(id: UUID()))
        )
        let coordinator = AuthCoordinator(
            client: client,
            deviceRegistrationStateStore: MemoryDeviceRegistrationStateStore()
        )

        await coordinator.restoreSession()

        XCTAssertNil(coordinator.account)
        XCTAssertEqual(coordinator.statusMessage, "로그인이 필요합니다.")
        let registrationCallCount = await client.registrationCallCount()
        XCTAssertEqual(registrationCallCount, 0)
    }

    func testRestoreSessionClearsAccountWhenDeviceRegistrationIsUnauthorized() async {
        let account = makeAccount()
        let client = AuthClient(
            currentAccountResult: .success(account),
            registrationResult: .failure(.authenticationRequired)
        )
        let coordinator = AuthCoordinator(
            client: client,
            deviceRegistrationStateStore: MemoryDeviceRegistrationStateStore()
        )

        await coordinator.restoreSession()

        XCTAssertNil(coordinator.account)
        XCTAssertEqual(coordinator.statusMessage, "로그인이 필요합니다.")
    }

    func testRestoreSessionPreservesAccountAfterTransientDeviceFailure() async {
        let account = makeAccount()
        let store = MemoryDeviceRegistrationStateStore()
        let client = AuthClient(
            currentAccountResult: .success(account),
            registrationResult: .failure(.serverError(statusCode: 503))
        )
        let coordinator = AuthCoordinator(
            client: client,
            deviceRegistrationStateStore: store
        )

        await coordinator.restoreSession()

        XCTAssertEqual(coordinator.account, account)
        XCTAssertEqual(
            coordinator.statusMessage,
            "Device 등록에 실패했습니다. 다시 시도해 주세요."
        )
        let state = await store.load(for: account.id)
        XCTAssertNotNil(state.pendingIdempotencyKey)
    }

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .kakao,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAuthenticatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

private actor AuthClient: MosemoAPIClient {
    private let currentAccountResult: Result<Account, MosemoAPIError>
    private let registrationResult: Result<Device, MosemoAPIError>
    private var registrationCalls = 0

    init(
        currentAccountResult: Result<Account, MosemoAPIError>,
        registrationResult: Result<Device, MosemoAPIError>
    ) {
        self.currentAccountResult = currentAccountResult
        self.registrationResult = registrationResult
    }

    nonisolated func makeKakaoLoginURL(codeChallenge: String) throws -> URL {
        fatalError("Not used by AuthCoordinator lifecycle tests")
    }

    func authenticate(
        authorizationCode: String,
        codeVerifier: String
    ) async throws -> Account {
        fatalError("Not used by AuthCoordinator lifecycle tests")
    }

    func currentAccount() async throws -> Account {
        try currentAccountResult.get()
    }

    func registerDevice(idempotencyKey: UUID) async throws -> Device {
        registrationCalls += 1
        return try registrationResult.get()
    }

    func signOut() async throws {
        fatalError("Not used by AuthCoordinator lifecycle tests")
    }

    func registrationCallCount() -> Int {
        registrationCalls
    }
}

private actor MemoryDeviceRegistrationStateStore: DeviceRegistrationStateStoring {
    private var state = DeviceRegistrationState()

    func load(for accountID: UUID) -> DeviceRegistrationState {
        state
    }

    func save(
        _ state: DeviceRegistrationState,
        for accountID: UUID
    ) {
        self.state = state
    }
}
