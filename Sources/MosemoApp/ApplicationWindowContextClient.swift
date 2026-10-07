import AppKit
import ApplicationServices
import Foundation

struct ApplicationWindowContext: Equatable, Sendable {
    let title: String?
    let browserURL: String?
}

enum ApplicationWindowReadResult: Equatable, Sendable {
    case captured(ApplicationWindowContext)
    case noFocusedWindow
    case unavailable(String)
}

final class ApplicationWindowContextClient: @unchecked Sendable {
    private let firefoxBundleID = SystemEventsClient.firefoxBundleID

    func read(bundleID: String) -> ApplicationWindowReadResult {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).first else { return .unavailable("application_not_running") }
        guard AXIsProcessTrusted() else { return .unavailable("accessibility_permission") }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.75)
        guard let window = focusedWindow(of: applicationElement) else {
            return .noFocusedWindow
        }

        let title = stringAttribute(kAXTitleAttribute, of: window)
        let browserURL = bundleID == firefoxBundleID ? firefoxAddress(in: window) : nil
        guard title != nil || browserURL != nil else {
            return .unavailable("window_title_unavailable")
        }
        return .captured(ApplicationWindowContext(title: title, browserURL: browserURL))
    }

    private func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXFocusedWindowAttribute, of: application)
    }

    private func firefoxAddress(in window: AXUIElement) -> String? {
        var pending: [(element: AXUIElement, depth: Int, inToolbar: Bool)] = [(window, 0, false)]
        var visited = 0

        while !pending.isEmpty, visited < 300 {
            let current = pending.removeFirst()
            visited += 1

            let element = current.element
            let role = stringAttribute(kAXRoleAttribute, of: element)
            let inToolbar = current.inToolbar || role == kAXToolbarRole as String
            // Never descend into page content or read an actively edited address field.
            if role == "AXWebArea" { continue }
            if inToolbar, role == kAXComboBoxRole as String,
               isFirefoxAddressField(element),
               (attribute(kAXFocusedAttribute, of: element) as? Bool) == false,
               let value = stringAttribute(kAXValueAttribute, of: element),
               !value.isEmpty {
                return value
            }

            guard current.depth < 7,
                  let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] else {
                continue
            }
            pending.append(contentsOf: children.map { ($0, current.depth + 1, inToolbar) })
        }
        return nil
    }

    private func isFirefoxAddressField(_ element: AXUIElement) -> Bool {
        let description = stringAttribute(kAXDescriptionAttribute, of: element)?.lowercased() ?? ""
        let title = stringAttribute(kAXTitleAttribute, of: element)?.lowercased() ?? ""
        let label = description + " " + title
        return ["address", "url", "주소"].contains { label.contains($0) }
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
