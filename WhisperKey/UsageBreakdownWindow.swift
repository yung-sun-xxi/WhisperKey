import AppKit
import Combine
import SwiftUI
import ThemeKit
import SettingsStore
import UsageStatsStore

/// The popover's usage summary split by provider and model (#139). It follows the
/// period picked in the popover and redraws when a new entry is recorded.
///
/// The look is ThemeKit's (#184): `ThemedUsageBreakdownView` in the shared small-window
/// chrome, `ThemedSurfaceWindow`. This file maps the usage store into plain rows.
@MainActor
enum UsageBreakdownWindowController {
    private static let stackID = "usageBreakdown"
    private static var window: NSWindow?
    private static var themeFollower: AnyCancellable?
    private static let delegate = UsageBreakdownWindowDelegate()

    /// The window while it is on screen, for the Debug build's snapshot hook.
    static var openWindow: NSWindow? {
        guard let window, window.isVisible else { return nil }
        return window
    }

    static func show(usageStats: UsageStatsStore, settings: SettingsStore) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            register(existing)
            return
        }

        ThemeTokensSource.shared.follow(settings)
        let host = NSHostingController(rootView: ThemedRoot("usageByModel") {
            UsageBreakdownContent(usageStats: usageStats, settings: settings)
        })
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Usage by model"
        window.isReleasedWhenClosed = false
        window.level = .floating
        ThemedSurfaceWindow.configure(window, tokens: ThemeTokensSource.shared.tokens)
        themeFollower = ThemedSurfaceWindow.follow(ThemeTokensSource.shared, window: window)
        window.center()
        window.delegate = delegate

        Self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        register(window)
    }

    static func hide() {
        TransientWindowStack.shared.unregister(id: stackID)

        guard let window else { return }

        window.orderOut(nil)
    }

    /// Closes the window and lets it go, as its close button does, so the next `show`
    /// builds it again. For the Debug build's snapshot hook, which shows it over another
    /// usage store.
    static func close() {
        guard let closing = window else { return }
        closing.delegate = nil
        windowDidClose()
        closing.close()
    }

    static func windowDidClose() {
        TransientWindowStack.shared.unregister(id: stackID)
        window = nil
        themeFollower = nil
    }

    private static func register(_ window: NSWindow) {
        TransientWindowStack.shared.register(
            id: stackID,
            layer: .secondary,
            window: window
        ) {
            UsageBreakdownWindowController.hide()
        }
    }
}

@MainActor
private final class UsageBreakdownWindowDelegate: NSObject, NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            UsageBreakdownWindowController.windowDidClose()
        }
    }
}

/// The store's rows for the period picked, as the drawn view takes them, with the
/// popover's period picker on the band.
private struct UsageBreakdownContent: View {
    @ObservedObject var usageStats: UsageStatsStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        let range = settings.usageStatsRange

        ThemedUsageBreakdownView(
            rows: usageStats.breakdown(range: range).map { Self.line(for: $0) },
            total: Self.figures(for: usageStats.totalSummary(range: range))
        ) {
            ThemedPeriodPicker(
                "Usage stats range",
                selection: $settings.usageStatsRange,
                options: UsageStatsRange.allCases,
                title: { $0.compactLabel },
                help: { $0.displayName }
            )
            .help("Choose the usage stats range")
        }
    }

    private static func line(for row: UsageBreakdownRow) -> UsageBreakdownLine {
        UsageBreakdownLine(
            id: "\(row.key.providerID)/\(row.key.modelID)",
            title: modelName(for: row.key),
            figures: figures(for: row.summary)
        )
    }

    private static func figures(for summary: UsageSummary) -> UsageBreakdownFigures {
        UsageBreakdownFigures(
            words: UsageLineFormatter.wordsLabel(summary.wordCount),
            audio: UsageLineFormatter.compactAudioDurationLabel(summary.audioDurationSeconds),
            cost: costText(for: summary)
        )
    }

    private static func modelName(for key: ProviderModelKey) -> String {
        let provider = TranscriptionProviderID(rawValue: key.providerID)?.shortDisplayName ?? key.providerID
        return "\(provider) · \(key.modelID)"
    }

    /// Same rule as the popover's summary row: no single-currency price, no figure.
    private static func costText(for summary: UsageSummary) -> String {
        guard let cost = summary.estimatedCost, let currency = summary.currency else {
            return "-"
        }
        return UsageLineFormatter.compactApproximateCostLabel(cost, currency: currency)
    }
}
