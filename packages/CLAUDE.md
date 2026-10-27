# Pakete — paket-übergreifende Konventionen (lädt beim Arbeiten in `packages/`)

Geteilte Gesetze für alle Pakete; Domänen-Deltas → `packages/<pkg>/CLAUDE.md`. Vertrags-Spec `docs/package-contract.md`, fn-Kontrakte `docs/fn_catalog.md` (generiert, nie hand-editieren). Mechanik, Fallgeschichten und Entscheidungs-Begründungen → `docs/reference/packages.md` (on-demand).

- **Schema-SoT** = die idempotenten `packages/<pkg>/db/*.sql` + `packages/<pkg>/db/migrations/R__fn_*.sql` (eine Function je Datei). Bei Schema-Änderung Init und R__ synchron halten; per-fn-Verhalten steht im Katalog, nicht in Doku.
- **DB-Gesetze — Migrations-Modell, Schema-Änderungs-Regeln, Integritäts-Konventionen, Naming, Rollen/Cross-Schema-Read-Regel, DB-Test-Pattern** → `.claude/rules/sql.md` (lädt automatisch beim Öffnen einer `.sql`).
- **Struktur-Invariante:** `layout_lint.ps1` erzwingt Top-Level-Allowlist, Paket-Contract (`manifest.json`+`CLAUDE.md`+`build/`+`workflows/`), Tests-Buckets, Retired-Roots (`db`, `n8n`), Sub-CLAUDE.md-Titel, Pathspec-Listen. Allow-Sets nur per reviewtem Edit der In-Skript-Arrays bzw. `scripts/build/retired_paths_allowlist.json` (mit Begründung) — das rote Gate ist der Kontrollpunkt, kein Fehler.

## Workflow-Bau

Autoren-Regeln für jeden Workflow/Def; Engine-Mechanik → `scripts/build/CLAUDE.md`, Lifecycle-Mechanik → `docs/reference/packages.md`.

- **IDs:** der Autor vergibt die 16-Zeichen-nanoid im Dateinamen `packages/<pkg>/workflows/<id>-<name>.json`; `import:workflow` ist id-erhaltend. Kein POST-zum-Minten, keine ID-Registry, keine hardcodierten Workflow-IDs — jede Cross-Referenz per `Get-RequiredWorkflowId` (name-aufgelöst aus dem Datei-State). Flow immer: `build.ps1` → Substrat `bootstrap_test_n8n.ps1` (spielt nur Geänderte ein; frisch: `-Reset`; Prod: `provision.sh`/`lifeagents update`).
- **Credentials nur als Platzhalter** `__CRED_*__` (Deploy tauscht sie); `Save-WorkflowFile` bricht bei echter id ab.
- **Core-Dienste nie über den physischen Namen:** Paket-Defs nutzen `core:<alias>` (`Resolve-CoreServiceAlias`, SSOT `packages/core/manifest.json` `provides.services`); Fremd-Paket-Werkzeuge nie literal binden, immer über `agent.sub_dispatch_tool` + `Add-ServiceTools` (Vertrag `docs/package-contract.md` §5.1). `inputs.*.description` ohne `'`/Backtick.
- **Neuer Def** gehört ins Paket, dessen Manifest ihn in `provides.{agents,tools,crons,routes}` führt → `packages/<pkg>/build/workflows/{,tools}/`; Discovery per AST, keine Registry.
- **Neues Tool / neuer Route-Agent:** Platzhalter `packages/<pkg>/workflows/<id>-<name>.json` mit `{}` VORAB anlegen (eigene 16-Zeichen-nanoid; die Agent-Def wird bei jedem Build ausgewertet und verlangt die ID schon im ersten Lauf, auch mit `-Only`) → `tools/<neu>.ps1` mit genau einer `Build-<Neu>`; Trigger-Inputs in `Build-Trigger` **und** `$fromAI`-Mapping in der Agent-Def → `build.ps1` → `-Reset`.
- **Agent-Eingang:** jeder Agent-Workflow (nicht Tool, nicht Orchestrator) trägt das Depth-Gate (`call_depth >= 2 → max_call_depth`). Paket-Agenten zusätzlich über `New-AdvisorGateChain`: Depth → Package-Active (`core.fn_package_active`, fail-open) → Core-first (`core.fn_onboarding_status('core')`, Antwort = `Build-Set`-Redirect, **nicht** `Build-ToolError`). Geteilt sind nur diese drei Gates; Onboarding-Pflicht-Gates sind paket-lokal NACH `Load Config`. Core-Agenten (monitor/guide) brauchen beides nicht. Paket-Crons gaten fail-closed (`fn_package_active AND cron_enable`).
- **Write-Tool** nur via `New-FnWriteGate` (→ `docs/reference/packages.md` *Tool-Bau*).
- **Falle `Build-Pg`:** Default ist die WRITE-Cred → bei RO-Reads post-construction `.credentials = <pkg>_ro` + `.onError='continueRegularOutput'` setzen, sonst still ignoriert. `New-AdvisorToolNode -StartNode` ist Pflicht (kein Default-Erben der chat_id-Quelle).
- **Capabilities-Manifest:** jedes nutzer-facing Tool gibt `Build-Workflow` `@{ Category = '<id>' }` **oder** `@{ Internal = $true }`; Texte + Beispiele im Katalog (`<pkg>.help.<id>.*`, deutsche Beispiele = Routing-Case-`task`s, `-VerifyCatalog`). Danach `build.ps1 -CatalogOnly` + committen.
- **Feste Nutzertexte nie als Literal:** Katalog-Key + `t`-Map (`Get-UiTextExpr`) bzw. `core.fn_ui_text` mit der Empfänger-Sprache; `ui_literal_lint` (Ratchet, §3.11).
- **Command-Registry:** Slash-Befehle leben im `commands`-Block des Manifests; `dispatch:{agent,task}` = Code-Pfad-Command (Build-Zeit-Switch), reiner Text-/Callback-Prefix = Laufzeit-`core.callback_handlers`. Switch-Fallback **zuletzt** dynamisch verdrahten (sonst ist jeder Chat-Text still tot). `PACK_BUDGET` → Referenz.

## n8n-Versionshinweise (2.45.4)

- **Typed Sub-Workflow Inputs** im Start-Node des Sub-Workflows deklarieren (`executeWorkflowTrigger` → `workflowInputs.values`), nicht im Aufrufer; immer `inputSource: "workflowInputs"` — `passthrough` unterdrückt jede Schema-Deklaration still. Beispiel → `docs/reference/packages.md`.
- **Node-`typeVersion`s bleiben beim n8n-Update stehen** (Owner-Phase 2026-10-20, Sprung über 23 Minor-Versionen): n8n führt gespeicherte Versionen unverändert weiter, neuere ändern Verhalten still (`executeWorkflowTrigger` 1.2/1.3 Rückgabe, `scheduleTrigger` 1.4 Nachholen, `lmChatAnthropic` 1.6 eigenes Caching). Ein Bump ist ein eigenes, testpflichtiges Feature. Versionsunabhängig: ein Postgres-SELECT liefert bei 0 Zeilen **kein** Item (seit 2.25 auch mit `WITH`/Kommentar vorn) → aggregieren (`count`/`jsonb_agg`), wenn der Folge-Node laufen muss; Tool-Read per id/Name → `New-RequiredRowGate`.
- n8n akzeptiert ungültige Parameter beim Publish und failt zur Laufzeit still → Node-Doku vor dem Bau; Nodes nur über die Helper (`Build-If`/`Build-Pg`/Telegram-Helper/Modell-Builder), direkt konstruierte Nodes sind Altlast. Jedes neue Gotcha wird als BUILDER (Helper verhindert es) oder LINT (Gate fängt es) klassifiziert, PROSA nur mit Grund.

### Build-Gotchas

Checkliste (Symptom → Fix; Fallgeschichten → `docs/reference/packages.md` *Build-Gotchas*):

- **IF `rightValue` typgerecht** (`true`/`1`, kein String; `Build-If` konvertiert). **Operatoren nur kanonisch** `gt/gte/lt/lte` — unbekannte Strings (`largerEqual`) publishen, routen aber **still immer false**; `Build-If`-Aliase nutzen, nie raten.
- **Jeder Postgres-Node = ein `jsonb`-Parameter** (`Build-Pg` mit `[ordered]@{…}` → `($1::jsonb)->>'feld'`): n8n droppt leere Werte in komma-getrennter `queryReplacement` (Parameter-Shift). Positionale `$1,$2` und `'__none__'`-Sentinel sind Altlast.
- **`$fromAI`:** keine Apostrophe in Descriptions (bricht den Parser); 3-arg = Pflichtfeld, 4. Argument `''` = optional; vom LLM aufgelöste IDs als `'string'` (es quotet gelegentlich), die fn castet.
- **Neuer Tool-Input an zwei Stellen:** `Build-Trigger` (Sub-Workflow-Start) **und** InputSpec des Agent-Bindings (`New-AdvisorToolNode`; im Buchhalter `New-ToolWorkflowNode`) — sonst kommt er als `undefined` an.
- **Deploy:** Sub-Workflows vor Aufrufern publishen; `POST /publish` (seit 2.33; `/activate` ist veraltet) braucht `Content-Type: application/json` + Body `{}` (415 in 1 s ist **nicht** der keepAlive-Hang). `deploy_workflows.sh` erledigt beides.
- **Ausdrücke:** bedingten Textteil klammern `Text + ((Bed) ? a : b)`; **nie `}}`** in einem Ausdruck, auch nicht im Text einer `$fromAI`-Beschreibung (JSON-Beispiele mit Leerzeichen `} }`); `workflow_lint` prüft JS-Syntax, die Rangfolge nicht.
- **Export-JSON:** Single-Quotes stehen als `'`; das Edit-Tool matcht sie nicht → PowerShell-Replace oder echte `'` schreiben.
- **Telegram nur über die Helper** (`New-TelegramSendNode`/`New-TelegramSendAndWaitNode`, Alert-Formatter in `core.sub_error_notify.ps1`): sie setzen `appendAttribution:false`, `retryOnFail`, escapen dynamischen Text (die vier Legacy-Markdown-Entities Unterstrich, Stern, eckige Klammer, Backtick; `sendAndWait` ist hart `Markdown`) und brechen den Build bei statischem Text mit Entities; `workflow_lint` prüft jeden Send.
- **LLM-Relay = `New-TelegramSendWithPlainFallback`:** Primary `retryOnFail:true`+`maxTries:1` **nicht „aufräumen"** (`retryOnFail`×`onError=Continue` ist in n8n defekt, GH #10763); der Fehler-Ausgang gatet bewusst nicht auf 400.
- **KNOWN ISSUE Telegram-Send hängt 3–5 Min:** Node.js-keepAlive-Socket, Upstream-Problem — nicht im Workflow debuggen (Memory `telegram-socket-fix-watch`).
- **Free-SQL `postgres_select`:** `onError='continueRegularOutput'` + Description „`SELECT *`, `information_schema`", keine Spaltenliste im Prompt. **Nie** auf deterministische `tool_*`-Nodes anwenden (dort ist ein DB-Fehler ein echter Defekt).
- **Bestätigen im Chat:** `New-TelegramSendAndWaitNode` setzt `chatApproval` als Deploy-Platzhalter und `approverIds` (Default nur bei literalem Ziel; Ausdruck-Ziel → `-ApproverIdsExpr` mit `.first()`, nie leer = „jeder darf"); Knopf-Texte + Popup sind Pflicht-Parameter (Katalog), `removeButtons` fest. n8n bindet einen Tipp an die Execution, nicht an die Nachricht → mehrere Fragen nacheinander in einer Execution brauchen `New-StaleTapGuard` (Muster `cron.remind_interest`).
- **HITL-Gate:** Stufe `self` (die eigene Person bestätigt, kein Owner-Send) nur für Workflows, die ausschließlich `agent.fn_set_own_context_facts` rufen (`approval_lint` (e)). `approval_tier` nie von Hand — SoT ist der `approval_matrix`-Block des besitzenden Pakets (`Set-ApprovalTier` injiziert, `approval_lint` prüft); `owner_only` doppelt gesichert (Gate + DB-Backstop); beim Ändern beide Stickies (`Doc HITL Dual-Control`, `Doc Zwei-Send-Risiko`) mitführen; der `test_e2e`-Sentinel-Switch bleibt bewusst.
- **Filter-/Selector-`conditions` und `connections` in Array-Form** schreiben (`conditions = @(…)`, `@(,@(…))`, Unary-Komma beim Serialisieren) — PS-`ConvertTo-Json` kollabiert sonst Einzel-Elemente, der Import failt.
- **Dynamisch generierte Nodes ins `$nodes`-Array mergen** — `build.ps1` validiert Node↔Connection nicht, `workflow_lint` fängt es beim Commit.
- **Prompt-Caching macht der LLM-Gateway, nicht der Node:** wechselnde Prompt-Teile (Absender, Onboarding, Haushalt, Manifest) nur ans ENDE des System-Prompts, nie `$now`/Datum; die n8n-2.37-Node-Option auch nach Update **aus** lassen.
- **`chat_id` ist produktiv eine Zahl:** String-Ops nur `String(… || '')`-gewrappt (`Build-If` wrappt automatisch; `workflow_lint` prüft Hand-Expressions + Orchestrator-Bindings).
- **Code-Node:** `runOnceForEachItem` returnt `{ json: {…} }`, nie ein Array (`workflow_lint` prüft Mode ↔ Shape).
- Außerdem: parametrisierte Query = nur ein Statement, `maxIterations`-Cap, Reverse-Proxy `/webhook-waiting/*` + `/webhook-waiting-telegram` für den HITL-Resume (Root-`CLAUDE.md`).

## Scheduled Workflows (`cron`)

- Dedizierter Workflow, Rolle `cron`, Scope nach Domäne (`agent.<pkg>.cron_*`); Defs `packages/*/build/workflows/cron.*.ps1`, Zuordnung = Manifest-`provides.crons`.
- **Schedule immer aus `core.config`:** `Build-ScheduleTrigger … -ScheduleKey '<job>'` schreibt `__CFG_SCHEDULE_<JOB>__`, `deploy_workflows.sh` setzt den Wert ein (n8n liest den Plan statisch beim Aktivieren); Cron-Expression als `config.schedule.<job>` im Manifest. Schwellen zur Laufzeit per `core.fn_config_get` lesen, nie einbacken; LLM-Schritte lesen ihr Modell über `New-ModelConfigNode`.
- **Ableiten statt materialisieren:** Pattern speichern, Vorkommen per testbarer `fn_*(p_date)` berechnen (DB-Test zuerst, Vorlage `test_fn_recurring_due_open.sql`); nur nicht-ableitbaren State (Skips) materialisieren.
- **Dialog nur Button-wählbar** (`New-TelegramSendAndWaitNode`, 2 Buttons; >2 Ausgänge = Stufen-Dialog). Reiner Reminder mit Freitext-Antwort ⟹ `sendMessage` — Text erreicht ein offenes Gate nicht.
- **Loop = `splitInBatches` v3:** `main[0]=done`, `main[1]=loop`, alle Zweige zurück zur Loop-Node.
- Deterministische Crons brauchen keine Agent-Test-Tier; `config_test` deckt Platzhalter ⟺ Manifest ab. Beispiel `cron_reconcile_accounts` → `docs/reference/packages.md` *Scheduled Workflows*.

## Tool-Bau: paket-übergreifende Verträge

- **KI-Tool-Namen:** gebundene Write-Tools tragen `tool_` (spiegelt den Workflow-Namen minus Scope); bare bleiben nur `web_search`/`postgres_select`/`load_context`/`expert_panel`. Geteilte Tools unter fachlichem KI-Namen bleiben stabil (LLM-Vertrag). Node-Namen + `errorMessage` Englisch, Stickies Deutsch, gespeicherte `description` Deutsch.
- **Sticky-Pflicht:** DB-Automatik (Trigger, GENERATED, CHECK) als `Build-Sticky` an der Stelle im Tool; bei `agent.fn_*`-Tools zählt die Sticky die Function-Schritte auf. Nach jedem Graph-Edit Stickies gegenlesen.

### Verb-Taxonomie

- **`create_*`** neue Stammdaten-Entität (Pflicht-Dubletten-Node; darf verknüpfte Zeilen erzeugen). Ausnahme `create_case_task` (disposable Child, kein Dubletten-Node, kein HITL).
- **`book_*`** verbucht Transaktionen auf bestehende Entitäten. **`set_*`** partielles UPDATE (`COALESCE(NULLIF(p->>'feld',''), spalte)`), legt nichts an; entitäts-besessene Recurring in-place ändern und beim Deaktivieren mit-pausieren; Validity-Split nur im standalone `set_recurring_payment`.
- **`record_*`** idempotenter UPSERT auf externen Schlüssel · **`cancel_*`** Abbruch auf terminalen Nicht-Erfolgs-Status mit Historie · **`export_*`** Datei-Egress (erster gegateter READ-Egress) — alle Rang 0 (`owner_info`-fähig) in der **einen** Verb→Rang-Map `scripts/build/lib/approval_matrix.ps1` + `approval_matrix`-Block des Pakets. **`reset_*`** nie Agent-Tool (Owner-Ops), abgegrenzt von `purge` (Paket-Deinstallation) und `clear_*` (Test-Sentinel).
- Read/Helper: `resolve_*` (Name→ID, 0/>1 → `Build-ToolError`), `get_*`, `fetch_*`, `verify_*`/`validate_*`, `<entity>_context()`. Begründungen → `docs/reference/packages.md` *Entscheidungen*.

### Post-State-Vertrag (Erfolgs-Rückgabe)

Jede Write-`fn` gibt im `ok:true` **genau drei Kategorien** zurück, sonst nichts: (1) Handles (`id`s erzeugter/berührter Entitäten), (2) berührten Post-State (neuer Saldo **jedes** berührten Kontos, `shares`/`avg`, `remaining_debt`, `status` — **in der fn, nach dem Trigger, in derselben Transaktion** gelesen, kein separater Read-back-Node, kein breiter Snapshot), (3) DB-berechnete Größen, die der Aufrufer nicht geliefert hat. **Kein** Echo von Aufrufer-Eingaben, **keine** nackten Counts (außer der Count ist die Information). Jedes neue Return-Feld bekommt eine Zahlen-Assertion in `test_fn_*.sql`.

### Korrigierbare Ablehnung

Nutzer-korrigierbare Fehler (Oversell, Über-/Unterzahlung, nicht-positive Beträge, Typ-Mismatch, gleiches Quell-/Zielkonto …) gibt die fn **vor** dem Write als Daten zurück: `{ok:false, reason:'<EN mit Beträgen>', <zahlfelder>}` — kein RAISE (der würde `core.sub_error_notify` einen Owner-Alert je Fehlgriff feuern lassen). Tool-Graph: `Build-If 'Write ok?'` → false: `Build-ToolError` mit `reason`. Echte Ausnahmen (not-found, already-closed, DB-CHECK/Trigger) bleiben RAISE; `Build-Err` nur für Schreibfehler nach Approval. Wo möglich zusätzlich ein spiegelnder `CHECK` als Backstop.

### HITL-Bestätigungs-Format

- **Die Karte ist eine Struktur, kein Text:** `New-HitlSummary` (Titel-Key + `New-HitlLine`/`New-HitlNote`, typisierte Rohwerte); das Gate rendert sie je Empfänger in dessen Sprache (`workflow_lint` lehnt String-Summaries ab). Texte als Keys im Textkatalog des Pakets (`docs/package-contract.md` §3.11), Keys prüft der Build.
- Titel `Verb + Objekt – bitte prüfen:`; ein Feld pro Zeile `• <Label>: <Wert>`, Labels nutzerfreundlich (nie DB-Spaltennamen); ENUMs als `-Kind enum` (Wert-Key `<pkg>.enum.<typ>.<wert>`).
- **Beträge und Daten nur als `-Kind money`/`-Kind date`** (Intl im Locale des Empfängers) — nie hart „€"/„EUR"; Währung per `-Currency` aus der Zeile; festes `'EUR'` nur mit `-EurByModel`.
- **Je Art dieselben Zeilen**, leer = `—`; optionale Info ohne Wert `-OmitEmpty` (entfällt); `-If` für Unterart/Folgegruppen; Default `-IsDefault`. Plain text, kein Markdown (auch nicht im Katalog: `_ * [` Backtick). Buttons und lange Karten (Teile) macht das Gate.
- **Bei uns anders (Textkatalog):** einfache `{name}`-Platzhalter statt ICU/Fluent (keine Plural-/Genus-Fälle); Koreanisch setzt Namen als `{name} 님` statt einer Josa-Bibliothek.
