# Changelog

## 0.30.10.0 — Per-tool help & a user manual (2026-09-16)

- **In-game help** — a **?** button on the panel header (and the **/** key) toggles a contextual help
  panel beside the editor that shows the **selected tool's** full help — what it does, how to use it,
  and its controls — following the tool as you switch. Non-modal, so you can read it while working.
- **User manual** — a complete written manual at [`docs/manual.md`](docs/manual.md), one section per
  tool plus a General reference. It and the in-game help are generated from one source
  (`tools/make_help.py`), so they never disagree.
- **Tool numbers renumbered** — the keycaps now run **1→9, 0** straight down the Create and Shape
  groups in the panel's reading order instead of scattering by internal id. There are ten number keys
  and fourteen tools, so the Connect and Utility tools (convert, merge, name, delete) are click-only.

## 0.30.8.0 — Settings dialog, safer recovery, better card hiding (2026-09-16)

- **Standalone settings dialog** — a modal popup opened by the **⚙ gear** on the panel header (or a
  rebindable keybind). It carries the full settings surface: ui scale, theme, accent, a per-role
  colour editor (role picker, live swatch + hex, R/G/B), reset-all and close. It matches the panel —
  the theme's own colours, at the theme's scale.
- **Reset recovery** — a `FlyoverResetTheme` console command (always available) and a rebindable
  "reset editor colours and scale" key put the theme back to default, so a custom colour that makes
  the panel unreadable can never trap you.
- **Card hiding reworked** — middle-mouse no longer hides the tool card (it was fighting the camera's
  orbit). Instead the card **auto-hides while you drag a point**, plus an **`H` key** and a **panel
  button** toggle it (and now hide the armed span-tool popup too, consistently across tools).
- **Version in the panel** — the build number shows next to the FLYOVER EDITOR title, so a screenshot
  always says which build it is.

## 0.30.2.0 — Advanced per-role colour editor (2026-09-16)

Added the third theming layer: hand-tune individual colours on top of a preset + accent.

- **In-editor colour editor** — in the panel's **Settings**, toggle **advanced colours** to open a
  **COLOUR OVERRIDE** section.
  - **edit** — click / scroll / − + to pick which of 15 roles to tune (panel bg, body text, value
    text, borders, accent text, hover, danger, tool bg, stepper bg, …).
  - **swatch + hex** — a live colour chip and hex readout of the selected role (marked *custom* once
    overridden).
  - **R / G / B** — 0–255 per channel, by click / scroll / − + / type.
  - **clear this colour** — reverts just that role back to the preset + accent.
- Overrides **layer on top** of the preset and accent, apply live, and persist to `theme.xml`.
  Switching preset or accent keeps them; **reset to default** wipes them.
- Under the hood: the resolved palette is now kept in **sRGB as well as linear** (the editor works in
  sRGB / 0–255; rendering still hands `setColor` linear), with `srgb()` / `hexOf()` accessors and a
  curated `EDITABLE_ROLES` list.

## 0.30.1.0 — Themeable, scalable panel (2026-09-16)

Reworked the editor panel from a fixed grey look into a scalable, fully themeable one, with a new
high-contrast default.

- **Scalable UI** — a mod-specific size multiplier (**0.70×–2.00×**) on top of the game's UI scale,
  so the editor can be enlarged for a high-res display or easier reading without resizing the rest of
  the HUD.
- **Colour themes** — every colour the panel draws is now a named *role* resolved from a **preset +
  accent + optional overrides**:
  - **7 presets:** Contrast Dark, Amber, Cyan, Green, Slate + Blue, HC Light, Classic.
  - **7 accents:** amber, blue, cyan, green, red, purple, white.
- **New default:** **Contrast Dark + amber at 1.0×** — deliberately off the old low-contrast
  grey-on-grey-with-blue.
- **In-editor Settings** — open from the panel's **ACTIONS → settings**; adjust scale, theme and
  accent live (click / scroll / − + / type). Everything saves automatically to `theme.xml`.
- **Gamma fix** — colours are authored in sRGB (as in the design lab) and converted to **linear**
  before `setColor`, because FS25's overlays take linear light. Without this the display gamma lifted
  every dark value to grey — which is why the dark themes (and the original panel) looked washed out.
- Internally: the ~50 hardcoded colours in the HUD became role lookups; the mouse wheel now adjusts
  any numeric field under the cursor, including the settings fields.

---

*A design preview used to choose the default palette and scale lives at the
[theme lab](https://claude.ai/artifact/H3HuvqeRZ4cuWqCgAbYyaJ).*
