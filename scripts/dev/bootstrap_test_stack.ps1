#Requires -Version 5.1
# bootstrap_test_stack.ps1 -- Test-Substrat als Docker-Verbund, derselbe, den ein Nutzer bekommt (Gegenstueck zum klassischen
# systemd-Container bootstrap_test_n8n.ps1; beide laufen nebeneinander, Treiber lesen den Unterbau aus der Zustandsdatei).
# Ablauf: master-Abbild aus dem Arbeitsstand bauen -> `stack up` ueber den Kern -> Antwort-Datei mit dem Code des Fragebogens
# (tests/wizard/render_ci_answers.js --profile dev + TEST_*-Werte aus .env) -> `stack install -- --profile dev --packages …`
# -> REST-Bruecke -> API-Schluessel -> Zustandsdatei (runtime=compose). Nach einer kalten Installation ein Schnappschuss der
# Daten-Volumes; -Reset spielt ihn zurueck (rund 30 s statt einer Installation), wenn sein Schluessel noch passt (Abbild,
# Antwort-Datei, compose.yml), sonst kalt neu. Bausteine, Etiketten-Vertrag und Abbau-Regeln: scripts/lib/test_stack.ps1.
#
# Usage (Pflicht: Projekt $env:N8NTEST_CONTAINER, Bruecken-Port $env:N8NTEST_PORT, Port-Spanne des Kerns $env:N8NTEST_STACK_PORTS):
#   $env:N8NTEST_CONTAINER='s4t0'; $env:N8NTEST_PORT='57500'; $env:N8NTEST_STACK_PORTS='57510-57519'
#   .\scripts\dev\bootstrap_test_stack.ps1             # hoch + installieren
#   … .\scripts\dev\bootstrap_test_stack.ps1 -Reset     # Schnappschuss zurueck (passt er nicht: kalt neu + neuer Schnappschuss)
#   … .\scripts\dev\bootstrap_test_stack.ps1 -Down      # Verbund, Daten, Schnappschuss, Abbild, Zustandsdatei weg
#   -HitlChatApproval / -FullDeploy / $env:LLM_GATEWAY_SERIAL_TOOLS wie bootstrap_test_n8n.ps1; -Verbose zeigt die Kern-Ausgabe.
# Ohne Schalter auf einem vorhandenen Verbund: `stack up` (neues Abbild ersetzt den master) und eine Installation ueber die
# vorhandenen Daten, kein neuer Schnappschuss (er bliebe sonst nicht der Stand „frisch installiert“).
# Ohne Attrappen: die Telegram-Weiche gehoert in die Umgebung von provision.sh (in der Antwort-Datei gesperrt); bis die
# Attrappen am anchor laufen, installiert der Verbund wie der klassische Unterbau mit dem Test-Bot aus .env
# (TEST_TELEGRAM_BOT_TOKEN, nie der Prod-Bot) und TELEGRAM_WEBHOOK_TAKEOVER=1.
# Voraussetzungen: Docker Desktop (Linux-Container), git, .env mit TEST_HARNESS_SECRET.
# Exit 0 = Verbund bereit bzw. abgebaut; jeder Fehler wirft (Exit ungleich 0).
param(
    [switch]$Reset,
    [switch]$Down,
    [switch]$HitlChatApproval,
    [switch]$FullDeploy,
    [switch]$Verbose
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# Schreibweise wie git sie liefert (C:/…): dieselbe wie bootstrap_test_n8n.ps1, der Haken und die Platz-Liste im Etikett
# lifeagents.worktree vergleichen.
$RepoRoot = ([string](git -C $PSScriptRoot rev-parse --show-toplevel)).Trim()
. "$PSScriptRoot\..\lib\test_stack.ps1"
. "$PSScriptRoot\..\lib\n8ntest_state_file.ps1"
. "$PSScriptRoot\..\lib\substrate_reservations.ps1"
. "$PSScriptRoot\..\lib\dotenv.ps1"

if (-not $env:N8NTEST_CONTAINER -or -not $env:N8NTEST_PORT -or -not $env:N8NTEST_STACK_PORTS) {
    throw 'N8NTEST_CONTAINER, N8NTEST_PORT und N8NTEST_STACK_PORTS setzen (eigener Verbund je Session, kein geteilter Standard).'
}
$Names = Get-TestStackNames $env:N8NTEST_CONTAINER
$Ports = Get-TestStackPorts -Port $env:N8NTEST_PORT -CoreRange $env:N8NTEST_STACK_PORTS
$N8nUrl = "http://127.0.0.1:$($Ports.Bridge)"
$LogDir = Join-Path ([System.IO.Path]::GetTempPath()) "lifeagents-test-stack\$($Names.Project)"
$BackupDir = Join-Path $LogDir 'backup'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$StateVolumes = Get-TestStackStateVolumes ([System.IO.File]::ReadAllText((Join-Path $RepoRoot 'provisioning\lib\runtime.sh'), $Utf8NoBom))
$StateFile = Get-TestN8nStateFile -Container $Names.Project
$clock = [System.Diagnostics.Stopwatch]::StartNew()
function Write-Step([string]$Text) { Write-Host ("[{0,5:n0} s] {1}" -f $clock.Elapsed.TotalSeconds, $Text) -ForegroundColor Cyan }
function Show-CoreLog($Result) { if ($Verbose -and $Result.err_file -and (Test-Path $Result.err_file)) { Write-Host (Get-TestStackErrTail $Result.err_file 400) } }

if ((Invoke-Native docker @('version', '--format', '{{.Server.Os}}')).Output -join '' -notmatch 'linux') {
    throw 'Docker antwortet nicht oder laeuft nicht mit Linux-Containern.'
}
function Test-StackInstalled { return ((Get-TestStackVolumeLabel (& $Names.Volume 'var_la') 'io.lifeagents.install') -eq $Names.Project) }

# Remove-OwnStack -- Bruecke, Container (Kern ohne --delete-data), Daten-Volumes, optional Schnappschuss; Abbilder bleiben.
function Remove-OwnStack([switch]$WithSnapshot) {
    Remove-TestStackBridge $Names
    if ((Test-StackInstalled) -or ((Invoke-Native docker @('ps', '-aq', '--filter', "label=io.lifeagents.install=$($Names.Project)")).Output -join '')) {
        if ((Invoke-Native docker @('image', 'inspect', $Names.Image)).Code -ne 0) { throw "Abbild $($Names.Image) fehlt - der Abbau braucht den Kern daraus (erst ohne -Down bauen)." }
        $r = Invoke-TestStackCore -Names $Names -Ports $Ports -Verb uninstall -LogDir $LogDir
        Show-CoreLog $r
        Assert-TestStackCoreOk $r 'uninstall'
    }
    Remove-TestStackStateVolumes $Names $StateVolumes
    if ($WithSnapshot) { Remove-TestStackSnapshot $Names $StateVolumes }
}

if ($Down) {
    $before = Get-TestStackDockerNames
    $labeled = @((Invoke-Native docker @('ps', '-a', '--filter', "label=io.lifeagents.install=$($Names.Project)", '--format', '{{.Names}}')).Output | Where-Object { $_ })
    Write-Step "Abbau $($Names.Project) ..."
    Remove-OwnStack -WithSnapshot
    if ((Invoke-Native docker @('image', 'inspect', $Names.Image)).Code -eq 0) {
        $r = Invoke-Native docker @('image', 'rm', $Names.Image)
        if ($r.Code -ne 0) { throw "Abbild $($Names.Image) liess sich nicht entfernen: $($r.Output -join "`n")" }
    }
    # Namenlos gewordene Vorgaenger desselben Tags (jeder Bau mit neuem Arbeitsstand): nur mit eigenem Etikett + Worktree.
    $old = @((Invoke-Native docker @('images', '-q', '--filter', 'dangling=true', '--filter', 'label=lifeagents.substrate=n8n-image',
        '--filter', "label=lifeagents.worktree=$RepoRoot")).Output | Where-Object { $_ } | Sort-Object -Unique)
    if ($old.Count) { [void](Invoke-Native docker (@('image', 'rm') + $old)) }
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Remove-Item $LogDir -Recurse -Force -ErrorAction SilentlyContinue
    $finds = @(Compare-TestStackTeardown -Project $Names.Project -Before $before -After (Get-TestStackDockerNames) -Labeled $labeled)
    if ($finds.Count) { throw "Abbau-Abgleich:`n$($finds -join "`n")" }
    Write-Step "Abgebaut: keine Reste, nichts Fremdes entfernt."
    return
}

# --- Abbild, Antworten, Schluessel (ohne den Verbund anzufassen) -----------------------------------------------------------
Write-Step "master-Abbild $($Names.Image) aus dem Arbeitsstand ..."
$img = New-TestStackImage -RepoRoot $RepoRoot -Names $Names -LogDir $LogDir
Write-Step "Abbild $($img.ImageId.Substring(7, 12)) (Baum $($img.Tree.Substring(0, 12)))"

$envValues = @{}
Read-DotEnvLines (Join-Path $RepoRoot '.env') | ForEach-Object {
    if ($_ -match '^\s*(TEST_[A-Z0-9_]+)=(.*)$') { $envValues[$Matches[1]] = $Matches[2].Trim() }
}
if (-not $envValues['TEST_HARNESS_SECRET']) { Write-Warning 'TEST_HARNESS_SECRET fehlt in .env - Harness-Webhooks antworten dann 403.' }
if (-not $envValues['TEST_TELEGRAM_BOT_TOKEN']) { Write-Warning 'TEST_TELEGRAM_BOT_TOKEN fehlt in .env - Telegram-Zugang bleibt leer (wie klassisch; der Orchestrator-Trigger aktiviert ggf. nicht).' }
if (-not $envValues['TEST_ANTHROPIC_API_KEY']) { Write-Warning 'TEST_ANTHROPIC_API_KEY fehlt in .env - LLM-Zugang bleibt leer (die Agenten-Suiten brauchen ihn).' }
$extra = ConvertTo-TestStackExtra -Map (Get-TestInstallEnvMap $RepoRoot) -Values $envValues -HitlChatApproval:$HitlChatApproval -FullDeploy:$FullDeploy -SerialTools ([string]$env:LLM_GATEWAY_SERIAL_TOOLS)
$answers = Get-TestStackAnswers -RepoRoot $RepoRoot -Names $Names -BackupDir $BackupDir -ExtraText $extra -LogDir $LogDir
$extra = $null
$composeText = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'provisioning\compose\compose.yml'), $Utf8NoBom)
$key = Get-TestStackSnapshotKey -ImageId $img.ImageId -AnswersText $answers.Text -ComposeText $composeText

function Install-Stack {
    $in = Join-Path $LogDir 'answers.stdin'
    try {
        [System.IO.File]::WriteAllText($in, $answers.Text, $Utf8NoBom)
        Write-Step "stack install (Profil dev, Pakete $($answers.Packages)) ..."
        $r = Invoke-TestStackCore -Names $Names -Ports $Ports -Verb install -Rest @('--', '--profile', 'dev', '--packages', $answers.Packages) -StdinFile $in -LogDir $LogDir
    } finally { Remove-Item $in -Force -ErrorAction SilentlyContinue }
    Show-CoreLog $r
    Assert-TestStackCoreOk $r 'install'
}
function Start-Stack {
    $r = Invoke-TestStackCore -Names $Names -Ports $Ports -Verb up -LogDir $LogDir
    Show-CoreLog $r
    Assert-TestStackCoreOk $r 'up'
    Write-Step "stack up: edge $($r.ports.edge), wizard $($r.ports.wizard)"
}
function Resume-Stack {
    $r = Invoke-TestStackCore -Names $Names -Ports $Ports -Verb start -LogDir $LogDir
    Show-CoreLog $r
    Assert-TestStackCoreOk $r 'start'
}

$mode = if (-not (Test-StackInstalled)) { 'cold' } elseif ($Reset) { 'reset' } else { 'warm' }
if ($mode -eq 'reset') {
    $stored = Get-TestStackSnapshotKeyStored $Names $StateVolumes
    # Der Schluessel sagt nur, dass der Schnappschuss zum gebauten Abbild passt; laeuft der master (nach einem Lauf ohne
    # Schalter auf einem anderen Arbeitsstand) aus einem anderen Abbild, stammen er und die abgeleiteten Volumes nicht dazu.
    $running = ((Invoke-Native docker @('inspect', '-f', '{{.Image}}', $Names.Master)).Output -join '').Trim()
    if ($stored -eq $key -and $running -ne $img.ImageId) { $stored = 'master-image' }
    if ($stored -ne $key) {
        $why = if (-not $stored) { 'fehlt' } elseif ($stored -eq 'master-image') { 'passt, aber der master laeuft aus einem anderen Abbild' } else { 'veraltet (Abbild, Antworten oder compose.yml geaendert)' }
        Write-Step "Schnappschuss $why - kalt neu."
        Remove-OwnStack -WithSnapshot
        $mode = 'cold'
    }
}
if ($mode -eq 'cold') {
    Remove-TestStackSnapshot $Names $StateVolumes
    Wait-TestStackSlot $Names.Project
    New-TestStackPgdata $Names $RepoRoot
    Write-Step "stack up (kalt) ..."
    Start-Stack
    if (Remove-SlotReservation -Container $Names.Project) { Write-Host "Reservierung fuer $($Names.Project) eingeloest." }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    Install-Stack
    Write-Step 'Schnappschuss der Daten-Volumes ...'
    Stop-TestStackContainers $Names
    New-TestStackSnapshot $Names $StateVolumes $key $RepoRoot
    Resume-Stack
} elseif ($mode -eq 'reset') {
    Write-Step 'Schnappschuss passt: anhalten, zurueckspielen, starten ...'
    Remove-TestStackBridge $Names
    Stop-TestStackContainers $Names
    Restore-TestStackSnapshot $Names $StateVolumes $RepoRoot
    Resume-Stack
} else {
    Write-Step 'stack up + Installation ueber die vorhandenen Daten ...'
    Start-Stack
    Install-Stack
}

Start-TestStackBridge -Names $Names -Ports $Ports -RepoRoot $RepoRoot
Wait-TestStackReady $N8nUrl
$apiKey = Get-TestStackApiKey $Names
if (-not $apiKey) { Write-Warning "Kein N8N_API_KEY in /etc/lifeagents/core.env von $($Names.Master) - die Treiber koennen die REST-API nicht nutzen." }
$cid = ((Invoke-Native docker @('inspect', '-f', '{{.Id}}', $Names.Master)).Output -join '').Trim()
Write-TestN8nState -Runtime compose -Project $Names.Project -Url $N8nUrl -ApiKey $apiKey -Container $Names.Master -ContainerId $cid -StateContainer $Names.Project
Write-Step "bereit ($mode)"

Write-Host ''
Write-Host '============================================================'
Write-Host "  Test-Verbund bereit ($mode, $([int]$clock.Elapsed.TotalSeconds) s)"
Write-Host "  Projekt:  $($Names.Project)   master: $($Names.Master)"
Write-Host "  n8n:      $N8nUrl   (REST + Webhooks ueber $($Names.Bridge))"
Write-Host "  State:    $StateFile"
Write-Host "  Abbau:    .\scripts\dev\bootstrap_test_stack.ps1 -Down"
Write-Host '============================================================'
