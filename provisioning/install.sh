#!/usr/bin/env bash
# install.sh — Wegwerf-Bootstrap-Launcher (NUR Erstinstallation via curl|bash).
#
# Genau EINE Aufgabe: die Quelle aufloesen -> SHA256-verifiziert laden -> entpacken -> den
# `provision.sh` des verifizierten Baums starten. KEINE Provisionierungslogik, KEIN Sourcing der
# schweren lib/ (unter `curl … | bash` gibt es noch keinen Baum) -> self-contained.
#
# Bootstrap auf frischem Debian (install.sh ist Release-Asset; mit && verkettet, damit ein fehlgeschlagener
# Download kein STALE install.sh aus dem CWD ausfuehrt; nie `| bash` — ein abgebrochener Download liefe halb):
#   curl -fsSL https://github.com/<slug>/releases/latest/download/install.sh -o install.sh \
#     && bash install.sh --domain n8n.example.com
#   bash install.sh --version v0.1.0 --domain n8n.example.com   # eine bestimmte Version pinnen
#
# Default (ohne --version) = neuestes STABLES Release (GitHubs /releases/latest); `--version <tag>`
# pinnt ein Tag (oder 'latest'). --profile defaultet auf `release` (Endnutzer-Fall), wenn der Nutzer
# keins uebergibt; alle uebrigen Flags (--profile/--domain/--unattended/--uninstall/…) laufen
# unveraendert an provision.sh durch. Wird NICHT in die Runtime gespiegelt (install_cli laesst
# install.sh aus); Updates der installierten Instanz laufen ueber `lifeagents update`, nie hierueber.
#
# Sicherheitsmodell (Sigstore "safer curl|bash"): NIE blind `curl … | bash`. Erst Asset + Pruefsumme
# holen, die Pruefsumme VOR dem Entpacken/Ausfuehren verifizieren, dann den verifizierten Baum starten.
# EIN Weg (Owner-Entscheid 2026-10-24, oeffentliches Repo): immer anonym, kein Token.
#
# Bewusste kleine Doppelung gegenueber lib/fetch_release.sh (das `lifeagents update` nutzt): exakt das
# rustup-Muster `sh.rustup.rs` (Bootstrap, self-contained) != `rustup self update` (Runtime, lib-basiert). Der
# Download-Block `# >>> gh-download` ist in beiden Dateien byte-gleich (contract_lint Check 23).
set -euo pipefail
# UTF-8 ist Gesetz (provisioning/CLAUDE.md) — egal was das System sagt (Proxmox-Vorlagen: LANG="C"); provision.sh
# setzt es ebenso, hier schon fuer die eigene Ausgabe des Launchers.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# shellcheck disable=SC2154  # false positive: ShellCheck doesn't parse assignments inside the trap
                            # string argument, so it can't see that rc=$? is set at the trap body start.
trap 'rc=$?; printf "\n[x] install.sh: unerwarteter Abbruch bei Zeile %s (Exit %s).\n" "$LINENO" "$rc" >&2' ERR

# --- minimale, self-contained Helfer (kein common.sh-Sourcing) ---------------
if [ -t 2 ]; then
  _C_RST=$'\033[0m'; _C_CYAN=$'\033[0;36m'; _C_GREEN=$'\033[0;32m'; _C_YELLOW=$'\033[0;33m'; _C_RED=$'\033[0;31m'
else
  _C_RST=''; _C_CYAN=''; _C_GREEN=''; _C_YELLOW=''; _C_RED=''
fi
log()  { printf '%s[*]%s %s\n' "$_C_CYAN"   "$_C_RST" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$_C_GREEN"  "$_C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$_C_YELLOW" "$_C_RST" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$_C_RED"    "$_C_RST" "$*" >&2; exit 1; }
# die_because <code> <text> — wie die; der Grund-Code dient nur der Fehler-Hilfe im Chat (lib/common.sh, Ergebnis-Datei).
#   Der Bootstrap kennt keine Ergebnis-Datei -> Code verwerfen (der gh-download-Block ist mit fetch_release.sh byte-gleich).
die_because() { shift; die "$@"; }
need_cmd()     { command -v "$1" >/dev/null 2>&1; }
require_root() { [ "$(id -u)" -eq 0 ] || die "Bootstrap muss als root laufen (sudo)."; }

PROVISION_REPO_SLUG="${PROVISION_REPO_SLUG:-DennisBaerlin/n8n-life-agents}"
PROVISION_ASSET_BASENAME="n8n-life-agents"
# >>> release-key — oeffentlicher Release-Signierschluessel = base64 von provisioning/keys/release-signing.gpg (leer = das
#     Projekt signiert noch nicht). Gesetzt von scripts/new_release_key.ps1; contract_lint haelt beides gleich.
RELEASE_KEY_B64='mDMEaty8sBYJKwYBBAHaRw8BAQdAAXd8PoJJuAW9uSfcz2xqLliN3wipRDi2HnekKE8vUIq0H244bi1saWZlLWFnZW50cyByZWxlYXNlIHNpZ25pbmeIkAQTFgoAOBYhBDEpRdgjdAMch/AiWMZPrPTgh6C/BQJq3LywAhsDBQsJCAcCBhUKCQgLAgQWAgMBAh4BAheAAAoJEMZPrPTgh6C/kwEA/06eB0lK8gJ4c6ZUpPUHxQsYPHR7y/RbNLz4of11aTlYAQCCurwiXXbHiNVe110Bv3uvz4Rxa0jrSBM36S12tfkaCQ=='
# <<< release-key
PROVISION_GH_API="${PROVISION_GH_API:-https://api.github.com}"   # Override nur Test (Mock)

VERSION=""          # leer => neuestes STABLES Release (/releases/latest); --version <tag> pinnt.
PASSTHROUGH=()      # --profile/--domain/--unattended/--uninstall/… unveraendert an provision.sh.
PROFILE_SEEN=0      # hat der Nutzer ein --profile uebergeben? Sonst defaulten wir auf release.

usage() {
  cat >&2 <<EOF
Usage: install.sh [--version <tag>] [--profile dev|release] [--domain <fqdn>] [weitere provision.sh-Flags]

  Bootstrap-Launcher (Erstinstallation). Laedt das Release-Asset SHA256-verifiziert, entpackt
  es und startet provision.sh. Updates einer installierten Instanz: 'lifeagents update'.

  --version <tag>      dieses Tag laden (z.B. v0.1.0) statt des neuesten stabilen Release.
                       <tag> darf 'latest' sein (= Default ohne Flag).
  --profile dev|release   an provision.sh durchgereicht (Netzwerk/Ingress). Default: release.
  --domain <fqdn>      an provision.sh durchgereicht (n8n WEBHOOK_URL + ausgegebenes Reverse-Proxy-Caddyfile).
  --help               diese Hilfe (alle uebrigen Flags reicht der Launcher an provision.sh weiter).
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)   VERSION="${2:-}"; shift 2 ;;
      --version=*) VERSION="${1#*=}"; shift ;;
      --help|-h)   usage; exit 0 ;;
      *)
        # --profile in beiden Formen merken, damit wir es NICHT ueberschreiben, wenn der Nutzer eins gab.
        case "$1" in --profile|--profile=*) PROFILE_SEEN=1 ;; esac
        PASSTHROUGH+=("$1"); shift ;;   # alles andere -> provision.sh
    esac
  done
  # Endnutzer-Default: ohne explizites --profile ist "release" der selbstverstaendliche Fall (das
  # Test-Substrat ruft provision.sh direkt mit --profile dev auf, NICHT ueber install.sh -> unberuehrt).
  [ "$PROFILE_SEEN" -eq 1 ] || PASSTHROUGH+=(--profile release)
}

# _ensure_deps — die wenigen Tools, die der Download braucht, vorab nachinstallieren (frischer Host
# hat ggf. weder jq noch curl). Root vorausgesetzt (main fordert es vorher).
_ensure_deps() {
  need_cmd curl && need_cmd jq && need_cmd tar && need_cmd sha256sum && return 0
  log "Fehlende Download-Tools — installiere (curl jq tar coreutils) ..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq tar coreutils
}

# >>> gh-download — GESPIEGELT in provisioning/install.sh UND provisioning/lib/fetch_release.sh; beide Bloecke
#     byte-gleich halten (contract_lint Check 23). Erwartet vom Umfeld: PROVISION_GH_API, PROVISION_REPO_SLUG, die, die_because.
#     Immer anonym: nie ein Auth-Header, kein Token (oeffentliches Repo).

# _gh_http <accept> <url> <out> <max-time> → HTTP-Status auf STDOUT ('000' = keine bzw. abgebrochene Antwort, 'local' =
#   lokaler Schreibfehler). Body nach <out> (bei Nicht-2xx geloescht, damit kein Fehler-JSON als Asset liegen bleibt),
#   Header nach <out>.hdr. Ohne -f, Exit-Code per `|| rc=$?` -> sicher unter set -euo pipefail. Ohne -f endet curl nur
#   bei Uebertragungsfehlern != 0 (Timeout 28, Reset 56, Teil-Datei 18, leere Antwort 52; Schreiben 23/26) — dann ist
#   der gemeldete Status (oft schon 200 oder der 302 vor dem Redirect) bedeutungslos und die Datei unvollstaendig ->
#   nie Erfolg. Redirects (Asset -> signierte S3-URL) nur auf https, wenn die Basis https ist (PROVISION_GH_API ist nur
#   im Test ein http-Mock).
_gh_http() {
  local accept="$1" url="$2" out="$3" max="$4" code rc=0 proto=()
  case "$PROVISION_GH_API" in https://*) proto=(--proto-redir "=https") ;; esac
  code="$(curl -sSL --max-time "$max" "${proto[@]}" -H "Accept: ${accept}" -H 'X-GitHub-Api-Version: 2022-11-28' \
    -D "$out.hdr" -o "$out" -w '%{http_code}' "$url")" || rc=$?
  code="${code:-000}"
  case "$rc" in 0) ;; 23|26) code="local" ;; *) code="000" ;; esac
  case "$code" in 2??) ;; *) rm -f "$out" ;; esac
  printf '%s' "$code"
}

# _gh_rate_limited <code> <hdr-file> — Abfragelimit: 429, oder 403 mit x-ratelimit-remaining: 0 (primaer; anonym 60/h je
#   IP, ein Lauf braucht 1-2 API-Anfragen) bzw. mit retry-after (sekundaer, zu viele Anfragen kurz hintereinander).
_gh_rate_limited() {
  [ "$1" = "429" ] && return 0
  [ "$1" = "403" ] && grep -qiE '^(x-ratelimit-remaining:[[:space:]]*0[[:space:]]*|retry-after:.*)$' "$2" 2>/dev/null
}

# _gh_die_status <code> <hdr-file> <was> — die mit der passenden Meldung fuer ein Nicht-2xx.
_gh_die_status() {
  [ "$1" != "local" ] || die_because disk "$3: lokaler Schreibfehler (Platte voll? Freien Platz unter /tmp pruefen) — dann erneut versuchen."
  [ "$1" != "000" ] || die_because net "$3: GitHub nicht erreichbar oder Antwort abgebrochen (${PROVISION_GH_API}) — Netzwerk/DNS pruefen und erneut versuchen."
  if _gh_rate_limited "$1" "$2"; then
    die_because rate_limit "$3: GitHub-Abfragelimit erreicht (HTTP $1) — in einer Stunde erneut versuchen."
  fi
  die "$3 fehlgeschlagen (HTTP $1)."
}

# _gh_release_json <url> <out> — Release-Metadaten (/releases/latest bzw. /releases/tags/<tag>) nach <out>; die mit
#   Klartext. 404 = kein stabiles Release bzw. Tag unbekannt (oder das Repo ist nicht oeffentlich).
_gh_release_json() {
  local url="$1" out="$2" code
  code="$(_gh_http 'application/vnd.github+json' "$url" "$out" 30)"
  case "$code" in
    2??) return 0 ;;
    404)
      case "$url" in
        */releases/latest) die_because not_found "Kein veroeffentlichtes stabiles Release in ${PROVISION_REPO_SLUG} gefunden (HTTP 404; Repo oeffentlich?)." ;;
        *)                 die_because not_found "Release nicht gefunden (HTTP 404) — dieses Tag existiert nicht in ${PROVISION_REPO_SLUG}." ;;
      esac ;;
    *) _gh_die_status "$code" "$out.hdr" "Release-Abfrage" ;;
  esac
}

# _gh_fetch <accept> <url> <out> <max-time> <was> — Asset-Download ueber die browser_download_url (github.com/.../
#   releases/download/..., zaehlt nicht gegen das API-Abfragelimit); die bei Nicht-2xx.
_gh_fetch() {
  local code; code="$(_gh_http "$1" "$2" "$3" "$4")"
  case "$code" in 2??) return 0 ;; esac
  _gh_die_status "$code" "$3.hdr" "Download von '$5'"
}

# _release_tag_from <json-file> → tag_name auf STDOUT. Charset-Sanity: das Tag fliesst in Asset-Namen und URLs -> nur
#   harmlose Tag-Zeichen zulassen (kein /, ?, #, Whitespace).
_release_tag_from() {
  local tag; tag="$(jq -r '.tag_name // empty' "$1")" || die "Release-Antwort nicht lesbar (kein JSON)."
  [ -n "$tag" ] || die "Kein tag_name aus /releases/latest lesbar."
  case "$tag" in *[!A-Za-z0-9._-]*) die "Unerwartetes Tag-Format aus /releases/latest: '$tag'." ;; esac
  printf '%s' "$tag"
}
# _asset_url <release-json> <name> → browser_download_url des Assets (leer, wenn es fehlt).
_asset_url() {
  local u; u="$(jq -r --arg n "$2" '.assets[]? | select(.name==$n) | .browser_download_url' "$1" 2>/dev/null | head -n1)" || u=""
  [ "$u" = "null" ] && u=""
  printf '%s' "$u"
}

# _release_fetch_verify <release-json> <dir> <tarball-name> <tag> <keyring|''> — Tarball + Pruefdaten laden und VOR dem
#   Entpacken pruefen. Mit Schluesselbund (ab der ersten signierenden Version fest in /etc/lifeagents, nie aus dem Release
#   selbst): SHA256SUMS muss per gpgv gegen GENAU dieses Bund gueltig unterschrieben sein (SHA256SUMS.sig, Muster Debian
#   SecureApt), dann muss die exakte Zeile "<sha256>  <tarball-name>" darin stehen. Ohne Bund: das Sidecar
#   <tarball>.sha256 (nur Unversehrtheit, keine Echtheit).
_release_fetch_verify() {
  local rel="$1" dir="$2" name="$3" tag="$4" kr="$5" url sum
  url="$(_asset_url "$rel" "$name")"
  [ -n "$url" ] || die "Asset '$name' fehlt im Release ${tag}."
  _gh_fetch 'application/octet-stream' "$url" "$dir/$name" 600 "$name"
  if [ -n "$kr" ]; then
    command -v gpgv >/dev/null 2>&1 || die_because signature "gpgv fehlt — ohne Prüfung der Unterschrift wird nichts installiert (apt-get install gpgv)."
    for _f in SHA256SUMS SHA256SUMS.sig; do
      url="$(_asset_url "$rel" "$_f")"
      [ -n "$url" ] || die_because signature "Release ${tag} ist nicht unterschrieben (Asset '$_f' fehlt) — ABBRUCH vor dem Entpacken."
      _gh_fetch 'application/octet-stream' "$url" "$dir/$_f" 60 "$_f"
    done
    mkdir -p "$dir/.gpgv"; chmod 0700 "$dir/.gpgv"
    gpgv --homedir "$dir/.gpgv" --keyring "$kr" "$dir/SHA256SUMS.sig" "$dir/SHA256SUMS" >/dev/null 2>&1 \
      || die_because signature "Die Unterschrift von Release ${tag} ist ungültig (nicht mit dem Projekt-Schlüssel signiert) — ABBRUCH vor dem Entpacken, es wurde nichts installiert."
    sum="$(sha256sum "$dir/$name" | cut -d' ' -f1)"
    grep -qxF "${sum}  ${name}" "$dir/SHA256SUMS" \
      || die_because checksum "'${name}' passt nicht zur unterschriebenen Prüfsummenliste — ABBRUCH vor dem Entpacken (manipuliertes/korruptes Asset)."
    ok "Unterschrift + SHA256 verifiziert: $name"
  else
    url="$(_asset_url "$rel" "${name}.sha256")"
    [ -n "$url" ] || die "Asset '${name}.sha256' fehlt im Release ${tag}."
    _gh_fetch 'application/octet-stream' "$url" "$dir/${name}.sha256" 60 "${name}.sha256"
    ( cd "$dir" && sha256sum -c "${name}.sha256" ) >/dev/null 2>&1 \
      || die_because checksum "SHA256-Verifikation fehlgeschlagen fuer '$name' — ABBRUCH vor dem Entpacken (manipuliertes/korruptes Asset)."
    ok "SHA256 verifiziert: $name"
  fi
}

# <<< gh-download

main() {
  parse_args "$@"
  require_root
  _ensure_deps

  # Arbeitsverzeichnis: bei jedem Abbruch (die/exit) per EXIT-Trap weg; `exec` des Appliers loest keinen Trap aus, nach
  # Erfolg bleibt es also liegen -> Reste frueherer Laeufe (eigenes Muster, aelter als 60 min) vorher abraeumen.
  find /tmp -maxdepth 1 -type d -name 'n8n_bootstrap.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  local work; work="$(mktemp -d /tmp/n8n_bootstrap.XXXXXX)"
  _BOOT_WORK="$work"
  trap 'rm -rf "${_BOOT_WORK:-}"' EXIT
  local rel="$work/release.json"

  # Quelle aufloesen: Default = neuestes STABLES Release (/releases/latest = neuestes NICHT-prerelease,
  # NICHT-draft, samt Assets). --version <tag> pinnt; 'latest' faellt auf denselben Pfad.
  local tag="${VERSION:-latest}"
  if [ "$tag" = "latest" ]; then
    log "Neuestes stabiles Release ermitteln (/releases/latest) ..."
    _gh_release_json "${PROVISION_GH_API}/repos/${PROVISION_REPO_SLUG}/releases/latest" "$rel"
    tag="$(_release_tag_from "$rel")"
    ok "Neuestes stabiles Release: ${tag}"
  else
    _gh_release_json "${PROVISION_GH_API}/repos/${PROVISION_REPO_SLUG}/releases/tags/${tag}" "$rel"
  fi
  log "Release ${tag} von ${PROVISION_REPO_SLUG} laden (SHA256-verifiziert) ..."

  local tarball_name="${PROVISION_ASSET_BASENAME}-${tag}.tar.gz"
  # Schluesselbund: das INSTALLIERTE (/etc — Neuinstallation, Rueckweg) gewinnt immer; sonst der mit diesem install.sh
  # gelieferte (Erstinstallation = Vertrauen beim ersten Kontakt, TOFU, unvermeidbar). Leer = das Projekt signiert noch
  # nicht -> nur das SHA256-Sidecar. Pruefen VOR dem Entpacken (gh-download-Block).
  local kr="${LIFEAGENTS_RELEASE_KEYRING:-/etc/lifeagents/release-signing.gpg}"
  if [ ! -s "$kr" ]; then
    kr=""
    if [ -n "$RELEASE_KEY_B64" ]; then
      kr="$work/release-signing.gpg"
      printf "%s" "$RELEASE_KEY_B64" | base64 -d > "$kr" || die "Eingebetteter Release-Schluessel nicht lesbar (install.sh beschaedigt)."
    fi
  fi
  _release_fetch_verify "$rel" "$work" "$tarball_name" "$tag" "$kr"

  tar -xzf "$work/$tarball_name" -C "$work" || die "Entpacken von '$tarball_name' fehlgeschlagen."
  local applier=''
  for _c in "$work"/*/provisioning/provision.sh; do [ -e "$_c" ] && { applier="$_c"; break; }; done
  [ -n "$applier" ] || die "Im Asset fehlt provisioning/provision.sh (unvollstaendiges Release)."
  ok "Release ${tag} entpackt nach ${applier%/provisioning/provision.sh}"

  # RELEASE_TAG fuer den Applier-Lauf exportieren -> install_cli schreibt es in die lifeagents-
  # VERSION-Datei (`lifeagents version`). Den verifizierten provision.sh exec'en (anderes Skript ->
  # KEIN Self-Loop; provision.sh kennt --version nicht, daher reicht der Passthrough ohne Filter).
  export RELEASE_TAG="$tag"
  log "Starte Applier: provisioning/provision.sh ${PASSTHROUGH[*]:-}"
  exec bash "$applier" "${PASSTHROUGH[@]}"
}

main "$@"
