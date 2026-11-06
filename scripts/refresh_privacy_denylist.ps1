#Requires -Version 5.1
# refresh_privacy_denylist.ps1 -- haelt die Privacy-Liste selbst aktuell: liest Namen, Geburtsdaten, Nummern, Bestaende und
# Stueckzahlen NUR LESEND aus einer Instanz (scripts/lib/privacy_terms.sql) und schreibt sie allein nach
# .local/privacy_denylist.generated.txt im Haupt-Checkout (gitignored). privacy_lint.ps1 liest die Datei zusaetzlich zur
# handgepflegten .local/privacy_denylist.txt.
# Die Liste waechst nur: ein frueherer Wert bleibt gesperrt, auch wenn er auf der Instanz nicht mehr steht.
# Ausgaben nennen NIE einen Wert, nur Anzahlen je Art. Zu haeufige Woerter nimmt .local/privacy_denylist.exclude.txt heraus
# (je Zeile ein Begriff, '#' = Kommentar, Gross-/Kleinschreibung egal).
# Ablauf: wochenweise im Skill /live-findings und in der Tiefenpruefung (Skill /privacy-deep-review).
#
# Usage (Zugang aus der .env des Haupt-Checkouts: DEV_INSTANCE_HOST/_USER/_SSH_KEY):
#   .\scripts\refresh_privacy_denylist.ps1 -Preview     # nichts schreiben, nur Treffer im getrackten Baum als Datei:Zeile melden
#   .\scripts\refresh_privacy_denylist.ps1              # Liste aktualisieren
#   .\scripts\refresh_privacy_denylist.ps1 -Container lifeagents-n8ntest-xx   # Test-Substrat statt Instanz
# Exit-Code: 0 = ok; 1 = Quelle nicht lesbar (Liste bleibt unveraendert); bei -Preview Anzahl der Treffer-Zeilen.
param(
    [switch]$Preview,
    [string]$Container
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'lib\privacy_terms.ps1')
$MainRoot = Split-Path ([string](& git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir)) -Parent
$localDir = Join-Path $MainRoot '.local'
$target = Join-Path $localDir 'privacy_denylist.generated.txt'
$sqlFile = Join-Path $PSScriptRoot 'lib\privacy_terms.sql'

# Einen Wert aus der .env des Haupt-Checkouts lesen.
function Get-MainEnvValue([string]$Key) {
    $path = Join-Path $MainRoot '.env'
    if (-not (Test-Path $path)) { return '' }
    foreach ($l in [System.IO.File]::ReadAllLines($path, $u8)) {
        if ($l -match "^\s*$Key\s*=\s*(.*)$") { return $Matches[1].Trim().Trim('"', "'") }
    }
    ''
}

# SQL ausfuehren; Zeilen "art<TAB>wert". stderr bleibt draussen: eine psql-Fehlermeldung kann Werte zitieren.
$prefix = "\pset format unaligned`n\pset tuples_only on`n\pset fieldsep '\t'`nSET default_transaction_read_only = on;`n"
$sqlText = [System.IO.File]::ReadAllText($sqlFile, $u8) -replace "`r", ''
$psql = 'runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d n8n -f /tmp/lifeagents_privacy_terms.sql'
$rmSql = 'rm -f /tmp/lifeagents_privacy_terms.sql'
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ('privacy_terms_' + [guid]::NewGuid().ToString('N') + '.sql')
[System.IO.File]::WriteAllText($temp, $prefix + $sqlText, $u8)
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try {
    if ($Container) {
        & docker cp $temp "${Container}:/tmp/lifeagents_privacy_terms.sql" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "Quelle nicht lesbar (docker cp nach $Container)." -ForegroundColor Red; exit 1 }
        $rows = @(& docker exec $Container bash -c "chmod 644 /tmp/lifeagents_privacy_terms.sql; $psql; rc=`$?; $rmSql; exit `$rc" 2>$null)
    } else {
        $hostName = Get-MainEnvValue 'DEV_INSTANCE_HOST'
        $user = Get-MainEnvValue 'DEV_INSTANCE_USER'; if (-not $user) { $user = 'root' }
        $key = Get-MainEnvValue 'DEV_INSTANCE_SSH_KEY'
        if ($key -match '^~[\\/]') { $key = Join-Path $HOME $key.Substring(2) }
        if (-not $hostName -or -not $key) { Write-Host 'DEV_INSTANCE_HOST oder DEV_INSTANCE_SSH_KEY fehlt in der .env des Haupt-Checkouts.' -ForegroundColor Red; exit 1 }
        & scp -q -i $key -o BatchMode=yes $temp "${user}@${hostName}:/tmp/lifeagents_privacy_terms.sql" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host 'Quelle nicht lesbar (scp).' -ForegroundColor Red; exit 1 }
        $rows = @(& ssh -i $key -o BatchMode=yes "${user}@${hostName}" "chmod 644 /tmp/lifeagents_privacy_terms.sql; $psql; rc=`$?; $rmSql; exit `$rc" 2>$null)
    }
    $rc = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEAP
    Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
}
if ($rc -ne 0) { Write-Host "Quelle nicht lesbar (psql Exit $rc). Liste unveraendert." -ForegroundColor Red; exit 1 }

# Schreibweisen bilden, Ausnahmen abziehen, Anzahlen je Art zaehlen (nie Werte).
$exclude = @{}
$excludeFile = Join-Path $localDir 'privacy_denylist.exclude.txt'
if (Test-Path $excludeFile) {
    foreach ($l in [System.IO.File]::ReadAllLines($excludeFile, $u8)) {
        $t = $l.Trim(); if ($t -and -not $t.StartsWith('#')) { $exclude[$t.ToLowerInvariant()] = $true }
    }
}
# Der Autorenname ist die oeffentliche Identitaet des Repos (LICENSE, Commits): gesperrt wuerde er jeden Commit blockieren.
$author = "$(& git -C $RepoRoot config user.name)".Trim()
if ($author) { foreach ($t in @($author) + @($author -split '\s+')) { if ($t) { $exclude[$t.ToLowerInvariant()] = $true } } }
$fresh = @{}
$counts = @{}
foreach ($row in $rows) {
    $f = "$row" -split "`t", 2
    if ($f.Count -ne 2) { continue }
    foreach ($term in (Get-PrivacyTermVariants $f[0] $f[1])) {
        if ($exclude.ContainsKey($term.ToLowerInvariant())) { continue }
        if (-not $fresh.ContainsKey($term)) { $fresh[$term] = $true; $counts[$f[0]] = 1 + [int]$counts[$f[0]] }
    }
}
Write-Host ("Gelesen: {0} Begriffe ({1})" -f $fresh.Count, (($counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Value)" }) -join ', '))
foreach ($must in 'name', 'date') {
    if (-not $counts.ContainsKey($must)) { Write-Host "Keine Werte der Art '$must' gelesen: Quelle verdaechtig, Liste unveraendert." -ForegroundColor Red; exit 1 }
}

if ($Preview) {
    $tmpList = Join-Path ([System.IO.Path]::GetTempPath()) ('privacy_preview_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllLines($tmpList, [string[]]@($fresh.Keys | Sort-Object), $u8)
    try {
        & (Join-Path $PSScriptRoot 'privacy_lint.ps1') -ExtraTermsFile $tmpList
        $code = $LASTEXITCODE
    } finally { Remove-Item -LiteralPath $tmpList -ErrorAction SilentlyContinue }
    Write-Host "Vorschau: nichts geschrieben, $code Treffer-Zeile(n) im getrackten Baum."
    exit $code
}

$known = @()
if (Test-Path $target) { $known = @([System.IO.File]::ReadAllLines($target, $u8) | Where-Object { $_ -and -not $_.StartsWith('#') }) }
$before = $known.Count
$merged = @($known + @($fresh.Keys) | Sort-Object -Unique)
New-Item -ItemType Directory -Force $localDir | Out-Null
$header = '# Automatisch aus der Instanz erzeugt (scripts/refresh_privacy_denylist.ps1), waechst nur. NIE committen.'
[System.IO.File]::WriteAllLines($target, [string[]](@($header) + $merged), $u8)
Write-Host ("Liste aktualisiert: {0} Begriffe, {1} neu." -f $merged.Count, ($merged.Count - $before))
exit 0
