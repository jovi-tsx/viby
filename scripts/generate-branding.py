#!/usr/bin/env python3
"""Regenerate Viby brand exports from the approved icon and bundled Manrope.
Developer-only dependencies: scripts/branding-requirements.txt (WSL).
Never downloads assets or modifies the canonical icon / Illustrator source.
"""
from pathlib import Path
from io import BytesIO
import hashlib
import html
import json
import re
import xml.etree.ElementTree as ET
import zipfile

import cairosvg
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.transformPen import TransformPen

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / "assets/branding"
FONTS = ROOT / "assets/fonts/manrope"
# The CSS is the canonical palette for generated artwork as well as the app.
TOKEN_NAMES = {
    "green": "green", "hover": "accent-hover", "ink": "ink",
    "canvas": "canvas", "surface": "card", "border": "border",
    "control": "control-border", "paper": "text", "muted": "muted",
    "deep": "green-ink", "error": "error",
}
tokens = (BRAND / "tokens.css").read_text()
COLORS = {
    key: re.search(r"--" + name + r":\s*(#[0-9a-fA-F]{6});", tokens).group(1).upper()
    for key, name in TOKEN_NAMES.items()
}
NS = {"s": "http://www.w3.org/2000/svg"}
ICON_D = ET.parse(BRAND / "viby-icon.svg").find(".//s:path", NS).attrib["d"]
UPSTREAM_HASH = "3ae11c49db0455a3cc33e37d380f20fdb8c7f8b41dc07625c177e3d87a9d6ae6"
assert hashlib.sha256((FONTS / "Manrope-Variable.ttf").read_bytes()).hexdigest() == UPSTREAM_HASH
font = TTFont(FONTS / "Manrope-Variable.ttf", recalcTimestamp=False)
font.flavor = "woff2"
font.save(FONTS / "Manrope-Variable.woff2")
fonts = {}
generated = []

def face(weight):
    if weight not in fonts:
        variable = TTFont(FONTS / "Manrope-Variable.ttf", recalcTimestamp=False)
        fonts[weight] = instantiateVariableFont(variable, {"wght": weight}, inplace=True)
    return fonts[weight]

def text_path(text, x, baseline, size, color, weight=600, tracking=0):
    f = face(weight)
    glyphs, cmap = f.getGlyphSet(), f.getBestCmap()
    scale, advance, paths = size / f["head"].unitsPerEm, 0, []
    for char in text:
        name = cmap[ord(char)]
        pen = SVGPathPen(glyphs)
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, x + advance, baseline)))
        paths.append(pen.getCommands())
        advance += glyphs[name].width * scale + tracking
    return f'<path fill="{color}" d="{" ".join(paths)}"/>'

def icon(x, y, size, color=COLORS["green"]):
    return f'<path fill="{color}" fill-rule="evenodd" transform="translate({x} {y}) scale({size / 1024})" d="{ICON_D}"/>'

def lockup(x, y, height, word_color, mark_color=COLORS["green"]):
    # Stable optical spacing, derived from the same font bundled in the app.
    return icon(x, y, height, mark_color) + text_path("Viby", x + height * 1.29,
        y + height * .76, height * .92, word_color, 700, -height * .023)

def svg(width, height, title, content):
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title"><title id="title">{html.escape(title)}</title>{content}</svg>\n'

def export(name, width, height, title, content, raster=True):
    data = svg(width, height, title, content)
    (BRAND / (name + ".svg")).write_text(data, encoding="utf-8")
    generated.append(name + ".svg")
    if raster:
        cairosvg.svg2png(bytestring=data.encode(), write_to=str(BRAND / (name + ".png")),
                        output_width=width, output_height=height)
        generated.append(name + ".png")

for tone, color in [("ink", COLORS["ink"]), ("light", COLORS["paper"])]:
    export("viby-lockup-" + tone, 720, 240, "Viby",
           lockup(24, 24, 192, color))
    export("viby-lockup-mono-" + tone, 720, 240, "Viby monochrome",
           lockup(24, 24, 192, color, color))
    export("viby-wordmark-" + tone, 480, 240, "Viby wordmark",
           text_path("Viby", 24, 168, 188, color, 700, -4.7))
    export("viby-icon-mono-" + tone, 1024, 1024, "Viby monochrome icon",
           icon(0, 0, 1024, color))

export("viby-avatar", 1024, 1024, "Viby avatar",
       f'<rect width="1024" height="1024" fill="{COLORS["ink"]}"/>' + icon(176, 176, 672))
banner = f'<rect width="1600" height="480" fill="{COLORS["paper"]}"/>'
banner += lockup(72, 48, 64, COLORS["ink"])
banner += text_path("Your voice.", 72, 239, 88, COLORS["ink"], 650, -2)
banner += text_path("Your words.", 72, 336, 88, COLORS["ink"], 650, -2)
banner += text_path("Local dictation for Windows.", 76, 410, 24, COLORS["deep"], 500)
banner += icon(1168, 100, 280)
export("viby-github-banner", 1600, 480, "Viby — Your voice. Your words.", banner)

social = f'<rect width="1280" height="640" fill="{COLORS["ink"]}"/>'
social += lockup(64, 52, 72, COLORS["paper"])
social += text_path("Your voice.", 64, 280, 88, COLORS["paper"], 650, -2)
social += text_path("Your words.", 64, 378, 88, COLORS["paper"], 650, -2)
social += text_path("Local dictation for Windows.", 68, 468, 26, COLORS["muted"], 500)
social += icon(914, 218, 256)
social += text_path("OPEN SOURCE", 68, 579, 16, COLORS["green"], 700, 2)
social += text_path("Pre-alpha · github.com/jovi-tsx/viby", 68, 610, 15, COLORS["muted"], 500)
export("viby-social-preview", 1280, 640, "Viby — local dictation for Windows. Pre-alpha.", social)

# Compact transparent avatar for GitHub / other surfaces with their own background.
data = (BRAND / "viby-icon.svg").read_bytes()
cairosvg.svg2png(bytestring=data, write_to=str(BRAND / "viby-icon-512.png"),
                output_width=512, output_height=512)
generated.append("viby-icon-512.png")
manifest = {
    "source_icon_sha256": hashlib.sha256(data).hexdigest(),
    "font_source_sha256": UPSTREAM_HASH,
    "colors": COLORS,
    "files": {name: hashlib.sha256((BRAND / name).read_bytes()).hexdigest() for name in sorted(generated)},
}
(BRAND / "exports.json").write_text(json.dumps(manifest, indent=2) + "\n")
# The ZIP is an intentional downloadable deliverable, not another identity.
# Byte-stable timestamps make regeneration auditable.
names = sorted(p for p in BRAND.iterdir() if p.is_file() and p.suffix in {".svg", ".png", ".ai", ".md", ".css", ".html", ".json"})
with zipfile.ZipFile(BRAND / "viby-brand-kit.zip", "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    items = [(p, Path("branding") / p.name) for p in names]
    items += [(p, Path("fonts/manrope") / p.name) for p in sorted(FONTS.iterdir()) if p.is_file()]
    items += [(ROOT / "LICENSE", Path("LICENSE"))]
    for source, target in items:
        info = zipfile.ZipInfo(target.as_posix(), (2026, 10, 29, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, source.read_bytes())
print(f"Generated {len(generated)} exports, font, manifest and brand kit.")
