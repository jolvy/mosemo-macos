import XCTest
import MosemoAPI
@testable import MosemoApp

@MainActor
final class FocusSessionTests: XCTestCase {
    func testElapsedTimeExcludesPauseAndEndsDefinitively() {
        var now: TimeInterval = 0
        let model = FocusSessionViewModel(fetchLabels: { [] }, clock: { now })
        model.start()
        now = 10
        model.pause()
        now = 100
        model.tick()
        XCTAssertEqual(model.workSeconds, 10)
        model.resume()
        now = 105
        model.end()
        XCTAssertEqual(model.workSeconds, 15)
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.displaySeconds, 0)
        model.resume()
        model.reset()
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.workSeconds, 15)
    }

    func testCountdownAutomaticallyEndsAtTarget() {
        var now: TimeInterval = 0
        let model = FocusSessionViewModel(fetchLabels: { [] }, clock: { now })
        model.timeInput = "00:20:00"
        model.start()
        now = 20
        model.tick()
        XCTAssertEqual(model.displaySeconds, 1180)
        now = 1201
        model.pause()
        XCTAssertEqual(model.phase, .review)
        XCTAssertEqual(model.workSeconds, 1200)
        XCTAssertEqual(model.displaySeconds, 0)
    }

    func testCompletionRequiresActiveLabelAndRetainsItForNextSession() async {
        let active = LabelCatalogEntry(id: UUID(), displayName: "개발", archivedAt: nil)
        let archived = LabelCatalogEntry(id: UUID(), displayName: "보관", archivedAt: .now)
        let model = FocusSessionViewModel(fetchLabels: { [active, archived] })
        await model.loadLabels()
        XCTAssertEqual(model.labels, [active])
        model.start()
        model.end()
        model.complete()
        XCTAssertEqual(model.phase, .review)
        model.selectedLabelID = archived.id
        XCTAssertFalse(model.canComplete)
        model.selectedLabelID = active.id
        XCTAssertTrue(model.canComplete)
        model.complete()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.selectedLabelID, active.id)
        XCTAssertEqual(model.description, "")
        XCTAssertEqual(model.timeInput, "00:00:00")
        XCTAssertEqual(model.lastCompleted?.label, active)
        XCTAssertEqual(model.lastCompleted?.description, "")
    }

    func testResetClearsAllReadyInputsButCannotResetRunningSession() {
        let model = FocusSessionViewModel(fetchLabels: { [] })
        model.timeInput = "00:20:00"
        model.selectedLabelID = UUID()
        model.description = "작업 내용"
        model.start()
        model.reset()
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.description, "작업 내용")
        let ready = FocusSessionViewModel(fetchLabels: { [] })
        ready.timeInput = "00:20:00"
        ready.selectedLabelID = UUID()
        ready.description = "작업 내용"
        ready.reset()
        XCTAssertEqual(ready.timeInput, "00:00:00")
        XCTAssertNil(ready.selectedLabelID)
        XCTAssertEqual(ready.description, "")
    }

    func testInvalidTimeCannotStartAndAuthenticationFailureIsReported() async {
        var authenticationFailed = false
        let model = FocusSessionViewModel(fetchLabels: { throw MosemoAPIError.authenticationRequired }, authenticationFailed: { authenticationFailed = true })
        model.timeInput = "00:60:00"
        model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.canStart)
        await model.loadLabels()
        XCTAssertTrue(authenticationFailed)
        XCTAssertNotNil(model.labelError)
        XCTAssertFalse(model.isLoadingLabels)
    }
}
