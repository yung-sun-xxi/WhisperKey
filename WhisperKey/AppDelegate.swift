import AppKit
import os
import SingleInstance

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "WhisperKey", category: "AppDelegate")
    private var menuBarController: MenuBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let runningApplications = NSWorkspace.shared.runningApplications
        let snapshot = runningApplications.map {
            RunningProcess(bundleIdentifier: $0.bundleIdentifier, processIdentifier: $0.processIdentifier)
        }
        let mePID = ProcessInfo.processInfo.processIdentifier
        let ourID = Bundle.main.bundleIdentifier
        let ourBundlePath = Bundle.main.bundlePath
        let ourExecutablePath = Bundle.main.executablePath ?? "nil"
        let matchingApplications = runningApplications.filter {
            $0.bundleIdentifier == ourID && $0.processIdentifier != mePID
        }
        let matchingDescription = matchingApplications
            .map { app in
                let bundlePath = app.bundleURL?.path ?? "nil"
                let executablePath = app.executableURL?.path ?? "nil"
                return "pid=\(app.processIdentifier) bundle=\(bundlePath) executable=\(executablePath)"
            }
            .joined(separator: " | ")

        Self.log.info("willFinishLaunching pid=\(mePID, privacy: .public) bundleID=\(ourID ?? "nil", privacy: .public) bundlePath=\(ourBundlePath, privacy: .public) executablePath=\(ourExecutablePath, privacy: .public) matchingInstances=\(matchingApplications.count, privacy: .public) matches=\(matchingDescription, privacy: .public)")

        guard SingleInstanceCheck.anotherInstanceIsRunning(
            ourBundleIdentifier: ourID,
            selfPID: mePID,
            runningProcesses: snapshot
        ) else { return }

        Self.log.info("another WhisperKey instance is already running; activating it and exiting pid=\(mePID, privacy: .public)")

        if let other = matchingApplications.first {
            Self.log.info("activating existing instance pid=\(other.processIdentifier, privacy: .public) bundlePath=\(other.bundleURL?.path ?? "nil", privacy: .public) executablePath=\(other.executableURL?.path ?? "nil", privacy: .public)")
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
        Self.log.info("didFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public)")
        menuBarController = MenuBarController()
    }
}
