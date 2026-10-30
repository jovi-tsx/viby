# Viby roadmap

Updated: 2026-10-30.

Viby is a Windows dictation bridge for AI that the user runs locally.
The user owns the engine, models and inference runtime; Viby owns capture,
shortcuts, interaction and destination insertion.

This roadmap records the delivery direction. The engine boundary was reviewed
on 2026-10-30 ([ADR 0002](docs/adrs/0002-user-managed-local-engine.md)) and
its implementation is in progress.

## Where the application is today

| Area | Status |
| --- | --- |
| Public GitHub source, MIT license, final logo and setup documentation | Available |
| Changelog, numeric version policy and CI checks | Available; pre-alpha source snapshots |
| Native Windows shell, tray, Options and saved preferences | Implemented |
| Global shortcuts, capture, level feedback and provisional preview | Implemented; complete native regression evidence still pending |
| Connection to a user-run local engine (OpenAI-style HTTP, address checks) | Implemented; native journey evidence pending |
| Embedded Whisper transcription | Removed — Viby bundles no engine or model |
| Paste into the original Windows destination | Not implemented |
| Clipboard preservation and optional Enter delivery | Not implemented; UI preferences already exist |
| Windows installer and published application release | Not available yet |

Recorded verification on 2026-10-30: frontend build, Windows executable build
without LLVM, 80 Rust unit tests (including the engine bridge against local
HTTP and HTTPS test servers) and Clippy passed, and a synthesized spoken take
went through the production request path to a real whisper.cpp server. The
keyboard-and-microphone journey against the engine still needs native
evidence; destination insertion and a clean-machine installation are not done.

The repository is public. Development releases are source-only pre-alpha
snapshots using numeric SemVer. A usable, packaged Windows application release
has not been published. See [CHANGELOG.md](CHANGELOG.md) and
[RELEASING.md](RELEASING.md).

## The engine boundary

Decided on 2026-10-30 and documented in R3/R3a of the
[dictation spec](docs/specs/voice-dictation.md):

- One HTTP `multipart/form-data` request: the take as 16 kHz mono WAV in,
  a JSON `text` field out — the OpenAI transcription shape, which whisper.cpp
  server, Speaches/faster-whisper, LocalAI and vLLM speak.
- The user enters the engine address; Viby starts and manages nothing.
- This PC always; a private network only with an explicit, warned opt-in; the
  internet never. No redirects, no proxies, no credentials, no fallback.
- Bounded timeouts, abandonment on cancel/discard/Close, and a provisional
  preview from the same endpoint.

A generic text-only model needs a speech-to-text component before it can serve
this contract.

## Delivery order

### 1. Configurable local-engine integration — in progress

- [x] Separate the Windows dictation flow from embedded Whisper inference.
- [x] Add the reviewed engine client and its Options configuration.
- [x] Preserve cancellation, disposable audio/text and actionable errors.
- [x] Retire embedded-model management and the native inference build.
- [ ] Native keyboard-and-microphone journey evidence against a running engine.

**Exit:** a take reaches a user-operated, compatible local engine and returns
text through the shared flow, with tested connection failures and cancellation.

### 2. Complete native interaction validation

- Recheck hold-to-talk and press-once behavior against the integrated engine.
- Verify accept/discard by keyboard and pointer, shortcut conflicts and
  settings persistence.
- Recheck microphone closure, capture/processing cancellation, Close behavior,
  previews, error states and focus preservation.
- Make the tray/Options automation reliable enough to obtain current evidence.

**Exit:** current Windows evidence covers the actual integrated application;
previous embedded-Whisper runs are not used as a substitute for this proof.

### 3. Safe insertion into Windows applications

- Capture the intended destination when the take starts.
- Confirm that the original window is still a safe destination before paste.
- Paste returned text into supported fields, including an editor and a WSL
  terminal.
- Preserve unrelated clipboard contents and handle clipboard changes.
- Keep Enter opt-in.
- Exercise a closed/changed destination, elevated-process boundaries and
  cancellation/Close during delivery.

**Exit:** a complete voice-to-text-to-destination journey works, and unsafe or
cancelled flows paste nothing and send no Enter.

### 4. Package and publish a Windows release

- Build and verify an installer with the required runtime prerequisites.
- Document how users run/configure a compatible local engine separately.
- Test installation, first launch, connection setup, the full dictation
  journey, restart and uninstall on a clean Windows environment.
- Run the complete normal/error/cancellation regression matrix.
- Verify privacy behavior and the absence of retained audio/transcript data.
- Record release versions, checksums and a restore/rollback procedure.
- Publish tested artifacts and release notes through GitHub Releases.

Signing and the initial distribution format require an explicit release
decision. They are not a requirement to purchase a certificate before a
development build can be shared.

**Exit:** a new user can install Viby, connect their local engine, dictate into
a supported application and recover from failures using the release
instructions.

## First usable release checklist

- [x] Public source repository and MIT license.
- [x] Final identity and source/development documentation.
- [x] Versioned source baseline and working frontend/native builds.
- [x] Reviewed engine integration contract.
- [ ] Configurable connection to a user-managed local engine (implemented; native evidence pending).
- [ ] Complete native interaction verification.
- [ ] Safe destination insertion and clipboard handling.
- [ ] Full end-to-end and privacy regression evidence.
- [ ] Clean-machine installer and setup validation.
- [ ] Published Windows release artifacts and release notes.

The remaining items are delivery gates, not an estimate of percentage complete.
There is no release date committed here.

## Known follow-ups

The existing prototype has a recorded brief caption-bar flash around the
dock's discard/hide interaction. It remains tracked as polish debt, with its
previous non-blocking disposition preserved. The native smoke helpers also
have maintenance work; their failures must not be described as successful
end-to-end validation.

See [README.md](README.md) for setup and current limitations,
and [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow.
