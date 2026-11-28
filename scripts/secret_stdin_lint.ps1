#Requires -Version 5.1
# secret_stdin_lint.ps1 -- kein Geheimnis per Pipe an ein Programm (hartes Gate). Eine PowerShell-Pipe haengt an den String ein
# Zeilenende, und Windows PowerShell 5.1 stellt bei UTF-8-Konsole ein BOM davor: das Programm bekommt ein anderes Passwort oder Token.
# Der Weg ist Invoke-NativeStdinBytes / Invoke-GpgPassphrase (scripts/lib/native_process.ps1).
# Erkennung (PowerShell-Parser): ein Befehl traegt ein stdin-Geheimnis-Kennzeichen ($marker) und bekommt seine Eingabe
#   (a) aus einer Pipe und ist kein PowerShell-Befehl (Verb-Substantiv oder Kurzform), oder
#   (b) ueber den Parameter -StdIn (Invoke-Native reicht ihn per Pipe weiter).
# Grenze: Kennzeichen, die erst in einer Variablen stehen (`$a = @(...); $x | & $exe @a`), und Geheimnisse in einer Konfiguration auf
# stdin (`curl -K -`) sieht die Pruefung nicht.
# Ausnahme: `# secret-stdin-lint: ok <Grund>` in einer Zeile des Befehls.
# Aufruf: .\scripts\secret_stdin_lint.ps1 [Datei ...]          ohne Dateien alle getrackten *.ps1 (git ls-files)
#         .\scripts\secret_stdin_lint.ps1 -Root <Baum>         alle *.ps1 unter dem Baum (nur fuer scripts/dev/secret_stdin_lint_test.ps1)
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
# Keine Positionsbindung: pre-commit haengt die Dateinamen an, der erste duerfte sonst nicht in -Root landen.
[CmdletBinding(PositionalBinding = $false)]
param([string]$Root, [Parameter(ValueFromRemainingArguments)][string[]]$Files)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$fails = 0

$marker = '--passphrase-fd|--password-stdin|--with-token|\bgh\s+secret\s+set\b|/dev/stdin|\bread\s+-[a-z]*r|-pass(in|out)?[\s''",]+stdin|--pinentry-mode[\s''",=]+loopback'
$psAlias = @('?', '%', 'where', 'foreach', 'select', 'sort', 'sls', 'measure', 'group', 'tee', 'ft', 'fl', 'echo', 'write')

if ($Root) {
    $Root = (Resolve-Path $Root).Path
    $paths = @(Get-ChildItem $Root -Recurse -File -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } | ForEach-Object { $_.FullName })
} elseif ($Files) {
    $paths = @($Files | Where-Object { $_ -like '*.ps1' } | ForEach-Object { (Resolve-Path $_).Path })
} else {
    $top = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
    $paths = @(git -C $top ls-files '*.ps1' | ForEach-Object { Join-Path $top $_ })
}

# Ein Programm ist, was nicht wie ein PowerShell-Befehl heisst; ein Aufruf ueber eine Variable (`& $gpg`) hat keinen Namen.
function Test-NativeCommand($Cmd) {
    $name = $Cmd.GetCommandName()
    if (-not $name) { return $true }
    return ($name -cnotmatch '^[A-Z][A-Za-z]*-[A-Z][A-Za-z]*$') -and ($psAlias -notcontains $name)
}

$n = 0
foreach ($p in $paths) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $n++
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errs)
    $allowed = @($tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text -match 'secret-stdin-lint:\s*ok\s+\S' } | ForEach-Object { $_.Extent.StartLineNumber })
    foreach ($cmd in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($cmd.Extent.Text -cnotmatch $marker) { continue }
        $pipe = $cmd.Parent -as [System.Management.Automation.Language.PipelineAst]
        $piped = $pipe -and $pipe.PipelineElements.IndexOf($cmd) -gt 0 -and (Test-NativeCommand $cmd)
        $stdinParam = @($cmd.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'StdIn' }).Count -gt 0
        if (-not ($piped -or $stdinParam)) { continue }
        $first = $cmd.Extent.StartLineNumber; $last = $cmd.Extent.EndLineNumber
        if (@($allowed | Where-Object { $_ -ge $first -and $_ -le $last }).Count) { continue }
        Write-Host "  [FAIL] ${p}:${first}: Geheimnis per Pipe an ein Programm (Zeilenende und BOM landen im Wert) -> Invoke-NativeStdinBytes bzw. Invoke-GpgPassphrase (scripts/lib/native_process.ps1)." -ForegroundColor Red
        $fails++
    }
}
if ($fails -eq 0) { Write-Host "secret_stdin_lint: OK ($n Datei(en))" -ForegroundColor Green }
else { Write-Host "secret_stdin_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
