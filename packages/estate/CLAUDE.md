# Estate-Paket — Domänen-Regeln (lädt beim Arbeiten in `packages/estate/`)

Nachlass-/Vorsorge-Agent (`agent.estate_advisor`): Vorsorge-Modus (geführtes Register-Erfassen, Gap-Nudges, Jahres-Review) und Ereignisfall (Tod/Vorsorgefall eines Mitglieds: DB-berechnete Fristen-Checkliste, „eine nächste Aufgabe"-UX, `/notfall`, Notfallmappe). SoT `packages/estate/db/*.sql`; Paket-Gesetze → `packages/CLAUDE.md`; Schema-Semantik, Ereignisfall-/Review-/Binder-Mechanik → `docs/reference/estate.md` (on-demand); **Write-Tools-Katalog** → `docs/reference/packages.md`.

## Grenzregel & Privacy-Hard-Rules (gelten für jede estate-Oberfläche)

- **Produkt-Attribute → finance; Prozess-/Fundort-/Wunsch-Attribute → estate.** finance ist **optionale** Dependency (`requires` leer): die drei Lese-fns `finance.fn_insurance_register()`/`fn_account_register()`/`fn_liability_register()` werden doppel-guardet konsumiert (Absenz = sichtbare Absenz-Zeile, nie Crash). estate referenziert lose (z. B. `provider_contracts.finance_recurring_payment_id` ohne FK — stale ID = Gap-Anzeige); FK nur auf `agent.persons` + estate-intern, nie Cross-Schema.
- **Geheimnisse nie:** keine Passwörter/PINs/Seed-Phrases — nur Fundort-Verweise (`access_path`, `twofa_hint`, `seed_backup_location`, `access_hint`, System-Steckbrief). Die DB koppelt `seed_backup_location` per CHECK an `category='crypto'`; „nur Verweis" erzwingen Tool-Descriptions + Instructions.
- **Ein Haushalts-Register, symmetrisch:** Einträge person-zugeordnet über `owner_person_id` (NULL = Haushalt); Lesen/Schreiben für Erwachsene (household + `adults_only`, **nicht** per_user wie career). Jede Write-fn prüft den `adults_only`-Backstop über `core.fn_check_write_permission` (Kind → `{ok:false}`, je fn ein Kind-Reject-db_test). Person via `core.fn_resolve_person`, nie `$fromAI`-Slug.

## Regeln

- **Kein paket-lokales Pflicht-Onboarding-Gate** am Agenten (fail-open — der Ereignisfall ist der Moment höchsten Bedarfs); Core-first bleibt. `estate_overview` ist household, hat keine `context_scopes`-Zeile und ist nie Publish-Ziel (render-at-fetch aus den Register-Tabellen).
- **Die Fristen rechnet die DB, nie das LLM:** `fn_case_template_rows` ist die eine Quelle des Soll-Task-Satzes für Create **und** HITL-Preview (kein TOCTOU); Engine-fns sind IMMUTABLE; v1 nur landesweite Feiertage, ohne § 193-Verschiebung (konservativ).
- **Break-Glass:** `export_emergency_binder`, `create_case`, `cancel_case` laufen bewusst auf `owner_info` — `owner_approval` deadlockte, wenn der Owner der Betroffene ist; `set_*`/`delete_*` = `owner_approval`; `confirm_review`, `set_case_task`, `create_case_task`, `set_onboarding_section` = Fortschritts-Flag ohne Gate. `adults_only` bleibt tier-unabhängiger Kind-Riegel, beim Binder doppelt (n8n-IF + RAISE im DEFINER-Renderer).
- `system_profile` hat einen Singleton-CHECK als Pflicht-Backstop, weil ein Agent-Tool schreibt. Gap-Report degradiert unter `estate_ro` ehrlich (`not_readable_on_this_path`), nie Crash.
- Jahres-Review: NULL `last_reviewed_at` feuert nicht (die Register-Lücke deckt Unvollständigkeit); `advisor.estate_review_days` aus `core.config`; eigener always-on Cron `cron_review_register` (estate hat kein Publish, das die geteilten Advisor-Crons einschalten könnte), selbst-still über den Latch, kein Chat-Toggle.
- `/notfall` ist ein Code-Pfad-Command (Manifest `dispatch`, visibility=all); Register-Rendering nur über `fn_render_register_body` (Overview = Wrapper, Binder = DEFINER mit Maskierung).
- Backup `schema_dump: true`; `directive_types` konvergiert nach Restore per Re-Seed.
