# Viby — final identity

This logo was confirmed as final on 2026-10-28 (D18). There is one identity:
a green rounded square with the waveform V and typing cursor cut out.
The exterior and both cutouts are transparent.

## Final files

- [viby-icon.svg](viby-icon.svg) — canonical editable vector master.
- [viby-icon.ai](viby-icon.ai) — editable Illustrator source.
- [viby-icon.png](viby-icon.png) — generated transparent 2048 × 2048 image.
- [viby-icon-preview.png](viby-icon-preview.png) — same final logo on a dark backdrop.

Brand green: `#1ddd66`; UI hover: `#42e581`. Options and both local page
favicons render the SVG. Files under `src-tauri/icons/` are required size and
platform derivatives of this same logo, not alternate designs.

Old variants, archived artwork and duplicate exports have been removed.

## Regeneration

Run from the repository root in WSL:

```sh
npm run icons
npm run build
```

Native builds and smoke tests run on Windows. Assets are bundled locally.
