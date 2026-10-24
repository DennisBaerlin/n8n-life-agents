---
name: feature
description: Startet eine Feature-/Entwicklungsphase mit Blast-Radius (fn_*, Schema/Trigger, Workflows, Build-Engine, Provisioning, Auth, neuer Agent/Tool) — Plan-Modus, Plan zur Owner-Freigabe, danach TDD → Build → /code-review → Ship. Args = die Aufgabe oder der Pfad einer Handoff-Plan-Datei (.claude/plans/*.md).
---

# Feature-Phase (Entwicklungszyklus)

Leitsatz: **Ceremony scales to the task.** Ein Diff, der in einen Satz passt, braucht keinen Plan-Modus — direkt umsetzen, die Gates laufen beim Commit/Push. Alles mit Blast-Radius (Tabelle in CLAUDE.md *Testing / TDD-Workflow*) läuft hier durch: der Owner ist Nicht-Programmierer, der Plan ist seine Prüfstelle für Architektur-Entscheidungen.

## 1. Kontext

- Handoff-Plan-Datei genannt → zuerst lesen (Fortsetzungs-Session). Sonst `BACKLOG.md` scannen und die Aufgabe aufnehmen.
- In den Plan-Modus wechseln (EnterPlanMode), falls nicht schon aktiv.

## 2. Plan (eine Datei, die der Owner liest)

Checkliste — was nicht zutrifft, kurz als „n/a" nennen:

- **Scope** als EARS-Kriterien; Annahmen explizit; Unklares fragen, nie raten.
- **Recherche** bei unklarem Scope, Edge-Cases oder Best Practices; n8n-Doku für jeden berührten Node (n8n failt still). Quellen verlinken.
- **Berührte Oberflächen** (DB/fn, Tool, Prompt, Routing, Build, Provisioning) → die Blast-Radius-Matrix fixiert die Gates dieser Phase.
- **Analog benannt?** Neue Oberfläche → das bestehende Referenz-Analog (meist `finance`; Katalog `docs/package-contract.md` §8), Abweichung nur mit belegtem Grund. Neue Architektur/Mechanik → `/arch-challenge`.
- **Plan-Reviewer:** bei `fn_*`/Schema/Trigger/Auth/neuem Agent oder Tool **ein** unabhängiger Opus-Reviewer (nur Plan-Datei + Konventions-Exzerpte; Findings einarbeiten), sonst `Plan-Reviewer: nicht nötig – <Grund>`. Diese Zeile ist der Marker, den der ExitPlanMode-Hook verlangt.
- Code-Suche fürs Verständnis → `Explore`-Subagent. Keine Subagenten, um den eigenen Plan gegenzuprüfen.
- ExitPlanMode → Owner-Freigabe. Erst danach Code.

## 3. Umsetzung

- **TDD Red:** neue oder geänderte `fn_*` → `tests/db/<pkg>/test_fn_*.sql` zuerst; Inner Loop `db_apply` → `db_test.ps1 -Filter '*<subject>*'`.
- **Build & Deploy:** `build.ps1` → Stickies gegen den neuen Graphen gegenlesen → Substrat `bootstrap_test_n8n.ps1 -Reset` mit eigenen Container-Namen/Ports. `infra_test.ps1`, wenn Infra berührt ist. LLM-Suiten nur im Owner-Fenster, sonst das exakte Kommando empfehlen.
- **Doku:** CLAUDE.md-Familie nur Deltas (ein Fakt, eine Adresse); nutzer-sichtbare Änderung ⟹ `docs/site` (deutsch) + `README.md` (englisch, OSS-Doku wie `AGENTS.md`/`CONTRIBUTING.md`), dann `build_site.ps1`.

## 4. Review & Ship

- `/code-review high` auf den Diff; Findings einarbeiten (bei fn-Änderung zurück zu TDD).
- Führt der Diff eine **neue Paket-Oberfläche** ein (neues Paket, neues `tool_*`-/`fn_*`-Analog, Core-Single-Paket-Naht)? → ein kurzer Sonnet-Pass mit der Paritäts-Checkliste aus `docs/package-contract.md` §8 gegen das Referenz-Analog.
- Commit (Conventional Commits) → Push; die Lints laufen beim Commit, `db_test` beim Push (rot ⟹ fixen, nie `--no-verify`). Commit- und PR-Texte sind öffentlich: einen Live-Befund mit erfundenen Werten beschreiben, `privacy_lint` prüft Message und Push.
- Phasen-Ende: Plan/BACKLOG aktualisieren, Substrate stoppen (`scripts/dev/stop_test_containers.ps1`), frische Session.
