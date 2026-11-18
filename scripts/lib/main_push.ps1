# main_push.ps1 -- Urteil der main-Push-Sperre (scripts/main_push_guard.ps1), getrennt von git und Netz, damit
# scripts/dev/main_push_guard_test.ps1 es an erfundenen Workflow-Texten und Lauf-Listen pruefen kann. Dot-sourcen;
# braucht Get-CiWaitVerdict aus ci_wait.ps1.

# Pfad-Filter des push-Ausloesers aus dem Text einer Workflow-Datei: @{ Paths; Ignore }. Die Filter stehen nur in der
# Workflow-Datei; hier wird gelesen, nicht gespiegelt. Liest die Block-Form (push: / paths: / - 'muster'), die alle
# Workflows dieses Repos nutzen; eine Inline-Liste (paths: [a, b]) wirft, damit die Sperre nicht still zu wenig verlangt.
function Get-WorkflowPushFilter([string]$YamlText) {
    $filter = @{ Paths = @(); Ignore = @() }
    $inPush = $false; $pushIndent = -1; $key = $null
    foreach ($line in ($YamlText -split "\r?\n")) {
        if ($line -match '^\s*(#.*)?$') { continue }
        $indent = ($line -replace '^(\s*).*$', '$1').Length
        if (-not $inPush) {
            if ($line -match '^\s+push:\s*(#.*)?$') { $inPush = $true; $pushIndent = $indent }
            continue
        }
        if ($indent -le $pushIndent) { break }
        if ($line -match '^\s*(paths|paths-ignore):\s*(.*)$') {
            if ($Matches[2] -and $Matches[2] -notmatch '^#') { throw "Pfad-Filter als Inline-Liste nicht lesbar: $($line.Trim())" }
            $key = if ($Matches[1] -eq 'paths') { 'Paths' } else { 'Ignore' }
            continue
        }
        if ($line -match '^\s*-\s*(.+?)\s*(#.*)?$' -and $key) { $filter[$key] += $Matches[1].Trim('"', "'"); continue }
        $key = $null
    }
    return $filter
}

# GitHub-Glob als Regex: * bleibt innerhalb eines Ordners, ** geht ueber Ordner.
function ConvertTo-PathRegex([string]$Glob) {
    $rx = [regex]::Escape($Glob) -replace '\\\*\\\*/', '(?:.*/)?' -replace '\\\*\\\*', '.*' -replace '\\\*', '[^/]*'
    return "^$rx$"
}

# Wuerde ein Push dieser Dateien den Workflow starten? paths: eine Datei passt; paths-ignore: eine Datei faellt nicht
# unter die Ausnahmen. Ohne Filter immer.
function Test-WorkflowTriggered($Filter, [string[]]$Files) {
    $match = { param($file, $globs) [bool]($globs | Where-Object { $file -match (ConvertTo-PathRegex $_) }) }
    if ($Filter.Paths.Count -gt 0) { return [bool]($Files | Where-Object { & $match $_ $Filter.Paths }) }
    if ($Filter.Ignore.Count -gt 0) { return [bool]($Files | Where-Object { -not (& $match $_ $Filter.Ignore) }) }
    return $true
}

# Je verlangtem Workflow, der auf dem Stand nicht gruen ist, eine Zeile "<workflow>: <urteil>"; leer = frei.
function Get-MainPushProblems([string[]]$Required, [object[]]$Runs, [string]$Sha) {
    $problems = @()
    foreach ($wf in $Required) {
        $v = Get-CiWaitVerdict -Runs $Runs -Workflow $wf -Sha $Sha
        if ($v.verdict -ne 'green') {
            $word = switch ($v.verdict) { 'red' { 'rot' } 'pending' { 'laeuft noch' } default { 'kein Lauf' } }
            $problems += "${wf}: $word"
        }
    }
    return $problems
}
