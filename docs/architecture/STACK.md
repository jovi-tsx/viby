# Initial stack

The application will be a Tauri 2 application with a Rust backend and a local
web interface. It exposes no server, public API, or network traffic during
normal use.

| Layer | Choice | Reason |
|---|---|---|
| Desktop host | Tauri 2 + Rust | Transparent window, tray, permissions, and low-overhead Windows distribution. |
| Transcription | whisper.cpp via `whisper-rs` | Local Whisper inference without a Python service or remote API. |
| Capture | CPAL/WASAPI | Microphone access in the native process and level measurement for the waveform. |
| Insertion | Clipboard + Windows keyboard events | Terminal-compatible flow, including WSL, without coupling to oh-my-pi. |
| Preferences | Local app storage | Persist only non-sensitive settings and the model path. |

The reference default is a quantized multilingual Whisper model for the CPU.
The concrete choice between `base` and `small` will be measured on the machine
during the first milestone; an English-only model will not be the default.

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
