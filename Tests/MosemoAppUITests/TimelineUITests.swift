import XCTest

final class TimelineUITests: XCTestCase {
    func testCommonDetailSurvivesModeSwitchAndExplainsMissingItems() {
        let app = XCUIApplication()
        app.launchArguments = ["--timeline-ui-preview", "--timeline-preview-now", "2026-09-30T07:00:00Z"]
        app.launch()
        let first = app.buttons["timeline-segment-00000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        app.activate()
        first.click()
        let duration = app.staticTexts["timeline-detail-duration"]
        XCTAssertTrue(duration.waitForExistence(timeout: 3))
        XCTAssertEqual(text(duration), "00:42:00")
        XCTAssertTrue(text(app.staticTexts["timeline-detail-title"]).contains("MosemoApp.swift"))
        XCTAssertFalse(app.staticTexts["timeline-detail-url"].exists)
        app.radioButtons["시간축"].click()
        XCTAssertEqual(text(duration), "00:42:00")
        app.radioButtons["목록"].click()
        XCTAssertEqual(text(duration), "00:42:00")
        app.buttons["timeline-segment-00000000-0000-0000-0000-000000000003"].click()
        XCTAssertTrue(text(app.staticTexts["timeline-detail-empty-reason"]).contains("개인정보 보호"))
        XCTAssertFalse(app.staticTexts["timeline-detail-title"].exists)
        app.buttons["timeline-segment-00000000-0000-0000-0000-000000000004"].click()
        XCTAssertTrue(text(app.staticTexts["timeline-detail-empty-reason"]).contains("수집 공백"))
    }

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
        XCTAssertFalse(app.buttons["timeline-refresh"].exists)
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

    func testPreviewShowsSegmentsInBothModesWithoutManualRefreshControl() {
        let app = XCUIApplication()
        app.launchArguments = ["--timeline-ui-preview", "--timeline-preview-now", "2026-09-30T07:00:00Z"]
        app.launch()

        XCTAssertTrue(app.staticTexts["관찰 타임라인"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["timeline-list"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["8개 표시 구간"].exists)

        app.radioButtons["시간축"].click()
        XCTAssertTrue(app.scrollViews["timeline-time-axis"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["timeline-refresh"].exists)
        XCTAssertTrue(app.scrollViews["timeline-time-axis"].waitForExistence(timeout: 5))
        app.buttons["navigation-label-review"].click()
        XCTAssertTrue(app.staticTexts["라벨 제안"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["새로고침"].exists)
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
    func testTreeSelectionAndContextKeepControlsIndependent() {
        let app = XCUIApplication()
        app.launchArguments = ["--label-review-ui-preview"]
        app.launch()
        let groupID = "00000000-0000-0000-0000-000000000001"
        let secondID = "00000000-0000-0000-0000-000000000002"
        let thirdID = "00000000-0000-0000-0000-000000000003"
        let row = app.buttons["review-expand-" + groupID]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("+"))
        row.click()
        XCTAssertTrue(row.label.contains("−"))
        app.buttons["review-group-check-" + groupID].click()
        XCTAssertTrue(row.label.contains("−"))
        app.buttons["review-group-check-" + groupID].click()
        row.click()
        XCTAssertTrue(row.label.contains("+"))
        XCTAssertFalse(app.buttons["review-check-" + groupID].exists)
        row.click()
        let firstCheck = app.buttons["review-check-" + groupID]
        XCTAssertTrue(firstCheck.waitForExistence(timeout: 3))
        firstCheck.click()
        XCTAssertTrue(app.buttons["review-group-check-" + groupID].label.contains("부분 선택"))
        XCTAssertTrue(app.buttons["review-all-check"].label.contains("부분 선택"))
        XCTAssertTrue((app.staticTexts["review-title-" + thirdID].value as? String ?? "").contains("수집 불가"))
        XCTAssertTrue((app.staticTexts["review-url-" + thirdID].value as? String ?? "").contains("https://example.com/swift"))
        XCTAssertTrue((app.staticTexts["review-title-" + secondID].value as? String ?? "").contains("AuthCoordinator.swift"))
        XCTAssertFalse(app.staticTexts["review-url-" + secondID].exists)
        XCTAssertTrue((app.staticTexts["review-duration-" + secondID].value as? String ?? "").contains("480초"))
        let menu = app.popUpButtons["review-choice-" + groupID]
        XCTAssertTrue(menu.exists)
        menu.click()
        app.menuItems["미분류"].click()
        XCTAssertTrue(row.label.contains("−"))
        XCTAssertTrue(row.label.contains("미분류 1건"))
        app.buttons["review-confirm-" + groupID].click()
        XCTAssertTrue(app.buttons["review-expand-" + secondID].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["review-check-" + secondID].exists)
        XCTAssertFalse(firstCheck.exists)
    }

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
