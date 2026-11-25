#Requires -Version 5.1
# ps_glue_lint.ps1 -- zusammengeklebte Zeilen in PowerShell-Dateien (hartes Gate). Ging beim Merge ein Zeilenumbruch verloren,
# steckt der Befehl der naechsten Zeile hinter dem Kommentar der vorigen: er laeuft nie, und weder der Parser noch PSScriptAnalyzer
# merken es. Erkennung: ein Kommentar-Token, in dem ein Befehl der Form Verb-Substantiv (Write-Host, Invoke-Native ...) ohne
# Leerzeichen an ein Wort anschliesst ("freiWrite-Host"). Die Token kommen vom PowerShell-Parser, ein `#` in einem String zaehlt nicht.
# Aufruf: .\scripts\ps_glue_lint.ps1 [Datei ...]          ohne Dateien alle getrackten *.ps1 (git ls-files)
#         .\scripts\ps_glue_lint.ps1 -Root <Baum>         alle *.ps1 unter dem Baum (nur fuer scripts/dev/ps_glue_lint_test.ps1)
# Ausnahme einer Zeile: 'ps-glue-lint: ok <Grund>' im selben Kommentar.
# Exit-Code = Anzahl Fehler. Kein LLM, kein Netz, kein Docker.
param([string]$Root, [Parameter(ValueFromRemainingArguments)][string[]]$Files)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

$verbs = 'Write|Invoke|Get|Set|New|Remove|Start|Stop|Add|Test|Out|Copy|Move|Select|Where|ForEach|Import|Export|Read|Clear|Join|Split|Resolve|Wait|Sort|Format|ConvertTo|ConvertFrom|Install|Enable|Disable|Restart|Update'
$glue = [regex]"[a-zäöüß0-9](?:$verbs)-[A-Z][A-Za-z]+"

if ($Root) {
    $Root = (Resolve-Path $Root).Path
    $paths = @(Get-ChildItem $Root -Recurse -File -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' } | ForEach-Object { $_.FullName })
} elseif ($Files) {
    $paths = @($Files | Where-Object { $_ -like '*.ps1' } | ForEach-Object { (Resolve-Path $_).Path })
} else {
    $top = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
    $paths = @(git -C $top ls-files '*.ps1' | ForEach-Object { Join-Path $top $_ })
}

# Zwei Durchgaenge: erst die Funktionsnamen des Repos sammeln, dann die Kommentare lesen. Als Fund zaehlt nur ein Befehl, den es
# gibt (eingebaut oder im Repo definiert): "SessionStart-Hook" ist ein zusammengesetztes Wort, kein Befehl.
$parsed = @()
$known = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $paths) {
    if (-not (Test-Path $p)) { continue }
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errs)
    $parsed += [pscustomobject]@{ Path = $p; Tokens = $tokens }
    foreach ($f in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { [void]$known.Add($f.Name) }
}
function Test-Command([string]$Name) { return $known.Contains($Name) -or [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

foreach ($f in $parsed) {
    foreach ($t in $f.Tokens) {
        if ($t.Kind -ne 'Comment' -or $t.Text -match 'ps-glue-lint:\s*ok') { continue }
        foreach ($m in $glue.Matches($t.Text)) {
            $cmd = $m.Value.Substring(1)
            if (-not (Test-Command $cmd)) { continue }
            Fail "$($f.Path):$($t.Extent.StartLineNumber): Befehl klebt im Kommentar ('$cmd'): ein Zeilenumbruch ging verloren, der Befehl laeuft nie."
            break
        }
    }
}
$n = $parsed.Count
if ($fails -eq 0) { Write-Host "ps_glue_lint: OK ($n Datei(en))" -ForegroundColor Green }
else { Write-Host "ps_glue_lint: $fails Fehler" -ForegroundColor Red }
exit $fails
