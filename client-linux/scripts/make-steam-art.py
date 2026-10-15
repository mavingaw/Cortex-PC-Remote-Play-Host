#!/usr/bin/env python3
"""Generate Steam library artwork for the non-Steam shortcut from the app icon.

Writes to client-linux/steam-art/:
  grid-portrait.png   600x900   library grid tile (Game Mode / Big Picture)
  grid-landscape.png  920x430   "recent games" / header tile
  hero.png            1920x620  banner behind the title on the game page
  logo.png            transparent logo shown over the hero

Run from client-linux/:  python3 scripts/make-steam-art.py
"""
import pathlib
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = pathlib.Path(__file__).resolve().parent.parent
ICON = Image.open(HERE / "razer-pc-remote-play.png").convert("RGBA")
OUT = HERE / "steam-art"
OUT.mkdir(exist_ok=True)

BG = (11, 11, 11)
GREEN = (68, 214, 44)
WHITE = (240, 240, 240)
GREY = (160, 160, 160)

def font(size, bold=True):
    for name in (["DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf"] if bold else ["DejaVuSans.ttf", "LiberationSans-Regular.ttf"]):
        for base in ("/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/truetype/liberation", "/usr/share/fonts/TTF", "/usr/share/fonts"):
            p = pathlib.Path(base) / name
            if p.exists():
                return ImageFont.truetype(str(p), size)
    return ImageFont.load_default()

def background(w, h, glow_center, glow_radius):
    im = Image.new("RGBA", (w, h), BG + (255,))
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(glow)
    cx, cy = glow_center
    d.ellipse([cx - glow_radius, cy - glow_radius, cx + glow_radius, cy + glow_radius], fill=GREEN + (70,))
    glow = glow.filter(ImageFilter.GaussianBlur(glow_radius / 2))
    im.alpha_composite(glow)
    # faint diagonal lines for texture
    tex = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    td = ImageDraw.Draw(tex)
    for x in range(-h, w, 48):
        td.line([(x, h), (x + h, 0)], fill=(255, 255, 255, 6), width=1)
    im.alpha_composite(tex)
    return im

def paste_icon(im, size, center):
    icon = ICON.resize((size, size), Image.LANCZOS)
    im.alpha_composite(icon, (center[0] - size // 2, center[1] - size // 2))

def text_block(im, lines, center_x, top, sizes, colors, spacing=8):
    d = ImageDraw.Draw(im)
    y = top
    for line, size, color in zip(lines, sizes, colors):
        f = font(size)
        bbox = d.textbbox((0, 0), line, font=f)
        tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
        d.text((center_x - tw // 2 - bbox[0], y - bbox[1]), line, font=f, fill=color)
        y += th + spacing
    return y

# ---- portrait 600x900
im = background(600, 900, (300, 380), 260)
paste_icon(im, 300, (300, 380))
text_block(im, ["RAZER", "PC REMOTE PLAY"], 300, 610, [64, 44], [GREEN, WHITE])
text_block(im, ["Stream your PC"], 300, 760, [26], [GREY])
im.convert("RGB").save(OUT / "grid-portrait.png", optimize=True)

# ---- landscape 920x430
im = background(920, 430, (230, 215), 200)
paste_icon(im, 260, (230, 215))
text_block(im, ["RAZER", "PC REMOTE PLAY"], 620, 140, [64, 40], [GREEN, WHITE])
im.convert("RGB").save(OUT / "grid-landscape.png", optimize=True)

# ---- hero 1920x620 (logo is drawn separately by Steam, keep this mostly texture)
im = background(1920, 620, (1500, 310), 360)
paste_icon(im, 420, (1500, 310))
im.convert("RGB").save(OUT / "hero.png", optimize=True)

# ---- logo (transparent) 1000x320
im = Image.new("RGBA", (1000, 320), (0, 0, 0, 0))
paste_icon(im, 280, (160, 160))
text_block(im, ["RAZER", "PC REMOTE PLAY"], 650, 70, [96, 60], [GREEN, WHITE], spacing=14)
im.save(OUT / "logo.png", optimize=True)

for p in sorted(OUT.glob("*.png")):
    print(p.name, Image.open(p).size, p.stat().st_size // 1024, "KiB")
