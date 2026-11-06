#Requires -Version 5.1
# =====================================================================================================
# builder_discovery.ps1 — findet die Workflow-Builder aller Pakete (Phase D: keine zentrale Registry)
#
# Konvention: jede Def-Datei unter packages/<pkg>/build/workflows/{,tools/}*.ps1 definiert ihre Builder als
# TOP-LEVEL-Funktion 'Build-<X>' (tools/: genau eine). Die Engine parst jede Datei mit dem PowerShell-Parser
# (keine Ausfuehrung, kein Namens-Raten) und leitet daraus die Builder-Liste ab — ein neues Paket dockt ohne
# Engine-Edit an. Hilfs-Dateien ohne Build-* (harnesses.ps1, cron.advisor_common.ps1, …) liefern 0 Builder.
# Die Reihenfolge ist fuer das Ergebnis wirkungslos (IDs kommen nur aus den gespeicherten <id>-<name>.json,
# ein im selben Lauf neu gebauter Workflow ist ohnehin id-los) — sie bestimmt nur die Report-Zeilen.
# Fail-closed: Parse-Fehler, verschachteltes Build-*, tools/-Datei mit != 1 Builder, Doppel-Name -> throw.
# =====================================================================================================

function Find-WorkflowBuilder {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $root  = $RepoRoot.TrimEnd('\', '/')
    $files = @(Get-ChildItem (Join-Path $root 'packages\*\build\workflows\tools\*.ps1') | Sort-Object FullName) +
             @(Get-ChildItem (Join-Path $root 'packages\*\build\workflows\*.ps1') | Sort-Object FullName)
    $isBuild = { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Build-*' }
    $parsed = @(); $builders = @(); $seen = @{}
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
        $tok = $null; $err = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
        if ($err.Count -gt 0) { throw "builder_discovery: Parse-Fehler in ${rel}:$($err[0].Extent.StartLineNumber): $($err[0].Message)" }
        $pkg    = if ($rel -match '^packages/([^/]+)/build/') { $Matches[1] } else { throw "builder_discovery: '$rel' liegt in keinem Paket." }
        $isTool = $rel -match '/build/workflows/tools/'
        $top = @($ast.EndBlock.Statements | Where-Object { & $isBuild $_ })
        $all = @($ast.FindAll($isBuild, $true))
        if ($all.Count -ne $top.Count) { throw "builder_discovery: $rel definiert ein Build-* verschachtelt (nur Top-Level-Funktionen sind Builder)." }
        if ($isTool -and $top.Count -ne 1) { throw "builder_discovery: Tool-Def $rel definiert $($top.Count) Build-*-Funktionen (erwartet genau 1)." }
        foreach ($fn in $top) {
            if ($seen.ContainsKey($fn.Name)) { throw "builder_discovery: '$($fn.Name)' doppelt definiert ($($seen[$fn.Name]) und $rel)." }
            $seen[$fn.Name] = $rel
            $builders += [pscustomobject]@{ Function = $fn.Name; File = $rel; Package = $pkg; IsTool = $isTool }
        }
        $parsed += [pscustomobject]@{ Path = $f.FullName; Rel = $rel; Ast = $ast }
    }
    if ($builders.Count -eq 0) { throw 'builder_discovery: keine Build-*-Funktion gefunden (Glob/Layout kaputt?).' }
    return [pscustomobject]@{ Files = $parsed; Builders = $builders }
}

# Netz gegen still leere Credentials: jede in einer Datei gelesene $CRED_*-Variable muss ein bekannter
# Deskriptor (Host + Manifest-erzeugt) sein oder IRGENDWO in derselben Datei zugewiesen werden (lokaler
# Alias, z. B. $CRED_POSTGRES = $CRED_<PKG>_RW). Ein Tippfehler ergaebe sonst in PowerShell still $null.
# Umgekehrt: eine zugewiesene UNBEKANNTE $CRED_*-Variable, die in der Datei nie gelesen wird, ist ein Tippfehler auf
# der linken Seite ($CRED_POSTGRSE = $CRED_<PKG>_RW -> der Build-Pg liefe still unter der breiten Owner-Cred).
# $Files = Liste {Path, Rel, Ast} (Find-WorkflowBuilder.Files bzw. geparste lib-Dateien).
function Assert-CredentialReference {
    param([Parameter(Mandatory)][object[]]$Files, [Parameter(Mandatory)][string[]]$Known)
    $knownSet = @{}; foreach ($k in $Known) { $knownSet[$k.ToUpperInvariant()] = $true }
    $bad = @()
    foreach ($f in $Files) {
        $assigned = @{}; $lhsAt = @{}
        foreach ($a in $f.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            $lhs = $a.Left
            if ($lhs -is [System.Management.Automation.Language.ConvertExpressionAst]) { $lhs = $lhs.Child }
            if ($lhs -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $assigned[(($lhs.VariablePath.UserPath -replace '^\w+:', '').ToUpperInvariant())] = $true
                $lhsAt[$lhs.Extent.StartOffset] = $true
            }
        }
        $read = @{}
        foreach ($v in $f.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            $name = ($v.VariablePath.UserPath -replace '^\w+:', '').ToUpperInvariant()
            if ($name -notlike 'CRED_*') { continue }
            if (-not $lhsAt.ContainsKey($v.Extent.StartOffset)) { $read[$name] = $true }
            if ($knownSet.ContainsKey($name) -or $assigned.ContainsKey($name)) { continue }
            $bad += "$($f.Rel):$($v.Extent.StartLineNumber) `$$($v.VariablePath.UserPath)"
        }
        foreach ($an in $assigned.Keys) {
            if ($an -like 'CRED_*' -and -not $knownSet.ContainsKey($an) -and -not $read.ContainsKey($an)) {
                $bad += "$($f.Rel): `$$an zugewiesen, aber nie gelesen (unbekannter Name)"
            }
        }
    }
    if ($bad.Count -gt 0) {
        throw ("Unbekannte Credential-Variable(n) (weder Host-/Manifest-Deskriptor noch in der Datei zugewiesen — Tippfehler?):`n  " + (($bad | Select-Object -Unique) -join "`n  "))
    }
}
