import SwiftUI

/// The history entry reader's content as drawn (#165): a `divider` line under the
/// titlebar; the date line (the date, then the language tag in caps) in
/// `secondaryText`; the text in a `card`, scrollable and selectable; and the action bar
/// on `bar` under another `divider` line, holding today's buttons — Copy (reads "Copied"
/// for a moment after a click, ⌘C) for a recognised entry, Retry for one that can be
/// recognised again, and Close (Esc) at the trailing edge.
///
/// Every size is `tokens.historyReader` or a shared token; every colour and font a token.
/// The words (the date, the text) are the caller's, and so are the actions. Lives in
/// ThemeKit rather than in the app so a test can host it.
public struct ThemedHistoryReaderView: View {
    /// How long Copy reads "Copied" after a click: the app's earlier 1.4 s.
    public static let copiedNanoseconds: UInt64 = 1_400_000_000

    /// The tag after the date: the language code in caps, or none without a language.
    public static func languageTag(_ language: String?) -> String? {
        guard let language, !language.isEmpty else { return nil }
        return language.uppercased()
    }

    /// Copy's title, "Copied" for a moment after a click.
    public static func copyTitle(copied: Bool) -> String {
        copied ? "Copied" : "Copy"
    }

    @Environment(\.themeTokens) private var tokens
    @State private var didCopy = false
    private let date: String
    private let language: String?
    private let text: String
    private let isRecognized: Bool
    private let canRetry: Bool
    private let onCopy: () -> Void
    private let onRetry: () -> Void
    private let onClose: () -> Void

    /// - Parameters:
    ///   - date: When the entry was made, already formatted.
    ///   - language: The entry's language code, if any.
    ///   - text: The entry's text, or its failure's wording.
    ///   - isRecognized: A recognised entry offers Copy and draws its text as primary.
    ///   - canRetry: Whether the bar carries Retry.
    ///   - onCopy: Puts the text on the pasteboard.
    ///   - onRetry: Runs the recognition again; the reader closes after it.
    ///   - onClose: Closes the reader.
    public init(
        date: String,
        language: String?,
        text: String,
        isRecognized: Bool,
        canRetry: Bool,
        onCopy: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.date = date
        self.language = language
        self.text = text
        self.isRecognized = isRecognized
        self.canRetry = canRetry
        self.onCopy = onCopy
        self.onRetry = onRetry
        self.onClose = onClose
    }

    public var body: some View {
        let reader = tokens.historyReader
        VStack(spacing: 0) {
            divider
            content
            divider
            actionBar
        }
        .frame(
            minWidth: reader.minContentSize.width,
            maxWidth: .infinity,
            minHeight: reader.minContentSize.height,
            maxHeight: .infinity,
            alignment: .top
        )
        .background(tokens.colors.surface.color)
    }

    private var divider: some View {
        Rectangle()
            .fill(tokens.colors.divider.color)
            .frame(height: tokens.historyReader.dividerWidth)
    }

    /// The date line over the card, padded to the window text edge.
    private var content: some View {
        let reader = tokens.historyReader
        return VStack(alignment: .leading, spacing: reader.contentGap) {
            dateLine
            card
        }
        .padding(.vertical, reader.contentPaddingVertical)
        .padding(.horizontal, tokens.spacing.windowTextEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The date, then the language tag right after it, both in `secondaryText`.
    private var dateLine: some View {
        let reader = tokens.historyReader
        return HStack(alignment: .firstTextBaseline, spacing: reader.languageGap) {
            Text(date)
                .font(reader.date.font)
            if let tag = Self.languageTag(language) {
                Text(tag)
                    .font(tokens.type.caption.font)
            }
        }
        .foregroundStyle(tokens.colors.secondaryText.color)
        .lineLimit(1)
    }

    /// The text in a `card`, the body at the body line height, scrolling inside the
    /// card's rounded edge.
    private var card: some View {
        let reader = tokens.historyReader
        let body = tokens.type.body
        // CSS line height: the extra room between the lines, and half of it above the
        // first and below the last.
        let lineSpacing = tokens.type.bodyLineHeight.map { body.extraLineSpacing(lineHeight: $0) } ?? 0
        return ScrollView {
            Text(text)
                .font(body.font)
                .foregroundStyle((isRecognized ? tokens.colors.primaryText : tokens.colors.secondaryText).color)
                .lineSpacing(lineSpacing)
                .padding(.vertical, lineSpacing / 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.vertical, reader.cardPaddingVertical)
                .padding(.horizontal, reader.cardPaddingHorizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.colors.card.color, in: RoundedRectangle(cornerRadius: tokens.radii.card))
        .clipShape(RoundedRectangle(cornerRadius: tokens.radii.card))
    }

    /// Today's buttons: Copy and Retry leading, Close trailing.
    private var actionBar: some View {
        let reader = tokens.historyReader
        return HStack(spacing: reader.actionGap) {
            if isRecognized {
                ThemedPushButton(Self.copyTitle(copied: didCopy)) {
                    copy()
                }
                .keyboardShortcut("c", modifiers: [.command])
                .fixedSize()
            }
            if canRetry {
                ThemedPushButton("Retry") {
                    onRetry()
                    onClose()
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            ThemedPushButton("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
                .fixedSize()
        }
        .padding(.horizontal, tokens.spacing.windowTextEdge)
        .frame(maxWidth: .infinity)
        .frame(height: tokens.sizes.actionBar)
        .background(tokens.colors.bar.color)
    }

    private func copy() {
        onCopy()
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.copiedNanoseconds)
            didCopy = false
        }
    }
}
