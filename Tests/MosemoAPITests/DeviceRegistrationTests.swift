import Foundation
import XCTest
@testable import MosemoAPI

final class DeviceRegistrationTests: XCTestCase {
    func testFirstRegistrationPersistsPendingKeyBeforeCallAndDeviceAfterSuccess() async throws {
        let account = makeAccount()
        let store = MemoryDeviceRegistrationStateStore()
        let deviceID = UUID()
        let client = RecordingDeviceClient(
            accountID: account.id,
            stateStore: store,
            outcomes: [.success(Device(id: deviceID))]
        )
        let manager = DeviceRegistrationManager(stateStore: store)

        let device = try await manager.ensureRegistered(for: account, using: client)

        XCTAssertEqual(device, Device(id: deviceID))
        let observed = await client.observedRegistrations()
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed[0].state.deviceID, nil)
        XCTAssertEqual(observed[0].state.pendingIdempotencyKey, observed[0].key)
        let storedState = await store.state(for: account.id)
        XCTAssertEqual(
            storedState,
            DeviceRegistrationState(deviceID: deviceID)
        )
    }

    func testRegisteredAccountReusesDeviceWithoutCallingAPI() async throws {
        let account = makeAccount()
        let deviceID = UUID()
        let store = MemoryDeviceRegistrationStateStore(
            states: [account.id: DeviceRegistrationState(deviceID: deviceID)]
        )
        let client = RecordingDeviceClient(
            accountID: account.id,
            stateStore: store,
            outcomes: []
        )
        let manager = DeviceRegistrationManager(stateStore: store)

        let device = try await manager.ensureRegistered(for: account, using: client)

        XCTAssertEqual(device, Device(id: deviceID))
        let observed = await client.observedRegistrations()
        XCTAssertTrue(observed.isEmpty)
    }

    func testPendingKeyIsReusedAfterResponseLossAndManagerRecreation() async throws {
        let account = makeAccount()
        let store = MemoryDeviceRegistrationStateStore()
        let deviceID = UUID()
        let client = RecordingDeviceClient(
            accountID: account.id,
            stateStore: store,
            outcomes: [
                .responseLost(Device(id: deviceID)),
                .success(Device(id: deviceID)),
            ]
        )
        let manager = DeviceRegistrationManager(stateStore: store)

        await assertAPIError(.networkUnavailable) {
            _ = try await manager.ensureRegistered(for: account, using: client)
        }
        let pendingState = await store.state(for: account.id)
        let firstKey = try XCTUnwrap(pendingState.pendingIdempotencyKey)
        let acceptedDevice = await client.acceptedDevice(for: firstKey)
        XCTAssertEqual(
            acceptedDevice,
            Device(id: deviceID)
        )

        let retryManager = DeviceRegistrationManager(stateStore: store)
        _ = try await retryManager.ensureRegistered(for: account, using: client)

        let observed = await client.observedRegistrations()
        XCTAssertEqual(observed.map(\.key), [firstKey, firstKey])
        let storedState = await store.state(for: account.id)
        XCTAssertEqual(
            storedState,
            DeviceRegistrationState(deviceID: deviceID)
        )
    }

    func testDifferentAccountsKeepIndependentRegistrationState() async throws {
        let firstAccount = makeAccount()
        let secondAccount = makeAccount()
        let store = MemoryDeviceRegistrationStateStore()
        let firstDevice = UUID()
        let secondDevice = UUID()
        let client = RecordingDeviceClient(
            accountID: firstAccount.id,
            stateStore: store,
            outcomes: [
                .success(Device(id: firstDevice)),
                .success(Device(id: secondDevice)),
            ]
        )
        let manager = DeviceRegistrationManager(stateStore: store)

        _ = try await manager.ensureRegistered(for: firstAccount, using: client)
        client.setAccountID(secondAccount.id)
        _ = try await manager.ensureRegistered(for: secondAccount, using: client)

        let observed = await client.observedRegistrations()
        XCTAssertEqual(observed.count, 2)
        XCTAssertNotEqual(observed[0].key, observed[1].key)
        let firstState = await store.state(for: firstAccount.id)
        let secondState = await store.state(for: secondAccount.id)
        XCTAssertEqual(
            firstState,
            DeviceRegistrationState(deviceID: firstDevice)
        )
        XCTAssertEqual(
            secondState,
            DeviceRegistrationState(deviceID: secondDevice)
        )
    }

    func testUnauthorizedFailurePreservesPendingKey() async throws {
        let account = makeAccount()
        let store = MemoryDeviceRegistrationStateStore()
        let client = RecordingDeviceClient(
            accountID: account.id,
            stateStore: store,
            outcomes: [.failure(.authenticationRequired)]
        )
        let manager = DeviceRegistrationManager(stateStore: store)

        await assertAPIError(.authenticationRequired) {
            _ = try await manager.ensureRegistered(for: account, using: client)
        }

        let state = await store.state(for: account.id)
        XCTAssertNil(state.deviceID)
        XCTAssertNotNil(state.pendingIdempotencyKey)
    }

    func testServerFailurePreservesPendingKey() async throws {
        let account = makeAccount()
        let store = MemoryDeviceRegistrationStateStore()
        let client = RecordingDeviceClient(
            accountID: account.id,
            stateStore: store,
            outcomes: [.failure(.serverError(statusCode: 503))]
        )
        let manager = DeviceRegistrationManager(stateStore: store)

        await assertAPIError(.serverError(statusCode: 503)) {
            _ = try await manager.ensureRegistered(for: account, using: client)
        }

        let state = await store.state(for: account.id)
        XCTAssertNil(state.deviceID)
        XCTAssertNotNil(state.pendingIdempotencyKey)
    }

    func testConcurrentRegistrationCallsShareOneAPIRequest() async throws {
        let account = makeAccount()
        let store = MemoryDeviceRegistrationStateStore()
        let device = Device(id: UUID())
        let client = RecordingDeviceClient(
            accountID: account.id,
            stateStore: store,
            outcomes: [.success(device), .success(device)],
            delayNanoseconds: 50_000_000
        )
        let manager = DeviceRegistrationManager(stateStore: store)

        async let first = manager.ensureRegistered(for: account, using: client)
        async let second = manager.ensureRegistered(for: account, using: client)

        let firstDevice = try await first
        let secondDevice = try await second
        XCTAssertEqual(firstDevice, device)
        XCTAssertEqual(secondDevice, device)
        let observed = await client.observedRegistrations()
        XCTAssertEqual(observed.count, 1)
    }

    func testKeychainStoreScopesStateByAccount() async throws {
        let service = "io.mosemo.app.tests.device-registration.\(UUID().uuidString)"
        let store = KeychainDeviceRegistrationStateStore(service: service)
        let firstAccount = makeAccount()
        let secondAccount = makeAccount()
        let state = DeviceRegistrationState(
            deviceID: UUID(),
            pendingIdempotencyKey: nil
        )

        try await store.save(state, for: firstAccount.id)

        let firstState = await store.load(for: firstAccount.id)
        let secondState = await store.load(for: secondAccount.id)
        XCTAssertEqual(firstState, state)
        XCTAssertEqual(
            secondState,
            DeviceRegistrationState()
        )
    }

    private func makeAccount() -> Account {
        Account(
            id: UUID(),
            provider: .kakao,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastAuthenticatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func assertAPIError<T>(
        _ expected: MosemoAPIError,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? MosemoAPIError, expected)
        }
    }
}

private actor MemoryDeviceRegistrationStateStore: DeviceRegistrationStateStoring {
    private var states: [UUID: DeviceRegistrationState]

    init(states: [UUID: DeviceRegistrationState] = [:]) {
        self.states = states
    }

    func load(for accountID: UUID) -> DeviceRegistrationState {
        states[accountID] ?? DeviceRegistrationState()
    }

    func save(_ state: DeviceRegistrationState, for accountID: UUID) {
        states[accountID] = state
    }

    func state(for accountID: UUID) -> DeviceRegistrationState {
        states[accountID] ?? DeviceRegistrationState()
    }
}

private actor RecordingDeviceClient: MosemoAPIClient {
    enum RegistrationOutcome: Sendable {
        case success(Device)
        case responseLost(Device)
        case failure(MosemoAPIError)
    }

    struct Observation: Sendable {
        let key: UUID
        let state: DeviceRegistrationState
    }

    private var accountID: UUID
    private let stateStore: MemoryDeviceRegistrationStateStore
    private var outcomes: [RegistrationOutcome]
    private let delayNanoseconds: UInt64
    private var observations: [Observation] = []
    private var acceptedDevices: [UUID: Device] = [:]

    init(
        accountID: UUID,
        stateStore: MemoryDeviceRegistrationStateStore,
        outcomes: [RegistrationOutcome],
        delayNanoseconds: UInt64 = 0
    ) {
        self.accountID = accountID
        self.stateStore = stateStore
        self.outcomes = outcomes
        self.delayNanoseconds = delayNanoseconds
    }

    nonisolated func makeKakaoLoginURL(codeChallenge: String) throws -> URL {
        fatalError("Not used by device registration tests")
    }

    func authenticate(
        authorizationCode: String,
        codeVerifier: String
    ) async throws -> Account {
        fatalError("Not used by device registration tests")
    }

    func currentAccount() async throws -> Account {
        fatalError("Not used by device registration tests")
    }

    func registerDevice(idempotencyKey: UUID) async throws -> Device {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        observations.append(Observation(
            key: idempotencyKey,
            state: await stateStore.load(for: accountID)
        ))
        switch outcomes.removeFirst() {
        case .success(let device):
            return device
        case .responseLost(let device):
            acceptedDevices[idempotencyKey] = device
            throw MosemoAPIError.networkUnavailable
        case .failure(let error):
            throw error
        }
    }

    func signOut() async throws {
        fatalError("Not used by device registration tests")
    }

    func observedRegistrations() -> [Observation] {
        observations
    }

    func acceptedDevice(for key: UUID) -> Device? {
        acceptedDevices[key]
    }

    func setAccountID(_ accountID: UUID) {
        self.accountID = accountID
    }
}
