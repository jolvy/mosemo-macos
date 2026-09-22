import Foundation

public struct ActivityRecordMetadataResolver: Sendable {
    private let stateStore: any DeviceRegistrationStateStoring

    public init(stateStore: any DeviceRegistrationStateStoring) {
        self.stateStore = stateStore
    }

    public func resolve(
        for account: Account,
        eventID: UUID,
        sequence: Int,
        observedAt: Date,
        timezoneID: String,
        utcOffsetMinutes: Int
    ) async throws -> ActivityRecordMetadata {
        let state = try await stateStore.load(for: account.id)
        guard let deviceID = state.deviceID else {
            throw MosemoAPIError.deviceRegistrationRequired
        }

        return ActivityRecordMetadata(
            deviceRegistrationID: deviceID,
            eventID: eventID,
            sequence: sequence,
            observedAt: observedAt,
            timezoneID: timezoneID,
            utcOffsetMinutes: utcOffsetMinutes
        )
    }
}
