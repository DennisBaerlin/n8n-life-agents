# retire_cases.sh — Faelle RT* fuer `lifeagents retire` (lib/retire_cli.sh) und die Sperre „nie zwei Bots“; eingebunden von
# cases.sh (dieselben Attrappen docker/systemctl/runuser, $W, $STUB_LOG, pass/fail/eq, core/scr/res aus Abschnitt SC).
# real-path-test: tests/backup/retire_cases.sh (scripts/dev/retire_test.ps1: echtes n8n + PostgreSQL im klassischen Substrat).
# shellcheck shell=bash disable=SC2016,SC2034,SC2329,SC2015,SC2030,SC2031,SC2086,SC2154  # Attrappen-Funktionen ruft der Lib-Code; Pruef-Ausdruecke in einfachen Quotes; Zahlenlisten (RUNNING) bewusst zerlegt; fails/W/ROOT setzt cases.sh

RS="$W/ret"
_rt_reset() { rm -rf "$RS" "$W/ret_etc" "$W/ret_out"; mkdir -p "$RS" "$W/ret_etc"; : > "$STUB_LOG"; : > "${STUB_LOG}.put"; rm -f "$W/ret.run"; }
_rt_mark() { printf 'STAGE=%s\nAT=2026-11-20T10:00:00Z\nRELEASE=v9.1.0\n' "$1" > "$RS/retired"; }
_rt_log() { grep -E '^(ev|systemctl|docker)\|' "$STUB_LOG" | sed 's/|stdin=.*$//'; }
# _rt_stopped — hat der Lauf n8n schon angehalten? (Attrappen-Antworten „vor“ und „nach dem Stopp“)
_rt_stopped() { grep -qE '^systemctl\|stop\|n8n\||^docker\|compose\|.*\|stop\|n8n' "$STUB_LOG"; }

# ---------------------------------------------------------------------------- RT-S: Sperre in lib/runtime.sh
_rt_reset
_svc() ( export LIFEAGENTS_RUNTIME="${RT:-systemd}" LIFEAGENTS_STATE_DIR="$RS"; "$@" )
_rt_mark 'done'
if _svc svc_start n8n 2>/dev/null; then fail RT-S.start-n8n-gesperrt "rc 0"; else pass RT-S.start-n8n-gesperrt; fi
_svc enable_start_unit n8n 0 2>/dev/null; _svc svc_up n8n 2>/dev/null; _svc svc_restart n8n.service 2>/dev/null
RT=compose _svc svc_start n8n 2>/dev/null; RT=compose _svc enable_start_unit n8n 1 2>/dev/null
if grep -qE 'n8n' "$STUB_LOG"; then fail RT-S.kein-n8n-aufruf "$(grep n8n "$STUB_LOG")"; else pass RT-S.kein-n8n-aufruf; fi
case "$(_svc svc_start n8n 2>&1)" in *stillgelegt*'retire --undo'*) pass RT-S.satz ;; *) fail RT-S.satz "$(_svc svc_start n8n 2>&1)" ;; esac
_svc svc_start postgresql; _svc svc_start lifeagents-backup.timer
eq RT-S.andere-dienste-laufen 2 "$(grep -cE '^systemctl\|start\|(postgresql|lifeagents-backup.timer)\|' "$STUB_LOG")"
: > "$STUB_LOG"; LIFEAGENTS_RETIRE_UNDO=1 _svc svc_start n8n
eq RT-S.undo-darf 1 "$(grep -c '^systemctl|start|n8n|' "$STUB_LOG")"
rm -f "$RS/retired"; : > "$STUB_LOG"; _svc svc_start n8n
eq RT-S.ohne-merker-frei 1 "$(grep -c '^systemctl|start|n8n|' "$STUB_LOG")"

# ---------------------------------------------------------------------------- RT-K: Minuten-Takt setzt aus
_rt_reset; _rt_mark 'done'; rm -f "$W/tick.log" "$W/tick.state"
( export LIFEAGENTS_STATE_DIR="$RS" LIFEAGENTS_RUNTIME=compose; UPDATE_TICK_STATE="$W/tick.state"; BACKUP_AUTO_AT=0000; update_tick )
eq RT-K.tick-still '' "$(cat "$W/tick.log" 2>/dev/null)"
if [ -e "$W/tick.state" ]; then fail RT-K.tick-kein-zustand "tick.state geschrieben"; else pass RT-K.tick-kein-zustand; fi

# ---------------------------------------------------------------------------- RT-B: Boot-Start im Verbund laesst n8n aus
_rt_cfg="$(jq -c '.services.n8n = {image:"n8n:t", container_name:"lifeagents-n8n"}' <<<"$SC_CFG")"
SC_CFG="$_rt_cfg" STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING='lifeagents-anchor lifeagents-n8n lifeagents-edge' STUB_RUNNING=lifeagents-anchor \
  STUB_CAT__var_la_retired='STAGE=done' scr start --json
_st="$(grep '^docker|compose|.*|start|' "$STUB_LOG")"
case "$_st" in *'|n8n'*) fail RT-B.boot-ohne-n8n "$_st" ;; *'|edge'*) pass RT-B.boot-ohne-n8n ;; *) fail RT-B.boot-ohne-n8n "kein start: $_st" ;; esac
eq RT-B.boot-ok true "$(res .ok)"
SC_CFG="$_rt_cfg" STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING='lifeagents-anchor lifeagents-n8n lifeagents-edge' STUB_RUNNING=lifeagents-anchor scr start --json
case "$(grep '^docker|compose|.*|start|' "$STUB_LOG")" in *'|n8n'*) pass RT-B.ohne-merker-mit-n8n ;; *) fail RT-B.ohne-merker-mit-n8n "$(grep '|start|' "$STUB_LOG")" ;; esac

# ---------------------------------------------------------------------------- RT-V: Verteiler + provision.sh
_rt_reset; _rt_mark 'done'
sed "s|@@LIBDIR@@|$ROOT|" "$ROOT/provisioning/templates/lifeagents.tpl" > "$W/la-cli"; chmod +x "$W/la-cli"
_cli() { LIFEAGENTS_STATE_DIR="$RS" bash "$W/la-cli" "$@" 2>&1 </dev/null; }
for _c in "update" "config set a b" "package install x" "household pair-owner" "reconfigure" "rollback"; do
  # shellcheck disable=SC2086  # bewusst in Woerter zerlegt
  case "$(_cli $_c; echo "rc=$?")" in *stillgelegt*rc=1) pass "RT-V.gesperrt-${_c%% *}" ;; *) fail "RT-V.gesperrt-${_c%% *}" "$(_cli $_c)" ;; esac
done
case "$(_cli update --tick)" in *stillgelegt*) fail RT-V.tick-durch "gesperrt" ;; *) pass RT-V.tick-durch ;; esac
case "$(_cli version)" in *stillgelegt*) fail RT-V.version-durch "gesperrt" ;; *) pass RT-V.version-durch ;; esac
# hand-injected: Merker-Ordner im Wegwerf-Verzeichnis statt /var/lib/lifeagents (Attrappe, kein echtes System); echter Pfad in tests/backup/retire_cases.sh
case "$(LIFEAGENTS_STATE_DIR="$RS" bash "$ROOT/provisioning/provision.sh" --unattended "$W/none.env" 2>&1; echo "rc=$?")" in
# hand-injected: wie oben, Merker-Ordner im Wegwerf-Verzeichnis
  *stillgelegt*rc=1) pass RT-V.provision-gesperrt ;; *) fail RT-V.provision-gesperrt "$(LIFEAGENTS_STATE_DIR="$RS" bash "$ROOT/provisioning/provision.sh" --unattended "$W/none.env" 2>&1 | tail -n2)" ;; esac

# ---------------------------------------------------------------------------- RT: Ablauf (Attrappen fuer DB, Telegram, Sicherung)
# shellcheck source=/dev/null
for _f in deploy_workflows.sh backup_cli.sh telegram_cli.sh install_update_timers.sh install_backup_timer.sh install_llm_gateway.sh retire_cli.sh; do
  . "$ROOT/provisioning/lib/$_f"
done
# _rr <args…> — retire_cli in einer Subshell; Steuerung ueber Umgebung:
#   RUNNING  = Zahlen fuer die laufenden Ausfuehrungen vor dem Stopp, je Abfrage eine (letzte bleibt), STALE = nach dem Stopp,
#   WAITING/CARDS/DOC_RED = Vorpruefungen, TG_FAIL = Telegram nicht erreichbar, WH_URL = Webhook laut Telegram,
#   PLAN_REL = Release der Rueck-Sicherung, RT = Betriebsart.
_rr() (
  export LIFEAGENTS_RUNTIME="${RT:-systemd}" LIFEAGENTS_STATE_DIR="$RS" LIFEAGENTS_DIR="$W/ret_etc" N8N_ENV_FILE="$W/ret_etc/n8n.env"
  # hand-injected: kurze Takte/Wartezeiten (Sekunden statt Minuten) und ein Abbild-Name fuer die Rechner-Ordner-Attrappe; Standardwerte prueft der echte Weg
  export BACKUP_STATE_FILE="$RS/backup.state" RETIRE_POLL_SECS=1 RETIRE_DRAIN_SECS="${DRAIN:-2}" RETIRE_WEBHOOK_WAIT_SECS=1 LA_PROBE_IMAGE=probe:t
  unset LIFEAGENTS_RETIRE_UNDO
  printf 'LAST_OK=%s\n' "${LAST_OK:-$(date +%s)}" > "$BACKUP_STATE_FILE"
  ev() { printf 'ev|%s\n' "$*" >> "$STUB_LOG"; }
  require_root() { :; }; _bkp_resolve_db() { N8N_DB_NAME=n8n; }; update_lock_acquire() { export LIFEAGENTS_UPDATE_LOCK_HELD=1; }; update_lock_free() { ev lockprobe; return 0; }
  lifeagents_env_file() { printf '%s/%s.env' "$LIFEAGENTS_DIR" "$1"; }   # Abschnitt K ueberschreibt sie global
  _pkg_dir() { printf '%s' "$ROOT/packages"; }
  _ret_doctor_red() { printf '%s' "${DOC_RED:-0}"; }
  _bkp_release_tag() { printf '%s' "${INST_REL:-v9.1.0}"; }; _bkp_key() { printf '0123456789abcdef0123'; }; _bkp_active_names() { printf 'core career'; }
  _bkp_tmpdir() { mktemp -d -p "$W"; }
  _ret_sql() {
    case "$1" in
      *execution_entity*waiting*) if _rt_stopped; then printf "%s" "${WAITING_AFTER:-0}"; else printf "%s" "${WAITING:-0}"; fi ;;
      *execution_entity*running*)
        if _rt_stopped; then ev count-nach-stopp; printf '%s' "${STALE:-0}"
        elif [ -n "${RUN_FAIL:-}" ]; then ev count-vor-stopp; return 1
        else ev count-vor-stopp; set -- ${RUNNING:-0}; local n; n="$(wc -l < "$W/ret.run" 2>/dev/null || echo 0)"; echo x >> "$W/ret.run"
             shift "$(( n < $# ? n : $# - 1 ))"; printf '%s' "$1"; fi ;;
      *hitl_pending*) if _rt_stopped; then printf "%s" "${CARDS_AFTER:-0}"; else printf "%s" "${CARDS:-0}"; fi ;;
      *) printf '' ;;
    esac
  }
  telegram_cmd_release_webhook() { ev deleteWebhook; [ -z "${TG_FAIL:-}" ]; }
  owner_tg_token() { [ -n "${NO_TOKEN:-}" ] || printf 'tok'; }
  tg_api_curl() {
    [ -z "${TG_FAIL:-}" ] || return 7
    case "$2" in
      getWebhookInfo) printf '{"ok":true,"result":{"url":"%s","pending_update_count":0}}
200' "${WH_URL:-}" ;;
      getUpdates*) printf '%s' "${POLL_CODE:-200}" ;;
    esac
  }
  backup_cmd_export() { ev export; printf 'enc' > "$1"; }
  backup_cmd_restore() { case " $* " in *' --plan '*) printf '{"ok":true,"release":"%s"}\n' "${PLAN_REL:-v9.1.0}" ;; *) ev restore ;; esac; }
  move_snapshot() { printf 'rows finance.accounts 3\n'; }
  retire_cli "$@"
)
_rt_env() {
  { printf "OWNER_FIRST_NAME=Erika\nOWNER_LAST_NAME=Muster'mann\nOWNER_BIRTH_DATE=1980-01-01\nTELEGRAM_BOT_TOKEN=123:abc\n"
    printf 'ANTHROPIC_API_KEY=sk-test\nREACH_MODE=proxy\nDOMAIN=bot.example.org\nTRUSTED_PROXIES=192.0.2.10\n'
    printf 'TELEGRAM_WEBHOOK_TAKEOVER=1\nN8N_DB_PASSWORD=geheim\nHOUSEHOLD_TIMEZONE=Europe/Berlin\nOWNER_LANGUAGE=de\nGOOGLE_API_KEY=\n'
    printf 'BACKUP_HOST_DIR=/srv/hd\n'; } > "$W/ret_etc/core.env"
  printf 'ADZUNA_APP_ID=app 1\nADZUNA_APP_KEY=k2\nCAREER_RW_PASSWORD=x\n' > "$W/ret_etc/career.env"
  printf 'WEBHOOK_URL=https://own.example/\nDB_POSTGRESDB_USER=n8n\n' > "$W/ret_etc/n8n.env"
}

# Vorpruefung rot -> nichts geaendert.
for _p in WAITING CARDS DOC_RED; do
  _rt_reset; _rt_env
  ( export "$_p=1"; _rr --out "$W/ret_out" ) >/dev/null 2>&1
  if _rt_log | grep -qE 'deleteWebhook|systemctl\|stop'; then fail "RT.vorpruefung-$_p" "$(_rt_log | tr '\n' ' ')"; else pass "RT.vorpruefung-$_p"; fi
  [ ! -e "$RS/retired" ] && pass "RT.vorpruefung-$_p-kein-merker" || fail "RT.vorpruefung-$_p-kein-merker" "Merker liegt"
done
_rt_reset; _rt_env
( LAST_OK=$(( $(date +%s) - 100000 )) _rr --out "$W/ret_out" ) >/dev/null 2>&1
if _rt_log | grep -q deleteWebhook; then fail RT.vorpruefung-alte-sicherung "lief"; else pass RT.vorpruefung-alte-sicherung; fi
_rt_reset; _rt_env
( TG_FAIL=1 _rr --out "$W/ret_out" ) >/dev/null 2>&1
if _rt_log | grep -q 'systemctl|stop'; then fail RT.telegram-weg-nichts-angehalten "$(_rt_log | tr '\n' ' ')"; else pass RT.telegram-weg-nichts-angehalten; fi
[ ! -e "$RS/retired" ] && pass RT.telegram-weg-kein-merker || fail RT.telegram-weg-kein-merker "Merker liegt"

# Normaler Lauf (klassisch): Reihenfolge, Deaktivieren, Ordner.
_rt_reset; _rt_env
( RUNNING='2 1 0' DRAIN=10 _rr --out "$W/ret_out" ) >/dev/null 2>"$W/ret.err"; _rc=$?
eq RT.lauf-ok 0 "$_rc"
_seq="$(_rt_log | sed -E 's/^systemctl\|(stop|disable)\|(.*)$/\1 \2/; s/^ev\|//' | grep -vE '^(systemctl|docker)' | tr '\n' ',')"
case "$_seq" in
  deleteWebhook,count-vor-stopp,count-vor-stopp,count-vor-stopp,stop\ lifeagents-update-check.timer,disable\ lifeagents-update-check.timer,*stop\ n8n,disable\ n8n,*disable\ lifeagents-llm-gateway,deleteWebhook,count-nach-stopp,export,*) pass RT.reihenfolge ;;
  *) fail RT.reihenfolge "$_seq" ;; esac
# Die eigene Sperre haelt der Lauf: keine Wartezeit auf sie (nur --check probt sie).
if _rt_log | grep -q 'ev|lockprobe'; then fail RT.keine-eigene-sperr-probe "Probe lief"; else pass RT.keine-eigene-sperr-probe; fi
_f0=$fails
for _u in n8n lifeagents-llm-gateway lifeagents-update-check.timer lifeagents-update-run.timer lifeagents-backup.timer; do
  grep -q "^systemctl|disable|${_u}|" "$STUB_LOG" || fail "RT.deaktiviert-$_u" "fehlt"
done; [ "$fails" = "$_f0" ] && pass RT.deaktiviert-alle
if grep -q '^systemctl|stop|postgresql' "$STUB_LOG"; then fail RT.postgres-bleibt "gestoppt"; else pass RT.postgres-bleibt; fi
eq RT.merker-fertig 'done' "$(read_env_value "$RS/retired" STAGE)"
eq RT.ordner-rechte 700 "$(stat -c %a "$W/ret_out")"
eq RT.dateien-rechte 600 "$(stat -c %a "$W/ret_out"/* | sort -u | tr '\n' ' ' | sed 's/ $//')"
_f0=$fails
for _f in move.env move.manifest vorher.txt SO-GEHT-ES-WEITER.txt; do
  [ -s "$W/ret_out/$_f" ] || fail "RT.ordner-$_f" "fehlt/leer"
done; [ "$fails" = "$_f0" ] && pass RT.ordner-vollstaendig
_bf="$(read_env_value "$W/ret_out/move.manifest" BACKUP_FILE)"
case "$_bf" in lifeagents-backup-*-v9.1.0.nla.enc) [ -s "$W/ret_out/$_bf" ] && pass RT.sicherung-im-ordner || fail RT.sicherung-im-ordner "Datei fehlt" ;; *) fail RT.sicherung-im-ordner "$_bf" ;; esac
eq RT.manifest-pakete career "$(read_env_value "$W/ret_out/move.manifest" PACKAGES)"
grep -qF -- '--packages career' "$W/ret_out/SO-GEHT-ES-WEITER.txt" && pass RT.naechste-schritte || fail RT.naechste-schritte "$(cat "$W/ret_out/SO-GEHT-ES-WEITER.txt")"
if ls -A "$W"/tmp.* >/dev/null 2>&1; then fail RT.arbeitsordner-weg "$(ls -d "$W"/tmp.*)"; else pass RT.arbeitsordner-weg; fi

# Antwort-Datei: Positivliste, Tunnel, nie Uebernahme/erzeugte Geheimnisse/Proxy; liest sich ohne Warnung zurueck.
_ae="$W/ret_out/move.env"
_keys="$(grep -oE '^[A-Z_]+=' "$_ae" | tr -d = | sort | tr '\n' ' ')"
eq RT.antworten-schluessel 'ANTHROPIC_API_KEY HOUSEHOLD_TIMEZONE OWNER_BIRTH_DATE OWNER_FIRST_NAME OWNER_LANGUAGE OWNER_LAST_NAME REACH_MODE TELEGRAM_BOT_TOKEN ' "$_keys"
if grep -qE '^(TELEGRAM_WEBHOOK_TAKEOVER|DOMAIN|TRUSTED_PROXIES|N8N_DB_PASSWORD|CAREER_RW_PASSWORD|ADZUNA_APP_ID|ADZUNA_APP_KEY)=' "$_ae"; then fail RT.antworten-nie "$(grep -E 'TAKEOVER|DOMAIN|TRUSTED|PASSWORD' "$_ae")"; else pass RT.antworten-nie; fi
_back="$( ( unset REACH_MODE OWNER_LAST_NAME; install_answers_load "$_ae" 2>"$W/ret.load"; printf '%s|%s' "$REACH_MODE" "$OWNER_LAST_NAME" ) )"
eq RT.antworten-zurueck "tunnel|Muster'mann" "$_back"
eq RT.antworten-ohne-warnung '' "$(cat "$W/ret.load")"
_rt_reset; _rt_env
( _rr --out "$W/ret_out" --backup-dir /srv/sicherung ) >/dev/null 2>&1
eq RT.antworten-backup-dir "'/srv/sicherung'" "$(grep '^BACKUP_PARENT_DIR=' "$W/ret_out/move.env" | cut -d= -f2-)"
# Vorab-Release (Umzugs-Probe): Vorpruefung gruen, Ordner und Sicherung tragen das Vorab-Tag (die neue Maschine vergleicht es
# woertlich).
_rt_reset; _rt_env
( INST_REL=v0.51.0-rc.1 _rr --out "$W/ret_out" ) >/dev/null 2>"$W/ret.err"; _rc=$?
eq RT.vorab-lauf-ok 0 "$_rc"
eq RT.vorab-manifest v0.51.0-rc.1 "$(read_env_value "$W/ret_out/move.manifest" RELEASE)"
case "$(read_env_value "$W/ret_out/move.manifest" BACKUP_FILE)" in lifeagents-backup-*-v0.51.0-rc.1.nla.enc) pass RT.vorab-sicherung-name ;; *) fail RT.vorab-sicherung-name "$(read_env_value "$W/ret_out/move.manifest" BACKUP_FILE)" ;; esac

# --status in jeder Stufe; erneuter Lauf setzt fort, ohne Erledigtes zu wiederholen.
_rt_reset; ( _rr --status ) >/dev/null 2>&1; eq RT.status-nicht 0 "$?"
for _s in released stopped drained; do _rt_mark "$_s"; ( _rr --status ) >/dev/null 2>&1; eq "RT.status-$_s" 10 "$?"; done
_rt_mark 'done'; ( _rr --status ) >/dev/null 2>&1; eq RT.status-fertig 11 "$?"
_rt_reset; _rt_env; _rt_mark released
( _rr --out "$W/ret_out" ) >/dev/null 2>&1
# Ab released: nur noch das zweite Loesen nach dem Stopp (das erste ist erledigt).
eq RT.weiter-ab-released 1 "$(_rt_log | grep -c deleteWebhook)"
eq RT.weiter-ab-released-fertig 'done' "$(read_env_value "$RS/retired" STAGE)"
_rt_reset; _rt_env; _rt_mark stopped
( _rr --out "$W/ret_out" ) >/dev/null 2>&1
if _rt_log | grep -qE 'deleteWebhook|systemctl\|stop'; then fail RT.weiter-ab-stopped "$(_rt_log | tr '\n' ' ')"; else pass RT.weiter-ab-stopped; fi
# Abgebrochene Ausfuehrung nach dem Stopp: Abbruch vor dem Export, Stand bleibt, zweiter Lauf schliesst ab.
_rt_reset; _rt_env
( STALE=1 _rr --out "$W/ret_out" ) >/dev/null 2>"$W/ret.err"
if _rt_log | grep -q 'ev|export'; then fail RT.reste-kein-export "export lief"; else pass RT.reste-kein-export; fi
grep -q 'retire --undo' "$W/ret.err" && pass RT.reste-satz || fail RT.reste-satz "$(cat "$W/ret.err")"
eq RT.reste-stand stopped "$(read_env_value "$RS/retired" STAGE)"
: > "$STUB_LOG"; ( _rr --out "$W/ret_out" ) >/dev/null 2>&1
eq RT.reste-zweiter-lauf 'done' "$(read_env_value "$RS/retired" STAGE)"
# Wartezeit abgelaufen: n8n haelt trotzdem an (danach entscheidet die DB-Pruefung).
_rt_reset; _rt_env
( RUNNING='3' DRAIN=2 _rr --out "$W/ret_out" ) >/dev/null 2>"$W/ret.err"
grep -q '^systemctl|stop|n8n|' "$STUB_LOG" && pass RT.wartezeit-dann-stopp || fail RT.wartezeit-dann-stopp "$(_rt_log | tr '\n' ' ')"

# Verbund: n8n per compose stop, keine Timer, Ordner auf dem Rechner.
_rt_reset; _rt_env
( RT=compose _rr ) >/dev/null 2>"$W/ret.err"; _rc=$?
eq RT.verbund-ok 0 "$_rc"
grep -qE '^docker\|compose\|.*\|stop\|n8n' "$STUB_LOG" && pass RT.verbund-stop-n8n || fail RT.verbund-stop-n8n "$(_rt_log | tr '\n' ' ')"
if grep -q '^systemctl' "$STUB_LOG"; then fail RT.verbund-ohne-systemctl "$(grep '^systemctl' "$STUB_LOG")"; else pass RT.verbund-ohne-systemctl; fi
grep -q '^== /out/' "${STUB_LOG}.put" 2>/dev/null || grep -q 'move.env' "$STUB_LOG" && pass RT.verbund-ordner-rechner || fail RT.verbund-ordner-rechner "$(grep 'run' "$STUB_LOG" | head -3)"
eq RT.verbund-ordner '/srv/hd/lifeagents-move' "$(read_env_value "$RS/retired" OUT)"
# Ohne Sicherungs-Ordner auf dem Rechner: Abbruch vor dem Export (die in $(…) darf nicht still mit leerem Ziel weiterlaufen).
_rt_reset; _rt_env; sed -i '/^BACKUP_HOST_DIR=/d' "$W/ret_etc/core.env"
( RT=compose _rr ) >/dev/null 2>"$W/ret.err"; _rc=$?
eq RT.verbund-ohne-ordner-abbruch 1 "$_rc"
if _rt_log | grep -q 'ev|export'; then fail RT.verbund-ohne-ordner-kein-export "export lief"; else pass RT.verbund-ohne-ordner-kein-export; fi

# --undo: Webhook frei -> alles an, Merker weg; fremd -> nichts; Telegram weg -> nichts.
_rt_reset; _rt_env; _rt_mark 'done'
( WH_URL='https://neu.ts.net/webhook/x/webhook' _rr --undo ) >/dev/null 2>"$W/ret.err"
if grep -qE '^systemctl\|(start|restart|enable)' "$STUB_LOG"; then fail RT.undo-fremd-nichts "$(_rt_log | tr '\n' ' ')"; else pass RT.undo-fremd-nichts; fi
[ -e "$RS/retired" ] && pass RT.undo-fremd-merker-bleibt || fail RT.undo-fremd-merker-bleibt "weg"
grep -q 'woanders' "$W/ret.err" && pass RT.undo-fremd-satz || fail RT.undo-fremd-satz "$(cat "$W/ret.err")"
: > "$STUB_LOG"; ( TG_FAIL=1 _rr --undo ) >/dev/null 2>&1
if grep -qE '^systemctl\|(start|restart)' "$STUB_LOG"; then fail RT.undo-telegram-weg "gestartet"; else pass RT.undo-telegram-weg; fi
: > "$STUB_LOG"; ( WH_URL='' _rr --undo ) >/dev/null 2>"$W/ret.err"; _rc=$?
eq RT.undo-frei-ok 0 "$_rc"
_f0=$fails
for _u in n8n lifeagents-update-check.timer lifeagents-update-run.timer lifeagents-backup.timer; do
  grep -q "^systemctl|enable|${_u}|" "$STUB_LOG" || fail "RT.undo-aktiviert-$_u" "fehlt"
done; [ "$fails" = "$_f0" ] && pass RT.undo-aktiviert-alle
grep -qE '^systemctl\|(restart|start)\|n8n\|' "$STUB_LOG" && pass RT.undo-n8n-an || fail RT.undo-n8n-an "$(_rt_log | tr '\n' ' ')"
[ ! -e "$RS/retired" ] && pass RT.undo-merker-weg || fail RT.undo-merker-weg "liegt noch"
_rt_reset; _rt_env; _rt_mark 'done'
( WH_URL='https://own.example/webhook/x/webhook' _rr --undo ) >/dev/null 2>"$W/ret.err"
[ ! -e "$RS/retired" ] && pass RT.undo-eigener-webhook || fail RT.undo-eigener-webhook "Merker liegt"
grep -q 'hört wieder hier' "$W/ret.err" && pass RT.undo-meldet-wieder-hier || fail RT.undo-meldet-wieder-hier "$(tail -n1 "$W/ret.err")"
# Ohne Bot-Schluessel gibt es keinen Bot, der woanders hoeren koennte: der Rueckweg ist frei.
_rt_reset; _rt_env; _rt_mark 'done'
( NO_TOKEN=1 _rr --undo ) >/dev/null 2>"$W/ret.err"; _rc=$?
eq RT.undo-ohne-bot-frei 0 "$_rc"
[ ! -e "$RS/retired" ] && pass RT.undo-ohne-bot-merker-weg || fail RT.undo-ohne-bot-merker-weg "$(cat "$W/ret.err")"

# --undo --restore: andere Release -> nichts; gleiche -> erst einspielen (die Sicherung traegt das Gedaechtnis), dann an.
_rt_reset; _rt_env; _rt_mark 'done'; mkdir -p "$W/rueck"
printf 'FORMAT=1\nRELEASE=v9.1.0\nBACKUP_FILE=b.nla.enc\n' > "$W/rueck/move.manifest"; printf 'enc' > "$W/rueck/b.nla.enc"
( PLAN_REL=v9.0.0 WH_URL='' _rr --undo --restore "$W/rueck" ) >/dev/null 2>"$W/ret.err"
if _rt_log | grep -qE 'ev\|restore|systemctl\|(start|restart)'; then fail RT.undo-restore-andere-release "$(_rt_log | tr '\n' ' ')"; else pass RT.undo-restore-andere-release; fi
grep -q 'dieselbe Version' "$W/ret.err" && pass RT.undo-restore-release-satz || fail RT.undo-restore-release-satz "$(cat "$W/ret.err")"
: > "$STUB_LOG"; ( WH_URL='' _rr --undo --restore "$W/rueck" ) >/dev/null 2>&1
_seq="$(_rt_log | sed 's/^ev|//; s/^systemctl|//' | grep -E '^(restore|start\|n8n|restart\|n8n)' | cut -d'|' -f1-2 | tr '\n' ',')"
eq RT.undo-restore-reihenfolge 'restore,restart|n8n,' "$_seq"
( _rr --restore "$W/rueck" ) >/dev/null 2>&1; eq RT.restore-nur-mit-undo 1 "$?"
rm -rf "$W/rueck"

# ---------------------------------------------------------------------------- RT-P: Funde der Code-Pruefung
# Waehrend der Wartezeit geoeffnete Karte / wartende Ausfuehrung: Abbruch nach dem Stopp, vor dem Export.
for _p in CARDS_AFTER WAITING_AFTER; do
  _rt_reset; _rt_env
  ( export "$_p=1"; _rr --out "$W/ret_out" ) >/dev/null 2>"$W/ret.err"
  if _rt_log | grep -q 'ev|export'; then fail "RT-P.nach-stopp-$_p" "export lief"; else pass "RT-P.nach-stopp-$_p"; fi
  grep -q 'retire --undo' "$W/ret.err" && pass "RT-P.nach-stopp-$_p-satz" || fail "RT-P.nach-stopp-$_p-satz" "$(cat "$W/ret.err")"
done
# Boot-Start: Merker nicht lesbar (Hilfs-Container scheitert) -> n8n bleibt aus (lieber aus als zwei Bots).
SC_CFG="$_rt_cfg" STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING='lifeagents-anchor lifeagents-n8n lifeagents-edge' STUB_RUNNING=lifeagents-anchor \
  STUB_FAIL='/var_la/retired' scr start --json
case "$(grep '^docker|compose|.*|start|' "$STUB_LOG")" in *'|n8n'*) fail RT-P.boot-merker-unlesbar "n8n gestartet" ;; *) pass RT-P.boot-merker-unlesbar ;; esac
# Verteiler: lesen geht, Daten aendern nicht (der Ordner ist geschrieben, vorher.txt passte sonst nicht mehr).
_rt_reset; _rt_mark 'done'
case "$(_cli household list)" in *stillgelegt*) fail RT-P.household-list-frei "gesperrt" ;; *) pass RT-P.household-list-frei ;; esac
case "$(_cli backup restore x.nla.enc --plan --json)" in *stillgelegt*) fail RT-P.probelauf-frei "gesperrt" ;; *) pass RT-P.probelauf-frei ;; esac
for _c in "household add" "backup restore x.nla.enc"; do
  # shellcheck disable=SC2086  # bewusst in Woerter zerlegt
  case "$(_cli $_c; echo "rc=$?")" in *stillgelegt*rc=1) pass "RT-P.gesperrt-${_c// /-}" ;; *) fail "RT-P.gesperrt-${_c// /-}" "$(_cli $_c | tail -n2)" ;; esac
done
# Wiederverwendeter Umzugs-Ordner: die Sicherung, die das alte Manifest nennt, und ein alter Gedaechtnis-Abzug (frueherer Stand) fliegen
# raus; eine
# andere Sicherung im Ordner bleibt (--out kann der normale Sicherungs-Ordner sein); fremder Ordner -> Abbruch.
_rt_reset; _rt_env; mkdir -p "$W/ret_out"
printf 'FORMAT=1\nBACKUP_FILE=lifeagents-backup-1-k0-v9.0.0.nla.enc\n' > "$W/ret_out/move.manifest"; printf 'alt' > "$W/ret_out/memory.dump"
printf 'alt' > "$W/ret_out/lifeagents-backup-1-k0-v9.0.0.nla.enc"; printf 'taeglich' > "$W/ret_out/lifeagents-backup-2-k0-v9.0.0.nla.enc"
( _rr --out "$W/ret_out" ) >/dev/null 2>"$W/ret.err"
[ ! -e "$W/ret_out/memory.dump" ] && pass RT-P.alter-abzug-weg || fail RT-P.alter-abzug-weg "liegt noch"
[ ! -e "$W/ret_out/lifeagents-backup-1-k0-v9.0.0.nla.enc" ] && pass RT-P.alte-move-sicherung-weg || fail RT-P.alte-move-sicherung-weg "liegt noch"
[ -e "$W/ret_out/lifeagents-backup-2-k0-v9.0.0.nla.enc" ] && pass RT-P.andere-sicherung-bleibt || fail RT-P.andere-sicherung-bleibt "geloescht"
eq RT-P.neue-sicherung-da 1 "$(find "$W/ret_out" -name '*-v9.1.0.nla.enc' | wc -l)"
_rt_reset; _rt_env; mkdir -p "$W/ret_out"; printf 'fremd' > "$W/ret_out/notiz.txt"
( _rr --out "$W/ret_out" ) >/dev/null 2>"$W/ret.err"; _rc=$?
eq RT-P.fremder-ordner-abbruch 1 "$_rc"
[ -e "$W/ret_out/notiz.txt" ] && pass RT-P.fremder-ordner-unberuehrt || fail RT-P.fremder-ordner-unberuehrt "weg"
# Vergleichswerte: eine scheiternde Abfrage bricht ab statt eine leere Zeile zu schreiben; System-Tabellen ohne md5; psql 17 gibt
# vor dem Ergebnis je SET eine Zeile aus (so im echten Substrat gesehen).
_ms() (
  _bkp_psql_scalar() { case "$1" in *md5*finance.accounts*) [ -z "${MS_FAIL:-}" ] || return 1; printf 'SET
SET
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;; *config*md5*) printf '' ;; *md5*) printf 'SET
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;; *count*) printf '3' ;; *) printf '' ;; esac; }
  _bkp_bulk_tables() { printf 'agent.reminder_prefs\nfinance.accounts\n'; }; _bkp_filtered() { :; }; _bkp_system_tables() { printf 'agent.reminder_prefs\n'; }
  _bkp_memory_tables() { :; }; _bkp_access_write_bundle() { printf '{}' > "$1/access.json"; }
  move_snapshot
)
( MS_FAIL=1 _ms ) >/dev/null 2>&1; _rc=$?
[ "$_rc" != 0 ] && pass RT-P.snapshot-fehler-bricht-ab || fail RT-P.snapshot-fehler-bricht-ab "rc 0"
_snap="$(_ms 2>/dev/null)"
case "$_snap" in *'md5 agent.reminder_prefs'*) fail RT-P.system-tabelle-ohne-md5 "$_snap" ;; *'md5 finance.accounts aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'*'rows agent.reminder_prefs 3'*) pass RT-P.system-tabelle-ohne-md5 ;; *) fail RT-P.system-tabelle-ohne-md5 "$_snap" ;; esac
_rt_reset; _rt_env; ( _rr --check ) >/dev/null 2>&1
_rt_log | grep -q 'ev|lockprobe' && pass RT-P.check-probt-sperre || fail RT-P.check-probt-sperre "keine Probe"
# Wartezeit: eine gescheiterte Zaehl-Abfrage heisst „unbekannt“, nicht „nichts laeuft“ -> weiter warten bis zur Grenze.
_rt_reset; _rt_env
( RUN_FAIL=1 DRAIN=3 _rr --out "$W/ret_out" ) >/dev/null 2>&1
_n="$(_rt_log | grep -c 'ev|count-vor-stopp')"
[ "$_n" -ge 3 ] && pass RT-P.wartezeit-db-fehler-wartet || fail RT-P.wartezeit-db-fehler-wartet "nur $_n Abfrage(n)"
# Rueckweg: holt ein Programm per Long-Polling ab (getUpdates 409), gilt der Bot als belegt -> nichts.
_rt_reset; _rt_env; _rt_mark 'done'
( WH_URL='' POLL_CODE=409 _rr --undo ) >/dev/null 2>"$W/ret.err"; _rc=$?
eq RT-P.undo-long-polling-abbruch 1 "$_rc"
[ -e "$RS/retired" ] && pass RT-P.undo-long-polling-merker-bleibt || fail RT-P.undo-long-polling-merker-bleibt "weg"
# Eigene Adresse heisst <WEBHOOK_URL>/webhook/…; eine andere Adresse unter derselben Domain ist fremd.
_rt_reset; _rt_env; _rt_mark 'done'
( WH_URL='https://own.example/anders/x' _rr --undo ) >/dev/null 2>&1
[ -e "$RS/retired" ] && pass RT-P.undo-fremder-pfad || fail RT-P.undo-fremder-pfad "als eigen gewertet"
# Verteiler: Positivliste — lesende Paket-Befehle frei, ein unbekanntes Verb gesperrt.
_rt_reset; _rt_mark 'done'
case "$(_cli package list)" in *stillgelegt*) fail RT-P.package-list-frei "gesperrt" ;; *) pass RT-P.package-list-frei ;; esac
case "$(_cli brandneu; echo "rc=$?")" in *stillgelegt*rc=1) pass RT-P.neues-verb-gesperrt ;; *) fail RT-P.neues-verb-gesperrt "$(_cli brandneu | tail -n1)" ;; esac
# n8n-Unit: startet nicht, solange die Datei liegt (gilt auch fuer Neustart, Restart=on-failure, systemctl von Hand).
_unit="$(cd "$ROOT/provisioning" && render_template templates/n8n.service.tpl N8N_USER=n8n N8N_ENV_FILE=/e N8N_OWNER_ENV_FILE=/o N8N_BIN=/b N8N_HOME=/h RETIRED_FILE=/var/lib/lifeagents/retired 2>/dev/null)"
case "$_unit" in *'ConditionPathExists=!/var/lib/lifeagents/retired'*) pass RT-P.unit-bedingung ;; *) fail RT-P.unit-bedingung "fehlt" ;; esac
