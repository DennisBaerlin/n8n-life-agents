# PreToolUse-Hook (Bash|PowerShell), Ausgangs-Waechter fuer das oeffentliche Repo:
# (1) schreibende 'gh'-Befehle (pr/issue/release/gist/repo/label/discussion, gh api mit Feldern): der veroeffentlichte
#     Text = Befehlstext (inkl. Heredoc/Inline-Body) + per --body-file/--notes-file/--input/-F bzw. api '=@datei'
#     referenzierte Dateien laeuft durch scripts/privacy_lint.ps1 -TextFile. Treffer -> 'deny' (hart, auch in VS Code).
#     Nicht pruefbar (Datei per $(cat ..)/Get-Content eingelesen, Pfad aus unbekannter Variable, Datei unlesbar,
#     interner Fehler) -> ebenfalls 'deny' (fail-closed) mit Hinweis "Text in Datei, per --body-file uebergeben".
#     Lokale Pfade (Body-Datei, Variablen-Zuweisung mit Pfad) werden vorher aus dem Befehlstext genommen: sie werden
#     nicht veroeffentlicht und traefen sonst die Benutzerpfad-Regel.
# (2) echter 'git push'-Aufruf -> zuerst privacy_lint -Outgoing je Refspec gegen das genannte Remote (ausgehende Commits
#     + neue annotierte Tags; deckt den reinen Tag-Push ab, den prek auslaesst) -> Treffer = 'deny'. Sonst Erinnerung an Schritt 8 (/code-review): 'ask' mit Hinweis-
#     Charakter - die VS-Code-Erweiterung winkt ein Hook-'ask' unter bypassPermissions still durch (GH #77212); "Review
#     gelaufen" ist kein deterministisch pruefbarer Zustand, die harten Gates sind die von prek.
# Kein jq -> native ConvertFrom-Json. ASCII-only + Compact-JSON (kein BOM in stdout-JSON).
$ErrorActionPreference = 'Stop'
$raw = [Console]::In.ReadToEnd()
try { $j = $raw | ConvertFrom-Json } catch { exit 0 }
$cmd = ''
if ($j.tool_input -and $j.tool_input.command) { $cmd = [string]$j.tool_input.command }
function Out-Decision($decision, $reason) {
  $out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = $decision; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 5
  Write-Output $out
  exit 0
}
$lint = Join-Path $PSScriptRoot '..\..\scripts\privacy_lint.ps1'
function Get-FailLines($res) { (@($res | Where-Object { $_ -match '\[FAIL\]' } | ForEach-Object { $_.Trim() }) -join '; ') }
$unverifiable = 'OEFFENTLICHER TEXT NICHT PRUEFBAR ({0}). Den Text in eine Datei schreiben und per --body-file/--notes-file mit literalem Pfad uebergeben (bzw. gh api -F feld=@datei).'

$isGh = $cmd -match '\bgh\s+(pr|issue|release|gist|repo|label|discussion|api)\b'
$ghRead = ($cmd -match '\bgh\s+(pr|issue|release|gist|repo|label)\s+(view|list|diff|status|checks|download|checkout|clone|watch)\b') -or
          ($cmd -match '\bgh\s+api\b' -and $cmd -notmatch '\s(-f|-F|--field|--raw-field|--input)[\s=]')
if ($isGh -and -not $ghRead) {
  try {
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $base = if ($j.cwd) { [string]$j.cwd } else { (Get-Location).Path }
    $isApi = $cmd -match '\bgh\s+api\b'
    $tok = '("[^"]*"|''[^'']*''|[^\s;&|]+)'
    # Datei in eine Kommando-Substitution eingelesen (Heredoc '$(cat <<' ist inline und damit pruefbar).
    if ($cmd -match '\$\(\s*(cat\s+(?!<<)|<|Get-Content\b|gc\s|type\s)') { Out-Decision 'deny' ($unverifiable -f 'Datei per Kommando-Substitution eingelesen') }
    # Variablen-Zuweisungen (PowerShell $p = '..', Bash p=..) fuer Pfad-Argumente aufloesen.
    $vars = @{}
    # Regexe nur aus '..'-Strings: in "..." wuerde PowerShell '$?' als Variable einsetzen.
    $assign = '(?:^|[;&|\s])\$?([A-Za-z_]\w*)\s*=\s*'
    foreach ($m in [regex]::Matches($cmd, $assign + $tok)) { $vars[$m.Groups[1].Value] = $m.Groups[2].Value.Trim('"', "'") }
    $fileArg = if ($isApi) { '(?:--input(?:\s+|=)|=@)' + $tok } else { '(?:--body-file|--notes-file|--input|(?<=\s)-F)(?:\s+|=)' + $tok }
    $files = @()
    foreach ($m in [regex]::Matches($cmd, $fileArg)) {
      $f = $m.Groups[1].Value.Trim('"', "'")
      if ($f -match '^\$\{?(\w+)\}?$' -and $vars.ContainsKey($Matches[1])) { $f = $vars[$Matches[1]] }
      if ($f -eq '-' -or $f -match '\$') { Out-Decision 'deny' ($unverifiable -f "Pfad '$f' nicht aufloesbar") }
      if ($f -match '^~[\\/]') { $f = Join-Path $HOME $f.Substring(2) }
      elseif ($f -match '^/([A-Za-z])/(.*)$') { $f = $Matches[1] + ':\' + $Matches[2] }   # Bash-Pfad /c/Users/.. -> C:\Users\..
      $path = if ([System.IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $base $f }
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Out-Decision 'deny' ($unverifiable -f "Datei '$f' nicht lesbar") }
      $files += $path
    }
    # Veroeffentlicht wird der Befehlstext ohne lokale Pfade: Datei-Argumente und Pfad-Zuweisungen entfernen.
    $text = [regex]::Replace($cmd, $fileArg, ' ')
    $text = [regex]::Replace($text, $assign + '("[^"]*[\\/][^"]*"|''[^'']*[\\/][^'']*''|[^\s;&|]*[\\/][^\s;&|]*)', ' ')
    foreach ($p in $files) { $text += "`n" + [System.IO.File]::ReadAllText($p, $u8) }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
      [System.IO.File]::WriteAllText($tmp, $text, $u8)
      $res = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $lint -TextFile $tmp)
      $code = $LASTEXITCODE
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
  } catch {
    Out-Decision 'deny' ($unverifiable -f "Hook-Fehler: $($_.Exception.Message)")
  }
  if ($code -ne 0) {
    Out-Decision 'deny' "PERSOENLICHE DATEN IM OEFFENTLICHEN TEXT (Repo ist public, privacy_lint): $(Get-FailLines $res). Echte Werte entfernen bzw. durch erfundene ersetzen (Zeilen zaehlen ueber Befehlstext + angehaengte Dateien), dann erneut senden."
  }
}
# Nur ein echter Aufruf zaehlt: 'git [-C dir] push' am Anfang eines Befehls-Segments (nicht der Text in einem
# Argument, z. B. einer sed-Ersetzung oder Commit-Message). Geprueft wird das tatsaechliche Ziel: Remote + Refspecs
# aus dem Befehl (ohne Refspec: HEAD), mit --tags/--follow-tags/--all/--mirror zusaetzlich jeder lokale Tag, der dem
# Remote fehlt.
# Vor 'push' beliebig viele globale Optionen (-C/-c <arg>, --opt[=wert]) und Bash-Env-Praefixe (X=1 git ...): sonst
# liefe ein `git -c credential.helper= push` ungeprueft durch (fail-open).
$push = [regex]::Match($cmd, '(?:^|[;&|(]|\r?\n)\s*(?:[A-Za-z_]\w*=\S*\s+)*git(?:\.exe)?((?:\s+(?:-[Cc]\s+(?:"[^"]+"|''[^'']+''|\S+)|--[\w-]+(?:=\S*)?))*)\s+push\b([^;&|\r\n]*)')
if ($push.Success) {
  $gitDir = [regex]::Match($push.Groups[1].Value, '-C\s+("[^"]+"|''[^'']+''|\S+)')
  $gitC = if ($gitDir.Success) { @('-C', $gitDir.Groups[1].Value.Trim('"', "'")) } else { @() }
  # Ausgabe-Umleitungen (2>$null, *>&1, > log.txt, 2>> x) gehoeren zur Shell, nicht zu git: vorher entfernen, sonst
  # galten sie als Refspec ("nicht aufloesbar" -> deny; zweimal gestolpert 2026-10-24).
  $pRest = [regex]::Replace($push.Groups[2].Value, '(?:\d|\*)?>>?(?:&\d|\s*(?:"[^"]*"|''[^'']*''|[^\s;&|]+))?', ' ')
  $pArgs = @($pRest.Trim() -split '\s+' | Where-Object { $_ })
  $pos = @($pArgs | Where-Object { $_ -notmatch '^-' } | ForEach-Object { $_.Trim('"', "'") })
  $allTags = [bool]($pArgs | Where-Object { $_ -match '^--(tags|follow-tags|all|mirror)$' })
  $remote = if ($pos.Count -ge 1) { $pos[0] } else { 'origin' }
  $specs = if ($pos.Count -ge 2) { @($pos[1..($pos.Count - 1)]) } else { @('HEAD') }
  $fails = @()
  try {
    foreach ($spec in $specs) {
      $src = ($spec -split ':')[0].TrimStart('+')
      if (-not $src) { continue }   # ':ziel' loescht nur, veroeffentlicht nichts
      $env:PRE_COMMIT_REMOTE_NAME = $remote
      $env:PRE_COMMIT_TO_REF = (& git ($gitC + @('rev-parse', '--verify', '-q', "$src^{commit}")))
      Remove-Item Env:PRE_COMMIT_FROM_REF -ErrorAction SilentlyContinue
      if (-not $env:PRE_COMMIT_TO_REF) { $fails += "[FAIL] Refspec '$spec' nicht aufloesbar"; continue }
      $lintArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $lint, '-Outgoing') + $(if ($allTags) { @('-AllTags') } else { @() })
      $res = @(& powershell $lintArgs)
      if ($LASTEXITCODE -ne 0) { $fails += @($res | Where-Object { $_ -match '\[FAIL\]' } | ForEach-Object { $_.Trim() }) }
    }
  } catch { $fails += "[FAIL] Hook-Fehler: $($_.Exception.Message)" }
  if ($fails.Count -gt 0) {
    $shown = (@($fails | Select-Object -First 5) -join '; ') + $(if ($fails.Count -gt 5) { " (+$($fails.Count - 5) weitere)" } else { '' })
    Out-Decision 'deny' "PUSH GESPERRT (Repo ist public, privacy_lint -Outgoing, Ziel '$remote'): $shown. Commit-Message/Tag-Message korrigieren (Commit: amend/rebase; Tag: neu anlegen), nie --no-verify."
  }
  Out-Decision 'ask' 'Schritt 8 offen? Vor dem Push: /code-review (high) auf DIESEN Diff gelaufen und die Findings eingearbeitet? Die Gates (Lints beim Commit, db_test + privacy-outgoing beim Push) ersetzen den Review nicht.'
}
exit 0
