#Requires -Version 5.1
# sign_release.ps1 — nach jedem Release im Terminal des Owners: den Release-ENTWURF pruefen, unterschreiben und
# veroeffentlichen (Update im Chat, Phase 2; Schluessel aus scripts/new_release_key.ps1).
#
# Warum lokal und nicht in der CI: ein Signierschluessel als Actions-Secret schuetzte nicht gegen ein gekapertes
# GitHub-Konto (wer das Konto hat, laesst die CI signieren). Darum unterschreibt der Owner selbst — aber nie blind:
#   1. Entwurfs-Assets laden (Tarball, install.sh, SHA256SUMS) und SHA256SUMS gegen die Dateien pruefen.
#   2. Den Inhalt mit dem LOKALEN Tag vergleichen: der entpackte Tar-Strom muss byte-gleich mit `git archive` des Tags
#      sein (gzip-Bytes duerfen je git-Version abweichen, der Tar-Strom nicht); sonst Datei fuer Datei per Blob-Hash.
#      install.sh muss genau provisioning/install.sh des Tags sein.
#   3. SHA256SUMS mit dem privaten Schluessel unterschreiben (detached, SHA256SUMS.sig) und gegen das Schluesselbund im
#      Repo gegenpruefen.
#   4. SHA256SUMS.sig hochladen, den Entwurf veroeffentlichen. Erst jetzt zeigt /releases/latest auf das Release.
#
# Braucht: gpg (Git for Windows), gh (winget GitHub.cli), git; GH_TOKEN wird bei Bedarf aus dem Git-Credential-Manager
#   geholt (nur fuer diesen Prozess). Usage: .\scripts\sign_release.ps1 v0.14.0
param([Parameter(Mandatory = $true)][string]$Tag)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)   # stdin an gpg (Passwort) als UTF-8, nicht ASCII (PS 5.1)
$RepoRoot = Split-Path -Parent $PSScriptRoot

if ($Tag -notmatch '^v\d+\.\d+\.\d+$') { throw "Ungueltiges Tag '$Tag' (erwartet z. B. v0.14.0)." }
$keyFile = Join-Path $RepoRoot 'provisioning\keys\release-signing.gpg'
if (-not (Test-Path $keyFile)) { throw 'Noch kein Release-Schluessel im Repo — zuerst .\scripts\new_release_key.ps1.' }

function Get-GpgExe {
    $c = Get-Command gpg -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\Git\usr\bin\gpg.exe", "${env:ProgramFiles(x86)}\Git\usr\bin\gpg.exe")) {
        if (Test-Path $p) { return $p }
    }
    throw 'gpg nicht gefunden — Git for Windows bringt es mit (usr\bin\gpg.exe).'
}
function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Invoke-Git { & git -C $RepoRoot @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') fehlgeschlagen." } }

$gpg = Get-GpgExe
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh (GitHub CLI) fehlt: winget install GitHub.cli' }
if (-not $env:GH_TOKEN) {
    $cred = "protocol=https`nhost=github.com`n`n" | git credential fill 2>$null
    $tok = ($cred | Where-Object { $_ -like 'password=*' } | Select-Object -First 1)
    if ($tok) { $env:GH_TOKEN = $tok.Substring(9) } else { throw 'Kein GitHub-Zugang (GH_TOKEN oder Git-Credential-Manager) gefunden.' }
}
$remote = (& git -C $RepoRoot remote get-url origin).Trim()
if ($remote -notmatch 'github\.com[:/](?<slug>[^/]+/[^/.]+?)(\.git)?$') { throw "origin ist kein GitHub-Repo: $remote" }
$slug = $Matches['slug']

# Fingerabdruck des Repo-Schluessels + privater Teil vorhanden?
$fpr = ((& $gpg --batch --with-colons --show-keys $keyFile) | Where-Object { $_ -like 'fpr:*' } | Select-Object -First 1).Split(':')[9]
& $gpg --batch --list-secret-keys $fpr *> $null
if ($LASTEXITCODE -ne 0) { throw "Der private Schluessel $fpr fehlt in diesem gpg-Speicher (anderer PC? Sicherung importieren: gpg --import <datei>)." }

Write-Host "Release $Tag ($slug) pruefen ..." -ForegroundColor Cyan
Invoke-Git fetch --quiet --tags origin
Invoke-Git rev-parse --verify --quiet "$Tag^{commit}" | Out-Null

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("sign_release_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
try {
    $tarball = "n8n-life-agents-$Tag.tar.gz"
    & gh release download $Tag -R $slug -D $work -p $tarball -p install.sh -p SHA256SUMS
    if ($LASTEXITCODE -ne 0) { throw "Assets von $Tag nicht ladbar (Entwurf vorhanden? CI fertig?)." }
    $isDraft = (& gh release view $Tag -R $slug --json isDraft --jq '.isDraft').Trim()
    if ($isDraft -ne 'true') { Write-Host "  Hinweis: $Tag ist schon veroeffentlicht — es wird nur die Unterschrift ergaenzt." -ForegroundColor Yellow }

    # 1) SHA256SUMS passt zu den Dateien (genau diese zwei Zeilen)
    $sums = [System.IO.File]::ReadAllLines((Join-Path $work 'SHA256SUMS'))
    $expect = @("$(Get-Sha256 (Join-Path $work $tarball))  $tarball", "$(Get-Sha256 (Join-Path $work 'install.sh'))  install.sh")
    if ((Compare-Object $sums $expect -SyncWindow 0)) { throw "SHA256SUMS passt nicht zu den geladenen Dateien:`n$($sums -join "`n")" }

    # 2a) install.sh = provisioning/install.sh des Tags (Blob-Hash ohne Zeilenende-Filter)
    $blobWant = (& git -C $RepoRoot rev-parse "${Tag}:provisioning/install.sh").Trim()
    $blobHave = (& git -C $RepoRoot hash-object --no-filters (Join-Path $work 'install.sh')).Trim()
    if ($blobWant -ne $blobHave) { throw 'install.sh im Release weicht von provisioning/install.sh des Tags ab — NICHT unterschreiben.' }

    # 2b) Tarball-Inhalt = git archive des Tags (gleiche Pathspec + Prefix wie .github/workflows/release.yml)
    $localTar = Join-Path $work 'local.tar'
    Invoke-Git archive --format=tar "--prefix=n8n-life-agents-$Tag/" -o $localTar $Tag provisioning packages .gitattributes
    $ciTar = Join-Path $work 'ci.tar'
    $in = [System.IO.File]::OpenRead((Join-Path $work $tarball))
    try {
        $gz = [System.IO.Compression.GZipStream]::new($in, [System.IO.Compression.CompressionMode]::Decompress)
        $out = [System.IO.File]::Create($ciTar)
        try { $gz.CopyTo($out) } finally { $out.Dispose(); $gz.Dispose() }
    } finally { $in.Dispose() }
    if ((Get-Sha256 $localTar) -ne (Get-Sha256 $ciTar)) {
        # Rueckfall: Datei fuer Datei per Blob-Hash (andere git-Version schreibt evtl. andere Tar-Header)
        $ex = Join-Path $work 'x'; New-Item -ItemType Directory $ex | Out-Null
        & tar -xf $ciTar -C $ex
        if ($LASTEXITCODE -ne 0) { throw 'CI-Tarball nicht entpackbar.' }
        $root = Join-Path $ex "n8n-life-agents-$Tag"
        $want = @{}
        foreach ($l in (& git -C $RepoRoot ls-tree -r $Tag -- provisioning packages .gitattributes)) {
            $parts = $l -split "`t", 2; $want[$parts[1]] = ($parts[0] -split ' ')[2]
        }
        $have = @{}
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File)) {
            $rel = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
            $have[$rel] = (& git -C $RepoRoot hash-object --no-filters $f.FullName).Trim()
        }
        $diff = @($want.Keys | Where-Object { $have[$_] -ne $want[$_] }) + @($have.Keys | Where-Object { -not $want.ContainsKey($_) })
        if ($diff.Count -gt 0) { throw "Der Release-Inhalt weicht vom lokalen Tag ab (z. B. $($diff | Select-Object -First 5)) — NICHT unterschreiben." }
        Write-Host '  Inhalt geprueft (Datei fuer Datei; die Tar-Header weichen nur formal ab).' -ForegroundColor DarkGray
    } else {
        Write-Host '  Inhalt geprueft (byte-gleich mit git archive des Tags).' -ForegroundColor DarkGray
    }

    # 3) unterschreiben + gegenpruefen
    $sec = Read-Host -AsSecureString "Passwort des Signierschluessels ($fpr)"
    $pass = [System.Net.NetworkCredential]::new('', $sec).Password
    $sig = Join-Path $work 'SHA256SUMS.sig'
    $pass | & $gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --local-user $fpr --detach-sign --output $sig (Join-Path $work 'SHA256SUMS')
    $pass = $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $sig)) { throw 'Unterschreiben fehlgeschlagen (falsches Passwort?).' }
    & $gpg --batch --no-default-keyring --keyring $keyFile --verify $sig (Join-Path $work 'SHA256SUMS') *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Die neue Unterschrift passt nicht zum Schluesselbund im Repo — nicht hochgeladen.' }

    # 4) hochladen + veroeffentlichen
    & gh release upload $Tag -R $slug $sig --clobber
    if ($LASTEXITCODE -ne 0) { throw 'Upload von SHA256SUMS.sig fehlgeschlagen.' }
    if ($isDraft -eq 'true') {
        & gh release edit $Tag -R $slug --draft=false --latest
        if ($LASTEXITCODE -ne 0) { throw 'Veroeffentlichen fehlgeschlagen (Unterschrift ist hochgeladen; erneut: gh release edit --draft=false).' }
    }
    Write-Host "Fertig: $Tag ist unterschrieben und veroeffentlicht. Installationen sehen das Update beim naechsten Check." -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
