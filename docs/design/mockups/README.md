# Mockups: Midnight (dark) theme

One PNG per `data-screen-label` section of [`../dark/master-design.dc.html`](../dark/master-design.dc.html) (the Token sheet is transcribed in [`../tokens.md`](../tokens.md) instead), exported on 2026-10-10.
The four `settings-*.png` and `settings-theme-row.png` (the "Theme row states" section) were re-exported on 2026-10-11, when the Settings window became 520 wide with rows of 32.
`full-history-empty.png` (the "Full history empty" section) was added on 2026-10-13: the Full history window with no entries.
To regenerate: [`scripts/export-mockups.mjs`](../../../scripts/export-mockups.mjs) opens the design file in headless Chrome and takes an element screenshot of each named `[data-screen-label]` section at device scale factor 2, with 24 pt of page background around it for the shadow and the rest of the board hidden.
