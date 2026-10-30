---
paths:
  - "**/*.ps1"
---

# PowerShell-Regeln (lädt beim Öffnen einer `.ps1`-Datei — `scripts/`, `packages/*/build/`, `.claude/hooks/`)

- **Skript-Dateien = UTF-8 mit BOM** (`ps_lint` erzwingt es für `scripts/` + `packages/*/build/`). Ausnahme `.claude/hooks/`: bewusst ASCII-only ohne BOM (JSON auf stdout). Ohne BOM liest PS 5.1 Windows-1252 → `€`/Umlaute brechen den Parser mit kryptischen „Argument fehlt"-Fehlern. Neu schreiben: `[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($true))`.
- **BOM nie per String-Vergleich erkennen:** `$s.StartsWith([char]0xFEFF)` (ebenso `IndexOf`/`EndsWith` mit Null-Breite-Zeichen) vergleicht in PS 5.1 kulturabhängig und liefert **immer** `true`/`0` → ein „BOM abschneiden" per `Substring(1)` löscht das erste echte Zeichen (2026-10-30: `#Requires` → `Requires`, `build.ps1` brach). `ReadAllText` entfernt eine BOM ohnehin; prüfen nur über Bytes (`[System.IO.File]::ReadAllBytes($path)[0..2]` = `EF BB BF`) oder mit `[StringComparison]::Ordinal`. Im Tool-Kommando ist das unsichtbare Zeichen gesperrt → `[char]0xFEFF` schreiben, in SQL `E'﻿'`.
- **Jede Daten-I/O explizit UTF-8** (PS-5.1-Default ist Windows-1252): lesen mit `[System.IO.File]::ReadAllText($path, $Utf8NoBom)` — **nie** `Get-Content -Raw` (liest UTF-8-ohne-BOM als Windows-1252; ein früher REST-Sync warf dadurch „Failed to parse request body"); schreiben mit `[System.IO.File]::WriteAllText($path, $content, $Utf8NoBom)`; API-Body als Bytes senden: `-Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8'` (sonst Mojibake in Workflow-Literalen). Am Skript-Anfang `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`, damit Native-Tool-Output (psql, curl) sauber durchgeht.
- **`param([switch]$Verbose)` + farbiges `Write-Host` ist Absicht**, nicht auf `[CmdletBinding()]`/`Write-Verbose` umstellen: Compound-Gating (`if ($Verbose -or …)`, `psql -q` ohne `-Verbose`) ist in `Write-Verbose` nicht ausdrückbar; ohne `[CmdletBinding()]` kollidiert der eigene `$Verbose` nicht mit dem Common-Parameter; `PSAvoidUsingWriteHost` ist in `config/PSScriptAnalyzerSettings.psd1` begründet ausgeschlossen.
- **Build-Defs und `lib/` per Dot-Sourcing laden** (`. file.ps1`), nie `&`/`Import-Module`: die `Build-*`-Funktionen brauchen die Script-Scope-Creds (`$CRED_*`, `$WorkflowsDir`, `$GateId`) und Helper des Aufrufers. Harness-Beiträge appenden `$script:Harnesses += @(…)` (Output-Stream-Sicherheit).
- Ausführen nur über das PowerShell-Tool, ohne `2>&1` (Root-`CLAUDE.md` *Scripts*).
