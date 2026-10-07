import AppKit
import CollectorCore
import Foundation

enum SystemEventsReadFailure: Error, Equatable {
    case accessibilityPermissionDenied
    case malformedResponse
    case noFocusedWindow
    case pageContextUnavailable
    case unavailable
}

struct FirefoxObservation: Equatable {
    let identity: FirefoxObservationIdentity
    let classification: SurfaceClassification
    let diagnosticContext: TransientBrowserContext?
}

final class SystemEventsClient: @unchecked Sendable {
    static let firefoxBundleID = "org.mozilla.firefox"

    func readFirefoxFrontmostContext() -> Result<FirefoxObservation, SystemEventsReadFailure> {
        let context: ApplicationWindowContext
        switch ApplicationWindowContextClient().read(bundleID: Self.firefoxBundleID) {
        case .unavailable("application_not_running"), .noFocusedWindow:
            return .failure(.noFocusedWindow)
        case .unavailable("accessibility_permission"):
            return .failure(.accessibilityPermissionDenied)
        case .unavailable:
            return .failure(.pageContextUnavailable)
        case let .captured(value):
            context = value
        }
        let windowTitle = context.title

        let isProtected = ["private", "사생활 보호", "개인 정보 보호"].contains {
            windowTitle?.localizedCaseInsensitiveContains($0) == true
        }
        if isProtected {
            return .success(FirefoxObservation(
                identity: FirefoxObservationIdentity(
                    windowFingerprint: windowTitle.hashValue,
                    contentFingerprint: 0
                ),
                classification: SurfaceClassifier.classify(urlString: nil, protectedContext: true),
                diagnosticContext: nil
            ))
        }

        let pageURL = context.browserURL
        var hasher = Hasher()
        hasher.combine(windowTitle)
        hasher.combine(pageURL)
        let classification = pageURL.map {
            SurfaceClassifier.classify(urlString: $0, protectedContext: false)
        } ?? SurfaceClassification(
            registeredDomain: nil,
            surfaceType: .application,
            observationState: .observed,
            protectedContext: false
        )
        return .success(FirefoxObservation(
            identity: FirefoxObservationIdentity(
                windowFingerprint: windowTitle.hashValue,
                contentFingerprint: hasher.finalize()
            ),
            classification: classification,
            diagnosticContext: TransientBrowserContext(
                title: windowTitle,
                url: pageURL,
                windowTitle: windowTitle
            )
        ))
    }

}
