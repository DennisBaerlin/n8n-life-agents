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
    foreach ($rel in @('packages', 'scripts\build', 'scripts\lib', 'tests\agent', 'scripts\gen_fn_catalog.ps1', 'docs\fn_catalog.md')) {
        $to = Join-Path $sandbox $rel
        New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo $rel) -Destination $to -Recurse
    }
    $build = Join-Path $sandbox 'scripts\build\build.ps1'
    function Invoke-Script([string]$Script, [string[]]$ScriptArgs) {
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @ScriptArgs 2>&1 | Out-String) }
        finally { $ErrorActionPreference = $prev }
        return @{ code = $LASTEXITCODE; out = $out }
    }
    function Invoke-Verify { return (Invoke-Script $build @('-VerifyWorkflows')) }

    $r = Invoke-Verify
    Assert-Case ($r.code -eq 0 -and $r.out -match 'Workflow-Verify OK') 'unveraenderter Stand ist gruen' "(Exit $($r.code)): $($r.out)"

    # Erzeugte Texte (Faehigkeiten-Katalog, fn-Katalog): der Vergleich ist ordinal. -ne/-ceq uebergingen Gross-/Kleinschreibung bzw.
    # Zeichen ohne Gewicht (weicher Trennstrich U+00AD), ein Hand-Eingriff bliebe gruen. -VerifyCatalog allein liest OWNER_CHAT_ID
    # aus der .env: hier ein erfundener Wert im Wegwerf-Repo.
    [System.IO.File]::WriteAllText((Join-Path $sandbox '.env'), "OWNER_CHAT_ID=909000000000001`n", $u8)
    $r = Invoke-Script $build @('-VerifyCatalog')
    Assert-Case ($r.code -eq 0 -and $r.out -match 'Catalog-Verify OK') 'Katalog: unveraenderter Stand ist gruen' "(Exit $($r.code)): $($r.out)"
    $frag = Join-Path $sandbox 'packages\finance\seed\capabilities_catalog\de.fragment.md'
    $fragText = [System.IO.File]::ReadAllText($frag, $u8)
    $heading = [regex]::Match($fragText, '(?m)^## (\p{Lu})(\w{3,})').Value
    foreach ($case in @(@{ n = 'andere Gross-/Kleinschreibung'; t = $heading.ToLowerInvariant() }, @{ n = 'unsichtbares Zeichen'; t = $heading.Insert(5, [string][char]0x00AD) })) {
        [System.IO.File]::WriteAllText($frag, $fragText.Replace($heading, $case.t), $u8)
        $r = Invoke-Script $build @('-VerifyCatalog')
        Assert-Case ($heading -and $r.code -ne 0 -and $r.out -match 'DRIFT: Fragment packages/finance') "Katalog: $($case.n) im Fragment ist Drift" "(Exit $($r.code))"
    }
    [System.IO.File]::WriteAllText($frag, $fragText, $u8)
    $fnGen = Join-Path $sandbox 'scripts\gen_fn_catalog.ps1'; $fnMd = Join-Path $sandbox 'docs\fn_catalog.md'
    $r = Invoke-Script $fnGen @('-Verify')
    Assert-Case ($r.code -eq 0 -and $r.out -match 'fn-Katalog OK') 'fn-Katalog: unveraenderter Stand ist gruen' "(Exit $($r.code)): $($r.out)"
    $fnText = [System.IO.File]::ReadAllText($fnMd, $u8)
    [System.IO.File]::WriteAllText($fnMd, $fnText.Insert($fnText.IndexOf('fn_', [System.StringComparison]::Ordinal) + 1, [string][char]0x00AD), $u8)
    $r = Invoke-Script $fnGen @('-Verify')
    Assert-Case ($r.code -ne 0 -and $r.out -match 'DRIFT') 'fn-Katalog: unsichtbares Zeichen ist Drift' "(Exit $($r.code))"

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
