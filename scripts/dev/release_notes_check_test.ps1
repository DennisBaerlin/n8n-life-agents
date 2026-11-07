#Requires -Version 5.1
# release_notes_check_test.ps1 - GRATIS Test von scripts\release_notes_check.ps1 (kein Docker, kein n8n).
# Liest die gemeinsamen Faelle aus tests\fixtures\release_notes\ (<fall>.md + <fall>.<lang>.expected.txt = erwartete
# Kurzfassung) und prueft Exit-Code und Meldung; Grenzfaelle der Laenge (Umlaute, Emoji = ein Codepoint) entstehen
# im Test. Dieselben Faelle stehen inline in tests\db\core\test_fn_release_card.sql (Abschnitt 9) - Aenderungen an beiden Stellen.
# Usage:  .\scripts\dev\release_notes_check_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$Check = Join-Path (Join-Path $RepoRoot 'scripts') 'release_notes_check.ps1'
$Fix = Join-Path (Join-Path (Join-Path $RepoRoot 'tests') 'fixtures') 'release_notes'
$PsExe = (Get-Process -Id $PID).Path
$Utf8 = [Text.UTF8Encoding]::new($false)
$failed = 0
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("rnc_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

function Invoke-Check([string]$Path, [string[]]$More = @()) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $PsExe -NoProfile -ExecutionPolicy Bypass -File $Check -File $Path @More 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Text = (($out | ForEach-Object { "$_" }) -join "`n") }
}
function Assert-Case([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Ok) { Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Name - $Detail" -ForegroundColor Red; $script:failed++ }
}

try {
    Write-Host "release_notes_check_test"

    # --- Fixtures: in Ordnung + erwartete Kurzfassungen -------------------------------------------------------------
    $r = Invoke-Check (Join-Path $Fix 'ok.md')
    Assert-Case 'ok.md besteht' ($r.Code -eq 0) "Exit $($r.Code): $($r.Text)"
    foreach ($exp in Get-ChildItem -LiteralPath $Fix -Filter '*.expected.txt') {
        $parts = $exp.Name -split '\.'          # <fall>.<lang>.expected.txt
        $case = $parts[0]; $lang = $parts[1]
        $want = [IO.File]::ReadAllText($exp.FullName, $Utf8).Trim()
        $p = Invoke-Check (Join-Path $Fix "$case.md") @('-Print', $lang)
        Assert-Case "$case Kurzfassung $lang" ($p.Text.Trim() -ceq $want) "erwartet '$want', bekommen '$($p.Text.Trim())'"
    }

    # --- Fixtures: muessen scheitern, mit passender Meldung ----------------------------------------------------------
    $bad = [ordered]@{
        'ohne_ko.md'            = 'summary:ko fehlt'
        'ohne_de.md'            = 'summary:de fehlt'
        'nur_en.md'             = 'summary:de fehlt'
        'marker_im_intro.md'    = 'Einleitungsabsatz enthaelt'
        'schliesser_im_text.md' = 'passt nicht'
        'unbekannte_sprache.md' = 'nicht im Manifest'
        'leerer_marker.md'      = 'summary:de ist leer'
        'marker_nach_4000.md'   = 'endet nach Zeichen 4000'
    }
    foreach ($name in $bad.Keys) {
        $r = Invoke-Check (Join-Path $Fix $name)
        Assert-Case "$name scheitert" ($r.Code -eq 1 -and $r.Text.Contains($bad[$name])) "Exit $($r.Code), Text: $($r.Text)"
    }

    # --- Zaehlung: Codepoints, nicht UTF-16-Einheiten ---------------------------------------------------------------
    $ko = "`n`n<!-- summary:ko`n" + [string][char]0xD55C + "`n-->`n"
    $make = {
        param($de, $intro = 'English intro.')
        $f = Join-Path $tmp ([guid]::NewGuid().ToString('N') + '.md')
        [IO.File]::WriteAllText($f, "$intro`n`n<!-- summary:de`n$de`n-->$ko", $Utf8)
        $f
    }
    $ae = [string][char]0xE4
    $emoji = [char]::ConvertFromUtf32(0x1F600)
    $r = Invoke-Check (& $make ($ae * 300))
    Assert-Case '300 Umlaute bestehen' ($r.Code -eq 0) "Exit $($r.Code): $($r.Text)"
    $r = Invoke-Check (& $make ($ae * 301))
    Assert-Case '301 Umlaute scheitern' ($r.Code -eq 1 -and $r.Text.Contains('301 Zeichen')) "Exit $($r.Code): $($r.Text)"
    $r = Invoke-Check (& $make (($emoji * 150) + ($ae * 150)))
    Assert-Case '150 Emoji + 150 Umlaute = 300 Codepoints bestehen' ($r.Code -eq 0) "Exit $($r.Code): $($r.Text)"
    $r = Invoke-Check (& $make 'Kurz.' ('x' * 301))
    Assert-Case 'Intro mit 301 Zeichen scheitert' ($r.Code -eq 1 -and $r.Text.Contains('Einleitungsabsatz ist 301')) "Exit $($r.Code): $($r.Text)"
    $p = Invoke-Check (& $make ($ae * 400)) @('-Print', 'de')
    Assert-Case '-Print kuerzt auf 299 + Auslassung' ($p.Text.Trim().Length -eq 300 -and $p.Text.Trim().EndsWith([string][char]0x2026)) "Laenge $($p.Text.Trim().Length)"
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failed -eq 0) { Write-Host "release_notes_check_test: alle Faelle gruen" -ForegroundColor Green } else { Write-Host "release_notes_check_test: $failed Fehler" -ForegroundColor Red }
exit $failed
