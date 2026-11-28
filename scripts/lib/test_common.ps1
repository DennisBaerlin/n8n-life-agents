#Requires -Version 5.1
# Gemeinsame Helfer der Test-Skripte und Test-Treiber (Nutzer: per Grep nach test_common.ps1). Dot-sourcen:
#   . "$PSScriptRoot\..\lib\test_common.ps1"     (aus scripts/dev; aus scripts/ ohne "..")
# Nur Helfer, die in mehreren Skripten wortgleich gebraucht wurden; Substrat-Helfer (n8n, Mock-Telegram, Kosten) liegen in
# scripts/dev/test_n8n_state.ps1, Wegwerf-Repos in git_sandbox.ps1.

# Invoke-Native <exe> <args> [-StdIn <text>] -> @{ Code; Output } (stdout+stderr je Zeile als String). Wirft nie wegen stderr:
# PS 5.1 macht aus nativem stderr unter $ErrorActionPreference='Stop' sonst einen Abbruch. Aufrufer pruefen .Code.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Alias('CmdArgs')][string[]]$Arguments = @(),
        [string]$StdIn
    )
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        if ($PSBoundParameters.ContainsKey('StdIn')) { $out = $StdIn | & $Exe @Arguments 2>&1 } else { $out = & $Exe @Arguments 2>&1 }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Code = $code; Output = @($out | ForEach-Object { "$_" }) }
}

# Invoke-SqlViaTempFile -Container <c> -Sql <text> [-AsLines] -> Ausgabe von psql -q -tA gegen die Container-DB. SQL geht ueber eine
# Datei, nicht per -c: PS 5.1 verstuemmelt eingebettete Anfuehrungszeichen (JSON-Literale) beim Uebergeben an docker.
# Ohne -AsLines ein zusammengefuegter, getrimmter String; mit -AsLines die Zeilen (leeres SQL = leeres Array, kein Aufruf).
# Fehler (Exit-Code != 0) werfen mit dem SQL im Text. Braucht Invoke-TestN8nPsqlFile (test_n8n_state.ps1) im Aufrufer.
function Invoke-SqlViaTempFile {
    param([Parameter(Mandatory)][string]$Container, [string]$Sql, [switch]$AsLines)
    if ($AsLines -and [string]::IsNullOrWhiteSpace($Sql)) { return @() }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "testsql_$([guid]::NewGuid().ToString('N')).sql"
    try {
        [System.IO.File]::WriteAllText($tmp, $Sql, (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-TestN8nPsqlFile -Container $Container -HostFile $tmp -PsqlArgs @('-q', '-tA')
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    if ($r.Code -ne 0) { throw "SQL fehlgeschlagen: $Sql`n$($r.Output -join "`n")" }
    $lines = @($r.Output | ForEach-Object { "$_" })
    if ($AsLines) { return $lines }
    return ($lines -join "`n").Trim()
}

# New-TestTree <Dateien> [<Praefix>] -> Wurzel eines Wegwerf-Baums im Temp-Ordner: Schluessel = Pfad ab Wurzel, Wert = Inhalt
# (UTF-8 ohne BOM). Den Baum loescht der Aufrufer.
function New-TestTree([hashtable]$Files, [string]$Prefix = 'tt') {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + '_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($rel in $Files.Keys) {
        $p = Join-Path $root $rel
        New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null
        [System.IO.File]::WriteAllText($p, $Files[$rel], (New-Object System.Text.UTF8Encoding($false)))
    }
    return $root
}

# Test-LintCase -Lint <skript> -Name <fall> -Files <baum> -ExpectRed <bool> [-ExpectText <teil der meldung>] [-LintArgs <weitere>]
# Ein Fall eines Lint-Selbsttests: der Lint laeuft mit -Root auf einem Wegwerf-Baum (New-TestTree) in einem eigenen Prozess (er endet
# mit exit); verglichen wird rot/gruen und, falls genannt, ein Teil der Ausgabe. Schreibt PASS/FAIL und zaehlt bei FAIL $fails des
# aufrufenden Skripts hoch. Der Prozess ist die PowerShell des Aufrufers (5.1 im Commit-Hook, pwsh auf dem Linux-Runner), per .NET
# ermittelt: Get-Process kaeme aus einem Modul, das unter einem fremden PSModulePath fehlt (scripts/hook_autoload_lint.ps1).
function Test-LintCase {
    param([Parameter(Mandatory)][string]$Lint, [Parameter(Mandatory)][string]$Name, [hashtable]$Files = @{}, [bool]$ExpectRed,
        [string]$ExpectText = '', [string[]]$LintArgs = @())
    $root = New-TestTree $Files 'lt'
    try {
        $shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $out = (& $shell -NoProfile -ExecutionPolicy Bypass -File $Lint -Root $root @LintArgs) -join "`n"
        $red = $LASTEXITCODE -ne 0
        $ok = ($red -eq $ExpectRed) -and (-not $ExpectText -or $out -match [regex]::Escape($ExpectText))
        if ($ok) { Write-Host "  PASS $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL $Name (Exit $LASTEXITCODE): $out" -ForegroundColor Red; $script:fails++ }
    } finally { Remove-Item -Recurse -Force $root }
}
