"""Zip FS25_MPProbe/ into FS25_MPProbe.zip beside this script (git-ignored).

Copy the zip into the mods folder of EVERY peer (the game and the dedicated server) while the game is
closed - never while FS25 runs (see the deploy notes in the memory: a hot-swapped zip breaks source()).
"""
import os, zipfile
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "FS25_MPProbe")
dst = os.path.join(here, "FS25_MPProbe.zip")
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for name in sorted(os.listdir(src)):
        z.write(os.path.join(src, name), name)
print("built", dst)
