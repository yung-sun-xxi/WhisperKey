# WhisperKey (macOS) — how to check the work

The process lives in the `do-work` skill and the branch/commit/merge rules live in
`~/PersonalProjects/AGENTS.md`. This file holds only what is specific to this
repository.

## Checking the work

```bash
scripts/verify.sh
```

Package build, package tests, and the macOS app build: about **13 seconds**,
185 tests. `-t` runs the package tests alone, `-b` skips them, `-c` cleans the
app's derived data first. CI runs this same script, so a green run here is the
same check the pull request gets.

## Traps

1. **The `WhisperKey` scheme installs into `/Applications` as a build phase**,
   and that phase fails whenever the app is unsigned. It exits early when `CI`
   is `true` — which GitHub Actions sets for itself — so the same command is
   green on CI and red on a laptop. `scripts/verify.sh` sets
   `WHISPERKEY_SKIP_APPLICATIONS_INSTALL=1` for the same reason. **CI therefore
   never exercises the install path**; only a hand-run scheme does.
2. **Debug builds need a stable local signing identity** so macOS keeps their
   TCC permissions across rebuilds. Create it once with
   `scripts/ensure-local-signing-cert.sh`.
3. **The dev app and the release app are different identities to macOS** —
   `yung-sun-xxi.WhisperKey.dev` and `yung-sun-xxi.WhisperKey`. Microphone,
   Accessibility and the rest are granted separately for each, so a permission
   proved on one says nothing about the other.
4. **The default branch is `master`, not `main`.** Read it rather than assuming.
5. **Anything touching the microphone, Accessibility, global hotkeys, auto-paste
   or launch behaviour has to run as the installed app**, not from the build
   directory. That is what the `WhisperKey Dev Installed` scheme is for.

## Releases

Developer ID signing, notarization, DMG packaging and publishing are in
[RELEASING.md](RELEASING.md). Do not improvise around it.
