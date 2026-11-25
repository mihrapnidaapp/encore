"""Encore app icon: a pink-to-orange play triangle with a white sound wave running through it,
on a deep indigo-violet background. Drawn at 4x and scaled down for smooth edges."""
import math, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 4096
OUT = sys.argv[1]
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) / S

def rgb(arr):
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")

def mix(c1, c2, t):
    t = t[..., None]
    return np.array(c1, np.float32) * (1 - t) + np.array(c2, np.float32) * t

# Background: smooth diagonal gradient plus a warm glow in the middle.
t = np.clip((xx + yy) / 2, 0, 1)
bg = mix((20, 16, 60), (62, 14, 78), t)
d = np.sqrt((xx - 0.52) ** 2 + (yy - 0.5) ** 2)
glow = np.clip(1 - d / 0.42, 0, 1) ** 2 * 0.40
bg = mix((0, 0, 0), (255, 55, 120), glow) + bg * (1 - glow[..., None])

def mask_from(draw_fn, blur=0):
    m = Image.new("L", (S, S), 0)
    draw_fn(ImageDraw.Draw(m))
    if blur:
        m = m.filter(ImageFilter.GaussianBlur(blur))
    return np.asarray(m, np.float32) / 255

# Rounded play triangle.
cx, cy = S * 0.535, S * 0.5
h = S * 0.54
w = h * math.sqrt(3) / 2
tri = [(cx - w / 2, cy - h / 2), (cx - w / 2, cy + h / 2), (cx + w / 2, cy)]
soft = mask_from(lambda dr: dr.polygon(tri, fill=255), blur=S * 0.03)
tmask = np.clip((soft - 0.5) * 40 + 0.5, 0, 1)   # rounded corners, crisp edge

# Shadow.
shadow = mask_from(lambda dr: dr.polygon([(x, y + S * 0.025) for x, y in tri], fill=255), blur=S * 0.035) * 0.55
bg = bg * (1 - shadow[..., None]) + np.array((8, 4, 20), np.float32) * shadow[..., None]

# Triangle fill: hot pink top-left to orange bottom-right.
tt = np.clip((xx - 0.25) * 0.6 + (yy - 0.23) * 1.2, 0, 1)
fill = mix((255, 45, 115), (255, 150, 55), tt)
bg = bg * (1 - tmask[..., None]) + fill * tmask[..., None]

# Sound wave stamped as overlapping discs for a perfectly smooth thick stroke.
r = S * 0.014
wimg = Image.new("L", (S, S), 0)
wd = ImageDraw.Draw(wimg)
x0, x1 = S * 0.09, S * 0.91
n = 6000
for i in range(n + 1):
    u = i / n
    x = x0 + (x1 - x0) * u
    env = math.sin(math.pi * u) ** 1.5
    y = cy + math.sin(u * math.pi * 7) * S * 0.09 * env
    wd.ellipse([x - r, y - r, x + r, y + r], fill=255)
wave = np.asarray(wimg.filter(ImageFilter.GaussianBlur(S * 0.0012)), np.float32) / 255
alpha = wave * (0.7 + 0.3 * tmask)        # a little see-through outside the triangle
bg = bg * (1 - alpha[..., None]) + 255 * alpha[..., None]

rgb(bg).resize((1024, 1024), Image.LANCZOS).save(OUT)
print("saved", OUT)
