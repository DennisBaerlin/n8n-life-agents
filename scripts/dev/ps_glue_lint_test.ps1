#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/ps_glue_lint.ps1 in einem Wegwerf-Baum (-Root): ein Befehl, der hinter dem Kommentar der vorigen
# Zeile klebt, muss rot werden (eingebauter und im Baum definierter Befehl); ein zusammengesetztes Wort, ein `#` im String, ein
# getrennter Befehl und die Ausnahme gruen. Kein Docker, kein git.
# Usage: .\scripts\dev\ps_glue_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\ps_glue_lint.ps1'
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0

function Test-Case([string]$Name, [string]$Code, [bool]$ExpectRed) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pgl_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        [System.IO.File]::WriteAllText((Join-Path $root 'x.ps1'), $Code, $u8)
        $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint -Root $root) -join "`n"
        $red = $LASTEXITCODE -ne 0
        if ($red -eq $ExpectRed) { Write-Host "  PASS $Name" -ForegroundColor Green }
        else { Write-Host "  FAIL $Name (Exit $LASTEXITCODE): $out" -ForegroundColor Red; $script:fails++ }
    } finally { Remove-Item -Recurse -Force $root }
}

Test-Case 'eingebauter Befehl klebt im Kommentar' "`$a = 1   # nur so freiWrite-Host `"x`"`n" $true
Test-Case 'Befehl des Baums klebt im Kommentar' "function Invoke-Eigen { }`n`$a = 1   # nur so freiInvoke-Eigen 3`n" $true
Test-Case 'getrennter Befehl ist gruen' "`$a = 1   # nur so frei`nWrite-Host `"x`"`n" $false
Test-Case 'Befehl mit Leerzeichen im Kommentar ist gruen' "`$a = 1   # danach Write-Host nicht vergessen`n" $false
Test-Case 'zusammengesetztes Wort ist kein Befehl' "# SessionStart-Hook und Wait-Dialog`n`$a = 1   # der Wait-Gate`n" $false
Test-Case 'Raute im String ist kein Kommentar' "`$a = 'frei#freiWrite-Host x'`n" $false
Test-Case 'Ausnahme mit Grund ist gruen' "`$a = 1   # ps-glue-lint: ok Beispieltext freiWrite-Host`n" $false
Test-Case 'Ausnahme ohne Grund ist rot' "`$a = 1   # freiWrite-Host ps-glue-lint: ok`n" $true

# Aufruf wie pre-commit: mehrere Dateien als Argumente, die verklebte zuletzt. Jede Datei zaehlt, keine wird als -Root gelesen.
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pgl_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    [System.IO.File]::WriteAllText((Join-Path $dir 'a.ps1'), "`$a = 1`n", $u8)
    [System.IO.File]::WriteAllText((Join-Path $dir 'b.ps1'), "`$a = 1   # nur so freiWrite-Host `"x`"`n", $u8)
    $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint (Join-Path $dir 'a.ps1') (Join-Path $dir 'b.ps1')) -join "`n"
    if ($LASTEXITCODE -ne 0 -and $out -match 'b\.ps1') { Write-Host '  PASS zweite Datei der Argumente wird geprueft' -ForegroundColor Green }
    else { Write-Host "  FAIL zweite Datei der Argumente wird geprueft (Exit $LASTEXITCODE): $out" -ForegroundColor Red; $fails++ }
} finally { Remove-Item -Recurse -Force $dir }
if ($fails -eq 0) { Write-Host 'PASS ps_glue_lint_test' -ForegroundColor Green } else { Write-Host "FAIL ps_glue_lint_test ($fails)" -ForegroundColor Red }
exit $fails
