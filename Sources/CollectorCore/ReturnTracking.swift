import Foundation

public enum ReturnTargetKind: String, Equatable, Sendable {
    case application
    case accessibilityWindow
    case chromeTab
}

public struct ReturnAnchorDescriptor: Equatable, Sendable {
    public let identifier: UUID
    public let kind: ReturnTargetKind
    public let appBundleID: String
    public let capturedAt: Date
    public let protectedContext: Bool

    public init(
        identifier: UUID = UUID(),
        kind: ReturnTargetKind,
        appBundleID: String,
        capturedAt: Date,
        protectedContext: Bool
    ) {
        self.identifier = identifier
        self.kind = kind
        self.appBundleID = appBundleID
        self.capturedAt = capturedAt
        self.protectedContext = protectedContext
    }
}

public struct ReturnAttempt: Equatable, Sendable {
    public let identifier: UUID
    public let anchor: ReturnAnchorDescriptor
    public let attemptedAt: Date
}

public enum ReturnFailureReason: String, Error, Equatable, Sendable {
    case noAnchor
    case accessibilityPermissionMissing
    case automationPermissionDenied
    case applicationTerminated
    case windowUnavailable
    case tabUnavailable
    case protectedContext
    case activationRejected
    case unknown
}

public enum ReturnOutcome: Equatable, Sendable {
    case success
    case failure(ReturnFailureReason)
}

public struct ReturnResult: Equatable, Sendable {
    public let attemptIdentifier: UUID
    public let outcome: ReturnOutcome
    public let completedAt: Date
}

public enum ReturnAttemptTracker {
    public static func begin(anchor: ReturnAnchorDescriptor, at date: Date) -> ReturnAttempt {
        ReturnAttempt(identifier: UUID(), anchor: anchor, attemptedAt: date)
    }

    public static func finish(
        attempt: ReturnAttempt,
        outcome: ReturnOutcome,
        at date: Date
    ) -> ReturnResult {
        ReturnResult(
            attemptIdentifier: attempt.identifier,
            outcome: outcome,
            completedAt: date
        )
    }
}
