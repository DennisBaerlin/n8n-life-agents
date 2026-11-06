# Pakete — paket-übergreifende Konventionen (lädt beim Arbeiten in `packages/`)

Geteilte Gesetze für alle Pakete; Domänen-Deltas → `packages/<pkg>/CLAUDE.md`. Vertrag `docs/package-contract.md`, fn-Kontrakte `docs/fn_catalog.md`, Mechanik und Begründungen → `docs/reference/packages.md`.

- **Schema-SoT** = die idempotenten `packages/<pkg>/db/*.sql` + `R__fn_*.sql` (eine Function je Datei); Init und R__ synchron halten, per-fn-Verhalten steht im Katalog. DB-Gesetze → `.claude/rules/sql.md`.
- **Struktur-Invariante** (`layout_lint.ps1`): Allow-Sets nur per begründetem Edit der In-Skript-Arrays bzw. `scripts/build/retired_paths_allowlist.json`; das rote Gate ist der Kontrollpunkt, kein Fehler.

## Workflow-Bau

Autoren-Regeln für jeden Workflow/Def; Engine-Mechanik → `scripts/build/CLAUDE.md`, Lifecycle-Mechanik → `docs/reference/packages.md`.

- **IDs:** der Autor vergibt die 16-Zeichen-nanoid im Dateinamen `packages/<pkg>/workflows/<id>-<name>.json`; `import:workflow` ist id-erhaltend. Keine hardcodierten Workflow-IDs: jede Cross-Referenz per `Get-RequiredWorkflowId` (name-aufgelöst). Flow: `build.ps1` → Substrat `bootstrap_test_n8n.ps1` (spielt nur Geänderte ein; frisch: `-Reset`).
- **Credentials nur als Platzhalter** `__CRED_*__` (Deploy tauscht sie); `Save-WorkflowFile` bricht bei echter id ab.
- **Core-Dienste nie über den physischen Namen:** Paket-Defs nutzen `core:<alias>` (`Resolve-CoreServiceAlias`, SSOT `packages/core/manifest.json` `provides.services`); Fremd-Paket-Werkzeuge nie literal binden, immer über `agent.sub_dispatch_tool` + `Add-ServiceTools` (Vertrag `docs/package-contract.md` §5.1). `inputs.*.description` ohne `'`/Backtick.
- **Neuer Def** gehört ins Paket, dessen Manifest ihn in `provides.{agents,tools,crons,routes}` führt → `packages/<pkg>/build/workflows/{,tools}/`; Discovery per AST, keine Registry.
- **Neues Tool / neuer Route-Agent:** Platzhalter `packages/<pkg>/workflows/<id>-<name>.json` mit `{}` VORAB anlegen (eigene 16-Zeichen-nanoid; die Agent-Def wird bei jedem Build ausgewertet und verlangt die ID schon im ersten Lauf, auch mit `-Only`) → `tools/<neu>.ps1` mit genau einer `Build-<Neu>`; Trigger-Inputs in `Build-Trigger` und `$fromAI`-Mapping in der Agent-Def → `build.ps1` → `-Reset`.
- **Agent-Eingang:** jeder Agent-Workflow (nicht Tool, nicht Orchestrator) trägt das Depth-Gate (`call_depth >= 2 → max_call_depth`; `call_depth` = Tiefe des Empfängers: Root 0, Sub-Agent `caller_depth + 1`, Tools keines). Paket-Agenten zusätzlich über `New-AdvisorGateChain`: Depth → Package-Active (`core.fn_package_active`, fail-open) → Core-first (`core.fn_onboarding_status('core')`, Antwort = `Build-Set`-Redirect, nicht `Build-ToolError`). Geteilt sind nur diese drei Gates; Onboarding-Pflicht-Gates sind paket-lokal NACH `Load Config`. Core-Agenten (monitor/guide) brauchen beides nicht. Paket-Crons gaten fail-closed (`fn_package_active AND cron_enable`).
- **Write-Tool** nur via `New-FnWriteGate` (→ `docs/reference/packages.md` *Tool-Bau*).
- **Falle `Build-Pg`:** Default ist die WRITE-Cred → bei RO-Reads post-construction `.credentials = <pkg>_ro` + `.onError='continueRegularOutput'` setzen, sonst still ignoriert. `New-AdvisorToolNode -StartNode` ist Pflicht (kein Default-Erben der chat_id-Quelle).
- **Capabilities-Manifest:** jedes nutzer-facing Tool gibt `Build-Workflow` `@{ Category = '<id>' }` oder `@{ Internal = $true }`; Texte + Beispiele im Katalog (`<pkg>.help.<id>.*`, deutsche Beispiele = Routing-Case-`task`s, `-VerifyCatalog`). Danach `build.ps1 -CatalogOnly` + committen.
- **Feste Nutzertexte nie als Literal:** Katalog-Key + `t`-Map (`Get-UiTextExpr`) bzw. `core.fn_ui_text` mit der Empfänger-Sprache; `ui_literal_lint` (Ratchet, §3.11).
- **Command-Registry:** Slash-Befehle leben im `commands`-Block des Manifests; `dispatch:{agent,task}` = Code-Pfad-Command (Build-Zeit-Switch), reiner Text-/Callback-Prefix = Laufzeit-`core.callback_handlers`. Switch-Fallback zuletzt dynamisch verdrahten (sonst bleibt Chat-Text still).

## n8n-Versionshinweise (2.45.4)

- **Typed Sub-Workflow Inputs** im Start-Node des Sub-Workflows deklarieren (`executeWorkflowTrigger` → `workflowInputs.values`), nicht im Aufrufer; immer `inputSource: "workflowInputs"` — `passthrough` unterdrückt jede Schema-Deklaration still.
- **Node-`typeVersion`s bleiben beim n8n-Update stehen**: neuere ändern Verhalten still (z. B. `scheduleTrigger` 1.4 Nachholen, `lmChatAnthropic` 1.6 eigenes Caching); ein Bump ist ein eigenes, getestetes Feature. Ein Postgres-SELECT liefert bei 0 Zeilen kein Item (auch mit `WITH`/Kommentar vorn) → aggregieren (`count`/`jsonb_agg`), wenn der Folge-Node laufen muss; Tool-Read per id/Name → `New-RequiredRowGate`.
- Nodes nur über die Helper (`Build-If`/`Build-Pg`/Telegram-Helper/Modell-Builder), direkt konstruierte Nodes sind Altlast. Ein neues Gotcha wird Builder (Helper verhindert es) oder Lint (Gate fängt es), Prosa nur mit Grund.

### Build-Gotchas

Symptom → Fix; Fallgeschichten → `docs/reference/packages.md` *Build-Gotchas*.

- **IF `rightValue` typgerecht** (`true`/`1`, kein String; `Build-If` konvertiert). Operatoren nur kanonisch `gt/gte/lt/lte` — unbekannte Strings (`largerEqual`) publishen, routen aber still immer false; `Build-If`-Aliase nutzen, nie raten.
- **Jeder Postgres-Node = ein `jsonb`-Parameter** (`Build-Pg` mit `[ordered]@{…}` → `($1::jsonb)->>'feld'`): n8n droppt leere Werte in komma-getrennter `queryReplacement` (Parameter-Shift). Positionale `$1,$2` und `'__none__'`-Sentinel sind Altlast.
- **`$fromAI`:** keine Apostrophe in Descriptions (bricht den Parser); 3-arg = Pflichtfeld, 4. Argument `''` = optional; vom LLM aufgelöste IDs als `'string'` (es quotet gelegentlich), die fn castet.
- **Neuer Tool-Input an zwei Stellen:** `Build-Trigger` (Sub-Workflow-Start) und InputSpec des Agent-Bindings (`New-AdvisorToolNode`; im Buchhalter `New-ToolWorkflowNode`) — sonst kommt er als `undefined` an.
- **Deploy:** Sub-Workflows vor Aufrufern publishen; `POST /publish` braucht `Content-Type: application/json` + Body `{}` (415 in 1 s ist nicht der keepAlive-Hang); `deploy_workflows.sh` erledigt beides.
- **Ausdrücke:** bedingten Textteil klammern `Text + ((Bed) ? a : b)`; **nie `}}`** in einem Ausdruck, auch nicht im Text einer `$fromAI`-Beschreibung (JSON-Beispiele mit Leerzeichen `} }`); `workflow_lint` prüft JS-Syntax, die Rangfolge nicht.
- **Export-JSON:** Single-Quotes stehen als `'`; das Edit-Tool matcht sie nicht → PowerShell-Replace.
- **Telegram nur über die Helper** (`New-TelegramSendNode`/`New-TelegramSendAndWaitNode`, Alert-Formatter in `core.sub_error_notify.ps1`): sie setzen Attribution, Retry und das Escaping der Legacy-Markdown-Entities (`sendAndWait` ist hart `Markdown`); `workflow_lint` prüft jeden Send.
- **LLM-Relay = `New-TelegramSendWithPlainFallback`:** Primary `retryOnFail:true`+`maxTries:1` nicht „aufräumen" (`retryOnFail`×`onError=Continue` ist in n8n defekt, GH #10763); der Fehler-Ausgang gatet bewusst nicht auf 400.
- **KNOWN ISSUE Telegram-Send hängt 3–5 Min:** Node.js-keepAlive-Socket, Upstream-Problem — nicht im Workflow debuggen.
- **Free-SQL `postgres_select`:** `onError='continueRegularOutput'` + Description „`SELECT *`, `information_schema`", keine Spaltenliste im Prompt außer `view_hints.ps1`. Nie auf deterministische `tool_*`-Nodes anwenden (dort ist ein DB-Fehler ein echter Defekt).
- **Bestätigen im Chat:** `New-TelegramSendAndWaitNode` setzt `chatApproval` und `approverIds` (Ausdruck-Ziel → `-ApproverIdsExpr` mit `.first()`, leer hieße „jeder darf"). n8n bindet einen Tipp an die Execution, nicht an die Nachricht → mehrere Fragen nacheinander in einer Execution brauchen `New-StaleTapGuard` (Muster `cron.remind_interest`).
- **HITL-Gate:** `approval_tier` kommt aus dem `approval_matrix`-Block des besitzenden Pakets (`Set-ApprovalTier` injiziert, `approval_lint` prüft, auch Stufe `self`); `owner_only` ist doppelt gesichert (Gate + DB-Backstop); beim Ändern beide Stickies (`Doc HITL Dual-Control`, `Doc Zwei-Send-Risiko`) mitführen; der `test_e2e`-Sentinel-Switch bleibt bewusst.
- **Filter-/Selector-`conditions` und `connections` in Array-Form** schreiben (`conditions = @(…)`, `@(,@(…))`, Unary-Komma beim Serialisieren) — PS-`ConvertTo-Json` kollabiert sonst Einzel-Elemente, der Import failt.
- **Prompt-Caching macht der LLM-Gateway, nicht der Node:** wechselnde Prompt-Teile (Absender, Onboarding, Haushalt, Manifest) nur ans ENDE des System-Prompts, nie `$now`/Datum; die n8n-2.37-Node-Option auch nach Update aus lassen.
- **`chat_id` ist produktiv eine Zahl:** String-Ops nur `String(… || '')`-gewrappt (`Build-If` wrappt automatisch; `workflow_lint` prüft Hand-Expressions + Orchestrator-Bindings).
- **Code-Node:** `runOnceForEachItem` returnt `{ json: {…} }`, nie ein Array (`workflow_lint` prüft Mode ↔ Shape).
- Außerdem: parametrisierte Query = nur ein Statement, `maxIterations`-Cap, Reverse-Proxy `/webhook-waiting/*` + `/webhook-waiting-telegram` für den HITL-Resume.

## Scheduled Workflows (`cron`)

- Dedizierter Workflow, Rolle `cron`, Scope nach Domäne (`agent.<pkg>.cron_*`); Defs `packages/*/build/workflows/cron.*.ps1`, Zuordnung = Manifest-`provides.crons`.
- **Schedule immer aus `core.config`:** `Build-ScheduleTrigger … -ScheduleKey '<job>'` schreibt `__CFG_SCHEDULE_<JOB>__`, `deploy_workflows.sh` setzt den Wert ein (n8n liest den Plan statisch beim Aktivieren); Cron-Expression als `config.schedule.<job>` im Manifest. Schwellen zur Laufzeit per `core.fn_config_get` lesen, nie einbacken; LLM-Schritte lesen ihr Modell über `New-ModelConfigNode`.
- **Ableiten statt materialisieren:** Pattern speichern, Vorkommen per testbarer `fn_*(p_date)` berechnen (DB-Test zuerst, Vorlage `test_fn_recurring_due_open.sql`); nur nicht-ableitbaren State (Skips) materialisieren.
- **Dialog nur Button-wählbar** (`New-TelegramSendAndWaitNode`, 2 Buttons; >2 Ausgänge = Stufen-Dialog). Reiner Reminder mit Freitext-Antwort ⟹ `sendMessage` — Text erreicht ein offenes Gate nicht.
- **Loop = `splitInBatches` v3:** `main[0]=done`, `main[1]=loop`, alle Zweige zurück zur Loop-Node.
- Deterministische Crons brauchen keine Agent-Test-Tier (Beispiel → `docs/reference/packages.md` *Scheduled Workflows*).

## Tool-Bau: paket-übergreifende Verträge

- **KI-Tool-Namen:** gebundene Write-Tools tragen `tool_` (Workflow-Name minus Scope), bare nur `web_search`/`postgres_select`/`load_context`/`expert_panel`; geteilte Tools behalten ihren KI-Namen (LLM-Vertrag). Node-Namen + `errorMessage` Englisch, Stickies Deutsch, gespeicherte `description` Deutsch.
- **Stickies im Tool:** DB-Automatik (Trigger, GENERATED, CHECK) als `Build-Sticky` an der Stelle im Tool; bei `agent.fn_*`-Tools zählt die Sticky die Function-Schritte auf.

### Verb-Taxonomie

- **`create_*`** neue Stammdaten-Entität (Pflicht-Dubletten-Node; darf verknüpfte Zeilen erzeugen). Ausnahme `create_case_task` (disposable Child, kein Dubletten-Node, kein HITL).
- **`book_*`** verbucht Transaktionen auf bestehende Entitäten. **`set_*`** partielles UPDATE (`COALESCE(NULLIF(p->>'feld',''), spalte)`), legt nichts an; entitäts-besessene Recurring in-place ändern und beim Deaktivieren mit-pausieren; Validity-Split nur im standalone `set_recurring_payment`.
- **`record_*`** idempotenter UPSERT auf externen Schlüssel · **`cancel_*`** Abbruch auf terminalen Nicht-Erfolgs-Status mit Historie · **`export_*`** Datei-Egress (erster gegateter READ-Egress) — alle Rang 0 (`owner_info`-fähig) in der einen Verb→Rang-Map `scripts/build/lib/approval_matrix.ps1` + `approval_matrix`-Block des Pakets. **`reset_*`** nie Agent-Tool (Owner-Ops), abgegrenzt von `purge` (Paket-Deinstallation) und `clear_*` (Test-Sentinel).
- Read/Helper: `resolve_*` (Name→ID, 0/>1 → `Build-ToolError`), `get_*`, `fetch_*`, `verify_*`/`validate_*`, `<entity>_context()`. Begründungen → `docs/reference/packages.md` *Entscheidungen*.

### Post-State-Vertrag (Erfolgs-Rückgabe)

Jede Write-`fn` gibt im `ok:true` genau drei Kategorien zurück: (1) Handles (`id`s erzeugter/berührter Entitäten), (2) berührten Post-State (Saldo jedes berührten Kontos, `shares`/`avg`, `remaining_debt`, `status`; in der fn nach dem Trigger in derselben Transaktion gelesen, kein Read-back-Node, kein breiter Snapshot), (3) DB-berechnete Größen, die der Aufrufer nicht geliefert hat. Kein Echo von Eingaben, keine nackten Counts. Test-Seite → `.claude/rules/sql.md` *DB-Tests*.

### Korrigierbare Ablehnung

Nutzer-korrigierbare Fehler (Oversell, Über-/Unterzahlung, nicht-positive Beträge, Typ-Mismatch …) gibt die fn vor dem Write als Daten zurück: `{ok:false, reason:'<EN mit Beträgen>', <zahlfelder>}`, kein RAISE (der löste je Fehlgriff einen Owner-Alert aus). Tool-Graph: `Build-If 'Write ok?'` → false: `Build-ToolError` mit `reason`. Echte Ausnahmen (not-found, already-closed, DB-CHECK/Trigger) bleiben RAISE; `Build-Err` nur für Schreibfehler nach Approval; wo möglich ein spiegelnder `CHECK` als Backstop.

### HITL-Bestätigungs-Format

- **Die Karte ist eine Struktur, kein Text:** `New-HitlSummary` (Titel-Key + `New-HitlLine`/`New-HitlNote`, typisierte Rohwerte); das Gate rendert sie je Empfänger in dessen Sprache. Texte als Keys im Textkatalog des Pakets (`docs/package-contract.md` §3.11), Keys prüft der Build.
- Titel `Verb + Objekt – bitte prüfen:`; ein Feld pro Zeile `• <Label>: <Wert>`, Labels nutzerfreundlich (nie DB-Spaltennamen); ENUMs als `-Kind enum` (Wert-Key `<pkg>.enum.<typ>.<wert>`).
- **Beträge und Daten nur als `-Kind money`/`-Kind date`** — nie hart „€"/„EUR"; Währung per `-Currency` aus der Zeile; festes `'EUR'` nur mit `-EurByModel`.
- **Je Art dieselben Zeilen**, leer = `—`; optionale Info ohne Wert `-OmitEmpty` (entfällt); `-If` für Unterart/Folgegruppen; Default `-IsDefault`. Plain text, kein Markdown (auch nicht im Katalog: `_ * [` Backtick). Knöpfe, Teile langer Karten und Schlusszeile macht das Gate; Laien-Gerüst → `docs/reference/packages.md` *HITL-Karten*.
- **Ganzer Text zum Prüfen:** `New-HitlBody` (nie gekürzt); formuliert das Modell ihn je Aufruf neu → `-RepeatKey` (`docs/reference/core.md` *Wiederhol-Sperre*).
