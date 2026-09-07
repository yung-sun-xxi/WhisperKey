import AppKit
import Foundation

/// What one poll of a pasteboard yields.
public struct ClipboardContent: Equatable, Sendable {
    /// `nil` when the pasteboard holds no plain string — an image, a file promise, and so on.
    public let string: String?
    /// Type identifiers present on the pasteboard's first item.
    public let types: Set<String>

    public init(string: String?, types: Set<String> = []) {
        self.string = string
        self.types = types
    }
}

/// The system boundary the monitor sits behind, so tests drive a fake pasteboard and no
/// test needs the live clipboard.
public protocol ClipboardReading: AnyObject {
    var changeCount: Int { get }
    func read() -> ClipboardContent
}

public final class SystemClipboardReader: ClipboardReading {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func read() -> ClipboardContent {
        let types = Set(pasteboard.pasteboardItems?.first?.types.map(\.rawValue) ?? [])
        return ClipboardContent(string: pasteboard.string(forType: .string), types: types)
    }
}

/// Polls the pasteboard's change counter and hands whatever appears to a sink.
///
/// Polling is the only mechanism macOS offers; there is no change notification.
public final class ClipboardMonitor {
    /// The convention password managers write so clipboard managers skip their item. It
    /// is a convention, not a guarantee.
    ///
    /// An item carrying it is recorded like any other — the popup exists so that a
    /// password copied a minute ago is still reachable. The marker travels with the entry
    /// instead, and stops it at the edge of the file: see `ClipboardHistoryStore`.
    public static let concealedTypeIdentifier = "org.nspasteboard.ConcealedType"

    public typealias Capture = (String, ClipboardEntryOrigin, Bool) -> Void

    private let pasteboard: ClipboardReading
    private let pollInterval: TimeInterval
    private let onCapture: Capture
    private var timer: Timer?
    private var lastChangeCount: Int

    public private(set) var isSuspended = false
    public var isRunning: Bool { timer != nil }

    public init(
        pasteboard: ClipboardReading,
        pollInterval: TimeInterval = 0.5,
        onCapture: @escaping Capture
    ) {
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.onCapture = onCapture
        self.lastChangeCount = pasteboard.changeCount
    }

    public convenience init(pollInterval: TimeInterval = 0.5, onCapture: @escaping Capture) {
        self.init(pasteboard: SystemClipboardReader(), pollInterval: pollInterval, onCapture: onCapture)
    }

    /// Baselines against whatever is on the pasteboard right now — what was already there
    /// when the app launched is not a fresh copy — and starts polling.
    public func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Silences the monitor around the paste path's own clipboard swap.
    public func suspend() {
        isSuspended = true
    }

    /// Re-baselines against the change counter as it stands *now*, then listens again.
    ///
    /// This is load-bearing, not tidiness. A swap-and-restore moves the counter by two,
    /// because each write clears the pasteboard first. Resuming against the baseline from
    /// before the swap makes the very next poll see an unfamiliar counter and record the
    /// restored content as a fresh copy — and de-duplication does not save it, because the
    /// restore may put back something other than the newest entry, or nothing at all.
    public func resume() {
        lastChangeCount = pasteboard.changeCount
        isSuspended = false
    }

    /// A monitor that records everything it captures into `store`, concealment included.
    ///
    /// This is the join between the two halves of the target, and it lives here rather
    /// than at the call site so it is covered by a test instead of by eye.
    public static func recording(
        into store: ClipboardHistoryStore,
        pasteboard: ClipboardReading = SystemClipboardReader(),
        pollInterval: TimeInterval = 0.5
    ) -> ClipboardMonitor {
        ClipboardMonitor(pasteboard: pasteboard, pollInterval: pollInterval) { [weak store] text, origin, isConcealed in
            store?.record(text: text, origin: origin, isConcealed: isConcealed)
        }
    }

    /// One poll. The timer calls this; tests call it directly.
    public func poll() {
        guard !isSuspended else { return }

        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        let content = pasteboard.read()
        guard let string = content.string else { return }
        // Recorded, not skipped — but flagged, so the store keeps it out of the file.
        let isConcealed = content.types.contains(Self.concealedTypeIdentifier)
        onCapture(string, ClipboardOriginMarker.origin(forTypes: content.types), isConcealed)
    }
}
