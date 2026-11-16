#Requires -Version 5.1
# timer_lock_lint.ps1 -- Zeitgeber und die gemeinsame Update-Sperre (hartes Gate; Regel im Kopf der Sperre, provisioning/lib/common.sh).
# Der Minuten-Runner (lifeagents-update-run) haelt die Update-Sperre zu jeder vollen Minute kurz. Wer sie zur selben
# Sekunde ohne Warten probt oder nimmt, faellt still aus. Der Lint haelt drei Regeln:
#   (A) `update_lock_free` ohne Wartezeit steht nur in provisioning/doctor.sh (Anzeige, kein Zeitgeber);
#   (B) `update_lock_acquire` ohne Wartezeit steht nur in provisioning/lib/update_runner.sh (der Minuten-Runner selbst);
#   (C) jede provisioning/templates/*.timer.tpl steht in $KnownTimers mit ihrem Umgang mit der Sperre; ein neuer
#       Zeitgeber wird erst gruen, wenn er dort eingetragen ist.
# Aufruf: .\scripts\timer_lock_lint.ps1 [-Root <Baum>]   (-Root nur fuer scripts/dev/timer_lock_lint_test.ps1)
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
$Root = (Resolve-Path $Root).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }
function Rel([string]$p) { return $p.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }

$KnownTimers = @{
    'lifeagents-update-run'   = 'Minuten-Runner: nimmt die Sperre ohne Warten, naechste Minute'
    'lifeagents-update-check' = 'probt die Sperre mit Wartezeit (update_check), Start Sekunde 30'
    'lifeagents-backup'       = 'nimmt die Sperre mit Wartezeit (backup_cli.sh)'
}
$BareAllowed = @{
    'update_lock_free'    = 'provisioning/doctor.sh'
    'update_lock_acquire' = 'provisioning/lib/update_runner.sh'
}

$prov = Join-Path $Root 'provisioning'
$files = @()
if (Test-Path $prov) { $files = @(Get-ChildItem $prov -Recurse -File | Where-Object { $_.Extension -in '.sh', '.tpl' }) }
$rx = [regex]'\b(update_lock_free|update_lock_acquire)\b(?!\s*\(\))(.*)$'
$calls = 0
foreach ($f in $files) {
    $rel = Rel $f.FullName
    $lines = [System.IO.File]::ReadAllLines($f.FullName, $u8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimStart().StartsWith('#')) { continue }
        $m = $rx.Match($lines[$i]); if (-not $m.Success) { continue }
        $calls++
        if ($m.Groups[2].Value.TrimStart() -match '^["$0-9A-Za-z]') { continue }
        $fn = $m.Groups[1].Value
        if ($rel -ne $BareAllowed[$fn]) {
            Fail "${rel}:$($i + 1): $fn ohne Wartezeit; nur $($BareAllowed[$fn]) darf das. Der Minuten-Runner haelt die Sperre zur vollen Minute kurz, ein Aufruf ohne Warten faellt dann still aus -> Sekunden angeben."
        }
    }
}

$tplDir = Join-Path $prov 'templates'
$timers = @()
if (Test-Path $tplDir) { $timers = @(Get-ChildItem $tplDir -File -Filter '*.timer.tpl') }
foreach ($t in $timers) {
    $name = $t.Name -replace '\.timer\.tpl$', ''
    if (-not $KnownTimers.ContainsKey($name)) {
        Fail "$(Rel $t.FullName): neuer Zeitgeber '$name' fehlt in `$KnownTimers (scripts/timer_lock_lint.ps1). Eintragen, wie sein Dienst mit der Update-Sperre umgeht (braucht sie nicht / wartet N Sekunden)."
    }
}

if ($fails -eq 0) { Write-Host "timer_lock_lint: OK ($calls Sperr-Aufruf(e), $($timers.Count) Zeitgeber)" -ForegroundColor Green }
else { Write-Host "timer_lock_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
