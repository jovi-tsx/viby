# Contributing to Viby

Viby is an early Windows desktop project. Check existing issues before starting
a large change, and keep pull requests focused on one observable outcome.

## Development workflow

Keep the checkout on a Windows drive. Use WSL for editing, npm dependencies,
and frontend builds. Use Windows Rust MSVC for native builds and tests.
The setup commands are in [README.md](README.md).

After frontend or asset changes, run `npm run build` in WSL. After Rust or build
integration changes, run `scripts/run-rust-gates.ps1` and
`scripts/run-release-build.ps1` on Windows. Both scripts resolve the checkout
relative to their own location.

## Behavior and privacy

Follow the [dictation contract](docs/specs/voice-dictation.md).

- Keep inference local; do not add remote transcription fallbacks.
- Never persist or log audio, recognized text, or clipboard contents.
- Preserve the two-item tray menu: Options… and Close.
- Preserve cancellation and cleanup when closing the app.
- Keep Enter opt-in and insertion fail-closed.
- Do not bundle model weights or recordings in source commits.

Use hardware-free Rust tests where possible. Microphone, hotkey, tray, Win32,
and clipboard behavior need native Windows evidence. A passing build does
not prove those interactions.

## Native smoke checks

The PowerShell smoke scripts write reports to local `docs/plans/.../artifacts/`
directories. These reports, desktop captures, and machine-local planning files
are intentionally excluded from Git.

Run UI smoke checks on an available Windows desktop. Some scenarios change
preferences temporarily; inspect the script and its cleanup before running it.
Spoken checks need an explicit local model path and a real microphone.
Narrator and 200% scaling are not exercised by the existing smoke suite.

## Reporting a problem

Include the Windows version, Viby source revision, relevant steps, and whether
the problem concerns capture, transcription, shortcuts, UI, or insertion.
Remove personal text, model paths, and desktop details from reports.

## Licensing

The project uses the [MIT License](LICENSE). Third-party code and model files
remain subject to their own license terms.

## Changelog and release preparation

Add noteworthy completed changes to `CHANGELOG.md` under `Unreleased`, using
the appropriate change group. Keep planned work in `ROADMAP.md`. Ordinary
changes do not require an immediate version bump.

Run `npm run check:version` before submitting changes. Release preparation uses
`npm run version:set -- X.Y.Z` to keep all manifests/lockfiles aligned and adds
a dated changelog section. Versions have no suffixes; maturity is a separate
label. Follow [RELEASING.md](RELEASING.md) before creating a tag or release.

CI covers metadata, frontend, Windows Rust unit tests and Clippy; passing it
does not claim completion of native microphone/UI/insertion validation.
