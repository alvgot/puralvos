#!/usr/bin/env python3
"""Generate the PuralvOS identity assets from brand/tokens.json.

The mark
--------
Pur + Alv. Two people, so two traces, drawn as waveforms: one spells a P, the
other an A, and they interlock. Both are waveforms because audio is the
discipline that most defines this machine, and because a wordmark drawn as a
waveform cannot be mistaken for a font sample.

Two things are ruled out on purpose. No orange, because that is Ubuntu's
trademark and this image is not Ubuntu's. No spectrum either: a spectrum is
the obvious choice for a three-discipline logo and it is exactly the mark the
Freesh-derived audio lineage already uses, so an identity built on it would
read as somebody else's. Two complementary letterforms in three accents, and
nothing that has to be explained.

Output is SVG because it stays sharp from a 16 px menu icon to a 4 K wallpaper
and can be recoloured without re-running anything.

Usage: make-brand.py [output-dir]
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BRAND = os.path.join(HERE, os.pardir, "brand")

# Every wallpaper has to cover the resolutions people actually plug into, or
# they get scaled and go soft. 1080p and 1440p are the two that cover most
# laptops and desktops; 4K for the rest. Ultra-wide is deliberately absent:
# nobody designing a workstation wallpaper has a 21:9 panel, and generating a
# spec that is never used is a good way to look like a spec sheet.
TARGETS = {
    "1080p": (1920, 1080),
    "1440p": (2560, 1440),
    "4k": (3840, 2160),
}


def load_tokens():
    with open(os.path.join(BRAND, "tokens.json"), encoding="utf-8") as fh:
        return json.load(fh)


def load_targets():
    path = os.path.join(BRAND, "targets.json")
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def trace(stops, width, height, points=180, amp=0.30, ripple=1.0):
    """A waveform path through a list of (x_fraction, y_fraction) waypoints.

    Interpolated with a smooth curve rather than straight lines, because a
    waveform drawn as a polyline reads as a chart, and one drawn as a wave
    reads as a wave.

    The ripple is deliberately gentle and low frequency. A first pass used six
    cycles across the whole path and 180 samples, which turned the bowl of the
    P into a row of spikes: the oscillation was faster than the sample rate
    could follow, so it aliased. Fewer cycles and fewer samples is what makes
    it look like a drawn line instead of a damaged one.
    """
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
        # Fade the ripple in and out along the path so endpoints stay anchored.
        env = math.sin(t * math.pi) ** 0.5
        wobble = math.sin(t * math.pi * 2.0) * height * amp * 0.045 * ripple
        d.append((bx, by + wobble * env))
    return d


def polyline_path(coords, close=False):
    parts = []
    for i, (x, y) in enumerate(coords):
        cmd = "M" if i == 0 else "L"
        parts.append("%s%.2f %.2f" % (cmd, x, y))
    if close:
        parts.append("Z")
    return " ".join(parts)


def mark_geometry(size):
    """The one definition of the mark's geometry.

    Both the SVG writer and the PIL preview consume this. They each used to
    carry their own copy and they drifted: after the strokes were rebalanced,
    a fixed SVG still rendered with the old spiky preview that still had the
    stray dot in the corner. A preview that shows something the product does
    not do is worse than no preview at all, because it is believed. So there is
    now one place the shape is defined and everything reads from it.
    """
    s = float(size)
    m = s * 0.16
    w = s - 2 * m

    # Both letters share a baseline and a cap height. The first pass let the P
    # run taller than the A and the pair read as unbalanced rather than as a
    # monogram.
    baseline, cap = 0.88, 0.18

    def shift(pts):
        return [(x + m, y) for x, y in pts]

    return {
        "size": s,
        "margin": m,
        "box": (s * 0.03, s * 0.03, s * 0.97, s * 0.97),
        "corner": s * 0.18,
        "box_radius": s * 0.15,
        "edge_width": s * 0.008,
        # roles, so the colours live in one place and cannot drift either
        "shapes": [
            ("audio", s * 0.042, shift(trace([(0.06, baseline), (0.06, cap)], w, s, 90, 0.40))),
            # The bowl is an arc with seven waypoints, not the five-corner kink
            # it was. Five points left a hard corner where the curve turned over
            # and the P read as a flag on a pole rather than a letter.
            ("audio", s * 0.042, shift(trace([(0.06, cap), (0.20, cap + 0.01), (0.31, cap + 0.09),
                                             (0.34, 0.38), (0.30, 0.52), (0.19, 0.58),
                                             (0.06, 0.58)], w, s, 140, 0.16, ripple=0.4))),
            ("video", s * 0.042, shift(trace([(0.60, baseline), (0.75, cap)], w, s, 90, 0.30))),
            ("video", s * 0.042, shift(trace([(0.75, cap), (0.90, baseline)], w, s, 90, 0.30))),
            # graphics on the crossbar: the third discipline is the one that
            # holds the two letters together
            ("graphics", s * 0.038, shift(trace([(0.655, 0.62), (0.845, 0.62)], w, s, 40, 0.10, ripple=0.3))),
        ],
    }


def build_mark(tokens, size=512, mono=False):
    t = tokens
    bg = t["background"]["base"]
    edge = t["background"]["edge"]
    if mono:
        # One colour, for engraving, single-colour print, a boot splash on a
        # monochrome menu, or anywhere the three accents cannot survive. This
        # is not the colour mark faded down: it drops the accent encoding
        # entirely, because half-strength green is just a slightly darker
        # white.
        colours = {k: t["text"]["primary"] for k in ("audio", "video", "graphics")}
    else:
        colours = {
            "audio": t["accent"]["audio"],
            "video": t["accent"]["video"],
            "graphics": t["accent"]["graphics"],
        }
    g = mark_geometry(size)
    s = g["size"]
    x0, y0, x1, y1 = g["box"]

    paths = "\n".join(
        '  <path d="%s" fill="none" stroke="%s" stroke-width="%.1f"\n'
        '        stroke-linecap="round" stroke-linejoin="round"/>'
        % (polyline_path(pts), colours[role], width)
        for role, width, pts in g["shapes"])

    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {s:.0f} {s:.0f}"
     width="{size}" height="{size}" role="img"
     aria-label="PuralvOS">
  <title>PuralvOS</title>
  <desc>Pur and Alv: a P and an A drawn as waveforms. Three accents, one per
  discipline: the P is audio, the A is video, the crossbar is graphics.</desc>
  <rect width="{s:.0f}" height="{s:.0f}" rx="{g['corner']:.0f}" fill="{bg}"/>
  <rect x="{x0:.0f}" y="{y0:.0f}" width="{x1 - x0:.0f}" height="{y1 - y0:.0f}"
        rx="{g['box_radius']:.0f}" fill="none" stroke="{edge}"
        stroke-width="{g['edge_width']:.0f}"/>

{paths}
</svg>
"""


def build_wordmark(tokens, width=1200):
    t = tokens
    h = int(width * 0.22)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {h}"
     width="{width}" height="{h}" role="img" aria-label="PuralvOS">
  <title>PuralvOS</title>
  <text x="0" y="{h * 0.72:.0f}" font-family="Inter, 'DejaVu Sans', sans-serif"
        font-size="{h * 0.66:.0f}" font-weight="600" letter-spacing="{h * 0.02:.0f}"
        fill="{t['text']['primary']}">Pural<tspan fill="{t['accent']['graphics']}">v</tspan>OS</text>
  <text x="{width * 0.415:.0f}" y="{h * 0.72:.0f}" font-family="Inter, 'DejaVu Sans', sans-serif"
        font-size="{h * 0.26:.0f}" letter-spacing="{h * 0.06:.0f}"
        fill="{t['text']['muted']}">{t['tagline'].upper()}</text>
</svg>
"""


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


def render_preview(tokens, png_path, size=900):
    """Rasterise the mark with PIL so it can actually be looked at.

    The SVG is the deliverable, but SVG cannot be viewed without a rasteriser
    and this machine has none: no rsvg-convert, no inkscape, no ImageMagick,
    no chromium. Rather than ship a logo nobody has seen, draw the same
    geometry straight into a bitmap. It reads mark_geometry(), not a private
    copy, so what gets reviewed is what gets built.
    """
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return None

    g = mark_geometry(size)
    s = g["size"]
    colours = {
        "audio": tokens["accent"]["audio"],
        "video": tokens["accent"]["video"],
        "graphics": tokens["accent"]["graphics"],
    }

    im = Image.new("RGB", (int(s), int(s)), tokens["background"]["base"])
    d = ImageDraw.Draw(im)
    d.rounded_rectangle(list(g["box"]), radius=int(g["box_radius"]),
                        outline=tokens["background"]["edge"],
                        width=max(1, int(g["edge_width"])))

    for role, width, pts in g["shapes"]:
        d.line(pts, fill=colours[role], width=max(2, int(width)), joint="curve")

    im.save(png_path)
    return png_path


def hex_rgb(value):
    """'#0B0E14' -> (11, 14, 20).

    The tokens are hex because that is what belongs in tokens.json and in CSS
    and in SVG. PIL wants a tuple. Converting here keeps the palette authored
    once and readable, instead of duplicated as magic numbers in the drawing
    code, which is how two places end up disagreeing about what green is.
    """
    v = value.lstrip("#")
    return tuple(int(v[i:i + 2], 16) for i in (0, 2, 4))


def _glow(layer, cx, cy, radius, colour, strength):
    """Composite one soft coloured light onto a layer, for the wallpaper."""
    from PIL import Image, ImageDraw, ImageFilter

    w, h = layer.size
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius * 0.55))
    mask = mask.point(lambda v: int(v * strength))

    wash = Image.new("RGB", (w, h), colour)
    layer.paste(wash, (0, 0), mask)


# The wallpaper palette. Deliberately wider than the three accents: three
# colours repeated down a frame reads as a gradient with stripes. Every entry
# is chosen to stay bright ON black rather than to be tinted by it, which is
# the whole point of the additive glow below.
VIVID = [
    "#22D3EE",  # cyan
    "#34D399",  # green
    "#FBBF24",  # amber
    "#A78BFA",  # violet
    "#F472B6",  # pink
    "#A3E635",  # lime
    "#38BDF8",  # sky
    "#FB7185",  # rose
]


def build_wallpaper(tokens, width=3840, height=2160, variant="deep"):
    """A field of vivid sinusoids on black.

    Every line is a sum of sines, because a sine is what audio looks like and
    this is a machine for audio. Lines are drawn thin and bright, then a blurred
    copy of the same lines is added back on top: that additive pass is what
    makes them glow rather than merely be coloured. Additive over black can
    only brighten, which is why nothing goes muddy the way the earlier low
    opacity washes did.

    Two things keep it a wallpaper rather than a poster. The field is denser
    and brighter low in the frame and thins out towards the top, where the icon
    grid lives. And there is no logo: a wordmark across a desktop is an
    advertisement.
    """
    from PIL import Image, ImageDraw, ImageChops, ImageFilter

    # Draw at SS times the target size and downsample, which is what makes the
    # lines smooth rather than stepped. PIL has no anti-aliased line drawing, so
    # a 1px diagonal line at native resolution is a staircase and a field of
    # them reads as noise. Two times is enough; three is not worth the memory at
    # 4K, where the intermediate canvas is already 100 MB a layer.
    SS = 2
    width, height = width * SS, height * SS
    w, h = width, height

    # True black rather than the deep blue of tokens.json. The brief is a black
    # background, and on black the vivid lines are at their most vivid.
    im = Image.new("RGB", (w, h), (0, 0, 0))
    lines = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(lines)

    band = max(1, w // (1800 * SS))
    # More lines on a bigger screen, but sub-linearly: doubling the resolution
    # should not quadruple the work.
    count = int(46 + 42 * (height / (2160.0 * SS)) ** 0.5)

    for n in range(count):
        u = n / float(max(1, count - 1))

        # Biased low: y in [0.28, 0.97]. Empty at the top for the icons, dense
        # signal underneath them.
        y = h * (0.28 + 0.69 * (u ** 1.35))
        # Amplitude grows towards the bottom too, so the frame has a shape
        # instead of being an even hatch.
        amp = h * 0.005 + h * 0.038 * (u ** 1.6)

        # Per line frequency and phase, so no two repeat, with a slow drift so
        # the wave appears to travel sideways. The golden angle keeps
        # neighbouring lines from ever lining up into visible stripes.
        f1 = 1.2 + 5.5 * ((n * 7919) % 100) / 100.0
        f2 = f1 * (2.1 + 0.9 * ((n * 6271) % 100) / 100.0)
        f3 = f1 * 0.37
        ph = n * 2.399963

        colour = hex_rgb(VIVID[(n * 5) % len(VIVID)])
        # Brightness falls off towards the top, matching the density gradient.
        lum = 0.78 + 0.22 * (u ** 0.8)
        colour = tuple(min(255, int(c * lum)) for c in colour)

        pts = []
        step = max(1, w // (1100 * SS))
        for i in range(0, w + step, step):
            x = i / float(w)
            wave = (math.sin(x * math.pi * 2 * f1 + ph) * 0.62
                    + math.sin(x * math.pi * 2 * f2 + ph * 1.7) * 0.26
                    + math.sin(x * math.pi * 2 * f3 + ph * 0.4) * 0.12)
            # Fade at the left and right margins so lines do not stop dead
            # against the frame edge.
            env = min(1.0, (min(x, 1.0 - x) / 0.08) ** 0.6)
            pts.append((i, y + wave * amp * env))
        d.line(pts, fill=colour, width=band, joint="curve")

    # The glow: a blurred copy of the lines added back additively. On black
    # this is a pure brightening, so vivid stays vivid.
    glow = lines.filter(ImageFilter.GaussianBlur(radius=max(3, h // 130)))
    im = ImageChops.add(im, glow.point(lambda v: min(255, int(v * 1.15))))
    im = ImageChops.add(im, lines)

    # A tighter second halo, so the cores look hot rather than flat.
    hot = lines.filter(ImageFilter.GaussianBlur(radius=max(2, h // 430)))
    im = ImageChops.add(im, hot.point(lambda v: min(255, int(v * 0.75))))

    # Fade the top, so an icon has somewhere quiet to sit even where a line
    # happens to run.
    fade = Image.new("L", (w, h), 255)
    fd = ImageDraw.Draw(fade)
    for yy in range(0, int(h * 0.30)):
        fd.line([(0, yy), (w, yy)], fill=255 - int(150 * (yy / (h * 0.30)) ** 1.6))
    im = ImageChops.multiply(im, fade.convert("RGB"))

    # Down to the real size. The resampling also softens the glow, which is
    # why the glow is applied after the lines are drawn but before this: the
    # order matters and the tuning above assumed it.
    return im.resize((width // SS, height // SS), Image.LANCZOS)


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
        print("\npreview: %s  (delete it, or keep it for review)" % preview)
    else:
        print("\npreview skipped: PIL not available")

    try:
        import PIL  # noqa: F401
        for name, px in TARGETS.items():
            path = os.path.join(outdir, "wallpaper-%s.png" % name)
            build_wallpaper(tokens, px[0], px[1], "deep").save(path, optimize=True)
            written.append(os.path.relpath(path, outdir))
            print("  %s  %dx%d  %.1f MB" % (
                os.path.relpath(path, outdir), px[0], px[1],
                os.path.getsize(path) / 1048576.0))
    except ImportError:
        print("wallpapers skipped: PIL not available")
    return 0


if __name__ == "__main__":
    sys.exit(main())
