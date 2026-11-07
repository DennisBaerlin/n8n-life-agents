# Core-Paket — Domänen-Regeln (lädt beim Arbeiten in `packages/core/`)

Host-Paket: Agent-Plattform (Schemas `agent` + `core`) — Orchestrator, Guide, Monitor, die geteilten Registries und die Kern-Tabellen aller Agenten. Paket-übergreifende Gesetze → `packages/CLAUDE.md` + `.claude/rules/sql.md`; Mechanik der Registries, Tabellen und Flows → `docs/reference/core.md`.

## Advisor-Plaene (`agent.advisor_plans`)

- Genau ein `draft` und ein `active` je `(domain, person_id)` — die Partial-UNIQUEs brauchen **`NULLS NOT DISTINCT`**, sonst kollidieren zwei household-NULL-Zeilen nicht und die Invariante gilt still nicht.
- `person_id` kommt nur aus `agent.fn_resolve_sender(chat_id)` (Registry-Scope), nie vom LLM; Owner-Anker `agent.fn_owner_person_id()`.
- Publish prüft vor dem Write, dass jeder Plan-Top-Block aus genau einer Sektion stammt (`jsonb_each`-Merge ist storage-order → Doppelung verlöre still eine Hälfte) → `{ok:false, reason}`.
## Trigger-Monitoring (`agent.monitor_*`)

- **Cron-vs-Trigger-Gesetz:** schreibt es in Domänen-Tabellen oder führt es einen Dialog → n8n-Cron (Entwickler baut ihn); beobachtet es nur einen Wert → Trigger-Zeile (Agent per HITL). Kein dritter Mechanismus, kein Workflow-Bau zur Laufzeit; `cron_check_triggers` ist der einzige Heartbeat.
- `package` ist der Lifecycle-/Purge-Owner (nicht die fachliche `domain`), je Binding fest (advisor `'finance'`, Monitor `'core'`), nie `$fromAI`. `fn_pkg_purge_data` räumt nur `origin='user'` — sonst bricht die Purge am Protect-Trigger ab.
- `spec_summary` der Read-Windows nur aus typisierten Spalten, nie aus `acquisition_spec`/`action_note` (Prompt-Injection-Echo). Web-Trigger: `check_interval >= 12h` (CHECK).

## Haushalts-Fakten-Schicht (`core_contexts` + `metadata.facts`)

- **Derived-Key-Denylist** gilt rekursiv über alle jsonb-Ebenen jedes Sidecars (`age/…/income/years_to_*`, Prefix `derived_/computed_`, `nominal`, `regelaltersgrenze/kindergeld`, Muster `*_year`, `(…_)age(_…)`, `years_since_*`, `is_minor/is_adult`; geplante Roh-Alter `start_age`/`planned_retirement_age`/`age_from`/`age_to` erlaubt); Roh-Inputs bleiben erlaubt, sonst open-world.
- **Relative Daten und Stempel macht die DB:** `core.fn_resolve_date` (feste Form `-3 days`/`in 3 weeks`/`next friday`, sonst NULL) ist die eine Adresse; Fakten/Plan-Abschnitte lösen `*_date`/`since` über `core.fn_resolve_fact_dates` auf (Genauigkeit folgt der Angabe). Write-fns lösen ihre Datums-Keys als erste Anweisung über `core.fn_resolve_input_dates(p, ARRAY[…])` auf (unlesbar → `{ok:false, code:'invalid_date'}`); Feld-Hinweis fürs Modell `Get-DateParamHint`, rohe `::date`-Casts fangen `test_fn_relative_dates` und `contract_lint` 27. Karte und Write nutzen denselben aufgelösten Wert. `as_of` stempelt die fn, Slugs neuer `family`-Personen `agent.fn_person_slug`. Reservierte Form-Keys `persons` (Array, eindeutige `person_id`) und `household`; per_user-Kontexte tragen kein `persons`.
- **Einziger Fakten-Schreibweg = `fn_set_context_facts`** (eigene per_user-Kontexte über `fn_set_own_context_facts`, HITL-Stufe `self`; Plan-Dokumente nur über `fn_advisor_publish_plan`). Merge-Patch: `null` löscht nur den Patch-Key; Person entfernen nur `fn_remove_household_person`; Prosa nicht leerbar. Household-Kontexte existieren nur als Installer-Skelett (`contract_lint` 16a); per_user-Kontexte `<base>__<pid>`, fail-closed bei unaufgelöstem Sender.
- **„Fakt im Header, Prosa verweist nur":** berechenbare Werte leben im `facts`-Sidecar, Renderer liefern nur den Header (Ableitungen render-at-fetch, nie gespeichert). Keine Modell-Kopplung in `core.advisors`, tunbare Werte in `core.config`.
- **Drei Flags:** `package` = Purge-Key · `managed_by` (`seed|build|agent`) = Overwrite-Guard (Seeder fasst `'agent'` nie an) · Löschschutz nur über die Registry `core.protected_contexts` (Manifest `protected_contexts`; nur Host/Deinstall entfernt den Eintrag; suffix-aware für `<base>__<pid>` lebender Personen). Neuer Entitätstyp: Systemzeile → `origin`, geschützter Context → Registry-Eintrag.
- **Advisor-Latch / Notify-Dedup:** der Latch wird an beiden Call-Sites (`fn_should_notify` + `fn_notify_reconcile`) mit derselben person-suffigierten `source` gesetzt; `metric_key` ohne Domänen-Präfix (`contract_lint` 14); Staleness-Alarme über `core.fn_staleness_alert`.
- `agent.persons` ist ein read-only Read-Model der `family`-Facts (FK-Ziel der `*_person_id`-Spalten, ON DELETE RESTRICT); Namen werden nicht automatisch nachgetaggt. Paket-Rollen lesen es nur über `core.fn_household_persons()`. `core.fn_resolve_person` ist tolerant (Vorname/Alias); 0 oder >1 Treffer → Tool bricht vor dem Gate ab.
- **Sprach-Präzedenz:** Antwortsprache = Sprache der Nutzer-Nachricht; der `language`-Fakt ist nur Fallback für ambige Turns. Für feste Texte (Textkatalog) ist er maßgeblich: Code aus `core.ui_languages`, Fallback Owner-Sprache → `en` (`agent.fn_person_lang`). Die Telegram-App-Sprache (`from.language_code`) ist nur ein Vorschlag (`pairing_state.language_hint`), kein stiller Write.
- **Wörtliches Weiterreichen (Orchestrator-Relay):** Spezialisten-Antworten sendet `Relay compose` wörtlich aus `intermediateSteps` (`returnIntermediateSteps`); der Router antwortet nach einem Tool nur `FRAME`/`NOFRAME`, der Rahmensatz kommt fest aus dem Katalog (`core.persona.frame.*`); schreibt er doch eine eigene Fassung, setzt `Router memory signal` sein Gedächtnis aufs Signal zurück (sonst ahmt er sie nach; n8n hat kein return_direct, der Chat Memory Manager schriebe nicht atomar → `fn_*`). Bei uns anders als Handoff „Spezialist antwortet selbst“: Sende-Knoten, HITL-Sperre, Memory und Persona hängen am Orchestrator.
- **Bot-Persona = Rahmen nur im Orchestrator:** `persons[].persona` (Wertevorrat `core.ui_personas`, `neutral` = Key fehlt, Fallback immer neutral, keine Owner-Vererbung) erreicht als Runtime-Flag `persona` (via `fn_resolve_sender`) nur den Orchestrator-Prompt; Regeln in `contexts/persona_styles.md`. Spezialisten sehen die Persona nie (Relay oben) → Zahlen bleiben neutral, keine neue Cache-Variante der Fach-Prompts. Herz/Sticker: nur DB-Regeln → Referenz *Bot mit Gesicht*.

## Karte-offen-Sperre (`agent.hitl_pending`)

- Solange eine Gate-Karte offen ist, parkt n8n die ganze Kette dahinter; der Orchestrator beantwortet Nicht-Callback-Nachrichten dieses Chats deshalb mit festem Hinweis statt einem Agent-Lauf. Bei uns anders: eigene Tabelle statt n8n-Executions-Status; Schlüssel ist der Ursprungs-Chat, nicht der Karten-Empfänger; mehrere Zeilen je Chat gewollt; `expires_at` ist die Wahrheit (fail-open, kein Fencing). Nach dem Tipp gibt das Gate die Zeile nur frei, gelöscht wird sie erst nach der Antwort des Orchestrators (sonst sähe eine sofort nachgeschobene Korrektur das Gedächtnis der Kartenrunde nicht). Gate-Crons ohne geparkte Unterhaltung sperren nicht.
- Wiederhol-Sperre (`decline_key`) → `docs/reference/core.md`.

## Eingangs-Bündelung (`agent.ingress_buffer`)

- Telegram liefert „Weiterleiten mit Kommentar“ als zwei unverknüpfte Updates in offener Reihenfolge. Der Orchestrator-Eingang legt deshalb jede message ab (`fn_record_ingress_message`), wartet 1,5 s und beansprucht dann (`fn_claim_ingress_burst`): Ein Lauf verarbeitet alle Texte und alle Dateien desselben (chat, from), die anderen enden still. Jeder Befehl und jede Sprachnachricht läuft für sich.
- Mehrere Dateien, Grenzen, *Bei uns anders* → `docs/reference/core.md` *Eingangs-Bündelung*.
- Der Claim nimmt per eigener Anweisung zuerst den Advisory-Lock je Chat und liest erst danach (frischer Schnappschuss). Eine ältere unbeanspruchte Zeile gehört zu einem Lauf, der nach einem DB-Fehler schon allein lief, und wird darum nicht ein zweites Mal verarbeitet. Fail-open: Bei jedem DB-Fehler läuft die Nachricht einzeln.
- **Bei uns anders:** kein Wiederaufnahme-Cron für Zeilen, deren Lauf in den 1,5–5 s stirbt (ein n8n-Neustart verliert ohnehin jeden laufenden Lauf).

## Mini-App (`core.app_*`)

- Sichtbarkeit nur in der Bildschirm-fn, Rollenfrage nur über `core.fn_app_sees_household`; `core.fn_app_screen` wirft nie. → `docs/reference/core.md` *Mini-App*.

## Backup/Restore

Nur per CLI (`lifeagents backup`), nicht über den Chat → `provisioning/CLAUDE.md` *Backup/Restore*.

## Update im Chat (`core.update_requests`)

Callback `upd:` ist owner-only und legt höchstens einen offenen Auftrag an (Unique-Index); SemVer nur in `core.fn_semver_cmp`; alle Runner-Meldungen baut die DB (`core.fn_release_card`, `core.fn_update_report`), bash sendet nur. Brücke und Runner → `provisioning/CLAUDE.md` *Update im Chat*.

## Multi-User-Pairing (`agent.pairing_state`)

- Nur die numerische `telegram_user_id` zählt, nie der Username (Identity-Rebinding-CVE). Challenge ≥ 8 alphanum (CHECK) + `fail_count`-Lockout.
- `owner-no-rearm` blockt nur einen gepairten Owner, nicht das Bootstrap-Skelett. Re-Arm eines etablierten Owners nur per CLI.
- Jeder Bind läuft über `fn_merge_member_identity` (Doppel-Bind/Replay → `{ok:false}`); der Validator fängt nur Intra-Payload-Kollisionen. `pairing_state` ist ephemer, nicht im Backup.

## Owner-Lifecycle + Sperrliste (`agent.access_blocks`)

- Block ist die stärkere Form: `fn_is_blocked` gatet `fn_register_knock` (erste Anweisung, kein Latch-Touch) und `fn_claim_`/`fn_consume_pairing_challenge`. Block/Unblock berühren die Knock-Dedup nie.
- Owner-Unlink ist erlaubt (Re-Link per `lifeagents household pair-owner`); nur das Löschen des Owners bleibt blockiert. CLI und Owner-Button laufen ohne HITL-Gate (`approval_matrix` unberührt).

## Onboarding-Zustand

- Tri-State `unknown|completed|skipped` als **`text + CHECK`**, kein Cross-Schema-ENUM (ein `::agent.<enum>`-Cast scheitert still unter `<pkg>_rw`). `completed` und `skipped` zählen beide als aufgelöst.
- `p_package` ist build-time-konstant, nie `$fromAI`. per_user-Pakete (career) onboarden pro Person; person_id aus `fn_resolve_sender`, fail-closed.
- **Haushalts-Sektionen (core + household-Pakete) setzt nur der Owner:** `fn_set_onboarding_section` lehnt ein Mitglied per `core.fn_check_write_permission('owner_only')` ab. Jedes `tool_set_onboarding_section` reicht dafür die build-fixe `chat_id` durch.
- EXECUTE auf `fn_onboarding_overview`/`fn_onboarding_pending_packages` nur in `util_create_core_ro.sql`, nicht in `fn_provision_package_roles`; `<pkg>_rw` braucht `SELECT ON core.context_scopes`.
- Keine Guide→Paket-Delegation: jeder Paket-Agent onboardet seine Sektionen selbst (`tool_set_onboarding_section` mit festem `package`).
- **Plan-Schritt ≠ Abschnitt** (`plan_step`): nie in Fortschritt/Latch/Nachfassen (contract §3.2).
- **Knopf-Folge-Bindung** (`agent.dispatch_followup`): einmalig je Chat, danach trägt das Router-Gedächtnis (`agent.fn_set_router_button_turn`); nur Privatchats → contract §3.2.
- **Den nächsten Bereich nennt die Karte, nicht das LLM:** jedes `tool_set_onboarding_section` endet mit `New-OnboardingProgressCallNode` (`core.sub_onboarding_progress`); Einmal-Ereignisse latcht `core.fn_onboarding_progress_event`. Bei uns anders: kein [Später]-Knopf (Nicht-Tippen ist später); Menüs werden neu gesendet statt editiert (n8n-Telegram-Node ohne `message_id`-Kette).

## Lern-Loop (`agent.guide_learn_*`)

- Der Cron schreibt ausschließlich `guide_learn_*`, nie `core_contexts` (`contract_lint` 9); der einzige `core_contexts`-Schreibpfad ist die owner-gegatete `fn_approve_learn_candidate`.
- Der Protect-Trigger blockt nur DELETE → der Allowlist-Guard `core.fn_note_context_allowed` ist die einzige Sicherung gegen content-UPDATE von Instruktions- und Fakten-Kontexten. `## Gelernt` ist ein system-verwalteter Block.

## Zentral-Config (`core.config`)

- SSOT = `.config`-Block der Manifeste + `packages/core/seed/ai_models.json`; geseedet nur über `core.fn_config_seed` (Owner-Wert überlebt Updates). Werte typisiert (`value_type`, `minimum`/`maximum`) — Trigger lehnt ungültige Werte deutsch ab.
- Modell-Werte zeigen per FK auf `agent.ai_models`; die FKs liegen bewusst in `core:V024`, nicht im Init (Inits bleiben reihenfolge-tolerant). Apply/Seed-Reihenfolge: `ai_models` vor `core.config`.

## Paket-Framework (`core`-Schema)

- `active` wird immer zuletzt gesetzt; `fn_pkg_check_deps` vor jeder Mutation. Core kennt kein Paket: Paketschlüssel → `<pkg>.onboarding_state`, `<pkg>.fn_clear_e2e_data` per Konvention (`contract_lint` 17), Resets deny-by-default außer `COMMENT 'lifecycle:reference'`.
- **Falle:** `packages/finance/db/migrations/R__zz_drop_agent_finance_orphans.sql` droppt jede `agent.<fn>` mit finance-Zwilling gleicher Signatur — gewollt gleichnamige Core-fns gehören auf die dortige Ausnahmeliste (`touch_updated_at`, `fn_clear_e2e_data`).
- **Callback-Member-Gate ist DB-Gesetz:** `core.fn_dispatch_callback` re-resolvt den Sender selbst (Zero-Trust); `member_permeable` DEFAULT false; die feine Autorisierung bleibt im Handler (kein RAISE, `{ok,toast}`); Owner-Admin-Prefixes sind keine Registry-Handler. Einzige erlaubte Kollision mit einem `Callback action`-Arm: `onboarding` (Owner nimmt den Arm, Mitglieder die Registry; `contract_lint` 9).
- **`context_scopes`:** Suffix `<base>__<pid>` nur für Content/Metadata-I/O, für jeden Registry-Lookup gilt der Basis-Name; unaufgelöster Sender fail-closed. Purge löscht `protected_contexts` zuerst (Finalizer), dann in Reihenfolge — alles in einer Transaktion.

## Build-Deltas der Core-Workflows

- Orchestrator: die Route-Tools reichen `task` deterministisch aus dem Knoten `Agent input` weiter (Nutzernachricht wörtlich, kein `$fromAI`: der Router wählt nur). Die `webhookId` des `telegramTrigger` nicht von Hand pinnen; der Deploy ersetzt id + webhookId je Instanz (`provisioning/CLAUDE.md` *Gotchas*, Dev-Ingress). Router-Tools, Onboarding- und Command-Arme entstehen build-time aus den Manifesten und zielen auf `agent.sub_dispatch_agent`.
- Anhänge: geroutet wird der opake Marker, nie der Dokument-Inhalt (PII-Datenminimierung); Dokumentarten stehen in der `router_description` des Pakets, `fallback_for: ["attachment"]` fängt Unklares.
- `web_search` und Monitor-Wertbeschaffung: Leerquery-Guard, UNTRUSTED-Header, `{ok:false}` auch bei abgeschnittener Antwort.
