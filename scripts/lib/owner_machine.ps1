# owner_machine.ps1 -- erkennt die Owner-Maschine: private Denylist oder echte Chat-ID in der .env des Haupt-Checkouts.
# Sperren, die nur dort gelten (Pruefstempel scripts/privacy_outgoing.ps1 -Check, Release-Pin scripts/release_pin_guard.ps1),
# fragen hier: Beitraege von aussen und die CI haben beides nicht und werden nie blockiert.

function Test-OwnerMachine([string]$MainRoot) {
    if (Test-Path (Join-Path $MainRoot '.local\privacy_denylist.txt')) { return $true }
    $envPath = Join-Path $MainRoot '.env'
    if (-not (Test-Path $envPath)) { return $false }
    $u8 = New-Object System.Text.UTF8Encoding($false)
    return @([System.IO.File]::ReadAllLines($envPath, $u8) | Where-Object { $_ -match '^\s*[A-Z0-9_]*CHAT_ID\s*=\s*["'']?-?[0-9]{6,}["'']?\s*$' }).Count -gt 0
}

# Haupt-Checkout (nicht der Worktree): dort liegen .local/ und .env.
function Get-MainCheckoutRoot([string]$RepoRoot) {
    return Split-Path ([string](& git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir)) -Parent
}
