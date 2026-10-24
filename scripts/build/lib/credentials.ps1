#Requires -Version 5.1
# =====================================================================================================
# credentials.ps1 — Paket-Credential-Deskriptoren aus den Manifesten (Phase D: die Engine kennt kein Paket)
#
# Ein Build-Def referenziert eine Credential ueber einen lesbaren Platzhalter-Deskriptor
# @{ id = '__CRED_…__'; name = '…' }; inject_credentials.sh legt die Credential beim Deploy an und
# deploy_workflows.sh tauscht den Platzhalter gegen die echte id. Diese Funktion leitet die Deskriptoren
# ALLER Nicht-Core-Pakete mit DERSELBEN Formel ab wie provisioning/lib/inject_credentials.sh
# (_cred_pkg_placeholder_names) und contract_lint Check 12b:
#   (a) je Paket die zwei Rollen-Creds der Konvention <pkg>_rw/<pkg>_ro (der Installer legt beide fuer
#       JEDES Paket an) -> Variable CRED_<PKG>_RW / CRED_<PKG>_RO;
#   (b) je Eintrag des Manifest-`credentials`-Blocks (docs/package-contract.md §3.8) -> Variable = der
#       Platzhalter ohne die umschliessenden '__' (__CRED_ADZUNA__ -> CRED_ADZUNA).
# Ergibt exakt die frueher in build.ps1 hartkodierten Variablennamen -> die Build-Defs lesen sie unveraendert
# per Dynamic Scope. Kollision zweier Namen / ungueltiger Platzhalter -> throw (fail-closed).
# Abhaengigkeitsfrei (nur Manifest-JSON rein, Objekte raus).
# =====================================================================================================

function Get-PackageCredentialDescriptor {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $u8   = New-Object System.Text.UTF8Encoding($false)
    $inv  = [System.Globalization.CultureInfo]::InvariantCulture
    $list = @()
    foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json') | Sort-Object FullName)) {
        $m   = [System.IO.File]::ReadAllText($mf.FullName, $u8) | ConvertFrom-Json
        $pkg = [string]$m.name
        if ([string]::IsNullOrEmpty($pkg) -or $pkg -eq 'core') { continue }   # Core = Host: eigene Creds im build.ps1-Host-Block
        $up = $pkg.ToUpper($inv)
        $list += [pscustomobject]@{ Var = "CRED_${up}_RW"; Package = $pkg; Id = "__CRED_POSTGRES_${up}_RW__"; Name = "Postgres ${pkg}_rw (read-write)" }
        $list += [pscustomobject]@{ Var = "CRED_${up}_RO"; Package = $pkg; Id = "__CRED_POSTGRES_${up}_RO__"; Name = "Postgres ${pkg}_ro (read-only)" }
        if ($null -eq $m.credentials) { continue }
        foreach ($p in $m.credentials.PSObject.Properties) {
            if ($p.Name -eq '_comment') { continue }
            $ph = [string]$p.Value.placeholder
            if ($ph -notmatch '^__(CRED_[A-Z0-9_]+)__$') {
                throw "credentials: '$pkg.credentials.$($p.Name).placeholder' = '$ph' verfehlt ^__CRED_[A-Z0-9_]+__`$ (packages/$pkg/manifest.json)."
            }
            $list += [pscustomobject]@{ Var = $Matches[1]; Package = $pkg; Id = $ph; Name = [string]$p.Value.name }
        }
    }
    foreach ($dup in @($list | Group-Object Var | Where-Object { $_.Count -gt 1 })) {
        throw "credentials: Variable '`$$($dup.Name)' mehrfach abgeleitet ($((@($dup.Group | ForEach-Object { $_.Package })) -join ', ')) — Platzhalter umbenennen."
    }
    return $list
}
