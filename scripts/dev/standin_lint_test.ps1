#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/standin_lint.ps1 in einem Wegwerf-Baum (-Root): Attrappe ohne Marker, Marker auf
# fehlende Datei, Ausnahme ohne Grund, von Hand mitgegebener Wert ohne Begruendung muessen rot werden; die markierten
# Gegenstuecke gruen. Kein Docker, kein git.
# Usage: .\scripts\dev\standin_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\standin_lint.ps1'
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0

function New-Tree([hashtable]$Files) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('sil_' + [guid]::NewGuid().ToString('N'))
    foreach ($rel in $Files.Keys) {
        $p = Join-Path $root $rel
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        [System.IO.File]::WriteAllText($p, $Files[$rel], $u8)
    }
    return $root
}

function Test-Case([string]$Name, [hashtable]$Files, [bool]$ExpectRed, [string]$ExpectText) {
    $root = New-Tree $Files
    try {
        $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint -Root $root) -join "`n"
        $red = $LASTEXITCODE -ne 0
        $ok = ($red -eq $ExpectRed) -and (-not $ExpectText -or $out -match [regex]::Escape($ExpectText))
        if ($ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL $Name (Exit $LASTEXITCODE): $out" -ForegroundColor Red; $script:fails++ }
    } finally { Remove-Item -Recurse -Force $root }
}

# Pfade zusammengesetzt: doc_lint liest ausgeschriebene Repo-Pfade als Verweise auf echte Dateien.
$T = 'tests'
Test-Case 'Attrappe ohne Marker ist rot' @{
    "$T/x/fixtures/fake_tool.sh" = "#!/usr/bin/env bash`n# Attrappe`n"
} $true 'fake_tool.sh'
Test-Case 'Marker auf fehlende Datei ist rot' @{
    "$T/x/fixtures/fake_tool.sh" = "#!/usr/bin/env bash`n# real-path-test: $T/x/gibt_es_nicht.test.js`n"
} $true 'gibt_es_nicht'
Test-Case 'Marker auf vorhandenen Test ist gruen' @{
    "$T/x/fixtures/fake_tool.sh" = "#!/usr/bin/env bash`n# real-path-test: $T/x/real.test.js`n"
    "$T/x/real.test.js"         = "// test`n"
} $false ''
Test-Case 'Ausnahme ohne Grund ist rot' @{
    "$T/x/fixtures/fake_tool.sh" = "#!/usr/bin/env bash`n# real-path-test: none`n"
} $true 'Grund'
Test-Case 'Ausnahme mit Grund ist gruen' @{
    "$T/x/fixtures/fake_tool.sh" = "#!/usr/bin/env bash`n# real-path-test: none (Live-Dienst, im Test nicht erreichbar)`n"
} $false ''
Test-Case 'docker exec -e ohne Begruendung ist rot' @{
    '.github/workflows/a.yml' = "steps:`n  - run: |`n      docker exec -e RELEASE_TAG=v9.0.0 la bash /opt/x/provision.sh`n"
} $true 'RELEASE_TAG'
Test-Case 'docker exec -e mit Begruendung in der Zeile davor ist gruen' @{
    '.github/workflows/a.yml' = "steps:`n  - run: |`n      # hand-injected: Wert kommt im echten Weg aus der Antwort-Datei, hier Kurzweg`n      docker exec -e RELEASE_TAG=v9.0.0 la bash /opt/x/provision.sh`n"
} $false ''
Test-Case 'Wert vor provision.sh ohne Begruendung ist rot' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`nRELEASE_TAG=v9.0.0 bash /opt/x/provision.sh --unattended a.env`n"
} $true 'RELEASE_TAG'
Test-Case 'docker exec test ! -e ist kein Treffer' @{
    '.github/workflows/a.yml' = "steps:`n  - run: docker exec la test ! -e /var/lib/x/state`n"
} $false ''
Test-Case 'leere Begruendung zaehlt nicht' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`n# hand-injected:`ndocker exec --env FOO=1 la true`n"
} $true 'FOO'

if ($fails -eq 0) { Write-Host 'PASS standin_lint_test' -ForegroundColor Green } else { Write-Host "standin_lint_test: $fails Fehler" -ForegroundColor Red }
exit $fails
