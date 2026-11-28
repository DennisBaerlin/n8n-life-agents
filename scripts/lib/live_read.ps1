#Requires -Version 5.1
# live_read.ps1 -- der eine lesende Zugang zum Produktiv-System fuer die Routinen (/live-findings, /cost-report,
# refresh_privacy_denylist.ps1), fuer beide Laufzeiten: klassisch (systemd, `runuser … psql`) und Docker-Verbund
# (`docker exec <projekt>-postgres|-master`). Dot-sourcen; Befehls-Bausteine sind rein und ohne Netz testbar
# (scripts/dev/live_read_test.ps1). Aufrufer: scripts/live_read.ps1 und scripts/refresh_privacy_denylist.ps1; laedt dotenv.ps1.
# Zugang (LIVE_INSTANCE_*) kommt aus der .env des Haupt-Checkouts, nie ein Rueckfall auf DEV_INSTANCE_*.
# Ziel-Arten ($Target.Kind): ssh (Produktiv-System), local (Test: derselbe Befehl in bash auf diesem Rechner, z. B. gegen einen
# lokalen Test-Verbund), container (Test: klassisches Substrat, `docker exec <container> bash -c`).
# Laufzeit-Erkennung: laeuft der Container <projekt>-master, ist es der Verbund, sonst klassisch; ohne Docker auf dem Ziel
# ebenfalls klassisch. Kein gespeicherter Schalter: das Ziel laeuft klassisch oder als Verbund, das Skript erkennt es bei jedem Lauf selbst.

. (Join-Path $PSScriptRoot 'dotenv.ps1')

# --- Reine Bausteine -----------------------------------------------------------------------------------------------------
# Zugang aus der .env des Haupt-Checkouts; fehlt Host oder Schluessel -> $null (Aufrufer meldet den Grund).
function Get-LiveAccess([string]$MainRoot) {
    $path = Join-Path $MainRoot '.env'
    if (-not (Test-Path $path)) { return $null }
    $vals = Read-DotEnvValues $path
    $h = "$($vals['LIVE_INSTANCE_HOST'])"; $k = "$($vals['LIVE_INSTANCE_SSH_KEY'])"; $u = "$($vals['LIVE_INSTANCE_USER'])"
    if (-not $u) { $u = 'root' }
    if ($k -match '^~[\\/]') { $k = Join-Path $HOME $k.Substring(2) }
    if (-not $h -or -not $k) { return $null }
    return [pscustomobject]@{ Host = $h; User = $u; Key = $k }
}

function New-LiveTarget([string]$Kind, [string]$Project = 'lifeagents', $Access = $null, [string]$Container = '') {
    if ($Project -cnotmatch '^[a-z0-9][a-z0-9_-]{0,39}$') { throw "Projektname '$Project' ungueltig." }
    [pscustomobject]@{ Kind = $Kind; Project = $Project; Access = $Access; Container = $Container }
}

# SQL-Befehl je Laufzeit; psql liest das SQL von stdin (kein Dateiweg: das SQL liegt nie auf dem Ziel).
function Get-LiveSqlCommand([string]$Runtime, [string]$Project) {
    $psql = 'psql -X -q -v ON_ERROR_STOP=1 -d n8n'
    if ($Runtime -eq 'compose') { return "docker exec -i -u postgres $Project-postgres $psql" }
    return "runuser -u postgres -- $psql"
}

# Befehl fuer die Gateway-Mitschrift (GET /__usage, nur lesend); im Verbund teilt der master den Netz-Namensraum des Pods.
function Get-LiveUsageCommand([string]$Runtime, [string]$Project, [string]$After = '', [int]$Limit = 5000) {
    if ($After -and $After -notmatch '^[A-Za-z0-9_.-]+$') { throw 'after: nur Buchstaben, Ziffern, _ . -' }
    $q = "limit=$Limit"; if ($After) { $q = "after=$After&$q" }
    $curl = "curl -fsS 'http://127.0.0.1:8090/__usage?$q'"
    if ($Runtime -eq 'compose') { return "docker exec $Project-master $curl" }
    return $curl
}

# Das SQL beginnt immer lesend; jede Sitzung ueber diesen Weg kann nicht schreiben.
function Get-LiveReadOnlySql([string]$Sql) {
    "\pset format unaligned`n\pset tuples_only on`n\pset fieldsep '\t'`nSET default_transaction_read_only = on;`n" + ($Sql -replace "`r", '')
}

function Get-LiveRuntimeCommand([string]$Project) { "docker inspect -f '{{.State.Running}}' $Project-master" }

# --- Ausfuehrung ---------------------------------------------------------------------------------------------------------
function ConvertTo-ArgQuoted([string]$s) { '"' + ($s -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }

# Fuehrt eine Datei mit Argumenten aus, schreibt $Stdin (UTF-8 ohne BOM) auf stdin; stderr bleibt draussen (eine psql-Meldung
# kann Werte zitieren). Liefert @{ Lines; Rc }.
function Invoke-NativeStdin([string]$File, [string[]]$ArgList, [string]$Stdin = '') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    # Process.Start sucht nur .exe; ein .cmd auf dem PATH (Test-Attrappen) laeuft ueber cmd.exe.
    $exe = (Get-Command $File -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $argText = ($ArgList | ForEach-Object { ConvertTo-ArgQuoted $_ }) -join ' '
    if ($exe -match '\.(cmd|bat)$') { $psi.FileName = $env:ComSpec; $psi.Arguments = "/c `"`"$exe`" $argText`"" }
    else { $psi.FileName = $exe; $psi.Arguments = $argText }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Stdin)
    try { if ($bytes.Length) { $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length) }; $p.StandardInput.Close() } catch { }
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $null = $errTask.Result
    $lines = @(); if ($out.Length) { $lines = @($out -split "`r?`n"); if ($lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) } }
    [pscustomobject]@{ Lines = $lines; Rc = $p.ExitCode }
}

# Windows: `bash` auf dem PATH ist oft das WSL-Relais (kein Docker, anderes Dateisystem); die Git-Bash liegt neben git.
function Get-LocalBash {
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($git) {
            $b = Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'bin\bash.exe'
            if (Test-Path $b) { return $b }
        }
    }
    return 'bash'
}

function Invoke-LiveRemote($Target, [string]$Command, [string]$Stdin = '') {
    switch ($Target.Kind) {
        'ssh' {
            $a = $Target.Access
            # StrictHostKeyChecking=yes ausdruecklich: eine Nutzer-Config mit "no" liesse sonst einen falschen Host durch.
            return Invoke-NativeStdin 'ssh' @('-i', $a.Key, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', "$($a.User)@$($a.Host)", $Command) $Stdin
        }
        'local' { return Invoke-NativeStdin (Get-LocalBash) @('-c', $Command) $Stdin }
        'container' { return Invoke-NativeStdin 'docker' @('exec', '-i', $Target.Container, 'bash', '-c', $Command) $Stdin }
        default { throw "Ziel-Art '$($Target.Kind)' unbekannt." }
    }
}

# 'compose' | 'classic'. ssh-Fehler (Rc 255) ist kein Urteil "klassisch": sonst laese die Routine bei einem Verbindungsfehler still eine falsche Laufzeit.
function Get-LiveRuntime($Target) {
    $r = Invoke-LiveRemote $Target (Get-LiveRuntimeCommand $Target.Project)
    if ($Target.Kind -eq 'ssh' -and $r.Rc -eq 255) { throw 'Ziel nicht erreichbar (ssh).' }
    if ($r.Rc -eq 0) {
        # Der Container ist da, laeuft aber nicht: das Ziel ist der Verbund; "klassisch" waere hier die falsche Laufzeit.
        if (($r.Lines -join '').Trim() -ne 'true') { throw "Container $($Target.Project)-master vorhanden, aber nicht gestartet (Verbund steht)." }
        return 'compose'
    }
    return 'classic'
}

# SQL lesend auf dem Ziel (beide Laufzeiten); Zeilen "art<TAB>wert" usw. Liefert @{ Lines; Rc; Runtime }.
function Invoke-LiveSql($Target, [string]$Sql) {
    $rt = Get-LiveRuntime $Target
    $r = Invoke-LiveRemote $Target (Get-LiveSqlCommand $rt $Target.Project) (Get-LiveReadOnlySql $Sql)
    [pscustomobject]@{ Lines = $r.Lines; Rc = $r.Rc; Runtime = $rt }
}

function Invoke-LiveUsage($Target, [string]$After = '', [int]$Limit = 5000) {
    $rt = Get-LiveRuntime $Target
    $r = Invoke-LiveRemote $Target (Get-LiveUsageCommand $rt $Target.Project $After $Limit)
    [pscustomobject]@{ Lines = $r.Lines; Rc = $r.Rc; Runtime = $rt }
}
