import XCTest

final class TimelineUITests: XCTestCase {
    func testAxisStartsAtCurrentTimeAndRestoresAcrossTransitions() {
        let app = XCUIApplication()
        app.launchArguments = ["--timeline-ui-preview", "--timeline-preview-now", "2026-09-30T07:00:00Z"]
        app.launch()
        XCTAssertTrue(app.scrollViews["timeline-list"].waitForExistence(timeout: 5))
        app.radioButtons["시간축"].click()
        let axis = app.scrollViews["timeline-time-axis"]
        XCTAssertTrue(axis.waitForExistence(timeout: 5))
        let tick = app.staticTexts["timeline-tick-16"]
        XCTAssertTrue(tick.waitForExistence(timeout: 3))
        XCTAssertTrue(tick.isHittable)
        XCTAssertEqual(tick.frame.midY, axis.frame.midY, accuracy: 20)

        axis.scroll(byDeltaX: 0, deltaY: 400)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let before = tick.frame.midY
        XCTAssertGreaterThan(abs(before - axis.frame.midY), 100)
        app.radioButtons["목록"].click()
        app.radioButtons["시간축"].click()
        assertPosition(tick, equals: before)
        app.buttons["timeline-refresh"].click()
        XCTAssertTrue(axis.waitForExistence(timeout: 5))
        assertPosition(tick, equals: before)
        app.buttons["이전 날짜"].click()
        XCTAssertTrue(app.staticTexts["이 날짜에 기록이 없습니다"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["timeline-tick-0"].isHittable)
        app.buttons["다음 날짜"].click()
        XCTAssertTrue(axis.waitForExistence(timeout: 5))
        assertPosition(tick, equals: before)
        app.buttons["navigation-label-review"].click()
        app.buttons["navigation-timeline"].click()
        assertPosition(tick, equals: before)

        axis.scroll(byDeltaX: 0, deltaY: -10000)
        XCTAssertTrue(app.staticTexts["timeline-tick-0"].isHittable)
        for _ in 0..<8 { axis.scroll(byDeltaX: 0, deltaY: 500) }
        let last = app.staticTexts["timeline-tick-24"]
        XCTAssertTrue(last.isHittable)
    }

    private func text(_ element: XCUIElement) -> String {
        element.value as? String ?? element.label
    }

    private func assertPosition(_ element: XCUIElement, equals y: CGFloat) {
        let deadline = Date().addingTimeInterval(3)
        while abs(element.frame.midY - y) > 3, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(element.frame.midY, y, accuracy: 3)
    }

    func testPreviewShowsSegmentsInBothModesAndRefreshes() {
        let app = XCUIApplication()
        app.launchArguments = ["--timeline-ui-preview", "--timeline-preview-now", "2026-09-30T07:00:00Z"]
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
        app.launchArguments = ["--timeline-ui-preview", "--timeline-preview-now", "2026-09-30T07:00:00Z"]
        app.launch()

        XCTAssertTrue(app.staticTexts["관찰 타임라인"].waitForExistence(timeout: 5))
        app.buttons["이전 날짜"].click()

        let emptyState = app.staticTexts["이 날짜에 기록이 없습니다"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        let selectedDate = text(app.staticTexts["timeline-selected-date"])

        let timeAxisButton = app.radioButtons["시간축"]
        XCTAssertTrue(timeAxisButton.waitForExistence(timeout: 2))
        timeAxisButton.click()

        XCTAssertEqual(text(app.staticTexts["timeline-selected-date"]), selectedDate)
        XCTAssertTrue(emptyState.exists)
    }

    func testWorkspaceNavigationKeepsTimelineDate() {
        let app = XCUIApplication()
        app.launchArguments = ["--timeline-ui-preview", "--timeline-preview-now", "2026-09-30T07:00:00Z"]
        app.launch()

        let timelineDate = app.staticTexts["timeline-selected-date"]
        XCTAssertTrue(timelineDate.waitForExistence(timeout: 5))
        app.buttons["이전 날짜"].click()
        let selectedDate = text(timelineDate)

        app.buttons["navigation-label-review"].click()
        XCTAssertTrue(app.staticTexts["label-review-title"].waitForExistence(timeout: 5))

        app.buttons["navigation-timeline"].click()
        XCTAssertEqual(text(timelineDate), selectedDate)
    }
}

final class LabelReviewUITests: XCTestCase {
    func testGroupSubmissionUpdatesPendingCount() {
        let app = XCUIApplication()
        app.launchArguments = ["--label-review-ui-preview"]
        app.launch()

        let pendingCount = app.staticTexts["label-review-pending-count"]
        XCTAssertTrue(pendingCount.waitForExistence(timeout: 5))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (pendingCount.value as? String ?? pendingCount.label).contains("10건") }, object: pendingCount)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        let confirm = app.buttons["3건 확정"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        let deadline = Date().addingTimeInterval(5)
        while !(pendingCount.value as? String ?? pendingCount.label).contains("7건"), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue((pendingCount.value as? String ?? pendingCount.label).contains("7건"))
    }
}
