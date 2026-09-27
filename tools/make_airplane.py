"""Generate the flyover camera's map marker: a small top-down airplane, nose up.

Nose up (towards -y in the image) is the zero rotation. The marker is rotated at runtime to the
camera's aim, so this has to point exactly one way and have a nose that reads at a glance when it is
16 pixels tall on the HUD map.

Written as BC3 (DXT5) with a full mip chain, not the flat DXT1 the mod icon uses. A map marker sits
over terrain of every colour, so it needs real alpha and anti-aliased edges; DXT1 offers only one-bit
alpha and would give it a jagged cut-out edge, while BC3's interpolated alpha keeps the soft edge. It
used to be uncompressed BGRA, which FS25 flags as "raw format" (a performance warning).

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


def _downsample(px):
    """Halve an RGBA image, averaging colour weighted by alpha so the edge does not darken."""
    n = len(px) // 2
    out = []
    for y in range(n):
        row = []
        for x in range(n):
            quad = [px[2 * y + dy][2 * x + dx] for dy in (0, 1) for dx in (0, 1)]
            at = sum(q[3] for q in quad)
            if at == 0:
                row.append((0, 0, 0, 0))
                continue
            row.append((round(sum(q[0] * q[3] for q in quad) / at), round(sum(q[1] * q[3] for q in quad) / at),
                        round(sum(q[2] * q[3] for q in quad) / at), round(at / 4)))
        out.append(row)
    return out


def _to565(c):
    return ((c[0] * 31 + 127) // 255) << 11 | ((c[1] * 63 + 127) // 255) << 5 | ((c[2] * 31 + 127) // 255)


def _from565(v):
    return (((v >> 11) & 31) * 255 // 31, ((v >> 5) & 63) * 255 // 63, (v & 31) * 255 // 31)


def _bc3_block(block):
    """One 4x4 block as BC3 (DXT5): 8 bytes of interpolated alpha, then an 8-byte colour block."""
    alphas = [p[3] for p in block]
    a0, a1 = max(alphas), min(alphas)
    if a0 == a1:
        a_idx = [0] * 16
    else:
        pal = [a0, a1] + [((7 - i) * a0 + i * a1) // 7 for i in range(1, 7)]
        a_idx = [min(range(8), key=lambda k: abs(pal[k] - a)) for a in alphas]
    bits = 0
    for i, v in enumerate(a_idx):
        bits |= v << (3 * i)
    alpha_bytes = bytes((a0, a1)) + bits.to_bytes(6, "little")

    # Colour endpoints from the pixels that are actually visible (fully clear ones are don't-care).
    vis = [p for p in block if p[3] > 0] or block
    lo = tuple(min(p[i] for p in vis) for i in range(3))
    hi = tuple(max(p[i] for p in vis) for i in range(3))
    c0, c1 = _to565(hi), _to565(lo)
    if c0 < c1:
        c0, c1 = c1, c0
    if c0 == c1:
        c_idx = [0] * 16
    else:
        e0, e1 = _from565(c0), _from565(c1)
        pal = [e0, e1,
               tuple((2 * e0[i] + e1[i]) // 3 for i in range(3)),
               tuple((e0[i] + 2 * e1[i]) // 3 for i in range(3))]
        c_idx = [min(range(4), key=lambda k: sum((pal[k][i] - p[i]) ** 2 for i in range(3))) for p in block]
    cbits = 0
    for i, v in enumerate(c_idx):
        cbits |= v << (2 * i)
    return alpha_bytes + struct.pack("<HHI", c0, c1, cbits)


def _bc3_image(px):
    n = len(px)
    out = bytearray()
    for by in range(0, max(n, 4), 4):
        for bx in range(0, max(n, 4), 4):
            block = [px[min(by + y, n - 1)][min(bx + x, n - 1)] for y in range(4) for x in range(4)]
            out += _bc3_block(block)
    return out


def write_dds(path, pixels):
    """BC3 (DXT5) with a full mip chain. FS25 warns about raw (uncompressed) textures as a performance
    problem; BC3 keeps the smooth, interpolated alpha the anti-aliased edge needs, which DXT1 does not."""
    levels = [pixels]
    while len(levels[-1]) > 1:
        levels.append(_downsample(levels[-1]))
    header = bytearray(128)
    header[0:4] = b"DDS "
    struct.pack_into("<I", header, 4, 124)                            # dwSize
    struct.pack_into("<I", header, 8, 0x1 | 0x2 | 0x4 | 0x1000 | 0x20000 | 0x80000)  # CAPS|HEIGHT|WIDTH|PF|MIPCOUNT|LINEARSIZE
    struct.pack_into("<I", header, 12, SIZE)                          # height
    struct.pack_into("<I", header, 16, SIZE)                          # width
    struct.pack_into("<I", header, 20, max(1, SIZE // 4) ** 2 * 16)   # linear size of the top level
    struct.pack_into("<I", header, 28, len(levels))                   # mip count
    struct.pack_into("<I", header, 76, 32)                            # ddpf size
    struct.pack_into("<I", header, 80, 0x4)                           # DDPF_FOURCC
    header[84:88] = b"DXT5"
    struct.pack_into("<I", header, 108, 0x1000 | 0x400000 | 0x8)      # TEXTURE|MIPMAP|COMPLEX
    body = bytearray()
    for level in levels:
        body += _bc3_image(level)
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
