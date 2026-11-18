import CoreGraphics
import Foundation

/// Types text into the focused field with synthetic key events, without the clipboard.
///
/// The transcription auto-paste falls back to this when the clipboard holds files (#215).
public protocol TextTyper: Sendable {
    func type(_ text: String) async
}

/// SKELETON (#215): replaced by the implementation in the next commit.
public enum TypedText {
    public static let maxChunkUTF16Count = 20

    public static func replacingLineBreaks(_ text: String) -> String {
        text
    }

    public static func chunks(of text: String, maxUTF16Count: Int = maxChunkUTF16Count) -> [String] {
        [text]
    }
}

/// SKELETON (#215): replaced by the implementation in the next commit.
public struct CGEventTextTyper: TextTyper {
    private let makeEvent: @Sendable (_ keyDown: Bool) -> CGEvent?
    private let post: @Sendable (CGEvent) -> Void
    private let pauseBetweenChunksNanoseconds: UInt64

    public init() {
        self.init(
            makeEvent: { _ in nil },
            post: { _ in },
            pauseBetweenChunksNanoseconds: 0
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

    public func type(_ text: String) async {}
}
