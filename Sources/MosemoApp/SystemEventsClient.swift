import AppKit
import CollectorCore
import Foundation

enum SystemEventsReadFailure: Error, Equatable {
    case automationPermissionDenied
    case malformedResponse
    case noFocusedWindow
    case pageContextUnavailable
    case unavailable
}

enum SystemEventsAutomationPermissionResult: Equatable {
    case granted
    case denied
    case firefoxNotRunning
    case unavailable
}

struct FirefoxObservation: Equatable {
    let identity: FirefoxObservationIdentity
    let classification: SurfaceClassification
    let diagnosticContext: TransientBrowserContext?
}

final class SystemEventsClient: @unchecked Sendable {
    static let firefoxBundleID = "org.mozilla.firefox"

    private static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )

    func requestAutomationPermission() -> SystemEventsAutomationPermissionResult {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.firefoxBundleID
        ).isEmpty else {
            return .firefoxNotRunning
        }

        let source = """
        tell application id "com.apple.systemevents"
            tell process "Firefox"
                return name of front window
            end tell
        end tell
        """

        switch execute(source: source) {
        case .success:
            return .granted
        case .failure(.automationPermissionDenied):
            return .denied
        case .failure:
            return .unavailable
        }
    }

    @discardableResult
    func openAutomationSettings() -> Bool {
        guard let url = Self.automationSettingsURL else { return false }
        return NSWorkspace.shared.open(url)
    }

    func readFirefoxFrontmostContext() -> Result<FirefoxObservation, SystemEventsReadFailure> {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.firefoxBundleID
        ).isEmpty else {
            return .failure(.unavailable)
        }

        let source = """
        tell application id "com.apple.systemevents"
            tell process "Firefox"
                if (count of windows) is 0 then return {"no_window"}

                set targetWindow to front window
                set windowTitle to ""
                try
                    set windowTitle to (value of attribute "AXTitle" of targetWindow) as text
                end try

                if windowTitle contains "Private" or windowTitle contains "private" or windowTitle contains "개인 정보 보호" or windowTitle contains "사생활 보호" then
                    return {"protected", windowTitle}
                end if

                set pageTitle to windowTitle
                try
                    set webArea to UI element 1 of UI element 1 of group 1 of group 2 of group 1 of targetWindow
                    set pageTitle to description of webArea
                end try

                set pageURL to ""
                try
                    set pageURL to (value of combo box 1 of group 2 of group 1 of toolbar 1 of group 1 of targetWindow) as text
                end try

                return {"normal", windowTitle, pageTitle, pageURL}
            end tell
        end tell
        """

        switch execute(source: source) {
        case let .failure(error):
            return .failure(error)
        case let .success(descriptor):
            guard let tag = descriptor.atIndex(1)?.stringValue else {
                return .failure(.malformedResponse)
            }
            if tag == "no_window" {
                return .failure(.noFocusedWindow)
            }
            if tag == "protected" {
                return .success(FirefoxObservation(
                    identity: FirefoxObservationIdentity(
                        windowFingerprint: descriptor.atIndex(2)?.stringValue?.hashValue ?? 0,
                        contentFingerprint: 0
                    ),
                    classification: SurfaceClassifier.classify(
                        urlString: nil,
                        protectedContext: true
                    ),
                    diagnosticContext: nil
                ))
            }

            guard
                tag == "normal",
                let windowTitle = descriptor.atIndex(2)?.stringValue,
                let pageTitle = descriptor.atIndex(3)?.stringValue,
                let pageURL = descriptor.atIndex(4)?.stringValue
            else {
                return .failure(.malformedResponse)
            }

            guard !windowTitle.isEmpty || !pageTitle.isEmpty || !pageURL.isEmpty else {
                return .failure(.pageContextUnavailable)
            }

            var hasher = Hasher()
            hasher.combine(pageTitle)
            hasher.combine(pageURL)
            return .success(FirefoxObservation(
                identity: FirefoxObservationIdentity(
                    windowFingerprint: windowTitle.hashValue,
                    contentFingerprint: hasher.finalize()
                ),
                classification: SurfaceClassifier.classify(
                    urlString: pageURL.isEmpty ? nil : pageURL,
                    protectedContext: false
                ),
                diagnosticContext: TransientBrowserContext(
                    title: pageTitle.isEmpty ? nil : pageTitle,
                    url: pageURL.isEmpty ? nil : pageURL
                )
            ))
        }
    }

    private func execute(source: String) -> Result<NSAppleEventDescriptor, SystemEventsReadFailure> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(.unavailable)
        }
        var details: NSDictionary?
        let descriptor = script.executeAndReturnError(&details)
        guard details == nil else {
            let number = details?[NSAppleScript.errorNumber] as? Int
            return .failure(number == -1743 ? .automationPermissionDenied : .unavailable)
        }
        return .success(descriptor)
    }
}
