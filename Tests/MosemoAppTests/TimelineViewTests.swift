import Foundation
import MosemoAPI
import XCTest
@testable import MosemoApp

@MainActor
final class TimelineViewTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Seoul")!

    private func date(_ year: Int = 2026, _ month: Int = 9, _ day: Int = 23) -> TimelineDate {
        TimelineDate(year: year, month: month, day: day)
    }

    private func instant(_ hour: Int, _ minute: Int, day: TimelineDate? = nil) -> Date {
        let day = day ?? date()
        return day.startOfDay(timeZone: zone).addingTimeInterval(Double(hour * 60 + minute) * 60)
    }

    func testFullDayAxisPlacesAfternoonRecordWithoutTrimmingMorning() async {
        let model = TimelineViewModel(fetcher: ImmediateFetcher(result: .success(.init(
            date: date(), timeZoneID: zone.identifier, segments: [
                .activity(.init(id: uuid(1), startedAt: instant(15, 0), endedAt: instant(16, 0),
                                lastObservedAt: instant(16, 0), context: .opaque))
            ]))), timeZone: zone, now: instant(16, 0))
        await waitUntil { model.loadState == .loaded }
        XCTAssertEqual(model.axis.height, 1800)
        XCTAssertEqual(model.axis.ticks.first?.label, "00:00")
        XCTAssertEqual(model.axis.ticks.last?.label, "00:00")
        XCTAssertEqual(model.axis.segments.first?.top, 1125)
        XCTAssertEqual(model.axis.segments.first?.height, 75)
    }

    func testConfirmedLabelsRemainDistinctAndRefreshUpdatesSelectedSegment() async {
        let start = instant(9, 0)
        let end = instant(10, 0)
        let labelID = uuid(80)
        func activity(_ id: UInt8, _ label: TimelineConfirmedLabel?, open: Bool = false,
                      opaque: Bool = false) -> TimelineSegment {
            .activity(.init(id: uuid(id), startedAt: start, endedAt: open ? nil : end,
                            lastObservedAt: end, context: opaque ? .opaque : .detailed(.init(appName: "Xcode")),
                            confirmedLabel: label))
        }
        let fetcher = ChangingTimelineFetcher(segments: [
            activity(1, .label(id: labelID, displayName: "개발")),
            activity(2, .unclassified), activity(3, nil),
            activity(4, .unclassified, open: true), activity(5, .unclassified, opaque: true),
            .captureGap(.init(id: uuid(6), startedAt: start, endedAt: end, reason: "잠금"))
        ])
        let model = TimelineViewModel(fetcher: fetcher, timeZone: zone, now: start)
        await waitUntil { model.loadState == .loaded }
        XCTAssertEqual(model.presentations.map(\.confirmedLabelText), ["개발", "미분류", nil, nil, nil, nil])
        XCTAssertEqual(model.presentations[2].labelStateText, "미확정")
        XCTAssertNil(model.presentations[3].labelStateText)
        model.selectSegment(uuid(1))
        await fetcher.replace(with: [activity(1, .label(id: labelID, displayName: "코딩"))])
        model.refresh()
        await waitUntil { model.loadState == .loaded }
        XCTAssertEqual(model.selectedSegmentID, uuid(1))
        XCTAssertEqual(model.presentations.first?.confirmedLabelText, "코딩")
        XCTAssertEqual(model.axis.segments.first?.entry.confirmedLabelText, "코딩")
        await fetcher.replace(with: [activity(1, .unclassified)])
        model.refresh()
        await waitUntil { model.loadState == .loaded }
        XCTAssertEqual(model.presentations.first?.confirmedLabelText, "미분류")
    }

    func testEmptyAxisUsesAccountZoneAndDSTDayLength() async {
        let ny = TimeZone(identifier: "America/New_York")!
        for (date, height, count) in [
            (TimelineDate(year: 2026, month: 3, day: 8), 1725.0, 24),
            (TimelineDate(year: 2026, month: 11, day: 1), 1875.0, 26)
        ] {
            let model = TimelineViewModel(fetcher: ZoneRecordingFetcher(), timeZone: ny,
                                          now: date.startOfDay(timeZone: ny))
            await waitUntil { model.loadState == .empty }
            XCTAssertEqual(model.axis.height, height)
            XCTAssertEqual(model.axis.ticks.count, count)
            XCTAssertEqual(model.axis.start, date.startOfDay(timeZone: ny))
            XCTAssertTrue(model.axis.segments.isEmpty)
        }
    }

    func testAxisClipsDisplayOnlyAndPreservesOpenAndZeroMarkers() async {
        let start = instant(0, 0)
        let end = instant(24, 0)
        let segments: [TimelineSegment] = [
            .captureGap(.init(id: uuid(1), startedAt: start.addingTimeInterval(-3600),
                             endedAt: start.addingTimeInterval(3600), reason: "boundary")),
            .captureGap(.init(id: uuid(2), startedAt: end.addingTimeInterval(-3600),
                             endedAt: end.addingTimeInterval(3600), reason: "boundary")),
            .activity(.init(id: uuid(3), startedAt: instant(13, 0), endedAt: nil,
                            lastObservedAt: instant(13, 5), context: .opaque)),
            .activity(.init(id: uuid(4), startedAt: instant(14, 0), endedAt: instant(14, 0),
                            lastObservedAt: instant(14, 0), context: .opaque))
        ]
        let model = TimelineViewModel(fetcher: ImmediateFetcher(result: .success(
            .init(date: date(), timeZoneID: zone.identifier, segments: segments))),
            timeZone: zone, now: start)
        await waitUntil { model.loadState == .loaded }
        XCTAssertEqual(model.axis.segments.map(\.top), [0, 1725, 975, 1050])
        XCTAssertEqual(model.axis.segments.map(\.height), [75, 75, 0, 0])
        XCTAssertEqual(model.axis.segments[0].entry.start, start.addingTimeInterval(-3600))
        XCTAssertEqual(model.axis.segments[1].entry.end, end.addingTimeInterval(3600))
        XCTAssertTrue(model.axis.segments[2].entry.isOpen)
        XCTAssertTrue(model.axis.segments[3].entry.isZeroLength)
    }

    func testAxisEntryPositionIsRememberedPerDateAndClearedForAccountChanges() async {
        let account = uuid(90)
        let model = TimelineViewModel(fetcher: ZoneRecordingFetcher(), accountID: account,
                                      timeZone: zone, now: instant(16, 0), clock: { self.instant(16, 0) })
        await waitUntil { model.loadState == .empty }
        XCTAssertEqual(model.initialAxisOffset(viewportHeight: 400), 1000)
        model.saveAxisOffset(600)
        model.selectStyle(.timeAxis)
        model.selectStyle(.list)
        XCTAssertEqual(model.initialAxisOffset(viewportHeight: 400), 600)
        model.moveDate(by: -1)
        await waitUntil { model.loadState == .empty }
        XCTAssertEqual(model.initialAxisOffset(viewportHeight: 400), 0)
        model.moveDate(by: 1)
        await waitUntil { model.loadState == .empty }
        XCTAssertEqual(model.initialAxisOffset(viewportHeight: 400), 600)
        model.refresh()
        await waitUntil { model.loadState == .empty }
        XCTAssertEqual(model.initialAxisOffset(viewportHeight: 400), 600)
        model.switchAccount(to: uuid(91))
        await waitUntil { model.loadState == .empty }
        XCTAssertEqual(model.initialAxisOffset(viewportHeight: 400), 1000)
        model.saveAxisOffset(300)
        model.switchAccount(to: uuid(91), timeZone: TimeZone(identifier: "UTC")!)
        await waitUntil { model.loadState == .empty }
        XCTAssertEqual(model.initialAxisOffset(viewportHeight: 400), 325)
    }

    func testPresentationHandlesZeroOpenOpaqueGapAndUndisplayableContext() async {
        let selectedDay = date()
        let expected: [TimelineSegment] = [
            .activity(.init(id: uuid(1), startedAt: instant(9, 0), endedAt: instant(9, 0), lastObservedAt: instant(9, 0), context: .detailed(appName: "Finder", windowTitle: nil, webURL: nil))),
            .activity(.init(id: uuid(2), startedAt: instant(9, 1), endedAt: nil, lastObservedAt: instant(9, 12), context: .detailed(appName: "Xcode", windowTitle: nil, webURL: nil))),
            .activity(.init(id: uuid(3), startedAt: instant(9, 13), endedAt: instant(9, 20), lastObservedAt: instant(9, 20), context: .opaque)),
            .captureGap(.init(id: uuid(4), startedAt: instant(9, 20), endedAt: nil, reason: "종료 시각 없음")),
            .activity(.init(id: uuid(5), startedAt: instant(9, 21), endedAt: instant(9, 22), lastObservedAt: instant(9, 22), context: .detailed(appName: nil, windowTitle: nil, webURL: nil)))
        ]
        let model = TimelineViewModel(fetcher: ImmediateFetcher(result: .success(TimelineDay(date: selectedDay, timeZoneID: zone.identifier, segments: expected))), accountID: uuid(99), timeZone: zone, now: selectedDay.startOfDay(timeZone: zone))
        await waitUntil { model.loadState == .loaded }

        let entries = model.presentations
        XCTAssertEqual(entries.map(\.title), ["Finder", "Xcode", "알 수 없는 활동", "수집 공백", "상세 활동"])
        XCTAssertTrue(entries[0].isZeroLength)
        XCTAssertNil(entries[1].displayEnd)
        XCTAssertEqual(entries[1].durationText, "종료 전")
        XCTAssertTrue(entries[1].timeText(timeZone: zone).contains("진행 중"))
        XCTAssertTrue(entries[2].context.contains("가려졌습니다"))
        XCTAssertNil(entries[3].displayEnd)
        XCTAssertEqual(entries[3].durationText, "길이 미정")
    }

    func testEmptyAndFailureResponsesBecomeDistinctStates() async {
        let emptyDay = date()
        let empty = TimelineViewModel(fetcher: ImmediateFetcher(result: .success(.init(date: emptyDay, timeZoneID: zone.identifier, segments: []))), timeZone: zone, now: emptyDay.startOfDay(timeZone: zone))
        await waitUntil { empty.loadState == .empty }
        XCTAssertTrue(empty.presentations.isEmpty)

        let failure = TimelineViewModel(fetcher: ImmediateFetcher(result: .failure(TestError.expected)), timeZone: zone, now: emptyDay.startOfDay(timeZone: zone))
        await waitUntil { if case .failed = failure.loadState { return true }; return false }
        if case .failed(let message) = failure.loadState { XCTAssertFalse(message.isEmpty) }
        else { XCTFail("Expected failure state") }
    }

    func testModeSwitchReusesFetchedDayWithoutRefetching() async {
        let requested = date()
        let fetcher = CountingFetcher(result: .success(.init(date: requested, timeZoneID: zone.identifier, segments: [
            .activity(.init(id: uuid(10), startedAt: instant(9, 0), endedAt: instant(9, 1), lastObservedAt: instant(9, 1), context: .detailed(appName: "Xcode", windowTitle: nil, webURL: nil)))
        ])))
        let model = TimelineViewModel(fetcher: fetcher, timeZone: zone, now: requested.startOfDay(timeZone: zone))
        await waitUntil { model.loadState == .loaded }
        let before = await fetcher.count
        model.selectStyle(.timeAxis)
        model.selectStyle(.list)
        XCTAssertEqual(model.presentations.count, 1)
        let after = await fetcher.currentCount()
        XCTAssertEqual(after, before)
    }

    func testLateResponseForPreviousDateCannotReplaceCurrentDate() async {
        let first = date()
        let second = date(2026, 9, 24)
        let fetcher = DelayedFetcher(slowDate: first)
        let model = TimelineViewModel(fetcher: fetcher, timeZone: zone, now: first.startOfDay(timeZone: zone))
        model.selectDate(second)
        await waitUntil { model.loadState == .empty }
        XCTAssertEqual(model.day?.date, second)
        try? await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(model.selectedDate, second)
        XCTAssertEqual(model.day?.date, second)
    }

    func testAccountChangeClearsCurrentResultAndFetchesForNewAccount() async {
        let requested = date()
        let fetcher = CountingFetcher(result: .success(.init(date: requested, timeZoneID: zone.identifier, segments: [])))
        let model = TimelineViewModel(fetcher: fetcher, accountID: uuid(20), timeZone: zone, now: requested.startOfDay(timeZone: zone))
        await waitUntil { model.loadState == .empty }

        model.switchAccount(to: uuid(21))
        XCTAssertNil(model.day)
        XCTAssertEqual(model.loadState, .loading)
        await waitUntil { model.loadState == .empty }
        let fetchCount = await fetcher.currentCount()
        XCTAssertEqual(fetchCount, 2)
    }

    func testLateResponseForPreviousAccountCannotReplaceCurrentAccount() async {
        let newYork = TimeZone(identifier: "America/New_York")!
        let requested = date()
        let fetcher = LateAccountResponseFetcher()
        let model = TimelineViewModel(
            fetcher: fetcher,
            accountID: uuid(22),
            timeZone: zone,
            now: requested.startOfDay(timeZone: zone)
        )
        await waitForRequestCount(1, in: fetcher)

        model.switchAccount(to: uuid(23), timeZone: newYork)
        await waitUntil { model.loadState == .empty && model.day?.timeZoneID == newYork.identifier }
        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(model.timeZone.identifier, newYork.identifier)
        XCTAssertEqual(model.day?.timeZoneID, newYork.identifier)
        let timeZones = await fetcher.requestTimeZones()
        XCTAssertEqual(timeZones, [zone.identifier, newYork.identifier])
    }

    func testReturningToPreviousDateFetchesAgain() async {
        let first = date()
        let second = date(2026, 9, 24)
        let fetcher = RecordingFetcher()
        let model = TimelineViewModel(fetcher: fetcher, timeZone: zone, now: first.startOfDay(timeZone: zone))
        await waitUntil { model.loadState == .empty && model.day?.date == first }

        model.selectDate(second)
        await waitUntil { model.loadState == .empty && model.day?.date == second }
        model.selectDate(first)
        await waitUntil { model.loadState == .empty && model.day?.date == first }

        let requests = await fetcher.requests()
        XCTAssertEqual(requests, [first, second, first])
    }

    func testActivityWithoutCapturedIdentifiersRemainsVisible() async {
        let requested = date()
        let response = TimelineDay(date: requested, timeZoneID: zone.identifier, segments: [
            .activity(.init(id: uuid(31), startedAt: instant(9, 0), endedAt: instant(9, 1), lastObservedAt: instant(9, 1), context: .detailed(appName: nil, windowTitle: nil, webURL: nil)))
        ])
        let model = TimelineViewModel(fetcher: ImmediateFetcher(result: .success(response)), timeZone: zone, now: requested.startOfDay(timeZone: zone))
        await waitUntil { model.loadState == .loaded }

        XCTAssertEqual(model.presentations.map(\.title), ["상세 활동"])
        XCTAssertEqual(model.presentations.count, 1)
    }

    func testAccountTimeZoneDefinesTodayAndRequest() async {
        let newYork = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-09-15T01:00:00Z")!
        let fetcher = ZoneRecordingFetcher()
        let model = TimelineViewModel(fetcher: fetcher, timeZone: newYork, now: now)
        await waitUntil { model.loadState == .empty }

        XCTAssertEqual(model.selectedDate, date(2026, 9, 14))
        XCTAssertEqual(model.timeZone.identifier, "America/New_York")
        let requests = await fetcher.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].0, date(2026, 9, 14))
        XCTAssertEqual(requests[0].1, "America/New_York")
    }

    func testRefreshRequestsSameDateAndShowsProgress() async {
        let requested = date()
        let fetcher = ZoneRecordingFetcher(delayNanoseconds: 80_000_000)
        let model = TimelineViewModel(fetcher: fetcher, timeZone: zone, now: requested.startOfDay(timeZone: zone))
        await waitUntil { model.loadState == .empty }

        model.refresh()
        XCTAssertTrue(model.isRefreshing)
        XCTAssertEqual(model.loadState, .loading)
        await waitUntil { model.loadState == .empty && !model.isRefreshing }
        let requests = await fetcher.requests()
        XCTAssertEqual(requests.map(\.0), [requested, requested])
    }

    func testUnauthorizedTimelineResponseNotifiesAuthenticationCoordinator() async {
        let requested = date()
        var failureCount = 0
        let model = TimelineViewModel(
            fetcher: AuthenticationFailureFetcher(),
            timeZone: zone,
            now: requested.startOfDay(timeZone: zone),
            authenticationFailed: { failureCount += 1 }
        )
        await waitUntil { failureCount == 1 }
        XCTAssertNil(model.day)
    }

    private func waitUntil(
        timeout: UInt64 = 1_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds - start < timeout {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Condition did not become true before timeout")
    }

    private func waitForRequestCount(_ count: Int, in fetcher: LateAccountResponseFetcher) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while await fetcher.requestCount() < count,
              DispatchTime.now().uptimeNanoseconds - start < 1_000_000_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let actualCount = await fetcher.requestCount()
        XCTAssertEqual(actualCount, count)
    }

    private func uuid(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last))
    }
}

private enum TestError: Error { case expected }

private struct ImmediateFetcher: TimelineFetching {
    let result: Result<TimelineDay, TestError>
    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay { try result.get() }
}

private actor CountingFetcher: TimelineFetching {
    let result: Result<TimelineDay, TestError>
    private(set) var count = 0
    init(result: Result<TimelineDay, TestError>) { self.result = result }
    func currentCount() -> Int { count }
    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay { count += 1; return try result.get() }
}

private actor RecordingFetcher: TimelineFetching {
    private var requestedDates: [TimelineDate] = []

    func requests() -> [TimelineDate] { requestedDates }

    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay {
        requestedDates.append(day)
        return TimelineDay(date: day, timeZoneID: "Asia/Seoul", segments: [])
    }
}

private struct DelayedFetcher: TimelineFetching {
    let slowDate: TimelineDate
    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay {
        try? await Task.sleep(nanoseconds: day == slowDate ? 300_000_000 : 20_000_000)
        return TimelineDay(date: day, timeZoneID: "Asia/Seoul", segments: [])
    }
}

private actor LateAccountResponseFetcher: TimelineFetching {
    private var requestedTimeZones: [String] = []

    func requestCount() -> Int { requestedTimeZones.count }
    func requestTimeZones() -> [String] { requestedTimeZones }

    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay {
        requestedTimeZones.append(timeZoneID)
        let delay = timeZoneID == "Asia/Seoul" ? 250_000_000 : 20_000_000
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(delay)) {
                continuation.resume(returning: TimelineDay(
                    date: day,
                    timeZoneID: timeZoneID,
                    segments: []
                ))
            }
        }
    }
}

private actor ZoneRecordingFetcher: TimelineFetching {
    let delayNanoseconds: UInt64
    private var recorded: [(TimelineDate, String)] = []

    init(delayNanoseconds: UInt64 = 0) { self.delayNanoseconds = delayNanoseconds }

    func requests() -> [(TimelineDate, String)] { recorded }

    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay {
        recorded.append((day, timeZoneID))
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        return TimelineDay(date: day, timeZoneID: timeZoneID, segments: [])
    }
}

private struct AuthenticationFailureFetcher: TimelineFetching {
    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay {
        throw MosemoAPIError.authenticationRequired
    }
}

private actor ChangingTimelineFetcher: TimelineFetching {
    private var segments: [TimelineSegment]
    init(segments: [TimelineSegment]) { self.segments = segments }
    func replace(with segments: [TimelineSegment]) { self.segments = segments }
    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay {
        .init(date: day, timeZoneID: timeZoneID, segments: segments)
    }
}
