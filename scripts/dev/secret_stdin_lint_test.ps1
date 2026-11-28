#Requires -Version 5.1
# Fehl- und Gutfaelle von scripts/secret_stdin_lint.ps1 in einem Wegwerf-Baum (-Root): jedes Kennzeichen per Pipe oder -StdIn an ein
# Programm ist rot; eine Pipe ohne Kennzeichen, eine Suche nach dem Kennzeichen (PowerShell-Befehl), der Helfer, ein Kennzeichen im
# String und die Ausnahme mit Grund sind gruen (ohne Grund rot); dazu der Aufruf wie pre-commit mit mehreren Dateien. Kein Docker.
# Usage: .\scripts\dev\secret_stdin_lint_test.ps1   Exit-Code = Anzahl fehlgeschlagener Faelle.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = Join-Path $PSScriptRoot '..\secret_stdin_lint.ps1'
$fails = 0
. (Join-Path $PSScriptRoot '..\lib\test_common.ps1')

function Test-Case([string]$Name, [string]$Code, [bool]$ExpectRed) { Test-LintCase -Lint $lint -Name $Name -Files @{ 'x.ps1' = $Code } -ExpectRed $ExpectRed }

Test-Case 'gpg ueber Variable mit --passphrase-fd ist rot' '$pass | & $gpg --batch --passphrase-fd 0 --detach-sign x' $true
Test-Case 'leeres Passwort per Pipe ist rot' "'' | & `$gpg --pinentry-mode loopback --detach-sign x" $true
Test-Case 'docker --password-stdin ist rot' '$token | docker login ghcr.io -u x --password-stdin' $true
Test-Case '/dev/stdin ist rot' '$env:KEY | docker exec -i $c tailscale up --auth-key=file:/dev/stdin *> $null' $true
Test-Case 'read -r im Container-Befehl ist rot' "`$t | docker exec -i c sh -c 'read -r T; export T'" $true
Test-Case 'openssl -passin stdin ist rot' '$p | openssl pkey -in k.pem -passin stdin' $true
Test-Case 'openssl -passout stdin ist rot' '$p | openssl genpkey -algorithm ed25519 -passout stdin' $true
Test-Case 'openssl -pass stdin ist rot' '$p | openssl enc -aes-256-cbc -pass stdin -in a' $true
Test-Case 'gh auth login --with-token ist rot' '$token | gh auth login --with-token' $true
Test-Case 'gh secret set per Pipe ist rot' '$v | gh secret set NAME' $true
Test-Case 'Geheimnis-Befehl mitten in der Pipeline ist rot' '$p | & $gpg --passphrase-fd 0 -s x | Out-Null' $true
Test-Case '-StdIn an Invoke-Native ist rot' "`$r = Invoke-Native docker @('exec', '-i', `$c, 'sh', '-c', 'read -r T; x') -StdIn `$tok" $true
Test-Case 'Helfer ist gruen' "Invoke-NativeStdinBytes -FilePath docker -ArgumentList @('exec', '-i', `$c, 'sh', '-c', 'read -r T') -InputText `$tok" $false
Test-Case 'Pipe ohne Kennzeichen ist gruen' '$sql | docker exec -i c psql -U postgres' $false
Test-Case '-StdIn ohne Kennzeichen ist gruen' "Invoke-Native docker @('exec', '-i', `$c, 'psql') -StdIn `$sql" $false
Test-Case 'Suche nach dem Kennzeichen ist gruen' '$lines | Where-Object { $_ -match ''/dev/stdin'' } | Select-String ''read -r''' $false
Test-Case 'Programm ohne Pipe ist gruen' "docker exec c sh -c 'read -r T < /root/f'" $false
Test-Case 'Kennzeichen nur im String ist gruen' '$muster = ''$p | & $g --passphrase-fd 0''' $false
Test-Case 'Ausnahme mit Grund ist gruen' "`$t | docker exec -i c sh -c 'read -r NAME'   # secret-stdin-lint: ok kein Geheimnis" $false
Test-Case 'Ausnahme ohne Grund ist rot' "`$t | docker exec -i c sh -c 'read -r NAME'   # secret-stdin-lint: ok" $true

# Aufruf wie pre-commit: mehrere Dateien als Argumente, die rote zuletzt.
$root = New-TestTree @{ 'a.ps1' = '$a = 1'; 'b.ps1' = '$p | & $gpg --passphrase-fd 0 -s x' } 'ssl'
try {
    $shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $out = (& $shell -NoProfile -ExecutionPolicy Bypass -File $lint (Join-Path $root 'a.ps1') (Join-Path $root 'b.ps1')) -join "`n"
    if ($LASTEXITCODE -ne 0 -and $out -match 'b\.ps1') { Write-Host '  PASS zweite Datei der Argumente wird geprueft' -ForegroundColor Green }
    else { Write-Host "  FAIL zweite Datei der Argumente wird geprueft (Exit $LASTEXITCODE): $out" -ForegroundColor Red; $fails++ }
} finally { Remove-Item -Recurse -Force $root }
if ($fails -eq 0) { Write-Host 'PASS secret_stdin_lint_test' -ForegroundColor Green } else { Write-Host "FAIL secret_stdin_lint_test ($fails)" -ForegroundColor Red }
exit $fails
