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

# Get-TestStackPorts <N8NTEST_PORT> -- der Port ist die REST-Bruecke; der Kern sucht seine zwei Ports (edge, wizard) in den neun
# folgenden (LA_CORE_PORTS), damit ein Verbund im eigenen Bereich der Session bleibt.
function Get-TestStackPorts([string]$Port) {
    if ($Port -notmatch '^\d{4,5}$' -or [int]$Port -lt 1024 -or [int]$Port -gt 65520) { throw "N8NTEST_PORT '$Port' ungueltig (1024-65520)." }
    $b = [int]$Port
    return [pscustomobject]@{ Bridge = $b; CoreRange = "$($b + 1)-$($b + 9)" }
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

# Get-TestInstallEnvMap <repo> -- .env-Schluessel TEST_<x> -> Kern-Schluessel, dieselbe Zuordnung wie bootstrap_test_n8n.ps1
# (feste Liste + je Paket die env-Namen aus manifest.json credentials). Zwei Kopien bis P6, dann faellt der klassische Bootstrap.
function Get-TestInstallEnvMap([string]$RepoRoot) {
    $map = [ordered]@{
        'TEST_N8N_OWNER_EMAIL'    = 'N8N_OWNER_EMAIL'
        'TEST_N8N_OWNER_PASSWORD' = 'N8N_OWNER_PASSWORD'
        'TEST_N8N_ENCRYPTION_KEY' = 'N8N_ENCRYPTION_KEY'
        'TEST_PG_PASSWORD'        = 'N8N_DB_PASSWORD'
        'TEST_TELEGRAM_BOT_TOKEN' = 'TELEGRAM_BOT_TOKEN'
        'TEST_TELEGRAM_CHAT_ID'   = 'OWNER_CHAT_ID'
        'TEST_GOOGLE_API_KEY'     = 'GOOGLE_API_KEY'
        'TEST_ANTHROPIC_API_KEY'  = 'ANTHROPIC_API_KEY'
        'TEST_HARNESS_SECRET'     = 'TEST_HARNESS_SECRET'
        'TEST_OWNER_FIRST_NAME'   = 'OWNER_FIRST_NAME'
        'TEST_OWNER_LAST_NAME'    = 'OWNER_LAST_NAME'
        'TEST_OWNER_BIRTH_DATE'   = 'OWNER_BIRTH_DATE'
        'TEST_OWNER_LANGUAGE'     = 'OWNER_LANGUAGE'
    }
    foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | Sort-Object Name)) {
        $mfPath = Join-Path $pkgDir.FullName 'manifest.json'
        if (-not (Test-Path $mfPath)) { continue }
        $mf = [System.IO.File]::ReadAllText($mfPath, $script:TestStackUtf8) | ConvertFrom-Json
        if ($null -eq $mf.credentials) { continue }
        foreach ($credProp in ($mf.credentials.PSObject.Properties | Where-Object { $_.Name -notlike '_*' })) {
            if ($null -eq $credProp.Value.env) { continue }
            foreach ($envKeyProp in $credProp.Value.env.PSObject.Properties) {
                if (-not $map.Contains("TEST_$($envKeyProp.Name)")) { $map["TEST_$($envKeyProp.Name)"] = [string]$envKeyProp.Name }
            }
        }
    }
    return $map
}

# ConvertTo-TestStackExtra -- Zusatz-Zeilen fuer render_ci_answers.js --extra-stdin: gesetzte TEST_*-Werte als Kern-Schluessel und
# die Schalter des Bootstraps. Ohne Schalter keine Zeile: die Vorgaben (Link-Knoepfe, nur Geaendertes) stehen in DEV_KEYS dort.
function ConvertTo-TestStackExtra {
    param([Parameter(Mandatory)]$Map, [Parameter(Mandatory)][hashtable]$Values, [switch]$HitlChatApproval, [switch]$FullDeploy, [string]$SerialTools = '')
    $out = New-Object System.Text.StringBuilder
    foreach ($k in $Map.Keys) {
        $v = [string]$Values[$k]
        if (-not $v) { continue }
        if ($v -match '[\x00-\x1f\x7f]') { throw ".env: Wert von $k enthaelt ein Steuerzeichen." }
        [void]$out.Append("$($Map[$k])=$v`n")
    }
    if ($HitlChatApproval) { [void]$out.Append("LIFEAGENTS_HITL_CHAT_APPROVAL=true`n") }
    if ($FullDeploy) { [void]$out.Append("LIFEAGENTS_DEPLOY_FULL=1`n") }
    if ($SerialTools) {
        if ($SerialTools -notin @('0', '1')) { throw "LLM_GATEWAY_SERIAL_TOOLS nur 0 oder 1, nicht '$SerialTools'." }
        [void]$out.Append("LLM_GATEWAY_SERIAL_TOOLS=$SerialTools`n")
    }
    return $out.ToString()
}

# Compare-TestStackTeardown -- Abgleich der Docker-Namen (Container, Volumes, Abbilder) vor und nach dem Abbau. Zum Verbund
# gehoeren nur die Container mit seinem Install-Etikett (-Labeled, vom Aufrufer vor dem Abbau gelesen), die Volumes <p>_* und
# <p>snap_* und das Abbild <p>-master:wt; andere Objekte mit demselben Anfang gehoeren der Session (s4t0-dbtest …). Fehlen darf
# nur, was zum Verbund gehoert, und davon darf nichts bleiben. Rueckgabe = Funde als Text, leer = sauber.
function Test-TestStackOwnName([string]$Project, [string]$Name, [string[]]$Labeled) {
    if ($Labeled -contains $Name) { return $true }
    $q = [regex]::Escape($Project)
    return ($Name -match "^$q(_|snap_)[a-z0-9_]+$" -or $Name -match "^$q-master:wt@")
}
function Compare-TestStackTeardown([string]$Project, [string[]]$Before, [string[]]$After, [string[]]$Labeled = @()) {
    $f = @()
    foreach ($n in $Before) {
        if (($After -notcontains $n) -and -not (Test-TestStackOwnName $Project $n $Labeled)) { $f += "fremdes Objekt fehlt nach dem Abbau (oder ein Nachbar baute zugleich ab): $n" }
    }
    foreach ($n in $After) {
        if (Test-TestStackOwnName $Project $n $Labeled) { $f += "eigenes Objekt blieb nach dem Abbau: $n" }
    }
    return $f
}

# --- Docker-Schritte (bewiesen auf dem echten Weg: bootstrap_test_stack.ps1 kalt, -Reset, -Down) ----------------------------
# Invoke-TestStackNative -- kurzer Docker-Aufruf, Ausgabe + Exit; EAP lokal Continue (PS 5.1: native stderr unter Stop wirft).
function Invoke-TestStackNative([string[]]$DockerArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & docker @DockerArgs 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Code = $code; Output = @($out | ForEach-Object { "$_" }) }
}

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
    $id = ((Invoke-TestStackNative @('image', 'inspect', '-f', '{{.Id}}', $Names.Image)).Output -join '').Trim()
    if ($id -notmatch '^sha256:[0-9a-f]{64}$') { throw "Abbild $($Names.Image) nach dem Bau nicht lesbar ($id)." }
    return [pscustomobject]@{ ImageId = $id; Tree = $tree }
}

# Invoke-TestStackCore -- der Kern in seiner einen Aufruf-Form, stdin aus Datei (Antwort-Datei bei install), Ergebnis = result.
function Invoke-TestStackCore {
    param([Parameter(Mandatory)]$Names, [Parameter(Mandatory)]$Ports, [Parameter(Mandatory)][string]$Verb,
          [string[]]$Rest = @(), [string]$StdinFile = '', [Parameter(Mandatory)][string]$LogDir)
    if (-not $StdinFile) { $StdinFile = Get-TestStackEmptyFile $LogDir }
    $a = @('run', '--rm', '-i', '--name', $Names.Core, '--label', "io.lifeagents.install=$($Names.Project)",
        '--env', 'LA_CORE=1', '--env', "LA_PROJECT=$($Names.Project)", '--env', "LA_CORE_PORTS=$($Ports.CoreRange)",
        '--mount', 'type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock', $Names.Image, 'stack', $Verb, '--json') + $Rest
    $r = Invoke-TestStackProcess -DockerArgs $a -StdinFile $StdinFile -LogBase (Join-Path $LogDir "core-$Verb")
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
    $js = Join-Path $RepoRoot 'tests\wizard\render_ci_answers.js'
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
    $id = ((Invoke-TestStackNative @('ps', '-aq', '--filter', "name=^/$($Names.Bridge)$")).Output -join '').Trim()
    if ($id) { [void](Invoke-TestStackNative @('rm', '-fv', $Names.Bridge)) }
}
function Start-TestStackBridge {
    param([Parameter(Mandatory)]$Names, [Parameter(Mandatory)]$Ports, [Parameter(Mandatory)][string]$RepoRoot)
    Remove-TestStackBridge $Names
    $r = Invoke-TestStackNative @('run', '-d', '--name', $Names.Bridge, '--network', $Names.Network,
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
    $r = Invoke-TestStackNative @('exec', $Names.Master, 'sh', '-c', "grep -E '^N8N_API_KEY=' /etc/lifeagents/core.env 2>/dev/null | head -n1 | cut -d= -f2-")
    return (($r.Output -join '').Trim())
}

# Stop-TestStackContainers -- alle Container des Projekts anhalten (Daten-Volumes konsistent fuer Kopie und Rueckspiel).
function Stop-TestStackContainers($Names) {
    $ids = @((Invoke-TestStackNative @('ps', '-q', '--filter', "label=io.lifeagents.install=$($Names.Project)")).Output | Where-Object { $_ })
    if ($ids.Count) {
        $r = Invoke-TestStackNative (@('stop', '-t', '20') + $ids)
        if ($r.Code -ne 0) { throw "Container von $($Names.Project) liessen sich nicht anhalten: $($r.Output -join "`n")" }
    }
}

# Get-TestStackVolumeLabel -> Wert des Etiketts, '' ohne dieses Etikett, $null ohne Volume. Als JSON gelesen: eine Vorlage
# {{index .Labels "x"}} kaeme ohne ihre Anfuehrungszeichen bei Docker an (Pruefung in test_stack_test.ps1).
function Get-TestStackVolumeLabel([string]$Volume, [string]$Label) {
    $r = Invoke-TestStackNative @('volume', 'inspect', '-f', '{{json .Labels}}', $Volume)
    if ($r.Code -ne 0) { return $null }
    $labels = ($r.Output -join '') | ConvertFrom-Json
    if ($null -eq $labels -or $null -eq $labels.$Label) { return '' }
    return [string]$labels.$Label
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
    $r = Invoke-TestStackNative @('volume', 'create', '--label', "io.lifeagents.install=$($Names.Project)",
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
        $r = Invoke-TestStackNative @('volume', 'rm', $v)
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
        $r = Invoke-TestStackNative @('volume', 'rm', $v)
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
    $r = Invoke-TestStackNative ($a + @($Names.Image, 'sh', '-c', $sh))
    if ($r.Code -ne 0) { throw "Volume-Kopie ($(if ($Restore) { 'zurueckspielen' } else { 'Schnappschuss' })) fehlgeschlagen: $($r.Output -join "`n")" }
}
function New-TestStackSnapshot($Names, [string[]]$Volumes, [string]$Key, [string]$RepoRoot) {
    Remove-TestStackSnapshot $Names $Volumes
    foreach ($s in $Volumes) {
        $r = Invoke-TestStackNative @('volume', 'create', '--label', 'lifeagents.substrate=n8n-snapshot',
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
    $c = (Invoke-TestStackNative @('ps', '-a', '--format', '{{.Names}}')).Output
    $v = (Invoke-TestStackNative @('volume', 'ls', '--format', '{{.Name}}')).Output
    # Mit Digest: die Abbilder der compose.yml sind per Digest geladen und haben keinen Tag (Repository:<none>); ohne Repository
    # (namenlose Bau-Reste) zaehlt ein Abbild nicht.
    $i = (Invoke-TestStackNative @('images', '--digests', '--format', '{{.Repository}}:{{.Tag}}@{{.Digest}}')).Output | Where-Object { $_ -notmatch '^<none>:' }
    return @(@($c) + @($v) + @($i) | Where-Object { $_ } | Sort-Object -Unique)
}

# Wait-TestStackSlot -- Parallel-Grenze wie Wait-SubstrateSlot in bootstrap_test_n8n.ps1 (dieselbe Zaehlung aus
# substrate_reservations.ps1; die Zaehlung des Verbunds an pgdata liefert T5 dort nach), eigener Name = Projekt.
function Wait-TestStackSlot([string]$Own) {
    $max  = if ($env:N8NTEST_MAX_PARALLEL) { [int]$env:N8NTEST_MAX_PARALLEL } else { 2 }
    $wait = if ($env:N8NTEST_WAIT_MIN)     { [int]$env:N8NTEST_WAIT_MIN }     else { 15 }
    $deadline = (Get-Date).AddMinutes($wait)
    while ($true) {
        $running = @(Get-RunningSubstrates | Where-Object { $_.Name -ne $Own -and $_.Name -notlike "$Own-*" } | ForEach-Object { $_.Name })
        $slot = Get-SlotAvailability -Running $running -Reservations @(Read-SlotReservations) -Own $Own -Max $max
        if ($slot.Free) { return }
        $msg = Format-SlotBlockedMessage -Availability $slot -Own $Own -Max $max
        if ((Get-Date) -ge $deadline) { throw "Parallel-Limit: $msg`nEin fremdes Substrat nicht abreissen; warten oder `$env:N8NTEST_MAX_PARALLEL bewusst anheben." }
        Write-Host "Parallel-Limit: $msg -- warte auf einen freien Platz ..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }
}
