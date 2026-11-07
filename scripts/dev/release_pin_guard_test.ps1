#Requires -Version 5.1
# release_pin_guard_test.ps1 -- Regressionstest der Release-Tag-Sperre: scripts/release_pin_guard.ps1 (Test-MasterPinOffline aus
# scripts/lib/release_images.ps1) und ihr Einsatz in .claude/hooks/dev_cycle_guard.ps1 (git tag v.., git push mit Tag), alle als
# Kopie in einem Wegwerf-Repo mit Wegwerf-Remote. Ausgangsfall: Tag auf einem Stand, dessen Release-Baum sich seit dem Bau des
# master-Images geaendert hat. Kein Substrat, kein Netz, keine Kosten; alle Werte erfunden. prek startet ihn bei Aenderungen.
# Usage:  .\scripts\dev\release_pin_guard_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$u8 = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
Clear-GitEnvironment
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$id = [guid]::NewGuid().ToString('N').Substring(0, 12)
$sandbox = Join-Path $env:TEMP "release_pin_guard_$id"
$bare = Join-Path $env:TEMP "release_pin_remote_$id"
New-Item -ItemType Directory -Force $sandbox, $bare | Out-Null
$failed = 0

function Invoke-SandboxGit([string[]]$GitArgs, [string]$Dir = $sandbox) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $Dir -c user.name=Test -c user.email=test@example.com -c core.autocrlf=false @GitArgs *> $null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') fehlgeschlagen" }
}
function Write-SandboxFile([string]$Rel, [string]$Text) {
    $path = Join-Path $sandbox $Rel
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    [System.IO.File]::WriteAllText($path, $Text, $u8)
}
function New-SandboxCommit([string]$Rel, [string]$Line) {
    Add-Content -LiteralPath (Join-Path $sandbox $Rel) -Value $Line -Encoding UTF8
    Invoke-SandboxGit @('add', '-A')
    Invoke-SandboxGit @('commit', '-q', '-m', "aendert $Rel")
}
$composeRel = 'provisioning\compose\compose.yml'
$neutral = "x-images:`n  master: &img_master `${LA_MASTER_IMAGE:?LA_MASTER_IMAGE fehlt (kein Release-Pin)}`n"
function Set-Pin([string]$Hex) {
    Write-SandboxFile $composeRel "x-images:`n  master: &img_master `${LA_MASTER_IMAGE:-ghcr.io/beispiel/repo/master@sha256:$($Hex * 32)}`n"
    Invoke-SandboxGit @('commit', '-q', '-am', 'chore(release): pin master image')
}

Initialize-GitSandbox $sandbox
Invoke-SandboxGit @('init', '-q', '--bare', '-b', 'main', $bare)
New-Item -ItemType Directory -Force (Join-Path $sandbox '.claude\hooks') | Out-Null
Copy-Item (Join-Path $repo '.claude\hooks\dev_cycle_guard.ps1') (Join-Path $sandbox '.claude\hooks\')
foreach ($name in 'privacy_lint.ps1', 'owner_fact_lint.ps1', 'privacy_outgoing.ps1', 'privacy_review_stamp.ps1', 'release_pin_guard.ps1', 'lib\owner_machine.ps1', 'lib\release_images.ps1') {
    $dst = Join-Path $sandbox "scripts\$name"
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item (Join-Path $repo "scripts\$name") $dst
}
Write-SandboxFile '.gitignore' ".local/`n.env`n"
Write-SandboxFile '.env' "OWNER_CHAT_ID=12345678`n"
Write-SandboxFile '.local\privacy_denylist.txt' "Zauberwort`n"
Write-SandboxFile $composeRel $neutral
Write-SandboxFile 'provisioning\a.sh' "echo a`n"
Write-SandboxFile 'docs\d.md' "d`n"
Invoke-SandboxGit @('add', '-A')
Invoke-SandboxGit @('commit', '-q', '-m', 'eins')
Invoke-SandboxGit @('remote', 'add', 'origin', $bare)
Invoke-SandboxGit @('push', '-q', 'origin', 'main')
$hook = Join-Path $sandbox '.claude\hooks\dev_cycle_guard.ps1'
$guard = Join-Path $sandbox 'scripts\release_pin_guard.ps1'

# Hook-Entscheidung: 'pin' (Release-Pin-Sperre), 'deny' (andere Sperre, z. B. Pruefstempel), 'free'.
function Get-HookVerdict([string]$Command) {
    $payload = @{ tool_name = 'Bash'; tool_input = @{ command = $Command }; cwd = $sandbox } | ConvertTo-Json -Compress -Depth 5
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.WorkingDirectory = $sandbox
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($payload); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    if ($out -match '"permissionDecision":"deny"' -and $out -match 'RELEASE-TAG GESPERRT') { return 'pin' }
    if ($out -match '"permissionDecision":"deny"') { return 'deny' }
    return 'free'
}
function Assert-Hook([string]$Name, [bool]$ExpectPin, [string]$Command) {
    $v = Get-HookVerdict $Command
    if (($v -eq 'pin') -eq $ExpectPin) { Write-Host "  [PASS] $Name" }
    else { Write-Host "  [FAIL] $Name (erwartet Pin-Sperre=$ExpectPin, got $v)" -ForegroundColor Red; $script:failed++ }
}
function Invoke-Guard([string[]]$ScriptArgs = @(), [hashtable]$Environment = @{}) {
    foreach ($k in $Environment.Keys) { [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $guard @ScriptArgs); return $LASTEXITCODE }
    finally {
        $ErrorActionPreference = $prev
        foreach ($k in $Environment.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
    }
}
function Assert-Exit([string]$Name, [int]$Expect, [int]$Got) {
    if ($Got -eq $Expect) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name (erwartet Exit $Expect, got $Got)" -ForegroundColor Red; $script:failed++ }
}
$tagCmd = 'git ' + 'tag'
$publish = 'git ' + 'push origin'

try {
    Write-Host 'Anlegen (git tag):'
    Assert-Hook 'Ohne Pin gesperrt'                   $true  "$tagCmd -a v1.0.0 --cleanup=whitespace -F notes.md"
    Assert-Hook 'Anderer Tag-Name frei'               $false "$tagCmd probe-1"
    Assert-Hook 'Tag-Liste frei'                      $false "$tagCmd -l 'v*'"
    Assert-Hook 'Tag loeschen frei'                   $false "$tagCmd -d v1.0.0"
    Assert-Hook '--contains v.. frei'                 $false "$tagCmd --contains v1.0.0"
    Assert-Hook 'Text in Argument frei'               $false "git log --grep `"$tagCmd v1.0.0`""
    Set-Pin 'ab'
    Assert-Hook 'Frischer Pin frei'                   $false "$tagCmd -a v1.0.0 --cleanup=whitespace -F notes.md"
    Assert-Hook 'Frischer Pin, -m mit Leerzeichen frei' $false "$tagCmd -a v1.0.0 -m `"Release v1.0.0 fertig`""
    New-SandboxCommit 'docs\d.md' 'nur Doku'
    Assert-Hook 'Doku seit dem Pin frei'              $false "$tagCmd -a v1.0.0 -m x"
    $good = [string](& git -C $sandbox rev-parse HEAD)
    New-SandboxCommit 'provisioning\a.sh' 'echo b'
    Assert-Hook 'Release-Baum seit dem Pin gesperrt'  $true  "$tagCmd -a v1.0.0 -m x"
    Assert-Hook 'Kombiniert -am gesperrt'             $true  "$tagCmd -am x v1.0.0"
    Assert-Hook 'Nach anderem Befehl gesperrt'        $true  "git status; $tagCmd v1.0.0"
    Assert-Hook 'Mit -C davor gesperrt'               $true  "git -C . tag v1.0.0"
    Assert-Hook 'Auf altem Stand frei'                $false "$tagCmd -a v1.0.0 -m x $good"
    Assert-Hook 'Unbekannter Stand gesperrt'          $true  "$tagCmd v1.0.0 gibtsnicht"

    Write-Host 'Push:'
    Invoke-SandboxGit @('tag', '-a', 'v1.0.0', '-m', 'veraltet')
    Invoke-SandboxGit @('tag', '-a', 'v0.9.0', '-m', 'gut', $good)
    Assert-Hook 'Tag-Push veraltet gesperrt'          $true  "$publish v1.0.0"
    Assert-Hook 'refs/tags/ veraltet gesperrt'        $true  "$publish refs/tags/v1.0.0"
    Assert-Hook 'Tag-Push frisch: keine Pin-Sperre'   $false "$publish v0.9.0"
    Assert-Hook 'Branch-Push: keine Pin-Sperre'       $false "$publish main"
    Assert-Hook 'Branch-Push mit --tags gesperrt'     $true  "$publish main --tags"
    Assert-Hook 'Branch-Push --follow-tags gesperrt'  $true  "git push --follow-tags origin main"

    Write-Host 'Wie prek pre-push (nur Umgebungsvariablen):'
    Assert-Exit 'prek: Tag veraltet Exit 1' 1 (Invoke-Guard @() @{ PRE_COMMIT_REMOTE_BRANCH = 'refs/tags/v1.0.0'; PRE_COMMIT_TO_REF = 'v1.0.0'; PRE_COMMIT_REMOTE_NAME = 'origin' })
    Assert-Exit 'prek: Tag frisch Exit 0'   0 (Invoke-Guard @() @{ PRE_COMMIT_REMOTE_BRANCH = 'refs/tags/v0.9.0'; PRE_COMMIT_TO_REF = 'v0.9.0'; PRE_COMMIT_REMOTE_NAME = 'origin' })
    Assert-Exit 'prek: Branch Exit 0'       0 (Invoke-Guard @() @{ PRE_COMMIT_REMOTE_BRANCH = 'refs/heads/main'; PRE_COMMIT_TO_REF = 'main'; PRE_COMMIT_REMOTE_NAME = 'origin' })
    Assert-Exit 'Unbekanntes Remote Exit 2' 2 (Invoke-Guard @('-AllTags') @{ PRE_COMMIT_REMOTE_BRANCH = 'refs/heads/main'; PRE_COMMIT_TO_REF = 'main'; PRE_COMMIT_REMOTE_NAME = 'gibtsnicht' })

    Write-Host 'Neuer Bau + Pin heilt:'
    Set-Pin 'cd'
    Invoke-SandboxGit @('tag', '-d', 'v1.0.0')
    Assert-Hook 'Neu gepinnt: Anlegen frei'           $false "$tagCmd -a v1.0.0 -m x"
    Invoke-SandboxGit @('tag', '-a', 'v1.0.0', '-m', 'frisch')
    Assert-Hook 'Neu gepinnt: Tag-Push frei'          $false "$publish v1.0.0"
    Write-SandboxFile $composeRel $neutral
    Invoke-SandboxGit @('commit', '-q', '-am', 'pin weg')
    Assert-Hook 'Pin wieder neutral gesperrt'         $true  "$tagCmd v1.1.0"

    Write-Host 'Mitwirkende (ohne Liste, ohne echte Chat-ID):'
    Remove-Item -LiteralPath (Join-Path $sandbox '.local\privacy_denylist.txt'), (Join-Path $sandbox '.env')
    Assert-Hook 'Keine Owner-Maschine: frei'          $false "$tagCmd v1.1.0"
    Assert-Exit 'Keine Owner-Maschine: Exit 0' 0 (Invoke-Guard @('-Tag', 'v1.1.0'))

    Write-Host 'Fail-closed:'
    Write-SandboxFile '.local\privacy_denylist.txt' "Zauberwort`n"
    Remove-Item -LiteralPath $guard
    Assert-Hook 'Skript fehlt: gesperrt'              $true  "$tagCmd v1.1.0"
} finally {
    Remove-Item -LiteralPath $sandbox, $bare -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "release_pin_guard_test: $failed Fehler."
exit $failed
