import Foundation
import XCTest

/// No hard-coded colour or size in the permissions onboarding window (#186), and its
/// wiring.
///
/// The same scan as `WelcomeSourceScanTests`. The drawn view, the badge, the push button
/// and the window chrome live in ThemeKit; the app's part, `WhisperKey/OnboardingWindow.swift`,
/// maps the coordinator's permissions onto the view, hosts it in the chrome and keeps the
/// window's behaviour. The application target has no test bundle, so that file is read
/// from the source: what this test holds is the text of the wiring, not the window it
/// builds.
final class PermissionsSourceScanTests: XCTestCase {
    private static let drawn = "Sources/ThemeKit/ThemedPermissionsView.swift"
    private static let controls = "Sources/ThemeKit/ThemedControls.swift"
    private static let chrome = "Sources/ThemeKit/ThemedSurfaceWindow.swift"
    private static let app = "WhisperKey/OnboardingWindow.swift"
    private static let hook = "WhisperKey/PermissionsSnapshotHook.swift"

    private static func source(_ path: String) throws -> String {
        try SettingsSourceScanTests.wholeFile(path).text
            .components(separatedBy: "\n").map(SettingsSourceScanTests.code(in:)).joined(separator: "\n")
    }

    private static func raw(_ path: String) throws -> String {
        try String(contentsOf: SettingsSourceScanTests.repositoryURL().appendingPathComponent(path), encoding: .utf8)
    }

    func testTheWindowHoldsNoLiteralColourOrSize() throws {
        var regions: [SettingsSourceScanTests.Region] = []
        var missing: [String] = []
        for path in [Self.drawn, Self.controls, Self.chrome, Self.app] {
            do { regions.append(try SettingsSourceScanTests.wholeFile(path)) } catch { missing.append("\(path): missing") }
        }
        let violations = missing + SettingsSourceScanTests.violations(in: regions)
        XCTAssertTrue(
            violations.isEmpty,
            "\(violations.count) literal colours or sizes:\n" + violations.joined(separator: "\n")
        )
    }

    /// The app's part holds no number but 0 and 1 beyond the text: every size is the
    /// tokens', and the general scan misses a size in an `NSRect` such as the old 520 × 1.
    /// Halving (`/ 2`) is the centring the window had and stays.
    func testTheAppsPartHoldsNoNumber() throws {
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])[0-9][0-9_]*(?:\.[0-9]+)?(?![A-Za-z0-9_])"#)
        var violations: [String] = []
        let code = try Self.source(Self.app).replacingOccurrences(of: "/ 2", with: "/ half")
        for (offset, line) in code.components(separatedBy: "\n").enumerated() {
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                let text = String(line[Range(match.range, in: line)!])
                if Double(text) != 0 && Double(text) != 1 { violations.append("\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        XCTAssertTrue(violations.isEmpty, "numbers:\n" + violations.joined(separator: "\n"))
    }

    /// The window is the drawn view under a `ThemedRoot`, sized to its fitting size, in the
    /// shared surface chrome that follows the theme while the window is kept; the old look
    /// is gone.
    func testTheWindowIsBuiltFromTheDrawnViewInTheSurfaceChrome() throws {
        let app = try Self.source(Self.app)
        let raw = try Self.raw(Self.app)
        XCTAssertTrue(raw.contains("ThemedRoot(\"permissions\") {"))
        XCTAssertTrue(app.contains("ThemedPermissionsView("), "the window does not host ThemedPermissionsView")
        XCTAssertTrue(app.contains("contentRect: NSRect(origin: .zero, size: hostingView.fittingSize)"))
        XCTAssertTrue(app.contains("window.setContentSize(hostingView.fittingSize)"))
        XCTAssertTrue(app.contains("ThemedSurfaceWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)"))
        XCTAssertTrue(app.contains("themeFollower = ThemedSurfaceWindow.follow(ThemeTokensSource.shared, window: window)"))
        XCTAssertNotNil(
            app.range(of: #"func windowWillClose[\s\S]*themeFollower = nil"#, options: .regularExpression),
            "the follower outlives the window"
        )
        for old in ["windowBackgroundColor", "controlBackgroundColor", "struct OnboardingView", "struct PermissionCard", "OnboardingWindowLayout", "backgroundColor", "Label("] {
            XCTAssertFalse(app.contains(old), "the window still uses \(old)")
        }
        for drawing in [#"\.font\("#, #"\.foregroundStyle\("#, #"\.foregroundColor\("#, #"\.background\("#, #"\bButton\("#, #"\bText\("#, #"\bImage\("#, #"\.padding\("#] {
            XCTAssertNil(app.range(of: drawing, options: .regularExpression), "the app's part draws on its own: \(drawing)")
        }
    }

    /// The window hosts the view that maps the coordinator's live permissions, so the
    /// cards follow a grant while the window is open.
    func testTheWindowShowsTheCoordinatorsPermissions() throws {
        let app = try Self.source(Self.app)
        XCTAssertNotNil(
            app.range(of: #"Self\.makeWindow\(\s*LivePermissionsView\(\)\s*\.environmentObject\(coordinator\)"#, options: .regularExpression),
            "the window does not show the live permissions"
        )
        XCTAssertNotNil(
            app.range(of: #"@EnvironmentObject private var coordinator: AppCoordinator[\s\S]*permissionsView\(for: coordinator\.permissions"#, options: .regularExpression),
            "the live view does not read the coordinator's permissions"
        )
    }

    /// The texts and actions stay: the microphone card offers "Allow Microphone" while its
    /// status is not determined, which asks; otherwise "Open System Settings", which opens
    /// the microphone pane, decided when tapped; the accessibility card "Open System
    /// Settings", which opens its pane. Granted is the state's own flag.
    func testTheCardsKeepTheirTitlesAndActions() throws {
        let app = try Self.source(Self.app)
        let raw = try Self.raw(Self.app)
        XCTAssertNotNil(
            raw.range(of: #"permissions\.microphoneStatus == \.notDetermined\s*\?\s*"Allow Microphone"\s*:\s*"Open System Settings""#, options: .regularExpression),
            "the microphone button's title changed"
        )
        XCTAssertNotNil(
            app.range(of: #"if coordinator\.permissions\.microphoneStatus == \.notDetermined \{\s*coordinator\.requestMicrophonePermission\(\)\s*\} else \{\s*coordinator\.openMicrophoneSettings\(\)"#, options: .regularExpression),
            "the microphone button's action changed"
        )
        XCTAssertTrue(app.contains("accessibility: coordinator.openAccessibilitySettings"), "the accessibility button's action changed")
        XCTAssertNotNil(
            raw.range(of: #"isGranted: permissions\.accessibilityGranted,\s*buttonTitle: "Open System Settings""#, options: .regularExpression),
            "the accessibility card's title or state changed"
        )
        XCTAssertTrue(app.contains("isGranted: permissions.microphoneGranted"), "the microphone card's state changed")
    }

    /// Behaviour kept: the title, the style, the spaces it joins, the z-order, centring,
    /// activating, closing for granted permissions and the user's own close.
    func testTheWindowKeepsTodaysBehaviour() throws {
        let app = try Self.source(Self.app)
        let raw = try Self.raw(Self.app)
        XCTAssertTrue(raw.contains("window.title = \"WhisperKey Permissions\""))
        XCTAssertTrue(app.contains("styleMask: [.titled, .closable]"))
        XCTAssertTrue(app.contains("window.isReleasedWhenClosed = false"))
        XCTAssertTrue(app.contains("window.delegate = self"))
        XCTAssertTrue(app.contains("window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]"))
        XCTAssertTrue(app.contains("ThemeTokensSource.shared.follow(coordinator.settings)"))
        XCTAssertTrue(app.contains("center(window)"))
        XCTAssertTrue(app.contains("applyZOrder(zOrderState, bringToFront: zOrderState == .aboveOrdinaryApps)"))
        XCTAssertTrue(app.contains("NSApp.activate(ignoringOtherApps: true)"))
        for part in [
            "case .aboveOrdinaryApps, .yieldingToMicrophonePrompt:",
            "window.level = .floating",
            "window.makeKeyAndOrderFront(nil)",
            "window.orderFrontRegardless()",
            "case .yieldingToAccessibilityPrompt, .yieldingToSystemSettings:",
            "window.level = .normal",
            "window.orderBack(nil)",
            "guard forceShow, !userExplicitlyClosed else { return }",
            "closingForGrantedPermissions = true",
            "userExplicitlyClosed = true",
            "if permissions.allGranted {",
        ] {
            XCTAssertTrue(app.contains(part), "the window lost \(part)")
        }
    }

    /// The drawn view keeps the texts, the glyphs and their order, and reads its tokens.
    func testTheDrawnViewKeepsTheTextsAndTheGlyphs() throws {
        let drawn = try Self.source(Self.drawn)
        let raw = try Self.raw(Self.drawn)
        var last: String.Index?
        for text in [
            "\"WhisperKey needs permissions\"",
            "\"Grant both permissions to record from the menu bar hotkey.\"",
            "glyph: \"mic\"",
            "title: \"Microphone\"",
            "message: \"Used only while recording after the hotkey starts capture.\"",
            "glyph: \"accessibility\"",
            "title: \"Accessibility\"",
            "message: \"Required for the global hotkey to work while other apps are focused.\"",
        ] {
            let range = try XCTUnwrap(raw.range(of: text), "\(text) is gone")
            if let last { XCTAssertLessThan(last, range.lowerBound, "\(text) moved") }
            last = range.lowerBound
        }
        XCTAssertTrue(raw.contains("\"Needs access\""))
        XCTAssertTrue(raw.contains("\"Granted\""))
        XCTAssertNotNil(
            raw.range(of: #"ThemedPushButton\(card\.buttonTitle, onCard: true, action: card\.action\)\s*\.disabled\(card\.isGranted\)"#, options: .regularExpression),
            "the button is not the push button, disabled when granted"
        )
        for part in [
            "tokens.permissions",
            "tokens.type.title.font",
            "tokens.type.small",
            "tokens.type.body.font",
            "tokens.type.caption.font",
            "tokens.type.bodyLineHeight",
            "tokens.colors.surface.color",
            "tokens.colors.divider.color",
            "tokens.colors.card.color",
            "tokens.colors.primaryText.color",
            "tokens.colors.secondaryText.color",
            "tokens.colors.success.color",
            "tokens.colors.failureFill.color",
            "tokens.colors.mutedEdge.color",
            "ThemedFailureHatch()",
            "dash: metrics.failureDash",
            "tokens.radii.card",
            "tokens.sizes.keycap",
            "tokens.sizes.dot",
        ] {
            XCTAssertTrue(drawn.contains(part), "the view does not read \(part)")
        }
        // The old badge glyphs are gone.
        for old in ["checkmark.circle.fill", "exclamationmark.circle.fill", "Label("] {
            XCTAssertFalse(drawn.contains(old), "the badge still draws \(old)")
        }
    }

    /// The push button: on a card its fill is `raisedControl`, disabled it has none and its
    /// label is `secondaryText`.
    func testThePushButtonHasTheCardAndDisabledLooks() throws {
        let controls = try Self.source(Self.controls)
        let start = try XCTUnwrap(controls.range(of: "public struct ThemedPushButton"), "no ThemedPushButton")
        let tail = String(controls[start.lowerBound...])
        let end = tail.range(of: "// MARK: - Default button")?.lowerBound ?? tail.endIndex
        let button = String(tail[..<end])
        for part in ["onCard", "colors.raisedControl", "isEnabled ? label : colors.secondaryText", "fill: isEnabled ?"] {
            XCTAssertTrue(button.contains(part), "the push button lost \(part)")
        }
    }

    /// The Debug-only snapshot hook is started with the others, shoots the app's window,
    /// and never asks for a permission, opens System Settings or writes anything but the
    /// theme it restores.
    func testTheSnapshotHookIsStartedAndLeavesThePermissionsAlone() throws {
        let controller = try Self.source("WhisperKey/MenuBarController.swift")
        XCTAssertTrue(controller.contains("PermissionsSnapshotHook.startIfRequested(settings: coordinator.settings)"))
        let hook = try Self.raw(Self.hook)
        XCTAssertTrue(hook.hasPrefix("#if DEBUG"), "the hook is not Debug-only")
        let code = try Self.source(Self.hook)
        XCTAssertTrue(code.contains("OnboardingWindowController.makeWindow("), "the hook does not shoot the app's window")
        XCTAssertTrue(code.contains("OnboardingWindowController.permissionsView(for:"), "the hook does not map its states as the app does")
        XCTAssertTrue(code.contains("microphoneStatus: .notDetermined"))
        XCTAssertTrue(code.contains("microphoneStatus: .authorized"))
        XCTAssertTrue(code.contains("settings.theme = originalTheme"), "the hook does not restore the theme")
        for write in [
            "requestMicrophonePermission",
            "openMicrophoneSettings",
            "openAccessibilitySettings",
            "requestAccess",
            "AXIsProcessTrustedWithOptions",
            "NSWorkspace",
            "refreshPermissions",
            "coordinator",
            "removeItem(",
        ] {
            XCTAssertFalse(code.contains(write), "the hook may change the permissions: \(write)")
        }
    }
}
