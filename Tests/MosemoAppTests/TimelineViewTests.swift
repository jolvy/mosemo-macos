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
        XCTAssertEqual(entries.map(\.title), ["Finder", "Xcode", "알 수 없는 활동", "수집 공백"])
        XCTAssertTrue(entries[0].isZeroLength)
        XCTAssertEqual(entries[1].displayEnd, instant(9, 12))
        XCTAssertEqual(entries[1].durationText, "11분")
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

    func testOnlyUndisplayableActivityResultsInEmptyPresentation() async {
        let requested = date()
        let response = TimelineDay(date: requested, timeZoneID: zone.identifier, segments: [
            .activity(.init(id: uuid(31), startedAt: instant(9, 0), endedAt: instant(9, 1), lastObservedAt: instant(9, 1), context: .detailed(appName: nil, windowTitle: nil, webURL: nil)))
        ])
        let model = TimelineViewModel(fetcher: ImmediateFetcher(result: .success(response)), timeZone: zone, now: requested.startOfDay(timeZone: zone))
        await waitUntil { model.loadState == .empty }

        XCTAssertTrue(model.presentations.isEmpty)
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

    private func uuid(_ last: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last))
    }
}

private enum TestError: Error { case expected }

private struct ImmediateFetcher: TimelineFetching {
    let result: Result<TimelineDay, TestError>
    func fetch(day: TimelineDate) async throws -> TimelineDay { try result.get() }
}

private actor CountingFetcher: TimelineFetching {
    let result: Result<TimelineDay, TestError>
    private(set) var count = 0
    init(result: Result<TimelineDay, TestError>) { self.result = result }
    func currentCount() -> Int { count }
    func fetch(day: TimelineDate) async throws -> TimelineDay { count += 1; return try result.get() }
}

private actor RecordingFetcher: TimelineFetching {
    private var requestedDates: [TimelineDate] = []

    func requests() -> [TimelineDate] { requestedDates }

    func fetch(day: TimelineDate) async throws -> TimelineDay {
        requestedDates.append(day)
        return TimelineDay(date: day, timeZoneID: "Asia/Seoul", segments: [])
    }
}

private struct DelayedFetcher: TimelineFetching {
    let slowDate: TimelineDate
    func fetch(day: TimelineDate) async throws -> TimelineDay {
        try? await Task.sleep(nanoseconds: day == slowDate ? 300_000_000 : 20_000_000)
        return TimelineDay(date: day, timeZoneID: "Asia/Seoul", segments: [])
    }
}
