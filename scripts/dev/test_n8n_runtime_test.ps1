#Requires -Version 5.1
# test_n8n_runtime_test.ps1 -- die Treiber-Bibliothek (scripts/dev/test_n8n_state.ps1) waehlt den Weg je Unterbau aus der
# Zustandsdatei: classic = alles im einen systemd-Container (Argumente byte-gleich zu vorher), compose = der Docker-Verbund
# (psql im Postgres-Container, Gateway als eigener Container, Attrappen-Logs als Datei auf dem Rechner).
# Kein Docker, kein Netz: geprueft werden die reinen Bausteine und die Datei-Wege.
# Usage:  .\scripts\dev\test_n8n_runtime_test.ps1     Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $repo 'scripts\dev\test_n8n_state.ps1')
$failed = 0
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Assert-That([bool]$Ok, [string]$Name) {
    if ($Ok) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}
function Assert-Throws([scriptblock]$Block, [string]$Name) {
    $threw = $false; try { & $Block | Out-Null } catch { $threw = $true }
    Assert-That $threw $Name
}

$classic = [pscustomobject]@{ url = 'http://127.0.0.1:5800'; container = 'probe-n8n'; api_key = 'k' }
$compose = [pscustomobject]@{ url = 'http://127.0.0.1:57800'; container = 'probe-master'; api_key = 'k'; runtime = 'compose'; project = 'probe' }

Write-Host 'Ziel je Unterbau'
$t = ConvertTo-TestN8nTarget -State $classic
Assert-That ($t.Runtime -eq 'classic' -and $t.Master -eq 'probe-n8n' -and $t.Postgres -eq 'probe-n8n' -and $t.Gateway -eq 'probe-n8n') 'classic: alle Rollen im einen Container'
$t = ConvertTo-TestN8nTarget -State $compose
Assert-That ($t.Runtime -eq 'compose' -and $t.Master -eq 'probe-master' -and $t.Postgres -eq 'probe-postgres' -and $t.Gateway -eq 'probe-gateway') 'compose: master, postgres, gateway je eigener Container'
Assert-That ($t.MockLogDir -eq (Join-Path (Get-TestStackLogDir 'probe') 'mocks')) 'compose: Attrappen-Logs im Log-Ordner des Verbunds (eine Adresse: Get-TestStackLogDir)'
Assert-Throws { ConvertTo-TestN8nTarget -State ([pscustomobject]@{ url = 'u'; container = 'c'; runtime = 'compose' }) } 'compose ohne project = Abbruch'
Assert-Throws { ConvertTo-TestN8nTarget -State ([pscustomobject]@{ url = 'u'; container = 'c'; runtime = 'lxc' }) } 'unbekannter Unterbau = Abbruch'
$t = Get-TestN8nTarget -Container 'other-n8n' -State $compose
Assert-That ($t.Runtime -eq 'classic' -and $t.Postgres -eq 'other-n8n') 'fremder Container (nicht der des Zustands) = classic auf genau diesem Container'
$t = Get-TestN8nTarget -Container 'probe-master' -State $compose
Assert-That ($t.Runtime -eq 'compose') 'Container des Zustands = Ziel aus dem Zustand'

Write-Host 'psql'
$tc = ConvertTo-TestN8nTarget -State $classic
$a = Get-TestN8nPsqlDockerArgs -Target $tc -Database 'n8n' -PsqlArgs @('-tAc', 'SELECT 1')
Assert-That (($a -join '|') -eq 'exec|probe-n8n|runuser|-u|postgres|--|psql|--no-psqlrc|-X|-v|ON_ERROR_STOP=1|-d|n8n|-tAc|SELECT 1') 'classic: runuser-Weg unveraendert'
$tp = ConvertTo-TestN8nTarget -State $compose
$a = Get-TestN8nPsqlDockerArgs -Target $tp -Database 'n8n' -PsqlArgs @('-tAc', 'SELECT 1')
Assert-That (($a -join '|') -eq 'exec|-u|postgres|probe-postgres|psql|--no-psqlrc|-X|-v|ON_ERROR_STOP=1|-d|n8n|-tAc|SELECT 1') 'compose: docker exec -u postgres im Postgres-Container'

Write-Host 'Gateway'
Assert-That (((Get-TestLlmGatewayRestartArgs -Target $tc) -join '|') -eq 'exec|probe-n8n|systemctl|restart|lifeagents-llm-gateway') 'classic: systemctl restart'
Assert-That (((Get-TestLlmGatewayRestartArgs -Target $tp) -join '|') -eq 'restart|probe-gateway') 'compose: docker restart <p>-gateway'
$lines = @(
    '2026-11-20T10:00:00.100000000Z gateway listening on 127.0.0.1:8090',
    '2026-11-20T10:00:01.000000000Z {"t":"x","ev":"usage","id":1,"model":"m","input_tokens":5}',
    '2026-11-20T10:00:02.000000000Z {"t":"x","ev":"usage","id":2,"model":"m","input_tokens":7}',
    '2026-11-20T10:00:03.000000000Z {"t":"x","ev":"other"}')
Assert-That ((Get-LlmUsageCursorFromLogLines -Lines $lines) -eq '2026-11-20T10:00:03.000000000Z') 'compose: Cursor = Zeitstempel der letzten Zeile'
Assert-That ($null -eq (Get-LlmUsageCursorFromLogLines -Lines @())) 'compose: ohne Zeilen kein Cursor'
$u = @(Select-LlmUsageFromLogLines -Lines $lines -AfterCursor '2026-11-20T10:00:01.000000000Z')
Assert-That ($u.Count -eq 1 -and $u[0].id -eq 2) 'compose: nur usage-Zeilen nach dem Cursor'
$u = @(Select-LlmUsageFromLogLines -Lines $lines)
Assert-That ($u.Count -eq 2 -and $u[0].id -eq 1) 'compose: ohne Cursor alle usage-Zeilen, aelteste zuerst'

Write-Host 'Attrappen-Logs'
Assert-That ((Resolve-TestMockLogPath -Target $tc -LogFile '/tmp/mock_telegram.jsonl') -eq '/tmp/mock_telegram.jsonl') 'classic: Log-Pfad im Container unveraendert'
$hostLog = Resolve-TestMockLogPath -Target $tp -LogFile '/tmp/mock_telegram.jsonl'
Assert-That ($hostLog -eq (Join-Path $tp.MockLogDir 'mock_telegram.jsonl')) 'compose: gleicher Dateiname im Log-Ordner auf dem Rechner'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('tnr_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $f = Join-Path $tmp 'mock_llm.jsonl'
    Assert-That (@(Read-TestMockLogFile -Path $f).Count -eq 0) 'fehlende Log-Datei = keine Eintraege'
    [System.IO.File]::WriteAllText($f, "{`"a`":1}`n`nkein json`n{`"a`":2,`"t`":`"Grüße`"}`n", $utf8)
    $r = @(Read-TestMockLogFile -Path $f)
    Assert-That ($r.Count -eq 2 -and $r[1].a -eq 2 -and $r[1].t -eq 'Grüße') 'Log-Datei: JSON-Zeilen in Reihenfolge, Leer- und Fremdzeilen uebersprungen, UTF-8'
    # Die Attrappe haelt die Datei zum Anhaengen offen (O_APPEND): Lesen und Leeren muessen das vertragen.
    $fs = New-Object System.IO.FileStream($f, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        Assert-That (@(Read-TestMockLogFile -Path $f).Count -eq 2) 'Log-Datei lesbar, waehrend ein Schreiber sie offen haelt'
        Clear-TestMockLogFile -Path $f
    } finally { $fs.Dispose() }
    Assert-That ((Get-Item $f).Length -eq 0) 'Leeren kuerzt die Datei auf 0'
    Clear-TestMockLogFile -Path (Join-Path $tmp 'fehlt.jsonl')
    Assert-That (-not (Test-Path (Join-Path $tmp 'fehlt.jsonl'))) 'Leeren einer fehlenden Datei legt keine an'

    Write-Host 'Zustands-Block'
    $sf = Join-Path $tmp 'state.json'
    [System.IO.File]::WriteAllText($sf, '{"url":"u","container":"c","mock_llm":{"port":1}}', $utf8)
    Set-TestN8nStateBlock -StateFile $sf -Name 'mock_telegram' -Block ([ordered]@{ port = 8089; nested = @{ x = @{ y = 1 } } })
    $s = [System.IO.File]::ReadAllText($sf, $utf8) | ConvertFrom-Json
    Assert-That ($s.url -eq 'u' -and $s.mock_llm.port -eq 1 -and $s.mock_telegram.port -eq 8089 -and $s.mock_telegram.nested.x.y -eq 1) 'Block setzen laesst die uebrigen Felder stehen'
    Set-TestN8nStateBlock -StateFile $sf -Name 'mock_llm' -Block $null
    $s = [System.IO.File]::ReadAllText($sf, $utf8) | ConvertFrom-Json
    Assert-That (-not $s.PSObject.Properties['mock_llm'] -and $s.mock_telegram.port -eq 8089) 'Block $null entfernt nur diesen Block'
    $raw = [System.IO.File]::ReadAllBytes($sf)
    Assert-That (-not ($raw[0] -eq 0xEF -and $raw[1] -eq 0xBB)) 'Zustandsdatei ohne BOM'
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

Write-Host 'Bot-Token'
Assert-That ((Get-TestBotToken -Target $tp) -eq $script:TestStackMockAnswers.TELEGRAM_BOT_TOKEN) 'compose: das erfundene Token der Installation (eine Adresse: TestStackMockAnswers)'

Write-Host "test_n8n_runtime_test: $failed Fehler."
exit $failed
