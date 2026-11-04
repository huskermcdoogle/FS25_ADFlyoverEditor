"""Draw the outline a field loop was built on, north up.

Every field loop writes modSettings/FS25_ADFlyoverEditor/fieldloop_outline.xml (overwritten each time):
raw = the outline as its source gave it, used = after leaving out islands, loop = the ring placed,
map = the game's own field outline when the loop used another one.

    python tools/fieldloop/plot_outline.py [fieldloop_outline.xml] [out.png]

With no file named it reads the one in the game's modSettings folder.
"""
import os, sys
import xml.etree.ElementTree as ET
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

DEFAULT = os.path.join(os.environ.get("USERPROFILE", ""), "OneDrive", "Documents", "My Games",
                       "FarmingSimulator2025", "modSettings", "FS25_ADFlyoverEditor", "fieldloop_outline.xml")
STYLE = {"map": ("#999999", 1.0, "game's field"), "raw": ("#2a9d3a", 1.2, "outline as given"),
         "used": ("#1f5fd6", 1.2, "after leaving out islands"), "loop": ("#d62828", 1.0, "loop placed")}


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(src)[0] + ".png"
    root = ET.parse(src).getroot()
    fig, ax = plt.subplots(figsize=(10, 10))
    for name in ("map", "raw", "used", "loop"):
        el = root.find(name)
        if el is None:
            continue
        pts = [(float(p.get("x")), float(p.get("z"))) for p in el.findall("p")]
        if not pts:
            continue
        pts.append(pts[0])
        colour, width, label = STYLE[name]
        # z grows toward the south: draw -z so north is up
        ax.plot([p[0] for p in pts], [-p[1] for p in pts], color=colour, lw=width,
                label="%s (%d points)" % (label, len(pts) - 1))
    ax.plot([float(root.get("x"))], [-float(root.get("z"))], "k+", ms=12, label="click")
    ax.set_aspect("equal")
    ax.legend(loc="best", fontsize=8)
    ax.set_title("%s, %s on %s - %s island(s), %s sliver(s) left out" % (
        root.get("label"), root.get("kind"), root.get("map"), root.get("islandsLeftOut"), root.get("sliversLeftOut")))
    fig.savefig(out, dpi=90, bbox_inches="tight")
    print("wrote", out)


if __name__ == "__main__":
    main()
