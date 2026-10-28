# ADR 0001 — Tauri/Rust with local whisper.cpp

> **Status:** records the architecture of the existing embedded prototype.
> The newer product direction is a bridge to user-managed local AI; see
> [the README](../../README.md#how-it-works). A replacement engine-integration
> contract is pending review and implementation.

## Context

The product must run on Windows, capture audio, show a bottom bar, and insert
text into Windows applications, while a WSL terminal is a frequent destination.
Privacy rules out a transcription API and an everyday network dependency.

## Decision

Use Tauri 2 and Rust; integrate whisper.cpp through the `whisper-rs` crate; keep
capture and insertion in the Rust backend. The local interface only represents
states and sends explicit actions to the backend.

## Consequences

- Transcription, audio, and preferences remain on the PC.
- There is no resident Python service or HTTP server to maintain.
- The binary must compile Whisper's native dependency, and the user must provide
  a local model.
- Elevated processes remain subject to Windows integrity rules.
