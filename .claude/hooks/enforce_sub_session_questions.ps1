# PreToolUse-Hook (AskUserQuestion|mcp__ccd_turn__wrap_up): Eine von der Leitung gestartete Session fragt den Owner nicht
# selbst (Owner-Regel 2026-11-02, Skill /coordinate Abschnitt 5). Die Regel allein reichte nicht: zweimal am selben Tag kam eine
# Frage direkt beim Owner an. Hart per 'deny', weil Hook-'ask' still durchgewinkt wird (siehe enforce_owner_window.ps1).
#
# Wer gilt als Unter-Session: Zeile 1 je Eintrag in .claude/sub_sessions.txt im Haupt-Checkout (gitignored, schreibt die Leitung
# per scripts/register_sub_session.ps1 direkt nach start_session). Verglichen wird mit CLAUDE_CODE_HOST_SESSION_ID.
# Geprueft wird: AskUserQuestion immer; wrap_up nur mit Frage oder Knoepfen (ask, actions), der Bericht allein laeuft durch.
# Nicht betroffen: Sessions, die der Owner selbst startet; Freigabe-Karten der App (Plan, Berechtigung), die kein Tool-Aufruf sind.
# Fehlt die Kennung oder die Liste -> fail-open (kein Block). Test: scripts/dev/lead_guard_hook_test.ps1.
# ASCII-only + Compact-JSON (kein BOM in stdout-JSON).
$inp = [Console]::In.ReadToEnd()
try { $j = $inp | ConvertFrom-Json } catch { exit 0 }

$id = $env:CLAUDE_CODE_HOST_SESSION_ID
if (-not $id) { exit 0 }

$dirs = @(Split-Path $PSScriptRoot -Parent)
try {
  $common = (& git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir 2>$null)
  if ($common) { $dirs += (Join-Path (Split-Path ([string]$common) -Parent) '.claude') }
} catch { }
$listed = $false
foreach ($d in ($dirs | Select-Object -Unique)) {
  $f = Join-Path $d 'sub_sessions.txt'
  if ((Test-Path $f) -and (@(Get-Content $f) -contains $id)) { $listed = $true }
}
if (-not $listed) { exit 0 }

if ([string]$j.tool_name -ne 'AskUserQuestion') {
  $hasAsk = [bool][string]$j.tool_input.ask
  $hasActions = @($j.tool_input.actions | Where-Object { $_ -and "$_" -notmatch '^\s*\[\s*\]\s*$' }).Count -gt 0
  if (-not ($hasAsk -or $hasActions)) { exit 0 }
}

$reason = 'FRAGE GESPERRT: Diese Session hat die Leitung gestartet. Fragen an den Owner laufen per SendMessage an die Leitung (Session-ID im Brief), die Antwort kommt im Wortlaut zurueck. Am Zug-Ende: Bericht ohne ask und ohne actions. Lokale Commits auf dem eigenen Branch brauchen keine Frage; Merge, Push und Release entscheidet die Leitung (Skill /coordinate Abschnitt 5).'
$out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 5
[Console]::Out.Write($out)
exit 0
