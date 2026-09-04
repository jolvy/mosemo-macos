import AppKit
import ApplicationServices
import CollectorCore
import Foundation

final class AccessibilityWindowReference {
    let processIdentifier: pid_t
    let element: AXUIElement

    init(processIdentifier: pid_t, element: AXUIElement) {
        self.processIdentifier = processIdentifier
        self.element = element
    }
}

enum FirefoxReadFailure: Error, Equatable {
    case accessibilityPermissionMissing
    case noFocusedWindow
    case pageContextUnavailable
}

struct FirefoxObservation: Equatable {
    let identity: FirefoxObservationIdentity
    let classification: SurfaceClassification
    let diagnosticContext: TransientBrowserContext?
}

final class AccessibilityClient: @unchecked Sendable {
    static let firefoxBundleID = "org.mozilla.firefox"

    private static let permissionSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestPermissionPrompt() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func openPermissionSettings() -> Bool {
        guard let url = Self.permissionSettingsURL else { return false }
        return NSWorkspace.shared.open(url)
    }

    func captureFocusedWindow(processIdentifier: pid_t) -> AccessibilityWindowReference? {
        guard isTrusted else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard result == .success, let value else { return nil }
        return AccessibilityWindowReference(
            processIdentifier: processIdentifier,
            element: unsafeBitCast(value, to: AXUIElement.self)
        )
    }

    func readFirefoxFrontmostContext(
        processIdentifier: pid_t
    ) -> Result<FirefoxObservation, FirefoxReadFailure> {
        guard isTrusted else { return .failure(.accessibilityPermissionMissing) }
        guard let reference = captureFocusedWindow(processIdentifier: processIdentifier) else {
            return .failure(.noFocusedWindow)
        }

        let scan = scanFirefoxWindow(reference.element)
        if scan.protectedContext {
            return .success(FirefoxObservation(
                identity: FirefoxObservationIdentity(
                    windowFingerprint: Int(truncatingIfNeeded: CFHash(reference.element)),
                    contentFingerprint: 0
                ),
                classification: SurfaceClassifier.classify(
                    urlString: nil,
                    protectedContext: true
                ),
                diagnosticContext: nil
            ))
        }

        guard scan.title != nil || scan.url != nil else {
            return .failure(.pageContextUnavailable)
        }

        var hasher = Hasher()
        hasher.combine(scan.title)
        hasher.combine(scan.url)
        return .success(FirefoxObservation(
            identity: FirefoxObservationIdentity(
                windowFingerprint: Int(truncatingIfNeeded: CFHash(reference.element)),
                contentFingerprint: hasher.finalize()
            ),
            classification: SurfaceClassifier.classify(
                urlString: scan.url,
                protectedContext: false
            ),
            diagnosticContext: TransientBrowserContext(title: scan.title, url: scan.url)
        ))
    }

    func activate(_ reference: AccessibilityWindowReference) -> ReturnOutcome {
        guard isTrusted else { return .failure(.accessibilityPermissionMissing) }
        guard let application = NSRunningApplication(processIdentifier: reference.processIdentifier), !application.isTerminated else {
            return .failure(.applicationTerminated)
        }

        let raiseResult = AXUIElementPerformAction(reference.element, kAXRaiseAction as CFString)
        guard raiseResult == .success else { return .failure(.windowUnavailable) }

        let activated = application.activate(options: [])
        return activated ? .success : .failure(.activationRejected)
    }


    private func scanFirefoxWindow(
        _ window: AXUIElement
    ) -> (title: String?, url: String?, protectedContext: Bool) {
        let windowTitle = stringAttribute(kAXTitleAttribute as String, of: window)
        var pageTitle: String?
        var pageURL: String?
        var addressBarURL: String?
        var protectedContext = containsPrivateBrowsingMarker(windowTitle)
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        var inspected = 0

        while index < queue.count, inspected < 800 {
            let (element, depth) = queue[index]
            index += 1
            inspected += 1

            let role = stringAttribute(kAXRoleAttribute as String, of: element)
            let identifier = stringAttribute(kAXIdentifierAttribute as String, of: element)
            let domIdentifier = stringAttribute(kAXDOMIdentifierAttribute as String, of: element)
            let description = stringAttribute(kAXDescriptionAttribute as String, of: element)

            if [identifier, domIdentifier, description].contains(where: containsPrivateBrowsingMarker) {
                protectedContext = true
            }

            if role == "AXWebArea" {
                if pageTitle == nil {
                    pageTitle = stringAttribute(kAXTitleAttribute as String, of: element)
                }
                if pageURL == nil {
                    pageURL = urlAttribute(of: element)
                }
                continue
            }

            let normalizedIdentifier = [identifier, domIdentifier]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            if addressBarURL == nil,
               normalizedIdentifier.contains("urlbar"),
               role == kAXTextFieldRole as String {
                addressBarURL = stringAttribute(kAXValueAttribute as String, of: element)
            }

            guard depth < 12 else { continue }
            queue.append(contentsOf: children(of: element).map { ($0, depth + 1) })
        }

        let title = pageTitle ?? windowTitle
        return (title, pageURL ?? addressBarURL, protectedContext)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func urlAttribute(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXURLAttribute as CFString,
            &value
        ) == .success else { return nil }
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    private func containsPrivateBrowsingMarker(_ value: String?) -> Bool {
        guard let normalized = value?.lowercased() else { return false }
        return [
            "private browsing",
            "private window",
            "개인 정보 보호 브라우징",
            "사생활 보호 모드",
        ].contains { normalized.contains($0) }
    }
}
