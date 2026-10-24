---
name: arch-challenge
description: Established-Pattern-Check einer neuen Architektur-/Mechanik-Entscheidung gegen etablierte Open-Source-/State-of-the-Art-Muster — ein belegpflichtiger Research-Pass mit Verdikt ADOPT / REJECT-„bei uns anders" / DEFER. Nutzen vor dem Bau bei neuer Mechanik oder neuem Sonderweg (nicht bei jeder Namenswahl) und als gelegentlicher Sonderlocken-Sweep. Args = die Entscheidung oder Oberfläche.
---

# Established-Pattern-Check

Owner-Direktive: Benennung und Mechanik folgen dem etablierten Standard. Default ist der etablierte Weg; eine Abweichung braucht einen **belegten** Grund. Keine Angst vorm Umbau.

## Ablauf

1. **Scope:** die Entscheidung (oder Oberfläche), Ist-Stand und Problem in 2–3 Sätzen.
2. **Research-Pass (ein Sonnet-Subagent mit Web):** „Wie lösen etablierte OSS-Projekte / der State of the Art dieses Problem?" Je Einwand: **ein konkreter externer Beleg** (Projekt, offizielle Doku, RFC), die benannte Sonderlocke und eine Umbau-Skizze. Ohne Beleg zählt ein Einwand nicht.
3. **Verdikt im Haupt-Loop** je Einwand, gegen unsere dokumentierten Constraints (CLAUDE.md-Familie, n8n-Quirks, DB-Gesetz, Single-User, Kosten/Privacy):
   - **ADOPT** → konkreter Schritt im Plan dieser Phase (nicht ins BACKLOG, wenn er hierher gehört).
   - **REJECT-„bei uns anders"** → Ein-Satz-Notiz in die passende CLAUDE.md, damit der Punkt nicht wiederkommt.
   - **DEFER** → größerer Umbau: terminierte Folge-Phase im BACKLOG mit Trigger.
   - Widersprechen sich Beleg und unser Kontext ohne klare Entscheidung → ein Opus-Arbiter adjudiziert genau diesen Punkt (selten).
4. Ergebnis = Liste {Einwand, Beleg, Verdikt, Ein-Satz-Begründung} im Plan.

Nicht hier: Korrektheit des gebauten Codes — das prüft `/code-review` nach dem Bau.
