"""Generate the flyover camera's map marker: a small top-down airplane, nose up.

Nose up (towards -y in the image) is the zero rotation. The marker is rotated at runtime to the
camera's aim, so this has to point exactly one way and have a nose that reads at a glance when it is
16 pixels tall on the HUD map.

Written as an uncompressed 32-bit BGRA DDS rather than the flat DXT1 the mod icon uses. A map marker
sits over terrain of every colour, so it needs real alpha and anti-aliased edges; DXT1 offers only
one-bit alpha and would give it a jagged cut-out edge. At 64x64 the uncompressed file is 16 KB.

No PIL on this machine, so the shape is defined analytically and supersampled for anti-aliasing,
and a PNG preview is written with zlib alone.
"""
import math
import os
import struct
import zlib

SIZE = 64
SAMPLES = 4          # 4x4 supersampling per pixel
OUTLINE = 0.085      # outline thickness, in the same -1..1 units as the shape
HALO_WIDTH = 0.07    # white halo beyond the outline

# Blue, not amber. The map is fields and forest - greens and browns - and amber sits on the same
# red/green axis those collapse onto for the commonest colour blindness (deuteranopia and
# protanopia), so an amber marker on a green map is close to invisible for about one man in twelve.
# Blue lies on the axis those conditions keep, so it stands off the terrain for them and for
# everyone else. A white halo outside the dark outline lifts it off dark forest as well as bright
# stubble.
FILL = (30, 144, 255)     # a strong sky blue
EDGE = (10, 12, 20)       # near-black outline
HALO = (255, 255, 255)    # white halo outside the outline


def inside(x, y):
    """The airplane in -1..1 coordinates, nose at y = -1, tail at y = +1."""
    ax = abs(x)

    # Fuselage, with the nose rounded rather than square so the heading is unambiguous.
    if -0.92 <= y <= 0.82:
        half = 0.12
        if y < -0.70:
            half = 0.12 * math.sqrt(max(0.0, (y + 0.92) / 0.22))
        if ax <= half:
            return True

    # Main wings: swept back, so the silhouette points forward even without the nose.
    if ax <= 0.94:
        leading = -0.18 + 0.30 * ax
        trailing = 0.10 + 0.14 * ax
        if leading <= y <= trailing:
            return True

    # Tailplane.
    if ax <= 0.40:
        leading = 0.56 + 0.20 * ax
        trailing = 0.80 + 0.04 * ax
        if leading <= y <= trailing:
            return True

    return False


def grown(x, y, r):
    """Inside the shape grown by r - each band is one growth minus the one inside it."""
    if inside(x, y):
        return True
    for k in range(16):
        a = k * math.pi / 8
        if inside(x + r * math.cos(a), y + r * math.sin(a)):
            return True
    return False


def near(x, y):
    return grown(x, y, OUTLINE)


def render():
    pixels = []
    for py in range(SIZE):
        row = []
        for px in range(SIZE):
            fill = edge = halo = 0
            for sy in range(SAMPLES):
                for sx in range(SAMPLES):
                    # Map the pixel into -1..1 with a margin so the halo is not clipped.
                    x = ((px + (sx + 0.5) / SAMPLES) / SIZE) * 2.5 - 1.25
                    y = ((py + (sy + 0.5) / SAMPLES) / SIZE) * 2.5 - 1.25
                    if inside(x, y):
                        fill += 1
                    elif near(x, y):
                        edge += 1
                    elif grown(x, y, OUTLINE + HALO_WIDTH):
                        halo += 1
            n = SAMPLES * SAMPLES
            covered = fill + edge + halo
            if covered == 0:
                row.append((0, 0, 0, 0))
                continue
            # Colour is the mix of bands among the covered samples; alpha is total coverage.
            r = round((FILL[0] * fill + EDGE[0] * edge + HALO[0] * halo) / covered)
            g = round((FILL[1] * fill + EDGE[1] * edge + HALO[1] * halo) / covered)
            b = round((FILL[2] * fill + EDGE[2] * edge + HALO[2] * halo) / covered)
            row.append((r, g, b, round(255 * covered / n)))
        pixels.append(row)
    return pixels


def write_dds(path, pixels):
    header = bytearray(128)
    header[0:4] = b"DDS "
    struct.pack_into("<I", header, 4, 124)                 # dwSize
    struct.pack_into("<I", header, 8, 0x0000100F)          # CAPS|HEIGHT|WIDTH|PITCH|PIXELFORMAT
    struct.pack_into("<I", header, 12, SIZE)               # height
    struct.pack_into("<I", header, 16, SIZE)               # width
    struct.pack_into("<I", header, 20, SIZE * 4)           # pitch
    struct.pack_into("<I", header, 28, 1)                  # mip count
    struct.pack_into("<I", header, 76, 32)                 # ddpf size
    struct.pack_into("<I", header, 80, 0x41)               # DDPF_RGB | DDPF_ALPHAPIXELS
    struct.pack_into("<I", header, 88, 32)                 # bits per pixel
    struct.pack_into("<I", header, 92, 0x00FF0000)         # R mask
    struct.pack_into("<I", header, 96, 0x0000FF00)         # G mask
    struct.pack_into("<I", header, 100, 0x000000FF)        # B mask
    struct.pack_into("<I", header, 104, 0xFF000000)        # A mask
    struct.pack_into("<I", header, 108, 0x1000)            # DDSCAPS_TEXTURE
    body = bytearray()
    for row in pixels:
        for r, g, b, a in row:
            body += bytes((b, g, r, a))                    # BGRA in memory
    with open(path, "wb") as fh:
        fh.write(header + body)


def write_png(path, pixels, scale=6):
    """A preview, scaled up and composited over grey so the edges can actually be judged."""
    w = h = SIZE * scale
    raw = bytearray()
    for py in range(h):
        raw.append(0)
        for px in range(w):
            r, g, b, a = pixels[py // scale][px // scale]
            checker = 96 if ((px // 24) + (py // 24)) % 2 else 128
            t = a / 255.0
            raw += bytes((round(r * t + checker * (1 - t)),
                          round(g * t + checker * (1 - t)),
                          round(b * t + checker * (1 - t))))

    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    px = render()
    write_dds(os.path.join(root, "airplane.dds"), px)
    write_png(os.path.join(root, "tools", "airplane_preview.png"), px)
    print("wrote airplane.dds (%d bytes) and tools/airplane_preview.png"
          % os.path.getsize(os.path.join(root, "airplane.dds")))
