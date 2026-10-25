---
paths:
  - "packages/*/db/**/*.sql"
  - "tests/db/**/*.sql"
---

# DB-Gesetze (lädt beim Öffnen einer `.sql`-Datei unter `packages/*/db/` oder `tests/db/`)

Leitlinie (Root-`CLAUDE.md` *Arbeitsweise*): DB-Constraint ist Gesetz → `fn_*` ist atomare Durchsetzung + freundliche `{ok:false}` → Tool/Prompt nur Komfort. Mechanik (Phasen-Tabelle, Rollen-Kette, Apply-Treiber) → `docs/reference/packages.md` *Migrations-Modell*; fn-Verträge → `docs/fn_catalog.md` (generiert).

## Migrations-Modell

Jedes Paket: `packages/<pkg>/db/*.sql` (Baseline-Inits, bei jedem Apply, idempotent) → `packages/<pkg>/db/migrations/V{NNN}__*.sql` (einmalig) → `packages/<pkg>/db/migrations/R__*.sql` (bei Inhalts-Änderung, Checksum) → `packages/core/db/util/util_*.sql` (Grants, zuletzt). Ledger `core.schema_version`.

- **Wann was:** idempotent ausdrückbar (`IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`, inline-Baseline-fn) → **Init**; einmalig/nicht-idempotent (Backfill, destruktiver ALTER/DROP, RENAME, ENUM-Wert-Drop) → **versioned**; per `CREATE OR REPLACE`/`DROP+CREATE` neu-setzbar (View/Function) → **repeatable**. Faustregel: läuft die SQL zweimal und tut Falsches → versioned.
- **`V__`:** `V{NNN}__kurz.sql`, `NNN` null-gepaddet, monoton je Paket. Kein `BEGIN`/`COMMIT` (Treiber wrapt). Ruft keine Tool-fn (die laufen erst als R__). **Angewandte V nie editieren** (Checksum-Guard wirft) → neue `V{NNN+1}`. `squawk`-Hook prüft jede V (unsafe NOT NULL, CONCURRENTLY, verirrtes BEGIN).
- **`R__`:** eine Repeatable pro Objekt: `R__fn_<name>.sql` je Tool-Function; interdependente View-Familie = **eine** Sammeldatei `R__<pkg>_views.sql` (`DROP … CASCADE` + `CREATE`; ein Split verlöre abhängige Views still), unabhängige Einzel-View = `R__v_<name>.sql`. Kein `BEGIN/COMMIT`.
- **R__-Reihenfolge ist alphabetisch:** ruft eine fn eine alphabetisch spätere R__-fn, muss sie `LANGUAGE plpgsql` sein (late-bound); `LANGUAGE sql` prüft den Body beim CREATE → „function … does not exist“ beim frischen Apply.
- **Jede neue/geänderte fn ⟹ `scripts/gen_fn_catalog.ps1` + `docs/fn_catalog.md` mit-committen** (Drift = Commit-Gate, prek-Hook); der fn-Header-Kommentar IST der Katalog-Eintrag. Neue fn = `R__fn_<neu>.sql` im besitzenden Paket + `tests/db/<pkg>/test_fn_<neu>.sql` **zuerst** (TDD Red). Inner Loop: `db_apply.ps1 -File …` (ungated); mehrere Dateien **kommagetrennt als ein Argument** (space-separiert läuft nur die erste), Verzeichnis oder Glob erlaubt.
- **Inline-Baseline-Helfer** (`fn_to_eur`, `fn_monthly_equivalent`, `fn_days_per_month`, `fn_validate_household_facts`) sind Trigger-/GENERATED-gekoppelt und bleiben bewusst im Init, nicht als R__.

## Schema-Änderungs-Regeln

- **GENERATED-Spalten können keine andere Tabelle referenzieren** → Cross-Table-Live-Werte (z. B. Restschuld) gehören in eine VIEW.
- **Neue Spalte in bestehender Tabelle:** `CREATE TABLE IF NOT EXISTS` legt sie nicht an → zusätzlich `ALTER TABLE … ADD COLUMN IF NOT EXISTS` direkt nach der Tabellendefinition.
- **Spalten-RENAME** = `V{NNN}__` im besitzenden Paket: geguardeter `DO`-Block (`IF alte EXISTS AND neue NOT EXISTS → RENAME`), kein Tabellen-Existenz-Guard; das Init trägt den **Endzustand**.
- **Views in `R__finance_views.sql`:** Drop in umgekehrter, Create in normaler Dependency-Reihenfolge; Spalten-Renames dort frei. `CREATE OR REPLACE VIEW` außerhalb: neue Spalten nur am Ende.

## Integritäts-Konventionen

- **`ON DELETE`:** Ledger-FKs `RESTRICT` (keine verwaisten Buchungen), Config/Children `CASCADE`, Sonderfälle `savings_goal_reserve_entries.source_tx_id` und `real_estate.sale_tx_id` `SET NULL` (Provenienz-Links; die Void-fn wertet sie vor dem Löschen aus). Sonst zeigt kein FK auf `finance.transactions`.
- **Keine ableitbaren Spalten.** Ein Wert, der sich aus anderen gespeicherten Fakten (+ heute/Config) ergibt, wird nicht gespeichert, sondern GENERATED, VIEW oder `fn_*` (render-at-fetch). Prüffrage je neuer Spalte/Fakt: „Wird er falsch, wenn sich ein anderer Fakt ändert?" → dann ableiten. Ausnahmen nur (a) Ledger-Aggregate mit Recompute-Trigger (balance/shares/avg), (b) FK-Read-Model (`agent.persons`), (c) Provenienz/Audit/Snapshot mit Stempel; die Ausnahme steht im Spaltenkommentar. Spiegelbild für Write-fns: Pflicht-Input nur, was nicht ableitbar ist (sonst Default/Ableitung in der fn); Slugs/IDs und Stempel (`as_of`) vergibt die fn, relative Zeitangaben („in drei Wochen") nimmt sie roh und rechnet selbst. Anlass: gespeicherte „anfängliche Tilgung" widersprach der echten Rate (2026-10-25).
- **Constraints vor Triggern** für Cross-Row-/Cross-Table-Invarianten (`UNIQUE`/`EXCLUDE`/`CHECK`/`FK`); Gate-Trigger über andere Zeilen haben MVCC-Races. Recompute-Trigger = Ausnahme (a) oben.
- **Multi-Leg = eine `group_id` (UUID)** je Write-fn, `fn_void_transaction` löscht die ganze Gruppe: ein Write = eine `group_id` = ein Void.
- **`payment_status` nie roh lesen:** `finance.active_recurring_payments` ist die eine Quelle für „läuft gerade"; eigene Queries replizieren exakt deren Prädikat.
- **Bewusste Nicht-Ziele** (nicht „reparieren"): Hard-DELETE statt Storno-Ledger; kein globales Double-Entry (`book_transaction` bucht einbeinig gegen externe Gegenparteien); keine `entity↔recurring_payment`-Exklusivität als FK; **keine UNIQUE auf Namen** (Bestands-Duplikate legitim → Resolver erst exakt, dann ohne Groß-/Kleinschreibung (`fn_name_matches`) + Dubletten-Backstop in der `fn_create_*`, die der Probelauf vor der Karte meldet; MVCC-Race bei Single-User hingenommen).
- **Naming:** `snake_case`, Englisch, nie für Sprache umbenennen. Suffixe tragen Bedeutung: `_id`, `_at` (timestamptz), `_date`, `_eur`, `_pct` (0..100); rollen-präzise `settlement_/disbursement_/debit_account_id`; Intervall-Trio `schedule_interval/_unit/_day_of_month` (+ `schedule_days_of_month` für feste Monatstage statt des Einzeltags). fn-Verben: `create_/book_/set_/close_/delete_/settle_/sell_/import_/export_/restore_` (Write), `resolve_/get_/fetch_/verify_/validate_` (Read); Semantik → `packages/CLAUDE.md` *Verb-Taxonomie*.

## Rollen & Cross-Schema-Read-Regel (D10)

- Schemas: `core` = geteilte Infra **inkl. aller publizierten Brücken-Lesefenster**; `agent` = Agent-Plattform; `<pkg>` = Domäne. Rollen `<pkg>_rw/_ro` eng auf ihr Schema; `core_ro` liest `agent`+`core` + je installiertem Paket ein Lesefenster (search_path-Tail generisch via `core.fn_sync_role_search_paths` — bleibt, weil monitor/guide Frei-SQL fahren); `context_ro` nur `core_contexts`. Vertrag → `docs/package-contract.md` §4.
- **Regel:** eine fn, die unter einer **engen** Rolle läuft und ein Schema liest, das die Rolle nicht sieht, **muss `SECURITY DEFINER`** sein (publiziertes Fenster in `core`) — nie nackter INVOKER cross-schema. Decision-Rule: käme ohne DEFINER `permission denied for schema X` → DEFINER + Härtung; ruft ohnehin nur Owner/Superuser → INVOKER ok. (`core.fn_fetch_context` war monatelang still gebrochen, weil `db_test` als Superuser läuft.)
- **DEFINER-Checkliste:** (1) `SET search_path` gepinnt, `pg_temp` zuletzt [Lint], (2) `REVOKE ALL … FROM PUBLIC` + explizite Grants [Lint], (3) Body schema-qualifiziert, (4) kein Caller-Input im dynamischen `EXECUTE`, (5) owned by der DDL-Credential.
- **Cross-Paket-Read** (Consumer liest Provider-Paket): Provider publiziert eine eigene Lese-fn (`provides.reads`), Consumer doppel-guardet (`core.fn_package_active` + `to_regprocedure`) → graceful NULL; nie eine `core.fn_*`, die `<pkg>.*`-Tabellen hartkodiert. → `docs/package-contract.md` §4.2.

## DB-Tests: Pattern

- `db_test.ps1` läuft als **Superuser** und sieht Rollenfehler nicht → **jede unter einer engen Rolle aufgerufene fn braucht einen `SET LOCAL ROLE`-Perspektiv-Test** in `tests/db/cross/test_role_permissions.sql` (`role_test_lint` erzwingt es; Zweig (C) prüft die Gegenrichtung: jeder `core.`/`agent.`-Aufruf eines Workflow-Knotens unter einer engen Rolle braucht PUBLIC-Default oder einen Grant an genau diese Rolle).
- Jedes neue Return-Feld einer Write-fn bekommt eine Zahlen-Assertion in `test_fn_*.sql` (nicht auf Message-Text). Bestehende Tests nur bei bewusster Vertragsänderung anfassen.
- Nutzer-korrigierbare Ablehnung = `RETURN {ok:false, reason}` (kein RAISE) **plus** spiegelnder CHECK als Backstop; echte Ausnahmen bleiben RAISE → `packages/CLAUDE.md` *Korrigierbare Ablehnung*.
