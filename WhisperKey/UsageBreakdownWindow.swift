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

    /// Wide enough for the longest "Provider · model" name next to the three figures,
    /// so names are never truncated and the window does not resize between periods.
    private static let contentWidth: CGFloat = 540
    private static let figureColumnWidth: CGFloat = 76

    var body: some View {
        let range = settings.usageStatsRange
        let rows = usageStats.breakdown(range: range)

        VStack(alignment: .leading, spacing: 14) {
            HeaderPeriodPicker(selection: $settings.usageStatsRange)

            if rows.isEmpty {
                Text("No usage in this period.")
                    .font(PopoverTypography.base)
                    .foregroundColor(PopoverTypography.secondaryColor)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    .background(HeaderSurfaceColor.bar, in: RoundedRectangle(cornerRadius: 8))
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
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                Text("Model")
                    .frame(maxWidth: .infinity, alignment: .leading)
                figureHeader("Words")
                figureHeader("Audio")
                figureHeader("Cost")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(PopoverTypography.secondaryColor)
            .padding(.bottom, 7)

            Divider()

            ForEach(rows) { row in
                GridRow {
                    Text(Self.modelName(for: row.key))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    figures(for: row.summary)
                }
                .padding(.vertical, 7)

                if row.id != rows.last?.id {
                    Divider().opacity(0.5)
                }
            }

            Divider()

            GridRow {
                Text("Total")
                    .frame(maxWidth: .infinity, alignment: .leading)
                figures(for: total)
            }
            .font(PopoverTypography.strongSectionTitle)
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(HeaderSurfaceColor.bar, in: RoundedRectangle(cornerRadius: 8))
    }

    private func figureHeader(_ title: String) -> some View {
        Text(title)
            .frame(width: Self.figureColumnWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func figures(for summary: UsageSummary) -> some View {
        figure(UsageLineFormatter.wordsLabel(summary.wordCount))
        figure(UsageLineFormatter.compactAudioDurationLabel(summary.audioDurationSeconds))
        figure(Self.costText(for: summary))
    }

    private func figure(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: Self.figureColumnWidth, alignment: .trailing)
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
