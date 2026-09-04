import Foundation
import XCTest
@testable import CollectorCore

final class ReturnTrackingTests: XCTestCase {
    func testTracksAttemptAndSuccessSeparately() {
        let anchor = ReturnAnchorDescriptor(
            identifier: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .chromeTab,
            appBundleID: "com.google.Chrome",
            capturedAt: Date(timeIntervalSince1970: 1),
            protectedContext: false
        )
        let attempt = ReturnAttemptTracker.begin(anchor: anchor, at: Date(timeIntervalSince1970: 2))
        let result = ReturnAttemptTracker.finish(
            attempt: attempt,
            outcome: .success,
            at: Date(timeIntervalSince1970: 3)
        )

        XCTAssertEqual(attempt.anchor, anchor)
        XCTAssertEqual(result.attemptIdentifier, attempt.identifier)
        XCTAssertEqual(result.outcome, .success)
    }

    func testPreservesEachFailureReason() {
        let anchor = ReturnAnchorDescriptor(
            kind: .accessibilityWindow,
            appBundleID: "com.microsoft.VSCode",
            capturedAt: Date(timeIntervalSince1970: 1),
            protectedContext: false
        )
        let attempt = ReturnAttemptTracker.begin(anchor: anchor, at: Date(timeIntervalSince1970: 2))

        for reason in [
            ReturnFailureReason.noAnchor,
            .accessibilityPermissionMissing,
            .automationPermissionDenied,
            .applicationTerminated,
            .windowUnavailable,
            .tabUnavailable,
            .protectedContext,
            .activationRejected,
            .unknown,
        ] {
            let result = ReturnAttemptTracker.finish(
                attempt: attempt,
                outcome: .failure(reason),
                at: Date(timeIntervalSince1970: 3)
            )
            XCTAssertEqual(result.outcome, .failure(reason))
        }
    }
}
