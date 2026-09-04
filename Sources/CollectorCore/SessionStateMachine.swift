import Foundation

public enum FocusSessionPhase: String, Equatable, Sendable {
    case notStarted
    case active
    case intendedRest
    case ended
}

public enum SessionTransitionError: Error, Equatable {
    case emptyIntention
    case alreadyActive
    case sessionNotActive
    case notResting
    case alreadyEnded
}

public struct FocusSessionStateMachine: Equatable, Sendable {
    public private(set) var phase: FocusSessionPhase = .notStarted
    public private(set) var intention: String?

    public init() {}

    public var allowsCollection: Bool {
        phase == .active
    }

    public mutating func start(intention: String) throws {
        let trimmed = intention.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SessionTransitionError.emptyIntention
        }
        guard phase != .active && phase != .intendedRest else {
            throw SessionTransitionError.alreadyActive
        }

        self.intention = trimmed
        phase = .active
    }

    public mutating func beginIntendedRest() throws {
        guard phase == .active else {
            if phase == .ended { throw SessionTransitionError.alreadyEnded }
            throw SessionTransitionError.sessionNotActive
        }
        phase = .intendedRest
    }

    public mutating func resume() throws {
        guard phase == .intendedRest else {
            if phase == .ended { throw SessionTransitionError.alreadyEnded }
            throw SessionTransitionError.notResting
        }
        phase = .active
    }

    public mutating func end() throws {
        guard phase == .active || phase == .intendedRest else {
            if phase == .ended { throw SessionTransitionError.alreadyEnded }
            throw SessionTransitionError.sessionNotActive
        }
        phase = .ended
    }
}
