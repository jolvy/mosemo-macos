import Foundation

enum TimelineResponseMapper {
    typealias ResponseSegment = Operations.ActivitiesGetLabelTimeline.Output.Ok.Body.JsonPayloadPayload

    static func segments(from response: [ResponseSegment]) throws -> [TimelineSegment] {
        try response.flatMap { item -> [TimelineSegment] in
            switch item {
            case .activityGroup(let group):
                let confirmedLabel: TimelineConfirmedLabel?
                if group.state == .confirmed {
                    switch group.selection {
                    case .label(let label):
                        confirmedLabel = .label(id: try identifier(label.labelId), displayName: label.displayName)
                    case .unclassified:
                        confirmedLabel = .unclassified
                    case nil:
                        throw MosemoAPIError.unexpectedResponse(statusCode: 200)
                    }
                } else {
                    confirmedLabel = nil
                }
                return try group.segments.map { segment in
                    .activity(.init(
                        id: try identifier(segment.segmentId), startedAt: segment.startedAt,
                        endedAt: segment.endedAt, lastObservedAt: segment.lastObservedAt,
                        context: .detailed(details(from: segment.context)), confirmedLabel: confirmedLabel
                    ))
                }
            case .inProgressActivity(let activity):
                return [.activity(.init(
                    id: try identifier(activity.segmentId), startedAt: activity.startedAt,
                    endedAt: nil, lastObservedAt: activity.lastObservedAt,
                    context: .detailed(details(from: activity.context))
                ))]
            case .opaqueActivity(let activity):
                return [.activity(.init(
                    id: try identifier(activity.segmentId), startedAt: activity.startedAt,
                    endedAt: activity.endedAt, lastObservedAt: activity.lastObservedAt, context: .opaque
                ))]
            case .captureGap(let gap):
                return [.captureGap(.init(
                    id: try identifier(gap.segmentId), startedAt: gap.startedAt,
                    endedAt: gap.endedAt, reason: gap.reason
                ))]
            }
        }
    }

    private static func identifier(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw MosemoAPIError.unexpectedResponse(statusCode: 200)
        }
        return id
    }

    private static func details(
        from detail: Components.Schemas.DetailedActivityContext
    ) -> TimelineActivity.Details {
        let appName: String?
        switch detail.app.name {
        case .captured(let value): appName = value.value
        default: appName = nil
        }
        let bundleID: String?
        switch detail.app.bundleId {
        case .captured(let value): bundleID = value.value
        default: bundleID = nil
        }
        let windowTitle: String?
        switch detail.window {
        case .captured(let window): windowTitle = window.title.value
        default: windowTitle = nil
        }
        var tabTitle: String?
        var webURL: String?
        if case .browser(let web) = detail.web {
            if case .captured(let title) = web.tabTitle { tabTitle = title.value }
            if case .captured(let url) = web.url { webURL = url.value }
        }
        return .init(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            tabTitle: tabTitle,
            webURL: webURL
        )
    }
}
