# Third-party components

Viby's own source and bundled artwork are licensed under [MIT](LICENSE).
Dependencies keep their upstream licenses; the project license does not replace
their notices.

The principal components are:

- [Tauri](https://github.com/tauri-apps/tauri), plus its store and global-shortcut plugins.
- [reqwest](https://github.com/seanmonstar/reqwest) with
  [rustls](https://github.com/rustls/rustls) and [ring](https://github.com/briansmith/ring)
  for the request to the user's engine, and [Tokio](https://github.com/tokio-rs/tokio).
- [CPAL](https://github.com/RustAudio/cpal) for Windows audio capture.
- [windows-rs](https://github.com/microsoft/windows-rs) for Win32 bindings.
- [Vite](https://github.com/vitejs/vite) and
  [TypeScript](https://github.com/microsoft/TypeScript) for the local interface.

Exact source dependency versions are recorded in `src-tauri/Cargo.lock` and
`package-lock.json`. Consult each installed package's license and notices
before redistributing a compiled bundle.

No speech-to-text engine or model is included or downloaded. The engine you
run, and its model, keep their own licenses and terms.

## Bundled font

[Manrope](https://github.com/googlefonts/manrope), copyright 2018 The Manrope
Project Authors, is bundled locally as an original variable TTF and WOFF2
conversion under the SIL Open Font License 1.1. The complete
[license](assets/fonts/manrope/OFL.txt) and
[pinned source record](assets/fonts/manrope/SOURCE.md) accompany both files.
The application never requests fonts from a remote service. The repository's
MIT license does not replace this font license.
