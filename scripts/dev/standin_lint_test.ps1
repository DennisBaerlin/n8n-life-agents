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

# --- (C) Stubs ohne den Namen fake_: PATH-Attrappen und die Ordner tests/mock_runtime, tests/mock_reach ---
$AL = 'tests/util/standin_allowlist.json'
Test-Case 'PATH-Attrappe ohne Marker ist rot' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`nW=/tmp/w`nexport PATH=`"`$W/bin:`$PATH`"`n"
} $true 'PATH-Attrappe'
Test-Case 'PATH-Attrappe mit Marker auf vorhandene Datei ist gruen' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`n# real-path-test: $T/y/real.sh`nW=/tmp/w`nexport PATH=`"`$W/bin:`$PATH`"`n"
    "$T/y/real.sh"  = "echo real`n"
} $false ''
Test-Case 'PATH-Attrappe mit Marker none und Grund ist gruen' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`n# real-path-test: none (kein echtes Konto im Test)`nPATH=`"`$W/shim:`$PATH`"`n"
} $false ''
Test-Case 'Datei in mock_runtime ohne Marker ist rot' @{
    "$T/mock_runtime/cases.sh" = "#!/usr/bin/env bash`necho hi`n"
} $true 'mock_runtime'
Test-Case 'Datei in mock_reach ohne Marker ist rot' @{
    "$T/mock_reach/server.js" = "// js`n"
    "$T/mock_reach/cli_cases.sh" = "#!/usr/bin/env bash`necho hi`n"
} $true 'mock_reach'
Test-Case 'PATH verengen ist keine Attrappe' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`nPATH=`"/usr/bin:/bin`"`n"
} $false ''
Test-Case 'PATH-Zeile im Here-Doc ist kein Treffer' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`ncat > x <<'EOF'`nPATH=`"`$W/bin:`$PATH`"`nexport RELEASE_TAG=v9.0.0`nEOF`n"
} $false ''

Test-Case 'Here-Doc-Marke im Kommentar oder in Arithmetik verschluckt nichts' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`n# cat <<EOF zeigt nur den Aufruf`nx=`$((1<<2))`nexport RELEASE_TAG=v9.0.0`n"
} $true 'RELEASE_TAG'

# --- (D) export NAME=<fester Wert> vor dem geprueften Aufruf ---
Test-Case 'export mit festem Wert ohne Begruendung ist rot' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`nexport RELEASE_TAG=v9.0.0`n"
} $true 'RELEASE_TAG'
Test-Case 'export mit Begruendung in der Zeile davor ist gruen' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`n# hand-injected: der echte Weg liest den Wert aus der Antwort-Datei, dort getrennt geprueft`nexport RELEASE_TAG=v9.0.0`n"
} $false ''
Test-Case 'export mit Wert aus Variable oder Pfad ist gruen' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`nexport LIFEAGENTS_DIR=`"`$W/etc`" X_FILE=`"`$ROOT/a`"`nexport LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1`n"
} $false ''
Test-Case 'zweiter fester Wert in einer export-Zeile ist rot' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`nexport A_DIR=`"`$W/a`" PROFILE=release`n"
} $true 'PROFILE'
Test-Case 'Ausnahmeliste nimmt den Fund aus' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`nexport PROFILE=release`n"
    $AL = '{"entries":{"tests/y/cases.sh|PROFILE":"echter Test fehlt: Installer-Lauf mit Antwort-Datei"}}'
} $false ''
Test-Case 'veralteter Ausnahme-Eintrag ist rot (Liste darf nur schrumpfen)' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`necho hi`n"
    $AL = '{"entries":{"tests/y/cases.sh|PROFILE":"alt"}}'
} $true 'veraltet'
Test-Case 'Ausnahme-Eintrag ohne Grund ist rot' @{
    "$T/y/cases.sh" = "#!/usr/bin/env bash`nexport PROFILE=release`n"
    $AL = '{"entries":{"tests/y/cases.sh|PROFILE":""}}'
} $true 'Grund'

if ($fails -eq 0) { Write-Host 'PASS standin_lint_test' -ForegroundColor Green } else { Write-Host "standin_lint_test: $fails Fehler" -ForegroundColor Red }
exit $fails
