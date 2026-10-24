---
title: "Monitor & Guide"
---

Neben dem [Buchhalter](buchhalter.html) und dem [Finanzberater](finanzberater.html) gibt es zwei kleinere Helfer im System: der **Monitor** behält für dich beliebige Werte im Auge und meldet sich, wenn etwas passiert. Der **Guide** hilft dir beim Einstieg und erklärt, was der Assistent kann. Beide legen selbst nichts fest, ohne dich vorher zu fragen (Bestätigung per Knopf — Details unter [Chatten & Bestätigen](chatten-bestaetigen.html)).

## Monitor — der Wächter

Der Monitor ist ein generischer Wächter (Watchdog): Du beschreibst ihm im Chat, welchen Wert er beobachten soll, und er prüft ihn regelmäßig im Hintergrund. Vier Arten von Beobachtungsaufträgen (Trigger) sind möglich:

- **Schwellwert** — ein Wert über- oder unterschreitet eine feste Grenze (z. B. ein Kurs, ein Zinssatz).
- **Kursrückgang vom Hoch** — der Wert fällt um einen bestimmten Prozentsatz gegenüber seinem bisherigen Höchststand (Drawdown).
- **Fälligkeit** — ein Termin rückt näher (z. B. eine Frist).
- **Wiederkehrende Info** — eine regelmäßige Erinnerung, unabhängig von einem Schwellwert.

Beim Anlegen fragt der Monitor genau nach: welche Größe genau (Einheit, Währung), woher der Wert kommt, wie oft geprüft werden soll und ab wann er dir Bescheid geben soll. Bevor der Trigger scharf geschaltet wird, holt er den aktuellen Wert testweise einmal ab und zeigt ihn dir — so siehst du sofort, ob die Quelle sauber funktioniert, bevor du bestätigst. Danach prüft ein Hintergrund-Job den Trigger automatisch im passenden Takt und meldet sich bei dir, sobald die Bedingung eintritt.

Der Monitor gibt dir bewusst **keine Einschätzung**, was du mit einer Meldung tun sollst — dafür ist der [Finanzberater](finanzberater.html) da. Ein ausgelöster Trigger (außer der „wiederkehrenden Info") bleibt danach inaktiv, bis du ihn bewusst wieder scharf stellst; du kannst ihn jederzeit pausieren, ändern lassen oder ganz löschen.

```
Du:     Sag mir Bescheid, wenn Gold unter 1.900 Euro pro Feinunze fällt.
Monitor: Verstanden — ich beobachte den Spotpreis Gold in EUR/oz, geprüft
         einmal täglich. Aktueller Testwert: 1.950 EUR/oz. Soll ich den
         Trigger so anlegen?
Du:     Ja
Monitor: [Bestätigungs-Knopf] Trigger "Gold unter 1.900" ist aktiv — ich melde
         mich, sobald die Grenze erreicht ist.
```

## Guide — der Lotse

Der Guide beantwortet dir Fragen wie „was kannst du eigentlich alles?" — der Befehl `/help` zeigt dir jederzeit die vollständige Übersicht aller Funktionen (Befehlsliste unter [Befehle](befehle.html)). Außerdem führt er dich beim Einrichten (Onboarding) durch die Angaben zu deinem Haushalt (wer gehört dazu). Die eigentlichen Finanzdaten (Konten, Investments, Verträge) erfasst danach der Buchhalter selbst, sobald du ihm davon erzählst.

Zusätzlich bietet der Guide eine **freiwillige Lern-Funktion** an (standardmäßig ausgeschaltet, du schaltest sie per Knopf ein): Ein täglicher Hintergrund-Lauf sichtet eure jüngsten Gespräche und schlägt dir dauerhaft merkenswerte Fakten oder Notizen vor. Geschrieben wird dabei **nichts automatisch** — jeder Vorschlag kommt einzeln als Karte mit Speichern/Verwerfen-Knopf, und nur was du bestätigst, landet im Gedächtnis des Systems.

```
Du:      /help
Guide:   [Übersicht aller Funktionen: Buchhaltung, Beratung, Erinnerungen,
          Karriere-Coaching, Befehle …]

Guide:   Vorschlag aus dem Lern-Loop: "Max arbeitet seit Juni in Teilzeit
          (3 Tage/Woche)." Übernehmen?
          [Speichern]  [Verwerfen]
```
