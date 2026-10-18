#!/usr/bin/env python3
"""Generate the PuralvOS identity assets from brand/tokens.json.

The mark
--------
A P and an A monogram. Pur + Alv, two people, two letters, one signal.

The geometry is deliberately reduced to what a monogram needs: a stem, a
circular bowl, an apex and a crossbar, all on one grid, all one stroke width.
An earlier version drew the letters as waveforms, which read as damaged
glyphs at every size it was asked to work at; a mark that has to survive a
16 px menu icon cannot spend its budget on texture.

The three disciplines are carried by colour instead of shape: one gradient
runs through the whole mark, audio green at the start, video cyan through the
middle, graphics amber at the end. One line, three colours, nothing that has
to be explained.

No orange: that is Ubuntu's trademark and this image is not Ubuntu's.
No spectrum: the obvious three-discipline pictogram, and it is already the
mark of the Freesh-derived audio lineage.

Output is SVG because it stays sharp at every size, plus PNGs drawn with PIL
from the same geometry for the two consumers that cannot take SVG at build
time (plymouth's watermark and the preview). One geometry, several outputs;
the shapes cannot differ because they are not defined twice.

Usage: make-brand.py [output-dir]
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BRAND = os.path.join(HERE, os.pardir, "brand")

# Wallpaper sizes. 1080p and 1440p cover most panels; 4K covers the rest.
TARGETS = {
    "1080p": (1920, 1080),
    "1440p": (2560, 1440),
    "4k": (3840, 2160),
}


def load_tokens():
    with open(os.path.join(BRAND, "tokens.json"), encoding="utf-8") as fh:
        return json.load(fh)


def hex_rgb(value):
    """'#0B0E14' -> (11, 14, 20)."""
    v = value.lstrip("#")
    return tuple(int(v[i:i + 2], 16) for i in (0, 2, 4))


def lerp_rgb(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def gradient_stops(tokens):
    return [hex_rgb(tokens["accent"]["audio"]),
            hex_rgb(tokens["accent"]["video"]),
            hex_rgb(tokens["accent"]["graphics"])]


def gradient_rgb(tokens, t):
    """Colour at position t in [0,1] along the discipline gradient."""
    stops = gradient_stops(tokens)
    if t <= 0.5:
        return lerp_rgb(stops[0], stops[1], t / 0.5)
    return lerp_rgb(stops[1], stops[2], (t - 0.5) / 0.5)


def gradient_png(tokens, size):
    """A diagonal render of the gradient, for compositing through a mask.

    PIL has no gradient primitive; a 2x2 image resized with BILINEAR is a
    four-corner bilinear blend, which for this palette is indistinguishable
    from the SVG's linear gradient at preview size.
    """
    from PIL import Image
    stops = gradient_stops(tokens)
    corner = Image.new("RGB", (2, 2))
    corner.putpixel((0, 0), stops[0])
    corner.putpixel((1, 0), lerp_rgb(stops[0], stops[1], 0.45))
    corner.putpixel((0, 1), lerp_rgb(stops[1], stops[2], 0.35))
    corner.putpixel((1, 1), stops[2])
    return corner.resize((size, size), Image.BILINEAR)


# ----------------------------------------------------------------------
# The mark geometry: one definition, consumed by the SVG writer and by both
# rasterisers. Everything is in a 100 x 100 box.
# ----------------------------------------------------------------------

MARK_BOX = 100.0
MARK_STROKE = 9.6          # one stroke width for every part of the mark
MARK_STEM_X = 27.0
MARK_TOP = 22.0
MARK_BASE = 80.0
MARK_BOWL_R = 15.0         # a true semicircle, not a polygon approximation
MARK_APEX = 22.0
MARK_A_L = 46.0
MARK_A_TIP = 60.0
MARK_A_R = 74.0
MARK_BAR_Y = 61.0
MARK_BAR_X0 = 51.0
MARK_BAR_X1 = 69.0
MARK_BAR_AMP = 2.0


def bowl_points(n=72):
    """Right half of a circle: top of the stem, over the bowl, back to it."""
    cx, cy = MARK_STEM_X, MARK_TOP + MARK_BOWL_R
    pts = []
    for i in range(n + 1):
        a = -math.pi / 2 + math.pi * (i / float(n))
        pts.append((cx + MARK_BOWL_R * math.cos(a),
                    cy + MARK_BOWL_R * math.sin(a)))
    return pts


def crossbar_points(n=48):
    """A single calm period of a wave. Amplitude is a hair over the stroke;
    enough to read as signal, small enough to stay a crossbar."""
    pts = []
    for i in range(n + 1):
        t = i / float(n)
        x = MARK_BAR_X0 + (MARK_BAR_X1 - MARK_BAR_X0) * t
        y = MARK_BAR_Y + MARK_BAR_AMP * math.sin(t * math.pi * 2.0)
        pts.append((x, y))
    return pts


def mark_shapes():
    """The mark's parts as point lists, each one continuous.

    paint is a gradient position: the whole mark shares one gradient, and each
    part is stamped at the colour of its own middle so the pieces read as one
    line that changes colour rather than three coloured pieces.
    """
    return [
        # P: stem and bowl as one path, the way a P is drawn by hand
        {"name": "p-stem", "t": 0.16, "pts": [(MARK_STEM_X, MARK_BASE),
                                              (MARK_STEM_X, MARK_TOP)] + bowl_points()[1:]},
        # A: apex at the same cap height, legs to the same baseline
        {"name": "a-left", "t": 0.55, "pts": [(MARK_A_L, MARK_BASE), (MARK_A_TIP, MARK_APEX)]},
        {"name": "a-right", "t": 0.80, "pts": [(MARK_A_TIP, MARK_APEX), (MARK_A_R, MARK_BASE)]},
        {"name": "a-bar", "t": 0.97, "pts": crossbar_points()},
    ]


def polyline_path(coords, close=False):
    parts = []
    for i, (x, y) in enumerate(coords):
        cmd = "M" if i == 0 else "L"
        parts.append("%s%.2f %.2f" % (cmd, x, y))
    if close:
        parts.append("Z")
    return " ".join(parts)


def build_mark(tokens, size=512, mono=False):
    """The mark as SVG: a deep tile, a hairline, and one gradient line."""
    s = MK = MARK_BOX
    sw = MARK_STROKE
    bg_deep = tokens["background"]["deep"]
    bg_base = tokens["background"]["base"]
    a, v, g = (tokens["accent"]["audio"], tokens["accent"]["video"],
               tokens["accent"]["graphics"])

    if mono:
        stroke = tokens["text"]["primary"]
        grad = ""
    else:
        stroke = "url(#puralvos-grad)"
        grad = (
            '  <linearGradient id="puralvos-grad" x1="0" y1="0" x2="1" y2="1">\n'
            '    <stop offset="0" stop-color="%s"/>\n'
            '    <stop offset="0.5" stop-color="%s"/>\n'
            '    <stop offset="1" stop-color="%s"/>\n'
            '  </linearGradient>\n' % (a, v, g)
        )

    paths = []
    for sh in mark_shapes():
        pts = [(x * s / MK, y * s / MK) for x, y in sh["pts"]]
        paths.append(
            '  <path d="%s" fill="none" stroke="%s" stroke-width="%.2f"\n'
            '        stroke-linecap="round" stroke-linejoin="round"/>'
            % (polyline_path(pts), stroke, sw * s / MK))

    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {s:.0f} {s:.0f}"
     width="{size}" height="{size}" role="img"
     aria-label="PuralvOS">
  <title>PuralvOS</title>
  <desc>A P and an A monogram in one gradient: audio green, video cyan,
  graphics amber. Two letters, one signal.</desc>
{grad}  <defs>
    <linearGradient id="puralvos-tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#121826"/>
      <stop offset="1" stop-color="{bg_deep}"/>
    </linearGradient>
  </defs>
  <rect width="{s:.0f}" height="{s:.0f}" rx="23" fill="url(#puralvos-tile)"/>
  <rect x="1.6" y="1.6" width="{s - 3.2:.0f}" height="{s - 3.2:.0f}" rx="21.4"
        fill="none" stroke="#FFFFFF" stroke-opacity="0.06" stroke-width="0.9"/>
{chr(10).join(paths)}
</svg>
"""


def build_wordmark(tokens, width=1200):
    t = tokens
    h = int(width * 0.22)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {h}"
     width="{width}" height="{h}" role="img" aria-label="PuralvOS">
  <title>PuralvOS</title>
  <text x="0" y="{h * 0.72:.0f}" font-family="Inter, 'DejaVu Sans', sans-serif"
        font-size="{h * 0.66:.0f}" font-weight="600" letter-spacing="{h * 0.01:.0f}"
        fill="{t['text']['primary']}">Pural<tspan fill="{t['accent']['graphics']}">v</tspan>OS</text>
  <text x="{width * 0.415:.0f}" y="{h * 0.72:.0f}" font-family="Inter, 'DejaVu Sans', sans-serif"
        font-size="{h * 0.26:.0f}" letter-spacing="{h * 0.06:.0f}"
        fill="{t['text']['muted']}">{t['tagline'].upper()}</text>
</svg>
"""


def trace(stops, width, height, points=180, amp=0.30, ripple=1.0):
    """A waveform path through waypoints, for the discipline glyphs."""
    def point(t):
        for i in range(len(stops) - 1):
            x0, y0 = stops[i]
            x1, y1 = stops[i + 1]
            if x0 <= t <= x1:
                f = 0 if x1 == x0 else (t - x0) / (x1 - x0)
                e = f * f * (3 - 2 * f)  # smoothstep
                return width * (x0 + (x1 - x0) * f), height * (y0 + (y1 - y0) * e)
        x, y = stops[-1]
        return width * x, height * y

    d = []
    for i in range(points + 1):
        t = i / points
        bx, by = point(t)
        env = math.sin(t * math.pi) ** 0.5
        wobble = math.sin(t * math.pi * 2.0) * height * amp * 0.045 * ripple
        d.append((bx, by + wobble * env))
    return d


def build_icons(tokens, size=64):
    """Single-discipline glyphs for menu entries and the desktop selector."""
    t = tokens
    out = {}
    for key, d in t["disciplines"].items():
        c, s = d["accent"], size
        m = s * 0.16
        w = s - 2 * m
        if d["glyph"] == "waveform":
            pts = trace([(0.06, 0.5), (0.94, 0.5)], w, s, points=120, amp=0.95)
            body = (f'<path d="{polyline_path([(x + m, y) for x, y in pts])}" fill="none" '
                    f'stroke="{c}" stroke-width="{s * 0.07:.0f}" stroke-linecap="round"/>')
        elif d["glyph"] == "play":
            body = (f'<path d="M{m + w * 0.24:.1f} {m + w * 0.14:.1f} '
                    f'L{m + w * 0.80:.1f} {s / 2:.1f} L{m + w * 0.24:.1f} '
                    f'{s - m - w * 0.14:.1f} Z" fill="{c}"/>')
        else:  # aperture
            blades = []
            for i in range(6):
                a0 = math.radians(i * 60)
                a1 = math.radians(i * 60 + 42)
                r0, r1 = w * 0.46, w * 0.20
                cx, cy = s / 2, s / 2
                blades.append(
                    f'<path d="M{cx + r0 * math.cos(a0):.1f} {cy + r0 * math.sin(a0):.1f} '
                    f'L{cx + r0 * math.cos(a1):.1f} {cy + r0 * math.sin(a1):.1f} '
                    f'L{cx + r1 * math.cos(a1):.1f} {cy + r1 * math.sin(a1):.1f} '
                    f'L{cx + r1 * math.cos(a0):.1f} {cy + r1 * math.sin(a0):.1f} Z" '
                    f'fill="{c}" fill-opacity="0.92"/>')
            body = "".join(blades)
        out[key] = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {s} {s}" '
                    f'width="{size}" height="{size}">{body}</svg>\n')
    return out


# ----------------------------------------------------------------------
# Rasterisers
# ----------------------------------------------------------------------

def _render_mark_mask(size, stroke_scale=1.0, ss=2):
    """The mark's strokes as a white-on-black L mask at size x ss."""
    from PIL import Image, ImageDraw
    px = int(size * ss)
    f = px / MARK_BOX
    mask = Image.new("L", (px, px), 0)
    d = ImageDraw.Draw(mask)
    w = max(2, int(MARK_STROKE * f * stroke_scale * 1.02))
    for sh in mark_shapes():
        pts = [(x * f, y * f) for x, y in sh["pts"]]
        # Segment at a time, with round joints drawn by hand. Pillow's own
        # joint="curve" fills the wedge between consecutive segments and on
        # a fine polyline that wedge comes out as a sliver comb: the mark
        # renders as a hedgehog. Overlapping caps are the same union without
        # the wedges.
        for a, b in zip(pts, pts[1:]):
            d.line([a, b], fill=255, width=w)
        for x, y in pts:
            d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)
    return mask


def render_preview(tokens, png_path, size=900):
    """Rasterise the mark with the tile and the gradient, so it can be judged.

    The SVG is the deliverable but there is no SVG rasteriser on this machine;
    this draws the same geometry through the same gradient so what gets
    reviewed is what gets built.
    """
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return None

    ss = 2
    px = size * ss
    tile = Image.new("RGB", (px, px), hex_rgb(tokens["background"]["deep"]))
    d = ImageDraw.Draw(tile)
    top = hex_rgb("#121826")
    bot = hex_rgb(tokens["background"]["deep"])
    for y in range(px):
        d.line([(0, y), (px, y)], fill=lerp_rgb(top, bot, y / float(px)))
    rounded = Image.new("L", (px, px), 0)
    ImageDraw.Draw(rounded).rounded_rectangle([0, 0, px - 1, px - 1],
                                              radius=int(23 * px / MARK_BOX), fill=255)

    grad = gradient_png(tokens, px)
    mask = _render_mark_mask(size, ss=ss)
    tile.paste(Image.composite(grad, Image.new("RGB", (px, px), (0, 0, 0)), mask), (0, 0), mask)

    frame = Image.new("L", (px, px), 0)
    ImageDraw.Draw(frame).rounded_rectangle(
        [int(1.6 * px / MARK_BOX), int(1.6 * px / MARK_BOX),
         px - 1 - int(1.6 * px / MARK_BOX), px - 1 - int(1.6 * px / MARK_BOX)],
        radius=int(21.4 * px / MARK_BOX), outline=64,
        width=max(1, int(0.9 * px / MARK_BOX)))
    tile.paste((255, 255, 255), (0, 0), frame)

    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    out.paste(tile, (0, 0), rounded)
    out = out.resize((size, size), Image.LANCZOS)
    out.save(png_path)
    return png_path


def render_mark_png(tokens, path, size=256, transparent=False):
    """The mark alone, for plymouth and SDDM, which take bitmaps only."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return None

    ss = 2
    px = size * ss
    mask = _render_mark_mask(size, ss=ss)
    grad = gradient_png(tokens, px)

    if transparent:
        body = Image.new("RGB", (px, px), (0, 0, 0))
        body = Image.composite(grad, body, mask)
        im = Image.new("RGBA", (px, px), (0, 0, 0, 0))
        im.paste(body, (0, 0), mask)
    else:
        im = Image.new("RGB", (px, px), hex_rgb(tokens["background"]["deep"]))
        im = Image.composite(grad, im, mask)
    im = im.resize((size, size), Image.LANCZOS)
    im.save(path)
    return path


def _bezier(p0, p1, p2, p3, t):
    u = 1.0 - t
    return (u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
            u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1])


def _ribbon_polygon(p0, p1, p2, p3, w_start, w_mid, w_end, n=220):
    """A tapered ribbon: the centreline's offset curves, out and back.

    PIL draws constant-width lines only; a polygon between two offset copies
    of the centreline is how a stroke that grows and thins like silk gets a
    smooth silhouette with no visible joints.
    """
    upper, lower = [], []
    for i in range(n + 1):
        t = i / float(n)
        cx, cy = _bezier(p0, p1, p2, p3, t)
        dx, dy = _bezier(p0, p1, p2, p3, min(1.0, t + 0.004))
        ex, ey = _bezier(p0, p1, p2, p3, max(0.0, t - 0.004))
        tx, ty = dx - ex, dy - ey
        tl = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / tl, tx / tl
        # width profile: rises quickly, holds, tapers at the far end
        prof = (w_start + (w_mid - w_start) * min(1.0, t / 0.35)) if t < 0.35 \
            else (w_mid + (w_end - w_mid) * ((t - 0.35) / 0.65) ** 1.4)
        hw = prof / 2.0
        upper.append((cx + nx * hw, cy + ny * hw))
        lower.append((cx - nx * hw, cy - ny * hw))
    return upper + lower[::-1]


def build_wallpaper(tokens, width=3840, height=2160, variant="deep"):
    """Night signal: a deep field, three coloured atmospheres, three ribbons.

    The previous wallpaper was a dense field of thin sinusoids and it is the
    reason this one is sparse. Tight thin lines at high density read as
    noise, not as craft, and no amount of glow fixes that: what fixes it is
    keeping three ribbons and giving each one room, a taper, and its own
    column of light to sit in.

    Three, not eight: the palette is three disciplines, and a wallpaper that
    needs a fourth colour is telling a different story.
    """
    from PIL import Image, ImageDraw, ImageChops, ImageFilter

    ss = 2
    w, h = width * ss, height * ss
    base_deep = hex_rgb(tokens["background"]["deep"])
    base_soft = hex_rgb("#0A0E16")

    # The field: a vertical wash, soft at the top, deepest at the bottom.
    im = Image.new("RGB", (w, h), base_deep)
    d = ImageDraw.Draw(im)
    for y in range(h):
        d.line([(0, y), (w, y)], fill=lerp_rgb(base_soft, base_deep, y / float(h)))

    # Atmosphere. Three big, dim lights in the three discipline colours. Dim is
    # the point: these are here to tint the black, not to be looked at.
    atmos = [
        (0.10, 0.95, 0.74, tokens["accent"]["audio"], 0.15),
        (0.82, 0.42, 0.85, tokens["accent"]["video"], 0.15),
        (0.72, 1.02, 0.66, tokens["accent"]["graphics"], 0.13),
    ]
    for fx, fy, fr, colour, strength in atmos:
        rad = max(w, h) * fr * 0.55
        cx, cy = w * fx, h * fy
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(rad * 0.5))
        mask = mask.point(lambda v, s=strength: int(v * s))
        im.paste(Image.new("RGB", (w, h), colour), (0, 0), mask)

    # The ribbons. One per discipline, ascending left to right, the way a
    # signal rises. Each sits low enough that the top of the frame stays
    # quiet for icons.
    ribbons = [
        # colour, start, c1, c2, end, widths (start, mid, end)
        (0, (0.02, 0.86), (0.28, 0.80), (0.55, 0.92), (0.99, 0.60), (2, 22, 5)),
        (1, (0.00, 0.97), (0.34, 0.90), (0.62, 1.00), (1.00, 0.68), (3, 30, 7)),
        (2, (0.06, 1.00), (0.30, 0.96), (0.62, 1.02), (0.97, 0.74), (2, 20, 5)),
    ]
    stops = gradient_stops(tokens)

    lines = Image.new("RGB", (w, h), (0, 0, 0))
    hot = Image.new("RGB", (w, h), (0, 0, 0))
    dl = ImageDraw.Draw(lines)
    dh = ImageDraw.Draw(hot)
    unit = h / 1080.0 * 1.15 * ss / 2.0
    for idx, p0, p1, p2, p3, (w0, wm, w1) in ribbons:
        colour = stops[idx]
        poly = _ribbon_polygon((p0[0] * w, p0[1] * h), (p1[0] * w, p1[1] * h),
                               (p2[0] * w, p2[1] * h), (p3[0] * w, p3[1] * h),
                               w0 * unit, wm * unit, w1 * unit)
        dl.polygon(poly, fill=colour)
        # a thin, brighter core on the same centreline, for the metal shine
        core = _ribbon_polygon((p0[0] * w, p0[1] * h), (p1[0] * w, p1[1] * h),
                               (p2[0] * w, p2[1] * h), (p3[0] * w, p3[1] * h),
                               max(1, w0 * unit * 0.30), wm * unit * 0.22,
                               max(1, w1 * unit * 0.30))
        dh.polygon(core, fill=tuple(min(255, int(c + (255 - c) * 0.35)) for c in colour))

    # Compose: atmosphere, then the ribbons, then two haloes, then the core.
    halo1 = lines.filter(ImageFilter.GaussianBlur(radius=max(6, h // 90)))
    halo2 = lines.filter(ImageFilter.GaussianBlur(radius=max(18, h // 26)))
    im = ImageChops.add(im, halo2.point(lambda v: min(255, int(v * 0.45))))
    im = ImageChops.add(im, halo1.point(lambda v: min(255, int(v * 0.75))))
    im = ImageChops.add(im, lines)
    im = ImageChops.add(im, hot)

    # Vignette: darken the corners so the eye lands in the middle.
    vig = Image.new("L", (w, h), 0)
    ImageDraw.Draw(vig).ellipse([-w * 0.25, -h * 0.35, w * 1.25, h * 1.35], fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(max(w, h) // 12))
    vig = vig.point(lambda v: 150 + int(v * 0.41))
    im = ImageChops.multiply(im, Image.merge("RGB", (vig, vig, vig)))

    # Grain. Large flat gradients band on 8-bit panels; a little noise is the
    # standard dither and it also gives the black a filmic texture.
    im = im.resize((width, height), Image.LANCZOS)
    noise = Image.effect_noise((width, height), 12).convert("RGB")
    im = Image.blend(im, ImageChops.overlay(im, noise), 0.10)
    return im


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(BRAND, "assets")
    os.makedirs(outdir, exist_ok=True)
    tokens = load_tokens()

    written = []

    def write(name, content):
        path = os.path.join(outdir, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        written.append(os.path.relpath(path, outdir))

    write("mark.svg", build_mark(tokens, 512))
    write("mark-mono.svg", build_mark(tokens, 512, mono=True))
    write("wordmark.svg", build_wordmark(tokens, 1200))
    for name, svg in build_icons(tokens, 256).items():
        write("glyph-%s.svg" % name, svg)

    print("brand assets written to %s" % outdir)
    for w in sorted(written):
        print("  %s" % w)

    preview = os.path.join(outdir, "preview-mark.png")
    if render_preview(tokens, preview):
        print("\npreview: %s" % preview)
    else:
        print("\npreview skipped: PIL not available")

    for name, px, transparent in (("mark-256.png", 256, False),
                                  ("mark-alpha-256.png", 256, True)):
        path = os.path.join(outdir, name)
        if render_mark_png(tokens, path, px, transparent):
            written.append(name)
            print("  %s  %dpx%s" % (name, px, " transparent" if transparent else ""))
        else:
            print("  %s skipped: PIL not available" % name)

    try:
        import PIL  # noqa: F401
        for name, px in TARGETS.items():
            path = os.path.join(outdir, "wallpaper-%s.png" % name)
            build_wallpaper(tokens, px[0], px[1], "deep").save(path, optimize=True)
            written.append(os.path.relpath(path, outdir))
            print("  %s  %dx%d  %.1f MB" % (
                os.path.relpath(path, outdir), px[0], px[1],
                os.path.getsize(path) / 1048576.0))
        # The Plasma look-and-feel picker wants a JPEG for the full screen
        # preview. Converted from the 1080p render rather than rendered again:
        # it is the same picture at a smaller size and rebuilding it would only
        # make the two capable of drifting apart.
        from PIL import Image
        lnf = os.path.join(outdir, "lnf-fullscreenpreview.jpg")
        Image.open(os.path.join(outdir, "wallpaper-1080p.png")) \
            .convert("RGB").save(lnf, quality=88, optimize=True)
        written.append(os.path.relpath(lnf, outdir))
        print("  %s  %dx%d  %.1f MB" % (
            os.path.relpath(lnf, outdir), 1920, 1080,
            os.path.getsize(lnf) / 1048576.0))
    except ImportError:
        print("wallpapers skipped: PIL not available")
    return 0


if __name__ == "__main__":
    sys.exit(main())
