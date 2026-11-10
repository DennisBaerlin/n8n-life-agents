#Requires -Version 5.1
# release_images_test.ps1 -- Regressionstest fuer scripts/lib/release_images.ps1 (Pin-Zeile, Herkunft im Git, Blick ins Register).
# Teil A (immer, ohne Netz/Docker): Get-MasterPin/Set-MasterPin, Test-MasterRevision in einem Wegwerf-Repo.
# Teil B (nur mit -Registry): kleine Test-Images in ein LOKALES Register (registry:2 auf 127.0.0.1) und Get-MasterImageReport
#   dagegen: Multi-Arch mit Label = gruen; eine Plattform, ohne Label, falscher Digest = rot. Das Register startet der Aufrufer
#   (Docker nur mit eigenem Vorsatz), z. B.:
#     docker run -d --name di5-registry -p 127.0.0.1:5099:5000 registry:2
#     .\scripts\dev\release_images_test.ps1 -Registry 127.0.0.1:5099
#     docker rm -fv di5-registry
# Teil C (nur mit -MasterImage <register/pfad@sha256:…>, ein mit build_master_image.ps1 -NoPin aus HEAD gebautes Image): die
#   Pruefung von sign_release.ps1 (Test-ReleaseCompose) gegen lose Pin-Commits — gruen, Installer geaendert, falscher Digest,
#   Asset abweichend, ohne Pin. Legt nur lose Git-Objekte an (kein Branch, kein Tag).
# Exit-Code = Anzahl Fehler.
param([string]$Registry, [string]$MasterImage)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$u8 = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot '..\lib\release_images.ps1')
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
$failed = 0; $passed = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:passed++; Write-Host "  [OK]   $Name" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red }
}
function Throws([scriptblock]$Sb) { try { & $Sb | Out-Null; return $false } catch { return $true } }

$D = 'sha256:' + ('ab' * 32)
$base = "x-images:`n  busybox: &img_busybox busybox:1@$D`n  master: &img_master $MasterPinNeutral`nservices:`n  master:`n    image: *img_master`n"

Write-Host 'A: Pin-Zeile' -ForegroundColor Cyan
Check 'neutral erkannt' ((Get-MasterPin $base).Form -eq 'neutral')
$pinned = Set-MasterPin $base -Ref 'ghcr.io/o/r/master' -Digest $D
Check 'Pin gesetzt' ((Get-MasterPin $pinned).Ref -eq 'ghcr.io/o/r/master' -and (Get-MasterPin $pinned).Digest -eq $D)
Check 'Pin-Zeile exakt' ($pinned -match [regex]::Escape("  master: &img_master `${LA_MASTER_IMAGE:-ghcr.io/o/r/master@$D}"))
Check 'zurueck auf neutral = Ausgangstext' ((Set-MasterPin $pinned) -ceq $base)
Check 'nur die Pin-Zeile geaendert' ((($pinned -split "`n") | Where-Object { ($base -split "`n") -notcontains $_ }).Count -eq 1)
Check 'CRLF bleibt erhalten' ((Set-MasterPin ($base -replace "`n", "`r`n") -Ref 'ghcr.io/o/r/master' -Digest $D) -match "@$D\}`r`n")
Check 'lokales Register mit Port' ((Get-MasterPin (Set-MasterPin $base -Ref '127.0.0.1:5099/di5/master' -Digest $D)).Ref -eq '127.0.0.1:5099/di5/master')
Check 'Tag statt Digest = Abbruch' (Throws { Get-MasterPin ($base.Replace($MasterPinNeutral, '${LA_MASTER_IMAGE:-ghcr.io/o/r/master:v1}')) })
Check 'Grossbuchstaben = Abbruch' (Throws { Set-MasterPin $base -Ref 'ghcr.io/O/r/master' -Digest $D })
Check 'kurzer Digest = Abbruch' (Throws { Set-MasterPin $base -Ref 'ghcr.io/o/r/master' -Digest 'sha256:abc' })
Check 'fehlende Zeile = Abbruch' (Throws { Get-MasterPin ($base -replace '  master: &img_master [^\n]*\n', '') })
Check 'doppelte Zeile = Abbruch' (Throws { Get-MasterPin ($base + "  master: &img_master $MasterPinNeutral`n") })
Check 'freie Vorgabe = Abbruch' (Throws { Get-MasterPin ($base.Replace($MasterPinNeutral, '${LA_MASTER_IMAGE:-x}')) })
$real = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "..\..\$MasterComposeRel"), $u8)
Check 'echte compose.yml lesbar' (-not (Throws { Get-MasterPin $real }))

Write-Host 'A: Herkunft (Test-MasterRevision) im Wegwerf-Repo' -ForegroundColor Cyan
Clear-GitEnvironment
$repo = Join-Path ([System.IO.Path]::GetTempPath()) ('rit_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Force $repo | Out-Null
function TGit { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { $o = & git -C $repo -c user.name=Test -c user.email=test@example.com -c core.autocrlf=false @args 2>$null } finally { $ErrorActionPreference = $prev }; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ')" }; $o }
function Put([string]$Rel, [string]$Text) { $p = Join-Path $repo $Rel; New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null; [System.IO.File]::WriteAllText($p, $Text, $u8) }
try {
    Initialize-GitSandbox $repo
    Put $MasterComposeRel $base; Put 'provisioning/a.sh' "echo a`n"; Put 'packages/p/x.md' "x`n"; Put '.gitattributes' "* text eol=lf`n"; Put 'docs/d.md' "d`n"   # lint-ignore: Pfade im Wegwerf-Repo
    TGit add -A | Out-Null; TGit commit -q -m base | Out-Null
    $r0 = (TGit rev-parse HEAD).Trim()
    Put $MasterComposeRel $pinned; TGit commit -q -am pin | Out-Null; TGit tag t-ok | Out-Null
    Check 'nur Pin seit dem Bau = gruen' ((Test-MasterRevision $repo $r0 't-ok').Count -eq 0) ((Test-MasterRevision $repo $r0 't-ok') -join '; ')
    Put 'docs/d.md' "d2`n"; TGit commit -q -am docs | Out-Null; TGit tag t-docs | Out-Null   # lint-ignore: Pfade im Wegwerf-Repo
    Check 'Doku ausserhalb des Release-Baums = gruen' ((Test-MasterRevision $repo $r0 't-docs').Count -eq 0)
    Put 'provisioning/a.sh' "echo b`n"; TGit commit -q -am code | Out-Null; TGit tag t-code | Out-Null
    Check 'Installer-Datei geaendert = rot' ((Test-MasterRevision $repo $r0 't-code').Count -eq 1)
    TGit checkout -q -b side $r0 | Out-Null
    Put $MasterComposeRel ($pinned + "# mehr`n"); TGit commit -q -am more | Out-Null; TGit tag t-more | Out-Null
    Check 'compose.yml mehr als die Pin-Zeile = rot' ((Test-MasterRevision $repo $r0 't-more').Count -eq 1)
    Check 'Revision kein Vorfahr = rot' ((Test-MasterRevision $repo (TGit rev-parse t-code).Trim() 't-more').Count -eq 1)
    Check 'Revision unbekannt = rot' ((Test-MasterRevision $repo ('0' * 40) 't-ok').Count -eq 1)
    Check 'ohne origin/main = rot' ((Test-HeadIsRemoteMain $repo).Count -eq 1)
    TGit update-ref refs/remotes/origin/main HEAD | Out-Null
    Check 'HEAD = origin/main = gruen' ((Test-HeadIsRemoteMain $repo).Count -eq 0)
    TGit update-ref refs/remotes/origin/main t-code | Out-Null
    Check 'HEAD nicht origin/main = rot' ((Test-HeadIsRemoteMain $repo).Count -eq 1)
} finally { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host 'A: SHA256SUMS (Test-ReleaseSums)' -ForegroundColor Cyan
$sd = Join-Path ([System.IO.Path]::GetTempPath()) ('ris_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Force $sd | Out-Null
try {
    $tb = 'n8n-life-agents-v9.9.9.tar.gz'
    foreach ($n in @($tb) + $ReleaseSumAssets) { [System.IO.File]::WriteAllText((Join-Path $sd $n), "inhalt $n`n", $u8) }
    $lines = foreach ($n in @($tb) + $ReleaseSumAssets) { "$(Get-FileSha256 (Join-Path $sd $n))  $n" }
    [System.IO.File]::WriteAllText((Join-Path $sd 'SHA256SUMS'), ($lines -join "`n") + "`n", $u8)
    Check 'passende Liste = gruen' ((Test-ReleaseSums $sd $tb).Count -eq 0)
    [System.IO.File]::WriteAllText((Join-Path $sd 'SHA256SUMS'), (($lines | Select-Object -First 2) -join "`n") + "`n", $u8)
    Check 'DMG/EXE fehlen in der Liste = rot' ((Test-ReleaseSums $sd $tb).Count -eq 1)
    [System.IO.File]::WriteAllText((Join-Path $sd 'SHA256SUMS'), ($lines -join "`n") + "`n", $u8)
    [System.IO.File]::WriteAllText((Join-Path $sd 'compose.yml'), "anders`n", $u8)
    Check 'geaenderte compose.yml = rot' ((Test-ReleaseSums $sd $tb).Count -eq 1)
    Remove-Item (Join-Path $sd 'lifeagents.dmg')
    Check 'fehlendes Asset = rot' ((Test-ReleaseSums $sd $tb).Count -ge 1)
} finally { Remove-Item -LiteralPath $sd -Recurse -Force -ErrorAction SilentlyContinue }

if ($MasterImage) {
    # Ganze Kette gegen ein echtes, schon gebautes master-Image (build_master_image.ps1 -Registry <lokal> -NoPin auf HEAD):
    # Pin-Commit als loses Objekt (commit-tree, kein Branch, keine Hooks), dann Test-ReleaseCompose wie sign_release.ps1.
    Write-Host "C: Kette mit $MasterImage" -ForegroundColor Cyan
    $root = (& git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
    $mRef, $mDig = $MasterImage -split '@', 2
    $cw = Join-Path ([System.IO.Path]::GetTempPath()) ('ric_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Force $cw | Out-Null
    function New-LooseCommit([hashtable]$Files) {
        $env:GIT_INDEX_FILE = Join-Path $cw 'index'
        try {
            & git -C $root read-tree HEAD
            foreach ($k in $Files.Keys) {
                $f = Join-Path $cw 'blob'; [System.IO.File]::WriteAllText($f, $Files[$k], $u8)
                $b = (& git -C $root hash-object -w --no-filters $f).Trim()
                & git -C $root update-index --add --cacheinfo "100644,$b,$k"
            }
            $t = (& git -C $root write-tree).Trim()
        } finally { Remove-Item env:GIT_INDEX_FILE }
        return (& git -C $root -c user.name=Test -c user.email=test@example.com commit-tree $t -p HEAD -m 'di5 chain test').Trim()
    }
    try {
        $headCompose = (& git -C $root show "HEAD:$MasterComposeRel") -join "`n"
        $pinnedTxt = (Set-MasterPin $headCompose -Ref $mRef -Digest $mDig) + "`n"
        $asset = Join-Path $cw 'compose.yml'; [System.IO.File]::WriteAllText($asset, $pinnedTxt, $u8)
        $ok = New-LooseCommit @{ $MasterComposeRel = $pinnedTxt }
        $r = Test-ReleaseCompose $root $ok $asset
        Check 'Pin-Commit nach dem Bau = gruen' ($r.Problems.Count -eq 0) ($r.Problems -join '; ')
        $bad = New-LooseCommit @{ $MasterComposeRel = $pinnedTxt; 'provisioning/di5_chain_extra.sh' = "echo x`n" }   # lint-ignore: Wegwerf-Objekt
        $r = Test-ReleaseCompose $root $bad $asset
        Check 'Installer seit dem Bau geaendert = rot' ($r.Problems.Count -eq 1 -and ($r.Problems -join ' ') -match 'neu bauen') ($r.Problems -join '; ')
        $wrong = (Set-MasterPin $headCompose -Ref $mRef -Digest ('sha256:' + ('1' * 64))) + "`n"
        $wc = New-LooseCommit @{ $MasterComposeRel = $wrong }
        [System.IO.File]::WriteAllText($asset, $wrong, $u8)
        $r = Test-ReleaseCompose $root $wc $asset
        Check 'Digest nicht im Register = rot' ($r.Problems.Count -ge 1) ($r.Problems -join '; ')
        $r = Test-ReleaseCompose $root $ok $asset
        Check 'Asset != Datei des Tags = rot' ($r.Problems.Count -eq 1 -and ($r.Problems -join ' ') -match 'weicht') ($r.Problems -join '; ')
        [System.IO.File]::WriteAllText($asset, $headCompose + "`n", $u8)
        $r = Test-ReleaseCompose $root 'HEAD' $asset
        Check 'ohne Release-Pin = rot' (($r.Problems -join ' ') -match 'keinen Release-Pin') ($r.Problems -join '; ')
    } finally { Remove-Item -LiteralPath $cw -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($Registry) {
    Write-Host "B: Register $Registry" -ForegroundColor Cyan
    $bb = ([regex]::Match($real, '(?m)^\s+busybox:\s*&img_busybox\s+(\S+)')).Groups[1].Value
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('rib_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Force $work | Out-Null
    function Build-Test([string]$Name, [string]$Platforms, [string[]]$Labels) {
        [System.IO.File]::WriteAllText((Join-Path $work 'Dockerfile'), "FROM $bb`nRUN echo $Name > /n`n", $u8)
        $meta = Join-Path $work "$Name.json"
        $a = @('buildx', 'build', '-q', '--platform', $Platforms, '--provenance=false', '--sbom=false', '--metadata-file', $meta,
            '--output', 'type=image,push=true', '-t', "$Registry/di5test/${Name}:t")
        foreach ($l in $Labels) { $a += @('--label', $l) }
        $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & docker @a $work *> $null } finally { $ErrorActionPreference = $prev }
        if ($LASTEXITCODE -ne 0) { throw "Test-Image $Name nicht baubar." }
        return ([System.IO.File]::ReadAllText($meta, $u8) | ConvertFrom-Json).'containerimage.digest'
    }
    try {
        $rev = 'org.opencontainers.image.revision=' + ('c' * 40)
        $ok = Build-Test 'multi' 'linux/amd64,linux/arm64' @($rev, 'org.opencontainers.image.version=v9.9.9')
        $rep = Get-MasterImageReport "$Registry/di5test/multi" $ok
        Check 'Multi-Arch mit Label = gruen' ($rep.Ok -and $rep.Revision -eq ('c' * 40) -and $rep.Version -eq 'v9.9.9') ($rep.Problems -join '; ')
        $one = Build-Test 'single' 'linux/amd64' @($rev)
        $rep = Get-MasterImageReport "$Registry/di5test/single" $one
        Check 'nur eine Plattform (kein Index) = rot' ((-not $rep.Ok) -and ($rep.Problems -join ' ') -match 'Multi-Arch') ($rep.Problems -join '; ')
        $arm = Build-Test 'armonly' 'linux/arm64,linux/arm/v7' @($rev)
        $rep = Get-MasterImageReport "$Registry/di5test/armonly" $arm
        Check 'Index ohne amd64 = rot' ((-not $rep.Ok) -and ($rep.Problems -join ' ') -match 'amd64') ($rep.Problems -join '; ')
        $nol = Build-Test 'nolabel' 'linux/amd64,linux/arm64' @()
        $rep = Get-MasterImageReport "$Registry/di5test/nolabel" $nol
        Check 'ohne Revision-Label = rot' ((-not $rep.Ok) -and ($rep.Problems -join ' ') -match 'revision') ($rep.Problems -join '; ')
        $rep = Get-MasterImageReport "$Registry/di5test/multi" ('sha256:' + ('0' * 64))
        Check 'Digest nicht im Register = rot' (-not $rep.Ok) ($rep.Problems -join '; ')
        $rep = Get-MasterImageReport "$Registry/di5test/fehlt" $ok
        Check 'Pfad nicht im Register = rot' (-not $rep.Ok)
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ("{0} ok, {1} Fehler" -f $passed, $failed) -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
exit $failed
