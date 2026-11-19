import CoreGraphics
import Foundation
import os

private let typerLog = Logger(subsystem: "WhisperKey", category: "TextTyper")

/// Types text into the focused field with synthetic key events, without the clipboard.
///
/// The transcription auto-paste falls back to this when the clipboard holds files: a
/// file copied in Finder from a TCC-protected folder cannot be put back after a swap, so
/// the clipboard is left alone and the text typed instead (#215).
public protocol TextTyper: Sendable {
    func type(_ text: String) async
}

/// The text side of typing: what a typed transcript looks like, and how it is cut into
/// the pieces each key event carries.
public enum TypedText {
    /// How much text one key event carries. Applications accept longer strings
    /// unevenly; twenty UTF-16 units is what every target tried takes whole.
    public static let maxChunkUTF16Count = 20

    /// Turns every line break into one space. A typed line break is Return, and Return
    /// sends the message in a chat application.
    ///
    /// Works on `Character`s, so `\r\n` is one break and one space. `isNewline` covers
    /// `\n`, `\r`, `\r\n`, U+2028, U+2029 and the rest of Unicode's line separators.
    public static func replacingLineBreaks(_ text: String) -> String {
        String(text.map { $0.isNewline ? " " : $0 })
    }

    /// Cuts `text` into pieces of at most `maxUTF16Count` UTF-16 units, only ever between
    /// two `Character`s, so no piece ends inside a surrogate pair, an emoji sequence or a
    /// letter with its combining marks. A single `Character` longer than the limit goes
    /// whole, in a piece of its own: split, it would arrive as garbage.
    public static func chunks(of text: String, maxUTF16Count: Int = maxChunkUTF16Count) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentCount = 0
        for character in text {
            let count = character.utf16.count
            if currentCount > 0, currentCount + count > maxUTF16Count {
                chunks.append(current)
                current = ""
                currentCount = 0
            }
            current.append(character)
            currentCount += count
        }
        if currentCount > 0 {
            chunks.append(current)
        }
        return chunks
    }
}

/// Types with `CGEvent` key events whose Unicode string is the text itself.
///
/// Each piece of text goes as one key-down and one key-up carrying it. The virtual key
/// is irrelevant to an application that reads the Unicode string, which is every text
/// field tried; one that reads the key code instead gets the wrong text (see #215,
/// Risks). Posting needs the Accessibility permission auto-paste already has.
public struct CGEventTextTyper: TextTyper {
    /// The pause between two pieces: long enough that a busy target keeps them in
    /// order, short enough that a thousand characters take a fraction of a second.
    public static let defaultPauseBetweenChunksNanoseconds: UInt64 = 2_000_000

    private let makeEvent: @Sendable (_ keyDown: Bool) -> CGEvent?
    private let post: @Sendable (CGEvent) -> Void
    private let pauseBetweenChunksNanoseconds: UInt64

    public init() {
        self.init(
            makeEvent: { keyDown in
                CGEvent(
                    keyboardEventSource: CGEventSource(stateID: .combinedSessionState),
                    virtualKey: 0,
                    keyDown: keyDown
                )
            },
            post: { $0.post(tap: .cgAnnotatedSessionEventTap) },
            pauseBetweenChunksNanoseconds: Self.defaultPauseBetweenChunksNanoseconds
        )
    }

    init(
        makeEvent: @escaping @Sendable (_ keyDown: Bool) -> CGEvent?,
        post: @escaping @Sendable (CGEvent) -> Void,
        pauseBetweenChunksNanoseconds: UInt64
    ) {
        self.makeEvent = makeEvent
        self.post = post
        self.pauseBetweenChunksNanoseconds = pauseBetweenChunksNanoseconds
    }

    public func type(_ text: String) async {
        let chunks = TypedText.chunks(of: text)
        for (index, chunk) in chunks.enumerated() {
            guard
                let keyDown = makeEvent(true),
                let keyUp = makeEvent(false)
            else {
                typerLog.error("failed to create a key event; typing stopped after \(index, privacy: .public) of \(chunks.count, privacy: .public) pieces")
                return
            }
            let units = Array(chunk.utf16)
            for event in [keyDown, keyUp] {
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                // The source merges the keys physically held right now. A modifier still
                // down from the dictation hotkey would turn the text into shortcuts.
                event.flags = []
            }
            post(keyDown)
            post(keyUp)
            if pauseBetweenChunksNanoseconds > 0, index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: pauseBetweenChunksNanoseconds)
            }
        }
    }
}
