# Viby roadmap

Updated: 2026-10-28.

Viby is a Windows dictation bridge for AI that the user runs locally.
The user owns the engine, models and inference runtime; Viby owns capture,
shortcuts, interaction and destination insertion.

This roadmap records the delivery direction. The configurable engine boundary
still needs technical review before implementation.

## Where the application is today

| Area | Status |
| --- | --- |
| Public GitHub source, MIT license, final logo and setup documentation | Available |
| Native Windows shell, tray, Options and saved preferences | Implemented |
| Global shortcuts, capture, level feedback and provisional preview | Implemented; complete native regression evidence still pending |
| Embedded Whisper transcription | Implemented in the current prototype |
| Dynamic connection to user-managed local AI | Not implemented |
| Paste into the original Windows destination | Not implemented |
| Clipboard preservation and optional Enter delivery | Not implemented; UI preferences already exist |
| Windows installer and published application release | Not available yet |

Recorded verification on 2026-10-28: frontend build, Windows executable build,
60 Rust unit tests and Clippy passed. These checks cover the current embedded
prototype. They do not establish that the new engine bridge, destination
insertion or a clean-machine installation already works.

The repository is public. A usable, packaged application release has not been
published.

## Next step: review the local-engine boundary

Define the integration contract before extending the runtime:

- A compatible engine accepts audio and returns text.
- Choose the initial local transport/protocol and its capability requirements.
- Define connection and model selection at runtime, without recompiling Viby.
- Define audio formats, response validation, cancellation, timeouts and errors.
- Define the local-only connection boundary and any authentication requirements.
- Replace embedded-model assumptions in Options, preferences and documentation.

A generic text-only model needs a speech-to-text component before it can serve
this contract. Supporting an engine depends on its interface or an adapter;
the project does not promise compatibility with every arbitrary AI runtime.

Ready to implement when the behavioral, architecture and test contracts agree
on the engine boundary. No protocol or provider has been selected by this
roadmap.

## Delivery order

### 1. Configurable local-engine integration — next

- Separate the Windows dictation flow from embedded Whisper inference.
- Add the reviewed local-engine client/adapter and configuration.
- Let the user validate the connection and select supported engine/model
  settings through Options.
- Preserve cancellation, disposable audio/text and actionable local errors.
- Verify changing the configured engine without recompiling the application.
- Retire embedded-model management and native inference dependencies when the
  replacement is working and the migration is reviewed.

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
- [ ] Reviewed engine integration contract.
- [ ] Configurable connection to a user-managed local engine.
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

See [README.md](README.md) for the current prototype's setup and limitations,
and [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow.
