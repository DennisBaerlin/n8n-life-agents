#Requires -Version 5.1
# test_stack_test.ps1 -- die Bausteine des Test-Verbunds (scripts/lib/test_stack.ps1) ohne Docker: Projektname, Namen, Ports,
# Daten-Volumes aus runtime.sh, Schnappschuss-Schluessel, Vertrag der Kern-Ausgabe, TEST_*-Zuordnung, Zusatz-Zeilen der
# Antwort-Datei, Abbau-Abgleich. Den echten Weg (kalt, -Reset per Schnappschuss, -Down) beweist bootstrap_test_stack.ps1 selbst.
# Usage:  .\scripts\dev\test_stack_test.ps1     Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $repo 'scripts\lib\test_stack.ps1')
$failed = 0
function Assert-That([bool]$Ok, [string]$Name) {
    if ($Ok) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name" -ForegroundColor Red; $script:failed++ }
}
function Test-Throws([scriptblock]$Block) { try { & $Block | Out-Null; return $false } catch { return $true } }

# --- Projektname: klein, kurz, nie der Standardname einer echten Installation -------------------------------------------
Assert-That (-not (Test-Throws { Assert-TestStackProject 's4t0' })) 'Projekt s4t0 gilt'
foreach ($bad in @('', 'lifeagents', 'S4T0', 's4 t0', '-s4', 's4t0_x', ('a' * 41))) {
    Assert-That (Test-Throws { Assert-TestStackProject $bad }) "Projekt '$bad' wird abgelehnt"
}
$n = Get-TestStackNames 's4t0'
Assert-That ($n.Image -eq 's4t0-master:wt' -and $n.Master -eq 's4t0-master' -and $n.Core -eq 's4t0-core' -and $n.Bridge -eq 's4t0-testbridge' -and $n.Postgres -eq 's4t0-postgres') 'Namen aus dem Projekt'
Assert-That ((& $n.Volume 'pgdata') -eq 's4t0_pgdata' -and (& $n.Snapshot 'pgdata') -eq 's4t0snap_pgdata') 'Volume- und Schnappschuss-Namen'

# --- Ports: Bruecke = N8NTEST_PORT, der Kern sucht in den neun Ports danach ---------------------------------------------
$p = Get-TestStackPorts '57500'
Assert-That ($p.Bridge -eq 57500 -and $p.CoreRange -eq '57501-57509') 'Ports aus N8NTEST_PORT'
foreach ($bad in @('', 'x', '80', '65530')) { Assert-That (Test-Throws { Get-TestStackPorts $bad }) "Port '$bad' wird abgelehnt" }

# --- Daten-Volumes: aus runtime.sh gelesen, nicht abgeschrieben ----------------------------------------------------------
$rt = [System.IO.File]::ReadAllText((Join-Path $repo 'provisioning\lib\runtime.sh'))
$vols = Get-TestStackStateVolumes $rt
Assert-That ($vols -contains 'pgdata' -and $vols -contains 'var_la' -and $vols -contains 'n8n_home' -and $vols.Count -ge 5) 'Daten-Volumes aus runtime.sh'
Assert-That (Test-Throws { Get-TestStackStateVolumes 'kein solcher text' }) 'fehlende LA_STATE_VOLUMES-Zeile = Abbruch'

# --- Schnappschuss-Schluessel: jede Eingabe zaehlt, kein Wert im Klartext -------------------------------------------------
$k1 = Get-TestStackSnapshotKey -ImageId 'sha256:aa' -AnswersText "A=geheim`n" -ComposeText 'c'
Assert-That ($k1 -match '^[0-9a-f]{64}$') 'Schluessel = 64 Hex'
Assert-That ($k1 -eq (Get-TestStackSnapshotKey -ImageId 'sha256:aa' -AnswersText "A=geheim`n" -ComposeText 'c')) 'Schluessel stabil'
Assert-That ($k1 -ne (Get-TestStackSnapshotKey -ImageId 'sha256:ab' -AnswersText "A=geheim`n" -ComposeText 'c')) 'anderes Abbild = anderer Schluessel'
Assert-That ($k1 -ne (Get-TestStackSnapshotKey -ImageId 'sha256:aa' -AnswersText "A=anders`n" -ComposeText 'c')) 'andere Antworten = anderer Schluessel'
Assert-That ($k1 -ne (Get-TestStackSnapshotKey -ImageId 'sha256:aa' -AnswersText "A=geheim`n" -ComposeText 'd')) 'andere compose.yml = anderer Schluessel'

# --- Kern-Ausgabe: nur JSON v1, genau ein result ---------------------------------------------------------------------------
$ok = @('{"v":1,"type":"progress","step":"lock"}', '{"v":1,"type":"result","ok":true,"ports":{"edge":57501,"wizard":57502}}')
$r = Read-TestStackCoreResult $ok
Assert-That ($r.ok -eq $true -and $r.ports.edge -eq 57501) 'Kern-Ergebnis gelesen'
Assert-That ((Read-TestStackCoreResult @('{"v":1,"type":"result","ok":false,"reason":"busy"}')).reason -eq 'busy') 'ok:false wird gelesen, nicht geworfen'
Assert-That (Test-Throws { Read-TestStackCoreResult @('{"v":1,"type":"progress"}') }) 'ohne result = Abbruch'
Assert-That (Test-Throws { Read-TestStackCoreResult ($ok + $ok[1]) }) 'zwei result = Abbruch'
Assert-That (Test-Throws { Read-TestStackCoreResult (@('Text fuer Menschen') + $ok) }) 'Zeile ohne JSON v1 = Abbruch'
Assert-That (Test-Throws { Read-TestStackCoreResult @('{"v":2,"type":"result","ok":true}') }) 'v2 = Abbruch'

# --- TEST_*-Zuordnung (wie bootstrap_test_n8n.ps1) und Zusatz-Zeilen ------------------------------------------------------
$map = Get-TestInstallEnvMap $repo
Assert-That ($map['TEST_TELEGRAM_BOT_TOKEN'] -eq 'TELEGRAM_BOT_TOKEN' -and $map['TEST_TELEGRAM_CHAT_ID'] -eq 'OWNER_CHAT_ID' -and $map['TEST_HARNESS_SECRET'] -eq 'TEST_HARNESS_SECRET') 'feste TEST_*-Zuordnung'
Assert-That ($map['TEST_ADZUNA_APP_ID'] -eq 'ADZUNA_APP_ID') 'Paket-Zugang aus dem Manifest'
$extra = ConvertTo-TestStackExtra -Map $map -Values @{ TEST_TELEGRAM_BOT_TOKEN = '1:invented'; TEST_GOOGLE_API_KEY = ''; UNRELATED = 'x' } -HitlChatApproval -FullDeploy -SerialTools '0'
$lines = @($extra -split "`n" | Where-Object { $_ })
Assert-That ($lines -contains 'TELEGRAM_BOT_TOKEN=1:invented') 'gesetzter TEST_*-Wert kommt als Kern-Schluessel'
Assert-That (-not ($lines -match '^GOOGLE_API_KEY=') -and -not ($lines -match 'UNRELATED')) 'leere und fremde Werte fehlen'
Assert-That ($lines -contains 'LIFEAGENTS_HITL_CHAT_APPROVAL=true' -and $lines -contains 'LIFEAGENTS_DEPLOY_FULL=1' -and $lines -contains 'LLM_GATEWAY_SERIAL_TOOLS=0') 'Schalter als Zeilen'
$plain = @((ConvertTo-TestStackExtra -Map $map -Values @{}) -split "`n" | Where-Object { $_ })
Assert-That ($plain.Count -eq 0) 'ohne Werte und Schalter keine Zeile (Vorgaben stehen in render_ci_answers.js)'
Assert-That (Test-Throws { ConvertTo-TestStackExtra -Map $map -Values @{} -SerialTools '2' }) 'SerialTools nur 0 oder 1'
Assert-That (Test-Throws { ConvertTo-TestStackExtra -Map $map -Values @{ TEST_TELEGRAM_BOT_TOKEN = "a`nB=1" } }) 'Zeilenumbruch im Wert = Abbruch'

# --- Abbau-Abgleich: nur Eigenes darf fehlen -----------------------------------------------------------------------------
$before = @('s4t0-master', 's4t0_pgdata', 's4t0snap_pgdata', 'fremd-n8n', 'n8nio/n8n:2.45.7', 's4t0-master:wt', 's4t0x-master')
$after  = @('fremd-n8n', 'n8nio/n8n:2.45.7', 's4t0x-master')
Assert-That (@(Compare-TestStackTeardown -Project 's4t0' -Before $before -After $after).Count -eq 0) 'nur eigene Objekte weg = kein Fund'
$f = @(Compare-TestStackTeardown -Project 's4t0' -Before $before -After @('fremd-n8n', 's4t0x-master'))
Assert-That ($f.Count -eq 1 -and $f[0] -match 'n8nio/n8n') 'fehlendes fremdes Abbild = Fund'
$f = @(Compare-TestStackTeardown -Project 's4t0' -Before $before -After @('fremd-n8n', 'n8nio/n8n:2.45.7'))
Assert-That ($f.Count -eq 1 -and $f[0] -match 's4t0x-master') 'Nachbar mit gleichem Anfang (s4t0x) zaehlt als fremd'
$f = @(Compare-TestStackTeardown -Project 's4t0' -Before $before -After ($after + 's4t0_pgdata'))
Assert-That ($f.Count -eq 1 -and $f[0] -match 'blieb') 'eigener Rest nach dem Abbau = Fund'

Write-Host "test_stack_test: $failed Fehler."
exit $failed
