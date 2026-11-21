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
$want = @('TEST_HARNESS_HEADER=X-Test-Auth', 'LIFEAGENTS_HITL_CHAT_APPROVAL=false', 'LIFEAGENTS_DEPLOY_FULL=0', 'LLM_GATEWAY_KEEPALIVE_HOURS=0', 'BOT_PROFILE_PHOTO=0', 'TELEGRAM_WEBHOOK_TAKEOVER=1')
Assert-That (($plain -join '|') -eq ($want -join '|')) 'ohne Werte nur die Test-Schalter mit ihren Vorgaben, in fester Reihenfolge'

# --- Eine Adresse fuer TEST_*-Zuordnung und Test-Schalter: beide Bootstraps rufen scripts/lib/test_install_env.ps1 -----------
$sw = Get-TestDevSwitches -HitlChatApproval -FullDeploy -SerialTools '1'
Assert-That ((@($sw.Keys) -join ',') -eq 'TEST_HARNESS_HEADER,LIFEAGENTS_HITL_CHAT_APPROVAL,LIFEAGENTS_DEPLOY_FULL,LLM_GATEWAY_KEEPALIVE_HOURS,LLM_GATEWAY_SERIAL_TOOLS,BOT_PROFILE_PHOTO,TELEGRAM_WEBHOOK_TAKEOVER') 'Test-Schalter: Reihenfolge wie im klassischen Bootstrap, SerialTools nur wenn gesetzt'
Assert-That ($sw['LIFEAGENTS_HITL_CHAT_APPROVAL'] -eq 'true' -and $sw['LIFEAGENTS_DEPLOY_FULL'] -eq '1' -and $sw['LLM_GATEWAY_SERIAL_TOOLS'] -eq '1') 'Schalter-Werte aus den Parametern'
$classic = [System.IO.File]::ReadAllText((Join-Path $repo 'scripts\dev\bootstrap_test_n8n.ps1'))
$envFile = @(ConvertTo-TestEnvFileLines -Map $map -Values @{ TEST_TELEGRAM_BOT_TOKEN = "1:it's-invented"; TEST_GOOGLE_API_KEY = '' })
Assert-That ($envFile -contains "TELEGRAM_BOT_TOKEN='1:it'\''s-invented'" -and -not ($envFile -match '^GOOGLE_API_KEY=')) 'Env-Datei des Klassikers: gesetzte TEST_*-Werte shell-gequotet, leere fehlen'
Assert-That ($envFile -contains "TEST_HARNESS_HEADER='X-Test-Auth'" -and $envFile -contains "BOT_PROFILE_PHOTO='0'" -and $envFile -contains "TELEGRAM_WEBHOOK_TAKEOVER='1'" -and $envFile -contains "LLM_GATEWAY_KEEPALIVE_HOURS='0'") 'Env-Datei des Klassikers traegt die Test-Schalter'
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
Assert-That ($script:TestStackMockAnswers['ANTHROPIC_API_KEY'] -and $script:TestStackMockAnswers['ANTHROPIC_API_KEY'] -match 'invented' -and $script:TestStackMockAnswers['TELEGRAM_BOT_TOKEN'] -match 'invented') 'Verbund: Bot-Token und KI-Schluessel erfunden (kein echter Zugang in der Installation)'

# --- Etikett lesen: fehlendes Volume ist $null, ein gestoertes Docker ist ein Fehler (nie „gibt es nicht“) ------------------
Assert-That ((ConvertFrom-TestStackLabelResult -Code 0 -Output @('{"io.lifeagents.install":"s4t0"}') -Label 'io.lifeagents.install') -eq 's4t0') 'Etikett gelesen'
Assert-That ((ConvertFrom-TestStackLabelResult -Code 0 -Output @('null') -Label 'x') -eq '') 'Volume ohne Etiketten = leer'
Assert-That ($null -eq (ConvertFrom-TestStackLabelResult -Code 1 -Output @('Error response from daemon: get s4t0_pgdata: no such volume') -Label 'x')) 'fehlendes Volume = $null'
Assert-That (Test-Throws { ConvertFrom-TestStackLabelResult -Code 1 -Output @('error during connect: The system cannot find the file specified.') -Label 'x' }) 'Docker-Fehler = Abbruch, nicht „fehlt“'

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
    foreach ($bad in @('Compose', 'docker', 'systemd')) {
        $env:N8NTEST_RUNTIME = $bad
        Assert-That (Test-Throws { Get-TestSuiteRuntime }) "Suiten-Weg: unbekannter Wert '$bad' = Abbruch statt stillem Rueckfall"
    }

    # Verbund-Weg ohne eigenen Projektnamen: kein geteilter Standard (das klassische lifeagents-n8ntest waere ein fremder Platz).
    $env:N8NTEST_RUNTIME = 'compose'; $env:N8NTEST_CONTAINER = $null
    Assert-That (Test-Throws { Resolve-TestSuiteContainer -Suite 'runtime_test' -RepoRoot $repo }) 'Verbund-Weg ohne N8NTEST_CONTAINER = Abbruch (vor jedem Docker-Aufruf)'

    # Suiten, die einen laufenden Verbund brauchen (Datenbank, n8n-Patch-Weg): Verbund-Weg bricht klar ab, klassisch laeuft.
    $env:N8NTEST_RUNTIME = 'classic'
    Assert-That (-not (Test-Throws { Assert-TestSuiteClassicOnly -Suite 'backup_test' -Reason 'x' })) 'Verbund-Suite: klassisch kein Abbruch'
    $env:N8NTEST_RUNTIME = 'compose'
    $msg = ''; try { Assert-TestSuiteClassicOnly -Suite 'backup_test' -Reason 'echte Datenbank' } catch { $msg = $_.Exception.Message }
    Assert-That ($msg -match 'backup_test' -and $msg -match 'echte Datenbank' -and $msg -match 'T3b') 'Verbund-Suite: Abbruch nennt Suite, Grund und Folgepaket'
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
# sonst haengt sein Ergebnis an der Umgebung (im Abbild: sechs rote Faelle in release_fetch_test). Der Container bekommt keine Sonder-Variable.
$gh = [System.IO.File]::ReadAllText((Join-Path $repo 'tests\mock_github\cases.sh'))
Assert-That ($gh -match '(?m)^export LIFEAGENTS_RUNTIME=systemd\b') 'mock_github/cases.sh setzt die klassische Betriebsart selbst (export LIFEAGENTS_RUNTIME=systemd)'
Assert-That (-not ($sa -contains '-e')) 'Wegwerf-Container: keine Sonder-Umgebung, die Runner setzen ihre Betriebsart selbst'
Assert-That ($sa -contains '--init') 'Wegwerf-Container: --init (PID 1 raeumt verwaiste Prozesse ab; sonst melden die KZ-Faelle einen Zombie als lebend)'
Assert-That ($sa[-2] -eq 'sleep' -and [int]$sa[-1] -gt 0) 'Wegwerf-Container: Ruhe-Befehl mit Ablauf (raeumt sich auch bei totem Skript ab)'

. (Join-Path $repo 'scripts\lib\substrate_reservations.ps1')
$tg = Get-WorktreeComposeTargets -Worktree 'C:/x' -ContainerLines @("$sn|lifeagents.substrate=n8n-suite,lifeagents.worktree=C:/x", "fremd-suite|lifeagents.substrate=n8n-suite,lifeagents.worktree=C:/y")
Assert-That (($tg.Containers -join ',') -eq $sn) 'Session-Ende-Haken raeumt den Wegwerf-Container dieses Worktrees ab, nie den eines anderen'

# Die Suiten selbst: vier laufen im Wegwerf-Container, zwei verlangen den Verbund. Eine Suite, die Resolve vergisst, liefe auf dem
# Verbund-Weg still gegen das klassische Substrat.
foreach ($s in @('runtime_test', 'reachability_test', 'release_fetch_test', 'bot_profile_photo_test')) {
    $t = [System.IO.File]::ReadAllText((Join-Path $repo "scripts\dev\$s.ps1"))
    Assert-That ($t -match "Resolve-TestSuiteContainer -Suite '$s'" -and $t -match 'Remove-TestSuiteScratch') "$s : Container ueber Resolve-TestSuiteContainer, Abbau ueber Remove-TestSuiteScratch"
}
foreach ($s in @('backup_test', 'n8n_patch_test')) {
    $t = [System.IO.File]::ReadAllText((Join-Path $repo "scripts\dev\$s.ps1"))
    Assert-That ($t -match "Assert-TestSuiteClassicOnly -Suite '$s'") "$s : bricht auf dem Verbund-Weg klar ab (Assert-TestSuiteClassicOnly)"
}

Write-Host "test_stack_test: $failed Fehler."
exit $failed
