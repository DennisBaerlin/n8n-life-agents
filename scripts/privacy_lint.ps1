#Requires -Version 5.1
# privacy_lint.ps1 -- keine echten Owner-/Familiendaten in allem, was das (oeffentliche) Repo verlaesst (hartes Gate).
# Zwei Regel-Klassen:
#   (A) Generisch, laeuft ueberall (auch CI): private IPv4 (10/8, 172.16/12, 192.168/16) ausserhalb der Beispiel-
#       Allowlist unten, Heimnetz-Hostnamen (*.fritz.box, *.myfritz.net ausser dem Doku-Platzhalter) und
#       Windows-Benutzerpfade (X:\Users\<name>). Beispiele in Doku/Installer nur aus der Allowlist nehmen.
#   (B) Denylist, nur lokal: .local/privacy_denylist.txt (gitignored, je Zeile ein Literal, '#' = Kommentar) traegt die
#       echten Werte (Namen, Geburtsdaten, Mail, ...) -- sie duerfen selbst nie ins Repo. Dazu kommen automatisch alle
#       *CHAT_ID-Werte aus .env (OWNER_CHAT_ID, TEST_TELEGRAM_CHAT_ID). Treffer: Gross-/Kleinschreibung egal; Begriffe,
#       die mit Buchstabe/Ziffer beginnen und enden, nur als ganzes Wort (sonst trifft ein kurzer Name jedes laengere Wort, das ihn enthaelt).
#       Liste und .env kommen immer aus dem Haupt-Checkout (git-common-dir), auch im Worktree: eine Kopie wuerde veralten.
#       Fehlt die Liste, prueft das Lint allein (A): Beitraege von aussen und CI duerfen sie nicht voraussetzen. Gesperrt wird
#       nur mit echter Chat-ID in .env (Owner-Maschine). Ein Owner-Klon ganz ohne .env ist von einem Fremd-Klon nicht zu unterscheiden.
# Modi (ein Fakt, eine Adresse: die Hook-Verdrahtung steht in .pre-commit-config.yaml / .claude/hooks/dev_cycle_guard.ps1):
#   (ohne)              getrackter Baum per git grep, auch generierte Dateien (docs/site/public, workflows) -- die werden
#                       publiziert. Ausnahmen ($exempt): nur einzeln benannte Dateien mit Grund, nie Verzeichnisse/Muster.
#                       Binaerdateien: PDF und Excel werden als Text gelesen; Bilder kann das Lint nicht lesen, darum
#                       duerfen Binaerdateien nur in den Ablagen von $binaryAllow liegen (deren Inhalt entsteht aus Skripten).
#   -MessageFile <f>    commit-msg: Message (alle Zeilen bis zur Scissors-Linie von `commit -v` -- `commit -F` speichert
#                       auch '#'-Zeilen) + Autor-/Committer-Identitaet (git var GIT_AUTHOR_IDENT/GIT_COMMITTER_IDENT).
#   -TextFile <f>       beliebiger oeffentlicher Text (PR-/Issue-/Release-Body des Claude-Hooks).
#   -Outgoing           pre-push: Branch-Name, Message + Identitaeten jedes ausgehenden Commits (PRE_COMMIT_FROM_REF..PRE_COMMIT_TO_REF
#                       von prek, sonst @{push}..HEAD; nie fremde lokale Branches paralleler Sessions) und jeder lokale
#                       annotierte Tag (= Release-Notes), der vom gepushten Stand erreichbar ist (mit -AllTags: jeder) und
#                       dem Remote fehlt.
#                       Grenze: prek prueft je Push nur den ersten Ref mit neuen Commits und laesst einen reinen Tag-Push
#                       aus -> der Claude-Hook dev_cycle_guard.ps1 ruft -Outgoing zusaetzlich vor jedem `git push`.
# Ausgaben nennen nie den Treffer-Wert selbst, nur Quelle:Zeile (das Log soll den echten Wert nicht wiederholen).
# Exit-Code = Anzahl Fehler. Kein LLM, kein Substrat; nur -Outgoing fragt das Remote (git ls-remote).
param(
    [string]$MessageFile,
    [string]$TextFile,
    [switch]$Outgoing,
    [switch]$AllTags,  # mit -Outgoing: jeden lokalen annotierten Tag pruefen, der dem Remote fehlt (git push --tags/--all)
    [string]$ExtraTermsFile   # weitere Begriffe (je Zeile einer) fuer diesen Lauf, Vorschau von refresh_privacy_denylist.ps1
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }
# git grep mit Fehler-Check: Exit 1 = kein Treffer, > 1 = Aufruf kaputt -> darf nie still als "sauber" durchgehen.
# Argumente als Array ohne Splatting (@): PS 5.1 macht aus einem gesplatteten '-w' sonst einen Parameternamen.
function Invoke-GitGrep([string[]]$GrepArgs) {
    $out = & git (@('grep') + $GrepArgs)
    if ($LASTEXITCODE -gt 1) { Fail "git grep fehlgeschlagen (Exit $LASTEXITCODE): git grep $($GrepArgs -join ' ')" }
    @($out | Where-Object { $_ })
}
# Text aus einer Binaerdatei: PDF roh (unsere Test-PDFs sind unkomprimiert), Excel/Word = die XML-Teile des ZIP.
function Get-BinaryText([string]$Path) {
    if ($Path -match '(?i)\.pdf$') { return [System.Text.Encoding]::GetEncoding('ISO-8859-1').GetString([System.IO.File]::ReadAllBytes($Path)) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $sb = New-Object System.Text.StringBuilder
        foreach ($e in $zip.Entries) {
            if ($e.FullName -notmatch '\.xml$') { continue }
            $r = New-Object System.IO.StreamReader($e.Open(), $u8)
            try { [void]$sb.AppendLine($r.ReadToEnd()) } finally { $r.Dispose() }
        }
        return $sb.ToString()
    } finally { $zip.Dispose() }
}
# Sonstige git-Aufrufe der Text-Modi: Exit != 0 ist immer ein Fehler (sonst gilt ein kaputter Bereich als "sauber").
function Invoke-Git([string[]]$GitArgs) {
    $out = & git $GitArgs
    if ($LASTEXITCODE -ne 0) { Fail "git fehlgeschlagen (Exit $LASTEXITCODE): git $($GitArgs -join ' ')" }
    @($out)
}

# Beispiel-Adressen, die Doku/Installer/Tests verwenden duerfen (keine echte Owner-Infrastruktur).
$ipAllow = @('192.168.1.0', '192.168.1.7', '192.168.1.50', '192.168.178.0', '192.168.178.10', '192.168.178.20', '192.168.178.30')
$hostAllow = @('deine-domain.myfritz.net')
$exempt = @()
# Die Regexe gelten fuer PowerShell -match (case-insensitiv) UND git grep -E -i.
$ipRegex = '\b(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}|192\.168)\.[0-9]{1,3}\.[0-9]{1,3}\b'
$hostRegex = '\b[a-z0-9-]+\.(fritz\.box|myfritz\.net)\b'
$pathRegex = '\b[a-z]:[\\/]+users[\\/]+[a-z]'
$wordTermRegex = '^\w(.*\w)?$'
$pathspec = @('.') + @($exempt | ForEach-Object { ":(exclude)$_" })
$binaryRegex = '(?i)\.(pdf|xlsx|xls|docx|png|webp|jpe?g|gif|ico|zip|gz|tgz|gpg)$'
$binaryAllow = @('docs/site/public/img/', 'docs/site/static/img/', 'packages/core/build/stickers/', 'packages/core/build/bot_profile/','provisioning/keys/', 'tests/mock_telegram/docs/')

# Das eine Regex aus der Begriffsliste (Baum und Text-Modi): Wort-Begriffe mit Grenze, der Rest als Teilstring. Grenze = kein
# Buchstabe, keine Ziffer: '_' trennt also (sonst bliebe ein Bezeichner wie name_abschnitt unerkannt). Endet ein Begriff auf
# einen Buchstaben, treffen auch Besitz- und Beugungsformen. Nur diese festen Endungen, kein offener Wortstamm: ein kurzer
# Vorname steckt sonst in vielen Alltagswoertern.
$wordEndings = "(?:s|es|n|ns|['" + [char]0x2019 + "]s?)?"
function New-DenyRegex([string[]]$Terms) {
    $alts = @($Terms | ForEach-Object {
        $e = [regex]::Escape($_)
        if ($_ -match $wordTermRegex) {
            $ending = if ($_ -match '\p{L}$') { $wordEndings } else { '' }
            "(?<![\p{L}\p{N}])$e$ending(?![\p{L}\p{N}])"
        } else { $e }
    })
    if ($alts.Count -eq 0) { return $null }
    New-Object System.Text.RegularExpressions.Regex(($alts -join '|'), 'IgnoreCase')
}
# Prueft einen Text zeilenweise gegen (A) + (B); $Label = Quelle in der Meldung (nie der Wert selbst).
function Test-PrivacyText([string]$Text, [string]$Label, $DenyRx) {
    $n = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $n++
        foreach ($m in [regex]::Matches($line, $ipRegex)) {
            if ($ipAllow -notcontains $m.Value) { Fail "private IP (keine Beispiel-Adresse) in ${Label}:$n" }
        }
        foreach ($m in [regex]::Matches($line, $hostRegex, 'IgnoreCase')) {
            if ($hostAllow -notcontains $m.Value.ToLowerInvariant()) { Fail "Heimnetz-Hostname in ${Label}:$n" }
        }
        if ($line -match $pathRegex) { Fail "Windows-Benutzerpfad in ${Label}:$n" }
        if ($DenyRx -and $DenyRx.IsMatch($line)) { Fail "Wert aus .local/privacy_denylist.txt bzw. .env in ${Label}:$n" }
    }
}

# --- Selbst-Asserts: stirbt die Erkennung still, bricht der Lint. Die Proben werden zur Laufzeit zusammengesetzt,
#     damit diese Datei selbst keinen Treffer enthaelt.
$probeIp = '192.168.' + '178.' + '99'
$probeHost = 'nas.' + 'fritz.box'
$probePath = 'C:' + '\Users\' + 'probe'
if ("reverse_proxy ${probeIp}:5678" -notmatch $ipRegex -or $ipAllow -contains $Matches[0]) { Fail 'Selbst-Assert: IP-Erkennung defekt' }
if (('10.' + '0.0.12') -notmatch $ipRegex) { Fail 'Selbst-Assert: IP-Erkennung 10/8 defekt' }
if ("ssh root@$probeHost" -notmatch $hostRegex) { Fail 'Selbst-Assert: Host-Erkennung defekt' }
if ($probePath -notmatch $pathRegex) { Fail 'Selbst-Assert: Pfad-Erkennung defekt' }
$probeRx = New-DenyRegex @(('Pro' + 'bewort'), ('x@' + 'probe.test'))
if (-not $probeRx.IsMatch('Hallo PROBEWORT.') -or $probeRx.IsMatch('Probeworte') -or -not $probeRx.IsMatch('<x@probe.test>') -or
    -not $probeRx.IsMatch('Probeworts Akte') -or -not $probeRx.IsMatch('probewort_key') -or $probeRx.IsMatch('Probewortliste')) {
    Fail 'Selbst-Assert: Denylist-Regex der Text-Modi defekt'
}

# --- Begriffe (B): Denylist + *CHAT_ID-Werte aus .env, inkl. Owner-Maschinen-Guard -------------------------------
$terms = @()
$MainRoot = $RepoRoot
$common = & git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -eq 0 -and $common) { $MainRoot = Split-Path ([string]$common) -Parent }
$envPath = Join-Path $MainRoot '.env'
if (Test-Path $envPath) {
    foreach ($l in [System.IO.File]::ReadAllLines($envPath, $u8)) {
        if ($l -match '^\s*[A-Z0-9_]*CHAT_ID\s*=\s*["'']?-?([0-9]{6,})["'']?\s*$') { $terms += $Matches[1] }
    }
}
$ownerMachine = $terms.Count -gt 0
$deny = Join-Path $MainRoot '.local\privacy_denylist.txt'
if (Test-Path $deny) {
    $terms += @([System.IO.File]::ReadAllLines($deny, $u8) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
} elseif ($ownerMachine) {
    Fail ".local/privacy_denylist.txt fehlt im Haupt-Checkout, aber .env traegt eine echte Chat-ID (Owner-Maschine) -> ohne Liste waere die Pruefung blind."
} else {
    Write-Host '  [skip] .local/privacy_denylist.txt fehlt -> nur generische Pruefung' -ForegroundColor DarkGray
}
# Dazu die aus der Instanz erzeugte Liste (scripts/refresh_privacy_denylist.ps1) und die Vorschau-Begriffe dieses Laufs.
foreach ($extra in @((Join-Path $MainRoot '.local\privacy_denylist.generated.txt'), $ExtraTermsFile)) {
    if ($extra -and (Test-Path $extra)) {
        $terms += @([System.IO.File]::ReadAllLines($extra, $u8) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
}
$terms = @($terms | Sort-Object -Unique)

Push-Location $RepoRoot
try {
    if ($MessageFile) {
        # --- commit-msg: Message + Identitaet ---------------------------------------------------------------------
        $denyRx = New-DenyRegex $terms
        $msg = @()
        foreach ($l in [System.IO.File]::ReadAllLines($MessageFile, $u8)) {
            if ($l -match '^# -+ >8 -+$') { break }   # `git commit -v`: darunter folgt der Diff (prueft der Baum-Modus)
            $msg += $l
        }
        Test-PrivacyText ($msg -join "`n") 'Commit-Message' $denyRx
        foreach ($v in 'GIT_AUTHOR_IDENT', 'GIT_COMMITTER_IDENT') {
            $ident = (Invoke-Git @('var', $v)) -join ' '
            Test-PrivacyText ($ident -replace '\s+\d+\s+[+-]\d{4}$', '') $v $denyRx
        }
    } elseif ($TextFile) {
        # --- oeffentlicher Text (gh-Body) ---------------------------------------------------------------------------
        Test-PrivacyText ([System.IO.File]::ReadAllText($TextFile, $u8)) 'Text' (New-DenyRegex $terms)
    } elseif ($Outgoing) {
        # --- pre-push: ausgehende Commits + neue annotierte Tags ----------------------------------------------------
        $denyRx = New-DenyRegex $terms
        $from = $env:PRE_COMMIT_FROM_REF; $to = $env:PRE_COMMIT_TO_REF
        $remote = if ($env:PRE_COMMIT_REMOTE_NAME) { $env:PRE_COMMIT_REMOTE_NAME } else { 'origin' }
        if ($to -and $from -and $from -notmatch '^0+$') { $revArgs = @("$from..$to") }
        elseif ($to) { $revArgs = @($to, '--not', "--remotes=$remote") }
        else {
            & git rev-parse -q --verify '@{push}' *> $null
            $revArgs = if ($LASTEXITCODE -eq 0) { @('@{push}..HEAD') } else { @('HEAD', '--not', "--remotes=$remote") }
        }
        $tip = if ($to) { $to } else { 'HEAD' }
        # Branch-Namen sind oeffentlich wie Commit-Texte: Zielname des Pushs und aktueller Branch.
        $current = @(& git symbolic-ref --short -q HEAD)
        foreach ($ref in @($env:PRE_COMMIT_REMOTE_BRANCH) + $current) {
            if ($ref) { Test-PrivacyText ([string]$ref) 'Branch-Name' $denyRx }
        }
        # Datensatz je Commit: Hash US Autor US Committer US Body RS (Steuerzeichen statt Zeilen -> Body darf alles enthalten).
        $log = (Invoke-Git (@('log', '--format=%h%x1f%an <%ae>%x1f%cn <%ce>%x1f%B%x1e') + $revArgs)) -join "`n"
        $count = 0
        foreach ($rec in ($log -split [char]0x1e)) {
            $f = $rec.Trim("`n", "`r") -split [char]0x1f
            if ($f.Count -lt 4) { continue }
            $count++
            Test-PrivacyText $f[1] "Commit $($f[0]) Autor" $denyRx
            Test-PrivacyText $f[2] "Commit $($f[0]) Committer" $denyRx
            Test-PrivacyText $f[3] "Commit $($f[0]) Message" $denyRx
        }
        # Tags: nur annotierte, vom gepushten Stand erreichbare (alte Tags fremder Historie zaehlen nicht), die dem Remote fehlen.
        $onRemote = @(Invoke-Git @('ls-remote', '--tags', '--refs', $remote) | ForEach-Object { ($_ -split "`t")[-1] -replace '^refs/tags/', '' })
        $tags = 0
        $tagArgs = if ($AllTags) { @('tag') } else { @('tag', '--merged', $tip) }
        foreach ($t in (Invoke-Git $tagArgs)) {
            if (-not $t -or $onRemote -contains $t) { continue }
            if (((Invoke-Git @('cat-file', '-t', "refs/tags/$t")) -join '') -ne 'tag') { continue }
            $tags++
            Test-PrivacyText $t "Tag-Name $t" $denyRx
            $tagger = (Invoke-Git @('for-each-ref', "refs/tags/$t", '--format=%(taggername) %(taggeremail)')) -join ' '
            Test-PrivacyText $tagger "Tag $t Tagger" $denyRx
            Test-PrivacyText ((Invoke-Git @('for-each-ref', "refs/tags/$t", '--format=%(contents)')) -join "`n") "Tag $t Message" $denyRx
        }
        Write-Host "  geprueft: $count ausgehende(r) Commit(s), $tags neue(r) Tag(s)" -ForegroundColor DarkGray
    } else {
        # --- (A1) private IPs ausserhalb der Allowlist --------------------------------------------------------------
        foreach ($h in (Invoke-GitGrep (@('-n', '-I', '-o', '-E', $ipRegex, '--') + $pathspec))) {
            $ip = ($h -split ':')[-1]
            if ($ipAllow -notcontains $ip) { Fail "private IP $ip ist keine Beispiel-Adresse (Allowlist in privacy_lint.ps1): $h" }
        }
        # --- (A2) Heimnetz-Hostnamen --------------------------------------------------------------------------------
        foreach ($h in (Invoke-GitGrep (@('-n', '-I', '-o', '-i', '-E', $hostRegex, '--') + $pathspec))) {
            $hn = ($h -split ':')[-1]
            if ($hostAllow -notcontains $hn.ToLowerInvariant()) { Fail "Heimnetz-Hostname ${hn}: $h" }
        }
        # --- (A3) Windows-Benutzerpfade -----------------------------------------------------------------------------
        foreach ($h in (Invoke-GitGrep (@('-n', '-I', '-i', '-E', $pathRegex, '--') + $pathspec))) { Fail "Windows-Benutzerpfad: $h" }
        # --- (B) Denylist + Chat-IDs --------------------------------------------------------------------------------
        # git grep -i faltet nur ASCII -> Begriffe mit Umlaut zusaetzlich in gross/klein/Titel (die Text-Modi falten per .NET).
        $gTerms = @($terms | ForEach-Object {
            $_
            if ($_ -match '[^\x00-\x7F]') { $_.ToUpperInvariant(); $_.ToLowerInvariant(); $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant() }
        } | Sort-Object -Unique -CaseSensitive)
        # --- (C) Binaerdateien --------------------------------------------------------------------------------------
        $denyAll = New-DenyRegex $terms
        foreach ($b in @(Invoke-Git @('ls-files') | Where-Object { $_ -match $binaryRegex -and $exempt -notcontains $_ })) {
            if (-not @($binaryAllow | Where-Object { $b.StartsWith($_) })) { Fail "Binaerdatei ausserhalb der erlaubten Ablagen (Inhalt nicht pruefbar): $b"; continue }
            if ($denyAll -and $b -match '(?i)\.(pdf|xlsx|docx)$' -and (Test-Path -LiteralPath $b)) {
                if ($denyAll.IsMatch((Get-BinaryText (Resolve-Path -LiteralPath $b).Path))) { Fail "Wert aus .local/privacy_denylist.txt bzw. .env in Binaerdatei: $b" }
            }
        }
        # git grep sucht nur vor (Teilstring), ueber Grenze und Endungen entscheidet dasselbe Regex wie in den Text-Modi.
        if ($gTerms.Count -gt 0) {
            $denyRx = New-DenyRegex $terms
            $pat = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.File]::WriteAllLines($pat, [string[]]$gTerms, $u8)
                foreach ($h in (Invoke-GitGrep (@('-n', '-I', '-i', '-F', '-f', $pat, '--') + $pathspec))) {
                    if ($h -match '^(.*?):(\d+):(.*)$' -and $denyRx.IsMatch($Matches[3])) {
                        Fail "Wert aus .local/privacy_denylist.txt bzw. .env: $($Matches[1]):$($Matches[2])"
                    }
                }
            } finally { Remove-Item -LiteralPath $pat -ErrorAction SilentlyContinue }
        }
    }
} finally { Pop-Location }

if ($fails -eq 0) { Write-Host 'privacy_lint: OK' -ForegroundColor Green }
exit $fails
