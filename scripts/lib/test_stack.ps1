# test_stack.ps1 -- Bausteine des Test-Verbunds (Docker-Verbund wie beim Nutzer, Einstieg scripts/dev/bootstrap_test_stack.ps1).
# Start, Installation und Abbau laufen nur ueber den Kern (`docker run … <master> stack <verb> --json`, Aufruf-Form im Kopf von
# provisioning/compose/stack.sh), nie mit eigener Compose-Logik. Eigenes hier: das master-Abbild aus dem Arbeitsstand, die
# Antwort-Datei (tests/wizard/render_ci_answers.js --profile dev), die REST-Bruecke, der Schnappschuss der Daten-Volumes.
# Etiketten-Vertrag mit dem Platz-Zaehler und dem Session-Ende-Haken (scripts/lib/substrate_reservations.ps1,
# .claude/hooks/stop_own_substrate.ps1):
#   <projekt>_pgdata          io.lifeagents.install=<projekt>, lifeagents.substrate=n8n, lifeagents.worktree=<checkout>
#   <projekt>snap_<vol>       lifeagents.substrate=n8n-snapshot, lifeagents.snapshot-of, lifeagents.snapshot-key, lifeagents.worktree
#   <projekt>-testbridge      io.lifeagents.install, lifeagents.substrate=n8n-bridge, lifeagents.bridge-of, lifeagents.worktree
#   <projekt>-master:wt       lifeagents.substrate=n8n-image, lifeagents.worktree (Abbild)
# Abgebaut werden geteilte Abbilder (n8n, postgres, caddy …) nie: `stack uninstall` laeuft ohne --delete-data (das loeschte die
# Abbilder, die dieser Verbund als erster geladen hat, auch wenn ein Nachbar-Verbund sie braucht); die Daten-Volumes entfernt
# Remove-TestStackStateVolumes selbst, nur mit dem eigenen Install-Etikett.
# Dot-sourcen; reine Bausteine testet scripts/dev/test_stack_test.ps1 ohne Docker.

$script:TestStackUtf8 = New-Object System.Text.UTF8Encoding($false)

# --- Reine Bausteine (ohne Docker) ---------------------------------------------------------------------------------------
# Assert-TestStackProject -- Compose-Projektname und Abbild-Name muessen klein sein; 'lifeagents' ist der Standardname einer
# echten Installation (compose.yml x-labels) und darf nie ein Test-Verbund sein.
function Assert-TestStackProject([string]$Project) {
    if ($Project -cnotmatch '^[a-z0-9][a-z0-9-]{1,39}$') { throw "Projektname '$Project' ungueltig (klein, Ziffern, '-', 2-40 Zeichen; Quelle `$env:N8NTEST_CONTAINER)." }
    if ($Project -eq 'lifeagents') { throw "Projektname 'lifeagents' gehoert einer echten Installation, nie einem Test-Verbund." }
    # <x>snap_<vol> ist der Schnappschuss von x; ein Projekt xsnap haette genau diese Namen als Daten-Volumes.
    if ($Project -like '*snap') { throw "Projektname '$Project' endet auf 'snap' (Namensraum der Schnappschuss-Volumes)." }
}

function Get-TestStackNames([string]$Project) {
    Assert-TestStackProject $Project
    $p = $Project
    return [pscustomobject]@{
        Project  = $p
        Image    = "$p-master:wt"
        Master   = "$p-master"
        Postgres = "$p-postgres"
        Core     = "$p-core"
        Bridge   = "$p-testbridge"
        Network  = "${p}_egress"
        Volume   = { param($v) "${p}_$v" }.GetNewClosure()
        Snapshot = { param($v) "${p}snap_$v" }.GetNewClosure()
    }
}

# Get-TestStackLogDir <projekt> -- Arbeits- und Log-Ordner des Verbunds auf dem Rechner (Kern-Ausgaben, Antworten, Attrappen-Logs
# unter mocks\). Bootstrap und Treiber (scripts/dev/test_n8n_state.ps1) lesen die Attrappen-Logs hier; -Down loescht ihn.
function Get-TestStackLogDir([string]$Project) {
    Assert-TestStackProject $Project
    return (Join-Path ([System.IO.Path]::GetTempPath()) "lifeagents-test-stack\$Project")
}

# Get-TestStackPorts -Port <N8NTEST_PORT> -CoreRange <N8NTEST_STACK_PORTS> -- Port = REST-Bruecke; in der Spanne (LA_CORE_PORTS)
# sucht der Kern seine zwei Ports (edge, wizard). Die Spanne wird nie abgeleitet: Port+1… gehoert oft einem Nachbarn oder dem
# -b-Substrat von run_free_gates -Parallel. Mindestens zwei Ports, ohne den Bruecken-Port.
function Get-TestStackPorts([string]$Port, [string]$CoreRange) {
    if ($Port -notmatch '^\d{4,5}$' -or [int]$Port -lt 1024 -or [int]$Port -gt 65520) { throw "N8NTEST_PORT '$Port' ungueltig (1024-65520)." }
    $b = [int]$Port
    if ($CoreRange -notmatch '^(\d{4,5})-(\d{4,5})$' -or [int]$Matches[1] -ge [int]$Matches[2] -or [int]$Matches[1] -lt 1024 -or [int]$Matches[2] -gt 65535) {
        throw "N8NTEST_STACK_PORTS '$CoreRange' ungueltig (von-bis, mindestens zwei Ports, z. B. 57510-57519)."
    }
    if ($b -ge [int]$Matches[1] -and $b -le [int]$Matches[2]) { throw "N8NTEST_STACK_PORTS '$CoreRange' enthaelt den Bruecken-Port $b." }
    return [pscustomobject]@{ Bridge = $b; CoreRange = $CoreRange }
}

# Get-TestStackStateVolumes <runtime.sh-Text> -- die Daten-Volumes (LA_STATE_VOLUMES) aus derselben Datei, die ins Abbild geht.
function Get-TestStackStateVolumes([string]$RuntimeShText) {
    $m = [regex]::Match($RuntimeShText, '(?m)^LA_STATE_VOLUMES="([a-z0-9_ ]+)"\r?$')
    if (-not $m.Success) { throw 'LA_STATE_VOLUMES="…" in provisioning/lib/runtime.sh nicht gefunden.' }
    return @($m.Groups[1].Value -split ' ' | Where-Object { $_ })
}

function Get-TestStackSha256([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($script:TestStackUtf8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}
# Get-TestStackSnapshotKey -- passt ein Schnappschuss noch? Abbild (Baum + Build-Argumente), Antwort-Datei (enthaelt Geheimnisse:
# nur der Hash geht ins Etikett) und compose.yml. Die abgeleiteten Volumes (shared, gw_code …) stammen aus dem Abbild.
function Get-TestStackSnapshotKey([string]$ImageId, [string]$AnswersText, [string]$ComposeText) {
    return Get-TestStackSha256 ("$ImageId`n" + (Get-TestStackSha256 $AnswersText) + "`n" + (Get-TestStackSha256 $ComposeText))
}

# Read-TestStackCoreResult <zeilen> -- Vertrag des Kerns mit --json (Kopf von provisioning/lib/stack_core.sh): nur JSON-Zeilen mit
# "v":1, genau ein result. Verletzung = Abbruch; ok:false ist ein normales Ergebnis (reason) fuer den Aufrufer.
function Read-TestStackCoreResult([string[]]$Lines) {
    $res = @()
    foreach ($l in @($Lines | Where-Object { $_ -ne '' })) {
        if (-not $l.StartsWith('{"v":1,', [StringComparison]::Ordinal)) { throw "Kern-Ausgabe verletzt den Vertrag (Zeile ohne JSON v1): $l" }
        $o = $l | ConvertFrom-Json
        if ($o.type -eq 'result') { $res += $o }
    }
    if ($res.Count -ne 1) { throw "Kern-Ausgabe verletzt den Vertrag: $($res.Count) result-Zeilen statt genau einer." }
    return $res[0]
}

# TEST_*-Zuordnung und Test-Schalter: eine Adresse fuer beide Unterbauten.
. (Join-Path $PSScriptRoot 'test_install_env.ps1')

# ConvertTo-TestStackExtra -- Zusatz-Zeilen fuer render_ci_answers.js --extra-stdin: gesetzte TEST_*-Werte als Kern-Schluessel,
# danach immer die Test-Schalter (Get-TestDevSwitches), zuletzt -Override (feste Ziele der Attrappen): ein Schluessel aus
# -Override ersetzt einen .env-Wert gleichen Namens (die Antwort-Datei duldet jeden Schluessel nur einmal).
function ConvertTo-TestStackExtra {
    param([Parameter(Mandatory)]$Map, [Parameter(Mandatory)][hashtable]$Values, [switch]$HitlChatApproval, [switch]$FullDeploy,
          [string]$SerialTools = '', $Override = @{})
    $out = New-Object System.Text.StringBuilder
    foreach ($k in $Map.Keys) {
        $v = [string]$Values[$k]
        if (-not $v -or $Override.Contains($Map[$k])) { continue }
        if ($v -match '[\x00-\x1f\x7f]') { throw ".env: Wert von $k enthaelt ein Steuerzeichen." }
        [void]$out.Append("$($Map[$k])=$v`n")
    }
    $sw = Get-TestDevSwitches -HitlChatApproval:$HitlChatApproval -FullDeploy:$FullDeploy -SerialTools $SerialTools
    foreach ($k in $sw.Keys) { if (-not $Override.Contains($k)) { [void]$out.Append("$k=$($sw[$k])`n") } }
    foreach ($k in $Override.Keys) { [void]$out.Append("$k=$($Override[$k])`n") }
    return $out.ToString()
}

# Get-TestStackSwitchNames <stack_core.sh-Text> -- die Test-Weichen, die `stack install` an provision.sh reicht (SC_TEST_SWITCHES,
# eine Adresse im Kern); Assert-TestStackSwitches bricht ab, bevor eine Weiche ausserhalb der Liste gesetzt wuerde (der Kern
# liesse sie ohnehin fallen, der Lauf liefe dann still gegen echte Dienste).
function Get-TestStackSwitchNames([string]$StackCoreText) {
    $m = [regex]::Match($StackCoreText, '(?m)^SC_TEST_SWITCHES="([A-Z0-9_ ]+)"\r?$')
    if (-not $m.Success) { throw 'SC_TEST_SWITCHES="…" in provisioning/lib/stack_core.sh nicht gefunden.' }
    return @($m.Groups[1].Value -split ' ' | Where-Object { $_ })
}
function Assert-TestStackSwitches([string[]]$Names, [string[]]$Allowed) {
    foreach ($n in $Names) { if ($Allowed -notcontains $n) { throw "Test-Weiche $n steht nicht in SC_TEST_SWITCHES (provisioning/lib/stack_core.sh)." } }
}

# Select-TestStackSideContainers -Rows <Name|Labels> -Project <p> -- Container mit Install- und Worktree-Etikett, die nicht
# Compose gehoeren (Attrappen aus tests/mock_pod/start_mocks.sh, REST-Bruecke): `stack uninstall` laesst sie stehen, sie haengen
# am Netz bzw. Namensraum des anchor und muessen vor ihm weg. Kurzlaeufe des Kerns (<p>-core, -core-next, -patchsrc) tragen kein
# Worktree-Etikett und verschwinden selbst (--rm); ein rm darauf liefe in einen Wettlauf mit Dockers eigenem Entfernen.
function Select-TestStackSideContainers([string[]]$Rows, [string]$Project) {
    $out = @()
    foreach ($r in $Rows) {
        $name, $labels = "$r" -split '\|', 2
        if (-not $name) { continue }
        $l = ",$labels,"
        if ($l -notmatch ',lifeagents\.worktree=') { continue }
        if ($l -notmatch (',io\.lifeagents\.install=' + [regex]::Escape($Project) + ',')) { continue }
        if ($l -match ',com\.docker\.compose\.project=') { continue }
        $out += $name
    }
    return @($out | Sort-Object)
}

# Compare-TestStackTeardown -- Abgleich der Docker-Namen (Container, Volumes, Abbilder) vor und nach dem Abbau. Zum Verbund
# gehoeren nur die Container mit seinem Install-Etikett (-Labeled, vom Aufrufer vor dem Abbau gelesen), die Volumes <p>_* und
# <p>snap_* und das Abbild <p>-master:wt; andere Objekte mit demselben Anfang gehoeren der Session (s4t0-dbtest …). Fehlen darf
# nur, was zum Verbund gehoert, und davon darf nichts bleiben. Rueckgabe = Funde @{Severity; Text}, leer = sauber.
# Schwere: ein fehlendes fremdes Abbild (Eintrag mit @digest) und jeder eigene Rest sind Fehler; ein fehlender fremder
# Container/Volume ist ein Hinweis, weil parallele Sessions ihre Substrate laufend abbauen (gemessen: ein Nachbar-Test
# entfernte waehrend des Abbaus seine Objekte). Abbilder baut sonst kaum jemand ab, und genau dort lag der Schaden aus P1a.
function Test-TestStackOwnName([string]$Project, [string]$Name, [string[]]$Labeled) {
    if ($Labeled -contains $Name) { return $true }
    $q = [regex]::Escape($Project)
    return ($Name -match "^$q(_|snap_)[a-z0-9_]+$" -or $Name -match "^$q-master:wt@")
}
function Compare-TestStackTeardown([string]$Project, [string[]]$Before, [string[]]$After, [string[]]$Labeled = @()) {
    $f = @()
    foreach ($n in $Before) {
        if (($After -notcontains $n) -and -not (Test-TestStackOwnName $Project $n $Labeled)) {
            if ($n.Contains('@')) { $f += [pscustomobject]@{ Severity = 'error'; Text = "fremdes Abbild fehlt nach dem Abbau: $n" } }
            else { $f += [pscustomobject]@{ Severity = 'hint'; Text = "fremdes Objekt fehlt nach dem Abbau (ein Nachbar baute zugleich ab? docker events --since 10m --filter event=destroy): $n" } }
        }
    }
    foreach ($n in $After) {
        if (Test-TestStackOwnName $Project $n $Labeled) { $f += [pscustomobject]@{ Severity = 'error'; Text = "eigenes Objekt blieb nach dem Abbau: $n" } }
    }
    return $f
}

# ConvertFrom-TestStackLabelResult -- Ergebnis von `docker volume inspect -f '{{json .Labels}}'`: Wert, '' ohne dieses Etikett,
# $null nur bei „no such volume“. Jeder andere Fehler wirft: ein gestoertes Docker darf nicht wie ein fehlendes Volume aussehen
# (sonst liefe -Reset kalt und ein Abbau liesse Volumes still stehen; dieselbe Trennung wie rt_volume_label in runtime.sh).
function ConvertFrom-TestStackLabelResult([int]$Code, [string[]]$Output, [string]$Label) {
    $text = ($Output -join "`n")
    if ($Code -ne 0) {
        if ($text -match '(?i)no such volume') { return $null }
        throw "docker volume inspect fehlgeschlagen: $text"
    }
    $labels = $text | ConvertFrom-Json
    if ($null -eq $labels -or $null -eq $labels.$Label) { return '' }
    return [string]$labels.$Label
}

# --- Docker-Schritte (bewiesen auf dem echten Weg: bootstrap_test_stack.ps1 kalt, -Reset, -Down) ----------------------------
# Kurze Aufrufe ueber Invoke-Native (scripts/lib/test_common.ps1).
. (Join-Path $PSScriptRoot 'test_common.ps1')

# Invoke-TestStackProcess -- langer Docker-Aufruf mit stdin aus einer Datei (UTF-8 ohne BOM; Pipe aus PS 5.1 kodiert nach
# $OutputEncoding um) und stdout/stderr in <LogBase>.out/.err. Start-Process quotet nicht: Argumente hier selbst quoten.
function Invoke-TestStackProcess([string[]]$DockerArgs, [string]$StdinFile, [string]$LogBase) {
    $argLine = ($DockerArgs | ForEach-Object { if ($_ -eq '' -or $_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
    $p = Start-Process -FilePath docker -ArgumentList $argLine -RedirectStandardInput $StdinFile `
        -RedirectStandardOutput "$LogBase.out" -RedirectStandardError "$LogBase.err" -NoNewWindow -Wait -PassThru
    $out = @()
    if (Test-Path "$LogBase.out") { $out = @([System.IO.File]::ReadAllText("$LogBase.out", $script:TestStackUtf8) -split "`r?`n" | Where-Object { $_ -ne '' }) }
    return [pscustomobject]@{ Code = $p.ExitCode; Output = $out; ErrFile = "$LogBase.err" }
}
function Get-TestStackEmptyFile([string]$LogDir) {
    $f = Join-Path $LogDir 'empty.stdin'
    if (-not (Test-Path $f)) { [System.IO.File]::WriteAllText($f, '', $script:TestStackUtf8) }
    return $f
}
function Get-TestStackErrTail([string]$ErrFile, [int]$Lines = 40) {
    if (-not (Test-Path $ErrFile)) { return '' }
    return ((@([System.IO.File]::ReadAllText($ErrFile, $script:TestStackUtf8) -split "`r?`n") | Select-Object -Last $Lines) -join "`n")
}

# New-TestStackImage -- master-Abbild aus dem Arbeitsstand (auch ungespeicherte und neue, nicht ignorierte Dateien): Baum ueber
# einen temporaeren Index (git add -A), `git archive --mtime=@0` dieses Baums als Bau-Kontext. Gleicher Arbeitsstand = gleicher
# Baum = byte-gleicher Kontext = dasselbe Abbild aus dem Bau-Cache (der Schnappschuss-Schluessel haengt an der Abbild-ID);
# `git stash create` gaebe je Aufruf einen neuen Commit-Zeitstempel. Rueckgabe: Abbild-ID und Baum.
function New-TestStackImage {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)]$Names, [Parameter(Mandatory)][string]$LogDir)
    $spec = @('provisioning', 'packages', '.gitattributes')
    $idx = Join-Path $LogDir 'image.index'
    $ctx = Join-Path $LogDir 'image-context.tar'
    $prevIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $idx
        Remove-Item $idx -Force -ErrorAction SilentlyContinue
        & git -C $RepoRoot read-tree HEAD; if ($LASTEXITCODE -ne 0) { throw 'git read-tree HEAD (temporaerer Index) fehlgeschlagen.' }
        & git -C $RepoRoot add -A -- @spec; if ($LASTEXITCODE -ne 0) { throw 'git add -A (temporaerer Index) fehlgeschlagen.' }
        $tree = ([string](& git -C $RepoRoot write-tree)).Trim(); if ($LASTEXITCODE -ne 0) { throw 'git write-tree fehlgeschlagen.' }
    } finally { $env:GIT_INDEX_FILE = $prevIndex; Remove-Item $idx -Force -ErrorAction SilentlyContinue }
    & git -C $RepoRoot archive --format=tar '--mtime=@0' -o $ctx $tree @spec
    if ($LASTEXITCODE -ne 0) { throw 'git archive des Arbeitsstands fehlgeschlagen.' }
    # --provenance/--sbom aus: mit dem containerd-Speicher (Docker Desktop) ist die Abbild-ID der Digest des Index, und der
    # Nachweis-Eintrag traegt den Bau-Zeitpunkt -> sonst je Bau eine neue ID trotz vollem Cache (gemessen).
    $r = Invoke-TestStackProcess -DockerArgs @('build', '-q', '--provenance=false', '--sbom=false', '-f', 'provisioning/compose/master.Dockerfile',
        '--build-arg', "RELEASE_TAG=dev-$($tree.Substring(0, 12))",
        '--label', 'lifeagents.substrate=n8n-image', '--label', "lifeagents.worktree=$RepoRoot",
        '-t', $Names.Image, '-') -StdinFile $ctx -LogBase (Join-Path $LogDir 'image-build')
    Remove-Item $ctx -Force -ErrorAction SilentlyContinue
    if ($r.Code -ne 0) { throw "docker build des master-Abbilds fehlgeschlagen:`n$(Get-TestStackErrTail $r.ErrFile)" }
    $id = ((Invoke-Native docker @('image', 'inspect', '-f', '{{.Id}}', $Names.Image)).Output -join '').Trim()
    if ($id -notmatch '^sha256:[0-9a-f]{64}$') { throw "Abbild $($Names.Image) nach dem Bau nicht lesbar ($id)." }
    return [pscustomobject]@{ ImageId = $id; Tree = $tree }
}

# Invoke-TestStackCore -- der Kern in seiner einen Aufruf-Form, stdin aus Datei (Antwort-Datei bei install), Ergebnis = result.
# -Switches: Test-Weichen (Name -> Wert) fuer `stack install`; nur Namen aus SC_TEST_SWITCHES. Der Wert steht nur in der Umgebung
# des docker-Aufrufs (--env NAME liest ihn dort), nie in einer Befehlszeile; danach ist die Umgebung wie vorher.
function Invoke-TestStackCore {
    param([Parameter(Mandatory)]$Names, [Parameter(Mandatory)]$Ports, [Parameter(Mandatory)][string]$Verb,
          [string[]]$Rest = @(), [string]$StdinFile = '', [Parameter(Mandatory)][string]$LogDir, $Switches = @{})
    if (-not $StdinFile) { $StdinFile = Get-TestStackEmptyFile $LogDir }
    $a = @('run', '--rm', '-i', '--name', $Names.Core, '--label', "io.lifeagents.install=$($Names.Project)",
        '--env', 'LA_CORE=1', '--env', "LA_PROJECT=$($Names.Project)", '--env', "LA_CORE_PORTS=$($Ports.CoreRange)")
    foreach ($k in $Switches.Keys) { $a += @('--env', $k) }
    $a += @('--mount', 'type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock', $Names.Image, 'stack', $Verb, '--json') + $Rest
    $saved = @{}
    foreach ($k in $Switches.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$Switches[$k]) }
    try { $r = Invoke-TestStackProcess -DockerArgs $a -StdinFile $StdinFile -LogBase (Join-Path $LogDir "core-$Verb") }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    try { $res = Read-TestStackCoreResult $r.Output }
    catch { throw "stack $Verb (Exit $($r.Code)): $($_.Exception.Message)`n$(Get-TestStackErrTail $r.ErrFile)" }
    $res | Add-Member -NotePropertyName exit_code -NotePropertyValue $r.Code -Force
    $res | Add-Member -NotePropertyName err_file -NotePropertyValue $r.ErrFile -Force
    return $res
}
function Assert-TestStackCoreOk($Result, [string]$Verb) {
    if ($Result.ok -ne $true) { throw "stack $Verb abgelehnt: reason=$($Result.reason) $($Result.detail)`n$(Get-TestStackErrTail $Result.err_file)" }
}

# Get-TestStackAnswers -- Antwort-Datei und Paket-Argument mit dem Code des Fragebogens im eigenen Abbild (render_ci_answers.js
# eingehaengt, ohne Netz, ohne laufenden Verbund); Zusatz-Zeilen ueber stdin (Geheimnisse nie in der Befehlszeile).
function Get-TestStackAnswers {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)]$Names, [Parameter(Mandatory)][string]$BackupDir,
          [string]$ExtraText = '', [Parameter(Mandatory)][string]$LogDir)
    # Vollpfad mit \ (RepoRoot kommt von git mit /): Docker Desktop haengt so einen Windows-Pfad sicher ein.
    $js = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'tests\wizard\render_ci_answers.js'))
    $base = @('run', '--rm', '-i', '--network', 'none', '-v', "${js}:/tmp/render_ci_answers.js:ro", $Names.Image,
        'node', '/tmp/render_ci_answers.js', '--reach', 'tunnel', '--backup', $BackupDir, '--profile', 'dev')
    $in = Join-Path $LogDir 'answers-extra.stdin'
    try {
        [System.IO.File]::WriteAllText($in, $ExtraText, $script:TestStackUtf8)
        $r = Invoke-TestStackProcess -DockerArgs ($base + '--extra-stdin') -StdinFile $in -LogBase (Join-Path $LogDir 'answers')
        if ($r.Code -ne 0) { throw "render_ci_answers.js fehlgeschlagen:`n$(Get-TestStackErrTail $r.ErrFile)" }
        $answers = ($r.Output -join "`n") + "`n"
    } finally { Remove-Item $in, (Join-Path $LogDir 'answers.out') -Force -ErrorAction SilentlyContinue }
    $r = Invoke-TestStackProcess -DockerArgs ($base + @('--print', 'packages')) -StdinFile (Get-TestStackEmptyFile $LogDir) -LogBase (Join-Path $LogDir 'packages')
    if ($r.Code -ne 0) { throw "render_ci_answers.js --print packages fehlgeschlagen:`n$(Get-TestStackErrTail $r.ErrFile)" }
    if (-not $answers.StartsWith("# lifeagents-answers v1`n", [StringComparison]::Ordinal)) { throw 'Antwort-Datei ohne Kopfzeile # lifeagents-answers v1.' }
    return [pscustomobject]@{ Text = $answers; Packages = ($r.Output -join '').Trim() }
}

# Bruecke 127.0.0.1:<port> -> anchor:5678 (n8n): der Rand gibt /api/v1 nicht frei, die Tests brauchen REST + Webhooks wie die
# socat-Bruecke des klassischen Unterbaus. Am Netz <p>_egress: am Netz internal (internal: true) laesst Docker keine Ports zu.
# Node aus dem eigenen Abbild (kein socat darin, kein weiteres Abbild aus dem Netz).
$script:TestStackBridgeJs = "const n=require('net');n.createServer(c=>{const u=n.connect(5678,'anchor');c.pipe(u);u.pipe(c);u.on('error',()=>c.destroy());c.on('error',()=>u.destroy());}).listen(5680,'0.0.0.0');"
function Remove-TestStackBridge($Names) {
    $id = ((Invoke-Native docker @('ps', '-aq', '--filter', "name=^/$($Names.Bridge)$")).Output -join '').Trim()
    if ($id) { [void](Invoke-Native docker @('rm', '-fv', $Names.Bridge)) }
}
function Start-TestStackBridge {
    param([Parameter(Mandatory)]$Names, [Parameter(Mandatory)]$Ports, [Parameter(Mandatory)][string]$RepoRoot)
    Remove-TestStackBridge $Names
    $r = Invoke-Native docker @('run', '-d', '--name', $Names.Bridge, '--network', $Names.Network,
        '-p', "127.0.0.1:$($Ports.Bridge):5680",
        '--label', "io.lifeagents.install=$($Names.Project)", '--label', 'lifeagents.substrate=n8n-bridge',
        '--label', "lifeagents.bridge-of=$($Names.Project)", '--label', "lifeagents.worktree=$RepoRoot",
        $Names.Image, 'node', '-e', $script:TestStackBridgeJs)
    if ($r.Code -ne 0) { throw "REST-Bruecke $($Names.Bridge) liess sich nicht starten: $($r.Output -join "`n")" }
}

# Wait-TestStackReady -- n8n bereit ueber die Bruecke (/healthz/readiness, nicht /healthz: das meldet vor den Migrationen ok).
function Wait-TestStackReady([string]$Url, [int]$TimeoutSec = 180) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri "$Url/healthz/readiness" -UseBasicParsing -TimeoutSec 5
            if ($resp.StatusCode -eq 200) { return }
        } catch { Write-Debug "readiness: $($_.Exception.Message)" }
        Start-Sleep -Seconds 2
    }
    throw "n8n unter $Url wurde nicht bereit ($TimeoutSec s, /healthz/readiness)."
}

function Get-TestStackApiKey($Names) {
    $r = Invoke-Native docker @('exec', $Names.Master, 'sh', '-c', "grep -E '^N8N_API_KEY=' /etc/lifeagents/core.env 2>/dev/null | head -n1 | cut -d= -f2-")
    return (($r.Output -join '').Trim())
}

# Stop-TestStackContainers -- alle Container des Projekts anhalten (Daten-Volumes konsistent fuer Kopie und Rueckspiel).
function Stop-TestStackContainers($Names) {
    $ids = @((Invoke-Native docker @('ps', '-q', '--filter', "label=io.lifeagents.install=$($Names.Project)")).Output | Where-Object { $_ })
    if ($ids.Count) {
        $r = Invoke-Native docker (@('stop', '-t', '20') + $ids)
        if ($r.Code -ne 0) { throw "Container von $($Names.Project) liessen sich nicht anhalten: $($r.Output -join "`n")" }
    }
}

# Get-TestStackVolumeLabel -> Wert des Etiketts, '' ohne dieses Etikett, $null ohne Volume. Als JSON gelesen: eine Vorlage
# {{index .Labels "x"}} kaeme ohne ihre Anfuehrungszeichen bei Docker an (Pruefung in test_stack_test.ps1).
function Get-TestStackVolumeLabel([string]$Volume, [string]$Label) {
    $r = Invoke-Native docker @('volume', 'inspect', '-f', '{{json .Labels}}', $Volume)
    return (ConvertFrom-TestStackLabelResult -Code $r.Code -Output $r.Output -Label $Label)
}

# New-TestStackPgdata -- <p>_pgdata vor dem ersten `stack up` mit den Etiketten des Platz-Zaehlers anlegen; rt_volumes_ensure
# (runtime.sh) uebernimmt ein Volume mit dem Install-Etikett. var_la nie vorab: sein Fehlen heisst fuer den Kern „erster Lauf“.
function New-TestStackPgdata($Names, [string]$RepoRoot) {
    $v = & $Names.Volume 'pgdata'
    $own = Get-TestStackVolumeLabel $v 'io.lifeagents.install'
    if ($null -ne $own) {
        if ($own -ne $Names.Project) { throw "Volume $v gehoert nicht zu $($Names.Project) - nichts geaendert." }
        return
    }
    $r = Invoke-Native docker @('volume', 'create', '--label', "io.lifeagents.install=$($Names.Project)",
        '--label', 'lifeagents.substrate=n8n', '--label', "lifeagents.worktree=$RepoRoot", $v)
    if ($r.Code -ne 0) { throw "Volume $v liess sich nicht anlegen: $($r.Output -join "`n")" }
}

# Remove-TestStackStateVolumes -- Daten-Volumes des Projekts entfernen, nur mit dem eigenen Install-Etikett (wie
# rt_volume_rm_own); ein fremdes Volume gleichen Namens bleibt und ist ein Fehler.
function Remove-TestStackStateVolumes($Names, [string[]]$Volumes) {
    foreach ($s in $Volumes) {
        $v = & $Names.Volume $s
        $own = Get-TestStackVolumeLabel $v 'io.lifeagents.install'
        if ($null -eq $own) { continue }
        if ($own -ne $Names.Project) { throw "Volume $v traegt nicht das Etikett von $($Names.Project) - bleibt unangetastet." }
        $r = Invoke-Native docker @('volume', 'rm', $v)
        if ($r.Code -ne 0) { throw "Volume $v liess sich nicht entfernen: $($r.Output -join "`n")" }
    }
}

# Schnappschuss: je Daten-Volume ein Volume <p>snap_<vol>, Schluessel als Etikett. Kopie in einem Kurzlauf aus dem eigenen
# Abbild (alle Volumes in einem Container, ohne Netz), Verbund vorher angehalten.
function Get-TestStackSnapshotKeyStored($Names, [string[]]$Volumes) {
    $keys = @()
    foreach ($s in $Volumes) {
        $v = & $Names.Snapshot $s
        if ((Get-TestStackVolumeLabel $v 'lifeagents.snapshot-of') -ne $Names.Project) { return $null }
        $keys += Get-TestStackVolumeLabel $v 'lifeagents.snapshot-key'
    }
    $u = @($keys | Sort-Object -Unique)
    if ($u.Count -ne 1 -or -not $u[0]) { return $null }
    return $u[0]
}
function Remove-TestStackSnapshot($Names, [string[]]$Volumes) {
    foreach ($s in $Volumes) {
        $v = & $Names.Snapshot $s
        $of = Get-TestStackVolumeLabel $v 'lifeagents.snapshot-of'
        if ($null -eq $of) { continue }
        if ($of -ne $Names.Project) { throw "Volume $v ist kein Schnappschuss von $($Names.Project) - bleibt unangetastet." }
        $r = Invoke-Native docker @('volume', 'rm', $v)
        if ($r.Code -ne 0) { throw "Schnappschuss-Volume $v liess sich nicht entfernen: $($r.Output -join "`n")" }
    }
}
function Invoke-TestStackVolumeCopy($Names, [string[]]$Volumes, [switch]$Restore, [string]$RepoRoot) {
    $a = @('run', '--rm', '--network', 'none', '--label', "lifeagents.worktree=$RepoRoot")
    foreach ($s in $Volumes) {
        $data = & $Names.Volume $s; $snap = & $Names.Snapshot $s
        $from = if ($Restore) { $snap } else { $data }; $to = if ($Restore) { $data } else { $snap }
        $a += @('--mount', "type=volume,src=$from,dst=/from/$s,readonly", '--mount', "type=volume,src=$to,dst=/to/$s")
    }
    # cp -a haelt Besitzer, Rechte und Zeiten (postgres verlangt pgdata 0700 und seinen uid). Ohne Anfuehrungszeichen: die
    # Volume-Namen sind feste Bezeichner aus runtime.sh ([a-z0-9_]).
    $sh = 'set -e; for v in ' + ($Volumes -join ' ') + '; do find /to/$v -mindepth 1 -delete; cp -a /from/$v/. /to/$v/; done'
    $r = Invoke-Native docker ($a + @($Names.Image, 'sh', '-c', $sh))
    if ($r.Code -ne 0) { throw "Volume-Kopie ($(if ($Restore) { 'zurueckspielen' } else { 'Schnappschuss' })) fehlgeschlagen: $($r.Output -join "`n")" }
}
function New-TestStackSnapshot($Names, [string[]]$Volumes, [string]$Key, [string]$RepoRoot) {
    Remove-TestStackSnapshot $Names $Volumes
    foreach ($s in $Volumes) {
        $r = Invoke-Native docker @('volume', 'create', '--label', 'lifeagents.substrate=n8n-snapshot',
            '--label', "lifeagents.snapshot-of=$($Names.Project)", '--label', "lifeagents.snapshot-key=$Key",
            '--label', "lifeagents.worktree=$RepoRoot", (& $Names.Snapshot $s))
        if ($r.Code -ne 0) { throw "Schnappschuss-Volume $(& $Names.Snapshot $s) liess sich nicht anlegen: $($r.Output -join "`n")" }
    }
    Invoke-TestStackVolumeCopy $Names $Volumes -RepoRoot $RepoRoot
}
function Restore-TestStackSnapshot($Names, [string[]]$Volumes, [string]$RepoRoot) {
    Invoke-TestStackVolumeCopy $Names $Volumes -Restore -RepoRoot $RepoRoot
}

# Get-TestStackDockerNames -- alle Container-, Volume- und Abbild-Namen des Rechners (fuer Compare-TestStackTeardown).
function Get-TestStackDockerNames {
    $c = (Invoke-Native docker @('ps', '-a', '--format', '{{.Names}}')).Output
    $v = (Invoke-Native docker @('volume', 'ls', '--format', '{{.Name}}')).Output
    # Mit Digest: die Abbilder der compose.yml sind per Digest geladen und haben keinen Tag (Repository:<none>); ohne Repository
    # (namenlose Bau-Reste) zaehlt ein Abbild nicht.
    $i = (Invoke-Native docker @('images', '--digests', '--format', '{{.Repository}}:{{.Tag}}@{{.Digest}}')).Output | Where-Object { $_ -notmatch '^<none>:' }
    return @(@($c) + @($v) + @($i) | Where-Object { $_ } | Sort-Object -Unique)
}

# --- Attrappen im Pod (tests/mock_pod/start_mocks.sh) ------------------------------------------------------------------------
# Ziele der Attrappen = ihre festen Ports in start_mocks.sh (Telegram 8089, KI 8088, Paperless 8092), alle auf 127.0.0.1 des
# anchor. Weichen gehen per `stack install` an provision.sh, Paperless als Antwort (Paket-Einstellung + erfundener Schluessel).
$script:TestStackMockSwitches = [ordered]@{ LIFEAGENTS_TELEGRAM_API = 'http://127.0.0.1:8089'; LIFEAGENTS_LLM_UPSTREAM = 'http://127.0.0.1:8088' }
# Erfundenes Bot-Token und erfundener KI-Schluessel: Installer, n8n-Zugang (inject_credentials.sh baseUrl) und Gateway gehen ueber die
# Weichen an die Attrappen; echte Zugaenge aus .env braucht der Verbund nicht und bekommt sie nie (faellt die KI-Weiche bei einem
# spaeteren Lauf ohne sie weg, scheitert der Aufruf an api.anthropic.com am erfundenen Schluessel statt Kosten zu machen).
$script:TestStackMockAnswers  = [ordered]@{ CONFIG_GENERAL_PAPERLESS_URL = 'http://127.0.0.1:8092'; PAPERLESS_API_TOKEN = 'mock-paperless-token'
    TELEGRAM_BOT_TOKEN = $script:TestInventedBotToken; ANTHROPIC_API_KEY = 'sk-ant-test-fake-key-for-the-mock-llm' }

# Get-TestStackBash -- bash fuer start_mocks.sh: unter Windows das von Git (Git Bash, cygpath), nie das von WSL
# (C:\Windows\System32\bash.exe kennt weder docker.exe noch die Windows-Pfade); sonst bash aus PATH.
function Get-TestStackBash {
    if ($env:OS -ne 'Windows_NT') { return 'bash' }
    $exec = ([string](& git --exec-path)).Trim() -replace '/', '\'
    $gitRoot = Split-Path (Split-Path (Split-Path $exec -Parent) -Parent) -Parent
    foreach ($c in @((Join-Path $gitRoot 'bin\bash.exe'), (Join-Path $gitRoot 'usr\bin\bash.exe'))) { if (Test-Path $c) { return $c } }
    throw "Git Bash nicht gefunden (gesucht unter $gitRoot)."
}
# Start-TestStackMocks -- Attrappen (neu) starten, ohne -Which alle drei; nach jedem Start des anchor noetig, weil Container im
# Namensraum eines neu gestarteten anchor ihr Netz verlieren. Logs nach <LogDir>\mocks. -Env: Umgebung fuer start_mocks.sh
# (MOCK_LLM_TODAY, MOCK_TG_DOCS), nur fuer diesen Aufruf gesetzt.
function Start-TestStackMocks {
    param([Parameter(Mandatory)]$Names, [Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$LogDir,
          [ValidateSet('tg', 'llm', 'pl')][string[]]$Which = @(), [hashtable]$Env = @{})
    $bash = Get-TestStackBash
    $script = (Join-Path $RepoRoot 'tests\mock_pod\start_mocks.sh') -replace '\\', '/'
    $logs = (Join-Path $LogDir 'mocks') -replace '\\', '/'
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$Env[$k]) }
    try { $r = Invoke-Native $bash (@($script, $Names.Project, $logs) + $Which) }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    if ($r.Code -ne 0) { throw "start_mocks.sh fehlgeschlagen (Exit $($r.Code)):`n$($r.Output -join "`n")" }
}
# Remove-TestStackSideContainers -- Attrappen und Bruecke (Select-TestStackSideContainers) entfernen, vor dem anchor.
function Remove-TestStackSideContainers($Names) {
    $rows = @((Invoke-Native docker @('ps', '-a', '--filter', "label=io.lifeagents.install=$($Names.Project)", '--format', '{{.Names}}|{{.Labels}}')).Output | Where-Object { $_ })
    foreach ($c in (Select-TestStackSideContainers -Rows $rows -Project $Names.Project)) {
        $r = Invoke-Native docker @('rm', '-fv', $c)
        if ($r.Code -ne 0 -and ($r.Output -join ' ') -notmatch 'No such container|already in progress') { throw "Container $c liess sich nicht entfernen: $($r.Output -join "`n")" }
    }
}

# --- Suiten ohne laufenden Verbund (scripts/dev/*_test.ps1 mit cases.sh-Attrappen-Ketten) ---------------------------------------
# Eine Suite, die nur bash und Werkzeuge braucht, laeuft im Verbund-Weg in einem Wegwerf-Container aus dem master-Abbild des
# Arbeitsstands (<projekt>-master:wt), nicht im Substrat. Dieselben docker cp/docker exec wie klassisch, weil die Runner eine Wurzel
# mit provisioning/ UND den Fall-Ordnern daneben erwarten (ein Einhaengen braucht einen Docker-Dienst, der Rechner-Pfade sieht;
# ein Tar ueber stdin belegt das stdin der Faelle). Der Container hat ein eigenes Netz: die Mock-Ports der Suiten (8082, 8084,
# 8093 ...) kollidieren nie mit einem Nachbarn.
# Suiten, die den laufenden Verbund brauchen (Datenbank, Timer, Gateway, n8n-Patches), laufen im master-Container des Verbunds (Abschnitt unten).

# Get-TestSuiteRuntime -- N8NTEST_RUNTIME = classic|compose; ohne Wert classic (Standard bis zur Umschaltung der Matrix). Ein
# unbekannter Wert bricht ab: der stille Rueckfall liesse die Suite auf dem falschen Unterbau laufen.
function Get-TestSuiteRuntime {
    $r = [string]$env:N8NTEST_RUNTIME
    if (-not $r) { return 'classic' }
    if ($r -cnotin @('classic', 'compose')) { throw "N8NTEST_RUNTIME '$r' ungueltig (classic oder compose)." }
    return $r
}

function Get-TestSuiteScratchName([string]$Project, [string]$Suite) {
    Assert-TestStackProject $Project
    if ($Suite -cnotmatch '^[a-z0-9][a-z0-9_]{1,40}$') { throw "Suiten-Name '$Suite' ungueltig (klein, Ziffern, '_')." }
    return "$Project-suite-" + ($Suite -replace '_', '-')
}

# Get-TestSuiteScratchRunArgs -- die Argumente von docker run (rein, testbar). Kein Install-Etikett: der Container gehoert nicht
# zum Verbund (Select-TestStackSideContainers, Platz-Zaehler). Substrat-Etikett n8n-suite + Worktree-Etikett: der Session-Ende-
# Haken raeumt ihn mit ab (Get-WorktreeComposeTargets, lifeagents.substrate like 'n8n*'). sleep 1800: raeumt sich auch bei einem
# toten Skript selbst ab (--rm). --init: PID 1 ist sonst `sleep` und raeumt verwaiste Prozesse nicht ab; ein beendeter Waise bliebe
# als Zombie stehen, und `kill -0` auf ihn meldet „lebt“ (mock_runtime KZ.*: ein Schritt nach der Zeitgrenze). Im klassischen Substrat
# raeumt systemd als PID 1 auf (Waise nach kill = Zombie).
# Das Abbild setzt LIFEAGENTS_RUNTIME=compose (Dockerfile ENV); ein Runner, der den klassischen Weg prueft, setzt die Variable selbst.
function Get-TestSuiteScratchRunArgs {
    param([Parameter(Mandatory)]$Names, [Parameter(Mandatory)][string]$Suite, [Parameter(Mandatory)][string]$RepoRoot)
    return @('run', '-d', '--rm', '--init', '--name', (Get-TestSuiteScratchName $Names.Project $Suite),
        '--label', 'lifeagents.substrate=n8n-suite', '--label', "lifeagents.worktree=$RepoRoot",
        $Names.Image, 'sleep', '1800')
}

# Resolve-TestSuiteContainer -- der Container, in dem die Suite ihre Dateien ablegt und die Fall-Runner faehrt.
# classic: das Substrat (Zustandsdatei, Get-TestN8nConnection aus test_n8n_state.ps1 -- der Aufrufer hat es dot-gesourct).
# compose: master-Abbild aus dem Arbeitsstand (Bau-Cache: gleicher Stand = gleiches Abbild) + Wegwerf-Container. Der Projektname
# kommt ausdruecklich aus N8NTEST_CONTAINER (wie bootstrap_test_stack.ps1, kein geteilter Standard). Das Abbild traegt denselben
# Tag wie das des Verbunds gleichen Namens: ein Lauf nach einer Aenderung setzt ihn um, der naechste -Reset dieses Verbunds
# installiert dann kalt (Schnappschuss-Schluessel haengt an der Abbild-ID); wer das nicht will, nimmt einen eigenen Namen.
function Resolve-TestSuiteContainer {
    param([Parameter(Mandatory)][string]$Suite, [Parameter(Mandatory)][string]$RepoRoot)
    if ((Get-TestSuiteRuntime) -eq 'classic') {
        return [pscustomobject]@{ Runtime = 'classic'; Container = (Get-TestN8nConnection).Container; Scratch = $false }
    }
    if (-not $env:N8NTEST_CONTAINER) { throw 'N8NTEST_RUNTIME=compose braucht einen eigenen Projektnamen in $env:N8NTEST_CONTAINER (z. B. s4t3a, kein geteilter Standard).' }
    $names = Get-TestStackNames $env:N8NTEST_CONTAINER
    $logDir = Get-TestStackLogDir $names.Project
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    [void](New-TestStackImage -RepoRoot $RepoRoot -Names $names -LogDir $logDir)
    $c = Get-TestSuiteScratchName $names.Project $Suite
    [void](Invoke-Native docker @('rm', '-fv', $c))
    $r = Invoke-Native docker (Get-TestSuiteScratchRunArgs -Names $names -Suite $Suite -RepoRoot $RepoRoot)
    if ($r.Code -ne 0) { throw "Wegwerf-Container $c liess sich nicht starten: $($r.Output -join "`n")" }
    return [pscustomobject]@{ Runtime = 'compose'; Container = $c; Scratch = $true }
}

# Remove-TestSuiteScratch -- raeumt den Wegwerf-Container ab (immer `rm -fv`); fuer das klassische Substrat ein No-op.
function Remove-TestSuiteScratch($Target) {
    if ($null -ne $Target -and $Target.Scratch) { [void](Invoke-Native docker @('rm', '-fv', $Target.Container)) }
}

# --- Suiten im laufenden Verbund (update_chat_test, bot_menu_test, llm_gateway_test, backup_test) ------------------------------
# Sie laufen im master des Verbunds (Netz-Namensraum des anchor: 127.0.0.1 gilt dort wie fuer n8n und den echten Gateway), nicht in
# einem Wegwerf-Container: sie brauchen die echte Datenbank, die Volumes und die Dienste. Zwei Dinge gibt es dort anders als
# klassisch: statt der systemd-Timer die Tick-Schleife des master, statt der transienten systemd-Einheiten eigene Container.

# Assert-TestSuiteStateRuntime -State <Zustandsdatei-Objekt> -- N8NTEST_RUNTIME und der laufende Unterbau muessen uebereinstimmen.
function Assert-TestSuiteStateRuntime {
    param([Parameter(Mandatory)]$State)
    $want = Get-TestSuiteRuntime; $have = Get-TestN8nRuntime -State $State
    if ($want -ne $have) {
        throw "N8NTEST_RUNTIME=$want, aber das laufende Substrat ist '$have' (Zustandsdatei). Passenden Unterbau starten (bootstrap_test_stack.ps1 fuer compose, bootstrap_test_n8n.ps1 fuer classic) oder N8NTEST_RUNTIME angleichen."
    }
}

# Get-TestStackTickScript -Action pause|resume -- sh-Text. Die Schleife im master (compose.yml) ruft `lifeagents update --tick` nur,
# wenn /usr/local/bin/lifeagents ausfuehrbar ist. Ein `chmod a-x` (so pausiert heartbeat_e2e.sh, das die CLI nie selbst ruft) bremste
# auch den Runner, der die CLI direkt ausfuehrt (`command -v lifeagents`, update_runner.sh) -> Link-Tausch: waehrend der Pause liegt die
# CLI unter /usr/local/sbin (steht vor /usr/local/bin im PATH), /usr/local/bin/lifeagents fehlt der Schleife. Ein Merker (stillgelegt-
# Datei) kaeme nicht in Frage: er sperrt auch CLI und Installer. Beim Pausieren wartet das Skript auf einen schon laufenden Schritt der
# Schleife; das Muster ist am Anfang der Befehlszeile verankert, weil die Schleife (PID 1) den Text selbst in ihrer Befehlszeile traegt.
function Get-TestStackTickScript {
    param([Parameter(Mandatory)][string]$Action)
    $cli = '/usr/local/lib/lifeagents/bin/lifeagents'
    switch ($Action) {
        'pause' { return "mkdir -p /usr/local/sbin; ln -sf $cli /usr/local/sbin/lifeagents; rm -f /usr/local/bin/lifeagents; i=0; while pgrep -f '^[^ ]*bash [^ ]*lifeagents update --(tick|run-requested|check)' >/dev/null && [ `$i -lt 240 ]; do sleep 0.5; i=`$((i+1)); done; [ `$i -lt 240 ]" }
        'resume' { return "ln -sf $cli /usr/local/bin/lifeagents; rm -f /usr/local/sbin/lifeagents" }
        default { throw "Tick-Aktion '$Action' unbekannt (pause oder resume)." }
    }
}
function Get-TestStackTickArgs {
    param([Parameter(Mandatory)][string]$Master, [Parameter(Mandatory)][string]$Action)
    if (-not $Master) { throw 'Tick: master-Container fehlt.' }
    return @('exec', $Master, 'sh', '-c', (Get-TestStackTickScript -Action $Action))
}
# Suspend-/Resume-TestStackTick -Master <p>-master -- nur im Verbund (klassisch pausieren die Suiten ihre Timer selbst). Resume
# gehoert in ein finally; ein vergessenes Resume heilt der naechste -Reset (die CLI liegt im Volume rt_tree). Die Pause ist ein einziger
# Schalter je master, ohne Besitzer und Zaehler: zwei Suiten gleichzeitig auf demselben Verbund stuenden sich im Weg (die zweite
# setzt die erste fort). Je Verbund eine Suite zur Zeit, parallele Suiten bekommen je einen eigenen Verbund.
function Suspend-TestStackTick([Parameter(Mandatory)][string]$Master) {
    $r = Invoke-Native docker (Get-TestStackTickArgs -Master $Master -Action pause)
    if ($r.Code -ne 0) { throw "Tick-Schleife von $Master liess sich nicht pausieren (ein Schritt lief nach 2 Min noch?): $($r.Output -join ' | ')" }
}
function Resume-TestStackTick([Parameter(Mandatory)][string]$Master) {
    $r = Invoke-Native docker (Get-TestStackTickArgs -Master $Master -Action resume)
    # Kein throw: Resume laeuft im finally und darf einen Fehler der Suite nicht ueberdecken. Sichtbar machen, denn ohne Fortsetzen
    # steht die Tick-Schleife (Updates, Pruefungen, Sicherung) still.
    if ($r.Code -ne 0) { Write-Host "    [WARN] Tick-Schleife von $Master liess sich nicht fortsetzen (Exit $($r.Code)): $($r.Output -join ' | ') -- bootstrap_test_stack.ps1 -Reset stellt sie her." -ForegroundColor Yellow }
}

# Get-TestSubstrateTimerScript -Action pause|resume -- sh-Text fuer das klassische Substrat (systemd). Dort laufen die echten
# lifeagents-Zeitgeber (update-run jede Minute, update-check, backup stuendlich) neben den Suiten; jeder nimmt oder probt die
# Update-Sperre und liesse einen Runner-Fall mit "Sperre belegt" ins Leere laufen (die Sicherung haelt sie waehrend ihres Laufs).
# Pausieren legt alle aktiven lifeagents-*.timer still, keine feste Liste: ein neuer Zeitgeber ist sofort mit dabei. Danach wartet es
# auf einen schon laufenden Dienst gleichen Namens (nicht per `is-active --quiet`: ein laufender oneshot steht auf `activating`,
# Exit 3, und gaelte als fertig). Die Liste steht in /run: ein Fortsetzen nach einem abgebrochenen Lauf findet dieselben
# Zeitgeber, ein zweites Pausieren vergisst keinen.
function Get-TestSubstrateTimerScript {
    param([Parameter(Mandatory)][string]$Action)
    $list = '/run/lifeagents-test-timers-stopped'
    switch ($Action) {
        'pause' { return @"
L=$list; touch `$L
for t in `$(systemctl list-units --type=timer --state=active --no-legend --plain 'lifeagents-*.timer' | awk '{print `$1}'); do
  systemctl stop "`$t" || exit 1
  grep -qxF "`$t" `$L || echo "`$t" >> `$L
done
i=0; busy=1
while [ `$i -lt 300 ]; do
  busy=0
  for t in `$(cat `$L); do
    u="`${t%.timer}.service"; s=`$(systemctl is-active "`$u")
    case "`$s" in inactive|failed|unknown) ;; *) busy=1 ;; esac
  done
  [ `$busy = 0 ] && break
  sleep 0.2; i=`$((i+1))
done
[ `$busy = 0 ]
"@ }
        'resume' { return @"
L=$list; [ -s `$L ] || exit 0
rc=0; while read -r t; do systemctl start "`$t" || rc=1; done < `$L
rm -f `$L; exit `$rc
"@ }
        default { throw "Zeitgeber-Aktion '$Action' unbekannt (pause oder resume)." }
    }
}
# Suspend-/Resume-TestTimers -Container <c> -Runtime classic|compose -- die eine Adresse, mit der eine Suite ihre Umgebung ruhig
# stellt: im Verbund die Tick-Schleife des master (Suspend-TestStackTick), klassisch die Zeitgeber des Substrats. Resume gehoert in
# ein finally. Je Substrat eine Suite zur Zeit (wie beim Tick: ein Schalter ohne Zaehler).
function Suspend-TestTimers([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$Runtime) {
    if ($Runtime -eq 'compose') { Suspend-TestStackTick -Master $Container; return }
    $r = Invoke-Native docker @('exec', $Container, 'sh', '-c', (Get-TestSubstrateTimerScript -Action pause))
    if ($r.Code -ne 0) { throw "Zeitgeber von $Container liessen sich nicht stilllegen (ein Stopp scheiterte oder ein Dienst lief nach 60 s noch): $($r.Output -join ' | ')" }
}
function Resume-TestTimers([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$Runtime) {
    if ($Runtime -eq 'compose') { Resume-TestStackTick -Master $Container; return }
    $r = Invoke-Native docker @('exec', $Container, 'sh', '-c', (Get-TestSubstrateTimerScript -Action resume))
    # Kein throw: Resume laeuft im finally und darf einen Fehler der Suite nicht ueberdecken.
    if ($r.Code -ne 0) { Write-Host "    [WARN] Zeitgeber von $Container liessen sich nicht fortsetzen (Exit $($r.Code)): $($r.Output -join ' | ')" -ForegroundColor Yellow }
}

# Get-TestStackUnitName -Project <p> -Unit <n8ntest-gwt…> -- Name des Container, der die gleichnamige systemd-Einheit der klassischen
# Gateway-Suite ersetzt. Nie im Standard-Projekt (Assert-TestStackProject).
function Get-TestStackUnitName {
    param([Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)][string]$Unit)
    Assert-TestStackProject $Project
    if ($Unit -cnotmatch '^n8ntest-gwt(-[a-z]+)?$') { throw "Einheit '$Unit' ungueltig (n8ntest-gwt oder n8ntest-gwt-<name>)." }
    return "$Project-$Unit"
}
# Gemeinsame Argumente: Namensraum des anchor (127.0.0.1 wie der echte Gateway), Etiketten fuer den Session-Ende-Haken
# (lifeagents.substrate=n8n-suite, Worktree) und kein Install-Etikett: der Container gehoert nicht zum Verbund, `stack uninstall`
# und der Platz-Zaehler sehen ihn nicht.
function Get-TestStackUnitCommon([string]$Project, [string]$Unit, [string]$RepoRoot) {
    return @('--name', (Get-TestStackUnitName -Project $Project -Unit $Unit), '--network', "container:$Project-anchor",
        '--label', 'lifeagents.substrate=n8n-suite', '--label', "lifeagents.worktree=$RepoRoot")
}
# Get-TestStackGatewayUnitArgs -- docker run fuer ein Wegwerf-Gateway: Abbild und Nutzer des echten Gateway-Containers, sein Code
# (/gw/server.js aus dem Volume gw_code, nur lesbar), aber die Umgebung der Suite statt gateway.env. Kein STATE_DIRECTORY: der
# echte Zaehler (Volume gw_state) bleibt unberuehrt; Suiten, die einen Zaehler brauchen, setzen LLM_GATEWAY_USAGE_DIR (tmpfs).
function Get-TestStackGatewayUnitArgs {
    param([Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)][string]$Unit, [Parameter(Mandatory)][string]$Image,
          [string[]]$Env = @(), [Parameter(Mandatory)][string]$RepoRoot)
    $a = @('run', '-d') + (Get-TestStackUnitCommon $Project $Unit $RepoRoot) + @('--user', '1000:1000', '-v', "${Project}_gw_code:/gw:ro",
        '-e', 'NODE_OPTIONS=--dns-result-order=ipv4first')
    foreach ($e in $Env) { $a += @('-e', $e) }
    # Der Zaehler-Ordner ist im Verbund je Einheit ein eigener tmpfs (klassisch teilen sich Einheiten einen Ordner im Substrat).
    if (@($Env | Where-Object { $_ -like 'LLM_GATEWAY_USAGE_DIR=*' }).Count -gt 0) { $a += @('--tmpfs', '/tmp/gwtest_usage:rw,mode=1777') }
    return $a + @('--entrypoint', 'node', $Image, '/gw/server.js')
}
# Get-TestStackNodeUnitCreateArgs -- docker create fuer eine Attrappe (Stub-LLM, Telegram) im master-Abbild; das Skript kopiert der
# Aufrufer mit docker cp hinein, danach docker start (ein Bind-Mount braeuchte einen Docker-Dienst, der Rechner-Pfade sieht).
function Get-TestStackNodeUnitCreateArgs {
    param([Parameter(Mandatory)][string]$Project, [Parameter(Mandatory)][string]$Unit, [Parameter(Mandatory)][string]$Image,
          [string[]]$Env = @(), [Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$RepoRoot)
    $a = @('create') + (Get-TestStackUnitCommon $Project $Unit $RepoRoot)
    foreach ($e in $Env) { $a += @('-e', $e) }
    return $a + @('--entrypoint', 'node', $Image, $ScriptPath)
}