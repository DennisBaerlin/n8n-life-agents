#Requires -Version 5.1
# release_tag.ps1 -- die EINE Stelle fuer "stabiles Release oder Vorab-Release" beim Release-Bau (release.yml ueber
# scripts/release_meta.ps1, scripts/sign_release.ps1). Ein Vorab-Tag (vX.Y.Z-<suffix>, z. B. v0.51.0-rc.1) wird auf GitHub als
# prerelease angelegt und nie als latest markiert: /releases/latest, aus dem `lifeagents update`, install.sh ohne --version,
# setup.sh-Einstieg und der Release-Check lesen, zeigt so weiter auf das letzte stabile Release. Die Kern-Seite (welche
# Nummern eine Installation als Version kennt) steht in provisioning/lib/common.sh. Test: scripts/dev/release_tag_test.ps1.

# Suffix nach SemVer-Zeichensatz ohne '+' (Build-Metadaten tragen wir nicht; '+' waere in Asset-URLs ein Sonderfall).
# [0-9] statt \d: \d trifft in .NET jede Unicode-Ziffer, die bash-Seite (common.sh) nur ASCII.
$ReleaseTagStableRx = '^v[0-9]+\.[0-9]+\.[0-9]+$'
$ReleaseTagPreRx = '^v[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*$'

# Get-ReleaseTagKind <tag> -> 'stable' | 'prerelease'; jedes andere Format wirft.
function Get-ReleaseTagKind([string]$Tag) {
    if ($Tag -cmatch $ReleaseTagStableRx) { return 'stable' }
    if ($Tag -cmatch $ReleaseTagPreRx) { return 'prerelease' }
    throw "Ungueltiges Release-Tag '$Tag' (erwartet vX.Y.Z oder vX.Y.Z-<suffix>, z. B. v0.51.0 oder v0.51.0-rc.1)."
}

# Get-ReleaseCreateFlags <tag> -> Zusatz-Schalter fuer `gh release create`. Stabil: keine (latest setzt erst sign_release beim
# Veroeffentlichen des Entwurfs). Vorab: prerelease und ausdruecklich nicht latest.
function Get-ReleaseCreateFlags([string]$Tag) {
    if ((Get-ReleaseTagKind $Tag) -eq 'prerelease') { return @('--prerelease', '--latest=false') }
    return @()
}

# Get-ReleasePublishFlags <tag> -> Schalter fuer `gh release edit` beim Veroeffentlichen des unterschriebenen Entwurfs.
function Get-ReleasePublishFlags([string]$Tag) {
    if ((Get-ReleaseTagKind $Tag) -eq 'prerelease') { return @('--draft=false', '--prerelease', '--latest=false') }
    return @('--draft=false', '--latest')
}

# Get-ReleaseInstallNote <slug> <tag> -> Installations-Hinweis am Ende des Release-Textes (englisch, oeffentliche Seite).
# Neue Linux-Installationen laufen ueber setup.sh (Docker-Verbund); install.sh nur noch mit --version fuer den klassischen Weg.
# Die Asset-URLs nennen das Tag, nicht /releases/latest: so installiert der Link genau dieses Release, auch ein Vorab-Release.
function Get-ReleaseInstallNote([string]$Slug, [string]$Tag) {
    $kind = Get-ReleaseTagKind $Tag
    $base = "https://github.com/$Slug/releases/download/$Tag"
    $setup = "``apt-get update && apt-get install -y curl && curl -fsSL $base/setup.sh -o setup.sh && bash setup.sh``"
    $classic = "``apt-get update && apt-get install -y curl && curl -fsSL $base/install.sh -o install.sh && bash install.sh --version $Tag``"
    if ($kind -eq 'prerelease') {
        return "Pre-release for testing only: it is not offered as an update, and existing instances stay on the latest stable release. " +
            "Install on a test server (as root): $setup. Classic installation (without Docker): $classic."
    }
    return "Install on a Linux server (as root): $setup. Update an existing instance: ``lifeagents update``. " +
        "Classic installation (without Docker): $classic."
}
