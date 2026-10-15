# Light theme (Daylight): master design file

The light theme as a colour-only copy of Midnight (#176): the same token sheet and surfaces,
recoloured, plus a "Token table" section listing every colour token with its Midnight and
Light value. Exported from Claude Design on 2026-10-15.

Open `master-design.dc.html` in a browser. `support.js` is the Claude Design runtime the
page loads and must stay next to it; it is the same file as in `../dark/`.

Only the colours count here. This file was made from the Midnight design as it stood before
the look-only revision of #173, so its surfaces still show texts and controls the app does not
have (trigger keycaps, "Hold / Toggle"). Layout, texts and controls follow `../dark/` and the
app; sizes are shared by both themes.

The accent is not fixed in the file: a "custom" accent computed from oklch props in the page,
with presets beside it. The value the app uses is recorded in [`../tokens.md`](../tokens.md).
