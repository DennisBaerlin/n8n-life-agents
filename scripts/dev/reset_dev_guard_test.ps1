#Requires -Version 5.1
# reset_dev_guard_test.ps1 -- Regressionstest der Ziel-Sperre im Reset-Skript der Entwickler-Instanz und der Trennung
# LIVE_INSTANCE_* (Produktiv, nur lesend) / DEV_INSTANCE_* (nur Reset). scripts/reset_dev_instance.ps1 und
# scripts/refresh_privacy_denylist.ps1 laufen als Kopie in einem Wegwerf-Repo mit erfundener .env; ssh/scp sind Attrappen auf dem
# PATH (Aufruf-Log + vorgegebene Antwort der Merkdatei-Abfrage). Dazu der Adress-Vergleich Test-SameTargetAddresses
# (scripts/lib/dev_target.ps1) und ein Scan der getrackten Dateien: DEV_INSTANCE_* steht nur in erlaubten Nutzern (braucht git).
# Kein echtes Ziel, kein Netz, kein Substrat; alle Werte erfunden.
# Usage:  .\scripts\dev\reset_dev_guard_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$u8 = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
Clear-GitEnvironment
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
$failed = 0
function Assert-True([string]$Name, [bool]$Ok, [string]$Got = '') {
    if ($Ok) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name $Got" -ForegroundColor Red; $script:failed++ }
}

Write-Host 'Adress-Vergleich DEV/LIVE: die Router-Adresse in beiden Namen zaehlt nicht (Fritz-Box-Namen loesen auch auf den Router auf)'
. (Join-Path $repo 'scripts\lib\dev_target.ps1')
$router = @('192.168.178.10')
Assert-True 'nur der Router gemeinsam: nicht dasselbe Ziel' (-not (Test-SameTargetAddresses @('192.168.178.20', '192.168.178.10') @('192.168.178.30', '192.168.178.10') $router))
Assert-True 'Container-Adresse gemeinsam (IP gegen Name): dasselbe Ziel' (Test-SameTargetAddresses @('192.168.178.20') @('192.168.178.20', '192.168.178.10') $router)
Assert-True 'gleiche Adressen samt Router: dasselbe Ziel' (Test-SameTargetAddresses @('192.168.178.20', '192.168.178.10') @('192.168.178.20', '192.168.178.10') $router)
Assert-True 'nichts aufloesbar: kein Urteil (die Merkdatei entscheidet)' (-not (Test-SameTargetAddresses @() @() $router))
Assert-True 'zwei nicht aufloesbare Namen (leere Ergebnisse kommen als $null an): kein Urteil' (-not (Test-SameTargetAddresses $null $null $router))
Assert-True 'ein nicht aufloesbarer Name: kein Urteil' (-not (Test-SameTargetAddresses $null @('192.168.178.20') $router))
Assert-True 'ohne bekannte Router-Adresse zaehlt jede gemeinsame' (Test-SameTargetAddresses @('192.168.178.10') @('192.168.178.10') @())

$isWin = [System.IO.Path]::DirectorySeparatorChar -eq '\'
$psExe = (Get-Process -Id $PID).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('reset_dev_guard_test_' + [guid]::NewGuid().ToString('N'))
$sandbox = Join-Path $work 'repo'
$fakeBin = Join-Path $work 'bin'
New-Item -ItemType Directory -Force $sandbox, $fakeBin | Out-Null
$log = Join-Path $work 'calls.log'
$guardOut = Join-Path $work 'guard_out.txt'
$keyFile = Join-Path $work 'key'
[System.IO.File]::WriteAllText($keyFile, 'fake', $u8)

try {
    # --- Wegwerf-Repo: Kopie der zwei Skripte samt Bibliotheken, erfundene .env ---
    Initialize-GitSandbox $sandbox
    foreach ($rel in 'scripts\reset_dev_instance.ps1', 'scripts\refresh_privacy_denylist.ps1', 'scripts\lib\dotenv.ps1', 'scripts\lib\dev_target.ps1', 'scripts\lib\live_read.ps1',
                     'scripts\lib\privacy_terms.ps1', 'scripts\lib\privacy_terms.sql') {
        $src = Join-Path $repo $rel
        $dst = Join-Path $sandbox $rel
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst
    }
    function Write-Env([string]$DevHost, [string]$LiveHost) {
        $t = "DEV_INSTANCE_HOST=$DevHost`nDEV_INSTANCE_USER=root`nDEV_INSTANCE_SSH_KEY=$keyFile`n"
        if ($LiveHost) { $t += "LIVE_INSTANCE_HOST=$LiveHost`nLIVE_INSTANCE_USER=root`nLIVE_INSTANCE_SSH_KEY=$keyFile`n" }
        [System.IO.File]::WriteAllText((Join-Path $sandbox '.env'), $t, $u8)
    }

    # --- Attrappen: ssh/scp protokollieren ihre Argumente; nur die Merkdatei-Abfrage bekommt eine Antwort, alles andere scheitert (Exit 1) ---
    $fakeCore = Join-Path $fakeBin 'fake_remote.ps1'
    [System.IO.File]::WriteAllText($fakeCore, @'
$name = $args[0]
$rest = @($args | Select-Object -Skip 1)
Add-Content -LiteralPath $env:FAKE_LOG -Value ("$name " + ($rest -join ' '))
if ($name -eq 'ssh' -and ($rest -join ' ') -match 'lifeagents-dev-instance' -and (Test-Path -LiteralPath $env:FAKE_GUARD_OUT)) {
    [System.IO.File]::ReadAllText($env:FAKE_GUARD_OUT) | Write-Host -NoNewline
    exit 0
}
exit 1
'@, $u8)
    foreach ($n in 'ssh', 'scp') {
        if ($isWin) {
            [System.IO.File]::WriteAllText((Join-Path $fakeBin "$n.cmd"),
                "@echo off`r`n`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$fakeCore`" $n %*`r`nexit /b %ERRORLEVEL%`r`n", $u8)
        } else {
            $p = Join-Path $fakeBin $n
            [System.IO.File]::WriteAllText($p, "#!/bin/sh`nexec `"$psExe`" -NoProfile -File `"$fakeCore`" $n `"`$@`"`n", $u8)
            & chmod +x $p
        }
    }
    $env:FAKE_LOG = $log
    $env:FAKE_GUARD_OUT = $guardOut
    $origPath = $env:PATH
    $env:PATH = $fakeBin + [System.IO.Path]::PathSeparator + $origPath

    # Skript im Wegwerf-Repo starten -> Text + Exit-Code + protokollierte Aufrufe.
    function Invoke-Sandboxed([string]$ScriptRel, [string[]]$ScriptArgs = @()) {
        if (Test-Path $log) { Remove-Item $log }
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            $text = (& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $sandbox $ScriptRel) @ScriptArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $prev }
        $calls = @(); if (Test-Path $log) { $calls = @([System.IO.File]::ReadAllLines($log)) }
        return [pscustomobject]@{ Code = $code; Text = $text; Calls = $calls }
    }
    function Set-GuardAnswer([string]$Text) {
        if ($null -eq $Text) { if (Test-Path $guardOut) { Remove-Item $guardOut }; return }
        [System.IO.File]::WriteAllText($guardOut, $Text, $u8)
    }
    function Test-NoWrite($r) {
        # -cmatch: 'chmod' stuende sonst als "BatchMode" (ssh-Option) im Treffer.
        return -not @($r.Calls | Where-Object { $_ -cmatch '^scp ' -or $_ -cmatch 'mkdir|rm -|chmod |reset\.sh|tee |>' }).Count
    }
    $mk = 'MARKER-FOUND'
    Write-Env 'devbox.example.invalid' 'livebox.example.invalid'

    Write-Host 'Ohne Merkdatei: Abbruch vor jedem Schreiben'
    Set-GuardAnswer "MARKER-MISSING`nHOST=devbox`n"
    $r = Invoke-Sandboxed 'scripts\reset_dev_instance.ps1'
    Assert-True 'Exit ungleich 0' ($r.Code -ne 0) "Code=$($r.Code)"
    Assert-True 'genau ein ssh-Aufruf (nur die Abfrage)' ($r.Calls.Count -eq 1 -and $r.Calls[0] -match '^ssh ') ($r.Calls -join ' | ')
    Assert-True 'kein Schreibzugriff (scp, mkdir, rm, chmod, Umleitung)' (Test-NoWrite $r) ($r.Calls -join ' | ')
    Assert-True 'Meldung nennt Merkdatei und den Befehl zum Anlegen' ($r.Text -match '/etc/lifeagents-dev-instance' -and $r.Text -match 'printf') $r.Text
    Assert-True 'ssh prueft den Host-Key streng (eine Nutzer-Config mit "no" darf ihn nicht abschalten)' ($r.Calls[0] -match 'StrictHostKeyChecking=yes') ($r.Calls -join ' | ')

    Write-Host 'Auch -KeepInstance schreibt (Upload) und ist gesperrt'
    $r = Invoke-Sandboxed 'scripts\reset_dev_instance.ps1' @('-KeepInstance')
    Assert-True 'Exit ungleich 0, nur die Abfrage' ($r.Code -ne 0 -and $r.Calls.Count -eq 1 -and (Test-NoWrite $r)) ($r.Calls -join ' | ')

    Write-Host 'Merkdatei eines anderen Rechners (kopiert/geklont): Abbruch'
    Set-GuardAnswer "$mk`nlifeagents-dev-instance: otherbox`ndata: test-only`nHOST=devbox`n"
    $r = Invoke-Sandboxed 'scripts\reset_dev_instance.ps1'
    Assert-True 'Exit ungleich 0, nur die Abfrage' ($r.Code -ne 0 -and $r.Calls.Count -eq 1 -and (Test-NoWrite $r)) ($r.Calls -join ' | ')

    Write-Host 'Merkdatei ohne Testdaten-Zusage: Abbruch'
    Set-GuardAnswer "$mk`nlifeagents-dev-instance: devbox`nHOST=devbox`n"
    $r = Invoke-Sandboxed 'scripts\reset_dev_instance.ps1'
    Assert-True 'Exit ungleich 0, nur die Abfrage' ($r.Code -ne 0 -and $r.Calls.Count -eq 1 -and (Test-NoWrite $r)) ($r.Calls -join ' | ')

    Write-Host 'DEV und LIVE zeigen auf dasselbe Ziel: Abbruch ohne einen ssh-Aufruf'
    Write-Env 'LiveBox.example.invalid' 'livebox.example.invalid'
    Set-GuardAnswer "$mk`nlifeagents-dev-instance: devbox`ndata: test-only`nHOST=devbox`n"
    $r = Invoke-Sandboxed 'scripts\reset_dev_instance.ps1'
    Assert-True 'Exit ungleich 0, kein Aufruf' ($r.Code -ne 0 -and $r.Calls.Count -eq 0) ($r.Calls -join ' | ')
    Assert-True 'Meldung nennt LIVE_INSTANCE_HOST' ($r.Text -match 'LIVE_INSTANCE_HOST') $r.Text

    Write-Host 'DEV als Adresse, LIVE als Name desselben Rechners: Abbruch ohne ssh-Aufruf'
    Write-Env '127.0.0.1' 'localhost'
    $r = Invoke-Sandboxed 'scripts\reset_dev_instance.ps1'
    Assert-True 'Exit ungleich 0, kein Aufruf' ($r.Code -ne 0 -and $r.Calls.Count -eq 0) ($r.Calls -join ' | ')

    Write-Host 'Gueltige Merkdatei: Sperre laesst durch (der naechste ssh-Aufruf ist der erste Schreibschritt)'
    Write-Env 'devbox.example.invalid' 'livebox.example.invalid'
    Set-GuardAnswer "$mk`nlifeagents-dev-instance: devbox`ndata: test-only`nHOST=devbox`n"
    $r = Invoke-Sandboxed 'scripts\reset_dev_instance.ps1'
    Assert-True 'zweiter ssh-Aufruf legt den Ordner an' ($r.Calls.Count -ge 2 -and $r.Calls[1] -match 'mkdir -p') ($r.Calls -join ' | ')

    Write-Host 'Ohne LIVE_INSTANCE_* (Sperre prueft dann nur die Merkdatei)'
    Write-Env 'devbox.example.invalid' ''
    $r = Invoke-Sandboxed 'scripts\reset_dev_instance.ps1'
    Assert-True 'Merkdatei gueltig -> weiter' ($r.Calls.Count -ge 2 -and $r.Calls[1] -match 'mkdir -p') ($r.Calls -join ' | ')

    Write-Host 'Privacy-Liste liest nur LIVE_INSTANCE_*, kein stiller Rueckfall auf DEV_INSTANCE_*'
    Write-Env 'devbox.example.invalid' ''
    $r = Invoke-Sandboxed 'scripts\refresh_privacy_denylist.ps1'
    Assert-True 'Exit 1, kein ssh/scp-Aufruf' ($r.Code -eq 1 -and $r.Calls.Count -eq 0) "Code=$($r.Code) Calls=$($r.Calls -join ' | ')"
    Assert-True 'Meldung nennt LIVE_INSTANCE_HOST' ($r.Text -match 'LIVE_INSTANCE_HOST') $r.Text
    Write-Env 'devbox.example.invalid' 'livebox.example.invalid'
    $r = Invoke-Sandboxed 'scripts\refresh_privacy_denylist.ps1'
    Assert-True 'Privacy-Liste prueft den Host-Key streng' ($r.Calls.Count -ge 1 -and @($r.Calls | Where-Object { $_ -notmatch 'StrictHostKeyChecking=yes' }).Count -eq 0) ($r.Calls -join ' | ')
    Assert-True 'mit LIVE_INSTANCE_*: Ziel ist der LIVE-Host' ($r.Calls.Count -ge 1 -and ($r.Calls -join ' ') -match 'livebox\.example\.invalid' -and ($r.Calls -join ' ') -notmatch 'devbox') ($r.Calls -join ' | ')

    Write-Host 'Trennung im Repo: DEV_INSTANCE_* nur im Reset-Skript'
    $liveUsers = @('scripts/refresh_privacy_denylist.ps1', 'scripts/live_read.ps1', 'scripts/lib/live_read.ps1','.claude/skills/live-findings/SKILL.md', '.claude/skills/cost-report/SKILL.md')
    # Die Nutzer duerfen DEV_INSTANCE_* nur als Verbot nennen ("tabu", "kein Rueckfall"), nie als Zugang lesen.
    foreach ($f in $liveUsers) {
        $t = [System.IO.File]::ReadAllText((Join-Path $repo $f))
        Assert-True "$f nennt LIVE_INSTANCE_" ($t -match 'LIVE_INSTANCE_')
        Assert-True "$f liest DEV_INSTANCE_* nicht" ($t -notmatch "Get-MainEnvValue\s+'DEV_INSTANCE" -and $t -notmatch '(?m)^[^#\r\n]*\$\w+\s*=\s*.*DEV_INSTANCE')
    }
    $tracked = @(git -C $repo ls-files -- scripts .claude/skills .claude/hooks docs provisioning packages '*.md' '.env.example')
    $devUsers = @($tracked | Where-Object {
        $_ -notlike 'scripts/dev/reset_dev_guard_test.ps1' -and $_ -notlike 'scripts/dev/live_read_test.ps1' -and (Test-Path (Join-Path $repo $_)) -and
        ([System.IO.File]::ReadAllText((Join-Path $repo $_)) -match 'DEV_INSTANCE_')
    })
    $allowed = @('scripts/reset_dev_instance.ps1', '.env.example', '.claude/skills/reset-dev/SKILL.md', 'docs/reference/scripts.md') + $liveUsers
    $stray = @($devUsers | Where-Object { $allowed -notcontains $_ -and $_ -notlike '.claude/plans/*' })
    Assert-True 'kein weiterer Nutzer von DEV_INSTANCE_*' ($stray.Count -eq 0) ($stray -join ', ')
} finally {
    if ($origPath) { $env:PATH = $origPath }
    Remove-Item Env:\FAKE_LOG, Env:\FAKE_GUARD_OUT -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed -eq 0) { Write-Host 'OK: alle Pruefungen bestanden.' -ForegroundColor Green } else { Write-Host "$failed Pruefung(en) FEHLGESCHLAGEN." -ForegroundColor Red }
exit $failed
