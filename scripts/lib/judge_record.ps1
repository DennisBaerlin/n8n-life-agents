#Requires -Version 5.1
# Dauerhafte Ablage der Bewerter-Urteile (judge_eval): eine JSONL-Datei je Lauf unter .local/judge_runs/<yyyyMMdd-HHmmss>-<suite>.jsonl.
# Dot-sourcen:  . "$PSScriptRoot\lib\judge_record.ps1"
# Anlass: tests/agent/judge_bundle.json ist nach dem Lauf leer (der naechste Lauf ueberschreibt es), Urteil und Begruendung waren danach nur
# noch in alten Session-Verlaeufen zu finden. Eine Zeile je bewertetem Fall: ts, mode (bundle|calibrate), suite, case_id, verdict, reason,
# det_pass, overall, model, commit (kurz), dirty; bei -Calibrate zusaetzlich human_verdict. Ein Fall ohne Urteil (Kostengrenze, Abbruch vor
# dem Aufruf) bekommt keine Zeile; ein Judge-ERROR schon.
# Ort: .local des Haupt-Checkouts (gitignored, ueberlebt das Aufraeumen eines Worktrees); Schreibfehler stoeren den Lauf nie.

# Haupt-Checkout aus dem git-common-dir: <haupt>/.git bei Worktrees, sonst der Repo-Root selbst.
function Resolve-MainCheckoutRoot {
    param([Parameter(Mandatory)][string]$RepoRoot, [AllowEmptyString()][string]$CommonDir)
    if ([string]::IsNullOrWhiteSpace($CommonDir)) { return $RepoRoot }
    $common = if ([System.IO.Path]::IsPathRooted($CommonDir)) { $CommonDir } else { Join-Path $RepoRoot $CommonDir }
    $common = [System.IO.Path]::GetFullPath($common).TrimEnd('\', '/')
    if ((Split-Path $common -Leaf) -ne '.git') { return $RepoRoot }
    return (Split-Path $common -Parent)
}

function Get-JudgeRunFile {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Suite, [datetime]$Now = (Get-Date), [string]$LocalRoot)
    if (-not $LocalRoot) {
        $cd = git -C $RepoRoot rev-parse --git-common-dir 2>$null
        $LocalRoot = Resolve-MainCheckoutRoot -RepoRoot $RepoRoot -CommonDir ($cd | Select-Object -First 1)
    }
    $safe = ($Suite -replace '[^A-Za-z0-9._-]', '-')
    return (Join-Path (Join-Path $LocalRoot '.local\judge_runs') ($Now.ToString('yyyyMMdd-HHmmss') + "-$safe.jsonl"))
}

# Add-JudgeRunRecord: haengt eine Zeile an. Wirft nie (Warnung genuegt: das Urteil steht dann noch in der Konsole).
function Add-JudgeRunRecord {
    param(
        [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Entry, [Parameter(Mandatory)][string]$Verdict,
        [AllowEmptyString()][string]$Reason, [Parameter(Mandatory)][string]$Model, [string]$Mode = 'bundle',
        [string]$Overall, [string]$Commit, [bool]$Dirty = $false
    )
    try {
        $rec = [ordered]@{
            ts = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); mode = $Mode
            suite = $(if ($Entry.PSObject.Properties['suite']) { "$($Entry.suite)" } else { '' })
            case_id = "$($Entry.id)"; verdict = $Verdict; reason = $Reason
        }
        if ($Mode -eq 'calibrate') { $rec['human_verdict'] = "$($Entry.human_verdict)" }
        else { $rec['det_pass'] = $(if ($Entry.PSObject.Properties['det_pass']) { [bool]$Entry.det_pass } else { $null }); $rec['overall'] = $Overall }
        $rec['model'] = $Model; $rec['commit'] = $Commit; $rec['dirty'] = $Dirty
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::AppendAllText($Path, ((ConvertTo-Json -InputObject $rec -Compress) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Warning "Urteil von '$($Entry.id)' nicht gespeichert ($Path): $($_.Exception.Message)" }
}

# Get-JudgeRunStamp: kurzer Commit-Hash und ob der Arbeitsbaum unbestaetigte Aenderungen hat (das Urteil gilt dann fuer mehr als den Commit).
function Get-JudgeRunStamp {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $h = git -C $RepoRoot rev-parse --short HEAD 2>$null
    $s = git -C $RepoRoot status --porcelain 2>$null
    return [pscustomobject]@{ commit = "$($h | Select-Object -First 1)"; dirty = -not [string]::IsNullOrWhiteSpace((@($s) -join '')) }
}

# Get-JudgeRunSuite: Suite des Laufs fuer den Dateinamen (eine gemeinsame, sonst 'gemischt', ohne Angabe 'unbekannt').
function Get-JudgeRunSuite {
    param([AllowNull()][object[]]$Entries)
    $names = @($Entries | ForEach-Object { if ($_.PSObject.Properties['suite'] -and $_.suite) { "$($_.suite)" } } | Select-Object -Unique)
    if ($names.Count -eq 0) { return 'unbekannt' }
    if ($names.Count -eq 1) { return $names[0] }
    return 'gemischt'
}
