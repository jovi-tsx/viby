# Initial modules

> **Scope:** this is the current embedded-prototype module map. The target
> engine boundary moves inference/model ownership to the user-managed local
> service; see [engine ownership](../../README.md#engine-ownership-and-integration).
> The configurable integration is not implemented yet.

| Area | Responsibility | Not responsible for |
|---|---|---|
| Desktop shell | Window, tray, configuration, and lifecycle | Speech recognition or destination automation |
| Activation | Global shortcut, state machine, and source focus | Raw capture or inference |
| Audio | Device selection, capture, level, and buffer disposal | Text insertion |
| STT | Load the local model and produce final transcription | Downloading, persisting audio, or rewriting text |
| Insertion | Preserve/restore the clipboard and trigger pasting into the destination | Deciding content or controlling the microphone |
| Bar | Show state, waveform, and explicit actions | Being the source of truth for data or permissions |

## Interfaces and seams

The activation module is the journey controller. Its interface to the shell and
bar must be limited to `start`, `stop`, `cancel`, `state`, and `retry`; it owns
the rules for disposal, capture eligibility, destination validation,
transcription preview, final transcription, and insertion internally. Callers
therefore do not learn CPAL, whisper.cpp, Win32, or clipboard details.

Audio, STT, and insertion are internal adapters of this module. Each receives
the dependencies it needs instead of creating them: audio provides PCM blocks
and level, STT provides a final transcription or a sanitized error, and insertion
receives only a validated destination and final text. STT may also provide
previews identified by audio window; the controller publishes only the newest
preview and discards any stale result. These internal seams enable tests without
a microphone, model, or real window, but do not become a large public surface
before a second real implementation exists.
