# Core-Paket — Domänen-Regeln (lädt beim Arbeiten in `packages/core/`)

Host-Paket: Agent-Plattform (Schemas `agent` + `core`) — Orchestrator, Guide, Monitor, die geteilten Registries und die Kern-Tabellen aller Agenten. SoT sind `packages/core/db/*.sql` + `packages/core/db/migrations/`; paket-übergreifende Gesetze → `packages/CLAUDE.md` + `.claude/rules/sql.md`; fn-Kontrakte → `docs/fn_catalog.md`; Mechanik der Registries, Tabellen und Flows → `docs/reference/core.md` (on-demand).

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
- **Relative Daten und Stempel macht die DB:** `core.fn_resolve_date` (feste Form `-3 days`/`in 3 weeks`/`next friday`, sonst NULL) ist die eine Adresse; Fakten/Plan-Abschnitte lösen `*_date`/`since` über `core.fn_resolve_fact_dates` auf (Genauigkeit folgt der Angabe: Jahre → `YYYY`). Write-fns lösen ihre Datums-Keys tagesgenau als erste Anweisung über `core.fn_resolve_input_dates(p, ARRAY[…])` auf (unlesbar → `{ok:false, code:'invalid_date'}`, Ergebnis in `effective`); den Feld-Hinweis fürs Modell liefert `Get-DateParamHint`, rohe `::date`-Casts auf Tool-Keys fangen `test_fn_relative_dates` (finance) und `contract_lint` (27, Tool-SQL). Karte und Write nutzen denselben aufgelösten Wert (Probelauf/Resolve-Knoten vor der Karte). `as_of` stempelt auf dem Chat-Pfad immer die fn, neue `family`-Personen bekommen den Slug von `agent.fn_person_slug`. Reservierte Form-Keys `persons` (Array mit eindeutigem `person_id`) und `household` (Objekt); per_user-Kontexte tragen kein `persons`.
- **Einziger Fakten-Schreibweg = `fn_set_context_facts`** (eigene per_user-Kontexte über den Delegaten `fn_set_own_context_facts`, scope fest per_user, HITL-Stufe `self`; Plan-Dokumente `core.advisors.plan_context` sind dort für alle gesperrt — nur `fn_advisor_publish_plan`) (Merge-Patch: `null` löscht nur den Patch-Key; Person entfernen nur `fn_remove_household_person`; Prosa nie leerbar). Household-Kontexte existieren nur als Installer-Skelett (`contract_lint` 16a); per_user-Kontexte `<base>__<pid>`, fail-closed bei unaufgelöstem Sender.
- **„Fakt im Header, Prosa verweist nur":** berechenbare Werte leben im `facts`-Sidecar, Renderer liefern nur den Header (Ableitungen render-at-fetch, nie gespeichert). Keine Modell-Kopplung in `core.advisors`; tunbare Werte in `core.config`.
- **Drei Flags:** `package` = Purge-Key · `managed_by` (`seed|build|agent`) = Overwrite-Guard (Seeder fasst `'agent'` nie an) · Löschschutz nur über die Registry `core.protected_contexts` (Manifest `protected_contexts`; nur Host/Deinstall entfernt den Eintrag; suffix-aware für `<base>__<pid>` lebender Personen). Neuer Entitätstyp: Systemzeile → `origin`, geschützter Context → Registry-Eintrag.
- **Advisor-Registry + Engine / Geteilte Notify-Dedup-Schicht / Löschschutz-Registry:** der Advisor-Latch wird an beiden Call-Sites (`fn_should_notify` + `fn_notify_reconcile`) mit derselben person-suffigierten `source` gesetzt; `metric_key` ohne Domänen-Präfix (`contract_lint` 14); Staleness-Alarme über `core.fn_staleness_alert`. Mechanik → `docs/reference/core.md`.
- `agent.persons` ist ein read-only Read-Model der `family`-Facts (FK-Ziel der `*_person_id`-Spalten, ON DELETE RESTRICT); Namen werden nie automatisch nachgetaggt. `finance_ro` darf `agent.persons` nicht direkt lesen → Fenster `core.fn_household_persons()` (Eltern-FIRE-Sicht schließt `role='child'` aus). `core.fn_resolve_person` ist tolerant (Vorname/Alias); 0 oder >1 Treffer → Tool bricht vor dem Gate ab.
- **Sprach-Präzedenz:** Antwortsprache = Sprache der Nutzer-Nachricht; der `language`-Fakt ist nur Fallback für ambige Turns, nie Override. Für **feste** Texte (Textkatalog) ist er dagegen maßgeblich: Code aus `core.ui_languages` (Validator), Fallback Owner-Sprache → `en` (`agent.fn_person_lang`); gesetzt per Installer, CLI-Picker oder Knopf-Karte (`lang:`-Callback; jede Person für sich per `/language`). Die Telegram-App-Sprache (`from.language_code`) ist nur ein Vorschlag (`pairing_state.language_hint`), nie ein stiller Write.
- **Wörtliches Weiterreichen (Orchestrator-Relay):** Spezialisten-Antworten sendet `Relay compose` wörtlich aus `intermediateSteps` (`returnIntermediateSteps`); der Router antwortet nach einem Tool nur `FRAME`/`NOFRAME`, der Rahmensatz kommt fest aus dem Katalog (`core.persona.frame.*`); schreibt er doch eine eigene Fassung, setzt `Router memory signal` sein Gedächtnis aufs Signal zurück (sonst ahmt er sie nach; n8n hat kein return_direct, der Chat Memory Manager schriebe nicht atomar → `fn_*`). Warum: der Router verfälschte Antworten (Live-Befund 2026-10-25). Handoff „Spezialist antwortet selbst" (OpenAI Agents SDK) bewusst nicht: ein Sende-Knoten, HITL-Sperre, Memory und Persona hängen am Orchestrator.
- **Bot-Persona = Rahmen nur im Orchestrator:** `persons[].persona` (Wertevorrat `core.ui_personas`, `neutral` = Key fehlt, Fallback immer neutral — keine Owner-Vererbung, Owner-Entscheid) erreicht als Runtime-Flag `persona` (via `fn_resolve_sender`) nur den Orchestrator-Prompt; Regeln in `contexts/persona_styles.md`. Warum: Spezialisten sehen die Persona nie und ihre Antwort geht wörtlich raus (Relay oben) → Zahlen und gespeicherte Inhalte bleiben bauartbedingt neutral, und es entsteht keine neue Cache-Variante der großen Fach-Prompts.

## Karte-offen-Sperre (`agent.hitl_pending`)

- Solange eine Gate-Karte offen ist, parkt n8n die ganze Kette dahinter; der Orchestrator beantwortet Nicht-Callback-Nachrichten dieses Chats deshalb mit festem Hinweis statt einem Agent-Lauf. **Bei uns anders** (arch-challenge 2026-10-22): eigene Tabelle statt n8n-Executions-Status (kein Pro-Chat-Wartezustand in n8n); Schlüssel ist der **Ursprungs-Chat** der Anfrage, nicht der Karten-Empfänger; mehrere Zeilen je Chat gewollt; `expires_at` ist die Wahrheit (Effizienz-Lock, fail-open, kein Fencing). Nach dem Tipp gibt das Gate die Zeile nur frei (kurze Gnadenfrist), gelöscht wird sie erst nach der Antwort des Orchestrators — sonst sähe eine sofort nachgeschobene Korrektur das Gedächtnis der Kartenrunde noch nicht. Gate-Crons ohne geparkte Unterhaltung sperren nicht.

## Eingangs-Bündelung (`agent.ingress_buffer`)

- Telegram liefert „Weiterleiten mit Kommentar“ als zwei Updates ohne verknüpfendes Feld und in offener Reihenfolge. Der Orchestrator-Eingang legt deshalb jede message ab (`fn_record_ingress_message`), wartet 1,5 s und beansprucht dann (`fn_claim_ingress_burst`): Ein Lauf verarbeitet alle Texte plus die früheste Datei desselben (chat, from), die anderen enden still. Jede weitere Datei, jeder Befehl und jede Sprachnachricht läuft für sich.
- Der Claim nimmt per eigener Anweisung zuerst den Advisory-Lock je Chat und liest erst danach (frischer Schnappschuss). Das Fenster gilt relativ zur eigenen Ankunft und reicht von 2 s davor bis 10 s danach. Eine ältere unbeanspruchte Zeile gehört zu einem Lauf, der nach einem DB-Fehler schon allein lief, und wird darum nicht ein zweites Mal verarbeitet. Die Zeitbasis ist `clock_timestamp()`. Fail-open: Bei jedem DB-Fehler läuft die Nachricht einzeln. Die Schleifen-Bremse sitzt zusätzlich im Graphen.
- **Bei uns anders** (arch-challenge 2026-10-23): kein Wiederaufnahme-Cron für Zeilen, deren Lauf während der 1,5–5 s stirbt. Ein n8n-Neustart verliert ohnehin jeden laufenden Lauf, und ein Lauf, der nach dem Zugriff stirbt, verliert die mit-beanspruchten Teile genauso wie heute seinen eigenen.

## Mini-App (`core.app_*`)

- Sichtbarkeit nur in der Bildschirm-fn, Rollenfrage nur über `core.fn_app_sees_household`; `core.fn_app_screen` wirft nie. → `docs/reference/core.md` *Mini-App*.

## Backup/Restore

CLI-only (`lifeagents backup`), nie über den Chat; `core.backup_key` nie rotieren. Mechanik → `provisioning/CLAUDE.md` *Backup/Restore*.

## Update im Chat (`core.update_requests`)

Callback `upd:now|retry:<tag>` (owner-only) legt höchstens einen offenen Auftrag an (Unique-Index = Gesetz); ausgeführt wird er nur vom root-Runner, nie von n8n. Die SemVer-Logik lebt allein in `core.fn_semver_cmp`; alle Runner-Meldungen (Karte, Start, Ergebnis, Fehler-Hilfe) baut die DB (`core.fn_release_card`, `core.fn_update_report`), bash sendet nur. Mechanik → `docs/reference/provisioning.md` *Update im Chat*.

## Multi-User-Pairing (`agent.pairing_state`)

- Nur die numerische `telegram_user_id` zählt, nie der Username (Identity-Rebinding-CVE). Challenge ≥ 8 alphanum (CHECK) + `fail_count`-Lockout.
- `owner-no-rearm` blockt nur einen gepairten Owner, nicht das Bootstrap-Skelett (sonst könnte der Zwei-Stufen-Bootstrap nie armieren). Re-Arm eines etablierten Owners nur per CLI.
- Jeder Bind läuft über `fn_merge_member_identity` (liest die aktuelle uid vorab → Doppel-Bind/Replay `{ok:false}`); der Validator fängt nur Intra-Payload-Kollisionen. `pairing_state` ist ephemer, nicht im Backup.

## Owner-Lifecycle + Sperrliste (`agent.access_blocks`)

- Block ist die stärkere Form: `fn_is_blocked` gatet `fn_register_knock` (erste Anweisung, kein Latch-Touch) und `fn_claim_`/`fn_consume_pairing_challenge`. Block/Unblock berühren die Knock-Dedup nie.
- Owner-Unlink ist erlaubt (Re-Link per `lifeagents household pair-owner`); nur das **Löschen** des Owners bleibt blockiert. CLI und Owner-Button laufen ohne HITL-Gate (`approval_matrix` unberührt).

## Onboarding-Zustand

- Tri-State `unknown|completed|skipped` als **`text + CHECK`**, kein Cross-Schema-ENUM (ein `::agent.<enum>`-Cast scheitert still unter `<pkg>_rw`). `completed` und `skipped` zählen beide als aufgelöst.
- `p_package` ist build-time-konstant, nie `$fromAI`. per_user-Pakete (career) onboarden pro Person; person_id aus `fn_resolve_sender`, fail-closed.
- **Haushalts-Sektionen (core + household-Pakete) setzt nur der Owner:** `fn_set_onboarding_section` lehnt ein Mitglied per `core.fn_check_write_permission('owner_only')` ab (sonst sperrte ein Reset von `household` per Core-first-Gate alle Paket-Agenten). Jedes `tool_set_onboarding_section` reicht dafür die build-fixe `chat_id` durch.
- EXECUTE auf `fn_onboarding_overview`/`fn_onboarding_pending_packages` nur in `util_create_core_ro.sql`, nicht in `fn_provision_package_roles` (Menü-Read unter `core_ro`); `<pkg>_rw` braucht `SELECT ON core.context_scopes`.
- Keine Guide→Paket-Delegation: jeder Paket-Agent onboardet seine Sektionen selbst (`tool_set_onboarding_section` mit festem `package`).
- **Plan-Schritt ≠ Abschnitt** (`plan_step`): nie in Fortschritt/Latch/Nachfassen (contract §3.2).
- **Den nächsten Bereich nennt die Karte, nicht das LLM:** jedes `tool_set_onboarding_section` endet mit `New-OnboardingProgressCallNode` (`core.sub_onboarding_progress`); Einmal-Ereignisse latcht `core.fn_onboarding_progress_event`. **Bei uns anders** (arch-challenge 2026-10-23): kein [Später]-Knopf an der Karte (eine Chat-Nachricht blockiert nichts, Nicht-Tippen *ist* später) und Menüs werden neu gesendet statt per `editMessageText` editiert (n8n-Telegram-Node ohne `message_id`-Kette).

## Lern-Loop (`agent.guide_learn_*`)

- Der Cron schreibt ausschließlich `guide_learn_*`, nie `core_contexts` (`contract_lint` 9); der einzige `core_contexts`-Schreibpfad ist die owner-gegatete `fn_approve_learn_candidate`.
- Der Protect-Trigger blockt nur DELETE → der Allowlist-Guard `core.fn_note_context_allowed` (nur `managed_by='agent'` ∧ `family` oder Plan-Dokument mit `learn_notes=true`) ist die einzige Sicherung gegen content-UPDATE von Instruktions-/Fakten-Kontexten. `## Gelernt` ist ein system-verwalteter Block.

## Zentral-Config (`core.config`)

- SSOT = `.config`-Block der Manifeste + `packages/core/seed/ai_models.json`; geseedet nur über `core.fn_config_seed` (Owner-Wert überlebt Updates). Werte typisiert (`value_type`, `minimum`/`maximum`) — Trigger lehnt ungültige Werte deutsch ab.
- Modell-Werte zeigen per FK auf `agent.ai_models`; die FKs liegen bewusst in `core:V024`, nicht im Init (Inits bleiben reihenfolge-tolerant). Apply/Seed-Reihenfolge: `ai_models` vor `core.config`.

## Paket-Framework (`core`-Schema)

- `active` wird immer zuletzt gesetzt; `fn_pkg_check_deps` vor jeder Mutation. Core kennt kein Paket: Paketschlüssel → `<pkg>.onboarding_state`, `<pkg>.fn_clear_e2e_data` per Konvention (`contract_lint` 17), Resets deny-by-default außer `COMMENT 'lifecycle:reference'`.
- **Falle:** `packages/finance/db/migrations/R__zz_drop_agent_finance_orphans.sql` droppt jede `agent.<fn>` mit finance-Zwilling gleicher Signatur — gewollt gleichnamige Core-fns gehören auf die dortige Ausnahmeliste (`touch_updated_at`, `fn_clear_e2e_data`).
- **Callback-Member-Gate ist DB-Gesetz:** `core.fn_dispatch_callback` re-resolvt den Sender selbst (Zero-Trust, kein Caller-Flag); `member_permeable` DEFAULT false; die feine Autorisierung bleibt im Handler (nie RAISE, `{ok,toast}`). Owner-Admin-Prefixes sind keine Registry-Handler. Einzige erlaubte Kollision mit einem `Callback action`-Arm: `onboarding` (`member_permeable: true`, `core.fn_handle_onboarding_cb`) — der Owner nimmt den Arm, Mitglieder die Registry (`contract_lint` 9).
- **`context_scopes`:** Suffix `<base>__<pid>` nur für Content/Metadata-I/O, für jeden Registry-Lookup gilt der Basis-Name; unaufgelöster Sender fail-closed. Purge löscht `protected_contexts` zuerst (Finalizer), dann in Reihenfolge — alles in einer Transaktion.
- Paket-Rollen haben keinen Zugriff auf `agent.*`/`core`-Tabellen; einziges Core-Lesefenster = die publizierten DEFINER-fns, EXECUTE-Grants in `fn_provision_package_roles`.

## Build-Deltas der Core-Workflows

- Orchestrator: die Route-Tools reichen `task` **deterministisch** aus dem Knoten `Agent input` weiter (Nutzernachricht wörtlich, kein `$fromAI` — der Router wählt nur, er formuliert nicht um; Hard Rule 4). `telegramTrigger`-`webhookId` ist build-stabil wie jede (`scripts/build/CLAUDE.md`), nie von Hand pinnen; der Deploy ersetzt id + webhookId des Triggers je Instanz (`provisioning/CLAUDE.md` *Dev-Ingress*). Router-Tools, Onboarding- und Command-Arme entstehen build-time aus den Manifesten und zielen auf `agent.sub_dispatch_agent`, nie literal auf Paket-Workflows.
- Anhänge: geroutet wird der opake Marker, nie der Dokument-Inhalt (PII-Datenminimierung); Dokumentarten stehen in der `router_description` des Pakets, `fallback_for: ["attachment"]` fängt Unklares.
- `web_search` und Monitor-Wertbeschaffung laufen über `New-AnthropicMessagesNode` (`scripts/build/CLAUDE.md`); Leerquery-Guard, UNTRUSTED-Header, `{ok:false}` auch bei abgeschnittener Antwort.
