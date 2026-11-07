#Requires -Version 5.1
# Test des Hooks .claude/hooks/enforce_app_window.ps1 (Mini-App nur mit Zustimmung des Owners): fuettert ihn mit Tool-Aufrufen
# wie Claude Code (JSON auf stdin) und prueft deny/allow. Kein Substrat, keine Kosten, schreibt nur app_grant.txt in einen
# eigenen Temp-Klon des Hook-Ordners (nie ins echte .claude/).
# Usage:  .\scripts\dev\app_window_hook_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
Clear-GitEnvironment
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$sandbox = Join-Path $env:TEMP ("app_window_hook_" + [guid]::NewGuid().ToString('N'))
$hookDir = Join-Path $sandbox '.claude\hooks'
New-Item -ItemType Directory -Force $hookDir | Out-Null
function Add-HookCopy([string]$HooksDir) {
    New-Item -ItemType Directory -Force $HooksDir | Out-Null
    Copy-Item (Join-Path $repo '.claude\hooks\enforce_app_window.ps1') $HooksDir
    Copy-Item (Join-Path $repo '.claude\hooks\lib') $HooksDir -Recurse
}
Add-HookCopy $hookDir
$hook = Join-Path $hookDir 'enforce_app_window.ps1'
$grant = Join-Path $sandbox '.claude\app_grant.txt'
$failed = 0
# Der Hook wertet ein Fenster nur in einem Repo (fail-closed), darum ist die Sandbox selbst eines.
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
Initialize-GitSandbox $sandbox
git -C $sandbox -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init --no-verify 2>$null
$ErrorActionPreference = $prev

# Ein String als $inputObj geht unveraendert auf stdin (Fall: kaputter Input). $envVars gilt nur fuer diesen einen Lauf.
function Invoke-Hook($tool, $inputObj, $cwd = $sandbox, [hashtable]$envVars = @{}) {
    $payload = if ($inputObj -is [string]) { $inputObj } else { @{ tool_name = $tool; tool_input = $inputObj; cwd = $cwd } | ConvertTo-Json -Compress -Depth 5 }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    foreach ($k in $envVars.Keys) { $psi.EnvironmentVariables[$k] = $envVars[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.Write($payload); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    [void]$errTask.Wait(5000)
    return $out -match '"permissionDecision":"deny"'
}
function Assert-Case($name, $expectDeny, $tool, $inputObj, $cwd = $sandbox, [hashtable]$envVars = @{}) {
    $denied = Invoke-Hook $tool $inputObj $cwd $envVars
    if ($denied -eq $expectDeny) { Write-Host "  [PASS] $name" }
    else { Write-Host "  [FAIL] $name (erwartet deny=$expectDeny, got $denied)" -ForegroundColor Red; $script:failed++ }
}

$html   = 'C:\r\packages\core\build\app\index.html'
$fnApp  = 'C:\r\packages\finance\db\migrations\R__fn_app_screen_accounts.sql'
$locale = 'C:\r\packages\finance\locales\de.json'
$manif  = 'C:\r\packages\finance\manifest.json'

Write-Host 'Ohne Fenster:'
Assert-Case 'Edit index.html'                 $true  'Edit'  @{ file_path = $html; old_string = 'a'; new_string = 'b' }
Assert-Case 'Write fn_app_*'                  $true  'Write' @{ file_path = $fnApp; content = 'x' }
Assert-Case 'Edit Serve-Def'                  $true  'Edit'  @{ file_path = 'C:\r\packages\core\build\workflows\core.main_app_serve.ps1'; old_string = 'a'; new_string = 'b' }
Assert-Case 'Edit Locale mit .app.-Key'       $true  'Edit'  @{ file_path = $locale; old_string = '"x"'; new_string = '"finance.app.accounts.y": "z"' }
Assert-Case 'Edit Locale ohne .app.-Key'      $false 'Edit'  @{ file_path = $locale; old_string = '"x"'; new_string = '"finance.note.y": "z"' }
Assert-Case 'Edit Manifest app_screens'       $true  'Edit'  @{ file_path = $manif; old_string = '"app_screens": {'; new_string = '"app_screens": { }' }
Assert-Case 'Edit Manifest sonst'             $false 'Edit'  @{ file_path = $manif; old_string = '"a"'; new_string = '"b"' }
Assert-Case 'Edit andere fn'                  $false 'Edit'  @{ file_path = 'C:\r\packages\finance\db\migrations\R__fn_account_funding.sql'; old_string = 'a'; new_string = 'b' }
Assert-Case 'Edit Test einer App-fn'          $false 'Edit'  @{ file_path = 'C:\r\tests\db\finance\test_fn_app_screen_accounts.sql'; old_string = 'a'; new_string = 'b' }
Assert-Case 'Bash cat liest'                  $false 'Bash'  @{ command = 'cat packages/core/build/app/index.html' }
Assert-Case 'Bash sed -n liest'               $false 'Bash'  @{ command = 'sed -n 1,20p packages/finance/db/migrations/R__fn_app_screen_goals.sql' }
Assert-Case 'Bash git diff liest'             $false 'Bash'  @{ command = 'git diff HEAD -- packages/core/build/app/index.html' }
Assert-Case 'Bash sed -i schreibt'            $true  'Bash'  @{ command = 'sed -i s/a/b/ packages/core/build/app/index.html' }
Assert-Case 'Bash perl -pi schreibt'          $true  'Bash'  @{ command = 'perl -pi -e s/a/b/ packages/finance/db/migrations/R__fn_app_low_state_pill.sql' }
Assert-Case 'Bash Umleitung schreibt'         $true  'Bash'  @{ command = 'echo x > packages/core/build/app/index.html' }
Assert-Case 'Bash git checkout Pfad'          $true  'Bash'  @{ command = 'git checkout HEAD~1 -- packages/core/build/app/index.html' }
Assert-Case 'PowerShell Set-Content'          $true  'PowerShell' @{ command = 'Set-Content packages\core\build\app\index.html x' }
Assert-Case 'Bash perl auf Locale .app.'      $true  'Bash'  @{ command = 'perl -pi -e s/finance.app.accounts.y/z/ packages/finance/locales/de.json' }
Assert-Case 'Bash ohne App-Bezug'             $false 'Bash'  @{ command = 'rm -f /tmp/x; ls docs' }
Assert-Case 'Grant-Skript ausfuehren'         $true  'PowerShell' @{ command = '.\scripts\grant_app_window.ps1' }
Assert-Case 'Grant-Skript erwaehnen'          $false 'Bash'  @{ command = 'git log --oneline -- scripts/grant_app_window.ps1' }
Assert-Case 'Grant-Datei schreiben (Edit)'    $true  'Write' @{ file_path = 'C:\r\.claude\app_grant.txt'; content = 'x' }
Assert-Case 'Grant-Datei schreiben (Shell)'   $true  'Bash'  @{ command = 'echo x > .claude/app_grant.txt' }
Assert-Case 'Grant-Datei: Kurzform copy'      $true  'PowerShell' @{ command = 'copy x.txt .claude\app_grant.txt' }
Assert-Case 'Grant-Datei: Pfad mit Leerzeichen' $true 'PowerShell' @{ command = 'echo x > "C:\mein ordner\.claude\app_grant.txt"' }
Assert-Case 'Grant-Datei lesen frei'          $false 'PowerShell' @{ command = 'Get-Content .claude\app_grant.txt' }
Assert-Case 'Kurzform an Befehls-Position schreibt' $true 'PowerShell' @{ command = 'copy x.txt packages\core\build\app\index.html' }
Assert-Case 'Suchwort copy in App-Datei liest' $false 'Bash' @{ command = 'grep copy packages/core/build/app/index.html' }
Assert-Case 'Suchwort move in App-Datei liest' $false 'Bash' @{ command = 'rg move packages/core/build/app/index.html' }
Assert-Case 'Owner-Grant: Write'              $true  'Write' @{ file_path = 'C:\r\.claude\owner_grant.txt'; content = 'x' }
Assert-Case 'Owner-Grant: Edit'               $true  'Edit'  @{ file_path = 'C:\r\.claude\owner_grant.txt'; old_string = 'a'; new_string = 'b' }
Assert-Case 'Owner-Grant: NotebookEdit'       $true  'NotebookEdit' @{ notebook_path = 'C:\r\.claude\owner_grant.txt'; new_source = 'x' }
Assert-Case 'kaputter Input mit App-Schreiben' $true '' 'kein json sed -i s/a/b/ packages/core/build/app/index.html'
Assert-Case 'kaputter Input ohne Bezug'       $false '' 'kein json git status'

# (3) Commit-Backstop gegen ein Wegwerf-Repo
$git = Join-Path $sandbox 'gitrepo'
New-Item -ItemType Directory -Force (Join-Path $git 'packages\core\build\app') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $git 'packages\finance\locales') | Out-Null
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
Initialize-GitSandbox $git
git -C $git config user.email t@example.invalid; git -C $git config user.name t; git -C $git config core.autocrlf false
Set-Content (Join-Path $git 'other.txt') 'a'
git -C $git add -A; git -C $git commit -qm init --no-verify 2>$null
Set-Content (Join-Path $git 'other.txt') 'b'; git -C $git add -A
Assert-Case 'Commit ohne App-Flaeche'         $false 'Bash'  @{ command = 'git commit -m x' } $git
Set-Content (Join-Path $git 'packages\core\build\app\index.html') 'x'; git -C $git add -A
Assert-Case 'Commit mit App-Datei'            $true  'Bash'  @{ command = 'git commit -m x' } $git
Assert-Case 'Commit mit git -C'               $true  'PowerShell' @{ command = "git -C `"$git`" commit -m x" }
git -C $git reset -q --hard; git -C $git clean -qfd
New-Item -ItemType Directory -Force (Join-Path $git (Join-Path packages (Join-Path finance locales))) | Out-Null
Set-Content (Join-Path $git 'packages\finance\locales\de.json') '  "finance.note.y": "z"'; git -C $git add -A
Assert-Case 'Commit Locale ohne .app.-Key'    $false 'Bash'  @{ command = 'git commit -m x' } $git
Add-Content (Join-Path $git 'packages\finance\locales\de.json') '  "finance.app.accounts.y": "z"'; git -C $git add -A
Assert-Case 'Commit Locale mit .app.-Key'     $true  'Bash'  @{ command = 'git commit -m x' } $git
# Umgelenktes GIT_DIR darf den Backstop nicht blind machen: es zeigt auf ein Repo ohne gestagte Aenderung.
$emptyRepo = Join-Path $sandbox 'emptyrepo'
New-Item -ItemType Directory -Force $emptyRepo | Out-Null
Initialize-GitSandbox $emptyRepo
Assert-Case 'Commit mit App, GIT_DIR umgelenkt' $true 'Bash' @{ command = 'git commit -m x' } $git @{ GIT_DIR = (Join-Path $emptyRepo '.git') }
# Merge-Commit: nur Dateien, die sich gegenueber beiden Eltern unterscheiden, zaehlen.
$mrg = Join-Path $sandbox 'mergerepo'
New-Item -ItemType Directory -Force (Join-Path $mrg 'packages\core\build\app') | Out-Null
Initialize-GitSandbox $mrg
git -C $mrg config user.email t@example.invalid; git -C $mrg config user.name t; git -C $mrg config core.autocrlf false
Set-Content (Join-Path $mrg 'other.txt') 'a'
git -C $mrg add -A; git -C $mrg commit -qm init --no-verify 2>$null
$base = (git -C $mrg rev-parse --abbrev-ref HEAD).Trim()
git -C $mrg checkout -q -b theirs
Set-Content (Join-Path $mrg 'packages\core\build\app\index.html') 'von main'
git -C $mrg add -A; git -C $mrg commit -qm app --no-verify 2>$null
git -C $mrg checkout -q $base
Set-Content (Join-Path $mrg 'other.txt') 'b'; git -C $mrg add -A; git -C $mrg commit -qm other --no-verify 2>$null
git -C $mrg merge --no-ff --no-commit theirs 2>$null | Out-Null
Assert-Case 'Merge bringt App-Datei unveraendert mit' $false 'Bash' @{ command = 'git commit -m merge' } $mrg
Set-Content (Join-Path $mrg 'packages\core\build\app\index.html') 'im Merge geaendert'; git -C $mrg add -A
Assert-Case 'Merge veraendert App-Datei selbst'       $true  'Bash' @{ command = 'git commit -m merge' } $mrg
$ErrorActionPreference = $prev

Write-Host 'Mit offenem Fenster:'
[System.IO.File]::WriteAllText($grant, [datetime]::UtcNow.AddMinutes(5).ToString('o'))
Assert-Case 'Edit index.html erlaubt'         $false 'Edit'  @{ file_path = $html; old_string = 'a'; new_string = 'b' }
Assert-Case 'Bash sed -i erlaubt'             $false 'Bash'  @{ command = 'sed -i s/a/b/ packages/core/build/app/index.html' }
Assert-Case 'Commit mit App erlaubt'          $false 'Bash'  @{ command = 'git commit -m x' } $git
Assert-Case 'Grant-Skript bleibt gesperrt'    $true  'PowerShell' @{ command = '.\scripts\grant_app_window.ps1' }

Write-Host 'Abgelaufenes Fenster:'
[System.IO.File]::WriteAllText($grant, [datetime]::UtcNow.AddMinutes(-1).ToString('o'))
Assert-Case 'Edit index.html wieder gesperrt' $true  'Edit'  @{ file_path = $html; old_string = 'a'; new_string = 'b' }
if (Test-Path $grant) { Write-Host '  [FAIL] abgelaufener Grant nicht geloescht' -ForegroundColor Red; $failed++ } else { Write-Host '  [PASS] abgelaufener Grant geloescht' }

Write-Host 'Umlenkung auf ein fremdes Repo mit gueltigem Grant:'
$grantEmpty = Join-Path $emptyRepo '.claude\app_grant.txt'
New-Item -ItemType Directory -Force (Split-Path $grantEmpty) | Out-Null
[System.IO.File]::WriteAllText($grantEmpty, [datetime]::UtcNow.AddMinutes(5).ToString('o'))
$editHtml = @{ file_path = $html; old_string = 'a'; new_string = 'b' }
Assert-Case 'GIT_DIR'                         $true  'Edit'  $editHtml $sandbox @{ GIT_DIR = (Join-Path $emptyRepo '.git') }
Assert-Case 'GIT_COMMON_DIR'                  $true  'Edit'  $editHtml $sandbox @{ GIT_COMMON_DIR = (Join-Path $emptyRepo '.git') }
Assert-Case 'cwd im Aufruf'                   $true  'Edit'  $editHtml $emptyRepo
Remove-Item $grantEmpty -Force

Write-Host 'Fail-closed (gueltiger Grant im Haupt-Checkout):'
[System.IO.File]::WriteAllText($grant, [datetime]::UtcNow.AddMinutes(5).ToString('o'))
Assert-Case 'git nicht auffindbar'            $true  'Edit'  $editHtml $sandbox @{ PATH = [Environment]::SystemDirectory }
$noRepo = Join-Path ([System.IO.Path]::GetTempPath()) ('awh_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
Add-HookCopy (Join-Path $noRepo '.claude\hooks')
[System.IO.File]::WriteAllText((Join-Path $noRepo '.claude\app_grant.txt'), [datetime]::UtcNow.AddMinutes(5).ToString('o'))
$mainHook = $hook
$hook = Join-Path $noRepo '.claude\hooks\enforce_app_window.ps1'
Assert-Case 'ausserhalb eines Repos'          $true  'Edit'  $editHtml $noRepo
$hook = $mainHook

Write-Host 'Fenster im Haupt-Checkout, Hook im Worktree:'
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$wt = Join-Path $sandbox 'wt'
git -C $sandbox worktree add -q -b wt $wt 2>$null
$ErrorActionPreference = $prev
Add-HookCopy (Join-Path $wt '.claude\hooks')
$hook = Join-Path $wt '.claude\hooks\enforce_app_window.ps1'
Assert-Case 'Grant im Haupt-Checkout gilt'    $false 'Edit'  $editHtml $wt
Remove-Item $grant -Force
Assert-Case 'kein Grant: gesperrt'            $true  'Edit'  $editHtml $wt
[System.IO.File]::WriteAllText((Join-Path $wt '.claude\app_grant.txt'), [datetime]::UtcNow.AddMinutes(5).ToString('o'))
Assert-Case 'gueltige Kopie im Worktree zaehlt nicht' $true 'Edit' $editHtml $wt

Write-Host 'Bibliothek fehlt, ist kaputt oder leer (Fenster offen):'
[System.IO.File]::WriteAllText($grant, [datetime]::UtcNow.AddMinutes(5).ToString('o'))
$lib = Join-Path $wt '.claude\hooks\lib\grant_window.ps1'
[System.IO.File]::WriteAllText($lib, 'function {{{ kaputt')
Assert-Case 'kaputt: App-Edit gesperrt'       $true  'Edit'  $editHtml $wt
Assert-Case 'kaputt: Shell-Lesen auf App gesperrt' $true 'Bash' @{ command = 'cat packages/core/build/app/index.html' } $wt
Assert-Case 'kaputt: fremder Befehl frei'     $false 'Bash'  @{ command = 'git status' } $wt
Assert-Case 'kaputt: fremde Datei frei'       $false 'Edit'  @{ file_path = 'C:\r\doc.txt'; old_string = 'a'; new_string = 'b' } $wt
[System.IO.File]::WriteAllText($lib, '')
Assert-Case 'leer: Shell-Schreiben auf App gesperrt' $true 'Bash' @{ command = 'sed -i s/a/b/ packages/core/build/app/index.html' } $wt
Assert-Case 'leer: fremder Befehl frei'       $false 'Bash'  @{ command = 'git status' } $wt
Remove-Item $lib -Force
Assert-Case 'fehlt: App-Edit gesperrt'       $true  'Edit'  $editHtml $wt
Assert-Case 'fehlt: fremder Befehl frei'      $false 'Bash'  @{ command = 'git status' } $wt
$hook = $mainHook

Remove-Item $noRepo -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "app_window_hook_test: $failed Fehler."
exit $failed
