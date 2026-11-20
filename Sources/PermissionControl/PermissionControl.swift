import AVFoundation
import Foundation

/// A system permission WhisperKey uses, one row of the Settings Permissions tab (#225).
public enum PermissionKind: String, CaseIterable, Sendable {
    case microphone
    case accessibility
    case appleMusic

    /// The row's label.
    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .appleMusic: return "Automation: Apple Music"
        }
    }

    /// The row's hint: what the permission is for.
    public var purpose: String {
        switch self {
        case .microphone: return "Records your voice for transcription."
        case .accessibility: return "Lets the hotkey, auto-paste and quick paste work in any app."
        case .appleMusic: return "Pauses Apple Music while you record."
        }
    }

    /// The service name `tccutil reset` takes for this permission.
    public var tccService: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .appleMusic: return "AppleEvents"
        }
    }
}

/// What macOS says about one permission.
public enum PermissionStatus: Equatable, Sendable {
    case allowed
    case notAllowed
    case notAsked
    /// macOS cannot say: for Apple Music, while Music is not running.
    case unknown

    /// The `OSStatus` values `AEDeterminePermissionToAutomateTarget` answers with.
    public enum AutomationResult {
        public static let allowed: Int32 = 0                  // noErr
        public static let notAllowed: Int32 = -1743           // errAEEventNotPermitted
        public static let wouldRequireConsent: Int32 = -1744  // errAEEventWouldRequireUserConsent
        public static let targetNotRunning: Int32 = -600      // procNotFound
    }

    public static func microphone(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .allowed
        case .denied, .restricted: return .notAllowed
        case .notDetermined: return .notAsked
        @unknown default: return .unknown
        }
    }

    /// macOS reports only trusted or not; an app it has never been asked about reads as
    /// not trusted too.
    public static func accessibility(trusted: Bool) -> PermissionStatus {
        trusted ? .allowed : .notAllowed
    }

    /// From `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded: false)`. Any
    /// answer other than the three known ones leaves the status unknown.
    public static func automation(_ result: Int32) -> PermissionStatus {
        switch result {
        case AutomationResult.allowed: return .allowed
        case AutomationResult.notAllowed: return .notAllowed
        case AutomationResult.wouldRequireConsent: return .notAsked
        default: return .unknown
        }
    }

    /// The status as the row shows it.
    public func text(for kind: PermissionKind) -> String {
        switch self {
        case .allowed: return "Allowed"
        case .notAllowed: return "Not allowed"
        case .notAsked: return "Not asked"
        case .unknown:
            return kind == .appleMusic ? "Unknown until Apple Music is open" : "Unknown"
        }
    }
}

/// The one button a row carries.
public enum PermissionRowAction: Equatable, Sendable {
    /// Resets the permission with `tccutil`, after a confirmation.
    case revoke
    /// Asks for the microphone the way onboarding does.
    case allowMicrophone
    /// Opens the permission's pane in System Settings.
    case openSystemSettings

    public var buttonTitle: String {
        switch self {
        case .revoke: return "Revoke"
        case .allowMicrophone: return "Allow Microphone"
        case .openSystemSettings: return "Open System Settings"
        }
    }

    /// Revoke for a granted permission, and for Apple Music while its status is unknown
    /// (a reset of a permission that was never given changes nothing). Otherwise the
    /// action the popover banner and onboarding use.
    public static func action(for kind: PermissionKind, status: PermissionStatus) -> PermissionRowAction {
        switch status {
        case .allowed:
            return .revoke
        case .unknown:
            return kind == .appleMusic ? .revoke : .openSystemSettings
        case .notAsked:
            return kind == .microphone ? .allowMicrophone : .openSystemSettings
        case .notAllowed:
            return .openSystemSettings
        }
    }
}

/// The question asked before Revoke runs.
public struct PermissionRevokePrompt: Equatable, Sendable {
    public static let confirmButtonTitle = "Revoke"
    public static let cancelButtonTitle = "Cancel"

    public let title: String
    public let informativeText: String

    public init(kind: PermissionKind) {
        switch kind {
        case .microphone:
            title = "Revoke Microphone access?"
            informativeText = "WhisperKey will ask for the microphone again the next time you record."
        case .accessibility:
            title = "Revoke Accessibility access?"
            informativeText = "The hotkey, auto-paste and quick paste stop working until you allow Accessibility again."
        case .appleMusic:
            title = "Revoke Apple Music automation?"
            informativeText = "WhisperKey will ask again the next time it pauses Apple Music."
        }
    }
}

/// `/usr/bin/tccutil reset <service> <bundle id>`.
public enum TCCResetCommand {
    public static let executable = URL(fileURLWithPath: "/usr/bin/tccutil")

    public static func arguments(for kind: PermissionKind, bundleIdentifier: String) -> [String] {
        ["reset", kind.tccService, bundleIdentifier]
    }
}

/// What a finished command left behind.
public struct CommandOutput: Equatable, Sendable {
    public var exitStatus: Int32
    public var standardError: String

    public init(exitStatus: Int32, standardError: String) {
        self.exitStatus = exitStatus
        self.standardError = standardError
    }
}

/// Runs a command to completion. The app runs `tccutil` through `ProcessCommandRunner`;
/// tests pass a fake, so no test ever resets a real permission.
public protocol CommandRunning: Sendable {
    func run(_ executable: URL, arguments: [String]) async throws -> CommandOutput
}

/// Runs the command with `Process`, off the caller's thread, and collects its standard
/// error.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: URL, arguments: [String]) async throws -> CommandOutput {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandOutput(
                exitStatus: process.terminationStatus,
                standardError: String(decoding: errorData, as: UTF8.self)
            )
        }.value
    }
}

/// Why a revoke did not happen.
public enum PermissionRevokeError: Error, Equatable, Sendable {
    case noBundleIdentifier
    case couldNotRun(message: String)
    case failed(exitStatus: Int32, message: String)

    /// The line the row shows under its button.
    public var userMessage: String {
        switch self {
        case .noBundleIdentifier:
            return "Couldn't revoke: the app has no bundle identifier."
        case .couldNotRun(let message):
            return "Couldn't revoke: \(message)"
        case .failed(let exitStatus, let message):
            return message.isEmpty
                ? "Couldn't revoke (error \(exitStatus))."
                : "Couldn't revoke: \(message)"
        }
    }
}

/// Resets one permission of one app with `tccutil`. macOS then treats it as never asked:
/// the next use asks again.
public struct PermissionRevoker: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func revoke(_ kind: PermissionKind, bundleIdentifier: String?) async -> Result<Void, PermissionRevokeError> {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .failure(.noBundleIdentifier)
        }

        let output: CommandOutput
        do {
            output = try await runner.run(
                TCCResetCommand.executable,
                arguments: TCCResetCommand.arguments(for: kind, bundleIdentifier: bundleIdentifier)
            )
        } catch {
            return .failure(.couldNotRun(message: error.localizedDescription))
        }

        guard output.exitStatus == 0 else {
            let message = output.standardError
                .split(whereSeparator: \.isNewline)
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            return .failure(.failed(exitStatus: output.exitStatus, message: message))
        }
        return .success(())
    }
}
