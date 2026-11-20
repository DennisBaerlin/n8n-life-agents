#Requires -Version 5.1
# dev_target.ps1 -- Hilfen der Ziel-Sperre im Reset-Skript der Entwickler-Instanz (Dot-sourcen). Test: scripts/dev/reset_dev_guard_test.ps1.

# Name oder Adresse -> Adressen (Text); nicht aufloesbar -> leer.
function Resolve-HostAddresses([string]$Name) {
    try { return @([System.Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.ToString() }) } catch { return @() }
}

# Adressen des Routers dieses Rechners: Gateways der Netzwerkkarten plus der Name fritz.box. Fritz-Box-Namen von Containern loesen
# neben der Container-Adresse auch auf die der Box selbst auf; sie steckt dann in DEV und LIVE und sagt nichts ueber dasselbe Ziel.
function Get-RouterAddresses {
    $addrs = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            foreach ($g in $nic.GetIPProperties().GatewayAddresses) { $addrs.Add($g.Address.ToString()) }
        }
    } catch { }
    foreach ($a in (Resolve-HostAddresses 'fritz.box')) { $addrs.Add($a) }
    return @($addrs | Select-Object -Unique)
}

# $true, wenn DEV und LIVE eine gemeinsame aufgeloeste Adresse haben, die nicht die des Routers ist. Ohne aufloesbare Adressen
# kein Urteil ($false): dann entscheidet allein die Merkdatei auf dem Ziel.
function Test-SameTargetAddresses([string[]]$DevAddresses, [string[]]$LiveAddresses, [string[]]$RouterAddresses) {
    # Eine leere Auflösung kommt als $null an; ein $null im Pipeline-Eingang liefe sonst als Element mit und träfe sich mit $null.
    $common = @(@($DevAddresses) | Where-Object { $_ -and (@($LiveAddresses) -contains $_) -and (@($RouterAddresses) -notcontains $_) })
    return $common.Count -gt 0
}
