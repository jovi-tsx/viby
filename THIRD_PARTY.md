# Third-party components

Viby's own source and bundled artwork are licensed under [MIT](LICENSE).
Dependencies keep their upstream licenses; the project license does not replace
their notices.

The principal components are:

- [Tauri](https://github.com/tauri-apps/tauri), plus its store and global-shortcut plugins.
- [whisper-rs](https://github.com/tazz4843/whisper-rs), including its
  [whisper.cpp](https://github.com/ggml-org/whisper.cpp) native dependency.
- [CPAL](https://github.com/RustAudio/cpal) for Windows audio capture.
- [windows-rs](https://github.com/microsoft/windows-rs) for Win32 bindings.
- [Vite](https://github.com/vitejs/vite) and
  [TypeScript](https://github.com/microsoft/TypeScript) for the local interface.

Exact source dependency versions are recorded in `src-tauri/Cargo.lock` and
`package-lock.json`. Consult each installed package's license and notices
before redistributing a compiled bundle.

Whisper model weights are not included or downloaded automatically. Supply a
compatible model separately and retain the terms accompanying that model.
