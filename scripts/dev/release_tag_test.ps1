#Requires -Version 5.1
# release_tag_test.ps1 -- Regressionstest der Vorab-Erkennung beim Release: scripts/lib/release_tag.ps1 (EINE Stelle fuer
# "Vorab ja/nein"), ihr Kommandozeilen-Eingang scripts/release_meta.ps1 (Aufruf in .github/workflows/release.yml) und die
# Verdrahtung in release.yml, scripts/sign_release.ps1 und scripts/build_master_image.ps1. Eigenschaft: ein Vorab-Tag wird nie
# latest, sonst zeigte /releases/latest darauf und jede Installation bekaeme es als Update.
# Kein Netz, kein gh-Aufruf, kein Docker; alle Werte erfunden. prek startet ihn bei Aenderungen.
# Usage:  .\scripts\dev\release_tag_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$PsExe = (Get-Process -Id $PID).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$failed = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "  [OK]   $Name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red }
}
function Throws([scriptblock]$Sb) { try { & $Sb | Out-Null; return $false } catch { return $true } }
function Join-Flags($a) { (@($a) | Where-Object { $_ }) -join ' ' }
# release_meta.ps1 so aufrufen wie release.yml (eigener Prozess, Ausgabe zeilenweise).
function Invoke-Meta([string[]]$ArgList) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & $PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot 'scripts\release_meta.ps1') @ArgList 2>$null; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    [pscustomobject]@{ Code = $code; Lines = @($out | ForEach-Object { "$_" }) }
}

$lib = Join-Path $RepoRoot 'scripts\lib\release_tag.ps1'
Check 'Helfer scripts/lib/release_tag.ps1 vorhanden' (Test-Path $lib)
if (Test-Path $lib) { . $lib }

Write-Host 'A: Art des Tags' -ForegroundColor Cyan
if (Get-Command Get-ReleaseTagKind -ErrorAction SilentlyContinue) {
    foreach ($t in 'v0.51.0', 'v1.0.0', 'v10.20.30') { Check "stabil: $t" ((Get-ReleaseTagKind $t) -eq 'stable') }
    foreach ($t in 'v0.51.0-rc.1', 'v0.51.0-rc1', 'v1.0.0-beta.2', 'v0.51.0-probe-x') { Check "vorab: $t" ((Get-ReleaseTagKind $t) -eq 'prerelease') }
    foreach ($t in "v$([char]0x0661).51.0", '0.51.0', 'v0.51', 'v0.51.0-', 'v0.51.0+build', 'v0.51.0 -rc.1', 'v0.51.0-rc;1', 'dev-abc', '') {
        Check "ungueltig: '$t'" (Throws { Get-ReleaseTagKind $t })
    }
} else { Check 'Get-ReleaseTagKind vorhanden' $false }

Write-Host 'B: gh-Schalter' -ForegroundColor Cyan
if (Get-Command Get-ReleaseCreateFlags -ErrorAction SilentlyContinue) {
    Check 'anlegen stabil: keine Zusatz-Schalter' ((Join-Flags (Get-ReleaseCreateFlags 'v0.51.0')) -eq '')
    Check 'anlegen vorab: --prerelease --latest=false' ((Join-Flags (Get-ReleaseCreateFlags 'v0.51.0-rc.1')) -eq '--prerelease --latest=false')
    Check 'veroeffentlichen stabil: --draft=false --latest' ((Join-Flags (Get-ReleasePublishFlags 'v0.51.0')) -eq '--draft=false --latest')
    Check 'veroeffentlichen vorab: --draft=false --prerelease --latest=false' ((Join-Flags (Get-ReleasePublishFlags 'v0.51.0-rc.1')) -eq '--draft=false --prerelease --latest=false')
    Check 'vorab nie mit --latest (true)' (@(Get-ReleaseCreateFlags 'v0.51.0-rc.1') + @(Get-ReleasePublishFlags 'v0.51.0-rc.1') -notcontains '--latest')
} else { Check 'Get-ReleaseCreateFlags/Get-ReleasePublishFlags vorhanden' $false }

Write-Host 'C: Installations-Hinweis im Release-Text' -ForegroundColor Cyan
if (Get-Command Get-ReleaseInstallNote -ErrorAction SilentlyContinue) {
    $s = Get-ReleaseInstallNote 'beispiel/repo' 'v0.51.0'
    Check 'stabil: setup.sh des Tags' ($s -match [regex]::Escape('curl -fsSL https://github.com/beispiel/repo/releases/download/v0.51.0/setup.sh -o setup.sh && bash setup.sh'))
    Check 'stabil: setup.sh holt curl selbst (frisches Debian hat keins)' ($s -match [regex]::Escape('apt-get update && apt-get install -y curl && curl -fsSL https://github.com/beispiel/repo/releases/download/v0.51.0/setup.sh'))
    Check 'stabil: klassischer Weg holt curl selbst' ($s -match [regex]::Escape('apt-get update && apt-get install -y curl && curl -fsSL https://github.com/beispiel/repo/releases/download/v0.51.0/install.sh'))
    Check 'stabil: Bestand per lifeagents update' ($s -match [regex]::Escape('`lifeagents update`'))
    Check 'stabil: kein Vorab-Satz' ($s -notmatch 'pre-release')
    Check 'stabil: klassischer Weg nur noch fuer Bestand mit --version' ($s -match [regex]::Escape('install.sh --version v0.51.0'))
    $p = Get-ReleaseInstallNote 'beispiel/repo' 'v0.51.0-rc.1'
    Check 'vorab: setup.sh des Tags' ($p -match [regex]::Escape('releases/download/v0.51.0-rc.1/setup.sh -o setup.sh && bash setup.sh'))
    Check 'vorab: Satz pre-release / not offered as an update' ($p -match 'pre-release' -and $p -match 'not offered as an update')
    Check 'vorab: kein Hinweis auf lifeagents update als Weg dorthin' ($p -notmatch [regex]::Escape('`lifeagents update`'))
} else { Check 'Get-ReleaseInstallNote vorhanden' $false }

Write-Host 'D: release_meta.ps1 (Eingang fuer release.yml)' -ForegroundColor Cyan
$r = Invoke-Meta @('-Tag', 'v0.51.0-rc.1', '-What', 'create-flags')
Check 'create-flags vorab' ($r.Code -eq 0 -and ($r.Lines -join ' ') -eq '--prerelease --latest=false') "Exit $($r.Code): $($r.Lines -join ' | ')"
$r = Invoke-Meta @('-Tag', 'v0.51.0', '-What', 'create-flags')
Check 'create-flags stabil: leer' ($r.Code -eq 0 -and (@($r.Lines | Where-Object { $_ }).Count -eq 0)) "Exit $($r.Code): $($r.Lines -join ' | ')"
$r = Invoke-Meta @('-Tag', 'v0.51.0-rc.1', '-What', 'install-note', '-Repo', 'beispiel/repo')
Check 'install-note vorab' ($r.Code -eq 0 -and ($r.Lines -join "`n") -match 'not offered as an update') "Exit $($r.Code)"
$r = Invoke-Meta @('-Tag', 'v0.51', '-What', 'create-flags')
Check 'ungueltiges Tag -> Exit ungleich 0' ($r.Code -ne 0)

Write-Host 'E: Verdrahtung' -ForegroundColor Cyan
$yml = [IO.File]::ReadAllText((Join-Path $RepoRoot '.github\workflows\release.yml'), $u8)
Check 'release.yml holt die Schalter aus release_meta.ps1' ($yml -match 'release_meta\.ps1 -Tag "\$\{TAG\}" -What create-flags')
Check 'release.yml reicht sie an gh release create' ($yml -match '(?s)gh release create "\$\{TAG\}".*?"\$\{kind_flags\[@\]\}"')
Check 'release.yml: Installations-Hinweis aus release_meta.ps1' ($yml -match 'release_meta\.ps1 -Tag "\$\{TAG\}" -What install-note')
Check 'release.yml: kein eigener Installations-Text mehr' ($yml -notmatch 'printf .*Install \(as root')
$sign = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts\sign_release.ps1'), $u8)
Check 'sign_release laedt den Helfer' ($sign -match "lib\\release_tag\.ps1")
Check 'sign_release veroeffentlicht mit Get-ReleasePublishFlags' ($sign -match 'gh release edit \$Tag -R \$slug @\(Get-ReleasePublishFlags \$Tag\)')
Check 'sign_release: kein festes --latest mehr' ($sign -notmatch '--draft=false --latest')
Check 'sign_release: Tag-Pruefung ueber den Helfer (keine zweite Regex)' ($sign -notmatch [regex]::Escape("'^v\d+\.\d+\.\d+$'"))
$bmi = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts\build_master_image.ps1'), $u8)
Check 'build_master_image prueft die Version ueber den Helfer' ($bmi -match 'Get-ReleaseTagKind \$Version' -and $bmi -notmatch [regex]::Escape("-notmatch '^v"))

Write-Host ''
if ($failed) { Write-Host "release_tag_test: $failed Fehler" -ForegroundColor Red } else { Write-Host 'release_tag_test: alles gruen' -ForegroundColor Green }
exit $failed
