#Requires -Version 5.1
# reset_dev_instance.ps1 — die Dev-Instanz (Proxmox-LXC im LAN) clean machen und den LOKALEN Repo-Stand
# (inkl. nicht committeter Aenderungen) als frischen Install-Baum bereitlegen. Die Installation selbst
# faehrt der Owner danach INTERAKTIV im Container (Look-and-feel-Test des Nutzer-Installationsprozesses):
#   bash /root/lifeagents-dev/install-dev.sh
#
# Ablauf: (1) Vorab-Pruefung (SSH, freier Platz) -> (2) Baum packen wie das Release (`git archive`, dieselbe
# Pathspec wie .github/workflows/release.yml, aber aus einer KOPIE des Git-Index inkl. Working-Tree ->
# gitignorte Dateien wie .env/.local/.claude koennen strukturell nicht hinein; + dasselbe No-Secrets-Gate)
# -> (3) scp + SHA256-Abgleich -> (4) im Container: einmalig /etc/lifeagents/*.env nach saved-env/ retten,
# Shell-Syntax pruefen, bestehende Instanz per `provision.sh --uninstall --purge-data --yes` (aus dem NEUEN
# Baum) abbauen, Rest-Check, neuen Baum nach src/ tauschen (alter wird geloescht) + install-dev.sh schreiben.
#
# WARUM kein Build: der getrackte Baum ist bereits gebaut und deploybar (der Build ist deterministisch, ein Lauf ohne
# Def-Aenderung aendert nichts) -> gebaut wird nur, wenn Build-Defs geaendert wurden (Root-CLAUDE.md *Entwicklungszyklus*).
# WARUM scp statt Pipe: PS 5.1 kodiert Native-Pipes als Text -> ein tar.gz ueber `| ssh` waere korrupt.
# WARUM install-dev.sh: install.sh laedt immer ein GitHub-Release; der Wrapper macht exakt dessen letzten
# Schritt (RELEASE_TAG exportieren, --profile release als Default, exec provision.sh) auf dem lokalen Baum.
#
# Ziel aus .env (gitignored): DEV_INSTANCE_HOST (Pflicht), DEV_INSTANCE_USER (Default root),
# DEV_INSTANCE_SSH_KEY (Pfad zum privaten Key; ~ erlaubt). Nur Key-Login (BatchMode).
#
# -KeepInstance (Install-UX-Phase 7): denselben Stand bereitlegen, aber die bestehende Instanz NICHT abbauen (kein
# Abbau, kein Rest-Check) — zum Testen des Update-Pfads (install-dev.sh laeuft dann als Bestands-Lauf).
#
# Usage:
#   .\scripts\reset_dev_instance.ps1                # clean + aktuellen Stand bereitlegen
#   .\scripts\reset_dev_instance.ps1 -KeepInstance  # Stand auf die bestehende Instanz legen (Update-Pfad testen)
#   .\scripts\reset_dev_instance.ps1 -Verbose       # volle Container-Ausgabe (Abbau-Log)
param(
    [switch]$KeepInstance,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel

$RemoteDir   = '/root/lifeagents-dev'
$MinFreeMb   = 500
# Dieselbe Allowlist-Pathspec wie release.yml (`git archive … HEAD provisioning packages .gitattributes`).
$ReleasePaths = @('provisioning', 'packages', '.gitattributes')
# Dasselbe No-Secrets-Gate-Muster wie release.yml.
$SecretPathRegex = '(?i)((^|/)(\.env|\.local/|\.claude/|\.git/)|\.(key|pem)$|(^|/)id_rsa)'

# --- .env laden (gleiche Mechanik wie die uebrigen scripts/-Treiber) ---------
Get-Content "$RepoRoot\.env" | ForEach-Object {
    if ($_ -match '^\s*([^#\s][^=]*)=(.*)$') {
        Set-Variable -Name $Matches[1].Trim() -Value $Matches[2].Trim() -Scope Script
    }
}
function Get-EnvValue([string]$name) {
    $v = Get-Variable $name -ValueOnly -Scope Script -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v.Trim()
}

# Invoke-Native — natives Tool aufrufen, stdout+stderr + Exit-Code einsammeln (wie bootstrap_test_n8n.ps1).
# EAP lokal auf 'Continue' (PS-5.1-Quirk: native stderr unter 'Stop' + 2>&1 wuerde als terminierender
# NativeCommandError werfen).
function Invoke-Native {
    param([string]$Exe, [string[]]$CmdArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @CmdArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Code = $code; Output = @($out) }
}

$devHost = Get-EnvValue 'DEV_INSTANCE_HOST'
$devUser = Get-EnvValue 'DEV_INSTANCE_USER'; if (-not $devUser) { $devUser = 'root' }
$devKey  = Get-EnvValue 'DEV_INSTANCE_SSH_KEY'
if (-not $devHost) { throw "DEV_INSTANCE_HOST fehlt in .env (siehe .env.example)." }
if (-not $devKey)  { throw "DEV_INSTANCE_SSH_KEY fehlt in .env (siehe .env.example)." }
if ($devKey.StartsWith('~')) { $devKey = Join-Path $HOME $devKey.Substring(1).TrimStart('/', '\') }
if (-not (Test-Path $devKey)) { throw "SSH-Key nicht gefunden: $devKey" }
$target  = "$devUser@$devHost"
$sshOpts = @('-i', $devKey, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')

function Invoke-Remote([string]$cmd) {
    return Invoke-Native ssh ($sshOpts + @($target, $cmd))
}

# --- (1) Vorab-Pruefung ------------------------------------------------------
Write-Host "Ziel: $target"
$r = Invoke-Remote "mkdir -p $RemoteDir && chmod 700 $RemoteDir && df -Pm / | awk 'NR==2{print `$4}'"
if ($r.Code -ne 0) { throw "SSH zum Ziel fehlgeschlagen (Exit $($r.Code)): $($r.Output -join "`n")" }
$freeMb = [int](($r.Output | Select-Object -Last 1).ToString().Trim())
Write-Host "Freier Platz im Container: $freeMb MB"
if ($freeMb -lt $MinFreeMb) { throw "Zu wenig Platz im Container ($freeMb MB < $MinFreeMb MB) — erst aufraeumen." }

# --- (2) Baum packen (Working-Tree inkl. uncommitteter Aenderungen, release-identische Pathspec) ------
$head  = (git -C $RepoRoot rev-parse --short HEAD).Trim()
$dirty = @(git -C $RepoRoot status --porcelain -- @ReleasePaths).Count -gt 0
$tag   = "dev-$head" + $(if ($dirty) { '-dirty' } else { '' })

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "reset_dev_instance.$PID"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$tgz = Join-Path $tmpDir 'src.tgz'
$remoteScript = Join-Path $tmpDir 'reset.sh'
try {
    # Kopie des echten Index -> der Owner-Index bleibt unberuehrt; `add -A` respektiert .gitignore.
    $indexPath = (git -C $RepoRoot rev-parse --path-format=absolute --git-path index).Trim()
    $tmpIndex  = Join-Path $tmpDir 'index'
    Copy-Item $indexPath $tmpIndex
    $env:GIT_INDEX_FILE = $tmpIndex
    try {
        $r = Invoke-Native git (@('-C', $RepoRoot, 'add', '-A', '--') + $ReleasePaths)
        if ($r.Code -ne 0) { throw "git add (Temp-Index) fehlgeschlagen: $($r.Output -join "`n")" }
        $tree = (git -C $RepoRoot write-tree).Trim()
    } finally {
        Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue
    }

    $files = @(git -C $RepoRoot ls-tree -r --name-only $tree -- @ReleasePaths)
    $suspicious = @($files | Where-Object { $_ -match $SecretPathRegex })
    if ($suspicious.Count -gt 0) { throw "No-Secrets-Gate: verdaechtige Pfade im Baum — Abbruch:`n$($suspicious -join "`n")" }

    # core.autocrlf=false: LF wie das Release (Linux-Runner); sonst schmuggelt autocrlf=true CRLF in Dateien ohne eol-Attribut.
    $r = Invoke-Native git (@('-C', $RepoRoot, '-c', 'core.autocrlf=false', 'archive', '--format=tar.gz', '--prefix=lifeagents-src/', '-o', $tgz, $tree) + $ReleasePaths)
    if ($r.Code -ne 0) { throw "git archive fehlgeschlagen: $($r.Output -join "`n")" }
    $sha = (Get-FileHash -Algorithm SHA256 $tgz).Hash.ToLowerInvariant()
    Write-Host ("Stand: {0} ({1} Dateien, {2:N1} MB)" -f $tag, $files.Count, ((Get-Item $tgz).Length / 1MB))

    # --- (4) Container-Skript (LF, Platzhalter) ------------------------------
    $bash = @'
set -euo pipefail
export PATH="$PATH:/usr/local/bin:/usr/sbin:/sbin"
D='@@DIR@@'; SHA='@@SHA@@'; TAG='@@TAG@@'; KEEP='@@KEEP@@'
cd "$D"
echo "$SHA  src.tgz" | sha256sum -c --quiet - || { echo "[x] SHA256-Abgleich fehlgeschlagen (Upload korrupt)."; exit 10; }
echo "[+] Upload verifiziert (SHA256)."

# Einmalig: die bisherigen Installer-Eingaben retten (bleiben nur am Server, root-only).
if [ ! -d "$D/saved-env" ] && [ -d /etc/lifeagents ]; then
  install -d -m 700 "$D/saved-env"
  cp -a /etc/lifeagents/*.env "$D/saved-env/" 2>/dev/null || true
  if [ -f /etc/n8n/install.env ]; then cp -a /etc/n8n/install.env "$D/saved-env/n8n-install.env"; fi
  chmod 600 "$D/saved-env"/* 2>/dev/null || true
  echo "[+] Bisherige Eingaben gesichert -> $D/saved-env/ ($(ls "$D/saved-env" | tr '\n' ' '))"
fi

rm -rf "$D/src.new"; mkdir -p "$D/src.new"
# -m: mtime nicht uebernehmen (git archive eines Trees stempelt "jetzt" der PC-Uhr -> Clock-Skew-Warnflut).
tar -xzmf src.tgz -C "$D/src.new" --strip-components=1
for f in "$D/src.new"/provisioning/*.sh "$D/src.new"/provisioning/lib/*.sh "$D/src.new"/provisioning/templates/lifeagents.tpl; do
  bash -n "$f" || { echo "[x] Shell-Syntaxfehler: ${f#"$D/src.new/"}"; exit 11; }
done
echo "[+] Shell-Syntax ok."

if [ "$KEEP" = 1 ]; then
  echo "[*] -KeepInstance: bestehende Instanz bleibt (kein Abbau, kein Rest-Check)."
else
if [ -e /etc/n8n ] || [ -e /etc/lifeagents ] || [ -e /usr/local/bin/lifeagents ] || systemctl cat n8n.service >/dev/null 2>&1; then
  echo "[*] Bestehende Instanz abbauen (provision.sh --uninstall --purge-data --yes) ..."
  bash "$D/src.new/provisioning/provision.sh" --uninstall --purge-data --yes > "$D/uninstall.log" 2>&1 \
    || { echo "[x] Abbau fehlgeschlagen:"; tail -n 30 "$D/uninstall.log"; exit 12; }
  if [ "${VERBOSE:-0}" = 1 ]; then cat "$D/uninstall.log"; else grep -E '^\[(!|x)\]' "$D/uninstall.log" || true; fi
  echo "[+] Abbau fertig."
else
  echo "[*] Keine Instanz gefunden — Abbau uebersprungen."
fi

left=0
if [ -e /etc/systemd/system/lifeagents-firewall.service ]; then echo "[!] Rest: lifeagents-firewall.service"; left=1; fi
if [ -e /etc/systemd/system/n8n.service.d/lifeagents-firewall.conf ]; then echo "[!] Rest: n8n-Drop-in lifeagents-firewall.conf"; left=1; fi
if command -v nft >/dev/null 2>&1 && nft list table inet lifeagents >/dev/null 2>&1; then echo "[!] Rest: nft-Tabelle inet lifeagents"; left=1; fi
for p in /etc/n8n /etc/lifeagents /var/lib/n8n /usr/local/bin/lifeagents /usr/local/lib/lifeagents; do
  if [ -e "$p" ]; then echo "[!] Rest: $p"; left=1; fi
done
if systemctl cat n8n.service >/dev/null 2>&1; then echo "[!] Rest: n8n.service"; left=1; fi
if systemctl is-active -q postgresql@17-main; then
  db="$(runuser -u postgres -- psql -tAc "SELECT count(*) FROM pg_database WHERE datname='n8n'")"
  roles="$(runuser -u postgres -- psql -tAc "SELECT string_agg(rolname, ' ') FROM pg_roles WHERE rolname = 'n8n' OR rolname ~ '_(rw|ro)\$'")"
  if [ "$db" != 0 ]; then echo "[!] Rest: Datenbank n8n"; left=1; fi
  if [ -n "$roles" ]; then echo "[!] Rest: Rollen $roles"; left=1; fi
fi
[ "$left" -eq 0 ] || { echo "[x] Instanz nicht vollstaendig clean (siehe oben)."; exit 13; }
echo "[+] Instanz ist clean (DB, Rollen, /etc/n8n, /etc/lifeagents, /var/lib/n8n, CLI entfernt)."
fi

rm -rf "$D/src"; mv "$D/src.new" "$D/src"; rm -f src.tgz
cat > "$D/install-dev.sh" <<EOF
#!/usr/bin/env bash
# Generiert von scripts/reset_dev_instance.ps1 — startet den Installer aus dem hochgeladenen Repo-Stand
# exakt wie install.sh nach dem Download: RELEASE_TAG exportieren, --profile release als Default, exec provision.sh.
export RELEASE_TAG='$TAG'
case " \$* " in *" --profile"*) set -- "\$@" ;; *) set -- --profile release "\$@" ;; esac
exec bash $D/src/provisioning/provision.sh "\$@"
EOF
chmod 700 "$D/install-dev.sh"
echo "[+] Bereit: Stand $TAG in $D/src ($(df -Pm / | awk 'NR==2{print $4}') MB frei)."
'@
    $keepFlag = if ($KeepInstance) { '1' } else { '0' }
    $bash = $bash.Replace('@@DIR@@', $RemoteDir).Replace('@@SHA@@', $sha).Replace('@@TAG@@', $tag).Replace('@@KEEP@@', $keepFlag).Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText($remoteScript, $bash, $Utf8NoBom)

    # --- (3) Upload --------------------------------------------------------------
    Write-Host "Upload ..."
    $r = Invoke-Native scp ($sshOpts + @('-q', $tgz, $remoteScript, "${target}:$RemoteDir/"))
    if ($r.Code -ne 0) { throw "scp fehlgeschlagen (Exit $($r.Code)): $($r.Output -join "`n")" }

    if ($KeepInstance) { Write-Host "Container: Stand bereitlegen (bestehende Instanz bleibt) ..." }
    else { Write-Host "Container: clean machen + bereitlegen ..." }
    $verboseFlag = if ($Verbose) { '1' } else { '0' }
    $r = Invoke-Remote "VERBOSE=$verboseFlag bash $RemoteDir/reset.sh; rc=`$?; rm -f $RemoteDir/reset.sh; exit `$rc"
    $r.Output | ForEach-Object { Write-Host "  $_" }
} finally {
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($r.Code -ne 0) {
    Write-Host "FEHLER (Exit $($r.Code)) — Instanz NICHT bereit." -ForegroundColor Red
    exit $r.Code
}
Write-Host ''
if ($KeepInstance) {
    Write-Host "OK — Stand $tag liegt auf der bestehenden Instanz bereit (nichts abgebaut)." -ForegroundColor Green
    Write-Host 'Update-Lauf im Container starten:'
} else {
    Write-Host "OK — Instanz ist clean, Stand $tag liegt bereit." -ForegroundColor Green
    Write-Host 'Installation im Container starten:'
}
Write-Host "  ssh $target   dann:   bash $RemoteDir/install-dev.sh"
exit 0
