import XCTest

final class TimelineUITests: XCTestCase {
    func testViewSwitchKeepsDateAndEmptyState() {
        let app = XCUIApplication()
        app.launchArguments = ["--timeline-ui-preview"]
        app.launch()

        XCTAssertTrue(app.staticTexts["관찰 타임라인"].waitForExistence(timeout: 5))
        app.buttons["이전 날짜"].click()

        let emptyState = app.staticTexts["이 날짜에 기록이 없습니다"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        let selectedDate = app.staticTexts["timeline-selected-date"].label

        let timeAxisButton = app.radioButtons["시간축"]
        XCTAssertTrue(timeAxisButton.waitForExistence(timeout: 2))
        timeAxisButton.click()

        XCTAssertEqual(app.staticTexts["timeline-selected-date"].label, selectedDate)
        XCTAssertTrue(emptyState.exists)
    }
}
