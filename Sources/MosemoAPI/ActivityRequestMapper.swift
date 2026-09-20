import Foundation

enum ActivityRequestMapper {
    typealias RequestPayload = Operations.ActivitiesCreate.Input.Body.JsonPayload

    static func request(
        from record: ActivityRecord
    ) throws -> (payload: RequestPayload, eventID: UUID) {
        switch record {
        case .observation(let observation):
            let metadata = observation.metadata
            return (
                .activityObservation(.init(
                    context: context(observation.context),
                    deviceId: metadata.deviceRegistrationID.uuidString,
                    eventId: metadata.eventID.uuidString,
                    observedAt: metadata.observedAt,
                    recordType: .activityObservation,
                    sequence: metadata.sequence,
                    timezoneId: try timezone(metadata.timezoneID),
                    utcOffsetMinutes: metadata.utcOffsetMinutes
                )),
                metadata.eventID
            )
        case .collectionStateChanged(let change):
            let metadata = change.metadata
            let state: Components.Schemas.CollectionState = switch change.state {
            case .active: .active
            case .suspended: .suspended
            }
            return (
                .collectionStateChanged(.init(
                    deviceId: metadata.deviceRegistrationID.uuidString,
                    eventId: metadata.eventID.uuidString,
                    observedAt: metadata.observedAt,
                    reason: change.reason,
                    recordType: .collectionStateChanged,
                    sequence: metadata.sequence,
                    state: state,
                    timezoneId: try timezone(metadata.timezoneID),
                    utcOffsetMinutes: metadata.utcOffsetMinutes
                )),
                metadata.eventID
            )
        }
    }

    private static func timezone(
        _ value: String
    ) throws -> Components.Schemas.Timezone {
        guard let timezone = Components.Schemas.Timezone(rawValue: value) else {
            throw MosemoAPIError.validationFailed
        }
        return timezone
    }

    private static func context(
        _ context: ActivityContext
    ) -> Components.Schemas.ActivityObservation.ContextPayload {
        switch context {
        case .opaque:
            return .opaque(.init(kind: .opaque))
        case .detailed(let context):
            return .detailed(.init(
                app: .init(
                    bundleId: appBundleID(context.app.bundleID),
                    name: appName(context.app.name)
                ),
                kind: .detailed,
                web: web(context.web),
                window: window(context.window)
            ))
        }
    }

    private static func appBundleID(
        _ value: ActivityObservedString
    ) -> Components.Schemas.AppContext.BundleIdPayload {
        switch value {
        case .captured(let value):
            return .captured(.init(status: .captured, value: value))
        case .absent:
            return .absent(.init(status: .absent))
        case .unavailable(let reason):
            return .unavailable(.init(reason: reason, status: .unavailable))
        }
    }

    private static func appName(
        _ value: ActivityObservedString
    ) -> Components.Schemas.AppContext.NamePayload {
        switch value {
        case .captured(let value):
            return .captured(.init(status: .captured, value: value))
        case .absent:
            return .absent(.init(status: .absent))
        case .unavailable(let reason):
            return .unavailable(.init(reason: reason, status: .unavailable))
        }
    }

    private static func window(
        _ value: ActivityWindowContext
    ) -> Components.Schemas.DetailedActivityContext.WindowPayload {
        switch value {
        case .captured(let title):
            return .captured(.init(status: .captured, title: capturedText(title)))
        case .absent:
            return .absent(.init(status: .absent))
        case .unavailable(let reason):
            return .unavailable(.init(reason: reason, status: .unavailable))
        }
    }

    private static func web(
        _ value: ActivityWebContext
    ) -> Components.Schemas.DetailedActivityContext.WebPayload {
        switch value {
        case .notApplicable:
            return .notApplicable(.init(kind: .notApplicable))
        case .browser(let browser):
            return .browser(.init(
                kind: .browser,
                tabTitle: tabTitle(browser.tabTitle),
                url: url(browser.url)
            ))
        }
    }

    private static func tabTitle(
        _ value: ActivityObservedText
    ) -> Components.Schemas.BrowserWebContext.TabTitlePayload {
        switch value {
        case .captured(let text):
            return .captured(capturedText(text))
        case .absent:
            return .absent(.init(status: .absent))
        case .unavailable(let reason):
            return .unavailable(.init(reason: reason, status: .unavailable))
        case .redacted(let reason):
            return .redacted(.init(reason: reason, status: .redacted))
        }
    }

    private static func url(
        _ value: ActivityPrivacyFilteredString
    ) -> Components.Schemas.BrowserWebContext.UrlPayload {
        switch value {
        case .captured(let value):
            return .captured(.init(status: .captured, value: value))
        case .absent:
            return .absent(.init(status: .absent))
        case .unavailable(let reason):
            return .unavailable(.init(reason: reason, status: .unavailable))
        case .redacted(let reason):
            return .redacted(.init(reason: reason, status: .redacted))
        }
    }

    private static func capturedText(
        _ text: ActivityCapturedText
    ) -> Components.Schemas.CapturedText {
        .init(
            originalByteLength: text.originalByteLength,
            status: .captured,
            truncated: text.truncated,
            value: text.value
        )
    }
}
