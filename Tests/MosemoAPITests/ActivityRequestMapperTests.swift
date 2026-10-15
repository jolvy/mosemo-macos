import Foundation
import XCTest
@testable import MosemoAPI

final class ActivityRequestMapperTests: XCTestCase {
    func testUTCAliasesSerializeBothRecordKindsWithoutChangingMetadata() throws {
        for timezoneID in ["UTC", "GMT", "Etc/GMT", "Etc/UTC"] {
            let metadata = ActivityRecordMetadata(
                deviceRegistrationID: UUID(), eventID: UUID(), sequence: 1,
                observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                timezoneID: timezoneID, utcOffsetMinutes: 0
            )
            let records: [ActivityRecord] = [
                .observation(.init(metadata: metadata, context: .opaque)),
                .collectionStateChanged(.init(metadata: metadata, state: .active, reason: "test"))
            ]
            for record in records {
                let mapped = try ActivityRequestMapper.request(from: record)
                switch mapped.payload {
                case .activityObservation(let payload):
                    XCTAssertEqual(payload.timezoneId, .utc)
                    XCTAssertEqual(payload.utcOffsetMinutes, 0)
                    XCTAssertEqual(payload.observedAt, metadata.observedAt)
                case .collectionStateChanged(let payload):
                    XCTAssertEqual(payload.timezoneId, .utc)
                    XCTAssertEqual(payload.utcOffsetMinutes, 0)
                    XCTAssertEqual(payload.observedAt, metadata.observedAt)
                }
                XCTAssertEqual(mapped.eventID, metadata.eventID)
            }
            XCTAssertEqual(metadata.timezoneID, timezoneID)
        }
    }

    func testUnsupportedTimezoneStillFailsValidation() {
        let metadata = ActivityRecordMetadata(
            deviceRegistrationID: UUID(), eventID: UUID(), sequence: 1,
            observedAt: .now, timezoneID: "Europe/Paris", utcOffsetMinutes: 120
        )
        XCTAssertThrowsError(try ActivityRequestMapper.request(from: .observation(.init(metadata: metadata, context: .opaque)))) {
            XCTAssertEqual($0 as? MosemoAPIError, .validationFailed)
        }
    }
}
