# Viby brand kit

One approved identity: green rounded square with waveform V and typing cursor
cut out. Symbol finalized 2026-10-28; expanded system approved 2026-10-29.

- [Complete brandbook (Portuguese, 36-page PDF)](brandbook/viby-brandbook.pdf) — strategy, archetype, 56-color scales and software application mocks.
- [Brandbook assets and export instructions](brandbook/README.md).
- [Brand guide](brand-guide.md) — positioning, voice, color, type and usage.
- [Visual brand sheet](brand-sheet.html) — open locally or through the dev server.
- [Download the full kit](viby-brand-kit.zip).
- [Export manifest](exports.json) — asset/source hashes.
- [Implementation tokens](tokens.css) — shared by the app and visual sheet.

## Sources and applications

| Files | Purpose |
| --- | --- |
| `viby-icon.svg` / `viby-icon.ai` | Approved vector master / Illustrator source |
| `viby-icon.png` / `viby-icon-512.png` | Transparent 2048px / 512px icon |
| `viby-icon-preview.png` | Original final symbol on dark backing |
| `viby-lockup-{ink,light}.{svg,png}` | Green icon and outlined name |
| `viby-lockup-mono-{ink,light}.{svg,png}` | One-color horizontal signatures |
| `viby-wordmark-{ink,light}.{svg,png}` | Outlined name |
| `viby-icon-mono-{ink,light}.{svg,png}` | One-color symbol |
| `viby-avatar.{svg,png}` | 1024px avatar with crop safety |
| `viby-github-banner.{svg,png}` | 1600 × 480 repository cover |
| `viby-social-preview.{svg,png}` | 1280 × 640 sharing image |

Colorways are applications of one identity, not competing logo variants.
Canonical green: `#1DDD66`. Exterior/wave/caret transparency stays real.
Manrope source/license: [../fonts/manrope](../fonts/manrope/SOURCE.md).
Outlined signatures require no installed font.

## Regeneration (WSL)

Developer-only export dependencies never become app runtime packages.

```sh
python3 -m venv /tmp/viby-brand-tools
/tmp/viby-brand-tools/bin/python -m pip install -r scripts/branding-requirements.txt
/tmp/viby-brand-tools/bin/python scripts/generate-branding.py
npm run icons
npm run build
```

Run from the repository root. CairoSVG needs the WSL system Cairo library.
The generator reads the checked-in icon and pinned original font; it never
downloads files or modifies the original SVG/AI. It generates outlined SVGs,
PNGs, local WOFF2, manifest and deterministic ZIP.

`npm run icons` is needed only to regenerate native/platform sizes from the
canonical icon. Native builds remain on Windows; Node/frontend tooling in WSL.

## Publication

README uses the repository banner. Upload `viby-social-preview.png` through
GitHub Settings → General → Social preview when configuring that setting.
Committing an image does not automatically change repository settings.
No personal GitHub profile avatar is changed by this kit.
