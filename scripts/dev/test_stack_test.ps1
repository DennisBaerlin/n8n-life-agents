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
$want = @('TEST_HARNESS_HEADER=X-Test-Auth', 'LIFEAGENTS_HITL_CHAT_APPROVAL=false', 'LIFEAGENTS_DEPLOY_FULL=0', 'LLM_GATEWAY_KEEPALIVE_HOURS=0', 'BOT_PROFILE_PHOTO=0', 'TELEGRAM_WEBHOOK_TAKEOVER=1', 'CRON_DISABLE=refresh_fx_rates')
Assert-That (($plain -join '|') -eq ($want -join '|')) 'ohne Werte nur die Test-Schalter mit ihren Vorgaben, in fester Reihenfolge'

# --- Eine Adresse fuer TEST_*-Zuordnung und Test-Schalter: beide Bootstraps rufen scripts/lib/test_install_env.ps1 -----------
$sw = Get-TestDevSwitches -HitlChatApproval -FullDeploy -SerialTools '1'
Assert-That ((@($sw.Keys) -join ',') -eq 'TEST_HARNESS_HEADER,LIFEAGENTS_HITL_CHAT_APPROVAL,LIFEAGENTS_DEPLOY_FULL,LLM_GATEWAY_KEEPALIVE_HOURS,LLM_GATEWAY_SERIAL_TOOLS,BOT_PROFILE_PHOTO,TELEGRAM_WEBHOOK_TAKEOVER,CRON_DISABLE') 'Test-Schalter: Reihenfolge wie im klassischen Bootstrap, SerialTools nur wenn gesetzt'
Assert-That ($sw['LIFEAGENTS_HITL_CHAT_APPROVAL'] -eq 'true' -and $sw['LIFEAGENTS_DEPLOY_FULL'] -eq '1' -and $sw['LLM_GATEWAY_SERIAL_TOOLS'] -eq '1') 'Schalter-Werte aus den Parametern'
# CRON_DISABLE nennt nur cron_enable-Schluessel, die genau ein Manifest deklariert: ein umbenannter Schluessel liesse den UPDATE des Seeds
# still ins Leere laufen, und die Test-Installationen holten wieder echte Kurse.
foreach ($k in @(([string]$sw['CRON_DISABLE']) -split '[ ,]+' | Where-Object { $_ })) {
    $owners = @(Get-ChildItem (Join-Path $repo 'packages') -Directory | Where-Object {
        $m = Join-Path $_.FullName 'manifest.json'
        (Test-Path $m) -and (($j = [System.IO.File]::ReadAllText($m) | ConvertFrom-Json).config -and $j.config.cron_enable -and ($j.config.cron_enable.PSObject.Properties.Name -contains $k)) })
    Assert-That ($owners.Count -eq 1) "CRON_DISABLE: '$k' ist cron_enable-Schluessel in genau einem Manifest"
}
Assert-That (@(([string]$sw['CRON_DISABLE']) -split '[ ,]+' | Where-Object { $_ }).Count -ge 1) 'CRON_DISABLE: mindestens ein Schluessel (sonst prueft die Schleife davor nichts)'
$classic = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\dev\bootstrap_test_n8n.ps1'))
$envFile = @(ConvertTo-TestEnvFileLines -Map $map -Values @{ TEST_TELEGRAM_BOT_TOKEN = "1:it's-invented"; TEST_GOOGLE_API_KEY = '' })
Assert-That ($envFile -contains "TELEGRAM_BOT_TOKEN='1:it'\''s-invented'" -and -not ($envFile -match '^GOOGLE_API_KEY=')) 'Env-Datei des Klassikers: gesetzte TEST_*-Werte shell-gequotet, leere fehlen'
Assert-That ($envFile -contains "TEST_HARNESS_HEADER='X-Test-Auth'" -and $envFile -contains "BOT_PROFILE_PHOTO='0'" -and $envFile -contains "TELEGRAM_WEBHOOK_TAKEOVER='1'" -and $envFile -contains "LLM_GATEWAY_KEEPALIVE_HOURS='0'" -and $envFile -contains "CRON_DISABLE='refresh_fx_rates'") 'Env-Datei des Klassikers traegt die Test-Schalter'
Assert-That ($classic -match 'ConvertTo-TestEnvFileLines' -and $classic -notmatch 'envLines\.Add\(') 'klassischer Bootstrap baut seine Env-Datei nur ueber die Bibliothek'
$stackSrc = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\dev\bootstrap_test_stack.ps1'))
Assert-That ($stackSrc -match 'ConvertTo-TestStackExtra' -and $stackSrc -match '-ExtraText \$extra') 'Verbund reicht die Zusatz-Zeilen (Werte + Schalter) an die Antwort-Datei'
Assert-That ($classic -notmatch "'TEST_TELEGRAM_BOT_TOKEN'\s*=" -and $classic -notmatch 'TELEGRAM_WEBHOOK_TAKEOVER=1' -and $classic -notmatch 'X-Test-Auth') 'klassischer Bootstrap haelt keine eigene Kopie der Zuordnung oder der Schalter'
$js = [System.IO.File]::ReadAllText((Join-Path $repo 'tests\wizard\render_ci_answers.js'))
Assert-That ($js -notmatch 'X-Test-Auth|TELEGRAM_WEBHOOK_TAKEOVER') 'render_ci_answers.js haelt keine eigene Kopie der Test-Schalter'
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

# --- Attrappen (tests/mock_pod/start_mocks.sh): feste Ziele ersetzen .env-Werte, Weichen nur aus der Liste des Kerns ---------
$ov = [ordered]@{ PAPERLESS_API_TOKEN = 'mock-paperless-token'; CONFIG_GENERAL_PAPERLESS_URL = 'http://127.0.0.1:8092' }
$x = @((ConvertTo-TestStackExtra -Map $map -Values @{ TEST_PAPERLESS_API_TOKEN = 'invented-from-env'; TEST_HARNESS_SECRET = 'h' } -Override $ov) -split "`n" | Where-Object { $_ })
Assert-That (@($x -match '^PAPERLESS_API_TOKEN=').Count -eq 1 -and $x -contains 'PAPERLESS_API_TOKEN=mock-paperless-token' -and $x -contains 'CONFIG_GENERAL_PAPERLESS_URL=http://127.0.0.1:8092' -and $x -contains 'TEST_HARNESS_SECRET=h') 'Override ersetzt den .env-Wert (ein Schluessel einmal) und ergaenzt neue'
$core = [System.IO.File]::ReadAllText((Join-Path $repo 'provisioning\lib\stack_core.sh'))
$sw = @(Get-TestStackSwitchNames $core)
Assert-That ($sw -contains 'LIFEAGENTS_TELEGRAM_API' -and $sw -contains 'LIFEAGENTS_LLM_UPSTREAM') 'Weichen-Namen aus stack_core.sh (SC_TEST_SWITCHES)'
Assert-That (Test-Throws { Get-TestStackSwitchNames 'kein solcher text' }) 'fehlende SC_TEST_SWITCHES-Zeile = Abbruch'
Assert-That (Test-Throws { Assert-TestStackSwitches -Names @('LIFEAGENTS_DIR') -Allowed $sw }) 'Weiche ausserhalb der Liste = Abbruch, bevor etwas laeuft'
$rows = @('s4t0-n8n|com.docker.compose.project=s4t0,io.lifeagents.install=s4t0', 's4t0-tgmock|io.lifeagents.install=s4t0,lifeagents.worktree=C:/x',
          's4t0-testbridge|io.lifeagents.install=s4t0,lifeagents.substrate=n8n-bridge,lifeagents.worktree=C:/x', 's4t0-core|io.lifeagents.install=s4t0',
          's4t0-core-next|io.lifeagents.install=s4t0', 's4t0-patchsrc|io.lifeagents.install=s4t0', 'fremd|io.lifeagents.install=other,lifeagents.worktree=C:/x')
$side = @(Select-TestStackSideContainers -Rows $rows -Project 's4t0')
Assert-That (($side -join ',') -eq 's4t0-testbridge,s4t0-tgmock') 'Neben-Container: Install- und Worktree-Etikett, ohne Compose-Projekt; nie Kurzlaeufe des Kerns, nie Fremdes'
Assert-That ($script:TestStackMockAnswers['ANTHROPIC_API_KEY'] -and $script:TestStackMockAnswers['ANTHROPIC_API_KEY'] -match 'test-fake' -and $script:TestStackMockAnswers['TELEGRAM_BOT_TOKEN'] -match 'invented') 'Verbund: Bot-Token und KI-Schluessel erfunden (kein echter Zugang in der Installation)'

# --- Etikett lesen: fehlendes Volume ist $null, ein gestoertes Docker ist ein Fehler (nie „gibt es nicht“) ------------------
Assert-That ((ConvertFrom-TestStackLabelResult -Code 0 -Output @('{"io.lifeagents.install":"s4t0"}') -Label 'io.lifeagents.install') -eq 's4t0') 'Etikett gelesen'
Assert-That ((ConvertFrom-TestStackLabelResult -Code 0 -Output @('null') -Label 'x') -eq '') 'Volume ohne Etiketten = leer'
Assert-That ($null -eq (ConvertFrom-TestStackLabelResult -Code 1 -Output @('Error response from daemon: get s4t0_pgdata: no such volume') -Label 'x')) 'fehlendes Volume = $null'
Assert-That (Test-Throws { ConvertFrom-TestStackLabelResult -Code 1 -Output @('error during connect: The system cannot find the file specified.') -Label 'x' }) 'Docker-Fehler = Abbruch, nicht „fehlt“'

# --- PS 5.1 reicht ein " innerhalb eines Arguments nicht an native Programme weiter (Vorlage/Skript zerfaellt still) ------
# Darum in test_stack.ps1 kein " in einem Literal, das als Docker-Argument geht: weder `" noch '…"…'. Ausnahme: der eine
# Quoter in Invoke-NativeStdinFile (der Prozess bekommt eine fertige Zeile; scripts/lib/native_process.ps1).
$text = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\lib\test_stack.ps1'))
$src = $text -split "`r?`n"
$argLines = @{}
for ($i = 0; $i -lt $src.Count; $i++) { if ($src[$i] -match 'Invoke-Native docker|^\s*\$sh = |^\s*\$a \+= ') { $argLines[$i + 1] = $true } }
Assert-That ($argLines.Count -ge 15)"Pruefung sieht die Docker-Aufrufe ($($argLines.Count) Zeilen)"
$bad = @([System.Management.Automation.PSParser]::Tokenize($text, [ref]$null) |
    Where-Object { $_.Type -eq 'String' -and $argLines.ContainsKey($_.StartLine) -and $_.Content.Contains('"') } |
    ForEach-Object { $_.StartLine } | Sort-Object -Unique)
Assert-That ($bad.Count -eq 0) "kein doppeltes Anfuehrungszeichen in Docker-Argumenten von test_stack.ps1 (Zeilen: $($bad -join ', '))"

# --- Skripte, die der Linux-Job backup-roundtrip (free-gates.yml) fuehrt, nennen keinen Windows-Programmnamen -----------------------
# Der Job faehrt backup_roundtrip_test.ps1 unter PowerShell 7 auf Linux: dort gibt es kein powershell.exe ("The term 'powershell.exe' is
# not recognized"). Kindaufrufe laufen ueber den laufenden Host ((Get-Process -Id $PID).Path). Geprueft werden Befehle, Argumente und
# Zeichenketten (Tokenizer, keine Kommentare) in dem Test, dem Bootstrap und allen Bibliotheken unter scripts\lib, die sie laden.
$linuxScripts = @(Get-ChildItem (Join-Path $repo 'scripts\lib') -Filter '*.ps1') + @(Get-Item (Join-Path $repo 'scripts\dev\backup_roundtrip_test.ps1'), (Join-Path $repo 'scripts\dev\bootstrap_test_stack.ps1'))
Assert-That ($linuxScripts.Count -ge 10) "Linux-Skripte gefunden ($($linuxScripts.Count))"
$winExe = @()
foreach ($f in $linuxScripts) {
    $code = [System.IO.File]::ReadAllText($f.FullName, (New-Object System.Text.UTF8Encoding($false)))
    foreach ($tk in [System.Management.Automation.PSParser]::Tokenize($code, [ref]$null)) {
        if ($tk.Type -in 'Command', 'CommandArgument', 'String' -and $tk.Content -match '(^|[\/\s])(powershell|cmd)\.exe\b') { $winExe += "$($f.Name):$($tk.StartLine)" }
    }
}
Assert-That ($winExe.Count -eq 0) "Linux-Skripte rufen kein powershell.exe/cmd.exe auf (unter Linux nur pwsh; Host nehmen wie (Get-Process -Id `$PID).Path): $($winExe -join ', ')"
# --- Suiten ohne Verbund (N8NTEST_RUNTIME, Wegwerf-Container aus dem master-Abbild) ---------------------------------------------
# Ohne Docker: Weg-Auswahl, Namen, Argumente von docker run, Abbruch ohne Projektnamen und bei Suiten, die den Verbund brauchen.
$savedRt = $env:N8NTEST_RUNTIME; $savedCt = $env:N8NTEST_CONTAINER
try {
    $env:N8NTEST_RUNTIME = $null
    Assert-That ((Get-TestSuiteRuntime) -eq 'classic') 'Suiten-Weg: ohne N8NTEST_RUNTIME classic (Standard bis zur Umschaltung)'
    $env:N8NTEST_RUNTIME = 'compose'
    Assert-That ((Get-TestSuiteRuntime) -eq 'compose') 'Suiten-Weg: compose'
    $env:N8NTEST_RUNTIME = 'classic'
    Assert-That ((Get-TestSuiteRuntime) -eq 'classic') 'Suiten-Weg: classic'
    foreach ($badRt in @('Compose', 'docker', 'systemd')) {
        $env:N8NTEST_RUNTIME = $badRt
        Assert-That (Test-Throws { Get-TestSuiteRuntime }) "Suiten-Weg: unbekannter Wert '$badRt' = Abbruch statt stillem Rueckfall"
    }

    # Verbund-Weg ohne eigenen Projektnamen: kein geteilter Standard (das klassische lifeagents-n8ntest waere ein fremder Platz).
    $env:N8NTEST_RUNTIME = 'compose'; $env:N8NTEST_CONTAINER = $null
    Assert-That (Test-Throws { Resolve-TestSuiteContainer -Suite 'runtime_test' -RepoRoot $repo }) 'Verbund-Weg ohne N8NTEST_CONTAINER = Abbruch (vor jedem Docker-Aufruf)'

} finally { $env:N8NTEST_RUNTIME = $savedRt; $env:N8NTEST_CONTAINER = $savedCt }

$sn = Get-TestSuiteScratchName 's4t3a' 'runtime_test'
Assert-That ($sn -eq 's4t3a-suite-runtime-test') 'Wegwerf-Container: <projekt>-suite-<suite>'
Assert-That (Test-Throws { Get-TestSuiteScratchName 's4t3a' 'Runtime Test' }) 'Wegwerf-Container: Suiten-Name nur klein/Ziffern/_'
Assert-That (Test-Throws { Get-TestSuiteScratchName 'lifeagents' 'runtime_test' }) 'Wegwerf-Container: Projekt lifeagents = Abbruch'
$sa = @(Get-TestSuiteScratchRunArgs -Names (Get-TestStackNames 's4t3a') -Suite 'runtime_test' -RepoRoot 'C:/x')
Assert-That ($sa[0] -eq 'run' -and $sa -contains '-d' -and $sa -contains '--rm' -and $sa[($sa.IndexOf('--name') + 1)] -eq $sn) 'Wegwerf-Container: docker run -d --rm mit Namen'
Assert-That ($sa -contains 'lifeagents.worktree=C:/x' -and $sa -contains 'lifeagents.substrate=n8n-suite') 'Wegwerf-Container: Etiketten fuer den Session-Ende-Haken (Worktree + n8n-*)'
Assert-That (-not (@($sa | Where-Object { $_ -like 'io.lifeagents.install=*' }).Count) -and $sa -contains 's4t3a-master:wt') 'Wegwerf-Container: kein Install-Etikett (kein Teil des Verbunds), Abbild <projekt>-master:wt'
# Das Abbild setzt LIFEAGENTS_RUNTIME=compose (Dockerfile ENV). Ein Runner, der den klassischen Weg prueft, setzt die Betriebsart selbst,
# sonst haengt sein Ergebnis an der Umgebung (im Abbild: rote Faelle in release_fetch_test). Der Container bekommt keine Sonder-Variable.
$gh = [System.IO.File]::ReadAllText((Join-Path $repo 'tests\mock_github\cases.sh'))
Assert-That ($gh -match '(?m)^export LIFEAGENTS_RUNTIME=systemd\b') 'mock_github/cases.sh setzt die klassische Betriebsart selbst (export LIFEAGENTS_RUNTIME=systemd)'
Assert-That (-not ($sa -contains '-e')) 'Wegwerf-Container: keine Sonder-Umgebung, die Runner setzen ihre Betriebsart selbst'
Assert-That ($sa -contains '--init') 'Wegwerf-Container: --init (PID 1 raeumt verwaiste Prozesse ab; sonst melden die KZ-Faelle einen Zombie als lebend)'
Assert-That ($sa[-2] -eq 'sleep' -and [int]$sa[-1] -gt 0) 'Wegwerf-Container: Ruhe-Befehl mit Ablauf (raeumt sich auch bei totem Skript ab)'

. (Join-Path $repo 'scripts\lib\substrate_reservations.ps1')
$tg = Get-WorktreeComposeTargets -Worktree 'C:/x' -ContainerLines @("$sn|lifeagents.substrate=n8n-suite,lifeagents.worktree=C:/x", "fremd-suite|lifeagents.substrate=n8n-suite,lifeagents.worktree=C:/y")
Assert-That (($tg.Containers -join ',') -eq $sn) 'Session-Ende-Haken raeumt den Wegwerf-Container dieses Worktrees ab, nie den eines anderen'

# Die Suiten selbst, am Syntaxbaum gelesen (ein Treffer in einem Kommentar oder ausserhalb von finally zaehlt nicht): Eine Suite, die
# Resolve vergisst, liefe auf dem Verbund-Weg still gegen das klassische Substrat; ein Abbau ausserhalb von finally liesse den
# Wegwerf-Container bei einem Abbruch stehen.
function Get-SuiteCommands([string]$Path, [string]$Name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    return @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true))
}
function Get-SuiteArg($Cmd, [string]$Param) {
    $els = $Cmd.CommandElements
    for ($i = 0; $i -lt $els.Count - 1; $i++) {
        if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $Param) { return "$($els[$i + 1].Value)" }
    }
    return ''
}
foreach ($s in @('runtime_test', 'reachability_test', 'release_fetch_test', 'bot_profile_photo_test')) {
    $p = Join-Path $repo "scripts\dev\$s.ps1"
    $res = @(Get-SuiteCommands $p 'Resolve-TestSuiteContainer' | Where-Object { (Get-SuiteArg $_ 'Suite') -eq $s })
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null)
    $inFinally = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally }, $true) |
        Where-Object { @($_.Finally.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Remove-TestSuiteScratch' }, $true)).Count -gt 0 })
    Assert-That ($res.Count -eq 1 -and $inFinally.Count -ge 1) "$s : ruft Resolve-TestSuiteContainer mit eigenem Namen und raeumt in finally mit Remove-TestSuiteScratch ab"
}

# --- Suiten im laufenden Verbund (T3b): Tick pausieren, Wegwerf-Einheiten neben dem echten Gateway --------------------------
# Die Tick-Schleife des master (compose.yml) ruft jede Minute `lifeagents update --tick` und konkurriert mit den Suiten um
# Auftraege und die Update-Sperre. Sie ruft die CLI nur, wenn /usr/local/bin/lifeagents ausfuehrbar ist; der Runner ruft die CLI aber
# selbst direkt auf (`command -v lifeagents`), ein `chmod a-x` bremste also auch ihn. Darum Link-Tausch: die CLI liegt waehrend der
# Pause unter /usr/local/sbin (steht vor /usr/local/bin im PATH), /usr/local/bin/lifeagents fehlt der Schleife.
$tickOff = Get-TestStackTickScript -Action pause
$tickOn = Get-TestStackTickScript -Action resume
Assert-That ($tickOff -match 'ln -sf /usr/local/lib/lifeagents/bin/lifeagents /usr/local/sbin/lifeagents' -and $tickOff -match 'rm -f /usr/local/bin/lifeagents') 'Tick: pausieren = CLI nach /usr/local/sbin (im PATH), /usr/local/bin/lifeagents weg'
Assert-That ($tickOn -match 'ln -sf /usr/local/lib/lifeagents/bin/lifeagents /usr/local/bin/lifeagents' -and $tickOn -match 'rm -f /usr/local/sbin/lifeagents') 'Tick: fortsetzen = Link des Abbilds zurueck, sbin-Link weg'
# Die Schleife im master (PID 1) traegt den Text `lifeagents update --tick` in ihrer eigenen Befehlszeile: ein unverankertes `pgrep -f`
# fand sie immer und die Pause lief in die Zeitgrenze. Das Muster beginnt darum am Anfang der Befehlszeile (bash <pfad>/lifeagents update).
Assert-That ($tickOff -match [regex]::Escape("pgrep -f '^[^ ]*bash [^ ]*lifeagents update --(tick|run-requested|check)'")) 'Tick: wartet nur auf echte Schritte (am Anfang der Befehlszeile verankert), nicht auf die Schleife selbst'
Assert-That ($tickOn -notmatch 'pgrep') 'Tick: Fortsetzen wartet auf nichts'
Assert-That (Test-Throws { Get-TestStackTickScript -Action 'stop' }) 'Tick: unbekannte Aktion = Abbruch'
$ta = @(Get-TestStackTickArgs -Master 's4t3b-master' -Action pause)
Assert-That ($ta[0] -eq 'exec' -and $ta[1] -eq 's4t3b-master' -and $ta[2] -eq 'sh' -and $ta[3] -eq '-c') 'Tick: docker exec nur im master dieses Verbunds'
Assert-That (Test-Throws { Get-TestStackTickArgs -Master '' -Action pause }) 'Tick: ohne master-Namen = Abbruch'

# Der laufende Unterbau muss zu N8NTEST_RUNTIME passen: ein Lauf im Verbund-Weg gegen ein klassisches Substrat (oder umgekehrt) fuehrte
# systemd- bzw. docker-Aufrufe ins Leere und liefe mit irrefuehrenden Fehlern.
. (Join-Path $repo 'scripts\lib\n8ntest_state_file.ps1')
$savedRt2 = $env:N8NTEST_RUNTIME
try {
    $env:N8NTEST_RUNTIME = 'compose'
    Assert-That (-not (Test-Throws { Assert-TestSuiteStateRuntime -State ([pscustomobject]@{ runtime = 'compose' }) })) 'Unterbau passt: compose/compose kein Abbruch'
    $msg = ''; try { Assert-TestSuiteStateRuntime -State ([pscustomobject]@{ container = 'x' }) } catch { $msg = $_.Exception.Message }
    Assert-That ($msg -match 'compose' -and $msg -match 'classic') 'Unterbau passt nicht: compose gewaehlt, Substrat klassisch = Abbruch mit beiden Namen'
    $env:N8NTEST_RUNTIME = 'classic'
    Assert-That (Test-Throws { Assert-TestSuiteStateRuntime -State ([pscustomobject]@{ runtime = 'compose' }) }) 'Unterbau passt nicht: classic gewaehlt, Verbund laeuft = Abbruch'
    Assert-That (-not (Test-Throws { Assert-TestSuiteStateRuntime -State ([pscustomobject]@{ container = 'x' }) })) 'Unterbau passt: classic/ohne Feld (alte Zustandsdatei) kein Abbruch'
} finally { $env:N8NTEST_RUNTIME = $savedRt2 }

$un = Get-TestStackUnitName -Project 's4t3b' -Unit 'n8ntest-gwt-mock'
Assert-That ($un -eq 's4t3b-n8ntest-gwt-mock') 'Einheit: <projekt>-<einheit>'
Assert-That ((Test-Throws { Get-TestStackUnitName -Project 's4t3b' -Unit 'fremd' }) -and (Test-Throws { Get-TestStackUnitName -Project 'lifeagents' -Unit 'n8ntest-gwt' })) 'Einheit: nur n8ntest-gwt…-Namen, nie im Standard-Projekt'
$gw = @(Get-TestStackGatewayUnitArgs -Project 's4t3b' -Unit 'n8ntest-gwt-dead' -Image 'node:24-alpine@sha256:x' -Env @('LLM_GATEWAY_PORT=8097') -RepoRoot 'C:/x')
Assert-That ($gw[0] -eq 'run' -and $gw -contains '-d' -and $gw[($gw.IndexOf('--name') + 1)] -eq 's4t3b-n8ntest-gwt-dead') 'Gateway-Einheit: docker run -d mit Namen'
Assert-That ($gw[($gw.IndexOf('--network') + 1)] -eq 'container:s4t3b-anchor') 'Gateway-Einheit: im Netz-Namensraum des anchor (127.0.0.1 wie der echte Gateway)'
Assert-That ($gw[($gw.IndexOf('--user') + 1)] -eq '1000:1000' -and $gw -contains 's4t3b_gw_code:/gw:ro') 'Gateway-Einheit: Nutzer und Code-Volume wie compose.yml (gateway), Code nur lesbar'
Assert-That ($gw -contains 'lifeagents.worktree=C:/x' -and $gw -contains 'lifeagents.substrate=n8n-suite' -and -not (@($gw | Where-Object { $_ -like 'io.lifeagents.install=*' }).Count)) 'Gateway-Einheit: Etiketten fuer den Session-Ende-Haken, kein Install-Etikett'
Assert-That ($gw -contains 'LLM_GATEWAY_PORT=8097' -and ($gw -contains 'NODE_OPTIONS=--dns-result-order=ipv4first') -and -not (@($gw | Where-Object { $_ -like 'STATE_DIRECTORY=*' }).Count)) 'Gateway-Einheit: Umgebung der Suite + NODE_OPTIONS wie der echte Gateway, kein STATE_DIRECTORY (sonst schriebe sie in den echten Zaehler)'
Assert-That ($gw[-3] -eq '--entrypoint' -or $gw[-4] -eq '--entrypoint') 'Gateway-Einheit: eigener Einstieg (node), nicht das Skript des echten Gateways'
Assert-That ($gw[-1] -eq '/gw/server.js' -and $gw[-2] -eq 'node:24-alpine@sha256:x') 'Gateway-Einheit: gleicher Code /gw/server.js im Abbild des echten Gateways'
$gwl = @(Get-TestStackGatewayUnitArgs -Project 's4t3b' -Unit 'n8ntest-gwt' -Image 'i' -Env @('LLM_GATEWAY_USAGE_DIR=/tmp/gwtest_usage') -RepoRoot 'C:/x')
Assert-That ($gwl -contains '--tmpfs' -and $gwl[($gwl.IndexOf('--tmpfs') + 1)] -like '/tmp/gwtest_usage*') 'Gateway-Einheit mit Zaehler-Ordner in der Umgebung: tmpfs dafuer (Nutzer 1000 darf schreiben)'
Assert-That (-not ($gw -contains '--tmpfs')) 'Gateway-Einheit ohne Zaehler-Ordner: kein tmpfs'
$mk = @(Get-TestStackNodeUnitCreateArgs -Project 's4t3b' -Unit 'n8ntest-gwt-mock' -Image 's4t3b-master:wt' -Env @('MOCK_LLM_PORT=8096') -ScriptPath '/tmp/gwtest_mock.js' -RepoRoot 'C:/x')
Assert-That ($mk[0] -eq 'create' -and $mk[($mk.IndexOf('--network') + 1)] -eq 'container:s4t3b-anchor' -and $mk -contains 'MOCK_LLM_PORT=8096') 'Attrappen-Einheit: docker create im Namensraum des anchor (danach docker cp, docker start)'
Assert-That ($mk[-1] -eq '/tmp/gwtest_mock.js' -and $mk[-2] -eq 's4t3b-master:wt') 'Attrappen-Einheit: node + Skript im master-Abbild'

foreach ($s in @('update_chat_test', 'bot_menu_test', 'backup_test')) {
    $p = Join-Path $repo "scripts\dev\$s.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$null)
    $sus = @(Get-SuiteCommands $p 'Suspend-TestTimers')
    $inFinally = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally }, $true) |
        Where-Object { @($_.Finally.FindAll({ param($c) $c -is [System.Management.Automation.Language.CommandAst] -and $c.GetCommandName() -eq 'Resume-TestTimers' }, $true)).Count -gt 0 })
    # Jede Pause steht im Rumpf eines try, dessen finally fortsetzt: scheitert die Pause selbst (der Link ist dann schon getauscht), laeuft das finally trotzdem.
    $guarded = @($sus | Where-Object { $c = $_; @($inFinally | Where-Object { $c.Extent.StartOffset -ge $_.Body.Extent.StartOffset -and $c.Extent.EndOffset -le $_.Body.Extent.EndOffset }).Count -gt 0 })
    Assert-That ($sus.Count -ge 1 -and $guarded.Count -eq $sus.Count) "$s : legt die Zeitgeber (Verbund: den Tick) im Rumpf eines try still und setzt sie in finally fort (auch wenn die Pause selbst scheitert)"
}
# Klassisch: Suspend-TestTimers legt alle aktiven lifeagents-*.timer still (keine feste Liste), sonst brachte ein nicht gelisteter
# Zeitgeber (die stuendliche Sicherung hielt die Update-Sperre) die Runner-Faelle mit "Sperre belegt" ins Leere.
$tmOff = Get-TestSubstrateTimerScript -Action pause
$tmOn = Get-TestSubstrateTimerScript -Action resume
Assert-That ($tmOff -match [regex]::Escape("--type=timer --state=active") -and $tmOff -match [regex]::Escape("'lifeagents-*.timer'")) 'Zeitgeber: pausieren = alle aktiven lifeagents-*.timer, keine feste Liste'
Assert-That ($tmOff -match 'systemctl stop' -and $tmOff -match 'systemctl is-active' -and $tmOff -notmatch 'is-active --quiet') 'Zeitgeber: pausieren stoppt die Timer und wartet auf einen schon laufenden Dienst'
Assert-That ($tmOff -match 'lifeagents-test-timers-stopped' -and $tmOn -match 'lifeagents-test-timers-stopped' -and $tmOn -match 'systemctl start') 'Zeitgeber: fortsetzen startet genau die gemerkten Timer'
Assert-That (Test-Throws { Get-TestSubstrateTimerScript -Action 'stop' }) 'Zeitgeber: unbekannte Aktion = Abbruch'
$bashTm = Get-TestStackBash
foreach ($pair in @(@('pause', $tmOff), @('resume', $tmOn))) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tm_" + [guid]::NewGuid().ToString('N') + '.sh')
    try {
        [System.IO.File]::WriteAllText($tmp, ($pair[1] -replace "`r", ''), (New-Object System.Text.UTF8Encoding($false)))
        $syn = Invoke-Native $bashTm @('-n', ($tmp -replace '\\', '/'))
        Assert-That ($syn.Code -eq 0) "Zeitgeber: $($pair[0])-Skript ist gueltiges sh ($($syn.Output -join ' '))"
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}
foreach ($s in @('update_chat_test', 'bot_menu_test', 'llm_gateway_test', 'backup_test', 'n8n_patch_test')) {
    $p = Join-Path $repo "scripts\dev\$s.ps1"
    Assert-That ((Get-SuiteCommands $p 'Get-TestSuiteRuntime').Count -ge 1) "$s : waehlt den Weg ueber Get-TestSuiteRuntime (N8NTEST_RUNTIME), nicht ueber Annahmen"
}

# backup/cases.sh im Verbund: der Standard-Name kommt aus der Meldung des Exports ohne Pfad. Fehlt er dort, bricht der Runner mit einem
# klaren FAIL ab, statt mit einer anderen Datei weiterzupruefen. Der Block wird aus der Datei gezogen und in bash gegen eine Meldung mit
# und ohne Namen ausgefuehrt; die Gegenprobe (Guard entfernt) belegt, dass der Test den Unterschied sieht.
$bkText = [System.IO.File]::ReadAllText((Join-Path $repo 'tests\backup\cases.sh'), (New-Object System.Text.UTF8Encoding($false)))
$bkBlock = [regex]::Match($bkText, '(?s)if rt_is_compose; then\r?\n  fa="\$\(grep -m1 -o .*?\r?\nfi\r?\n').Value
Assert-That ($bkBlock.Length -gt 0 -and $bkBlock -match 'E\.name-aus-meldung') 'backup/cases.sh: Verbund-Block fuer den Namen aus der Meldung gefunden (mit Abbruch-Guard)'
function Invoke-BackupNameBlock([string]$Block, [string]$Message) {
    $sh = "rt_is_compose() { return 0; }`nfails=0; fail() { printf 'FAIL %s: %s\n' `"`$1`" `"`$2`"; fails=`$((fails + 1)); }`n" +
          "W=`$(mktemp -d); printf '%s\n' '$Message' > `"`$W/out.e2`"; fa=''`n$Block`nprintf 'FA=%s\n' `"`$fa`"`n"
    # Datei statt stdin: PS 5.1 stellt beim Pipen in ein natives Programm eine BOM vor die erste Zeile.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bkname_" + [guid]::NewGuid().ToString('N') + '.sh')
    try {
        [System.IO.File]::WriteAllText($tmp, ($sh -replace "`r", ''), (New-Object System.Text.UTF8Encoding($false)))
        return (Invoke-Native (Get-TestStackBash) @(($tmp -replace '\\', '/')))
    } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}
if ($bkBlock.Length -gt 0) {
    $with = Invoke-BackupNameBlock $bkBlock '[+] Backup geschrieben: C:\x\lifeagents-backup-20261121130414-kc1dab51c-vdev.nla.enc (Ordner auf dem Rechner)'
    Assert-That ($with.Code -eq 0 -and ($with.Output -join "`n") -match 'FA=lifeagents-backup-20261121130414-kc1dab51c-vdev\.nla\.enc') 'backup/cases.sh: Name aus der Meldung gelesen (auch bei Windows-Pfad)'
    $without = Invoke-BackupNameBlock $bkBlock '[+] Backup geschrieben: irgendwo'
    Assert-That ($without.Code -ne 0 -and ($without.Output -join "`n") -match 'FAIL E\.name-aus-meldung' -and ($without.Output -join "`n") -notmatch 'FA=') 'backup/cases.sh: Meldung ohne Namen = klarer FAIL und Abbruch (kein Weiterpruefen mit anderer Datei)'
    $mutated = [regex]::Replace($bkBlock, '(?m)^\s*\[ -n "\$fa" \] \|\| \{.*\}\r?\n', '')
    $mm = Invoke-BackupNameBlock $mutated '[+] Backup geschrieben: irgendwo'
    Assert-That ($mutated -ne $bkBlock -and $mm.Code -eq 0 -and ($mm.Output -join "`n") -match 'FA=\s*$') 'backup/cases.sh: Gegenprobe - ohne den Guard laeuft der Block still mit leerem Namen weiter (der Test sieht den Unterschied)'
}

Write-Host "test_stack_test: $failed Fehler."
exit $failed
