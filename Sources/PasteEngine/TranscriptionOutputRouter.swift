import AppKit
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

    @discardableResult
    func replaceWithString(_ string: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
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

    @discardableResult
    public func deliver(text: String, settings: TranscriptionOutputSettings) async -> TranscriptionOutputResult {
        switch (settings.saveToClipboard, settings.autoPaste) {
        case (true, true):
            let wroteClipboard = pasteboard.replaceWithString(text)
            let decision = attemptPasteIfClipboardWriteSucceeded(wroteClipboard)
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
            let wroteClipboard = pasteboard.replaceWithString(text)
            let decision = attemptPasteIfClipboardWriteSucceeded(wroteClipboard)
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

    private func attemptPasteIfClipboardWriteSucceeded(_ wroteClipboard: Bool) -> PasteDecision? {
        guard wroteClipboard else {
            outputLog.error("failed to write transcription to pasteboard; paste skipped")
            return nil
        }
        return pasteEngine.attemptPaste()
    }
}
