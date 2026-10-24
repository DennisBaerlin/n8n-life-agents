# SessionStart-Hook: deterministische Frisch-System-Erkennung. Liest NUR den Marker
# .local/devenv_state.json + die geteilte Anforderungs-Liste (scripts/lib/devenv.ps1) -- KEINE
# Tool-Probes (kein winget/docker/--version), daher <50 ms. Fehlt der Marker oder ist er stale
# (Marker complete=false ODER Tool-Pins geaendert) -> Reminder, scripts/setup_dev_env.ps1 zu fahren.
# ASCII-only + Compact-JSON, damit kein BOM die stdout-JSON bricht.
$ErrorActionPreference = 'Stop'
try {
    $repo = (git rev-parse --show-toplevel 2>$null)
    if (-not $repo) { exit 0 }
    $repo = "$repo".Trim()
    $lib = Join-Path $repo 'scripts/lib/devenv.ps1'
    if (-not (Test-Path $lib)) { exit 0 }
    . $lib

    $marker = Join-Path $repo '.local/devenv_state.json'
    $fresh = $false
    $dockerMissing = $false
    $pinsChanged = $false
    if (Test-Path $marker) {
        try {
            $state = Get-Content -Raw $marker | ConvertFrom-Json
            $hashOk = ($state.hash -eq (Get-DevEnvRequirementHash))
            $complete = [bool]$state.complete
            if ($complete -and $hashOk) { $fresh = $true }
            if ($complete -and -not $hashOk) { $pinsChanged = $true }
            if (-not $complete -and ($state.missing -contains 'docker')) { $dockerMissing = $true }
        } catch { $fresh = $false }
    }
    if ($fresh) { exit 0 }

    $lines = @()
    if ($pinsChanged) {
        $lines += 'DEV-UMGEBUNG: die gepinnten Tool-Versionen haben sich seit der letzten Einrichtung geaendert. Fuehre scripts/setup_dev_env.ps1 erneut aus (aktualisiert die gepinnten Binaries + den Marker).'
    } else {
        $lines += 'DEV-UMGEBUNG UNVOLLSTAENDIG: dieses Repo braucht eine eingerichtete Dev-Toolchain (winget-Pakete, prek-Hooks, gepinnte Binaries, .env). Fuehre scripts/setup_dev_env.ps1 aus, BEVOR du entwickelst. Nur pruefen ohne Aenderung: scripts/setup_dev_env.ps1 -Verify (Exit-Code = Anzahl fehlend).'
        if ($dockerMissing) {
            $lines += 'Docker Desktop fehlt und wird bewusst NICHT automatisch installiert: manuell installieren (docker.com) + Windows neu starten, DANN scripts/setup_dev_env.ps1 erneut.'
        }
    }
    $ctx = ($lines -join ' ')
    $out = @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $ctx } } | ConvertTo-Json -Compress -Depth 5
    Write-Output $out
    exit 0
} catch {
    exit 0
}
