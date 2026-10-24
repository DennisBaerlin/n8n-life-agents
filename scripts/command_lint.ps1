#Requires -Version 5.1
# command_lint.ps1 -- WS-5 Command-Registry Coverage-Lint (hartes Gate, Vorbild scripts/approval_lint.ps1).
# Prueft die SoT `commands`-Bloecke der Manifeste (packages/*/manifest.json) gegen (a) die deterministischen
# Zweige des Orchestrator-Switch `Command router` in den GEBAUTEN Workflow-JSONs (getrackte Deploy-Contracts,
# wie approval_lint -- kein ephemeres dist/) und (b) die /help-Katalog-Doku -- fail-closed, beidseitig:
#   (a) jeder im Router behandelte Befehl (gequotetes '/xxx'-Literal in einer leftValue-Bedingung) ist
#       registriert ODER auf der Hidden-Allowlist {/start,/hilfe};
#   (b) kein Orphan: jeder registrierte Befehl ist real im Router verdrahtet;
#   (c) jeder registrierte Befehl ist in einer /help-Tail-Sektion dokumentiert — in JEDER Katalogsprache (Texte
#       <pkg>.help.<tail-id>.body im Textkatalog, Hilfe<->Features synchron; gegen die SoT, NICHT die generierte
#       .md -> kein Rebuild-Order-Trap);
#   plus Registry-Selbstkonsistenz (cmd-Form, visibility-Enum, keine Dubletten) und der Menue-Text je Sprache
#   (Katalog-Key <pkg>.cmd.<name>, nicht leer, Laengen-Cap; Textkatalog Phase B, docs/package-contract.md §3.11).
# Exit-Code = Anzahl Fehler (CI-/Pre-Push-tauglich). Kein LLM, kein Netz, kein Substrat.
param([switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# --- Hidden-Allowlist: deterministische Befehle, die bewusst NICHT beworben werden (nicht im Menue) -----
#   /start = Telegram-Spezial (auto-invoked beim Erstkontakt); /hilfe = DE-Alias von /help, /sprache = DE-Alias
#   von /language, /erinnerungen = DE-Alias von /reminders (jeweils selber Branch).
$hidden = @('/start', '/hilfe', '/sprache', '/erinnerungen')
$descCap = 48   # Kuerze-Cap fuer ein aufgeraeumtes Menue (Telegram BotCommand.description Hard-Limit ist 256).
$langs = @((([System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\manifest.json'), $u8) | ConvertFrom-Json).languages.list) | ForEach-Object { [string]$_.code })

# Katalog-Datei eines Pakets in einer Sprache (fehlt -> leeres Objekt).
$locCache = @{}
function Get-Locale([string]$Pkg, [string]$Lang) {
    $k = "$Pkg|$Lang"
    if (-not $locCache.ContainsKey($k)) {
        $f = Join-Path $RepoRoot "packages\$Pkg\locales\$Lang.json"
        $locCache[$k] = if (Test-Path $f) { [System.IO.File]::ReadAllText($f, $u8) | ConvertFrom-Json } else { [pscustomobject]@{} }
    }
    $locCache[$k]
}

# --- (1) Registry laden + Selbst-Konsistenz + Menue-Texte; nebenbei alle Tail-Bodies je Sprache fuer Check (c) --
$registered = @{}            # cmd -> visibility
$tailBodies = @{}            # lang -> List[string]
foreach ($l in $langs) { $tailBodies[$l] = New-Object System.Collections.Generic.List[string] }
foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json'))) {
    $mjson = [System.IO.File]::ReadAllText($mf.FullName, $u8) | ConvertFrom-Json
    $pkg = [string]$mjson.name
    if ($mjson.catalog -and $mjson.catalog.tail) {
        foreach ($t in $mjson.catalog.tail) {
            foreach ($l in $langs) { $b = (Get-Locale $pkg $l)."$pkg.help.$($t.id).body"; if ($b) { $tailBodies[$l].Add([string]$b) } }
        }
    }
    if (-not $mjson.commands -or -not $mjson.commands.list) { continue }
    foreach ($c in $mjson.commands.list) {
        $cmd = [string]$c.cmd; $vis = [string]$c.visibility
        if ($cmd -notmatch '^/[a-z][a-z0-9_]{0,31}$') { Fail "registry: ungueltiges cmd '$cmd' (muss ^/[a-z][a-z0-9_]{0,31}`$ matchen)"; continue }
        if ($registered.ContainsKey($cmd))            { Fail "registry: doppeltes cmd '$cmd'"; continue }
        if ($vis -notin @('owner', 'member', 'all'))  { Fail "registry: '$cmd' ungueltige visibility '$vis' (owner|member|all)" }
        if ($null -ne $c.description)                 { Fail "registry: '$cmd' traegt noch description im Manifest — der Menue-Text ist der Katalog-Key $pkg.cmd.$($cmd.TrimStart('/')) (§3.11)" }
        $key = "$pkg.cmd.$($cmd.TrimStart('/'))"
        foreach ($l in $langs) {
            $desc = [string](Get-Locale $pkg $l).$key
            if ([string]::IsNullOrWhiteSpace($desc)) { Fail "registry: '$cmd' Menue-Text $key fehlt in packages/$pkg/locales/$l.json" }
            elseif ($desc.Length -gt $descCap)      { Fail "registry: '$cmd' Menue-Text $key ($l) $($desc.Length) Zeichen > $descCap (Kuerze-Cap; Telegram-Hard-Limit 256)" }
        }
        $registered[$cmd] = $vis
    }
}

# --- (2) Router-Tokens aus dem GEBAUTEN Orchestrator-Switch `Command router` -----------------------------
# Getrackte-Dir-Scan wie approval_lint (NIE rekursiver Glob -> .local/backups/** haette alte Orchestrator-
# JSONs mit /help-Literalen). Node per name=='Command router' UND type=='switch'; hart-fail bei 0/>1.
$wfDirs = @()
foreach ($p in (Get-ChildItem -Path (Join-Path $RepoRoot 'packages') -Directory -ErrorAction SilentlyContinue)) {
    $w = Join-Path $p.FullName 'workflows'; if (Test-Path $w) { $wfDirs += $w }
}
$routerNodes = @()
foreach ($file in (Get-ChildItem $wfDirs -Filter '*.json')) {
    $wf = [System.IO.File]::ReadAllText($file.FullName, $u8) | ConvertFrom-Json
    foreach ($n in $wf.nodes) {
        if ($n.type -eq 'n8n-nodes-base.switch' -and [string]$n.name -eq 'Command router') { $routerNodes += $n }
    }
}
$handled = @{}
if ($routerNodes.Count -ne 1) {
    Fail "Genau EIN Switch-Node 'Command router' erwartet, $($routerNodes.Count) gefunden (Rename/Build-Drift?)"
} else {
    foreach ($r in $routerNodes[0].parameters.rules.values) {
        foreach ($cond in $r.conditions.conditions) {
            # M1: quoted-only ('/xxx' inkl. Single-Quote-Delimiter) -> das Regex-Literal /\s+/ wird NIE getroffen.
            foreach ($m in [regex]::Matches([string]$cond.leftValue, "'(/[a-z][a-z0-9_]*)'")) {
                $handled[$m.Groups[1].Value] = $true
            }
        }
    }
    # (a) jeder behandelte Nicht-Hidden-Befehl ist registriert (blockt un-katalogisiertes Command)
    foreach ($cmd in ($handled.Keys | Sort-Object)) {
        if ($hidden -contains $cmd) { continue }
        if (-not $registered.ContainsKey($cmd)) { Fail "Router behandelt '$cmd', aber es ist in KEINEM manifest commands.list (un-katalogisiertes Command)" }
    }
    # (b) kein Orphan: jeder registrierte Befehl ist real im Router verdrahtet
    foreach ($cmd in ($registered.Keys | Sort-Object)) {
        if (-not $handled.ContainsKey($cmd)) { Fail "registry: '$cmd' ist registriert, aber NICHT im 'Command router' verdrahtet (Orphan)" }
    }
}
if ($Verbose) { Write-Host "  handled = $(@($handled.Keys | Sort-Object) -join ', ')" -ForegroundColor DarkGray }

# --- (c) jeder registrierte Befehl ist in einer Tail-Sektion dokumentiert, je Sprache (Wort-Grenze) -----
foreach ($l in $langs) {
    $tailAll = ($tailBodies[$l] -join "`n")
    foreach ($cmd in ($registered.Keys | Sort-Object)) {
        $rx = [regex]::Escape($cmd) + '(?![a-z0-9_])'   # /help matcht NICHT /helper
        if ($tailAll -notmatch $rx) { Fail "registry: '$cmd' ist in KEINER /help-Tail-Sektion ($l) dokumentiert (Hilfe<->Features Drift)" }
    }
}

if ($fails -eq 0) { Write-Host "command_lint: OK ($($registered.Count) Befehl(e) registriert, Router + /help-Doku konsistent)" -ForegroundColor Green }
else { Write-Host "command_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
