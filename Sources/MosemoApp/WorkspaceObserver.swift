import AppKit
import Foundation

final class WorkspaceObserver {
    var onActivatedApplication: ((NSRunningApplication) -> Void)?
    var onChromeLifecycleChange: (() -> Void)?
    var onAutomaticPause: ((String) -> Void)?
    var onAutomaticResume: ((String) -> Void)?

    private var tokens: [NSObjectProtocol] = []

    func start() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        tokens.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.onActivatedApplication?(application)
        })

        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    application.bundleIdentifier == ChromeAppleEventClient.bundleID
                else { return }
                self?.onChromeLifecycleChange?()
            })
        }

        for (name, reason) in [
            (NSWorkspace.willSleepNotification, "system_sleep"),
            (NSWorkspace.screensDidSleepNotification, "screen_sleep"),
            (NSWorkspace.sessionDidResignActiveNotification, "session_inactive"),
        ] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.onAutomaticPause?(reason)
            })
        }

        for (name, reason) in [
            (NSWorkspace.didWakeNotification, "system_sleep"),
            (NSWorkspace.screensDidWakeNotification, "screen_sleep"),
            (NSWorkspace.sessionDidBecomeActiveNotification, "session_inactive"),
        ] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.onAutomaticResume?(reason)
            })
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
    }

    deinit {
        stop()
    }
}
