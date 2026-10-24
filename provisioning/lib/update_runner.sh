# update_runner.sh — Update im Chat (Update-Hinweis 2026-10-24): taeglicher Release-Check + Runner fuer Update-Auftraege.
#
# Gesourct von der lifeagents-CLI fuer die Arme `update --check` (systemd-Timer lifeagents-update-check, taeglich) und
# `update --run-requested` (Timer lifeagents-update-run, minuetlich) — zusammen mit common.sh, deploy_workflows.sh
# (Owner-chat_id aus der DB) und fetch_release.sh (_gh_http). Laeuft als root; n8n bleibt ohne Rechte.
#
# Ablauf (Mechanik + Begruendung -> docs/reference/provisioning.md *Update im Chat*):
#   Check:  GET /releases (anonym, 1 Abfrage) -> jq-Auszug -> core.fn_release_card (faellig? Text/Knoepfe in Owner-
#           Sprache) -> Karte per Bot-API -> erst nach 2xx core.fn_release_card_sent (Latch). Fehler = nur Log.
#   Runner: Update-Sperre (flock -n, sonst auslassen) -> core.fn_update_request_claim (haengende schliessen + offenen
#           Auftrag uebernehmen) -> Gegenpruefung (Tag-Format, Tag > VERSION, Tag = releases/latest) -> Vorab-Pruefung
#           (Platz, DB) -> Start-Meldung -> `lifeagents update --version <tag>` mit Ergebnis-Datei, Ausgabe per tee ins
#           Log -> core.fn_update_request_finish -> Ergebnis-Meldung (core.fn_update_report = die Fehler-Hilfe).
#   Der Runner traut der Auftrags-Zeile NICHT (n8n kann sie schreiben): er installiert nur das aktuelle stabile
#   releases/latest, und nur wenn es neuer ist als VERSION (Retry: gleich VERSION erlaubt).
#   Meldungen gehen direkt ueber die Bot-API (tg_api_curl), nicht ueber n8n — das Update startet n8n neu, und ein
#   gescheitertes Update kann n8n lahmlegen.
#
# Reads globals: PROVISION_GH_API, PROVISION_REPO_SLUG (common.sh), N8N_PORT (Default 5678).

UPDATE_LOG_DIR="${UPDATE_LOG_DIR:-/var/log/lifeagents}"

# update_cli [args] — der `lifeagents update`-Arm: --check | --run-requested (Timer, kehren zurueck) oder ein normales
#   Update (optional --version <tag>, --allow-downgrade; Rest geht an provision.sh) — fetch_and_run_release kehrt nie zurueck.
update_cli() {
  case "${1:-}" in
    --check)         update_check; return 0 ;;
    --run-requested) update_run_requested; return 0 ;;
  esac
  local tag=latest
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)         [ -n "${2:-}" ] || die "--version braucht ein Tag (z. B. --version v0.14.0)."; tag="$2"; shift 2 ;;
      --version=*)       tag="${1#*=}"; shift ;;
      --allow-downgrade) export LIFEAGENTS_ALLOW_DOWNGRADE=1; shift ;;
      *) break ;;
    esac
  done
  case "$tag" in *[!A-Za-z0-9._-]*|'') die "Ungültiges Tag '${tag}' (erwartet z. B. v0.14.0)." ;; esac
  fetch_and_run_release "$tag" "$@"
}
UPDATE_MIN_FREE_KB="${UPDATE_MIN_FREE_KB:-2097152}"   # 2 GB frei auf / und /var (n8n-npm-Install + Sicherung + Tarball)

# _ur_alert / _ur_notice <text> — wie warn / log, unter systemd (JOURNAL_STREAM) zusaetzlich mit Syslog-Praefix <4>/<5>:
#   die Runner-Unit laesst wegen des minuetlichen Leerlaufs nur notice+ ins Journal (LogLevelMax=notice) — Fehler und ein
#   gestartetes Update bleiben so in `journalctl -u lifeagents-update-run` sichtbar (systemd SyslogLevelPrefix=, Standard an).
_ur_alert()  { warn "$*"; if [ -n "${JOURNAL_STREAM:-}" ]; then printf '<4>%s\n' "$*" >&2; fi; return 0; }
_ur_notice() { log "$*";  if [ -n "${JOURNAL_STREAM:-}" ]; then printf '<5>%s\n' "$*" >&2; fi; return 0; }

# _ur_sql <json> <sql> — SQL (mit :'p' als jsonb-Parameter) als Superuser gegen die App-DB; Ergebnis auf stdout.
#   Die Daten gehen als psql-Variable (sauber gequotet), das SQL ueber stdin (-v wird bei -c nicht ersetzt).
_ur_sql() {
  local json="$1" sql="$2"
  printf '%s\n' "$sql" | runuser -u "$DB_SUPERUSER" -- psql -X -tA -q -v ON_ERROR_STOP=1 -d "$N8N_DB_NAME" -v p="$json" -f -
}

# _ur_installed -> Inhalt der VERSION-Datei (Tag oder 'dev'; leer = keine installierte Release-Version).
_ur_installed() { cat "$(lifeagents_version_marker)" 2>/dev/null | head -n1 | tr -d '[:space:]' || true; }

# _ur_is_tag <s> — stabiles Release-Tag vX.Y.Z (gleiche Form wie der CHECK in core.update_requests).
_ur_is_tag() { [[ "$1" =~ ^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]]; }

# _ur_semver_cmp <a> <b> -> 1|0|-1 bzw. leer (nicht vergleichbar) — die EINE SemVer-Logik lebt in der DB.
_ur_semver_cmp() {
  _ur_sql "$(jq -nc --arg a "$1" --arg b "$2" '{a:$a,b:$b}')" \
    "SELECT core.fn_semver_cmp((:'p'::jsonb)->>'a', (:'p'::jsonb)->>'b');" 2>/dev/null || true
}

# _ur_require_signature — 0, wenn diese Installation unterschriebene Releases verlangt (Phase 2: Schluesselbund in /etc).
_ur_require_signature() { [ -n "$(_release_keyring)" ]; }

# _ur_send <text> [keyboard-json] — Plain-Text (ohne parse_mode, kein Escaping) an den gepairten Owner, optional mit
#   inline_keyboard. 0 = gesendet (2xx), 1 = nicht moeglich. Token nie im argv (tg_api_curl).
_ur_send() {
  local text="$1" kb="${2:-[]}" token chat rm=()
  need_cmd curl || return 1
  token="$(owner_tg_token)"; chat="$(owner_tg_chat_id)"
  [ -n "$token" ] && [ -n "$chat" ] && [ -n "$text" ] || return 1
  if [ "$(jq -r 'length' <<<"$kb" 2>/dev/null || echo 0)" -gt 0 ]; then
    rm=(--data-urlencode "reply_markup=$(jq -c '{inline_keyboard: .}' <<<"$kb")")
  fi
  tg_api_curl "$token" sendMessage -fsS --max-time 20 -o /dev/null \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}" "${rm[@]}" >/dev/null 2>&1
}

# _ur_help_url -> die Hilfeseite "Wenn ein Update fehlschlaegt" (GitHub Pages des Repos; eine Adresse: der Slug).
_ur_help_url() {
  local owner="${PROVISION_REPO_SLUG%%/*}" repo="${PROVISION_REPO_SLUG#*/}"
  printf 'https://%s.github.io/%s/docs/update-hilfe.html' "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" "$repo"
}

# _ur_bot_up — 0, wenn n8n bereit ist (Knoepfe im Chat erreichen dann einen Empfaenger). Wartet bis 120 s: direkt nach
#   einem Update startet n8n noch (/healthz/readiness erst nach den Migrationen gruen).
_ur_bot_up() {
  local i
  for i in $(seq 1 60); do
    curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:${N8N_PORT:-5678}/healthz/readiness" 2>/dev/null && return 0
    [ "${1:-wait}" = nowait ] && return 1
    sleep 2
  done
  return 1
}

# _ur_report <request_id> <phase> [key=value ...] — Meldung zum Auftrag bauen (core.fn_update_report) und senden.
#   Zusatz-Felder (bot_up, backup, log, missing, failed, latest) als key=value; Texte/Knoepfe kommen aus der DB.
_ur_report() {
  local id="$1" phase="$2"; shift 2
  local p kv out
  p="$(jq -nc --argjson id "$id" --arg ph "$phase" --arg h "$(_ur_help_url)" --arg s "$PROVISION_REPO_SLUG" \
         '{request_id:$id, phase:$ph, help_url:$h, repo_slug:$s}')"
  for kv in "$@"; do
    case "${kv%%=*}" in
      bot_up) p="$(jq -c --argjson v "${kv#*=}" '. + {bot_up:$v}' <<<"$p")" ;;
      *)      p="$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k):$v}' <<<"$p")" ;;
    esac
  done
  out="$(_ur_sql "$p" "SELECT core.fn_update_report(:'p'::jsonb);")" || { _ur_alert "Update-Meldung nicht baubar (DB)."; return 1; }
  _ur_send "$(jq -r '.text // empty' <<<"$out")" "$(jq -c '.keyboard // []' <<<"$out")" \
    || _ur_alert "Update-Meldung konnte nicht gesendet werden (kein Token, Owner nicht verbunden oder Netz)."
}

# _ur_finish <id> <outcome> [stage] [reason_code] [changed:true|false|null] [detail]
_ur_finish() {
  local p
  p="$(jq -nc --argjson id "$1" --arg o "$2" --arg st "${3:-}" --arg rc "${4:-}" --arg ch "${5:-null}" --arg d "${6:-}" \
         '{id:$id, outcome:$o, stage:$st, reason_code:$rc, detail:$d,
           changed:(if $ch == "true" then true elif $ch == "false" then false else null end)}')"
  _ur_sql "$p" "SELECT core.fn_update_request_finish(:'p'::jsonb);" >/dev/null || _ur_alert "Auftrag ${1}: Ergebnis nicht speicherbar (DB)."
}

# _ur_code_reason <http-code> <hdr-file> -> reason_code fuer einen gescheiterten GitHub-Abruf.
_ur_code_reason() {
  case "$1" in
    000)   printf 'net' ;;
    local) printf 'disk' ;;
    404)   printf 'not_found' ;;
    *)     if _gh_rate_limited "$1" "$2"; then printf 'rate_limit'; else printf 'unknown'; fi ;;
  esac
}

# update_check — der taegliche Release-Check (`lifeagents update --check`). Immer rc 0 (ein Timer-Fehlschlag
#   ist kein Alarm wert; der naechste Lauf versucht es erneut).
update_check() {
  require_root
  lifeagents_db_name >/dev/null
  local installed work
  installed="$(_ur_installed)"
  if ! _ur_is_tag "$installed"; then
    log "Release-Check: installiert ist keine Release-Version ('${installed:-keine}') — nichts zu tun."
    return 0
  fi
  work="$(mktemp -d)"
  _ur_check_in "$work" "$installed" || true
  rm -rf -- "$work"
  return 0
}

# _ur_check_in <workdir> <installed> — Rumpf von update_check (Aufraeumen des workdir macht der Aufrufer).
_ur_check_in() {
  local work="$1" installed="$2" code json card tag
  code="$(_gh_http 'application/vnd.github+json' "${PROVISION_GH_API}/repos/${PROVISION_REPO_SLUG}/releases?per_page=20" "$work/rel.json" 30)"
  case "$code" in
    2??) ;;
    *) _ur_notice "Release-Check: GitHub antwortet ${code} ($(_ur_code_reason "$code" "$work/rel.json.hdr")) — nächster Versuch beim nächsten Lauf."; return 0 ;;
  esac
  json="$(jq -c --arg inst "$installed" --argjson sig "$(_ur_require_signature && echo true || echo false)" \
    '{installed:$inst, require_signature:$sig,
      releases:[.[]? | {tag:.tag_name, draft, prerelease, body:((.body // "")[0:4000]), html_url,
                        assets:[.assets[]?.name]}]}' "$work/rel.json")" \
    || { log "Release-Check: Antwort nicht lesbar."; return 0; }
  card="$(_ur_sql "$json" "SELECT core.fn_release_card(:'p'::jsonb);")" || { _ur_alert "Release-Check: DB nicht erreichbar."; return 0; }
  if [ "$(jq -r '.due' <<<"$card")" != true ]; then
    log "Release-Check: keine Karte fällig ($(jq -r '.reason // "?"' <<<"$card"))."
    return 0
  fi
  tag="$(jq -r '.tag' <<<"$card")"
  if _ur_send "$(jq -r '.text' <<<"$card")" "$(jq -c '.keyboard' <<<"$card")"; then
    _ur_sql "$(jq -nc --arg t "$tag" '{tag:$t}')" "SELECT core.fn_release_card_sent((:'p'::jsonb)->>'tag');" >/dev/null || true
    _ur_notice "Release-Check: Karte für ${tag} gesendet."
  else
    _ur_alert "Release-Check: Karte für ${tag} nicht gesendet — der nächste Check versucht es erneut."
  fi
  return 0
}

# _ur_free_kb <path> -> freier Platz in KB
_ur_free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# _ur_result <file> <key> — Wert aus der Ergebnis-Datei von provision.sh (KEY=VALUE, env_upsert-Format).
_ur_result() { read_env_value "$1" "$2" 2>/dev/null || true; }

# _ur_last_error <log> -> die letzte Fehlerzeile ([x] …) aus dem Lauf-Log, ohne Farbcodes, gekuerzt.
_ur_last_error() {
  sed 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null | grep -E '^\[x\]' | tail -n1 | sed 's/^\[x\] *//' | cut -c1-300 || true
}

# _ur_run_one <id> <tag> <kind> <installed> — einen uebernommenen Auftrag pruefen, ausfuehren, abschliessen, melden.
_ur_run_one() {
  local id="$1" tag="$2" kind="$3" installed="$4"
  local cmp work code latest log rf rc status stage changed reason missing failed backup bot detail

  if ! _ur_is_tag "$tag"; then
    _ur_finish "$id" failed preflight unknown false "Ungültiges Tag im Auftrag."; _ur_report "$id" result bot_up=true; return 0
  fi
  cmp="$(_ur_semver_cmp "$tag" "$installed")"
  if [ -z "$cmp" ]; then
    _ur_finish "$id" failed preflight unknown false "Installiert ist keine Release-Version (${installed:-keine})."
    _ur_report "$id" result bot_up=true; return 0
  fi
  if [ "$cmp" -lt 0 ] || { [ "$cmp" -eq 0 ] && [ "$kind" != retry ]; }; then
    _ur_finish "$id" already_current; _ur_report "$id" result bot_up=true; return 0
  fi

  work="$(mktemp -d)"
  code="$(_gh_http 'application/vnd.github+json' "${PROVISION_GH_API}/repos/${PROVISION_REPO_SLUG}/releases/latest" "$work/latest.json" 30)"
  case "$code" in
    2??) latest="$(jq -r '.tag_name // empty' "$work/latest.json" 2>/dev/null || true)" ;;
    *)   _ur_finish "$id" failed download "$(_ur_code_reason "$code" "$work/latest.json.hdr")" false "GitHub: HTTP ${code}"
         rm -rf -- "$work"; _ur_report "$id" result bot_up=true; return 0 ;;
  esac
  rm -rf -- "$work"
  if [ "$latest" != "$tag" ]; then
    _ur_finish "$id" superseded; _ur_report "$id" result bot_up=true "latest=${latest}"
    update_check   # die Karte fuer die neuere Version gleich hinterher
    return 0
  fi

  if [ "$(_ur_free_kb /)" -lt "$UPDATE_MIN_FREE_KB" ] || [ "$(_ur_free_kb /var)" -lt "$UPDATE_MIN_FREE_KB" ]; then
    _ur_finish "$id" failed preflight disk false "Frei: / $(_ur_free_kb /) KB, /var $(_ur_free_kb /var) KB (nötig ${UPDATE_MIN_FREE_KB} KB)."
    _ur_report "$id" result bot_up=true; return 0
  fi

  _ur_report "$id" start
  mkdir -p "$UPDATE_LOG_DIR"; chmod 0750 "$UPDATE_LOG_DIR"
  log="${UPDATE_LOG_DIR}/update-$(date -u +%Y%m%dT%H%M%SZ).log"
  rf="$(mktemp /run/lifeagents-update-result.XXXXXX)"
  _ur_notice "Update-Auftrag ${id}: ${installed} -> ${tag} (${kind}), Protokoll ${log}"
  rc=0
  # Linke Seite einer ||-Liste: errexit greift im Block nicht, PIPESTATUS gehoert noch der Pipeline (Exit des Updates,
  # nicht von tee). Die Sperre erbt das Kind ueber den offenen fd + LIFEAGENTS_UPDATE_LOCK_HELD (update_lock_acquire).
  {
    LIFEAGENTS_RESULT_FILE="$rf" LIFEAGENTS_UPDATE_REQUESTED=1 \
      "$(command -v lifeagents || printf '/usr/local/bin/lifeagents')" update --version "$tag" </dev/null 2>&1 \
      | tee -a "$log" >/dev/null
    rc="${PIPESTATUS[0]}"
  } || true
  chmod 0640 "$log" 2>/dev/null || true

  status="$(_ur_result "$rf" status)"; stage="$(_ur_result "$rf" stage)"; changed="$(_ur_result "$rf" changed)"
  reason="$(_ur_result "$rf" reason_code)"; missing="$(_ur_result "$rf" missing_keys)"
  failed="$(_ur_result "$rf" failed_packages)"; backup="$(_ur_result "$rf" backup)"
  rm -f -- "$rf"
  detail="$(_ur_last_error "$log")"
  if _ur_bot_up; then bot=true; else bot=false; fi

  if [ "$status" = held ]; then
    _ur_finish "$id" held "${stage:-preflight}" '' false
    _ur_report "$id" result "bot_up=$bot" "missing=${missing}" "log=${log}"
  elif [ "$rc" -eq 0 ] && [ "$status" = ok ]; then
    _ur_finish "$id" succeeded "${stage:-final}"
    _ur_report "$id" result "bot_up=$bot"
  elif [ "$rc" -eq 0 ] && [ "$status" = partial ]; then
    _ur_finish "$id" partial "${stage:-final}" "${reason:-package}" true "$detail"
    _ur_report "$id" result "bot_up=$bot" "failed=${failed}" "log=${log}" "backup=${backup}"
  else
    # Kein/unvollstaendiges Ergebnis = abgebrochen. changed unbekannt -> null (die Hilfe behandelt das vorsichtig).
    _ur_finish "$id" failed "${stage:-unknown}" "${reason:-unknown}" "${changed:-null}" "$detail"
    _ur_report "$id" result "bot_up=$bot" "log=${log}" "backup=${backup}"
  fi
  return 0
}

# update_run_requested — der minuetliche Runner (`lifeagents update --run-requested`). Immer rc 0 bei erwartbaren
#   Zustaenden (keine Auftraege, Sperre belegt), damit der Timer nicht im failed-Zustand haengt.
update_run_requested() {
  require_root
  lifeagents_db_name >/dev/null
  # Sperre nehmen, BEVOR ein Auftrag angefasst wird: unter ihr laeuft sicher kein anderes Update (provision.sh main
  # nimmt dieselbe Sperre) -> haengende Auftraege duerfen als interrupted geschlossen werden.
  update_lock_acquire || { log "Update-Sperre belegt (anderes Update/Einrichtung läuft) — nächster Lauf."; return 0; }
  local installed claim rec n i id tag kind bot
  installed="$(_ur_installed)"
  claim="$(_ur_sql "$(jq -nc --arg i "$installed" '{installed:$i}')" "SELECT core.fn_update_request_claim(:'p'::jsonb);")" \
    || { _ur_alert "Update-Runner: DB nicht erreichbar."; return 0; }

  rec="$(jq -c '.recovered // []' <<<"$claim")"
  n="$(jq -r 'length' <<<"$rec")"
  if [ "$n" -gt 0 ]; then
    if _ur_bot_up nowait; then bot=true; else bot=false; fi
    for i in $(seq 0 $((n - 1))); do
      _ur_report "$(jq -r ".[$i].id" <<<"$rec")" result "bot_up=$bot"
    done
  fi

  [ "$(jq -r '.claimed' <<<"$claim")" != null ] || return 0
  id="$(jq -r '.claimed.id' <<<"$claim")"; tag="$(jq -r '.claimed.tag' <<<"$claim")"; kind="$(jq -r '.claimed.kind' <<<"$claim")"
  _ur_run_one "$id" "$tag" "$kind" "$installed"
  return 0
}
