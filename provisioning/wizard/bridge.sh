#!/usr/bin/env bash
# shellcheck disable=SC1111  # deutsche Anführungszeichen in Meldungen sind gewollt
# bridge.sh — die Brücke zwischen dem Wizard (server.js) und der EINEN Quelle der CLI-Fragen (Plan „Docker-Installer für
# Freunde“, Paket 4). Der Wizard hat keine eigene Kopie der Fragen oder Prüfregeln: er fragt hier nach und lässt hier
# prüfen. Dieselben Funktionen nutzt die Installation im Terminal (release_inputs.sh, pkg_lifecycle.sh, common.sh) —
# CLI und Wizard können darum nicht auseinanderlaufen.
#
#   bash bridge.sh questions                     -> eine JSON-Zeile: Host-Fragen (_host_key_def, _REQUIRED_HOST_KEYS),
#                                                   Sprachen, Charaktere, Pakete (pkg_display_name, package.summary,
#                                                   Manifest-config mit prompt, Manifest-credentials)
#   bash bridge.sh validate host:<KEY>           -> Wert auf stdin; JSON {"rc":0|1|2,"value":…,"problem":…}
#   bash bridge.sh validate cred:<pkg>:<ENVKEY>     (rc 2 = Dienst nicht erreichbar, wie _live_rc)
#   bash bridge.sh validate cfg:<pkg>:<cat>.<key>
#   bash bridge.sh paperless-check               -> stdin: Zeile 1 Adresse, Zeile 2 Zugangstoken (optional);
#                                                   JSON {"ok":…,"reason":…,"version":…}
#   bash bridge.sh tg-check                      -> Token in Env TELEGRAM_BOT_TOKEN; Prüfliste Nr. 10 (s. tg_check_json)
#   bash bridge.sh reach-status                  -> Zustand des Tunnels (Schnittstelle zu Paket 3, s. reach_status_json)
#   bash bridge.sh public-ip                     -> öffentliche IPv4 des Anschlusses (Paket 3, reach_public_ipv4)
#
# Geheimnisse nur über stdin/Env, nie im argv (die Prozessliste ist für jeden lesbar). Ausgabe immer genau eine JSON-Zeile
# auf stdout; Meldungen der Bibliotheken gehen nach stderr, die der Wizard verwirft. Exit 0, ausser bei falschem Aufruf (64).
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

_BR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BR_PROV="$(cd "$_BR_HERE/.." && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$_BR_PROV/.." && pwd)}"
export REPO_ROOT
# Kein Terminal, keine Nachfrage: die Bibliotheken fragen nie, solange UNATTENDED=1 gilt (ui_interactive).
# shellcheck disable=SC2034  # gelesen von den gesourcten Bibliotheken (ui_interactive, _ask_*)
UNATTENDED=1
# shellcheck disable=SC2034  # s. o.
PROFILE=release
# shellcheck source=/dev/null
. "$_BR_PROV/lib/common.sh"
# shellcheck source=/dev/null
. "$_BR_PROV/lib/pkg_lifecycle.sh"
# shellcheck source=/dev/null
. "$_BR_PROV/lib/release_inputs.sh"
# shellcheck source=/dev/null
. "$_BR_PROV/lib/bootstrap_owner.sh"
# runtime.sh (Docker-Wrapper) und reach.sh (Weg nach außen) lädt common.sh mit.

# Host-Fragen, die der Wizard stellt (Reihenfolge = _INSTALL_ENV_KEYS). Nicht dabei: die n8n-Anmeldung (die Installation
# erzeugt sie) und der Proxy-Ort (ergibt sich im Docker-Betrieb aus dem Rand, Paket 1/3). DOMAIN fragt der Wizard nur
# beim FritzBox-Weg.
_BR_SKIP_KEYS=" N8N_OWNER_EMAIL N8N_OWNER_PASSWORD TRUSTED_PROXIES "

_br_bool() { if [ "${1:-0}" = 1 ]; then printf true; else printf false; fi; }

# _br_labels <json-array-of-prompts> -> {"<prompt>":"<label>",…} über _prompt_label (dieselbe Beschriftung wie die CLI).
_br_labels() {
  local p out='{}'
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    out="$(jq -c --arg p "$p" --arg l "$(_prompt_label "$p")" '. + {($p): $l}' <<<"$out")"
  done <<<"$(jq -r '.[]' <<<"$1")"
  printf '%s' "$out"
}

br_questions() {
  local k host='[]' req p pkgs='[]' mf one prompts labels langs personas
  for k in $_INSTALL_ENV_KEYS; do
    case "$_BR_SKIP_KEYS" in *" $k "*) continue ;; esac
    _host_key_def "$k"
    req=0; _host_key_required "$k" && req=1
    host="$(jq -c --arg k "$k" --arg p "$_HK_PROMPT" --arg l "$(_prompt_label "$_HK_PROMPT")" --arg h "$_HK_HELP" \
      --arg v "$_HK_VFN" --argjson s "$(_br_bool "$_HK_SECRET")" --argjson c "$(_br_bool "$_HK_CONFIRM")" \
      --argjson r "$(_br_bool "$req")" --argjson live "$(_is_live_validator "$_HK_VFN" && echo true || echo false)" \
      '. + [{key:$k, prompt:$p, label:$l, help:$h, validator:$v, secret:$s, confirm:$c, required:$r, live:$live}]' <<<"$host")"
  done
  langs="$(_owner_language_options | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {name:.[0], code:.[1]})')"
  personas="$(_owner_persona_options | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {name:.[0], code:.[1]})')"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    mf="$(_pkg_dir)/$p/manifest.json"
    # Dieselben Zeilen wie die CLI-Fragen (_PKG_SETTING_ROWS_JQ / _PKG_CRED_ROWS_JQ aus pkg_lifecycle.sh), hier nur in die
    # Form des Wizards gebracht (Zugänge mit ihren Schlüsseln gruppiert, Reihenfolge bleibt); Beschriftungen danach.
    one="$(jq -c --arg id "$p" --arg name "$(pkg_display_name "$p")" --arg summary "$(pkg_text "$p" package.summary)" \
      --argjson settings "$(jq -c "[ $_PKG_SETTING_ROWS_JQ ]" "$mf")" \
      --argjson creds "$(jq -c --arg only '' "[ $_PKG_CRED_ROWS_JQ ]" "$mf")" '
      {id:$id, name:$name, summary:$summary, requires:(.requires // []),
       settings:[$settings[] | {id:(.cat + "." + .key), env:("CONFIG_" + (.cat + "_" + .key | ascii_upcase)), prompt,
                 help:(.help // ""), validator:(.validator // "none"), choices:(.choices // [])}],
       credentials:(reduce $creds[] as $r ([];
                 {env:$r.k, prompt:($r.prompt // ($r.k + ": ")), help:($r.help // ""), secret:$r.secret, validator:$r.validator} as $k
                 | if length > 0 and .[-1].id == $r.cred then .[-1].keys += [$k]
                   else . + [{id:$r.cred, required:$r.required, keys:[$k]}] end))}' "$mf")"
    pkgs="$(jq -c --argjson one "$one" '. + [$one]' <<<"$pkgs")"
  done <<<"$(_bundled_packages)"
  prompts="$(jq -c '[.[] | (.settings[].prompt, .credentials[].keys[].prompt)]' <<<"$pkgs")"
  labels="$(_br_labels "$prompts")"
  pkgs="$(jq -c --argjson L "$labels" 'map(.settings |= map(. + {label: $L[.prompt]})
                                         | .credentials |= map(.keys |= map(. + {label: $L[.prompt]})))' <<<"$pkgs")"
  jq -nc --argjson host "$host" --argjson langs "$langs" --argjson personas "$personas" --argjson pkgs "$pkgs" \
    '{v:1, host:$host, languages:$langs, personas:$personas, packages:$pkgs}'
}

# _br_out <rc> [value] [problem] -> die Antwort von validate.
_br_out() { jq -nc --argjson rc "$1" --arg v "${2:-}" --arg p "${3:-}" '{rc:$rc, value:$v, problem:$p}'; }

# _br_run_validator <fn> <wert> -> rc der CLI-Prüffunktion (0 gültig, 1 abgelehnt, 2 Dienst nicht erreichbar).
_br_run_validator() { local rc=0; "$1" "$2" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

br_validate() {
  local ref="$1" val kind rest pkg id vfn rc problem mf entry choices
  val="$(cat)"
  kind="${ref%%:*}"; rest="${ref#*:}"
  case "$kind" in
    host)
      id="$rest"
      case " $_INSTALL_ENV_KEYS " in *" $id "*) : ;; *) _br_out 1 '' 'unbekannte Frage'; return 0 ;; esac
      case "$_BR_SKIP_KEYS" in *" $id "*) _br_out 1 '' 'unbekannte Frage'; return 0 ;; esac
      case "$id" in
        OWNER_LANGUAGE) if _owner_language_options | cut -f2 | grep -qxF -- "$val"; then _br_out 0 "$val"; else _br_out 1 '' 'keine der angebotenen Sprachen'; fi; return 0 ;;
        OWNER_PERSONA)  if _owner_persona_options | cut -f2 | grep -qxF -- "$val"; then _br_out 0 "$val"; else _br_out 1 '' 'keiner der angebotenen Charaktere'; fi; return 0 ;;
      esac
      _host_key_def "$id"
      val="$(_input_normalize "$id" "$val")"
      if [ -z "$val" ]; then
        if _host_key_required "$id"; then _br_out 1 '' 'Diese Angabe ist nötig'; else _br_out 0 ''; fi
        return 0
      fi
      rc="$(_br_run_validator "$_HK_VFN" "$val")"
      problem=''
      if [ "$rc" = 1 ]; then problem="$(_input_problem "$id" "$val")"; fi
      # Docker-Weg über die FritzBox: die Adresse der Box selbst führt nicht zu diesem Rechner (dieselbe Regel wie doctor).
      if [ "$rc" = 0 ] && [ "$id" = DOMAIN ] && is_router_myfritz_name "$val"; then
        rc=1; problem='Das ist die Adresse der FritzBox selbst. Du brauchst die Adresse mit dem Namen deines Rechners vorne'
      fi
      _br_out "$rc" "$val" "$problem" ;;
    cred|cfg)
      pkg="${rest%%:*}"; id="${rest#*:}"
      _pkg_name_ok "$pkg" || { _br_out 1 '' 'unbekanntes Paket'; return 0; }
      mf="$(_pkg_dir)/$pkg/manifest.json"
      [ -r "$mf" ] || { _br_out 1 '' 'unbekanntes Paket'; return 0; }
      if [ "$kind" = cred ]; then
        entry="$(jq -c --arg k "$id" '[(.credentials // {}) | to_entries[] | select(.key != "_comment") | .value.env[$k] // empty] | first // empty' "$mf")"
      else
        entry="$(jq -c --arg c "${id%%.*}" --arg k "${id#*.}" '(.config[$c][$k] // empty) | select(type == "object" and has("prompt"))' "$mf")"
      fi
      [ -n "$entry" ] || { _br_out 1 '' 'unbekannte Frage'; return 0; }
      if [ -z "$val" ]; then _br_out 0 ''; return 0; fi   # Paket-Fragen sind optional (Enter = überspringen wie in der CLI)
      choices="$(jq -r '(.choices // [])[] | .value' <<<"$entry")"
      if [ -n "$choices" ]; then
        if printf '%s\n' "$choices" | grep -qxF -- "$val"; then _br_out 0 "$val"; else _br_out 1 '' 'keine der angebotenen Antworten'; fi
        return 0
      fi
      vfn="$(_pkg_validator_fn "$(jq -r '.validator // "none"' <<<"$entry")")" || vfn=_validate_any
      rc="$(_br_run_validator "$vfn" "$val")"
      _br_out "$rc" "$val" ;;
    *) _br_out 1 '' 'unbekannte Frage' ;;
  esac
  return 0
}

# _br_http <out-headers-file> <url> [token] -> HTTP-Code (000 = nicht erreichbar). Token nur über die curl-Konfig (stdin).
_br_http() {
  local hf="$1" url="$2" tok="${3:-}" code
  code="$( { curl_cfg url "$url"
             if [ -n "$tok" ]; then curl_cfg header "Authorization: Token ${tok}"; fi
             curl_cfg header 'Accept: application/json'
           } | curl -K - -sS -o /dev/null -D "$hf" -w '%{http_code}' --max-time 8 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

# paperless-check — Live-Prüfung der Paperless-Anbindung (Plan *Die Module wie in der CLI*): Adresse, Version (3.0 oder
#   neuer), Zugang. localhost/127.x/::1 meint im Docker-Betrieb den Container selbst -> mit Erklärung abgelehnt. Ohne Token
#   lässt sich nur „antwortet wie Paperless“ prüfen (die Version zeigt Paperless erst angemeldet, Kopfzeile X-Version).
#   reason: localhost | invalid | unreachable | not_paperless | token_rejected | too_old.
br_paperless_check() {
  local url tok host hf code ver major
  IFS= read -r url || true
  IFS= read -r tok || true
  url="${url%/}"
  _validate_url "$url" || { jq -nc '{ok:false, reason:"invalid"}'; return 0; }
  host="${url#*://}"; host="${host%%/*}"; host="${host%%\?*}"; host="${host%%#*}"; host="${host##*@}"   # ohne Nutzer:Passwort@
  case "$host" in \[*) host="${host%%]*}]" ;; *) host="${host%%:*}" ;; esac
  case "${host,,}" in
    localhost|localhost.*|127.*|0|0.0.0.0|\[::1\]|\[::\]|\[0:0:0:0:0:0:0:1\]|\[::ffff:127.*|\[::ffff:7f*)
      jq -nc '{ok:false, reason:"localhost"}'; return 0 ;;
  esac
  hf="$(mktemp)"
  code="$(_br_http "$hf" "${url}/api/" "$tok")"
  ver="$(tr -d '\r' <"$hf" | awk -F': *' 'tolower($1) == "x-version" { v = $2 } END { print v }')"
  rm -f "$hf"
  case "$code" in
    000) jq -nc '{ok:false, reason:"unreachable"}'; return 0 ;;
    401|403)
      if [ -n "$tok" ]; then jq -nc '{ok:false, reason:"token_rejected"}'; else jq -nc '{ok:true, reason:"reachable"}'; fi
      return 0 ;;
    200) : ;;
    *) jq -nc '{ok:false, reason:"not_paperless"}'; return 0 ;;
  esac
  if [ -z "$ver" ]; then
    if [ -n "$tok" ]; then jq -nc '{ok:false, reason:"not_paperless"}'; else jq -nc '{ok:true, reason:"reachable"}'; fi
    return 0
  fi
  major="${ver%%.*}"
  if ! printf '%s' "$major" | grep -qE '^[0-9]+$'; then jq -nc '{ok:false, reason:"not_paperless"}'; return 0; fi
  if [ "$major" -lt 3 ]; then jq -nc --arg v "$ver" '{ok:false, reason:"too_old", version:$v}'; return 0; fi
  jq -nc --arg v "$ver" '{ok:true, reason:"ok", version:$v}'
}

# tg-check — Prüfliste Nr. 10, VOR der Installation: ist der Bot schon woanders verbunden? Dieselben Abfragen wie die
#   Sperre des Installers (telegram_webhook_preflight, Paket 1, bricht eine unbeaufsichtigte Erstinstallation ohne
#   TELEGRAM_WEBHOOK_TAKEOVER=1 ab): getWebhookInfo, bei leerer Adresse getUpdates?timeout=0&limit=1 (409 = anderer
#   Abnehmer). Nur lesen, nie setWebhook/deleteWebhook, nie offset, nie drop_pending_updates. Der Wizard fragt so vorher
#   selbst und schreibt die Übernahme nur nach ausdrücklicher Wahl.
#   {"ok":true,"bot":"…","webhook_host":"…"|"","polling_conflict":bool} bzw. {"ok":false,"reason":"unauthorized|unreachable"}.
br_tg_check() {
  local me info bot
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || { jq -nc '{ok:false, reason:"unauthorized"}'; return 0; }
  me="$(tg_api_curl "$TELEGRAM_BOT_TOKEN" getMe -sS --max-time 10 2>/dev/null || true)"
  if [ -z "$me" ]; then jq -nc '{ok:false, reason:"unreachable"}'; return 0; fi
  [ "$(jq -r '.ok // false' <<<"$me" 2>/dev/null || echo false)" = true ] || { jq -nc '{ok:false, reason:"unauthorized"}'; return 0; }
  bot="$(jq -r '.result.username // ""' <<<"$me")"
  # Dieselbe Regel wie die Installer-Sperre (telegram_webhook_json, release_inputs.sh). „ours“ (zeigt schon auf diesen
  # Rechner) ist kein Konflikt.
  info="$(telegram_webhook_json 2>/dev/null || true)"
  if [ "$(jq -r '.ok // false' <<<"$info" 2>/dev/null || echo false)" != true ]; then
    jq -nc --arg r "$(jq -r '.reason // "unreachable"' <<<"$info" 2>/dev/null || echo unreachable)" \
      '{ok:false, reason:(if $r == "unreachable" then "unreachable" else "unauthorized" end)}'
    return 0
  fi
  jq -c --arg bot "$bot" '{ok:true, bot:$bot, webhook_host:(if .state == "foreign" then (.webhook_host // "") else "" end),
    polling_conflict:(.polling_conflict // false)}' <<<"$info"
}

# reach-status — Zustand des Weges nach außen für die Anzeige im Wizard, Format von reach_status_json (lib/reach.sh).
br_reach_status() { reach_status_json; }

# reach-ports — Prüfliste Nr. 13 (FritzBox-Weg): sind Port 80 und 443 auf diesem Rechner frei? {"state":"free|busy|unknown"};
#   der Wizard empfiehlt bei „busy“ den Tunnel und löscht nie etwas. rt_host_port_free (lib/runtime.sh) misst per
#   Docker-Kurzlauf und scheitert auch ohne Docker oder Probe-Image: das ist „unknown“, nicht „busy“.
br_reach_ports() {
  if ! rt_docker_ok || [ -z "${LA_PROBE_IMAGE:-}" ]; then jq -nc '{state:"unknown"}'; return 0; fi
  if rt_host_port_free 80 && rt_host_port_free 443; then jq -nc '{state:"free"}'; else jq -nc '{state:"busy"}'; fi
}

# paperless-ports — veröffentlichte Ports der Paperless-Container auf DIESEM Rechner (Vorausfüllung der Adresse, Owner-Runde
#   2026-11-06; kein Abtasten des Heimnetzes). Docker-Abfragen nur über runtime.sh (contract_lint 32):
#   rt_published_ports_json <image-teil> <container-port> -> [{"ip":"0.0.0.0","port":8010}, …]; ohne Docker oder bei
#   einem Fehler keine Ausgabe und rc 1.
#   Ausgabe {"ports":[…]}; die Entscheidung (genau ein erreichbarer Treffer) trifft flow.paperlessGuess.
br_paperless_ports() {
  local p
  # rc != 0 (kein Docker, Fehler, Funktion fehlt): keine Treffer.
  p="$(rt_published_ports_json paperless-ngx 8000 2>/dev/null)" || p='[]'
  jq -nc --argjson p "$(jq -c 'if type == "array" then . else [] end' <<<"${p:-[]}" 2>/dev/null || echo '[]')" '{ports:$p}'
}

# public-ip — öffentliche IPv4 dieses Anschlusses (MyFRITZ-Prüfung: eine Adresse wird nur vorgeschlagen, wenn sie hierauf
#   zeigt). Die Messung ist reach_public_ipv4 (lib/reach.sh), dieselbe wie für die DS-Lite-Prüfung.
#   Ausgabe {"ip":"203.0.113.7"} oder {"ip":""} (unbekannt -> der Wizard schlägt nichts vor).
br_public_ip() {
  local ip
  ip="$(reach_public_ipv4 2>/dev/null || true)"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || ip=''
  jq -nc --arg ip "$ip" '{ip:$ip}'
}

case "${1:-}" in
  questions)       br_questions ;;
  paperless-ports) br_paperless_ports ;;
  reach-ports)     br_reach_ports ;;
  validate)        [ -n "${2:-}" ] || exit 64; br_validate "$2" ;;
  paperless-check) br_paperless_check ;;
  tg-check)        br_tg_check ;;
  reach-status)    br_reach_status ;;
  public-ip)       br_public_ip ;;
  *) printf 'Aufruf: bridge.sh questions|validate <ref>|paperless-check|tg-check|reach-status|public-ip\n' >&2; exit 64 ;;
esac
