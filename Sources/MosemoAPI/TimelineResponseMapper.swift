import Foundation

enum TimelineResponseMapper {
    typealias ResponseSegment = Operations.ActivitiesGetTimeline.Output.Ok.Body.JsonPayloadPayload

    static func segments(from response: [ResponseSegment]) throws -> [TimelineSegment] {
        try response.map { segment in
            switch segment {
            case .activity(let activity):
                guard let id = UUID(uuidString: activity.segmentId) else {
                    throw MosemoAPIError.unexpectedResponse(statusCode: 200)
                }
                let context: TimelineActivity.Context
                switch activity.context {
                case .opaque:
                    context = .opaque
                case .detailed(let detail):
                    context = .detailed(details(from: detail))
                }
                return .activity(.init(
                    id: id,
                    startedAt: activity.startedAt,
                    endedAt: activity.endedAt,
                    lastObservedAt: activity.lastObservedAt,
                    context: context
                ))
            case .captureGap(let gap):
                guard let id = UUID(uuidString: gap.segmentId) else {
                    throw MosemoAPIError.unexpectedResponse(statusCode: 200)
                }
                return .captureGap(.init(
                    id: id,
                    startedAt: gap.startedAt,
                    endedAt: gap.endedAt,
                    reason: gap.reason
                ))
            }
        }
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
