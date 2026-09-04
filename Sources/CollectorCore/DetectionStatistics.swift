import Foundation

public struct DetectionStatistics: Equatable, Sendable {
    public private(set) var detectedTransitions = 0
    public private(set) var expectedTransitions = 0
    public private(set) var matchedExpectedTransitions = 0
    public private(set) var observationFailures = 0
    private var latencySamples: [Int] = []

    public init() {}

    public var missedTransitions: Int {
        max(0, expectedTransitions - matchedExpectedTransitions)
    }

    public var averageLatencyMilliseconds: Int? {
        guard !latencySamples.isEmpty else { return nil }
        return latencySamples.reduce(0, +) / latencySamples.count
    }

    public var p95LatencyMilliseconds: Int? {
        guard !latencySamples.isEmpty else { return nil }
        let sorted = latencySamples.sorted()
        let rank = Int(ceil(Double(sorted.count) * 0.95))
        return sorted[max(0, rank - 1)]
    }

    public mutating func expectTransition(count: Int = 1) {
        guard count > 0 else { return }
        expectedTransitions += count
    }

    public mutating func recordDetection(
        latencyMilliseconds: Int,
        matchesExpectedTransition: Bool = false
    ) {
        detectedTransitions += 1
        if matchesExpectedTransition {
            matchedExpectedTransitions += 1
        }
        latencySamples.append(max(0, latencyMilliseconds))
    }

    public mutating func recordObservationFailure() {
        observationFailures += 1
    }

    public mutating func reset() {
        self = DetectionStatistics()
    }
}

public struct RingBuffer<Element>: Sendable where Element: Sendable {
    public let capacity: Int
    private var storage: [Element] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var elements: [Element] { storage }

    public mutating func append(_ element: Element) {
        if storage.count == capacity {
            storage.removeFirst()
        }
        storage.append(element)
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity)
    }
}
