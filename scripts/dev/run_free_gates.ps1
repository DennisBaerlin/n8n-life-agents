#Requires -Version 5.1
# =====================================================================================================
# run_free_gates.ps1 — ALLE kostenlosen Gates auf dem laufenden (oder frisch gebauten) Substrat in EINEM Lauf
#
# Anlass (2026-10-23, Schluss-Gates des gemeinsamen Release): die Leitung setzte die Reihe von Hand zusammen und
# verlor Zeit an drei Fallen — fehlende Mock-Vorbedingung (infra_test braucht mock_paperless), ein aus Bash
# uebergebenes -WriteTools kam als EIN String an, und eine psql-NOTICE brach unter *>-Umleitung ab. Dieses Skript
# ist die EINE Adresse fuer "freie Gates auf dem Gesamtstand" (/coordinate): richtige Reihenfolge, alle Mocks,
# jede Suite einzeln geloggt, Zusammenfassung am Ende. Bezahlte Suiten laufen hier NIE (Owner-Fenster).
#
# PARALLEL (2026-10-26, Owner: "Das dauert immer sehr lange"): -Parallel verteilt die Substrat-Suiten auf ZWEI Substrate
# (das eigene + <N8NTEST_CONTAINER>-b auf Port +1), je ein Kind-Prozess mit eigenen Mocks und eigener Zustandsdatei
# (.local/n8ntest_state.<container>.json, Get-TestN8nStateFile); db_test laeuft derweil im Eltern-Prozess. Die Gruppen
# sind nach gemessener Dauer balanciert ($GroupA/$GroupB). Belegt beide Substrat-Plaetze (Limit 2).
#
# Usage (eigene Container, Pflicht — nie die geteilten Defaults):
#   $env:N8NTEST_CONTAINER='n8ntest-xx'; $env:N8NTEST_PORT='57xx'; $env:DBTEST_CONTAINER='dbtest-xx'; $env:DBTEST_PG_PORT='554xx'
#   .\scripts\dev\run_free_gates.ps1                    # gegen das laufende Substrat
#   .\scripts\dev\run_free_gates.ps1 -Reset             # Substrat vorher frisch (Basis-Image)
#   .\scripts\dev\run_free_gates.ps1 -Reset -Parallel   # zwei Substrate parallel (schnellster Komplettlauf)
#   .\scripts\dev\run_free_gates.ps1 -Reset -Cold       # vorher kalt (nur wenn der Install-Kern geaendert wurde)
# Exit-Code = Anzahl roter Suiten (0 = alles gruen). Logs: $env:TEMP\free_gate_<N8NTEST_CONTAINER>_<suite>.log
# (je Container benannt: den TEMP-Ordner teilen alle Sessions desselben Windows-Nutzers).
# -Child / -Suites / -ResultFile sind intern (Kind-Prozess eines -Parallel-Laufs).
# =====================================================================================================
param(
    [switch]$Reset,
    [switch]$Cold,
    [switch]$Parallel,
    [switch]$Child,
    [string[]]$Suites,
    [string]$ResultFile
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
if ($missing) { throw "Eigene Test-Container setzen, fehlt: $($missing -join ', ') (siehe Usage im Skript-Kopf)." }

# --- Die Substrat-Suiten (Reihenfolge = Laufreihenfolge je Gruppe) ------------------------------------------------
$Gates = [ordered]@{
    release_fetch = @{ Script = 'scripts\dev\release_fetch_test.ps1' }   # Release-Download gegen Mock-GitHub (nur Container)
    infra         = @{ Script = 'scripts\infra_test.ps1' }
    hitl_gate     = @{ Script = 'scripts\dev\hitl_gate_test.ps1' }
    cron_text     = @{ Script = 'scripts\dev\cron_text_test.ps1' }
    bot_menu      = @{ Script = 'scripts\dev\bot_menu_test.ps1' }
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
}
# Gruppen fuer -Parallel, nach gemessener Dauer balanciert (2026-10-26: mr_orch ~3,2 min, real_ingress ~3,5, mr_finance ~2,8).
$GroupA = @('infra', 'hitl_gate', 'cron_text', 'bot_menu', 'update_chat', 'llm_gateway', 'mr_finance', 'mr_advisor', 'mr_guide',
            'mr_monitor', 'mr_career', 'mr_estate', 'mr_paperless')
$GroupB = @('release_fetch', 'mr_orch', 'real_ingress')
$unknown = @($GroupA + $GroupB + $Suites | Where-Object { -not $Gates.Contains($_) })
if ($unknown) { throw "Unbekannte Suite(n): $($unknown -join ', ')" }
if (@($GroupA + $GroupB).Count -ne $Gates.Count) { throw 'run_free_gates: jede Suite muss in genau einer Gruppe stehen ($GroupA/$GroupB).' }

# Sperre gegen parallele Laeufe auf DENSELBEN Containern (2026-10-23: ein git push lief waehrend dieses Skripts;
# Pre-Push-db_test und infra-softcheck kollidierten mit den Suiten). db_test.ps1 prueft dieselbe Datei. Ein Kind-Prozess
# laeuft unter der Sperre seines Eltern-Laufs.
$lock = Join-Path $RepoRoot '.local\run_free_gates.lock'
if (-not $Child) {
    if (Test-Path $lock) {
        $held = Get-Content $lock -Raw | ConvertFrom-Json
        if (Get-Process -Id $held.pid -ErrorAction SilentlyContinue) {
            throw "run_free_gates laeuft bereits (PID $($held.pid), Container $($held.n8n)/$($held.db)) -- abwarten statt parallel starten."
        }
    }
    New-Item -ItemType Directory -Force (Split-Path $lock) | Out-Null
    @{ pid = $PID; n8n = $env:N8NTEST_CONTAINER; db = $env:DBTEST_CONTAINER } | ConvertTo-Json -Compress |
        Set-Content -Path $lock -Encoding UTF8
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

# Ein Substrat vorbereiten + Suiten fahren (seriell ODER als Kind eines -Parallel-Laufs).
function Invoke-SubstrateSuites([string[]]$Names) {
    if ($Reset) {
        $boot = @{ Reset = $true }; if ($Cold) { $boot['Cold'] = $true }
        Invoke-Gate 'substrat' 'scripts\dev\bootstrap_test_n8n.ps1' $boot
        if (-not $results[-1].Ok) { Write-Host "Substrat-Aufbau rot -> Abbruch (Log: $env:TEMP\free_gate_$($env:N8NTEST_CONTAINER)_substrat.log)" -ForegroundColor Red; return $false }
    }
    # Alle Mocks VOR den Substrat-Suiten (infra_test-Faelle verlangen mock_paperless/mock_llm/mock_telegram im State;
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

# --- Kind-Prozess: nur die genannten Suiten auf SEINEM Substrat, Ergebnis als JSON an den Eltern-Lauf ------------
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
    foreach ($spec in @(@{ C = $env:N8NTEST_CONTAINER; P = $env:N8NTEST_PORT; S = $GroupA }, @{ C = $b; P = $bPort; S = $GroupB })) {
        $res = Join-Path $env:TEMP "free_gates_$($spec.C)_results.json"; Remove-Item $res -Force -ErrorAction SilentlyContinue
        $out = Join-Path $env:TEMP "free_gates_$($spec.C)_child.log"
        $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Child', '-Suites', ($spec.S -join ','), '-ResultFile', $res)
        if ($Reset) { $argv += '-Reset' }; if ($Cold) { $argv += '-Cold' }
        $prevC = $env:N8NTEST_CONTAINER; $prevP = $env:N8NTEST_PORT
        $env:N8NTEST_CONTAINER = $spec.C; $env:N8NTEST_PORT = $spec.P   # vom Kind-Prozess geerbt
        $proc = Start-Process -FilePath $ps -ArgumentList $argv -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
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
            # (sonst landete das ganze Array als ein Ergebnis und rote Suiten zaehlten nicht; 2026-10-26).
            $parsed = [System.IO.File]::ReadAllText($c.Result, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
            foreach ($r in $parsed) { $results.Add($r) }
        } else {
            $results.Add([pscustomobject]@{ Suite = 'kind'; Substrat = $c.Container; Ok = $false; Exit = 99; Minuten = 0; Ergebnis = "kein Ergebnis -- Log: $($c.Log)" })
        }
    }
} else {
    if ($Reset) {
        $boot = @{ Reset = $true }; if ($Cold) { $boot['Cold'] = $true }
        Invoke-Gate 'substrat' 'scripts\dev\bootstrap_test_n8n.ps1' $boot
        if (-not $results[-1].Ok) { Remove-Item $lock -Force -ErrorAction SilentlyContinue; Write-Host "Substrat-Aufbau rot -> Abbruch (Log: $env:TEMP\free_gate_$($env:N8NTEST_CONTAINER)_substrat.log)" -ForegroundColor Red; exit 1 }
    }
    Invoke-Gate 'db' 'scripts\db_test.ps1'
    $Reset = $false   # Substrat steht -> Invoke-SubstrateSuites baut nicht erneut
    [void](Invoke-SubstrateSuites @($Gates.Keys))
}

Remove-Item $lock -Force -ErrorAction SilentlyContinue

# Vollstaendigkeit: jede Suite hat genau ein Ergebnis (ein fehlendes Kind-Ergebnis oder ein verschlucktes rotes darf nie
# als "alles gruen" durchgehen).
foreach ($n in @($Gates.Keys) + 'db') {
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
