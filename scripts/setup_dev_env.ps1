#Requires -Version 5.1
# setup_dev_env.ps1 -- Frisches-System-Erkennung + Ein-Befehl-Dev-Setup (idempotenter Installer + Pruefer).
#
# EINE Adresse fuer die komplette Dev-Toolchain dieses Repos: erkennt DETERMINISTISCH, was auf einem
# frisch aufgesetzten Windows fehlt, und installiert die fehlenden Voraussetzungen ueber EINEN Befehl --
# BEVOR das erste Entwickeln beginnt. Erkennung = Tooling (nichts wird geraten). Muster: db_apply.ps1/
# bootstrap_test_n8n.ps1 (Multi-Modus via Flags), Marker wie bootstrap_test_db.ps1 (.local/*_state.json).
#
#   .\scripts\setup_dev_env.ps1            # fehlende Voraussetzungen installieren (idempotent)
#   .\scripts\setup_dev_env.ps1 -Verify    # NUR pruefen, nichts aendern; Exit-Code = Anzahl fehlend
#   .\scripts\setup_dev_env.ps1 -Site      # zusaetzlich Hugo (Showcase-Site) nach <repo>\.local\bin
#   .\scripts\setup_dev_env.ps1 -Full      # Abschluss-Smoke: prek run --all-files --hook-stage pre-commit
#
# NICHT-Ziele (bewusst): Docker NICHT silent installieren (nur erkennen + Anleitung); Windows-
# Entwicklermodus NICHT setzen (nur warnen); keine Secrets ausfuellen (nur OWNER_CHAT_ID=0-Platzhalter);
# KEIN System-Python -- prek-managed Python ist der offizielle Weg, der AppData-Junction-Block wird ueber
# die zwei Env-Vars in Schritt 4 geloest, nicht ueber ein System-Python.
#
# Marker .local/devenv_state.json: Hash ueber die Anforderungs-Liste (Tool-Namen + Pins, geteilt via
# scripts/lib/devenv.ps1) -- der SessionStart-Hook check_dev_env.ps1 liest ihn. BEWUSSTER Trade-off:
# der Marker prueft die Anforderungs-Liste, NICHT den Ist-Zustand (kein TTL, KISS; Grenze in CONTRIBUTING).
#
# Encoding: UTF-8 mit BOM (.claude/rules/powershell.md). Pin-SoT + geteilte prek-Aufloesung: scripts/lib/devenv.ps1.

param(
    [switch]$Verify,
    [switch]$Site,
    [switch]$Full,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\lib\devenv.ps1"

# --- Laufzeit-Zustand ------------------------------------------------------
$script:missing  = 0                # zaehlt fehlende Pflicht-Voraussetzungen (= Exit-Code, blockt Marker)
$script:missNames = New-Object System.Collections.Generic.List[string]   # fuer die docker-bewusste Reminder-Unterscheidung
$script:versions = [ordered]@{}     # Tool -> Versions-/Status-String fuer die Abschluss-Tabelle
$LocalBin = Join-Path $HOME '.local\bin'    # Ziel der gepinnten Binaries (auf dem User-PATH, Schritt 9)

# --- Ausgabe-Helfer (Hausstil: farbiges Write-Host) ------------------------
function Write-Step([string]$m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "  OK    $m" -ForegroundColor Green }
function Write-Info([string]$m) { if ($Verbose) { Write-Host "        $m" -ForegroundColor DarkGray } }
function Write-SoftWarn([string]$m) { Write-Host "  WARN  $m" -ForegroundColor Yellow }
function Write-Miss([string]$Name, [string]$m) {
    Write-Host "  FEHLT $m" -ForegroundColor Red
    $script:missing++
    $script:missNames.Add($Name)
}

# Natives Tool aufrufen: stdout+stderr + Exit-Code einsammeln (Muster bootstrap_test_db.ps1; EAP lokal
# auf 'Continue', sonst wuerde native stderr unter 'Stop'+2>&1 als terminierender NativeCommandError werfen).
function Invoke-Native {
    param([string]$Exe, [string[]]$CmdArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @CmdArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out) }
}

# Versions-String eines Tools extrahieren (Semver), sonst $null.
function Get-ToolVersion {
    param([string]$Exe, [string[]]$VersionArgs, [string]$Rx = '([0-9]+\.[0-9]+\.[0-9]+)')
    try {
        $r = Invoke-Native $Exe $VersionArgs
        $text = ($r.Output -join ' ')
        if ($text -match $Rx) { return $Matches[1] }
    } catch { }
    return $null
}

# Download mit Proxy-Durchreichung ($env:HTTP_PROXY) -- wirft bei Netzfehler (Aufrufer faengt + gibt
# die manuelle CONTRIBUTING-Anleitung statt eines Stacktrace aus).
function Save-Download {
    param([string]$Url, [string]$OutFile)
    $p = @{ Uri = $Url; OutFile = $OutFile; UseBasicParsing = $true }
    if ($env:HTTP_PROXY) { $p.Proxy = $env:HTTP_PROXY }
    Invoke-WebRequest @p
}

# Bare-.exe-Pin nach $Dir\<Target> laden.
function Save-PinnedExe {
    param([string]$Url, [string]$Target, [string]$Dir)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Save-Download $Url (Join-Path $Dir $Target)
}

# ZIP-Pin nach Temp laden, entpacken, <Inner> nach $Dir\<Target> kopieren (try/finally-Cleanup).
function Save-PinnedZip {
    param([string]$Url, [string]$Inner, [string]$Target, [string]$Dir)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $tmp = Join-Path $env:TEMP ('devenv_dl_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'pkg.zip'
        Save-Download $Url $zip
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $exe = Get-ChildItem -Path $tmp -Recurse -Filter $Inner | Select-Object -First 1
        if (-not $exe) { throw "Erwartete Datei '$Inner' nicht im Archiv ($Url)." }
        Copy-Item $exe.FullName (Join-Path $Dir $Target) -Force
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Idempotenz vor jedem Install: die konkreten Tool-Checks (Test-Path psql.exe in Schritt 6, Resolve-Prek
# in Schritt 7) sind das zuverlaessige Guard-Signal -- verlaesslicher als `winget list`-Output-Parsing
# (winget-Exit-Codes/-Ausgaben bei "nicht gefunden" sind unzuverlaessig).
function Install-WingetPackage([string]$Id) {
    Write-Info "winget install --id $Id"
    $r = Invoke-Native winget @('install', '--id', $Id, '-e', '--silent',
        '--accept-source-agreements', '--accept-package-agreements')
    return ($r.Code -eq 0)
}

# Gepinntes Binary sicherstellen: vorhanden mit exakt dem Pin (via --version, nicht nur Test-Path) -> OK;
# sonst -Verify=fehlend / Default=in $Dir installieren + nachpruefen. $Install ist ein Scriptblock, der
# das Binary nach $Dir\<Name>.exe legt.
function Confirm-PinnedBinary {
    param(
        [string]$Name, [string[]]$VersionArgs, [string]$Pin, [string]$Dir, [scriptblock]$Install
    )
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    $ver = if ($cmd) { Get-ToolVersion $cmd.Source $VersionArgs } else { $null }
    if ($ver -eq $Pin) { $script:versions[$Name] = "v$ver"; Write-Ok "$Name v$ver"; return }
    if ($ver) { Write-Info "$Name v$ver != Pin v$Pin -> neu setzen" }

    if ($Verify) {
        $script:versions[$Name] = if ($ver) { "v$ver != v$Pin" } else { 'fehlt' }
        Write-Miss $Name ("$Name " + $(if ($ver) { "v$ver != Pin v$Pin" } else { "fehlt (Pin v$Pin)" }))
        return
    }
    try {
        & $Install
    } catch {
        $script:versions[$Name] = 'Download-Fehler'
        Write-Miss $Name "$Name v$Pin Download fehlgeschlagen ($($_.Exception.Message)). Manuell: CONTRIBUTING.md *Setup*."
        return
    }
    $ver2 = Get-ToolVersion (Join-Path $Dir "$Name.exe") $VersionArgs
    if ($ver2 -eq $Pin) { $script:versions[$Name] = "v$ver2"; Write-Ok "$Name v$ver2 installiert -> $Dir" }
    else { $script:versions[$Name] = 'Installations-Fehler'; Write-Miss $Name "$Name Installation ergab '$ver2' != Pin v$Pin." }
}

# User-Scope-Env-Var setzen UND im laufenden Prozess spiegeln (Querschnitt: jede persistente Aenderung
# wird sofort in $env: sichtbar, bevor -Full/Folgeschritte das Tool nutzen).
function Set-UserEnvMirrored([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path "Env:$Name" -Value $Value
}

Write-Host "=== setup_dev_env: $(if ($Verify) { 'Verify (nur pruefen)' } else { 'Installieren fehlender Voraussetzungen' }) ===" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1) winget vorhanden? (ohne ist nichts installierbar -> harter Abbruch mit Anleitung)
# ---------------------------------------------------------------------------
Write-Step "1) winget (App Installer)"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "  winget nicht gefunden. Installiere 'App Installer' aus dem Microsoft Store" -ForegroundColor Red
    Write-Host "  (https://apps.microsoft.com/detail/9NBLGGH4NNS1) und starte dieses Skript erneut." -ForegroundColor Red
    exit 1
}
Write-Ok "winget vorhanden"

# ---------------------------------------------------------------------------
# 2) Git-Identitaet gesetzt? (kein Auto-Set -- nur Anleitung; WARN, blockt den Marker nicht)
# ---------------------------------------------------------------------------
Write-Step "2) Git-Identitaet (user.name / user.email)"
$gitName  = (Invoke-Native git @('config', '--get', 'user.name')).Output  -join ''
$gitEmail = (Invoke-Native git @('config', '--get', 'user.email')).Output -join ''
if ($gitName.Trim() -and $gitEmail.Trim()) {
    Write-Ok "git user.name='$($gitName.Trim())', user.email gesetzt"
} else {
    Write-SoftWarn "git user.name/user.email nicht gesetzt -- fuer Commits noetig. Setzen:"
    Write-Host '          git config --global user.name "Dein Name"' -ForegroundColor Yellow
    Write-Host '          git config --global user.email "du@example.com"' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 3) Windows-Entwicklermodus (offizielle Voraussetzung; WARN, KEIN Silent-Set). Ehrlich: allgemeine
#    Voraussetzung, NICHT der Fix fuer den Junction-Block (Schritt 4).
# ---------------------------------------------------------------------------
Write-Step "3) Windows-Entwicklermodus"
$devModeOn = $false
try {
    $rk = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
        -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction Stop
    $devModeOn = ($rk.AllowDevelopmentWithoutDevLicense -eq 1)
} catch { $devModeOn = $false }
if ($devModeOn) {
    Write-Ok "Entwicklermodus aktiv"
} else {
    Write-SoftWarn "Entwicklermodus AUS -- Einstellungen > System > Fuer Entwickler > 'Entwicklermodus' AN,"
    Write-Host "          danach ab-/anmelden. (Allgemeine Voraussetzung; NICHT der Fix fuer Schritt 4.)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 4) AppData-Junction-Traversal-Probe (deterministisch): das LOCALAPPDATA-Traversal wirft
#    ERROR_PATH_NOT_FOUND (0x80070003) OBWOHL das Ziel per direktem Pfad existiert -> uv/prek-managed
#    Python bricht. Fix: PREK_HOME + UV_PYTHON_INSTALL_DIR raus aus AppData nach $HOME (verifiziert:
#    mit den zwei Vars laeuft der prek-Von-Null-Lauf ueber alle Hook-Sprachen gruen). \Temp ist vom
#    Block ausgenommen -> Probe-Pfad bewusst NICHT unter $env:TEMP.
# ---------------------------------------------------------------------------
Write-Step "4) AppData-Junction-Traversal-Probe"
$prekHome = Join-Path $HOME '.prek'
$uvPyDir  = Join-Path $HOME '.uv\python'

function Test-JunctionBlock {
    # 'blocked' | 'clear' | 'inconclusive'. Fester Probe-Pfad (Konstante), Leichen-Cleanup VOR dem
    # Anlegen, komplette Probe in try/finally (Cleanup garantiert). "Geblockt" ENG: Traversal wirft
    # DirectoryNotFound/ERROR_PATH_NOT_FOUND, WAEHREND das Ziel direkt existiert.
    $probeRoot = Join-Path $env:LOCALAPPDATA 'lifeagents-devenv-probe'
    if (Test-Path $probeRoot) { Remove-Item -Recurse -Force $probeRoot -ErrorAction SilentlyContinue }
    try {
        $leaf = Join-Path $probeRoot 'python\3.14\bin'   # tiefe, uv-aehnliche Struktur
        New-Item -ItemType Directory -Force -Path $leaf | Out-Null
        $marker = Join-Path $leaf 'probe.bin'
        [System.IO.File]::WriteAllText($marker, 'x', $Utf8NoBom)
        if (-not [System.IO.File]::Exists($marker)) { return 'inconclusive' }   # direkter Pfad muss existieren
        try {
            # Traversal-Enumeration (die uv/prek-Operation): rekursiv von der Wurzel + direkt am Blatt.
            $null = [System.IO.Directory]::GetFileSystemEntries($leaf)
            $null = [System.IO.Directory]::GetDirectories($probeRoot, '*', [System.IO.SearchOption]::AllDirectories)
            return 'clear'
        } catch [System.IO.DirectoryNotFoundException] {
            if ([System.IO.File]::Exists($marker)) { return 'blocked' }   # Ziel existiert direkt -> genau der Block
            return 'inconclusive'
        } catch {
            if ($_.Exception.HResult -eq -2147024893 -and [System.IO.File]::Exists($marker)) { return 'blocked' }  # 0x80070003
            return 'inconclusive'
        }
    } catch {
        return 'inconclusive'
    } finally {
        if (Test-Path $probeRoot) { Remove-Item -Recurse -Force $probeRoot -ErrorAction SilentlyContinue }
    }
}

$block = Test-JunctionBlock
$varsSet = ([Environment]::GetEnvironmentVariable('PREK_HOME', 'User') -eq $prekHome) -and
           ([Environment]::GetEnvironmentVariable('UV_PYTHON_INSTALL_DIR', 'User') -eq $uvPyDir)
Write-Info "Probe-Ergebnis: $block ; Env-Vars gesetzt: $varsSet"
switch ($block) {
    'blocked' {
        if ($varsSet) {
            Write-Ok "Junction-Block erkannt; PREK_HOME + UV_PYTHON_INSTALL_DIR bereits gesetzt"
        } elseif ($Verify) {
            Write-Miss 'junction-vars' "Junction-Block erkannt, aber PREK_HOME/UV_PYTHON_INSTALL_DIR fehlen -> setup_dev_env.ps1 (ohne -Verify) ausfuehren."
        } else {
            New-Item -ItemType Directory -Force -Path $prekHome, $uvPyDir | Out-Null
            Set-UserEnvMirrored 'PREK_HOME' $prekHome
            Set-UserEnvMirrored 'UV_PYTHON_INSTALL_DIR' $uvPyDir
            Write-Ok "Junction-Block erkannt -> PREK_HOME=$prekHome + UV_PYTHON_INSTALL_DIR=$uvPyDir gesetzt (raus aus AppData)"
        }
    }
    'clear' {
        Write-Ok "Kein Junction-Block -- LOCALAPPDATA-Traversal frei (PREK_HOME/UV_PYTHON_INSTALL_DIR nicht noetig)"
    }
    default {
        Write-SoftWarn "Junction-Probe unschluessig -- konservativ NICHT gesetzt. Bricht prek/uv-Python spaeter, dann PREK_HOME=$prekHome + UV_PYTHON_INSTALL_DIR=$uvPyDir manuell setzen."
    }
}

# ---------------------------------------------------------------------------
# 5) Docker Desktop: nur DETECT (kein Silent-Install). Zaehlt als fehlend + blockt den Erfolgs-Marker
#    (ehrlicher Zustand); der SessionStart-Reminder unterscheidet den Docker-Fall.
# ---------------------------------------------------------------------------
Write-Step "5) Docker Desktop (nur erkennen)"
$dockerOk = $false
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $dockerOk = ((Invoke-Native docker @('info', '--format', '{{.ServerVersion}}')).Code -eq 0)
}
if ($dockerOk) { $script:versions['docker'] = 'laeuft'; Write-Ok "Docker-Daemon erreichbar" }
else {
    $script:versions['docker'] = 'fehlt'
    Write-Miss 'docker' "Docker Desktop nicht erreichbar -- manuell installieren (https://www.docker.com/products/docker-desktop/) + Windows neu starten, dann Skript erneut. (Wird bewusst NICHT automatisch installiert.)"
}

# ---------------------------------------------------------------------------
# 6) PostgreSQL-Client psql 17
# ---------------------------------------------------------------------------
Write-Step "6) psql (PostgreSQL 17 Client)"
$pgBin = 'C:\Program Files\PostgreSQL\17\bin'
$psqlOnPath = [bool](Get-Command psql -ErrorAction SilentlyContinue)
if ((Test-Path "$pgBin\psql.exe") -or $psqlOnPath) {
    $script:versions['psql'] = '17'
    Write-Ok "psql vorhanden ($(if (Test-Path "$pgBin\psql.exe") { $pgBin } else { 'PATH' }))"
} elseif ($Verify) {
    $script:versions['psql'] = 'fehlt'
    Write-Miss 'psql17' "psql 17 fehlt (winget PostgreSQL.PostgreSQL.17)."
} else {
    if (Install-WingetPackage 'PostgreSQL.PostgreSQL.17') {
        if (Test-Path "$pgBin") { Set-Item -Path 'Env:PATH' -Value "$pgBin;$env:PATH" }   # in-process spiegeln
        $script:versions['psql'] = '17'
        Write-Ok "PostgreSQL 17 installiert"
    } else { $script:versions['psql'] = 'Install-Fehler'; Write-Miss 'psql17' "winget install PostgreSQL.PostgreSQL.17 fehlgeschlagen." }
}

# ---------------------------------------------------------------------------
# 7) prek (Hook-Runner) + Hooks verdrahten
# ---------------------------------------------------------------------------
Write-Step "7) prek (Hook-Runner)"
$prek = Resolve-Prek
if (-not $prek -and -not $Verify) {
    if (Install-WingetPackage 'j178.Prek') { $prek = Resolve-Prek }   # Aufloesung via geteilter Funktion nach frischem Install
}
if ($prek) {
    $pv = Get-ToolVersion $prek @('--version')
    $script:versions['prek'] = if ($pv) { "v$pv" } else { 'vorhanden' }
    Write-Ok "prek vorhanden ($prek)"
    if (-not $Verify) {
        Push-Location $RepoRoot
        try {
            $r = Invoke-Native $prek @('install', '--overwrite', '--hook-type', 'pre-commit', '--hook-type', 'pre-push', '--hook-type', 'commit-msg')
            if ($r.Code -eq 0) { Write-Ok "Git-Hooks verdrahtet (pre-commit + pre-push + commit-msg)" }
            else { Write-SoftWarn "prek install ergab Exit $($r.Code) -- scripts/install_git_hooks.ps1 pruefen." }
        } finally { Pop-Location }
    }
} else {
    $script:versions['prek'] = 'fehlt'
    Write-Miss 'prek' "prek fehlt (winget j178.Prek)."
}

# ---------------------------------------------------------------------------
# 8) PSScriptAnalyzer (ps-lint). Reihenfolge exakt: -ListAvailable -> Fallback-Pfad -> Install-Module
#    (PSGallery trusted) -> bei KFM-Fehler Save-Module-Fallback.
# ---------------------------------------------------------------------------
Write-Step "8) PSScriptAnalyzer (ps-lint)"
$psmodulesFallback = Join-Path $HOME '.local\psmodules'
$psaFound = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer -ErrorAction SilentlyContinue) -or
            (Test-Path (Join-Path $psmodulesFallback 'PSScriptAnalyzer'))
if ($psaFound) {
    $script:versions['PSScriptAnalyzer'] = 'vorhanden'
    Write-Ok "PSScriptAnalyzer vorhanden"
} elseif ($Verify) {
    $script:versions['PSScriptAnalyzer'] = 'fehlt'
    Write-Miss 'psscriptanalyzer' "PSScriptAnalyzer fehlt (Install-Module PSScriptAnalyzer -Scope CurrentUser)."
} else {
    try {
        if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        }
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        $script:versions['PSScriptAnalyzer'] = 'installiert'
        Write-Ok "PSScriptAnalyzer via Install-Module installiert"
    } catch {
        # KFM/OneDrive-Umleitung von Documents laesst Install-Module scheitern -> Save-Module-Fallback.
        Write-Info "Install-Module fehlgeschlagen ($($_.Exception.Message)) -> Save-Module-Fallback nach $psmodulesFallback"
        try {
            New-Item -ItemType Directory -Force -Path $psmodulesFallback | Out-Null
            Save-Module PSScriptAnalyzer -Path $psmodulesFallback -ErrorAction Stop
            $script:versions['PSScriptAnalyzer'] = 'installiert (Fallback)'
            Write-Ok "PSScriptAnalyzer via Save-Module -> $psmodulesFallback (ps_lint.ps1 prueft diesen Pfad)"
        } catch {
            $script:versions['PSScriptAnalyzer'] = 'Install-Fehler'
            Write-Miss 'psscriptanalyzer' "PSScriptAnalyzer Install-/Save-Module fehlgeschlagen: $($_.Exception.Message). Manuell: CONTRIBUTING.md *Setup*."
        }
    }
}

# ---------------------------------------------------------------------------
# 9) $HOME\.local\bin anlegen + auf den User-PATH (kein Doppeleintrag; in-process spiegeln VOR Schritt 10).
# ---------------------------------------------------------------------------
Write-Step "9) `$HOME\.local\bin auf dem User-PATH"
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $userPath) { $userPath = '' }   # frisches Profil: User-Scope-Path fehlt ganz (-> nicht $null.TrimEnd)
$onUserPath = @(($userPath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $LocalBin.TrimEnd('\') }).Count -gt 0
if ($onUserPath) {
    Write-Ok ".local\bin bereits im User-PATH"
    if (@(($env:PATH -split ';') | Where-Object { $_.TrimEnd('\') -ieq $LocalBin.TrimEnd('\') }).Count -eq 0) {
        Set-Item -Path 'Env:PATH' -Value "$LocalBin;$env:PATH"   # in aktueller Session sichtbar machen
    }
} elseif ($Verify) {
    Write-Miss 'localbin-path' ".local\bin nicht im User-PATH (gepinnte Binaries werden dort nicht gefunden)."
} else {
    New-Item -ItemType Directory -Force -Path $LocalBin | Out-Null
    $newPath = ($userPath.TrimEnd(';') + ';' + $LocalBin).TrimStart(';')
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Set-Item -Path 'Env:PATH' -Value "$LocalBin;$env:PATH"       # in-process spiegeln
    Write-Ok ".local\bin dem User-PATH hinzugefuegt"
}

# ---------------------------------------------------------------------------
# 10) Gepinnte Binaries nach $HOME\.local\bin (Versions-Vergleich via --version, nicht nur Test-Path).
# ---------------------------------------------------------------------------
Write-Step "10) Gepinnte Binaries (gitleaks / squawk / dotenv-linter)"
Confirm-PinnedBinary -Name 'gitleaks' -VersionArgs @('version') -Pin $script:DevEnvPins.gitleaks -Dir $LocalBin -Install {
    Save-PinnedZip "https://github.com/gitleaks/gitleaks/releases/download/v$($script:DevEnvPins.gitleaks)/gitleaks_$($script:DevEnvPins.gitleaks)_windows_x64.zip" 'gitleaks.exe' 'gitleaks.exe' $LocalBin
}
Confirm-PinnedBinary -Name 'squawk' -VersionArgs @('--version') -Pin $script:DevEnvPins.squawk -Dir $LocalBin -Install {
    Save-PinnedExe "https://github.com/sbdchd/squawk/releases/download/v$($script:DevEnvPins.squawk)/squawk-windows-x64.exe" 'squawk.exe' $LocalBin
}
Confirm-PinnedBinary -Name 'dotenv-linter' -VersionArgs @('--version') -Pin $script:DevEnvPins.dotenv_linter -Dir $LocalBin -Install {
    Save-PinnedZip "https://github.com/dotenv-linter/dotenv-linter/releases/download/v$($script:DevEnvPins.dotenv_linter)/dotenv-linter-win-x64.zip" 'dotenv-linter.exe' 'dotenv-linter.exe' $LocalBin
}

# ---------------------------------------------------------------------------
# 11) -Site: Hugo nach <repo>\.local\bin (dort sucht build_site.ps1: $env:HUGO_EXE -> .local\bin -> PATH).
# ---------------------------------------------------------------------------
if ($Site) {
    Write-Step "11) Hugo (Showcase-Site, gepinnt)"
    $repoBin = Join-Path $RepoRoot '.local\bin'
    $hugoPin = $script:DevEnvPins.hugo
    $hugoExe = if ($env:HUGO_EXE -and (Test-Path $env:HUGO_EXE)) { $env:HUGO_EXE }
               elseif (Test-Path (Join-Path $repoBin 'hugo.exe')) { Join-Path $repoBin 'hugo.exe' }
               else { (Get-Command hugo -ErrorAction SilentlyContinue).Source }
    $hv = if ($hugoExe) { Get-ToolVersion $hugoExe @('version') } else { $null }
    if ($hv -eq $hugoPin) { $script:versions['hugo'] = "v$hv"; Write-Ok "hugo v$hv" }
    elseif ($Verify) { $script:versions['hugo'] = if ($hv) { "v$hv != v$hugoPin" } else { 'fehlt' }; Write-Miss 'hugo' "hugo $(if ($hv) { "v$hv != Pin v$hugoPin" } else { "fehlt (Pin v$hugoPin)" })." }
    else {
        try {
            Save-PinnedZip "https://github.com/gohugoio/hugo/releases/download/v$hugoPin/hugo_${hugoPin}_windows-amd64.zip" 'hugo.exe' 'hugo.exe' $repoBin
            $hv2 = Get-ToolVersion (Join-Path $repoBin 'hugo.exe') @('version')
            if ($hv2 -eq $hugoPin) { $script:versions['hugo'] = "v$hv2"; Write-Ok "hugo v$hv2 installiert -> $repoBin" }
            else { $script:versions['hugo'] = 'Install-Fehler'; Write-Miss 'hugo' "hugo Installation ergab '$hv2' != Pin v$hugoPin." }
        } catch {
            $script:versions['hugo'] = 'Download-Fehler'
            Write-Miss 'hugo' "hugo v$hugoPin Download fehlgeschlagen ($($_.Exception.Message)). Manuell: CONTRIBUTING.md *Setup*."
        }
    }
}

# ---------------------------------------------------------------------------
# 12) .env aus .env.example (OWNER_CHAT_ID=0-Platzhalter -- sonst crasht der always-run-Hook
#     capabilities-catalog/build.ps1 -VerifyCatalog beim allerersten Commit).
# ---------------------------------------------------------------------------
Write-Step "12) .env (Owner-Toolchain)"
$envFile     = Join-Path $RepoRoot '.env'
$exampleFile = Join-Path $RepoRoot '.env.example'
if (Test-Path $envFile) {
    Write-Ok ".env vorhanden"
} elseif ($Verify) {
    Write-Miss 'dotenv-file' ".env fehlt (aus .env.example kopieren; OWNER_CHAT_ID=0-Platzhalter)."
} else {
    $content = [System.IO.File]::ReadAllText($exampleFile, $Utf8NoBom)
    $content = $content -replace '(?m)^OWNER_CHAT_ID=\s*$', 'OWNER_CHAT_ID=0'
    [System.IO.File]::WriteAllText($envFile, $content, $Utf8NoBom)
    Write-Ok ".env aus .env.example erstellt"
    Write-Host "  HINWEIS: OWNER_CHAT_ID=0 ist ein PLATZHALTER -- fuer echten Betrieb durch deine numerische" -ForegroundColor Yellow
    Write-Host "          Telegram-chat_id ersetzen; fuer Lint/Build reicht 0. Weitere Secrets: .env.example." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 13) Abschluss: Versions-Tabelle + Marker (bei Vollstaendigkeit) + Neustart-Hinweis + optional -Full.
# ---------------------------------------------------------------------------
Write-Step "Zusammenfassung"
foreach ($k in $script:versions.Keys) { Write-Host ("  {0,-18} {1}" -f $k, $script:versions[$k]) }

# Marker immer in Default-Modus schreiben (Ist-Zustand fuer den docker-bewussten Reminder); -Verify
# schreibt nie (rein lesend). complete=true nur bei 0 fehlend.
if (-not $Verify) {
    $stateFile = Join-Path $RepoRoot '.local\devenv_state.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $stateFile) | Out-Null
    $state = [ordered]@{
        hash         = (Get-DevEnvRequirementHash)
        complete     = ($script:missing -eq 0)
        missing      = @($script:missNames)
        requirements = @((Get-DevEnvRequirementFingerprint) -split "`n")
        built_at     = (Get-Date -Format 'o')
    }
    [System.IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json), $Utf8NoBom)
}

Write-Host ""
if ($script:missing -eq 0) {
    if ($Verify) {
        Write-Host "setup_dev_env -Verify: OK -- 0 Voraussetzungen fehlen." -ForegroundColor Green
    } else {
        Write-Host "Dev-Umgebung vollstaendig -- Marker .local/devenv_state.json geschrieben." -ForegroundColor Green
        Write-Host "WICHTIG: alle offenen Terminals UND VS Code komplett neu starten (ein neuer Tab reicht NICHT) --" -ForegroundColor Yellow
        Write-Host "         PATH-/Env-Aenderungen (PREK_HOME, .local\bin, ...) greifen erst in neuen Prozessen." -ForegroundColor Yellow
    }
} else {
    Write-Host "setup_dev_env: $($script:missing) Voraussetzung(en) fehlen -- siehe oben." -ForegroundColor Red
    if ($Verify) { Write-Host "Beheben: .\scripts\setup_dev_env.ps1 (ohne -Verify)." -ForegroundColor Yellow }
}

# Optionaler Abschluss-Smoke -- nur bei vollstaendiger Umgebung + Default-Modus.
if ($Full -and -not $Verify -and $script:missing -eq 0) {
    Write-Step "-Full: prek run --all-files --hook-stage pre-commit"
    $prekFull = Resolve-Prek
    if ($prekFull) {
        Push-Location $RepoRoot
        try { & $prekFull run --all-files --hook-stage pre-commit } finally { Pop-Location }
    } else { Write-SoftWarn "prek nicht auffindbar -- -Full-Smoke uebersprungen." }
}

exit $script:missing
