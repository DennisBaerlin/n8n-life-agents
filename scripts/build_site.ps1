# build_site.ps1 — Treiber der Showcase-Site (docs/site): Hugo-Build + -Verify-Regenerat-Diff.
#
# Muster build.ps1/gen_fn_catalog: Quelle (docs/site/{content,layouts,static,data,hugo.toml})
# -> externes Standard-Binary (Hugo, arch-challenge R2/R3: KEIN Eigenbau-Renderer) -> getrackter
# Output docs/site/public/ (NIE hand-editieren; Eingeladene brauchen kein Binary, nur den Output).
#
#   .\scripts\build_site.ps1            # baut docs/site/public/ neu (cleanDestinationDir)
#   .\scripts\build_site.ps1 -Verify    # pre-push-Gate: frischer Build in Temp == public/ (byte-genau)
#
# Binary-Aufloesung: $env:HUGO_EXE -> <repo>\.local\bin\hugo.exe -> (Worktree) <haupt-checkout>\.local\bin\hugo.exe -> PATH. Die Version ist HART auf
# $PinnedHugoVersion assertiert (Doku-Pin waere Ehrensache: abweichende Versionen aendern den Output
# und machen das Regenerat-Diff nicht-deterministisch; Generator-Meta ist via hugo.toml
# disableHugoGeneratorInject abgeschaltet). Install -> CONTRIBUTING.md "The enforcement gates".
[CmdletBinding()]
param(
    [switch]$Verify
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PinnedHugoVersion = '0.168.0'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SiteDir  = Join-Path $RepoRoot 'docs\site'
$PublicDir = Join-Path $SiteDir 'public'

function Resolve-HugoExe {
    if ($env:HUGO_EXE -and (Test-Path $env:HUGO_EXE)) { return $env:HUGO_EXE }
    $localExe = Join-Path $RepoRoot '.local\bin\hugo.exe'
    if (Test-Path $localExe) { return $localExe }
    # Git-Worktree (.claude/worktrees/*): .local/ ist gitignored und fehlt dort -> die Binary des Haupt-Checkouts
    # nutzen (git-common-dir = <haupt>\.git), statt sie in jeden Worktree zu kopieren.
    $commonDir = git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($commonDir) {
        $mainExe = Join-Path (Split-Path -Parent $commonDir) '.local\bin\hugo.exe'
        if (Test-Path $mainExe) { return $mainExe }
    }
    $cmd = Get-Command hugo -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw ("hugo.exe nicht gefunden. Installation (gepinnt v{0}): Release-ZIP 'hugo_{0}_windows-amd64.zip' von github.com/gohugoio/hugo nach .local\bin\ entpacken ODER `$env:HUGO_EXE setzen (CONTRIBUTING.md)." -f $PinnedHugoVersion)
}

function Test-HugoVersion([string]$exe) {
    $verLine = (& $exe version) -join ' '
    if ($verLine -notmatch 'hugo v([0-9]+\.[0-9]+\.[0-9]+)') {
        throw "Unerwartete 'hugo version'-Ausgabe: $verLine"
    }
    $found = $Matches[1]
    if ($found -ne $PinnedHugoVersion) {
        throw "Hugo-Version $found != Pin $PinnedHugoVersion — abweichende Versionen aendern den Output (Regenerat-Diff). Gepinnte Version installieren oder Pin hier + CONTRIBUTING bewusst anheben."
    }
}

function Invoke-HugoBuild([string]$exe, [string]$destination) {
    & $exe --source $SiteDir --destination $destination --cleanDestinationDir --quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Hugo-Build fehlgeschlagen (Exit $LASTEXITCODE)." }
}

# Relativer Pfad -> SHA256 fuer jeden File eines Baums (Vergleichsbasis des Regenerat-Diffs).
function Get-TreeHashes([string]$root) {
    $map = @{}
    Get-ChildItem -Path $root -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
        $map[$rel] = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
    }
    return $map
}

$hugoExe = Resolve-HugoExe
Test-HugoVersion $hugoExe

if (-not $Verify) {
    Invoke-HugoBuild $hugoExe $PublicDir
    $count = (Get-ChildItem -Path $PublicDir -Recurse -File | Measure-Object).Count
    Write-Output "build_site: OK — $count Dateien nach docs/site/public/ gebaut (Hugo v$PinnedHugoVersion)."
    exit 0
}

# -Verify: frischer Build in ein Temp-Ziel, byte-genauer Vergleich gegen den getrackten Output.
if (-not (Test-Path $PublicDir)) { Write-Output 'build_site -Verify: FAIL — docs/site/public/ fehlt (erst bauen).'; exit 1 }
$tmpDest = Join-Path ([System.IO.Path]::GetTempPath()) ("site_verify_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    Invoke-HugoBuild $hugoExe $tmpDest
    $tracked = Get-TreeHashes $PublicDir
    $fresh   = Get-TreeHashes $tmpDest
    $drift = @()
    foreach ($rel in $fresh.Keys)   { if (-not $tracked.ContainsKey($rel)) { $drift += "NUR im Regenerat: $rel" } elseif ($tracked[$rel] -ne $fresh[$rel]) { $drift += "INHALT abweichend: $rel" } }
    foreach ($rel in $tracked.Keys) { if (-not $fresh.ContainsKey($rel))   { $drift += "NUR in public/ (stale): $rel" } }
    if ($drift.Count -gt 0) {
        Write-Output "build_site -Verify: FAIL — public/ weicht vom frischen Build ab ($($drift.Count) Datei(en)). Fix: .\scripts\build_site.ps1 ausfuehren und committen."
        $drift | Select-Object -First 20 | ForEach-Object { Write-Output "  $_" }
        exit 1
    }
    Write-Output "build_site -Verify: OK — public/ == frischer Build ($($tracked.Count) Dateien byte-identisch)."
    exit 0
}
finally {
    if (Test-Path $tmpDest) { Remove-Item -Recurse -Force $tmpDest }
}
