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
    @discardableResult func replaceWithString(_ string: String) -> Bool
    @discardableResult func restore(_ snapshot: PasteboardSnapshot) -> Bool
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

public struct TranscriptionOutputRouter {
    private let pasteEngine: PasteEngine
    private let pasteboard: TranscriptionPasteboard
    private let restoreDelayNanoseconds: UInt64

    public init(
        pasteEngine: PasteEngine = PasteEngine(),
        restoreDelayNanoseconds: UInt64 = 150_000_000
    ) {
        self.init(
            pasteEngine: pasteEngine,
            pasteboard: SystemTranscriptionPasteboard(),
            restoreDelayNanoseconds: restoreDelayNanoseconds
        )
    }

    init(
        pasteEngine: PasteEngine = PasteEngine(),
        pasteboard: TranscriptionPasteboard,
        restoreDelayNanoseconds: UInt64 = 150_000_000
    ) {
        self.pasteEngine = pasteEngine
        self.pasteboard = pasteboard
        self.restoreDelayNanoseconds = restoreDelayNanoseconds
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
            return TranscriptionOutputResult(
                wroteClipboard: wroteClipboard,
                pasteDecision: decision,
                restoredClipboard: false
            )

        case (true, false):
            let wroteClipboard = pasteboard.replaceWithString(text)
            return TranscriptionOutputResult(
                wroteClipboard: wroteClipboard,
                pasteDecision: nil,
                restoredClipboard: false
            )

        case (false, true):
            let snapshot = pasteboard.snapshot()
            guard !Task.isCancelled else {
                return TranscriptionOutputResult(wroteClipboard: false, pasteDecision: nil, restoredClipboard: false)
            }
            let wroteClipboard = pasteboard.replaceWithString(text)
            guard !Task.isCancelled else {
                let restored = pasteboard.restore(snapshot)
                return TranscriptionOutputResult(wroteClipboard: wroteClipboard, pasteDecision: nil, restoredClipboard: restored)
            }
            let decision = attemptPasteIfClipboardWriteSucceeded(wroteClipboard, secureFieldPolicy: secureFieldPolicy)
            if wroteClipboard && restoreDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: restoreDelayNanoseconds)
            }
            let restored = pasteboard.restore(snapshot)
            if !restored {
                outputLog.error("failed to restore pasteboard after auto-paste")
            }
            return TranscriptionOutputResult(
                wroteClipboard: wroteClipboard,
                pasteDecision: decision,
                restoredClipboard: restored
            )

        case (false, false):
            return TranscriptionOutputResult(
                wroteClipboard: false,
                pasteDecision: nil,
                restoredClipboard: false
            )
        }
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
