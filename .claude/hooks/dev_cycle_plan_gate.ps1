# PreToolUse-Hook (ExitPlanMode): EIN deterministischer Marker, bevor der Owner einen Plan sieht.
# Ein substanzieller Plan (> 400 Zeichen) traegt eine Zeile "Plan-Reviewer: <Verdikt>" - entweder das
# Verdikt eines unabhaengigen Plan-Reviews (ab Blast-Radius fn_*/Schema/Trigger/Auth/neuer Agent,
# Skill /feature) oder "Plan-Reviewer: nicht noetig - <Grund>". Fehlt die Zeile -> deny: Claude bekommt
# den Grund als Tool-Fehler, ergaenzt die Zeile ehrlich und legt erneut vor.
# deny statt ask: ein Hook-'ask' wird in der VS-Code-Erweiterung unter bypassPermissions still
# durchgewinkt (GH #77212, hier 2026-10-20 reproduziert); 'deny' gilt laut Doku in jedem Modus.
# Plan-Quelle: Claude Code speist den Plan-Text vor dem Hook-Aufruf als tool_input.plan ein (+ planFilePath).
# Fehlt plan, liest der Hook planFilePath; fehlt beides -> deny (Waechter stirbt nie still - Muster doc_lint
# Selbst-Asserts). Marker-Formen: "Plan-Reviewer: x", "**Plan-Reviewer:** x", "**Plan-Reviewer**: x",
# "## Plan-Reviewer: x", Bullet/Blockquote, Tabellenzelle "| Plan-Reviewer | x |".
# Kein jq -> native ConvertFrom-Json. ASCII-only + Compact-JSON (kein BOM in stdout-JSON).
$ErrorActionPreference = 'Stop'
function Block-PlanExit([string]$Reason) {
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } } | ConvertTo-Json -Compress -Depth 5
  Write-Output $out
  exit 0
}
$raw = [Console]::In.ReadToEnd()
try { $j = $raw | ConvertFrom-Json } catch { exit 0 }
$plan = ''
if ($j.tool_input -and $j.tool_input.plan) { $plan = [string]$j.tool_input.plan }
if (-not $plan -and $j.tool_input -and $j.tool_input.planFilePath) {
  $p = [string]$j.tool_input.planFilePath
  if (Test-Path $p) { try { $plan = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } catch { } }
}
if (-not $plan) {
  Block-PlanExit 'PLAN-GATE: Plan-Text nicht lesbar (weder tool_input.plan noch planFilePath nutzbar) - Hook-Eingabe hat sich geaendert; .claude/hooks/dev_cycle_plan_gate.ps1 an die aktuelle ExitPlanMode-Eingabe anpassen statt das Gate zu umgehen.'
}
if ($plan.Length -lt 400) { exit 0 }                                                        # trivialer Plan: kein Gate
if ($plan -match '(?im)^[\s\-\*>#|]*Plan-Reviewer\**\s*[:|]\**\s*\S') { exit 0 }            # Marker da (fett/Bullet/Heading/Tabelle)
Block-PlanExit 'PLAN OHNE REVIEW-ZEILE: ein substanzieller Plan traegt eine Zeile "Plan-Reviewer: <Verdikt>" - das Verdikt eines unabhaengigen Plan-Reviews (Pflicht ab Blast-Radius fn_*/Schema/Trigger/Auth/neuer Agent, Skill /feature) oder "Plan-Reviewer: nicht noetig - <Grund>". Zeile ehrlich ergaenzen und erneut vorlegen.'
