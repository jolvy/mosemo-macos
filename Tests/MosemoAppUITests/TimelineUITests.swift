import XCTest

final class TimelineUITests: XCTestCase {
    func testPreviewShowsSegmentsInBothModesAndRefreshes() {
        let app = XCUIApplication()
        app.launchArguments = ["--timeline-ui-preview"]
        app.launch()

        XCTAssertTrue(app.staticTexts["관찰 타임라인"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["timeline-list"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["8개 표시 구간"].exists)

        app.radioButtons["시간축"].click()
        XCTAssertTrue(app.scrollViews["timeline-time-axis"].waitForExistence(timeout: 5))
        app.buttons["timeline-refresh"].click()
        XCTAssertFalse(app.buttons["timeline-refresh"].isEnabled)
        XCTAssertTrue(app.scrollViews["timeline-time-axis"].waitForExistence(timeout: 5))
    }

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

final class LabelReviewUITests: XCTestCase {
    func testGroupSubmissionUpdatesPendingCount() {
        let app = XCUIApplication()
        app.launchArguments = ["--label-review-ui-preview"]
        app.launch()

        let pendingCount = app.staticTexts["label-review-pending-count"]
        XCTAssertTrue(pendingCount.waitForExistence(timeout: 5))
        XCTAssertTrue(pendingCount.label.contains("10건"))
        let confirm = app.buttons["3건 확정"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        let deadline = Date().addingTimeInterval(5)
        while !pendingCount.label.contains("7건"), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(pendingCount.label.contains("7건"))
    }
}
