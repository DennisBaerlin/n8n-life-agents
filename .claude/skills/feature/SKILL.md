---
name: feature
description: Startet eine Entwicklungsphase mit Blast-Radius (fn_*, Schema/Trigger, Workflows, Build-Engine, Provisioning, Auth, neuer Agent/Tool) – Plan-Modus, Owner-Freigabe, dann TDD → Build → /code-review → Ship. Args = die Aufgabe oder der Pfad einer Plan-Datei.
---

# Feature-Phase (Entwicklungszyklus)

Leitsatz: Ceremony scales to the task. Alles mit Blast-Radius (Root-`CLAUDE.md` *Testing / TDD-Workflow*) läuft hier durch: der Plan ist die Prüfstelle für Architektur-Entscheidungen.

## 1. Kontext

- Plan-Datei genannt → zuerst lesen (Fortsetzungs-Session). Ist der Plan freigegeben: direkt weiter mit Abschnitt 3; Plan-Modus nur, wenn sich die Architektur ändert. Sonst das private Backlog (.local/BACKLOG.md im Haupt-Checkout) scannen und die Aufgabe aufnehmen.
- Ohne freigegebenen Plan: in den Plan-Modus wechseln (EnterPlanMode), falls nicht schon aktiv.

## 2. Plan (eine Datei, die der Owner liest)

Checkliste — was nicht zutrifft, kurz als „n/a" nennen:

- **Scope** als EARS-Kriterien; Annahmen explizit; Unklares fragen, nie raten.
- **Recherche** bei unklarem Scope, Edge-Cases oder Best Practices; n8n-Doku für jeden berührten Node (n8n failt still). Quellen verlinken.
- **Berührte Oberflächen** (DB/fn, Tool, Prompt, Routing, Build, Provisioning) → die Blast-Radius-Matrix fixiert die Gates dieser Phase.
- **Analog benannt?** Neue Oberfläche → das bestehende Referenz-Analog (meist `finance`; Katalog `docs/package-contract.md` §8), Abweichung nur mit belegtem Grund. Neue Architektur/Mechanik → `/arch-challenge`.
- **Plan-Reviewer:** bei `fn_*`/Schema/Trigger/Auth/neuem Agent oder Tool ein frischer Opus-Reviewer (nur Plan-Datei + Konventions-Exzerpte, nicht die Herleitung; Findings einarbeiten), sonst `Plan-Reviewer: nicht nötig – <Grund>`.
- **Denkstufe:** `Denkstufe: medium` (Standard) oder `Denkstufe: high – <Grund>`. high nur mit einem Grund, den der Plan belegt: neue Mechanik mit `/arch-challenge`, Migration mit Daten-Umbau, Auth- oder Sicherheits-Änderung, Fehlersuche ohne Reproduktion. Beide Zeilen verlangt der ExitPlanMode-Hook (`.claude/hooks/dev_cycle_plan_gate.ps1`).
- **Zustands-Matrix:** Enthält der Plan neue Bot-Texte, Knöpfe, Vorschläge oder Beispielsätze, steht die Matrix aus `/ui-task` §2 (*Zustands-Matrix vor jeder Vorlage*) im Plan, belegt statt angenommen und vom frischen Prüfer gegengelesen; sonst „n/a".
- **Bezahlte Fälle:** Jeder Fall im Plan nennt die genaue Fall-ID und die Fall-Datei (`-CasesFile`), dazu den Kostenrahmen.
- Code-Suche fürs Verständnis → `Explore`-Subagent.
- ExitPlanMode → Owner-Freigabe. Erst danach Code. **Ausnahme Unter-Session einer Leitung:** kein ExitPlanMode. Die Plan-Datei fertigstellen und am Zug-Ende Pfad, „Kurz gesagt“ und offene Fragen an die Leitung melden. Die Freigabe holt die Leitung in ihrem eigenen Chat (`/leitung` §2 *Plan-Freigabe*). Hintergrund: Die weitergeleitete Plan-Karte stellt die Session unzuverlässig von Auto auf manuell und erscheint nicht in der Handy-App.
- **Nach der Freigabe baut eine neue Session** (sauberer Kontext, schriftliches Ziel): zuerst alles im Chat Entschiedene in die Plan-Datei nachtragen, dann `start_session` mit frischem Kontext, `effort` laut Plan-Zeile *Denkstufe* und `/feature <Plan-Datei>` starten; ohne dieses Werkzeug oder über Remote Control (dort verweigert die App den Start) dem Owner genau diesen Prompt für die Desktop-App geben. Hier nichts bauen. Ausnahme: Der Owner sagt „hier weitermachen“, oder die Planung war sehr kurz.

## 3. Umsetzung

- **TDD Red:** neue oder geänderte `fn_*` → `tests/db/<pkg>/test_fn_*.sql` zuerst; Inner Loop `db_apply` → `db_test.ps1 -Filter '*<subject>*'`.
- **Build & Deploy:** `build.ps1` → Stickies gegen den neuen Graphen gegenlesen → Substrat `bootstrap_test_n8n.ps1 -Reset` mit eigenen Container-Namen/Ports. `infra_test.ps1`, wenn Infra berührt ist. LLM-Suiten nur im Owner-Fenster, sonst das exakte Kommando empfehlen.
- **Doku:** CLAUDE.md-Familie nur Deltas (ein Fakt, eine Adresse); nutzer-sichtbare Änderung ⟹ `docs/site` (deutsch) + `README.md` (englisch, OSS-Doku wie `AGENTS.md`/`CONTRIBUTING.md`), dann `build_site.ps1`.

## 4. Review & Ship

- `/code-review high` auf den Diff; Findings einarbeiten (bei fn-Änderung zurück zu TDD).
- Führt der Diff eine neue Paket-Oberfläche ein (neues Paket, neues `tool_*`-/`fn_*`-Analog, Core-Single-Paket-Naht)? → ein kurzer Sonnet-Pass mit der Paritäts-Checkliste aus `docs/package-contract.md` §8 gegen das Referenz-Analog.
- Commit (Conventional Commits) → Push; die Lints laufen beim Commit, `db_test` beim Push (rot ⟹ fixen, nie `--no-verify`). Commit- und PR-Texte sind öffentlich: einen Befund nur mit seiner Eigenschaft beschreiben, ohne Person, Bank, Betrag und Haushaltsbezug (`tests/fixtures/README.md`), `privacy_lint` prüft Message und Push.
- Phasen-Ende: Plan und privates Backlog aktualisieren, Substrate stoppen (`scripts/dev/stop_test_containers.ps1`), frische Session.
