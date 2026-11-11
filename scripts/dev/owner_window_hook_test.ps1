#Requires -Version 5.1
# Test des Hooks .claude/hooks/enforce_owner_window.ps1 (bezahlte Suiten + Dev-Reset nur im Owner-Fenster): fuettert ihn mit
# Tool-Aufrufen wie Claude Code (JSON auf stdin) und prueft deny/allow. Laeuft in einem Wegwerf-Repo mit zwei Worktrees: die
# Grant-Dateien liegen nur dort, das echte .claude/ bleibt unberuehrt. Kein Substrat, kein Netz, keine Kosten.
# Prueft: Suche im Haupt-Checkout, geschlossen/abgelaufen, fail-closed und die Umgehungswege (Umgebungsvariablen, Pfade im Aufruf).
# Usage:  .\scripts\dev\owner_window_hook_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
Clear-GitEnvironment
$HookSource = Join-Path $PSScriptRoot '..\..\.claude\hooks\enforce_owner_window.ps1'
$PowerShellExe = (Get-Process -Id $PID).Path
$failed = 0

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('owh_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$main = Join-Path $sandbox 'main'
$wt = Join-Path $sandbox 'wt'
$sibling = Join-Path $sandbox 'sibling'
$fake = Join-Path $sandbox 'fake'
$noRepo = Join-Path $sandbox 'norepo'

function Invoke-QuietGit([string]$Dir, [string[]]$GitArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $Dir -c user.name=Test -c user.email=test@example.com @GitArgs *> $null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') fehlgeschlagen" }
}
function Add-HookCopy([string]$Checkout) {
    $dir = Join-Path $Checkout '.claude\hooks'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item $HookSource $dir
    Copy-Item (Join-Path (Split-Path $HookSource) 'lib') $dir -Recurse
}
function Get-GrantPath([string]$Checkout) { Join-Path $Checkout '.claude\owner_grant.txt' }
function Set-Grant([string]$Checkout, [int]$Minutes) {
    [System.IO.File]::WriteAllText((Get-GrantPath $Checkout), [datetime]::UtcNow.AddMinutes($Minutes).ToString('o'))
}
function Clear-Grants {
    foreach ($c in @($main, $wt, $sibling, $fake, $noRepo)) { Remove-Item (Get-GrantPath $c) -Force -ErrorAction SilentlyContinue }
}

# Startet die Hook-Kopie des genannten Checkouts wie Claude Code. $Env setzt Variablen nur fuer diesen einen Lauf;
# ein String als $InputObj geht unveraendert auf stdin (Fall: kaputter Input).
function Invoke-Hook([string]$Checkout, [string]$Tool, $InputObj, [hashtable]$Env = @{}, [string]$Cwd = $Checkout) {
    $payload = if ($InputObj -is [string]) { $InputObj } else { @{ tool_name = $Tool; tool_input = $InputObj; cwd = $Cwd } | ConvertTo-Json -Compress -Depth 5 }
    $hook = Join-Path $Checkout '.claude\hooks\enforce_owner_window.ps1'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PowerShellExe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.WorkingDirectory = $Checkout
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.StandardInput.Write($payload); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    [void]$errTask.Wait(5000)
    return $out -match '"permissionDecision":"deny"'
}
function Assert-Case([string]$Name, [bool]$ExpectDeny, [string]$Checkout, [string]$Tool, $InputObj, [hashtable]$Env = @{}, [string]$Cwd = '') {
    if (-not $Cwd) { $Cwd = $Checkout }
    $denied = Invoke-Hook $Checkout $Tool $InputObj $Env $Cwd
    if ($denied -eq $ExpectDeny) { Write-Host "  [PASS] $Name" }
    else { Write-Host "  [FAIL] $Name (erwartet deny=$ExpectDeny, got $denied)" -ForegroundColor Red; $script:failed++ }
}
function Assert-True([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  [PASS] $Name" }
    else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}

try {
    # Wegwerf-Repo mit zwei Worktrees + ein zweites Repo als falsches Ziel (dort liegt spaeter ein gueltiger Grant)
    foreach ($d in @($main, $fake, $noRepo)) { New-Item -ItemType Directory -Force $d | Out-Null }
    Initialize-GitSandbox $main
    [System.IO.File]::WriteAllText((Join-Path $main 'doc.txt'), "x`n")
    Invoke-QuietGit $main @('add', '-A')
    Invoke-QuietGit $main @('commit', '-q', '-m', 'test', '--no-verify')
    Invoke-QuietGit $main @('worktree', 'add', '-q', '-b', 'wt', $wt)
    Invoke-QuietGit $main @('worktree', 'add', '-q', '-b', 'sibling', $sibling)
    Initialize-GitSandbox $fake
    foreach ($c in @($main, $wt, $sibling, $fake, $noRepo)) { Add-HookCopy $c }

    $suite = @{ command = '.\scripts\orch_test.ps1' }

    Write-Host 'Geschlossen:'
    foreach ($s in @('n8n_test', 'orch_test', 'e2e_test', 'judge_eval', 'multiturn_test', 'monitor_probe')) {
        Assert-Case "$s im Worktree gesperrt" $true $wt 'PowerShell' @{ command = ".\scripts\$s.ps1" }
    }
    Assert-Case 'Gratis-Suite monitor_probe_test frei' $false $wt  'PowerShell' @{ command = '.\scripts\dev\monitor_probe_test.ps1' }
    Assert-Case 'Durchspiel -Real gesperrt'           $true  $wt   'PowerShell' @{ command = '.\scripts\conversation_test.ps1 -Id s2 -Real' }
    Assert-Case 'Durchspiel -Rea (Kurzform) gesperrt' $true  $wt   'PowerShell' @{ command = '.\scripts\conversation_test.ps1 -Rea -Id s2' }
    Assert-Case 'Durchspiel gratis (Mock) frei'      $false $wt   'PowerShell' @{ command = '.\scripts\conversation_test.ps1 -Id s2' }
    Assert-Case 'Suite im Haupt-Checkout gesperrt'    $true  $main 'PowerShell' $suite
    Assert-Case 'Dev-Reset gesperrt'                  $true  $wt   'PowerShell' @{ command = '.\scripts\reset_dev_instance.ps1' }
    Assert-Case 'Dev-Reset -KeepInstance frei'        $false $wt   'PowerShell' @{ command = '.\scripts\reset_dev_instance.ps1 -KeepInstance' }
    Assert-Case 'anderer Befehl frei'                 $false $wt   'PowerShell' @{ command = 'git status' }

    Write-Host 'Offen im Haupt-Checkout:'
    Set-Grant $main 5
    Assert-Case 'Suite im Worktree erlaubt'           $false $wt      'PowerShell' $suite
    Assert-Case 'Suite im zweiten Worktree erlaubt'   $false $sibling 'PowerShell' $suite
    Assert-Case 'Suite im Haupt-Checkout erlaubt'     $false $main    'PowerShell' $suite
    Assert-Case 'Dev-Reset im Worktree erlaubt'       $false $wt      'PowerShell' @{ command = '.\scripts\reset_dev_instance.ps1' }
    Assert-Case 'Grant-Skript bleibt gesperrt'        $true  $wt      'PowerShell' @{ command = '.\scripts\grant_owner_window.ps1' }

    Write-Host 'Abgelaufen oder unlesbar:'
    Clear-Grants; Set-Grant $main -1
    Assert-Case 'abgelaufen: Worktree gesperrt'       $true  $wt 'PowerShell' $suite
    Assert-True 'abgelaufener Grant im Haupt-Checkout geloescht' (-not (Test-Path (Get-GrantPath $main)))
    Clear-Grants; [System.IO.File]::WriteAllText((Get-GrantPath $main), 'kein Zeitpunkt')
    Assert-Case 'unlesbarer Zeitpunkt: gesperrt'      $true  $wt 'PowerShell' $suite
    Clear-Grants; [System.IO.File]::WriteAllText((Get-GrantPath $main), '')
    Assert-Case 'leere Datei: gesperrt'               $true  $wt 'PowerShell' $suite

    # Die App kopiert beim Anlegen eines Worktrees die gitignorte Grant-Datei mit: nur die Datei im Haupt-Checkout zaehlt.
    Write-Host 'Grant-Datei im Worktree (Alt-Kopie) zaehlt nicht:'
    Clear-Grants; Set-Grant $wt 5
    Assert-Case 'gueltige Kopie im eigenen Worktree: gesperrt' $true $wt 'PowerShell' $suite
    Assert-Case 'gueltige Kopie im Nachbar-Worktree: gesperrt' $true $sibling 'PowerShell' $suite
    Assert-Case 'gueltige Kopie im Worktree, Haupt-Checkout: gesperrt' $true $main 'PowerShell' $suite
    Clear-Grants; Set-Grant $wt -1; Set-Grant $main 5
    Assert-Case 'abgelaufene Kopie, Haupt-Checkout offen: erlaubt' $false $wt 'PowerShell' $suite
    Assert-True 'offener Grant im Haupt-Checkout bleibt' (Test-Path (Get-GrantPath $main))

    Write-Host 'Umgehung ueber Umgebungsvariablen (gueltiger Grant nur im falschen Repo):'
    Clear-Grants; Set-Grant $fake 5
    $fakeGit = Join-Path $fake '.git'
    Assert-Case 'GIT_DIR'                             $true  $wt 'PowerShell' $suite @{ GIT_DIR = $fakeGit }
    Assert-Case 'GIT_COMMON_DIR'                      $true  $wt 'PowerShell' $suite @{ GIT_COMMON_DIR = $fakeGit }
    Assert-Case 'GIT_DIR + GIT_WORK_TREE'             $true  $wt 'PowerShell' $suite @{ GIT_DIR = $fakeGit; GIT_WORK_TREE = $fake }
    Assert-Case 'GIT_DIR auch im Haupt-Checkout'      $true  $main 'PowerShell' $suite @{ GIT_DIR = $fakeGit }
    Set-Grant $main 5
    Assert-Case 'GIT_DIR falsch, echtes Fenster offen: erlaubt' $false $wt 'PowerShell' $suite @{ GIT_DIR = (Join-Path $sandbox 'gibtsnicht') }
    Clear-Grants; Set-Grant $fake 5

    Write-Host 'Umgehung ueber Pfade im Aufruf (gueltiger Grant nur im falschen Repo):'
    Assert-Case 'cwd im Aufruf'                       $true  $wt 'PowerShell' $suite @{} $fake
    Assert-Case 'cd in den Befehl'                    $true  $wt 'PowerShell' @{ command = "Set-Location '$fake'; .\scripts\orch_test.ps1" }
    Assert-Case 'git -C in den Befehl'                $true  $wt 'PowerShell' @{ command = "git -C '$fake' status; .\scripts\orch_test.ps1" }
    Assert-Case 'GIT_DIR im Befehl'                   $true  $wt 'PowerShell' @{ command = "`$env:GIT_DIR='$fakeGit'; .\scripts\orch_test.ps1" }
    Assert-Case 'Grant-Pfad als Feld im Aufruf'       $true  $wt 'PowerShell' @{ command = '.\scripts\orch_test.ps1'; grant = (Get-GrantPath $fake) }

    Write-Host 'Fail-closed:'
    Clear-Grants; Set-Grant $noRepo 5
    Assert-Case 'ausserhalb eines Repos: gesperrt, auch mit Grant' $true $noRepo 'PowerShell' $suite
    Clear-Grants; Set-Grant $main 5
    $gitLess = [Environment]::SystemDirectory
    Assert-Case 'git nicht auffindbar: gesperrt, auch mit Grant' $true $wt 'PowerShell' $suite @{ PATH = $gitLess }
    $gitFile = Join-Path $wt '.git'
    $gitFileText = [System.IO.File]::ReadAllText($gitFile)
    (Get-Item -Force $gitFile).Attributes = 'Normal'   # git legt sie versteckt an, WriteAllText verweigert das
    [System.IO.File]::WriteAllText($gitFile, "gitdir: $(Join-Path $sandbox 'gibtsnicht')`n")
    Assert-Case 'kaputter Worktree-Verweis: gesperrt, auch mit Grant' $true $wt 'PowerShell' $suite
    [System.IO.File]::WriteAllText($gitFile, $gitFileText)
    Assert-True 'Grant bei git-Fehler nicht geloescht' (Test-Path (Get-GrantPath $main))

    Write-Host 'Kaputter Hook-Input (kein JSON):'
    Clear-Grants
    Assert-Case 'mit Suite-Namen: gesperrt'           $true  $wt '' '{kaputt .\scripts\orch_test.ps1'
    Assert-Case 'mit Grant-Skript: gesperrt'          $true  $wt '' '{kaputt .\scripts\grant_owner_window.ps1'
    Assert-Case 'mit Schreiben der Grant-Datei: gesperrt' $true $wt '' '{kaputt echo x > .claude/owner_grant.txt'
    Assert-Case 'ohne Bezug: frei'                    $false $wt '' '{kaputt git status'

    Write-Host 'Fenster selbst oeffnen (immer gesperrt, auch bei offenem Fenster):'
    Clear-Grants
    Assert-Case 'Grant-Skript ausfuehren'             $true  $wt 'PowerShell' @{ command = '.\scripts\grant_owner_window.ps1' }
    Assert-Case 'Grant-Skript ueber powershell -File' $true  $wt 'Bash'       @{ command = 'powershell -File scripts/grant_owner_window.ps1' }
    Assert-Case 'Grant-Skript erwaehnen'              $false $wt 'Bash'       @{ command = 'git log --oneline -- scripts/grant_owner_window.ps1' }
    Assert-Case 'Grant-Datei: Umleitung'             $true  $wt 'Bash'       @{ command = 'echo x > .claude/owner_grant.txt' }
    Assert-Case 'Grant-Datei: Set-Content'            $true  $wt 'PowerShell' @{ command = "Set-Content '$(Get-GrantPath $main)' x" }
    Assert-Case 'Grant-Datei: Copy-Item'              $true  $wt 'PowerShell' @{ command = "Copy-Item x.txt '$(Get-GrantPath $main)'" }
    foreach ($c in @('copy x.txt .claude\owner_grant.txt', 'move x.txt .claude\owner_grant.txt', 'ren x.txt owner_grant.txt',
                     'ni .claude\owner_grant.txt -Value x', 'sc .claude\owner_grant.txt x', 'ac .claude\owner_grant.txt x',
                     'cmd /c copy x.txt .claude\owner_grant.txt', 'robocopy . .claude owner_grant.txt',
                     'Invoke-WebRequest http://example.invalid/x -OutFile .claude\owner_grant.txt')) {
        Assert-Case "Grant-Datei: $c" $true $wt 'PowerShell' @{ command = $c }
    }
    Assert-Case 'Grant-Datei: Umleitung, Pfad mit Leerzeichen' $true $wt 'PowerShell' @{ command = 'echo x > "C:\mein ordner\.claude\owner_grant.txt"' }
    Assert-Case 'Grant-Datei: Umleitung, einfache Quotes'      $true $wt 'PowerShell' @{ command = "echo x >> 'C:\mein ordner\.claude\owner_grant.txt'" }
    Assert-Case 'Grant-Datei: powershell -c "copy"'   $true  $wt 'Bash'       @{ command = 'powershell -c "copy x.txt .claude\owner_grant.txt"' }
    Assert-Case 'Grant-Datei: nach Semikolon'         $true  $wt 'PowerShell' @{ command = 'git status; copy x.txt .claude\owner_grant.txt' }
    Assert-Case 'Grant-Datei: Suchwort copy frei'     $false $wt 'Bash'       @{ command = 'grep copy .claude/owner_grant.txt' }
    Assert-Case 'Grant-Datei erwaehnen (git log) frei' $false $wt 'Bash'      @{ command = 'git log --oneline -- .claude/owner_grant.txt' }
    Assert-Case 'Grant-Datei lesen frei'              $false $wt 'PowerShell' @{ command = "Get-Content '$(Get-GrantPath $main)'" }
    Set-Grant $main 5
    Assert-Case 'Grant-Datei: Umleitung bei offenem Fenster' $true $wt 'Bash' @{ command = 'echo x >> .claude/owner_grant.txt' }

    Write-Host 'Bibliothek fehlt, ist kaputt oder leer (Fenster offen):'
    $lib = Join-Path $sibling '.claude\hooks\lib\grant_window.ps1'
    [System.IO.File]::WriteAllText($lib, 'function {{{ kaputt')
    Assert-Case 'kaputt: Suite gesperrt'              $true  $sibling 'PowerShell' $suite
    Assert-Case 'kaputt: Grant-Datei lesen gesperrt'  $true  $sibling 'PowerShell' @{ command = 'Get-Content .claude\owner_grant.txt' }
    Assert-Case 'kaputt: anderer Befehl frei'         $false $sibling 'PowerShell' @{ command = 'git status' }
    [System.IO.File]::WriteAllText($lib, '')
    Assert-Case 'leer: Suite gesperrt'                $true  $sibling 'PowerShell' $suite
    Assert-Case 'leer: Grant-Datei schreiben gesperrt' $true $sibling 'PowerShell' @{ command = 'echo x > .claude\owner_grant.txt' }
    Assert-Case 'leer: anderer Befehl frei'           $false $sibling 'PowerShell' @{ command = 'git status' }
    Remove-Item $lib -Force
    Assert-Case 'fehlt: Suite gesperrt'               $true  $sibling 'PowerShell' $suite
    Assert-Case 'fehlt: anderer Befehl frei'          $false $sibling 'PowerShell' @{ command = 'git status' }
    Copy-Item (Join-Path (Split-Path $HookSource) 'lib\grant_window.ps1') $lib

    # Das Grant-Skript laeuft hier nur als Kopie im Wegwerf-Repo: seine Datei landet dort, nie im echten .claude/.
    Write-Host 'Grant-Skript aus einem Worktree gestartet:'
    Clear-Grants
    $scriptDir = Join-Path $wt 'scripts'
    New-Item -ItemType Directory -Force $scriptDir | Out-Null
    Copy-Item (Join-Path $PSScriptRoot '..\grant_owner_window.ps1') $scriptDir
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'grant_owner_window.ps1') -Minutes 5 *> $null
    Assert-True 'Datei liegt im Haupt-Checkout' (Test-Path (Get-GrantPath $main))
    Assert-True 'keine Datei im Worktree' (-not (Test-Path (Get-GrantPath $wt)))
    Assert-Case 'Fenster gilt im Nachbar-Worktree'    $false $sibling 'PowerShell' $suite
}
finally {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "owner_window_hook_test: $failed Fehler."
exit $failed
