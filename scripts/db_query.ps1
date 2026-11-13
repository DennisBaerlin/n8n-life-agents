#Requires -Version 5.1
# Read-only ad-hoc SELECT gegen die DB des Docker-Test-Substrats (Verifikation/Debug).
# Die Session ist read-only (SET default_transaction_read_only=on) -> versehentliche Writes brechen ab.
# Verbindung container-intern per Peer-Auth (docker exec ... psql -d n8n), der apply_schema.sh-Pfad.
#
# Usage:
#   .\scripts\db_query.ps1 -Sql "SELECT * FROM finance.loan_overview;"
#   .\scripts\db_query.ps1 -Sql "SELECT ..." -Csv
#
# Voraussetzung: ein laufendes Substrat (scripts/dev/bootstrap_test_n8n.ps1), sonst wirft Get-TestN8nConnection.
# Exit: 0 = Abfrage lief; ungleich 0 = throw (kein Substrat, psql-Fehler).
param(
    [Parameter(Mandatory)][string]$Sql,
    [switch]$Csv
)

$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Get-TestN8nConnection wirft ohne Substrat -> nie versehentlich gegen eine fremde Instanz.
. "$PSScriptRoot\dev\test_n8n_state.ps1"
$conn = Get-TestN8nConnection

# Der docker-exec-Pfad ist Superuser/Peer-Auth -> der read-only-Guard ist die Sicherung, nicht die Rolle.
$wrapped = "SET default_transaction_read_only = on; $Sql"

# Invoke-TestN8nPsql setzt --no-psqlrc/-X/-v ON_ERROR_STOP=1/-d n8n selbst.
$psqlArgs = if ($Csv) { @('--csv', '-c', $wrapped) } else { @('-P', 'pager=off', '-c', $wrapped) }
$r = Invoke-TestN8nPsql -Container $conn.Container -PsqlArgs $psqlArgs
$r.Output | ForEach-Object { Write-Output $_ }
if ($r.Code -ne 0) { throw "psql fehlgeschlagen (Exit $($r.Code))." }
