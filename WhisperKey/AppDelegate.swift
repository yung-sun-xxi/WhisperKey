import AppKit
import os
import SingleInstance

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "WhisperKey", category: "AppDelegate")
    private var menuBarController: MenuBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let snapshot = NSWorkspace.shared.runningApplications.map {
            RunningProcess(bundleIdentifier: $0.bundleIdentifier, processIdentifier: $0.processIdentifier)
        }
        let mePID = ProcessInfo.processInfo.processIdentifier
        let ourID = Bundle.main.bundleIdentifier

        guard SingleInstanceCheck.anotherInstanceIsRunning(
            ourBundleIdentifier: ourID,
            selfPID: mePID,
            runningProcesses: snapshot
        ) else { return }

        Self.log.info("another WhisperKey instance is already running; activating it and exiting")

        if let other = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == ourID && $0.processIdentifier != mePID
        }) {
            other.activate(options: [.activateAllWindows])
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "WhisperKey is already running"
        alert.informativeText = "Click the menu bar icon to use it."
        alert.addButton(withTitle: "OK")
        alert.runModal()

        NSApplication.shared.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
    }
}
