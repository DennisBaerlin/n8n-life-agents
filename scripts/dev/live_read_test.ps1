#Requires -Version 5.1
# live_read_test.ps1 -- Gratis-Test des gemeinsamen Lese-Zugangs scripts/lib/live_read.ps1: Befehle je Laufzeit, lesende
# SQL-Sitzung, Laufzeit-Erkennung (Verbund/klassisch, ssh-Fehler ist kein Urteil), stdin-Weg. Kein Docker, kein Netz; der
# Lauf gegen einen echten Test-Verbund und ein klassisches Substrat steht in scripts/live_read.ps1 (-Local/-Container).
# Usage:  .\scripts\dev\live_read_test.ps1
# Exit-Code = Anzahl Fehler.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\live_read.ps1')
$failed = 0
function Assert-True([string]$Name, [bool]$Ok, [string]$Got = '') {
    if ($Ok) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name $Got" -ForegroundColor Red; $script:failed++ }
}

Write-Host 'SQL-Befehl je Laufzeit'
$c = Get-LiveSqlCommand 'classic' 'lifeagents'
Assert-True 'klassisch: runuser + psql, SQL von stdin' ($c -match '^runuser -u postgres -- psql ' -and $c -notmatch 'docker')
$v = Get-LiveSqlCommand 'compose' 'lifeagents'
Assert-True 'Verbund: docker exec -i im Postgres-Container, SQL von stdin' ($v -match '^docker exec -i -u postgres lifeagents-postgres psql ' -and $v -notmatch 'runuser')
Assert-True 'Projektname steuert den Container (Test-Verbund)' ((Get-LiveSqlCommand 'compose' 'abc') -match 'abc-postgres')

Write-Host 'Mitschrift-Befehl je Laufzeit'
$u = Get-LiveUsageCommand 'classic' 'lifeagents' '' 100
Assert-True 'klassisch: curl direkt auf 127.0.0.1:8090' ($u -eq "curl -fsS 'http://127.0.0.1:8090/__usage?limit=100'")
$u = Get-LiveUsageCommand 'compose' 'lifeagents' '1700000000000abc' 50
Assert-True 'Verbund: curl im master, after + limit' ($u -eq "docker exec lifeagents-master curl -fsS 'http://127.0.0.1:8090/__usage?after=1700000000000abc&limit=50'")
$threw = $false; try { Get-LiveUsageCommand 'classic' 'lifeagents' "x'; rm -rf /" 10 | Out-Null } catch { $threw = $true }
Assert-True 'after mit Sonderzeichen wird abgelehnt (kein Befehl-Einschleusen)' $threw
$threw = $false; try { New-LiveTarget 'ssh' 'a b' | Out-Null } catch { $threw = $true }
Assert-True 'Projektname mit Leerzeichen wird abgelehnt' $threw

Write-Host 'Lesende Sitzung'
$sql = Get-LiveReadOnlySql "SELECT 1;`r`n"
Assert-True 'SET default_transaction_read_only = on steht vor dem SQL' ($sql.IndexOf('SET default_transaction_read_only = on;') -ge 0 -and $sql.IndexOf('SET default_transaction_read_only') -lt $sql.IndexOf('SELECT 1'))
Assert-True 'CR entfernt' ($sql -notmatch "`r")

Write-Host 'Laufzeit-Erkennung (Aufruf-Attrappe statt ssh/docker)'
function Invoke-LiveRemote($Target, [string]$Command, [string]$Stdin = '') { $script:lastCmd = $Command; $script:fake }
$t = [pscustomobject]@{ Kind = 'ssh'; Project = 'lifeagents'; Access = $null; Container = '' }
$script:fake = [pscustomobject]@{ Lines = @('true'); Rc = 0 }
Assert-True 'master laeuft -> compose' ((Get-LiveRuntime $t) -eq 'compose')
Assert-True 'Frage geht an <projekt>-master' ($script:lastCmd -match 'lifeagents-master')
$script:fake = [pscustomobject]@{ Lines = @('false'); Rc = 0 }
$threw = $false; try { Get-LiveRuntime $t | Out-Null } catch { $threw = $true }
Assert-True 'master vorhanden, aber gestoppt -> Fehler, nie als klassisch lesen' $threw
$script:fake = [pscustomobject]@{ Lines = @(); Rc = 1 }
Assert-True 'kein master-Container -> classic' ((Get-LiveRuntime $t) -eq 'classic')
$script:fake = [pscustomobject]@{ Lines = @(); Rc = 127 }
Assert-True 'kein docker auf dem Ziel -> classic' ((Get-LiveRuntime $t) -eq 'classic')
$script:fake = [pscustomobject]@{ Lines = @(); Rc = 255 }
$threw = $false; try { Get-LiveRuntime $t | Out-Null } catch { $threw = $true }
Assert-True 'ssh nicht erreichbar -> Fehler, nie still "classic"' $threw
$tl = [pscustomobject]@{ Kind = 'local'; Project = 'lifeagents'; Access = $null; Container = '' }
$script:fake = [pscustomobject]@{ Lines = @(); Rc = 255 }
Assert-True 'Rc 255 bei lokalem Ziel ist kein ssh-Fehler' ((Get-LiveRuntime $tl) -eq 'classic')

Write-Host 'Sperrlisten-Skript: das Ziel-Objekt ueberschreibt nicht den Pfad der Ausgabedatei ($target)'
$refresh = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\refresh_privacy_denylist.ps1'))
Assert-True 'Pfad $target nur einmal zugewiesen, Ziel-Objekt heisst $liveTarget' (([regex]::Matches($refresh, '(?m)^\s*(if|elseif)?[^#\r\n]*\$target\s*=')).Count -eq 1 -and $refresh -match '\$liveTarget = New-LiveTarget')

Write-Host 'Zugang aus der .env (nie DEV_INSTANCE_*)'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('lr_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    [System.IO.File]::WriteAllText((Join-Path $tmp '.env'), "DEV_INSTANCE_HOST=dev.example.invalid`nDEV_INSTANCE_SSH_KEY=/k`n", (New-Object System.Text.UTF8Encoding($false)))
    Assert-True 'nur DEV_INSTANCE_* -> kein Zugang' ($null -eq (Get-LiveAccess $tmp))
    [System.IO.File]::WriteAllText((Join-Path $tmp '.env'), "LIVE_INSTANCE_HOST=live.example.invalid`nLIVE_INSTANCE_SSH_KEY=/k`n", (New-Object System.Text.UTF8Encoding($false)))
    $a = Get-LiveAccess $tmp
    Assert-True 'LIVE_INSTANCE_*: Host, Nutzer-Vorgabe root' ($a.Host -eq 'live.example.invalid' -and $a.User -eq 'root')
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

if ($failed -eq 0) { Write-Host 'OK: alle Pruefungen bestanden.' -ForegroundColor Green } else { Write-Host "$failed Pruefung(en) FEHLGESCHLAGEN." -ForegroundColor Red }
exit $failed
