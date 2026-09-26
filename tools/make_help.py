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
        "what": "Select mode is where you act on what is already there. Clicking the network opens a "
                "small popup of actions for what you clicked - a point, a span or a whole run - and a "
                "selection opens one for the whole set, so most edits need no tool at all. The popup "
                "opens clear of what it acts on and can be dragged by its header.",
        "how": [
            "Click a waypoint: its POINT popup (name, move, connect, spline, one/two-way, primary/"
            "secondary, delete).",
            "Click a second point: the SPAN between them. Double-click a point: the whole RUN.",
            "Alt+drag a box, Shift+drag a circle, Alt+Shift+drag freehand, Space+drag+click a rotated "
            "box, or Ctrl-click points one by one to make a SELECTION; its popup acts on the whole set. "
            "A plain click followed by Ctrl-clicks keeps the first point; one point left is a point again.",
            "Picking a tool from a popup opens that tool's card where the popup was; right-click "
            "applies, Esc steps back to the popup.",
            "Esc closes the popup (and drops a selection); right-click closes it too.",
        ],
        "controls": [
            ("Point popup", "name, move, connect, spline, make one-way or two-way, make primary or "
                            "secondary, delete point."),
            ("Span / run popup", "move, straighten, smooth, divide, ground (+ parallel on a run), "
                                 "make one-way or two-way, flip direction, make primary or secondary, delete."),
            ("Selection popup", "move, clear, make one-way or two-way, flip direction, make primary or "
                                "secondary, delete selection. Conversions only touch links BETWEEN selected points."),
            ("Convert buttons", "each offers the opposite of what is there now and swaps after a click; a mix "
                                "offers both. Flip direction hides while everything is two-way. One-way follows "
                                "the road beyond the ends."),
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
            ("traffic", "one-way, two-way or reverse-way (a road vehicles drive in reverse gear)."),
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
            ("spline direction", "as clicked builds the curve from the first point; reversed builds it from "
                                 "the far end. That reshapes the curve and, on a one-way, sets which way it runs."),
            ("end / start tangent", "flip the direction the curve leaves each end."),
            ("traffic / priority", "as for Draw - one-way, two-way or reverse-way (AutoDrive's reverse road, which "
                                   "vehicles drive in reverse gear) and primary/secondary."),
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
            ("obstacle clearance", "how far the loop keeps from trees, poles, fences and buildings before detouring."),
            ("turning radius", "the tightest turn the loop is allowed to make. Never used below "
                               "5m even if set lower - a sharper corner than that reads as an "
                               "awkward kink rather than a smooth turn."),
            ("vehicle height", "how tall a machine the tree check clears for."),
            ("detect custom field", "on by default; also finds ground plowed to connect two "
                                     "separate map fields into one, not just a field shipped with "
                                     "the map. Turn it off to fall back to the map-field-only "
                                     "lookup if it ever misreads a field on your save."),
            ("avoid obstacles", "on by default; nudges the loop away from trees, poles, fences and "
                                 "buildings instead of laying it straight through them. Turn it "
                                 "off to take the offset boundary as laid if the obstacle check "
                                 "keeps flagging something that isn't really in the way."),
            ("combo gap", "how far to auto-search for another disconnected patch of the same "
                          "field when it's split by a lane, and combine it into the same course - "
                          "a live scan can only ever return the one piece a click lands on, so "
                          "this finds the rest on its own, no extra clicks needed. A real per-map "
                          "setting, not just a safety margin: raise it if a wide lane gets missed, "
                          "lower it if it ever reaches across an actual road into an unrelated "
                          "field."),
        ],
    },
    {
        "key": "parallel", "name": "Parallel", "group": "Create",
        "summary": "Lay a new track running parallel to a span or run.",
        "what": "Parallel copies a span or run sideways by a set distance as a second track alongside "
                "it - a passing lane or a return leg.",
        "how": [
            "Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The \"picks\" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.",
            "The side follows where the cursor is when the span is picked; change it on the card.",
            "Set the distance (type, step or wheel), then right-click to lay it.",
        ],
        "controls": [
            ("side", "a one-way track: left / right of its direction of travel. A two-way track: "
                     "left / right or up / down as it lies on screen - the words follow the camera."),
            ("flow", "beside a one-way road: the new track runs the SAME way, or OPPOSITE as a return "
                     "lane. Greyed on a two-way road, where it makes no difference."),
            ("picks", "span / run - what was picked; click to lock the type."),
            ("distance", "how far to the side the new track sits."),
        ],
    },
    {
        "key": "siding", "name": "Siding", "group": "Create",
        "summary": "A parallel spur that splines back in at both ends.",
        "what": "Siding drops a short parallel stretch beside a run and curves it back into the run "
                "at each end, like a pull-off or passing siding, in one action.",
        "how": [
            "Click where the siding should sit - the click is its centre, and the side follows the cursor.",
            "Set the offset and length (the wheel adjusts the length), then right-click to lay it.",
        ],
        "controls": [
            ("side", "as for Parallel: left / right of travel on a one-way track, by screen on a two-way one."),
            ("offset", "how far to the side the siding sits."),
            ("length (wheel)", "how long the parallel stretch is."),
        ],
    },
    {
        "key": "move", "name": "Move", "group": "Shape",
        "summary": "Drag a point, a span, a run or a selection - move, copy, cut loose, or slide sideways.",
        "what": "Move drags waypoints to a new spot and re-seats them on the real ground there. A "
                "CLICK picks what moves (a point, a span, a run), a DRAG moves it, so picking and "
                "moving are the same gestures as everywhere else. Falloff decides whether the move "
                "tapers smoothly or goes as one rigid piece. Copy leaves the originals and moves a new "
                "copy; disconnect cuts the moved piece loose. The OFFSET action slides a span or run "
                "sideways in place instead of moving it freely.",
        "how": [
            "Press and drag a point to move it. Release to drop it.",
            "Click (no drag) to pick instead: a point; a second point for the SPAN between; "
            "double-click for the whole RUN. Then drag any point of the pick to move the lot. "
            "Dragging a point outside the pick moves just that point.",
            "The \"picks\" row lights to show what is picked. Click a type to lock it: run moves the "
            "whole run from a single grab, point never builds spans. Click it again to unlock.",
            "A selection (box, circle, freehand, rotated box, Ctrl-click) wins: grab any selected point "
            "to move the set. One connected run of points counts as a span; a scattered set moves rigidly.",
            "Falloff: on a single point it spreads along the track by the falloff value (wheel, "
            "steppers, typed, or , and .). On a span, run or run-shaped selection it tapers from the "
            "point you grab down to zero at its own two ends - no value to set.",
            "Copy (B): on before you grab, you drag a new copy out and the original stays; turned on "
            "part way, the original drops straight back and the copy carries on; turned on just after "
            "a drop, that move becomes a copy.",
            "Action OFFSET (span or run picked): the cursor's distance from the chain slides it "
            "sideways; release, fine-tune with the wheel or a typed value, right-click to finish. Copy "
            "and disconnect work here too.",
            "Hold R and scroll WHILE dragging to rotate what is moving, around the grabbed point or the centroid.",
            "Options that cannot apply are greyed: falloff and disconnect exclude each other, offset "
            "falloff and disconnect too, and disconnect greys when nothing connects to the piece.",
        ],
        "controls": [
            ("picks", "point / span / run - an indicator of what a click picked, and a type lock."),
            ("action", "move (free drag) or offset (sideways slide; needs a span or run)."),
            ("falloff", "tapered or rigid. A single point's reach is the falloff value."),
            ("auto-hookup", "on a drop, joins a dangling end to what it lands near."),
            ("copy (b) / disconnect", "leave a copy / cut the moved piece loose."),
            ("offset falloff", "(offset) tapers the slide towards the chain's ends."),
            ("rotate pivot", "click point or centroid, for R+wheel."),
            ("snap to", "terrain or surface for the dropped points."),
        ],
    },
    {
        "key": "smooth", "name": "Smooth", "group": "Shape",
        "summary": "Round off the jitter in a span or run.",
        "what": "Smooth eases the small kinks out of a stretch so a driven path stops feeling jumpy. "
                "Relax nudges the existing points into line (keeping junctions and markers); rebuild "
                "lays the stretch again at an even spacing.",
        "how": [
            "Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The \"picks\" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.",
            "Or Ctrl-click the points one by one - they have to stay one connected run; a plain click "
            "afterwards drops that and starts a new pick.",
            "Set the mode and strength / spacing, then right-click to apply.",
        ],
        "controls": [
            ("mode", "relax (move points) or rebuild (respace)."),
            ("strength", "how hard relax pulls."),
            ("max spacing", "point spacing when rebuilding."),
        ],
    },
    {
        "key": "straighten", "name": "Straighten", "group": "Shape",
        "summary": "Flatten the noise out of a span while keeping real bends.",
        "what": "Straighten removes wandering detail but keeps genuine corners, dropping only the points "
                "within a tolerance of the straight line. Junctions, markers and the ends are kept; each "
                "stretch between them is straightened along the route you picked.",
        "how": [
            "Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The \"picks\" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.",
            "Or Ctrl-click the points one by one (one connected run).",
            "Set the tolerance - larger removes more - then right-click to apply.",
        ],
        "controls": [
            ("tolerance", "how far off the line a point may be before it is kept."),
        ],
    },
    {
        "key": "divide", "name": "Divide", "group": "Shape",
        "summary": "Respace a span or run with a chosen number of points.",
        "what": "Divide spreads a chosen number of waypoints evenly by distance along a stretch, along "
                "the route you picked, keeping junctions and markers where they are.",
        "how": [
            "Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The \"picks\" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.",
            "Or Ctrl-click the points one by one (one connected run).",
            "Set how many points, then right-click to apply.",
        ],
        "controls": [
            ("points", "how many points between the ends (starts at what is there now)."),
        ],
    },
    {
        "key": "ground", "name": "Ground", "group": "Shape",
        "summary": "Re-seat points onto the surface under them.",
        "what": "Ground drops (or raises) waypoints onto the ground within a tolerance, fixing points "
                "that float or sit buried. A point already correctly on a placed ramp or bridge deck is "
                "left there.",
        "how": [
            "Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The \"picks\" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.",
            "Or select points - box, circle, Ctrl-click - connected or not; Ground checks each on its own.",
            "Set the tolerance; the points found off the ground are marked. Right-click re-seats them.",
        ],
        "controls": [
            ("picks", "span / run / selection."),
            ("level", "settle on the span line or the top surface. Greyed while snapping to terrain."),
            ("snap to", "terrain, or whatever surface is there (roads, decks)."),
            ("tolerance", "how far off the surface a point may be before it is moved."),
        ],
    },
    {
        "key": "convert", "name": "Convert", "group": "Connect",
        "summary": "Change a point's or run's direction and priority in one click.",
        "what": "Convert rewrites connections that already exist. Set the direction AND the priority "
                "you want on the card; one click applies both, as one undo step.",
        "how": [
            "Set direction and priority on the card, and whether it applies to one waypoint or the whole run.",
            "Click the point or run.",
        ],
        "controls": [
            ("direction", "two-way, one-way, other way (flips a one-way; a reverse-way stays reverse-way), "
                          "or reverse-way (AutoDrive's reverse road, driven in reverse gear)."),
            ("priority", "primary, or secondary (a give-way road)."),
            ("applies to", "this waypoint, or the whole run."),
        ],
    },
    {
        "key": "merge", "name": "Merge", "group": "Connect",
        "summary": "Fold two parallel lanes into one shared track.",
        "what": "Merge is for a stretch where two separately-recorded tracks run alongside each other - "
                "the two directions of a road, or a lane recorded twice - and you want them to become one. "
                "Pick the stretch on one track, then click the other, and the picked stretch is absorbed.",
        "how": [
            "Pick the stretch the usual way: click one end and then the other for a SPAN, or double-click for the whole RUN between junctions. Click again near either end to move that end. The \"picks\" row lights to show what you picked; click a type to lock to it (the others dull), click it again to unlock. A route that only joins the two points the long way round is refused.",
            "Green marks what would be absorbed. Click the OTHER track to merge - or right-click if "
            "it is the only track alongside.",
            "The two tracks have to be within the merge distance of each other for anything to merge.",
        ],
        "controls": [
            ("merge distance", "how far apart the two tracks may sit and still merge."),
            ("divergence", "how far they may pull apart along the stretch before the merge stops there."),
            ("snap to", "terrain, or keep merged points on a bridge / ramp surface."),
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
        "summary": "Remove a point, a run, or a selection.",
        "what": "Delete removes waypoints and the connections through them - one waypoint or a whole run "
                "between junctions per click, or everything selected.",
        "how": [
            "Click a point: it (or its run, per the card) is removed.",
            "With a selection, a left click does nothing - right-click deletes the selection, Esc clears it.",
            "Everything is undoable (Q).",
        ],
        "controls": [
            ("removes", "one waypoint, or the whole run. Greyed while a selection exists."),
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
            ", and . - Move's falloff value down / up.",
            "B - toggle Move's copy.",
            "R (held) + wheel - rotate what is being dragged (Move, mid-drag).",
            "Esc - back out ONE step: a typed number, a dialog, a popup (and its selection), a tool "
            "picked from a popup (back to the popup), a pending action, the selection, the tool - and "
            "only then leave the editor.",
        ]),
        ("Mouse & camera", [
            "Left-click - pick; left-drag - move (Move). Second click = span, double-click = run, in "
            "every tool that works on a stretch.",
            "Right-click - apply what is pending (end a run, lay a track, commit), or close a popup.",
            "Middle-mouse - orbit / spin the camera. WASD moves it.",
            "Wheel - camera zoom, or adjust the number the cursor is over.",
            "Ctrl - add to / remove from the selection, on its own or on top of a shape below. In "
            "Smooth, Straighten, Divide, Parallel and Merge it must stay one connected run.",
            "Alt+drag box, Shift+drag circle, Alt+Shift+drag freehand, Space+drag+click rotated box.",
        ]),
        ("Popups", [
            "Clicking the network opens a popup for the point, span, run or selection. It opens clear "
            "of what it acts on and can be dragged by its header.",
        ]),
        ("The tool card", [
            "The floating card carries the active tool's settings: toggles lit when on, choices side by "
            "side, numbers you can step, scroll or type. Options that cannot apply right now are greyed.",
            "Picked from a popup, the card opens where the popup was. It steps aside when it would cover "
            "your work, and otherwise stays where you dragged it (header strip).",
            "Pin (on the header, or the settings dialog) keeps it exactly where it is, always.",
            "H hides and shows it; it also auto-hides while you drag a waypoint.",
        ]),
        ("Numeric fields", [
            "Every number on the panel can be changed three ways: click the - / + steppers, scroll "
            "the wheel over it, or click the value and type it.",
        ]),
        ("Settings & colours", [
            "The panel's SETTINGS has UI scale, theme and accent; drag the panel's bottom-right corner "
            "to resize. \"more settings...\" (or the gear) opens the dialog: line weight, per-role "
            "colours, the tool card pin, the launch button and debug logging.",
            "Everything applies live and saves automatically. Console command FlyoverResetTheme resets "
            "colours and scale if a custom colour ever makes the panel hard to read.",
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
