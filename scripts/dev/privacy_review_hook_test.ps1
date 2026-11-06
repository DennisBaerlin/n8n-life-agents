#Requires -Version 5.1
# Test der Sperre vor jedem Push: .claude/hooks/dev_cycle_guard.ps1 (wie Claude Code, JSON auf stdin), scripts/privacy_outgoing.ps1 und
# scripts/privacy_review_stamp.ps1, alle als Kopie in einem Wegwerf-Repo mit Wegwerf-Remote. Kein Substrat, keine Kosten, kein Netz.
# Alle Werte sind erfunden. prek startet ihn, sobald eine der Dateien sich aendert.
# Usage:  .\scripts\dev\privacy_review_hook_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
$u8 = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
Clear-GitEnvironment
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$id = [guid]::NewGuid().ToString('N').Substring(0, 12)
$sandbox = Join-Path $env:TEMP "privacy_review_hook_$id"
$bare = Join-Path $env:TEMP "privacy_review_remote_$id"
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
function New-SandboxCommit([string]$Message, [string]$Line = $Message) {
    Add-Content -LiteralPath (Join-Path $sandbox 'doc.txt') -Value $Line -Encoding UTF8
    Invoke-SandboxGit @('add', '-A')
    Invoke-SandboxGit @('commit', '-q', '-m', $Message)
}
Initialize-GitSandbox $sandbox
Invoke-SandboxGit @('init', '-q', '--bare', '-b', 'main', $bare)
New-Item -ItemType Directory -Force (Join-Path $sandbox '.claude\hooks'), (Join-Path $sandbox 'scripts') | Out-Null
Copy-Item (Join-Path $repo '.claude\hooks\dev_cycle_guard.ps1') (Join-Path $sandbox '.claude\hooks\')
foreach ($name in 'privacy_lint.ps1', 'owner_fact_lint.ps1', 'privacy_outgoing.ps1', 'privacy_review_stamp.ps1') { Copy-Item (Join-Path $repo "scripts\$name") (Join-Path $sandbox 'scripts\') }
Write-SandboxFile '.gitignore' ".local/`n.env`n.claude/owner_grant.txt`n"
Write-SandboxFile '.env' "OWNER_CHAT_ID=12345678`n"
Write-SandboxFile '.local\privacy_denylist.txt' "Zauberwort`n"
Write-SandboxFile 'doc.txt' "eins`n"
Invoke-SandboxGit @('add', '-A')
Invoke-SandboxGit @('commit', '-q', '-m', 'eins')
Invoke-SandboxGit @('remote', 'add', 'origin', $bare)
$hook = Join-Path $sandbox '.claude\hooks\dev_cycle_guard.ps1'
$outgoing = Join-Path $sandbox 'scripts\privacy_outgoing.ps1'
$stampDir = Join-Path $sandbox '.local\privacy_review_stamps'

function Test-Denied([string]$Command) {
    $payload = @{ tool_name = 'Bash'; tool_input = @{ command = $Command }; cwd = $sandbox } | ConvertTo-Json -Compress -Depth 5
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.WorkingDirectory = $sandbox
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($payload); $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
    return $out -match '"permissionDecision":"deny"'
}
function Assert-Case([string]$Name, [bool]$ExpectDeny, [string]$Command) {
    $denied = Test-Denied $Command
    if ($denied -eq $ExpectDeny) { Write-Host "  [PASS] $Name" }
    else { Write-Host "  [FAIL] $Name (erwartet deny=$ExpectDeny, got $denied)" -ForegroundColor Red; $script:failed++ }
}
function Assert-True([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}
# Ruft privacy_outgoing.ps1 als eigenen Prozess; liefert Exit-Code und Hash.
function Invoke-Outgoing([string[]]$ScriptArgs = @(), [hashtable]$Environment = @{}) {
    foreach ($k in $Environment.Keys) { [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $outgoing @ScriptArgs)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
        foreach ($k in $Environment.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
    }
    @{ code = $code; hash = [string](@($out | Where-Object { $_ -match '^[0-9a-f]{64}$' }) | Select-Object -Last 1) }
}
# Setzt einen Stempel direkt (der Skript-Weg hat unten eigene Faelle).
function Add-Stamp([string[]]$ScriptArgs) {
    $h = (Invoke-Outgoing $ScriptArgs).hash
    if (-not $h) { throw 'kein Hash' }
    New-Item -ItemType Directory -Force $stampDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $stampDir "$h.json"), '{}', $u8)
}
# Schreibt den Pruef-Text; ein Fehler darf nie als leerer oder alter Text durchgehen.
function Get-ReviewText([string]$Source, [string]$File) {
    if (Test-Path -LiteralPath $File) { Remove-Item -LiteralPath $File }
    $r = Invoke-Outgoing @('-Ref', $Source, '-OutFile', $File)
    if ($r.code -ne 0 -or -not $r.hash) { throw "Pruef-Text nicht erzeugt (Exit $($r.code))" }
    [System.IO.File]::ReadAllText($File, $u8)
}
$publish = 'git ' + 'push origin'
$publishBare = 'git ' + 'push'

Write-Host 'Ohne Stempel:'
Assert-Case 'Neuer Stand gesperrt'           $true  "$publish main"
Assert-Case 'Ohne Refspec gesperrt'          $true  $publishBare
Assert-Case 'Mit -u gesperrt'                $true  "git push -u origin main"
Assert-Case 'Mit -c davor gesperrt'          $true  "git -c x=1 push origin main"
Assert-Case 'Im zweiten Befehl gesperrt'     $true  "git status; $publish main"
Assert-Case 'Text in Argument frei'          $false "git log --grep `"$publish main`""
Assert-Case 'Ref loeschen frei'              $false "$publish --delete altes"
Assert-Case 'Ziel loeschen frei'             $false "$publish :altes"
Assert-Case 'Unbekannter Stand gesperrt'     $true  "$publish gibtsnicht"

Write-Host 'Stempel gilt genau fuer einen Stand:'
Add-Stamp @('-Ref', 'main')
Assert-Case 'Gestempelter Stand frei'        $false "$publish main"
Assert-Case 'Ohne Refspec gleicher Stempel'  $false $publishBare
Assert-Case 'Anderer Zielname gesperrt'      $true  "$publish main:refs/heads/anders"
New-SandboxCommit 'zwei'
Assert-Case 'Neuer Commit gesperrt'          $true  "$publish main"
Add-Stamp @('-Ref', 'main')
Assert-Case 'Neu gestempelt frei'            $false "$publish main"
Invoke-SandboxGit @('commit', '-q', '--amend', '-m', 'zwei anders')
Assert-Case 'Geaenderter Commit-Text gesperrt' $true "$publish main"
Remove-Item $stampDir -Recurse -Force

Write-Host 'Lint bleibt davor:'
Add-Stamp @('-Ref', 'main', '-DestRef', 'zauberwort')
Assert-Case 'Stempel ersetzt das Lint nicht'  $true  "$publish main:zauberwort"

Write-Host 'Nur Unbekanntes ist ausgehend:'
Invoke-SandboxGit @('push', '-q', 'origin', 'main')
Assert-Case 'Nichts ausgehend: frei'          $false "$publish main"
Assert-True 'Nichts ausgehend: kein Hash'     (-not (Invoke-Outgoing @('-Ref', 'main')).hash)
Invoke-SandboxGit @('checkout', '-q', '-b', 'feat/a')
Assert-Case 'Nur neuer Branch-Name gesperrt'  $true  "$publish feat/a"
New-SandboxCommit 'hin' 'Zeile-hin'
$before = Get-Content -LiteralPath (Join-Path $sandbox 'doc.txt') -Encoding UTF8 | Where-Object { $_ -ne 'Zeile-hin' }
[System.IO.File]::WriteAllLines((Join-Path $sandbox 'doc.txt'), [string[]]$before, $u8)
Invoke-SandboxGit @('add', '-A')
Invoke-SandboxGit @('commit', '-q', '-m', 'weg')
$text = Join-Path $sandbox '.local\outgoing.txt'
$content = Get-ReviewText 'feat/a' $text
Assert-True 'Text zeigt die wieder geloeschte Zeile' ($content -match '\+Zeile-hin')
Assert-True 'Text zeigt beide Commit-Texte'   (($content -match 'hin') -and ($content -match 'weg'))
Assert-True 'Text zeigt den neuen Branch-Namen' ($content -match 'Branch-Name: feat/a')
Assert-True 'Text ohne Bekanntes vom Remote'  ($content -notmatch 'zwei anders')
Invoke-SandboxGit @('checkout', '-q', 'main')
New-SandboxCommit 'auf-main' 'Zeile-main'
Invoke-SandboxGit @('push', '-q', 'origin', 'main')
Invoke-SandboxGit @('checkout', '-q', 'feat/a')
Invoke-SandboxGit @('merge', '-q', '--no-edit', '-X', 'theirs', 'main')
$content = Get-ReviewText 'feat/a' $text
Assert-True 'Merge: Commit von main nicht erneut im Text' ($content -notmatch '(?m)^auf-main$')
Assert-True 'Merge: eigene Commits weiter im Text' ($content -match '\+Zeile-hin')
Write-SandboxFile 'docs\fn_catalog.md' "Generiert-Inhalt`n"
Write-SandboxFile 'packages\x\workflows\a.json' "Generiert-Workflow`n"
Write-SandboxFile 'packages\x\build\workflows\tools\a.ps1' "Quelle-Workflow`n"
Invoke-SandboxGit @('add', '-A')
Invoke-SandboxGit @('commit', '-q', '-m', 'nur-generiert')
$content = Get-ReviewText 'feat/a' $text
$withGenerated = (Invoke-Outgoing @('-Ref', 'feat/a')).hash
Assert-True 'Generierte Datei nicht im Text'  ($content -notmatch 'Generiert-Inhalt')
Assert-True 'Generierter Workflow nicht im Text' ($content -notmatch 'Generiert-Workflow')
Assert-True 'Quelle unter build/workflows im Text' ($content -match 'Quelle-Workflow')
Assert-True 'Commit-Text trotzdem im Text'    ($content -match 'nur-generiert')
Write-SandboxFile 'docs\fn_catalog.md' "Generiert-Inhalt2`n"
Invoke-SandboxGit @('add', '-A')
Invoke-SandboxGit @('commit', '-q', '--amend', '-m', 'nur-generiert')
Assert-True 'Hash deckt generierte Dateien ab' ((Invoke-Outgoing @('-Ref', 'feat/a')).hash -ne $withGenerated)
Invoke-SandboxGit @('checkout', '-q', 'main')

Write-Host 'Tags:'
Invoke-SandboxGit @('tag', '-a', 'v1.0.0', '-m', 'Text-eins')
Assert-Case 'Tag-Push gesperrt'               $true  "$publish v1.0.0"
Add-Stamp @('-Ref', 'v1.0.0')
Assert-Case 'Tag-Push gestempelt frei'        $false "$publish v1.0.0"
Assert-True 'Tag-Text im Pruef-Text'          ((Get-ReviewText 'v1.0.0' $text) -match 'Text-eins')
Invoke-SandboxGit @('tag', '-f', '-a', 'v1.0.0', '-m', 'Text-zwei')
Assert-Case 'Anderer Tag-Text gesperrt'       $true  "$publish v1.0.0"
Assert-Case 'Tag bleibt lokal: Branch-Push frei' $false "$publish main"
Assert-Case 'Mit --tags gesperrt'             $true  "$publish main --tags"
Add-Stamp @('-Ref', 'main', '-AllTags')
Assert-Case 'Mit --tags gestempelt frei'      $false "$publish main --tags"

Write-Host 'gh release create:'
Remove-Item $stampDir -Recurse -Force
Assert-Case 'Unbekannter Tag gesperrt'        $true  'gh release create v9.9.9'
Assert-Case 'Lokaler Tag gesperrt'            $true  'gh release create v1.0.0'
Invoke-SandboxGit @('push', '-q', 'origin', 'v1.0.0')
Assert-Case 'Tag und Commits oeffentlich: frei' $false 'gh release create v1.0.0'
Assert-Case 'gh release view frei'            $false 'gh release view v1.0.0'

Write-Host 'Wie prek pre-push (nur Umgebungsvariablen):'
Invoke-SandboxGit @('checkout', '-q', '-b', 'feat/b')
New-SandboxCommit 'bee'
$prekEnv = @{ PRE_COMMIT_TO_REF = [string](& git -C $sandbox rev-parse HEAD); PRE_COMMIT_REMOTE_NAME = 'origin'; PRE_COMMIT_REMOTE_BRANCH = 'refs/heads/feat/b' }
Assert-True 'prek: ohne Stempel Exit 1'       ((Invoke-Outgoing @('-Check') $prekEnv).code -eq 1)
Add-Stamp @('-Ref', 'feat/b')
Assert-True 'prek: Stempel aus -Ref passt'    ((Invoke-Outgoing @('-Check') $prekEnv).code -eq 0)
Assert-Case 'Hook: derselbe Stempel passt'    $false "$publish feat/b"
Assert-Case 'Hook: HEAD derselbe Stempel'     $false "$publish HEAD"
Invoke-SandboxGit @('push', '-q', 'origin', 'feat/b')

Write-Host 'Fail-closed:'
New-SandboxCommit 'cee'
$moved = "$outgoing.weg"
Move-Item $outgoing $moved
Assert-Case 'Skript fehlt: gesperrt'          $true  "$publish feat/b"
Move-Item $moved $outgoing
Assert-True 'Unbekanntes Remote: Exit 2'      ((Invoke-Outgoing @('-Check', '-Remote', 'gibtsnicht')).code -eq 2)

Write-Host 'Mitwirkende (ohne Liste, ohne echte Chat-ID):'
$savedList = [System.IO.File]::ReadAllText((Join-Path $sandbox '.local\privacy_denylist.txt'), $u8)
Remove-Item (Join-Path $sandbox '.local\privacy_denylist.txt'), (Join-Path $sandbox '.env')
Assert-Case 'Ohne .env: kein Stempel noetig'  $false "$publish feat/b"
Write-SandboxFile '.env' "OWNER_CHAT_ID=0`n"
Assert-Case 'OWNER_CHAT_ID=0: kein Stempel noetig' $false "$publish feat/b"
Assert-True '-Check frei'                     ((Invoke-Outgoing @('-Check')).code -eq 0)
Write-SandboxFile '.env' "OWNER_CHAT_ID=12345678`n"
Assert-Case 'Echte Chat-ID ohne Liste: gesperrt' $true "$publish feat/b"
Write-SandboxFile '.local\privacy_denylist.txt' $savedList

# --- Stempel-Skript: nur mit sauberem Baum und gruenen Lints, ein Owner-Fenster ist nicht noetig -----------------------
Write-Host 'Stempel-Skript:'
if (Test-Path $stampDir) { Remove-Item $stampDir -Recurse -Force }
function Invoke-Stamp([string[]]$ScriptArgs = @()) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox 'scripts\privacy_review_stamp.ps1') @ScriptArgs *> $null; return $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
}
function Assert-Stamp([string]$Name, [bool]$ExpectStamp, [string[]]$ScriptArgs = @()) {
    if (Test-Path $stampDir) { Remove-Item $stampDir -Recurse -Force }
    $code = Invoke-Stamp $ScriptArgs
    $hash = (Invoke-Outgoing $ScriptArgs).hash
    $ok = if ($ExpectStamp) { $code -eq 0 -and (Test-Path (Join-Path $stampDir "$hash.json")) } else { $code -ne 0 -and -not (Test-Path $stampDir) }
    if ($ok) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name (Exit $code)" -ForegroundColor Red; $script:failed++ }
}
Assert-Stamp 'Ohne Owner-Fenster, Baum sauber: Stempel' $true
Assert-Case 'Stempel aus dem Skript gibt frei' $false "$publish feat/b"
$body = [System.IO.File]::ReadAllText((Get-ChildItem $stampDir | Select-Object -First 1).FullName, $u8) | ConvertFrom-Json
Assert-True 'Stempel enthaelt nur Hash, Commit, Zeitpunkt' ((@($body.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'commit,hash,reviewed_at')
Invoke-SandboxGit @('tag', '-a', 'v2.0.0', '-m', 'Text-drei')
Assert-Stamp 'Mit -AllTags: Stempel' $true @('-AllTags')
Assert-Case 'Mit --tags frei'                 $false "$publish feat/b --tags"
Assert-Case 'Derselbe Push ohne Tags frei'    $false "$publish feat/b"
Invoke-SandboxGit @('tag', '-d', 'v2.0.0')
Invoke-SandboxGit @('push', '-q', 'origin', 'feat/b')
Remove-Item $stampDir -Recurse -Force
Assert-True 'Nichts ausgehend: kein Hash'     (-not (Invoke-Outgoing).hash)
Assert-True 'Nichts ausgehend: Stempel-Skript Exit 0' ((Invoke-Stamp) -eq 0)
Assert-True 'Nichts ausgehend: kein Stempel'  (-not (Test-Path $stampDir))
New-SandboxCommit 'dee'
Write-SandboxFile 'neu.txt' 'x'
Assert-Stamp 'Baum nicht sauber: kein Stempel' $false
Remove-Item (Join-Path $sandbox 'neu.txt')
Write-SandboxFile 'adresse.txt' ('192.168.' + '178.99' + "`n")
Invoke-SandboxGit @('add', '-A')
Invoke-SandboxGit @('commit', '-q', '-m', 'vier')
Assert-Stamp 'Lint rot: kein Stempel' $false

Remove-Item $sandbox, $bare -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "privacy_review_hook_test: $failed Fehler."
exit $failed
