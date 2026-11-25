#Requires -Version 5.1
# desktop_paths_lint.ps1 -- paths: von desktop.yml gegen die Dateien, die die Start-App einliest (hartes Gate).
# Der Workflow laeuft nur bei Aenderungen unter paths:. Liest die App oder ihr Bau eine Datei ausserhalb von
# provisioning/desktop, startet deren Aenderung ihn nur, wenn sie dort steht; sonst faellt ein Bruch erst beim naechsten
# Lauf aus anderem Anlass auf. Der Lint haelt:
#   (A) jede Datei ausserhalb von provisioning/desktop, die ein include_str!/include_bytes! in provisioning/desktop/**/*.rs
#       einliest, jeder Schluessel von bundle.resources in tauri.conf.json und jeder Repo-Pfad in den Schritten von
#       desktop-build.yml (plus $ImplicitInputs) steht in push UND pull_request;
#   (B) beide Workflow-Dateien stehen in beiden Listen;
#   (C) push und pull_request nennen dieselben Muster (eine Liste, zwei Ausloeser: sonst baut der PR nicht, was der Push baut).
# Nicht aufgenommen: Shell-Skripte unter provisioning/lib, die die App nur ueber `docker run ... lifeagents <verb>` im master
# erreicht. Der Lauf der App ruft sie nie auf; die Gegenstuecke (Blatt-Fixture, Vertrags-Konstanten) pruefen mock_runtime
# (B.blatt-fixture-aktuell) und contract_lint 33, und die Fixture steht hier in der Liste.
# Aufruf: .\scripts\desktop_paths_lint.ps1 [-Root <Baum>]   (-Root nur fuer scripts/dev/desktop_paths_lint_test.ps1)
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = git -C $PSScriptRoot rev-parse --show-toplevel }
$Root = (Resolve-Path $Root).Path
. (Join-Path $PSScriptRoot 'lib\main_push.ps1')
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }
function Rel([string]$p) { return $p.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/') }
function Read-Text([string]$rel) { [System.IO.File]::ReadAllText((Join-Path $Root $rel), $u8) }

# Pfad mit ./.. auf einen Repo-relativen Pfad mit Schraegstrichen aufloesen.
function Resolve-Rel([string]$BaseDir, [string]$Target) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($s in (($BaseDir + '/' + $Target) -split '/')) {
        if ($s -eq '' -or $s -eq '.') { continue }
        if ($s -eq '..') { if ($parts.Count -gt 0) { $parts.RemoveAt($parts.Count - 1) } } else { $parts.Add($s) }
    }
    return ($parts -join '/')
}

$wfDesktop = '.github/workflows/desktop.yml'
$wfBuild = '.github/workflows/desktop-build.yml'
# Gelesen, aber im Quelltext nicht als Pfad erkennbar: Read-UiTokens (scripts/lib/ui_tokens.ps1) laedt die Farbwerte fuer
# das Symbol der App.
$ImplicitInputs = @{ 'config/ui.tokens.json' = 'Farbwerte fuer das Symbol (Read-UiTokens im Schritt "Symbole")' }

# Eingaben sammeln: Pfad -> Fundstelle.
$inputs = [ordered]@{}
function Add-Input([string]$Path, [string]$Where) {
    if ($Path.StartsWith('provisioning/desktop/')) { return }
    if (-not $inputs.Contains($Path)) { $inputs[$Path] = $Where }
}

$desktopDir = Join-Path $Root 'provisioning/desktop'
if (Test-Path $desktopDir) {
    $rs = @(Get-ChildItem $desktopDir -Recurse -File -Filter '*.rs' | Where-Object { $_.FullName -notmatch '[\\/]target[\\/]' })
    $incRx = [regex]'\binclude_(?:str|bytes)!\(\s*"([^"]+)"'
    foreach ($f in $rs) {
        $rel = Rel $f.FullName
        $lines = [System.IO.File]::ReadAllLines($f.FullName, $u8)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].TrimStart().StartsWith('//')) { continue }
            foreach ($m in $incRx.Matches($lines[$i])) {
                $target = Resolve-Rel (Split-Path $rel -Parent).Replace('\', '/') $m.Groups[1].Value
                if (-not (Test-Path -LiteralPath (Join-Path $Root $target))) { Fail "${rel}:$($i + 1): include verweist auf eine fehlende Datei: $target"; continue }
                Add-Input $target "${rel}:$($i + 1)"
            }
        }
    }
}

$tauriRel = 'provisioning/desktop/app/tauri.conf.json'
if (Test-Path (Join-Path $Root $tauriRel)) {
    $conf = Read-Text $tauriRel | ConvertFrom-Json
    $res = $conf.bundle.resources
    if ($res) {
        foreach ($p in $res.PSObject.Properties) { Add-Input (Resolve-Rel 'provisioning/desktop/app' $p.Name) "$tauriRel bundle.resources" }
    }
}

if (Test-Path (Join-Path $Root $wfBuild)) {
    $pathRx = [regex]'(?<![\w./-])((?:scripts|docs|config|packages|provisioning|tests)/[\w./-]+\.[A-Za-z0-9]+)'
    $blines = [System.IO.File]::ReadAllLines((Join-Path $Root $wfBuild), $u8)
    for ($i = 0; $i -lt $blines.Count; $i++) {
        foreach ($m in $pathRx.Matches($blines[$i])) {
            $p = $m.Groups[1].Value
            if (Test-Path -LiteralPath (Join-Path $Root $p) -PathType Leaf) { Add-Input $p "${wfBuild}:$($i + 1)" }
        }
    }
}
foreach ($k in $ImplicitInputs.Keys) { Add-Input $k "`$ImplicitInputs ($($ImplicitInputs[$k]))" }
Add-Input $wfDesktop 'Workflow-Datei selbst'
Add-Input $wfBuild 'Workflow-Datei selbst'

# Listen aus desktop.yml.
$wfText = Read-Text $wfDesktop
$lists = [ordered]@{}
foreach ($trigger in 'push', 'pull_request') {
    $lists[$trigger] = @((Get-WorkflowPushFilter $wfText $trigger).Paths)
    if ($lists[$trigger].Count -eq 0) { Fail "$wfDesktop $trigger`: keine paths: gefunden (Block-Form erwartet)." }
}

foreach ($path in $inputs.Keys) {
    foreach ($trigger in $lists.Keys) {
        if ($lists[$trigger].Count -eq 0) { continue }
        $hit = @($lists[$trigger] | Where-Object { $path -match (ConvertTo-PathRegex $_) })
        if ($hit.Count -eq 0) {
            Fail "$wfDesktop $trigger`: '$path' fehlt in paths: (gelesen von $($inputs[$path])). Eintragen, sonst startet seine Aenderung den Start-App-Bau nicht."
        }
    }
}

$onlyPush = @($lists['push'] | Where-Object { $lists['pull_request'] -notcontains $_ })
$onlyPr = @($lists['pull_request'] | Where-Object { $lists['push'] -notcontains $_ })
foreach ($p in $onlyPush) { Fail "$wfDesktop pull_request: '$p' steht nur unter push; beide Listen muessen gleich sein." }
foreach ($p in $onlyPr) { Fail "$wfDesktop push: '$p' steht nur unter pull_request; beide Listen muessen gleich sein." }

if ($fails -eq 0) { Write-Host "desktop_paths_lint: OK ($($inputs.Count) Eingabe(n), $($lists['push'].Count) Muster je Ausloeser)" -ForegroundColor Green }
else { Write-Host "desktop_paths_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
