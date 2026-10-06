# Editor split tools

For splitting `scripts/editor/FlyoverEditor.lua` into modules without changing what it does. The plan is
[docs/editor-modules-spec.md](../../docs/editor-modules-spec.md).

| tool | what it does |
|---|---|
| `modules.txt` | where each module starts in FlyoverEditor.lua, and the file it moves to |
| `split.py plan` | every module still in FlyoverEditor.lua: its lines, the helpers it needs from above, the helpers files below it need from it, and what blocks it |
| `split.py move [--dry-run]` | moves the LAST module still in FlyoverEditor.lua to its file, writes the shared and alias blocks, lists it in Prelude |
| `bundle.py [--commit C] out.lua` | the whole editor in one file (each module in its own `do ... end`), for `FE_SRC` and A/B runs; `--list` prints the editor's files |
| `gate.sh [BASE]` | the working tree against a commit: static checks, then every offline test, all of which must match byte for byte |

One step:

    python tools/modsplit/split.py plan              # what moves next, and whether anything blocks it
    python tools/modsplit/split.py move              # move it
    bash tools/modsplit/gate.sh                      # against HEAD: must say GATE: PASS
    git add -A scripts tools/modsplit && git commit  # one module per commit

The editor loads offline the way it loads in game: `tools/junction-harness/editor_load.lua` reads
Prelude's `P.EDITOR_FILES` and loads FlyoverEditor.lua and every file after it, in that order. `FE_SRC`
still loads one file instead: an older copy, or a bundle.

How the move stays safe:
- **Order.** Lua code can only use a local helper declared above it. Modules move out from the end of the
  file backwards, so what stays in FlyoverEditor.lua (always the top of the old file) never needs a moved
  file, and each moved file loads after it, in the old order.
- **Shared helpers.** A helper declared above a module and used in it is published on
  `ADFlyoverEditor.shared` at the end of the file that declares it (the `MODSPLIT` shared block). The
  module takes a local alias of it at its top (the `MODSPLIT` helpers block), and says in the log if one is
  missing at load. No call site changes.
- **Reassigned state.** A helper assigned again after its declaration can't be shared by alias: the alias
  would keep the old value. `split.py` refuses the move and names it; it has to become a table field
  first.
- **Today's `do ... end` blocks.** The five that kept the one file under Lua's 200-local limit are unwrapped
  when a cut goes through one, or when the module holding one moves out.
- **Test tools that swap a helper.** A harness tool that swaps a local helper through `debug.setupvalue`
  (missed.lua swaps `jxRemove`) reached every caller while they shared one file. After a split each file
  has its own alias, so the tool must swap it in every function that holds it (missed.lua walks them all
  since phase 3; caught by the full gate's regmissed, 2026-10-06).
- **The gate.** It compiles every file and diffs the global names each file reads or writes against the
  base, since a helper that lost its local shows up as a new global. It then runs every offline test,
  base and working tree side by side, in three waves:
  - A: reg75 and reg75check, with and without the split registry, twice for the working tree;
  - B: regbuild, regplace exact and smooth, reg75undo;
  - C: regtwin, reg75click, reg_extra, regnames, regmissed, dbgtypes.

  Outputs go to `out/<time>/` (git-ignored).
