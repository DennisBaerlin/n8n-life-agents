# umzug_cases.sh — Faelle UZ* fuer `lifeagents umzug` (lib/move_cli.sh), `lifeagents config import` (lib/config_cli.sh) und die
# Update-Sperre „Umzug offen“ (lib/update_runner.sh); eingebunden von cases.sh (dieselben Attrappen, $W, $STUB_LOG, pass/fail/eq).
# real-path-test: tests/backup/umzug_cases.sh (scripts/dev/umzug_test.ps1: echtes n8n + PostgreSQL im klassischen Substrat)
# shellcheck shell=bash disable=SC2016,SC2034,SC2329,SC2015,SC2030,SC2031,SC2086,SC2154,SC2119,SC2120  # Attrappen-Funktionen ruft der Lib-Code; Pruef-Ausdruecke in einfachen Quotes; fails/W/ROOT setzt cases.sh

MV="$W/mv"; MI="$W/mv_in"
_mv_reset() { rm -rf "$MV" "$W/mv_etc" "$MI"; mkdir -p "$MV" "$W/mv_etc" "$MI"; : > "$STUB_LOG"; : > "${STUB_LOG}.put"; }
_mv_log() { grep '^ev|' "$STUB_LOG" | sed 's/^ev|//'; }
_mv_state() { read_env_value "$MV/umzug-open" "$1" 2>/dev/null || true; }
# Umzugs-Ordner wie `lifeagents retire` ihn schreibt (B1): Manifest, Sicherung, Gedaechtnis-Abzug, Einstellungen, Vergleichswerte, Antworten.
_mv_folder() {
  printf 'FORMAT=1\nRELEASE=%s\nCREATED=%s\nRUNTIME=systemd\nBACKUP_FILE=b.nla.enc\nPACKAGES=career\n' "${F_REL:-v9.1.0}" "${F_MOVE:-2026-11-20T10:00:00Z}" > "$MI/umzug.manifest"
  printf 'enc' > "$MI/b.nla.enc"
  if [ -z "${F_NOMEM:-}" ]; then printf 'dump' > "$MI/memory.dump"; printf 'agent.guide_chat_memory\t2\t7\n' > "$MI/memory.counts"; fi
  printf '[{"package":"core","category":"cron_enable","key":"refresh_fx_rates","value":"false"}]' > "$MI/config.json"
  printf 'rows finance.accounts 3\nmd5 finance.accounts aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nmemory agent.guide_chat_memory 2\n' > "$MI/vorher.txt"
  printf "REACH_MODE='tunnel'\nTELEGRAM_BOT_TOKEN='123:abc'\n" > "$MI/umzug.env"
  chmod 0700 "$MI"; chmod 0600 "$MI"/*
}

# ---------------------------------------------------------------------------- UZ-S: Merker „Umzug offen“ in lib/runtime.sh
_mv_reset
# hand-injected: Merker-Ordner im Wegwerf-Verzeichnis statt /var/lib/lifeagents (Attrappe, kein echtes System); echter Pfad in tests/backup/umzug_cases.sh
_sv() ( export LIFEAGENTS_STATE_DIR="$MV"; "$@" )
eq UZ-S.datei "$MV/umzug-open" "$(_sv la_umzug_file)"
if _sv la_umzug_open; then fail UZ-S.ohne-merker-zu "offen"; else pass UZ-S.ohne-merker-zu; fi
: > "$MV/umzug-open"
if _sv la_umzug_open; then pass UZ-S.mit-merker-offen; else fail UZ-S.mit-merker-offen "zu"; fi
# Ein Merker blockiert weder Dienste noch retire: er sperrt nur das Update.
if _sv la_is_retired; then fail UZ-S.nicht-stillgelegt "gilt als stillgelegt"; else pass UZ-S.nicht-stillgelegt; fi

# ---------------------------------------------------------------------------- UZ-V: Vergleich vorher/nachher (rein, ohne DB)
for _f in move_cli.sh retire_cli.sh config_cli.sh; do
  # shellcheck source=/dev/null
  [ -r "$ROOT/provisioning/lib/$_f" ] && . "$ROOT/provisioning/lib/$_f"
done
printf 'md5 finance.accounts aaa\nmemory agent.guide_chat_memory 2\nrows finance.accounts 3\n' > "$W/v.vorher"
cp "$W/v.vorher" "$W/v.nachher"
_cmp="$(umzug_compare "$W/v.vorher" "$W/v.nachher" 2>&1)"; _rc=$?
eq UZ-V.gleich-rc 0 "$_rc"
eq UZ-V.gleich-still '' "$_cmp"
printf 'md5 finance.accounts bbb\nmemory agent.guide_chat_memory 2\nrows finance.accounts 3\n' > "$W/v.nachher"
_cmp="$(umzug_compare "$W/v.vorher" "$W/v.nachher" 2>&1)"; _rc=$?
eq UZ-V.abweichung-rc 1 "$_rc"
case "$_cmp" in *'md5 finance.accounts'*) pass UZ-V.nennt-tabelle ;; *) fail UZ-V.nennt-tabelle "$_cmp" ;; esac
# Nur Namen und Kennzahlen, nie mehr: kein Inhalt aus der Zeile ausser dem, was die Zeile selbst traegt (Kennzahl bzw. md5).
printf 'rows finance.accounts 3\nmd5 finance.accounts aaa\nmemory agent.guide_chat_memory 2\n' > "$W/v.vorher"
printf 'rows finance.accounts 4\nmd5 finance.accounts aaa\nmemory agent.guide_chat_memory 2\nconfig core.cron_enable.x ccc\n' > "$W/v.nachher"
_cmp="$(umzug_compare "$W/v.vorher" "$W/v.nachher" 2>&1)"
case "$_cmp" in *'rows finance.accounts'*3*4*) pass UZ-V.zeilenzahl-vorher-nachher ;; *) fail UZ-V.zeilenzahl-vorher-nachher "$_cmp" ;; esac
case "$_cmp" in *'config core.cron_enable.x'*) pass UZ-V.nur-neu-gemeldet ;; *) fail UZ-V.nur-neu-gemeldet "$_cmp" ;; esac
printf 'rows finance.accounts 3\nconfig core.cron_enable.y ddd\n' > "$W/v.vorher"; printf 'rows finance.accounts 3\n' > "$W/v.nachher"
_cmp="$(umzug_compare "$W/v.vorher" "$W/v.nachher" 2>&1)"; _rc=$?
eq UZ-V.nur-alt-rc 1 "$_rc"
case "$_cmp" in *'config core.cron_enable.y'*) pass UZ-V.nur-alt-gemeldet ;; *) fail UZ-V.nur-alt-gemeldet "$_cmp" ;; esac
umzug_compare "$W/nichtda" "$W/v.nachher" >/dev/null 2>&1; eq UZ-V.fehlende-datei-rc 2 "$?"

# ---------------------------------------------------------------------------- UZ-C: config import (lib/config_cli.sh)
# _cfg_psql ist die Attrappe: sie protokolliert das SQL und antwortet je nach Schluessel.
_ci() (
  ev() { printf 'ev|%s\n' "$*" >> "$STUB_LOG"; }
  _cfg_resolve_db() { :; }
  _cfg_psql() {
    local sql="${*: -1}"
    case "$sql" in
      *"SELECT managed_by"*) case "$sql" in *"key = 'api_core_version'"*) printf 'system' ;; *"key = 'gibtsnicht'"*) printf '' ;; *) printf 'owner' ;; esac ;;
      UPDATE*) ev "sql $sql"; case "$sql" in *"key = 'gibtsnicht'"*) printf '' ;; *) printf 'x' ;; esac ;;
      *) printf '' ;;
    esac
  }
  _cfg_apply_schedule() { ev "apply $1 $2"; }
  config_cmd_import "$@"
)
_mv_reset
cat > "$W/cfg.json" <<'JSON'
[{"package":"core","category":"cron_enable","key":"refresh_fx_rates","value":"false"},
 {"package":"core","category":"cron_enable","key":"gibtsnicht","value":"x"},
 {"package":"core","category":"schedule","key":"score_jobs","value":"0 7 * * 1-5"},
 {"package":"core","category":"api","key":"api_core_version","value":"v0"},
 {"package":"core","category":"a'; DROP TABLE x; --","key":"k","value":"v"},
 {"package":"core","category":"note","key":"text","value":"it's \"quoted\""}]
JSON
_out="$(_ci "$W/cfg.json" 2>&1)"; _rc=$?
eq UZ-C.fehler-je-zeile-rc 1 "$_rc"
_n="$(_mv_log | grep -c '^sql UPDATE')"
eq UZ-C.rest-laeuft 4 "$_n"
case "$_out" in *gibtsnicht*) pass UZ-C.unbekannter-schluessel-gemeldet ;; *) fail UZ-C.unbekannter-schluessel-gemeldet "$_out" ;; esac
case "$_out" in *api_core_version*) pass UZ-C.systemwert-gemeldet ;; *) fail UZ-C.systemwert-gemeldet "$_out" ;; esac
if _mv_log | grep -q 'api_core_version'; then fail UZ-C.systemwert-nie-geschrieben "UPDATE lief"; else pass UZ-C.systemwert-nie-geschrieben; fi
if _mv_log | grep -q 'DROP'; then fail UZ-C.ident-geprueft "SQL mit Einschleusung"; else pass UZ-C.ident-geprueft; fi
case "$(_mv_log | grep "key = 'text'")" in *"it''s \"quoted\""*) pass UZ-C.quote-verdoppelt ;; *) fail UZ-C.quote-verdoppelt "$(_mv_log | grep "key = 'text'")" ;; esac
# Werte stehen nie in der Ausgabe (Einstellungen koennen Eigenes tragen).
case "$_out" in *quoted*|*'0 7 * * 1-5'*) fail UZ-C.wert-nie-in-ausgabe "$_out" ;; *) pass UZ-C.wert-nie-in-ausgabe ;; esac
# Zeitplan: einzeln einspielen, ausser der Aufrufer macht es gesammelt (umzug apply spielt danach alle Workflows neu ein).
eq UZ-C.zeitplan-einzeln 1 "$(_mv_log | grep -c '^apply schedule score_jobs')"
_mv_reset
( export LIFEAGENTS_CONFIG_DEFER_APPLY=1; _ci "$W/cfg.json" ) >/dev/null 2>&1
eq UZ-C.zeitplan-gesammelt 0 "$(_mv_log | grep -c '^apply ')"
printf '[]' > "$W/cfg0.json"; _ci "$W/cfg0.json" >/dev/null 2>&1; eq UZ-C.leer-ok 0 "$?"
printf 'kein json' > "$W/cfg1.json"; _ci "$W/cfg1.json" >/dev/null 2>&1; eq UZ-C.kaputt-rc 1 "$?"
_ci "$W/nichtda.json" >/dev/null 2>&1; eq UZ-C.fehlende-datei-rc 1 "$?"

# ---------------------------------------------------------------------------- UZ-U: Update-Sperre „Umzug offen“
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/update_runner.sh"
_uu() (
  # hand-injected: Merker-Ordner im Wegwerf-Verzeichnis und Betriebsart fest; der echte Pfad laeuft in tests/backup/umzug_cases.sh
  export LIFEAGENTS_STATE_DIR="$MV" LIFEAGENTS_RUNTIME=systemd
  ev() { printf 'ev|%s\n' "$*" >> "$STUB_LOG"; }
  lifeagents_version_heal() { :; }; require_root() { :; }
  fetch_and_run_release() { ev fetch "$@"; }
  update_check() { ev check "$@"; }; update_run_requested() { ev run_requested; }; update_tick() { ev tick; }
  "$@"
)
_mv_reset
_uu update_cli --version v9.9.9 >/dev/null 2>&1; eq UZ-U.ohne-merker-laeuft 1 "$(_mv_log | grep -c '^fetch')"
: > "$MV/umzug-open"; : > "$STUB_LOG"
_out="$(_uu update_cli --version v9.9.9 2>&1)"; _rc=$?
eq UZ-U.update-gesperrt-rc 1 "$_rc"
eq UZ-U.update-kein-download 0 "$(_mv_log | grep -c '^fetch')"
case "$_out" in *'umzug done'*) pass UZ-U.satz-nennt-abnahme ;; *) fail UZ-U.satz-nennt-abnahme "$_out" ;; esac
_uu update_cli >/dev/null 2>&1; eq UZ-U.update-ohne-tag-gesperrt 0 "$(_mv_log | grep -c '^fetch')"
: > "$STUB_LOG"; _uu update_cli --check >/dev/null 2>&1; _uu update_cli --tick >/dev/null 2>&1; _uu update_cli --run-requested >/dev/null 2>&1
eq UZ-U.check-tick-runner-frei 3 "$(_mv_log | grep -cE '^(check|tick|run_requested)')"
_uu update_cli --help >/dev/null 2>&1; eq UZ-U.hilfe-frei 0 "$?"
# Keine Update-Karte, solange der Umzug offen ist: eine Karte, die man nicht ausfuehren kann, ist Rauschen. Kein Netzabruf.
_chk() (
  # hand-injected: Merker-Ordner im Wegwerf-Verzeichnis und Betriebsart fest; der echte Pfad laeuft in tests/backup/umzug_cases.sh
  export LIFEAGENTS_STATE_DIR="$MV" LIFEAGENTS_RUNTIME=systemd
  ev() { printf 'ev|%s\n' "$*" >> "$STUB_LOG"; }
  require_root() { :; }; lifeagents_db_name() { :; }; update_lock_free() { return 0; }; heartbeat_record() { ev "heartbeat $*"; }
  _ur_installed() { printf 'v9.1.0'; }
  _gh_http() { ev gh_http; printf '200'; }; _ur_check_in() { ev check_in; }; _ur_send() { ev send; }
  update_check
)
: > "$STUB_LOG"; _chk >/dev/null 2>&1
eq UZ-U.keine-karte-offen 0 "$(_mv_log | grep -cE '^(check_in|gh_http|send)')"
rm -f "$MV/umzug-open"; : > "$STUB_LOG"; _chk >/dev/null 2>&1
eq UZ-U.karte-ohne-merker 1 "$(_mv_log | grep -c '^check_in')"
# Ein schon gestellter Auftrag (alte Karte angetippt) endet mit dem vorhandenen Grund „locked“, ohne Update.
_ro() (
  # hand-injected: Merker-Ordner im Wegwerf-Verzeichnis und Betriebsart fest; der echte Pfad laeuft in tests/backup/umzug_cases.sh
  export LIFEAGENTS_STATE_DIR="$MV" LIFEAGENTS_RUNTIME=systemd
  ev() { printf 'ev|%s\n' "$*" >> "$STUB_LOG"; }
  _ur_finish() { ev "finish $*"; }; _ur_reports_flush() { ev flush; }; _ur_semver_cmp() { printf '1'; }
  _gh_http() { ev gh_http; printf '200'; }
  _ur_run_one 7 v9.2.0 update v9.1.0
)
: > "$MV/umzug-open"; : > "$STUB_LOG"; _ro >/dev/null 2>&1
case "$(_mv_log | grep '^finish')" in 'finish 7 failed preflight locked'*) pass UZ-U.auftrag-locked ;; *) fail UZ-U.auftrag-locked "$(_mv_log | tr '\n' ' ')" ;; esac
eq UZ-U.auftrag-kein-netz 0 "$(_mv_log | grep -c '^gh_http')"

# ---------------------------------------------------------------------------- UZ: Ablauf von `umzug apply` (Attrappen)
# _ua <args…> — umzug_cli in einer Subshell; Steuerung ueber die Umgebung:
#   RT = Betriebsart, OWNER = Owner-chat_id der „frischen“ Maschine (leer = ungekoppelt), INST_REL = installierte Version,
#   PLAN_CODE = Fehlercode des Probelaufs (key_needed …), PLAN_REL = Release der Sicherung, FAIL_AT = Stufe, die scheitert
#   (restore|memory_import|config_import|finalize|menu), CFG_RC, REACH = Tunnel-Zustaende je Abfrage, IA = Terminal (1), ASK_KEY.
_ua() (
  # hand-injected: Betriebsart, Merker- und Env-Ordner im Wegwerf-Verzeichnis; der echte Weg (klassisch) laeuft in tests/backup/umzug_cases.sh
  export LIFEAGENTS_RUNTIME="${RT:-systemd}" LIFEAGENTS_STATE_DIR="$MV" LIFEAGENTS_DIR="$W/mv_etc" N8N_ENV_FILE="$W/mv_etc/n8n.env"
  # hand-injected: kurze Takte/Wartezeiten (Sekunden statt Minuten) und ein Abbild-Name fuer die Rechner-Ordner-Attrappe; Standardwerte prueft der echte Weg
  export UMZUG_TUNNEL_POLL_SECS=1 UMZUG_TUNNEL_WAIT_SECS="${TUNNEL_WAIT:-2}" LA_PROBE_IMAGE=probe:t
  unset LIFEAGENTS_RETIRE_UNDO
  ev() { printf 'ev|%s\n' "$*" >> "$STUB_LOG"; }
  require_root() { :; }; _bkp_resolve_db() { N8N_DB_NAME=n8n; }; update_lock_acquire() { export LIFEAGENTS_UPDATE_LOCK_HELD=1; }
  load_install_env() { :; }; _pkg_resolve_env() { :; }
  lifeagents_env_file() { printf '%s/%s.env' "$LIFEAGENTS_DIR" "$1"; }
  _bkp_release_tag() { printf '%s' "${INST_REL:-v9.1.0}"; }
  _owner_chat_id_db() { printf '%s' "${OWNER:-}"; }
  ui_interactive() { [ "${IA:-0}" = 1 ]; }
  _bkp_ask_key_tty() { ev ask_key; printf 'key:%s\n' "${ASK_KEY:-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef}"; }
  backup_cmd_restore() {
    local key; key="$(cat)"
    case " $* " in
      *' --plan '*)
        ev "plan key=${key:+ja}"
        if [ -n "${PLAN_CODE:-}" ] && [ -z "$key" ]; then printf '{"ok":false,"code":"%s"}\n' "$PLAN_CODE"; return 1; fi
        printf '{"ok":true,"release":"%s"}\n' "${PLAN_REL:-v9.1.0}" ;;
      *) ev "restore key=${key:+ja}"; [ "${FAIL_AT:-}" != restore ] ;;
    esac
  }
  memory_import() { ev memory_import; [ "${FAIL_AT:-}" != memory_import ]; }
  # config_import scheitert hart (wie `die` im echten Code, z. B. Datei unlesbar) bei FAIL_AT; CFG_RC = abgelehnte Zeilen, nicht fatal
  config_cmd_import() { ev "config_import lazy=${LIFEAGENTS_CONFIG_DEFER_APPLY:-0}"; [ "${FAIL_AT:-}" != config_import ] || exit 1; return "${CFG_RC:-0}"; }
  _oc_finalize_verified() { ev finalize; if [ "${FAIL_AT:-}" = finalize ]; then OC_FINALIZE_REASON=placeholders_left; return 1; fi; OC_FINALIZE_REASON=''; }
  _set_bot_menu_buttons() { ev menu; }
  owner_tg_token() { printf 'tok'; }
  _ret_sql() {
    case "$1" in
      *"telegram_user_id"*) printf '111\n222\n' ;;
      *fn_should_notify*) ev "latch $1" ;;
      *) printf '' ;;
    esac
  }
  move_snapshot() { if [ -n "${NACHHER_ABWEICHT:-}" ]; then printf 'rows finance.accounts 9\n'; else cat "$MI/vorher.txt"; fi; }
  reach_status_json() {
    local n; n="$(wc -l < "$W/mv.reach" 2>/dev/null || echo 0)"; echo x >> "$W/mv.reach"
    set -- ${REACH:-ready}; shift "$(( n < $# ? n : $# - 1 ))"
    printf '{"mode":"tunnel","state":"%s","url":"%s","dns_name":"neu.example.ts.net"}\n' "$1" "https://login.tailscale.com/a/abc123"
  }
  _mv_reach_activate() { ev activate; }
  _ret_fetch_dir() { _RET_DIR="$MI"; }
  rt_host_rm() { ev "host_rm $*"; }
  rt_host_put() { ev "host_put $*"; cat "$3" > /dev/null; }
  umzug_cli "$@"
)
_mv_run() { _mv_reset; _mv_folder; rm -f "$W/mv.reach"; "$@"; }

# Vorpruefungen rot -> nichts geaendert (kein Marker, kein restore, nichts geloescht).
_mv_nothing() {  # <name> <grund-im-satz>
  if _mv_log | grep -qE '^(restore|memory_import|config_import|finalize|menu)'; then fail "UZ.$1-nichts" "$(_mv_log | tr '\n' ' ')"; else pass "UZ.$1-nichts"; fi
  [ ! -e "$MV/umzug-open" ] && pass "UZ.$1-kein-merker" || fail "UZ.$1-kein-merker" "Merker liegt"
  [ -e "$MI/umzug.env" ] && pass "UZ.$1-dateien-bleiben" || fail "UZ.$1-dateien-bleiben" "umzug.env geloescht"
  [ -z "${2:-}" ] || { grep -qi -- "$2" "$W/mv.err" && pass "UZ.$1-satz" || fail "UZ.$1-satz" "$(tail -n3 "$W/mv.err")"; }
}
_mv_run true; rm -f "$MI/umzug.manifest"
_ua apply "$MI" >/dev/null 2>"$W/mv.err"; eq UZ.ohne-manifest-rc 1 "$?"; _mv_nothing ohne-manifest 'umzug.manifest'
_mv_run true; F_REL=v9.0.0 _mv_folder
_ua apply "$MI" >/dev/null 2>"$W/mv.err"; eq UZ.andere-release-rc 1 "$?"; _mv_nothing andere-release 'v9.0.0'
_mv_run true; rm -f "$MI/b.nla.enc"
_ua apply "$MI" >/dev/null 2>"$W/mv.err"; eq UZ.ohne-sicherung-rc 1 "$?"; _mv_nothing ohne-sicherung 'Sicherung'
_mv_run true; ( OWNER=4711 _ua apply "$MI" ) >/dev/null 2>"$W/mv.err"; eq UZ.in-gebrauch-rc 1 "$?"; _mv_nothing in-gebrauch 'in Gebrauch'
_mv_run true; ( PLAN_REL=v9.0.0 _ua apply "$MI" ) >/dev/null 2>"$W/mv.err"; eq UZ.plan-andere-release-rc 1 "$?"; _mv_nothing plan-andere-release 'v9.0.0'
_mv_run true; ( PLAN_CODE=corrupt _ua apply "$MI" ) >/dev/null 2>"$W/mv.err"; eq UZ.plan-rot-rc 1 "$?"; _mv_nothing plan-rot ''
# Notfallblatt: ohne Terminal klarer Satz mit dem Befehl, nichts geaendert; mit Terminal einmal fragen, an Plan UND Restore reichen.
_mv_run true; ( PLAN_CODE=key_needed _ua apply "$MI" ) >/dev/null 2>"$W/mv.err"; eq UZ.blatt-ohne-terminal-rc 1 "$?"; _mv_nothing blatt-ohne-terminal 'Notfallblatt'
_mv_run true; ( PLAN_CODE=key_needed IA=1 _ua apply "$MI" ) >/dev/null 2>"$W/mv.err"; eq UZ.blatt-mit-terminal-rc 0 "$?"
eq UZ.blatt-einmal-gefragt 1 "$(_mv_log | grep -c '^ask_key')"
case "$(_mv_log | grep -E '^(plan|restore)' | tr '\n' ',')" in 'plan key=,plan key=ja,restore key=ja,') pass UZ.blatt-an-plan-und-restore ;; *) fail UZ.blatt-an-plan-und-restore "$(_mv_log | grep -E '^(plan|restore)' | tr '\n' ',')" ;; esac
# Verbund-Tunnel: nicht fertig -> Link zeigen, nach der Wartezeit Abbruch ohne Aenderung; Anmeldung waehrenddessen -> weiter.
_mv_run true; ( RT=compose TUNNEL_WAIT=2 REACH='needs_login' _ua apply "$MI" ) >/dev/null 2>"$W/mv.err"; eq UZ.tunnel-nicht-fertig-rc 1 "$?"
_mv_nothing tunnel-nicht-fertig 'login.tailscale.com/a/abc123'
_mv_run true; ( RT=compose TUNNEL_WAIT=5 REACH='needs_login needs_login pending_activation ready' _ua apply "$MI" ) >/dev/null 2>"$W/mv.err"; eq UZ.tunnel-wartet-rc 0 "$?"
eq UZ.tunnel-aktiviert 1 "$(_mv_log | grep -c '^activate')"
_mv_run true; ( RT=compose REACH='ready' _ua apply "$MI" ) >/dev/null 2>&1; eq UZ.tunnel-fertig-ohne-aktivierung 0 "$(_mv_log | grep -c '^activate')"
# Klassisch: kein Tunnel-Weg (Reverse-Proxy-Betrieb), also keine Abfrage.
_mv_run true; ( RT=systemd REACH='needs_login' _ua apply "$MI" ) >/dev/null 2>&1; eq UZ.klassisch-ohne-tunnelpruefung 0 "$?"

# Normaler Lauf: Reihenfolge, Zustand, Aufraeumen, Vergleich.
_mv_run true; _ua apply "$MI" >"$W/mv.out" 2>"$W/mv.err"; _rc=$?
eq UZ.lauf-ok 0 "$_rc"
[ "$_rc" = 0 ] || printf '# %s\n' "$(tail -n6 "$W/mv.err")"
_seq="$(_mv_log | grep -vE '^(host_|ask_key)' | sed -E 's/ key=.*$//; s/^latch .*$/latch/; s/ lazy=.*$//' | tr '\n' ',')"
case "$_seq" in
  'plan,restore,memory_import,config_import,latch,latch,finalize,menu,') pass UZ.reihenfolge ;;
  *) fail UZ.reihenfolge "$_seq" ;; esac
eq UZ.stufe-angewendet applied "$(_mv_state STAGE)"
eq UZ.merker-move 2026-11-20T10:00:00Z "$(_mv_state MOVE)"
eq UZ.config-ohne-einzeldeploy 'config_import lazy=1' "$(_mv_log | grep '^config_import')"
for _f in umzug.env memory.dump memory.counts; do
  [ ! -e "$MI/$_f" ] && pass "UZ.geloescht-$_f" || fail "UZ.geloescht-$_f" "liegt noch"
done
[ -e "$MI/b.nla.enc" ] && [ -e "$MI/umzug.manifest" ] && pass UZ.sicherung-bleibt || fail UZ.sicherung-bleibt "weg"
[ -s "$MI/nachher.txt" ] && pass UZ.nachher-geschrieben || fail UZ.nachher-geschrieben "fehlt"
case "$(cat "$W/mv.out" "$W/mv.err")" in *'umzug done'*) pass UZ.satz-abnahme ;; *) fail UZ.satz-abnahme "$(tail -n4 "$W/mv.err")" ;; esac
# Intro-Latch fuer jede Person der family-Fakten, vor dem Menue-Lauf.
case "$(_mv_log | grep '^latch')" in *"'app_intro', '111'"*"'app_intro', '222'"*) pass UZ.intro-latch-je-person ;; *) fail UZ.intro-latch-je-person "$(_mv_log | grep '^latch')" ;; esac
# Zweiter Lauf desselben Umzugs: nichts mehr einspielen (sonst gingen Daten der letzten Tage verloren).
: > "$STUB_LOG"; _ua apply "$MI" >/dev/null 2>"$W/mv.err"; _rc=$?
if _mv_log | grep -qE '^(plan|restore|memory_import|config_import|finalize)'; then fail UZ.nochmal-kein-restore "$(_mv_log | tr '\n' ' ')"; else pass UZ.nochmal-kein-restore; fi
eq UZ.nochmal-rc 0 "$_rc"
# Ein anderer Umzug, solange dieser offen ist -> Abbruch.
_mv_folder_new() { F_MOVE=2026-11-25T10:00:00Z _mv_folder; }
_mv_folder_new; : > "$STUB_LOG"; _ua apply "$MI" >/dev/null 2>"$W/mv.err"; _rc=$?
eq UZ.anderer-umzug-rc 1 "$_rc"
if _mv_log | grep -qE '^(plan|restore)'; then fail UZ.anderer-umzug-nichts "$(_mv_log | tr '\n' ' ')"; else pass UZ.anderer-umzug-nichts; fi
grep -q 'umzug done' "$W/mv.err" && pass UZ.anderer-umzug-satz || fail UZ.anderer-umzug-satz "$(tail -n2 "$W/mv.err")"
# Verbund: Geheimnisse ueber den Rechner-Ordner loeschen (rt_host_rm), nie ueber die Platte des master.
_mv_run true; ( RT=compose _ua apply "$MI" ) >/dev/null 2>&1
case "$(_mv_log | grep '^host_rm')" in *'umzug.env'*'memory.dump'*'memory.counts'*) pass UZ.verbund-loescht-ueber-rechner ;; *) fail UZ.verbund-loescht-ueber-rechner "$(_mv_log | grep host_ | tr '\n' ' ')" ;; esac
case "$(_mv_log | grep '^host_put')" in *nachher.txt*) pass UZ.verbund-nachher-in-ordner ;; *) fail UZ.verbund-nachher-in-ordner "$(_mv_log | grep host_ | tr '\n' ' ')" ;; esac

# Abbruch an jeder Stufe: Stand bleibt, Geheimnisse bleiben, ein neuer Lauf macht dort weiter und spielt nichts doppelt ein.
for _s in restore:started memory_import:restored config_import:memory finalize:config; do
  _at="${_s%%:*}"; _st="${_s##*:}"
  _mv_run true; ( FAIL_AT="$_at" _ua apply "$MI" ) >/dev/null 2>"$W/mv.err"; _rc=$?
  eq "UZ.bricht-ab-$_at-rc" 1 "$_rc"
  eq "UZ.bricht-ab-$_at-stand" "$_st" "$(_mv_state STAGE)"
  [ -e "$MI/umzug.env" ] && pass "UZ.bricht-ab-$_at-geheimnisse-bleiben" || fail "UZ.bricht-ab-$_at-geheimnisse-bleiben" "geloescht"
  : > "$STUB_LOG"; _ua apply "$MI" >/dev/null 2>&1; _rc=$?
  eq "UZ.weiter-nach-$_at-rc" 0 "$_rc"
  eq "UZ.weiter-nach-$_at-fertig" applied "$(_mv_state STAGE)"
  _n="$(_mv_log | grep -c '^restore')"
  if [ "$_at" = restore ]; then eq "UZ.weiter-nach-$_at-restore-neu" 1 "$_n"; else eq "UZ.weiter-nach-$_at-kein-zweites-restore" 0 "$_n"; fi
done
# Einstellungen teils abgelehnt: der Lauf geht weiter (Stufe config zaehlt), der Vergleich zeigt es.
_mv_run true; ( CFG_RC=1 _ua apply "$MI" ) >/dev/null 2>"$W/mv.err"
eq UZ.config-abgelehnt-weiter applied "$(_mv_state STAGE)"
# Vergleich rot: Lauf gelungen, aber Exit 1 und die Abweichung steht da.
_mv_run true; ( NACHHER_ABWEICHT=1 _ua apply "$MI" ) >"$W/mv.out" 2>"$W/mv.err"; _rc=$?
eq UZ.vergleich-rot-rc 1 "$_rc"
eq UZ.vergleich-rot-stufe applied "$(_mv_state STAGE)"
# Ohne Gedaechtnis-Abzug: Stufe wird uebersprungen.
_mv_run true; rm -f "$MI/memory.dump" "$MI/memory.counts"; ( _ua apply "$MI" ) >/dev/null 2>&1
eq UZ.ohne-gedaechtnis-ok applied "$(_mv_state STAGE)"
eq UZ.ohne-gedaechtnis-kein-import 0 "$(_mv_log | grep -c '^memory_import')"
# Nur Umzugs-Ordner und Wort: ohne Argument/Option -> Abbruch.
_mv_run true; _ua apply >/dev/null 2>&1; eq UZ.apply-ohne-ordner-rc 1 "$?"
_ua brandneu >/dev/null 2>&1; eq UZ.unbekanntes-verb-rc 1 "$?"

# ---------------------------------------------------------------------------- UZ: status / check / done
_mv_run true; _ua status >/dev/null 2>&1; eq UZ.status-kein-umzug 0 "$?"
printf 'STAGE=restored\nMOVE=m\nAT=x\n' > "$MV/umzug-open"; _ua status >/dev/null 2>&1; eq UZ.status-mitten-drin 10 "$?"
printf 'STAGE=applied\nMOVE=m\nAT=x\n' > "$MV/umzug-open"; _ua status >/dev/null 2>&1; eq UZ.status-offen 11 "$?"
# check: gleich -> 0, schreibt nachher.txt; abweichend -> 1; ohne Ordner-Angabe aus dem gemerkten Umzug.
_mv_run true; _ua check "$MI" >/dev/null 2>&1; eq UZ.check-gleich 0 "$?"
[ -s "$MI/nachher.txt" ] && pass UZ.check-schreibt-nachher || fail UZ.check-schreibt-nachher "fehlt"
( NACHHER_ABWEICHT=1 _ua check "$MI" ) >/dev/null 2>&1; eq UZ.check-abweichung 1 "$?"
rm -f "$MI/vorher.txt"; _ua check "$MI" >/dev/null 2>&1; eq UZ.check-ohne-vorher 2 "$?"
# done: ohne Merker nichts zu tun; ohne Terminal nur mit --yes; mit --yes hebt es die Sperre auf (und das Update geht wieder).
_mv_run true; _ua 'done' >/dev/null 2>&1; eq UZ.done-ohne-umzug 0 "$?"
printf 'STAGE=applied\nMOVE=m\nAT=x\nDIR=%s\n' "$MI" > "$MV/umzug-open"
_ua 'done' >/dev/null 2>"$W/mv.err"; eq UZ.done-ohne-terminal-rc 1 "$?"
[ -e "$MV/umzug-open" ] && pass UZ.done-ohne-terminal-merker-bleibt || fail UZ.done-ohne-terminal-merker-bleibt "weg"
_ua 'done' --yes >"$W/mv.out" 2>"$W/mv.err"; eq UZ.done-yes-rc 0 "$?"
[ ! -e "$MV/umzug-open" ] && pass UZ.done-merker-weg || fail UZ.done-merker-weg "liegt noch"
case "$(cat "$W/mv.out" "$W/mv.err")" in *Proxy*) pass UZ.done-erinnert-an-abraeumen ;; *) fail UZ.done-erinnert-an-abraeumen "$(tail -n3 "$W/mv.err")" ;; esac
# Mitten im Umzug (Stufe nicht angewendet) gibt es keine Abnahme.
printf 'STAGE=restored\nMOVE=m\nAT=x\n' > "$MV/umzug-open"
_ua 'done' --yes >/dev/null 2>&1; eq UZ.done-mitten-drin-rc 1 "$?"
[ -e "$MV/umzug-open" ] && pass UZ.done-mitten-drin-merker-bleibt || fail UZ.done-mitten-drin-merker-bleibt "weg"

# ---------------------------------------------------------------------------- UZ-VT: Verteiler
sed "s|@@LIBDIR@@|$ROOT|" "$ROOT/provisioning/templates/lifeagents.tpl" > "$W/la-cli2"; chmod +x "$W/la-cli2"
case "$(bash "$W/la-cli2" help 2>&1)" in *' umzug '*|*$'\n  umzug'*) pass UZ-VT.hilfe-nennt-umzug ;; *) fail UZ-VT.hilfe-nennt-umzug "kein Eintrag" ;; esac
case "$(bash "$W/la-cli2" umzug help 2>&1 </dev/null)" in *apply*check*done*|*apply*done*) pass UZ-VT.umzug-hilfe ;; *) fail UZ-VT.umzug-hilfe "$(bash "$W/la-cli2" umzug help 2>&1 </dev/null | head -3)" ;; esac
# Auf einer stillgelegten Maschine (alte Seite) gibt es keinen Umzug-Befehl.
_mv_reset; printf 'STAGE=done\n' > "$MV/retired"
case "$(LIFEAGENTS_STATE_DIR="$MV" bash "$W/la-cli2" umzug status 2>&1 </dev/null; echo "rc=$?")" in *stillgelegt*rc=1) pass UZ-VT.stillgelegt-gesperrt ;; *) fail UZ-VT.stillgelegt-gesperrt "$(LIFEAGENTS_STATE_DIR="$MV" bash "$W/la-cli2" umzug status 2>&1 </dev/null | tail -n2)" ;; esac
