#Requires -Version 5.1
# new_release_key.ps1 — EINMALIG im Terminal des Owners: den Release-Signierschluessel des Projekts erzeugen
# (Update im Chat, Phase 2 "unterschriebene Releases"; Muster Debian SecureApt: Offline-Schluessel + gpgv).
#
# Was passiert:
#   1. gpg (aus Git for Windows) erzeugt einen Ed25519-Signierschluessel mit Passwort (fragt dieses Skript ab, geht per
#      stdin an gpg — nie ins argv). Der PRIVATE Schluessel bleibt im gpg-Speicher dieses PCs.
#   2. Der OEFFENTLICHE Schluessel landet als Schluesselbund in provisioning/keys/release-signing.gpg UND base64-
#      eingebettet in provisioning/install.sh (RELEASE_KEY_B64; contract_lint 24 haelt beides gleich).
#   3. Ab dem naechsten Release legt die CI das Release als ENTWURF an; veroeffentlicht wird es erst nach
#      .\scripts\sign_release.ps1 <tag>. Jede Installation spielt dann nur noch unterschriebene Updates ein.
# Danach: die beiden geaenderten Dateien committen (Leitung/Release-Ablauf) und den privaten Schluessel OFFLINE sichern
# (USB-Stick oder Passwort-Manager, Befehl steht am Ende). Geht er verloren, lassen sich keine Updates mehr ausliefern.
#
# Usage: .\scripts\new_release_key.ps1 [-Name 'n8n-life-agents release signing'] [-Email <adresse>]
param(
    [string]$Name = 'n8n-life-agents release signing',
    [string]$Email = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)   # stdin an gpg (Passwort) als UTF-8, nicht ASCII (PS 5.1)
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-GpgExe {
    $c = Get-Command gpg -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\Git\usr\bin\gpg.exe", "${env:ProgramFiles(x86)}\Git\usr\bin\gpg.exe")) {
        if (Test-Path $p) { return $p }
    }
    throw 'gpg nicht gefunden — Git for Windows bringt es mit (usr\bin\gpg.exe).'
}

function Read-Passphrase {
    $a = Read-Host -AsSecureString 'Passwort fuer den Signierschluessel (mind. 12 Zeichen)'
    $b = Read-Host -AsSecureString 'Passwort wiederholen'
    $pa = [System.Net.NetworkCredential]::new('', $a).Password
    $pb = [System.Net.NetworkCredential]::new('', $b).Password
    if ($pa -cne $pb) { throw 'Die Passwoerter stimmen nicht ueberein.' }
    if ($pa.Length -lt 12) { throw 'Das Passwort ist zu kurz (mindestens 12 Zeichen).' }
    return $pa
}

$gpg = Get-GpgExe
# gpg >= 2.4 legt in einem neuen Home 'use-keyboxd' in common.conf an. Das gpg aus Git for Windows startet keyboxd
# ausserhalb der Git-Bash nicht ("error running '/usr/lib/gnupg/keyboxd'", Owner-Lauf 2026-10-24) -> Zeile
# auskommentieren; gpg nutzt dann die Schluesseldatei pubring.kbx direkt (der klassische Weg, auch fuer sign_release.ps1).
$gpgHome = if ($env:GNUPGHOME) { $env:GNUPGHOME } else { Join-Path $env:USERPROFILE '.gnupg' }
$commonConf = Join-Path $gpgHome 'common.conf'
if ($gpg -like '*\Git\usr\bin\*' -and (Test-Path $commonConf)) {
    $conf = [System.IO.File]::ReadAllText($commonConf, $Utf8NoBom)
    if ($conf -match '(?m)^\s*use-keyboxd\s*$') {
        $conf = [regex]::Replace($conf, '(?m)^\s*use-keyboxd\s*$', '# use-keyboxd  (abgeschaltet: keyboxd startet mit Git-for-Windows-gpg nicht; new_release_key.ps1)')
        [System.IO.File]::WriteAllText($commonConf, $conf, $Utf8NoBom)
        Write-Host "gpg-Einstellung angepasst: 'use-keyboxd' in $commonConf abgeschaltet." -ForegroundColor DarkGray
    }
}
$keyFile = Join-Path $RepoRoot 'provisioning\keys\release-signing.gpg'
$installSh = Join-Path $RepoRoot 'provisioning\install.sh'
if (Test-Path $keyFile) {
    throw "Es gibt schon einen Release-Schluessel ($keyFile). Ein Schluesselwechsel ist bewusst kein Ein-Befehl-Vorgang (Installationen vertrauen nur dem ersten): docs/reference/provisioning.md *Release-Signatur*."
}
$uid = if ($Email) { "$Name <$Email>" } else { $Name }
# Nur der Exit-Code zaehlt. PS 5.1 macht aus umgeleitetem stderr eines Native-Tools ein ErrorRecord, das unter
# ErrorActionPreference=Stop abbricht -- gpg schreibt beim ersten Lauf "directory '.../.gnupg' created" dorthin
# (Owner-Lauf 2026-10-24) -> fuer diesen einen Aufruf Continue.
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& $gpg --batch --list-keys $uid *> $null
$listRc = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($listRc -eq 0) { throw "Im gpg-Speicher gibt es schon einen Schluessel '$uid' — anderen -Name waehlen oder den alten bewusst exportieren." }

Write-Host "Erzeuge den Ed25519-Signierschluessel '$uid' ..." -ForegroundColor Cyan
$pass = Read-Passphrase
$pass | & $gpg --batch --pinentry-mode loopback --passphrase-fd 0 --quick-generate-key $uid ed25519 sign never
if ($LASTEXITCODE -ne 0) { throw 'Schluessel-Erzeugung fehlgeschlagen.' }
$pass = $null

$fpr = ((& $gpg --batch --with-colons --list-keys $uid) | Where-Object { $_ -like 'fpr:*' } | Select-Object -First 1).Split(':')[9]
if (-not $fpr) { throw 'Fingerabdruck des neuen Schluessels nicht lesbar.' }

New-Item -ItemType Directory -Force (Split-Path $keyFile) | Out-Null
& $gpg --batch --yes --output $keyFile --export $fpr
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $keyFile)) { throw 'Export des oeffentlichen Schluessels fehlgeschlagen.' }

$b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($keyFile))
$txt = [System.IO.File]::ReadAllText($installSh, $Utf8NoBom)
$new = [regex]::Replace($txt, "(?m)^RELEASE_KEY_B64='[^']*'$", "RELEASE_KEY_B64='$b64'")
if ($new -ceq $txt) { throw "Zeile RELEASE_KEY_B64='...' in provisioning/install.sh nicht gefunden." }
[System.IO.File]::WriteAllText($installSh, $new, $Utf8NoBom)

Write-Host ''
Write-Host "Fertig. Fingerabdruck: $fpr" -ForegroundColor Green
Write-Host '  Geaendert: provisioning/keys/release-signing.gpg + provisioning/install.sh (RELEASE_KEY_B64) — bitte committen.'
Write-Host '  JETZT den privaten Schluessel offline sichern (USB-Stick/Passwort-Manager), z. B.:' -ForegroundColor Yellow
Write-Host "    & '$gpg' --export-secret-keys --armor $fpr > E:\release-signing-private.asc"
Write-Host '  Ohne diese Sicherung: ein verlorener PC = keine Updates mehr fuer alle Installationen.'
