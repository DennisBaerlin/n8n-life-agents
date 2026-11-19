#Requires -Version 5.1
# release_setup_asset.ps1 -- schreibt das Release-Asset setup.sh: provisioning/setup.sh dieses Baums mit dem Abbild-Pin der
# compose.yml desselben Baums (x-images.master). Aufruf in .github/workflows/release.yml auf dem Tag-Checkout; sign_release.ps1
# prueft das Asset danach mit Test-ReleaseSetup (scripts/lib/release_images.ps1), also kein zweiter Weg, den Pin zu setzen.
# Usage: pwsh -NoProfile -File scripts/release_setup_asset.ps1 [-Out setup.sh]
# Exit 0 = geschrieben; sonst throw (compose.yml traegt keinen Release-Pin, setup.sh ohne genau eine Platzhalter-Zeile).
param([string]$Out = 'setup.sh')
$ErrorActionPreference = 'Stop'
$u8 = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib/release_images.ps1')

$pin = Get-MasterPin ([System.IO.File]::ReadAllText((Join-Path $RepoRoot $MasterComposeRel), $u8))
if ($pin.Form -ne 'pinned') { throw "$MasterComposeRel traegt keinen Release-Pin des master-Images (build_master_image.ps1)." }
$text = [System.IO.File]::ReadAllText((Join-Path $RepoRoot $SetupRel), $u8)
if ((Get-SetupPin $text) -ne '') { throw "$SetupRel traegt im Baum schon einen Pin (erwartet MASTER_IMAGE_PIN='')." }
[System.IO.File]::WriteAllText($Out, (Set-SetupPin $text "$($pin.Ref)@$($pin.Digest)"), $u8)
Write-Host "setup.sh geschrieben ($Out), Pin $($pin.Ref)@$($pin.Digest)"
