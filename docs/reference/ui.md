# UI und UX: Regeln für alle Oberflächen

Die eine Adresse für Gestaltungsregeln. Gilt für Doku-Seite, Mini-App, Wizard und Mac-App. Der **Ablauf** (wer gibt wann was frei, Vorschau, Markierungen) steht im Skill `/ui-task`, die **Farbwerte** in `config/ui.tokens.json`. Der technische Vertrag der Mini-App bleibt `docs/package-contract.md` §3.12; er konkretisiert diese Regeln für ihre Bildschirme. Sprachregeln gelten auch für Telegram-Karten und feste Chat-Texte (Format: `packages/CLAUDE.md` *HITL-Bestätigungs-Format*).

## UX-Regeln

1. **Eine Frage je Abschnitt.** Jeder Abschnitt beantwortet genau eine Frage. Nie drei Fragen in einen Abschnitt mischen. In der Mini-App steht die Frage im Kopf der `fn_app_screen_*` (`contract_lint`).
2. **Ein Zuhause je Fakt**, über alle Reiter und Seiten hinweg. Steht ein Fakt schon woanders, wird er nicht wiederholt, höchstens als Sprungziel.
3. **Kein Jargon.** Jedes Wort besteht den Laientest: Jemand ohne Technikwissen versteht es. Keine Markierung wie „nicht ermittelbar“ ohne Grund; jede Markierung nennt, wie viel fehlt oder ab wann.
4. **Ein Zeitraum.** Eine Anzeige zeigt einen Zeitraum, keine zwei konkurrierenden Zahlen. Lieber die verwirrende zweite Zahl entfernen, als sie zu erklären. Kurzform ohne Jahr nur im Fenster [heute − 3 Monate, heute + 9 Monate).
5. **Markierung (Pille) nur, wenn gehandelt werden muss.** Keine grünen Pillen bei „alles gut“. Gelb und Rot nennen immer den Betrag oder das Datum.
6. **Summen sichtbar als Summen beschriften** („zusammen …“), nie über einer einzelnen Zeile.
7. **Entfernen vor Erklären.** Eine Erklärung ist ein Zeichen, dass die Darstellung falsch ist.
8. **Lange Listen kurz halten** (aufklappbare Zeilen), Betrag rechts, Balken nur mit Zielbetrag.
9. **Im Zustand mit Daten prüfen**, alle Zustände aus dem erfundenen Datenmodell, nicht nur den Leerzustand.
10. **Eine Frage je Wizard-Seite**, ein Hauptknopf, Zurück als Link.

## Sprache

- Deutsch, du, kurze Sätze. Fachwörter nur, wenn es sie braucht, und dann einmal erklärt.
- Knöpfe sagen, was als Nächstes passiert: „Weiter zu Telegram“, nicht „OK“.
- Beispiele nur mit erfundenen Werten, nie mit echten Namen, Beträgen oder Konten.

## Farben und Formen

- **Nie Werte fest eintragen.** Eine Oberfläche nutzt `var(--token)`; ihre Variablen kommen als erzeugter Block aus `config/ui.tokens.json` (`scripts/build_ui_tokens.ps1`). Zur Laufzeit wird nichts nachgeladen. `scripts/ui_token_lint.ps1` weist neue feste Farben ab.
- **Neue Farbe nötig?** Erst fragen, ob eine vorhandene Rolle passt. Sonst ein Token mit Verwendung in der Farbdatei und mit Kontrast-Paarung.
- **Lesen:** `ink` auf `bg`. Der Hauptknopf ist `ink` mit `bg` als Schrift.
- **Akzent:** `accent` für Links und „läuft“, `accent-pale` als Fläche für Gewähltes, Text darauf `ink`.
- **Zustandsfarbe nie allein:** `ok`, `warn` und `alert` nur als Punkt oder Rand. Die Fläche kommt von `*-wash`, die Schrift ist `ink`, und die Bedeutung steht zusätzlich im Text.
- **Kontrast:** Text mindestens 4,5:1 auf seiner vorgesehenen Fläche, hell und dunkel; Punkte und Ränder 3:1, begründete Ausnahmen stehen an der Paarung in der Farbdatei.
- **Formen:** `radius` für Flächen, `radius-pill` für Knöpfe und Chips, Trennlinie statt Schatten. Schatten nur beim Überfahren. Bewegung ruhig, 0,18 s.
- **Schrift:** Systemschrift (`font`), keine Schriftdatei und kein CDN.
- **Mini-App:** Flächen und Text kommen von Telegrams Theme (`--tg-theme-*`), Akzent und Zustand aus der Farbdatei. Bedeutung je Element: `docs/package-contract.md` §3.12.

## Prüfen

Was mechanisch geht, prüft der Commit (`ui_token_lint`, `locale_lint`, `contract_lint`). Was gelesen werden muss, prüft die feste Liste in `/ui-task` und der Prüf-Agent `.claude/agents/ui-review.md`. Der Agent meldet nur; die Entscheidung bleibt beim Owner.

## Bei uns anders

Ergebnis der Muster-Prüfung (`/arch-challenge`), damit die Punkte nicht wiederkommen:

- **Eigener Generator und Lint statt Style Dictionary und stylelint:** Die Toolchain hat kein Node, und stylelint prüft weder SVG-Attribute noch JS-Strings. Das Format bleibt DTCG, ein späterer Wechsel braucht keinen Farb-Umbau.
- **Hell und Dunkel als Gruppen, ohne Resolver-Datei:** Die Farbdatei liest nur unser Skript.
- **Vorschau-Seite statt Pflicht-Check am PR (Chromatic, Vercel):** Das sind kostenpflichtige Fremddienste, und bei einer einzigen prüfenden Person wäre der Pflicht-Check nur Papier.
- **WCAG 2 statt APCA:** WCAG 3 ist noch Entwurf, 4,5:1 bleibt die geltende Schwelle. Eine Prüfung am fertigen Bild (axe) folgt erst, wenn ein Fund zeigt, dass die Paar-Liste etwas verpasst.
