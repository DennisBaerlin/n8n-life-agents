# update_runner.sh — Update im Chat: Release-Check alle 2 Stunden + Runner fuer Update-Auftraege.
#
# Gesourct von der lifeagents-CLI fuer die Arme `update --check` (systemd-Timer lifeagents-update-check, alle 2 h) und
# `update --run-requested` (Timer lifeagents-update-run, minuetlich) — zusammen mit common.sh, deploy_workflows.sh
# (Owner-chat_id aus der DB) und fetch_release.sh (_gh_http). Laeuft als root; n8n bleibt ohne Rechte.
#
# Ablauf (Mechanik + Begruendung -> docs/reference/provisioning.md *Update im Chat*):
#   Check:  GET /releases (anonym, 1 Abfrage) -> jq-Auszug -> core.fn_release_card (faellig? Text/Knoepfe in Owner-
#           Sprache) -> Karte per Bot-API -> erst nach 2xx core.fn_release_card_sent (Latch). Fehler = nur Log.
#   Runner: Update-Sperre (flock -n, sonst auslassen) -> core.fn_update_request_claim (haengende schliessen + offenen
#           Auftrag uebernehmen) -> Gegenpruefung (Tag-Format, Tag > VERSION, Tag = releases/latest) -> Vorab-Pruefung
#           (Platz, DB) -> Fortschritts-Helfer (lib/update_progress.sh) -> `lifeagents update --version <tag>` mit Ergebnis-
#           Datei, Ausgabe per tee ins Log -> core.fn_update_request_finish (Ergebnis zuerst) -> Ergebnis-Meldung ueber
#           _ur_reports_flush (core.fn_update_report = die Fehler-Hilfe). Nicht Zugestelltes holt der naechste Lauf nach.
#   Der Runner traut der Auftrags-Zeile nicht (n8n kann sie schreiben): er installiert nur das aktuelle stabile
#   releases/latest, und nur wenn es neuer ist als VERSION (Retry: gleich VERSION erlaubt).
#   Meldungen gehen direkt ueber die Bot-API (tg_api_curl), nicht ueber n8n — das Update startet n8n neu, und ein
#   gescheitertes Update kann n8n lahmlegen.
#
# Reads globals: PROVISION_GH_API, PROVISION_REPO_SLUG (common.sh), N8N_PORT (Default 5678).

# shellcheck source=update_progress.sh
. "$(dirname "${BASH_SOURCE[0]}")/update_progress.sh"

# Verbund: auf dem Volume var_la (das Protokoll eines Updates muss den master-Wechsel ueberleben).
if rt_is_compose; then UPDATE_LOG_DIR="${UPDATE_LOG_DIR:-/var/lib/lifeagents/log}"; fi
UPDATE_LOG_DIR="${UPDATE_LOG_DIR:-/var/log/lifeagents}"

# update_cli [args] — der `lifeagents update`-Arm: --check | --run-requested (Timer, kehren zurueck) oder ein normales
#   Update (optional --version <tag>, --allow-downgrade; Rest geht an provision.sh) — fetch_and_run_release kehrt nie zurueck.
update_cli() {
  # Aeussere Zeitgrenze um den ganzen Tick (UPDATE_TICK_TIMEOUT_S): der Tick laeuft als zweiter Prozess unter _ur_step, mit ihm
  #   lifeagents_version_heal und die docker-Aufrufe zwischen den Schritten (haengt Docker selbst, stuende der Tick sonst).
  if [ "${1:-}" = --tick ] && [ -z "${LA_TICK_INNER:-}" ]; then
    export LA_TICK_INNER=1; _ur_step "$UPDATE_TICK_TIMEOUT_S" update --tick; return 0
  fi
  case "${1:-}" in --help|-h) ;; *) lifeagents_version_heal || true ;; esac   # vor dem Lesen von VERSION (common.sh)
  case "${1:-}" in
    --check)         update_check "$([ "${2:-}" = --scheduled ] && printf scheduled)"; return 0 ;;
    --run-requested) update_run_requested; return 0 ;;
    --tick)          update_tick; return 0 ;;
  esac
  # Alles wird vor dem Laden geprueft: eine unbekannte Option liefe sonst bis provision.sh durch, im Verbund startete sie
  # vorher schon den master-Wechsel. Weitergereicht wird nur, was provision.sh parse_args fuer einen normalen Lauf kennt
  # (nicht --uninstall/--purge-data/--unattended/--yes: dafuer gibt es eigene Befehle).
  local tag=latest pass=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)         _ur_update_usage; return 0 ;;
      --version)         [ -n "${2:-}" ] || die "--version braucht ein Tag (z. B. --version v0.14.0)."; tag="$2"; shift 2 ;;
      --version=*)       tag="${1#*=}"; shift ;;
      --allow-downgrade) export LIFEAGENTS_ALLOW_DOWNGRADE=1; shift ;;
      --profile|--domain|--trusted-proxies|--trusted-proxy|--packages)
        case "${2:-}" in ''|-*) die "$1 braucht einen Wert (lifeagents update --help)." ;; esac
        pass+=("$1" "$2"); shift 2 ;;
      --profile=*|--domain=*|--trusted-proxies=*|--trusted-proxy=*|--packages=*|--apply-network|--core-only|--verbose)
        pass+=("$1"); shift ;;
      *) die "Unbekannte Option für update: $1 — es wurde nichts geändert (lifeagents update --help)." ;;
    esac
  done
  case "$tag" in *[!A-Za-z0-9._-]*|'') die "Ungültiges Tag '${tag}' (erwartet z. B. v0.14.0)." ;; esac
  # Vor dem Laden und damit vor jedem master-Wechsel: die Sperre des Verbs sitzt hier (der Chat-Runner ruft denselben Weg;
  # rollback und provision.sh: upgrade_guard.sh upgrade_move_guard).
  if la_move_open; then die "$(la_move_text)"; fi
  fetch_and_run_release "$tag" "${pass[@]}"
}

# _ur_update_usage — Hilfe zu `lifeagents update` (stderr wie die Hilfe der CLI).
_ur_update_usage() {
  cat >&2 <<'EOF'
Usage: lifeagents update [--version <tag>] [--allow-downgrade] [Einrichtungs-Optionen]
  Neuestes Release (oder <tag>) laden, Echtheit prüfen und einspielen. Braucht root.
  --version <tag>     genau dieses Release (z. B. v0.48.1)
  --allow-downgrade   älter als installiert zulassen (besser: lifeagents rollback)
  Weitergereicht an die Einrichtung: --profile, --domain, --trusted-proxies, --packages, --apply-network,
  --core-only, --verbose
EOF
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
  printf '%s\n' "$sql" | pg_su_psql -X -tA -q -v ON_ERROR_STOP=1 -d "$N8N_DB_NAME" -v p="$json" -f -
}

# _ur_installed -> Inhalt der VERSION-Datei (Tag oder 'dev'; leer = keine installierte Release-Version).
_ur_installed() { cat "$(lifeagents_version_marker)" 2>/dev/null | head -n1 | tr -d '[:space:]' || true; }

# _ur_is_tag <s> — stabiles Release-Tag vX.Y.Z (gleiche Form wie der CHECK in core.update_requests).
_ur_is_tag() { [[ "$1" =~ ^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]]; }

# _ur_semver_cmp <a> <b> -> 1|0|-1 bzw. leer (nicht vergleichbar) — die eine SemVer-Logik lebt in der DB.
_ur_semver_cmp() {
  _ur_sql "$(jq -nc --arg a "$1" --arg b "$2" '{a:$a,b:$b}')" \
    "SELECT core.fn_semver_cmp((:'p'::jsonb)->>'a', (:'p'::jsonb)->>'b');" 2>/dev/null || true
}

# _ur_require_signature — 0, wenn diese Installation unterschriebene Releases verlangt (Schluesselbund in /etc).
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

# _ur_busy_s <zeitgrenze_s> -> busy-Dauer fuer ein Lebenszeichen: Zeitgrenze des Schritts + KILL-Frist, hoechstens 4 h
#   (CHECK in core.heartbeats). Danach zaehlt der Waechter wieder, falls der Schritt haengt oder starb.
_ur_busy_s() { local s=$(( $1 + UPDATE_STEP_KILL_S )); [ "$s" -le 14400 ] || s=14400; printf '%s' "$s"; }

# _ur_n8n_port -> Port aus Prozess-Env, sonst n8n.env, sonst 5678 (die CLI laedt n8n.env nicht).
_ur_n8n_port() {
  local p="${N8N_PORT:-}"
  [ -n "$p" ] || p="$(read_env_value "${N8N_ENV_FILE:-/etc/n8n/n8n.env}" N8N_PORT 2>/dev/null || true)"
  printf '%s' "${p:-5678}"
  return 0
}

# _ur_bot_ready — 0, wenn der Bot antwortet: n8n bereit und Orchestrator aktiv. Ohne API-Schluessel (frueher Abbruch der
#   Einrichtung) bleibt nur Readiness; ein API-Fehler zaehlt als nicht bereit.
_ur_bot_ready() {
  local key st port
  port="$(_ur_n8n_port)"
  curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:${port}/healthz/readiness" 2>/dev/null || return 1
  key="$(read_env_value "$(lifeagents_env_file core)" N8N_API_KEY 2>/dev/null || true)"
  [ -n "$key" ] || return 0
  st="$(n8n_orchestrator_state "$key" "http://127.0.0.1:${port}")"
  [ "${st#*$'\t'}" = true ]
}

# _ur_bot_up — 0, wenn der Bot antwortet (Knoepfe im Chat erreichen dann einen Empfaenger). Wartet bis 120 s: direkt nach
#   einem Update startet n8n noch (/healthz/readiness erst nach den Migrationen gruen).
_ur_bot_up() {
  local i
  for i in $(seq 1 "${UPDATE_BOT_WAIT_TRIES:-60}"); do
    _ur_bot_ready && return 0
    [ "${1:-wait}" = nowait ] && return 1
    sleep 2
  done
  return 1
}

# _ur_report <request_id> <phase> [key=value ...] — Meldung zum Auftrag bauen (core.fn_update_report) und senden; erst nach
#   2xx gilt sie als zugestellt. Zusatz-Felder (bot_up, backup, log, missing, failed, latest) als key=value; Texte/Knoepfe
#   kommen aus der DB, die Befehle darin (cli, cli_tty) aus rt_cli_hint. Immer rc 0: unter set -e darf eine Meldung nie den
#   Runner beenden.
_ur_report() {
  local id="$1" phase="$2"; shift 2
  local p kv out
  p="$(jq -nc --argjson id "$id" --arg ph "$phase" --arg h "$(lifeagents_help_url)" --arg s "$PROVISION_REPO_SLUG" \
         --arg c "$(rt_cli_hint)" --arg ct "$(rt_cli_hint tty)" \
         '{request_id:$id, phase:$ph, help_url:$h, repo_slug:$s, cli:$c, cli_tty:$ct}')"
  for kv in "$@"; do
    case "${kv%%=*}" in
      bot_up) p="$(jq -c --argjson v "${kv#*=}" '. + {bot_up:$v}' <<<"$p")" ;;
      *)      p="$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k):$v}' <<<"$p")" ;;
    esac
  done
  out="$(_ur_sql "$p" "SELECT core.fn_update_report(:'p'::jsonb);" 2>/dev/null)" || { log "Update-Meldung nicht baubar (DB)."; return 0; }
  if [ "$phase" = result ]; then _up_close "$id" "$(jq -r '.class // empty' <<<"$out")"; fi
  if _ur_send "$(jq -r '.text // empty' <<<"$out")" "$(jq -c '.keyboard // []' <<<"$out")"; then
    _ur_sql "$(jq -nc --argjson i "$id" '{id:$i}')" "SELECT core.fn_update_report_sent(:'p'::jsonb);" >/dev/null 2>&1 || true
    _up_forget "$id"
  else
    log "Update-Meldung nicht zugestellt (Token, Verbindung oder Netz) — der nächste Lauf versucht es erneut."
  fi
  return 0
}

# _ur_lock_release — Update-Sperre abgeben: Telegram-Aufrufe duerfen ein Terminal-Update nie aufhalten (es wartet nur 30 s).
#   Nur fd 9 schliessen: jede weitere Umleitung an einem `exec` ohne Befehl gilt fuer den Rest des Prozesses (ein `2>/dev/null`
#   hier naehme dem Runner alle spaeteren Meldungen; Test tests/mock_runtime/shell_trap_cases.sh SH-B).
_ur_lock_release() { exec 9>&-; unset LIFEAGENTS_UPDATE_LOCK_HELD; return 0; }

# _ur_reports_flush [auftrag] — offene Ergebnis-Meldungen zustellen. Der erste Aufruf fragt n8n nicht (Leerlauf jede Minute).
#   Ohne die Faellig-fn (neuer master bricht beim Umstieg vor dem Schema-Schritt ab) geht <auftrag> direkt hinaus. Immer rc 0.
_ur_reports_flush() {
  local due n i bot id direct="${1:-}"
  local -a kv
  _ur_lock_release
  if ! due="$(_ur_sql '{}' "SELECT core.fn_update_report_due(:'p'::jsonb);" 2>/dev/null)"; then
    [ -n "$direct" ] || return 0
    if _ur_bot_up nowait; then bot=true; else bot=false; fi
    _ur_report "$direct" result "bot_up=$bot"
    return 0
  fi
  [ -n "$due" ] && [ "$due" != '[]' ] || return 0
  if _ur_bot_up nowait; then bot=true; else bot=false; fi
  due="$(_ur_sql "$(jq -nc --argjson b "$bot" '{bot_up:$b}')" "SELECT core.fn_update_report_due(:'p'::jsonb);" 2>/dev/null || true)"
  [ -n "$due" ] || return 0
  n="$(jq -r 'length' <<<"$due" 2>/dev/null || echo 0)"
  [ "$n" -gt 0 ] || return 0
  for i in $(seq 0 $((n - 1))); do
    id="$(jq -r ".[$i].id" <<<"$due")"
    mapfile -t kv < <(jq -r ".[$i].params | to_entries[] | \"\(.key)=\(.value)\"" <<<"$due")
    _ur_report "$id" result "bot_up=$bot" "${kv[@]}"
  done
  return 0
}

# _ur_finish <id> <outcome> [stage] [reason_code] [changed:true|false|null] [detail] [key=value ...] — Ergebnis festhalten und
#   die Meldung als faellig vormerken; key=value sind ihre Zusatz-Felder (backup, log, missing, failed, latest).
_ur_finish() {
  local p kv report='{}' id="$1" o="$2" st="${3:-}" rc="${4:-}" ch="${5:-null}" d="${6:-}"
  if [ "$#" -gt 6 ]; then
    shift 6
    for kv in "$@"; do report="$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k):$v}' <<<"$report")"; done
  fi
  p="$(jq -nc --argjson id "$id" --arg o "$o" --arg st "$st" --arg rc "$rc" --arg ch "$ch" --arg d "$d" --argjson rep "$report" \
         '{id:$id, outcome:$o, stage:$st, reason_code:$rc, detail:$d, report:$rep,
           changed:(if $ch == "true" then true elif $ch == "false" then false else null end)}')"
  _ur_sql "$p" "SELECT core.fn_update_request_finish(:'p'::jsonb);" >/dev/null || _ur_alert "Auftrag ${id}: Ergebnis nicht speicherbar (DB)."
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

# _ur_outcome <decided|undecided> — meldet dem Tick (UPDATE_CHECK_OUTCOME_FILE, nur dort gesetzt), ob der Check eine Entscheidung
#   getroffen hat (Karte gesendet, aktuell, schon gemeldet, nicht zustaendig) oder nichts ausrichten konnte (Sperre, Netz, DB,
#   Karte nicht gesendet, ausserhalb des Erinnerungs-Fensters). Nur im ersten Fall gilt das volle Pruefintervall.
_ur_outcome() { if [ -n "${UPDATE_CHECK_OUTCOME_FILE:-}" ]; then echo "$1" > "$UPDATE_CHECK_OUTCOME_FILE" 2>/dev/null || true; fi; }

# update_check [scheduled] — der Release-Check (`lifeagents update --check`). Immer rc 0 (ein Timer-Fehlschlag
#   ist kein Alarm wert; der naechste Lauf versucht es erneut). `scheduled` (Timer/Tick, alle 2 h) laesst die DB die
#   Karte auf das Erinnerungs-Fenster beschraenken; Handaufruf und Folge-Check nach einem Update schicken sofort.
update_check() {
  require_root
  lifeagents_db_name >/dev/null
  local installed work scheduled=false
  [ "${1:-}" = scheduled ] && scheduled=true
  # Eine Karte, die sich nicht ausfuehren laesst, ist Rauschen: solange der Umzug offen ist, kommt keine (ohne Netzabruf).
  if la_move_open; then
    log "Release-Check: Umzug offen — keine Update-Karte bis lifeagents move done."
    heartbeat_record check skipped
    _ur_outcome decided
    return 0
  fi
  # Mitten in einem Update liest der Check noch die alte VERSION und schickt eine ueberfluessige Karte. Die Sperre
  # nur pruefen, nie nehmen (der Check ist kein Update); ein Lauf, der sie selbst haelt (Folge-Check), prueft weiter.
  # Mit Wartezeit: der Minuten-Runner haelt die Sperre zu jeder vollen Minute kurz; ein Update haelt sie Minuten.
  if [ "${LIFEAGENTS_UPDATE_LOCK_HELD:-0}" != 1 ] && ! update_lock_free "${UPDATE_CHECK_LOCK_WAIT_S:-20}"; then
    log "Release-Check: Update-Sperre belegt (Update/Einrichtung läuft) — ausgelassen, nächster Lauf."
    _ur_outcome undecided
    return 0
  fi
  installed="$(_ur_installed)"
  if ! _ur_is_tag "$installed"; then
    log "Release-Check: installiert ist keine Release-Version ('${installed:-keine}') — nichts zu tun."
    # Release-Profil ohne Versionsnummer (leer/'dev') bekommt nie Update-Hinweise -> Waechter meldet es; ein benannter
    # Entwickler-Stand dev-<rev> oder ein anderes Profil ist gewollt still.
    if [ "$(_install_profile)" = release ] && ! version_is_named "$installed"; then heartbeat_record check not_release
    else heartbeat_record check skipped; fi
    _ur_outcome decided
    return 0
  fi
  work="$(mktemp -d)"
  _ur_check_in "$work" "$installed" "$scheduled" || true
  rm -rf -- "$work"
  return 0
}

# _ur_check_in <workdir> <installed> <scheduled:true|false> — Rumpf von update_check (Aufraeumen des workdir macht der Aufrufer).
_ur_check_in() {
  local work="$1" installed="$2" scheduled="${3:-false}" code json card tag
  code="$(_gh_http 'application/vnd.github+json' "${PROVISION_GH_API}/repos/${PROVISION_REPO_SLUG}/releases?per_page=20" "$work/rel.json" 30)"
  case "$code" in
    2??) ;;
    *) _ur_notice "Release-Check: GitHub antwortet ${code} ($(_ur_code_reason "$code" "$work/rel.json.hdr")) — nächster Versuch beim nächsten Lauf."; _ur_outcome undecided; return 0 ;;
  esac
  json="$(jq -c --arg inst "$installed" --argjson sig "$(_ur_require_signature && echo true || echo false)" \
    --argjson sched "$scheduled" \
    '{installed:$inst, require_signature:$sig, scheduled:$sched,
      releases:[.[]? | {tag:.tag_name, draft, prerelease, body:((.body // "")[0:4000]), html_url,
                        assets:[.assets[]?.name]}]}' "$work/rel.json")" \
    || { log "Release-Check: Antwort nicht lesbar."; _ur_outcome undecided; return 0; }
  card="$(_ur_sql "$json" "SELECT core.fn_release_card(:'p'::jsonb);")" || { _ur_alert "Release-Check: DB nicht erreichbar."; _ur_outcome undecided; return 0; }
  heartbeat_record check ok   # der Check selbst hat gearbeitet; ob die Karte ankommt, meldet _ur_alert
  if [ "$(jq -r '.due' <<<"$card")" != true ]; then
    local why; why="$(jq -r '.reason // "?"' <<<"$card")"
    log "Release-Check: keine Karte fällig (${why})."
    # Ausserhalb des Erinnerungs-Fensters ist nichts entschieden: die Karte steht noch aus.
    if [ "$why" = outside_window ]; then _ur_outcome undecided; else _ur_outcome decided; fi
    return 0
  fi
  tag="$(jq -r '.tag' <<<"$card")"
  if _ur_send "$(jq -r '.text' <<<"$card")" "$(jq -c '.keyboard' <<<"$card")"; then
    _ur_sql "$(jq -nc --arg t "$tag" '{tag:$t}')" "SELECT core.fn_release_card_sent((:'p'::jsonb)->>'tag');" >/dev/null || true
    _ur_notice "Release-Check: Karte für ${tag} gesendet."
    _ur_outcome decided
  else
    _ur_outcome undecided
    _ur_alert "Release-Check: Karte für ${tag} nicht gesendet — der nächste Check versucht es erneut."
  fi
  return 0
}

# _ur_free_kb <path> -> freier Platz in KB
_ur_free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# _ur_result <file> <key> — Wert aus der Ergebnis-Datei von provision.sh (KEY=VALUE, env_upsert-Format).
_ur_result() { read_env_value "$1" "$2" 2>/dev/null || true; }

# _ur_logs_prune — alte Update-Protokolle raeumen: die neuesten UPDATE_LOG_KEEP bleiben immer (die letzten Meldungen nennen
#   ihren Pfad), darueber hinaus geht nur, was aelter als UPDATE_LOG_MAX_DAYS Tage ist. Nur update-*.log. Immer rc 0.
UPDATE_LOG_KEEP="${UPDATE_LOG_KEEP:-10}"
UPDATE_LOG_MAX_DAYS="${UPDATE_LOG_MAX_DAYS:-30}"
_ur_logs_prune() {
  local f
  find "$UPDATE_LOG_DIR" -maxdepth 1 -type f -name 'update-*.log' -printf '%T@\t%p\n' 2>/dev/null \
    | sort -rn | tail -n +$((UPDATE_LOG_KEEP + 1)) | cut -f2- \
    | while IFS= read -r f; do
        if [ -n "$(find "$f" -maxdepth 0 -mtime +"$UPDATE_LOG_MAX_DAYS" 2>/dev/null)" ]; then rm -f -- "$f"; fi
      done
  return 0
}

# _ur_last_error <log> -> die letzte Fehlerzeile ([x] …) aus dem Lauf-Log, ohne Farbcodes, gekuerzt.
_ur_last_error() {
  sed 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null | grep -E '^\[x\]' | tail -n1 | sed 's/^\[x\] *//' | cut -c1-300 || true
}

# _ur_run_one <id> <tag> <kind> <installed> — einen uebernommenen Auftrag pruefen, ausfuehren, abschliessen, melden.
_ur_run_one() {
  local id="$1" tag="$2" kind="$3" installed="$4"
  local cmp work code latest log rf rc

  # Ein Auftrag aus einer Karte von vor dem Umzug: vorhandener Grund „locked“, ohne Update und ohne Netz.
  if la_move_open; then
    _ur_finish "$id" failed preflight locked false "Umzug offen — $(la_move_text)"
    _ur_reports_flush; return 0
  fi
  if ! _ur_is_tag "$tag"; then
    _ur_finish "$id" failed preflight unknown false "Ungültiges Tag im Auftrag."; _ur_reports_flush; return 0
  fi
  cmp="$(_ur_semver_cmp "$tag" "$installed")"
  if [ -z "$cmp" ]; then
    _ur_finish "$id" failed preflight unknown false "Installiert ist keine Release-Version (${installed:-keine})."
    _ur_reports_flush; return 0
  fi
  if [ "$cmp" -lt 0 ] || { [ "$cmp" -eq 0 ] && [ "$kind" != retry ]; }; then
    _ur_finish "$id" already_current; _ur_reports_flush; return 0
  fi

  work="$(mktemp -d)"
  code="$(_gh_http 'application/vnd.github+json' "${PROVISION_GH_API}/repos/${PROVISION_REPO_SLUG}/releases/latest" "$work/latest.json" 30)"
  case "$code" in
    2??) latest="$(jq -r '.tag_name // empty' "$work/latest.json" 2>/dev/null || true)" ;;
    *)   _ur_finish "$id" failed download "$(_ur_code_reason "$code" "$work/latest.json.hdr")" false "GitHub: HTTP ${code}"
         rm -rf -- "$work"; _ur_reports_flush; return 0 ;;
  esac
  rm -rf -- "$work"
  if [ "$latest" != "$tag" ]; then
    _ur_finish "$id" superseded '' '' null '' "latest=${latest}"; _ur_reports_flush
    update_check   # die Karte fuer die neuere Version gleich hinterher
    return 0
  fi

  if [ "$(_ur_free_kb /)" -lt "$UPDATE_MIN_FREE_KB" ] || [ "$(_ur_free_kb /var)" -lt "$UPDATE_MIN_FREE_KB" ]; then
    _ur_finish "$id" failed preflight disk false "Frei: / $(_ur_free_kb /) KB, /var $(_ur_free_kb /var) KB (nötig ${UPDATE_MIN_FREE_KB} KB)."
    _ur_reports_flush; return 0
  fi

  mkdir -p "$UPDATE_LOG_DIR"; chmod 0750 "$UPDATE_LOG_DIR"; _ur_logs_prune
  log="${UPDATE_LOG_DIR}/update-$(date -u +%Y%m%dT%H%M%SZ).log"
  rf="$(mktemp /run/lifeagents-update-result.XXXXXX)"
  _ur_notice "Update-Auftrag ${id}: ${installed} -> ${tag} (${kind}), Protokoll ${log}"
  _up_start "$id" "$rf" || true
  rc=0
  # LIFEAGENTS_UPDATE_REQUEST_ID: im Docker-Verbund merkt sich der master-Wechsel den Auftrag (lib/master_swap.sh), damit der
  # neue master ihn abschliesst.
  # Linke Seite einer ||-Liste: errexit greift im Block nicht, PIPESTATUS gehoert noch der Pipeline (Exit des Updates,
  # nicht von tee). Die Sperre erbt das Kind ueber den offenen fd + LIFEAGENTS_UPDATE_LOCK_HELD (update_lock_acquire).
  {
    LIFEAGENTS_RESULT_FILE="$rf" LIFEAGENTS_UPDATE_REQUESTED=1 LIFEAGENTS_UPDATE_REQUEST_ID="$id" \
      "$(command -v lifeagents || printf '/usr/local/bin/lifeagents')" update --version "$tag" </dev/null 2>&1 \
      | tee -a "$log" >/dev/null
    rc="${PIPESTATUS[0]}"
  } || true
  chmod 0640 "$log" 2>/dev/null || true
  if [ "$(_ur_result "$rf" status)" = handoff ]; then
    # Docker-Verbund: der Helfer wechselt gleich den master, der neue schliesst den Auftrag ab (lib/master_swap.sh).
    _up_stop
    rm -f -- "$rf"
    _ur_notice "Update-Auftrag ${id}: an den master-Wechsel übergeben — der neue master setzt fort."
    return 0
  fi
  _ur_conclude "$id" "$rc" "$rf" "$log"
  return 0
}

# _ur_conclude <id> <exit-code> <ergebnis-datei> <log> — Ergebnis eines Update-Laufs lesen, Auftrag abschliessen, melden
#   (Chat-Runner und Fortsetzung nach einem master-Wechsel). Loescht die Ergebnis-Datei.
_ur_conclude() {
  local id="$1" rc="$2" rf="$3" log="$4" status stage changed reason missing failed backup detail
  status="$(_ur_result "$rf" status)"; stage="$(_ur_result "$rf" stage)"; changed="$(_ur_result "$rf" changed)"
  reason="$(_ur_result "$rf" reason_code)"; missing="$(_ur_result "$rf" missing_keys)"
  failed="$(_ur_result "$rf" failed_packages)"; backup="$(_ur_result "$rf" backup)"
  detail="$(_ur_last_error "$log")"

  # Das Ergebnis steht zuerst in der DB, bevor auf Helfer, n8n oder Telegram gewartet wird.
  if [ "$status" = held ]; then
    _ur_finish "$id" held "${stage:-preflight}" '' false '' "missing=${missing}" "log=${log}"
  elif [ "$rc" -eq 0 ] && [ "$status" = ok ]; then
    _ur_finish "$id" succeeded "${stage:-final}"
  elif [ "$rc" -eq 0 ] && [ "$status" = partial ]; then
    _ur_finish "$id" partial "${stage:-final}" "${reason:-package}" true "$detail" "failed=${failed}" "log=${log}" "backup=${backup}"
  else
    # Kein/unvollstaendiges Ergebnis = abgebrochen. changed unbekannt -> null (die Hilfe behandelt das vorsichtig).
    _ur_finish "$id" failed "${stage:-unknown}" "${reason:-unknown}" "${changed:-null}" "$detail" "log=${log}" "backup=${backup}"
  fi
  # Der Helfer liest die Ergebnis-Datei, also erst nach ihm loeschen.
  _up_stop
  rm -f -- "$rf"
  _ur_lock_release
  _ur_bot_up >/dev/null 2>&1 || true
  _ur_reports_flush "$id"
  return 0
}

# update_run_requested — der minuetliche Runner (`lifeagents update --run-requested`). Immer rc 0 bei erwartbaren
#   Zustaenden (keine Auftraege, Sperre belegt), damit der Timer nicht im failed-Zustand haengt.
update_run_requested() {
  require_root
  lifeagents_db_name >/dev/null
  # Lebenszeichen vor der Sperre: auch wenn ein Terminal-Update oder die Einrichtung die Sperre haelt, lebt die Schleife.
  heartbeat_record loop ok
  # Sperre nehmen, bevor ein Auftrag angefasst wird: unter ihr laeuft sicher kein anderes Update (provision.sh main
  # nimmt dieselbe Sperre) -> haengende Auftraege duerfen als interrupted geschlossen werden.
  update_lock_acquire || { log "Update-Sperre belegt (anderes Update/Einrichtung läuft) — nächster Lauf."; return 0; }
  local installed claim id tag kind
  # Docker-Verbund: ein offener master-Wechsel geht vor jeden neuen Auftrag — und vor dem Schliessen haengender Auftraege,
  # denn sein Auftrag steht bis zum Abschluss offen (lib/master_swap.sh).
  if rt_is_compose && master_swap_pending; then _ur_swap_continue; return 0; fi
  installed="$(_ur_installed)"
  claim="$(_ur_sql "$(jq -nc --arg i "$installed" '{installed:$i, report:true}')" "SELECT core.fn_update_request_claim(:'p'::jsonb);")" \
    || { _ur_alert "Update-Runner: DB nicht erreichbar."; return 0; }
  # Ein erholter, unterbrochener Lauf (Zeitgrenze, Neustart) kann nach upgrade_prepare gestorben sein: n8n steht dann, bis das
  # naechste Update den Merkzettel fortsetzt -> wieder an (der Merkzettel bleibt). Pfad wie upgrade_guard.sh UPGRADE_MARKER,
  # das die CLI im update-Arm nicht laedt.
  if [ -f "${UPGRADE_MARKER:-/var/lib/lifeagents/upgrade.pending}" ] \
     && [ "$(jq -r '[.recovered[]? | select(.outcome == "interrupted")] | length' <<<"$claim" 2>/dev/null || echo 0)" -gt 0 ]; then
    _ur_alert "Update-Runner: ein Update wurde unterbrochen — n8n wird wieder gestartet; 'lifeagents update' setzt es fort."
    svc_start n8n 2>/dev/null || true
  fi

  if [ "$(jq -r '.claimed' <<<"$claim")" = null ]; then
    _ur_reports_flush
    _ur_menu_refresh
    return 0
  fi
  id="$(jq -r '.claimed.id' <<<"$claim")"; tag="$(jq -r '.claimed.tag' <<<"$claim")"; kind="$(jq -r '.claimed.kind' <<<"$claim")"
  heartbeat_record loop busy "$(_ur_busy_s "$UPDATE_RUN_TIMEOUT_S")"   # ein Update haelt die Schleife bis zu 2 h an
  _ur_run_one "$id" "$tag" "$kind" "$installed"   # ein Update setzt am Ende ohnehin alle Menues (und schliesst den Auftrag)
  heartbeat_record loop ok   # busy nur, solange der Schritt laeuft (sonst zaehlte der Waechter bis zur Zeitgrenze nicht)
  return 0
}

# _ur_menu_refresh — zweite Auftragsart desselben Runners: offener Menue-Auftrag der Mini-App (core.menu_refresh; Kopplung,
#   Entkoppeln, Rollen-/Sprachwechsel, app.enabled/audience) -> nur die Knoepfe neu setzen (_set_bot_menu_buttons, ohne
#   Befehlsmenues, ohne Update). Vorher die Update-Sperre freigeben: der Menue-Lauf hat seine eigene, und ein Terminal-
#   Update wartet nur 30 s auf die Update-Sperre (Telegram-Aufrufe duerfen es nie aufhalten). Offen-Pruefung in der DB
#   (requested_gen > done_gen, Wartezeit nach Fehlschlag), sonst still — der Leerlauf erzeugt kein Journal.
_ur_menu_refresh() {
  _ur_lock_release
  local claim gen token
  claim="$(_ur_sql '{}' "SELECT core.fn_menu_refresh_claim();" 2>/dev/null || true)"
  [ -n "$claim" ] || return 0
  [ "$(jq -r '.open // false' <<<"$claim" 2>/dev/null || true)" = true ] || return 0
  gen="$(jq -r '.gen // 0' <<<"$claim")"
  token="${TELEGRAM_BOT_TOKEN:-}"
  [ -n "$token" ] || token="$(read_env_value "$(lifeagents_env_file core)" TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
  if [ -z "$token" ]; then
    # als Fehlschlag verbuchen: Wartezeit 10 Min, beim dritten Mal aufgeben (sonst jede Minute dieselbe Warnung)
    _ur_alert "Übersicht-Knopf: kein Bot-Token in core.env — Menü-Auftrag wartet."
    _ur_sql "$(jq -nc --argjson g "${gen:-0}" '{gen:$g}')" \
      "SELECT core.fn_menu_refresh_finish((:'p'::jsonb->>'gen')::bigint, false);" >/dev/null 2>&1 || true
    return 0
  fi
  need_cmd curl || return 0
  [ -n "${REPO_ROOT:-}" ] || REPO_ROOT="${LIFEAGENTS_LIB:-/usr/local/lib/lifeagents}"
  _ur_notice "Übersicht-Knopf: Haushalt oder Einstellung geändert — Menü-Knöpfe werden neu gesetzt."
  _set_bot_menu_buttons "$token"
  return 0
}

# _ur_swap_continue — Rolle 3 des master-Wechsels (lib/master_swap.sh): im neuen master provision.sh aus dem Image-Baum
#   fahren und den Auftrag abschliessen; nach einem Rueckweg des Helfers den Auftrag als gescheitert melden (nichts
#   geaendert). Laeuft unter der Update-Sperre (update_run_requested).
_ur_swap_continue() {
  local what id tag mode allow log rf rc=0 drop note
  what="$(master_swap_resolve)"
  id="$(_swap_get REQUEST_ID)"; tag="$(_swap_get TAG)"; mode="$(_swap_get MODE)"; allow="$(_swap_get ALLOW_DOWNGRADE)"
  case "$what" in
    none|wait) return 0 ;;
    apply)
      heartbeat_record loop busy "$(_ur_busy_s "$UPDATE_RUN_TIMEOUT_S")"
      _swap_set PHASE applying
      mkdir -p "$UPDATE_LOG_DIR"; chmod 0750 "$UPDATE_LOG_DIR"; _ur_logs_prune
      log="${UPDATE_LOG_DIR}/update-$(date -u +%Y%m%dT%H%M%SZ).log"
      rf="$(mktemp /tmp/lifeagents-update-result.XXXXXX)"
      _ur_notice "master-Wechsel auf ${tag} steht — Einrichtung läuft weiter (${mode:-update}), Protokoll ${log}"
      if [ -n "$id" ]; then _up_start "$id" "$rf" || true; fi
      {
        RELEASE_TAG="$tag" LIFEAGENTS_RESULT_FILE="$rf" LIFEAGENTS_UPDATE_REQUESTED=1 LIFEAGENTS_ALLOW_DOWNGRADE="${allow:-0}" \
          bash "${MASTER_IMAGE_TREE}/provisioning/provision.sh" </dev/null 2>&1 | tee -a "$log" >/dev/null
        rc="${PIPESTATUS[0]}"
      } || true
      chmod 0640 "$log" 2>/dev/null || true
      # Rueckweg (lifeagents rollback): erst nach erfolgreichem Einspielen die beiseitegelegte DB loeschen + Owner melden.
      drop="$(_swap_get DROP_DB_AFTER)"; note="$(_swap_get NOTIFY)"
      if [ "$rc" -eq 0 ] && [ -n "$drop" ]; then pg_su_exec dropdb --if-exists --force "$drop" >/dev/null 2>&1 || true; fi
      if [ "$rc" -eq 0 ] && [ -n "$note" ]; then notify_owner_telegram "$note" || true; fi
      master_swap_close
      if [ -n "$id" ]; then _ur_conclude "$id" "$rc" "$rf" "$log"; else rm -f -- "$rf"; fi
      if [ "$rc" -eq 0 ]; then _ur_notice "Update auf ${tag} abgeschlossen."; else _ur_alert "Update auf ${tag} gescheitert (Exit ${rc}) — Protokoll ${log}"; fi
      heartbeat_record loop ok
      ;;
    rolled_back|interrupted)
      master_swap_close
      _ur_alert "master-Wechsel auf ${tag:-?} nicht abgeschlossen (${what}) — es läuft der vorherige Stand."
      # n8n kann gestoppt sein: der Rueckweg haelt es fuer das Zuruecksetzen an, ein Update fuer die Sicherung vor einem
      # Versionswechsel (upgrade_prepare), und ein Abbruch durch die Zeitgrenze trifft mitten hinein -> wieder an, sonst
      # bliebe der Bot aus (start auf einen laufenden Container aendert nichts). Die beiseitegelegte DB bleibt liegen.
      svc_start n8n 2>/dev/null || true
      if [ "$mode" = rollback ]; then
        _ur_alert "Rückweg: die Daten sind zurückgesetzt, der vorherige Stand ${tag:-?} startete aber nicht — n8n wurde wieder gestartet. Diagnose: lifeagents doctor"
      fi
      if [ -n "$id" ]; then
        # Schritt "base": im Verbund stecken die Basis-Programme im master-Image (core.fn_update_report kennt den Code).
        if [ "$what" = rolled_back ]; then
          _ur_finish "$id" failed base unknown false "Das neue Programm-Paket startete nicht — der vorherige Stand läuft unverändert weiter."
        else
          _ur_finish "$id" failed base unknown null "Der Wechsel wurde unterbrochen."
        fi
        _ur_reports_flush "$id"
      fi
      ;;
  esac
  return 0
}

# update_tick — Ersatz der beiden systemd-Timer im Docker-Verbund (`lifeagents update --tick`, die Schleife im master ruft es
#   jede Minute als frischen Prozess): Auftraege wie lifeagents-update-run, alle UPDATE_CHECK_EVERY_S
#   Sekunden (2 h) der Release-Check wie lifeagents-update-check (`update_check scheduled`: Karte nur im Erinnerungs-Fenster).
#   Vor der ersten Installation (keine VERSION) still. Zustand in UPDATE_TICK_STATE (doctor prueft, ob die Schleife lebt). Immer rc 0.
#   Ein neuer langer Schritt bekommt vorher `heartbeat_record loop busy` mit seiner Zeitgrenze und danach `loop ok`, sonst meldet der Waechter
#   (core.cron_heartbeat_watch) nach 15 Minuten eine stehende Schleife.
UPDATE_TICK_STATE="${UPDATE_TICK_STATE:-/var/lib/lifeagents/update-tick.state}"
UPDATE_CHECK_EVERY_S="${UPDATE_CHECK_EVERY_S:-7200}"   # wie OnCalendar von lifeagents-update-check.timer
UPDATE_CHECK_RETRY_S="${UPDATE_CHECK_RETRY_S:-900}"    # Neuversuch nach einem Check ohne Entscheidung (GitHub anonym: 60 Abfragen/h)
BACKUP_RETRY_EVERY_S="${BACKUP_RETRY_EVERY_S:-3600}"   # Abstand der Sicherungs-Laeufe (stuendlich wie der Timer)
# Zeitgrenzen je Schritt: UPDATE_RUN_TIMEOUT_S, UPDATE_CHECK_TIMEOUT_S, BACKUP_TIMEOUT_S (common.sh, auch doctor liest sie).
UPDATE_STEP_KILL_S="${UPDATE_STEP_KILL_S:-60}"          # nach TERM so lange warten, dann KILL (systemd: TimeoutStopSec 90 s)
# Ganzer Tick: alle drei Schritte samt KILL-Nachlauf plus Luft fuer die Zwischenschritte; greift also nur bei einem Haenger ausserhalb der Schritte.
UPDATE_TICK_TIMEOUT_S="${UPDATE_TICK_TIMEOUT_S:-$(( UPDATE_RUN_TIMEOUT_S + UPDATE_CHECK_TIMEOUT_S + BACKUP_TIMEOUT_S + 3 * UPDATE_STEP_KILL_S + 600 ))}"
# Nach einer Sicherung, die an ihrer Zeitgrenze endete, laenger warten: sonst haelt jede Stunde ein neuer Haenger den Tick eine halbe Stunde auf.
BACKUP_RETRY_AFTER_TIMEOUT_S="${BACKUP_RETRY_AFTER_TIMEOUT_S:-14400}"

# _ur_cli -> Pfad der CLI (vor der ersten Installation zeigt der Link im master-Image ins Leere).
_ur_cli() { command -v lifeagents || printf '/usr/local/bin/lifeagents'; }

# _ur_step <sekunden> <cli-args…> — ein Tick-Schritt als eigener Prozess unter `timeout` (eigene Prozessgruppe: bei Ablauf
#   endet die ganze Gruppe samt Fortschritts-Helfer und docker-Client; Prozesse, die per `docker exec` in einem anderen
#   Container laufen, erreicht das nicht). Ein TERM an den Tick (docker stop, Neuanlage des master) geht an den Schritt
#   weiter, sonst liefe er bis zum KILL nach 10 s ungeordnet weiter. Ablauf der Grenze = Alarm im Log. Immer rc 0; der Exit des Schritts steht in _UR_STEP_RC.
_UR_STEP_PID='' _UR_STEP_RC=0
_ur_step() {
  local secs="$1" rc=0 old_term old_int; shift
  old_term="$(trap -p TERM)"; old_int="$(trap -p INT)"
  timeout --kill-after="$UPDATE_STEP_KILL_S" "$secs" "$(_ur_cli)" "$@" </dev/null &
  _UR_STEP_PID=$!
  trap 'kill -TERM "$_UR_STEP_PID" 2>/dev/null; wait "$_UR_STEP_PID" 2>/dev/null; exit 143' TERM INT
  wait "$_UR_STEP_PID" || rc=$?
  trap - TERM INT
  if [ -n "$old_term" ]; then eval "$old_term"; fi
  if [ -n "$old_int" ]; then eval "$old_int"; fi
  _UR_STEP_PID='' _UR_STEP_RC="$rc"
  case "$rc" in
    124|137) _ur_alert "Tick: '$*' nach ${secs} s abgebrochen (Zeitgrenze) — der nächste Tick macht weiter." ;;
  esac
  return 0
}

update_tick() {
  require_root
  [ -r "$(lifeagents_version_marker)" ] || return 0
  # Stillgelegt (lib/retire_cli.sh): kein Update, keine Sicherung — beides gehoert jetzt der neuen Maschine.
  la_is_retired && return 0
  mkdir -p "$(dirname "$UPDATE_TICK_STATE")"
  env_upsert "$UPDATE_TICK_STATE" LAST_TICK "$(date -u +%s)"
  # Eigener Prozess: die Update-Sperre (fd 9) endet mit ihm.
  _ur_step "$UPDATE_RUN_TIMEOUT_S" update --run-requested
  local tz now last nowe
  tz="$(read_env_value "$(lifeagents_env_file core)" HOUSEHOLD_TIMEZONE 2>/dev/null || true)"
  now="$(TZ="${tz:-Europe/Berlin}" date +%H%M)"
  last="$(read_env_value "$UPDATE_TICK_STATE" LAST_CHECK 2>/dev/null || true)"
  # LAST_CHECK = Epoch-Sekunden; ein Datum ("2026-11-08", Zustand aelterer Versionen) zaehlt als "lange her" (sonst bricht die Rechnung unter set -e ab)
  [[ $last =~ ^[0-9]+$ ]] || last=0
  nowe="$(date -u +%s)"
  [ "$last" -le "$nowe" ] || last=0   # Uhr zurueckgestellt: LAST_CHECK in der Zukunft zaehlt als "lange her"
  if [ "$((nowe - last))" -ge "$UPDATE_CHECK_EVERY_S" ]; then
    env_upsert "$UPDATE_TICK_STATE" LAST_CHECK "$nowe"
    # Nur ein Check, der entschieden hat, verbraucht das 2-h-Fenster; sonst (Sperre, Netz, DB, ausserhalb des
    # Erinnerungs-Fensters) kommt der Neuversuch nach UPDATE_CHECK_RETRY_S. Ohne Meldung gilt er als entschieden.
    local outf outcome
    outf="$(mktemp)"
    export UPDATE_CHECK_OUTCOME_FILE="$outf"
    _ur_step "$UPDATE_CHECK_TIMEOUT_S" update --check --scheduled
    unset UPDATE_CHECK_OUTCOME_FILE
    outcome="$(head -n1 "$outf" 2>/dev/null || true)"; rm -f -- "$outf"
    if [ "$outcome" = undecided ]; then
      env_upsert "$UPDATE_TICK_STATE" LAST_CHECK "$((nowe - UPDATE_CHECK_EVERY_S + UPDATE_CHECK_RETRY_S))"
    fi
  fi
  # Taegliche Sicherung in den Ordner auf dem Rechner wie lifeagents-backup.timer: ab BACKUP_AUTO_AT (Haushalts-Zeitzone) jede
  # Stunde `backup auto --scheduled`; ob seit BACKUP_AUTO_AT schon gesichert wurde, entscheidet backup.state (LAST_OK,
  # backup_cli.sh _bkp_auto_due), ein Lauf danach kostet nichts. So holt der naechste Takt einen Fehlschlag, eine belegte
  # Sperre oder einen Lauf ohne Vermerk (Zeitgrenze, Neustart) nach, und ohne gewaehlten Ordner erreicht der Hinweis das
  # Meldefenster am Tag (er drosselt sich selbst, BACKUP_NOTIFY_*).
  local try
  try="$(read_env_value "$UPDATE_TICK_STATE" LAST_BACKUP_TRY 2>/dev/null || true)"; [[ $try =~ ^[0-9]+$ ]] || try=0
  [ "$try" -le "$nowe" ] || try=0   # Uhr zurueckgestellt
  local every="$BACKUP_RETRY_EVERY_S"
  [ "$(read_env_value "$UPDATE_TICK_STATE" LAST_BACKUP_TIMEOUT 2>/dev/null || true)" != 1 ] || every="$BACKUP_RETRY_AFTER_TIMEOUT_S"
  if rt_is_compose && [ "$((10#$now))" -ge "$((10#$BACKUP_AUTO_AT))" ] && [ "$((nowe - try))" -ge "$every" ]; then
    env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP_TRY "$nowe"
    heartbeat_record loop busy "$(_ur_busy_s "$BACKUP_TIMEOUT_S")"
    _ur_step "$BACKUP_TIMEOUT_S" backup auto --scheduled
    # Nach der Zeitgrenze zaehlt die Pause ab dem Abbruch, nicht ab dem Start.
    case "$_UR_STEP_RC" in
      124|137) env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP_TRY "$(date -u +%s)"; env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP_TIMEOUT 1 ;;
      *)       env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP_TIMEOUT 0 ;;
    esac
    heartbeat_record loop ok
  fi
  return 0
}
