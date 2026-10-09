import AppKit
import SwiftUI
import SettingsStore
import UsageStatsStore

/// The popover's usage summary split by provider and model (#139). It follows the
/// period picked in the popover and redraws when a new entry is recorded.
@MainActor
enum UsageBreakdownWindowController {
    private static let stackID = "usageBreakdown"
    private static var window: NSWindow?
    private static let delegate = UsageBreakdownWindowDelegate()

    static func show(usageStats: UsageStatsStore, settings: SettingsStore) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            register(existing)
            return
        }

        let host = NSHostingController(rootView: UsageBreakdownView(usageStats: usageStats, settings: settings))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Usage by model"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = SettingsWindowLayout.backgroundColor
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

    static func windowDidClose() {
        TransientWindowStack.shared.unregister(id: stackID)
        window = nil
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

private struct UsageBreakdownView: View {
    @ObservedObject var usageStats: UsageStatsStore
    @ObservedObject var settings: SettingsStore

    private static let contentWidth: CGFloat = 400

    var body: some View {
        let range = settings.usageStatsRange
        let rows = usageStats.breakdown(range: range)

        VStack(alignment: .leading, spacing: 10) {
            Text(range.displayName)
                .font(PopoverTypography.sectionTitle)
                .foregroundColor(PopoverTypography.secondaryColor)

            if rows.isEmpty {
                Text("No usage in this period.")
                    .font(PopoverTypography.base)
                    .foregroundColor(PopoverTypography.secondaryColor)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                    .background(HeaderSurfaceColor.bar, in: RoundedRectangle(cornerRadius: 7))
            } else {
                table(rows: rows, total: usageStats.totalSummary(range: range))
            }
        }
        .padding(SettingsWindowLayout.contentPadding)
        .frame(width: Self.contentWidth, alignment: .topLeading)
        .font(PopoverTypography.base)
        .foregroundColor(PopoverTypography.primaryColor)
    }

    private func table(rows: [UsageBreakdownRow], total: UsageSummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Model")
                Text("words").gridColumnAlignment(.trailing)
                Text("audio").gridColumnAlignment(.trailing)
                Text("cost").gridColumnAlignment(.trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(PopoverTypography.primaryColor.opacity(0.62))

            Divider()

            ForEach(rows) { row in
                GridRow {
                    Text(Self.modelName(for: row.key))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Self.modelName(for: row.key))
                    metrics(for: row.summary)
                }
            }

            Divider()

            GridRow {
                Text("Total")
                metrics(for: total)
            }
            .font(PopoverTypography.strongSectionTitle)
        }
        .padding(10)
        .background(HeaderSurfaceColor.bar, in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func metrics(for summary: UsageSummary) -> some View {
        Text(UsageLineFormatter.wordsLabel(summary.wordCount))
            .monospacedDigit()
        Text(UsageLineFormatter.compactAudioDurationLabel(summary.audioDurationSeconds))
            .monospacedDigit()
        Text(Self.costText(for: summary))
            .monospacedDigit()
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
