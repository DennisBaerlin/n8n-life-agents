#Requires -Version 5.1
# scheduled_task_check_test.ps1 -- prueft scripts/dev/scheduled_task_check.ps1 gegen erfundene Wrapper in einem
# Wegwerf-Ordner: einer verweist auf den Schlussschritt (Backslash), einer mit Schraegstrich, einer ohne Verweis,
# einer mit Verweis plus altem Meldeblock, einer erklaert den Verzicht auf Remote Control in Worten (kein Befund),
# einer gehoert zu einem fremden Projekt, einer zu einem Geschwister-Ordner <repo>-alt, einer ist eine
# Einmal-Aufgabe ohne Verweis (faellt nur ohne -TaskId auf). Fehlt _gemeinsam/schlussschritt.md oder der Ordner
# einer taskId, ist das je ein Befund; eine Komma-Liste in einem String (Aufruf per -File) zaehlt wie mehrere IDs.
# Usage: .\scripts\dev\scheduled_task_check_test.ps1   Exit-Code = Anzahl roter Faelle.
$ErrorActionPreference = 'Stop'
$failed = 0
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$root = Join-Path ([IO.Path]::GetTempPath()) ("sched_test_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$repo = 'fake-repo'
function New-Task([string]$name, [string]$text) {
    $d = Join-Path $root $name
    New-Item -ItemType Directory -Force $d | Out-Null
    [IO.File]::WriteAllText((Join-Path $d 'SKILL.md'), $text, $Utf8NoBom)
}
$ref = 'Lies D:\tasks\_gemeinsam\schlussschritt.md und befolge ihn.'
try {
    New-Task 'gut'      "Repo C:\code\$repo. $ref"
    New-Task 'slash'    "Repo ~/code/$repo/. Lies ~/tasks/_gemeinsam/schlussschritt.md."
    New-Task 'ohne'     "Repo C:\code\$repo (Projekt). Melde dich irgendwie."
    New-Task 'alt'      "Repo C:\code\$repo. $ref`n### Meldewege (alle nacheinander)`n3. PushNotification aufrufen."
    New-Task 'worte'    "Repo C:\code\$repo. $ref Remote Control und ungelesen gibt es nicht mehr."
    New-Task 'fremd'    'Anderes Projekt, kein Verweis.'
    New-Task 'geschw'   "Repo C:\code\$repo-alt. Kein Verweis."
    New-Task 'einmalig' "Repo C:\code\$repo. Einmal-Aufgabe ohne Verweis."
    $script = Join-Path $PSScriptRoot 'scheduled_task_check.ps1'

    # Ohne Schlussschritt-Datei: genau dieser Befund, die gute Aufgabe bleibt ok.
    $o0 = & $script -TasksRoot $root -RepoName $repo -TaskId 'gut' 6>&1 | Out-String; $rc0 = $LASTEXITCODE

    New-Item -ItemType Directory -Force (Join-Path $root '_gemeinsam') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '_gemeinsam\schlussschritt.md'), 'Schlussschritt', $Utf8NoBom)

    $o1 = & $script -TasksRoot $root -RepoName $repo 6>&1 | Out-String; $rc1 = $LASTEXITCODE
    $o2 = & $script -TasksRoot $root -RepoName $repo -TaskId 'gut', 'slash', 'ohne', 'alt', 'worte', 'fremd' 6>&1 | Out-String; $rc2 = $LASTEXITCODE
    $o3 = & $script -TasksRoot $root -RepoName $repo -TaskId 'gut,ohne,tippfehler' 6>&1 | Out-String; $rc3 = $LASTEXITCODE
    # Ohne -RepoName: Name aus git; die erfundenen Aufgaben sind dann alle fremd.
    $o4 = & $script -TasksRoot $root 6>&1 | Out-String; $rc4 = $LASTEXITCODE

    $cases = @(
        @{ n = 'ohne_datei_ein_befund';   ok = ($rc0 -eq 1 -and $o0 -match 'FEHLT\s+_gemeinsam' -and $o0 -match 'ok\s+gut') }
        @{ n = 'alle_exit_drei';          ok = ($rc1 -eq 3) }
        @{ n = 'gut_ok';                  ok = ($o1 -match 'ok\s+gut') }
        @{ n = 'schraegstrich_ok';        ok = ($o1 -match 'ok\s+slash') }
        @{ n = 'ohne_verweis_gemeldet';   ok = ($o1 -match 'FEHLT\s+ohne: kein Verweis') }
        @{ n = 'alter_block_gemeldet';    ok = ($o1 -match 'FEHLT\s+alt: alter Meldeweg: Meldewege.*PushNotification') }
        @{ n = 'worte_ok';                ok = ($o1 -match 'ok\s+worte') }
        @{ n = 'fremd_ignoriert';         ok = ($o1 -notmatch 'fremd') }
        @{ n = 'geschwister_ignoriert';   ok = ($o1 -notmatch 'geschw') }
        @{ n = 'einmalig_ohne_ids';       ok = ($o1 -match 'FEHLT\s+einmalig') }
        @{ n = 'ids_exit_zwei';           ok = ($rc2 -eq 2) }
        @{ n = 'einmalig_mit_ids_still';  ok = ($o2 -notmatch 'einmalig') }
        @{ n = 'kommaliste_und_tippfehler'; ok = ($rc3 -eq 2 -and $o3 -match 'FEHLT\s+tippfehler: kein Ordner' -and $o3 -match 'ok\s+gut') }
        @{ n = 'reponame_aus_git';        ok = ($rc4 -eq 0 -and $o4 -match '0 Aufgaben') }
    )
    foreach ($c in $cases) {
        if ($c.ok) { Write-Host "[PASS] $($c.n)" } else { Write-Host "[FAIL] $($c.n)"; $failed++ }
    }
    if ($failed) { Write-Host "Ausgaben (rc=$rc0/$rc1/$rc2/$rc3/$rc4):"; Write-Host $o0; Write-Host $o1; Write-Host $o2; Write-Host $o3; Write-Host $o4 }
} finally {
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
exit $failed
