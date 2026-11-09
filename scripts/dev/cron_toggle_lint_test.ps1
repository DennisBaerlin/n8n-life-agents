#Requires -Version 5.1
# Fehlfall von scripts/cron_toggle_lint.ps1 Regel (k): ein neuer Telegram-sendender Cron ohne Budget-Weg muss rot werden.
# Legt einen Wegwerf-Workflow im Temp-Ordner an, faehrt den Lint einmal ohne und einmal mit ihm. Kein Docker.
# Usage: .\scripts\dev\cron_toggle_lint_test.ps1   Exit-Code 0 = ok.
$ErrorActionPreference = 'Stop'
$lint = Join-Path $PSScriptRoot '..\cron_toggle_lint.ps1'
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ctl_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $json = '{"name":"x.cron_new","nodes":[{"type":"n8n-nodes-base.telegram","parameters":{"text":"__CFG_SCHEDULE_ZZ_UNBUDGETED__"}}]}'
    [System.IO.File]::WriteAllText((Join-Path $dir 'abcdefghijklmnop-x.cron_new.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    $out = & powershell.exe -NoProfile -File $lint -ExtraWorkflowDir $dir
    if ($LASTEXITCODE -eq 0 -or -not (($out -join ' ') -match 'zz_unbudgeted')) { Write-Host "FAIL: Lint hat den Cron ohne Budget-Weg nicht gemeldet: $out" -ForegroundColor Red; exit 1 }
    Write-Host 'PASS cron_toggle_lint_test' -ForegroundColor Green
    exit 0
} finally { Remove-Item -Recurse -Force $dir }
