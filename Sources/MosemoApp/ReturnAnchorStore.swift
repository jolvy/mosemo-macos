import AppKit
import CollectorCore
import Foundation

private enum ReturnHandle {
    case application(processIdentifier: pid_t)
    case chromeTab(windowID: Int, tabID: Int)
}

final class ReturnAnchorStore {
    private let chrome: ChromeAppleEventClient
    private var handles: [UUID: ReturnHandle] = [:]

    init(chrome: ChromeAppleEventClient) {
        self.chrome = chrome
    }

    func captureCurrent(at date: Date = Date()) -> ReturnAnchorDescriptor? {
        guard
            let application = NSWorkspace.shared.frontmostApplication,
            let bundleID = application.bundleIdentifier
        else { return nil }

        if bundleID == ChromeAppleEventClient.bundleID {
            switch chrome.readFrontmostContext() {
            case let .success(.observation(observation)):
                let identity = observation.identity
                if identity.classification.protectedContext {
                    let descriptor = ReturnAnchorDescriptor(
                        kind: .application,
                        appBundleID: bundleID,
                        capturedAt: date,
                        protectedContext: true
                    )
                    handles[descriptor.identifier] = .application(
                        processIdentifier: application.processIdentifier
                    )
                    return descriptor
                }
                let descriptor = ReturnAnchorDescriptor(
                    kind: .chromeTab,
                    appBundleID: bundleID,
                    capturedAt: date,
                    protectedContext: false
                )
                handles[descriptor.identifier] = .chromeTab(
                    windowID: identity.windowID,
                    tabID: identity.tabID
                )
                return descriptor
            default:
                break
            }
        }

        let descriptor = ReturnAnchorDescriptor(
            kind: .application,
            appBundleID: bundleID,
            capturedAt: date,
            protectedContext: false
        )
        handles[descriptor.identifier] = .application(
            processIdentifier: application.processIdentifier
        )
        return descriptor
    }

    func activate(_ anchor: ReturnAnchorDescriptor) -> ReturnOutcome {
        guard !anchor.protectedContext else { return .failure(.protectedContext) }
        guard let handle = handles[anchor.identifier] else { return .failure(.noAnchor) }

        switch handle {
        case let .application(processIdentifier):
            guard let application = NSRunningApplication(processIdentifier: processIdentifier), !application.isTerminated else {
                return .failure(.applicationTerminated)
            }
            return application.activate(options: []) ? .success : .failure(.activationRejected)
        case let .chromeTab(windowID, tabID):
            switch chrome.activate(windowID: windowID, tabID: tabID) {
            case .success: return .success
            case let .failure(reason): return .failure(reason)
            }
        }
    }

    func removeAll() {
        handles.removeAll(keepingCapacity: false)
    }
}
