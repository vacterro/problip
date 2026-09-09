#!/usr/bin/env python3
"""Generate problip.ico from a source image, aliased (pixel) style.

The avatar is downscaled to each icon frame with PIL's NEAREST resampler, so no
antialiasing is introduced at any size - a strictly pixelated look, matching
the "no blur" UI rule. Frames are stored as PNG-compressed icons (Vista+
format, the same kind the original problip.ico used); System.Drawing.Icon
reads them fine and Windows itself picks the closest native frame, so nothing
is resampled at render time.

Run:
  python scripts/make_pixel_ico.py [path-to-source.png]
  (default source: V:\\___VAC\\_PIC\\_AVATARS\\_vacuum34\\SAIPEN_OrangeShine.png)
Out: problip.ico  (16/20/24/32/48/64/128/256 frames)
"""
import io
import os
import struct
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit('Pillow required: python -m pip install pillow')

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
OUT = os.path.join(ROOT, 'problip.ico')

DEFAULT_SRC = r'V:\___VAC\_PIC\_AVATARS\_vacuum34\SAIPEN_OrangeShine.png'
SIZES = (16, 20, 24, 32, 48, 64, 128, 256)


def png_frame(img):
    buf = io.BytesIO()
    img.convert('RGBA').save(buf, format='PNG')
    return buf.getvalue()


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    if not os.path.exists(src):
        sys.exit('source image not found: %s' % src)
    with Image.open(src) as im:
        im.load()
        frames = [png_frame(im.resize((s, s), Image.NEAREST)) for s in SIZES]

    out = bytearray(struct.pack('<HHH', 0, 1, len(SIZES)))
    offset = 6 + 16 * len(SIZES)
    for size, data in zip(SIZES, frames):
        dim = 0 if size >= 256 else size
        out += struct.pack('<BBBBHHII', dim, dim, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    for data in frames:
        out += data
    with open(OUT, 'wb') as fh:
        fh.write(out)
    print('wrote %s  %d bytes  frames: %s'
          % (os.path.relpath(OUT, ROOT), len(out), ', '.join(str(s) for s in SIZES)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
