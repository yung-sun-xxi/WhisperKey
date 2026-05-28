import AppKit
import os

@MainActor
final class TransientWindowStack {
    enum Layer: Int {
        case root = 0
        case secondary = 1
        case nested = 2
    }

    static let shared = TransientWindowStack()

    private static let log = Logger(subsystem: "WhisperKey", category: "TransientWindowStack")

    fileprivate final class Entry {
        let id: String
        let layer: Layer
        weak var window: NSWindow?
        let containsScreenPoint: ((NSPoint) -> Bool)?
        let dismiss: () -> Void

        init(
            id: String,
            layer: Layer,
            window: NSWindow,
            containsScreenPoint: ((NSPoint) -> Bool)?,
            dismiss: @escaping () -> Void
        ) {
            self.id = id
            self.layer = layer
            self.window = window
            self.containsScreenPoint = containsScreenPoint
            self.dismiss = dismiss
        }
    }

    private var entries: [Entry] = []
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    private init() {}

    func register(
        id: String,
        layer: Layer,
        window: NSWindow,
        containsScreenPoint: ((NSPoint) -> Bool)? = nil,
        dismiss: @escaping () -> Void
    ) {
        unregister(id: id)
        entries.append(Entry(
            id: id,
            layer: layer,
            window: window,
            containsScreenPoint: containsScreenPoint,
            dismiss: dismiss
        ))
        pruneClosedWindows()
        startMonitoringIfNeeded()
        Self.log.info("registered id=\(id, privacy: .public) layer=\(layer.rawValue, privacy: .public) count=\(self.entries.count, privacy: .public)")
    }

    func unregister(id: String) {
        let originalCount = entries.count
        entries.removeAll { $0.id == id || $0.window == nil }
        if entries.isEmpty {
            stopMonitoring()
        }
        if entries.count != originalCount {
            Self.log.info("unregistered id=\(id, privacy: .public) count=\(self.entries.count, privacy: .public)")
        }
    }

    func dismissAll() {
        dismiss(entriesToDismiss: liveEntries.sortedForDismissal(), reason: "all")
    }

    private func dismissAbove(layer: Layer) {
        let dismissible = liveEntries
            .filter { $0.layer.rawValue > layer.rawValue }
            .sortedForDismissal()
        dismiss(entriesToDismiss: dismissible, reason: "above-\(layer.rawValue)")
    }

    private func dismiss(entriesToDismiss dismissible: [Entry], reason: String) {
        guard !dismissible.isEmpty else { return }

        Self.log.info("dismiss reason=\(reason, privacy: .public) ids=\(dismissible.map(\.id).joined(separator: ","), privacy: .public)")
        for entry in dismissible {
            entry.dismiss()
        }
        pruneClosedWindows()
        if entries.isEmpty {
            stopMonitoring()
        }
    }

    private var liveEntries: [Entry] {
        entries.filter { $0.window != nil }
    }

    private func pruneClosedWindows() {
        entries.removeAll { $0.window == nil }
    }

    private func startMonitoringIfNeeded() {
        guard localMouseMonitor == nil, globalMouseMonitor == nil else { return }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalMouseDown(event)
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                TransientWindowStack.shared.handleGlobalMouseDown()
            }
        }

        Self.log.info("monitoring started")
    }

    private func stopMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }

        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func handleLocalMouseDown(_ event: NSEvent) -> NSEvent? {
        pruneClosedWindows()

        guard let clickedEntry = entry(containing: event.window)
            ?? entry(containingScreenPoint: screenPoint(for: event))
        else {
            Self.log.debug("localMouseDown unknown eventWindow=\(self.windowDescription(event.window), privacy: .public) point=\(String(describing: self.screenPoint(for: event)), privacy: .public) stack=\(self.stackDescription, privacy: .public)")
            return event
        }

        Self.log.debug("localMouseDown hit id=\(clickedEntry.id, privacy: .public) layer=\(clickedEntry.layer.rawValue, privacy: .public) eventWindow=\(self.windowDescription(event.window), privacy: .public) point=\(String(describing: self.screenPoint(for: event)), privacy: .public) stack=\(self.stackDescription, privacy: .public)")
        dismissAbove(layer: clickedEntry.layer)
        return event
    }

    private func handleGlobalMouseDown() {
        pruneClosedWindows()

        let point = NSEvent.mouseLocation
        guard let clickedEntry = entry(containingScreenPoint: point) else {
            Self.log.debug("globalMouseDown outside point=\(String(describing: point), privacy: .public) stack=\(self.stackDescription, privacy: .public)")
            dismissAll()
            return
        }

        Self.log.debug("globalMouseDown hit id=\(clickedEntry.id, privacy: .public) layer=\(clickedEntry.layer.rawValue, privacy: .public) point=\(String(describing: point), privacy: .public) stack=\(self.stackDescription, privacy: .public)")
        dismissAbove(layer: clickedEntry.layer)
    }

    private func entry(containing window: NSWindow?) -> Entry? {
        guard let window else { return nil }

        return liveEntries
            .sortedForHitTesting()
            .first { entry in
                guard let entryWindow = entry.window else { return false }

                return window === entryWindow
                    || window.parent === entryWindow
                    || window.sheetParent === entryWindow
                    || entryWindow.childWindows?.contains(where: { $0 === window }) == true
                    || entryWindow.attachedSheet === window
            }
    }

    private func entry(containingScreenPoint point: NSPoint?) -> Entry? {
        guard let point else { return nil }

        return liveEntries
            .sortedForHitTesting()
            .first { entry in
                entry.windowsForScreenHitTesting.contains { window in
                    window.isVisible && window.frame.contains(point)
                } || entry.containsScreenPoint?(point) == true
            }
    }

    private func screenPoint(for event: NSEvent) -> NSPoint? {
        guard let window = event.window else { return NSEvent.mouseLocation }

        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private var stackDescription: String {
        liveEntries
            .map { entry in
                "\(entry.id):\(entry.layer.rawValue):\(windowDescription(entry.window))"
            }
            .joined(separator: "|")
    }

    private func windowDescription(_ window: NSWindow?) -> String {
        guard let window else { return "nil" }

        return "\(type(of: window))#\(ObjectIdentifier(window).hashValue) title='\(window.title)' visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) frame=\(window.frame)"
    }
}

private extension Array where Element == TransientWindowStack.Entry {
    func sortedForHitTesting() -> [Element] {
        sorted { lhs, rhs in
            lhs.layer.rawValue > rhs.layer.rawValue
        }
    }

    func sortedForDismissal() -> [Element] {
        sorted { lhs, rhs in
            lhs.layer.rawValue > rhs.layer.rawValue
        }
    }
}

private extension TransientWindowStack.Entry {
    var windowsForScreenHitTesting: [NSWindow] {
        guard let window else { return [] }

        return ([window]
            + (window.childWindows ?? [])
            + [window.attachedSheet].compactMap(\.self))
    }
}
