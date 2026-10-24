# fetch_release.sh — gespiegelte Fetch-Bibliothek der Runtime (`lifeagents update`, Phase 6b).
#
# NICHT von provision.sh gesourct (der Applier laeuft auf einem bereits vorliegenden Baum). Gesourct
# von der `lifeagents`-CLI (fuer `update` nur zusammen mit common.sh — keine release_inputs.sh-Helfer nutzen):
# fetch_and_run_release() laedt den getrackten Baum eines getaggten Releases als SHA256-
# verifiziertes Asset, entpackt ihn und exec't den NEUEN `provision.sh`
# (self-replacing, rustup-Muster `rustup self update`). Ruft NIE install.sh (der Wegwerf-Bootstrap
# lebt nicht in der Runtime).
#
# Der Bootstrap-Launcher install.sh nutzt DIESELBE Mechanik inline/self-contained (bewusste kleine
# Doppelung Bootstrap<->Runtime, exakt das rustup-Muster `sh.rustup.rs` != `rustup self update`); der
# Download-Block `# >>> gh-download` ist in beiden Dateien byte-gleich (contract_lint Check 23).
#
# Sicherheitsmodell (Sigstore "safer curl|bash"): NIE blind `curl … | bash`. Erst Datei + Pruefsumme
# holen, die Pruefsumme VOR dem Entpacken/Ausfuehren verifizieren, dann den verifizierten Baum starten.
#
# EIN Weg (Owner-Entscheid 2026-10-24, oeffentliches Repo): der Download ist immer anonym — kein Token, keine
# Token-Frage, kein Auth-Header. Ein alter GH_TOKEN aus der privaten Zeit wird nie gelesen; provision.sh
# entfernt ihn aus den Env-Dateien (drop_legacy_repo_token).
#
# Exec't provision.sh OHNE Argument-Filter (provision.sh kennt kein --version) -> reicht die Passthrough-Args
# direkt durch.
# Zweiter Einstieg (Install-UX-Phase 7): run_installed_release = derselbe exec-Schwanz (_exec_applier) auf einer Kopie
# des INSTALLIERTEN Baums, ohne Download (`lifeagents reconfigure`).

# Release-Quelle (PROVISION_REPO_SLUG, PROVISION_GH_API) lebt in common.sh — geteilt mit dem Rueckweg-Hinweis
# (upgrade_guard.sh); install.sh traegt als self-contained Bootstrap bewusst eine eigene Kopie.
PROVISION_ASSET_BASENAME="n8n-life-agents"

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

# _ensure_release_deps — die wenigen Tools, die der Download braucht (frischer Host hat ggf. weder jq
# noch curl). Root vorausgesetzt (fetch_and_run_release fordert).
_ensure_release_deps() {
  local missing=() c
  for c in curl jq tar sha256sum; do need_cmd "$c" || missing+=("$c"); done
  [ "${#missing[@]}" -eq 0 ] && return 0
  log "Fehlende Tools fuer den Release-Download: ${missing[*]} — installiere ..."
  local pkgs=() m
  for m in "${missing[@]}"; do
    case "$m" in sha256sum) pkgs+=(coreutils) ;; *) pkgs+=("$m") ;; esac
  done
  apt_update_once
  apt_install "${pkgs[@]}"
}

# fetch_and_run_release [tag] [provision-args...]  — der `lifeagents update`-Pfad. Laedt + verifiziert
# + entpackt das Release und exec't den gepinnten provision.sh (Passthrough-Args). Kehrt nie zurueck
# (exec) — bei jedem Fehler `die` (Abbruch VOR jeder Aenderung am System). tag default 'latest'.
# Arbeitsverzeichnis: bei jedem Abbruch per EXIT-Trap weg; `exec` des Appliers loest keinen Trap aus (wie install.sh).
fetch_and_run_release() {
  local tag="${1:-latest}"; [ "$#" -gt 0 ] && shift || true
  require_root
  # Ergebnis-Datei (Chat-Runner): bis zum Applier wird nichts am System geaendert.
  result_set changed false
  result_set stage download
  _ensure_release_deps

  local work; work="$(_release_workdir_new)"
  _REL_WORK="$work"
  trap 'rm -rf "${_REL_WORK:-}"' EXIT
  local rel="$work/release.json"
  # 'latest' (= `lifeagents update`): /releases/latest liefert das neueste NICHT-prerelease, NICHT-draft Release
  # samt Assets -> kein zweiter Aufruf je Tag noetig.
  if [ "$tag" = "latest" ]; then
    log "Neuestes Release ermitteln (/releases/latest) ..."
    _gh_release_json "${PROVISION_GH_API}/repos/${PROVISION_REPO_SLUG}/releases/latest" "$rel"
    tag="$(_release_tag_from "$rel")"
    ok "Neuestes Release: ${tag}"
  else
    _gh_release_json "${PROVISION_GH_API}/repos/${PROVISION_REPO_SLUG}/releases/tags/${tag}" "$rel"
  fi
  _refuse_downgrade "$tag"
  log "Release ${tag} von ${PROVISION_REPO_SLUG} laden (SHA256-verifiziert) ..."

  local tarball_name="${PROVISION_ASSET_BASENAME}-${tag}.tar.gz"
  # Pruefen VOR dem Entpacken (gh-download-Block): mit installiertem Schluesselbund Unterschrift + Pruefsummenliste,
  # sonst das SHA256-Sidecar. Bricht ab, bevor irgendetwas entpackt oder ausgefuehrt wird.
  result_set stage verify
  _release_fetch_verify "$rel" "$work" "$tarball_name" "$tag" "$(_release_keyring)"

  tar -xzf "$work/$tarball_name" -C "$work" || die "Entpacken von '$tarball_name' fehlgeschlagen."
  local applier=''
  for _c in "$work"/*/provisioning/provision.sh; do [ -e "$_c" ] && { applier="$_c"; break; }; done
  [ -n "$applier" ] || die "Im Asset fehlt provisioning/provision.sh (unvollstaendiges Release)."
  ok "Release ${tag} entpackt nach ${applier%/provisioning/provision.sh}"

  _exec_applier "$applier" "$tag" "$@"
}

# _refuse_downgrade <tag> — kein Rueckschritt auf eine aeltere Version, ausser bewusst (LIFEAGENTS_ALLOW_DOWNGRADE=1, gesetzt
#   von `lifeagents update --allow-downgrade` bzw. `lifeagents rollback`). Ein Downgrade liefe die neueren Schema-Migrationen
#   nicht zurueck — der echte Rueckweg stellt erst die Sicherung her (lifeagents rollback). Greift nur zwischen zwei stabilen
#   Tags vX.Y.Z; Vergleich per `sort -V` (dieselbe Ordnung wie core.fn_semver_cmp fuer vX.Y.Z — bewusst ohne DB, denn
#   genau bei einer kaputten DB muss ein Update/Rueckweg noch laufen). Gleiches Tag = erneut anwenden, erlaubt.
_refuse_downgrade() {
  local tag="$1" installed
  [ "${LIFEAGENTS_ALLOW_DOWNGRADE:-0}" = 1 ] && return 0
  installed="$(cat "$(lifeagents_version_marker)" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  [[ "$installed" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  [ "$installed" = "$tag" ] && return 0
  if [ "$(printf '%s\n%s\n' "$installed" "$tag" | sort -V | head -n1)" = "$tag" ]; then
    die_because downgrade "Release ${tag} ist älter als die installierte Version ${installed} — kein Rückschritt. Zurück auf eine frühere Version: lifeagents rollback (stellt auch die Daten von vorher wieder her)."
  fi
}

# _release_keyring -> Pfad des installierten Release-Schluesselbunds auf stdout (leer = diese Installation prueft noch keine
#   Unterschrift). Fest in /etc (install_release_keyring legt es einmal an, ein Update ueberschreibt es nie); der Override
#   LIFEAGENTS_RELEASE_KEYRING dient nur Tests (Prozess-Env von root). Immer rc 0.
_release_keyring() {
  local k="${LIFEAGENTS_RELEASE_KEYRING:-/etc/lifeagents/release-signing.gpg}"
  [ -s "$k" ] && printf "%s" "$k"
  return 0
}

# _release_workdir_new -> frisches Arbeitsverzeichnis fuer einen Applier-Lauf auf stdout. Raeumt dabei die Reste FRUEHERER
#   Laeufe ab: der Applier startet per exec, danach kann niemand mehr aufraeumen — also raeumt der naechste Lauf (es bleibt
#   hoechstens das juengste Verzeichnis liegen). Nur das eigene Namensmuster direkt unter /tmp und nur aelter als 60 Minuten
#   (ein gleichzeitig laufender Converge — z. B. ein Cron-Update waehrend `reconfigure` — verliert so nie seinen Baum).
_release_workdir_new() {
  find /tmp -maxdepth 1 -type d -name 'n8n_release.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  mktemp -d /tmp/n8n_release.XXXXXX
}

# _exec_applier <provision.sh> <tag> [provision-args...] — der geteilte exec-Schwanz von `update` und `reconfigure`:
#   RELEASE_TAG exportieren -> install_cli schreibt es in die lifeagents-VERSION-Datei (`lifeagents version`), dann den
#   provision.sh des vorbereiteten Baums exec'en (re-spiegelt CLI + Baum). Kehrt nie zurueck.
#   Leeres Array unter set -u: `"${arr[@]}"` expandiert in bash 4.4+ (Debian 12 = 5.2) zu NULL Args.
_exec_applier() {
  local applier="$1" tag="$2"
  shift 2
  export RELEASE_TAG="$tag"
  log "Starte Applier ${tag}: provisioning/provision.sh ${*:-}"
  exec bash "$applier" "$@"
}

# run_installed_release [provision-args...] — den INSTALLIERTEN Stand erneut anwenden (`lifeagents reconfigure`,
#   Install-UX-Phase 7): wie fetch_and_run_release, nur ohne Download — der Runtime-Baum wird nach /tmp kopiert (der
#   laufende Baum tauscht sich in install_cli so nie selbst aus), RELEASE_TAG kommt aus der installierten VERSION
#   (sonst schriebe install_cli „dev"). Profil (INSTALL_PROFILE) und Paketmenge (Registry) liest provision.sh selbst.
#   Kehrt nie zurueck.
run_installed_release() {
  require_root
  local lib work tag
  lib="$(lifeagents_runtime_dir)"
  [ -r "$lib/provisioning/provision.sh" ] || die "Installierter Baum unvollständig ($lib/provisioning/provision.sh fehlt) — 'lifeagents update' stellt ihn wieder her."
  tag="$(cat "$(lifeagents_version_marker)" 2>/dev/null || true)"
  work="$(_release_workdir_new)"
  cp -a "$lib/provisioning" "$work/provisioning"
  if [ -d "$lib/packages" ]; then cp -a "$lib/packages" "$work/packages"; fi
  _exec_applier "$work/provisioning/provision.sh" "${tag:-dev}" "$@"
}
