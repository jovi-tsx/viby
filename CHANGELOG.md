# Changelog

Notable shipped changes are recorded here for users and contributors.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions use [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as
numeric `MAJOR.MINOR.PATCH`, without suffixes. Maturity is a separate label.

## [Unreleased]

### Added

- A complete Viby brand guide, visual sheet and downloadable vector/raster kit,
  including outlined signatures, monochrome applications, avatar and repository covers.
- Locally bundled Manrope typography with its upstream license and source record.

### Changed

- Applied shared brand tokens, typography and the final signature to Options and
  the dictation dock; refreshed the repository cover.
- Clarified that the current prototype does not paste text, including in the
  confirmation copy and insertion settings.

The app remains pre-alpha. This identity update does not implement dynamic
engine connections or destination insertion.

## [0.0.1] - 2026-10-28

**Stage: Pre-alpha. Distribution: source-only snapshot.**

This establishes a development baseline. It is not a finished Windows
dictation application and does not include an installer or downloadable
application binary.

### Added

- Native Tauri/Rust Windows shell, minimal tray menu and Options interface.
- Configurable dictation/discard shortcuts, WASAPI capture, microphone level
  feedback and optional provisional transcription preview.
- Embedded Whisper prototype with local model loading, hold-to-talk and
  optional press-once confirmation.
- Non-sensitive settings, bottom-edge dock positioning and reduced-motion
  behavior.
- Final green cutout identity, editable artwork and generated native icons.
- Public MIT source repository, setup guide, contributor documentation and
  roadmap for user-managed local AI integration.
- Central version synchronization/check commands and curated release-note
  extraction.
- CI checks for version/changelog consistency, frontend builds, Windows Rust
  unit tests and Clippy.

### Changed

- Defined Viby as the Windows interaction bridge to a local AI engine operated
  by the user; configurable engine integration remains planned.
- Established `0.0.1` as the first release version. Earlier `0.1.0` values were
  unpublished scaffold metadata, not a historical release.
- Made Windows helper scripts resolve their checkout location, respect an
  existing LLVM configuration and report real command failures.

### Fixed

- Rebuild the executable's Windows icon resource when generated artwork changes.
- Associate invalid discard-shortcut feedback with its own Options field.

### Known limitations

- The current runtime still embeds Whisper; dynamic engine connections are
  not implemented.
- Automatic text insertion, clipboard preservation and optional Enter delivery
  are not implemented.
- Native interaction verification and clean-machine installation testing
  remain incomplete.
- A brief caption-bar flash around discard/hide remains recorded as polish debt.
- The source snapshot must not be treated as a validated end-user release.

[Unreleased]: https://github.com/jovi-tsx/viby/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/jovi-tsx/viby/releases/tag/v0.0.1
