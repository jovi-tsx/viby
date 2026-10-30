# ADR 0002 — Viby bridges to a user-managed local engine

> **Status:** accepted 2026-10-30 (D20, D23). Supersedes
> [ADR 0001](0001-local-whisper-rust-desktop.md) for transcription; the
> Tauri/Rust host, capture, and insertion decisions of ADR 0001 stand.

## Context

ADR 0001 compiled whisper.cpp into Viby through `whisper-rs`. The product is
the desktop interaction — shortcut, capture, dock, confirmation, insertion into
the focused application — and the user wants to run, choose, and update their
own speech-to-text engine and model. Embedding one engine tied Viby to it,
required LLVM/libclang for every build, and made Viby responsible for model
files.

## Decision

Viby contains no inference engine and bundles, downloads, starts, or manages
no engine, server, or model. It sends each take to an endpoint the user
configures, using one wire shape: HTTP `POST` `multipart/form-data` with the
audio as WAV and `response_format=json`, answered by a JSON object with a
`text` string. This is the OpenAI transcription shape and the shape of
whisper.cpp's `/inference`, so one adapter reaches the common local servers.
The full contract is R3 and R3a of the
[dictation spec](../specs/voice-dictation.md).

The endpoint must be loopback, or a private-network address the user
explicitly allowed. The host is checked on every connection, redirects and
proxies are not used, and there is no remote fallback.

## Consequences

- Any engine that answers the shape works; Viby is not coupled to one.
- The Rust build loses `whisper-rs`, the native whisper.cpp compile, and the
  LLVM/`LIBCLANG_PATH` prerequisite.
- Out of the box, Viby transcribes nothing until the user runs an engine and
  configures it; the first-run message must say so.
- Viby now opens local sockets during dictation. The privacy promise moves from
  "no network" to "the audio never leaves this PC, or the private network the
  user allowed".
- Engines requiring credentials, streaming protocols, and command-line engines
  are out of scope until a later decision.
