#Requires -Version 5.1
# Test von build.ps1 -VerifyWorkflows: in einem Wegwerf-Repo (Kopie der Bau-Eingaben) laeuft der Vergleich erst auf dem unveraenderten
# Stand (gruen), dann nach vier Eingriffen (rot, jeder mit Dateiname): Hand-Aenderung, unsichtbares Null-Breite-Zeichen, geloeschtes
# JSON, JSON ohne Bau-Quelle. Der Vergleich darf nichts schreiben.
# Aufruf: .\scripts\dev\workflow_drift_test.ps1     Exit-Code = Anzahl roter Faelle. Kein Docker, kein Netz, keine .env.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
Clear-GitEnvironment
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Assert-Case([bool]$Ok, [string]$Name, [string]$Detail = '') {
    if ($Ok) { Write-Host "  [PASS] $Name" } else { Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red; $script:fails++ }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('wfd_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox | Out-Null
try {
    Initialize-GitSandbox $sandbox
    foreach ($rel in @('packages', 'scripts\build', 'scripts\lib')) {
        $to = Join-Path $sandbox $rel
        New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo $rel) -Destination $to -Recurse
    }
    $build = Join-Path $sandbox 'scripts\build\build.ps1'
    function Invoke-Verify {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $build -VerifyWorkflows 2>&1 | Out-String) }
        finally { $ErrorActionPreference = $prev }
        return @{ code = $LASTEXITCODE; out = $out }
    }

    $r = Invoke-Verify
    Assert-Case ($r.code -eq 0 -and $r.out -match 'Workflow-Verify OK') 'unveraenderter Stand ist gruen' "(Exit $($r.code)): $($r.out)"

    # Crons ruft kein anderer Workflow per ID auf: ihr Fehlen bricht den Bau nicht ab, sondern muss als Drift erscheinen.
    $crons = @(Get-ChildItem (Join-Path $sandbox 'packages\finance\workflows') -Filter '*.cron_*.json' | Sort-Object Name)
    Assert-Case ($crons.Count -ge 3) 'drei Cron-Workflows als Versuchsobjekte da' "($($crons.Count))"
    $edited = $crons[0]; $invisible = $crons[1]; $deleted = $crons[2]
    $text = [System.IO.File]::ReadAllText($edited.FullName, $u8)
    [System.IO.File]::WriteAllText($edited.FullName, ([regex]'"name": +"').Replace($text, '"name":  "von Hand ', 1), $u8)
    $text = [System.IO.File]::ReadAllText($invisible.FullName, $u8)
    $at = $text.IndexOf('"name":', [System.StringComparison]::Ordinal) + 1
    [System.IO.File]::WriteAllText($invisible.FullName, $text.Insert($at, [string][char]0x200B), $u8)
    Remove-Item -LiteralPath $deleted.FullName
    $orphan = Join-Path $sandbox 'packages\finance\workflows\AAAAAAAAAAAAAAAA-agent.finance.cron_gone.json'
    [System.IO.File]::WriteAllText($orphan, '{}', $u8)
    $before = [System.IO.File]::ReadAllText($edited.FullName, $u8)

    $r = Invoke-Verify
    Assert-Case ($r.code -eq 1) 'veraenderter Stand ist rot' "(Exit $($r.code))"
    Assert-Case ($r.out.Contains("Workflow weicht vom Bau ab: packages/finance/workflows/$($edited.Name)")) 'Hand-Aenderung wird genannt' $r.out
    Assert-Case ($r.out.Contains("Workflow weicht vom Bau ab: packages/finance/workflows/$($invisible.Name)")) 'Null-Breite-Zeichen wird genannt' $r.out
    $bare = $deleted.Name.Substring($deleted.Name.IndexOf('-') + 1)
    Assert-Case ($r.out.Contains("Workflow weicht vom Bau ab: packages/finance/workflows/$bare")) 'fehlendes JSON wird genannt' $r.out
    Assert-Case ($r.out.Contains('Workflow ohne Bau-Quelle: packages/finance/workflows/AAAAAAAAAAAAAAAA-agent.finance.cron_gone.json')) 'JSON ohne Bau-Quelle wird genannt' $r.out
    Assert-Case ([string]::Equals([System.IO.File]::ReadAllText($edited.FullName, $u8), $before, [System.StringComparison]::Ordinal) -and
                 -not (Test-Path -LiteralPath $deleted.FullName) -and (Test-Path -LiteralPath $orphan)) 'der Vergleich schreibt und loescht nichts'
} finally {
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}

if ($fails -eq 0) { Write-Host 'PASS workflow_drift_test' -ForegroundColor Green } else { Write-Host "workflow_drift_test: $fails rot" -ForegroundColor Red }
exit $fails
