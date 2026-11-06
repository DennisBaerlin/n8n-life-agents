#Requires -Version 5.1
# =====================================================================================================
# agent_cases.ps1 — findet die Agent-Test-Case-Dateien aller Pakete (Phase D: keine Datei-Liste je Paket)
#
# Quelle: tests/agent/<pkg|cross>/*_cases.json (Layout erzwingt layout_lint L3). Jede Datei ist ein JSON-Array
# von Cases (eine Objekt-Wurzel wird als EIN Case gelesen). Die Konsumenten filtern selbst nach der Case-Form:
#   - lib/catalog.ps1 Get-CaseUtterance: Routing-Cases (Schluessel expected_tool ODER expected_route vorhanden)
#     als Pool fuer den Example-Drift-Check;
#   - scripts/mock_lint.ps1: Mock-Tier-Cases (task, kein `kind`; Art route|tool aus dem Erwartungs-Schluessel).
# Abhaengigkeitsfrei (nur JSON rein, Objekte raus), damit Build und Lint sie dot-sourcen koennen.
# =====================================================================================================

function Get-AgentCaseFile {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $u8   = New-Object System.Text.UTF8Encoding($false)
    $root = $RepoRoot.TrimEnd('\', '/')
    $out  = @()
    foreach ($f in (Get-ChildItem (Join-Path $root 'tests\agent\*\*_cases.json') | Sort-Object FullName)) {
        $json = [System.IO.File]::ReadAllText($f.FullName, $u8) | ConvertFrom-Json
        $out += [pscustomobject]@{
            Path  = $f.FullName
            Rel   = ($f.FullName.Substring($root.Length + 1) -replace '\\', '/')
            Cases = @($json)
        }
    }
    if ($out.Count -eq 0) { throw 'agent_cases: keine tests/agent/*/*_cases.json gefunden (Layout kaputt?).' }
    return $out
}

# Hat der Case den Schluessel (auch mit null/[] — ein "kein Tool"-Case ist trotzdem ein Routing-Case)?
function Test-CaseHasKey([object]$Case, [string]$Key) {
    return ($null -ne $Case) -and ($Case.PSObject.Properties.Name -contains $Key)
}
