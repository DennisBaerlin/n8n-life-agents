#Requires -Version 5.1
# Test der Hooks .claude/hooks/enforce_sub_session_questions.ps1, enforce_lead_start_first.ps1 und enforce_no_push.ps1: fuettert sie mit Tool-Aufrufen wie Claude
# Code (JSON auf stdin) und prueft deny/allow. Kein Substrat, keine Kosten, schreibt nur in einen eigenen Temp-Klon des Hook-Ordners.
# Usage:  .\scripts\dev\lead_guard_hook_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$sandbox = Join-Path $env:TEMP ("lead_guard_hook_" + [guid]::NewGuid().ToString('N'))
$hookDir = Join-Path $sandbox '.claude\hooks'
New-Item -ItemType Directory -Force $hookDir | Out-Null
Copy-Item (Join-Path $repo '.claude\hooks\enforce_sub_session_questions.ps1'), (Join-Path $repo '.claude\hooks\enforce_lead_start_first.ps1'), (Join-Path $repo '.claude\hooks\enforce_no_push.ps1') $hookDir
$askHook = Join-Path $hookDir 'enforce_sub_session_questions.ps1'
$pushHook = Join-Path $hookDir 'enforce_no_push.ps1'
$agentHook = Join-Path $hookDir 'enforce_lead_start_first.ps1'
$leadFile = Join-Path $sandbox '.claude\lead_session.txt'
$list = Join-Path $sandbox '.claude\sub_sessions.txt'
$lock = Join-Path $sandbox '.claude\no_push.txt'
$failed = 0

function Invoke-Hook($hook, $tool, $inputObj, $sessionId) {
    $payload = @{ tool_name = $tool; tool_input = $inputObj; cwd = $sandbox } | ConvertTo-Json -Compress -Depth 5
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['CLAUDE_CODE_HOST_SESSION_ID'] = $sessionId
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($payload); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    return $out -match '"permissionDecision":"deny"'
}
function Assert-Case($name, $expectDeny, $hook, $tool, $inputObj, $sessionId = 'local_lead') {
    $denied = Invoke-Hook $hook $tool $inputObj $sessionId
    if ($denied -eq $expectDeny) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name (erwartet deny=$expectDeny, got $denied)" -ForegroundColor Red; $script:failed++ }
}
$wrap = 'mcp__ccd_turn__wrap_up'
$q = @{ questions = @(@{ question = 'x' }) }

Write-Host 'Fragen, ohne Liste:'
Assert-Case 'Frage erlaubt'                    $false $askHook 'AskUserQuestion' $q 'local_child'

[System.IO.File]::WriteAllText($list, "local_child`r`nlocal_child2`r`n")
Write-Host 'Fragen, mit Liste:'
Assert-Case 'Unter-Session: AskUserQuestion'   $true  $askHook 'AskUserQuestion' $q 'local_child'
Assert-Case 'Zweite Zeile der Liste'           $true  $askHook 'AskUserQuestion' $q 'local_child2'
Assert-Case 'Unter-Session: wrap_up mit ask'   $true  $askHook $wrap @{ recap = 'r'; ask = 'Mergen?' } 'local_child'
Assert-Case 'Unter-Session: wrap_up, Knoepfe'  $true  $askHook $wrap @{ recap = 'r'; actions = @(@{ label = 'Ja' }) } 'local_child'
Assert-Case 'Unter-Session: Knoepfe als Text'  $true  $askHook $wrap @{ recap = 'r'; actions = '[{"label":"Ja"}]' } 'local_child'
Assert-Case 'Unter-Session: nur Bericht'       $false $askHook $wrap @{ recap = 'r' } 'local_child'
Assert-Case 'Unter-Session: leere Knoepfe'     $false $askHook $wrap @{ recap = 'r'; actions = '[]' } 'local_child'
Assert-Case 'Leitung darf fragen'              $false $askHook 'AskUserQuestion' $q 'local_lead'
Assert-Case 'Leitung: wrap_up mit ask'         $false $askHook $wrap @{ recap = 'r'; ask = 'Mergen?' } 'local_lead'
Assert-Case 'Keine Kennung: fail-open'         $false $askHook 'AskUserQuestion' $q ''

$ag = @{ description = 'x'; prompt = 'y' }
Write-Host 'Unteragenten, ohne Leitungs-Datei:'
Assert-Case 'Agent frei'                       $false $agentHook 'Agent' $ag 'local_lead'
Remove-Item $list -Force
[System.IO.File]::WriteAllText($leadFile, "local_lead`r`n")
Write-Host 'Unteragenten, Leitung eingetragen, keine Unter-Session:'
Assert-Case 'Leitung: Agent gesperrt'          $true  $agentHook 'Agent' $ag 'local_lead'
Assert-Case 'Leitung: alter Name Task'         $true  $agentHook 'Task' $ag 'local_lead'
Assert-Case 'Andere Session: Agent frei'       $false $agentHook 'Agent' $ag 'local_other'
Assert-Case 'Keine Kennung: fail-open'         $false $agentHook 'Agent' $ag ''
[System.IO.File]::WriteAllText($list, "`r`n")
Assert-Case 'Leere Liste: gesperrt'            $true  $agentHook 'Agent' $ag 'local_lead'
[System.IO.File]::WriteAllText($list, "local_child`r`n")
Assert-Case 'Nach erster Unter-Session frei'   $false $agentHook 'Agent' $ag 'local_lead'
Remove-Item $list -Force
[System.IO.File]::WriteAllText($leadFile, "local_lead`r`nno-starts`r`n")
Assert-Case 'Sprint ohne Starts: frei'         $false $agentHook 'Agent' $ag 'local_lead'

Write-Host 'Push, ohne Sperre:'
Assert-Case 'git push frei'                    $false $pushHook 'Bash' @{ command = 'git push origin main' }

[System.IO.File]::WriteAllText($lock, 'gesperrt')
Write-Host 'Push, mit Sperre:'
Assert-Case 'git push'                         $true  $pushHook 'Bash' @{ command = 'git push origin main' }
Assert-Case 'git push im PowerShell-Tool'      $true  $pushHook 'PowerShell' @{ command = '$env:X=1; git push -u origin feat/x' }
Assert-Case 'git -C pfad push'                 $true  $pushHook 'Bash' @{ command = 'git -C "C:\r\x y" push origin x' }
Assert-Case 'git -c opt push'                  $true  $pushHook 'Bash' @{ command = 'git -c http.x=1 push' }
Assert-Case 'gh workflow run'                  $true  $pushHook 'Bash' @{ command = 'gh workflow run free-gates.yml --ref x' }
Assert-Case 'gh pr create'                     $true  $pushHook 'Bash' @{ command = 'gh pr create --draft' }
Assert-Case 'gh release upload'                $true  $pushHook 'Bash' @{ command = 'gh release upload v1 a.tgz' }
Assert-Case 'gh api mit -X POST'               $true  $pushHook 'Bash' @{ command = 'gh api -X POST repos/o/r/x' }
Assert-Case 'gh api mit Feld'                  $true  $pushHook 'Bash' @{ command = 'gh api repos/o/r/x -f a=b' }
Assert-Case 'git log liest'                    $false $pushHook 'Bash' @{ command = 'git log --oneline -3' }
Assert-Case 'git ls-remote liest'              $false $pushHook 'Bash' @{ command = 'git ls-remote origin' }
Assert-Case 'git commit lokal'                 $false $pushHook 'PowerShell' @{ command = 'git commit -F msg.txt' }
Assert-Case 'gh pr view liest'                 $false $pushHook 'Bash' @{ command = 'gh pr view 1' }
Assert-Case 'gh run watch liest'               $false $pushHook 'Bash' @{ command = 'gh run watch 1 --exit-status' }
Assert-Case 'gh api liest'                     $false $pushHook 'Bash' @{ command = 'gh api repos/o/r' }
Assert-Case 'Sperre setzen erlaubt'            $false $pushHook 'PowerShell' @{ command = '.\scripts\set_no_push.ps1 -On' }
Assert-Case 'Sperre aufheben gesperrt'         $true  $pushHook 'PowerShell' @{ command = '.\scripts\set_no_push.ps1 -Off' }
Assert-Case 'Sperrdatei loeschen gesperrt'     $true  $pushHook 'PowerShell' @{ command = 'Remove-Item .claude\no_push.txt' }
Assert-Case 'Sperrdatei rm gesperrt'           $true  $pushHook 'Bash' @{ command = 'rm -f .claude/no_push.txt' }

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "lead_guard_hook_test: $failed Fehler."
exit $failed
