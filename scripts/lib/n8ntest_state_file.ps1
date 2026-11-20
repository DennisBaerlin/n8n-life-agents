# n8ntest_state_file.ps1 -- die eine Adresse der Zustandsdatei des Test-Substrats (URL der socat-Bruecke, API-Schluessel, mock_*):
# .local/n8ntest_state.<container>.json im Haupt-Checkout, je Container eine Datei (Container = $env:N8NTEST_CONTAINER, sonst der
# Bootstrap-Default). Die Datei gehoert zum Container, nicht zum Worktree: Laege sie im Worktree, laese ein zweiter Worktree
# gegen denselben Container einen alten Schluessel (401 Unauthorized); eine gemeinsame Datei fuer alle Container liesse ein zweites
# Substrat den Schluessel des ersten ueberschreiben (403). Jeder Leser und Schreiber holt den Pfad hier.
# Dot-sourcen; Test: scripts/dev/n8ntest_state_file_test.ps1.
# Der Haupt-Checkout wird je Lauf einmal ermittelt: git rev-parse kostet rund 50 ms, die Treiber fragen den Pfad in Warteschleifen.
$script:TestN8nMainCheckout = $null
function Get-TestN8nStateFile {
    param([string]$Container = $(if ($env:N8NTEST_CONTAINER) { $env:N8NTEST_CONTAINER } else { 'lifeagents-n8ntest' }))
    if (-not $script:TestN8nMainCheckout) {
        # Haupt-Checkout = Elternordner des gemeinsamen .git; stimmt nicht bei Bare-Repo oder --separate-git-dir (hier nicht genutzt).
        $common = [string](& git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir)
        $script:TestN8nMainCheckout = Split-Path $common -Parent
    }
    return (Join-Path $script:TestN8nMainCheckout ".local\n8ntest_state.$Container.json")
}

# Write-TestN8nState -- schreibt die Zustandsdatei (Datei des Containers, UTF-8 ohne BOM) fuer den Verbund; der klassische
# Bootstrap schreibt dieselben Felder ohne runtime/project noch selbst (faellt in P6). runtime sagt dem Treiber (Get-TestN8nRuntime),
# welcher Unterbau laeuft: classic = systemd-Container (bootstrap_test_n8n.ps1), compose = Docker-Verbund
# (bootstrap_test_stack.ps1, dann project = LA_PROJECT und container = <project>-master). Schreibt die Datei neu, also ohne
# die mock_*-Felder der enable_mock_*-Skripte: die setzen sich nach einem Neuaufbau wieder (Substrat-Neuaufbau = Mocks neu).
$script:TestN8nRuntimes = @('classic', 'compose')
function Write-TestN8nState {
    param(
        [Parameter(Mandatory)][string]$Runtime,
        [string]$Project = '',
        [Parameter(Mandatory)][string]$Url,
        [string]$ApiKey = '',
        [Parameter(Mandatory)][string]$Container,
        [string]$ContainerId = '',
        [string]$StateContainer = $(if ($env:N8NTEST_CONTAINER) { $env:N8NTEST_CONTAINER } else { 'lifeagents-n8ntest' })
    )
    if ($script:TestN8nRuntimes -notcontains $Runtime) { throw "Unbekannter Unterbau '$Runtime' (erlaubt: $($script:TestN8nRuntimes -join ', '))." }
    if ($Runtime -eq 'compose' -and -not $Project) { throw 'Unterbau compose braucht -Project (LA_PROJECT).' }
    $file = Get-TestN8nStateFile -Container $StateContainer
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    $state = [ordered]@{
        container    = $Container
        container_id = $ContainerId
        url          = $Url
        api_key      = $ApiKey
        runtime      = $Runtime
        project      = $Project
        built_at     = (Get-Date -Format 'o')
    }
    [System.IO.File]::WriteAllText($file, ($state | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}
# Get-TestN8nRuntime -State <gelesenes json> -> classic|compose; ein fehlendes Feld ist classic (der klassische Bootstrap
# schreibt es nicht), ein unbekannter Wert ist ein Fehler statt eines stillen Rueckfalls auf den falschen Unterbau.
function Get-TestN8nRuntime {
    param([Parameter(Mandatory)]$State)
    $r = [string]$State.runtime
    if (-not $r) { return 'classic' }
    if ($script:TestN8nRuntimes -notcontains $r) { throw "Zustandsdatei nennt unbekannten Unterbau '$r'." }
    return $r
}
