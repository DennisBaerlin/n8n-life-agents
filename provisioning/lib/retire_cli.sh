# retire_cli.sh — `lifeagents retire`: Installation fuer den Umzug stilllegen und alles fuer die neue Maschine in einen Ordner
# legen (Mechanik: docs/reference/provisioning.md *Umzug*).
# Gesourct von templates/lifeagents.tpl (mit common.sh, release_inputs.sh, backup_cli.sh samt Install-Primitiven, telegram_cli.sh,
# install_update_timers.sh, install_backup_timer.sh, install_llm_gateway.sh fuer die Unit-Namen). Beide Betriebsarten: im
# Verbund ist es der Rueckweg „neu zuerst stilllegen“.
#
# Ablauf in Stufen; die Datei la_retired_file (runtime.sh) ist zugleich Zustand und Sperre (ab ihr startet nichts n8n):
#   (Vorpruefung, aendert nichts) -> released (Webhook geloest) -> stopped (n8n, Gateway, Timer aus und deaktiviert)
#   -> drained (keine laufende Ausfuehrung mehr in der DB) -> done (Ordner geschrieben).
# Ein neuer Lauf setzt nach der letzten erledigten Stufe fort; `--undo` geht aus jeder Stufe zurueck. PostgreSQL bleibt immer an.
#
# Umzugs-Ordner (0700, Dateien 0600): Sicherung (*.nla.enc; traegt auch Gespraeche, geaenderte Einstellungen und Paket-Zugaenge),
#   move.env (Antworten fuer setup.sh --answers), vorher.txt (move_snapshot),
#   move.manifest (Kopf: Format, Release, Sicherungs-Datei), SO-GEHT-ES-WEITER.txt. move_snapshot nutzt auch
#   `lifeagents move`; es fuehrt auf backup_cli.sh backup_fingerprint.
#
# Exit: 0 ok; 1 Abbruch (Grund auf stderr, nichts weiter geaendert); --status: 0 nicht stillgelegt, 10 mitten drin, 11 fertig.

RETIRE_DRAIN_SECS="${RETIRE_DRAIN_SECS:-300}"
RETIRE_POLL_SECS="${RETIRE_POLL_SECS:-5}"
RETIRE_WEBHOOK_WAIT_SECS="${RETIRE_WEBHOOK_WAIT_SECS:-90}"
RETIRE_BACKUP_MAX_AGE_S="${RETIRE_BACKUP_MAX_AGE_S:-93600}"   # 26 h: die taegliche Sicherung darf einmal knapp ausfallen
RETIRE_OUT_DEFAULT=/root/lifeagents-move
RETIRE_HOST_SUBDIR=lifeagents-move
RETIRE_FORMAT=1
RETIRE_STAGES="released stopped drained done"

retire_usage() {
  cat >&2 <<'USAGE'
lifeagents retire — diese Installation für den Umzug auf eine neue Maschine stilllegen.

Usage: lifeagents retire [--out <ordner>] [--backup-dir <pfad-auf-der-neuen-maschine>]
       lifeagents retire --check | --status | --undo [--restore <ordner>]

  (ohne Option)   Bot lösen, n8n und Zeitgeber anhalten (auch nach einem Neustart), warten, bis nichts mehr läuft,
                  dann Sicherung, Gesprächs-Gedächtnis, Einstellungen und Antworten für die neue Maschine in den
                  Umzugs-Ordner schreiben (Standard /root/lifeagents-move; Docker-Verbund: Unterordner
                  lifeagents-move im Sicherungs-Ordner auf dem Rechner). Die Datenbank bleibt an.
                  Bricht der Lauf ab, macht ein neuer Lauf dort weiter.
  --check         Nur die Vorprüfungen (ändert nichts) — am Vortag als Trockenlauf.
  --status        Wie weit ist die Stilllegung? Exit 0 = nicht stillgelegt, 10 = mitten drin, 11 = fertig.
  --undo          Zurück: nur wenn der Bot frei ist (sonst erst die neue Maschine stilllegen); schaltet alles wieder an.
  --undo --restore <ordner>
                  Wie --undo, spielt vorher die Rück-Sicherung aus <ordner> ein (Umzugs-Ordner der neuen Maschine;
                  nur dieselbe Version).
  --backup-dir <pfad>  Sicherungs-Ordner auf der NEUEN Maschine (kommt in die Antwort-Datei).
USAGE
}

# --- Zustand -------------------------------------------------------------------------------------------------------------
_ret_get() { read_env_value "$(la_retired_file)" "$1" 2>/dev/null || true; }
_ret_set() {
  local f; f="$(la_retired_file)"
  ( umask 077; env_upsert "$f" "$1" "$2" ) || die "Stand der Stilllegung liess sich nicht schreiben ($f)."
}
_ret_stage() { [ -e "$(la_retired_file)" ] || return 0; _ret_get STAGE; }
# _ret_reached <stufe> — 0, wenn die gespeicherte Stufe <stufe> oder eine spaetere ist.
_ret_reached() { la_stage_reached "$RETIRE_STAGES" "$(_ret_stage)" "$1"; }

_ret_sql() { _bkp_psql_scalar "$1"; }
_ret_release() { _bkp_release_tag; }
_ret_timer_units() { local u; for u in "${UPDATE_TIMER_UNITS[@]}"; do printf '%s.timer\n' "$u"; done; printf '%s.timer\n' "$BACKUP_TIMER_UNIT"; }

# _ret_exec_count <status…> -> Anzahl n8n-Ausfuehrungen in diesen Zustaenden (ohne die Denk-Schleife, ohne weich geloeschte: die
#   behalten status running bis zum Hard-Delete, scripts/CLAUDE.md), aus der DB: das geht
#   auch, wenn n8n schon steht.
_ret_exec_count() {
  local st='' s skip; skip="$(thinking_workflow_id)"
  for s in "$@"; do st="${st:+$st,}'$s'"; done
  _ret_sql "SELECT count(*) FROM public.execution_entity WHERE status IN (${st}) AND \"deletedAt\" IS NULL AND \"workflowId\" IS DISTINCT FROM '${skip}'"
}
_ret_open_cards() { _ret_sql "SELECT count(*) FROM agent.hitl_pending WHERE released_at IS NULL AND expires_at > now()"; }

# _ret_doctor_red -> Anzahl ROT von doctor (doctor zaehlt sie als Exit-Code).
_ret_doctor_red() {
  local rc=0
  bash "${LIFEAGENTS_DOCTOR:-$(lifeagents_runtime_dir)/provisioning/doctor.sh}" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# retire_checks -> eine Zeile "<code>\t<satz>" je roter Vorpruefung; leer = alles gruen. Aendert nichts.
retire_checks() {
  local rel n age last
  rel="$(_ret_release)"
  if [ -z "$rel" ] || [ "$rel" = dev ]; then
    printf 'release\tKeine Release-Version installiert — umziehen geht nur von einem Release (lifeagents update).\n'
  fi
  n="$(_ret_doctor_red)"
  [ "$n" = 0 ] || printf 'doctor\tlifeagents doctor meldet %s rote Punkt(e) — erst beheben.\n' "$n"
  n="$(_ret_exec_count waiting 2>/dev/null || echo '?')"
  [ "$n" = 0 ] || printf 'waiting\t%s Ausführung(en) warten auf eine Antwort (offene Karte?) — erst bestätigen oder abbrechen.\n' "$n"
  n="$(_ret_open_cards 2>/dev/null || echo '?')"
  [ "$n" = 0 ] || printf 'cards\t%s Bestätigungs-Karte(n) offen — erst bestätigen oder abbrechen.\n' "$n"
  # Haelt dieser Lauf die Sperre selbst (retire), waere die Probe nur 10 s Warten auf sich selbst.
  [ "${LIFEAGENTS_UPDATE_LOCK_HELD:-0}" = 1 ] || update_lock_free 10 || printf 'busy\tGerade läuft ein Update, eine Sicherung oder eine Wiederherstellung — danach erneut.\n'
  last="$(read_env_value "$BACKUP_STATE_FILE" LAST_OK 2>/dev/null || true)"
  [[ $last =~ ^[0-9]+$ ]] || last=0
  age=$(( $(date +%s) - last ))
  [ "$age" -le "$RETIRE_BACKUP_MAX_AGE_S" ] \
    || printf 'backup\tDie letzte gelungene Sicherung ist älter als 26 Stunden — erst lifeagents backup auto.\n'
  local key; key="$(_bkp_key 2>/dev/null || true)"
  [ "${#key}" -ge 16 ] || printf 'key\tSicherungs-Schlüssel fehlt — ohne ihn lässt sich die Sicherung nicht öffnen.\n'
  return 0
}

# --- Stufen --------------------------------------------------------------------------------------------------------------
_ret_release_webhook() {
  telegram_cmd_release_webhook || die "Bot ließ sich nicht lösen (Telegram nicht erreichbar). Es wurde nichts angehalten — später erneut: lifeagents retire"
}
_ret_stop() {
  local u
  if ! rt_is_compose; then
    while IFS= read -r u; do svc_stop "$u" 2>/dev/null || true; svc_disable "$u"; done < <(_ret_timer_units)
  fi
  svc_stop n8n || die "n8n ließ sich nicht anhalten — lifeagents retire --undo, dann erneut."
  svc_disable n8n
  svc_stop "$LLM_GATEWAY_UNIT_NAME" 2>/dev/null || true
  svc_disable "$LLM_GATEWAY_UNIT_NAME"
}
# _ret_drain — laufende Ausfuehrungen abwarten, solange n8n noch laeuft (Webhook ist schon los: Neues kommt nur von Zeitplaenen).
_ret_drain() {
  local left="$RETIRE_DRAIN_SECS" n
  while [ "$left" -gt 0 ]; do
    # Eine gescheiterte Abfrage ist „unbekannt“, nicht „nichts laeuft“: weiter warten (die Pruefung nach dem Stopp entscheidet).
    n="$(_ret_exec_count running new 2>/dev/null)" || n='?'
    [ "$n" = 0 ] && return 0
    log "Warte auf ${n} laufende Ausführung(en) (noch höchstens ${left} s) ..."
    sleep "$RETIRE_POLL_SECS"; left=$((left - RETIRE_POLL_SECS))
  done
  warn "Nach ${RETIRE_DRAIN_SECS} s laufen noch Ausführungen — n8n hält trotzdem an; danach wird geprüft."
}
# _ret_verify_drained — nach dem Stopp: eine Ausfuehrung, die n8n beim Anhalten abbrach, steht noch auf running/new; eine Karte,
#   die ein Zeitplan in der Wartezeit schickte, wartet (waiting, hitl_pending) — beides ginge mit dem Umzug verloren (n8n-Tabellen
#   ziehen nicht mit, der Tipp liefe ins Leere).
_ret_verify_drained() {
  local n w c
  if ! { n="$(_ret_exec_count running new)" && w="$(_ret_exec_count waiting)" && c="$(_ret_open_cards)"; }; then
    die "Datenbank nicht erreichbar — Prüfung der Ausführungen unmöglich."
  fi
  [ "$n" = 0 ] || die "${n} Ausführung(en) wurden beim Anhalten abgebrochen — bitte zurück (lifeagents retire --undo) und später erneut."
  [ "$w" = 0 ] && [ "$c" = 0 ] \
    || die "In der Wartezeit kam eine Bestätigungs-Karte dazu — bitte zurück (lifeagents retire --undo), die Karte erledigen, dann erneut."
}

# --- Umzugs-Ordner -------------------------------------------------------------------------------------------------------
# _ret_q <wert> -> 'wert' fuer eine .env-Antwort-Datei (install_answers_load liest '…' woertlich, ' als '\'').
_ret_q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# _ret_answer_keys -> "datei\tschluessel" je Antwort, die mitgeht: Host-Fragen (_INSTALL_ENV_KEYS) ohne Proxy-Werte und die
#   Haushalts-Zeitzone. Die Zugaenge der Pakete reisen in der Sicherung (access.json, backup_cli.sh), nicht hier.
_ret_answer_keys() {
  local k core; core="$(lifeagents_env_file core)"
  for k in $_INSTALL_ENV_KEYS HOUSEHOLD_TIMEZONE; do
    case "$k" in REACH_MODE|DOMAIN|TRUSTED_PROXIES) continue ;; esac
    printf '%s\t%s\n' "$core" "$k"
  done
}
# _ret_write_answers <datei> <release> [backup-dir] — Antwort-Datei fuer `setup.sh --answers`. Nie TELEGRAM_WEBHOOK_TAKEOVER: ohne
#   ihn bricht die neue Installation ab, solange der Bot noch woanders hoert (Schutz gegen zwei Bots, release_inputs.sh).
_ret_write_answers() {
  local out="$1" f k v
  {
    printf '# lifeagents-move %s %s — Antworten für setup.sh --answers. Enthält Schlüssel: nur direkt alt -> neu kopieren.\n' "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'REACH_MODE=%s\n' "$(_ret_q tunnel)"
    [ -z "${3:-}" ] || printf 'BACKUP_PARENT_DIR=%s\n' "$(_ret_q "$3")"
    while IFS=$'\t' read -r f k; do
      [ -n "$k" ] || continue
      case "$k" in TELEGRAM_WEBHOOK_TAKEOVER) die "interner Fehler: $k gehört nie in die Umzugs-Datei." ;; esac
      _answer_key_denied "$k" && die "interner Fehler: $k steuert die Installation und gehört nicht in die Antworten."
      v="$(read_env_value "$f" "$k" 2>/dev/null || true)"
      [ -n "$v" ] || continue
      printf '%s=%s\n' "$k" "$(_ret_q "$v")"
    done < <(_ret_answer_keys)
  } > "$out"
}

# move_snapshot -> Vergleichswerte fuer vorher.txt/nachher.txt: der Fingerabdruck der Sicherung (backup_cli.sh backup_fingerprint).
move_snapshot() { backup_fingerprint; }

_ret_next_steps() {
  local pk="$1" dir="$2" base
  base="$(basename "$dir")"
  printf 'So geht es weiter (Stand %s):\n\n' "$(date '+%d.%m.%Y %H:%M')"
  if rt_is_compose; then
    cat <<TXT
Diese Maschine (Docker-Verbund) ist stillgelegt — Rückweg auf die alte Maschine:
1. Hier den Verbund abbauen, die Daten bleiben liegen:  bash setup.sh --uninstall   (ohne --delete-data)
2. Diesen Ordner direkt auf die alte Maschine kopieren (enthält Schlüssel — nie über Laptop oder Chat):
     scp -r ${dir} root@<alte-maschine>:/root/
3. Auf der alten Maschine:  lifeagents retire --undo --restore /root/${base}
TXT
    return 0
  fi
  cat <<TXT
1. Diesen Ordner direkt auf die neue Maschine kopieren (enthält Schlüssel — nie über Laptop oder Chat):
     scp -r ${dir} root@<neue-maschine>:/root/
2. Auf der neuen Maschine einrichten (die Antworten kommen aus der Datei):
     bash setup.sh --answers /root/${base}/move.env -- --packages ${pk}
3. Auf der neuen Maschine die Daten einspielen:
     lifeagents move apply /root/${base}

Zurück (bis zur Abnahme): erst die neue Maschine stilllegen (dort lifeagents retire, dann setup.sh --uninstall ohne
--delete-data), dann hier: lifeagents retire --undo --restore <ordner von der neuen maschine>
TXT
}

# _ret_publish <staging> <ziel> — Dateien in den Umzugs-Ordner: klassisch ein Ordner hier (0700, Dateien 0600, je Datei .part ->
#   umbenannt), im Verbund ein Ordner auf dem Rechner (rt_host_put prueft je Datei die Pruefsumme).
#   Die Sicherung eines frueheren Laufs wuerde sonst mit eingespielt: geloescht wird genau die, die das alte move.manifest nennt —
#   nie andere Sicherungen im Ordner (--out kann der normale Sicherungs-Ordner sein). Ein Ordner mit Inhalt (klassisch) bzw. mit
#   Sicherungen (Verbund) ohne move.manifest bricht ab.
_ret_publish() {
  local st="$1" out="$2" f hd old=''
  if rt_is_compose; then
    hd="$(_bkp_hd "$out")"
    if rt_host_get "$hd" move.manifest > "$st/.alt.manifest" 2>/dev/null; then
      old="$(read_env_value "$st/.alt.manifest" BACKUP_FILE 2>/dev/null || true)"
      case "$old" in */*|*\\*) old='' ;; esac
      [ -z "$old" ] || rt_host_rm "$hd" "$old" || die "Reste im Umzugs-Ordner '${out}' ließen sich nicht entfernen."
    elif [ -n "$(rt_host_ls "$hd" 2>/dev/null)" ]; then
      die "Im Ordner '${out}' liegen Sicherungen, er ist aber kein Umzugs-Ordner — einen eigenen wählen: lifeagents retire --out <ordner>"
    fi
    rm -f "$st/.alt.manifest"
    for f in "$st"/*; do rt_host_put "$hd" "$(basename "$f")" "$f" || die "Datei $(basename "$f") ließ sich nicht in '${out}' schreiben."; done
    return 0
  fi
  if [ -d "$out" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
    [ -e "$out/move.manifest" ] || die "Ordner ${out} ist nicht leer und kein Umzugs-Ordner — einen anderen wählen: lifeagents retire --out <ordner>"
    old="$(read_env_value "$out/move.manifest" BACKUP_FILE 2>/dev/null || true)"
    case "$old" in ''|*/*) ;; *) rm -f -- "${out:?}/${old}" ;; esac
  fi
  ( umask 077; mkdir -p "$out" ) || die "Umzugs-Ordner ${out} ließ sich nicht anlegen."
  chmod 0700 "$out"
  for f in "$st"/*; do
    if ! { install -m 0600 "$f" "$out/.$(basename "$f").part" && mv -f "$out/.$(basename "$f").part" "$out/$(basename "$f")"; }; then
      die "Datei $(basename "$f") ließ sich nicht nach ${out} schreiben."
    fi
  done
}

# _ret_out_dir <--out> -> Ziel-Ordner. Verbund: Unterordner im gemerkten Sicherungs-Ordner auf dem Rechner (die Platte des
#   Containers waere fuer scp unerreichbar).
_ret_out_dir() {
  if [ -n "$1" ]; then printf '%s' "$1"; return 0; fi
  if rt_is_compose; then
    local hd; hd="$(_bkp_host_dir)"
    [ -n "$hd" ] || die "Kein Sicherungs-Ordner auf dem Rechner gewählt — einmalig: lifeagents backup host-dir <ordner>, oder --out <ordner>."
    rt_host_mkdir "$(_bkp_hd "$hd")" "$RETIRE_HOST_SUBDIR" || die "Ordner ${RETIRE_HOST_SUBDIR} ließ sich in '${hd}' nicht anlegen."
    _bkp_join "$hd" "$RETIRE_HOST_SUBDIR"
    return 0
  fi
  printf '%s' "$RETIRE_OUT_DEFAULT"
}

_ret_export() {
  local out="$1" bdir="$2" st rel key name pk
  st="$(_bkp_tmpdir)" || die "Arbeitsordner ließ sich nicht anlegen."
  # shellcheck disable=SC2064  # bewusst jetzt expandieren: $st ist local
  trap "rm -rf -- '$st'" EXIT
  rel="$(_ret_release)"
  key="$(_bkp_key)"
  name="$(_bkp_file_name "$(date -u +%Y%m%d%H%M%S)" "$(printf '%s' "$key" | backup_key_id)" "$rel")"
  # Eigene Subshell: backup_cmd_export setzt seinen EXIT-Trap und beendet sich per die.
  ( backup_cmd_export "$st/$name" ) || die "Sicherung ließ sich nicht schreiben — nichts verloren, erneut: lifeagents retire"
  _ret_write_answers "$st/move.env" "$rel" "$bdir"
  move_snapshot > "$st/vorher.txt" || die "Vergleichswerte ließen sich nicht lesen."
  pk="$(for p in $(_bkp_active_names); do [ "$p" = core ] || printf '%s\n' "$p"; done | paste -sd, -)"
  {
    printf 'FORMAT=%s\nRELEASE=%s\nCREATED=%s\nRUNTIME=%s\nBACKUP_FILE=%s\nPACKAGES=%s\n' \
      "$RETIRE_FORMAT" "$rel" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LIFEAGENTS_RUNTIME:-systemd}" "$name" "${pk:-none}"
  } > "$st/move.manifest"
  _ret_next_steps "${pk:-none}" "$out" > "$st/SO-GEHT-ES-WEITER.txt"
  _ret_publish "$st" "$out"
}

# --- Rueckweg ------------------------------------------------------------------------------------------------------------
# _ret_webhook_state -> free | own | foreign | unknown (Telegram nicht erreichbar). Ohne Bot-Schluessel free: ohne Bot gibt es
#   keinen zweiten, der woanders hoeren koennte.
#   Dieselbe Pruefung wie die Installation (release_inputs.sh _tg_webhook_probe): erkennt auch ein Programm, das per Long-Polling
#   abholt (getUpdates 409 = fremd).
_ret_webhook_state() {
  local token
  token="$(owner_tg_token)"; [ -n "$token" ] || { printf free; return 0; }
  _tg_webhook_probe "$token" "$(read_env_value "${N8N_ENV_FILE:-/etc/n8n/n8n.env}" WEBHOOK_URL 2>/dev/null || true)"
  case "$TG_WEBHOOK_STATE" in ours) printf own ;; free|foreign) printf '%s' "$TG_WEBHOOK_STATE" ;; *) printf unknown ;; esac
}

_ret_start() {
  local u
  svc_enable "$LLM_GATEWAY_UNIT_NAME"; svc_start "$LLM_GATEWAY_UNIT_NAME" || warn "LLM-Gateway startete nicht — $(svc_logs_hint "$LLM_GATEWAY_UNIT_NAME")"
  svc_enable n8n
  # Laeuft n8n noch (Abbruch direkt nach dem Loesen), setzt nur ein Neustart den Webhook wieder: n8n registriert ihn beim Aktivieren.
  if svc_is_active n8n; then svc_restart n8n; else svc_start n8n; fi || die "n8n startete nicht — $(svc_logs_hint n8n). Die Stilllegung ist aufgehoben; Stand: lifeagents doctor"
  if ! rt_is_compose; then
    while IFS= read -r u; do svc_enable "$u"; svc_start "$u" || warn "Zeitgeber ${u} startete nicht."; done < <(_ret_timer_units)
  fi
}

# _ret_fetch_dir <ordner> -> _RET_DIR = lokaler Ordner mit dem Umzugs-Inhalt (Verbund: aus dem Rechner-Ordner geholt). Direkt rufen,
#   nicht in $(…): Aufraeum-Falle und Abbruch (die) gehoeren in die Haupt-Shell.
_ret_fetch_dir() {
  local src="$1" st f
  if ! rt_is_compose; then [ -r "$src/move.manifest" ] || die "In ${src} liegt kein Umzugs-Ordner (move.manifest fehlt)."; _RET_DIR="$src"; return 0; fi
  st="$(_bkp_tmpdir)" || die "Arbeitsordner ließ sich nicht anlegen."
  # shellcheck disable=SC2064  # bewusst jetzt expandieren: $st ist local
  trap "rm -rf -- '$st'" EXIT
  rt_host_get "$(_bkp_hd "$src")" move.manifest > "$st/move.manifest" 2>/dev/null || die "In '${src}' liegt kein Umzugs-Ordner (move.manifest fehlt)."
  # Der Name kommt aus einer Datei des Ordners und wird hier zum Pfad: erst pruefen, dann holen.
  f="$(read_env_value "$st/move.manifest" BACKUP_FILE || true)"
  case "$f" in ''|.|..|*/*) die "move.manifest nennt keine Sicherung." ;; esac
  for f in "$f" vorher.txt; do
    rt_host_get "$(_bkp_hd "$src")" "$f" > "$st/$f" 2>/dev/null || rm -f "$st/$f"
  done
  _RET_DIR="$st"
}

_ret_restore_from() {
  local d="$1" f rel plan prel
  f="$(read_env_value "$d/move.manifest" BACKUP_FILE 2>/dev/null || true)"
  case "$f" in ''|.|..|*/*) die "move.manifest nennt keine Sicherung." ;; esac
  [ -r "$d/$f" ] || die "Sicherung ${f} fehlt im Umzugs-Ordner."
  rel="$(_ret_release)"
  # Erst pruefen (aendert nichts): Release der Sicherung = installierte; sonst Abbruch vor jeder Aenderung.
  plan="$( ( backup_cmd_restore "$d/$f" --plan --json ) 2>/dev/null | tail -n1 || true)"
  prel="$(printf '%s' "$plan" | jq -r '.release // empty' 2>/dev/null || true)"
  [ "$(printf '%s' "$plan" | jq -r '.ok // false' 2>/dev/null)" = true ] \
    || die "Die Rück-Sicherung lässt sich hier nicht einspielen ($(printf '%s' "$plan" | jq -r '.detail // .reason // "Prüfung gescheitert"' 2>/dev/null)). Es wurde nichts geändert."
  [ -n "$prel" ] && [ "$prel" = "$rel" ] \
    || die "Die Rück-Sicherung stammt aus ${prel:-einer unbekannten Version}, hier ist ${rel:-keine Version} installiert — nur dieselbe Version geht zurück. Es wurde nichts geändert."
  # Die Sicherung traegt Gespraeche, Einstellungen und Zugaenge selbst (backup_cli.sh _bkp_restore_parts).
  ( backup_cmd_restore "$d/$f" --yes ) || die "Wiederherstellen gescheitert — die Daten sind unverändert (atomar). Die Sperre bleibt."
}

# --- Verben --------------------------------------------------------------------------------------------------------------
retire_cmd_check() {
  local red; red="$(retire_checks)"
  if [ -z "$red" ]; then ok "Vorprüfungen grün — lifeagents retire kann laufen. Notfallblatt bereitlegen (lifeagents backup key)."; return 0; fi
  printf '%s\n' "$red" | while IFS=$'\t' read -r _ s; do err "$s"; done
  return 1
}

retire_cmd_status() {
  local st; st="$(_ret_stage)"
  if [ ! -e "$(la_retired_file)" ]; then log "Nicht stillgelegt."; return 0; fi
  if [ "$st" = 'done' ]; then
    ok "Stillgelegt seit $(_ret_get AT) (Release $(_ret_get RELEASE)); Umzugs-Ordner: $(_ret_get OUT). Zurück: lifeagents retire --undo"
    return 11
  fi
  warn "Stilllegung angefangen, Stand: ${st:-?} (seit $(_ret_get AT)). Weiter: lifeagents retire — oder zurück: lifeagents retire --undo"
  return 10
}

retire_cmd_run() {
  local out="$1" bdir="$2" red
  require_root
  _bkp_resolve_db
  update_lock_acquire 30 || die "Gerade läuft ein Update, eine Sicherung oder eine Wiederherstellung — danach erneut."
  if [ "$(_ret_stage)" = 'done' ]; then retire_cmd_status || true; return 0; fi
  if [ ! -e "$(la_retired_file)" ]; then
    red="$(retire_checks)"
    if [ -n "$red" ]; then
      printf '%s\n' "$red" | while IFS=$'\t' read -r _ s; do err "$s"; done
      die "Vorprüfungen rot — es wurde nichts geändert."
    fi
  fi
  if ! _ret_reached released; then
    _ret_release_webhook
    _ret_set AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; _ret_set RELEASE "$(_ret_release)"; _ret_set STAGE released
  fi
  if ! _ret_reached stopped; then
    _ret_drain
    _ret_stop
    # n8n lief in der Wartezeit noch und kann den Webhook neu angemeldet haben (Knopf-Karte: hitl/setup.js setzt ihn, wenn er leer
    # ist; Neustart nach Absturz). Jetzt steht n8n, ein zweites Loesen ist endgueltig.
    _ret_release_webhook
    _ret_set STAGE stopped
  fi
  if ! _ret_reached drained; then _ret_verify_drained; _ret_set STAGE drained; fi
  # die in $(…) beendet nur die Unterschale -> ausdruecklich abbrechen.
  out="$(_ret_out_dir "$out")" || exit 1
  _ret_export "$out" "$bdir"
  _ret_set OUT "$out"; _ret_set STAGE 'done'
  ok "Stillgelegt. Umzugs-Ordner: ${out} — nächste Schritte in ${out}/SO-GEHT-ES-WEITER.txt"
}

retire_cmd_undo() {
  local from="$1" ws d
  require_root
  _bkp_resolve_db
  [ -e "$(la_retired_file)" ] || { log "Nicht stillgelegt — nichts zurückzunehmen."; return 0; }
  update_lock_acquire 30 || die "Gerade läuft ein Update, eine Sicherung oder eine Wiederherstellung — danach erneut."
  ws="$(_ret_webhook_state)"
  case "$ws" in
    free|own) ;;
    foreign) die "Der Bot hört gerade woanders (neue Maschine?). Erst dort stilllegen: lifeagents retire, dann setup.sh --uninstall. Hier wurde nichts geändert." ;;
    *) die "Telegram nicht erreichbar — ohne Prüfung, wo der Bot hört, geht es nicht zurück. Hier wurde nichts geändert." ;;
  esac
  export LIFEAGENTS_RETIRE_UNDO=1
  if [ -n "$from" ]; then _ret_fetch_dir "$from"; _ret_restore_from "$_RET_DIR"; fi
  # Erst die Datei weg, dann starten: die n8n-Unit startet sonst nicht (ConditionPathExists, templates/n8n.service.tpl).
  rm -f "$(la_retired_file)"
  _ret_start
  _ret_wait_webhook
}
# _ret_wait_webhook — n8n setzt den Webhook beim Aktivieren selbst; bis zu RETIRE_WEBHOOK_WAIT_SECS darauf warten.
_ret_wait_webhook() {
  local left="$RETIRE_WEBHOOK_WAIT_SECS"
  while [ "$left" -gt 0 ]; do
    if [ "$(_ret_webhook_state)" = own ]; then ok "Zurück: n8n läuft, der Bot hört wieder hier."; return 0; fi
    sleep "$RETIRE_POLL_SECS"; left=$((left - RETIRE_POLL_SECS))
  done
  warn "n8n läuft wieder, der Bot meldet sich aber noch nicht hier an — lifeagents doctor zeigt den Stand."
}

retire_cli() {
  local mode=run out='' bdir='' from='' a prev=''
  for a in "$@"; do
    case "$prev" in
      --out) out="$a"; prev=''; continue ;;
      --backup-dir) bdir="$a"; prev=''; continue ;;
      --restore) from="$a"; prev=''; continue ;;
    esac
    case "$a" in
      --check) mode=check ;;
      --status) mode=status ;;
      --undo) mode=undo ;;
      --out|--backup-dir|--restore) prev="$a" ;;
      help|--help|-h) retire_usage; return 0 ;;
      *) retire_usage; die "lifeagents retire: unbekannte Angabe: $a" ;;
    esac
  done
  [ -z "$prev" ] || die "lifeagents retire: ${prev} braucht einen Wert."
  if [ -n "$from" ] && [ "$mode" != undo ]; then die "--restore gibt es nur mit --undo."; fi
  case "$mode" in
    check)  require_root; _bkp_resolve_db; retire_cmd_check ;;
    status) require_root; retire_cmd_status ;;   # die Datei ist 0600 root: ohne root sahe --status nur „mitten drin“
    undo)   retire_cmd_undo "$from" ;;
    run)    retire_cmd_run "$out" "$bdir" ;;
  esac
}
