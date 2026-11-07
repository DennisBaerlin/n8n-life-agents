# PreToolUse-Hook (Edit|Write|NotebookEdit|Bash|PowerShell): die Mini-App aendert sich nur mit Zustimmung des Owners
# (Owner-Regel 2026-11-01: die Darstellung ist immer ein eigener Plan). Hart per 'deny' (Hook-'ask' wird in der
# VS-Code-Erweiterung still durchgewinkt, siehe enforce_owner_window.ps1).
#
# APP-FENSTER: scripts/grant_app_window.ps1 (nur der Owner, im Terminal) schreibt .claude/app_grant.txt im Haupt-Checkout
# (Zeile 1 = UTC-Expiry, ISO 'o'). Bewusst getrennt vom Owner-Fenster der LLM-Suiten: Testkosten freizugeben ist keine
# Zustimmung zu einer App-Aenderung. Offenes Fenster = alles erlaubt; abgelaufene Grants loescht der Hook selbst.
# Suche und Schreib-Erkennung: lib/grant_window.ps1 (gemeinsam mit enforce_owner_window.ps1). Fehlt sie, bricht sie oder ist
# sie leer, gilt das Fenster als zu und jeder Befehl als schreibend (fail-closed).
#
# APP-FLAECHE (was die Mini-App zeigt):
#   packages/<pkg>/build/app/**            die Seite selbst
#   core.main_app_serve (Def + JSON)       ihre Auslieferung
#   migrations/*fn_app_*                   Bildschirm-Handler, Pillen, Banner, Lint
#   locales/*.json: Keys <pkg>.app.*       ihre Texte (nur solche Zeilen, die Datei ist geteilt)
#   manifest.json: app_screens             ihre Bildschirm-Liste
# Nicht dazu: Tests, die Hilfe-Seite, Rechen-fns ausserhalb fn_app_* (fn_account_low_state u. a.): eine Aenderung dort kann
# die Anzeige indirekt beeinflussen, das bleibt Sache des Plans (kein Pfad-Muster kann es erkennen).
#
# Geprueft wird:
#   (1) Edit/Write/NotebookEdit auf die App-Flaeche ohne Fenster -> deny.
#   (2) Shell-Befehl, der einen App-Pfad nennt UND einen Schreib-Operator traegt, ohne Fenster -> deny. Blosses Lesen
#       (cat, grep, sed -n, git diff) laeuft durch. Text-Abgleich, deshalb bewusst breit; im Zweifel den Befehl trennen.
#   (3) 'git commit', dessen Stand die App-Flaeche beruehrt, ohne Fenster -> deny. Backstop fuer alles, was (2) nicht sieht
#       (Skript, Variable). Ohne lesbares git-Ergebnis laeuft der Befehl durch; prek ist davon unberuehrt.
#       Bei MERGE_HEAD zaehlen nur Dateien, die sich gegenueber BEIDEN Eltern unterscheiden (im Merge veraendert/aufgeloest).
#   (4) immer deny: grant_app_window.ps1 ausfuehren oder app_grant.txt schreiben (Maker-Checker). Edit/Write/NotebookEdit
#       auf owner_grant.txt sperrt dieser Hook mit, weil er auf diesen Tools ohnehin laeuft (Rest: enforce_owner_window.ps1).
# Kein lesbares JSON: der rohe Text wird wie ein Shell-Befehl geprueft.
# Grenze: wirkt nur auf Claude-Sessions; Commits des Owners im Terminal sind frei. Kein Match -> kein Output.
# Test: scripts/dev/app_window_hook_test.ps1. ASCII-only + Compact-JSON (kein BOM in stdout-JSON).
$inp = [Console]::In.ReadToEnd()
$j = $null
try { $j = $inp | ConvertFrom-Json } catch { }
$libOk = $false
try { . (Join-Path $PSScriptRoot 'lib\grant_window.ps1'); $libOk = [bool](Get-Command Test-GrantWindow, Test-ShellWrite, Test-ShellGrantWrite -ErrorAction Stop) } catch { }

$AppPath = '(packages[/\\][^/\\\s"'']+[/\\]build[/\\]app[/\\]|core\.main_app_serve|migrations[/\\][^/\\\s"'']*fn_app_)'
$LocalePath = 'packages[/\\][^/\\\s"'']+[/\\]locales[/\\][^/\\\s"'']+\.json'
$ManifestPath = 'packages[/\\][^/\\\s"'']+[/\\]manifest\.json'
$LocaleText = '[a-z_]+\.app\.'
$ManifestText = 'app_screens'
$Grant = 'app_grant\.txt'

function Block-ToolCall([string]$Reason) {
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } } | ConvertTo-Json -Compress -Depth 5
  [Console]::Out.Write($out)
  exit 0
}
function Block-App {
  Block-ToolCall 'Die Mini-App aendert sich nur mit Zustimmung des Owners, die Darstellung ist immer ein eigener Plan. Dem Owner zuerst zusammenfassen, was vorher ist und was danach ist (je Bildschirm, kleinste Aenderung, kein Umbau). Nach der Zustimmung oeffnet der Owner im Terminal das Fenster (.\scripts\grant_app_window.ps1, Default 60 Min). Nicht umgehen, danach erneut senden.'
}
function Test-WindowOpen { return $libOk -and (Test-GrantWindow 'app_grant.txt') }

$tool = [string]$j.tool_name
if ($tool -in @('Edit', 'Write', 'NotebookEdit')) {
  $path = [string]$j.tool_input.file_path
  if (-not $path) { $path = [string]$j.tool_input.notebook_path }
  if ($path -match $Grant) { Block-ToolCall 'Das App-Fenster oeffnet nur der Owner selbst im Terminal: .\scripts\grant_app_window.ps1.' }
  if ($path -match 'owner_grant\.txt') { Block-ToolCall 'Das Owner-Fenster oeffnet nur der Owner selbst im Terminal: .\scripts\grant_owner_window.ps1. Claude schreibt owner_grant.txt nie.' }
  $text = [string]$j.tool_input.old_string + "`n" + [string]$j.tool_input.new_string + "`n" + [string]$j.tool_input.content
  $hit = ($path -match $AppPath) -or
         ($path -match $LocalePath -and $text -match $LocaleText) -or
         ($path -match $ManifestPath -and $text -match $ManifestText)
  if ($hit -and -not (Test-WindowOpen)) { Block-App }
  exit 0
}

$cmd = if ($j) { [string]$j.tool_input.command } else { [string]$inp }
if (-not $cmd) { exit 0 }

# (4) Maker-Checker: Fenster oeffnet nur der Owner (Muster enforce_owner_window: Aufruf-Position oder Ausfuehrungs-Operator)
if ($cmd -match 'grant_app_window\.ps1') {
  $atCmdPos = $cmd -match '(?m)(?:^|[;&|(]\s*)\S*grant_app_window\.ps1'
  $hasExec  = $cmd -match '(?i)(?:^|[\s;|(])(?:&|\.)\s*(?:\$|\S*grant_app_window)|(?:^|[\s;|(])(?:powershell|pwsh|cmd|start|call|Start-Process|Invoke-Expression|iex|Invoke-Command|icm)(?:\.exe)?\b|(?:^|\s)-(?:File|Command|FilePath|ArgumentList|c|f)\b'
  if ($atCmdPos -or $hasExec) {
    Block-ToolCall 'Das App-Fenster oeffnet nur der Owner selbst im Terminal: .\scripts\grant_app_window.ps1. Claude ruft es nie auf; den Owner fragen und danach erneut senden.'
  }
}

$hasWrite = (-not $libOk) -or (Test-ShellWrite $cmd)
if ($cmd -match $Grant -and (-not $libOk -or (Test-ShellGrantWrite $cmd 'app_grant.txt'))) {
  Block-ToolCall 'Das App-Fenster oeffnet nur der Owner selbst im Terminal: .\scripts\grant_app_window.ps1.'
}

# (2) Schreib-Operator + App-Pfad im selben Befehl, oder Umleitung in einen App-Pfad
$redirect = $cmd -match ">>?\s*[""']?[^\s""']*$AppPath"
$pathHit = ($cmd -match $AppPath) -or
           ($cmd -match $LocalePath -and $cmd -match $LocaleText) -or
           ($cmd -match $ManifestPath -and $cmd -match $ManifestText)
if ($redirect -or ($hasWrite -and $pathHit)) {
  if (-not (Test-WindowOpen)) { Block-App }
  exit 0
}

# (3) Backstop beim Commit: Stand im Arbeitsverzeichnis des Befehls (cd/Set-Location/git -C, sonst cwd der Session)
if ($cmd -match '\bgit\b[^|;&\n]*\scommit\b') {
  $tok = '("[^"]*"|''[^'']*''|[^\s;&|]+)'
  $dir = [string]$j.cwd
  if ($cmd -match "(?i)\b(?:cd|Set-Location)\s+(?:-Path\s+)?$tok") { $dir = $Matches[1].Trim('"', "'") }
  if ($cmd -match "\bgit\s+-C\s+$tok") { $dir = $Matches[1].Trim('"', "'") }
  if (-not $dir) { $dir = (Get-Location).Path }
  try {
    $range = if ($cmd -match '(?:\s-[a-zA-Z]*a[a-zA-Z]*\b|\s--all\b)') { 'HEAD' } else { '--cached' }
    # Merge-Commit (MERGE_HEAD vorhanden): nur zaehlen, was sich gegenueber BEIDEN Eltern unterscheidet, also in diesem Merge
    # wirklich veraendert oder aufgeloest wurde. Unveraendert aus dem anderen Elternteil mitgebrachte Dateien sind kein App-Eingriff.
    & git -C $dir rev-parse -q --verify MERGE_HEAD 2>$null | Out-Null
    $isMerge = ($LASTEXITCODE -eq 0)
    $bases = if ($isMerge) { @('HEAD', 'MERGE_HEAD') } else { @('') }
    $nameSets = @(); $lineHits = @()
    foreach ($b in $bases) {
      $a = @(if (-not $isMerge) { $range } elseif ($range -eq '--cached') { '--cached'; $b } else { $b })   # @(): ein Einzelwert wuerde sonst als String gesplattet
      $nameSets += , @(& git -C $dir diff @a --name-only 2>$null | Where-Object { $_ -match $AppPath })
      $lines = @(& git -C $dir diff @a -U0 -- 'packages/*/locales/*.json' 'packages/*/manifest.json' 2>$null)
      $lineHits += (@($lines | Where-Object { $_ -match "^[+-]\s.*(`"$LocaleText|$ManifestText)" }).Count -gt 0)
    }
    $common = @($nameSets[0] | Where-Object { $nameSets.Count -eq 1 -or $nameSets[1] -contains $_ })
    $hit = ($common.Count -gt 0) -or (@($lineHits | Where-Object { -not $_ }).Count -eq 0)
  } catch { $hit = $false }
  if ($hit -and -not (Test-WindowOpen)) { Block-App }
}
exit 0
