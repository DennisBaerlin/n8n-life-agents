#Requires -Version 5.1
# Inspect AND stop n8n executions via the REST API (debugging helper).
#
# Usage:
#   .\scripts\n8n_executions.ps1                       # last 20 executions (summary)
#   .\scripts\n8n_executions.ps1 -ErrorsOnly           # last 20 failed executions
#   .\scripts\n8n_executions.ps1 -Status waiting       # filter by any status (success|error|waiting|...)
#   .\scripts\n8n_executions.ps1 -Limit 50
#   .\scripts\n8n_executions.ps1 -Id 1234              # detail of one execution incl. error
#   .\scripts\n8n_executions.ps1 -Id 1234 -Dump        # + dump each node's output JSON (messages/tool I/O)
#   .\scripts\n8n_executions.ps1 -Id 1234 -Stop        # stop a specific execution (POST /stop)
#   .\scripts\n8n_executions.ps1 -StopWaiting          # stop ALL waiting executions (stale gates/approvals)
#
# -StopWaiting is safe: only touches executions with status=waiting. Useful when a gate
# (sendAndWait) was never clicked and blocks n8n resources / slows down the web UI.
#
# Connection from the ephemeral Docker test substrate (Get-TestN8nConnection -> .local/n8ntest_state.<container>.json),
# NOT from .env: there is no live prod anymore. Throws with a hint if no substrate is running.

param(
    [int]$Limit = 20,
    [string]$Id,
    [switch]$ErrorsOnly,
    [string]$Status,
    [switch]$Dump,
    [switch]$Stop,
    [switch]$StopWaiting
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn       = Get-TestN8nConnection
$N8N_URL    = $conn.Url
$N8N_API_KEY = $conn.ApiKey
$Headers = @{ 'X-N8N-API-KEY' = $N8N_API_KEY }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Map workflowId -> name (one call, for readable output)
$wfNames = @{}
try {
    $wf = Invoke-RestMethod -Uri "$N8N_URL/api/v1/workflows?limit=200" -Headers $Headers -Method Get
    foreach ($w in $wf.data) { $wfNames[$w.id] = $w.name }
} catch { }

function Truncate($s, $n) {
    if ($null -eq $s) { return '' }
    if ($s.Length -gt $n) { return $s.Substring(0, $n) + ' ...[truncated]' }
    return $s
}

function Stop-Execution([string]$ExecId, [string]$Label) {
    try {
        Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions/$ExecId/stop" `
            -Headers $Headers -Method Post | Out-Null
        Write-Host "  [STOPPED] $ExecId  $Label"
    } catch {
        Write-Host "  [FEHLER]  $ExecId  $Label  -> $_"
    }
}

# -Stop: einzelne Execution anhalten
if ($Stop) {
    if (-not $Id) { throw "-Stop erfordert -Id <id>" }
    $ex = Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions/$Id" -Headers $Headers -Method Get
    $name = if ($wfNames.ContainsKey($ex.workflowId)) { $wfNames[$ex.workflowId] } else { $ex.workflowId }
    Write-Host "Stoppe Execution $Id  [$($ex.status)]  $name ..."
    Stop-Execution $Id $name
    return
}

# -StopWaiting: alle haengenden Gates/Approvals auf einmal stoppen
if ($StopWaiting) {
    $resp = Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions?status=waiting&limit=100" `
        -Headers $Headers -Method Get
    if ($resp.data.Count -eq 0) {
        Write-Host "Keine waiting-Executions vorhanden."
        return
    }
    Write-Host "Stoppe $($resp.data.Count) waiting-Execution(s) ..."
    foreach ($e in $resp.data) {
        $name = if ($wfNames.ContainsKey($e.workflowId)) { $wfNames[$e.workflowId] } else { $e.workflowId }
        Stop-Execution $e.id $name
    }
    Write-Host "Fertig."
    return
}

if ($Id) {
    $ex = Invoke-RestMethod -Uri "$N8N_URL/api/v1/executions/$Id`?includeData=true" -Headers $Headers -Method Get
    $name = if ($wfNames.ContainsKey($ex.workflowId)) { $wfNames[$ex.workflowId] } else { $ex.workflowId }
    Write-Host "Execution $($ex.id)  [$($ex.status)]  workflow: $name"
    Write-Host "  started: $($ex.startedAt)   stopped: $($ex.stoppedAt)   mode: $($ex.mode)"
    $rd = $ex.data.resultData
    Write-Host "  lastNodeExecuted: $($rd.lastNodeExecuted)"
    if ($rd.error) {
        Write-Host ""
        Write-Host "  ERROR:"
        Write-Host "    name:        $($rd.error.name)"
        Write-Host "    message:     $($rd.error.message)"
        if ($rd.error.description) { Write-Host "    description: $($rd.error.description)" }
        if ($rd.error.node)        { Write-Host "    node:        $($rd.error.node.name)" }
    }
    # Per-node errors (where the failure actually happened)
    if ($rd.runData) {
        Write-Host ""
        Write-Host "  Node-level errors:"
        foreach ($p in $rd.runData.PSObject.Properties) {
            foreach ($run in $p.Value) {
                if ($run.error) {
                    Write-Host "    [$($p.Name)] $($run.error.message)"
                    if ($run.error.description) { Write-Host "        desc: $($run.error.description)" }
                }
            }
        }
    }
    # Dump each node's first-run output (messages / tool I/O) for conversation analysis
    if ($Dump -and $rd.runData) {
        Write-Host ""
        Write-Host "  Node outputs (first run, truncated):"
        foreach ($p in $rd.runData.PSObject.Properties) {
            $run = $p.Value[0]
            $j = '<no output>'
            try {
                $out = $run.data.main[0]
                if ($out) { $j = ($out | ConvertTo-Json -Depth 8 -Compress) }
            } catch { $j = '<unparseable>' }
            Write-Host "  ── [$($p.Name)]"
            Write-Host "     $(Truncate $j 1800)"
        }
    }
    return
}

# List mode
$st = if ($ErrorsOnly) { 'error' } elseif ($Status) { $Status } else { $null }
$url = "$N8N_URL/api/v1/executions?limit=$Limit"
if ($st) { $url += "&status=$st" }
$resp = Invoke-RestMethod -Uri $url -Headers $Headers -Method Get
Write-Host ("{0,-8} {1,-9} {2,-22} {3}" -f 'id','status','startedAt','workflow')
foreach ($e in $resp.data) {
    $name = if ($wfNames.ContainsKey($e.workflowId)) { $wfNames[$e.workflowId] } else { $e.workflowId }
    Write-Host ("{0,-8} {1,-9} {2,-22} {3}" -f $e.id, $e.status, $e.startedAt, $name)
}
Write-Host ""
Write-Host "Detail:  .\scripts\n8n_executions.ps1 -Id <id> [-Dump]"
Write-Host "Stop:    .\scripts\n8n_executions.ps1 -Id <id> -Stop"
Write-Host "Bulk:    .\scripts\n8n_executions.ps1 -StopWaiting"
