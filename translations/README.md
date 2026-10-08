# Translations

Thank you for helping! The Brazilian Portuguese (PT-BR) draft is in one file:

**[`scripts/editor/locale/br.lua`](../scripts/editor/locale/br.lua)**

It is a first draft made with Claude's help. It needs a native speaker to make it sound natural.

## How to edit

Each line looks like this:

    ["MODE"] = "MODO",

- The part in the **first** brackets is the English text shown in the editor. **Do not change it.**
- The part after `=` is the Portuguese. **Change this** whenever it sounds wrong.
- Keep `%d`, `%s` and `%.1f` exactly as they are. The game fills in numbers there.
- Keep it short. The editor panel is narrow, and long labels get cut off.
- Keep the quote marks and the comma at the end of the line.
- To write a quote inside a text, use `\"`.

Long help text (the `HELP` section) is one paragraph per line. Do not break it into short lines yourself, because the editor wraps it.

## What to check

1. **Terms.** The same word should be used for the same thing everywhere. The words we chose:

   | English | Portuguese |
   |---|---|
   | waypoint | ponto |
   | span | trecho |
   | run | rota |
   | junction | cruzamento |
   | lane | faixa |
   | siding | desvio |
   | field loop | contorno de campo |
   | one-way / two-way | mão única / mão dupla |
   | reverse-way | contramão |
   | falloff | atenuação |

2. **Words we are not sure about** (please say what you would use instead):
   - "assentar" for *Ground* (put points back on the surface)
   - "desvio" for *Siding*
   - "contramão" for *reverse-way*. In Brazil it normally means driving against traffic, but here it means vehicles reversing along the road.
   - "conversão" for a junction turn
   - "faixa" and "pista", which may be confused
   - "refazer" is used for both *Redo* and *Rebuild*. Maybe "recriar" for Rebuild?
   - "Seleção" in the help text means the row of *picks*. The label on screen is "escolhas".
   - "estrada de preferência para o outro lado" (give-way road) sounds awkward
   - short forms used to save space: "pts", "desl.", "lig.", "ligação auto"

3. **The junction help** was translated from the German version, because the English has no text for it yet.

## How to send your changes

- **Easiest:** copy the lines you changed into a comment on [issue #16](https://github.com/huskermcdoogle/FS25_ADFlyoverEditor/issues/16).
- **Or** fork the repository, edit `scripts/editor/locale/br.lua`, and open a pull request.

To test in game, the Brazilian Portuguese game language is used automatically.
