#Requires -Version 5.1
# bootstrap_test_n8n.ps1 — ephemere, hermetische Test-n8n-Instanz fuer die Integrations-Tiers
# (infra_test/n8n_test/orch_test/e2e_test/multiturn_test) — raus aus Prod, rein in Docker.
#
# Faehrt einen WEGWERF-Debian-12-Container mit ECHTEM systemd (jrei/systemd-debian:12) und fahrt
# darin den byte-identischen Applier `provisioning/provision.sh --profile dev --unattended <env-file>`
# (PostgreSQL + n8n in den Versionen aus provision.sh + Schema + Seeds + Owner-Bootstrap + Workflows/Credentials; KEIN Reverse Proxy —
# der ist seit Install-UX-Phase 2 bring-your-own). Damit ist
# das Test-Substrat dasselbe wie Prod (Debian 12 + derselbe provision.sh), nur der ephemere Host ist
# ein Docker-Container statt eines Proxmox-LXC -> kein Drift, der bash-Kern bleibt unangetastet.
#
# WARUM systemd-in-Docker: provision.sh steuert alle Dienste ueber systemctl (PG/n8n als units),
# daher MUSS der Container systemd als PID 1 fahren. Auf cgroup v2 (Docker Desktop/WSL2) genuegt
#   --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw
# (verifiziert: systemctl is-system-running -> running). Kein .wslconfig-Eingriff noetig.
#
# WARUM die socat-Bruecke: n8n bindet im Container an 127.0.0.1:5678 (N8N_LISTEN_ADDRESS, fuer Prod
# korrekt — der (bring-your-own) Reverse Proxy ist die oeffentliche Flaeche). Docker-Port-Publishing
# erreicht einen an die Container-Loopback gebundenen Dienst NICHT (die Tiers brauchen aber die
# REST-API). Loesung: eine TEST-ONLY socat-Bruecke (0.0.0.0:<bridge> -> 127.0.0.1:5678) im Container,
# auf den Host publiziert. Der provision.sh-Kern bleibt dadurch byte-identisch (keine Listener-Aenderung).
#
# WARUM TEST_HARNESS_HEADER=X-Test-Auth: die Harness-Webhooks nutzen httpHeaderAuth; alle Test-Skripte
# senden den Header `X-Test-Auth`. inject_credentials.sh defaultet auf `x-harness-secret` -> ohne den
# Override wuerde die Credential mit falschem Header-Namen angelegt -> infra_test bekaeme 403.
#
# Verbindungswerte (URL + frisch geminteter N8N_API_KEY) landen in .local/n8ntest_state.json; die
# Tier-Skripte lesen sie ueber scripts/dev/test_n8n_state.ps1 (Prod-.env-Keys werden nicht mehr gelesen).
#
# Usage:
#   .\scripts\dev\bootstrap_test_n8n.ps1            # Container hoch + provision.sh (idempotent)
#   .\scripts\dev\bootstrap_test_n8n.ps1 -Reset     # Container verwerfen und frisch bauen
#   .\scripts\dev\bootstrap_test_n8n.ps1 -Down      # Container entfernen (Teardown), State loeschen
#   .\scripts\dev\bootstrap_test_n8n.ps1 -SkipInstall   # nur Container hoch (Debug)
#   .\scripts\dev\bootstrap_test_n8n.ps1 -Reset -Version v0.1.0   # gepinntes Release abnehmen (s. u.)
#   .\scripts\dev\bootstrap_test_n8n.ps1 -HitlChatApproval        # Bestaetigungs-Knoepfe im Chat erzwingen (hitl_gate_test erkennt den Modus selbst)
#   .\scripts\dev\bootstrap_test_n8n.ps1 -FullDeploy              # alle Workflows neu einspielen (sonst nur geaenderte)
#   .\scripts\dev\bootstrap_test_n8n.ps1 -Reset -Cold            # Installer von null (nacktes Debian, ohne Basis-Image)
#   .\scripts\dev\bootstrap_test_n8n.ps1 -RebuildBase             # Basis-Image frisch bauen (neue Debian-/PG-/Node-Minors; impliziert -Reset)
#
# BASIS-IMAGE (Schnellpfad, Default): ein neuer Container startet aus dem lokalen Image lifeagents-substrate-base, in dem
# Basis-Pakete, PostgreSQL (Cluster UTF-8), Node und n8n in den Pins aus provision.sh schon liegen (scripts/dev/
# substrate-image/: Dockerfile + build_base.sh, die DIESELBEN provisioning/lib-Funktionen sourcen). provision.sh erkennt
# sie als vorhanden und faehrt nur Schema/Owner/Credentials/Workflows (gemessen 2026-10-22: -Reset 7:21 -> 3:35 Min;
# beschreibbare Schicht je Container 3,9 GB -> 0,2 GB, n8n liegt einmal im Image). Tag = Pins + Hash ueber die
# Build-Eingaben (Get-SubstrateBaseSpec) -> jede inhaltliche Aenderung baut automatisch neu (einmalig ~10 Min, Named
# Mutex gegen Doppel-Bauten paralleler Sessions); nach einem Bau bleibt neben dem aktuellen das juengste weitere
# Basis-Image (paralleler Worktree), aeltere ungenutzte werden geloescht. Der jrei-Stand wird nur per
# -RebuildBase aufgefrischt (Hinweis ab 30 Tagen).
# KALTER PFAD: -Cold und -Version laufen auf dem nackten $Image (Installer von null, Owner-Regel „Installer immer
# getestet"); CI genericity.yml faehrt ihn bei jeder provisioning/-Aenderung. Aendert der Branch den Install-Kern
# (Dateiliste: Show-InstallCoreHint), weist der Schnellpfad auf `-Reset -Cold` vor dem Push hin.
#
# PARALLEL-LIMIT + AUFRAEUMEN (RAM, 16-GB-Host): ein neues Substrat startet erst, wenn weniger als
# $env:N8NTEST_MAX_PARALLEL (Default 2) andere laufen (wartet bis $env:N8NTEST_WAIT_MIN = 15 Min). Jedes Substrat
# traegt die Labels lifeagents.substrate/lifeagents.worktree; der SessionEnd-Hook .claude/hooks/stop_own_substrate.ps1
# raeumt beim Session-Ende das des eigenen WORKTREES ab, nie im geteilten Haupt-Checkout (dort -Down selbst; Opt-out: $env:LIFEAGENTS_KEEP_SUBSTRATE=1).
#
# RELEASE-PIN (-Version <tag>|latest): statt provision.sh direkt faehrt der Bootstrap-Launcher
# install.sh den SHA256-verifizierten, anonymen Bezug des getaggten Releases aus dem oeffentlichen Repo und
# exec't den GEPINNTEN provision.sh -> testet den Launcher end-to-end (kein Token). Sinnvoll mit -Reset (frische
# Instanz aus dem Tag-Asset).
#
# Secrets aus dem .env-Test-Block (gitignored): TEST_HARNESS_SECRET ist PFLICHT (Harness-Auth);
# Owner/PG werden generiert, LLM-/Telegram-Keys sind optional (fehlend -> Credential uebersprungen).
# Vorbedingung: Docker (Desktop) installiert + Daemon laeuft.
param(
    [switch]$Reset,
    [switch]$Down,
    [switch]$SkipInstall,
    [string]$Version,
    [switch]$HitlChatApproval,
    [switch]$FullDeploy,
    [switch]$Cold,
    [switch]$RebuildBase,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

# --- Container-/Verbindungs-Parameter (nicht-geheime Wegwerf-Defaults) -------
# Override $env:N8NTEST_CONTAINER (+ $env:N8NTEST_PORT): ein zweiter Git-Worktree faehrt sein eigenes Substrat parallel,
# statt das geteilte per -Reset abzureissen (die Tier-Skripte lesen den Namen aus dem State-File des Worktrees).
$Container  = if ($env:N8NTEST_CONTAINER) { $env:N8NTEST_CONTAINER } else { 'lifeagents-n8ntest' }
# $Image = das nackte Image: kalter Pfad (-Cold/-Version) UND Grundlage des Basis-Images. Dieselbe Referenz wie CI
# genericity.yml (Tag, nicht Digest -> kein CI<->Dev-Drift); den Digest loest erst der Basis-Bau auf (Cache-Key).
$Image      = 'jrei/systemd-debian:12'
$BaseRepo   = 'lifeagents-substrate-base'
$UseBase    = -not ($Cold -or $Version)
$BridgePort = 5680                       # socat-Listener IM Container (0.0.0.0) -> 127.0.0.1:5678
$HostPort   = if ($env:N8NTEST_PORT) { $env:N8NTEST_PORT } else { '5680' }
$N8nUrl     = "http://127.0.0.1:$HostPort"
$StateFile  = Join-Path $RepoRoot '.local\n8ntest_state.json'
$ContainerRoot = '/opt/n8n-life-agents'   # provisioning/ + packages/ als Geschwister (REPO_ROOT)
$EnvFileInC = '/root/.n8ntest_install.env'

# --- .env laden (gleiche Mechanik wie die uebrigen scripts/-Treiber) ---------
Get-Content "$RepoRoot\.env" | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') {
        Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script
    }
}
function Get-EnvValue([string]$name) {
    $v = Get-Variable $name -ValueOnly -Scope Script -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v.Trim()
}

# Invoke-Native — natives Tool aufrufen, stdout+stderr + Exit-Code einsammeln (wie bootstrap_test_db.ps1).
# EAP lokal auf 'Continue' (PS-5.1-Quirk: native stderr unter 'Stop' + 2>&1 wuerde als terminierender
# NativeCommandError werfen).
function Invoke-Native {
    param([string]$Exe, [string[]]$CmdArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @CmdArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out) }
}

function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker nicht im PATH. Vorbedingung: Docker Desktop installieren + starten (die Test-Instanz laeuft als $Image-Container)."
    }
    $r = Invoke-Native docker @('info','--format','{{.ServerVersion}}')
    if ($r.Code -ne 0) { throw "Docker-Daemon nicht erreichbar — Docker Desktop starten. ($($r.Output -join ' '))" }
}

function Get-ContainerId {
    param([switch]$RunningOnly)
    $a = @('ps'); if (-not $RunningOnly) { $a += '-a' }
    $a += @('--filter', "name=^/$Container$", '--format', '{{.ID}}')
    $r = Invoke-Native docker $a
    return (($r.Output -join "`n").Trim())
}

# Wait-SubstrateSlot — Parallel-Limit fuer n8n-Substrate (je 1-1,5 GB RAM; bei 16 GB Host + mehreren Sessions
# lagert Windows sonst aus und ALLE Tests werden langsam). Zaehlt laufende Substrate (Container-Label
# lifeagents.substrate, vom Basis-Image geerbtes Label lifeagents.substrate-base ODER nacktes $Image -> auch
# Alt-Container ohne Label; kein ancestor= auf das Basis-Image: BuildKit setzt dafuer keine verlaesslichen
# Eltern-Verweise) ausser dem eigenen; ab $env:N8NTEST_MAX_PARALLEL (Default 2)
# wird gewartet (Poll 30 s, max. $env:N8NTEST_WAIT_MIN Minuten, Default 15), dann klarer Abbruch. Kein Deckel je
# Container (ein harter --memory-Deckel koennte n8n mitten im Test beenden; die Summe begrenzt dieses Limit).
function Get-OtherSubstrates {
    $ids = @()
    foreach ($f in @("label=lifeagents.substrate=n8n", "label=lifeagents.substrate-base=1", "ancestor=$Image")) {
        # {{.Labels}} statt {{.Label "x"}}: PS 5.1 verstuemmelt eingebettete Anfuehrungszeichen in nativen Argumenten.
        $r = Invoke-Native docker @('ps','--filter',$f,'--format','{{.Names}}|{{.Labels}}')
        if ($r.Code -ne 0) { continue }
        foreach ($line in @($r.Output | Where-Object { $_ })) {
            $n, $labels = "$line" -split '\|', 2
            if ($n -eq $Container) { continue }
            $wt = ((("$labels" -split ',') | Where-Object { $_ -like 'lifeagents.worktree=*' } | Select-Object -First 1) -replace '^lifeagents\.worktree=', '')
            $ids += "$n|$wt"
        }
    }
    return @($ids | Sort-Object -Unique)
}
function Wait-SubstrateSlot {
    $max  = if ($env:N8NTEST_MAX_PARALLEL) { [int]$env:N8NTEST_MAX_PARALLEL } else { 2 }
    $wait = if ($env:N8NTEST_WAIT_MIN)     { [int]$env:N8NTEST_WAIT_MIN }     else { 15 }
    $deadline = (Get-Date).AddMinutes($wait)
    while ($true) {
        $others = @(Get-OtherSubstrates)
        if ($others.Count -lt $max) { return }
        $list = ($others | ForEach-Object { $n, $w = $_ -split '\|', 2; if ($w) { "$n ($w)" } else { $n } }) -join ', '
        if ((Get-Date) -ge $deadline) {
            throw ("Parallel-Limit: bereits {0} n8n-Test-Substrate laufen ({1}); Limit {2}. Ein fremdes Substrat " +
                   "nicht abreissen -- warten, bis die besitzende Session es mit -Down beendet, oder die Grenze bewusst " +
                   "per `$env:N8NTEST_MAX_PARALLEL anheben.") -f $others.Count, $list, $max
        }
        Write-Host ("Parallel-Limit {0} erreicht ({1}) -- warte auf einen freien Platz ..." -f $max, $list) -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }
}

# --- Basis-Image (Schnellpfad, s. Kopf) --------------------------------------
# Get-SubstratePins — die drei Versions-Pins aus provision.sh (eine Quelle; gleiches Lese-Muster wie doctor.sh).
function Get-SubstratePins {
    $src = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'provisioning\provision.sh'), $Utf8NoBom)
    $pins = [ordered]@{}
    foreach ($k in 'PG_VERSION', 'N8N_VERSION', 'NODE_MAJOR') {
        $m = [regex]::Match($src, '(?m)^' + $k + '="\$\{' + $k + ':-([^}]+)\}"\r?$')
        if (-not $m.Success) { throw "Pin $k in provisioning/provision.sh nicht gefunden (Format KEY=`"`${KEY:-wert}`")." }
        $pins[$k] = $m.Groups[1].Value
    }
    return $pins
}

# Get-SubstrateBaseSpec — Build-Kontext in ein Temp-Verzeichnis stagen (Dockerfile + build_base.sh + die gesourcten
# provisioning/lib-Dateien) und den Tag ableiten: Pins + SHA256 ueber alles, was den Image-INHALT bestimmt.
# common.sh zaehlt nur mit den Helfern, die der Bau aufruft ($BaseCommonHelpers) — der Rest (ui_*/gum/env) wuerde
# sonst bei jeder Install-UX-Aenderung einen ~10-Min-Neubau ausloesen. Ruft build_base.sh (bzw. eine der drei
# Install-Libs) einen weiteren common.sh-Helfer, gehoert er in diese Liste. Der jrei-Digest steht NICHT im Tag (er
# kommt als Label ans Image): ein lokal weggeraeumtes/neu gezogenes $Image erzwingt keinen Neubau, aufgefrischt
# wird bewusst per -RebuildBase.
$BaseCommonHelpers = @('need_cmd', 'write_if_changed', 'add_apt_key', 'add_apt_source', 'apt_update_once', 'force_apt_update', 'apt_install')
function Get-SubstrateBaseSpec {
    $pins = Get-SubstratePins
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "lifeagents-substrate-base.$PID"
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'lib') | Out-Null
    $files = [ordered]@{
        'Dockerfile'    = Join-Path $RepoRoot 'scripts\dev\substrate-image\Dockerfile'
        'build_base.sh' = Join-Path $RepoRoot 'scripts\dev\substrate-image\build_base.sh'
    }
    foreach ($f in 'common.sh', 'packages.sh', 'install_pg.sh', 'install_n8n.sh') {
        $files["lib/$f"] = Join-Path $RepoRoot "provisioning\lib\$f"
    }
    $buf = New-Object System.IO.MemoryStream
    foreach ($rel in ($files.Keys | Sort-Object)) {
        Copy-Item $files[$rel] (Join-Path $dir $rel)
        $body = [System.IO.File]::ReadAllBytes($files[$rel])
        if ($rel -eq 'lib/common.sh') {
            $src = $Utf8NoBom.GetString($body)
            $parts = foreach ($fn in $BaseCommonHelpers) {
                # einzeilig `name() { ...; }` oder mehrzeilig bis zur schliessenden `}` in Spalte 0
                $m = [regex]::Match($src, '(?m)^' + $fn + '\(\)[ \t]*\{[^\n]*\}[ \t]*$')
                if (-not $m.Success) { $m = [regex]::Match($src, '(?ms)^' + $fn + '\(\)[ \t]*\{.*?^\}') }
                if (-not $m.Success) { throw "common.sh-Helfer '$fn' nicht gefunden -- `$BaseCommonHelpers im Bootstrap nachziehen." }
                $m.Value
            }
            $body = $Utf8NoBom.GetBytes(($parts -join "`n"))
        }
        $head = $Utf8NoBom.GetBytes("$rel`n"); $buf.Write($head, 0, $head.Length)
        $buf.Write($body, 0, $body.Length)
    }
    $tail = $Utf8NoBom.GetBytes((($pins.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n"))
    $buf.Write($tail, 0, $tail.Length)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = (-join ($sha.ComputeHash($buf.ToArray()) | ForEach-Object { $_.ToString('x2') })).Substring(0, 12)
    $sha.Dispose(); $buf.Dispose()
    return [pscustomobject]@{
        Ref  = "${BaseRepo}:n8n$($pins.N8N_VERSION)-node$($pins.NODE_MAJOR)-pg$($pins.PG_VERSION)-$hash"
        Dir  = $dir
        Pins = $pins
    }
}

# Get-SubstrateBaseDigest — Digest-Referenz von $Image fuer FROM (-Pull bzw. fehlendes $Image: frisch ziehen).
function Get-SubstrateBaseDigest {
    param([switch]$Pull)
    if ($Pull -or (Invoke-Native docker @('image', 'inspect', $Image)).Code -ne 0) {
        $r = Invoke-Native docker @('pull', $Image)
        if ($r.Code -ne 0) { throw "docker pull $Image fehlgeschlagen: $($r.Output -join "`n")" }
    }
    $r = Invoke-Native docker @('image', 'inspect', '-f', '{{index .RepoDigests 0}}', $Image)
    $digestRef = (($r.Output -join '').Trim())
    if ($r.Code -ne 0 -or $digestRef -notmatch '@sha256:[0-9a-f]{64}$') { throw "Digest von $Image nicht lesbar: $($r.Output -join ' ')" }
    return $digestRef
}

# Get-SubstrateBaseImages — alle lokalen Basis-Images als {Ref, Created}. CreatedAt = lokale Zeit
# "yyyy-MM-dd HH:mm:ss +zone"; nur die ersten 19 Zeichen per ParseExact (PS 5.1 parst den Rest unzuverlaessig).
function Get-SubstrateBaseImages {
    $r = Invoke-Native docker @('image', 'ls', '--filter', 'label=lifeagents.substrate-base=1', '--format', '{{.Repository}}:{{.Tag}}|{{.CreatedAt}}')
    if ($r.Code -ne 0) { return @() }
    foreach ($line in @($r.Output | Where-Object { "$_" -match '\|' })) {
        $ref, $created = "$line" -split '\|', 2
        if ($ref -like '*:<none>') { continue }
        [pscustomobject]@{
            Ref     = $ref
            Created = [datetime]::ParseExact($created.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        }
    }
}

# Initialize-SubstrateBaseImage — stellt das Basis-Image zum aktuellen Tag sicher und gibt die Referenz zurueck.
# Fehlt es (oder -Force = -RebuildBase: $Image frisch ziehen, --no-cache), wird gebaut; Fortschritt live, volles Log
# in .local/substrate-base-build.log (Aufraeumen alter Images: Remove-StaleSubstrateBaseImages nach dem Start). Eine globale Named Mutex serialisiert parallele Sessions (geteilter Docker-Daemon): die
# zweite wartet (Frist 30 Min, Ctrl+C-faehig in 30-s-Schritten) und findet dann den Tag.
function Initialize-SubstrateBaseImage {
    param([switch]$Force)
    $mutex = New-Object System.Threading.Mutex($false, 'Global\lifeagents-substrate-base')
    $owned = $false
    try {
        $deadline = (Get-Date).AddMinutes(30)
        while (-not $owned) {
            try { $owned = $mutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
            if ($owned) { break }
            if ((Get-Date) -ge $deadline) { throw "Eine andere Session baut das Basis-Image seit ueber 30 Min -- abgebrochen (Ausweg: -Reset -Cold)." }
            Write-Host "Eine andere Session baut gerade das Basis-Image -- warte ..." -ForegroundColor Yellow
        }
        $spec = Get-SubstrateBaseSpec
        try {
            $have = (Invoke-Native docker @('image', 'inspect', $spec.Ref)).Code -eq 0
            if ($have -and -not $Force) {
                $cur = Get-SubstrateBaseImages | Where-Object { $_.Ref -eq $spec.Ref } | Select-Object -First 1
                if ($cur -and $cur.Created -lt (Get-Date).AddDays(-30)) {
                    Write-Host ("Basis-Image ist {0} Tage alt -- fuer frische Debian-/PG-/Node-Minors einmal -RebuildBase." -f [int]((Get-Date) - $cur.Created).TotalDays) -ForegroundColor Yellow
                }
                return $spec.Ref
            }
            $digestRef = Get-SubstrateBaseDigest -Pull:$Force
            Write-Host "Baue Basis-Image $($spec.Ref) (einmalig, ~10 Min; PG $($spec.Pins.PG_VERSION) + Node $($spec.Pins.NODE_MAJOR) + n8n $($spec.Pins.N8N_VERSION) auf $digestRef) ..."
            $t0 = Get-Date
            $a = @('build', '--progress=plain', '-t', $spec.Ref,
                '--label', "lifeagents.base-digest=$digestRef",
                '--build-arg', "BASE_IMAGE=$digestRef",
                '--build-arg', "PG_VERSION=$($spec.Pins.PG_VERSION)",
                '--build-arg', "N8N_VERSION=$($spec.Pins.N8N_VERSION)",
                '--build-arg', "NODE_MAJOR=$($spec.Pins.NODE_MAJOR)")
            if ($Force) { $a += '--no-cache' }
            $a += $spec.Dir
            # Live statt gepuffert (Invoke-Native sammelt bis zum Ende): die [*]/[+]/[!]/[x]-Zeilen von build_base.sh
            # zeigen den Fortschritt, alles andere nur im Log bzw. mit -Verbose. EAP 'Continue' wie in Invoke-Native.
            $log = Join-Path $RepoRoot '.local\substrate-base-build.log'
            New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
            $sw = New-Object System.IO.StreamWriter($log, $false, $Utf8NoBom)
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & docker @a 2>&1 | ForEach-Object {
                    $l = "$_"; $sw.WriteLine($l)
                    if ($Verbose -or $l -match '\[[*+!x]\] ') { Write-Host "  $l" }
                }
                $code = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prev
                $sw.Dispose()
            }
            if ($code -ne 0) {
                Write-Host (([System.IO.File]::ReadAllLines($log, $Utf8NoBom) | Select-Object -Last 30) -join "`n")
                throw "Bau des Basis-Images fehlgeschlagen (Log: $log). Kalter Pfad als Ausweg: -Reset -Cold."
            }
            Write-Host ("Basis-Image gebaut in {0:mm\:ss} Min." -f ((Get-Date) - $t0))
            $script:BaseBuilt = $true
            return $spec.Ref
        } finally {
            Remove-Item $spec.Dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Remove-StaleSubstrateBaseImages — nach einem Bau UND erst nach dem Start des neuen Containers (vorher haelt der
# verworfene Container sein altes Image noch fest): neben $Keep bleibt das juengste weitere Basis-Image, aeltere weg.
# `docker rmi` ohne -f verweigert noch benutzte (fremde Substrate) -> still uebersprungen. Danach namenlose Vorgaenger
# (-RebuildBase mit gleichem Tag nimmt dem alten Image den Namen); prune entfernt ebenfalls nur ungenutzte.
$BaseBuilt = $false
function Remove-StaleSubstrateBaseImages {
    param([string]$Keep)
    $others = @(Get-SubstrateBaseImages | Where-Object { $_.Ref -ne $Keep } | Sort-Object Created -Descending)
    foreach ($old in @($others | Select-Object -Skip 1)) {
        if ((Invoke-Native docker @('rmi', $old.Ref)).Code -eq 0) { Write-Host "Altes Basis-Image entfernt: $($old.Ref)" }
    }
    Invoke-Native docker @('image', 'prune', '-f', '--filter', 'label=lifeagents.substrate-base=1') | Out-Null
}

# Show-InstallCoreHint — der Schnellpfad faehrt die frischen Install-Zweige (PG-/Node-/n8n-Erstinstallation, Preflight
# eines nackten Hosts) nicht. Aendert der Branch den Install-Kern, vor dem Push einmal kalt pruefen. Nie fatal.
function Show-InstallCoreHint {
    $core = '^provisioning/(provision\.sh|lib/(common|preflight|packages|install_pg|install_n8n|upgrade_guard|firewall)\.sh)$'
    # Gegen origin/main (das lokale main eines Worktree-Hosts hinkt oft hinterher -> fremde Commits als Fehlalarm).
    $base = if ((Invoke-Native git @('-C', $RepoRoot, 'rev-parse', '--verify', '-q', 'origin/main')).Code -eq 0) { 'origin/main' } else { 'main' }
    $names = @()
    foreach ($a in @(@('diff', '--name-only', "$base...HEAD"), @('diff', '--name-only', 'HEAD'))) {
        $r = Invoke-Native git (@('-C', $RepoRoot) + $a)
        if ($r.Code -eq 0) { $names += @($r.Output | ForEach-Object { "$_".Trim() }) }
    }
    $hit = @($names | Where-Object { $_ -match $core } | Sort-Object -Unique)
    if ($hit.Count -gt 0) {
        Write-Host ("Install-Kern geaendert ({0}) -- der Schnellpfad testet die Erstinstallation nicht; vor dem Push einmal -Reset -Cold." -f ($hit -join ', ')) -ForegroundColor Yellow
    }
}

# --- Teardown ----------------------------------------------------------------
if ($Down) {
    Assert-Docker
    if (Get-ContainerId) {
        Invoke-Native docker @('rm','-f',$Container) | Out-Null
        Write-Host "Container $Container entfernt."
    } else {
        Write-Host "Kein Container $Container vorhanden."
    }
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    return
}

# --- Container sicherstellen -------------------------------------------------
Assert-Docker

# Kalter Pfad nie still warm: -Cold auf einem vorhandenen (schon installierten) Container waere ein Zweitlauf, und
# -Version auf einem Basis-Image-Container (Update-Test) startete nicht vom nackten Debian.
$existing = Get-ContainerId
if ($existing -and -not $Reset) {
    if ($Cold) { throw "-Cold testet den Installer von null und braucht -Reset (Container $Container existiert schon)." }
    if ($Version) {
        $img = ((Invoke-Native docker @('inspect', '-f', '{{.Config.Image}}', $Container)).Output -join '').Trim()
        if ($img -ne $Image) { throw "Container $Container laeuft aus '$img' (Schnellpfad). -Version braucht hier -Reset." }
    }
}
if ($RebuildBase -and -not $UseBase) {
    Write-Warning "-RebuildBase gilt nur fuer den Schnellpfad (ohne -Cold/-Version) -- ignoriert."
} elseif ($RebuildBase -and $existing -and -not $Reset) {
    Write-Host "-RebuildBase setzt -Reset: der Container startet aus dem frischen Image neu."
    $Reset = $true
}
# Basis-Image VOR dem Abriss sicherstellen: ein gescheiterter Bau laesst das alte Substrat stehen.
$RunImage = $Image
if ($UseBase -and ($Reset -or -not $existing)) {
    $RunImage = Initialize-SubstrateBaseImage -Force:$RebuildBase
    Show-InstallCoreHint
}

if ($Reset -and $existing) {
    Write-Host "Verwerfe Container $Container (-Reset) ..."
    Invoke-Native docker @('rm','-f',$Container) | Out-Null
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
}

if (-not (Get-ContainerId)) {
    Wait-SubstrateSlot
    # Nach dem Warten nur pruefen (ein paralleler Bau koennte aufgeraeumt haben); fehlt es, neu sicherstellen.
    if ($UseBase -and (Invoke-Native docker @('image', 'inspect', $RunImage)).Code -ne 0) { $RunImage = Initialize-SubstrateBaseImage }
    Write-Host "Starte $RunImage als $Container (systemd, 127.0.0.1:$HostPort -> Container:$BridgePort) ..."
    # Labels: lifeagents.substrate markiert ein n8n-Test-Substrat (Parallel-Limit), lifeagents.worktree den
    # besitzenden Checkout -> der SessionEnd-Hook (.claude/hooks/stop_own_substrate.ps1) raeumt nur DIESES ab.
    # --pull never beim Basis-Image: es existiert nur lokal (sonst ein irrefuehrender Docker-Hub-Fehler).
    $pullArg = if ($UseBase) { @('--pull','never') } else { @() }
    $r = Invoke-Native docker (@('run','-d','--name',$Container) + $pullArg + @(
        '--privileged','--cgroupns=host',
        '-v','/sys/fs/cgroup:/sys/fs/cgroup:rw',
        '-p',"127.0.0.1:${HostPort}:${BridgePort}",
        '--label','lifeagents.substrate=n8n',
        '--label',"lifeagents.worktree=$RepoRoot",
        $RunImage))
    if ($r.Code -ne 0) { throw "docker run fehlgeschlagen: $($r.Output -join "`n")" }
    if ($BaseBuilt) { Remove-StaleSubstrateBaseImages -Keep $RunImage }
} elseif (-not (Get-ContainerId -RunningOnly)) {
    $r = Invoke-Native docker @('start',$Container)
    if ($r.Code -ne 0) { throw "docker start fehlgeschlagen: $($r.Output -join "`n")" }
}

# systemd-Readiness abwarten (PID 1 = systemd; akzeptiere running/degraded — degraded heisst nur, dass
# eine unit faellt, systemctl/apt funktionieren trotzdem).
$sysd = $false
for ($i = 0; $i -lt 60; $i++) {
    $r = Invoke-Native docker @('exec',$Container,'systemctl','is-system-running')
    $state = (($r.Output -join '').Trim())
    if ($state -eq 'running' -or $state -eq 'degraded') { $sysd = $true; break }
    Start-Sleep -Milliseconds 500
}
if (-not $sysd) { throw "systemd im Container $Container wurde nicht bereit (Timeout). Letzter Status: $state" }

# Systemsprache wie die Proxmox-Debian-Vorlage (LANG="C"). postgresql-common legt den Cluster mit der SYSTEM-Locale
# aus /etc/default/locale an (maintscripts-functions::set_system_locale), nicht mit der Sitzung; das jrei-Image hat
# die Datei leer -> Fallback C.UTF-8 verdeckte, dass der Installer ohne UTF-8-Zwang eine SQL_ASCII-DB anlegte (v0.4.0).
# Das Substrat faehrt deshalb bewusst den schaerferen Fall.
# \042 statt " im Argument: PS 5.1 reicht eingebettete doppelte Anfuehrungszeichen nicht escaped an native Programme weiter.
$r = Invoke-Native docker @('exec',$Container,'sh','-c','printf ''LANG=\042C\042\n'' > /etc/default/locale')
if ($r.Code -ne 0) { throw "/etc/default/locale im Container nicht schreibbar: $($r.Output -join "`n")" }

if ($SkipInstall) {
    Write-Host "Container $Container bereit (systemd up). Install uebersprungen (-SkipInstall)."
    return
}

# --- Install-Env-Block bauen (TEST_* -> Kern-Env) ---------------------------
$envMap = [ordered]@{
    'TEST_N8N_OWNER_EMAIL'        = 'N8N_OWNER_EMAIL'
    'TEST_N8N_OWNER_PASSWORD'     = 'N8N_OWNER_PASSWORD'
    'TEST_N8N_ENCRYPTION_KEY'     = 'N8N_ENCRYPTION_KEY'
    'TEST_PG_PASSWORD'            = 'N8N_DB_PASSWORD'
    'TEST_TELEGRAM_BOT_TOKEN'     = 'TELEGRAM_BOT_TOKEN'
    'TEST_TELEGRAM_CHAT_ID'       = 'OWNER_CHAT_ID'
    'TEST_GOOGLE_API_KEY'         = 'GOOGLE_API_KEY'
    'TEST_ANTHROPIC_API_KEY'      = 'ANTHROPIC_API_KEY'
    'TEST_HARNESS_SECRET'         = 'TEST_HARNESS_SECRET'
    'TEST_OWNER_FIRST_NAME'       = 'OWNER_FIRST_NAME'
    'TEST_OWNER_LAST_NAME'        = 'OWNER_LAST_NAME'
    'TEST_OWNER_BIRTH_DATE'       = 'OWNER_BIRTH_DATE'
    'TEST_OWNER_LANGUAGE'         = 'OWNER_LANGUAGE'
}
# Paket-Secret-Keys MANIFEST-GETRIEBEN (paperless-WS-0 Naht 3, loest die statischen career-Zeilen ab —
# der BACKLOG-Trigger "2. Paket mit credentials-Block" hat gefeuert): jedes packages/<pkg>/manifest.json
# deklariert seine Fremd-API-Creds im `credentials`-Block (§3.8, env[].field = der Kern-Env-Name);
# das Substrat reicht je Feld TEST_<field> -> <field> als Prozess-Env (der Stage-4-Wizard skippt ohne
# TTY, _inject_manifest_credentials liest env-override-first). doc_lint 7b prueft die abgeleiteten
# TEST_*-Keys gegen .env.example (manifest-getrieben, dieselbe Ableitung).
foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | Sort-Object Name)) {
    $mfPath = Join-Path $pkgDir.FullName 'manifest.json'
    if (-not (Test-Path $mfPath)) { continue }
    $mf = [System.IO.File]::ReadAllText($mfPath, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
    if ($null -eq $mf.credentials) { continue }
    foreach ($credProp in ($mf.credentials.PSObject.Properties | Where-Object { $_.Name -notlike '_*' })) {
        if ($null -eq $credProp.Value.env) { continue }
        foreach ($envKeyProp in $credProp.Value.env.PSObject.Properties) {
            # env-Objekt: Property-NAME = der Kern-Env-Key (z. B. ADZUNA_APP_ID); .field ist das
            # n8n-Credential-Datenfeld (nicht der Env-Name).
            if (-not $envMap.Contains("TEST_$($envKeyProp.Name)")) {
                $envMap["TEST_$($envKeyProp.Name)"] = [string]$envKeyProp.Name
            }
        }
    }
}
function ConvertTo-ShellQuote([string]$v) { "'" + ($v -replace "'", "'\''") + "'" }
$envLines = New-Object System.Collections.Generic.List[string]
foreach ($k in $envMap.Keys) {
    $val = Get-EnvValue $k
    if ($val) { $envLines.Add("$($envMap[$k])=$(ConvertTo-ShellQuote $val)") }
}
# Harness-Header-Name fix auf das, was ALLE Test-Skripte senden (sonst 403 — s. Kopf).
$envLines.Add("TEST_HARNESS_HEADER=$(ConvertTo-ShellQuote 'X-Test-Auth')")
# -HitlChatApproval: Bestaetigungs-Knoepfe im Chat (callback_data) ERZWINGEN — das Substrat hat keine echte Domain, die
# Selbst-Probe in deploy_workflows.sh (_hitl_chat_approval) bliebe sonst immer bei Link-Knoepfen. Nur fuer
# hitl_gate_test erkennt den Modus selbst; Standard bleibt der Prod-gleiche Weg ohne Domain (Link-Knoepfe).
$envLines.Add("LIFEAGENTS_HITL_CHAT_APPROVAL=$(if ($HitlChatApproval) { 'true' } else { 'false' })")
# -FullDeploy: Not-Schalter von deploy_workflows.sh (sonst spielt es nur neue/geaenderte Workflows ein).
$envLines.Add("LIFEAGENTS_DEPLOY_FULL=$(if ($FullDeploy) { '1' } else { '0' })")
# Cache-Keep-Alive des LLM-Gateways AUS: ein stundenlang laufendes Substrat wuerde den Cache sonst bis zu 24 h auf dem
# Entwickler-Schluessel anstupsen (kostet ohne Nutzen). Die Mechanik prueft llm_gateway_test (k) mit eigener Unit.
$envLines.Add('LLM_GATEWAY_KEEPALIVE_HOURS=0')

# Release-Pin (-Version): install.sh --version laedt anonym aus dem oeffentlichen Repo (kein Token).
if ($Version) {
    if ($Version -notmatch '^(v\d+\.\d+\.\d+([-.][A-Za-z0-9._-]+)?|latest)$') {
        throw "Ungueltiges -Version '$Version' (erwartet vX.Y.Z oder 'latest')."
    }
}

if (-not (Get-EnvValue 'TEST_HARNESS_SECRET')) {
    Write-Warning "TEST_HARNESS_SECRET fehlt in .env — die Harness-Header-Auth-Credential wird uebersprungen; infra_test/n8n_test bekaemen 403."
}
if (-not (Get-EnvValue 'TEST_TELEGRAM_BOT_TOKEN')) {
    Write-Warning "TEST_TELEGRAM_BOT_TOKEN fehlt — Telegram-Credential uebersprungen (Orchestrator-Trigger aktiviert ggf. nicht; infra_test braucht ihn nicht)."
}

$tmpEnv = Join-Path ([System.IO.Path]::GetTempPath()) "n8ntest_install_env.$PID.tmp"
[System.IO.File]::WriteAllText($tmpEnv, (($envLines -join "`n") + "`n"), $Utf8NoBom)   # LF, no BOM (in bash gesourct)

# --- Provisioning-Baum + Env in den Container kopieren -----------------------
Write-Host "Stage Provisioning-Baum (provisioning/ packages/) -> ${Container}:$ContainerRoot ..."
$r = Invoke-Native docker @('exec',$Container,'mkdir','-p',$ContainerRoot)
if ($r.Code -ne 0) { throw "mkdir im Container fehlgeschlagen: $($r.Output -join "`n")" }
foreach ($d in 'provisioning','packages') {
    if (-not (Test-Path (Join-Path $RepoRoot $d))) { continue }   # tolerant, Muster install_cli
    # Vorher LEEREN: `docker cp` MERGT in ein bestehendes Verzeichnis -> ohne -Reset blieben aus dem Baum
    # geloeschte/umbenannte Dateien (z. B. eine stillgelegte Workflow-JSON) im Staging liegen, wuerden mit-
    # importiert und verfaelschten jeden Update-Test (Prod: lifeagents update entpackt jede Version in einen
    # FRISCHEN Ordner). Real getroffen Phase A: eine alte + eine umbenannte JSON mit derselben id.
    $r = Invoke-Native docker @('exec',$Container,'rm','-rf',"$ContainerRoot/$d")
    if ($r.Code -ne 0) { throw "Leeren von $ContainerRoot/$d im Container fehlgeschlagen: $($r.Output -join "`n")" }
    $r = Invoke-Native docker @('cp',(Join-Path $RepoRoot $d),"${Container}:$ContainerRoot/")
    if ($r.Code -ne 0) { throw "docker cp $d fehlgeschlagen: $($r.Output -join "`n")" }
}
$r = Invoke-Native docker @('cp',$tmpEnv,"${Container}:$EnvFileInC")
Remove-Item $tmpEnv -Force -ErrorAction SilentlyContinue   # lokale Secret-Kopie sofort weg
if ($r.Code -ne 0) { throw "docker cp install-env fehlgeschlagen: $($r.Output -join "`n")" }

# --- Applier/Launcher im Container fahren (byte-identisch zu Prod) -----------
# Ohne -Version: der Applier provision.sh DIREKT auf dem cp'ten lokalen Baum (kein Fetch/Token) — der
# Dev-Default. Mit -Version: der Bootstrap-Launcher install.sh laedt das getaggte Release anonym und
# SHA256-verifiziert, entpackt es und exec't den gepinnten provision.sh (--version VOR den Profil-Flags,
# die als Passthrough durchlaufen) -> testet den Launcher end-to-end.
# --unattended <env-file>: provision.sh sourct die Env-Datei SELBST (einzige Eingabe-Quelle) — kein
# manuelles Sourcen im Wrapper (auch nicht auf dem -Version-Pfad: install.sh liest nichts aus ihr).
if ($Version) {
    # --packages all ab v0.3.0 (erstes Release mit Install-UX-Phase 4 = Standard nur Core; ohne das Flag fehlten
    # alle Pakete und die Tiers liefen gegen ein nacktes Grundsystem). v0.1.0/v0.2.0 kennen das Flag nicht und
    # installieren ohnehin alles. 'latest' ist inzwischen >= v0.3.0.
    $pkgFlag = ''
    if ($Version -eq 'latest' -or ($Version -match '^v(\d+)\.(\d+)\.(\d+)$' -and ([version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" -ge [version]'0.3.0'))) {
        $pkgFlag = ' --packages all'
    }
    $entryScript  = "$ContainerRoot/provisioning/install.sh"
    $installFlags = "--version $Version --profile dev$pkgFlag --unattended $EnvFileInC"
} else {
    # --packages all: seit Install-UX-Phase 4 installiert provision.sh standardmaessig NUR den Core; die
    # Integrations-Tiers brauchen alle Pakete.
    $entryScript  = "$ContainerRoot/provisioning/provision.sh"
    $installFlags = "--profile dev --packages all --unattended $EnvFileInC"
}
Write-Host "Fahre $entryScript $installFlags im Container (PG17 + n8n + Schema + Workflows; dauert einige Minuten) ..."
$remote = @"
trap 'shred -u $EnvFileInC 2>/dev/null || rm -f $EnvFileInC' EXIT
set -e
chmod 600 $EnvFileInC
rc=0
bash $entryScript $installFlags || rc=`$?
exit `$rc
"@
$remote = $remote -replace "`r`n", "`n"
$r = Invoke-Native docker @('exec',$Container,'bash','-c',$remote)
$installOut = ($r.Output -join "`n")
if ($Verbose -or $r.Code -ne 0) { Write-Host $installOut }
if ($r.Code -ne 0) { throw "$entryScript im Container endete mit Exit $($r.Code) (Logs oben)." }

# UTF-8 ist Gesetz (provisioning/CLAUDE.md): jede DB des Clusters muss UTF8 sein — hart, egal was der Installer meldet.
$r = Invoke-Native docker @('exec',$Container,'runuser','-u','postgres','--','psql','-X','-tA','-c',
    "SELECT string_agg(datname || '=' || pg_encoding_to_char(encoding), ' ') FROM pg_database WHERE pg_encoding_to_char(encoding) <> 'UTF8'")
$nonUtf8 = (($r.Output -join '').Trim())
if ($r.Code -ne 0) { throw "Kodierungs-Pruefung der Container-DB fehlgeschlagen: $($r.Output -join "`n")" }
if ($nonUtf8) { throw "Nicht-UTF8-Datenbank(en) im Substrat: $nonUtf8 — der Installer muss UTF-8 erzwingen." }
# (Kein Pairing-Code mehr aus der Ausgabe: seit Install-UX-Phase 3 armiert provision.sh ihn erst im
#  gefuehrten, interaktiven Ende — unattended nie. Die Tiers pairen den Owner deterministisch in der
#  Container-DB; ein manueller Test pairt per `lifeagents household pair-owner` im Container.)

# --- socat-Bruecke 0.0.0.0:<bridge> -> 127.0.0.1:5678 (test-only) ------------
$r = Invoke-Native docker @('exec',$Container,'sh','-c','command -v socat >/dev/null 2>&1 && echo yes || echo no')
if ((($r.Output -join '').Trim()) -ne 'yes') {
    Write-Host "Installiere socat im Container (Test-Bruecke) ..."
    $r = Invoke-Native docker @('exec',$Container,'bash','-c','apt-get update -qq && apt-get install -y -qq socat')
    if ($r.Code -ne 0) { throw "socat-Installation fehlgeschlagen: $($r.Output -join "`n")" }
}
# socat-Bruecke als transiente systemd-unit (zuverlaessig pruef-/idempotent; das jrei-Base-Image hat
# WEDER pgrep/ps NOCH ss -> eine systemd-unit ist die robuste Variante: is-active prueft sauber, der
# Prozess wird verwaltet, --collect raeumt eine beendete unit selbst weg). systemd ist hier PID 1.
$r = Invoke-Native docker @('exec',$Container,'systemctl','is-active','--quiet','n8ntest-bridge')
if ($r.Code -ne 0) {
    Write-Host "Starte socat-Bruecke (systemd-unit n8ntest-bridge: 0.0.0.0:$BridgePort -> 127.0.0.1:5678) ..."
    $r = Invoke-Native docker @('exec',$Container,'systemd-run','--unit=n8ntest-bridge','--collect',
        'socat',"TCP4-LISTEN:$BridgePort,fork,reuseaddr","TCP4:127.0.0.1:5678")
    if ($r.Code -ne 0) { throw "socat-Bruecke (systemd-run) fehlgeschlagen: $($r.Output -join "`n")" }
    Start-Sleep -Seconds 1
}

# --- N8N_API_KEY aus dem Container extrahieren (Owner-Bootstrap mintet ihn -> /etc/lifeagents/core.env, Phase 5) ---
$r = Invoke-Native docker @('exec',$Container,'sh','-c',"grep -E '^N8N_API_KEY=' /etc/lifeagents/core.env 2>/dev/null | head -n1 | cut -d= -f2-")
$apiKey = (($r.Output -join '').Trim())
if (-not $apiKey) {
    Write-Warning "Kein N8N_API_KEY in /etc/lifeagents/core.env gefunden — der Owner-Bootstrap hat den Mint ggf. uebersprungen. Workflows/Credentials evtl. nicht deployt; die Tiers koennen die REST-API nicht authentifizieren."
}

# --- Erreichbarkeit pruefen + State schreiben --------------------------------
$reachable = $false
for ($i = 0; $i -lt 20; $i++) {
    try {
        $h = @{}; if ($apiKey) { $h['X-N8N-API-KEY'] = $apiKey }
        Invoke-RestMethod -Uri "$N8nUrl/api/v1/workflows?limit=1" -Headers $h -Method Get -TimeoutSec 5 | Out-Null
        $reachable = $true; break
    } catch {
        # 401 = erreichbar, nur Auth -> auch das zaehlt als "n8n antwortet"
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ne 0) { $reachable = $true; break }
        Start-Sleep -Milliseconds 750
    }
}
if (-not $reachable) {
    Write-Warning "n8n unter $N8nUrl nicht erreichbar (socat-Bruecke/Port pruefen)."
}

New-Item -ItemType Directory -Force -Path (Split-Path $StateFile) | Out-Null
$containerId = ((Invoke-Native docker @('inspect','-f','{{.Id}}',$Container)).Output -join '').Trim()
$state = [ordered]@{
    container    = $Container
    container_id = $containerId
    url          = $N8nUrl
    api_key      = $apiKey
    built_at     = (Get-Date -Format 'o')
}
[System.IO.File]::WriteAllText($StateFile, ($state | ConvertTo-Json), $Utf8NoBom)

Write-Host ""
Write-Host "============================================================"
Write-Host "  Test-n8n-Instanz bereit (Docker, systemd)"
Write-Host "  Container:  $Container"
Write-Host "  n8n:        $N8nUrl   (REST + Webhooks ueber socat-Bruecke)"
Write-Host "  API-Key:    $(if ($apiKey) { '(geminted, in .local/n8ntest_state.json)' } else { '(FEHLT — s. Warnung oben)' })"
Write-Host ""
Write-Host "  Tiers gegen diese Instanz:  .\scripts\infra_test.ps1"
Write-Host "  zum Abbauen:                .\scripts\dev\bootstrap_test_n8n.ps1 -Down"
Write-Host "============================================================"
