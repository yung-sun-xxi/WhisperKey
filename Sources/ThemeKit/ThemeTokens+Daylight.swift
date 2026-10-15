public extension ThemeTokens {
    /// Daylight: the light theme. It is Midnight with other colours and nothing else
    /// (decided 2026-10-11): it starts from `midnight` and replaces only `colors`, the
    /// panel shells' fill and edge colours, the shadow colours and the window appearance
    /// that follows the palette. `ThemeParityTests` holds that.
    ///
    /// Values: the "Light" column of `docs/design/tokens.md`, transcribed from the token
    /// table of `docs/design/light/master-design.dc.html`. `TokenSheetTests` reads the
    /// file and holds these to it. Each comment names the sheet token.
    static let daylight: ThemeTokens = {
        var tokens = ThemeTokens.midnight
        tokens.theme = .daylight
        tokens.colors = Colors(
            bar: .hex(0xF8F9FB),            // 01
            surface: .hex(0xEFF0F3),        // 02
            settingsSurface: .hex(0xEFF0F3), // 02
            card: .hex(0xE0E2E6),           // 03
            divider: .hex(0xE0E2E6),        // 03
            selectedRow: .hex(0xD0D3D8),    // 04
            raisedControl: .hex(0xD0D3D8),  // 04
            edge: .hex(0xB8BCC4),           // 05
            mutedEdge: .hex(0x8C929F),      // 06
            secondaryText: .hex(0x515763),  // 07
            navigationText: .hex(0x424854), // 07n
            primaryText: .hex(0x16181D),    // 08
            checkboxFill: .hex(0x16181D),   // 08
            brand: DaylightAccent.red,      // red
            brandHover: DaylightAccent.redHover, // red hover
            onBrand: .hex(0x16181D),        // on red
            recordingStop: DaylightAccent.red, // red, #105 rule 1
            success: .hex(0x4F8E00),        // green
            failureFill: .hex(0xE8E9ED),    // failure
            failureHatch: .hex(0x666C78, opacity: 0.18),
            offKnob: .hex(0x666C78),        // off knob
            destructiveText: .hex(0x16181D),  // 08
            destructiveGlyph: .hex(0x515763), // 07
            failureText: .hex(0x16181D),    // 08
            cautionText: .hex(0x515763),    // 07
            actionGlyph: .hex(0x515763),    // 07
            chipEdge: .hex(0xB8BCC4)        // 05
        )
        tokens.panels.popover = tokens.panels.popover.daylight()
        tokens.panels.quickPaste = tokens.panels.quickPaste.daylight()
        tokens.panels.toast = tokens.panels.toast.daylight()
        // The design's light shadows: the same offsets and blurs, lighter black.
        tokens.shadows.window = .drop(color: .hex(0x000000, opacity: 0.14), blur: 52, x: 0, y: 24)
        // Not in the token table; the light design draws the actions menu at 16%, as
        // its panels.
        tokens.shadows.menu = .drop(color: .hex(0x000000, opacity: 0.16), blur: 36, x: 0, y: 18)
        tokens.shadows.alert = .drop(color: .hex(0x000000, opacity: 0.2), blur: 44, x: 0, y: 20)
        // `closeButton` stays Midnight's: the app's own close disc, in neither design.
        tokens.windowAppearance = .light
        return tokens
    }()
}

/// Daylight's red, chosen by the owner on 2026-10-15: the light design file's "custom"
/// accent at its default, oklch 0.78 0.205 32°, and its hover 0.05 darker. The one place
/// these two values live in code.
enum DaylightAccent {
    static let red: ThemeColor = .hex(0xFF7B5D)
    static let redHover: ThemeColor = .hex(0xFF6A4D)
}

private extension PanelShell {
    /// Midnight's shell in Daylight's colours: 02 at 95% over the same blur, a 05 edge.
    func daylight() -> PanelShell {
        var shell = self
        if case let .fill(_, blur) = shell.background {
            shell.background = .fill(.hex(0xEFF0F3, opacity: 0.95), blur: blur)
        }
        shell.edge = shell.edge.map { _ in .hex(0xB8BCC4) }
        return shell
    }
}
