import AppKit
import ClipboardHistoryStore
import Foundation
import os

private let outputLog = Logger(subsystem: "WhisperKey", category: "TranscriptionOutput")

public struct TranscriptionOutputSettings: Equatable, Sendable {
    public let saveToClipboard: Bool
    public let autoPaste: Bool

    public init(saveToClipboard: Bool, autoPaste: Bool) {
        self.saveToClipboard = saveToClipboard
        self.autoPaste = autoPaste
    }
}

public struct TranscriptionOutputResult: Equatable, Sendable {
    public let wroteClipboard: Bool
    public let pasteDecision: PasteDecision?
    public let restoredClipboard: Bool

    public init(wroteClipboard: Bool, pasteDecision: PasteDecision?, restoredClipboard: Bool) {
        self.wroteClipboard = wroteClipboard
        self.pasteDecision = pasteDecision
        self.restoredClipboard = restoredClipboard
    }
}

struct PasteboardSnapshot: Equatable {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(items: [[NSPasteboard.PasteboardType: Data]]) {
        self.items = items
    }
}

protocol TranscriptionPasteboard {
    func snapshot() -> PasteboardSnapshot
    /// Writes the string at once. For the paths that leave the transcript on the clipboard.
    @discardableResult func replaceWithString(_ string: String) -> Bool
    /// Writes the string as a promise kept on the first read, and hands back the signal
    /// that read fires; nil when the write failed. For the swap that restores afterwards:
    /// the signal is how it knows the paste target has taken the transcript.
    func replaceWithPromisedString(_ string: String) -> PasteboardReadSignal?
    @discardableResult func restore(_ snapshot: PasteboardSnapshot) -> Bool
}

/// Says that something read a promised clipboard write, and lets the swap wait for it.
///
/// Fired from the pasteboard's data provider, which AppKit calls on the main thread,
/// while the swap waits off it: every piece of state sits behind one lock. A waiter is
/// resumed exactly once, by whichever comes first of the read, its timeout and the
/// cancellation of its task; the other two find it gone.
///
/// The signal also keeps whatever it was given to retain alive — the data provider —
/// for as long as the swap holds the signal, so the promise never outlives its keeper.
final class PasteboardReadSignal: @unchecked Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }

    private let lock = NSLock()
    private var firedAt: UInt64?
    private var waiters: [UUID: Waiter] = [:]
    private let retained: AnyObject?

    init(retaining owner: AnyObject? = nil) {
        retained = owner
    }

    var hasFired: Bool { firedAtUptimeNanoseconds != nil }

    /// `DispatchTime` uptime of the first read, nil until it happens.
    var firedAtUptimeNanoseconds: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return firedAt
    }

    /// Records the read and wakes every waiter. Only the first call does anything.
    func fire() {
        lock.lock()
        guard firedAt == nil else {
            lock.unlock()
            return
        }
        firedAt = DispatchTime.now().uptimeNanoseconds
        let woken = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()

        for waiter in woken {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    /// True once the read has happened — at once if it already has — and false at the
    /// timeout or when the calling task is cancelled.
    func wait(timeoutNanoseconds: UInt64) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if firedAt != nil {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                // Checked under the lock: a cancellation that lands after this check runs
                // its handler after the waiter is in the table, and finds it there.
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                let timeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.resolve(id, with: false)
                }
                waiters[id] = Waiter(continuation: continuation, timeout: timeout)
                lock.unlock()
            }
        } onCancel: {
            resolve(id, with: false)
        }
    }

    private func resolve(_ id: UUID, with value: Bool) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        guard let waiter else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: value)
    }
}

/// Keeps the promise of a transcript: hands the text over on the first read and fires
/// the signal. AppKit asks once; after that it calls `pasteboardFinishedWithDataProvider`
/// and serves later reads from what was handed over.
///
/// The signal retains the provider and the provider the signal until AppKit is done
/// with it, so neither depends on who else holds them; the finish breaks the cycle.
private final class PromisedStringProvider: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private let lock = NSLock()
    private var signal: PasteboardReadSignal?

    init(text: String) {
        self.text = text
    }

    func attach(_ signal: PasteboardReadSignal) {
        lock.lock()
        self.signal = signal
        lock.unlock()
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        // Taken first: handing the text over can make AppKit call
        // `pasteboardFinishedWithDataProvider` from inside `setString`, which drops it.
        lock.lock()
        let signal = self.signal
        lock.unlock()
        item.setString(text, forType: type)
        signal?.fire()
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        lock.lock()
        signal = nil
        lock.unlock()
    }
}

struct SystemTranscriptionPasteboard: TranscriptionPasteboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func snapshot() -> PasteboardSnapshot {
        let snapshotItems = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                if let data = item.data(forType: type) {
                    result[type] = data
                }
            }
        } ?? []
        return PasteboardSnapshot(items: snapshotItems)
    }

    /// Writes the string together with WhisperKey's private origin marker.
    ///
    /// The marker is what lets `ClipboardMonitor` tell this write apart from a hand copy.
    /// It has to be produced here, at the point of writing: the monitor only ever sees
    /// that the change counter moved. It matters most in the `saveToClipboard: true`
    /// configuration, where this runs on a path with the monitor *not* suspended, so an
    /// unmarked transcription would be recorded as an ordinary hand copy.
    @discardableResult
    func replaceWithString(_ string: String) -> Bool {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        guard item.setString(string, forType: .string) else { return false }
        // Presence of the type is the signal; the value carries no meaning.
        item.setString(
            ClipboardOriginMarker.markerValue,
            forType: NSPasteboard.PasteboardType(ClipboardOriginMarker.pasteboardType)
        )
        return pasteboard.writeObjects([item])
    }

    /// Writes the string as a promise, with the origin marker set at once beside it.
    ///
    /// Only the string waits for a reader; the marker is plain data, so the monitor can
    /// still tell the write apart without reading — and thereby keeping — the promise.
    func replaceWithPromisedString(_ string: String) -> PasteboardReadSignal? {
        pasteboard.clearContents()
        let provider = PromisedStringProvider(text: string)
        let signal = PasteboardReadSignal(retaining: provider)
        provider.attach(signal)
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [.string]) else { return nil }
        item.setString(
            ClipboardOriginMarker.markerValue,
            forType: NSPasteboard.PasteboardType(ClipboardOriginMarker.pasteboardType)
        )
        guard pasteboard.writeObjects([item]) else { return nil }
        return signal
    }

    @discardableResult
    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return true }

        let items = snapshot.items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }
}

/// The clipboard history as the transcription path sees it: the monitor it silences
/// around its own swap, and the store its transcript goes into (#211).
///
/// The monitor and the store live on the main thread — the monitor's timer runs on the
/// main run loop and the store publishes to SwiftUI — while `deliver` runs off it. Every
/// method here is therefore main-actor, and the router awaits each one.
public struct TranscriptionClipboardHistory: @unchecked Sendable {
    private let monitor: ClipboardMonitor
    private let store: ClipboardHistoryStore

    public init(monitor: ClipboardMonitor, store: ClipboardHistoryStore) {
        self.monitor = monitor
        self.store = store
    }

    /// Silences the monitor and says whether this call did it. A monitor someone else
    /// already suspended is theirs to resume.
    ///
    /// A copy the monitor has not polled yet is taken first: `resume()` re-baselines, so
    /// anything still pending when the swap starts would otherwise be lost with it.
    @MainActor
    func suspendMonitor() -> Bool {
        guard !monitor.isSuspended else { return false }
        if monitor.isRunning { monitor.poll() }
        monitor.suspend()
        return true
    }

    @MainActor
    func resumeMonitor() {
        monitor.resume()
    }

    /// Records the transcript as a dictated entry. Only while the monitor is running:
    /// that is what "quick paste is on" means (`QuickPasteActivation`), and with the
    /// feature off nothing may fill the history.
    @MainActor
    func recordTranscript(_ text: String) {
        guard monitor.isRunning else { return }
        store.record(text: text, origin: .whisperKey)
    }
}

public struct TranscriptionOutputRouter {
    private let pasteEngine: PasteEngine
    private let pasteboard: TranscriptionPasteboard
    private let restoreDelayNanoseconds: UInt64
    private let readTimeoutNanoseconds: UInt64
    private let clipboardHistory: TranscriptionClipboardHistory?

    /// `clipboardHistory` is for the transcription path alone. The quick-paste popup
    /// builds its router without it: it suspends the monitor itself, and what it pastes
    /// is an entry already in the list, not a dictation.
    ///
    /// When the swap restores the user's clipboard after an auto-paste, it waits for the
    /// paste target to read the transcript, at most `readTimeoutNanoseconds`, and then
    /// `restoreDelayNanoseconds` more, since an application may read more than once.
    public init(
        pasteEngine: PasteEngine = PasteEngine(),
        restoreDelayNanoseconds: UInt64 = 150_000_000,
        readTimeoutNanoseconds: UInt64 = 2_000_000_000,
        clipboardHistory: TranscriptionClipboardHistory? = nil
    ) {
        self.init(
            pasteEngine: pasteEngine,
            pasteboard: SystemTranscriptionPasteboard(),
            restoreDelayNanoseconds: restoreDelayNanoseconds,
            readTimeoutNanoseconds: readTimeoutNanoseconds,
            clipboardHistory: clipboardHistory
        )
    }

    init(
        pasteEngine: PasteEngine = PasteEngine(),
        pasteboard: TranscriptionPasteboard,
        restoreDelayNanoseconds: UInt64 = 150_000_000,
        readTimeoutNanoseconds: UInt64 = 2_000_000_000,
        clipboardHistory: TranscriptionClipboardHistory? = nil
    ) {
        self.pasteEngine = pasteEngine
        self.pasteboard = pasteboard
        self.restoreDelayNanoseconds = restoreDelayNanoseconds
        self.readTimeoutNanoseconds = readTimeoutNanoseconds
        self.clipboardHistory = clipboardHistory
    }

    /// Puts `text` where `settings` says, and reports what happened.
    ///
    /// `secureFieldPolicy` is passed straight through to `PasteEngine` and says what this
    /// caller wants done about a focused field the application has labelled secure. It
    /// defaults to `.refuse`, which is what the transcription auto-paste wants and what
    /// every caller got before the quick-paste popup needed the other answer.
    @discardableResult
    public func deliver(
        text: String,
        settings: TranscriptionOutputSettings,
        secureFieldPolicy: SecureFieldPolicy = .refuse
    ) async -> TranscriptionOutputResult {
        guard !Task.isCancelled else {
            return TranscriptionOutputResult(wroteClipboard: false, pasteDecision: nil, restoredClipboard: false)
        }

        switch (settings.saveToClipboard, settings.autoPaste) {
        case (true, true):
            let wroteClipboard = pasteboard.replaceWithString(text)
            guard !Task.isCancelled else {
                return TranscriptionOutputResult(wroteClipboard: wroteClipboard, pasteDecision: nil, restoredClipboard: false)
            }
            let decision = attemptPasteIfClipboardWriteSucceeded(wroteClipboard, secureFieldPolicy: secureFieldPolicy)
            await recordTranscript(text, ifWritten: wroteClipboard)
            return TranscriptionOutputResult(
                wroteClipboard: wroteClipboard,
                pasteDecision: decision,
                restoredClipboard: false
            )

        case (true, false):
            let wroteClipboard = pasteboard.replaceWithString(text)
            await recordTranscript(text, ifWritten: wroteClipboard)
            return TranscriptionOutputResult(
                wroteClipboard: wroteClipboard,
                pasteDecision: nil,
                restoredClipboard: false
            )

        case (false, true):
            // The swap below moves the change counter twice, and the second move puts the
            // user's own text back. A monitor left listening records that restore as a
            // fresh copy on every dictation (#211). The swap is one function so that
            // every way out of it, cancellation included, comes back through the resume.
            let suspendedMonitor = await clipboardHistory?.suspendMonitor() ?? false
            let result = await swapPasteAndRestore(text: text, secureFieldPolicy: secureFieldPolicy)
            if suspendedMonitor {
                await clipboardHistory?.resumeMonitor()
            }
            return result

        case (false, false):
            return TranscriptionOutputResult(
                wroteClipboard: false,
                pasteDecision: nil,
                restoredClipboard: false
            )
        }
    }

    /// The `(saveToClipboard: false, autoPaste: true)` path: put the transcript on the
    /// clipboard, paste it, put back what was there.
    ///
    /// The transcript goes on as a promise, and the restore waits until the paste target
    /// has read it. A fixed delay used to stand there: on a loaded Mac the target handled
    /// ⌘V after the restore and pasted the user's own clipboard instead. No keystroke
    /// sent means no reader coming, and the restore goes ahead at once.
    private func swapPasteAndRestore(
        text: String,
        secureFieldPolicy: SecureFieldPolicy
    ) async -> TranscriptionOutputResult {
        let snapshot = pasteboard.snapshot()
        guard !Task.isCancelled else {
            return TranscriptionOutputResult(wroteClipboard: false, pasteDecision: nil, restoredClipboard: false)
        }
        // Held to the restore: it keeps the promise's provider alive until then.
        let readSignal = pasteboard.replaceWithPromisedString(text)
        let wroteClipboard = readSignal != nil
        guard !Task.isCancelled else {
            let restored = withExtendedLifetime(readSignal) { pasteboard.restore(snapshot) }
            return TranscriptionOutputResult(wroteClipboard: wroteClipboard, pasteDecision: nil, restoredClipboard: restored)
        }
        let decision = attemptPasteIfClipboardWriteSucceeded(wroteClipboard, secureFieldPolicy: secureFieldPolicy)
        let pastedAt = DispatchTime.now().uptimeNanoseconds
        // The monitor is silent here, so nothing else will put the transcript in the list.
        await recordTranscript(text, ifWritten: wroteClipboard)
        if let readSignal, decision == .paste {
            await waitForTheTargetToRead(readSignal, pastedAt: pastedAt)
        }
        let restored = withExtendedLifetime(readSignal) { pasteboard.restore(snapshot) }
        if !restored {
            outputLog.error("failed to restore pasteboard after auto-paste")
        }
        return TranscriptionOutputResult(
            wroteClipboard: wroteClipboard,
            pasteDecision: decision,
            restoredClipboard: restored
        )
    }

    /// Waits for the paste target's read of the transcript, then a short grace in case it
    /// reads again. Returns at the read timeout or on cancellation without the grace.
    private func waitForTheTargetToRead(_ readSignal: PasteboardReadSignal, pastedAt: UInt64) async {
        let read = await readSignal.wait(timeoutNanoseconds: readTimeoutNanoseconds)
        guard read else {
            if Task.isCancelled {
                outputLog.notice("auto-paste cancelled before the target read the clipboard; restoring")
            } else {
                let timeoutMilliseconds = readTimeoutNanoseconds / 1_000_000
                outputLog.notice("paste target did not read the clipboard within \(timeoutMilliseconds, privacy: .public) ms; restoring")
            }
            return
        }
        let firedAt = readSignal.firedAtUptimeNanoseconds ?? pastedAt
        let readAfterMilliseconds = (firedAt > pastedAt ? firedAt - pastedAt : 0) / 1_000_000
        outputLog.notice("paste target read the clipboard \(readAfterMilliseconds, privacy: .public) ms after the keystroke")
        if restoreDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: restoreDelayNanoseconds)
        }
    }

    /// Puts the transcript into clipboard history as a dictated entry, after the paste
    /// keystroke so the paste never waits for the store's file.
    ///
    /// Where the transcript stays on the clipboard the monitor sees the same marked write
    /// a moment later; the store keeps one entry per text, so it still lands once. A
    /// delivery cancelled before the paste records nothing here.
    private func recordTranscript(_ text: String, ifWritten wroteClipboard: Bool) async {
        guard wroteClipboard else { return }
        await clipboardHistory?.recordTranscript(text)
    }

    private func attemptPasteIfClipboardWriteSucceeded(
        _ wroteClipboard: Bool,
        secureFieldPolicy: SecureFieldPolicy
    ) -> PasteDecision? {
        guard wroteClipboard else {
            outputLog.error("failed to write transcription to pasteboard; paste skipped")
            return nil
        }
        return pasteEngine.attemptPaste(secureFieldPolicy: secureFieldPolicy)
    }
}
