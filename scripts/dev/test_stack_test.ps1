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

# Ein Projekt, das auf 'snap' endet, haette als Daten-Volume den Namen eines Schnappschusses (x + snap_pgdata = xsnap_pgdata).
Assert-That (Test-Throws { Assert-TestStackProject 's4t0snap' }) "Projekt 's4t0snap' wird abgelehnt (Schnappschuss-Namen)"

# --- Ports: Bruecke = N8NTEST_PORT, die Spanne des Kerns ausdruecklich (N8NTEST_STACK_PORTS), nie abgeleitet -------------
# Abgeleitet (Port+1…) traefe den Port eines Nachbarn oder den des -b-Substrats von run_free_gates -Parallel.
$p = Get-TestStackPorts -Port '57500' -CoreRange '57510-57519'
Assert-That ($p.Bridge -eq 57500 -and $p.CoreRange -eq '57510-57519') 'Bruecke und Kern-Spanne aus den Umgebungswerten'
foreach ($bad in @('', 'x', '80', '65530')) { Assert-That (Test-Throws { Get-TestStackPorts -Port $bad -CoreRange '57510-57519' }) "Port '$bad' wird abgelehnt" }
foreach ($bad in @('', '57510', '57510-57510', '57519-57510', '57499-57501', 'a-b')) {
    Assert-That (Test-Throws { Get-TestStackPorts -Port '57500' -CoreRange $bad }) "Kern-Spanne '$bad' wird abgelehnt (fehlt, zu klein, verkehrt oder mit dem Bruecken-Port)"
}

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
# Eigen = Container mit dem Install-Etikett (vom Aufrufer gelesen) + Volumes <p>_* / <p>snap_* + Abbild <p>-master:wt; andere
# Objekte mit demselben Anfang (s4t0-dbtest, s4t0-wizardtest:…) gehoeren der Session, nicht dem Verbund.
$img = 's4t0-master:wt@<none>'
$before = @('s4t0-master', 's4t0-testbridge', 's4t0_pgdata', 's4t0snap_pgdata', 'fremd-n8n', 'n8nio/n8n:<none>@sha256:aa', $img, 's4t0x-master', 's4t0-dbtest', 's4t0-wizardtest:x@sha256:bb')
$labeled = @('s4t0-master', 's4t0-testbridge')
$after  = @('fremd-n8n', 'n8nio/n8n:<none>@sha256:aa', 's4t0x-master', 's4t0-dbtest', 's4t0-wizardtest:x@sha256:bb')
Assert-That (@(Compare-TestStackTeardown -Project 's4t0' -Before $before -After $after -Labeled $labeled).Count -eq 0) 'nur Objekte des Verbunds weg, Session-Objekte bleiben = kein Fund'
$f = @(Compare-TestStackTeardown -Project 's4t0' -Before $before -After ($after | Where-Object { $_ -notmatch 'n8nio' }) -Labeled $labeled)
Assert-That ($f.Count -eq 1 -and $f[0].Text -match 'n8nio/n8n' -and $f[0].Severity -eq 'error') 'fehlendes fremdes Abbild (per Digest, ohne Tag) = Fehler'
$f = @(Compare-TestStackTeardown -Project 's4t0' -Before $before -After ($after | Where-Object { $_ -ne 's4t0-dbtest' }) -Labeled $labeled)
Assert-That ($f.Count -eq 1 -and $f[0].Text -match 's4t0-dbtest' -and $f[0].Severity -eq 'hint') 'Session-Container mit gleichem Anfang zaehlt als fremd (fehlt er, ein Hinweis: ein Nachbar baut oft zugleich ab)'
$f = @(Compare-TestStackTeardown -Project 's4t0' -Before $before -After ($after | Where-Object { $_ -ne 's4t0x-master' }) -Labeled $labeled)
Assert-That ($f.Count -eq 1 -and $f[0].Text -match 's4t0x-master' -and $f[0].Severity -eq 'hint') 'Nachbar-Projekt mit gleichem Anfang (s4t0x) zaehlt als fremd'
$f = @(Compare-TestStackTeardown -Project 's4t0' -Before $before -After ($after + 's4t0_pgdata' + 's4t0-testbridge') -Labeled $labeled)
Assert-That ($f.Count -eq 2 -and @($f | Where-Object { $_.Severity -eq 'error' -and $_.Text -match 'blieb' }).Count -eq 2) 'eigener Rest nach dem Abbau (Volume, etikettierter Container) = Fund'

# --- Etikett lesen: fehlendes Volume ist $null, ein gestoertes Docker ist ein Fehler (nie „gibt es nicht“) ------------------
Assert-That ((ConvertFrom-TestStackLabelResult -Code 0 -Output @('{"io.lifeagents.install":"s4t0"}') -Label 'io.lifeagents.install') -eq 's4t0') 'Etikett gelesen'
Assert-That ((ConvertFrom-TestStackLabelResult -Code 0 -Output @('null') -Label 'x') -eq '') 'Volume ohne Etiketten = leer'
Assert-That ($null -eq (ConvertFrom-TestStackLabelResult -Code 1 -Output @('Error response from daemon: get s4t0_pgdata: no such volume') -Label 'x')) 'fehlendes Volume = $null'
Assert-That (Test-Throws { ConvertFrom-TestStackLabelResult -Code 1 -Output @('error during connect: The system cannot find the file specified.') -Label 'x' }) 'Docker-Fehler = Abbruch, nicht „fehlt“'

# --- Platz-Zaehlung: nur der eigene Name zaehlt nicht mit, Substrate mit gleichem Anfang schon ------------------------------
$others = @(Select-TestStackOtherSubstrates -Running @('s4t0', 's4t0-b', 's4w-n8ntest') -Own 's4t0')
Assert-That ($others.Count -eq 2 -and $others -contains 's4t0-b') 'Substrat s4t0-b (run_free_gates -Parallel) zaehlt als anderer Platz'

# --- PS 5.1 reicht ein " innerhalb eines Arguments nicht an native Programme weiter (Vorlage/Skript zerfaellt still) ------
# Darum in test_stack.ps1 kein " in einem Literal, das als Docker-Argument geht: weder `" noch '…"…'. Ausnahme: der eine
# Quoter in Invoke-TestStackProcess (Start-Process bekommt eine fertige Zeile).
$text = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\lib\test_stack.ps1'))
$src = $text -split "`r?`n"
$argLines = @{}
for ($i = 0; $i -lt $src.Count; $i++) { if ($src[$i] -match 'Invoke-Native docker|^\s*\$sh = |^\s*\$a \+= ') { $argLines[$i + 1] = $true } }
Assert-That ($argLines.Count -ge 15)"Pruefung sieht die Docker-Aufrufe ($($argLines.Count) Zeilen)"
$bad = @([System.Management.Automation.PSParser]::Tokenize($text, [ref]$null) |
    Where-Object { $_.Type -eq 'String' -and $argLines.ContainsKey($_.StartLine) -and $_.Content.Contains('"') } |
    ForEach-Object { $_.StartLine } | Sort-Object -Unique)
Assert-That ($bad.Count -eq 0) "kein doppeltes Anfuehrungszeichen in Docker-Argumenten von test_stack.ps1 (Zeilen: $($bad -join ', '))"

Write-Host "test_stack_test: $failed Fehler."
exit $failed
