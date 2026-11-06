#Requires -Version 5.1
# Read-only ad-hoc SELECT gegen die Docker-Test-Substrat-DB (Verifikation/Debug; raus aus Prod).
# Die Session wird READ ONLY erzwungen (SET default_transaction_read_only=on) -> versehentliche
# Writes brechen ab. Verbindung NICHT mehr ueber TCP/PG_*, sondern container-intern per Peer-Auth
# (docker exec ... psql -d n8n), exakt der apply_schema.sh-Pfad. Es gibt kein lebendes Prod mehr;
# die DB liegt im ephemeren Substrat (scripts/dev/bootstrap_test_n8n.ps1).
#
# Usage:
#   .\scripts\db_query.ps1 -Sql "SELECT * FROM finance.loan_overview;"
#   .\scripts\db_query.ps1 -Sql "SELECT ..." -Csv
param(
    [Parameter(Mandatory)][string]$Sql,
    [switch]$Csv
)

$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Verbindung zur ephemeren Docker-Test-Instanz: Get-TestN8nConnection liefert den Container-Namen
# (Throw mit Hinweis, falls kein Substrat laeuft -> nie versehentlich gegen eine fremde Instanz).
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn = Get-TestN8nConnection

# READ ONLY erzwingen -> jeder versehentliche Write in dieser Session schlaegt fehl. (Der docker-exec-
# Pfad ist Superuser/Peer-Auth -> der READ-ONLY-Guard ist die Sicherung, nicht die Rolle.)
$wrapped = "SET default_transaction_read_only = on; $Sql"

# Invoke-TestN8nPsql setzt --no-psqlrc/-X/-v ON_ERROR_STOP=1/-d n8n selbst; hier nur die Zusatz-Args.
$psqlArgs = if ($Csv) { @('--csv', '-c', $wrapped) } else { @('-P', 'pager=off', '-c', $wrapped) }
$r = Invoke-TestN8nPsql -Container $conn.Container -PsqlArgs $psqlArgs
$r.Output | ForEach-Object { Write-Output $_ }
if ($r.Code -ne 0) { throw "psql fehlgeschlagen (Exit $($r.Code))." }
