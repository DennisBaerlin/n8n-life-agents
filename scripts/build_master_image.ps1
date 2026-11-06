#Requires -Version 5.1
# build_master_image.ps1 — das master-Image des Docker-Verbunds fuer linux/amd64 + linux/arm64 bauen, ins Register legen und
# seinen Digest als Release-Pin in provisioning/compose/compose.yml eintragen. Release-Ablauf (docs/reference/provisioning.md
# *Docker-Verbund*): bauen + pushen -> Pin-Commit -> Tag -> CI -> sign_release.ps1 prueft den Pin im Register.
#
# Bau-Kontext = der Release-Baum von HEAD (git archive, Pathspec aus scripts/lib/release_images.ps1), aber mit der NEUTRALEN
# Pin-Zeile (Begruendung im Kopf der Bibliothek). Label org.opencontainers.image.revision = HEAD; darum muss der Release-Baum
# sauber committet sein. SOURCE_DATE_EPOCH = Commit-Zeit, Basis-Images per Digest; bit-gleich ist ein Neubau trotzdem nicht
# (apt laedt die jeweils aktuellen Debian-Pakete). Mehrplattform-Bau ueber den Docker-eigenen Builder (Docker Desktop mit
# containerd-Speicher; arm64 per Emulation) — kein eigener Builder-Container. Ohne Nachweis-Eintraege (--provenance/--sbom
# false): der Index enthaelt genau die zwei Plattformen.
#
# Usage:
#   .\scripts\build_master_image.ps1 -Version v0.37.0                     # Owner: nach ghcr.io/<owner>/<repo>/master, Pin eintragen
#   .\scripts\build_master_image.ps1 -Version v0.37.0 -Registry 127.0.0.1:5099/di5 -NoPin   # Test gegen ein lokales Register
#   .\scripts\build_master_image.ps1 -Version v0.37.0 -NoPush             # nur bauen (lokaler Bild-Speicher), nichts veroeffentlichen
# Push nach ghcr.io braucht vorher `docker login ghcr.io` (Token mit write:packages) und ist eine Veroeffentlichung; das Paket
# muss danach oeffentlich sein (GitHub > Packages > master > Package settings > Change visibility), sonst scheitert die Pruefung.
# Exit 0 = gebaut (und ggf. gepusht + geprueft + Pin eingetragen); jeder Fehler bricht mit Meldung ab.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Registry,
    [string]$Name = 'master',
    [switch]$NoPush,
    [switch]$NoPin,
    [switch]$AllowDirty
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\release_images.ps1')

if ($Version -notmatch '^v\d+\.\d+\.\d+([-.][0-9A-Za-z.]+)?$') { throw "Ungueltige Version '$Version' (z. B. v0.37.0)." }
function Invoke-Git { $o = & git -C $RepoRoot @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') fehlgeschlagen." }; return $o }

$remote = (Invoke-Git remote get-url origin | Select-Object -First 1).Trim()
if ($remote -notmatch 'github\.com[:/](?<slug>[^/]+/[^/.]+?)(\.git)?$') { throw "origin ist kein GitHub-Repo: $remote" }
$slug = $Matches['slug']
if (-not $Registry) { $Registry = "ghcr.io/$($slug.ToLowerInvariant())" }
$ref = "$($Registry.TrimEnd('/'))/$Name"
if ($ref -cne $ref.ToLowerInvariant()) { throw "Image-Name '$ref' muss klein geschrieben sein (Register-Regel)." }

$dirty = @(Invoke-Git status --porcelain -- @ReleasePathspec | Where-Object { $_ })
if ($dirty.Count -and -not $AllowDirty) { throw "Release-Baum nicht committet ($($dirty.Count) Aenderungen, z. B. $($dirty[0])) — das Label revision waere falsch." }
$rev = (Invoke-Git rev-parse HEAD | Select-Object -First 1).Trim()
$epoch = (Invoke-Git log -1 --format=%ct HEAD | Select-Object -First 1).Trim()

$work = Join-Path ([System.IO.Path]::GetTempPath()) ('master_image_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
$prevIndex = $env:GIT_INDEX_FILE
try {
    # Release-Baum mit neutraler Pin-Zeile als eigener Baum (temporaerer Index; das Arbeitsverzeichnis bleibt unberuehrt).
    $composeHead = (Invoke-Git show "HEAD:$MasterComposeRel") -join "`n"
    $neutralFile = Join-Path $work 'compose.yml'
    [System.IO.File]::WriteAllText($neutralFile, (Set-MasterPin $composeHead) + "`n", $Utf8NoBom)
    $blob = (Invoke-Git hash-object -w --no-filters $neutralFile | Select-Object -First 1).Trim()
    $env:GIT_INDEX_FILE = Join-Path $work 'index'
    Invoke-Git read-tree HEAD | Out-Null
    Invoke-Git update-index --cacheinfo "100644,$blob,$MasterComposeRel" | Out-Null
    $tree = (Invoke-Git write-tree | Select-Object -First 1).Trim()
    $env:GIT_INDEX_FILE = $prevIndex
    $ctx = Join-Path $work 'context.tar'
    Invoke-Git archive --format=tar "--mtime=@$epoch" -o $ctx $tree @ReleasePathspec | Out-Null
    Write-Host "Bau-Kontext: Baum $($tree.Substring(0, 12)) (HEAD $($rev.Substring(0, 12)), Pin-Zeile neutral)" -ForegroundColor DarkGray

    $meta = Join-Path $work 'meta.json'
    $plat = $MasterPlatforms -join ','
    $args2 = @('buildx', 'build', '--platform', $plat, '-f', 'provisioning/compose/master.Dockerfile',
        '--provenance=false', '--sbom=false', '--build-arg', "SOURCE_DATE_EPOCH=$epoch",
        '--label', "org.opencontainers.image.revision=$rev",
        '--label', "org.opencontainers.image.version=$Version",
        '--label', "org.opencontainers.image.source=https://github.com/$slug",
        '--label', 'org.opencontainers.image.licenses=MIT',
        '--metadata-file', $meta, '-t', "${ref}:$Version")
    $args2 += $(if ($NoPush) { @('--output', 'type=image,rewrite-timestamp=true') } else { @('--output', 'type=image,push=true,rewrite-timestamp=true') })
    $args2 += '-'
    Write-Host "Baue $ref ($plat) ..." -ForegroundColor Cyan
    # Start-Process setzt die Argumente roh zusammen (PS 5.1 quotet nicht) -> selbst quoten.
    $argLine = ($args2 | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $p = Start-Process -FilePath docker -ArgumentList $argLine -RedirectStandardInput $ctx -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "docker buildx build fehlgeschlagen (Exit $($p.ExitCode))." }
    $digest = ([System.IO.File]::ReadAllText($meta, $Utf8NoBom) | ConvertFrom-Json).'containerimage.digest'
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Kein Digest in den Bau-Metadaten ($digest)." }
    Write-Host "Index: $ref@$digest" -ForegroundColor Green
    if ($NoPush) { Write-Host 'Nicht gepusht (-NoPush): kein Pin eingetragen.'; exit 0 }

    $rep = Get-MasterImageReport -Ref $ref -Digest $digest
    if (-not $rep.Ok) { throw "Pruefung im Register gescheitert: $($rep.Problems -join ' | ')" }
    if ($rep.Revision -ne $rev) { throw "Register meldet Revision $($rep.Revision), gebaut wurde $rev." }
    Write-Host ("Im Register geprueft (anonym): {0}, Revision {1}, ~{2} MB je Plattform." -f ($rep.Platforms -join ' + '), $rev.Substring(0, 12), $rep.SizeMb) -ForegroundColor Green

    if ($NoPin) { exit 0 }
    $cf = Join-Path $RepoRoot ($MasterComposeRel -replace '/', '\')
    $txt = [System.IO.File]::ReadAllText($cf, $Utf8NoBom)
    [System.IO.File]::WriteAllText($cf, (Set-MasterPin $txt -Ref $ref -Digest $digest), $Utf8NoBom)
    Write-Host "Pin eingetragen in $MasterComposeRel. Naechster Schritt: committen (nur diese Zeile), dann taggen:" -ForegroundColor Cyan
    Write-Host "  git commit -m `"chore(release): pin master image for $Version`" -- $MasterComposeRel"
} finally {
    $env:GIT_INDEX_FILE = $prevIndex
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
