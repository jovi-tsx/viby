# Viby brand guide

Version 1 · 29 October 2026 · Minimalist and welcoming

[Visual brand sheet](brand-sheet.html) · [Download the kit](viby-brand-kit.zip) ·
[Asset inventory and regeneration](README.md)

## Expanded brandbook

The [complete Portuguese brandbook](brandbook/viby-brandbook.pdf) defines the
Companion/Everyperson archetype with Creator support and the complete tonal
palette. Its [56-color source](brandbook/palette.json), wallpapers, watermark
exports and software mockups are in [the brandbook kit](brandbook/README.md).
This English guide remains the concise operational reference. Current app
token values and the approved symbol are unchanged.

## The idea

Viby makes room for your voice in the Windows desktop. It is the interaction
between speaking and writing: a shortcut, a moment of speech and a text result.
The product is a bridge to speech-to-text AI operated locally by the user.

**Promise:** a simple, calm way to turn speech into writing while keeping
control of the local AI setup.

**Public descriptor:** A Windows dictation bridge for your local AI.

**Expressive line:** Your voice. Your words.

**Portuguese line:** Sua voz. Suas palavras.

Use the descriptor to explain the software. Use the expressive line on covers.
Neither replaces honest feature status: 0.0.1 is pre-alpha; dynamic local-engine
connections, automatic insertion and installer distribution remain unfinished.

## Audience and personality

For people who would rather speak than interrupt their work to type, and who
want to operate their own speech-to-text setup. Describe familiar actions
before connection details. Developer documentation may explain protocols;
product controls name what the person can change.

- **Clear:** one action and one useful message at a time.
- **Welcoming:** familiar words, comfortable spacing and gentle shapes.
- **Quiet:** stay out of the way while the person works.
- **Trustworthy:** describe actual state and make privacy statements specific.
- **Independent:** Viby is the app, not the speech recognition engine.

Write **Viby**, with capital V, in prose, headings and the wordmark. Use `viby`
for identifiers, paths and URLs. Do not rename the product after an engine.
Whisper is the current prototype implementation.

## One symbol

The approved symbol is the green rounded square containing a sound-wave V
and typing cursor as transparent cutouts. The wave connects speech to a letter;
the cursor connects that letter to writing.

`viby-icon.svg` is the geometric source of truth. `viby-icon.ai` is the editable
Illustrator source of the same approved mark. SVG drives platform exports.
The icon is not redrawn as part of this expanded system.

### Signatures

| Application | Artwork |
| --- | --- |
| Standard on light backgrounds | `viby-lockup-ink.svg` |
| Standard on dark backgrounds | `viby-lockup-light.svg` |
| One-color dark print/restrictive media | `viby-lockup-mono-ink.svg` |
| One-color light application | `viby-lockup-mono-light.svg` |
| Tight app/tray/avatar space | approved icon at the appropriate generated size |
| Text-only application | outlined ink/light wordmark |

These are colorways/layouts of one identity, not separate logo proposals.
Standard signatures keep the icon green; the name adapts to its surface.

### Space and size

Let **S** be the visible square's width. Reserve at least **S / 4** of clear
space around the complete signature or isolated symbol. Canvas padding is not
guaranteed clear space: add layout spacing when placing an export.

Use the primary icon at 24px or larger in interface content. Native tray/favicon
sizes below 24px are constrained exceptions; use generated platform files.
Use a horizontal signature at 120px or larger; below that, prefer the icon.
For print start at 8mm for the icon or 28mm for the signature, then proof the
actual medium. Preserve the supplied optical alignment.

### Backgrounds and prohibited use

Cutouts are real transparency: the surface underneath shows through. Choose a
flat background preserving the silhouette. On busy material, provide a solid
backing panel and clear space.

Do not stretch, rotate, add shadows/glows, close the cutouts, reconstruct the
wave, clip the already-rounded square again, recolor individual details, or
replace the name with an engine name. Do not put white words on bright green
or use bright green as small text on paper.

One-color marks may use ink, paper or exact brand green when contrast permits.
Additional arbitrary colors are outside the kit.

## Color system

| Token | Hex | Role |
| --- | --- | --- |
| Viby green | `#1DDD66` | Symbol, primary action, active audio |
| Green hover | `#42E581` | Primary action hover |
| Ink | `#111713` | Text on paper and green |
| Canvas | `#0F1411` | Dark app background |
| Surface | `#19211C` | Cards/dock plates |
| Paper | `#F4F7F2` | Light brand surface; dark-interface text |
| Muted | `#AEBBB0` | Supporting text on dark |
| Green ink | `#136D3A` | Small green text on paper |
| Divider | `#2E3B32` | Decorative grouping |
| Control boundary | `#64756A` | Identifiable controls |
| Error | `#FF9B91` | Error text/intent on dark |

`tokens.css` is the implementation source; `src/styles.css` consumes it.
Do not create independent palettes in other stylesheets.

Dividers are quiet and never the sole control identifier. Normal text requires
4.5:1; large text/essential non-text indicators require 3:1. Green buttons use
ink text; small green text on paper uses green ink. Recheck contrast after
opacity/overlay changes. Disabled controls retain readable labels.
Options remains dark-only; light kit examples do not promise a new app theme.

## Typography

**Manrope** is the brand/product face. Open shapes soften the technical subject
while keeping interface text compact.

| Role | Weight | Starting size / line-height |
| --- | --- | --- |
| Brand statement | 600–700 | 48–88px / 1.1 |
| App heading | 650–700 | 24px / 1.2 |
| Group label | 650 | 14px / 1.4 |
| Label/body | 450–550 | 14px / 1.55 |
| Help/status | 450 | 13px / 1.55 |
| Paths/shortcut values | native monospace | 13px / 1.5 |

Use sentence case. Reserve small uppercase for sparse editorial metadata.
Do not tighten body tracking. The supplied wordmark has fixed optical spacing
and vector outlines; it requires no font installation.

The full variable font is bundled in `assets/fonts/manrope` with Segoe UI/system
fallback. No Google Fonts request is made. The font retains its SIL Open Font
License 1.1 and copyright; see [source](../fonts/manrope/SOURCE.md) and
[license](../fonts/manrope/OFL.txt). Viby source/artwork use MIT; the font keeps
its own license.

## Layout, motion and access

Use a 4px spacing unit: usually 8/12/16/24/32px. Options keeps one column,
labels above controls and help next to each choice. Preserve fieldset/legend
groups. Cards use 16px radii, controls 10px; the dock keeps its capsule.

The symbol supplies the personality. Avoid repeated giant waves/decorative
cursors in settings. One clear signature leaves room for the person's task.

Audio movement represents real microphone input. Processing movement represents
processing; preserve their difference. Add no ambient blinking to Options.
Honor reduced motion and Windows forced colors; keep the discrete meter,
visible focus and live announcements. Color alone never means error/success.
The accepted Narrator/200% evidence waivers are not reintroduced as gates.

## Voice and product writing

Be calm and direct. Buttons name actions; statuses name actual results.
Errors explain what happened and a useful next step.

| Situation | Example |
| --- | --- |
| Save action | Save changes |
| Saved preference | Changes saved |
| Missing microphone | No microphone found. Connect one, then try again. |
| Future failed engine connection | Could not connect. Check that your local engine is running. |
| Canceled take | Canceled — no text was inserted. |
| Future insertion, only after confirmed delivery | Text inserted |

Future connection/insertion examples are writing guidance, not shipped features.
Never show successful insertion until an adapter confirms it.
Avoid “AI-powered magic”, engine-specific identity, excessive exclamations,
blame and “works with every AI”. Compatible engines require an implemented
audio-in/text-out interface.

## Applications

- **README:** light repository banner, retaining the existing pre-alpha notice.
- **Social preview:** `viby-social-preview.png`, 1280 × 640, labeled pre-alpha.
  Upload in GitHub repository settings; committing it alone does not configure
  that setting.
- **Avatar:** `viby-avatar.png`, 1024px, with room for circular cropping.
  This does not authorize changing the maintainer's personal profile.
- **App:** local font, shared tokens, coherent header and existing native controls.
- **Restricted media:** outlined monochrome SVG signatures.

SVGs are editable vector paths, including the name; PNGs are convenience exports.
`viby-brand-kit.zip` contains the same guide/assets, preview, font notices and
license. `exports.json` records generated/source hashes.

## Maintenance

Preserve approved geometry/color. Regenerate, inspect the sheet, check contrast
and verify narrow/desktop layouts. Keep feature maturity truthful. Changing the
symbol or direction requires an explicit decision; export corrections stay
within this system.
