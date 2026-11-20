import AppKit
import SwiftUI
import XCTest
@testable import ThemeKit

/// Every boxed control is one look (#220): the pop-up, the number field and its stepper,
/// the secure field and the push button all fill with `controlFill` and outline in
/// `controlEdge`, in both themes.
///
/// The two tokens are swapped for colours no other token has before rendering, so a
/// control that still read `card` or `edge` (the same values today) shows up here.
@MainActor
final class ControlBoxTests: XCTestCase {
    private static let fill = ThemeColor.hex(0xC02090)
    private static let edge = ThemeColor.hex(0x20C040)

    private func marked(_ tokens: ThemeTokens) -> ThemeTokens {
        var tokens = tokens
        tokens.colors.controlFill = Self.fill
        tokens.colors.controlEdge = Self.edge
        return tokens
    }

    private static let inset: CGFloat = 8
    private let canvas = CGSize(width: 260, height: 44)

    private func render(_ view: some View, _ tokens: ThemeTokens) throws -> Snapshot {
        let root = view
            .environment(\.themeTokens, tokens)
            .padding(Self.inset)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .background(tokens.colors.settingsSurface.color)
        return try XCTUnwrap(Snapshot.render(root, size: canvas))
    }

    /// The fill a few points inside the box's leading edge and the outline on it, at the
    /// control's vertical middle.
    private func assertBox(_ name: String, _ shot: Snapshot, tokens: ThemeTokens, left: CGFloat? = nil) {
        let x = left ?? Self.inset
        let midY = canvas.height - (Self.inset + tokens.sizes.control / 2)
        let outline = shot.colour(x: x + tokens.controlMetrics.edgeWidth / 2, screenY: midY, height: canvas.height)
        let inside = shot.colour(x: x + 3, screenY: midY, height: canvas.height)
        XCTAssertTrue(outline.matches(Self.edge), "\(tokens.theme) \(name) outline: \(outline)")
        XCTAssertTrue(inside.matches(Self.fill), "\(tokens.theme) \(name) fill: \(inside)")
    }

    func testThePopUpIsTheBoxedLook() throws {
        for base in [ThemeTokens.midnight, .daylight] {
            let tokens = marked(base)
            let shot = try render(ThemedPopUpPicker("Pick", selection: .constant(0), options: [0, 1], title: { "Option \($0)" }), tokens)
            assertBox("pop-up", shot, tokens: tokens)
        }
    }

    func testTheNumberFieldAndItsStepperAreTheBoxedLook() throws {
        for base in [ThemeTokens.midnight, .daylight] {
            let tokens = marked(base)
            let field = ThemedNumberField("Size", value: .constant(50), in: 1...100, step: 1, unit: "entries")
                .environment(\.themeTokens, tokens)
            let shot = try render(field, tokens)
            assertBox("number field", shot, tokens: tokens)
            let width = Snapshot.fittingSize(field).width
            assertBox("stepper", shot, tokens: tokens, left: Self.inset + width - tokens.controlMetrics.stepper.width)
        }
    }

    func testTheSecureFieldIsTheBoxedLook() throws {
        for base in [ThemeTokens.midnight, .daylight] {
            let tokens = marked(base)
            let shot = try render(SecureFieldHost(), tokens)
            assertBox("secure field", shot, tokens: tokens)
        }
    }

    func testThePushButtonIsTheBoxedLookDestructiveOrNot() throws {
        for base in [ThemeTokens.midnight, .daylight] {
            let tokens = marked(base)
            assertBox("push button", try render(ThemedPushButton("Clear history") {}, tokens), tokens: tokens)
            assertBox("destructive push button", try render(ThemedPushButton("Reset usage", role: .destructive) {}, tokens), tokens: tokens)
        }
    }
}

/// `ThemedSecureField` needs a focus binding of its own.
private struct SecureFieldHost: View {
    @FocusState private var focused: Bool

    var body: some View {
        ThemedSecureField("API key", text: .constant(""), focus: $focused)
    }
}
