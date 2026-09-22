import Foundation
import XCTest
@testable import MosemoAPI

final class ActivityRecordMetadataResolverTests: XCTestCase {
    func testResolveUsesDeviceStoredForAuthenticatedAccount() async throws {
        let account = makeAccount(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let deviceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let eventID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let observedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let store = ResolverDeviceRegistrationStateStore(states: [
            account.id: DeviceRegistrationState(deviceID: deviceID),
        ])
        let resolver = ActivityRecordMetadataResolver(stateStore: store)

        let metadata = try await resolver.resolve(
            for: account,
            eventID: eventID,
            sequence: 7,
            observedAt: observedAt,
            timezoneID: "Asia/Seoul",
            utcOffsetMinutes: 540
        )

        XCTAssertEqual(metadata.deviceRegistrationID, deviceID)
        XCTAssertEqual(metadata.eventID, eventID)
        XCTAssertEqual(metadata.sequence, 7)
        XCTAssertEqual(metadata.observedAt, observedAt)
        XCTAssertEqual(metadata.timezoneID, "Asia/Seoul")
        XCTAssertEqual(metadata.utcOffsetMinutes, 540)
    }

    func testResolveKeepsDeviceStateIsolatedWhenAccountChanges() async throws {
        let firstAccount = makeAccount(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let secondAccount = makeAccount(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        let firstDeviceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondDeviceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let store = ResolverDeviceRegistrationStateStore(states: [
            firstAccount.id: DeviceRegistrationState(deviceID: firstDeviceID),
            secondAccount.id: DeviceRegistrationState(deviceID: secondDeviceID),
        ])
        let resolver = ActivityRecordMetadataResolver(stateStore: store)

        let firstMetadata = try await resolver.resolve(
            for: firstAccount,
            eventID: UUID(),
            sequence: 1,
            observedAt: Date(timeIntervalSince1970: 1_800_000_100),
            timezoneID: "Asia/Seoul",
            utcOffsetMinutes: 540
        )
        let secondMetadata = try await resolver.resolve(
            for: secondAccount,
            eventID: UUID(),
            sequence: 2,
            observedAt: Date(timeIntervalSince1970: 1_800_000_200),
            timezoneID: "Asia/Seoul",
            utcOffsetMinutes: 540
        )

        XCTAssertEqual(firstMetadata.deviceRegistrationID, firstDeviceID)
        XCTAssertEqual(secondMetadata.deviceRegistrationID, secondDeviceID)
    }

    func testResolveRequiresStoredDeviceForEmptyOrPendingState() async {
        let emptyAccount = makeAccount(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let pendingAccount = makeAccount(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        let store = ResolverDeviceRegistrationStateStore(states: [
            pendingAccount.id: DeviceRegistrationState(
                pendingIdempotencyKey: UUID(
                    uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
                )!
            ),
        ])
        let resolver = ActivityRecordMetadataResolver(stateStore: store)

        for account in [emptyAccount, pendingAccount] {
            await assertAPIError(.deviceRegistrationRequired) {
                _ = try await resolver.resolve(
                    for: account,
                    eventID: UUID(),
                    sequence: 1,
                    observedAt: Date(timeIntervalSince1970: 1_800_000_100),
                    timezoneID: "Asia/Seoul",
                    utcOffsetMinutes: 540
                )
            }
        }
    }

    func testResolvePreservesDeviceStateStorageFailure() async {
        let account = makeAccount(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let store = ResolverDeviceRegistrationStateStore(
            loadError: .credentialStorageFailed
        )
        let resolver = ActivityRecordMetadataResolver(stateStore: store)

        await assertAPIError(.credentialStorageFailed) {
            _ = try await resolver.resolve(
                for: account,
                eventID: UUID(),
                sequence: 1,
                observedAt: Date(timeIntervalSince1970: 1_800_000_100),
                timezoneID: "Asia/Seoul",
                utcOffsetMinutes: 540
            )
        }
    }

    private func makeAccount(id: UUID) -> Account {
        Account(
            id: id,
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

private actor ResolverDeviceRegistrationStateStore: DeviceRegistrationStateStoring {
    private var states: [UUID: DeviceRegistrationState]
    private let loadError: MosemoAPIError?

    init(
        states: [UUID: DeviceRegistrationState] = [:],
        loadError: MosemoAPIError? = nil
    ) {
        self.states = states
        self.loadError = loadError
    }

    func load(for accountID: UUID) throws -> DeviceRegistrationState {
        if let loadError {
            throw loadError
        }
        return states[accountID] ?? DeviceRegistrationState()
    }

    func save(_ state: DeviceRegistrationState, for accountID: UUID) {
        states[accountID] = state
    }
}
