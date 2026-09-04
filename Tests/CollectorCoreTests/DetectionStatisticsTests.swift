import XCTest
@testable import CollectorCore

final class DetectionStatisticsTests: XCTestCase {
    func testCalculatesMissingAverageAndNearestRankP95() {
        var statistics = DetectionStatistics()
        statistics.expectTransition(count: 4)
        statistics.expectTransition(count: 0)
        statistics.recordDetection(latencyMilliseconds: -10, matchesExpectedTransition: true)
        statistics.recordDetection(latencyMilliseconds: 100, matchesExpectedTransition: true)
        statistics.recordDetection(latencyMilliseconds: 200, matchesExpectedTransition: true)

        XCTAssertEqual(statistics.detectedTransitions, 3)
        XCTAssertEqual(statistics.expectedTransitions, 4)
        XCTAssertEqual(statistics.matchedExpectedTransitions, 3)
        XCTAssertEqual(statistics.missedTransitions, 1)
        XCTAssertEqual(statistics.averageLatencyMilliseconds, 100)
        XCTAssertEqual(statistics.p95LatencyMilliseconds, 200)
    }

    func testMissingNeverBecomesNegativeAndFailuresAreIndependent() {
        var statistics = DetectionStatistics()
        statistics.recordDetection(latencyMilliseconds: 1)
        statistics.recordObservationFailure()
        XCTAssertEqual(statistics.missedTransitions, 0)
        XCTAssertEqual(statistics.matchedExpectedTransitions, 0)
        XCTAssertEqual(statistics.observationFailures, 1)
    }

    func testResetClearsAllStatistics() {
        var statistics = DetectionStatistics()
        statistics.expectTransition(count: 1)
        statistics.recordDetection(latencyMilliseconds: 1)
        statistics.recordObservationFailure()
        statistics.reset()

        XCTAssertEqual(statistics, DetectionStatistics())
        XCTAssertNil(statistics.averageLatencyMilliseconds)
        XCTAssertNil(statistics.p95LatencyMilliseconds)
    }

    func testRingBufferKeepsOnlyNewestElements() {
        var buffer = RingBuffer<Int>(capacity: 2)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        XCTAssertEqual(buffer.elements, [2, 3])
        buffer.removeAll(keepingCapacity: false)
        XCTAssertEqual(buffer.elements, [])
    }
}
