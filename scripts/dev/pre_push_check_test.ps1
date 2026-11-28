#Requires -Version 5.1
# pre_push_check.ps1 mit einer prek-Attrappe auf dem PATH (protokolliert Argumente und SKIP, prueft nichts): in der Commit-Stufe stehen genau
# die Haken mit `-full`-Zwilling in SKIP (sie laufen in der Push-Stufe voll), die Push-Stufe laeuft ohne diese Liste (shellcheck-full ruft prek
# selbst auf und erbte sie), ein vorhandenes SKIP bleibt erhalten, und ein roter Lauf einer Stufe macht das Skript rot.
# Usage: .\scripts\dev\pre_push_check_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle. Kein Docker, kein Netz.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\test_common.ps1')
$check = Join-Path $PSScriptRoot '..\pre_push_check.ps1'
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL $Name $Detail" -ForegroundColor Red; $script:fails++ }
}

$cfg = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\.pre-commit-config.yaml'), $u8)
$ids = @([regex]::Matches($cfg, '(?m)^\s*- id:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
$twins = @($ids | Where-Object { $ids -ccontains "$_-full" } | Sort-Object -Unique)

$fake = New-TestTree @{ 'prek.cmd' = "@echo off`r`necho %*^|SKIP=%SKIP%>>`"%~dp0calls.log`"`r`necho %* | findstr /c:`"%FAKE_PREK_RED%`" >nul && exit /b 1`r`nexit /b 0`r`n" } 'ppc'
$savedPath = $env:PATH; $savedSkip = $env:SKIP; $savedRed = $env:FAKE_PREK_RED
try {
    $env:PATH = "$fake;$env:PATH"
    $shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    function Invoke-Check([string]$Skip, [string]$RedStage) {
        Remove-Item -LiteralPath (Join-Path $fake 'calls.log') -ErrorAction SilentlyContinue
        $env:SKIP = $Skip; $env:FAKE_PREK_RED = $RedStage
        $null = & $shell -NoProfile -ExecutionPolicy Bypass -File $check
        return @{ Code = $LASTEXITCODE; Calls = @(Get-Content -LiteralPath (Join-Path $fake 'calls.log')) }
    }

    $r = Invoke-Check '' 'nie-rot'
    Check 'zwei Laeufe, Commit-Stufe zuerst' ($r.Calls.Count -eq 2 -and $r.Calls[0] -match '--hook-stage pre-commit' -and $r.Calls[1] -match '--hook-stage pre-push') ($r.Calls -join ' ## ')
    $skip1 = @(($r.Calls[0] -split '\|SKIP=')[1] -split ',' | Where-Object { $_ })
    Check "Commit-Stufe ueberspringt genau die $($twins.Count) Haken mit -full-Zwilling" ($twins.Count -ge 7 -and (@($skip1 | Sort-Object) -join ',') -ceq ($twins -join ',')) "SKIP=$($skip1 -join ',')"
    Check 'Push-Stufe laeuft ohne SKIP' (($r.Calls[1] -split '\|SKIP=')[1] -eq '') $r.Calls[1]
    Check 'beide gruen -> Exit 0' ($r.Code -eq 0) "Exit $($r.Code)"

    $r = Invoke-Check 'gitleaks' 'nie-rot'
    Check 'vorhandenes SKIP gilt in beiden Stufen weiter' ((($r.Calls[0] -split '\|SKIP=')[1] -split ',') -ccontains 'gitleaks' -and ($r.Calls[1] -split '\|SKIP=')[1] -ceq 'gitleaks') ($r.Calls -join ' ## ')
    $r = Invoke-Check '' 'pre-commit'
    Check 'rote Commit-Stufe -> Exit 1, Push-Stufe laeuft trotzdem' ($r.Code -eq 1 -and $r.Calls.Count -eq 2) "Exit $($r.Code)"
    $r = Invoke-Check '' 'pre-push'
    Check 'rote Push-Stufe -> Exit 1' ($r.Code -eq 1) "Exit $($r.Code)"
} finally {
    $env:PATH = $savedPath; $env:SKIP = $savedSkip; $env:FAKE_PREK_RED = $savedRed
    Remove-Item -Recurse -Force $fake
}
if ($fails -eq 0) { Write-Host 'PASS pre_push_check_test' -ForegroundColor Green } else { Write-Host "FAIL pre_push_check_test ($fails)" -ForegroundColor Red }
exit $fails
