# hash.ps1 -- Pruefsummen ohne Get-FileHash. Dot-Sourcing: . (Join-Path $PSScriptRoot 'lib\hash.ps1')
#
# Get-FileHash ist in Windows PowerShell 5.1 eine Funktion des per Autoload geholten Moduls Microsoft.PowerShell.Utility. Ruft pwsh 7 (CI: prek
# auf dem Windows-Runner) powershell.exe -NoProfile auf, erbt 5.1 den PSModulePath von pwsh 7 und findet Get-FileHash nicht
# (CommandNotFoundException). Skripte, die ein Hook so startet, nehmen darum Get-FileSha256.
# Get-FileSha256 <pfad> -> SHA-256 als Hex, klein geschrieben, ohne Praefix.
function Get-FileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create(); $fs = [System.IO.File]::OpenRead($Path)
    try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $fs.Dispose(); $sha.Dispose() }
}