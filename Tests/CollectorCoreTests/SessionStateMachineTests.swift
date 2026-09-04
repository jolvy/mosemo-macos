import XCTest
@testable import CollectorCore

final class SessionStateMachineTests: XCTestCase {
    func testOnlyActivePhaseAllowsCollection() throws {
        var machine = FocusSessionStateMachine()
        XCTAssertFalse(machine.allowsCollection)

        try machine.start(intention: "문서 작성")
        XCTAssertTrue(machine.allowsCollection)

        try machine.beginIntendedRest()
        XCTAssertFalse(machine.allowsCollection)

        try machine.resume()
        XCTAssertTrue(machine.allowsCollection)

        try machine.end()
        XCTAssertFalse(machine.allowsCollection)
    }

    func testStartTrimsIntentionAndRejectsBlankOrDuplicateStart() throws {
        var machine = FocusSessionStateMachine()
        XCTAssertThrowsError(try machine.start(intention: " \n ")) { error in
            XCTAssertEqual(error as? SessionTransitionError, .emptyIntention)
        }

        try machine.start(intention: "  구현  ")
        XCTAssertEqual(machine.intention, "구현")
        XCTAssertThrowsError(try machine.start(intention: "다른 작업")) { error in
            XCTAssertEqual(error as? SessionTransitionError, .alreadyActive)
        }
    }

    func testInvalidPauseResumeAndEndTransitionsAreExplicit() throws {
        var machine = FocusSessionStateMachine()
        XCTAssertThrowsError(try machine.beginIntendedRest()) { error in
            XCTAssertEqual(error as? SessionTransitionError, .sessionNotActive)
        }
        XCTAssertThrowsError(try machine.resume()) { error in
            XCTAssertEqual(error as? SessionTransitionError, .notResting)
        }
        XCTAssertThrowsError(try machine.end()) { error in
            XCTAssertEqual(error as? SessionTransitionError, .sessionNotActive)
        }

        try machine.start(intention: "구현")
        XCTAssertThrowsError(try machine.resume()) { error in
            XCTAssertEqual(error as? SessionTransitionError, .notResting)
        }
        try machine.end()
        XCTAssertThrowsError(try machine.beginIntendedRest()) { error in
            XCTAssertEqual(error as? SessionTransitionError, .alreadyEnded)
        }
        XCTAssertThrowsError(try machine.resume()) { error in
            XCTAssertEqual(error as? SessionTransitionError, .alreadyEnded)
        }
        XCTAssertThrowsError(try machine.end()) { error in
            XCTAssertEqual(error as? SessionTransitionError, .alreadyEnded)
        }
    }

    func testEndedMachineCanStartANewSession() throws {
        var machine = FocusSessionStateMachine()
        try machine.start(intention: "첫 세션")
        try machine.end()
        try machine.start(intention: "둘째 세션")
        XCTAssertEqual(machine.phase, .active)
        XCTAssertEqual(machine.intention, "둘째 세션")
    }
}
