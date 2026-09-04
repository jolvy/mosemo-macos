import Foundation

public struct InputInterval: Equatable, Sendable {
    public let startedAt: Date
    public let inputOccurred: Bool

    public init(startedAt: Date, inputOccurred: Bool) {
        self.startedAt = startedAt
        self.inputOccurred = inputOccurred
    }
}

public struct InputActivityAggregator: Sendable {
    public let intervalSeconds: TimeInterval
    private var currentStart: Date?
    private var currentHasInput = false

    public init(intervalSeconds: TimeInterval = 10) {
        precondition(intervalSeconds > 0)
        self.intervalSeconds = intervalSeconds
    }

    public mutating func start(at date: Date) {
        currentStart = date
        currentHasInput = false
    }

    public mutating func recordInput(at date: Date) -> [InputInterval] {
        let closed = advance(until: date)
        if currentStart == nil {
            currentStart = date
        }
        currentHasInput = true
        return closed
    }

    public mutating func flushClosedIntervals(until date: Date) -> [InputInterval] {
        advance(until: date)
    }

    public mutating func stop() {
        currentStart = nil
        currentHasInput = false
    }

    private mutating func advance(until date: Date) -> [InputInterval] {
        guard var start = currentStart else { return [] }
        var intervals: [InputInterval] = []

        while date.timeIntervalSince(start) >= intervalSeconds {
            intervals.append(InputInterval(startedAt: start, inputOccurred: currentHasInput))
            start = start.addingTimeInterval(intervalSeconds)
            currentHasInput = false
        }
        currentStart = start
        return intervals
    }
}
