# Build-Engine — Regeln (lädt beim Arbeiten in `scripts/build/`)

Die Bau-Engine (`build.ps1` + `lib/`) generiert alle n8n-Workflow-JSONs aus den paket-uniformen Build-Defs. Hier nur Engine-Regeln; Autoren-Konventionen (Lifecycle, Neues Tool, Gate-Ketten, Build-Gotchas, Cron-Bau, Verb-Taxonomie, Post-State/HITL) → `packages/CLAUDE.md`. Layout, Builder-API und Entscheidungen → `docs/reference/build.md` (on-demand). PowerShell-Encoding/Dot-Sourcing → `.claude/rules/powershell.md`.

## Layout

- Die Engine **kennt kein Paket beim Namen** (`core_literal_lint` über `scripts/build/**/*.ps1`); alles Paket-Wissen kommt aus Manifesten und Paket-Build-Defs. Build-Defs liegen uniform unter `packages/<pkg>/build/workflows/`, Builder werden per AST entdeckt (keine Registry); eine `tools/`-Def hat genau eine `Build-*`-Funktion.
- Credentials nur über die `$CRED_*`-Deskriptoren (Host-Block in `build.ps1`, Paket-Deskriptoren aus `lib/credentials.ps1`); unbekannte Variable oder Credential ohne `__CRED_…__`-Platzhalter bricht den Build.
- **Build ist deterministisch:** `Save-WorkflowFile` macht jede Knoten-id, vorhandene `webhookId` und GUID-förmige innere id zur UUID-v5 aus Workflow- + Knoten-Name (+ JSON-Pfad), sortiert ungeordnete Hashtables und schreibt LF nur bei echter Änderung → ein unveränderter Workflow baut byte-identisch (Refactor-Beweis = `git status` leer). `New-Id` ist nur Platzhalter; eine feste/zufällige GUID oder ein doppelter Knoten-Name bricht den Build. Knoten- oder Workflow-Umbenennung = neue IDs (beim Telegram-Trigger: neue Empfangsadresse, n8n meldet sie beim Deploy neu an).

## Modell-Node-Builder

- **Kein Config-Wert wird beim Bauen eingebacken** (`config_test` 4): Agenten lesen ihr Modell über `Load Config`, alle anderen Verbraucher über `New-ModelConfigNode` (`Load model config`, vor dem Modell-Aufruf; Build-Fehler, wenn das Manifest den Key nicht deklariert).
- `New-ModelSelectorBundle` ist die eine Quelle der Modell-Nodes + des Selectors; **`-Effort` (low|medium|high) ist an `New-LmChatNode` und `New-ModelSelectorBundle` Pflicht** (Default wäre `medium` + `max_tokens` 4096, das Denken zählt mit → lange Antworten still abgeschnitten); keine Sampling-Parameter (`temperature` → 400).
- Selector ändern = nur den Builder ändern, dann alle Consumer neu bauen und `-Reset`; Modellwechsel braucht keinen Build (`model.<consumer>` im Manifest).
- `New-AnthropicMessagesNode` ist die einzige Quelle für direkte Claude-Aufrufe (Vision, Structured Output, Server-Tool `web_search`); Modell nur per `-ConfigModelKey`, Auswertung nur über `Get-AnthropicResultJs`, Texte über `ConvertTo-JsLiteral`; URL = der lokale LLM-Gateway, nie direkt Anthropic.
