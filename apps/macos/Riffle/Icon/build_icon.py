"""Builds the Riffle app icon: a riffled fan of envelopes on an Ink field.

Writes icon.svg next to this script and every macOS size into the AppIcon asset catalog.
Needs the resvg-py package: pip install resvg-py
"""
import json
from pathlib import Path

import resvg_py

HERE = Path(__file__).parent
APPICON = HERE.parent / "Riffle" / "Assets.xcassets" / "AppIcon.appiconset"

W, H, R = 470, 312, 30          # envelope size and corner radius
PIVOT = (500, 900)              # fan pivot, below the envelopes
CX, CY = 500, 548               # envelope center before rotation

# back to front: angle, fill, flap stroke, lift
CARDS = [
    (-22, "#5F7FBF", "#3F60A3", 0),
    (-13, "#87A1D6", "#4C6CAC", 0),
    (-4,  "#B3C6EB", "#5574B2", 0),
    (5,   "#DCE6F7", "#5A77AC", 0),
    (15,  "#FFFFFF", "#1F3F7A", 44),
]


def envelope(angle, fill, stroke, lift, front):
    x, y = CX - W / 2, CY - H / 2 - lift
    sw = 16 if front else 13
    flap_y = y + H * 0.56
    inset = 30
    parts = [
        f'<g transform="rotate({angle} {PIVOT[0]} {PIVOT[1]})">',
        f'<rect x="{x}" y="{y}" width="{W}" height="{H}" rx="{R}" fill="{fill}" filter="url(#drop)"/>',
        f'<path d="M{x + inset} {y + inset} L{CX} {flap_y} L{x + W - inset} {y + inset}" '
        f'fill="none" stroke="{stroke}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"/>',
    ]
    if front:
        ly = y + H - 62
        parts.append(
            f'<line x1="{CX - 120}" y1="{ly}" x2="{CX + 120}" y2="{ly}" stroke="#2E5AA8" '
            f'stroke-width="15" stroke-linecap="round" stroke-dasharray="0.1 30"/>'
        )
    parts.append("</g>")
    return "\n".join(parts)


def svg(with_squircle=True):
    body = "\n".join(envelope(a, f, s, l, i == len(CARDS) - 1) for i, (a, f, s, l) in enumerate(CARDS))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="field" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#2E5AA8"/>
    <stop offset="1" stop-color="#142A55"/>
  </linearGradient>
  <radialGradient id="glow" cx="0.5" cy="0.18" r="0.75">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.16"/>
    <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
  </radialGradient>
  <filter id="drop" x="-30%" y="-30%" width="160%" height="170%">
    <feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#0A1A3A" flood-opacity="0.38"/>
  </filter>
  <clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
</defs>
<g clip-path="url(#sq)">
  <rect x="100" y="100" width="824" height="824" fill="url(#field)"/>
  <rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>
  <g transform="translate(26 34)">
{body}
  </g>
</g>
<rect x="100.5" y="100.5" width="823" height="823" rx="184.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.12" stroke-width="2"/>
</svg>'''


source = svg()
(HERE / "icon.svg").write_text(source)

images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = points * scale
        name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
        png = resvg_py.svg_to_bytes(svg_string=source, width=pixels, height=pixels)
        (APPICON / name).write_bytes(bytes(png))
        images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})

contents = {"images": images, "info": {"author": "xcode", "version": 1}}
(APPICON / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
