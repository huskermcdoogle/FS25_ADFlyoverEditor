# One-time converter: turns the map's and the savegame's terrain files into plain byte grids the Lua
# harness can load in a blink, so the editor's in-game reads (paint, drive cost, height, field) can
# answer offline with the real values. Run with TERRAIN=1 to use them (see README, "Real ground").
#
#   python make_terrain.py [savegame folder] [out folder]
#
# Defaults: savegame6 under the FS25 profile, out = terrain_data/ beside this file (git-ignored: it
# is your map, ~17 MB). Pure Python, no numpy; a couple of seconds.
#
# What it writes, all 1 m cells, x = -1024 at column 0, z = -1024 at row 0 (north is small z):
#   paint.bin   2048 x 2048 bytes: the main paint layer index per cell (terrain.lod.type.cache, the
#               even byte of each 2-byte cell, after a 12-byte header)
#   cost.bin    2048 x 2048 bytes: the AI drive-cost map (vehicleNavigationCostmap.dat: "VNCM",
#               version, length, then zlib; the inflated data has a 1032-byte header). 255 = blocked
#   height.bin  2049 x 2049 big-endian 16-bit (terrain.heightmap.png as stored); m = v / 65535 * 255
#   layers.lua  the 86 paint layers in index order: name, colour r g b, softness, materialId, cost
#   fields.lua  the field outlines (mapUS.i3d fields/fieldN/polygonPoints), world x, z
#   meta.lua    where each came from and its size, so a stale folder can be spotted
import os, re, struct, sys, zlib, time

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.environ.get("FS25_GAME", r"C:/Program Files (x86)/Steam/steamapps/common/Farming Simulator 25")
I3D = GAME + "/data/maps/mapUS/mapUS.i3d"
PROFILE = os.environ.get("FS25_PROFILE",
                         os.path.join(os.path.expanduser("~"), "OneDrive/Documents/My Games/FarmingSimulator2025"))
SG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(PROFILE, "savegame6")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "terrain_data")
N = 2048


def layers():
    # Only <Layer> lines carry the attributes; <OverlayLayer> (ground detail) has none and is not
    # in the index the type cache uses. Attribute order is declared just above them in the i3d:
    # color (3 floats), softness, materialId, aiDriveCost.
    out = []
    with open(I3D, encoding="latin-1") as f:
        inl = False
        for line in f:
            if "<Layers>" in line:
                inl = True
            if inl:
                m = re.search(r'<Layer name="([^"]+)".*attributes="([^"]+)"', line)
                if m:
                    a = m.group(2).split()
                    out.append((m.group(1), float(a[0]), float(a[1]), float(a[2]), float(a[3]), int(a[4]), float(a[5])))
                if "</Layers>" in line:
                    break
    return out


def fields():
    # Same walk as the edgewalk reader: field translation + polygonPoints translation + point
    # translation. No rotations worth counting on these nodes.
    def tr(line):
        m = re.search(r'translation="([^"]+)"', line)
        if not m:
            return (0.0, 0.0)
        a = [float(v) for v in m.group(1).split()]
        return (a[0], a[2])
    polys = []
    inf = False
    field = pp = cur = None
    with open(I3D, encoding="latin-1") as f:
        for line in f:
            if not inf:
                if '<TransformGroup name="fields"' in line:
                    inf = True
                continue
            s = line.strip()
            if re.match(r'<TransformGroup name="(field\d+)"', s):
                field = tr(s)
                pp = None
                continue
            if s.startswith('<TransformGroup name="polygonPoints"') and field is not None:
                t = tr(s)
                pp = (field[0] + t[0], field[1] + t[1])
                cur = []
                polys.append(cur)
                continue
            if re.match(r'<TransformGroup name="point\d+"', s) and pp is not None and cur is not None:
                t = tr(s)
                cur.append((pp[0] + t[0], pp[1] + t[1]))
                continue
            if s.startswith('<TransformGroup name="nameIndicator"') or s.startswith('<TransformGroup name="fieldMapIndicator"'):
                pp = cur = None
            if line.startswith("      </TransformGroup>"):
                break
    return [p for p in polys if len(p) >= 3]


def png16(path):
    # Minimal PNG reader for the one format the heightmap uses: 16-bit grey, no interlace.
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat = 8, []
    w = h = bd = ct = il = None
    while pos < len(data):
        ln, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, bd, ct, _, _, il = struct.unpack(">IIBBBBB", body[:13])
        elif typ == b"IDAT":
            idat.append(body)
        pos += 12 + ln
    assert bd == 16 and ct == 0 and il == 0, "expected a 16-bit grey, non-interlaced heightmap"
    raw = zlib.decompress(b"".join(idat))
    bpp, stride = 2, w * 2
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            line = bytearray((a + b) & 255 for a, b in zip(line, prev))
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, bytes(out)


def main():
    t0 = time.time()
    os.makedirs(OUT, exist_ok=True)
    meta = {}

    lay = layers()
    with open(os.path.join(OUT, "layers.lua"), "w") as f:
        f.write("-- generated by make_terrain.py from %s - do not edit\nreturn {\n" % I3D)
        for (name, r, g, b, soft, mat, cost) in lay:
            f.write('  { name = "%s", r = %r, g = %r, b = %r, softness = %r, materialId = %d, cost = %r },\n'
                    % (name, r, g, b, soft, mat, cost))
        f.write("}\n")
    print("layers", len(lay))

    tc = open(os.path.join(SG, "terrain.lod.type.cache"), "rb").read()
    assert len(tc) == 12 + N * N * 2, "type cache is not 2048 x 2048 x 2 bytes"
    paint = tc[12::2]
    assert len(paint) == N * N
    top = max(paint)
    assert top < len(lay), "paint index %d past the %d layers - wrong map?" % (top, len(lay))
    open(os.path.join(OUT, "paint.bin"), "wb").write(paint)
    print("paint", len(paint), "max index", top)

    vn = open(os.path.join(SG, "vehicleNavigationCostmap.dat"), "rb").read()
    assert vn[:4] == b"VNCM", "drive-cost map does not start with VNCM"
    inflated = zlib.decompress(vn[12:])
    assert len(inflated) == 1032 + N * N, "drive-cost map is not 2048 x 2048 after its header"
    open(os.path.join(OUT, "cost.bin"), "wb").write(inflated[1032:])
    print("cost", N * N)

    w, h, hb = png16(os.path.join(SG, "terrain.heightmap.png"))
    assert w == N + 1 and h == N + 1, "heightmap is not 2049 x 2049"
    open(os.path.join(OUT, "height.bin"), "wb").write(hb)
    print("height", w, h)

    polys = fields()
    with open(os.path.join(OUT, "fields.lua"), "w") as f:
        f.write("-- generated by make_terrain.py from %s - do not edit\nreturn {\n" % I3D)
        for P in polys:
            f.write("  {" + ", ".join("%r, %r" % (x, z) for x, z in P) + "},\n")
        f.write("}\n")
    print("fields", len(polys))

    with open(os.path.join(OUT, "meta.lua"), "w") as f:
        f.write("-- generated by make_terrain.py - do not edit\nreturn {\n")
        f.write("  savegame = %s,\n  map = %s,\n" % (lua_str(SG), lua_str(I3D)))
        f.write("  size = %d, heightSize = %d, heightScale = 255,\n" % (N, N + 1))
        f.write("  layers = %d, fields = %d,\n}\n" % (len(lay), len(polys)))
    print("done in %.1f s ->" % (time.time() - t0), OUT)


def lua_str(s):
    return '"' + s.replace("\\", "/").replace('"', '\\"') + '"'


if __name__ == "__main__":
    main()
