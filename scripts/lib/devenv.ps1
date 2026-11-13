#Requires -Version 5.1
# Geteilte Helfer der Dev-Umgebungs-Einrichtung (dot-source-only, keine Seiteneffekte beim Laden).
#
# Konsumenten:
#   - scripts/install_git_hooks.ps1     -> Resolve-Prek (nach dem Clone)
#   - scripts/setup_dev_env.ps1         -> Resolve-Prek (nach frischem winget-Install), $DevEnvPins
#                                          (Download-Versionen) + Get-DevEnvRequirementHash (Marker)
#   - .claude/hooks/check_dev_env.ps1   -> Get-DevEnvRequirementHash (Frisch-System-Erkennung)
#   - scripts/doc_lint.ps1 (Check 11)   -> liest $DevEnvPins textuell fuer den Pin-Drift-Check
#
# Die gepinnten Binary-Versionen sind hier die Source of Truth; doc_lint Check 11 haelt sie
# driftfrei gegen die externen Zweitquellen (ci.yml fuer gitleaks/squawk, build_site.ps1 fuer Hugo).

# Gepinnte Toolchain-Versionen (Drift-gegatet via doc_lint Check 11).
$script:DevEnvPins = [ordered]@{
    gitleaks      = '8.30.1'   # == .github/workflows/ci.yml (gitleaks-Job)
    squawk        = '2.70.0'   # == .github/workflows/ci.yml (squawk-Install)
    dotenv_linter = '4.0.0'    # local-only (CI: SKIP=dotenv-linter) -> keine externe Zweitquelle
    hugo          = '0.168.0'  # == scripts/build_site.ps1 $PinnedHugoVersion (nur -Site)
}

# 3-stufige prek-Aufloesung: PATH -> winget-Links-Shim
# -> Packages-Scan. Gibt den Pfad oder $null zurueck; der Aufrufer entscheidet ueber throw/Install
# (install_git_hooks wirft, setup_dev_env installiert erst via winget und ruft dann erneut).
function Resolve-Prek {
    $p = (Get-Command prek -ErrorAction SilentlyContinue).Source
    if ($p) { return $p }
    $cand = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\prek.exe'
    if (Test-Path $cand) { return $cand }
    $pkg = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -Filter prek.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { return $pkg.FullName }
    return $null
}

# Windows sperrt PowerShell-Skripte im Terminal des Owners, solange keine passende Richtlinie gesetzt ist (Symptom:
# Abbruch beim Signieren). Die Prozess-Ebene zaehlt nicht: Hooks und Tools laufen mit -ExecutionPolicy Bypass, das Terminal
# nicht. Gibt den Hinweis zurueck oder $null. Setzt nie etwas: die Sicherheitseinstellung bleibt beim Owner.
function Get-ExecutionPolicyHint {
    foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
        $policy = "$(Get-ExecutionPolicy -Scope $scope)"
        if ($policy -eq 'Undefined') { continue }
        if ($policy -in 'RemoteSigned', 'Unrestricted', 'Bypass') { return $null }
        break
    }
    return 'Windows sperrt hier PowerShell-Skripte im Terminal (z. B. sign_release, grant_owner_window). Der Owner fuehrt selbst aus: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
}

# Stabiler, sortierter Fingerprint der Anforderungs-Liste (Tool-Namen + Pins) -> deterministisch.
# setup_dev_env.ps1 schreibt MD5(davon) in .local/devenv_state.json; check_dev_env.ps1 vergleicht.
# Jeder Pin-Bump / jedes hinzugefuegte/entfernte Tool aendert den String -> Marker wird stale ->
# Reminder. Bewusst nur die Anforderungs-Liste, nicht der Ist-Zustand (kein TTL -- ein spaeter
# manuell deinstalliertes Tool wird nicht re-erkannt; diese Grenze steht in CONTRIBUTING.md *Setup*).
function Get-DevEnvRequirementFingerprint {
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($k in $script:DevEnvPins.Keys) { $tokens.Add("pin:$k=$($script:DevEnvPins[$k])") }
    foreach ($t in @('winget', 'git-identity', 'developer-mode', 'junction-probe', 'docker',
                     'psql17', 'prek', 'psscriptanalyzer', 'localbin-path', 'dotenv-file')) {
        $tokens.Add("tool:$t")
    }
    return (($tokens | Sort-Object) -join "`n")
}

function Get-DevEnvRequirementHash {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes((Get-DevEnvRequirementFingerprint)))
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
}
