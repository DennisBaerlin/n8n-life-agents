#Requires -Version 5.1
# release_meta.ps1 -- Kommandozeilen-Eingang von scripts/lib/release_tag.ps1 fuer .github/workflows/release.yml (bash ruft pwsh).
# Usage:
#   pwsh -NoProfile -File scripts/release_meta.ps1 -Tag v0.51.0-rc.1 -What create-flags            Schalter fuer gh release create, je Zeile einer (stabil: keine Ausgabe)
#   pwsh -NoProfile -File scripts/release_meta.ps1 -Tag v0.51.0 -What install-note -Repo <owner/repo>  Installations-Hinweis fuer den Release-Text
# Exit 0 = ausgegeben; ungueltiges Tag -> Exit 1 (der Release-Lauf bricht dann ab, bevor ein Release entsteht).
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][ValidateSet('create-flags', 'install-note')][string]$What,
    [string]$Repo
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
trap { [Console]::Error.WriteLine("release_meta: $($_.Exception.Message)"); exit 1 }
. (Join-Path $PSScriptRoot 'lib/release_tag.ps1')

switch ($What) {
    'create-flags' { foreach ($f in (Get-ReleaseCreateFlags $Tag)) { Write-Output $f } }
    'install-note' {
        if (-not $Repo) { throw '-Repo <owner/repo> fehlt.' }
        Write-Output (Get-ReleaseInstallNote $Repo $Tag)
    }
}
