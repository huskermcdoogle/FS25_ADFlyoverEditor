--[[
ADFlyoverLocale - the editor's own small localization layer.

Why not g_i18n:getText? This mod is SOURCED INTO AutoDrive's Lua environment (see Arming), so at
runtime the "current mod" g_i18n resolves against is AutoDrive's, not ours - our own texts would not be
found without passing a custom environment, and whether the engine even builds one for a companion
loaded this way is not something to bet the UI on. So the strings live here, in plain Lua, chosen by
g_languageShort, with English as the identity fallback. The three INPUT-ACTION names still go through
the engine's own l10n in modDesc (the one place it is reliable), which is why they are not here.

Scope (chosen with the user): the persistent UI chrome - panel and dialog labels, tool names, toggle
options, section headers - plus each tool's one-line SUMMARY. The longer WHAT / HOW / CONTROLS help
prose and the contextual NEXT-step guidance stay English for now.

Adding a language: add a table under STRINGS (and SUMMARIES) keyed by its two-letter code. Any key with
no entry falls back to English - the key itself for STRINGS, the bundled English lines for SUMMARIES -
so a partial translation is safe and simply shows English wherever it is missing.
]]

ADFlyoverLocale = {}
local L = ADFlyoverLocale

--- The active two-letter language code ("en", "de", ...). FS exposes it as g_languageShort; a couple of
--- other spellings are tried under pcall in case a build differs, then English as the safe default -
--- every string has an English form, so a missed detection only costs the translation, never a crash.
function L.code()
    if type(g_languageShort) == "string" and #g_languageShort >= 2 then
        return string.lower(string.sub(g_languageShort, 1, 2))
    end
    local ok, suffix = pcall(function()
        if g_i18n ~= nil and type(g_i18n.getLanguageSuffix) == "function" then
            return g_i18n:getLanguageSuffix()   -- e.g. "_de"
        end
        return nil
    end)
    if ok and type(suffix) == "string" then
        local code = string.gsub(suffix, "^_", "")
        if #code >= 2 then
            return string.lower(string.sub(code, 1, 2))
        end
    end
    return "en"
end

-- English string -> localized string, per language. English is the identity fallback, so it needs no
-- table of its own. Keys are the exact English literals the UI draws, so a translation is a one-line
-- addition with nothing else to wire.
L.STRINGS = {
    de = {
        -- header / notes / status / cursor readout
        ["FLYOVER EDITOR"] = "FLYOVER-EDITOR",
        ["Standard AutoDrive editing suspended"] = "Standard-AutoDrive-Bearbeitung ausgesetzt",
        ["tool card hidden - press H or the button to show"] = "Werkzeugkarte verborgen – H oder Knopf zum Anzeigen",
        ["under cursor"] = "unter dem Cursor",
        ["selected %d   undo %d   placed %d"] = "ausgewählt %d   rückgängig %d   platziert %d",

        -- panel section headers
        ["MODE"] = "MODUS",
        ["CREATE"] = "ERSTELLEN",
        ["SHAPE"] = "FORMEN",
        ["CONNECT"] = "VERBINDEN",
        ["UTILITY"] = "WERKZEUGE",
        ["ACTIONS"] = "AKTIONEN",
        ["SETTINGS"] = "EINSTELLUNGEN",
        ["COLOUR OVERRIDE"] = "FARB-ÜBERSCHREIBUNG",
        ["NEW CONNECTIONS"] = "NEUE VERBINDUNGEN",
        ["THIS TOOL"] = "DIESES WERKZEUG",
        ["NEXT"] = "NÄCHSTER SCHRITT",

        -- settings-dialog section headers
        ["DISPLAY"] = "ANZEIGE",
        ["THEME"] = "DESIGN",
        ["ADVANCED - PER-ROLE COLOUR"] = "ERWEITERT – FARBE JE ROLLE",

        -- tool names, lower case (panel buttons)
        ["select"] = "auswählen",
        ["draw"] = "zeichnen",
        ["spline"] = "Spline",
        ["field loop"] = "Feldschleife",
        ["parallel"] = "Parallele",
        ["siding"] = "Ausweiche",
        ["move"] = "verschieben",
        ["smooth"] = "glätten",
        ["straighten"] = "begradigen",
        ["divide"] = "unterteilen",
        ["ground"] = "aufsetzen",
        ["convert"] = "umwandeln",
        ["merge"] = "zusammenführen",
        ["junction"] = "Kreuzung",
        ["junction BETA"] = "Kreuzung BETA",
        ["name"] = "benennen",
        ["delete"] = "löschen",

        -- tool names, capitalised (manual / help page titles, from Help.name)
        ["Select"] = "Auswählen",
        ["Draw"] = "Zeichnen",
        ["Spline"] = "Spline",
        ["Field loop"] = "Feldschleife",
        ["Parallel"] = "Parallele",
        ["Siding"] = "Ausweiche",
        ["Move"] = "Verschieben",
        ["Smooth"] = "Glätten",
        ["Straighten"] = "Begradigen",
        ["Divide"] = "Unterteilen",
        ["Ground"] = "Aufsetzen",
        ["Convert"] = "Umwandeln",
        ["Merge"] = "Zusammenführen",
        ["Junction"] = "Kreuzung",
        ["Name"] = "Benennen",
        ["Delete"] = "Löschen",

        -- actions / buttons / setting labels
        ["undo"] = "rückgängig",
        ["redo"] = "wiederherstellen",
        ["settings"] = "Einstellungen",
        ["show tool card"] = "Werkzeugkarte anzeigen",
        ["hide tool card"] = "Werkzeugkarte verbergen",
        ["reset to default"] = "auf Standard zurücksetzen",
        ["more settings..."] = "weitere Einstellungen...",
        ["clear this colour"] = "diese Farbe zurücksetzen",
        ["reset all to default"] = "alles auf Standard zurücksetzen",
        ["close"] = "schließen",
        ["open"] = "offen",
        ["advanced colours"] = "erweiterte Farben",
        ["shown"] = "angezeigt",
        ["hidden"] = "verborgen",
        ["ui scale"] = "UI-Größe",
        ["line weight"] = "Linienstärke",
        ["theme"] = "Design",
        ["accent"] = "Akzent",
        ["edit"] = "bearbeiten",
        ["role"] = "Rolle",
        ["current"] = "aktuell",
        ["current (custom)"] = "aktuell (eigen)",
        ["click / scroll / +- to change - saved automatically"] = "klicken / scrollen / +- zum Ändern – automatisch gespeichert",
        ["changes apply live and save automatically  -  Esc to close"] = "Änderungen sofort aktiv, automatisch gespeichert  –  Esc schließt",

        -- toggle labels
        ["direction"] = "Richtung",
        ["priority"] = "Priorität",
        ["side"] = "Seite",
        ["covers"] = "umfasst",
        ["snap to"] = "einrasten auf",
        ["mode"] = "Modus",
        ["level"] = "Höhe",
        ["off the ground"] = "über dem Boden",
        ["make it"] = "ändern zu",
        ["scope"] = "Umfang",
        ["applies to"] = "gilt für",
        ["tool card"] = "Werkzeugkarte",
        ["camera through buildings"] = "Kamera durch Gebäude",
        ["on: the camera flies under roofs, to place points inside sheds"] = "an: die Kamera fliegt unter Dächer, für Punkte in Hallen",
        ["height slice (G)"] = "Höhenschnitt (G)",
        ["slice height on foot"] = "Schnitthöhe zu Fuß",
        ["slice: looks straight down and hides roofs and trees over your vehicle's height"] = "Schnitt: Blick senkrecht nach unten, Dächer und Bäume über der Fahrzeughöhe ausgeblendet",
        ["pin"] = "anheften",
        ["picked side"] = "gewählte Seite",
        ["up"] = "oben",
        ["selection"] = "Auswahl",
        ["other way"] = "andersherum",
        ["reverse-way"] = "Rückwärtsweg",
        ["action"] = "Aktion",
        ["offset needs a run or span pick"] = "Versatz braucht eine Route oder einen Abschnitt",
        ["other way flips a one-way; reverse-way = vehicles back along it"] = "andersherum dreht eine Einbahn; Rückwärtsweg = Fahrzeuge fahren rückwärts",
        ["OPTIONS"] = "OPTIONEN",
        ["Those two points are only joined the long way round - pick points on the same stretch of track."] = "Diese Punkte sind nur über einen langen Umweg verbunden - Punkte auf demselben Streckenstück wählen.",
        ["That point is only joined to the span the long way round - the span was not changed."] = "Dieser Punkt ist nur über einen langen Umweg mit dem Abschnitt verbunden - der Abschnitt wurde nicht geändert.",
        ["selection  %d pts"] = "Auswahl  %d Pkt.",
        ["clear"] = "aufheben",
        ["delete selection"] = "Auswahl löschen",
        ["That would break the selection in two - for this tool a Ctrl selection has to be one connected run."] = "Das würde die Auswahl teilen - für dieses Werkzeug muss eine Strg-Auswahl eine zusammenhängende Route sein.",
        ["Green marks what would be absorbed. Click the OTHER track to merge (right-click if it is the only one)."] = "Grün markiert, was übernommen wird. Die ANDERE Spur anklicken, um zusammenzuführen (Rechtsklick, wenn es nur eine gibt).",
        ["Click one end of the span to merge, or double-click for the whole run."] = "Ein Ende des Abschnitts zum Zusammenführen anklicken, oder doppelklicken für die ganze Route.",
        ["click = point, 2nd click = span, double-click = run"] = "Klick = Punkt, 2. Klick = Abschnitt, Doppelklick = Route",
        ["offset needs a picked run or span"] = "Versatz braucht eine gewählte Route oder einen Abschnitt",
        ["a scattered selection moves rigidly - no falloff"] = "eine verstreute Auswahl bewegt sich starr - kein Abfall",
        ["selection is one run - falloff tapers to its ends"] = "Auswahl ist eine Route - Abfall läuft zu ihren Enden aus",
        ["No clear run through here - it is a junction, or a loop that leaves and returns to one junction. Click the two ends of the part you want instead."] = "Hier gibt es keine eindeutige Route - es ist eine Kreuzung oder eine Schleife, die zur selben Kreuzung zurückführt. Stattdessen die beiden Enden des gewünschten Teils anklicken.",
        ["Those two points are not connected, so they are not two ends of one span."] = "Diese beiden Punkte sind nicht verbunden und daher keine zwei Enden eines Abschnitts.",
        ["That point is not connected to the other end, so the span was not changed."] = "Dieser Punkt ist nicht mit dem anderen Ende verbunden, der Abschnitt wurde nicht geändert.",
        ["same way"] = "gleiche Richtung",
        ["opposite"] = "Gegenrichtung",
        ["(only matters beside a one-way track)"] = "(nur neben einer Einbahnspur relevant)",
        ["spline direction"] = "Spline-Richtung",
        ["curve by"] = "Kurve per",
        ["multi-point"] = "Mehrpunkt",
        ["spacing"] = "Abstand",
        ["start heading"] = "Start-Richtung",
        ["end heading"] = "End-Richtung",
        ["waypoints"] = "Wegpunkte",
        ["as clicked"] = "wie geklickt",
        ["traffic"] = "Verkehr",
        ["reversed builds the curve from the far end"] = "umgekehrt baut die Kurve vom fernen Ende aus",
        ["(shape, and on one-way the way it runs)"] = "(Form, und bei Einbahn die Fahrtrichtung)",
        ["reverse-way = a road vehicles back along"] = "Rückwärtsweg = Straße, auf der Fahrzeuge rückwärts fahren",
        ["2 clicks = span, double-click = run, or select points"] = "2 Klicks = Abschnitt, Doppelklick = Route, oder Punkte auswählen",
        ["Click a span or double-click a run, or select points (box, circle, Ctrl-click) - connected or not - to find waypoints off the ground."] = "Abschnitt anklicken oder Route doppelklicken, oder Punkte auswählen (Rahmen, Kreis, Strg-Klick) - verbunden oder nicht - um Wegpunkte über dem Boden zu finden.",
        ["Click one end of a span to run a track alongside it, or double-click for the whole run."] = "Ein Ende eines Abschnitts anklicken, um eine Spur daneben zu legen, oder doppelklicken für die ganze Route.",
        ["2 clicks = span, double-click = run"] = "2 Klicks = Abschnitt, Doppelklick = Route",
        ["Click one end of a span to find waypoints off the ground, or double-click for the whole run."] = "Ein Ende eines Abschnitts anklicken, um Wegpunkte über dem Boden zu finden, oder doppelklicken für die ganze Route.",
        ["Click one end of a span to straighten it, or double-click for the whole run."] = "Ein Ende eines Abschnitts anklicken, um ihn zu begradigen, oder doppelklicken für die ganze Route.",
        ["down"] = "unten",
        ["other side"] = "andere Seite",
        ["relax"] = "glätten",
        ["clockwise"] = "im Uhrzeigersinn",
        ["counter-clockwise"] = "gegen den Uhrzeigersinn",
        ["pivot"] = "Drehpunkt",
        ["track"] = "Spur",
        ["FOLLOW"] = "FOLGEN",
        ["OFFSET"] = "VERSATZ",
        ["COPY AND BREAK"] = "KOPIEREN / TRENNEN",
        ["ROTATE"] = "DREHEN",
        ["HOOKUP"] = "ANSCHLIESSEN",
        ["pinned"] = "angeheftet",
        ["stays put"] = "bleibt stehen",
        ["follows work"] = "folgt der Arbeit",
        ["removes"] = "entfernt",
        ["flow"] = "Fahrtrichtung",
        ["endpoints (shape)"] = "Endpunkte (Form)",
        ["end tangent"] = "End-Tangente",
        ["start tangent"] = "Start-Tangente",
        ["curvature (wheel)"] = "Krümmung (Rad)",
        ["strength"] = "Stärke",
        ["tolerance"] = "Toleranz",
        ["points"] = "Punkte",
        ["distance"] = "Abstand",
        ["picks"] = "Auswahl",
        ["falloff"] = "Abnahme",
        ["copy (b)"] = "kopieren (b)",
        ["disconnect"] = "trennen",
        ["auto-hookup"] = "Auto-Anschluss",
        ["rotate pivot"] = "Drehpunkt",
        ["offset falloff"] = "Versatz-Abnahme",
        ["detect custom field"] = "eigenes Feld erkennen",
        ["Courseplay field"] = "Courseplay-Feld",
        ["leave out islands"] = "Inseln auslassen",
        ["avoid obstacles"] = "Hindernisse meiden",
        ["combo gap"] = "Kombi-Lücke",

        -- editable-number labels
        ["offset"] = "Versatz",
        ["length"] = "Länge",
        ["margin"] = "Rand",
        ["obstacle clearance"] = "Hindernisabstand",
        ["turning radius"] = "Wenderadius",
        ["vehicle height"] = "Fahrzeughöhe",
        ["max spacing"] = "max. Abstand",
        ["merge distance"] = "Zusammenführ-Abstand",
        ["divergence"] = "Divergenz",
        ["falloff along track"] = "Abnahme entlang Strecke",

        -- toggle option values / name tables
        ["primary"] = "primär",
        ["secondary"] = "sekundär",
        ["one-way"] = "einseitig",
        ["two-way"] = "beidseitig",
        ["reverse"] = "umgekehrt",
        ["reversed"] = "umgekehrt",
        ["left"] = "links",
        ["right"] = "rechts",
        ["terrain"] = "Gelände",
        ["surface"] = "Oberfläche",
        ["span line"] = "Streckenlinie",
        ["top surface"] = "obere Fläche",
        ["picked span"] = "gewählter Abschnitt",
        ["whole run"] = "ganze Route",
        ["one waypoint"] = "ein Wegpunkt",
        ["relax (move points)"] = "lockern (Punkte verschieben)",
        ["rebuild (respace)"] = "neu aufbauen (neu verteilen)",
        ["swapped"] = "getauscht",
        ["normal"] = "normal",
        ["flipped"] = "umgedreht",
        ["auto"] = "auto",
        ["on"] = "an",
        ["off"] = "aus",
        ["point"] = "Punkt",
        ["run"] = "Route",
        ["span"] = "Abschnitt",
        ["click point"] = "Klickpunkt",
        ["centroid"] = "Schwerpunkt",

        -- theme preset names
        ["Contrast Dark"] = "Kontrast Dunkel",
        ["Amber"] = "Bernstein",
        ["Cyan"] = "Cyan",
        ["Green"] = "Grün",
        ["Slate + Blue"] = "Schiefer + Blau",
        ["HC Light"] = "HK Hell",
        ["Classic"] = "Klassisch",

        -- accent names
        ["amber"] = "bernstein",
        ["blue"] = "blau",
        ["cyan"] = "cyan",
        ["green"] = "grün",
        ["red"] = "rot",
        ["purple"] = "violett",
        ["white"] = "weiß",

        -- per-role colour labels (advanced editor)
        ["panel bg"] = "Panel-Hintergrund",
        ["card bg"] = "Karten-Hintergrund",
        ["header bg"] = "Kopf-Hintergrund",
        ["panel border"] = "Panel-Rand",
        ["card border"] = "Karten-Rand",
        ["body text"] = "Fließtext",
        ["value text"] = "Werttext",
        ["muted text"] = "gedämpfter Text",
        ["section text"] = "Abschnittstext",
        ["header text"] = "Kopftext",
        ["accent text"] = "Akzenttext",
        ["hover"] = "Hover",
        ["danger"] = "Gefahr",
        ["tool bg"] = "Werkzeug-Hintergrund",
        ["stepper bg"] = "Stepper-Hintergrund",

        -- help / manual chrome
        ["help"] = "Hilfe",
        ["browse the full manual  >"] = "vollständiges Handbuch  >",
        ["<  prev"] = "<  zurück",
        ["next  >"] = "weiter  >",
        ["General reference"] = "Allgemeine Referenz",
        ["WHAT IT DOES"] = "WAS ES TUT",
        ["HOW TO USE IT"] = "ANWENDUNG",
        ["CONTROLS"] = "STEUERUNG",

        -- cursor field readout templates (formatted in FlyoverEditor)
        ["field %d"] = "Feld %d",
        ["farmland %d (no field)"] = "Grundstück %d (kein Feld)",

        -- Select-mode context menu (headers, actions, the armed popup note)
        ["point %d"] = "Punkt %d",
        ["span  %d pts"] = "Abschnitt  %d Pkt.",
        ["run  %s pts"] = "Route  %s Pkt.",
        ["%s - selected"] = "%s – gewählt",
        ["name..."] = "benennen…",
        ["connect from here"] = "von hier verbinden",
        ["connect"] = "verbinden",
        ["spline from here"] = "von hier Spline",
        ["make two-way"] = "beidseitig machen",
        ["make one-way"] = "einseitig machen",
        ["flip direction"] = "Richtung umkehren",
        ["make primary"] = "primär machen",
        ["make secondary"] = "sekundär machen",
        ["delete point"] = "Punkt löschen",
        ["delete span"] = "Abschnitt löschen",
        ["delete run"] = "Route löschen",
        ["apply"] = "anwenden",
        ["cancel"] = "abbrechen",
        ["scroll or +/- to adjust - right-click applies"] = "scrollen oder +/- zum Ändern – Rechtsklick wendet an",

        -- "NEXT" helper guidance (each is one whole message, wrapped to the panel at render; the format
        -- placeholders must survive into the German exactly as they are here)
        ["No tool selected. Pick one above, or press 1-9 / 0."] = "Kein Werkzeug gewählt. Oben eines wählen oder 1-9 / 0 drücken.",
        ["Click ground to extend, or a waypoint to link. Right-click ends."] = "Boden anklicken zum Verlängern, oder einen Wegpunkt zum Verbinden. Rechtsklick beendet.",
        ["Click to start a run, or a waypoint to draw on from it."] = "Klicken für eine neue Route, oder einen Wegpunkt zum Weiterzeichnen.",
        ["Wheel changes falloff (%.1fm), live. Release to drop."] = "Rad ändert Abnahme (%.1fm), live. Zum Ablegen loslassen.",
        ["Drag the highlighted waypoint."] = "Den markierten Wegpunkt ziehen.",
        ["Point at a waypoint, then drag it."] = "Auf einen Wegpunkt zeigen, dann ziehen.",
        ["Right-click deletes the %d selected. Esc clears the selection."] = "Rechtsklick löscht die %d ausgewählten. Esc hebt die Auswahl auf.",
        ["Click a run to delete all of it, out to the junctions at each end."] = "Eine Route anklicken, um sie ganz zu löschen, bis zu den Kreuzungen an beiden Enden.",
        ["Click to delete the highlighted one."] = "Klicken, um den markierten zu löschen.",
        ["Point at a waypoint to delete it."] = "Auf einen Wegpunkt zeigen, um ihn zu löschen.",
        ["Wheel sets max spacing (%.1fm). Curves stay denser."] = "Rad setzt max. Abstand (%.1fm). Kurven bleiben dichter.",
        ["Wheel sets strength (%d). Right-click applies it."] = "Rad setzt Stärke (%d). Rechtsklick wendet an.",
        ["Click the far end of the span."] = "Das andere Ende des Abschnitts anklicken.",
        ["Click one end of the span."] = "Ein Ende des Abschnitts anklicken.",
        -- span pick, shared by every span tool card (2026-11-03)
        ["right-click applies - Esc goes back"] = "Rechtsklick wendet an - Esc geht zurück",
        ["click other end, then its new spot"] = "anderes Ende, dann neue Stelle klicken",
        ["Click a run to take all of it."] = "Eine Route anklicken, um sie ganz zu nehmen.",
        ["A click takes the run through that point instead."] = "Ein Klick nimmt stattdessen die Route durch diesen Punkt.",
        ["A click moves the nearer end there, along the track."] = "Ein Klick versetzt das nähere Ende dorthin, entlang der Spur.",
        ["A click on your own track moves the nearer end there."] = "Ein Klick auf der eigenen Spur versetzt das nähere Ende dorthin.",
        ["Right-click applies; Esc goes back to the menu."] = "Rechtsklick wendet an; Esc geht zurück zum Menü.",
        ["Esc goes back to the menu."] = "Esc geht zurück zum Menü.",
        ["Wheel sets distance (%.1fm %s). Flip the side on the panel. Right-click applies."] = "Rad setzt Abstand (%.1fm %s). Seite im Panel wechseln. Rechtsklick wendet an.",
        ["Drag any selected point to move the set."] = "Einen ausgewählten Punkt ziehen bewegt die Menge.",
        ["Drag any point of the run to move all of it."] = "Einen Punkt der Route ziehen bewegt sie ganz.",
        ["Drag any point of the span to move it."] = "Einen Punkt des Abschnitts ziehen bewegt ihn.",
        ["Click the other end for a span, or drag a point to move it."] = "Das andere Ende für einen Abschnitt anklicken, oder einen Punkt ziehen.",
        ["Drag a point to move it, or click two points for a span (double-click: run)."] = "Einen Punkt ziehen, oder zwei Punkte für einen Abschnitt anklicken (Doppelklick: Route).",
        ["Drag a point to move it."] = "Einen Punkt ziehen, um ihn zu bewegen.",
        ["Click a run to pick all of it, or drag a point."] = "Eine Route anklicken, um sie ganz zu wählen, oder einen Punkt ziehen.",
        ["more clicks move the last end set"] = "weitere Klicks versetzen das letzte Ende",
        ["or select points (box, Ctrl-click)"] = "oder Punkte auswählen (Rahmen, Strg-Klick)",
        ["Click one end of the span, or double-click for the whole run."] = "Ein Ende des Abschnitts anklicken, oder doppelklicken für die ganze Route.",
        ["Or select points (box, circle, Ctrl-click)."] = "Oder Punkte auswählen (Rahmen, Kreis, Strg-Klick).",
        ["Click the other end. The span follows the track, round a loop too."] = "Das andere Ende anklicken. Der Abschnitt folgt der Spur, auch um eine Schleife.",
        ["Stay on the SAME track."] = "Auf DERSELBEN Spur bleiben.",
        ["End picked up: click where it should go."] = "Ende aufgenommen: dorthin klicken, wo es hin soll.",
        ["Clicks on your own track move the last end set. Click the other end to move that one."] = "Klicks auf der eigenen Spur versetzen das letzte Ende. Das andere Ende anklicken, um jenes zu versetzen.",
        ["More clicks move the last end set, round loops too. Click the other end to move that one."] = "Weitere Klicks versetzen das letzte Ende, auch um Schleifen. Das andere Ende anklicken, um jenes zu versetzen.",
        ["Click a waypoint to name it."] = "Einen Wegpunkt anklicken, um ihn zu benennen.",
        ["Wheel adjusts the curve. Right-click places it."] = "Rad passt die Kurve an. Rechtsklick platziert sie.",
        ["Click the waypoint to curve to."] = "Den Wegpunkt anklicken, zu dem die Kurve führt.",
        ["Click the waypoint to curve from."] = "Den Wegpunkt anklicken, von dem die Kurve ausgeht.",
        ["Click to add a point (on the line it goes in between), drag one to move it, Ctrl-click one to remove it. Hold Alt to place without snapping. Right-click lays it."] = "Klicken fügt einen Punkt hinzu (auf der Linie wird er dazwischen eingefügt), Ziehen verschiebt ihn, Strg-Klick entfernt ihn. Alt halten setzt ohne Einrasten. Rechtsklick legt die Kurve.",
        ["Click the next point. On a waypoint it joins the road there; hold Alt to place without snapping."] = "Den nächsten Punkt anklicken. Auf einem Wegpunkt schließt die Kurve dort an die Straße an; Alt halten setzt ohne Einrasten.",
        ["Click the first point - on a waypoint to start from the road, or on the ground. Hold Alt to place without snapping."] = "Den ersten Punkt anklicken - auf einem Wegpunkt, um an der Straße zu beginnen, oder auf dem Boden. Alt halten setzt ohne Einrasten.",
        ["Waypoints can only be placed on the server (host/singleplayer)."] = "Wegpunkte können nur auf dem Server gesetzt werden (Host/Einzelspieler).",
        ["The spline starts and ends on the same waypoint."] = "Der Spline beginnt und endet auf demselben Wegpunkt.",
        ["Click inside a field to ring it. Uses the field loop settings."] = "In ein Feld klicken, um es zu umranden. Nutzt die Feldschleifen-Einstellungen.",
        ["Will not fit here. See the log for why."] = "Passt hier nicht. Grund siehe Log.",
        ["Wheel sets length (%.0fm, %s side). Flip the side on the panel. Right-click applies."] = "Rad setzt Länge (%.0fm, Seite %s). Seite im Panel wechseln. Rechtsklick wendet an.",
        ["Click where the siding should sit - the click is its centre."] = "Klicken, wo die Ausweiche liegen soll – der Klick ist ihre Mitte.",
        ["Too tight to offset that far. Wheel it back, or swap sides."] = "Zu eng für diesen Versatz. Zurückdrehen oder Seite wechseln.",
        ["Wheel sets offset (%.1fm %s). Flip the side on the panel. Right-click applies."] = "Rad setzt Versatz (%.1fm %s). Seite im Panel wechseln. Rechtsklick wendet an.",
        ["Click a run to offset the whole thing, junction to junction."] = "Eine Route anklicken, um sie ganz zu versetzen, Kreuzung zu Kreuzung.",
        ["Click one end of a span to run a track alongside it."] = "Ein Ende eines Abschnitts anklicken, um eine Spur daneben zu legen.",
        ["Nothing over %.1fm off the ground. Wheel the tolerance down to see more."] = "Nichts über %.1fm über dem Boden. Toleranz herunterdrehen für mehr.",
        ["%d of %d waypoint(s) off the ground. Right-click re-seats them."] = "%d von %d Wegpunkt(en) über dem Boden. Rechtsklick setzt sie auf.",
        ["Click a run to check the whole thing for waypoints off the ground."] = "Eine Route anklicken, um sie ganz auf Wegpunkte über dem Boden zu prüfen.",
        ["Click one end of a span to find waypoints off the ground."] = "Ein Ende eines Abschnitts anklicken, um Wegpunkte über dem Boden zu finden.",
        ["Wheel sets tolerance (%.2fm). Right-click straightens the span."] = "Rad setzt Toleranz (%.2fm). Rechtsklick begradigt den Abschnitt.",
        ["Click one end of a span to straighten it."] = "Ein Ende eines Abschnitts anklicken, um ihn zu begradigen.",
        ["Wheel sets the count (%d). Right-click applies it."] = "Rad setzt die Anzahl (%d). Rechtsklick wendet an.",
        ["Click one end of the span to divide."] = "Ein Ende des Abschnitts anklicken zum Unterteilen.",
        ["Click to make it %s (%s)."] = "Klicken, um es %s zu machen (%s).",
        ["whole run"] = "ganze Route",
        ["this waypoint"] = "dieser Wegpunkt",
        ["Green marks what would be absorbed. Click a point on the OTHER track."] = "Grün zeigt, was aufgenommen würde. Einen Punkt auf der ANDEREN Spur anklicken.",
        ["Click the far end of the span, on the SAME track."] = "Das andere Ende des Abschnitts anklicken, auf DERSELBEN Spur.",
        ["Click one end of the span to merge."] = "Ein Ende des Abschnitts zum Zusammenführen anklicken.",

        -- junction tool: NEXT guidance
        ["Site locked: %d new, %d rebuilt. Right-click places; left-click moves the lock."] = "Ort gesperrt: %d neu, %d neu gebaut. Rechtsklick platziert; Linksklick versetzt die Sperre.",
        ["Site locked: %d new turn(s). Right-click places; left-click moves the lock."] = "Ort gesperrt: %d neue Abbiegung(en). Rechtsklick platziert; Linksklick versetzt die Sperre.",
        ["Site locked, nothing new to place. Right-click unlocks; left-click moves the lock."] = "Ort gesperrt, nichts Neues zu platzieren. Rechtsklick entsperrt; Linksklick versetzt die Sperre.",
        ["%d turn(s) to lay here. Left-click locks the site."] = "%d Abbiegung(en) hier zu verlegen. Linksklick sperrt den Ort.",
        ["Point at a crossing and left-click to lock it. Right-click leaves the tool."] = "Auf eine Kreuzung zeigen und mit Linksklick sperren. Rechtsklick legt das Werkzeug weg.",

        -- junction tool: NEXT guidance (clear mode)
        ["Site locked: will clear %d point(s). Right-click clears; left-click moves the lock."] = "Ort gesperrt: %d Punkt(e) werden entfernt. Rechtsklick entfernt; Linksklick versetzt die Sperre.",
        ["Site locked, nothing here to clear. Right-click unlocks; left-click moves the lock."] = "Ort gesperrt, nichts zu entfernen. Rechtsklick entsperrt; Linksklick versetzt die Sperre.",
        ["%d point(s) to clear here. Left-click locks the site."] = "%d Punkt(e) hier zu entfernen. Linksklick sperrt den Ort.",
        ["Site locked: one shared point of farm tracks, %d track(s) to cut off it. Right-click clears; left-click moves the lock."] = "Ort gesperrt: ein gemeinsamer Punkt von Feldwegen, %d Weg(e) werden davon getrennt. Rechtsklick entfernt; Linksklick versetzt die Sperre.",
        ["One shared point of farm tracks here. Left-click locks the site."] = "Hier treffen sich Feldwege in einem Punkt. Linksklick sperrt den Ort.",
        ["Point at a junction and left-click to lock it. Right-click leaves the tool."] = "Auf eine Kreuzung zeigen und mit Linksklick sperren. Rechtsklick legt das Werkzeug weg.",
        ["Site locked. Right-click clears and builds; left-click moves the lock."] = "Ort gesperrt. Rechtsklick entfernt und baut; Linksklick versetzt die Sperre.",
        ["Left-click locks this junction; right-click then clears and builds it."] = "Linksklick sperrt diese Kreuzung; Rechtsklick entfernt und baut sie dann.",
        ["Site locked: right-click lays the %s %s; left-click moves the lock."] = "Ort gesperrt: Rechtsklick legt das Muster (%s %s); Linksklick versetzt die Sperre.",
        ["Site locked: the pattern won't fit, so right-click builds nothing. Left-click moves the lock."] = "Ort gesperrt: das Muster passt nicht, Rechtsklick baut nichts. Linksklick versetzt die Sperre.",

        -- junction tool: card labels and values
        ["action"] = "Aktion",
        ["build"] = "bauen",
        ["clear"] = "entfernen",
        ["leave through paths"] = "Durchfahrten belassen",
        -- the short card (doc 12)
        ["clear + build"] = "entfernen + bauen",
        ["through roads"] = "Durchfahrten",
        ["kept"] = "belassen",
        ["cleared"] = "entfernt",
        ["shape"] = "Form",
        ["mod"] = "Mod",
        ["type"] = "Art",
        ["state"] = "Zustand",
        ["will do"] = "macht",
        ["then"] = "danach",
        ["nothing to clear"] = "nichts zu entfernen",
        ["nothing to clear here"] = "hier ist nichts zu entfernen",
        ["nothing - no pattern fits"] = "nichts - kein Muster passt",
        ["lock it to see if the pattern fits"] = "sperren, um zu sehen, ob das Muster passt",
        ["turns"] = "Abbieger",
        ["refused"] = "abgelehnt",
        ["advanced says why"] = "Erweitert sagt warum",
        ["advanced"] = "erweitert",
        ["show"] = "zeigen",
        ["hide"] = "verbergen",
        ["pattern won't fit"] = "Muster passt nicht",
        ["turn by turn"] = "einzeln",
        ["refuse"] = "ablehnen",
        ["last clear"] = "zuletzt entfernt",
        ["last build"] = "zuletzt gebaut",
        ["no junction here"] = "hier keine Kreuzung",
        ["no box here"] = "hier keine Box",
        ["debug capture"] = "Fehlersuche-Aufzeichnung",
        ["approaches found"] = "Zufahrten gefunden",
        ["will clear"] = "wird entfernt",
        ["through points kept"] = "Durchfahrtspunkte belassen",
        ["tidy lane ends to"] = "Fahrbahnenden bis",
        ["lane ends to box edge"] = "Fahrbahnenden an Boxkante",
        ["point at a junction"] = "auf eine Kreuzung zeigen",
        ["numbered once it is built"] = "bekommt eine Nummer, sobald sie gebaut ist",
        ["search radius"] = "Suchradius",
        ["turn radius"] = "Wenderadius",
        ["road check"] = "Straßenprüfung",
        ["off (radius only)"] = "aus (nur Radius)",
        ["trim/extend"] = "Kürzen/Verlängern",
        ["off (clamp at trim)"] = "aus (am Ende stoppen)",
        ["existing turns"] = "Bestehende",
        ["keep"] = "behalten",
        ["rebuild"] = "neu bauen",
        ["curve"] = "Kurve",
        ["obstacles"] = "Hindernisse",
        ["swept path"] = "Schleppkurve",
        ["small rig"] = "kleines Gespann",
        ["big rig"] = "großes Gespann",
        ["semi"] = "Sattelzug",
        ["measured rig"] = "gemessenes Gespann",
        ["must fit"] = "muss passen",
        ["junction numbers"] = "Kreuzungsnummern",
        ["not checked"] = "nicht geprüft",
        ["fit"] = "passen",
        ["trailer cut-in"] = "Anhänger schneidet",
        ["trailer past corridor"] = "Anhänger außerhalb Korridor",
        ["corridor"] = "Korridor",
        ["clearance"] = "Freiraum",
        ["approaches"] = "Zufahrten",
        ["new movements"] = "neue Abbiegungen",
        ["rebuilt existing"] = "neu gebaut",
        ["old points to clear"] = "alte Punkte entfernt",
        ["radius used"] = "genutzter Radius",
        ["too tight (refused)"] = "zu eng (abgelehnt)",
        ["off road (refused)"] = "neben der Straße (abgelehnt)",
        ["no joinable curve"] = "keine Kurve möglich",
        ["skipped as U-turn"] = "als Wende übersprungen",
        ["too far apart"] = "zu weit auseinander",
        ["redundant lane"] = "doppelte Spur",
        ["blocked (refused)"] = "blockiert (abgelehnt)",
        ["laid wide"] = "weit ausgeholt",
        ["rig off road (refused)"] = "Gespann neben der Straße (abgelehnt)",
        ["rig hits obstacle (refused)"] = "Gespann trifft Hindernis (abgelehnt)",
        ["already there"] = "bereits vorhanden",
        ["confidence"] = "Konfidenz",
        ["point at a crossing"] = "auf eine Kreuzung zeigen",
    },
}

-- Tool one-line summaries, keyed by the tool key (ADFlyoverHelp.ORDER). Kept as ONE string and wrapped
-- to the panel at render, because German wraps differently from the English lines make_help.py bakes.
L.SUMMARIES = {
    de = {
        ["select"] = "Der Standardmodus. Dinge anklicken, um sie zu bearbeiten; kein Werkzeug aktiv.",
        ["draw"] = "Wegpunkte setzen und zu einer Route verbinden.",
        ["spline"] = "Eine glatte Kurve durch beliebig viele Punkte zeichnen.",
        ["field loop"] = "Eine befahrbare Schleife um das Feld unter dem Cursor erzeugen.",
        ["parallel"] = "Eine Spur parallel zu einem Abschnitt oder einer Route anlegen.",
        ["siding"] = "Ein paralleler Abzweig, der an beiden Enden wieder einschwenkt.",
        ["road runs"] = "AutoDrive-Routen entlang Kartenstraßen und Feldwegen ohne Pfad legen und gebaute Straßen umformen.",
        ["move"] = "Einen Punkt, Abschnitt, eine Route oder Auswahl ziehen - verschieben, kopieren, lostrennen oder seitlich schieben.",
        ["smooth"] = "Das Zittern in einem Abschnitt oder einer Route abrunden.",
        ["straighten"] = "Das Rauschen aus einem Abschnitt glätten, echte Kurven bleiben erhalten.",
        ["divide"] = "Gleichmäßig verteilte Punkte entlang eines Abschnitts einfügen.",
        ["ground"] = "Punkte wieder auf die Oberfläche unter ihnen aufsetzen.",
        ["convert"] = "Einbahn / beidseitig und Priorität ändern.",
        ["merge"] = "Zwei parallele Spuren zu einer gemeinsamen Spur zusammenführen.",
        ["junction"] = "Die Abbieger einer Kreuzung entfernen, neue legen oder beides mit einem Rechtsklick.",
        ["name"] = "Einem Wegpunkt einen Kartenmarker-Namen geben.",
        ["delete"] = "Einen Punkt, eine Route oder eine Auswahl entfernen.",
    },
}

-- Full-manual prose (the WHAT / HOW / CONTROLS of each tool), keyed by tool key. Stored UNWRAPPED - one
-- string per paragraph (what), per bullet (how) or per control line (controls) - and wrapped to the
-- page at render (L.helpSection), because German wraps differently from the English lines make_help.py
-- bakes. English stays the source of truth in Help.lua; this only adds the German.
L.HELP = {
    de = {
        ["select"] = {
            what = {
                "Im Auswahlmodus wirkst du auf das Vorhandene ein. Ein Klick aufs Netz öffnet ein kleines Popup mit Aktionen für das Angeklickte - einen Punkt, einen Abschnitt oder eine ganze Route - und eine Auswahl öffnet eines für die ganze Menge, sodass die meisten Änderungen gar kein Werkzeug brauchen. Das Popup öffnet sich neben dem, worauf es wirkt, und lässt sich an seiner Kopfzeile ziehen.",
            },
            how = {
                "Einen Wegpunkt anklicken: sein PUNKT-Popup (benennen, verschieben, verbinden, Spline, ein-/beidseitig, primär/sekundär, löschen).",
                "Einen zweiten Punkt anklicken: der ABSCHNITT dazwischen. Doppelklick auf einen Punkt: die ganze ROUTE.",
                "Alt+Ziehen für ein Kästchen, Umschalt+Ziehen für einen Kreis, Alt+Umschalt+Ziehen freihand, Leertaste+Ziehen+Klick für ein gedrehtes Kästchen, oder Punkte einzeln mit Strg anklicken: eine AUSWAHL, deren Popup auf die ganze Menge wirkt. Ein normaler Klick und danach Strg-Klicks behalten den ersten Punkt; bleibt ein Punkt übrig, ist er wieder ein Punkt.",
                "Ein Werkzeug aus einem Popup öffnet seine Karte dort, wo das Popup war; Esc geht zurück zum Popup. Bei Begradigen, Glätten, Unterteilen, Aufsetzen und Parallele wendet Rechtsklick an.",
                "Esc schließt das Popup und hebt eine Auswahl auf; Rechtsklick schließt nur das Popup.",
            },
            controls = {
                "Punkt-Popup: benennen, verschieben, verbinden, Spline, einseitig oder beidseitig machen, primär oder sekundär machen, Punkt löschen.",
                "Abschnitt-/Routen-Popup: verschieben, begradigen, glätten, unterteilen, aufsetzen (+ Parallele bei einer Route), einseitig oder beidseitig machen, Richtung umkehren, primär oder sekundär machen, löschen.",
                "Auswahl-Popup: verschieben, aufheben, einseitig oder beidseitig machen, Richtung umkehren, primär oder sekundär machen, Auswahl löschen. Umwandlungen betreffen nur Verbindungen ZWISCHEN ausgewählten Punkten.",
                "Umwandlungs-Knöpfe: jeder bietet das Gegenteil des jetzigen Zustands und wechselt nach dem Klick; bei gemischtem Zustand beide. Ohne Verbindungen untereinander gibt es keine Richtungs-Knöpfe. Bei Punkt oder Abschnitt folgt einseitig der Straße hinter den Enden.",
            },
        },
        ["draw"] = {
            what = {
                "Zeichnen setzt neue Wegpunkte Klick für Klick und verbindet jeden mit dem letzten, sodass eine Route mitwächst. Es ist der grundlegende Weg, um Strecke zu bauen, die nicht aus einer vorhandenen Form abgeleitet ist.",
            },
            how = {
                "Auf leeren Boden klicken, um einen Wegpunkt zu setzen; jeder neue verbindet sich mit dem vorigen.",
                "Auf einen vorhandenen Wegpunkt klicken, um VON ihm aus zu zeichnen und die neue Route ins Netz einzubinden. Bei laufender Route verbindet ein Klick auf einen Wegpunkt mit ihm - oder nimmt die Verbindung weg, wenn schon eine besteht.",
                "Rechtsklick beendet die aktuelle Route, der nächste Klick beginnt eine neue.",
            },
            controls = {
                "Verkehr: einseitig, beidseitig oder Rückwärtsweg (im Rückwärtsgang befahren).",
                "Priorität: primär oder sekundär (sekundär erscheint als Vorfahrt-gewähren-Straße).",
                "einrasten auf: Oberfläche oder Gelände - worauf die neuen Punkte liegen.",
            },
        },
        ["spline"] = {
            what = {
                "Spline legt eine glatte Kurve, die durch jeden angeklickten Punkt läuft - für weite Bögen, denen ein Fahrzeug zügig folgen kann. Eine Live-Vorschau zeigt die Kurve und die Wegpunkte, die sie legt, bevor du sie festlegst. Ein Ende auf einem Wegpunkt schließt dort an die Straße an und folgt ihrer Richtung; ein Ende auf freiem Boden bekommt einen neuen Wegpunkt. Steht Aktion auf \"edit placed\", nimmt ein Klick auf eine schon gelegte Route sie genauso zum Umformen auf.",
            },
            how = {
                "Punkte der Reihe nach anklicken - auf dem Boden, oder direkt auf einem Wegpunkt, um dort an die Straße anzuschließen. Die zwei Enden reichen weiter: der erste Klick schließt an einen Wegpunkt in etwa 1,5 m an (zuerst an ein Spurende), und beim Rechtsklick rückt ein letzter Punkt so nah an einem Wegpunkt auf ihn und schließt an - nie an den eigenen Anfang des Splines. Mittlere Punkte rasten nur direkt auf einem Wegpunkt ein. Alt halten setzt einen Punkt ohne Einrasten. Eine Markierung unter der Maus zeigt, was ein Klick tut: gelb schließt an einen Wegpunkt an, weiß ist freier Boden, grün fügt in die Linie ein.",
                "Auf die Kurve klicken fügt dort einen Punkt in die Linie ein. Einen Punkt ziehen, um ihn zu verschieben. Strg-Klick auf einen Punkt entfernt ihn.",
                "Rechtsklick legt die Kurve als ein Rückgängig-Schritt; Esc verwirft sie.",
                "Um eine schon gelegte Route umzuformen, Aktion auf \"edit placed\" stellen und die Route anklicken: ihre Form wird zu Punkten zum Ziehen, Hinzufügen (auf die Kurve klicken) oder Entfernen (Strg-Klick). Ihre zwei Enden bleiben, weil dort andere Straßen anschließen. Rechtsklick legt sie neu und behält Richtung, ein-/beidseitig und Priorität; ein Rückgängig nimmt es zurück.",
            },
            controls = {
                "Aktion: \"new\" legt einen neuen Spline; \"edit placed\" formt eine schon gelegte Route um (das Stück zwischen zwei Kreuzungen).",
                "Kurve per: Mehrpunkt ist diese Kurve; AutoDrive ist der alte Zwei-Punkt-Spline (zwei Wegpunkte anklicken, Rad für die Krümmung).",
                "Abstand: wie weit die gelegten Wegpunkte auseinander liegen, in Metern.",
                "Start-/End-Richtung: umkehren, in welche Richtung entlang der Straße ein angeschlossenes Ende abgeht oder ankommt.",
                "Verkehr/Priorität: wie bei Zeichnen - ein-/beidseitig oder Rückwärtsweg und primär/sekundär.",
            },
        },
        ["field loop"] = {
            what = {
                "Feldschleife baut eine vollständige Route (beidseitig und sekundär, wenn die Karte nichts anderes sagt), die knapp außerhalb der Feldgrenze verläuft, auf einen Wenderadius geglättet und um Bäume herum nach innen versetzt. Sie bleibt auf der Feldseite eines Zauns (innerhalb der Feldgrenze, wo der Zaun dort steht) und zieht ihren Rand ein, um Abstand zu einer anderen Feldschleife daneben zu halten. Es ist eine eigenständige Schleife - keine Kartenmarker, nicht mit dem übrigen Netz verbunden - die du danach mit Zeichnen oder dem Editor einbindest.",
            },
            how = {
                "In das Feld klicken, das umrundet werden soll. Es liest die Feldgrenze und legt die Schleife sofort.",
                "Die Schleife danach in dein Netz einbinden, falls du sie verbunden brauchst.",
            },
            controls = {
                "Priorität: primär oder sekundär (Standard).",
                "Spur: im Uhrzeigersinn, gegen den Uhrzeigersinn oder beidseitig (Standard).",
                "Rand: wie weit außerhalb der Grenze die Schleife läuft.",
                "Hindernisabstand: wie weit die Schleife von Bäumen, Masten, Zäunen und Gebäuden bleibt, bevor sie ausweicht.",
                "Wenderadius: die engste Kurve, die die Schleife machen darf, von 2 m bis 20 m. Sehr kleine Werte können eine spitze Feldecke wie einen Knick aussehen lassen.",
                "Fahrzeughöhe: für wie hohe Maschine die Baumprüfung frei hält.",
                "eigenes Feld erkennen: standardmäßig an; findet auch Boden, der gepflügt wurde, um zwei getrennte Kartenfelder zu einem zu verbinden, nicht nur ein Feld der Karte. Ausschalten, um nur die Felder der Karte zu nehmen, falls es ein Feld in deinem Spielstand falsch liest.",
                "Courseplay-Feld: nur zu sehen, wenn Courseplay installiert ist. Standardmäßig an; steht der Cursor in einem deiner eigenen Courseplay-Felder, folgt die Schleife diesem Umriss. Die Karte zeigt, welche Grenze die letzte Schleife genommen hat.",
                "Hindernisse meiden: standardmäßig an; schiebt die Schleife von Bäumen, Masten, Zäunen und Gebäuden weg, statt sie gerade hindurchzulegen. Ausschalten, um die versetzte Grenze so zu nehmen, wie sie liegt, falls die Prüfung etwas meldet, das nicht wirklich im Weg ist.",
                "Inseln auslassen: standardmäßig an; eine Karte kann eine Gruppe Masten oder Bäume mit einem Schlitz im Umriss aus einem Feld schneiden. Die Schleife läuft dann um das Feld, nicht in jede Insel. Ausschalten, um dem Umriss so zu folgen, wie die Karte ihn zeichnet.",
                "Kombi-Lücke: wie weit nach einem anderen, getrennten Stück desselben Felds gesucht wird, wenn ein Weg es teilt, um es in dieselbe Schleife zu nehmen. 0 (Standard) verlässt nie das angeklickte Feld. Nur für ein von einem Weg geteiltes Feld erhöhen; senken, falls es je über eine echte Straße in ein fremdes Feld greift. Zwei Felder, die sich ohne Lücke berühren, gelten weiter als ein Feld.",
            },
        },
        ["parallel"] = {
            what = {
                "Parallele kopiert einen Abschnitt oder eine Route um einen festen Abstand seitlich als zweite Spur daneben - eine Überholspur oder ein Rückweg.",
            },
            how = {
                "Den Abschnitt wie gewohnt wählen: ein Ende und dann das andere anklicken für einen ABSCHNITT, oder doppelklicken für die ganze ROUTE zwischen Kreuzungen. Auf einer Schleife nehmen zwei Klicks den kürzeren Weg.",
                "Hinter das ferne Ende klicken, um es weiterzuführen; es folgt der Spur, auch um eine Schleife. Der erste Klick bleibt stehen: ihn anklicken, dann dorthin, wo er hin soll, um ihn zu versetzen. Nach einer per Doppelklick gewählten Route versetzt ein Klick das nähere Ende.",
                "Die Zeile \"Auswahl\" zeigt, was gewählt ist; einen Typ anklicken sperrt ihn (die anderen werden blass), erneut anklicken hebt die Sperre auf.",
                "Zwei Punkte, die nur über einen langen Umweg verbunden sind (an einer Kreuzung weg von der Spur und zurück), werden abgelehnt.",
                "Die Seite folgt dem Cursor beim Wählen; auf der Karte änderbar.",
                "Abstand setzen (tippen, Stepper oder Rad), dann Rechtsklick zum Legen.",
            },
            controls = {
                "Seite: bei einer Einbahnspur links / rechts in Fahrtrichtung; bei einer beidseitigen Spur links / rechts oder oben / unten, wie sie auf dem Bildschirm liegt - die Wörter folgen der Kamera.",
                "Fahrtrichtung: neben einer Einbahnstraße fährt die neue Spur in GLEICHER Richtung oder GEGENRICHTUNG als Rückweg. Bei beidseitigen Straßen ausgegraut.",
                "Auswahl: Abschnitt / Route - was gewählt ist; anklicken sperrt den Typ.",
                "Abstand: wie weit seitlich die neue Spur liegt.",
            },
        },
        ["siding"] = {
            what = {
                "Ausweiche legt ein kurzes paralleles Stück neben eine Route und führt es an beiden Enden per Kurve zurück - wie eine Haltebucht oder Ausweichstelle, in einem Schritt.",
            },
            how = {
                "Einen Wegpunkt auf der Route anklicken, wo die Ausweiche liegen soll - der Klick ist ihre Mitte (sie rutscht weiter, wenn sie zu nah an einem Ende liegt), die Seite folgt dem Cursor.",
                "Versatz und Länge setzen (das Rad ändert die Länge), dann Rechtsklick zum Legen.",
            },
            controls = {
                "Seite: wie bei Parallele - links / rechts in Fahrtrichtung bei einer Einbahnspur, nach Bildschirm bei einer beidseitigen.",
                "Versatz: wie weit seitlich die Ausweiche liegt.",
                "Länge (Rad): wie lang das parallele Stück ist.",
            },
        },
        -- The road runs card is still English, so its labels stay English here (2026-11-04).
        ["road runs"] = {
            what = {
                "Road runs liest die Bodenfarbe um die Maus - Asphalt und Beton, Schotter, Feldwege - und hebt die Straßen hervor, die noch keinen AutoDrive-Pfad haben. Ein Klick folgt der Straße weiter durch Kreuzungen, wo sie geradeaus geht, und hält an T-Kreuzungen, echten Enden und vorhandenen Pfaden. Es legt die Spuren, die du wählst: einseitig, eine beidseitige Linie oder zwei Spuren mit Rechtsverkehr. An Gabelungen hält es vorher an, damit das Kreuzungswerkzeug sie fertig baut; ein Feldweg, der auf eine Straße trifft, läuft bis an den Asphalt. Brücken und Rampen werden aus den Straßenmodellen des Spiels gefunden. Eine schon gebaute Straße lässt sich mit Griffen umformen, auch durch ihre Kreuzungen, und die Straßen, die an sie anschließen, folgen.",
            },
            how = {
                "Auf eine Straße zeigen: sie leuchtet auf, mit ihren Spuren in der Vorschau. Klicken wählt sie; Doppelklick führt sie weiter durch Gabelungen.",
                "Für eine Einbahn-Route auf die Seite der Straße klicken, auf der du fahren würdest (rechts).",
                "Eine Wahl anklicken, um sie auszuwählen: einen Griff ziehen formt sie um, auf die Linie klicken fügt einen Griff hinzu, Strg-Klick auf einen Griff entfernt ihn (eine Route behält zwei). Ein Ende, das auf einen Wegpunkt gezogen wird, schließt dort an (Alt halten: ohne Einrasten).",
                "Rechtsklick baut alles Gewählte. Ein Rückgängig nimmt alles zurück.",
                "Eine schon gebaute Straße anklicken, um sie genauso umzuformen. Eine Straße mit zwei Spuren wird an ihrer Mitte geformt, beide Spuren zusammen. Kreuzungspunkte bewegen sich mit; kurze Abbieger biegen sich, und Seitenstraßen gleiten zurück an ihren Platz. Rechtsklick wendet an, als ein Rückgängig-Schritt.",
            },
            controls = {
                "lay as: auto (zwei Spuren auf befestigten Straßen, eine beidseitige Linie auf Feldwegen), einseitig, beidseitig oder zwei Spuren.",
                "Priorität: primär oder sekundär, wie bei Zeichnen.",
                "roads to find: befestigt, Schotter und Erde - eine Art ausschalten, damit sie nicht mehr aufleuchtet.",
                "lane gap: from road misst nach der Straßenbreite; set: eigenen Wert eintippen.",
                "through junctions: beim Umformen einer gebauten Straße die Auswahl durch ihre Kreuzungen weiterführen (an) oder nur die Route zwischen zwei Kreuzungen nehmen (aus).",
                "Einstellungsdialog: light up (under mouse oder all nearby), side check (bridges oder everywhere), rig width (3,0 m) und fork gap (7,5 m).",
            },
        },
        ["move"] = {
            what = {
                "Verschieben zieht Wegpunkte an eine neue Stelle und setzt sie dort auf den echten Boden. Ein KLICK wählt, was sich bewegt (Punkt, Abschnitt, Route), ein ZIEHEN bewegt es - dieselben Gesten wie überall. Abfall bestimmt, ob die Bewegung sanft ausläuft oder als starres Stück geht. Kopieren lässt die Originale stehen und bewegt eine neue Kopie; Trennen schneidet das bewegte Stück los. Die Aktion VERSATZ schiebt einen Abschnitt oder eine Route seitlich an Ort und Stelle.",
            },
            how = {
                "Einen Punkt drücken und ziehen, um ihn zu bewegen; loslassen setzt ihn ab.",
                "Klicken (ohne Ziehen) wählt stattdessen: einen Punkt; ein zweiter Punkt für den ABSCHNITT dazwischen; Doppelklick für die ganze ROUTE. Dann einen beliebigen Punkt der Wahl ziehen, um alles zu bewegen. Ein Punkt außerhalb der Wahl bewegt nur sich selbst.",
                "Hinter das ferne Ende eines Abschnitts klicken führt es weiter, auch um eine Schleife. Der erste Klick bleibt stehen: ihn anklicken, dann dorthin, wo er hin soll, um ihn zu versetzen. Nach einer per Doppelklick gewählten Route versetzt ein Klick das nähere Ende.",
                "Die Zeile \"Auswahl\" zeigt, was gewählt ist. Einen Typ anklicken sperrt ihn: Route bewegt die ganze Route mit einem Griff, Punkt baut nie Abschnitte. Erneut anklicken hebt die Sperre auf.",
                "Eine Auswahl (Kästchen, Kreis, freihand, gedrehtes Kästchen, Strg-Klick) hat Vorrang: einen ausgewählten Punkt greifen bewegt die Menge. Eine zusammenhängende Route gilt als Abschnitt; eine verstreute Menge bewegt sich starr.",
                "Abfall: bei einem einzelnen Punkt reicht er um den Abfallwert entlang der Strecke (Rad, Stepper, tippen oder , und .). Bei Abschnitt, Route oder routenförmiger Auswahl läuft er vom gegriffenen Punkt bis auf null an deren Enden aus - ohne Wert.",
                "Kopieren (B): vor dem Greifen an, ziehst du eine neue Kopie heraus und das Original bleibt; unterwegs eingeschaltet, springt das Original sofort zurück und die Kopie läuft weiter; direkt nach dem Absetzen eingeschaltet, wird diese Bewegung zur Kopie.",
                "Aktion VERSATZ (Abschnitt oder Route gewählt): der Abstand des Cursors zur Kette schiebt sie seitlich; loslassen, mit Rad oder Wert fein einstellen, Rechtsklick zum Abschließen. Kopieren und Trennen wirken auch hier.",
                "R halten und beim Ziehen scrollen dreht das Bewegte um den gegriffenen Punkt oder den Schwerpunkt.",
                "Was nicht passt, ist ausgegraut: Abfall und Trennen schließen sich aus, ebenso Versatz-Abfall und Trennen, und Trennen ist grau, wenn nichts mit dem Stück verbunden ist.",
            },
            controls = {
                "Auswahl: Punkt / Abschnitt / Route - zeigt, was ein Klick gewählt hat, und sperrt den Typ.",
                "Aktion: verschieben (frei ziehen) oder Versatz (seitlich schieben; braucht Abschnitt oder Route).",
                "Abfall: auslaufend oder starr. Die Reichweite eines Punkts ist der Abfallwert.",
                "Auto-Verbinden: beim Absetzen wird ein loses Ende mit dem Nächstgelegenen verbunden.",
                "Kopieren (B) / Trennen: eine Kopie lassen / das bewegte Stück losschneiden.",
                "Versatz-Abfall: (Versatz) lässt das Schieben zu den Enden hin auslaufen.",
                "Drehpunkt: Klickpunkt oder Schwerpunkt, für R+Rad.",
                "einrasten auf: Gelände oder Oberfläche für die abgesetzten Punkte.",
            },
        },
        ["smooth"] = {
            what = {
                "Glätten nimmt die kleinen Knicke aus einem Stück, damit eine gefahrene Strecke nicht ruckelt. Glätten (relax) zieht die vorhandenen Punkte in Linie (Kreuzungen und Marker bleiben); Neuaufbau legt das Stück genau entlang der gewählten Strecke neu: Punkte höchstens im max. Abstand, in Kurven dichter.",
            },
            how = {
                "Den Abschnitt wie gewohnt wählen: ein Ende und dann das andere anklicken für einen ABSCHNITT, oder doppelklicken für die ganze ROUTE zwischen Kreuzungen. Auf einer Schleife nehmen zwei Klicks den kürzeren Weg.",
                "Hinter das ferne Ende klicken, um es weiterzuführen; es folgt der Spur, auch um eine Schleife. Der erste Klick bleibt stehen: ihn anklicken, dann dorthin, wo er hin soll, um ihn zu versetzen. Nach einer per Doppelklick gewählten Route versetzt ein Klick das nähere Ende.",
                "Die Zeile \"Auswahl\" zeigt, was gewählt ist; einen Typ anklicken sperrt ihn (die anderen werden blass), erneut anklicken hebt die Sperre auf.",
                "Zwei Punkte, die nur über einen langen Umweg verbunden sind (an einer Kreuzung weg von der Spur und zurück), werden abgelehnt.",
                "Oder die Punkte einzeln mit Strg anklicken - sie müssen eine zusammenhängende Route bleiben; ein normaler Klick danach verwirft das und beginnt neu.",
                "Modus und Stärke / Abstand setzen, dann Rechtsklick zum Anwenden.",
            },
            controls = {
                "Modus: glätten (Punkte bewegen) oder Neuaufbau (neu verteilen).",
                "Stärke: wie stark das Glätten zieht.",
                "max. Abstand: größte Lücke beim Neuaufbau; in Kurven liegen die Punkte dichter.",
            },
        },
        ["straighten"] = {
            what = {
                "Begradigen entfernt ziellose Details, behält aber echte Kurven, und verteilt dann dieselbe Anzahl Punkte gleichmäßig auf der geraderen Linie. Kreuzungen, Marker und die Enden bleiben; jedes Stück dazwischen wird entlang der gewählten Strecke begradigt.",
            },
            how = {
                "Den Abschnitt wie gewohnt wählen: ein Ende und dann das andere anklicken für einen ABSCHNITT, oder doppelklicken für die ganze ROUTE zwischen Kreuzungen. Auf einer Schleife nehmen zwei Klicks den kürzeren Weg.",
                "Hinter das ferne Ende klicken, um es weiterzuführen; es folgt der Spur, auch um eine Schleife. Der erste Klick bleibt stehen: ihn anklicken, dann dorthin, wo er hin soll, um ihn zu versetzen. Nach einer per Doppelklick gewählten Route versetzt ein Klick das nähere Ende.",
                "Die Zeile \"Auswahl\" zeigt, was gewählt ist; einen Typ anklicken sperrt ihn (die anderen werden blass), erneut anklicken hebt die Sperre auf.",
                "Zwei Punkte, die nur über einen langen Umweg verbunden sind (an einer Kreuzung weg von der Spur und zurück), werden abgelehnt.",
                "Oder die Punkte einzeln mit Strg anklicken (eine zusammenhängende Route).",
                "Toleranz setzen - größer begradigt mehr - dann Rechtsklick zum Anwenden.",
            },
            controls = {
                "Toleranz: wie weit ein Schlenker von der Geraden abweichen darf und trotzdem geglättet wird.",
            },
        },
        ["divide"] = {
            what = {
                "Unterteilen verteilt eine gewählte Anzahl Wegpunkte gleichmäßig nach Abstand entlang eines Stücks, entlang der gewählten Strecke; Kreuzungen und Marker bleiben an ihrem Platz.",
            },
            how = {
                "Den Abschnitt wie gewohnt wählen: ein Ende und dann das andere anklicken für einen ABSCHNITT, oder doppelklicken für die ganze ROUTE zwischen Kreuzungen. Auf einer Schleife nehmen zwei Klicks den kürzeren Weg.",
                "Hinter das ferne Ende klicken, um es weiterzuführen; es folgt der Spur, auch um eine Schleife. Der erste Klick bleibt stehen: ihn anklicken, dann dorthin, wo er hin soll, um ihn zu versetzen. Nach einer per Doppelklick gewählten Route versetzt ein Klick das nähere Ende.",
                "Die Zeile \"Auswahl\" zeigt, was gewählt ist; einen Typ anklicken sperrt ihn (die anderen werden blass), erneut anklicken hebt die Sperre auf.",
                "Zwei Punkte, die nur über einen langen Umweg verbunden sind (an einer Kreuzung weg von der Spur und zurück), werden abgelehnt.",
                "Oder die Punkte einzeln mit Strg anklicken (eine zusammenhängende Route).",
                "Anzahl setzen, dann Rechtsklick zum Anwenden.",
            },
            controls = {
                "Punkte: wie viele Punkte zwischen den Enden (startet beim jetzigen Stand).",
            },
        },
        ["ground"] = {
            what = {
                "Aufsetzen senkt (oder hebt) Wegpunkte, die mehr als die Toleranz neben dem Boden liegen, und behebt schwebende oder vergrabene Punkte. Mit einrasten auf = Oberfläche bleibt ein Punkt, der schon auf einer gesetzten Rampe oder Brücke liegt, dort.",
            },
            how = {
                "Den Abschnitt wie gewohnt wählen: ein Ende und dann das andere anklicken für einen ABSCHNITT, oder doppelklicken für die ganze ROUTE zwischen Kreuzungen. Auf einer Schleife nehmen zwei Klicks den kürzeren Weg.",
                "Hinter das ferne Ende klicken, um es weiterzuführen; es folgt der Spur, auch um eine Schleife. Der erste Klick bleibt stehen: ihn anklicken, dann dorthin, wo er hin soll, um ihn zu versetzen. Nach einer per Doppelklick gewählten Route versetzt ein Klick das nähere Ende.",
                "Die Zeile \"Auswahl\" zeigt, was gewählt ist; einen Typ anklicken sperrt ihn (die anderen werden blass), erneut anklicken hebt die Sperre auf.",
                "Zwei Punkte, die nur über einen langen Umweg verbunden sind (an einer Kreuzung weg von der Spur und zurück), werden abgelehnt.",
                "Oder Punkte auswählen - Kästchen, Kreis, Strg-Klick - verbunden oder nicht; jeder wird einzeln geprüft.",
                "Toleranz setzen; die gefundenen Punkte über dem Boden werden markiert. Rechtsklick setzt sie auf.",
            },
            controls = {
                "Auswahl: Abschnitt / Route / Auswahl.",
                "Ebene: auf der Abschnittslinie oder der obersten Oberfläche. Ausgegraut beim Einrasten auf Gelände.",
                "einrasten auf: Gelände oder die vorhandene Oberfläche (Straßen, Decks).",
                "Toleranz: wie weit ein Punkt von der Oberfläche abweichen darf, bevor er bewegt wird.",
            },
        },
        ["convert"] = {
            what = {
                "Umwandeln ändert vorhandene Verbindungen. Richtung UND Priorität auf der Karte setzen; ein Klick wendet beides an, als ein Rückgängig-Schritt.",
            },
            how = {
                "Richtung und Priorität auf der Karte setzen, und ob es für einen Wegpunkt oder die ganze Route gilt.",
                "Den Punkt oder die Route anklicken.",
            },
            controls = {
                "Richtung: beidseitig, einseitig, andersherum (dreht eine Einbahn; ein Rückwärtsweg bleibt Rückwärtsweg) oder Rückwärtsweg (AutoDrives Rückwärtsstraße, im Rückwärtsgang befahren).",
                "Priorität: primär oder sekundär (Vorfahrt gewähren).",
                "gilt für: einen Wegpunkt oder die ganze Route.",
            },
        },
        ["merge"] = {
            what = {
                "Zusammenführen ist für ein Stück, auf dem zwei getrennt aufgezeichnete Spuren nebeneinander laufen - die zwei Richtungen einer Straße oder eine doppelt aufgezeichnete Spur - die eins werden sollen. Das Stück auf einer Spur wählen, dann die andere anklicken: die andere Spur wird eingefaltet, und das gewählte Stück rückt in die Mitte und wird beidseitig.",
            },
            how = {
                "Den Abschnitt wie gewohnt wählen: ein Ende und dann das andere anklicken für einen ABSCHNITT, oder doppelklicken für die ganze ROUTE zwischen Kreuzungen. Auf einer Schleife nehmen zwei Klicks den kürzeren Weg.",
                "Hinter das ferne Ende klicken, um es weiterzuführen; es folgt der Spur, auch um eine Schleife. Der erste Klick bleibt stehen: ihn anklicken, dann dorthin, wo er hin soll, um ihn zu versetzen. Nach einer per Doppelklick gewählten Route versetzt ein Klick das nähere Ende.",
                "Die Zeile \"Auswahl\" zeigt, was gewählt ist; einen Typ anklicken sperrt ihn (die anderen werden blass), erneut anklicken hebt die Sperre auf.",
                "Zwei Punkte, die nur über einen langen Umweg verbunden sind (an einer Kreuzung weg von der Spur und zurück), werden abgelehnt.",
                "Grün zeigt, was übernommen würde. Die ANDERE Spur anklicken - oder Rechtsklick, wenn es die einzige daneben ist.",
                "Die zwei Spuren müssen innerhalb des Zusammenführungsabstands liegen, sonst passiert nichts.",
            },
            controls = {
                "Zusammenführungsabstand: wie weit die Spuren auseinander liegen dürfen.",
                "Abweichung: wie weit sie entlang des Stücks auseinanderlaufen dürfen, bevor es dort endet.",
                "einrasten auf: Gelände, oder zusammengeführte Punkte auf einer Brücke / Rampe lassen.",
            },
        },
        ["name"] = {
            what = {
                "Benennen hängt einem Wegpunkt eine Beschriftung an, sodass er zu einem benannten Ziel/Marker auf der Karte wird - so, wie AutoDrive-Ziele benannt werden.",
            },
            how = {
                "Den Wegpunkt anklicken, den du benennen willst.",
                "Den Namen im Dialog eingeben, der sich öffnet, und bestätigen.",
            },
            controls = {
                "Namensdialog: die Texteingabe des Grundspiels, per Klick geöffnet.",
            },
        },
        ["delete"] = {
            what = {
                "Löschen entfernt Wegpunkte samt den Verbindungen durch sie - einen Wegpunkt oder eine ganze Route zwischen Kreuzungen je Klick, oder alles Ausgewählte.",
            },
            how = {
                "Einen Punkt anklicken: er (oder seine Route, je nach Karte) wird entfernt.",
                "Mit einer Auswahl tut ein Linksklick nichts - Rechtsklick löscht die Auswahl, Esc hebt sie auf.",
                "Alles ist widerrufbar (Q).",
            },
            controls = {
                "entfernt: einen Wegpunkt oder die ganze Route. Ausgegraut, solange eine Auswahl besteht.",
            },
        },
        ["junction"] = {
            what = {
                "Das Kreuzungswerkzeug arbeitet an einer Kreuzung auf einmal. Entfernen nimmt die alten Abbieger in der Kreuzung heraus und kürzt die Fahrbahnen auf saubere Enden; Bauen legt neue Abbieger - das eigene X- oder T-Muster der Mod, wo es an jede Straße dort passt, sonst Abbieger für Abbieger (oder gar nichts, wie die erweiterte Einstellung sagt). Entfernen + bauen macht beides als ein Rückgängig-Schritt. Kreuzungen sind über der Karte nummeriert, und die Nummern bleiben beim Spielstand. Es ist eine BETA: einfache X- und T-Kreuzungen von Straßen kann es heute gut; beidseitige Feldwege, Y-Kreuzungen und schiefe Kreuzungen kommen noch. Im Einstellungsdialog (Abschnitt BETA) ausschalten, dann verschwindet sein Knopf.",
            },
            how = {
                "Auf eine Kreuzung zeigen: die Karte sagt, welche es ist und welche Art. Linksklick sperrt sie.",
                "Die Aktion auf der Karte wählen: entfernen, bauen oder entfernen + bauen.",
                "Rechtsklick führt sie aus. Ein Rückgängig nimmt alles zurück.",
                "Linksklick woanders versetzt die Sperre auf eine andere Kreuzung. Rechtsklick ohne etwas zu tun gibt sie frei; Esc legt das Werkzeug weg.",
            },
            controls = {
                "Aktion: entfernen, bauen oder entfernen + bauen.",
                "Durchfahrten: beim Entfernen belassen (die Straßen geradeaus bleiben) oder mit entfernt.",
                "Form: beim Bauen Mod (das eigene X oder T der Mod) oder glätten (rundere Abbieger).",
                "muss passen: die Fahrzeuge, für die jeder neue Abbieger passen muss.",
                "erweitert: die Radien und Prüfungen hinter dem Bauen; standardmäßig zu.",
            },
        },
    },
}

-- The General-reference page (manual page 1). Same idea: one string per bullet, wrapped at render.
-- Section titles are stored already upper-cased for the language (Lua's string.upper only touches
-- ASCII, so it would leave umlauts mixed-case - hence pre-casing here).
L.GENERAL = {
    de = {
        summary = "Öffnen, Verlassen und die überall gültigen Tasten und Steuerungen.",
        sections = {
            { title = "ÖFFNEN & VERLASSEN", lines = {
                "Den Editor mit Linke Alt + V oder Linke Alt + F öffnen (im Steuerungsmenü belegbar) oder mit dem Knopf neben AutoDrives HUD.",
                "Esc zum Verlassen. Jede Änderung ist widerrufbar.",
                "Nur Einzelspieler. Änderungen werden geschrieben, wenn du der Host bist.",
            } },
            { title = "TASTEN", lines = {
                "1-9, 0 - ein Werkzeug wählen (die Zahl auf dem jeweiligen Werkzeugknopf).",
                "Q - rückgängig, E - wiederherstellen.",
                "H - die schwebende Werkzeugkarte aus-/einblenden (beim Ziehen blendet sie sich selbst aus).",
                ", und . - Abfallwert von Verschieben verkleinern / vergrößern.",
                "B - Kopieren von Verschieben umschalten.",
                "G - Höhenschnitt an / aus: Blick senkrecht nach unten, Dächer und Bäume über der Fahrzeughöhe ausgeblendet.",
                "/ - diese Hilfe zeigen / verbergen.",
                "R (halten) + Rad - das Gezogene drehen (Verschieben, beim Ziehen).",
                "Esc - EINEN Schritt zurück: eine Zahleneingabe, ein Dialog, ein Popup (samt Auswahl), ein Werkzeug aus einem Popup (zurück zum Popup), die Hilfe, eine offene Aktion, die Auswahl, das Werkzeug - und erst dann den Editor verlassen.",
            } },
            { title = "MAUS & KAMERA", lines = {
                "Linksklick - wählen; Linksziehen - bewegen (Verschieben). Zweiter Klick = Abschnitt, Doppelklick = Route, in jedem Werkzeug, das auf einem Stück arbeitet.",
                "Rechtsklick - Offenes anwenden (Route beenden, Spur legen, bestätigen) oder ein Popup schließen. Ist nichts offen, legt ein weiterer Rechtsklick nach einem Moment das Werkzeug weg.",
                "Mittlere Maustaste - die Kamera schwenken/drehen. WASD bewegt sie.",
                "Rad - Kamera-Zoom oder die Zahl unter dem Cursor ändern.",
                "Strg - zur Auswahl hinzufügen / entfernen, allein oder zusammen mit einer Form unten. In Glätten, Begradigen, Unterteilen, Parallele und Zusammenführen muss sie eine zusammenhängende Route bleiben.",
                "Alt+Ziehen Kästchen, Umschalt+Ziehen Kreis, Alt+Umschalt+Ziehen freihand, Leertaste+Ziehen+Klick gedrehtes Kästchen.",
            } },
            { title = "POPUPS", lines = {
                "Ein Klick aufs Netz öffnet ein Popup für den Punkt, Abschnitt, die Route oder Auswahl. Es öffnet sich neben dem, worauf es wirkt, und lässt sich an seiner Kopfzeile ziehen.",
            } },
            { title = "DIE WERKZEUGKARTE", lines = {
                "Die schwebende Karte trägt die Einstellungen des aktiven Werkzeugs: Schalter leuchten, wenn an, Auswahlen nebeneinander, Zahlen zum Steppen, Scrollen oder Tippen. Was gerade nicht passt, ist ausgegraut.",
                "Aus einem Popup gewählt, öffnet sie sich dort, wo das Popup war. Sie weicht aus, wenn sie deine Arbeit verdecken würde, und bleibt sonst, wo du sie hingezogen hast (Kopfleiste).",
                "Anheften (an der Kopfleiste oder im Einstellungsdialog) hält sie immer genau dort.",
                "H blendet sie aus und ein; beim Ziehen eines Wegpunkts blendet sie sich selbst aus.",
            } },
            { title = "ZAHLENFELDER", lines = {
                "Jede Zahl im Panel lässt sich auf drei Arten ändern: die - / + Stepper klicken, mit dem Rad darüber scrollen oder den Wert anklicken und eintippen.",
            } },
            { title = "EINSTELLUNGEN & FARBEN", lines = {
                "Die EINSTELLUNGEN im Panel haben UI-Größe, Design und Akzent; die untere rechte Ecke des Panels ziehen ändert die Größe. \"weitere Einstellungen...\" (oder das Zahnrad) öffnet den Dialog: Linienstärke, Farben je Rolle, Werkzeugkarte anheften, Startknopf und Debug-Logging.",
                "Alles wirkt sofort und speichert automatisch. Der Konsolenbefehl FlyoverResetTheme setzt Farben und Größe zurück, falls eine eigene Farbe das Panel schwer lesbar macht.",
            } },
        },
    },
}

--- Localized string for an English UI string. nil and non-strings pass straight through, and an
--- English string with no entry for the current language returns unchanged - so wrapping any drawn
--- literal in this call is always safe.
function L.t(s)
    if type(s) ~= "string" then
        return s
    end
    local tbl = L.STRINGS[L.code()]
    if tbl ~= nil then
        local v = tbl[s]
        if v ~= nil then
            return v
        end
    end
    return s
end

-- Greedy word-wrap to at most maxChars per line. Byte length, so an umlaut counts a little long and
-- wraps a touch early - safe against overflowing the panel rather than the reverse.
local function wrapText(s, maxChars)
    local out, line = {}, ""
    for word in string.gmatch(s, "%S+") do
        if line == "" then
            line = word
        elseif #line + 1 + #word <= maxChars then
            line = line .. " " .. word
        else
            out[#out + 1] = line
            line = word
        end
    end
    if line ~= "" then
        out[#out + 1] = line
    end
    if #out == 0 then
        out[1] = ""
    end
    return out
end

--- Word-wrap a single string to lines of at most maxChars. Exposed for callers that hold a whole
--- localized message (the "NEXT" guidance) and need it broken to the panel width at render.
function L.wrap(s, maxChars)
    return wrapText(s, maxChars or 44)
end

--- The summary lines for a tool page. When a translation exists it is wrapped to maxChars and returned;
--- otherwise the bundled English lines are returned exactly as make_help.py wrote them.
function L.summaryLines(toolKey, englishLines, maxChars)
    local tbl = L.SUMMARIES[L.code()]
    local s = tbl ~= nil and tbl[toolKey] or nil
    if s ~= nil then
        return wrapText(s, maxChars or 44)
    end
    return englishLines or {}
end

-- Word-wrap with a first-line prefix and a continuation prefix, for bullets ("- " / "  ") and hanging
-- indents ("" / "  "). Byte length, so umlauts wrap a touch early - safe against overflow.
local function wrapPrefixed(s, maxChars, firstPrefix, contPrefix)
    firstPrefix = firstPrefix or ""
    contPrefix = contPrefix or ""
    local out, line = {}, nil
    for word in string.gmatch(s, "%S+") do
        if line == nil then
            line = firstPrefix .. word
        elseif #line + 1 + #word <= maxChars then
            line = line .. " " .. word
        else
            out[#out + 1] = line
            line = contPrefix .. word
        end
    end
    if line ~= nil then out[#out + 1] = line end
    if #out == 0 then out[#out + 1] = firstPrefix end
    return out
end

-- How each help section wraps: "what" is flowing prose, "how" is bulleted, "controls" is
-- hanging-indented - matching the shapes make_help.py bakes into the English.
local HELP_STYLE = {
    what = { first = "", cont = "" },
    how = { first = "- ", cont = "  " },
    controls = { first = "", cont = "  " },
}

--- The body lines for one tool help section ("what" / "how" / "controls"). When a German translation
--- exists it is wrapped to maxChars in that section's style; otherwise the bundled English lines are
--- returned exactly as make_help.py wrote them.
function L.helpSection(toolKey, section, englishLines, maxChars)
    local tbl = L.HELP[L.code()]
    local items = tbl ~= nil and tbl[toolKey] ~= nil and tbl[toolKey][section] or nil
    if items == nil then
        return englishLines or {}
    end
    local style = HELP_STYLE[section] or HELP_STYLE.what
    local out = {}
    for _, para in ipairs(items) do
        for _, ln in ipairs(wrapPrefixed(para, maxChars or 46, style.first, style.cont)) do
            out[#out + 1] = ln
        end
    end
    return out
end

--- The General-reference summary for the current language (English when untranslated).
function L.generalSummary(englishSummary)
    local g = L.GENERAL[L.code()]
    return (g ~= nil and g.summary) or englishSummary
end

--- The General-reference sections, normalized to { title, lines } for the renderer. German is wrapped,
--- its titles already cased; English matches the current renderer - title upper-cased, lines as-is.
function L.generalSections(englishSections, maxChars)
    local out = {}
    local g = L.GENERAL[L.code()]
    if g ~= nil and g.sections ~= nil then
        for _, sec in ipairs(g.sections) do
            local lines = {}
            for _, item in ipairs(sec.lines or {}) do
                for _, ln in ipairs(wrapPrefixed(item, maxChars or 46, "- ", "  ")) do
                    lines[#lines + 1] = ln
                end
            end
            out[#out + 1] = { title = sec.title, lines = lines }
        end
        return out
    end
    for _, sec in ipairs(englishSections or {}) do
        out[#out + 1] = { title = string.upper(sec.title or ""), lines = sec.lines or {} }
    end
    return out
end
