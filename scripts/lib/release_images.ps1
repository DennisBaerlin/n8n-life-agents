# release_images.ps1 — eine Adresse fuer die Auslieferung des master-Images (Docker-Verbund): Release-Pathspec, die zwei Formen
# der Pin-Zeile in provisioning/compose/compose.yml und der Blick ins Container-Register per HTTP (ohne Docker, ohne Anmeldung).
# Dot-Sourcing: scripts/build_master_image.ps1, scripts/sign_release.ps1, scripts/release_pin_guard.ps1, scripts/contract_lint.ps1 (33),
# scripts/layout_lint.ps1 (L6), scripts/dev/release_images_test.ps1.
#
# Pin-Zeile (x-images.master, Anker &img_master):
#   neutral  ${LA_MASTER_IMAGE:?LA_MASTER_IMAGE fehlt (kein Release-Pin)}   Branches + JEDER Bau-Kontext des Images
#   Release  ${LA_MASTER_IMAGE:-<register>/<pfad>@sha256:<64 hex>}           ab dem Pin-Commit bis zum Tag
# Das Image enthaelt immer die neutrale Form: stuende sein eigener Digest darin, aenderte das Eintragen den Digest. Im master
# ist LA_MASTER_IMAGE ohnehin gesetzt (compose.yml environment). Pruefbar bleibt die Herkunft ueber das Label
# org.opencontainers.image.revision: zwischen diesem Commit und dem Tag darf sich im Release-Baum nur die Pin-Zeile aendern.

$ReleasePathspec = @('provisioning', 'packages', '.gitattributes')   # = git-archive-Pathspec in .github/workflows/release.yml (layout_lint L6)
$MasterPinNeutral = '${LA_MASTER_IMAGE:?LA_MASTER_IMAGE fehlt (kein Release-Pin)}'
$MasterPlatforms = @('linux/amd64', 'linux/arm64')
$MasterComposeRel = 'provisioning/compose/compose.yml'
$script:MasterPinLineRx = [regex]'(?m)^(?<pre>  master:[ \t]+&img_master[ \t]+)(?<val>[^\r\n]*?)[ \t]*(?=\r?$)'
$script:MasterPinValRx = [regex]'^\$\{LA_MASTER_IMAGE:-(?<ref>[a-z0-9.-]+(?::[0-9]+)?(?:/[a-z0-9._-]+)+)@(?<digest>sha256:[0-9a-f]{64})\}$'

# Get-MasterPin <compose-text> -> @{ Form = 'neutral'|'pinned'; Ref; Digest }. Wirft bei fehlender, doppelter oder fremder Zeile.
function Get-MasterPin([string]$ComposeText) {
    $m = $script:MasterPinLineRx.Matches($ComposeText)
    if ($m.Count -ne 1) { throw "compose.yml: $($m.Count) Zeilen 'master: &img_master …' (erwartet genau 1)." }
    $v = $m[0].Groups['val'].Value
    if ($v -ceq $MasterPinNeutral) { return @{ Form = 'neutral'; Ref = $null; Digest = $null } }
    $p = $script:MasterPinValRx.Match($v)
    if (-not $p.Success) { throw "compose.yml: Pin-Zeile '$v' ist weder neutral noch `${LA_MASTER_IMAGE:-<register>/<pfad>@sha256:<64 hex>}." }
    return @{ Form = 'pinned'; Ref = $p.Groups['ref'].Value; Digest = $p.Groups['digest'].Value }
}

# Set-MasterPin <compose-text> [-Ref <register/pfad> -Digest sha256:…] -> Text mit Release-Pin; ohne Ref die neutrale Form.
function Set-MasterPin([string]$ComposeText, [string]$Ref, [string]$Digest) {
    $null = Get-MasterPin $ComposeText   # genau eine gueltige Zeile, sonst Abbruch
    $val = $MasterPinNeutral
    if ($Ref) {
        $val = '${LA_MASTER_IMAGE:-' + $Ref + '@' + $Digest + '}'
        if (-not $script:MasterPinValRx.IsMatch($val)) { throw "Ungueltiger Pin '$Ref@$Digest' (Register/Pfad klein, Digest sha256:<64 hex>)." }
    }
    return $script:MasterPinLineRx.Replace($ComposeText, { param($mm) $mm.Groups['pre'].Value + $val }, 1)
}

# --- Register (OCI Distribution API) ----------------------------------------------------------------------------------------
# Lokales Test-Register (127.0.0.1/localhost) spricht http, alles andere https. Anonym: ein oeffentliches Paket muss so ladbar
# sein, sonst scheitert jede Installation — genau das prueft sign_release.ps1 damit mit.
$script:ManifestAccept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
$script:IndexTypes = @('application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json')

function Split-ImageRef([string]$Ref) {
    $i = $Ref.IndexOf('/')
    if ($i -lt 1) { throw "Image '$Ref' ohne Register (erwartet <register>/<pfad>)." }
    $reg = $Ref.Substring(0, $i)
    $scheme = if ($reg -match '^(127\.0\.0\.1|localhost)(:\d+)?$') { 'http' } else { 'https' }
    return @{ Registry = $reg; Repo = $Ref.Substring($i + 1); Base = "${scheme}://$reg" }
}

function New-RegistryClient {
    Add-Type -AssemblyName System.Net.Http
    $h = [System.Net.Http.HttpClientHandler]::new()
    $h.AllowAutoRedirect = $true   # Blobs leitet GHCR auf signierte Speicher-Adressen um; .NET laesst dabei Authorization weg
    $c = [System.Net.Http.HttpClient]::new($h)
    $c.Timeout = [TimeSpan]::FromSeconds(60)
    return $c
}

# Invoke-RegistryGet -> @{ Status; Type; Bytes; Auth (WWW-Authenticate) }
function Invoke-RegistryGet($Client, [string]$Url, [string]$Token, [string]$Accept) {
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
    if ($Accept) { $null = $req.Headers.TryAddWithoutValidation('Accept', $Accept) }
    if ($Token) { $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token) }
    $res = $Client.SendAsync($req).GetAwaiter().GetResult()
    try {
        $auth = if ($res.Headers.WwwAuthenticate.Count) { $res.Headers.WwwAuthenticate.ToString() } else { '' }
        $type = if ($res.Content.Headers.ContentType) { $res.Content.Headers.ContentType.MediaType } else { '' }
        return @{ Status = [int]$res.StatusCode; Type = $type; Bytes = $res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult(); Auth = $auth }
    } finally { $res.Dispose(); $req.Dispose() }
}

# Get-RegistryToken: anonymes Pull-Token nach dem Bearer-Muster (GHCR, Docker Hub); $null, wenn das Register keins verlangt.
function Get-RegistryToken($Client, $R) {
    $probe = Invoke-RegistryGet $Client "$($R.Base)/v2/" $null $null
    if ($probe.Status -ne 401) { return $null }
    $realm = [regex]::Match($probe.Auth, 'realm="([^"]+)"').Groups[1].Value
    $svc = [regex]::Match($probe.Auth, 'service="([^"]+)"').Groups[1].Value
    if (-not $realm) { throw "Register $($R.Registry) verlangt eine Anmeldung, nennt aber keinen Token-Dienst." }
    $u = "${realm}?service=$([uri]::EscapeDataString($svc))&scope=$([uri]::EscapeDataString("repository:$($R.Repo):pull"))"
    $t = Invoke-RegistryGet $Client $u $null $null
    if ($t.Status -ne 200) { throw "Kein anonymes Token fuer $($R.Registry)/$($R.Repo) (HTTP $($t.Status))." }
    $j = [System.Text.Encoding]::UTF8.GetString($t.Bytes) | ConvertFrom-Json
    if ($j.token) { return $j.token }
    return $j.access_token
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return 'sha256:' + (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

# Get-FileSha256: hex ohne Praefix. Bewusst nicht Get-FileHash: Ruft prek in der CI (Windows-Runner, Shell pwsh) powershell.exe
# auf, erbt 5.1 den PSModulePath von pwsh 7 und findet Get-FileHash nicht (CommandNotFoundException).
function Get-FileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create(); $fs = [System.IO.File]::OpenRead($Path)
    try { return (($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $fs.Dispose(); $sha.Dispose() }
}

# Get-RegistryObject: Manifest oder Blob per Digest; prueft, dass der Inhalt wirklich diesen Digest hat (Inhalts-Adressierung).
function Get-RegistryObject($Client, $R, [string]$Token, [string]$Kind, [string]$Digest) {
    $accept = if ($Kind -eq 'manifests') { $script:ManifestAccept } else { $null }
    $res = Invoke-RegistryGet $Client "$($R.Base)/v2/$($R.Repo)/$Kind/$Digest" $Token $accept
    if ($res.Status -ne 200) { throw "HTTP $($res.Status) fuer $($R.Registry)/$($R.Repo) $Kind/$Digest." }
    $got = Get-BytesSha256 $res.Bytes
    if ($got -ne $Digest) { throw "Register lieferte fuer $Digest Inhalt mit $got." }
    return @{ Type = $res.Type; Json = ([System.Text.Encoding]::UTF8.GetString($res.Bytes) | ConvertFrom-Json) }
}

# Get-MasterImageReport -Ref <register/pfad> -Digest sha256:… -> @{ Ok; Problems[]; Revision; Version; Platforms; SizeMb }
#   Ok = anonym ladbarer Multi-Arch-Index mit genau den Plattformen in $MasterPlatforms (Nachweis-Eintraege unknown/unknown
#   zaehlen nicht), alle mit demselben Label org.opencontainers.image.revision. SizeMb = Summe der komprimierten Schichten je
#   Plattform (groesste), fuer die Ansage vor dem Veroeffentlichen.
function Get-MasterImageReport([string]$Ref, [string]$Digest) {
    $out = @{ Ok = $false; Problems = New-Object System.Collections.Generic.List[string]; Revision = $null; Version = $null; Platforms = @(); SizeMb = 0 }
    $R = Split-ImageRef $Ref
    $c = New-RegistryClient
    try {
        $tok = Get-RegistryToken $c $R
        $idx = Get-RegistryObject $c $R $tok 'manifests' $Digest
        $mt = if ($idx.Json.mediaType) { $idx.Json.mediaType } else { $idx.Type }
        if ($script:IndexTypes -notcontains $mt) { $out.Problems.Add("$Ref@$Digest ist kein Multi-Arch-Index ($mt)."); return $out }
        $revs = @{}; $max = 0
        foreach ($m in @($idx.Json.manifests)) {
            $plat = "$($m.platform.os)/$($m.platform.architecture)"
            if ($plat -eq 'unknown/unknown') { continue }
            $out.Platforms += $plat
            $man = Get-RegistryObject $c $R $tok 'manifests' $m.digest
            $cfg = Get-RegistryObject $c $R $tok 'blobs' $man.Json.config.digest
            $lab = $cfg.Json.config.Labels
            $rev = if ($lab) { $lab.'org.opencontainers.image.revision' } else { $null }
            $revs[$plat] = $rev
            if ($lab -and $lab.'org.opencontainers.image.version') { $out.Version = $lab.'org.opencontainers.image.version' }
            $sz = 0; foreach ($l in @($man.Json.layers)) { $sz += [int64]$l.size }
            if ($sz -gt $max) { $max = $sz }
        }
        $out.SizeMb = [math]::Round($max / 1MB)
        $missing = @($MasterPlatforms | Where-Object { $out.Platforms -notcontains $_ })
        $extra = @($out.Platforms | Where-Object { $MasterPlatforms -notcontains $_ })
        if ($missing.Count) { $out.Problems.Add("Plattform fehlt im Index: $($missing -join ', ').") }
        if ($extra.Count) { $out.Problems.Add("Unerwartete Plattform im Index: $($extra -join ', ').") }
        $distinct = @($revs.Values | Sort-Object -Unique)
        if ($distinct.Count -ne 1 -or -not $distinct[0]) { $out.Problems.Add("Label org.opencontainers.image.revision fehlt oder ist je Plattform verschieden ($(($revs.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')).") }
        else { $out.Revision = $distinct[0] }
    } catch {
        $out.Problems.Add($_.Exception.Message)
        return $out
    } finally { $c.Dispose() }
    $out.Ok = ($out.Problems.Count -eq 0)
    return $out
}

# Test-MasterRevision -RepoRoot -Revision <commit> -Tag <ref> -> Liste der Abweichungen (leer = das Image ist der Release-Baum
#   des Tags bis auf die Pin-Zeile). Revision muss Vorfahr des Tags sein.
function Test-MasterRevision([string]$RepoRoot, [string]$Revision, [string]$Tag) {
    $iss = New-Object System.Collections.Generic.List[string]
    # PS 5.1 macht aus git-stderr unter ErrorActionPreference=Stop einen Abbruch; hier zaehlt nur der Exit-Code.
    $ErrorActionPreference = 'Continue'
    & git -C $RepoRoot cat-file -e "$Revision^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { $iss.Add("Image-Revision $Revision ist kein Commit dieses Repos (git fetch?)."); return , $iss }
    & git -C $RepoRoot merge-base --is-ancestor $Revision $Tag
    if ($LASTEXITCODE -ne 0) { $iss.Add("Image-Revision $Revision ist kein Vorfahr von $Tag."); return , $iss }
    $changed = @(& git -C $RepoRoot diff --name-only $Revision $Tag -- @ReleasePathspec | Where-Object { $_ })
    foreach ($f in $changed) { if ($f -ne $MasterComposeRel) { $iss.Add("Seit dem Image-Bau geaendert: $f — Image neu bauen (build_master_image.ps1).") } }
    if ($changed -contains $MasterComposeRel) {
        $a = (& git -C $RepoRoot show "${Revision}:$MasterComposeRel") -join "`n"
        $b = (& git -C $RepoRoot show "${Tag}:$MasterComposeRel") -join "`n"
        if ((Set-MasterPin $a) -cne (Set-MasterPin $b)) { $iss.Add("compose.yml weicht seit dem Image-Bau nicht nur in der Pin-Zeile ab — Image neu bauen.") }
    }
    return , $iss
}

# Test-MasterPinOffline -RepoRoot -Rev <commit/tag> -> Abweichungen (leer = Pin passt), ohne Register: die Revision ist dann
#   nicht das Label, sondern der Elternteil des Commits, der den Digest der Pin-Zeile eingetragen hat (build_master_image.ps1
#   baut aus HEAD, der Pin-Commit folgt direkt). Faengt einen Tag ohne Pin und einen veralteten Pin (Image aelter als der
#   Release-Baum); dass das Image im Register liegt und das Label stimmt, prueft erst sign_release.ps1 (Test-ReleaseCompose).
#   Nutzer: scripts/release_pin_guard.ps1 (Sperre beim Taggen und beim Tag-Push).
function Test-MasterPinOffline([string]$RepoRoot, [string]$Rev) {
    $iss = New-Object System.Collections.Generic.List[string]
    $ErrorActionPreference = 'Continue'
    $tip = [string](& git -C $RepoRoot rev-parse -q --verify "$Rev^{commit}" 2>$null)
    if (-not $tip) { $iss.Add("Stand $Rev nicht aufloesbar."); return , $iss }
    $text = (& git -C $RepoRoot show "${tip}:$MasterComposeRel" 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { $iss.Add("$MasterComposeRel fehlt in $Rev."); return , $iss }
    try { $pin = Get-MasterPin $text } catch { $iss.Add($_.Exception.Message); return , $iss }
    if ($pin.Form -ne 'pinned') { $iss.Add('compose.yml traegt keinen Release-Pin des master-Images.'); return , $iss }
    $pinCommit = [string](& git -C $RepoRoot log -1 --format=%H "-S$($pin.Digest)" $tip -- $MasterComposeRel 2>$null)
    $built = if ($pinCommit) { [string](& git -C $RepoRoot rev-parse -q --verify "$pinCommit^" 2>$null) } else { '' }
    if (-not $built) { $iss.Add("Pin-Commit fuer $($pin.Digest.Substring(0, 19)) nicht gefunden."); return , $iss }
    foreach ($p in (Test-MasterRevision $RepoRoot $built $tip)) { $iss.Add($p) }
    return , $iss
}

# --- Release-Pruefung (sign_release.ps1)--------------------------------------------------------------------------------------
$ReleaseSumAssets = @('install.sh', 'compose.yml', 'lifeagents.dmg', 'lifeagents-setup.exe')   # nach dem Tarball, Reihenfolge = release.yml

# Test-ReleaseSums -Dir -Tarball -> Abweichungen: SHA256SUMS muss genau Tarball + $ReleaseSumAssets in dieser Reihenfolge nennen,
#   jede Pruefsumme passend zur geladenen Datei.
function Test-ReleaseSums([string]$Dir, [string]$Tarball) {
    $iss = New-Object System.Collections.Generic.List[string]
    $names = @($Tarball) + $ReleaseSumAssets
    $want = foreach ($n in $names) {
        $p = Join-Path $Dir $n
        if (-not (Test-Path -LiteralPath $p)) { $iss.Add("Asset $n fehlt."); continue }
        "$(Get-FileSha256 $p)  $n"
    }
    if ($iss.Count) { return , $iss }
    $have = @([System.IO.File]::ReadAllLines((Join-Path $Dir 'SHA256SUMS')) | Where-Object { $_ })
    if ((@($have) -join "`n") -cne (@($want) -join "`n")) { $iss.Add("SHA256SUMS passt nicht zu den geladenen Dateien:`n$($have -join "`n")") }
    return , $iss
}

# Test-ReleaseCompose -RepoRoot -Tag -ComposeFile -> @{ Problems; Report }: Asset = compose.yml des Tags (Blob), traegt den
#   Release-Pin, das Image liegt anonym als Multi-Arch-Index im Register und ist der Release-Baum des Tags bis auf die Pin-Zeile.
function Test-ReleaseCompose([string]$RepoRoot, [string]$Tag, [string]$ComposeFile) {
    $iss = New-Object System.Collections.Generic.List[string]
    $ErrorActionPreference = 'Continue'
    $blobWant = (& git -C $RepoRoot rev-parse "${Tag}:$MasterComposeRel" 2>$null)
    $blobHave = (& git -C $RepoRoot hash-object --no-filters $ComposeFile)
    if (-not $blobWant -or $blobWant.Trim() -ne $blobHave.Trim()) { $iss.Add("compose.yml im Release weicht von $MasterComposeRel des Tags ab."); return @{ Problems = $iss; Report = $null } }
    try { $pin = Get-MasterPin ([System.IO.File]::ReadAllText($ComposeFile, [System.Text.UTF8Encoding]::new($false))) }
    catch { $iss.Add($_.Exception.Message); return @{ Problems = $iss; Report = $null } }
    if ($pin.Form -ne 'pinned') { $iss.Add('compose.yml traegt keinen Release-Pin des master-Images (build_master_image.ps1).'); return @{ Problems = $iss; Report = $null } }
    $rep = Get-MasterImageReport -Ref $pin.Ref -Digest $pin.Digest
    foreach ($p in $rep.Problems) { $iss.Add("master-Image $($pin.Ref)@$($pin.Digest): $p") }
    if ($rep.Ok) { foreach ($p in (Test-MasterRevision $RepoRoot $rep.Revision $Tag)) { $iss.Add($p) } }
    return @{ Problems = $iss; Report = $rep; Pin = $pin }
}
