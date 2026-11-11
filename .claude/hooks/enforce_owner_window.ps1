# PreToolUse-Hook (Bash|PowerShell): harte Sperre ('deny') fuer Aktionen mit Geld- oder Zerstoerungs-
# Wirkung, die Claude nie ohne den Owner ausloest. 'deny' statt 'ask': ein Hook-'ask' wird in der
# VS-Code-Erweiterung unter bypassPermissions still durchgewinkt (GH #77212, hier 2026-10-20
# reproduziert); 'deny' gilt laut Doku in jedem Modus. Deny-/ask-Regeln in den permissions-Arrays
# scheiden aus (Resolver-Bug GH #27139: Wildcard-Allow wird ignoriert, sobald enge Regeln im selben
# Namespace koexistieren) -> der Block lebt HIER, ausserhalb des Permission-Resolvers.
#
# OWNER-FENSTER: scripts/grant_owner_window.ps1 (nur der Owner, im Terminal) schreibt
# .claude/owner_grant.txt (Zeile 1 = UTC-Expiry, ISO 'o'). Solange das Fenster offen ist, laufen die
# gefensterten Aktionen durch; abgelaufene Grants loescht der Hook selbst.
# Suche und Schreib-Erkennung: lib/grant_window.ps1 (gemeinsam mit enforce_app_window.ps1). Nur die Datei im Haupt-Checkout
# zaehlt, ein offenes Fenster gilt fuer alle Sessions und Worktrees zugleich.
#   gefenstert : die LLM-kostenden Test-Suiten (n8n_test/orch_test/e2e_test/judge_eval/multiturn_test/monitor_probe,
#                conversation_test nur mit -Real)
#                + reset_dev_instance.ps1 ohne -KeepInstance (zerstoert die Dev-Instanz-Daten, kein Backup;
#                -KeepInstance baut nichts ab und ist ausgenommen)
#   immer deny : grant_owner_window.ps1 AUSFUEHREN (Claude oeffnet das Fenster nie - Maker-Checker). Ein
#                blosses Erwaehnen in git/cat/grep ist erlaubt (Match nur in Aufruf-Position oder mit
#                einem Ausfuehrungs-Operator im Befehl).
#                owner_grant.txt SCHREIBEN (Schreib-Operator im Shell-Befehl; Lesen ist frei). Edit/Write/NotebookEdit
#                sperrt enforce_app_window.ps1, das auf diesen Tools ohnehin laeuft (kein zweiter Prozess je Dateiaenderung).
# Die Suite-/Reset-Namen matchen dagegen ueberall im Befehlstext (auch in grep/cat) - bewusst breit, weil
# jede Aufruf-Form (powershell -Command, Start-Process, Variablen) gefangen sein muss: Suite-Dateien mit
# den dedizierten Lese-Tools oeffnen. Kein Match -> kein Output -> Aufruf laeuft normal.
# Grenze: Text-Abgleich und eine Kopie im Worktree; wer den Hook selbst oder die .git-Datei seines Worktrees
# umschreibt, kommt vorbei. Das faengt kein Hook, die Regel dagegen ist die Maker-Checker-Vorgabe.
# Test: scripts/dev/owner_window_hook_test.ps1. ASCII-only + Compact-JSON (kein BOM in stdout-JSON).
$inp = [Console]::In.ReadToEnd()
$j = $null
try { $j = $inp | ConvertFrom-Json } catch { }
# Kein lesbares JSON: den rohen Text wie einen Befehl pruefen, damit gesperrte Aktionen nicht durchrutschen.
$cmd = if ($j) { [string]$j.tool_input.command } else { [string]$inp }
function Block-ToolCall([string]$Reason) {
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } } | ConvertTo-Json -Compress -Depth 5
  [Console]::Out.Write($out)
  exit 0
}
# Fehlt die Bibliothek oder bricht sie: Fenster zu, und jede Erwaehnung der Grant-Datei gilt als Schreiben (fail-closed).
$libOk = $false
try { . (Join-Path $PSScriptRoot 'lib\grant_window.ps1'); $libOk = [bool](Get-Command Test-GrantWindow, Test-ShellWrite, Test-ShellGrantWrite -ErrorAction Stop) } catch { }
if ($cmd -match 'owner_grant\.txt' -and (-not $libOk -or (Test-ShellGrantWrite $cmd 'owner_grant.txt'))) {
  Block-ToolCall 'Das Owner-Fenster oeffnet nur der Owner selbst im Terminal: .\scripts\grant_owner_window.ps1. Claude schreibt owner_grant.txt nie - den Owner darum bitten und danach den eigentlichen Befehl erneut senden.'
}
if ($cmd -match 'grant_owner_window\.ps1') {
  # Aufruf-Position: Befehlsanfang oder nach ; & | ( -- oder ein Ausfuehrungs-Operator irgendwo im Befehl
  # (&-Call, Dot-Source, powershell/pwsh/cmd, Start-Process, Invoke-Expression/-Command, -File/-Command).
  $atCmdPos = $cmd -match '(?m)(?:^|[;&|(]\s*)\S*grant_owner_window\.ps1'
  $hasExec  = $cmd -match '(?i)(?:^|[\s;|(])(?:&|\.)\s*(?:\$|\S*grant_owner_window)|(?:^|[\s;|(])(?:powershell|pwsh|cmd|start|call|Start-Process|Invoke-Expression|iex|Invoke-Command|icm)(?:\.exe)?\b|(?:^|\s)-(?:File|Command|FilePath|ArgumentList|c|f)\b'
  if ($atCmdPos -or $hasExec) {
    Block-ToolCall 'Das Owner-Fenster oeffnet nur der Owner selbst im Terminal: .\scripts\grant_owner_window.ps1 (Default 30 Min). Claude ruft es nie auf - den Owner darum bitten und danach den eigentlichen Befehl erneut senden.'
  }
}
$isReset = $cmd -match 'reset_dev_instance\.ps1'
if ($isReset -and $cmd -match '(?i)-KeepInstance\b') { $isReset = $false }   # Update-Pfad: kein Abbau -> nicht gefenstert
$isRealConv = $cmd -match '(?is)conversation_test\.ps1.*-Real\b'   # nur der bezahlte Modus; der Gratis-Lauf mit Mock-Modell bleibt frei
if ($isReset -or $isRealConv -or $cmd -match '(n8n_test|orch_test|e2e_test|judge_eval|multiturn_test|monitor_probe)\.ps1') {
  if ($libOk -and (Test-GrantWindow 'owner_grant.txt')) { exit 0 }   # Fenster offen -> erlaubt
  $what = if ($isReset) { 'reset_dev_instance.ps1 (zerstoert die Dev-Instanz-Daten, kein Backup) ist' } else { 'Die LLM-Test-Suiten (kosten API-Credits) sind' }
  Block-ToolCall "$what owner-gegatet: der Owner oeffnet im Terminal ein Fenster (.\scripts\grant_owner_window.ps1, Default 30 Min) oder startet den Befehl selbst. Nicht umgehen - den Owner bitten und danach erneut senden."
}
exit 0
