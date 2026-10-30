# Initial modules

> Rationale: [ADR 0002](../adrs/0002-user-managed-local-engine.md).

| Area | Responsibility | Not responsible for |
|---|---|---|
| Desktop shell | Window, tray, configuration, and lifecycle | Speech recognition or destination automation |
| Activation | Global shortcut, state machine, and source focus | Raw capture or inference |
| Audio | Device selection, capture, level, and buffer disposal | Text insertion |
| Engine | Check the endpoint against the address boundary, send the take or preview window to the user's engine, parse its text, and abandon requests on cancel | Running inference, managing models or servers, persisting audio, or rewriting text |
| Insertion | Preserve/restore the clipboard and trigger pasting into the destination | Deciding content or controlling the microphone |
| Bar | Show state, waveform, and explicit actions | Being the source of truth for data or permissions |

## Interfaces and seams

The activation module is the journey controller. Its interface to the shell and
bar must be limited to `start`, `stop`, `cancel`, `state`, and `retry`; it owns
the rules for disposal, capture eligibility, destination validation,
transcription preview, final transcription, and insertion internally. Callers
therefore do not learn CPAL, HTTP, Win32, or clipboard details.

Audio, engine, and insertion are internal adapters of this module. Each
receives the dependencies it needs instead of creating them: audio provides PCM
blocks and level, the engine adapter provides a final transcription or a
sanitized error, and insertion receives only a validated destination and final
text. The engine adapter may also provide previews identified by audio
window; the controller shows a preview only when it is newer than the one on
screen, and the final request never waits for a preview. These internal seams
enable tests without a microphone, engine, or real window, but do not become a
large public surface before a second real implementation exists.
