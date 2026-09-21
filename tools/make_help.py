"""Single source for the flyover editor's tool help.

The content lives here, once. Running this emits both:
  * scripts/editor/Help.lua  - structured, line-wrapped, for the in-game help/manual overlays
  * docs/manual.md           - the full written manual (full prose, not wrapped)

so the in-game help and the written manual can never drift apart. Re-run after editing TOOLS:

    python tools/make_help.py

Tool keys match ADFlyoverEditor.TOOL_NAMES exactly (note "field loop" has a space); "select" is the
TOOL.NONE / Select-mode entry. GENERAL holds the not-tool-specific reference (opening, keys, etc.).
"""
import textwrap, os

WRAP = 46  # characters per line for the in-game (Lua) output; the .md keeps full prose

# Each tool: key, name, group, summary (one line), what (prose), how (steps), controls (name/desc).
TOOLS = [
    {
        "key": "select", "name": "Select", "group": "Mode",
        "summary": "The default mode. Click things to edit them; no tool is held.",
        "what": "Select mode is where you inspect and act on what is already there rather than "
                "creating anything. Clicking the network opens a context menu for whatever you "
                "clicked, and the same click can escalate from a single point to a whole span to a "
                "whole run, so you rarely have to switch tools to make an edit.",
        "how": [
            "Click a waypoint to open its POINT menu (name, move, connect, convert, delete).",
            "Click again on the same point, or double-click, to grab the SPAN either side of it.",
            "A further click grabs the whole RUN between the two nearest junctions.",
            "Ctrl+drag a box, Alt+drag a circle, or Ctrl+Alt+drag freehand to multi-select points - "
            "works in every tool, not just Select, and a plain Ctrl-click toggles one point at a time.",
            "The clicked point/span/run is highlighted in the world while its menu is open.",
            "Right-click closes the menu without doing anything.",
        ],
        "controls": [
            ("Point menu", "name, move, connect from here, spline from here, one/two-way, "
                           "primary/secondary, delete."),
            ("Span / run menu", "straighten, smooth, divide, ground, parallel (run), "
                                "one/two-way, flip direction, delete."),
            ("Arm a tool", "choosing an action from a menu ARMS that tool on the selection; "
                           "dial its setting, then right-click to apply."),
        ],
    },
    {
        "key": "draw", "name": "Draw", "group": "Create",
        "summary": "Place waypoints and connect them into a route.",
        "what": "Draw lays down new waypoints one click at a time, joining each to the last so a "
                "route grows as you go. It is the basic way to build track that is not derived from "
                "an existing shape.",
        "how": [
            "Click empty ground to drop a waypoint; each new one connects to the previous.",
            "Click an existing waypoint to start drawing FROM it, wiring the new run into the network.",
            "Right-click ends the current run, so the next click starts a fresh one.",
        ],
        "controls": [
            ("direction", "whether new connections are one-way or two-way."),
            ("priority", "primary or secondary (secondary shows as a give-way road)."),
            ("snap to", "surface or terrain - what the new points sit on."),
        ],
    },
    {
        "key": "spline", "name": "Spline", "group": "Create",
        "summary": "Draw a smooth curved connection between two points.",
        "what": "Spline connects two waypoints with a curve rather than a straight segment, for "
                "sweeping bends a vehicle can follow at speed. A live preview shows the curve before "
                "you commit it.",
        "how": [
            "Click the start waypoint, then the end waypoint - the curve previews between them.",
            "Scroll the wheel to tighten or loosen the curvature while the preview is up.",
            "Click again / confirm to place it; right-click cancels.",
        ],
        "controls": [
            ("curvature (wheel)", "how tight the curve is, clamped to a sane range."),
            ("endpoints", "which end the curve is computed from (reshapes it)."),
            ("end / start tangent", "flip the direction the curve leaves each end."),
            ("direction / priority", "as for Draw - one/two-way and primary/secondary."),
        ],
    },
    {
        "key": "field loop", "name": "Field loop", "group": "Create",
        "summary": "Generate a drivable loop around the field under the cursor.",
        "what": "Field loop builds a complete two-way route that runs just outside a field's "
                "boundary, smoothed to a turning radius and nudged inward around any trees in the "
                "way. It is a standalone loop - no map markers, not wired to the rest of the network "
                "- so you connect it in afterwards with Draw or the editor.",
        "how": [
            "Point the cursor at the field you want the loop around.",
            "Select the field loop tool - it reads the field boundary and lays the loop.",
            "Wire the loop into your network afterwards if you need it connected.",
        ],
        "controls": [
            ("margin", "how far outside the boundary the loop runs."),
            ("tree clearance", "how far the loop keeps from trees before detouring."),
            ("turning radius", "the tightest turn the loop is allowed to make."),
            ("vehicle height", "how tall a machine the tree check clears for."),
        ],
    },
    {
        "key": "parallel", "name": "Parallel", "group": "Create",
        "summary": "Lay a track running parallel to a span or run.",
        "what": "Parallel offsets an existing span or run sideways by a set distance to make a "
                "second track alongside it - a passing lane or a return leg.",
        "how": [
            "Pick the span (two points) or run you want to run alongside.",
            "Set the distance and side, then apply - the new parallel track is created.",
        ],
        "controls": [
            ("distance", "how far to the side the new track sits."),
            ("side", "left or right of the original's direction of travel."),
            ("covers", "whether it works on the picked span or the whole run."),
        ],
    },
    {
        "key": "siding", "name": "Siding", "group": "Create",
        "summary": "A parallel spur that splines back in at both ends.",
        "what": "Siding drops a short parallel stretch beside a run and curves it back into the run "
                "at each end, like a pull-off or passing siding, in one action.",
        "how": [
            "Pick the anchor point on the run.",
            "Set the offset and length (scroll adjusts the length), then apply.",
        ],
        "controls": [
            ("offset", "how far to the side the siding sits."),
            ("length (wheel)", "how long the parallel stretch is."),
            ("side", "left or right."),
        ],
    },
    {
        "key": "move", "name": "Move", "group": "Shape",
        "summary": "Drag a waypoint, a run, or a span, optionally carrying neighbours with it.",
        "what": "Move drags one or more waypoints to a new spot and re-seats them on the real "
                "ground there. Picks decide WHAT moves - a single point, the whole run it belongs "
                "to, or a span you pick the two ends of - and falloff decides whether that tapers "
                "smoothly or moves as one rigid piece. Copy leaves the originals in place and "
                "creates the move as a new, disconnected piece instead.",
        "how": [
            "Point at a waypoint and drag it; release to drop it.",
            "\"picks\" cycles Point / Run / Span. Span needs its two ends clicked first; once "
            "picked, click near either end again to replace it, or drag the span to move it.",
            "\"falloff\" toggles the taper. On Point it spreads along the track by the falloff "
            "radius (wheel over the card, the +/- steppers, or , and .); on Run/Span it tapers to "
            "the run or span's own two ends automatically, with no radius to set.",
            "A ctrl-click / box / circle (Alt+drag) / freehand (Ctrl+Alt+drag) selection, if one "
            "exists, always wins over picks - grab any point IN it to drag the whole set, rigid.",
            "\"copy\" toggles whether the drag creates a new, disconnected copy instead of moving "
            "the originals. It can be turned on before, during, or even just after a drag - "
            "toggling it on right after releasing still converts that move into a copy.",
            "The tool card auto-hides while you drag, so it is never in the way.",
        ],
        "controls": [
            ("picks", "what a plain drag grabs: Point, Run, or Span."),
            ("falloff", "on/off; Point also gets a settable radius when on."),
            ("copy", "on/off; leaves the originals and creates a new, disconnected piece."),
            ("snap to", "surface or terrain for the dropped point."),
        ],
    },
    {
        "key": "smooth", "name": "Smooth", "group": "Shape",
        "summary": "Round off the jitter in a span or run.",
        "what": "Smooth eases the small kinks out of a stretch so a driven path stops feeling jumpy. "
                "It has two modes: one nudges the existing points into line (keeping junctions and "
                "markers), the other rebuilds the stretch at an even spacing.",
        "how": [
            "Pick the span or run to smooth.",
            "Choose the mode and strength/spacing, then apply.",
        ],
        "controls": [
            ("mode", "nudge existing points, or rebuild the stretch fresh."),
            ("strength", "how hard the nudge pulls (nudge mode)."),
            ("max spacing", "point spacing when rebuilding (rebuild mode)."),
        ],
    },
    {
        "key": "straighten", "name": "Straighten", "group": "Shape",
        "summary": "Flatten the noise out of a span while keeping real bends.",
        "what": "Straighten removes wandering detail from a stretch but keeps genuine corners, by "
                "dropping only the points that sit within a tolerance of the straight line. Raise "
                "the tolerance to flatten a real bend as well. Junctions in the middle are kept.",
        "how": [
            "Pick the span or run to straighten.",
            "Set the tolerance - larger removes more - then apply.",
        ],
        "controls": [
            ("tolerance", "how far off the line a point may be before it is kept."),
        ],
    },
    {
        "key": "divide", "name": "Divide", "group": "Shape",
        "summary": "Add evenly-spaced points along a span or run.",
        "what": "Divide inserts a chosen number of new waypoints spread evenly by distance along a "
                "stretch, giving you handles to work with where the track was too coarse.",
        "how": [
            "Pick the span or run.",
            "Set how many points to add, then apply.",
        ],
        "controls": [
            ("points", "how many new points to space along the stretch."),
        ],
    },
    {
        "key": "ground", "name": "Ground", "group": "Shape",
        "summary": "Re-seat points onto the surface under them.",
        "what": "Ground drops (or raises) the waypoints of a stretch onto the ground within a "
                "tolerance, fixing points that float above the terrain or sit buried. It keeps a "
                "point that is already correctly on a placed ramp or bridge deck rather than pulling "
                "it down to the terrain the straight line runs over.",
        "how": [
            "Pick the span or run.",
            "Set the tolerance (how far off the ground counts as a problem) and apply.",
        ],
        "controls": [
            ("tolerance", "how far off the surface a point may be before it is moved."),
            ("level", "settle to the top surface, or the one nearest the point."),
            ("snap to", "terrain or any surface (roads, decks)."),
        ],
    },
    {
        "key": "convert", "name": "Convert", "group": "Connect",
        "summary": "Change one-way / two-way and priority.",
        "what": "Convert rewrites the direction and priority of connections that already exist - "
                "make a stretch two-way, one-way, or flip it to a give-way (secondary) road - for a "
                "point, a span or a whole run.",
        "how": [
            "Pick the point, span or run.",
            "Choose what to make it (two-way, one-way, primary, secondary) and apply.",
        ],
        "controls": [
            ("make it", "two-way, one-way, primary or secondary."),
            ("scope", "the point, the span, or the whole run."),
        ],
    },
    {
        "key": "merge", "name": "Merge", "group": "Connect",
        "summary": "Fold two parallel lanes into one shared track.",
        "what": "Merge is for a stretch where two separately-recorded tracks run alongside each other "
                "- the two directions of a road, or a lane you recorded twice - and you want them to "
                "become one. You mark the length on one track, then point at the other, and the "
                "marked span is absorbed into it. It is a three-click action, not a single click on a "
                "pile of points.",
        "how": [
            "Click one end of the stretch on ONE of the two tracks.",
            "Click the far end on the SAME track. The two clicks must be two ends of one connected "
            "span - if they are not on the same track a warning says so and nothing happens.",
            "Click a point on the OTHER track running alongside. The part that will be absorbed turns "
            "green; the click confirms which nearby track is meant, and the merge happens.",
            "The two tracks have to be within the merge distance of each other (measured across the "
            "gap between them) for anything to merge - if they are too far apart, nothing does.",
        ],
        "controls": [
            ("merge distance", "how far apart the two tracks may sit and still merge, measured across "
                               "the gap. Set on AutoDrive's settings page."),
            ("divergence", "how far the two tracks may pull apart ALONG the stretch before they count "
                           "as separate runs and the merge stops there."),
        ],
    },
    {
        "key": "name", "name": "Name", "group": "Utility",
        "summary": "Give a waypoint a map-marker name.",
        "what": "Name attaches a label to a waypoint so it becomes a named destination/marker on the "
                "map, the way AutoDrive targets are named.",
        "how": [
            "Click the waypoint you want to name.",
            "Type the name in the dialog that opens and confirm.",
        ],
        "controls": [
            ("name dialog", "the base-game text entry, opened on click."),
        ],
    },
    {
        "key": "delete", "name": "Delete", "group": "Utility",
        "summary": "Remove a point, a span or a run.",
        "what": "Delete removes waypoints and the connections through them - a single point, a picked "
                "span, or a whole run between junctions, depending on the scope.",
        "how": [
            "Pick the point, span or run.",
            "Set the scope and apply - it is removed (and undoable).",
        ],
        "controls": [
            ("scope", "the point, the span, or the whole run."),
        ],
    },
]

GENERAL = {
    "summary": "Opening, leaving, and the keys and controls that work everywhere.",
    "sections": [
        ("Opening & leaving", [
            "Open the editor with Left Alt + F (rebindable in the controls menu), or the button "
            "beside AutoDrive's HUD.",
            "Press Esc to leave. Every edit is undoable.",
            "Single player only. Edits are written when you are the host.",
        ]),
        ("Keys", [
            "1-9, 0 - select a tool (the number shown on each tool button).",
            "Q - undo,  E - redo.",
            "H - hide / show the floating tool card (it also auto-hides while you drag).",
            ", and . - move tool falloff radius down / up.",
            "Esc - leave the editor (or close a dialog / cancel an edit).",
        ]),
        ("Mouse & camera", [
            "Left-click - place / select / operate, depending on the tool.",
            "Right-click - end a run, cancel a menu, or apply an armed tool.",
            "Middle-mouse - orbit / spin the camera. WASD moves it.",
            "Wheel - camera zoom, or adjust the numeric field the cursor is over.",
            "Ctrl+drag - box-select (aligned to the current camera view, not north). Shift adds to "
            "an existing selection instead of replacing it. Works in every tool.",
            "Alt+drag - circle-select; the two dragged points are a diameter, not a centre and radius.",
            "Ctrl+Alt+drag - freehand-select; trace a shape and release to close it.",
        ]),
        ("The tool card", [
            "The floating card carries the active tool's settings. It jumps out BESIDE the first "
            "click of each action - offset, never on top of what you clicked.",
            "Drag it by its header strip (the bar with the tool's name) to park it anywhere. Once "
            "you have placed it yourself, it stays put for the whole session and never jumps again.",
            "H hides and shows it; it also auto-hides while you drag a waypoint.",
        ]),
        ("Numeric fields", [
            "Every number on the panel can be changed three ways: click the - / + steppers, scroll "
            "the wheel over it, or click the value and type it.",
        ]),
        ("Settings & colours", [
            "The gear on the panel header (or a rebindable key) opens the settings dialog: UI scale, "
            "theme preset, accent colour, and a per-role colour editor.",
            "Settings are also on the panel under ACTIONS > settings. Everything applies live and "
            "saves automatically.",
            "Console command FlyoverResetTheme (or a rebindable key) resets colours and scale to "
            "default if a custom colour ever makes the panel hard to read.",
        ]),
    ],
}


# --------------------------------------------------------------------------------------------------
def wrap(text):
    return textwrap.wrap(" ".join(text.split()), WRAP)


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def emit_lua():
    out = []
    out.append("-- GENERATED by tools/make_help.py - do not edit by hand; edit the generator and re-run.")
    out.append("-- Per-tool help for the in-game contextual help and the browsable manual.")
    out.append("")
    out.append("ADFlyoverHelp = {}")
    order = [t["key"] for t in TOOLS]
    out.append("ADFlyoverHelp.ORDER = { " + ", ".join(lua_str(k) for k in order) + " }")
    out.append("ADFlyoverHelp.tools = {}")
    out.append("local T = ADFlyoverHelp.tools")
    out.append("")
    for t in TOOLS:
        out.append("T[%s] = {" % lua_str(t["key"]))
        out.append("  name = %s," % lua_str(t["name"]))
        out.append("  group = %s," % lua_str(t["group"].upper()))
        out.append("  summary = {")
        for line in wrap(t["summary"]):
            out.append("    %s," % lua_str(line))
        out.append("  },")
        out.append("  what = {")
        for line in wrap(t["what"]):
            out.append("    %s," % lua_str(line))
        out.append("  },")
        out.append("  how = {")
        for step in t["how"]:
            wrapped = wrap(step)
            for i, line in enumerate(wrapped):
                prefix = "- " if i == 0 else "  "
                out.append("    %s," % lua_str(prefix + line))
        out.append("  },")
        out.append("  controls = {")
        for name, desc in t["controls"]:
            wrapped = wrap(name + ": " + desc)
            for i, line in enumerate(wrapped):
                prefix = "" if i == 0 else "  "
                out.append("    %s," % lua_str(prefix + line))
        out.append("  },")
        out.append("}")
        out.append("")
    # general reference
    out.append("ADFlyoverHelp.general = {")
    out.append("  summary = %s," % lua_str(GENERAL["summary"]))
    out.append("  sections = {")
    for title, lines in GENERAL["sections"]:
        out.append("    { title = %s, lines = {" % lua_str(title))
        for line in lines:
            for i, wl in enumerate(wrap(line)):
                prefix = "- " if i == 0 else "  "
                out.append("      %s," % lua_str(prefix + wl))
        out.append("    } },")
    out.append("  },")
    out.append("}")
    out.append("")
    return "\n".join(out)


def emit_md():
    out = []
    out.append("# Flyover Editor — user manual")
    out.append("")
    out.append("A top-down editor for AutoDrive route networks. This manual describes every tool and "
               "the controls that work everywhere. It is generated from the same source as the "
               "in-game help (`tools/make_help.py`), so the two always agree.")
    out.append("")
    out.append("## Contents")
    out.append("")
    out.append("- [General](#general)")
    # group the tools
    groups = []
    for t in TOOLS:
        if not groups or groups[-1][0] != t["group"]:
            groups.append((t["group"], []))
        groups[-1][1].append(t)
    for g, ts in groups:
        names = ", ".join("[%s](#%s)" % (t["name"], t["key"].replace(" ", "-")) for t in ts)
        out.append("- **%s** — %s" % (g, names))
    out.append("")
    out.append("## General")
    out.append("")
    out.append(GENERAL["summary"])
    out.append("")
    for title, lines in GENERAL["sections"]:
        out.append("### %s" % title)
        out.append("")
        for line in lines:
            out.append("- %s" % line)
        out.append("")
    for t in TOOLS:
        out.append('<a id="%s"></a>' % t["key"].replace(" ", "-"))
        out.append("## %s" % t["name"])
        out.append("")
        out.append("*%s — %s*" % (t["group"], t["summary"]))
        out.append("")
        out.append(t["what"])
        out.append("")
        out.append("**How to use it**")
        out.append("")
        for step in t["how"]:
            out.append("1. %s" % step)
        out.append("")
        out.append("**Controls**")
        out.append("")
        for name, desc in t["controls"]:
            out.append("- **%s** — %s" % (name, desc))
        out.append("")
    return "\n".join(out)


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    lua_path = os.path.join(root, "scripts", "editor", "Help.lua")
    md_path = os.path.join(root, "docs", "manual.md")
    with open(lua_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(emit_lua())
    with open(md_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(emit_md())
    print("wrote %s (%d tools) and %s" % (lua_path, len(TOOLS), md_path))
