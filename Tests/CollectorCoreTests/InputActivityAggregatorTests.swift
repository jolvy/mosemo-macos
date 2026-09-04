import Foundation
import XCTest
@testable import CollectorCore

final class InputActivityAggregatorTests: XCTestCase {
    func testReportsOnlyOccurrenceForEachTenSecondBucket() {
        var aggregator = InputActivityAggregator(intervalSeconds: 10)
        aggregator.start(at: date(1))
        XCTAssertEqual(aggregator.recordInput(at: date(2)), [])
        XCTAssertEqual(aggregator.recordInput(at: date(9)), [])

        XCTAssertEqual(
            aggregator.flushClosedIntervals(until: date(11)),
            [InputInterval(startedAt: date(1), inputOccurred: true)]
        )
        XCTAssertEqual(
            aggregator.flushClosedIntervals(until: date(21)),
            [InputInterval(startedAt: date(11), inputOccurred: false)]
        )
    }

    func testLateInputClosesEmptyBucketsBeforeMarkingCurrentBucket() {
        var aggregator = InputActivityAggregator(intervalSeconds: 10)
        aggregator.start(at: date(0))
        XCTAssertEqual(
            aggregator.recordInput(at: date(25)),
            [
                InputInterval(startedAt: date(0), inputOccurred: false),
                InputInterval(startedAt: date(10), inputOccurred: false),
            ]
        )
        XCTAssertEqual(
            aggregator.flushClosedIntervals(until: date(30)),
            [InputInterval(startedAt: date(20), inputOccurred: true)]
        )
    }

    func testStopDiscardsPartialBucketAndRecordCanRestart() {
        var aggregator = InputActivityAggregator(intervalSeconds: 10)
        aggregator.start(at: date(0))
        _ = aggregator.recordInput(at: date(1))
        aggregator.stop()
        XCTAssertEqual(aggregator.flushClosedIntervals(until: date(100)), [])
        XCTAssertEqual(aggregator.recordInput(at: date(101)), [])
        XCTAssertEqual(
            aggregator.flushClosedIntervals(until: date(111)),
            [InputInterval(startedAt: date(101), inputOccurred: true)]
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
