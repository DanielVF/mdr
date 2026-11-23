"""Regenerate the embedded Lusitana Regular bitmap strike with Pillow and fontTools."""
import struct
from pathlib import Path

from fontTools.ttLib import TTFont
from PIL import ImageFont

directory = Path(__file__).resolve().parents[1] / "src" / "fonts"
path = directory / "Lusitana-Regular.ttf"
face = ImageFont.truetype(path, 56)
cmap = TTFont(path).getBestCmap()
metrics = bytearray()
pixels = bytearray()
# Keep these ranges in sync with glyphIndex in heading.zig.
for start, stop in [(32, 127), (160, 384), (0x370, 0x530), (0x2000, 0x2040)]:
    for cp in range(start, stop):
        if cp not in cmap or 0x200b <= cp <= 0x200f or 0x2028 <= cp <= 0x202e:
            metrics.extend(bytes(10))
            continue
        mask, (x, y) = face.getmask2(chr(cp), mode="L", anchor="ls")
        w, h = mask.size
        advance = round(face.getlength(chr(cp)) * 64)
        if cp not in cmap or y < -62 or y + h > 22:
            advance = w = h = 0
        metrics.extend(struct.pack("<IHbbBB", len(pixels), advance, x, y, w, h))
        if w and h:
            pixels.extend(bytes(mask))
kerning = bytearray()
for a in range(32, 127):
    for b in range(32, 127):
        # Disable ligatures: the runtime paints the two glyphs separately.
        pair = face.getlength(chr(a) + chr(b), features=["-liga"])
        delta = pair - face.getlength(chr(a)) - face.getlength(chr(b))
        kerning.extend(struct.pack("<h", round(delta * 64)))
(directory / "metrics.bin").write_bytes(metrics)
(directory / "kerning.bin").write_bytes(kerning)
(directory / "coverage.bin").write_bytes(pixels)
