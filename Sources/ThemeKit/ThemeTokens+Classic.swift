public extension ThemeTokens {
    /// Classic: for now exactly Midnight under its own theme id (decided 2026-10-11).
    /// The themes differ only in colours; Classic gets its own palette later, and then
    /// changes `colors` here and nothing else. `ThemeParityTests` holds that.
    static let classic: ThemeTokens = {
        var tokens = ThemeTokens.midnight
        tokens.theme = .classic
        return tokens
    }()
}
