# ADR 0001 — Tauri/Rust with local whisper.cpp

> **Status:** superseded for transcription by
> [ADR 0002](0002-user-managed-local-engine.md) (2026-10-30). The Tauri/Rust
> host, capture, and insertion decisions below still stand; the embedded
> whisper.cpp decision describes the prototype that milestone M2b removes.

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
