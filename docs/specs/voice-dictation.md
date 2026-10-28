# Viby local dictation contract

> **Scope:** this contract describes the current embedded prototype. The user
> has changed the product direction to a dynamic bridge for user-managed local
> AI. The [target architecture](../../README.md#how-it-works) is documented;
> its configurable engine/transport contract still needs review and implementation.

See [project status](../../README.md#project-status) for the current implementation stage.

## Requirements

### R1 — intentional activation

The application accesses the microphone only on explicit activation, and never
otherwise. The shape of that activation follows the “confirm before inserting”
preference, because the two are different conversations and are driven
differently.

With the preference off — the default — activation is hold-to-talk. The
microphone is open only while the user holds the configured global shortcut, and
releasing it ends the take. In this mode the microphone cannot be open without a
key held down.

With the preference on, activation is press-once: one press opens the
microphone, a second press ends the take. The absolute guarantee of the hold
mode does not apply here and is traded deliberately, because a confirmation the
user must answer on the dock cannot also demand a key held down with the other
hand. The dock is on screen for the whole take and its live level is what shows
the microphone is open.

The dock's own control ends a take in either mode.

### R2 — visible capture indication

During capture, a bar anchored to the bottom edge shows an animated waveform
derived from the local audio level, the current state, and a discard control.
The take ends by the same shortcut that began it - released in hold mode,
pressed a second time in press-once mode - so the bar carries no separate stop
control. The routine state is announced rather than printed: only
a provisional preview, a recoverable error, a refused activation, and a
transcript waiting for confirmation are ever printed above the bar. It may
show a locally produced partial preview of the user's speech. The preview is
explicitly provisional, may be corrected at each audio window, and is not
inserted into the destination application. It shows neither screen content nor
recorded audio.

### R3 — local transcription

When a valid capture ends, the application transcribes only with the selected
local Whisper model. If no model is available, it explains how to point to a
local file and does not attempt a remote API.

While capture is active, the application performs inference in sliding windows
and shows the newest partial result in the bar. Processing must not accumulate a
queue that continues producing old previews: a delayed preview is discarded in
favor of the newest window. When the take ends, a final transcription replaces
the preview and is the only version eligible for insertion.

### R4 — insertion into the original destination

After a successful transcription, the text is inserted into the application that
had focus when recording began. Text is pasted without sending the message by
default. Sending Enter is opt-in through a preference.

With the preference off, releasing the shortcut is itself the decision to send,
so insertion needs no confirmation and offers none. A “confirm before inserting”
preference, off by default, turns that into two steps instead: the finished
transcript waits on the bar until the user accepts it, and discarding it inserts
nothing. The accept control exists only in that waiting step and only when the
preference is on.

Both outcomes of the waiting step are reachable without the mouse. Pressing the
dictation shortcut accepts the waiting transcript — the press that would
otherwise start a take resolves the one already held. A second configurable
shortcut discards it. Neither outcome may be reached by a press that also starts
a new take: a waiting transcript is never dropped as a side effect.

If the original destination no longer exists, does not accept pasting, or cannot
be safely reidentified, the application does not paste into the currently
focused application: it reports the failure and allows a retry.

### R5 — privacy and lifecycle

Audio, transcription buffers, and clipboard content exist only in memory during
the flow. The previous clipboard is restored when it can be preserved without
loss. Preferences and the model path remain only in the user's local profile.
Logs do not record audio or transcriptions.

### R6 — recoverable failures

An inaccessible microphone, conflicting shortcut, missing model, short capture,
failed transcription, or blocked insertion ends the flow, clears buffers, and
shows an actionable message. No attempt uses the network as a contingency.

### R7 — tray and local preferences

On the Viby tray icon, right-click opens only the “Options…” and “Close”
actions. “Options…” opens local configuration for the global shortcut, the
discard shortcut, microphone, model path, language, bar position (Bottom left,
Bottom center, or Bottom right), preview visibility, sending Enter, and
confirming before inserting. Bottom center is the
default. A changed shortcut must be validated before saving; a conflict keeps
the previous shortcut and presents an actionable message. The two shortcuts are
validated against each other as well as against the system: they may not be the
same, and the discard shortcut is only consulted while a transcript waits.

“Close” exits the application instead of merely hiding the bar. If any flow is
active — capture, processing, a transcript waiting for confirmation, or
insertion — it cancels the flow, clears
temporary audio and transcription, inserts no text and sends no Enter into the
destination, and only then exits the process.

## Observable scenarios

| ID | Scenario | Expected result |
|---|---|---|
| S1 | Hold and release the shortcut with a WSL terminal focused | Final text appears at the prompt without automatic Enter. |
| S2 | Cancel during capture | Nothing is transcribed or inserted; buffers are discarded. |
| S3 | Local model missing | The bar explains local configuration without opening an external connection. |
| S4 | Microphone unavailable | The bar shows the error and does not remain in a recording state. |
| S5 | Enable automatic Enter | After inserting the transcription, the destination receives exactly one Enter. |
| S6 | Windows reduced motion enabled | The bar keeps readable states with no continuous waveform animation. |
| S7 | Dictate a long sentence | The bar shows a preview marked provisional; only the final result is pasted when the take ends. |
| S8 | Right-click the tray icon | The menu shows only “Options…” and “Close”; Options opens local preferences. |
| S9 | Choose “Close” while a flow is active | The application cancels capture, processing, or insertion, exits without pasting text or sending Enter, and discards temporary buffers. |
| S10 | Enable “confirm before inserting”, then dictate | The finished transcript waits on the bar with accept and discard controls and does not leave on its own; accepting inserts it, discarding inserts nothing. With the preference off there is no accept control and no waiting step. |
| S11 | Enable “confirm before inserting”, then activate | One press of the shortcut opens the microphone and a second press ends the take; the key is not held. While the transcript waits, the dictation shortcut accepts it and the discard shortcut discards it, both without touching the mouse. With the preference off, activation is hold-to-talk and releasing the key ends the take. |

## Compatibility

The destination is any field that accepts normal Windows pasting. Elevated
processes may block insertion from a non-elevated application; the interface must
explain this boundary without automatically elevating the application.

## UI Contract

The user works in deep focus in a terminal, editor, or message field. Viby acts
as a small audio instrument, not a chat window: a bottom-edge dock of three
graphite elements — a round discard control, a wide level pill of thin bars,
and, only while a transcript waits for confirmation, a round accept control —
with nothing above it unless there is something to read. Bottom left, Bottom
center, and Bottom right are supported; Bottom center is the default.
The persisted position moves the whole dock within a safe edge inset and never
changes the bottom-edge vertical anchor. At rest, Viby lives in the tray. The
approved visual master is
`assets/branding/viby-icon.svg`
(`sha256:f6e06e960f7e7cea9bba2dbce1caded6971c13ed3363c9122b26d18e6aeafc48`): a green rounded square
with the waveform V and typing cursor cut out as transparency (D17). Native
icons and the PNG are generated from it; Options renders the SVG directly.

While speaking, the bars are Viby green (`#1ddd66`) and follow the current microphone
level, growing symmetrically about the pill's centre line — a real level,
perceptually scaled so ordinary speech fills the pill, never decorative
animation. Processing does not simulate an active microphone: the bars turn
muted grey and run their own sweep, which reads as work in flight rather than
as sound. The discard and accept glyphs are warm white at rest and take their
intent colour on hover — discard red, accept green. Discard appears whenever
there is something to discard; accept exists only in the confirmation step,
which only exists when the user turned that preference on, because releasing
the shortcut is already the decision to send. While a transcript waits, the
level pill gives way to the two controls and the dock does not leave on its
own.

Turning that preference on also changes how a take starts, because a step the
user must answer on the dock cannot also ask them to keep a key held down: one
press opens the microphone, a second ends the take. Neither the waiting step nor
its two outcomes require the mouse — the dictation shortcut accepts the waiting
transcript and a second configurable shortcut discards it, so a person who never
touches a pointing device can complete the whole flow. Reaching the dock's
controls by Tab remains available to anyone who has activated Viby, and is a
convenience rather than the keyboard path. The routine state carries no standing label: it is announced, not
printed. A polite atomic live region announces Listening, Processing, Success,
a waiting transcript, cancellation, recoverable errors, and a refused
activation once per transition; errors use an assertive announcement when
immediate action is required. Only four things are ever printed above the
dock — the provisional preview, a recoverable error, a refused activation, and
a waiting transcript — each on its own plate. Discarding returns the dock
immediately,
without waiting for buffers and inference to be torn down; an activation that
arrives before that teardown finishes is refused with a visible, announced
notice rather than silently dropped. Rapid provisional-preview replacements
are not live-announced. The bar never steals focus from the original
destination; an Open settings action receives focus only after the user
explicitly activates Viby. With reduced motion, the bars become a static meter
updated at discrete intervals. The only spoken content shown is the current
preview, explicitly marked provisional; there is no history, counter, or
screen context.

At rest, the Viby tray icon opens only “Options…” and “Close”, in that order.
Options is a dark-only native window with a Viby header, compact
single-column cards for Activation, Audio, Model and language, Insertion, and
Interface, plus a sticky Save/status footer. Near-black canvas, subtly bordered
cards, warm-white text, and muted gray establish hierarchy; Viby green (`#1ddd66`) is
reserved for focus, saved state, and the primary action. Forced-colors mode
uses Windows system colors instead of overriding them.

While local settings load, the form is `aria-busy`, its controls are disabled,
and the polite status says “Loading settings…”. A successful load starts clean
with Save disabled. Editing produces “Unsaved changes” and enables Save.
Submitting disables Save, prevents duplicate submission, preserves focus, and
announces “Saving…”. Success announces “Saved” and returns to clean/disabled.
A shortcut conflict marks and describes the shortcut field, keeps focus there,
retains the registered/persisted value, and re-enables Save after editing.
Persistence failure announces “Couldn’t save settings. Try again.”, keeps the
form dirty, and enables retry. Load failure disables the form and announces
“Couldn’t load settings. Reopen Options.”.

Native semantic controls provide DOM-order keyboard focus and screen-reader
names. Error meaning never relies on color alone. The default client is
560 × 720 CSS px; the supported minimum is 480 × 480 CSS px with vertical
scrolling. The sticky footer never overlays focused content, validation copy,
or status. Proof uses the real Windows window at 100% default size and 200%
minimum size, tabbing through every control. Browser/mobile layouts are not
applicable.
