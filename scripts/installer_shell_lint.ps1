#Requires -Version 5.1
# installer_shell_lint.ps1 -- Textregeln fuer die Shell-Skripte des Installers (hartes Gate): Zeitgeber und die gemeinsame Update-Sperre (A bis C,
# Regel im Kopf der Sperre, provisioning/lib/common.sh), `exec`-Umleitungen (D) und Locale (E).
# Der Minuten-Runner (lifeagents-update-run) haelt die Update-Sperre zu jeder vollen Minute kurz. Wer sie zur selben
# Sekunde ohne Warten probt oder nimmt, faellt still aus. Der Lint haelt fuenf Regeln:
#   (A) `update_lock_free` ohne Wartezeit steht nur in provisioning/doctor.sh (Anzeige, kein Zeitgeber);
#   (B) `update_lock_acquire` ohne Wartezeit steht nur in provisioning/lib/update_runner.sh (der Minuten-Runner selbst);
#   (C) jede provisioning/templates/*.timer.tpl steht in $KnownTimers mit ihrem Umgang mit der Sperre; ein neuer
#       Zeitgeber wird erst gruen, wenn er dort eingetragen ist.
#   (D) `exec` ohne Programm (die Sperre haengt an Deskriptor 9: `exec 9>>...`, `exec 9>&-`) leitet nur Deskriptoren ab 3 um.
#       Steht in derselben Zeile ein 0/1/2 (`exec 9>&- 2>/dev/null`), gilt das fuer den Rest des Skripts: jede spaetere
#       Fehlermeldung verschwindet. Gewollte Stellen stehen in $ExecStdAllowed.
#   (E) jedes ausfuehrbare Skript unter provisioning/ (Shebang in Zeile 1, ohne desktop/) exportiert selbst LANG=C.UTF-8 und
#       LC_ALL=C.UTF-8; gesourcte Bibliotheken erben beides vom Aufrufer.
# Aufruf: .\scripts\installer_shell_lint.ps1 [-Root <Baum>]   (-Root nur fuer scripts/dev/installer_shell_lint_test.ps1)
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
# (D) Gewollte Umleitungen von stdin/stdout/stderr der Shell selbst: Datei -> Zeilen (ohne Einrueckung, zeichengenau).
$ExecStdAllowed = @{
    'provisioning/lib/common.sh'     = @('exec >>"$UI_LOG_FILE" 2>&1', 'exec 0</dev/null')   # ui_log_begin: Installer-Protokoll
    'provisioning/lib/backup_cli.sh' = @('exec </dev/null >"$log_f" 2>&1')                    # abgeloester Hintergrund-Lauf in einer Subshell
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

# --- (D) `exec` ohne Programm: nur Deskriptoren ab 3 ---
$rxExec  = [regex]'(?:^|[;&|({!]|\b(?:then|do|if|elif|else|while|until)\b)\s*exec((?:\s+(?:\d+|\{\w+\})?(?:<>|>>|>&|<&|&>>?|>\||<|>)\s*(?:"[^"]*"|''[^'']*''|[^\s;&|)}]+))+)\s*(?:$|[;&|)}#])'
$rxRedir = [regex]'(?:^|\s)(\d+|\{\w+\})?(?:<>|>>|>&|<&|&>>?|>\||<|>)\s*(?:"[^"]*"|''[^'']*''|[^\s;&|)}]+)'
foreach ($f in $files) {
    $rel = Rel $f.FullName
    $lines = [System.IO.File]::ReadAllLines($f.FullName, $u8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line.StartsWith('#')) { continue }
        $m = $rxExec.Match($line); if (-not $m.Success) { continue }
        if ($ExecStdAllowed[$rel] -ccontains $line) { continue }
        foreach ($r in $rxRedir.Matches($m.Groups[1].Value)) {
            $fd = $r.Groups[1].Value
            if ($fd.StartsWith('{') -or ($fd -and [int]$fd -ge 3)) { continue }
            Fail "${rel}:$($i + 1): exec ohne Programm leitet Deskriptor $(if ($fd) { $fd } else { '0/1' }) der Shell selbst um, das gilt fuer den Rest des Skripts (ein '2>/dev/null' hinter 'exec 9>&-' verschluckt jede spaetere Fehlermeldung) -> nur Deskriptoren ab 3; gewollte Stellen in `$ExecStdAllowed eintragen."
            break
        }
    }
}

# --- (E) ausfuehrbares Skript (Shebang) setzt LANG und LC_ALL selbst ---
foreach ($f in $files) {
    $rel = Rel $f.FullName
    if ($rel -like 'provisioning/desktop/*') { continue }
    $lines = [System.IO.File]::ReadAllLines($f.FullName, $u8)
    if ($lines.Count -eq 0 -or -not $lines[0].StartsWith('#!')) { continue }
    $exports = @($lines | Where-Object { $_ -match '^\s*export\s' } | ForEach-Object { ($_ -split '\s#')[0] })
    if (-not (($exports -match '\bLANG=C\.UTF-8\b') -and ($exports -match '\bLC_ALL=C\.UTF-8\b'))) {
        Fail "${rel}: ausfuehrbares Skript (Shebang) ohne 'export LANG=C.UTF-8 LC_ALL=C.UTF-8' -- direkt gestartet gilt sonst die Systemsprache des Rechners (psql, sort und der Pager schreiben Umlaute dann als Bytes)."
    }
}

$tplDir = Join-Path $prov 'templates'
$timers = @()
if (Test-Path $tplDir) { $timers = @(Get-ChildItem $tplDir -File -Filter '*.timer.tpl') }
foreach ($t in $timers) {
    $name = $t.Name -replace '\.timer\.tpl$', ''
    if (-not $KnownTimers.ContainsKey($name)) {
        Fail "$(Rel $t.FullName): neuer Zeitgeber '$name' fehlt in `$KnownTimers (scripts/installer_shell_lint.ps1). Eintragen, wie sein Dienst mit der Update-Sperre umgeht (braucht sie nicht / wartet N Sekunden)."
    }
}

if ($fails -eq 0) { Write-Host "installer_shell_lint: OK ($calls Sperr-Aufruf(e), $($timers.Count) Zeitgeber)" -ForegroundColor Green }
else { Write-Host "installer_shell_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
