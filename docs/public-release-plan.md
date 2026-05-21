# WhisperKey Public Release Plan

Date: 2026-05-20

## Goal

Make WhisperKey publicly readable and usable while keeping the upstream repository owner-controlled.

Users should be able to:

- View the repository.
- Clone the repository.
- Fork the repository.
- Download source code.
- Build and modify their own copy.

Users must not be able to:

- Push to `master` or other protected upstream branches.
- Run code on the owner's self-hosted Mac runner.
- Trigger privileged repository automation from untrusted pull requests.
- Merge changes into the upstream repository.

The owner should still be able to:

- Commit and push normally.
- Run CI for trusted owner changes.
- Cut signed and notarized releases.
- Publish GitHub Releases.

## Current State

- GitHub repository: `yung-sun-xxi/WhisperKey`
- Visibility: private
- Default branch: `master`
- License: missing
- Public release artifact: missing
- README: present, but currently too internal and points to the PRD issue as source of truth
- CI: present, but unsafe for a public repo because it runs on `pull_request` using a self-hosted runner
- Release pipeline: present in `scripts/release.sh`
- Release docs: present in `RELEASING.md`

## Decisions Already Made

1. The repository should become public.
2. The upstream repository remains owner-controlled.
3. External users may clone, fork, and modify their own copies.
4. External users should not be able to run CI on the owner's self-hosted Mac.
5. No screenshots are required for the initial public release.
6. The first public version should be `v1.0.0`.
7. A public README rewrite is required.
8. A license is required before making the repo public.
9. A first GitHub Release with a notarized DMG is required.

## License Choice

Two reasonable permissive licenses:

### MIT

MIT is the simplest permissive license.

It allows users to:

- Use the code.
- Copy the code.
- Modify the code.
- Distribute their own versions.
- Use it commercially.

It requires users to:

- Keep the copyright and license notice.

It does not strongly spell out patent rights.

Recommended if the goal is: "do whatever you want with this, just keep the notice."

### Apache-2.0

Apache-2.0 is also permissive, but more formal.

It allows broadly the same things as MIT:

- Use.
- Copy.
- Modify.
- Distribute.
- Commercial use.

It additionally includes:

- An explicit patent grant.
- More detailed contribution/legal terms.
- More text and legal machinery.

Recommended if patent clarity matters, or if the project expects broader corporate adoption.

### Recommendation

Use MIT.

Reason: WhisperKey is a small owner-driven macOS utility. The desired policy is simple public reuse, not a heavyweight contribution/legal framework. Apache-2.0 is not wrong, it is just more machinery than this project needs right now.

## CI Policy

The risky part is not "public repo" by itself. The risky part is "public repo + untrusted PR code + self-hosted runner."

The current workflow uses a self-hosted macOS runner. If untrusted pull request code can run there, a stranger can make GitHub execute their code on the owner's machine. That is the thing to kill.

### Example A: Safe Owner Push

Owner pushes a branch or `master` update:

```text
owner laptop -> GitHub repo -> GitHub Actions -> self-hosted Mac runner
```

This is acceptable because the code came from the owner.

### Example B: Unsafe Public Pull Request

Stranger forks the repo and opens a PR:

```text
stranger fork -> PR to owner repo -> GitHub Actions -> self-hosted Mac runner
```

This is not acceptable. The PR can modify build scripts, tests, package commands, or workflow-adjacent files and try to execute arbitrary code on the runner.

### Example C: Safe Manual Owner Run

Owner manually starts CI from GitHub UI:

```text
owner clicks "Run workflow" -> GitHub Actions -> self-hosted Mac runner
```

This is acceptable if the owner chooses the trusted branch/ref.

### Recommended CI Shape

Use self-hosted CI only for trusted owner-controlled events:

- `push` to `master`
- optionally `push` to owner branches
- `workflow_dispatch` manual runs

Do not run self-hosted CI on:

- `pull_request`
- `pull_request_target`
- any event that executes code from forked PRs

Also remove automatic PR merge automation for public mode unless it is restricted to trusted owner branches.

### Implemented CI Shape

The public workflow is configured to run only on:

- `push` to `master`
- `workflow_dispatch` manual runs

The workflow does not run on `pull_request` or `pull_request_target`. External users can fork the repository and open pull requests for discussion, but their pull request code does not run on the owner's self-hosted Mac runner.

## Repository Permissions

Configure GitHub repository permissions so that:

- Only the owner has write/admin access.
- Public users have read access.
- Branch protection prevents direct accidental damage to `master`.
- Pull requests may be allowed for discussion, but they should not auto-run self-hosted CI.

Suggested public contribution stance:

```text
WhisperKey is currently an owner-driven project. Forks are welcome, but upstream changes are accepted at the owner's discretion.
```

This avoids pretending the project has a broad maintainer process when it does not.

### Implemented Branch Protection

The `master` branch is protected.

Current protection policy:

- Required status check: `test`
- Require branch to be up to date before merge: enabled
- Force pushes: disabled
- Branch deletion: disabled
- Required pull request reviews: disabled
- Admin enforcement: disabled

Reason for leaving admin enforcement disabled: the owner can keep the simple direct-push workflow. A trusted owner push to `master` still triggers CI after the push. Public users do not have upstream write access, so they cannot push to `master` in the first place.

## Release Configuration

The following files contain owner-specific release/build identity:

- `RELEASING.md`
- `scripts/release.sh`
- `ExportOptions.plist`
- `WhisperKey.xcodeproj/project.pbxproj`

Known values:

- Team ID: `UGLRY9ACZ6`
- Bundle ID: `yung-sun-xxi.WhisperKey`

These are not API secrets. Publishing them is not the same as publishing passwords, tokens, or private keys.

Recommended handling:

- Keep the bundle identifier in the Xcode project. It is part of the app identity.
- Keep `RELEASING.md`, but rewrite it so owner-specific signing values are described as configurable inputs.
- Change `scripts/release.sh` to read signing settings from environment variables or a local ignored config file.
- Consider generating or templating `ExportOptions.plist` during release instead of hardcoding Team ID there.

Do not delete release files. They are useful and document a real signed/notarized release path. The cleaner fix is to make the owner-specific parts configurable.

## Public README Requirements

Rewrite `README.md` as the public entrypoint.

It should include:

- What WhisperKey is.
- Feature list.
- Requirements.
- Install from GitHub Releases.
- First-run setup.
- Provider/API key setup.
- Privacy model.
- Development commands.
- Release link.
- License.

It should not depend on a private/internal PRD issue as the first source of truth.

## PRD / Internal Planning Docs

The current PRD issue is useful history, but it is not a good public README dependency.

Recommended handling:

- Stop linking to Issue #1 from the top of the README.
- Either leave Issue #1 as historical planning context, or export a cleaned version to `docs/PRD.md`.
- Keep current local issue docs in `docs/issues/` only if they are still useful and not misleading.

## First Public Release Steps

1. Harden CI for public mode.
2. Add MIT `LICENSE`.
3. Rewrite `README.md`.
4. Clean up release docs/config so owner-specific signing values are not awkwardly hardcoded in public docs.
5. Run final checks:
   - `swift test`
   - Xcode Debug build with signing disabled
   - release build/notarization flow
6. Create `v1.0.0` tag.
7. Publish GitHub Release with the notarized DMG.
8. Make repository public.
9. Verify as an anonymous/logged-out viewer:
   - README renders correctly.
   - Release artifact is downloadable.
   - No private issue/document link is required to understand the project.
   - CI is not available to untrusted PRs on the self-hosted runner.

## Open Questions

1. Confirm final license choice: MIT is recommended.
2. Decide whether public pull requests are disabled entirely, or allowed only as discussion without CI.
3. Decide whether to add a short `CONTRIBUTING.md` explaining owner-driven contribution policy.
4. Decide how far to parameterize release signing before public release:
   - minimum: rewrite docs and keep code as-is;
   - better: move Team ID out of `scripts/release.sh` and `ExportOptions.plist`.
5. Decide whether to clean/export the PRD into `docs/PRD.md`, or simply remove the README dependency on it.
