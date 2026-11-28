#Requires -Version 5.1
# gate: manual (spricht mit dem echten Tailscale-Dienst und wartet minutenlang auf eine Anmeldung)
# tailscale_login_wait_test.ps1 -- Bleibt der Anmelde-Link des Tunnels stehen, bis ein Mensch sich anmeldet? Faehrt den
# Dienst `tailscale` genau so, wie provisioning/compose/compose.yml ihn definiert (Image-Pin, entrypoint/command aus
# `docker compose config`), ohne Anmeldeschluessel, stoesst die Anmeldung an wie der master (lib/reach.sh reach_login_start:
# losgeloestes `tailscale up` mit denselben Schaltern) und beobachtet ihn -WaitSeconds lang (Standard 180):
#   - der Container startet nicht neu (RestartCount 0),
#   - es gibt einen Anmelde-Link (AuthURL login.tailscale.com), und er bleibt derselbe. Optional mit $env:TS_TEST_AUTHKEY
# (Einmal-Schluessel, z. B. scripts/ci/install_test_answers.sh): danach anmelden, Container neu starten, erwartet
# BackendState Running ohne neue Anmeldung; am Ende `tailscale logout` (Geraet sofort weg).
# Braucht Docker und Internet zu Tailscale (kostenlos, kein Konto ohne Schluessel). Eigene Namen: -Prefix (Container
# <prefix>-tstest, Volume <prefix>_tstest_state, Netz <prefix>-tstest-net), alles wird am Ende mit `docker rm -fv` entfernt.
#   .\scripts\dev\tailscale_login_wait_test.ps1 -Prefix s4wf
#   .\scripts\dev\tailscale_login_wait_test.ps1 -Prefix s4wf -WaitSeconds 60
# Exit-Code: 0 = alle Pruefungen gruen, sonst Anzahl roter Pruefungen.
param(
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,20}$')][string]$Prefix = "tstest$PID",
    [ValidateRange(30, 1800)][int]$WaitSeconds = 180
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot '..\lib\native_process.ps1')
$compose = Join-Path $RepoRoot 'provisioning\compose\compose.yml'
$name = "$Prefix-tstest"; $vol = "${Prefix}_tstest_state"; $net = "$Prefix-tstest-net"
$fails = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  [OK]  $what" -ForegroundColor Green } else { Write-Host "  [ROT] $what" -ForegroundColor Red; $script:fails++ }
}
function Invoke-Docker([string[]]$a) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & docker @a 2>$null; $global:LASTEXITCODE = $LASTEXITCODE; $o } finally { $ErrorActionPreference = $prev }
}
function Get-TsStatus {
    $j = Invoke-Docker @('exec', $name, 'tailscale', 'status', '--json', '--peers=false')
    if ($LASTEXITCODE -ne 0 -or -not $j) { return $null }
    try { ($j -join "`n") | ConvertFrom-Json } catch { $null }
}
function Get-Restarts { [int]((Invoke-Docker @('inspect', '-f', '{{.RestartCount}}', $name)) -join '') }
function Remove-All {
    Invoke-Docker @('rm', '-fv', $name) | Out-Null
    Invoke-Docker @('volume', 'rm', $vol) | Out-Null
    Invoke-Docker @('network', 'rm', $net) | Out-Null
}

# Dienst-Definition aus compose.yml (Pflicht-Variablen nur fuer das Rendern; der Dienst tailscale nutzt sie nicht).
$saved = @{}
foreach ($k in 'LA_EDGE_PORT', 'LA_WIZARD_PORT', 'LA_PG_SUPERPW') { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, '1') }
try { $cfg = (Invoke-Docker @('compose', '-f', $compose, '--profile', 'tunnel', 'config', '--format', 'json')) -join "`n" }
finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
if (-not $cfg) { throw 'docker compose config lieferte nichts (Docker laeuft?).' }
$svc = ($cfg | ConvertFrom-Json).services.tailscale
if (-not $svc) { throw 'Dienst tailscale fehlt in compose.yml.' }
$hostName = 'tstest-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))

$run = @('run', '-d', '--name', $name, '--network', $net, '--restart', [string]$svc.restart, '-v', "${vol}:/var/lib/tailscale")
if ($svc.entrypoint) { $run += @('--entrypoint', [string]$svc.entrypoint[0]) }
$run += [string]$svc.image
if ($svc.entrypoint -and $svc.entrypoint.Count -gt 1) { $run += @($svc.entrypoint[1..($svc.entrypoint.Count - 1)] | ForEach-Object { [string]$_ }) }
if ($svc.command) { $run += @($svc.command | ForEach-Object { [string]$_ }) }

Write-Host "Tailscale-Anmeldung wartet $WaitSeconds s ($($svc.image.Split('@')[0]))" -ForegroundColor Cyan
Remove-All
try {
    Invoke-Docker @('network', 'create', $net) | Out-Null
    Invoke-Docker $run | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Container $name startet nicht." }

    # Link holen: sobald tailscaled NeedsLogin meldet, anstossen wie reach_login_start (ohne `up` stellt tailscaled keinen aus).
    $url = ''; $kicked = $false; $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 60 -and -not $url) {
        Start-Sleep -Seconds 2
        $st = Get-TsStatus
        if ($st -and $st.AuthURL) { $url = [string]$st.AuthURL; break }
        if (-not $kicked -and $st -and $st.BackendState -eq 'NeedsLogin') {
            Invoke-Docker @('exec', '-d', $name, 'tailscale', 'up', "--hostname=$hostName", '--accept-dns=false', '--timeout=0') | Out-Null
            $kicked = $true
        }
    }
    Check ($url -match '^https://login\.tailscale\.com/') 'Anmelde-Link nach höchstens 60 s da'

    $changed = 0; $t1 = Get-Date
    while (((Get-Date) - $t1).TotalSeconds -lt $WaitSeconds) {
        Start-Sleep -Seconds 10
        $st = Get-TsStatus
        $now = if ($st) { [string]$st.AuthURL } else { '' }
        if ($url -and $now -ne $url) { $changed++ }
    }
    Check ((Get-Restarts) -eq 0) "kein Neustart in $WaitSeconds s (RestartCount $(Get-Restarts))"
    Check ($url -and $changed -eq 0) "Anmelde-Link blieb $WaitSeconds s derselbe ($changed Abweichungen)"

    if ($env:TS_TEST_AUTHKEY) {
        Invoke-NativeStdinBytes -FilePath docker -ArgumentList @('exec', '-i', $name, 'tailscale', 'up', '--auth-key=file:/dev/stdin', "--hostname=$hostName", '--accept-dns=false', '--timeout=90s') -InputText $env:TS_TEST_AUTHKEY -CaptureOutput | Out-Null
        Check ((Get-TsStatus).BackendState -eq 'Running') "Anmeldung nach $WaitSeconds s gelingt"
        Invoke-Docker @('restart', $name) | Out-Null
        $ok = $false; $t2 = Get-Date
        while (((Get-Date) - $t2).TotalSeconds -lt 60) { Start-Sleep -Seconds 3; $st = Get-TsStatus; if ($st -and $st.BackendState -eq 'Running') { $ok = $true; break } }
        Check $ok 'nach Container-Neustart wieder Running, ohne neue Anmeldung'
        Invoke-Docker @('exec', $name, 'tailscale', 'logout') | Out-Null
    } else {
        Write-Host '  [--]  Anmeldung + Neustart übersprungen (kein TS_TEST_AUTHKEY)' -ForegroundColor DarkGray
    }
} finally {
    Remove-All
}
if ($fails) { Write-Host "$fails Prüfung(en) rot." -ForegroundColor Red } else { Write-Host 'Alles grün.' -ForegroundColor Green }
exit $fails
