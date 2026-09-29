import Foundation

public struct ActivityRecordMetadata: Codable, Equatable, Sendable {
    public let deviceRegistrationID: UUID
    public let eventID: UUID
    public let sequence: Int
    public let observedAt: Date
    public let timezoneID: String
    public let utcOffsetMinutes: Int

    init(
        deviceRegistrationID: UUID,
        eventID: UUID,
        sequence: Int,
        observedAt: Date,
        timezoneID: String,
        utcOffsetMinutes: Int
    ) {
        self.deviceRegistrationID = deviceRegistrationID
        self.eventID = eventID
        self.sequence = sequence
        self.observedAt = observedAt
        self.timezoneID = timezoneID
        self.utcOffsetMinutes = utcOffsetMinutes
    }
}

public enum ActivityRecord: Codable, Equatable, Sendable {
    case observation(ActivityObservation)
    case collectionStateChanged(CollectionStateChange)
}

public struct ActivityObservation: Codable, Equatable, Sendable {
    public let metadata: ActivityRecordMetadata
    public let context: ActivityContext

    public init(metadata: ActivityRecordMetadata, context: ActivityContext) {
        self.metadata = metadata
        self.context = context
    }
}

public struct CollectionStateChange: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case active
        case suspended
    }

    public let metadata: ActivityRecordMetadata
    public let state: State
    public let reason: String

    public init(
        metadata: ActivityRecordMetadata,
        state: State,
        reason: String
    ) {
        self.metadata = metadata
        self.state = state
        self.reason = reason
    }
}

public enum ActivityContext: Codable, Equatable, Sendable {
    case detailed(DetailedActivityContext)
    case opaque
}

public struct DetailedActivityContext: Codable, Equatable, Sendable {
    public let app: ActivityApplicationContext
    public let window: ActivityWindowContext
    public let web: ActivityWebContext

    public init(
        app: ActivityApplicationContext,
        window: ActivityWindowContext,
        web: ActivityWebContext
    ) {
        self.app = app
        self.window = window
        self.web = web
    }
}

public struct ActivityApplicationContext: Codable, Equatable, Sendable {
    public let bundleID: ActivityObservedString
    public let name: ActivityObservedString

    public init(
        bundleID: ActivityObservedString,
        name: ActivityObservedString
    ) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum ActivityObservedString: Codable, Equatable, Sendable {
    case captured(String)
    case absent
    case unavailable(reason: String)
}

public struct ActivityCapturedText: Codable, Equatable, Sendable {
    public let value: String
    public let truncated: Bool
    public let originalByteLength: Int?

    public init(
        value: String,
        truncated: Bool = false,
        originalByteLength: Int? = nil
    ) {
        self.value = value
        self.truncated = truncated
        self.originalByteLength = originalByteLength
    }
}

public enum ActivityWindowContext: Codable, Equatable, Sendable {
    case captured(title: ActivityCapturedText)
    case absent
    case unavailable(reason: String)
}

public enum ActivityWebContext: Codable, Equatable, Sendable {
    case browser(ActivityBrowserContext)
    case notApplicable
}

public struct ActivityBrowserContext: Codable, Equatable, Sendable {
    public let tabTitle: ActivityObservedText
    public let url: ActivityPrivacyFilteredString

    public init(
        tabTitle: ActivityObservedText,
        url: ActivityPrivacyFilteredString
    ) {
        self.tabTitle = tabTitle
        self.url = url
    }
}

public enum ActivityObservedText: Codable, Equatable, Sendable {
    case captured(ActivityCapturedText)
    case absent
    case unavailable(reason: String)
    case redacted(reason: String)
}

public enum ActivityPrivacyFilteredString: Codable, Equatable, Sendable {
    case captured(String)
    case absent
    case unavailable(reason: String)
    case redacted(reason: String)
}

public enum ActivityPrivacyFilter {
    public static let maximumURLBytes = 8_192
    public static let maximumTitleBytes = 4_096

    public static func url(_ value: String) -> ActivityPrivacyFilteredString {
        if let scheme = URLComponents(string: value)?.scheme?.lowercased(),
           scheme == "data" || scheme == "javascript" {
            return .redacted(reason: "embedded_content_scheme")
        }
        guard value.utf8.count <= maximumURLBytes else {
            return .redacted(reason: "length_exceeded")
        }
        return .captured(value)
    }

    public static func title(_ value: String) -> ActivityCapturedText {
        let byteCount = value.utf8.count
        guard byteCount > maximumTitleBytes else {
            return ActivityCapturedText(value: value)
        }
        var prefix = ""
        var count = 0
        for scalar in value.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard count + scalarBytes <= maximumTitleBytes else { break }
            prefix.unicodeScalars.append(scalar)
            count += scalarBytes
        }
        return ActivityCapturedText(value: prefix, truncated: true, originalByteLength: byteCount)
    }
}

public struct ActivityCreateResult: Equatable, Sendable {
    public let eventID: UUID
    public let receivedAt: Date

    public init(eventID: UUID, receivedAt: Date) {
        self.eventID = eventID
        self.receivedAt = receivedAt
    }
}
