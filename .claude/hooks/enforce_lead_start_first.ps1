# PreToolUse-Hook (Agent): Die Leitung startet keinen Unteragenten, solange sie noch keine Unter-Session gestartet hat.
# Grund: Nach jeder Unteragenten-Meldung verweigert die App start_session bis zur naechsten getippten Owner-Nachricht
# (docs/reference/sessions.md *Start verweigert*). Hart per 'deny', weil
# Hook-'ask' still durchgewinkt wird (siehe enforce_owner_window.ps1).
#
# Wer gilt als Leitung: Zeile 1 von .claude/lead_session.txt im Haupt-Checkout (gitignored, schreibt die Leitung per
# scripts/register_sub_session.ps1 -Lead beim Start), verglichen mit CLAUDE_CODE_HOST_SESSION_ID.
# Gesperrt nur, solange .claude/sub_sessions.txt keinen Eintrag hat und lead_session.txt keine Zeile 'no-starts' traegt
# (register_sub_session.ps1 -NoStarts fuer Sprints ohne Unter-Sessions). -Clear am Sprint-Ende loescht beide Dateien.
# Fehlt die Kennung oder die Leitungs-Datei -> fail-open (kein Block). Test: scripts/dev/lead_guard_hook_test.ps1.
# ASCII-only + Compact-JSON (kein BOM in stdout-JSON).
$null = [Console]::In.ReadToEnd()

$id = $env:CLAUDE_CODE_HOST_SESSION_ID
if (-not $id) { exit 0 }

$dirs = @(Split-Path $PSScriptRoot -Parent)
try {
  $common = (& git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir 2>$null)
  if ($common) { $dirs += (Join-Path (Split-Path ([string]$common) -Parent) '.claude') }
} catch { }
$isLead = $false; $startsDone = $false
foreach ($d in ($dirs | Select-Object -Unique)) {
  $lead = Join-Path $d 'lead_session.txt'
  if (Test-Path $lead) {
    $lines = @(Get-Content $lead | ForEach-Object { $_.Trim() })
    if ($lines.Count -gt 0 -and $lines[0] -eq $id) { $isLead = $true }
    if ($lines -contains 'no-starts') { $startsDone = $true }
  }
  $subs = Join-Path $d 'sub_sessions.txt'
  if ((Test-Path $subs) -and @(Get-Content $subs | Where-Object { $_.Trim() }).Count -gt 0) { $startsDone = $true }
}
if (-not $isLead -or $startsDone) { exit 0 }

$reason = 'UNTERAGENT GESPERRT: Die Leitung hat noch keine Unter-Session gestartet. Nach einer Unteragenten-Meldung verweigert die App start_session bis zur naechsten getippten Owner-Nachricht. Erst Zuschnitt und Start-Frage in einem Zug, Inhalte selbst per Grep/Read pruefen, Sessions starten und registrieren (register_sub_session.ps1 -Id). Laeuft dieser Sprint ohne Unter-Sessions: .\scripts\register_sub_session.ps1 -NoStarts (Skill /leitung Abschnitt 2).'
$out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 5
[Console]::Out.Write($out)
exit 0
