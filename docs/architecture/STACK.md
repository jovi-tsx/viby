# Initial stack

> Rationale: [ADR 0002](../adrs/0002-user-managed-local-engine.md).

The application is a Tauri 2 application with a Rust backend and a local web
interface. It exposes no server or public API. Its only connections are
requests to the speech-to-text engine the user runs and configures, on this PC
or on a private network the user explicitly allowed.

| Layer | Choice | Reason |
|---|---|---|
| Desktop host | Tauri 2 + Rust | Transparent window, tray, permissions, and low-overhead Windows distribution. |
| Transcription | User-run engine over HTTP (OpenAI-shaped multipart, `{text}` reply) | Viby stays agnostic to the engine and ships no model; see spec R3/R3a. |
| Capture | CPAL/WASAPI | Microphone access in the native process and level measurement for the waveform. |
| Insertion | Clipboard + Windows keyboard events | Terminal-compatible flow, including WSL, without coupling to oh-my-pi. |
| Preferences | Local app storage | Persist only non-sensitive settings, including the engine endpoint and optional model name; no credentials. |

Viby recommends no model; which engine and model run is the user's choice.

## Hybrid development workflow

Keep the checkout on the Windows filesystem and open the same directory from
WSL through `/mnt/c/...`. WSL is the primary environment for editing and
frontend tooling (Node.js 22 or newer and npm). The checkout does not need to
be copied into the Linux filesystem.

The resulting application remains native Windows software. Rust MSVC, Microsoft
C++ Build Tools, and WebView2 belong on the Windows host because they are needed
to compile, launch, and prove real Tauri, WASAPI, hotkey, and Win32 behavior.
Node/npm do not need to be installed on Windows. Rust in WSL is optional for
code analysis and isolated tests that do not start the Tauri window; it does not
replace the MSVC toolchain.
