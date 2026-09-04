import AppKit
import CollectorCore
import Foundation

enum ChromeReadFailure: Error, Equatable {
    case automationPermissionDenied
    case malformedResponse
    case unavailable
}

enum ChromeReadResult: Equatable {
    case notRunning
    case noWindow
    case observation(ChromeObservation)
}

enum ChromeAutomationPermissionResult: Equatable {
    case granted
    case denied
    case chromeNotRunning
    case unavailable
}

struct TransientBrowserContext: Equatable {
    let title: String?
    let url: String?
}

struct ChromeObservation: Equatable {
    let identity: ChromeObservationIdentity
    let diagnosticContext: TransientBrowserContext?
}

final class ChromeAppleEventClient: @unchecked Sendable {
    static let bundleID = "com.google.Chrome"

    private static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )

    func requestAutomationPermission() -> ChromeAutomationPermissionResult {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else {
            return .chromeNotRunning
        }

        let source = """
        tell application id "com.google.Chrome"
            return version
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

    func readFrontmostContext() -> Result<ChromeReadResult, ChromeReadFailure> {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else {
            return .success(.notRunning)
        }

        let source = """
        tell application id "com.google.Chrome"
            if (count of windows) is 0 then return {"no_window"}
            set targetWindow to window 1
            set windowIdentifier to (id of targetWindow) as text
            set windowMode to (mode of targetWindow) as text
            if windowMode is "incognito" then return {"protected", windowIdentifier}
            set tabIndex to active tab index of targetWindow
            set targetTab to active tab of targetWindow
            return {"normal", windowIdentifier, (tabIndex as text), ((id of targetTab) as text), (URL of targetTab), (title of targetTab)}
        end tell
        """

        switch execute(source: source) {
        case let .failure(error):
            return .failure(error)
        case let .success(descriptor):
            guard let tag = descriptor.atIndex(1)?.stringValue else {
                return .failure(.malformedResponse)
            }
            if tag == "no_window" { return .success(.noWindow) }

            guard let windowID = descriptor.atIndex(2)?.integerValue else {
                return .failure(.malformedResponse)
            }

            if tag == "protected" {
                let classification = SurfaceClassifier.classify(urlString: nil, protectedContext: true)
                return .success(.observation(ChromeObservation(
                    identity: ChromeObservationIdentity(
                        windowID: windowID,
                        tabID: -1,
                        urlFingerprint: 0,
                        classification: classification
                    ),
                    diagnosticContext: nil
                )))
            }

            guard
                tag == "normal",
                let tabID = descriptor.atIndex(4)?.integerValue,
                let transientURL = descriptor.atIndex(5)?.stringValue,
                let transientTitle = descriptor.atIndex(6)?.stringValue
            else {
                return .failure(.malformedResponse)
            }

            let classification = SurfaceClassifier.classify(
                urlString: transientURL,
                protectedContext: false
            )
            return .success(.observation(ChromeObservation(
                identity: ChromeObservationIdentity(
                    windowID: windowID,
                    tabID: tabID,
                    urlFingerprint: transientURL.hashValue,
                    classification: classification
                ),
                diagnosticContext: TransientBrowserContext(
                    title: transientTitle,
                    url: transientURL
                )
            )))
        }
    }

    func activate(windowID: Int, tabID: Int) -> Result<Void, ReturnFailureReason> {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else {
            return .failure(.applicationTerminated)
        }

        let source = """
        tell application id "com.google.Chrome"
            set targetWindow to missing value
            repeat with candidateWindow in windows
                if (id of candidateWindow) is \(windowID) then
                    set targetWindow to candidateWindow
                    exit repeat
                end if
            end repeat
            if targetWindow is missing value then return "window_unavailable"
            if (mode of targetWindow as text) is "incognito" then return "protected"
            set targetIndex to 0
            repeat with candidateIndex from 1 to (count of tabs of targetWindow)
                if (id of tab candidateIndex of targetWindow) is \(tabID) then
                    set targetIndex to candidateIndex
                    exit repeat
                end if
            end repeat
            if targetIndex is 0 then return "tab_unavailable"
            set active tab index of targetWindow to targetIndex
            set index of targetWindow to 1
            activate
            return "success"
        end tell
        """

        switch execute(source: source) {
        case let .failure(error):
            return .failure(error == .automationPermissionDenied ? .automationPermissionDenied : .unknown)
        case let .success(descriptor):
            switch descriptor.stringValue {
            case "success": return .success(())
            case "window_unavailable": return .failure(.windowUnavailable)
            case "tab_unavailable": return .failure(.tabUnavailable)
            case "protected": return .failure(.protectedContext)
            default: return .failure(.unknown)
            }
        }
    }

    private func execute(source: String) -> Result<NSAppleEventDescriptor, ChromeReadFailure> {
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

private extension NSAppleEventDescriptor {
    var integerValue: Int? {
        if let text = stringValue, let value = Int(text) { return value }
        return Int(int32Value)
    }
}
