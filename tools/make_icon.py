"""Generate a 512x512 DXT1 .dds mod icon.

DXT1 stores each 4x4 block as two RGB565 endpoints plus 4 bytes of 2-bit indices. Setting every
index to 0 makes the whole block the first endpoint's colour, so a 128x128 grid of flat blocks is
enough for a simple flat-shaded icon and needs no real compressor.
"""
import struct, sys

SIZE = 512
BLOCKS = SIZE // 4  # 128


def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def colour_at(bx, by):
    """Dark slate ground, an amber ring, and a red crosshair through the centre."""
    cx = cy = BLOCKS / 2.0
    dx, dy = bx + 0.5 - cx, by + 0.5 - cy
    dist = (dx * dx + dy * dy) ** 0.5

    # crosshair arms
    if abs(dx) < 2 and dist < 46:
        return (214, 68, 52)
    if abs(dy) < 2 and dist < 46:
        return (214, 68, 52)
    # ring
    if 30 <= dist <= 36:
        return (226, 162, 62)
    # inner disc
    if dist < 30:
        return (38, 46, 56)
    return (26, 31, 38)


header = bytearray(128)
header[0:4] = b"DDS "
struct.pack_into("<I", header, 4, 124)                 # dwSize
struct.pack_into("<I", header, 8, 0x00081007)          # CAPS|HEIGHT|WIDTH|PIXELFORMAT|LINEARSIZE (matches the known-good AutoDrive icon)
struct.pack_into("<I", header, 12, SIZE)               # height
struct.pack_into("<I", header, 16, SIZE)               # width
struct.pack_into("<I", header, 20, SIZE * SIZE // 2)   # linear size (DXT1 = 0.5 byte/px)
struct.pack_into("<I", header, 28, 1)                  # mipMapCount
struct.pack_into("<I", header, 76, 32)                 # pixelformat dwSize
struct.pack_into("<I", header, 80, 0x4)                # DDPF_FOURCC
header[84:88] = b"DXT1"
struct.pack_into("<I", header, 108, 0x1000)            # DDSCAPS_TEXTURE

body = bytearray()
for by in range(BLOCKS):
    for bx in range(BLOCKS):
        c = rgb565(*colour_at(bx, by))
        # colour0 must be > colour1 for the opaque 4-colour DXT1 mode
        body += struct.pack("<HHI", c, 0, 0)

out = sys.argv[1]
with open(out, "wb") as f:
    f.write(header)
    f.write(body)
print("wrote %s (%d bytes, expected %d)" % (out, 128 + len(body), 128 + SIZE * SIZE // 2))
