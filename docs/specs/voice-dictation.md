# Viby local dictation contract

> **Scope:** Viby is the desktop interface to a speech-to-text engine the user
> runs themselves (D20, D23). It ships no engine, server, or model. Until
> milestone M2b lands, the code still runs the embedded Whisper prototype this
> contract replaces; see [project status](../../README.md#project-status).

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
show a partial preview of the user's speech produced by the user's engine (R3). The preview is
explicitly provisional, may be corrected at each audio window, and is not
inserted into the destination application. It shows neither screen content nor
recorded audio.

### R3 — transcription by the user's local engine

When a valid capture ends, Viby sends the audio to the speech-to-text engine the
user configured, and the text that engine returns is the transcript. Viby
contains no inference engine and bundles, downloads, starts, or manages no
engine, server, or model: the user installs and runs their engine, keeps its
model wherever they choose, and gives Viby only its address. Any engine that
answers the request below is supported; Viby does not depend on which one.

The engine contract is audio in, text out:

- **Request.** One HTTP `POST` of `multipart/form-data` to the configured
  endpoint URL. The default path is `/v1/audio/transcriptions` (the OpenAI
  transcription shape); whisper.cpp's `/inference` takes the same request. The
  `file` part is the take as WAV — 16 kHz, mono, 16-bit PCM — encoded in memory.
  `response_format` is `json`. `language` is sent only when the user chose a
  language rather than automatic detection; `model` is sent only when the user
  filled the optional model name.
- **Response.** A 2xx status with a JSON object whose `text` member is a string.
  Leading and trailing whitespace is trimmed; an empty result is a failure.
  Anything else — another status, invalid JSON, no `text` string — is a failure.
- **Endpoint.** The user enters one full `http` or `https` URL. When its path
  is empty or `/`, Viby uses `/v1/audio/transcriptions`; any other path is used
  exactly as typed, so a whisper.cpp server is reached by entering its
  `/inference` URL. The URL carries no user name, password, query, or fragment.
- **Timeouts.** A connection that is not established within 3 seconds,
  name resolution included, fails: as an address that cannot be found when
  resolution has not answered or found nothing, otherwise as unreachable. Once connected, the final request waits up to the greater of
  60 seconds and ten times the take's duration, so a slow but working engine
  finishes a long take; the user can discard at any moment while it waits. A
  preview request uses the same 3-second connection bound and waits up to 60
  seconds for its response.
- **Lifecycle.** Cancel, discard, and Close abandon any request in flight, and
  a response that arrives after that is discarded unread. Ending the take
  abandons any preview request in flight, so the final request never waits for
  a preview. A failed request is never retried against another endpoint.

While capture is active and the preview is visible, Viby sends the most recent
audio window to the same endpoint and shows the newest partial result in the
bar. At most one preview request is in flight and it runs to completion, so an
engine slower than the window cadence still produces previews, only less often;
when it returns, the next request carries the audio window that is most recent
at that moment, never a queued older one. Processing must not accumulate a
queue that continues producing old previews, so a response for an older window
than the one shown is discarded. When the take ends, in-flight preview requests
are abandoned, and the final transcription replaces the preview and is the only
version eligible for insertion. A preview request that fails, times out, or is
refused is dropped silently: capture continues, the last good preview stays
until a newer one arrives, and only the final request can fail the flow.

If no engine endpoint is configured, activation is refused before the
microphone opens, with a notice that says to set an engine in Options. When an
endpoint is configured, Viby checks it as the microphone opens — R3a, then a
connection to the checked address — without delaying capture; if that check
fails, the take ends at once with the matching message and its audio is
discarded, so the user does not speak a whole take that cannot be transcribed.
Viby never opens Options or takes focus on its own to ask for an engine.

### R3a — where the audio may go

The endpoint host must be this PC: a loopback address (`127.0.0.0/8`, `::1`) or
a name that resolves only to loopback. A private-network address
(`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fc00::/7`) is allowed only
while the user has turned on “Allow an engine on my local network”, whose
description states that the audio will leave this PC over that network. Every
other address is refused.

The check runs before every connection, against every address the host
resolves to, and the connection is made only to addresses that were checked.
Viby may try each address that passed in turn — a `localhost` engine listening
only on IPv4 is still reached — and the engine is unreachable only when every
one fails within the bound.
Redirects are not followed and system proxies are not used, because either
would carry the audio past the check. A refused endpoint fails before any audio
is sent. There is no remote or cloud fallback.

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

The discard shortcut also cancels a take while the engine is processing it,
in either activation mode: the pending request is abandoned, nothing is
inserted, and the dock returns as for any discard. So a slow or stuck engine
never holds a person who has no pointing device until the timeout.

If the original destination no longer exists, does not accept pasting, or cannot
be safely reidentified, the application does not paste into the currently
focused application: it reports the failure and allows a retry.

### R5 — privacy and lifecycle

Audio, transcription buffers, and clipboard content exist only in memory during
the flow; audio leaves the process only as the body of a request to the
configured engine (R3, R3a) and is never written to disk. The previous clipboard
is restored when it can be preserved without loss. Preferences — including the
engine endpoint and optional model name — remain only in the user's local
profile, and no credential is stored: an engine that requires an API key is not
supported in this version. Logs do not record audio, transcriptions, or engine
response bodies.

### R6 — recoverable failures

An inaccessible microphone, conflicting shortcut, unconfigured or refused
endpoint, unreachable engine, a final request that returns an error status,
malformed response, or empty text or times out, a short capture, or blocked
insertion ends the flow (a failed preview request does not; R3), clears buffers, and shows an
actionable message that names which of these happened without quoting audio or
text. A host name that does not resolve says the engine address cannot be
found; an `https` certificate that is invalid or does not match the host says
the engine's certificate was rejected — neither tells the user to start an
engine that may already be running. For `https`, the activation-time check
includes the TLS handshake, so a rejected certificate ends the take at its
start. No attempt uses another endpoint or a remote service as a contingency.

### R7 — tray and local preferences

On the Viby tray icon, right-click opens only the “Options…” and “Close”
actions. “Options…” opens local configuration for the global shortcut, the
discard shortcut, microphone, engine endpoint URL, optional model name,
language, the local-network permission (R3a), bar position (Bottom left,
Bottom center, or Bottom right), preview visibility, sending Enter, and
confirming before inserting. Bottom center is the
default. The endpoint may be saved empty, which leaves Viby unconfigured
(activation is refused, R3) and lets the user clear a saved endpoint. Before
saving a non-empty endpoint, the URL must have the R3 endpoint form and a host
that passes R3a under the local-network setting being saved — a name that does
not resolve at save time is refused; a refused URL
— including a private endpoint saved with the permission turned off — keeps the
previous values and presents an actionable message. This check belongs to
saving only: a stored endpoint that later stops passing R3a still loads, along
with every other preference, and is refused per take (S12). A changed shortcut must
be validated before saving; a conflict keeps
the previous shortcut and presents an actionable message. The two shortcuts are
validated against each other as well as against the system: they may not be the
same, and the discard shortcut is only consulted while a transcript waits or
the engine is processing a take (R4).

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
| S3 | No engine configured, or the configured engine is not running | With no endpoint, activation is refused before the microphone opens and the notice says to set an engine in Options. With an endpoint whose engine is not running, the take ends as soon as the connection fails and the message says to start the engine. No request goes to any other host. |
| S4 | Microphone unavailable | The bar shows the error and does not remain in a recording state. |
| S5 | Enable automatic Enter | After inserting the transcription, the destination receives exactly one Enter. |
| S6 | Windows reduced motion enabled | The bar keeps readable states with no continuous waveform animation. |
| S7 | Dictate a long sentence | The bar shows a preview marked provisional; only the final result is pasted when the take ends. |
| S8 | Right-click the tray icon | The menu shows only “Options…” and “Close”; Options opens local preferences. |
| S9 | Choose “Close” while a flow is active | The application cancels capture, processing, or insertion, exits without pasting text or sending Enter, and discards temporary buffers. |
| S10 | Enable “confirm before inserting”, then dictate | The finished transcript waits on the bar with accept and discard controls and does not leave on its own; accepting inserts it, discarding inserts nothing. With the preference off there is no accept control and no waiting step. |
| S11 | Enable “confirm before inserting”, then activate | One press of the shortcut opens the microphone and a second press ends the take; the key is not held. While the transcript waits, the dictation shortcut accepts it and the discard shortcut discards it, both without touching the mouse. With the preference off, activation is hold-to-talk and releasing the key ends the take. |
| S12 | Configure an endpoint on a public address, or on a private-network address with the local-network permission off | Options refuses to save it; an equivalent endpoint reached at dictation time (for example a name that now resolves elsewhere) fails before any audio is sent. |
| S13 | The engine answers with an error status, malformed JSON, empty text, or not within the timeout | The flow ends with the matching actionable error, nothing is inserted, and buffers are discarded. |

## Compatibility

The engine is any local speech-to-text server that answers the R3 request; the
user starts and stops it. An engine running inside WSL 2 on the same PC is
reachable through its forwarded loopback port.

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
transcript and a second configurable shortcut discards it — and also cancels a
take the engine is still processing — so a person who never touches a pointing
device can complete or abandon the whole flow. Reaching the dock's
controls by Tab remains available to anyone who has activated Viby, and is a
convenience rather than the keyboard path. The routine state carries no standing label: it is announced, not
printed. A polite atomic live region announces Listening, Processing, Success,
a waiting transcript, cancellation, recoverable errors, and a refused
activation once per transition; errors use an assertive announcement when
immediate action is required. Only four things are ever printed above the
dock — the provisional preview, a recoverable error, a refused activation, and
a waiting transcript — each on its own plate. Discarding returns the dock
immediately,
without waiting for buffers and engine requests to be torn down; an activation that
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
single-column cards for Activation, Audio, Engine and language, Insertion, and
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
