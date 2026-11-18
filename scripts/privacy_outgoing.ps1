#Requires -Version 5.1
# privacy_outgoing.ps1 -- was ein Push oeffentlich machen wuerde, als Text und als Hash. Grundlage der Modell-Pruefung vor jedem Push
# (Skill /privacy-review, Stempel scripts/privacy_review_stamp.ps1, Sperre .claude/hooks/dev_cycle_guard.ps1 und prek pre-push).
# Ausgehend ist jeder Commit, den das Remote noch nicht kennt, einzeln mit Text, Identitaeten und Aenderung: Der Gesamtunterschied
# wuerde einen Wert verbergen, den ein Commit einfuegt und der naechste wieder loescht, und der waere trotzdem oeffentlich.
# Dazu ein neuer Branch-Name und neue Tags (mit Text), soweit dieser Push sie mitnimmt.
# Der Hash deckt alles ab, auch generierte Dateien; jede Aenderung am Ausgehenden macht einen Stempel ungueltig, ausser das Ausgehende
# schrumpft auf schon Geprueftes (Deckung, unten bei Test-StampCovers).
# Kein LLM, kein Substrat; fragt das Remote (git ls-remote). Ausgaben nennen nie einen Inhalt.
# Usage:
#   .\scripts\privacy_outgoing.ps1 [-Ref <ref>] [-Remote <name>] [-DestRef <zielname>] [-AllTags]   gibt den Hash aus, nichts ausgehend = keine Ausgabe
#   ... -OutFile <datei>   schreibt zusaetzlich den Text fuer die Pruefung, ohne generierte Dateien (ihre Quellen sind im Text)
#   ... -Check             prueft den Stempel; Exit 0 = frei, 1 = Stempel fehlt, 2 = nicht pruefbar
#   ... -Manifest          statt des Hashs eine JSON-Zeile {hash, commits, header} fuer den Stempel (scripts/privacy_review_stamp.ps1)
# Ohne -Ref/-Remote/-DestRef gelten PRE_COMMIT_TO_REF, PRE_COMMIT_REMOTE_NAME, PRE_COMMIT_REMOTE_BRANCH (von prek), sonst HEAD und origin.
# -Check gilt nur auf der Owner-Maschine (Liste oder echte Chat-ID im Haupt-Checkout): Beitraege von aussen brauchen keinen Stempel.
param(
    [string]$Ref,
    [string]$Remote,
    [string]$DestRef,
    [switch]$AllTags,
    [string]$OutFile,
    [switch]$Check,
    [switch]$Manifest
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $PSScriptRoot 'lib\owner_machine.ps1')
$MainRoot = Get-MainCheckoutRoot $RepoRoot
$u8 = New-Object System.Text.UTF8Encoding($false)

function Stop-Outgoing([string]$Message) { Write-Host "  [FAIL] $Message" -ForegroundColor Red; exit 2 }
function Invoke-Git([string[]]$GitArgs) {
    $out = & git -C $RepoRoot $GitArgs
    if ($LASTEXITCODE -ne 0) { Stop-Outgoing "git fehlgeschlagen (Exit $LASTEXITCODE): git $($GitArgs -join ' ')" }
    @($out)
}
if ($Check -and -not (Test-OwnerMachine $MainRoot)) {
    Write-Host '  [skip] keine Owner-Maschine -> kein Pruefstempel noetig' -ForegroundColor DarkGray
    exit 0
}

if (-not $Ref) { $Ref = if ($env:PRE_COMMIT_TO_REF) { $env:PRE_COMMIT_TO_REF } else { 'HEAD' } }
if (-not $Remote) { $Remote = if ($env:PRE_COMMIT_REMOTE_NAME) { $env:PRE_COMMIT_REMOTE_NAME } else { 'origin' } }
if (-not $DestRef) { $DestRef = if ($env:PRE_COMMIT_REMOTE_BRANCH) { $env:PRE_COMMIT_REMOTE_BRANCH } else { $Ref } }
$tip = [string](& git -C $RepoRoot rev-parse --verify -q "$Ref^{commit}")
if (-not $tip) { Stop-Outgoing "Stand '$Ref' nicht aufloesbar." }

# Zielname: Branch oder Tag. HEAD steht fuer den aktuellen Branch.
$dest = $DestRef -replace '^refs/heads/', ''
$tagName = $null
if ($dest -match '^refs/tags/(.+)$') { $tagName = $Matches[1]; $dest = $null }
elseif ($dest -eq 'HEAD') { $dest = [string](& git -C $RepoRoot symbolic-ref --short -q HEAD) }
else {
    $isTag = [bool](& git -C $RepoRoot rev-parse --verify -q "refs/tags/$dest")
    $isBranch = [bool](& git -C $RepoRoot rev-parse --verify -q "refs/heads/$dest")
    if ($isTag -and -not $isBranch) { $tagName = $dest; $dest = $null }
}

$remoteRefs = @(Invoke-Git @('ls-remote', '--refs', $Remote) | ForEach-Object { ($_ -split "`t")[-1] })
$header = @()
if ($dest -and $remoteRefs -notcontains "refs/heads/$dest") { $header += "Branch-Name: $dest" }
$wanted = @($tagName) + $(if ($AllTags) { Invoke-Git @('tag') } else { @() })
$newTags = @($wanted | Where-Object { $_ } | Sort-Object -Unique | Where-Object { $remoteRefs -notcontains "refs/tags/$_" })
$revs = @($tip)
foreach ($t in $newTags) {
    $header += "Tag-Name: $t"
    $type = (Invoke-Git @('for-each-ref', "refs/tags/$t", '--format=%(objecttype)')) -join ''
    if ($type) { $revs += "refs/tags/$t" }
    if ($type -eq 'tag') { $header += Invoke-Git @('for-each-ref', "refs/tags/$t", '--format=%(taggername) %(taggeremail)%0a%(contents)') }
}
$revs += @('--not', "--remotes=$Remote")

# Feste Optionen, damit der Hash nicht von lokalen Einstellungen abhaengt. --cc zeigt von Merges nur, was keine Seite enthielt.
$logBase = @('-c', 'core.quotepath=off', '-c', 'log.showSignature=false', 'log', '--topo-order', '--no-color', '--no-notes',
    '--format=commit %H%nAutor: %an <%ae>%nCommitter: %cn <%ce>%n%n%B')
$patch = @('--cc', '--full-index', '--no-renames', '--no-ext-diff', '--no-textconv', '--diff-algorithm=myers', '--unified=3', '--src-prefix=a/', '--dst-prefix=b/')
# Rohe Bytes von git: PowerShell wuerde Ausgabe als Text umkodieren, und --cc erlaubt kein --output.
function Get-GitBytes([string[]]$GitArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = (@('-C', $RepoRoot) + $GitArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { Stop-Outgoing "git log fehlgeschlagen (Exit $($p.ExitCode))" }
    , $ms.ToArray()
}
function Join-Bytes([object[]]$Parts) {
    $ms = New-Object System.IO.MemoryStream
    foreach ($part in $Parts) { $ms.Write([byte[]]$part, 0, ([byte[]]$part).Length) }
    , $ms.ToArray()
}
$headerBytes = $u8.GetBytes(($header -join "`n") + $(if ($header) { "`n" } else { '' }))
$fullBytes = Get-GitBytes ($logBase + $patch + $revs)
if ($headerBytes.Length -eq 0 -and $fullBytes.Length -eq 0) {
    if ($Check) { Write-Host '  nichts Neues ausgehend -> kein Pruefstempel noetig' -ForegroundColor DarkGray }
    exit 0
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$hash = -join ($sha.ComputeHash((Join-Bytes @($headerBytes, $fullBytes))) | ForEach-Object { $_.ToString('x2') })

# Deckung: Ein Commit-Hash legt Text, Identitaeten und Aenderung fest (bei Merges auch --cc, die Eltern stecken im Hash). Ein Stempel
# deckt darum auch einen spaeteren Push, dessen Commits und Kopfzeilen eine Teilmenge der gestempelten sind: Das Remote kennt
# inzwischen einen Teil (Sammel-Branch gepusht), der Hash ist anders, Neues ist nicht dazugekommen. Kopfzeilen (Branch-/Tag-Name,
# Tag-Text) stehen nur als Hash im Stempel. Test: scripts/dev/privacy_review_hook_test.ps1 (Abschnitt "Remote kennt einen Teil schon").
$commits = @(Invoke-Git (@('rev-list') + $revs) | Where-Object { $_ })
$headerHashes = @($header | ForEach-Object { -join ($sha.ComputeHash($u8.GetBytes([string]$_)) | ForEach-Object { $_.ToString('x2') }) })
function Test-StampCovers([string]$StampFile) {
    try { $s = [System.IO.File]::ReadAllText($StampFile, $u8) | ConvertFrom-Json } catch { return $false }
    if (-not $s.PSObject.Properties['commits'] -or -not $s.PSObject.Properties['header']) { return $false }
    $known = @{}; foreach ($c in @($s.commits)) { $known[[string]$c] = $true }
    $knownHeader = @{}; foreach ($h in @($s.header)) { $knownHeader[[string]$h] = $true }
    foreach ($c in $commits) { if (-not $known.ContainsKey($c)) { return $false } }
    foreach ($h in $headerHashes) { if (-not $knownHeader.ContainsKey($h)) { return $false } }
    return $true
}

if ($OutFile) {
    # glob: ohne dieses Merkmal passt * auch ueber / und nimmt die Quellen unter packages/*/build/workflows/ mit heraus
    $generated = @('--', '.', ':(exclude,glob)packages/*/workflows/**', ':(exclude)docs/site/public/*', ':(exclude)docs/fn_catalog.md')
    $patchBytes = Get-GitBytes ($logBase + $patch + $revs + $generated)
    $textBytes = Get-GitBytes ($logBase + $revs)
    $title1 = $u8.GetBytes("=== Namen und alle Commit-Texte ===`n")
    $title2 = $u8.GetBytes("`n=== Aenderungen je Commit, ohne generierte Dateien ===`n")
    [System.IO.File]::WriteAllBytes($OutFile, (Join-Bytes @($title1, $headerBytes, $textBytes, $title2, $patchBytes)))
    Write-Host "  Text fuer die Pruefung: $([math]::Round((Get-Item -LiteralPath $OutFile).Length / 1KB)) KB" -ForegroundColor DarkGray
}

if ($Check) {
    $stampDir = Join-Path $MainRoot '.local\privacy_review_stamps'
    if (Test-Path (Join-Path $stampDir "$hash.json")) { Write-Host '  Pruefstempel vorhanden' -ForegroundColor DarkGray; exit 0 }
    foreach ($f in @(Get-ChildItem -LiteralPath $stampDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if (Test-StampCovers $f.FullName) { Write-Host '  Pruefstempel deckt diesen Push (nur schon gepruefte Commits)' -ForegroundColor DarkGray; exit 0 }
    }
    $flags = "-Ref $Ref -Remote $Remote -DestRef $DestRef" + $(if ($AllTags) { ' -AllTags' } else { '' })
    Write-Host "  [FAIL] Kein Pruefstempel fuer genau diesen Push. Skill /privacy-review, Aufruf des Stempels: privacy_review_stamp.ps1 $flags" -ForegroundColor Red
    exit 1
}
if ($Manifest) { Write-Output (@{ hash = $hash; commits = $commits; header = $headerHashes } | ConvertTo-Json -Compress); exit 0 }
Write-Output $hash
exit 0
