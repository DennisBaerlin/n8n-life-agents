# PreToolUse-Hook (Bash|PowerShell): Solange .claude/no_push.txt im Haupt-Checkout liegt, geht nichts aus einer Claude-Session
# nach GitHub (Owner-Entscheid). Hart per 'deny', damit gar keine Freigabe-Karte beim Owner ankommt.
#
# Geprueft wird (Text-Abgleich, im Zweifel den Befehl trennen):
#   (1) git push, auch mit -C/-c davor.
#   (2) gh mit schreibendem Verb auf pr/issue/release/workflow/repo/secret/variable/ruleset/gist/run; gh api mit Methode oder Feldern.
#   (3) immer deny, wenn die Sperre liegt: set_no_push.ps1 -Off ausfuehren oder no_push.txt entfernen (Maker-Checker: nur der
#       Owner im Terminal hebt sie auf). Setzen darf die Leitung selbst.
# Grenze: wirkt nur auf Claude-Sessions; ein Push des Owners im Terminal ist frei. Kein Match -> kein Output.
# Test: scripts/dev/lead_guard_hook_test.ps1. ASCII-only + Compact-JSON (kein BOM in stdout-JSON).
$inp = [Console]::In.ReadToEnd()
try { $j = $inp | ConvertFrom-Json } catch { exit 0 }
$cmd = [string]$j.tool_input.command
if (-not $cmd) { exit 0 }

$dirs = @(Split-Path $PSScriptRoot -Parent)
try {
  $common = (& git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir 2>$null)
  if ($common) { $dirs += (Join-Path (Split-Path ([string]$common) -Parent) '.claude') }
} catch { }
$locked = @($dirs | Select-Object -Unique | Where-Object { Test-Path (Join-Path $_ 'no_push.txt') }).Count -gt 0
if (-not $locked) { exit 0 }

function Block-ToolCall([string]$Reason) {
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } } | ConvertTo-Json -Compress -Depth 5
  [Console]::Out.Write($out)
  exit 0
}

$Lifted = 'Die Push-Sperre hebt nur der Owner selbst im Terminal auf: .\scripts\set_no_push.ps1 -Off. Claude tut das nie; den Owner ueber die Leitung fragen.'
if ($cmd -match 'set_no_push\.ps1[^|;&\n]*\s-Off\b') { Block-ToolCall $Lifted }
if ($cmd -match 'no_push\.txt' -and $cmd -match '(?i)(\brm\b|\bmv\b|Remove-Item|Move-Item|Rename-Item|\bdel\b|Delete\()') { Block-ToolCall $Lifted }

$Pushed = 'PUSH GESPERRT: Bis zum Repo-Neustart geht nichts nach GitHub (Owner-Entscheid), auch kein eigener Branch und kein Workflow-Lauf. Commits bleiben lokal, Tests laufen lokal (scripts/dev/run_free_gates.ps1). Nicht umgehen, keine Freigabe beim Owner anfragen; wer etwas auf GitHub braucht, meldet das der Leitung.'
$tok = '("[^"]*"|''[^'']*''|\S+)'
if ($cmd -match "\bgit(\s+-[cC]\s+$tok)*\s+push\b") { Block-ToolCall $Pushed }
if ($cmd -match '\bgh\s+(pr|issue|release|workflow|repo|secret|variable|ruleset|gist|run)\s+(create|edit|delete|comment|close|reopen|merge|ready|review|upload|run|enable|disable|set|rename|archive|sync|rerun|cancel|lock|unlock|transfer|pin|unpin)\b') { Block-ToolCall $Pushed }
if ($cmd -match '\bgh\s+api\b' -and $cmd -match '(?i)(\s-X\s*(POST|PATCH|PUT|DELETE)\b|\s--method[ =](POST|PATCH|PUT|DELETE)\b|\s-[fF]\s|\s--(raw-)?field\b|\s--input\b)') { Block-ToolCall $Pushed }
exit 0
