import Foundation

public struct TimelineDate: Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1970
        month = components.month ?? 1
        day = components.day ?? 1
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public func adding(days: Int, timeZone: TimeZone) -> TimelineDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        let date = calendar.date(from: components) ?? .now
        let nextDate = calendar.date(byAdding: .day, value: days, to: date) ?? date
        return TimelineDate(nextDate, timeZone: timeZone)
    }

    public func startOfDay(timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? .now
    }
}

public struct TimelineDay: Equatable, Sendable {
    public let date: TimelineDate
    public let timeZoneID: String
    /// The server's observation order is retained, including ties and zero-length segments.
    public let segments: [TimelineSegment]

    public init(date: TimelineDate, timeZoneID: String, segments: [TimelineSegment]) {
        self.date = date
        self.timeZoneID = timeZoneID
        self.segments = segments
    }
}

public enum TimelineSegment: Equatable, Sendable, Identifiable {
    case activity(TimelineActivity)
    case captureGap(TimelineCaptureGap)

    public var id: UUID {
        switch self {
        case .activity(let activity): activity.id
        case .captureGap(let gap): gap.id
        }
    }

    public var startedAt: Date {
        switch self {
        case .activity(let activity): activity.startedAt
        case .captureGap(let gap): gap.startedAt
        }
    }

    public var endedAt: Date? {
        switch self {
        case .activity(let activity): activity.endedAt
        case .captureGap(let gap): gap.endedAt
        }
    }
}

public struct TimelineActivity: Equatable, Sendable {
    public enum Context: Equatable, Sendable {
        case detailed(appName: String?, windowTitle: String?, webURL: URL?)
        case opaque
    }

    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let lastObservedAt: Date
    public let context: Context

    public init(
        id: UUID,
        startedAt: Date,
        endedAt: Date?,
        lastObservedAt: Date,
        context: Context
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastObservedAt = lastObservedAt
        self.context = context
    }
}

public struct TimelineCaptureGap: Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let reason: String

    public init(id: UUID, startedAt: Date, endedAt: Date?, reason: String) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
    }
}

public protocol TimelineFetching: Sendable {
    func fetch(day: TimelineDate) async throws -> TimelineDay
}
