# Referenz zu `scripts/build/CLAUDE.md` — Engine-Layout, Builder-API, Entscheidungen

On-demand lesen; **keine Regeln** (die stehen in `scripts/build/CLAUDE.md`).

## Layout: Engine (Toolchain) + paket-uniforme Build-Defs

Die Bau-Engine (`scripts/build/`) ist kein Paket — sie baut Pakete (analog `provision.sh`) und kennt kein Paket beim Namen (erzwungen von `core_literal_lint` über `scripts/build/**/*.ps1`): alles Paket-Wissen kommt aus den Manifesten bzw. den Paket-Build-Defs; ein Repo ohne Domänen-Pakete baut. Jedes Paket hält seine Build-Defs uniform unter `packages/<pkg>/build/workflows/` (Core unterscheidet sich nur per Manifest als Host, `privileged:true`). Ein Workflow = eine Datei.

```
scripts/build/                    # ENGINE (Toolchain, kein Paket)
  build.ps1                       # Orchestrator: env+creds, dot-source lib + packages/*/build, Builder-Discovery, Build->Save-Loop, -Only
  lib/                            # build_helpers.ps1 (Build-*/E/Build-Workflow/New-Id), workflow_lifecycle.ps1 (ID-Stelle,
                                  #   Get-RequiredWorkflowId, Get-WorkflowPackage), builder_discovery.ps1 (Builder per AST + Cred-Token-Assert),
                                  #   credentials.ps1 (Paket-Cred-Deskriptoren aus den Manifesten), approval_matrix.ps1 (Maker-Checker-Stufen;
                                  #   auch von approval_lint dot-gesourct), agent_cases.ps1 (Test-Case-Dateien per Glob; auch mock_lint),
                                  #   harness.ps1 (Build-Harness/Get-HarnessWorkflow + $script:Harnesses-Init), monitor_helpers/catalog,
                                  #   agent_routing.ps1 (provides.agents lesen + Vertrag pruefen; auch von contract_lint, llm_suite_advice,
                                  #   den Test-Treibern via test_n8n_state dot-gesourct)
packages/<pkg>/build/workflows/   # PAKET-Build-Defs (uniform)
  agent.*.ps1                     # je eine Build-Def pro Agent
  main.*.ps1                      # Webhook-Haupteingang ohne LLM (Rolle main; derzeit kein Slot belegt)
  cron.*.ps1                      # je eine Build-Def pro Scheduled Job
  sub.*.ps1                       # eigenständige Job-Workflows
  harnesses.ps1                   # Paket-Beitrag: `$script:Harnesses += @(…)`
  tools/<tool>.ps1                # je genau eine Top-Level-Build-<Tool>-Funktion
```

- **Builder-Discovery statt Registry:** `lib/builder_discovery.ps1` parst jede Def-Datei mit dem PowerShell-Parser (keine Ausführung) — Builder = Top-Level-Funktion `Build-*`; Hilfs-Dateien ohne `Build-*` (`harnesses.ps1`, `cron.advisor_common.ps1`, `paperless_common.ps1`, `import_tool_specs.ps1`) liefern 0. Fail-closed: Parse-Fehler, verschachteltes `Build-*`, `tools/`-Def mit ≠ 1 Builder, Doppel-Name, Ergebnis ohne `.name`/`.nodes`. Die Reihenfolge ist wirkungslos: IDs kommen nur aus den gespeicherten `<id>-<name>.json`, ein neuer Workflow braucht deshalb VORAB eine Platzhalter-Datei `<id>-<name>.json` mit `{}` (`packages/CLAUDE.md` *Neues Tool*). `Get-RequiredWorkflowId -Soft` = Warnung statt Abbruch für Ziele, die beim Erst-Build legitim noch fehlen.
- **Credentials:** Host-Deskriptoren (`$CRED_POSTGRES`/`$CRED_CORE_RO`/`$CRED_CONTEXT_RO`/`$CRED_TELEGRAM`/…) stehen im `build.ps1`-Host-Block (Namen = Installer-Map); Paket-Deskriptoren erzeugt `lib/credentials.ps1` aus den Manifesten (`$CRED_<PKG>_RW/_RO` je Paket + je `credentials`-Eintrag der Platzhalter ohne `__`, gleiche Formel wie `inject_credentials.sh`). Zwei Netze gegen still leere Creds: Token-Assert auf den ASTs (unbekannte `$CRED_*`-Variable = Abbruch) + `Save-WorkflowFile` (Credential ohne `__CRED_…__`-id = Abbruch).
- **Harness-Aggregation:** `lib/harness.ps1` initialisiert `$script:Harnesses = @()` + `Build-Harness`/`Get-HarnessWorkflow`; jede `packages/<pkg>/build/workflows/harnesses.ps1` appendet `$script:Harnesses += @(…)`.
- **Node-IDs sind random GUIDs (`New-Id`)** → jeder Build erzeugt neue Node-IDs (funktional egal; der Deploy importiert die Datei neu).

## Modell-Node-Builder (Engine-Bausteine)

- **Jedes Modell wirkt zur Laufzeit — kein Config-Wert wird beim Bauen eingebacken.** Agenten lesen ihr Modell über `core.sub_load_config` (`Load Config`); alle anderen Verbraucher über den Pg-Knoten `Load model config` (`New-ModelConfigNode -Keys @(@('<pkg>','<key>'), …)`, `core.fn_config_get` unter dem `$CRED_POSTGRES` des Aufrufers; Build-Fehler, wenn das Manifest den Key nicht deklariert). Der Knoten sitzt vor dem Modell-Aufruf (Advisor-Crons: vor dem Latch-schreibenden Evaluate). `config_test` (4) prüft statisch: Bezug ⟺ Config-Knoten ⟺ Manifest, jede Manifest-Modell-Zeile wird gelesen, kein Modell-Literal in Anthropic-HTTP-Knoten. Die Zuordnung `model_key → n8n_model_id` backt der Bau aus `ai_models.json` ein (`Get-ModelIdMapJs`; das Register ändert sich nur per Release). Kein `-Credential`-Parameter an `New-ModelConfigNode` — es nimmt wie `Build-Pg` das dynamische `$CRED_POSTGRES` des Aufrufers.
- **Model Selector = ein gemeinsamer Builder.** `New-ModelSelectorBundle` (`lib/build_helpers.ps1`) ist die eine Quelle für die Modell-Nodes (je Chat-Modell des Registers einer) + den Model Selector — genutzt von allen Agenten, dem Orchestrator (`model.orchestrator`) und den Nicht-Agent-Verbrauchern Lern-Cron, Advisor-Review-Crons (über `New-AdvisorPhrasingTail`) und `expert_panel` (zwei Umschalter). `-NamePrefix` = zwei Umschalter in einem Workflow; `-FirstConfigItem` = Regeln lesen `.first()` statt `.item`. Parameter: `-ConfigField`, `-ConfigNodeName`, `-AgentNodeName`, Layout-Positionen. Node-Name = `model_key` (kein Tier-Schema mehr). Alle Chat-Modelle (`mode='chat'`, Nummern lückenlos 1..n — `config_test` 5) sind überall verfügbar; nur der Config-Wert `model.<consumer>` wählt das aktive. Modell-ID + `selector_index` kommen aus der Registry → der alte „alle Anthropic-Nodes still auf Sonnet"-Bug ist strukturell ausgeschlossen.
- **Anthropic-Nodes:** der Builder setzt `options = { maxTokensToSample: 16000, thinkingMode: 'adaptive', effort: <-Effort> }` und kein `temperature`. Grund (Node-Source): ohne Wert gilt `effort:'medium'` + `max_tokens` 4096, und das Denken zählt zu `max_tokens` → lange Antworten würden still abgeschnitten. Symptom bei `temperature`: `400 temperature is deprecated`.
- **`New-AnthropicMessagesNode`** (`lib/build_helpers.ps1`, HTTP-Request auf `/v1/messages` + `anthropicApi`-Credential): für das, was der Chat-Node nicht kann — Bild/PDF-Blöcke (`Get-AnthropicFileBlockJs`), Structured Output (`-JsonSchema` → `output_config.format`), Server-Tool `web_search_20260209` (`-WebSearchMaxUses`). Konsumenten: `tool_web_search`, Monitor-Wertbeschaffung (`lib/monitor_helpers.ps1`), Belege-/CV-Vision, Job-Scorer. Modell: Pflicht `-ConfigModelKey` → Body `model: (<Zuordnung>[$('Load model config').first().json.model.<key>] || null)` — unbekannter Key ⟹ Anthropic 400 ⟹ `{ok:false}`, nie still ein anderes Modell. Auswertung immer über `Get-AnthropicResultJs` (`anthropicText(r)`: Text-Blöcke ohne Trenner gejoint; `stop_reason` max_tokens/refusal/pause_turn → `{ok:false}`). Texte/Schemas gehen über `ConvertTo-JsLiteral` in den Ausdruck (`{{`/`}}` im Text = Build-Fehler). URL = der lokale LLM-Gateway `http://127.0.0.1:8090/v1/messages` (Messung; kein Caching), `config_test` (4) prüft, dass kein Knoten den Gateway umgeht. Im Mock-Tier landen sie beim Mock (JSON-Schema-Aufrufe → schema-plausibler Platzhalter); echte Abdeckung liefert `e2e_test`.
- **Selector ändern = nur den Builder ändern**, dann alle Consumer neu bauen (`build.ps1 -Only 'agent.*'` deckt `agent.finance*`/`agent.monitor`/`agent.guide`/`agent.orchestrator*`), danach `-Reset`. Attachment-/Vision-Pfad, chat_id-Stringify und der Transkriptions-Switch `transcription.provider` leben in den Build-Defs (`packages/core/build/workflows/agent.orchestrator.ps1`; der Voice-Pfad ruft `agent.tool_transcribe_telegram_voice` inline). Modell pro Use-Case wechseln = `model.<consumer>` im `.config`-Block ändern → `-Reset` (re-seedet), kein Build.
- **`chainLlm`** (Basic LLM Chain) für No-Agent-LLM-Schritte: `@n8n/n8n-nodes-langchain.chainLlm` typeVersion 1.7, `parameters = { promptType='define'; text='={{ … }}' }`, Modell via `ai_languageModel`-Connection vom Umschalter. `onError continueRegularOutput` + deterministischer Fallback, wenn der Schritt optional ist.
- **`New-LmChatNode`** = ein Modell-Node aus einem `model_key` (liest `ai_models.json`, emittiert `lmChatAnthropic` + `thinkingMode:'adaptive'`; Nicht-Anthropic-/Embedding-Eintrag bricht den Bau ab). Nur noch interner Knoten-Bauer des Selector-Bundles.
- **`New-AdvisorPhrasingTail`** = der geteilte Umformulier-Schwanz der Advisor-Review-Crons (`New-AdvisorCron` + estate `cron.review_register`): `Load model config` + `Phrase message` (Basic LLM Chain, onError → deterministischer Text) + Umschalter + `Choose text`.

## Entscheidungen (bei uns anders — belegt)

- **Kein Ausdruck im `model`-Feld des Chat-Knotens statt Umschalter:** im Knoten v1.5 (geprüft 2.21.7 + 2.44.4) hängen die `effort`-Optionen per `displayOptions` am Modellwert, ein Ausdruck ließe sie still ins Leere laufen; neu öffnen nur, wenn n8n den Ausdrucks-Modus für Sub-Knoten dokumentiert.
- **Nativer n8n-Anthropic-Node für Direkt-Aufrufe verworfen:** kein `output_config`; ein Baustein (`New-AnthropicMessagesNode`) für alle Pfade statt zweier Mechaniken.
- **Modell-Zuordnung build-time aus `ai_models.json`** statt Laufzeit-DEFINER-fn: Seed und Bau lesen dieselbe Datei, das Register ändert sich nur per Release.
