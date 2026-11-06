# Gemeinsame Fenster-Mechanik der Hooks enforce_owner_window.ps1 und enforce_app_window.ps1. Laden per Dot-Sourcing.
# Fehlt diese Datei, bricht sie oder ist sie leer, behandeln beide Hooks das Fenster als zu und jeden Befehl als schreibend (fail-closed).
# ASCII-only, kein BOM (Hook-Regel).

# Beim Laden: Eine geerbte GIT_*-Variable koennte sonst jeden git-Aufruf des Hooks auf einen fremden Ordner umlenken,
# also die Fenster-Suche und den Commit-Backstop des App-Hooks.
foreach ($n in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_*' } | ForEach-Object { $_.Name })) {
  [Environment]::SetEnvironmentVariable($n, $null)
}

# Traegt der Shell-Befehl einen Schreib-Operator? Text-Abgleich, deshalb bewusst breit; im Zweifel den Befehl trennen.
# Die Kurzformen im zweiten Teil sind gewoehnliche Woerter, darum zaehlen sie nur an Befehls-Position (grep copy x bleibt frei).
function Test-ShellWrite([string]$Command) {
  return ($Command -match '(?i)(\bsed\b[^|;&\n]*\s-[a-z]*i|\bperl\b[^|;&\n]*\s-[a-z0-9]*i|\btee\b|\bcp\b|\bmv\b|\brm\b|\bln\b|\bpatch\b|\bgit\s+(apply|checkout|restore|am|cherry-pick)\b|Set-Content|Add-Content|Out-File|OutFile|Copy-Item|Move-Item|Remove-Item|New-Item|Rename-Item|Clear-Content|WriteAll(Text|Lines|Bytes))') -or
         ($Command -match '(?im)(?:^|[;&|(]|\s/c\s+|\s-c\s+|\s-Command\s+)\s*["'']?\s*(copy|xcopy|robocopy|move|ren|rename|del|erase|ni|sc|ac|cpi|mi|ri|rni|clc)\b')
}

# Schreibt der Shell-Befehl in die genannte Grant-Datei (Schreib-Operator oder Umleitung)? Blosses Lesen ist frei.
function Test-ShellGrantWrite([string]$Command, [string]$FileName) {
  $name = [regex]::Escape($FileName)
  if ($Command -notmatch $name) { return $false }
  return (Test-ShellWrite $Command) -or ($Command -match ">>?\s*(?:`"[^`"]*|'[^']*|[^\s`"']*)$name")
}

# Ist das Fenster offen? Es zaehlt nur die Datei im .claude/ des Haupt-Checkouts, dorthin schreiben die Grant-Skripte: ein
# Fenster gilt fuer alle Sessions und Worktrees zugleich. Eine Datei im Worktree zaehlt nicht (die App kopiert gitignorte
# Dateien beim Anlegen mit, das waeren Alt-Staende). git-Fehler oder kein Repo -> zu. Keine Angabe aus dem Tool-Aufruf (cwd,
# Befehl) fliesst in die Suche. Abgelaufene oder unlesbare Grants loescht die Suche selbst.
function Test-GrantWindow([string]$FileName) {
  try {
    $common = [string](& git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $common) { return $false }
    $f = Join-Path (Join-Path (Split-Path $common -Parent) '.claude') $FileName
    if (-not (Test-Path $f)) { return $false }
    $until = [datetime]::MinValue
    try {
      $until = [datetime]::Parse((Get-Content $f -TotalCount 1), [Globalization.CultureInfo]::InvariantCulture,
                                 [Globalization.DateTimeStyles]::RoundtripKind)
    } catch { }
    if ([datetime]::UtcNow -lt $until.ToUniversalTime()) { return $true }
    Remove-Item $f -Force -ErrorAction SilentlyContinue
  } catch { }
  return $false
}
