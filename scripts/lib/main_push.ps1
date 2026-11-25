# main_push.ps1 -- Urteil der main-Push-Sperre (scripts/main_push_guard.ps1), getrennt von git und Netz, damit
# scripts/dev/main_push_guard_test.ps1 es an erfundenen Workflow-Texten und Lauf-Listen pruefen kann. Dot-sourcen;
# braucht Get-CiWaitVerdict aus ci_wait.ps1.

# Pfad-Filter eines Ausloesers (Standard push; auch pull_request) aus dem Text einer Workflow-Datei: @{ Paths; Ignore }. Die Filter stehen nur in der
# Workflow-Datei; hier wird gelesen, nicht gespiegelt. Liest die Block-Form (push: / paths: / - 'muster'), die alle
# Workflows dieses Repos nutzen; eine Inline-Liste (paths: [a, b]) wirft, damit die Sperre nicht still zu wenig verlangt.
function Get-WorkflowPushFilter([string]$YamlText, [string]$Trigger = 'push') {
    $filter = @{ Paths = @(); Ignore = @() }
    $inPush = $false; $pushIndent = -1; $key = $null
    foreach ($line in ($YamlText -split "\r?\n")) {
        if ($line -match '^\s*(#.*)?$') { continue }
        $indent = ($line -replace '^(\s*).*$', '$1').Length
        if (-not $inPush) {
            if ($line -match "^\s+$([regex]::Escape($Trigger)):\s*(#.*)?$") { $inPush = $true; $pushIndent = $indent }
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

# Urteil fuer den Elternstand eines Pin-Commits: je Workflow entscheidet der juengste abgeschlossene Lauf, und gruen ist nur
# conclusion=success (cancelled, skipped, timed_out, failure sperren). Laeufe, die der main-Push des Elternstands gerade
# gestartet hat, uebergeht es: der Elternstand war vor dem Push gruen, sonst haette ihn die Sperre nicht durchgelassen.
# Zeilenform wie Get-MainPushProblems; leer = frei.
function Get-PinParentProblems([string[]]$Required, [object[]]$Runs, [string]$Sha) {
    $problems = @()
    foreach ($wf in $Required) {
        $done = @($Runs | Where-Object {
                $_ -and ("$($_.name)" -eq $wf -or "$($_.path)" -like "*/$wf.yml") -and "$($_.head_sha)".StartsWith($Sha, [StringComparison]::OrdinalIgnoreCase) -and "$($_.status)" -eq 'completed'
            } | Sort-Object { [datetime]$_.created_at } -Descending)
        if ($done.Count -eq 0) { $problems += "${wf}: kein abgeschlossener Lauf" }
        elseif ("$($done[0].conclusion)" -ne 'success') { $problems += "${wf}: rot ($($done[0].conclusion))" }
    }
    return $problems
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
