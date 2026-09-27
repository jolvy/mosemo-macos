import Foundation

public enum AccountProvider: String, Equatable, Sendable {
    case kakao
}

public struct Account: Equatable, Sendable {
    public let id: UUID
    public let provider: AccountProvider
    public let timeZoneID: String
    public let createdAt: Date
    public let lastAuthenticatedAt: Date

    public init(
        id: UUID,
        provider: AccountProvider,
        createdAt: Date,
        lastAuthenticatedAt: Date,
        timeZoneID: String
    ) {
        self.id = id
        self.provider = provider
        self.timeZoneID = timeZoneID
        self.createdAt = createdAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
    }
}

public struct Device: Equatable, Sendable {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }
}

public struct LabelCatalogEntry: Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let archivedAt: Date?

    public init(id: UUID, displayName: String, archivedAt: Date?) {
        self.id = id
        self.displayName = displayName
        self.archivedAt = archivedAt
    }
}

public struct PendingLabelTimelineSegment: Equatable, Sendable {
    public let id: UUID
    public let version: String
    public let sourceGroupVersion: String
    public let startedAt: Date
    public let endedAt: Date
    public let appName: String
    public let title: String

    public init(
        id: UUID, version: String, sourceGroupVersion: String,
        startedAt: Date, endedAt: Date, appName: String, title: String
    ) {
        self.id = id
        self.version = version
        self.sourceGroupVersion = sourceGroupVersion
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appName = appName
        self.title = title
    }
}

public enum RemoteLabelProposal: Equatable, Sendable {
    case readyLabel(UUID)
    case readyUnclassified
    case waiting
    case processing
    case failed
}

public enum RemoteSegmentLabelState: Equatable, Sendable {
    case pending(id: UUID, version: String, proposal: RemoteLabelProposal)
    case confirmed(id: UUID, version: String)
}

public protocol LabelReviewReading: Sendable {
    func listLabels() async throws -> [LabelCatalogEntry]
    func pendingLabelSegments(day: TimelineDate) async throws -> [PendingLabelTimelineSegment]
    func labelState(segmentID: UUID) async throws -> RemoteSegmentLabelState
}
