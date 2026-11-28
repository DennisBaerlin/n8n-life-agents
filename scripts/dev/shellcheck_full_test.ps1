#Requires -Version 5.1
# Der Pre-Push-Hook shellcheck-full prueft alle Shell-Skripte, nicht nur die geaenderten: aendert ein Commit eine Funktion (liest
# sie nun $1), meldet shellcheck (SC2119) den unveraenderten Aufrufer, den der Commit-Hook nicht sieht.
#   1. Verdrahtung: .pre-commit-config.yaml hat shellcheck-full (pre-push, always_run, ganzer Baum).
#   2. Nachgestellter Fall im Wegwerf-Repo: lib.sh + caller.sh, zweiter Commit aendert nur lib.sh. Der Lauf ueber die
#      geaenderte Datei bleibt gruen (die Luecke), der Lauf ueber alle Dateien (was shellcheck-full fuehrt) wird rot.
# Voraussetzung: prek, git, Hook-Umgebung im prek-Cache (kein Docker, kein Netz bei warmem Cache).
# Usage: .\scripts\dev\shellcheck_full_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$u8 = New-Object System.Text.UTF8Encoding($false)
$repo = (git -C $PSScriptRoot rev-parse --show-toplevel)
$cfg = [System.IO.File]::ReadAllText((Join-Path $repo '.pre-commit-config.yaml'), $u8)
$fails = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL $Name $Detail" -ForegroundColor Red; $script:fails++ }
}

# 1. Verdrahtung
$blk = [regex]::Match($cfg, '(?ms)^\s*-\s*id:\s*shellcheck-full\b.*?(?=^\s*-\s*id:|\z)')
Check 'shellcheck-full ist in der Konfiguration' $blk.Success
if ($blk.Success) {
    Check 'shellcheck-full laeuft im pre-push' ($blk.Value -match 'stages:\s*\[pre-push\]')
    Check 'shellcheck-full ist always_run ohne Dateiliste' (($blk.Value -match 'always_run:\s*true') -and ($blk.Value -match 'pass_filenames:\s*false'))
    Check 'shellcheck-full fuehrt shellcheck ueber alle Dateien' ($blk.Value -match 'prek\s+run\s+shellcheck\s+--all-files')
}

# 2. Nachgestellter Fall im Wegwerf-Repo
$rev = [regex]::Match($cfg, '(?ms)shellcheck-py/shellcheck-py\s*\r?\n\s*rev:\s*(\S+)').Groups[1].Value
Check 'shellcheck-py-Version gefunden' ($rev -ne '')
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('scf_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # SKIP: die Auslass-Liste des aeusseren prek-Laufs (CI) nennt Hooks, die es im Wegwerf-Repo nicht gibt; prek warnt dann
    # auf stderr, und 2>&1 macht daraus unter 'Stop' einen Abbruch.
    foreach ($n in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_PREFIX','GIT_COMMON_DIR','SKIP')) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
    New-Item -ItemType Directory -Path (Join-Path $tmp 'config') | Out-Null
    Copy-Item (Join-Path $repo 'config\shellcheckrc') (Join-Path $tmp 'config\shellcheckrc')
    $wcfg = "repos:`n  - repo: https://github.com/shellcheck-py/shellcheck-py`n    rev: $rev`n    hooks:`n      - id: shellcheck`n        args: ['--rcfile=config/shellcheckrc']`n"
    [System.IO.File]::WriteAllText((Join-Path $tmp '.pre-commit-config.yaml'), $wcfg, $u8)
    [System.IO.File]::WriteAllText((Join-Path $tmp 'lib.sh'), "#!/usr/bin/env bash`nf() { echo hi; }`n", $u8)
    [System.IO.File]::WriteAllText((Join-Path $tmp 'caller.sh'), "#!/usr/bin/env bash`n# shellcheck source=lib.sh`n. ./lib.sh`nf`n", $u8)
    Push-Location $tmp
    try {
        git init -q 2>&1 | Out-Null
        git config user.email t@example.invalid; git config user.name t; git config core.autocrlf false
        git add -A; git commit -q -m base 2>&1 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tmp 'lib.sh'), "#!/usr/bin/env bash`nf() { echo `"`$1`"; }`n", $u8)
        git add -A; git commit -q -m "f reads the first argument" 2>&1 | Out-Null
        $changed = (prek run shellcheck --from-ref HEAD~1 --to-ref HEAD 2>&1) -join "`n"
        $changedRc = $LASTEXITCODE
        $all = (prek run shellcheck --all-files 2>&1) -join "`n"
        $allRc = $LASTEXITCODE
    } finally { Pop-Location }
    Check 'Lauf nur ueber die geaenderte Datei sieht den Aufrufer nicht (die Luecke)' ($changedRc -eq 0) $changed
    Check 'Lauf ueber alle Dateien faengt SC2119 im unveraenderten Aufrufer' (($allRc -ne 0) -and ($all -match 'SC2119')) $all
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

if ($fails -eq 0) { Write-Host 'PASS shellcheck_full_test' -ForegroundColor Green } else { Write-Host "shellcheck_full_test: $fails Fehler" -ForegroundColor Red }
exit $fails
