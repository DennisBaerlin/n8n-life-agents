#Requires -Version 5.1
# =====================================================================================================
# run_free_gates.ps1 — alle kostenlosen Gates auf dem laufenden (oder frisch gebauten) Substrat in einem Lauf
#
# Die eine Adresse fuer "freie Gates auf dem Gesamtstand" (/coordinate): richtige Reihenfolge ([Substrat] -> Mocks llm, telegram, paperless -> Suiten aus $Gates; db_test im Eltern-Prozess), alle Mocks,
# jede Suite einzeln geloggt, Zusammenfassung am Ende. Bezahlte Suiten laufen hier nie (Owner-Fenster).
# retire/move laufen nur klassisch (N8NTEST_RUNTIME ungesetzt) und halten n8n im Substrat voruebergehend an (seriell innerhalb ihrer Gruppe, nie gleichzeitig mit anderen Suiten desselben Substrats).
# Fallen bei Handarbeit: fehlende Mock-Vorbedingung (infra_test braucht mock_paperless), ein aus Bash
# uebergebenes -WriteTools kommt als EIN String an, und eine psql-NOTICE bricht unter *>-Umleitung ab.
#
# Parallel: -Parallel verteilt die Substrat-Suiten auf ZWEI Substrate
# (das eigene + <N8NTEST_CONTAINER>-b auf Port +1), je ein Kind-Prozess mit eigenen Mocks und eigener Zustandsdatei
# (.local/n8ntest_state.<container>.json, Get-TestN8nStateFile); db_test laeuft derweil im Eltern-Prozess. Die Gruppen
# sind nach gemessener Dauer balanciert ($GroupA/$GroupB). Belegt beide Substrat-Plaetze (Limit 2) nur fuer den Lauf: das
# zweite Substrat baut jeder -Parallel-Lauf frisch auf (auch ohne -Reset) und am Ende wieder ab.
#
# Usage (eigene Container, Pflicht — nie die geteilten Defaults):
#   $env:N8NTEST_CONTAINER='n8ntest-xx'; $env:N8NTEST_PORT='57xx'; $env:DBTEST_CONTAINER='dbtest-xx'; $env:DBTEST_PG_PORT='554xx'
#   .\scripts\dev\run_free_gates.ps1                    # gegen das laufende Substrat
#   .\scripts\dev\run_free_gates.ps1 -Reset             # Substrat vorher frisch (Basis-Image)
#   .\scripts\dev\run_free_gates.ps1 -Reset -Parallel   # zwei Substrate parallel (schnellster Komplettlauf)
#   .\scripts\dev\run_free_gates.ps1 -Reset -Cold       # vorher kalt (nur wenn der Install-Kern geaendert wurde)
# Exit-Code = Anzahl roter Suiten (0 = alles gruen). Logs: $env:TEMP\free_gate_<N8NTEST_CONTAINER>_<suite>.log
# (je Container benannt: den TEMP-Ordner teilen alle Sessions desselben Windows-Nutzers).
#   .\scripts\dev\run_free_gates.ps1 -Suites mr_estate,hitl_gate   # nur diese Substrat-Suiten, ohne db_test (mit -Reset frisches Substrat)
#   .\scripts\dev\run_free_gates.ps1 -Suites backup              # ein Name ohne _<n> faehrt alle Teile backup_<n>
# -Child / -ResultFile sind intern (Kind-Prozess eines -Parallel-Laufs, je Stueck ein Job in .github/workflows/free-gates.yml).
# -ListPlan gibt die Suiten aus, die dieser Aufruf fahren wuerde (Selbsttest: scripts/dev/run_free_gates_filter_test.ps1).
# -ListSuites gibt die Substrat-Suiten als JSON aus: jede Suite einmal (Selbsttest-Grundlage).
# -ListJobs gibt die CI-Jobs als JSON aus (Stuecke der Gruppen, Trennmarke `|`): daraus baut free-gates.yml seine Matrix; eine neue
#   Suite muss in einer Gruppe stehen und fehlt dort darum nie still.
#   Mit -Suites nur die Jobs, die eine dieser Suiten tragen, gekuerzt auf sie (Handstart mit Auswahl).
# =====================================================================================================
param(
    [switch]$Reset,
    [switch]$Cold,
    [switch]$Parallel,
    [switch]$Child,
    [string[]]$Suites,
    [string]$ResultFile,
    [switch]$ListSuites,
    [switch]$ListJobs,
    [switch]$ListPlan
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
Set-Location $RepoRoot
# Ueber powershell.exe -File kommt eine Liste als EIN String an ("a,b,c") -> aufteilen (Muster mock_route_test -WriteTools).
$Suites = @($Suites | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# Eigene Container sind Pflicht (Root-CLAUDE.md *Scripts*): ohne die vier Variablen liefe alles gegen die geteilten
# Defaults und risse fremde Substrate ab.
$missing = @('N8NTEST_CONTAINER', 'N8NTEST_PORT', 'DBTEST_CONTAINER', 'DBTEST_PG_PORT') |
    Where-Object { [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_)) }
if ($missing -and -not ($ListSuites -or $ListJobs)) { throw "Eigene Test-Container setzen, fehlt: $($missing -join ', ') (siehe Usage im Skript-Kopf)." }

# --- Die Substrat-Suiten (Reihenfolge = Laufreihenfolge je Gruppe) ------------------------------------------------
$Gates = [ordered]@{
    release_fetch = @{ Script = 'scripts\dev\release_fetch_test.ps1' }   # Release-Download gegen Mock-GitHub (nur Container)
    reachability  = @{ Script = 'scripts\dev\reachability_test.ps1' }   # Geraete-Erreichbarkeit IPv4/IPv6 gegen Mock (nur Container)
    runtime       = @{ Script = 'scripts\dev\runtime_test.ps1' }   # Betriebsart-Naht systemd/compose, Antwort-Datei, Telegram-Pruefung (nur Container)
    # Suiten mit Endung _<n> sind Teile einer Suite (je ein CI-Job auf eigenem Substrat, lokal nacheinander); zusammen jeder Fall
    # eines Laufs ohne Teil (Faelle, die die Ausgaben pruefen, je Teil). -Suites <name> faehrt alle Teile.
    backup_1      = @{ Script = 'scripts\dev\backup_test.ps1'; Params = @{ Part = '1' } }   # Notfallblatt + Schluessel-Uebernahme gegen das echte PostgreSQL (nur Container)
    backup_2      = @{ Script = 'scripts\dev\backup_test.ps1'; Params = @{ Part = '2' } }
    backup_3      = @{ Script = 'scripts\dev\backup_test.ps1'; Params = @{ Part = '3' } }
    backup_4      = @{ Script = 'scripts\dev\backup_test.ps1'; Params = @{ Part = '4' } }
    n8n_patch     = @{ Script = 'scripts\dev\n8n_patch_test.ps1' }   # n8n-Korrektur Bestaetigungs-Karten gegen das installierte n8n (nur Container)
    retire        = @{ Script = 'scripts\dev\retire_test.ps1' }   # Umzug: `lifeagents retire` im klassischen Substrat (haelt n8n voruebergehend an; Mock-Telegram)
    move          = @{ Script = 'scripts\dev\move_test.ps1' }   # Umzug: `lifeagents move`/`config import` im klassischen Substrat (wie retire)
    infra        = @{ Script = 'scripts\infra_test.ps1' }
    hitl_gate     = @{ Script = 'scripts\dev\hitl_gate_test.ps1' }
    cron_text     = @{ Script = 'scripts\dev\cron_text_test.ps1' }
    bot_menu      = @{ Script = 'scripts\dev\bot_menu_test.ps1' }
    bot_profile_photo = @{ Script = 'scripts\dev\bot_profile_photo_test.ps1' }   # Bot-Profilbild gegen Mock-Telegram (nur Container)
    app_endpoint  = @{ Script = 'scripts\dev\app_endpoint_test.ps1' }   # Mini-App-Eingang (HTTP, initData, CORS)
    update_chat   = @{ Script = 'scripts\dev\update_chat_test.ps1' }   # Update im Chat gegen Mock-GitHub + Mock-Telegram
    llm_gateway   = @{ Script = 'scripts\dev\llm_gateway_test.ps1' }
    # Mock-Routing je Agent-Ziel (Default-Erkennung tool_* deckt alle Write-Tools; -WriteTools wuerde nur verengen).
    mr_orch       = @{ Script = 'scripts\dev\mock_route_test.ps1'; Params = @{} }
    mr_finance    = @{ Script = 'scripts\dev\mock_route_test.ps1'; Params = @{ TargetWorkflow = 'agent.finance'; WebhookPath = 'finance-test'; CasesFile = 'tests\agent\finance\finance_cases.json' } }
    mr_advisor    = @{ Script = 'scripts\dev\mock_route_test.ps1'; Params = @{ TargetWorkflow = 'agent.finance_advisor'; WebhookPath = 'advisor-test'; CasesFile = 'tests\agent\finance\advisor_cases.json' } }
    mr_guide      = @{ Script = 'scripts\dev\mock_route_test.ps1'; Params = @{ TargetWorkflow = 'agent.guide'; WebhookPath = 'guide-test'; CasesFile = 'tests\agent\core\guide_cases.json' } }
    mr_monitor    = @{ Script = 'scripts\dev\mock_route_test.ps1'; Params = @{ TargetWorkflow = 'agent.monitor'; WebhookPath = 'monitor-test'; CasesFile = 'tests\agent\core\monitor_cases.json' } }
    mr_career     = @{ Script = 'scripts\dev\mock_route_test.ps1'; Params = @{ TargetWorkflow = 'agent.career_advisor'; WebhookPath = 'career-test'; CasesFile = 'tests\agent\career\career_cases.json' } }
    mr_estate     = @{ Script = 'scripts\dev\mock_route_test.ps1'; Params = @{ TargetWorkflow = 'agent.estate_advisor'; WebhookPath = 'estate-test'; CasesFile = 'tests\agent\estate\estate_cases.json' } }
    mr_paperless  = @{ Script = 'scripts\dev\mock_route_test.ps1'; Params = @{ TargetWorkflow = 'agent.paperless_assistant'; WebhookPath = 'paperless-test'; CasesFile = 'tests\agent\paperless\paperless_cases.json'; AgentNode = 'Document Agent' } }
    real_ingress  = @{ Script = 'scripts\dev\real_ingress_test.ps1' }
    plan_rollout  = @{ Script = 'scripts\dev\plan_rollout_test.ps1' }   # Gefuehrte Abfolge am Laufende gegen die Mocks
    monitor_probe = @{ Script = 'scripts\dev\monitor_probe_test.ps1' }   # Waechter-Heartbeat Ende-zu-Ende gegen die Mocks
    conversation  = @{ Script = 'scripts\conversation_test.ps1' }   # Ablauf-Faelle ueber den echten Eingang samt Laien-Messung (Mock-Modell)
}
# Gruppen fuer -Parallel: je ein Substrat, grob nach Dauer verteilt (vor dem naechsten Umbau neu messen).
# '|' schneidet die Gruppen in die CI-Jobs (free-gates.yml, -ListJobs): je Stueck ein Runner mit eigenem Substrat. Stuecke statt
# freier Buendel, weil jedes Stueck dann ein Ausschnitt einer Reihenfolge ist, die lokal schon auf einem Substrat laeuft. Schnitt
# nach der reinen Suite-Zeit auf GitHub: je Stueck bis etwa so lang wie real_ingress allein, denn jeder Job zahlt rund 5 Min
# Ruestzeit (Abbild, Substrat) und die Runner-Plaetze teilt free-gates mit den anderen Workflows; wenige gleich lange Stuecke
# schlagen viele kurze.
$GroupA = @('infra', 'cron_text', 'bot_menu', 'update_chat', '|', 'llm_gateway', 'mr_finance', 'mr_advisor', 'mr_guide',
            'mr_monitor', 'mr_career', 'mr_paperless')
$GroupB = @('release_fetch', 'reachability', 'backup_1', '|', 'backup_2', '|', 'runtime', 'backup_3', '|', 'backup_4', 'n8n_patch',
            'bot_profile_photo', '|', 'hitl_gate', 'mr_estate', '|', 'mr_orch', '|', 'real_ingress', '|', 'app_endpoint', 'monitor_probe',
            'plan_rollout', 'conversation', '|', 'retire', 'move')
function Split-GateJobs([string[]]$Group) {
    $job = @()
    foreach ($s in $Group) { if ($s -eq '|') { if ($job) { , $job }; $job = @() } else { $job += $s } }
    if ($job) { , $job }
}
$Jobs = @(Split-GateJobs $GroupA) + @(Split-GateJobs $GroupB)
$GroupA = @($GroupA | Where-Object { $_ -ne '|' }); $GroupB = @($GroupB | Where-Object { $_ -ne '|' })
# -Suites <name> ohne eigene Suite, aber mit Teilen <name>_<n>: alle Teile in Reihenfolge.
$Suites = @(foreach ($s in $Suites) {
    $parts = @($Gates.Keys | Where-Object { $_ -match ('^' + [regex]::Escape($s) + '_[0-9]+$') })
    if ($Gates.Contains($s) -or -not $parts) { $s } else { $parts }
})
$unknown = @($GroupA + $GroupB + $Suites | Where-Object { -not $Gates.Contains($_) })
if ($unknown) { throw "Unbekannte Suite(n): $($unknown -join ', ')" }
$twice = @($GroupA + $GroupB | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
$absent = @($Gates.Keys | Where-Object { $_ -notin ($GroupA + $GroupB) })
if ($twice -or $absent) { throw "run_free_gates: jede Suite muss in genau einer Gruppe stehen (`$GroupA/`$GroupB). Doppelt: $($twice -join ', '); fehlt: $($absent -join ', ')" }
if ($ListSuites) { ConvertTo-Json -InputObject @($Gates.Keys) -Compress; exit 0 }
# Je CI-Job ein Eintrag "suite,suite,..." (Reihenfolge = Laufreihenfolge); free-gates.yml reicht ihn an -Suites weiter. Mit -Suites
# (Handstart mit Auswahl) nur die Jobs, die eine gewaehlte Suite tragen, gekuerzt auf diese; die Stuecke bleiben Ausschnitte.
if ($ListJobs) {
    $out = foreach ($j in $Jobs) {
        $keep = @(if ($Suites.Count) { $j | Where-Object { $_ -in $Suites } } else { $j })
        if ($keep.Count) { $keep -join ',' }
    }
    ConvertTo-Json -InputObject @($out) -Compress; exit 0
}
# Ein -Suites-Filter im normalen Lauf (ohne -Child/-Parallel) faehrt nur diese Suiten und kein db_test; -Parallel verteilt
# immer alle Suiten, ein Filter dazu waere still wirkungslos -> Fehler statt Ignorieren.
if ($Parallel -and $Suites.Count -gt 0 -and -not $Child) { throw '-Suites und -Parallel schliessen sich aus (Parallel verteilt immer alle Suiten).' }
$Filtered = ($Suites.Count -gt 0 -and -not $Child)
$Planned = if ($Filtered) { @($Suites) } else { @($Gates.Keys) }
if ($ListPlan) { ConvertTo-Json -InputObject @($Planned) -Compress; exit 0 }

# Vorab-Pruefung: ein frischer Worktree hat keine .env (gitignored). Ohne sie wuerden Substrat-Aufbau und fast jede Suite
# einzeln rot (TEST_HARNESS_SECRET fehlt) -- eine klare Meldung vorn ersetzt die vielen roten Suiten. In CI legt new_ci_env.ps1 sie an.
if (-not $Child -and -not (Test-Path (Join-Path $RepoRoot '.env'))) {
    throw ".env fehlt in $RepoRoot (frischer Worktree?). Aus dem Haupt-Checkout kopieren (Copy-Item <Haupt-Checkout>\.env $RepoRoot\.env) oder scripts\dev\new_ci_env.ps1 nutzen; Keys siehe .env.example."
}

# Sperre gegen parallele Laeufe auf denselben Containern (ein git push waehrend des Skripts:
# Pre-Push-db_test und infra-softcheck kollidieren mit den Suiten). db_test.ps1 prueft dieselbe Datei. Ein Kind-Prozess
# laeuft unter der Sperre seines Eltern-Laufs.
$lock = Join-Path $RepoRoot '.local\run_free_gates.lock'
if (-not $Child) {
    if (Test-Path $lock) {
        $held = [System.IO.File]::ReadAllText($lock, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        if (Get-Process -Id $held.pid -ErrorAction SilentlyContinue) {
            throw "run_free_gates laeuft bereits (PID $($held.pid), Container $($held.n8n)/$($held.db)) -- abwarten statt parallel starten."
        }
    }
    New-Item -ItemType Directory -Force (Split-Path $lock) | Out-Null
    $lockJson = @{ pid = $PID; n8n = $env:N8NTEST_CONTAINER; db = $env:DBTEST_CONTAINER } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($lock, $lockJson, (New-Object System.Text.UTF8Encoding($false)))
}

$results = New-Object System.Collections.Generic.List[object]
function Invoke-Gate {
    param([string]$Name, [string]$Script, [hashtable]$Params = @{})
    $log = Join-Path $env:TEMP "free_gate_$($env:N8NTEST_CONTAINER)_$Name.log"
    Write-Host ("==> {0,-12} {1}" -f $Name, $Script) -ForegroundColor Cyan
    $start = Get-Date
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # native stderr der Suiten nicht als Abbruch werten
    try { & (Join-Path $RepoRoot $Script) @Params *> $log; $code = $LASTEXITCODE }
    catch { $_ | Out-File -FilePath $log -Append -Encoding utf8; $code = 99 }
    finally { $ErrorActionPreference = $prevEAP }
    if ($null -eq $code) { $code = 0 }
    $summary = (Select-String -Path $log -Pattern 'bestanden|FAIL' -ErrorAction SilentlyContinue | Select-Object -Last 1).Line
    $results.Add([pscustomobject]@{ Suite = $Name; Substrat = $env:N8NTEST_CONTAINER; Ok = ($code -eq 0); Exit = $code
                                    Minuten = [math]::Round(((Get-Date) - $start).TotalMinutes, 1); Ergebnis = "$summary".Trim() })
    $color = if ($code -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("    exit={0}  {1}" -f $code, "$summary".Trim()) -ForegroundColor $color
}

# Ein Substrat vorbereiten + Suiten fahren (seriell oder als Kind eines -Parallel-Laufs).
function Invoke-SubstrateSuites([string[]]$Names) {
    if ($Reset) {
        $boot = @{ Reset = $true }; if ($Cold) { $boot['Cold'] = $true }
        Invoke-Gate 'substrat' 'scripts\dev\bootstrap_test_n8n.ps1' $boot
        if (-not $results[-1].Ok) { Write-Host "Substrat-Aufbau rot -> Abbruch (Log: $env:TEMP\free_gate_$($env:N8NTEST_CONTAINER)_substrat.log)" -ForegroundColor Red; return $false }
    }
    # Alle Mocks vor den Substrat-Suiten (infra_test-Faelle verlangen mock_paperless/mock_llm/mock_telegram im State;
    # ein Substrat-Redeploy setzt sie zurueck -> hier immer neu einschalten).
    foreach ($m in 'enable_mock_llm', 'enable_mock_telegram', 'enable_mock_paperless') {
        Invoke-Gate ($m -replace '^enable_', '') "scripts\dev\$m.ps1"
    }
    foreach ($n in $Names) {
        $g = $Gates[$n]; $p = if ($g.Params) { $g.Params } else { @{} }
        Invoke-Gate $n $g.Script $p
    }
    return $true
}

# --- Kind-Prozess: nur die genannten Suiten auf seinem Substrat, Ergebnis als JSON an den Eltern-Lauf ------------
if ($Child) {
    [void](Invoke-SubstrateSuites $Suites)
    [System.IO.File]::WriteAllText($ResultFile, ($results | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    exit @($results | Where-Object { -not $_.Ok }).Count
}

if ($Parallel) {
    # Zweites Substrat: eigenes Container-Paar aus dem Namen/Port des ersten (nie geteilte Defaults).
    $b = "$($env:N8NTEST_CONTAINER)-b"; $bPort = [string]([int]$env:N8NTEST_PORT + 1)
    $others = @(docker ps --filter 'label=lifeagents.substrate=n8n' --format '{{.Names}}' 2>$null |
                Where-Object { $_ -and $_ -ne $env:N8NTEST_CONTAINER -and $_ -ne $b })
    if ($others.Count -gt 0) {
        Remove-Item $lock -Force -ErrorAction SilentlyContinue
        throw "-Parallel braucht beide Substrat-Plaetze, belegt: $($others -join ', ') -- seriell laufen lassen (ohne -Parallel) oder abwarten."
    }
    $ps = (Get-Process -Id $PID).Path
    $script = Join-Path $RepoRoot 'scripts\dev\run_free_gates.ps1'
    $children = @()
    # Das zweite Substrat ist nie "laufend" (am Ende abgebaut) -> immer frisch; das eigene nur mit -Reset.
    foreach ($spec in @(@{ C = $env:N8NTEST_CONTAINER; P = $env:N8NTEST_PORT; S = $GroupA; R = [bool]$Reset }, @{ C = $b; P = $bPort; S = $GroupB; R = $true })) {
        $res = Join-Path $env:TEMP "free_gates_$($spec.C)_results.json"; Remove-Item $res -Force -ErrorAction SilentlyContinue
        $out = Join-Path $env:TEMP "free_gates_$($spec.C)_child.log"
        # PS 5.1 Start-Process verbindet -ArgumentList ungequotet mit Leerzeichen -> Pfade selbst quoten (TEMP/Repo mit Leerzeichen).
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-Child', '-Suites', ($spec.S -join ','), '-ResultFile', "`"$res`"")
        if ($spec.R) { $argv += '-Reset' }; if ($Cold) { $argv += '-Cold' }
        $prevC = $env:N8NTEST_CONTAINER; $prevP = $env:N8NTEST_PORT
        $env:N8NTEST_CONTAINER = $spec.C; $env:N8NTEST_PORT = $spec.P   # vom Kind-Prozess geerbt
        $proc = Start-Process -FilePath $ps -ArgumentList ($argv -join ' ') -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
        $env:N8NTEST_CONTAINER = $prevC; $env:N8NTEST_PORT = $prevP
        $children += @{ Proc = $proc; Result = $res; Container = $spec.C; Log = $out }
        Write-Host ("==> Kind {0} (Port {1}): {2}" -f $spec.C, $spec.P, ($spec.S -join ', ')) -ForegroundColor Cyan
        Start-Sleep -Seconds 5   # versetzt starten: zwei gleichzeitige docker run/Basis-Image-Pruefungen kollidieren sonst
    }
    Invoke-Gate 'db' 'scripts\db_test.ps1'   # derweil im Eltern-Prozess (eigener DB-Container)
    foreach ($c in $children) {
        $c.Proc.WaitForExit()
        if (Test-Path $c.Result) {
            # PS 5.1: ConvertFrom-Json gibt ein JSON-Array als EIN Objekt in die Pipeline -> erst zuweisen, dann iterieren
            # (sonst landete das ganze Array als ein Ergebnis und rote Suiten zaehlten nicht).
            $parsed = [System.IO.File]::ReadAllText($c.Result, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
            foreach ($r in $parsed) { $results.Add($r) }
        } else {
            $results.Add([pscustomobject]@{ Suite = 'kind'; Substrat = $c.Container; Ok = $false; Exit = 99; Minuten = 0; Ergebnis = "kein Ergebnis -- Log: $($c.Log)" })
        }
    }
    # Zweites Substrat abbauen: sonst hielte es bis Session-Ende einen der zwei globalen Plaetze (Wait-SubstrateSlot anderer
    # Sessions liefe ins Parallel-Limit). Das eigene bleibt stehen (wie im seriellen Lauf, fuer Nachtests).
    $prevC = $env:N8NTEST_CONTAINER; $prevP = $env:N8NTEST_PORT
    $env:N8NTEST_CONTAINER = $b; $env:N8NTEST_PORT = $bPort
    try { & (Join-Path $RepoRoot 'scripts\dev\bootstrap_test_n8n.ps1') -Down | Out-Null }
    catch { Write-Host "Abbau $b fehlgeschlagen: $_ -- von Hand: bootstrap_test_n8n.ps1 -Down (N8NTEST_CONTAINER=$b)" -ForegroundColor Yellow }
    finally { $env:N8NTEST_CONTAINER = $prevC; $env:N8NTEST_PORT = $prevP }
} else {
    if ($Reset) {
        $boot = @{ Reset = $true }; if ($Cold) { $boot['Cold'] = $true }
        Invoke-Gate 'substrat' 'scripts\dev\bootstrap_test_n8n.ps1' $boot
        if (-not $results[-1].Ok) { Remove-Item $lock -Force -ErrorAction SilentlyContinue; Write-Host "Substrat-Aufbau rot -> Abbruch (Log: $env:TEMP\free_gate_$($env:N8NTEST_CONTAINER)_substrat.log)" -ForegroundColor Red; exit 1 }
    }
    if (-not $Filtered) { Invoke-Gate 'db' 'scripts\db_test.ps1' }
    $Reset = $false   # Substrat steht -> Invoke-SubstrateSuites baut nicht erneut
    [void](Invoke-SubstrateSuites $Planned)
}

Remove-Item $lock -Force -ErrorAction SilentlyContinue

# Vollstaendigkeit: jede Suite hat genau ein Ergebnis (ein fehlendes Kind-Ergebnis oder ein verschlucktes rotes darf nie
# als "alles gruen" durchgehen).
foreach ($n in $(if ($Filtered) { $Planned } else { @($Gates.Keys) + 'db' })) {
    if (-not ($results | Where-Object { $_.Suite -eq $n })) {
        $results.Add([pscustomobject]@{ Suite = $n; Substrat = '-'; Ok = $false; Exit = 98; Minuten = 0; Ergebnis = 'kein Ergebnis (nicht gelaufen?)' })
    }
}

Write-Host ""
Write-Host "================ Freie Gates ================"
$results | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$red = @($results | Where-Object { -not $_.Ok }).Count
if ($red -gt 0) { Write-Host "$red Suite(n) rot -- Logs: $env:TEMP\free_gate_<container>_<suite>.log" -ForegroundColor Red }
else { Write-Host "Alle freien Gates gruen." -ForegroundColor Green }
exit $red
