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

public enum LabelReviewActivityContext: Equatable, Sendable {
    case app(title: String?)
    case web(title: String?, url: String?)

    public var title: String? {
        switch self {
        case .app(let title), .web(let title, _): title
        }
    }
}

public struct PendingLabelTimelineSegment: Equatable, Sendable {
    public let id: UUID
    public let version: String
    public let sourceGroupVersion: String
    public let startedAt: Date
    public let endedAt: Date
    public let appName: String
    public let context: LabelReviewActivityContext
    public var title: String { context.title ?? "수집 불가" }

    public init(
        id: UUID, version: String, sourceGroupVersion: String,
        startedAt: Date, endedAt: Date, appName: String, context: LabelReviewActivityContext
    ) {
        self.id = id
        self.version = version
        self.sourceGroupVersion = sourceGroupVersion
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appName = appName
        self.context = context
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
    case confirmed(id: UUID, version: String, selection: LabelConfirmationSelection)
}

public protocol LabelReviewReading: Sendable {
    func listLabels() async throws -> [LabelCatalogEntry]
    func pendingLabelSegments(day: TimelineDate) async throws -> [PendingLabelTimelineSegment]
    func labelState(segmentID: UUID) async throws -> RemoteSegmentLabelState
}

public enum LabelConfirmationSelection: Equatable, Sendable {
    case label(UUID)
    case unclassified
}

public struct LabelConfirmationDecision: Equatable, Sendable {
    public let segmentID: UUID
    public let segmentVersion: String
    public let selection: LabelConfirmationSelection

    public init(segmentID: UUID, segmentVersion: String, selection: LabelConfirmationSelection) {
        self.segmentID = segmentID
        self.segmentVersion = segmentVersion
        self.selection = selection
    }
}

public enum LabelConfirmationRejectionReason: Equatable, Sendable {
    case priorConfirmationConflict
    case segmentChanged
    case segmentNotFound
    case segmentNotLabelable
    case labelNotAvailable
    case timelineBusy
    case validationFailed
    case other(String)
}

public struct LabelConfirmationRejection: Error, Equatable, Sendable {
    public let reason: LabelConfirmationRejectionReason
    public let failedIndex: Int?
    public let retryAfter: TimeInterval?

    public init(reason: LabelConfirmationRejectionReason, failedIndex: Int? = nil, retryAfter: TimeInterval? = nil) {
        self.reason = reason
        self.failedIndex = failedIndex
        self.retryAfter = retryAfter
    }
}

public protocol LabelConfirmationWriting: Sendable {
    func confirmSegmentLabels(_ decisions: [LabelConfirmationDecision]) async throws
}

public struct FocusSessionRecord: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let deviceID: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let targetSeconds: Int
    public let workSeconds: Int?
    public let labelID: UUID?
    public let description: String

    public init(id: UUID, deviceID: UUID, startedAt: Date, endedAt: Date?, targetSeconds: Int, workSeconds: Int?, labelID: UUID?, description: String) {
        self.id = id
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.targetSeconds = targetSeconds
        self.workSeconds = workSeconds
        self.labelID = labelID
        self.description = description
    }
}

public protocol FocusSessionServing: Sendable {
    func startFocusSession(id: UUID, deviceID: UUID, startedAt: Date, targetSeconds: Int) async throws -> FocusSessionRecord
    func completeFocusSession(id: UUID, endedAt: Date, workSeconds: Int, labelID: UUID, description: String) async throws -> FocusSessionRecord
    func listFocusSessions(date: TimelineDate) async throws -> [FocusSessionRecord]
}
