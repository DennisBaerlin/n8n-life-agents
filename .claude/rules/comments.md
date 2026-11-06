---
paths:
  - "**/*.sql"
  - "**/*.ps1"
  - "**/*.sh"
  - "**/*.js"
  - "provisioning/lifeagents*"
---

# Kommentare (lädt beim Öffnen von Code)

Den Code lesen nur KI-Modelle, meist beim Suchen. Ein Kommentar sagt, was der Code nicht zeigt; jeder andere kostet Kontext und veraltet.

## Gehört hinein

- Warum: Grund einer nicht naheliegenden Entscheidung; eine verworfene Alternative in einem Halbsatz.
- Invariante oder Vertrag, den der Code voraussetzt und nicht selbst prüft.
- Falle: überraschendes Verhalten von n8n, PowerShell 5.1, PostgreSQL oder bash, mit Symptom.
- Bewusst so behandelter Grenzfall.
- Verweis auf die eine Adresse (Test, Lint, Doku-Abschnitt), wo die Regel steht.

## Fällt weg

- Nacherzählen des Codes oder der Parameter.
- Herkunft und Verlauf (Phase, Session, Datum, Befund, „früher“, „neu seit“): Das steht in git.
- Kopien von Regeln aus CLAUDE.md, `.claude/rules/` oder dem fn-Katalog.
- Auskommentierter Code; TODO ohne Auslöser.
- Betonung in Großbuchstaben. Ein Verbot ohne Ausnahme wird Lint oder Assert.

Maßstab im Zweifel: Ein Kommentar bleibt, wenn er Information trägt, die im Code fehlt, und beim nächsten Ändern nicht unbemerkt falsch wird. Über einem langen, nicht offensichtlichen Block darf eine Zeile stehen, was er leistet.

## Tragende Kommentare

- fn-Kopf (`R__fn_*.sql`) ist der Eintrag in `docs/fn_catalog.md`: Titelzeile, Zweck in ein bis drei Sätzen, Eingabe-Keys (Pflicht/optional), Rückgabe (`ok:true`-Felder, `ok:false`-reasons), Seiteneffekte und Trigger.
- Skript-Kopf (`scripts/**/*.ps1`, Top-Skripte in `provisioning/`) ist die Skript-Doku: Zweck, Aufruf-Beispiele, Voraussetzungen (Container, `.env`), Exit-Code.
- Sticky-Note je Workflow: was, Auslöser, Ausgang; weitere Stickies an nicht offensichtlichen Stellen nach denselben Kriterien wie oben.
- Maschinenlesbare Kommentare bleiben unverändert (`#Requires`, `shellcheck`-Direktiven, Lint-Marker, Spaltenkommentar einer Ableitungs-Ausnahme).

## Pflege

- Wer Code ändert, liest die Kommentare der Stelle mit; ein falscher Kommentar ist ein Bug.
- Angewandte `V__`-Migrationen bleiben auch für Kommentare unverändert (Prüfsumme).
- Sprache: Deutsch wie die Entwickler-Doku, Hooks ASCII; Identifier Englisch.
