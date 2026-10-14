import Foundation
import XCTest
@testable import MosemoApp
import MosemoAPI

@MainActor
final class TimelinePollingTests: XCTestCase {
    func testVisibleActivePollsImmediatelyTicksAndRetainsSnapshotOnFailure() async {
        let fetcher = PollFetcher()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let model = TimelineViewModel(fetcher: fetcher, clock: { clock },
            pollingSleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        await settle()
        model.setPolling(visible: true, active: true)
        await settle()
        let initial = await fetcher.count
        XCTAssertEqual(initial, 2)
        let snapshot = model.day
        await fetcher.failNext()
        clock.addTimeInterval(5)
        await model.pollIfDue()
        XCTAssertEqual(model.day, snapshot)
        XCTAssertNotNil(model.refreshError)
        let failedCount = await fetcher.count
        await model.pollIfDue()
        let unchangedCount = await fetcher.count
        XCTAssertEqual(failedCount, unchangedCount)
        clock.addTimeInterval(10)
        await model.pollIfDue()
        XCTAssertNil(model.refreshError)
        model.setPolling(visible: true, active: false)
        clock.addTimeInterval(60)
        await model.pollIfDue()
        let inactiveCount = await fetcher.count
        XCTAssertEqual(inactiveCount, failedCount + 1)
        model.setPolling(visible: true, active: true)
        await settle()
        let resumedCount = await fetcher.count
        XCTAssertEqual(resumedCount, inactiveCount + 1)
        model.setPolling(visible: false, active: true)
    }

    func testTicksAndReactivationNeverOverlapAndHiddenResponseIsDiscarded() async {
        let fetcher = HeldPollFetcher()
        let model = TimelineViewModel(fetcher: fetcher,
            pollingSleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        await settle()
        model.setPolling(visible: true, active: true)
        await model.pollIfDue()
        model.setPolling(visible: false, active: true)
        model.setPolling(visible: true, active: true)
        await settle()
        let count = await fetcher.count
        XCTAssertEqual(count, 1)
        await fetcher.release()
        await settle()
        let nextCount = await fetcher.count
        XCTAssertEqual(nextCount, 2)
        XCTAssertNil(model.day)
        model.setPolling(visible: false, active: true)
        await fetcher.release()
        await settle()
        XCTAssertNil(model.day)
    }

    private func settle() async { for _ in 0..<100 { await Task.yield() } }
}

private actor PollFetcher: TimelineFetching {
    private(set) var count = 0
    private var failing = false
    func failNext() { failing = true }
    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay {
        count += 1
        if failing { failing = false; throw MosemoAPIError.networkUnavailable }
        return .init(date: day, timeZoneID: timeZoneID, segments: [])
    }
}

private actor HeldPollFetcher: TimelineFetching {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func release() { continuation?.resume(); continuation = nil }
    func fetch(day: TimelineDate, timeZoneID: String) async throws -> TimelineDay {
        count += 1
        await withCheckedContinuation { continuation = $0 }
        return .init(date: day, timeZoneID: timeZoneID, segments: [])
    }
}
