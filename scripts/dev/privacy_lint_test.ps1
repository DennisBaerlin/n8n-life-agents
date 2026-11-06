#Requires -Version 5.1
# privacy_lint_test.ps1 -- Regressionstest fuer scripts/privacy_lint.ps1 in einem Wegwerf-Repo (mit Worktree). Alle Werte
# sind erfunden. Kein Substrat, kein Netz, kein LLM; prek startet ihn, sobald das Lint oder dieser Test sich aendert.
# Usage:  .\scripts\dev\privacy_lint_test.ps1
# Exit-Code = Anzahl Fehler.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$u8 = New-Object System.Text.UTF8Encoding($false)
$Lint = Join-Path $PSScriptRoot '..\privacy_lint.ps1'
$failed = 0
$passed = 0
$SandboxLib = Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1'
. $SandboxLib
Clear-GitEnvironment

function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, $u8)
}
# git ohne PowerShell-Fehler bei stderr-Text; Exit != 0 bricht den Testlauf ab.
function Invoke-TestGit([string]$Dir, [string[]]$GitArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $Dir -c user.name=Test -c user.email=test@example.com -c core.autocrlf=false @GitArgs *> $null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') fehlgeschlagen" }
}
# Legt ein Wegwerf-Repo an: getrackte Datei, Lint unter scripts/, .local/.env ignoriert. Liefert den Pfad.
function New-TestRepo([string]$Tracked = 'nichts Besonderes') {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('plt_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Force $dir | Out-Null
    Initialize-GitSandbox $dir
    Write-Utf8 (Join-Path $dir '.gitignore') ".local/`n.env`n"
    Write-Utf8 (Join-Path $dir 'doc.txt') "$Tracked`n"
    Copy-Item $Lint (New-Item -ItemType Directory -Force (Join-Path $dir 'scripts')).FullName
    Invoke-TestGit $dir @('add', '-A')
    Invoke-TestGit $dir @('commit', '-q', '-m', 'test')
    $dir
}
function Add-TestWorktree([string]$Repo) {
    $wt = "$Repo-wt"
    Invoke-TestGit $Repo @('worktree', 'add', '-q', '-b', 'wt', $wt)
    $wt
}
# Startet das Lint als eigenen Prozess; liefert den Exit-Code.
function Invoke-TestLint([string]$Dir, [hashtable]$Environment = @{}, [string[]]$LintArgs = @()) {
    $saved = @{}
    foreach ($k in @('CI', 'GITHUB_ACTIONS') + @($Environment.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
    foreach ($k in $Environment.Keys) { [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir 'scripts\privacy_lint.ps1') @LintArgs *> $null; $code = $LASTEXITCODE }
    finally {
        $ErrorActionPreference = $prev
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $code
}
function Assert-Lint([string]$Name, [bool]$ExpectFail, [int]$Code) {
    if (($Code -ne 0) -eq $ExpectFail) { $script:passed++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $Name (Exit $Code)" -ForegroundColor Red }
}
function Remove-TestRepo([string]$Repo) {
    foreach ($d in @("$Repo-wt", $Repo)) { if (Test-Path $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

Write-Host 'privacy_lint_test: Sandbox trifft nie das echte Repo'
# (0) Wie im Commit-Hook: GIT_DIR & Co. zeigen auf ein "echtes" Repo (hier ein Wegwerf-Repo). Ein eigener Prozess legt ein Test-Repo an.
function Get-RepoFingerprint([string]$Repo) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    (@('config', 'index', 'HEAD') | ForEach-Object { -join ($md5.ComputeHash([System.IO.File]::ReadAllBytes((Join-Path $Repo ".git\$_"))) | ForEach-Object { $_.ToString('x2') }) }) -join '/'
}
function Invoke-SandboxProbe([string]$Real, [string]$Target, [bool]$ClearEnv) {
    $clear = if ($ClearEnv) { 'Clear-GitEnvironment;' } else { '' }
    $probe = ". '$SandboxLib'; $clear Initialize-GitSandbox '$Target'; Set-Content (Join-Path '$Target' 'a.txt') x; & git -C '$Target' add -A"
    $saved = @{}
    foreach ($k in 'GIT_DIR', 'GIT_INDEX_FILE', 'GIT_WORK_TREE') { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
    [Environment]::SetEnvironmentVariable('GIT_DIR', (Join-Path $Real '.git'))
    [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', (Join-Path $Real '.git\index'))
    [Environment]::SetEnvironmentVariable('GIT_WORK_TREE', $Real)
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & powershell -NoProfile -ExecutionPolicy Bypass -Command "`$ErrorActionPreference = 'Stop'; $probe" *> $null; $code = $LASTEXITCODE }
    finally {
        $ErrorActionPreference = $prev
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $code
}
$real = New-TestRepo 'echtes Repo'
$fingerprint = Get-RepoFingerprint $real
$target = Join-Path ([System.IO.Path]::GetTempPath()) ('plt_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Force $target | Out-Null
$code = Invoke-SandboxProbe $real $target $true
Assert-Lint 'Hook-Umgebung geleert: Test-Repo entsteht' $false $code
Assert-Lint 'Hook-Umgebung geleert: echtes Repo unveraendert (config, Index, HEAD)' $false $(if ((Get-RepoFingerprint $real) -eq $fingerprint) { 0 } else { 1 })
Assert-Lint 'Hook-Umgebung geleert: Repo liegt im Temp-Ordner' $false $(if (Test-Path -LiteralPath (Join-Path $target '.git\config')) { 0 } else { 1 })
Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
# Gegenprobe: Ohne Leeren trifft git das "echte" Repo; die Sicherung bricht ab, bevor etwas in dessen Index landet.
$real2 = New-TestRepo 'echtes Repo'
$indexBefore = (Get-RepoFingerprint $real2) -split '/' | Select-Object -Index 1
$target = Join-Path ([System.IO.Path]::GetTempPath()) ('plt_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Force $target | Out-Null
Assert-Lint 'Gegenprobe ohne Leeren: Sicherung bricht ab' $true (Invoke-SandboxProbe $real2 $target $false)
$indexAfter = (Get-RepoFingerprint $real2) -split '/' | Select-Object -Index 1
Assert-Lint 'Gegenprobe ohne Leeren: Index des echten Repos unveraendert' $false $(if ($indexBefore -eq $indexAfter) { 0 } else { 1 })
Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
Remove-TestRepo $real
Remove-TestRepo $real2

Write-Host 'privacy_lint_test: Liste und Haupt-Checkout'
$RealEnv = "OWNER_CHAT_ID=12345678`n"
$ZeroEnv = "OWNER_CHAT_ID=0`n"

# (1) Haupt-Checkout mit Liste: Treffer sperrt, ohne Treffer gruen
$r = New-TestRepo 'der Wert Zauberwort steht hier'
Write-Utf8 (Join-Path $r '.env') $RealEnv
Write-Utf8 (Join-Path $r '.local\privacy_denylist.txt') "Zauberwort`n"
Assert-Lint 'Haupt-Checkout: Treffer sperrt' $true (Invoke-TestLint $r)
# (2) Worktree ohne eigene Kopie und ohne .env: die Liste des Haupt-Checkouts gilt
$wt = Add-TestWorktree $r
Assert-Lint 'Worktree ohne Kopie: Liste des Haupt-Checkouts gilt' $true (Invoke-TestLint $wt)
Remove-TestRepo $r

$r = New-TestRepo 'nichts Besonderes'
Write-Utf8 (Join-Path $r '.env') $RealEnv
Write-Utf8 (Join-Path $r '.local\privacy_denylist.txt') "Zauberwort`n"
Assert-Lint 'Haupt-Checkout: ohne Treffer gruen' $false (Invoke-TestLint $r)
$wt = Add-TestWorktree $r
Assert-Lint 'Worktree: ohne Treffer gruen' $false (Invoke-TestLint $wt)
Remove-TestRepo $r

# (3) Alte Kopie im Worktree zaehlt nicht: neuer Wert steht nur im Haupt-Checkout
$r = New-TestRepo 'der Wert Neuwort steht hier'
Write-Utf8 (Join-Path $r '.env') $RealEnv
Write-Utf8 (Join-Path $r '.local\privacy_denylist.txt') "Neuwort`n"
$wt = Add-TestWorktree $r
Write-Utf8 (Join-Path $wt '.local\privacy_denylist.txt') "Altwort`n"
Assert-Lint 'Worktree mit alter Kopie: Haupt-Checkout zaehlt' $true (Invoke-TestLint $wt)
Remove-TestRepo $r

# (4) Liste fehlt: Mitwirkende und CI pruefen nur generisch, gesperrt wird nur mit echter Chat-ID (Owner-Maschine)
$r = New-TestRepo
Assert-Lint 'Mitwirkende: ohne Liste, ohne .env nur generisch' $false (Invoke-TestLint $r)
$wt = Add-TestWorktree $r
Assert-Lint 'Mitwirkende: Worktree ohne Liste, ohne .env nur generisch' $false (Invoke-TestLint $wt)
Assert-Lint 'ohne Liste in CI: nur generisch' $false (Invoke-TestLint $r @{ CI = 'true' })
Write-Utf8 (Join-Path $r '.env') $ZeroEnv
Assert-Lint 'ohne Liste, OWNER_CHAT_ID=0: nur generisch' $false (Invoke-TestLint $r)
Assert-Lint 'Worktree ohne Liste, Haupt-Checkout OWNER_CHAT_ID=0: nur generisch' $false (Invoke-TestLint $wt)
Write-Utf8 (Join-Path $r '.env') $RealEnv
Assert-Lint 'ohne Liste, echte Chat-ID: sperrt' $true (Invoke-TestLint $r)
# Auch ohne Liste bleiben die generischen Regeln scharf (Mitwirkende und CI)
Remove-TestRepo $r
$r = New-TestRepo ('Adresse 192.168.' + '178.99 im Text')
Assert-Lint 'Mitwirkende: generische Regel sperrt weiter' $true (Invoke-TestLint $r)
Assert-Lint 'CI: generische Regel sperrt weiter' $true (Invoke-TestLint $r @{ CI = 'true' })
Remove-TestRepo $r

Write-Host 'privacy_lint_test: erzeugte Liste und Schreibweisen'
# (5) Die erzeugte Liste zaehlt wie die handgepflegte, auch im Worktree; -ExtraTermsFile gilt nur fuer diesen Lauf
$r = New-TestRepo 'der Wert Instanzwort steht hier'
Write-Utf8 (Join-Path $r '.env') $RealEnv
Write-Utf8 (Join-Path $r '.local\privacy_denylist.txt') "Zauberwort`n"
Assert-Lint 'ohne erzeugte Liste gruen' $false (Invoke-TestLint $r)
$extra = Join-Path $r '.local\vorschau.txt'
Write-Utf8 $extra "Instanzwort`n"
Assert-Lint 'Vorschau-Begriffe sperren den Lauf' $true (Invoke-TestLint $r @{} @('-ExtraTermsFile', $extra))
Write-Utf8 (Join-Path $r '.local\privacy_denylist.generated.txt') "# Kommentar`nInstanzwort`n"
Assert-Lint 'erzeugte Liste sperrt' $true (Invoke-TestLint $r)
$wt = Add-TestWorktree $r
Assert-Lint 'erzeugte Liste sperrt im Worktree' $true (Invoke-TestLint $wt)
Remove-TestRepo $r

# (6) Schreibweisen je Art
. (Join-Path $PSScriptRoot '..\lib\privacy_terms.ps1')
function Assert-Variants([string]$Name, [string]$Kind, [string]$Value, [string[]]$Expected) {
    $got = @(Get-PrivacyTermVariants $Kind $Value | Sort-Object)
    $want = @($Expected | Sort-Object)
    if (($got -join '|') -ceq ($want -join '|')) { $script:passed++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $Name" -ForegroundColor Red }
}
Assert-Variants 'Betrag in allen Schreibweisen' 'amount' '1234.50' @('1234.50', '1234,50', '1.234,50')
Assert-Variants 'Betrag negativ wie positiv' 'amount' '-7654.32' @('7654.32', '7654,32', '7.654,32')
Assert-Variants 'Stueckzahl ohne nachlaufende Nullen' 'amount' '0.12345000' @('0.12345', '0,12345')
Assert-Variants 'Datum ISO und deutsch' 'date' '2001-02-03' @('2001-02-03', '03.02.2001')
Assert-Variants 'Nummer roh und ohne Trenner' 'id' 'DE00 1234 5678' @('DE00 1234 5678', 'DE0012345678')
Assert-Variants 'zu kurze Nummer faellt weg' 'id' '123' @()
Assert-Variants 'zu kurzer Name faellt weg' 'name' 'Al' @()

Write-Host 'privacy_lint_test: Beugung und Zusammensetzung'
# (7) Getrackter Baum und Text-Modus: Beugungsform und Bezeichner treffen, ein laengeres Wort mit gleichem Anfang nicht
function Assert-Word([string]$Name, [bool]$ExpectFail, [string]$Text) {
    $r = New-TestRepo $Text
    Write-Utf8 (Join-Path $r '.env') $RealEnv
    Write-Utf8 (Join-Path $r '.local\privacy_denylist.txt') "Zauberwort`n"
    Assert-Lint "Baum: $Name" $ExpectFail (Invoke-TestLint $r)
    $file = Join-Path $r '.local\text.txt'
    Write-Utf8 $file "$Text`n"
    Assert-Lint "Text: $Name" $ExpectFail (Invoke-TestLint $r @{} @('-TextFile', $file))
    Remove-TestRepo $r
}
Assert-Word 'Besitzform' $true 'das ist Zauberworts Akte'
Assert-Word 'Besitzform mit Apostroph' $true "das ist Zauberwort's Akte"
Assert-Word 'Bezeichner hinten' $true 'der Schluessel zauberwort_abschnitt'
Assert-Word 'Bezeichner vorn' $true 'der Schluessel alt_zauberwort'
Assert-Word 'Grossschreibung' $true 'ZAUBERWORT steht hier'
Assert-Word 'laengeres Wort' $false 'die Zauberwortliste und die Zauberworte'
Assert-Word 'Wort mit gleichem Ende' $false 'das Ueberzauberwort bleibt'

Write-Host 'privacy_lint_test: Binaerdateien und Branch-Namen'
# (9) Binaerdateien nur in den erlaubten Ablagen; PDF und Excel werden gelesen
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-TestXlsx([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        $w = New-Object System.IO.StreamWriter($zip.CreateEntry('xl/sharedStrings.xml').Open(), $u8)
        try { $w.Write("<sst><si><t>$Text</t></si></sst>") } finally { $w.Dispose() }
    } finally { $zip.Dispose() }
}
function Assert-Binary([string]$Name, [bool]$ExpectFail, [string[]]$RelParts, [string]$Text) {
    $r = New-TestRepo
    Write-Utf8 (Join-Path $r '.env') $RealEnv
    Write-Utf8 (Join-Path $r '.local\privacy_denylist.txt') "Zauberwort`n"
    $file = Join-Path $r ($RelParts -join '\')
    if ($file -match '\.xlsx$') { New-TestXlsx $file $Text } else { Write-Utf8 $file "%PDF (Inhalt: $Text)`n" }
    Invoke-TestGit $r @('add', '-A')
    Assert-Lint $Name $ExpectFail (Invoke-TestLint $r)
    Remove-TestRepo $r
}
Assert-Binary 'Bild ausserhalb der Ablagen' $true @('docs', 'neu.png') 'x'
Assert-Binary 'Bild in erlaubter Ablage' $false @('docs', 'site', 'static', 'img', 'neu.png') 'x'
Assert-Binary 'PDF ohne Treffer' $false @('tests', 'mock_telegram', 'docs', 'a.pdf') 'nichts'
Assert-Binary 'PDF mit Treffer' $true @('tests', 'mock_telegram', 'docs', 'a.pdf') 'Zauberwort'
Assert-Binary 'Excel ohne Treffer' $false @('tests', 'mock_telegram', 'docs', 'a.xlsx') 'nichts'
Assert-Binary 'Excel mit Treffer' $true @('tests', 'mock_telegram', 'docs', 'a.xlsx') 'Zauberwort'

# (10) -Outgoing prueft den Branch-Namen
$r = New-TestRepo
Write-Utf8 (Join-Path $r '.env') $RealEnv
Write-Utf8 (Join-Path $r '.local\privacy_denylist.txt') "Zauberwort`n"
$bare = "$r-wt"
Invoke-TestGit $r @('init', '-q', '--bare', $bare)
Invoke-TestGit $r @('remote', 'add', 'origin', $bare)
Assert-Lint '-Outgoing: harmloser Branch' $false (Invoke-TestLint $r @{} @('-Outgoing'))
Assert-Lint '-Outgoing: Zielname des Pushs' $true (Invoke-TestLint $r @{ PRE_COMMIT_REMOTE_BRANCH = 'feat/zauberwort-fix' } @('-Outgoing'))
Invoke-TestGit $r @('checkout', '-q', '-b', 'feat/zauberwort-fix')
Assert-Lint '-Outgoing: aktueller Branch' $true (Invoke-TestLint $r @{} @('-Outgoing'))
Remove-TestRepo $r

Write-Host 'privacy_lint_test: Pruefsummen-Reparatur'
# (11) Die Reparatur in core.schema_version_init.sql nennt die tatsaechliche Summe der Migrationsdatei (ein Tippfehler braeche das Update)
$md5 = [System.Security.Cryptography.MD5]::Create()
$migration = Join-Path $PSScriptRoot '..\..\packages\finance\db\migrations\V019__takeover_unit_price.sql'
$actual = -join ($md5.ComputeHash([System.IO.File]::ReadAllBytes($migration)) | ForEach-Object { $_.ToString('x2') })
$initText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\packages\core\db\core.schema_version_init.sql'), $u8)
$expected = [regex]::Match($initText, "SET checksum = '([0-9a-f]{32})'\s+WHERE version = 'finance:V019'").Groups[1].Value
if ($expected -ceq $actual) { $passed++; Write-Host '  [PASS] Reparatur nennt die Summe der Datei' -ForegroundColor Green }
else { $failed++; Write-Host '  [FAIL] Reparatur nennt nicht die Summe der Datei' -ForegroundColor Red }

Write-Host 'privacy_lint_test: owner_fact_lint'
# (8) Saetze ueber den Betreiber nur in Prompt-Dateien, Marken und Betraege ueberall; generierte und V__-Dateien bleiben aussen vor
$OwnerLint = Join-Path $PSScriptRoot '..\owner_fact_lint.ps1'
function Assert-OwnerFact([string]$Name, [bool]$ExpectFail, [string[]]$RelParts, [string]$Text) {
    $r = New-TestRepo
    Copy-Item $OwnerLint (Join-Path $r 'scripts\')
    Write-Utf8 (Join-Path $r ($RelParts -join '\')) "$Text`n"
    Invoke-TestGit $r @('add', '-A')
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $r 'scripts\owner_fact_lint.ps1') *> $null; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    Assert-Lint $Name $ExpectFail $code
    Remove-TestRepo $r
}
$sentence = 'The owner' + ' dislikes meetings.'
$marker = 'Owner-' + 'Befund 2026-01-01: ein Fall'
Assert-OwnerFact 'Prompt: Satz ueber den Betreiber' $true @('packages', 'x', 'contexts', 'a.md') $sentence
Assert-OwnerFact 'Doku: derselbe Satz ist kein Prompt' $false @('docs', 'a.md') $sentence
Assert-OwnerFact 'Marke in einem Testfall' $true @('tests', 'a.json') $marker
Assert-OwnerFact 'Fachbegriff bleibt erlaubt' $false @('tests', 'a.sql') ('-- ' + 'Owner-' + 'Fallback greift')
Assert-OwnerFact 'Live-Befund mit Betrag' $true @('tests', 'b.sql') ('-- Live-' + 'Befund: -1.23 geht raus')
Assert-OwnerFact 'Live-Befund ohne Betrag' $false @('tests', 'c.sql') ('-- Live-' + 'Befund 2026-01-01, n8n 2.44.4')
Assert-OwnerFact 'Live-Befund, Betrag im Kommentar darunter' $true @('packages', 'x', 'db', 'd.sql') ("-- Live-" + "Befund 2026-01-01: ein Fall`n-- blaehte die Summe um 123 auf")
Assert-OwnerFact 'Live-Befund, Betrag im Kommentar mit Doppelpunkt darunter' $true @('tests', 'g.sql') ("-- Live-" + "Befund 2026-01-01`n-- Stand:12: 1,23 fehlen")
Assert-OwnerFact 'Live-Befund, Datum im Kommentar darunter' $false @('tests', 'e.sql') ("-- Live-" + "Befund 2026-01-01`n-- erste Periode 24.10.-31.12., dann 31.12.-31.03.")
Assert-OwnerFact 'Live-Befund, Betrag darunter ist kein Kommentar' $false @('tests', 'f.sql') ("-- Live-" + "Befund 2026-01-01`nSELECT 1,23;")
Assert-OwnerFact 'V-Migration ist ausgenommen' $false @('packages', 'x', 'db', 'migrations', 'V001__a.sql') $marker
Assert-OwnerFact 'generierte Datei ist ausgenommen' $false @('packages', 'x', 'workflows', 'a.json') $marker
Assert-OwnerFact 'Quelle unter build/workflows: Marke zaehlt' $true @('packages', 'x', 'build', 'workflows', 'a.ps1') $marker
Assert-OwnerFact 'Quelle unter build/workflows: Satz ueber den Betreiber zaehlt' $true @('packages', 'x', 'build', 'workflows', 'tools', 'b.ps1') $sentence

Write-Host ''
Write-Host "privacy_lint_test: $passed bestanden, $failed fehlgeschlagen."
exit $failed
