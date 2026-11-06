#Requires -Version 5.1
# ingress_stall_probe.ps1 — Belegt, ob CPU-Stillstand den echten Telegram-Eingang mit
# "Regular expression execution timed out" (HTTP 500) abbrechen laesst, ohne Fremdtext und ohne Lauf.
#
# Hintergrund: n8n prueft Anzeige-Regeln der Knoten beim Aufbau des Workflows je Webhook (new Workflow ->
# getNodeParameters -> checkConditions -> safeRegex, n8n-workflow/safe-regex). safeRegex laeuft in node:vm mit fest
# 250 ms Wanduhr-Zeit. Steht der Prozess laenger still, bricht auch ein harmloser Ausdruck ab.
#
# Vorgehen: POSTs mit FALSCHEM Geheimnis (Antwort sonst 403, startet keinen Lauf, schreibt nichts) an den echten
# Eingang: erst ohne Drossel (Kontrolle), dann mit CPU-Drossel NUR des eigenen Substrats (stoert keine Nachbarn).
# Die Drossel wird am Ende immer zurueckgenommen. Ziel kommt aus dem Substrat-State, nie aus .env -> kein Prod-Zugriff.
#
# Usage: .\scripts\dev\ingress_stall_probe.ps1 [-Count 200] [-QuotaUs 20000]
#        -QuotaUs = erlaubte CPU je 1-s-Periode (20000 = 20 ms; der Prozess steht den Rest der Sekunde).
# Exit-Code 0 = Lauf durchgefuehrt, das Ergebnis steht in der Ausgabe. Kein Gate (keine Pass/Fail-Aussage).
param(
    [int]$Count = 200,
    [int]$QuotaUs = 20000,
    [int]$ControlCount = 100
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. "$PSScriptRoot\test_n8n_state.ps1"
$conn = Get-TestN8nConnection
$url = (Resolve-OrchestratorIngress -BridgeUrl $conn.Url -ApiKey $conn.ApiKey).Url

function Invoke-ProbeRound([string]$Label, [int]$N) {
    $counts = @{}; $firstBody = $null; $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $N; $i++) {
        $kind = 'unbekannt'
        try {
            $r = Invoke-WebRequest -Uri $url -Method Post -UseBasicParsing -ContentType 'application/json' `
                -Headers @{ 'X-Telegram-Bot-Api-Secret-Token' = 'probe-falsches-geheimnis' } -Body '{"update_id":1}' -TimeoutSec 60
            $kind = "HTTP $([int]$r.StatusCode)"
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { -1 }
            $body = "$($_.ErrorDetails.Message)"
            $kind = if ($status -eq -1) { 'keine Antwort' } else { "HTTP $status" }
            if ($body -match 'Regular expression execution timed out') {
                $kind = "HTTP $status Regex-Abbruch"
                if (-not $firstBody) { $firstBody = $body }
            }
        }
        $counts[$kind] = 1 + [int]$counts[$kind]
    }
    Write-Host ("{0}: {1} Anfragen in {2:n0} s" -f $Label, $N, $sw.Elapsed.TotalSeconds)
    foreach ($k in ($counts.Keys | Sort-Object)) { Write-Host ("    {0,-28} {1}" -f $k, $counts[$k]) }
    if ($firstBody) { Write-Host "    Erster Abbruch: $firstBody" -ForegroundColor Yellow }
}

Invoke-ProbeRound 'Ohne Drossel' $ControlCount
try {
    docker update --cpu-period=1000000 --cpu-quota=$QuotaUs $conn.Container | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker update fehlgeschlagen ($LASTEXITCODE)" }
    Invoke-ProbeRound ("Mit Drossel ({0} ms CPU je Sekunde)" -f ($QuotaUs / 1000)) $Count
} finally {
    docker update --cpu-quota=-1 $conn.Container | Out-Null
    Write-Host "Drossel zurueckgenommen: CpuQuota=$(docker inspect -f '{{.HostConfig.CpuQuota}}' $conn.Container)"
}
