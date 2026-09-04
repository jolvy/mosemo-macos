import Foundation
import XCTest
@testable import CollectorCore

final class SafeActivityEventTests: XCTestCase {
    func testProtectedEventDropsAppDomainAndForcesProtectedSurface() {
        let event = SafeActivityEvent(
            eventType: .activity,
            appBundleID: "com.google.Chrome",
            registeredDomain: "youtube.com",
            surfaceType: .youtubeShorts,
            transitionType: .chromeSurfaceChange,
            observationState: .observed,
            inputOccurred: nil,
            occurredAt: Date(timeIntervalSince1970: 1),
            detectionLatencyMilliseconds: -1,
            protectedContext: true
        )

        XCTAssertNil(event.appBundleID)
        XCTAssertNil(event.registeredDomain)
        XCTAssertEqual(event.surfaceType, .protectedActivity)
        XCTAssertEqual(event.transitionType, .protectedActivity)
        XCTAssertEqual(event.observationState, .protected)
        XCTAssertEqual(event.detectionLatencyMilliseconds, 0)
    }

    func testEncodedSafeEventContainsOnlyAllowlistedKeys() throws {
        let event = SafeActivityEvent(
            eventType: .activity,
            appBundleID: "com.apple.finder",
            registeredDomain: nil,
            surfaceType: .application,
            transitionType: .appSwitch,
            observationState: .observed,
            inputOccurred: nil,
            occurredAt: Date(timeIntervalSince1970: 1),
            detectionLatencyMilliseconds: 3,
            protectedContext: false
        )

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), PrivacyAllowlist.allowedKeys.subtracting(["registeredDomain", "inputOccurred"]))
        XCTAssertNil(object["fullURL"])
        XCTAssertNil(object["pageTitle"])
        XCTAssertNil(object["keyContents"])
        XCTAssertNil(object["clickCoordinates"])
    }

    func testPrivacyAllowlistRemovesEveryForbiddenCandidate() {
        let candidate = [
            "eventType": "activity",
            "appBundleID": "com.apple.finder",
            "fullURL": "forbidden",
            "pageTitle": "forbidden",
            "keyContents": "forbidden",
            "clickCoordinates": "forbidden",
            "mousePath": "forbidden",
            "screenImage": "forbidden",
            "pageBody": "forbidden",
            "formValue": "forbidden",
        ]

        XCTAssertEqual(
            PrivacyAllowlist.sanitize(candidate),
            ["eventType": "activity", "appBundleID": "com.apple.finder"]
        )
    }
}
