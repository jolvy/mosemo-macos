import Foundation

public enum ActivityEventType: String, Codable, CaseIterable, Sendable {
    case activity
    case inputInterval
    case returnAttempt
    case returnResult
}

public enum ActivitySurfaceType: String, Codable, CaseIterable, Sendable {
    case application
    case browserPage
    case youtubeWatch
    case youtubeShorts
    case protectedActivity
    case unavailable
    case input
    case returnTarget
}

public enum ActivityTransitionType: String, Codable, CaseIterable, Sendable {
    case initialContext
    case appSwitch
    case chromeWindowSwitch
    case chromeTabSwitch
    case chromeURLChange
    case chromeSurfaceChange
    case chromeRestart
    case firefoxWindowSwitch
    case firefoxPageChange
    case inputInterval
    case returnAttempt
    case returnSuccess
    case returnFailure
    case protectedActivity
    case observationUnavailable
}

public enum ActivityObservationState: String, Codable, CaseIterable, Sendable {
    case observed
    case unavailable
    case protected
}

public struct SafeActivityEvent: Codable, Equatable, Sendable {
    public let eventType: ActivityEventType
    public let appBundleID: String?
    public let registeredDomain: String?
    public let surfaceType: ActivitySurfaceType
    public let transitionType: ActivityTransitionType
    public let observationState: ActivityObservationState
    public let inputOccurred: Bool?
    public let occurredAt: Date
    public let detectionLatencyMilliseconds: Int
    public let protectedContext: Bool

    public init(
        eventType: ActivityEventType,
        appBundleID: String?,
        registeredDomain: String?,
        surfaceType: ActivitySurfaceType,
        transitionType: ActivityTransitionType,
        observationState: ActivityObservationState,
        inputOccurred: Bool?,
        occurredAt: Date,
        detectionLatencyMilliseconds: Int,
        protectedContext: Bool
    ) {
        self.eventType = eventType
        self.appBundleID = protectedContext ? nil : appBundleID
        self.registeredDomain = protectedContext ? nil : registeredDomain
        self.surfaceType = protectedContext ? .protectedActivity : surfaceType
        self.transitionType = protectedContext ? .protectedActivity : transitionType
        self.observationState = protectedContext ? .protected : observationState
        self.inputOccurred = protectedContext ? nil : inputOccurred
        self.occurredAt = occurredAt
        self.detectionLatencyMilliseconds = protectedContext ? 0 : max(0, detectionLatencyMilliseconds)
        self.protectedContext = protectedContext
    }
}

public enum PrivacyAllowlist {
    public static let allowedKeys: Set<String> = [
        "eventType",
        "appBundleID",
        "registeredDomain",
        "surfaceType",
        "transitionType",
        "observationState",
        "inputOccurred",
        "occurredAt",
        "detectionLatencyMilliseconds",
        "protectedContext",
    ]

    public static func sanitize(_ candidate: [String: String]) -> [String: String] {
        candidate.filter { allowedKeys.contains($0.key) }
    }
}
