# backup_cli.sh — Runtime-CLI fuer Backup/Restore der Nutzerdaten.
# Gesourct (kein Shebang, kein `set -e` — der Top-Aufrufer `lifeagents` traegt den Error-Mode).
#
# Aufruf: `lifeagents backup <verb> [args]` (die CLI sourct diese Datei + common.sh).
# DB-Zugriff: postgres-Superuser via runuser/Peer-Auth am lokalen Socket (wie config_cli/pkg_lifecycle/
# apply_schema). Superuser ist Pflicht: pg_restore --disable-triggers schaltet auch die internen RI-(FK-)
# Trigger ab (-> keine Topo-Sort/Saldo-Recompute noetig), das geht nur als Superuser.
#
# Architektur: Standard-Werkzeug pg_dump statt selbstgebauter In-DB-Engine. Gesichert wird nur die echte
# Nutzerdaten-Teilmenge (nicht die ganze DB: der Rest ist Code aus dem Repo, n8n-Interna, verschluesselte
# Geheimnisse, Wegwerf-Logs). Deklariert rein im manifest.json (`backup`-Block, je Paket) — das Manifest
# ist die einzige Quelle.
#   * schema_dump-Pakete (finance): das ganze Schema via pg_dump -a --disable-triggers -Fc (materialisierte
#     Tabellen 1:1, kein Recompute), exclude_tables raus.
#   * full_tables (agent.advisor_plans/guide_onboarding_state): ganz, via pg_dump -t.
#   * filtered_tables (agent.core_contexts managed_by='agent', monitor_triggers origin='user'): pg_dump kann
#     nicht zeilen-filtern -> Export als jsonb (SELECT ... WHERE), Restore regel-bewusst via
#     core.fn_backup_restore_filtered (protected Contexts nur UPDATE, family vor finance_profile, monitor entdoppelt).
# pg_dump ignoriert -n (Schema), sobald -t gesetzt ist -> alle bulk-Tabellen werden explizit per -t enumeriert.
#
# Bundle = verschluesseltes Tarball {manifest.json (Header: bundle_format/release/packages/versions/migrations/verify_counts),
#   data.dump (pg_dump -Fc), shared.json (gefilterte Zeilen)}, gpg --symmetric AES256, Passphrase = aktiver Schluessel
#   aus core.backup_key (Lebenszyklus: common.sh *Sicherungs-Verschluesselung*). Klartext nur transient in /dev/shm.
#   Dateiname lifeagents-backup-<ts>-k<schluessel-id>-v<release>.nla.enc: die ID trennt "falscher Schluessel" von
#   "beschaedigt" und begrenzt das Aufraeumen auf eigene Sicherungen; die Release waehlt nur den Hinweis-Satz bei einem Aufbau-Unterschied.
# Notfallblatt: `backup key` zeigt den Schluessel (common.sh backup_kit_text); ein Restore, den kein gespeicherter
#   Schluessel oeffnet, nimmt ihn vom Blatt an (TTY verdeckt oder --key-stdin, nie argv) und macht ihn in derselben
#   Restore-TX zum aktiven.
#
# Restore ist atomar: pg_restore -f - erzeugt SQL-Text (kein eigener DB-Connect); TRUNCATE + Restore-SQL +
#   fn_backup_restore_filtered + Count-Verify laufen als ein `psql -1`-Skript (eine TX) -> jeder Fehler rollt
#   alles zurueck, die alte Welt bleibt intakt. Decrypt/Header-/Pre-Flight-Checks und der Abgleich des Aufbaus
#   (_bkp_schema_check) passieren vor dem Wipe. Fehlt ein Bundle-Paket mit backup-Block -> Auto-Install
#   `pkg_install_one --no-seed` (der Restore bringt die Daten), dann Pre-Flight-Recheck; Fehlschlag = Abbruch vor jedem Wipe.
#   Nach der TX gleicht _bkp_converge die Code-Fakten an diese Version an (wie ein Update).

DB_SUPERUSER="${DB_SUPERUSER:-postgres}"
# BACKUP_KEY_NAME, Schluessel-Lesen und gpg-Ver-/Entschluesselung leben in common.sh (geteilt mit der Upgrade-Sicherung).

# N8N_DB_NAME aus der n8n.env ableiten — eine Adresse: common.sh.
_bkp_resolve_db() { lifeagents_db_name >/dev/null; }

# _bkp_psql_scalar <sql> -> einzelner Wert auf stdout (leer bei NULL/keine Zeile).
_bkp_psql_scalar() {
  _bkp_resolve_db
  pg_su_psql -v ON_ERROR_STOP=1 -X -tA -d "$N8N_DB_NAME" -c "$1"
}

# _bkp_pgdump_stderr (stdin: stderr von `pg_dump -a`) -> dieselben Zeilen ohne den Block „circular foreign-key constraints“
#   (Warnung, detail-Zeilen mit Tabellennamen, die zwei festen hint-Zeilen). pg_dump meldet Fremdschluessel-Ringe nur bei
#   --data-only (pg_dump.c: getTableDataFKConstraints nur bei dataOnly; Text in pg_dump_sort.c repairDependencyLoop) und raet
#   genau zu --disable-triggers, mit dem wir sichern und zurueckspielen -> fuer uns harmlos, fuer Laien erschreckend. Jede
#   andere Zeile (auch andere Warnungen samt ihren Hinweisen, Fehler) bleibt.
_bkp_pgdump_stderr() {
  awk '
    /^pg_dump: warning: there are circular foreign-key constraints (on this table|among these tables):$/ { ring = 1; next }
    ring && /^pg_dump: detail: / { next }
    ring && /^pg_dump: hint: (You might not be able to restore the dump without using --disable-triggers|Consider using a full dump instead of a --data-only dump)/ { next }
    { ring = 0; print }
  '
}

# _bkp_jsonb_obj <"'key', wert">… -> SQL-Ausdruck fuer ein jsonb-Objekt aus beliebig vielen Paaren: PostgreSQL nimmt hoechstens
#   100 Argumente je Funktion ("cannot pass more than 100 arguments"), jsonb_build_object also hoechstens 50 Paare -> Bloecke
#   zu 50, mit || verbunden. Ohne Paare '{}'.
_bkp_jsonb_obj() {
  local out='' chunk='' i=0 p
  [ "$#" -gt 0 ] || { printf "'{}'::jsonb"; return 0; }
  for p in "$@"; do
    chunk="${chunk:+$chunk, }$p"; i=$((i + 1))
    if [ "$i" -eq 50 ]; then out="${out:+$out || }jsonb_build_object($chunk)"; chunk=''; i=0; fi
  done
  [ -z "$chunk" ] || out="${out:+$out || }jsonb_build_object($chunk)"
  printf '%s' "$out"
}

# _bkp_qual_ok <schema.table> -> 0 wenn beide Teile ^[a-z][a-z0-9_]*$ (Injection-Schutz vor Interpolation).
_bkp_qual_ok() { printf '%s' "$1" | grep -qE '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'; }

# _bkp_active_names -> aktive Paketnamen (space-separiert) aus der Registry.
_bkp_active_names() { _bkp_psql_scalar "SELECT string_agg(package, ' ') FROM core.package_registry WHERE status = 'active'"; }

# _bkp_is_active <pkg> <active-list> -> 0 wenn pkg in der Liste.
_bkp_is_active() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# _bkp_bulk_tables [weitere-pakete] -> qualifizierte Tabellen (eine/Zeile, sortiert/unique), die pg_dump per -t sichert:
#   schema_dump-Pakete = alle BASE TABLEs des Paket-Schemas minus exclude_tables; + full_tables.
#   (filtered_tables sind nicht dabei — die laufen ueber jsonb/fn.) Eine Quelle fuer Export-Args,
#   Restore-TRUNCATE und Count-Verify -> kein Drift.
_bkp_bulk_tables() {
  local active mf pkg schema t out=""
  active="$(_bkp_active_names) ${1:-}"   # $1: weitere Pakete (Restore: erst einzuschaltende, ihre Tabellen gibt es schon)
  for mf in "$(_pkg_dir)"/*/manifest.json; do
    [ -r "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)" || continue
    [ -n "$pkg" ] || continue
    _bkp_is_active "$pkg" "$active" || continue
    [ "$(jq -r 'has("backup")' "$mf" 2>/dev/null)" = "true" ] || continue
    # schema_dump: alle BASE TABLEs des Schemas minus excludes
    if [ "$(jq -r '.backup.schema_dump // false' "$mf" 2>/dev/null)" = "true" ]; then
      schema="$(jq -r '.schema // empty' "$mf" 2>/dev/null)"
      if [ -n "$schema" ] && printf '%s' "$schema" | grep -qE '^[a-z][a-z0-9_]*$'; then
        local excl_list; excl_list="$(jq -r '.backup.exclude_tables[]?' "$mf" 2>/dev/null)"
        while IFS= read -r t; do
          [ -n "$t" ] || continue
          # exclude?
          case $'\n'"$excl_list"$'\n' in *$'\n'"$t"$'\n'*) continue ;; esac
          out+="${schema}.${t}"$'\n'
        done < <(_bkp_psql_scalar "SELECT table_name FROM information_schema.tables WHERE table_schema = '${schema}' AND table_type = 'BASE TABLE' ORDER BY table_name")
      fi
    fi
    # full_tables: qualifiziert, as-is
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      out+="${t}"$'\n'
    done < <(jq -r '.backup.full_tables[]?' "$mf" 2>/dev/null)
  done
  printf '%s' "$out" | grep -v '^$' | sort -u
}

# _bkp_filtered [weitere-pakete] -> "qualified<TAB>condition"-Zeilen aller aktiven Pakete (filtered_tables).
_bkp_filtered() {
  local active mf pkg
  active="$(_bkp_active_names) ${1:-}"   # $1 wie _bkp_bulk_tables
  for mf in "$(_pkg_dir)"/*/manifest.json; do
    [ -r "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)" || continue
    [ -n "$pkg" ] || continue
    _bkp_is_active "$pkg" "$active" || continue
    jq -r '(.backup.filtered_tables // {}) | to_entries[] | [.key, .value] | @tsv' "$mf" 2>/dev/null || true
  done
}

# _bkp_key -> Backup-Schluessel aus core.backup_key (oder leer).
_bkp_key() { _bkp_resolve_db; backup_key_read; }

# _bkp_tmpdir -> sicheres tmpfs-Arbeitsverzeichnis (/dev/shm = RAM; PII-Klartext nie auf Disk). 0700.
_bkp_tmpdir() {
  local d
  if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    d="$(mktemp -d -p /dev/shm lifeagents-bkp.XXXXXX)" || return 1
  else
    warn "/dev/shm (tmpfs) nicht verfuegbar -> Klartext-Dump liegt transient auf Disk (mktemp). Klartext-Hygiene beachten."
    d="$(mktemp -d -p /tmp lifeagents-bkp.XXXXXX)" || return 1   # ohne -p entstuende der Ordner im aktuellen Verzeichnis
  fi
  chmod 0700 "$d"
  printf '%s' "$d"
}

# --- Kopie der Sicherung im Owner-Chat ---------------------------------------------------------------------------------
# Eine angeheftete Nachricht; jede weitere Kopie tauscht Datei + Text darin (editMessageMedia). Grund: auch eine stumme neue
# Nachricht (disable_notification) erzeugt bei Telegram einen Hinweis und zaehlt als ungelesen, ein Bearbeiten nicht.
# Schalter = core.config cron_enable.backup_telegram_copy (Haushalts-Erinnerung: Knopf cron_off:<key> an der Nachricht,
# wieder an per /reminders oder `lifeagents config set`; docs/package-contract.md *Cron-Toggle-Modell*).
# backup.state: NOTIFY_DOC=<chat>:<message_id> (die Nachricht), NOTIFY_SHOWN=on|off (was sie zeigt; leer bei gesetztem
# NOTIFY_DOC = Altbestand ohne Zustand, wird beim naechsten Austausch ergaenzt), NOTIFY_PINNED=1|0 (leer = unbekannt, wird
# angeheftet), NOTIFY_DATE=YYYY-MM-DD (Datum der Datei in der Nachricht).
# Key und Knopf stehen als Literal im Code (nicht in einer Variable): contract_lint (7) und cron_toggle_lint lesen sie statisch.
# Datenschutz: das Chiffrat liegt im Telegram-Cloud-Speicher (gpg-Schluessel nur offline) -> Telegram sieht nie Klartext.
# Tests: tests/mock_telegram/backup_notify_cases.sh
# Telegram-Antworten (.description), nach denen die Nachricht nicht mehr bearbeitbar ist -> einmal neu anlegen.
BACKUP_COPY_GONE_RE="message to edit not found|message can't be edited|MESSAGE_ID_INVALID"

# _bkp_copy_enabled -> rc 0 = Kopie an. Gleiche Regel wie /reminders (core.fn_reminder_allowed: nur 'true' ist an, fehlende
#   Zeile = aus); nur eine nicht lesbare DB zaehlt als an (die Kopie ist ein Sicherheitsnetz, ohne DB scheitert die Sicherung
#   ohnehin). Kein `set -e`-Abbruch: der Fehler wird ueber rc ausgewertet.
_bkp_copy_enabled() {
  local v rc=0
  v="$(_bkp_psql_scalar "SELECT core.fn_config_get('core','cron_enable','backup_telegram_copy')" 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ] || [ "$v" = true ]
}

# _bkp_household_day [<epoch>] -> YYYY-MM-DD in der Haushalts-Zeitzone (nie die Container-Zeitzone), ohne Argument heute.
_bkp_household_day() {
  local tz; tz="$(read_env_value "$(lifeagents_env_file core)" HOUSEHOLD_TIMEZONE 2>/dev/null || true)"
  if [ -n "${1:-}" ]; then TZ="${tz:-Europe/Berlin}" date -d "@$1" +%Y-%m-%d; else TZ="${tz:-Europe/Berlin}" date +%Y-%m-%d; fi
}

# _bkp_copy_date <YYYY-MM-DD> -> Datum in der Owner-Sprache (core.fn_fmt_date), sonst ISO. Braucht _BACKUP_LANG.
_bkp_copy_date() {
  local d; d="$(_bkp_psql_scalar "SELECT core.fn_fmt_date('$1'::date, '${_BACKUP_LANG:-de}')" 2>/dev/null || true)"
  printf '%s' "${d:-$1}"
}

# _bkp_tg_state -> unchanged | gone | permanent | transient: Einordnung der letzten Telegram-Fehlantwort (TG_BODY;
#   TG_ERR ist der gekuerzte, erklaerte Text und taugt nicht zum Vergleich). permanent = sonstige 4xx ausser 429 (ein
#   Wiederholen aendert nichts), transient = 5xx, 429, keine Verbindung (der naechste Lauf versucht es erneut).
_bkp_tg_state() {
  local d c
  d="$(printf '%s' "$TG_BODY" | jq -r '.description // empty' 2>/dev/null || true)"
  c="$(printf '%s' "$TG_BODY" | jq -r '.error_code // empty' 2>/dev/null || true)"
  if [[ "$d" == *'message is not modified'* ]]; then printf unchanged
  elif [[ "$d" =~ $BACKUP_COPY_GONE_RE ]]; then printf gone
  elif [[ "$c" =~ ^4[0-9][0-9]$ ]] && [ "$c" != 429 ]; then printf permanent
  else printf transient; fi
}

# _bkp_copy_target <chat> -> message_id der gemerkten Nachricht, wenn sie in <chat> liegt (ein anderer Chat = neues Owner-Pairing:
#   die fremde Nachricht wird nie angefasst).
_bkp_copy_target() {
  local m; m="$(read_env_value "$BACKUP_STATE_FILE" NOTIFY_DOC 2>/dev/null || true)"
  if [[ "$m" =~ ^(-?[0-9]+):([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" = "$1" ]; then printf '%s' "${BASH_REMATCH[2]}"; fi
}

# _bkp_copy_chat -> Owner-chat_id auf stdout, rc 1 (mit Warnung) ohne curl/Token/Pairing. Der Aufrufer loest vorher die DB auf
#   (_bkp_resolve_db in der eigenen Shell): der Aufruf hier laeuft in $(...), sonst fiele _resolve_owner_chat_id still auf '0'.
_bkp_copy_chat() {
  need_cmd curl || { warn "curl fehlt -> Kopie im Telegram-Chat uebersprungen."; return 1; }
  [ -n "$(owner_tg_token)" ] || { warn "Kein TELEGRAM_BOT_TOKEN in $(lifeagents_env_file core) -> Kopie im Telegram-Chat uebersprungen."; return 1; }
  local chat; chat="$(owner_tg_chat_id)"
  [ -n "$chat" ] || { warn "Owner-chat_id unbekannt/ungepairt -> Kopie im Telegram-Chat uebersprungen."; return 1; }
  printf '%s' "$chat"
}

# _bkp_copy_prepare -> DB und Owner-Sprache in der aufrufenden Shell aufloesen (die Texte entstehen in $(...)-Teilschalen;
#   ohne das fragte jede einzeln die DB, und vor _bkp_resolve_db die falsche).
_bkp_copy_prepare() {
  _bkp_resolve_db
  [ -n "${_BACKUP_LANG:-}" ] || _BACKUP_LANG="$(backup_kit_lang)"
}

# _bkp_copy_pin_state <token> <chat> <message_id> <1|0> — Nachricht an- bzw. losheften (ohne Hinweis), nur wenn NOTIFY_PINNED
#   etwas anderes sagt. rc 0 = Zustand erreicht oder nicht erreichbar (4xx, etwa vom Owner schon losgeheftet: kein Wiederholen);
#   rc 1 = voruebergehender Fehler, der naechste Lauf versucht es erneut. So bleibt ein Losheften durch den Owner bestehen.
_bkp_copy_pin_state() {
  local token="$1" chat="$2" mid="$3" want="$4" method=pinChatMessage body
  [ "$(read_env_value "$BACKUP_STATE_FILE" NOTIFY_PINNED 2>/dev/null || true)" != "$want" ] || return 0
  body="{\"chat_id\":${chat},\"message_id\":${mid},\"disable_notification\":true}"
  if [ "$want" = 0 ]; then method=unpinChatMessage; body="{\"chat_id\":${chat},\"message_id\":${mid}}"; fi
  if ! _tg_post "$token" "$method" "$body" && [ "$(_bkp_tg_state)" = transient ]; then
    log "Kopie im Telegram-Chat: ${method} gescheitert (${TG_ERR}) — nächster Versuch beim nächsten Lauf."
    return 1
  fi
  _bkp_state_set NOTIFY_PINNED "$want"
}

# _bkp_notify_telegram <datei> -> die fertige (verschluesselte) Sicherung in die Kopie-Nachricht des Owner-Chats.
#   Schalter an: Text doc_pinned + Knopf, angeheftet. Schalter aus (nur ueber --notify-telegram von Hand): Text doc_off ohne
#   Knopf, losgeheftet, damit der stuendliche Abgleich nichts zurueckdreht. Gemerkte Nachricht da: Datei, Text und Knopf darin
#   tauschen. Neu (sendDocument stumm) nur ohne Nachricht oder wenn Telegram sie nicht mehr kennt; 'not modified' = Erfolg;
#   jeder andere Fehler nur Warnung, kein Neuversand (sonst Doppel-Nachricht mit Hinweis); die alte Nachricht geht erst nach
#   der neuen. Ob die Kopie ueberhaupt laeuft, entscheiden die Aufrufer (backup auto gibt --notify-telegram nur bei Schalter an).
#   Best-effort: immer rc 0 (die Sicherung ist schon geschrieben; der geerbte `set -e` braeche sonst den Export ab). Token nie
#   ins argv (_tg_upload/_tg_post). Der Dateiname bleibt: die Schluessel-ID traegt _bkp_rotate_victims.
_bkp_notify_telegram() {
  local file="$1" chat token size day on=1 cap kb media mid newid='' state
  _bkp_copy_prepare
  chat="$(_bkp_copy_chat)" || return 0
  token="$(owner_tg_token)"
  # 50-MB-Grenze (Telegram-Limit fuer Dateien; unsere Bundles <<1 MB). Numerischer Guard vor -gt (set -e).
  size="$(stat -c '%s' "$file" 2>/dev/null || echo 0)"
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$size" -gt $((50 * 1024 * 1024)) ]; then
    warn "Backup ${size} Byte > 50 MB (Telegram-Limit) -> Kopie im Telegram-Chat uebersprungen. Backup liegt lokal: $file"
    return 0
  fi
  _bkp_copy_enabled || on=0
  day="$(_bkp_household_day)"
  if [ "$on" = 1 ]; then
    cap="$(backup_text notify.doc_pinned date "$(_bkp_copy_date "$day")")"
    kb="$(jq -nc --arg t "$(backup_text notify.btn_off)" --arg cb "cron_off:backup_telegram_copy" '{inline_keyboard:[[{text:$t,callback_data:$cb}]]}')"
  else
    cap="$(backup_text notify.doc_off date "$(_bkp_copy_date "$day")")"
    kb='{"inline_keyboard":[]}'
  fi
  mid="$(_bkp_copy_target "$chat")"

  if [ -n "$mid" ]; then
    media="$(jq -nc --arg c "$cap" '{type:"document",media:"attach://doc",caption:$c}')"
    if _tg_upload "$token" editMessageMedia --form-string "chat_id=${chat}" --form-string "message_id=${mid}" \
         --form-string "media=${media}" --form-string "reply_markup=${kb}" -F "doc=@${file}"; then
      newid="$mid"
    else
      state="$(_bkp_tg_state)"
      case "$state" in
        unchanged) newid="$mid" ;;
        gone) ;;
        *) warn "Kopie im Telegram-Chat nicht ausgetauscht (${TG_ERR:-Telegram-Antwort unklar}) -> unkritisch, nächster Versuch mit der nächsten Sicherung."
           return 0 ;;
      esac
    fi
  fi

  if [ -z "$newid" ]; then
    if _tg_upload "$token" sendDocument --form-string "chat_id=${chat}" -F "document=@${file}" --form-string "caption=${cap}" \
         --form-string "disable_notification=true" --form-string "reply_markup=${kb}"; then
      newid="$(printf '%s' "$TG_BODY" | jq -r '.result.message_id // empty' 2>/dev/null || true)"
      [ -z "$TG_RETRIED" ] || note "Kopie an den Telegram-Chat: erster Versuch scheiterte (${TG_RETRIED}), zweiter gelungen."
    fi
    if [ -z "$newid" ]; then
      warn "Kopie an den Telegram-Chat nicht gesendet (${TG_ERR:-Telegram-Antwort unklar}) -> unkritisch, Backup liegt lokal: $file"
      return 0
    fi
    _bkp_state_set NOTIFY_DOC "${chat}:${newid}"; _bkp_state_set NOTIFY_PINNED 0
    if [ -n "$mid" ]; then
      _tg_post "$token" deleteMessage "{\"chat_id\":${chat},\"message_id\":${mid}}" ||
        log "Die alte Kopie ließ sich im Chat nicht entfernen (${TG_ERR}) — unkritisch."
    fi
  fi
  _bkp_state_set NOTIFY_DATE "$day"
  env_remove_key "$BACKUP_STATE_FILE" NOTIFY_EXPLAINED 2>/dev/null || true   # Merker ohne Leser (Text fuer das erste Mal)
  if [ "$on" = 1 ]; then
    _bkp_copy_pin_state "$token" "$chat" "$newid" 1 || true
    _bkp_state_set NOTIFY_SHOWN on
    ok "Kopie der Sicherung im Telegram-Chat abgelegt (${size} Byte)."
  else
    # Losheften gescheitert -> NOTIFY_SHOWN bleibt 'on', der stuendliche Abgleich holt es nach.
    if _bkp_copy_pin_state "$token" "$chat" "$newid" 0; then _bkp_state_set NOTIFY_SHOWN off; else _bkp_state_set NOTIFY_SHOWN on; fi
    ok "Kopie der Sicherung im Telegram-Chat abgelegt (${size} Byte; Kopie ist ausgeschaltet, daher ohne Knopf)."
  fi
  return 0
}

# _bkp_notify_reconcile — Abgleich der Kopie-Nachricht mit dem Schalter, am Anfang jedes automatischen Laufs (ab BACKUP_AUTO_AT
#   stuendlich, auch wenn die Sicherung des Tages schon gelang): Schalter aus und die Nachricht zeigt noch 'an' -> Aus-Text ohne
#   Knopf (editMessageCaption, die Datei bleibt) und losheften. Noetig, weil der Knopf-Tipp die Datei-Nachricht nicht aendert:
#   der cron_off-Arm des Orchestrators antwortet mit Toast und einer neuen Text-Nachricht. Nachricht weg oder 4xx -> Zustand
#   off; voruebergehender Fehler -> naechster Lauf. Immer rc 0; ohne gemerkte Nachricht weder DB- noch Telegram-Aufruf.
_bkp_notify_reconcile() {
  local chat token mid day ok_at cap
  [ "$(read_env_value "$BACKUP_STATE_FILE" NOTIFY_SHOWN 2>/dev/null || true)" != off ] || return 0
  [ -n "$(read_env_value "$BACKUP_STATE_FILE" NOTIFY_DOC 2>/dev/null || true)" ] || return 0
  _bkp_copy_prepare
  ! _bkp_copy_enabled || return 0
  chat="$(_bkp_copy_chat)" || return 0
  mid="$(_bkp_copy_target "$chat")"; [ -n "$mid" ] || return 0
  token="$(owner_tg_token)"
  day="$(read_env_value "$BACKUP_STATE_FILE" NOTIFY_DATE 2>/dev/null || true)"
  if ! [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    # Altbestand ohne Datum: die letzte gelungene Sicherung war die letzte Kopie.
    ok_at="$(read_env_value "$BACKUP_STATE_FILE" LAST_OK 2>/dev/null || true)"
    if [[ "$ok_at" =~ ^[0-9]+$ ]]; then day="$(_bkp_household_day "$ok_at")"; else day="$(_bkp_household_day)"; fi
  fi
  cap="$(backup_text notify.doc_off date "$(_bkp_copy_date "$day")")"
  if ! _tg_post "$token" editMessageCaption "$(jq -nc --argjson c "$chat" --argjson m "$mid" --arg t "$cap" \
         '{chat_id:$c,message_id:$m,caption:$t,reply_markup:{inline_keyboard:[]}}')"; then
    case "$(_bkp_tg_state)" in
      unchanged) ;;
      transient) log "Kopie im Telegram-Chat: Aus-Hinweis nicht gesetzt (${TG_ERR}) — nächster Versuch beim nächsten Lauf."; return 0 ;;
      *) _bkp_state_set NOTIFY_SHOWN off; return 0 ;;
    esac
  fi
  _bkp_copy_pin_state "$token" "$chat" "$mid" 0 || return 0
  _bkp_state_set NOTIFY_SHOWN off
  return 0
}

# --- Bundle-Teile ------------------------------------------------------------------------------------------------------
# Kopf-Feld parts[] nennt, was das Bundle traegt: data (data.dump), shared (shared.json), memory (memory.*), config (config.json),
# access (access.json). Kennt dieser Stand einen Teil nicht, bricht der Restore vor jeder Aenderung mit version_newer ab: die
# Tabellen-Sperre (_bkp_schema_check) faengt nur neue Tabellen, ein neuer Teil ohne Tabelle verschwaende sonst still.
# Fehlt parts[] (aeltere Sicherung), gelten data und shared.
BACKUP_KNOWN_PARTS="data shared memory config access"
# _bkp_parts_json <arbeitsordner> -> JSON-Liste der Teile, die dort liegen.
_bkp_parts_json() {
  local out
  out='"data","shared"'
  [ ! -f "$1/memory.counts" ] || out="$out,\"memory\""
  [ ! -f "$1/config.json" ]   || out="$out,\"config\""
  [ ! -f "$1/access.json" ]   || out="$out,\"access\""
  printf '[%s]' "$out"
}
# _bkp_has_part <arbeitsordner> <teil> -> rc 0, wenn der Kopf (manifest.json) den Teil nennt.
_bkp_has_part() { jq -e --arg p "$2" '(.parts // ["data","shared"]) | index($p) != null' "$1/manifest.json" >/dev/null 2>&1; }

# --- Zugaenge (access.json) ---------------------------------------------------------------------------------------------
# Vom Nutzer eingegebene Dienst-Zugaenge reisen mit (Owner-Entscheid): die env-Schluessel der Manifest-`credentials` jedes aktiven
# Pakets (/etc/lifeagents/<pkg>.env) und die optionalen Host-Zugaenge BACKUP_HOST_ACCESS_KEYS (core.env). Nie: Instanz-Geheimnisse
# (N8N_ENCRYPTION_KEY, DB-Passwoerter, N8N_API_KEY, INGRESS_ID_KEY, app_secret, backup_key) und die Pflicht-Schluessel jeder
# Neuinstallation (TELEGRAM_BOT_TOKEN, ANTHROPIC_API_KEY): die fragt die Installation vor jedem Restore ohnehin ab, im Archiv
# vergroesserten sie nur den Schaden bei einem Leck. Form {"<pkg>": {"<ENV>": "<wert>"}, "host": {...}}; Klartext nur im
# gpg-Chiffrat und im 0700-tmpfs, nie im argv oder Log. Ein leerer Wert reist nicht.
# Tests: tests/backup/cases.sh (Z.*)
BACKUP_HOST_ACCESS_KEYS="GOOGLE_API_KEY"

# _bkp_pkg_access_keys <pkg> -> die env-Schluessel der Manifest-`credentials` des Pakets, einer je Zeile.
_bkp_pkg_access_keys() {
  local mf; mf="$(_pkg_dir)/$1/manifest.json"
  [ -r "$mf" ] || return 0
  jq -r '(.credentials // {}) | to_entries[] | select(.key != "_comment") | .value.env | keys[]' "$mf" 2>/dev/null || true
}

# _bkp_access_write_bundle <arbeitsordner> -> access.json aus den env-Dateien dieser Installation.
_bkp_access_write_bundle() {
  local d="$1" pkg k v
  : > "$d/access.tsv"
  for k in $BACKUP_HOST_ACCESS_KEYS; do
    v="$(read_env_value "$(lifeagents_env_file core)" "$k" 2>/dev/null || true)"
    [ -z "$v" ] || printf 'host\t%s\t%s\n' "$k" "$v" >> "$d/access.tsv"
  done
  for pkg in $(_bkp_active_names); do
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      v="$(read_env_value "$(lifeagents_env_file "$pkg")" "$k" 2>/dev/null || true)"
      [ -z "$v" ] || printf '%s\t%s\t%s\n' "$pkg" "$k" "$v" >> "$d/access.tsv"
    done < <(_bkp_pkg_access_keys "$pkg")
  done
  jq -Rn 'reduce (inputs | split("\t")) as [$s, $k, $v] ({}; .[$s][$k] = $v)' < "$d/access.tsv" > "$d/access.json" || return 1
  rm -f "$d/access.tsv"
}

# _bkp_access_covers <arbeitsordner> <pkg> [required] -> rc 0, wenn access.json alle env-Schluessel der (Pflicht-)Zugaenge des
#   Pakets traegt. Ohne Teil access (aeltere Sicherung) nie.
_bkp_access_covers() {
  local mf; mf="$(_pkg_dir)/$2/manifest.json"
  [ -r "$mf" ] && [ -r "$1/access.json" ] && _bkp_has_part "$1" access || return 1
  jq -e --arg p "$2" --arg req "${3:-}" --slurpfile a "$1/access.json" \
    '[(.credentials // {}) | to_entries[] | select(.key != "_comment") | select($req == "" or .value.required == true)
      | .value.env | keys[]] | all(. as $k | (($a[0][$p] // {})[$k] // "") != "")' "$mf" >/dev/null 2>&1
}

# _bkp_access_write_env <arbeitsordner> — vor der Paket-Einrichtung die Werte aus access.json in die env-Dateien dieses Systems
#   schreiben, nur wo der Schluessel fehlt oder leer ist (die Installation liest sie dann wie eingegebene Werte). Ein vorhandener,
#   anderer Wert bleibt (eben bei der Installation eingegeben) und wird gemeldet. Nur bekannte Schluessel: Manifest-`credentials`
#   des Pakets bzw. BACKUP_HOST_ACCESS_KEYS; alles andere im Bundle wird ignoriert. Setzt _BKP_ACCESS_WRITTEN (Anzahl).
_bkp_access_write_env() {
  local d="$1" s k v f cur
  _BKP_ACCESS_WRITTEN=0
  _bkp_has_part "$d" access && [ -r "$d/access.json" ] || return 0
  while IFS=$'\t' read -r s k v; do
    [ -n "$k" ] && [ -n "$v" ] || continue
    if [ "$s" = host ]; then
      case " $BACKUP_HOST_ACCESS_KEYS " in *" $k "*) ;; *) continue ;; esac
      f="$(lifeagents_env_file core)"
    else
      # Prozess-Ersetzung statt Pipe: grep -q beendet frueh, unter pipefail zaehlte das als "nicht gefunden".
      if ! [[ $s =~ ^[a-z][a-z0-9_]*$ ]] || ! grep -qxF -- "$k" < <(_bkp_pkg_access_keys "$s"); then continue; fi
      f="$(lifeagents_env_file "$s")"
    fi
    cur="$(read_env_value "$f" "$k" 2>/dev/null || true)"
    if [ -z "$cur" ]; then
      ( umask 077; env_upsert "$f" "$k" "$v" ) || { warn "Zugang ${k} ließ sich nicht schreiben."; continue; }
      _BKP_ACCESS_WRITTEN=$((_BKP_ACCESS_WRITTEN + 1))
    elif [ "$cur" != "$v" ]; then
      warn "${s}: Zugang ${k} auf diesem System behalten (weicht von der Sicherung ab)."
    fi
  done < <(jq -r 'to_entries[] | .key as $s | .value | to_entries[] | [$s, .key, .value] | @tsv' "$d/access.json" 2>/dev/null)
  [ "$_BKP_ACCESS_WRITTEN" = 0 ] || ok "Zugänge aus der Sicherung übernommen: ${_BKP_ACCESS_WRITTEN}."
}

# _bkp_access_inject <arbeitsordner> — nach dem Einspielen die n8n-Credentials der Zugaenge setzen (id-stabiler Upsert mit
#   /credentials/{id}/test je Zugang, inject_access_credentials) fuer die aktiven Pakete, die access.json nennt, und Google.
#   Ein roter Test ist ein Hinweis im Protokoll, kein Abbruch. rc 1 nur, wenn der Upsert selbst scheitert.
_bkp_access_inject() {
  local d="$1" pkgs='' p act
  _bkp_has_part "$d" access && [ -r "$d/access.json" ] || return 0
  act="$(_bkp_active_names)"
  for p in $(jq -r 'keys[] | select(. != "host")' "$d/access.json" 2>/dev/null); do
    [[ $p =~ ^[a-z][a-z0-9_]*$ ]] && _bkp_is_active "$p" "$act" && pkgs="$pkgs $p"
  done
  # shellcheck disable=SC2086  # $pkgs ist eine Liste geprüfter Paketnamen (je ein Wort)
  ( _pkg_resolve_env; inject_access_credentials $pkgs )
}

# --- Fingerabdruck (backup fingerprint) ---------------------------------------------------------------------------------
# backup_fingerprint -> Vergleichswerte des ganzen Sicherungs-Umfangs (sortiert, eine Zeile je Wert "<art> <name> <wert>"):
#   bulk-Tabelle: Zeilen + md5 (System-Tabellen nur Zeilen: der Abgleich setzt sie auf den Stand dieser Version); gefilterte
#   Tabelle: Zeilen + md5 der gefilterten Zeilen, ausser agent.core_contexts und agent.monitor_triggers (nur Zeilen: der Restore
#   setzt dort Zeitstempel bzw. ids neu) und core.llm_usage (zusammengefuehrt, das Ziel hat eigene Zeilen); Einstellungen
#   (core.fn_config_export) je md5 des Werts; Gespraeche je Tabelle Zeilen + md5 mit id (der Restore uebernimmt ids und
#   Folge-Nummern); Zugaenge (access.json-Umfang) nur md5 des Werts, nie der Wert.
#   Gleich auf beiden Seiten = alles wie vorher. Nutzer: move (vorher.txt/nachher.txt) und tests/backup/roundtrip_cases.sh.
#   Der md5 haengt nicht an der Maschine: Text der Zeilen mit festen Sitzungs-Einstellungen (Zeitzone/Datumsform setzt ein LXC aus
#   der System-Locale, das Docker-Abbild auf UTC), sortiert und verbunden werden je Zeile md5-Werte (hex: Sortierung ohne Collation,
#   feste Laenge statt einer Tabelle als ein Text bis zur 1-GB-Grenze).
BACKUP_MD5_SET="SET TimeZone = 'UTC'; SET DateStyle = 'ISO, YMD'; SET IntervalStyle = 'postgres'; SET extra_float_digits = 1;"
_bkp_md5_rows() {   # _bkp_md5_rows <tabelle> [<bedingung>] -> md5 ueber alle Zeilen
  local v
  v="$(_bkp_psql_scalar "${BACKUP_MD5_SET} SELECT md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text) COLLATE \"C\"), '')) FROM ${1} x WHERE ${2:-true}")" || return 1
  v="${v##*$'\n'}"   # psql gibt je SET eine Zeile „SET“ aus, das Ergebnis steht zuletzt
  [[ $v =~ ^[0-9a-f]{32}$ ]] || return 1
  printf '%s' "$v"
}
backup_fingerprint() {
  local t qual cond v sys out='' d
  sys=$'\n'"$(_bkp_system_tables)"$'\n'
  while IFS= read -r t; do
    if [ -z "$t" ] || ! _bkp_qual_ok "$t"; then continue; fi
    v="$(_bkp_psql_scalar "SELECT count(*) FROM ${t}")" || return 1; [ -n "$v" ] || return 1
    out+="rows ${t} ${v}"$'\n'
    [[ "$sys" == *$'\n'"$t"$'\n'* ]] && continue
    v="$(_bkp_md5_rows "$t")" || return 1
    out+="md5 ${t} ${v}"$'\n'
  done < <(_bkp_bulk_tables)
  while IFS=$'\t' read -r qual cond; do
    if [ -z "$qual" ] || ! _bkp_qual_ok "$qual"; then continue; fi
    # core.llm_usage fuehrt der Restore zusammen: das Ziel darf eigene Zeilen haben (roundtrip_cases.sh prueft die Teilmenge).
    [ "$qual" != core.llm_usage ] || continue
    v="$(_bkp_psql_scalar "SELECT count(*) FROM ${qual} WHERE ${cond}")" || return 1; [ -n "$v" ] || return 1
    out+="rows ${qual}[filtered] ${v}"$'\n'
    case "$qual" in agent.core_contexts|agent.monitor_triggers) continue ;; esac
    v="$(_bkp_md5_rows "$qual" "$cond")" || return 1
    out+="md5 ${qual}[filtered] ${v}"$'\n'
  done < <(_bkp_filtered)
  v="$(_bkp_psql_scalar "SELECT 'config ' || (e->>'package') || '.' || (e->>'category') || '.' || (e->>'key') || ' ' || md5(COALESCE(e->>'value', ''))
                         FROM jsonb_array_elements(core.fn_config_export()) e")" || return 1
  out+="${v}"$'\n'
  while IFS= read -r t; do
    if [ -z "$t" ] || ! _bkp_qual_ok "$t"; then continue; fi
    v="$(_bkp_psql_scalar "SELECT count(*) FROM ${t}")" || return 1; [ -n "$v" ] || return 1
    out+="memory ${t} ${v}"$'\n'
    v="$(_bkp_md5_rows "$t")" || return 1
    out+="memory-md5 ${t} ${v}"$'\n'
  done < <(_bkp_memory_tables)
  d="$(_bkp_tmpdir)" || return 1
  if _bkp_access_write_bundle "$d"; then
    while IFS=$'\t' read -r t qual v; do
      [ -n "$qual" ] && out+="access ${t}.${qual} $(printf '%s' "$v" | md5sum | cut -c1-32)"$'\n'
    done < <(jq -r 'to_entries[] | .key as $s | .value | to_entries[] | [$s, .key, .value] | @tsv' "$d/access.json" 2>/dev/null)
  fi
  rm -rf -- "$d"
  printf '%s' "$out" | grep -v '^$' | LC_ALL=C sort
}

# --- Gespraechs-Gedaechtnis (agent.*_chat_memory) ----------------------------------------------------------------------
# Die Tabellen legt n8n zur Laufzeit an (Chat-Memory-Knoten, je Agent eine). Sie reisen als eigener Bundle-Teil: memory.dump
# (pg_dump -Fc, Aufbau + Daten + Folge-Nummern) und memory.counts ("tabelle<TAB>zeilen<TAB>max_id"). Ein Bundle mit memory.counts
# bringt den Teil mit (auch leer = keine Gespraeche); aeltere Sicherungen ohne die Datei lassen das Gedaechtnis des Ziels stehen.
# Tests: tests/backup/cases.sh (G.*), tests/backup/retire_cases.sh, tests/backup/move_cases.sh

# _bkp_memory_tables -> die Gedaechtnis-Tabellen dieser Datenbank, eine je Zeile (agent.<agent>_chat_memory).
_bkp_memory_tables() {
  _bkp_psql_scalar "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname = 'agent' AND tablename LIKE '%\_chat\_memory' ORDER BY 1"
}

# _bkp_memory_write <ordner> -> memory.counts (immer) und memory.dump (wenn es Tabellen gibt). rc 1 bei Fehler.
_bkp_memory_write() {
  local d="$1" t v args=() rc=0
  : > "$d/memory.counts"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    _bkp_qual_ok "$t" || continue
    args+=(-t "$t")
    v="$(_bkp_psql_scalar "SELECT count(*) || E'\t' || COALESCE(max(id), 0) FROM ${t}")" || return 1
    [[ $v =~ ^[0-9]+$'\t'[0-9]+$ ]] || return 1
    printf '%s\t%s\n' "$t" "$v" >> "$d/memory.counts"
  done < <(_bkp_memory_tables)
  [ "${#args[@]}" -gt 0 ] || return 0
  pg_su_exec pg_dump -d "$N8N_DB_NAME" -Fc "${args[@]}" > "$d/memory.dump" 2> "$d/memory.err" || rc=$?
  rm -f "$d/memory.err"
  return "$rc"
}

# _bkp_memory_restore <memory.dump|-> <memory.counts> -> rc 0 eingespielt, 1 Fehler, 2 belegt (Sperre). Eine Transaktion:
#   alle Gedaechtnis-Tabellen des Ziels ersetzen (nicht nur die der Sicherung: sonst bliebe das Gespraech eines Agenten stehen,
#   den es beim Sichern noch nicht gab), Aufbau + Daten + Folge-Nummern aus dem Abzug, Wasserstand des Lern-Laufs je Tabelle auf
#   max(id) (sonst laese er alle alten Gespraeche erneut: doppelte Vorschlaege, Kosten), Zeilen gegen memory.counts. Angelegt wie
#   vom n8n-Knoten selbst: als n8n-Rolle dieser Maschine (ihr Name kann anders sein), ohne Rechte und Trigger aus dem Abzug; den
#   Guard haengt der Event-Trigger beim CREATE TABLE an (agent.chat_memory_guard_init.sql; die n8n-Rolle darf die Guard-Funktion
#   nicht selbst in einen Trigger setzen). n8n laeuft beim Restore weiter: lock_timeout statt endlosem Warten auf ein DROP.
_bkp_memory_restore() {
  local dump="$1" counts="$2" t n owner agent rc=0 wd sql
  [ -r "$counts" ] || return 1
  _bkp_resolve_db
  owner="$(read_env_value "${N8N_ENV_FILE:-/etc/n8n/n8n.env}" DB_POSTGRESDB_USER 2>/dev/null || true)"
  [[ $owner =~ ^[a-z_][a-z0-9_]*$ ]] || { err "n8n-Datenbank-Rolle unbekannt (DB_POSTGRESDB_USER in n8n.env)."; return 1; }
  # Das SQL traegt Gespraechs-Inhalte -> in den 0700-Arbeitsordner (tmpfs), nie neben den Abzug.
  wd="$(_bkp_tmpdir)" || return 1; sql="$wd/memory.sql"
  {
    printf '\\set ON_ERROR_STOP on\n'
    printf "SET LOCAL lock_timeout = '30s';\n"
    while IFS= read -r t; do
      [[ $t =~ ^agent\.[a-z][a-z0-9_]*_chat_memory$ ]] && printf 'DROP TABLE IF EXISTS %s CASCADE;\n' "$t"
    done < <(_bkp_memory_tables; cut -f1 "$counts")
    if [ -s "$counts" ]; then
      printf 'SET ROLE %s;\n' "$owner"
      pg_su_stdin pg_restore --no-owner --no-acl -f - < "$dump" | sed '/^CREATE TRIGGER trg_chat_memory_strip_thinking /d' || rc=$?
      printf 'RESET ROLE;\n'
    fi
    while IFS=$'\t' read -r t n _; do
      [[ $t =~ ^agent\.[a-z][a-z0-9_]*_chat_memory$ ]] || { rc=1; continue; }
      agent="${t#agent.}"; agent="${agent%_chat_memory}"
      printf "INSERT INTO agent.guide_learn_watermark(agent_name, last_seen_id) SELECT '%s', COALESCE(max(id), 0) FROM %s\n" "$agent" "$t"
      printf '  ON CONFLICT (agent_name) DO UPDATE SET last_seen_id = EXCLUDED.last_seen_id;\n'
      printf "DO \$\$ BEGIN IF (SELECT count(*) FROM %s) <> %s THEN RAISE EXCEPTION 'Zeilen in %s weichen ab'; END IF; END \$\$;\n" "$t" "${n:-0}" "$t"
    done < "$counts"
  } > "$sql"
  [ "$rc" -eq 0 ] || { rm -rf -- "$wd"; err "Gedächtnis-Abzug nicht lesbar (pg_restore)."; return 1; }
  # Ueber stdin: psql laeuft als postgres und darf den root-eigenen 0700-Arbeitsordner nicht lesen.
  pg_su_psql -X -q -1 -d "$N8N_DB_NAME" -f - < "$sql" >/dev/null 2> "$wd/err" || rc=$?
  # Fehlertext nicht ausgeben: psql zitiert bei COPY-Fehlern die Datenzeile (Gespraechs-Inhalt).
  if [ "$rc" -ne 0 ] && grep -q 'lock timeout' "$wd/err" 2>/dev/null; then rc=2; fi
  rm -rf -- "$wd"
  [ "$rc" -eq 0 ] || return "$rc"
  ok "Gesprächs-Gedächtnis eingespielt ($(grep -c . "$counts") Tabelle(n)), Lern-Lauf setzt danach an."
}

# _bkp_require_pg <programm> — pg_dump/pg_restore muessen dort liegen, wo die Wrapper sie ausfuehren: auf dem LXC lokal,
#   im Docker-Verbund im Datenbank-Container (pg_su_exec = docker exec, im master gibt es sie nicht).
_bkp_require_pg() { if rt_is_compose; then require_cmd docker; else require_cmd "$1"; fi; }

# --- Sicherungs-Ordner auf dem Rechner (Docker-Verbund) ------------------------------------------
# Die Docker-Platte kann mit allen Volumes verschwinden ("Clean up data", defekte VM-Platte) -> Sicherungen gehen in einen
# vom Nutzer gewaehlten Ordner auf dem Rechner. Gemerkt als BACKUP_HOST_DIR in core.env (nicht geheim) in der Schreibweise des
# Nutzers (Mac/Linux /…, Windows C:\…); an Docker geht immer die Docker-Form (_bkp_hd). Kein Komma (Trenner der --mount-
# Angabe), kein Anfuehrungszeichen, kein Zeilenumbruch.
_bkp_host_dir() { read_env_value "$(lifeagents_env_file core)" BACKUP_HOST_DIR 2>/dev/null || true; }
_bkp_host_dir_valid() {
  case "$1" in
    /*|[A-Za-z]:\\*|[A-Za-z]:/*) ;; *) return 1 ;;
  esac
  case "$1" in *,*|*$'\n'*|*$'\r'*|*'"'*) return 1 ;; esac
  return 0
}
# _bkp_hd <pfad> -> Docker-Form eines Rechner-Pfads: Windows "C:\Daten\x" -> "/run/desktop/mnt/host/c/Daten/x" (so muss ein
#   Container, der ueber den Docker-Socket einen weiteren startet, Laufwerke unter Docker Desktop/WSL2 angeben; "/C/Users/…"
#   scheitert mit "bind source path does not exist" — nur Erfahrungsberichte, Abnahme auf echtem Windows). Sonst unveraendert;
#   ein abschliessender Trenner faellt weg.
_bkp_hd() {
  local p="$1" d
  if [[ "$p" =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
    d="${BASH_REMATCH[1],,}"
    p="${BASH_REMATCH[2]//\\//}"
    p="/run/desktop/mnt/host/${d}/${p}"
  fi
  [ "$p" = / ] || p="${p%/}"
  printf '%s' "$p"
}
# _bkp_join <ordner> <name> -> Pfad in der Schreibweise des Ordners (Windows mit "\", sonst "/").
_bkp_join() { case "$1" in *\\*|[A-Za-z]:) printf '%s\\%s' "${1%\\}" "$2" ;; *) printf '%s/%s' "${1%/}" "$2" ;; esac; }
# _bkp_rotate_victims <behalten> <schluessel-id> (stdin: Dateinamen) -> die zu loeschenden: nur Sicherungen mit dieser
#   Schluessel-ID jenseits der neuesten <behalten>. Fremde IDs (ein alter Rechner im selben Ordner) und Namen ohne ID
#   bleiben immer liegen — sonst loeschte der neue Rechner nach 14 Tagen genau die Sicherungen, aus denen er herkommt.
_bkp_rotate_victims() {
  grep -E "^lifeagents-backup-[0-9]{14}-${2}-v[0-9A-Za-z.-]+\.nla\.enc\$" | sort -r | tail -n +$(( $1 + 1 ))
}
# _bkp_host_rotate <ordner> <schluessel-id> — eigene alte Sicherungen im Rechner-Ordner entfernen. Fehler = nur Warnung.
_bkp_host_rotate() {
  local v=() hd; hd="$(_bkp_hd "$1")"
  mapfile -t v < <(rt_host_ls "$hd" | _bkp_rotate_victims "$BACKUP_HOST_KEEP" "$2" || true)
  [ "${#v[@]}" -gt 0 ] && [ -n "${v[0]}" ] || return 0
  rt_host_rm "$hd" "${v[@]}" || warn "Alte Sicherungen im Ordner '$1' ließen sich nicht aufräumen."
}
# _bkp_release_tag -> Release der laufenden CLI (VERSION, leer ohne Marker) — Dateiname, Kopf-Feld release, Restore-Vergleich.
_bkp_release_tag() { cat "$(lifeagents_version_marker)" 2>/dev/null | head -n1 | tr -d '[:space:]' || true; }
# _bkp_file_name <ts> <schluessel-id> <release> -> Dateiname einer Sicherung; kein Release- oder Vorab-Tag -> "vdev".
_bkp_file_name() {
  local v="$3"
  is_release_tag "$v" || is_prerelease_tag "$v" || v=vdev
  printf 'lifeagents-backup-%s-%s-%s.nla.enc' "$1" "$2" "$v"
}
# _bkp_file_key_id <pfad|name> -> Schluessel-ID aus dem Dateinamen (leer bei Namen ohne ID).
_bkp_file_key_id() {
  local b; b="${1##*/}"
  # Nicht am Anfang verankert: umbenannte Kopien ("Kopie von …", "… (1).nla.enc", Cloud-Konfliktkopie) behalten ihre ID.
  [[ "$b" =~ lifeagents-backup-[0-9]{14}-(k[0-9a-f]{8})-v ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}
# _bkp_key_ids -> IDs aller gespeicherten Schluessel (aktiver zuerst), eine je Zeile.
_bkp_key_ids() {
  local k
  while IFS= read -r k; do [ -n "$k" ] && printf '%s' "$k" | backup_key_id && printf '\n'; done < <(backup_key_candidates 2>/dev/null || true)
}

# --- Ergebnis der Sicherungen (backup.state) ------------------------------------------------------------------------
# LAST_OK / LAST_FAIL (Epoch) + LAST_FAIL_REASON (fester Code folder|key|dump|encrypt|write) — doctor und der Chat-Hinweis
# lesen nur hier. Liegt im Verbund auf dem Volume var_la (uebersteht Neuanlage des master). Der Tick-Marker LAST_BACKUP_TRY
# (update_runner.sh) ist etwas anderes: nur der Stunden-Takt.
_bkp_state_set() { { env_upsert "$BACKUP_STATE_FILE" "$1" "$2" && chmod 0600 "$BACKUP_STATE_FILE"; } 2>/dev/null || true; }
# _bkp_fail <code> <meldung> — Fehlschlag einer Sicherung mit festem Grund festhalten, dann abbrechen.
_bkp_fail() { _bkp_state_set LAST_FAIL "$(date +%s)"; _bkp_state_set LAST_FAIL_REASON "$1"; shift; die "$@"; }

# _bkp_path_clean <pfad> -> Eingabe bereinigt: Leerraum und umschliessende Anfuehrungszeichen am Rand weg ("Als Pfad
#   kopieren" unter Windows liefert "C:\…" in Anfuehrungszeichen, der Finder-Pfad kommt oft mit Leerzeichen).
_bkp_path_clean() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
  case "$p" in \"*\"|\'*\') p="${p:1:${#p}-2}" ;; esac
  printf '%s' "$p"
}
# _bkp_folder_problem <ordner> -> fester Code, warum der Ordner nicht taugt (leer = taugt): invalid | missing | access |
#   readonly. Eine Adresse fuer CLI (host-dir), Fragebogen (bridge.sh backup-dir) und jede Sicherung (Grund in backup.state).
#   "missing" vs. "access" trennt Docker Desktop nicht verlaesslich (beides scheitert als Bind-Pfad) -> Texte nennen beides.
_bkp_folder_problem() {
  _bkp_host_dir_valid "$1" || { printf invalid; return 0; }
  local hd; hd="$(_bkp_hd "$1")"
  rt_host_exists "$hd" || { printf missing; return 0; }
  rt_host_readable "$hd" || { printf access; return 0; }
  rt_host_check "$hd" || { printf readonly; return 0; }
  return 0
}
# _bkp_reason_of <problem> -> Grund-Code fuer backup.state (folder = nicht erreichbar, write = nicht beschreibbar).
_bkp_reason_of() { case "$1" in readonly) printf write ;; *) printf folder ;; esac; }
# _bkp_folder_target <eltern-ordner> -> der Ordner, in den gesichert wird (Schreibweise des Nutzers): liegen im gewaehlten Ordner
#   schon Sicherungen, dieser selbst (sonst entstuende ".../Life Agents Sicherungen/Life Agents Sicherungen"); gibt es darin einen
#   Unterordner mit dem Namen aus IRGENDEINER Katalog-Sprache (alter Rechner auf Deutsch, neuer auf Englisch), dieser; sonst der
#   Name in der Owner-Sprache. Legt nichts an.
_bkp_folder_target() {
  local dir="$1" n f
  if rt_host_ls "$(_bkp_hd "$dir")" 2>/dev/null | grep -q .; then printf '%s' "$dir"; return 0; fi
  for f in "$(_pkg_dir)"/core/locales/*.json; do
    n="$(jq -r '.["core.backup.folder_name"] // empty' "$f" 2>/dev/null || true)"
    [ -n "$n" ] || continue
    if rt_host_exists "$(_bkp_hd "$(_bkp_join "$dir" "$n")")"; then _bkp_join "$dir" "$n"; return 0; fi
  done
  n="$(backup_text folder_name)"
  _bkp_join "$dir" "${n:-Life Agents Sicherungen}"
}
# _bkp_foreign_ids <ordner> -> Schluessel-IDs der Sicherungen im Ordner, die zu keinem gespeicherten Schluessel gehoeren
#   (Einteilung _bkp_classify; Namen ohne ID haben keine ID zum Nennen und fehlen hier).
_bkp_foreign_ids() {
  local b k cls _ts _v out=''
  while IFS=$'\t' read -r b k cls _ts _v; do
    [ "$cls" = other ] && [[ " $out " != *" $k "* ]] && out="${out:+$out }$k"
  done < <(rt_host_ls "$(_bkp_hd "$1")" 2>/dev/null | _bkp_classify || true)
  printf '%s' "$out"
}

# backup_cmd_host_dir [<ordner> [--create]] — Sicherungs-Ordner auf dem Rechner zeigen bzw. setzen (Fragebogen, Terminal).
#   --create: <ordner> ist der Eltern-Ordner (z. B. iCloud Drive); Ziel nach _bkp_folder_target, fehlt es, wird es angelegt,
#   die Schreibprobe laeuft dort, erst dann wird es gemerkt. Sicherungen eines anderen Schluessels bleiben, es gibt einen Hinweis.
backup_cmd_host_dir() {
  rt_is_compose || die "Der Sicherungs-Ordner auf dem Rechner gibt es nur im Docker-Verbund."
  if [ "$#" -eq 0 ]; then
    local d; d="$(_bkp_host_dir)"
    if [ -n "$d" ]; then printf '%s\n' "$d"; else log "Noch kein Sicherungs-Ordner gewählt."; fi
    return 0
  fi
  local dir create=0 prob target foreign
  dir="$(_bkp_path_clean "$1")"
  [ "${2:-}" = --create ] && create=1
  if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$create" != 1 ]; }; then die "Usage: lifeagents backup host-dir [<ordner> [--create]]"; fi
  prob="$(_bkp_folder_problem "$dir")"
  case "$prob" in
    '') ;;
    invalid)  die "Ungültiger Ordner '${dir}' (voller Pfad auf dem Rechner, z. B. /Users/… oder C:\\Users\\…, ohne Komma)." ;;
    readonly) die "In den Ordner '${dir}' lässt sich nicht schreiben (schreibgeschützt oder voll)." ;;
    *)        die "Ordner '${dir}' ist für Docker nicht erreichbar (gibt es ihn? Mac: Systemeinstellungen > Datenschutz & Sicherheit > Dateien und Ordner > Docker erlauben; Windows: Laufwerk und Schreibweise prüfen)." ;;
  esac
  target="$dir"
  if [ "$create" = 1 ]; then
    target="$(_bkp_folder_target "$dir")"
    if [ "$target" != "$dir" ]; then
      rt_host_mkdir "$(_bkp_hd "$dir")" "${target##*[\\/]}" || die "Konnte in '${dir}' den Ordner '${target##*[\\/]}' nicht anlegen."
    fi
    rt_host_check "$(_bkp_hd "$target")" || die "In den Ordner '${target}' lässt sich nicht schreiben."
  fi
  env_upsert "$(lifeagents_env_file core)" BACKUP_HOST_DIR "$target"
  ok "Sicherungen gehen ab jetzt nach '${target}' (auf dem Rechner, verschlüsselt)."
  foreign="$(_bkp_foreign_ids "$target")"
  if [ -n "$foreign" ]; then
    log "Hier liegen Sicherungen eines anderen Rechners (${foreign}). Sie bleiben erhalten; wiederherstellen: ${BACKUP_GUIDE_URL}"
  fi
}

# _bkp_stale_notify — Verbund und klassisch: ist die Bezugszeit (backup_ref_epoch) aelter als BACKUP_STALE_S, bekommt der Owner eine
#   Telegram-Nachricht mit dem festen Grund als Alltagssatz (nie ein Nutzerpfad oder Schluessel; Verbund: Ordnername, klassisch der feste
#   Systemordner BACKUP_LOCAL_DIR, Texte `notify.lxc.*` ohne Start-App; der Systempfad ist kein Personenbezug). Nur tagsueber
#   (BACKUP_NOTIFY_HOURS, Haushalts-Zeitzone; der Takt laeuft um 03:30 und danach stuendlich bis zum Erfolg), hoechstens alle
#   20 h, ohne gewaehlten Ordner nur woechentlich (dort hilft taegliches Erinnern nicht). Sperre LAST_NOTIFY.
#   Best-effort, immer rc 0.
BACKUP_NOTIFY_EVERY_S="${BACKUP_NOTIFY_EVERY_S:-72000}"          # 20 h
BACKUP_NOTIFY_NOFOLDER_S="${BACKUP_NOTIFY_NOFOLDER_S:-604800}"   # 7 Tage
BACKUP_NOTIFY_HOURS="${BACKUP_NOTIFY_HOURS:-09-20}"               # HH-HH, beide einschliesslich
_bkp_stale_notify() {
  local now ref ok_at last_n reason days folder txt every tz h from to
  now="$(date +%s)"
  ref="$(backup_ref_epoch)"; case "$ref" in ''|*[!0-9]*) ref=0 ;; esac
  [ $((now - ref)) -gt "$BACKUP_STALE_S" ] || return 0
  tz="$(read_env_value "$(lifeagents_env_file core)" HOUSEHOLD_TIMEZONE 2>/dev/null || true)"
  h="$(TZ="${tz:-Europe/Berlin}" date +%H)"; from="${BACKUP_NOTIFY_HOURS%-*}"; to="${BACKUP_NOTIFY_HOURS#*-}"
  [ "$((10#$h))" -ge "$((10#$from))" ] && [ "$((10#$h))" -le "$((10#$to))" ] || return 0
  reason="$(read_env_value "$BACKUP_STATE_FILE" LAST_FAIL_REASON 2>/dev/null || true)"
  case "$reason" in folder|nofolder|key|dump|encrypt|write) ;; *) reason=dump ;; esac
  every="$BACKUP_NOTIFY_EVERY_S"; [ "$reason" = nofolder ] && every="$BACKUP_NOTIFY_NOFOLDER_S"
  last_n="$(read_env_value "$BACKUP_STATE_FILE" LAST_NOTIFY 2>/dev/null || true)"; case "$last_n" in ''|*[!0-9]*) last_n=0 ;; esac
  [ "$last_n" -le "$now" ] || last_n=0   # Uhr zurueckgestellt
  [ $((now - last_n)) -ge "$every" ] || return 0
  ok_at="$(read_env_value "$BACKUP_STATE_FILE" LAST_OK 2>/dev/null || true)"; case "$ok_at" in ''|*[!0-9]*) ok_at=0 ;; esac
  folder="$(_bkp_host_dir)"; folder="${folder//\\//}"; folder="${folder##*/}"
  if [ "$ok_at" -gt 0 ]; then days=$(( (now - ok_at) / 86400 )); txt="$(backup_text notify.stale_since days "$days")"
  else txt="$(backup_text notify.stale_never)"; fi
  if rt_is_compose; then
    txt="${txt} $(backup_text "notify.reason.${reason}" folder "${folder:-?}")"
  else
    # Klassisch gibt es weder Start-App noch gewaehlten Ordner: eigene Texte, der Pfad ist der feste Systemordner.
    case "$reason" in write|key) ;; *) reason=failed ;; esac
    txt="${txt} $(backup_text "notify.lxc.${reason}" dir "$BACKUP_LOCAL_DIR")"
  fi
  txt="${txt}"$'\n'"$(backup_text notify.guide url "$BACKUP_GUIDE_URL")"
  notify_owner_telegram "$txt" >/dev/null 2>&1 || return 0
  _bkp_state_set LAST_NOTIFY "$now"
  return 0
}

# _bkp_auto_due -> rc 0, wenn seit der letzten BACKUP_AUTO_AT (Haushalts-Zeitzone) keine Sicherung gelang. Nur backup.state (LAST_OK):
#   ueberlebt Neustart und Uhr-Stellen ohne eigenen Marker.
_bkp_auto_due() {
  local tz now since ok_at hhmm
  tz="$(read_env_value "$(lifeagents_env_file core)" HOUSEHOLD_TIMEZONE 2>/dev/null || true)"
  now="$(date +%s)"; hhmm="${BACKUP_AUTO_AT:0:2}:${BACKUP_AUTO_AT:2:2}"
  since="$(TZ="${tz:-Europe/Berlin}" date -d "today ${hhmm}" +%s)"
  [ "$since" -le "$now" ] || since="$(TZ="${tz:-Europe/Berlin}" date -d "yesterday ${hhmm}" +%s)"
  ok_at="$(read_env_value "$BACKUP_STATE_FILE" LAST_OK 2>/dev/null || true)"; case "$ok_at" in ''|*[!0-9]*) ok_at=0 ;; esac
  [ "$ok_at" -lt "$since" ]
}
# _bkp_local_rotate <ordner> <schluessel-id> — eigene alte Sicherungen im lokalen Ordner entfernen (Auswahl wie im Rechner-Ordner,
#   _bkp_rotate_victims: Vorab-Sicherungen und Dateien fremder Schluessel bleiben liegen).
_bkp_local_rotate() {
  local v=() f
  mapfile -t v < <(find "$1" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | _bkp_rotate_victims "$BACKUP_HOST_KEEP" "$2" || true)
  for f in "${v[@]}"; do [ -n "$f" ] && { rm -f -- "$1/$f" || warn "Alte Sicherung '$f' ließ sich nicht entfernen."; }; done
  return 0
}
_bkp_auto_local_run() {
  local dir="$BACKUP_LOCAL_DIR" key kid copy=()
  _bkp_copy_enabled && copy=(--notify-telegram)
  if ! { mkdir -p "$dir" && chmod 0700 "$dir"; } 2>/dev/null; then
    _bkp_state_set LAST_FAIL "$(date +%s)"; _bkp_state_set LAST_FAIL_REASON write
    warn "Sicherungs-Ordner '${dir}' ließ sich nicht anlegen — nächster Versuch in einer Stunde."
    return 0
  fi
  if ! ( cd "$dir" && backup_cmd_export ${copy[@]+"${copy[@]}"} ); then
    warn "Tägliche Sicherung fehlgeschlagen — nächster Versuch in einer Stunde."
    return 0
  fi
  key="$(_bkp_key)"   # ohne den Zeilenumbruch von psql: die ID entsteht aus dem reinen Schluessel (wie im Export)
  kid="$(printf '%s' "$key" | backup_key_id)"
  _bkp_local_rotate "$dir" "$kid"
}
# _bkp_heartbeat <current|attempted|nofolder> — Lebenszeichen der Sicherung (core.heartbeats) am Ende jedes Laufs, mit der
#   letzten eigenen Sicherungs-Meldung (LAST_NOTIFY): der Waechter schweigt dann, statt doppelt zu melden. Ein von der
#   Zeitgrenze abgebrochener Lauf erreicht diese Zeile nie und schreibt darum keins.
_bkp_heartbeat() {
  local n
  n="$(read_env_value "$BACKUP_STATE_FILE" LAST_NOTIFY 2>/dev/null || true)"; case "$n" in ''|*[!0-9]*) n='' ;; esac
  heartbeat_record backup "$1" '' "$(jq -nc --arg n "$n" 'if $n == "" then {} else {notified_at: ($n | tonumber)} end')"
}
# _bkp_auto_local <scheduled 0|1> — ein Versuch; danach in jedem Fall der Chat-Hinweis (prueft selbst, ob die Sicherung veraltet ist).
_bkp_auto_local() {
  _bkp_notify_reconcile
  if [ "$1" = 1 ] && ! _bkp_auto_due; then _bkp_heartbeat current; return 0; fi
  _bkp_auto_local_run
  _bkp_resolve_db; _bkp_stale_notify
  _bkp_heartbeat attempted
  return 0
}
# backup_cmd_auto [--scheduled] — taegliche Sicherung.
#   Verbund: in den Rechner-Ordner (Tick im master, update_runner.sh: stuendlich ab BACKUP_AUTO_AT). Ohne gemerkten Ordner nur
#   der Vermerk "nofolder" (doctor ROT + Chat-Hinweis statt Dialog); jeder Fehler nur als Warnung, damit der Tick weiterlaeuft.
#   Danach ggf. die Erinnerung bei veralteter Sicherung (_bkp_stale_notify).
#   Klassisch (systemd): nach BACKUP_LOCAL_DIR.
#   Beide Betriebsarten: zuerst, bei jedem Lauf, der Abgleich der Kopie-Nachricht (_bkp_notify_reconcile); bei Schalter an
#   geht die neue Sicherung danach in die Kopie im Owner-Chat (--notify-telegram). `--scheduled` (Timer lifeagents-backup
#   bzw. Tick, stuendlich ab BACKUP_AUTO_AT) sichert nicht noch einmal, wenn seit BACKUP_AUTO_AT schon eine Sicherung gelang;
#   ohne die Option sichert der Aufruf immer. Immer rc 0 (Fehler stehen in backup.state).
backup_cmd_auto() {
  local scheduled=0 a
  for a in "$@"; do
    case "$a" in --scheduled) scheduled=1 ;; *) die "Unbekannte Option: $a" ;; esac
  done
  if ! rt_is_compose; then _bkp_auto_local "$scheduled"; return 0; fi
  _bkp_notify_reconcile
  if [ "$scheduled" = 1 ] && ! _bkp_auto_due; then _bkp_heartbeat current; return 0; fi
  local st=attempted copy=()
  _bkp_copy_enabled && copy=(--notify-telegram)
  if [ -z "$(_bkp_host_dir)" ]; then
    _bkp_state_set LAST_FAIL "$(date +%s)"; _bkp_state_set LAST_FAIL_REASON nofolder
    st=nofolder
  else
    ( backup_cmd_export --to-host ${copy[@]+"${copy[@]}"} ) || warn "Tägliche Sicherung in den Rechner-Ordner fehlgeschlagen — nächster Versuch in einer Stunde."
  fi
  _bkp_resolve_db
  _bkp_stale_notify
  _bkp_heartbeat "$st"
  return 0
}


# ============================================================
# export
# ============================================================
backup_cmd_export() {
  require_cmd jq; _bkp_require_pg pg_dump; require_cmd gpg
  _bkp_resolve_db
  # Arg-Parse wie backup_cmd_restore (reihenfolge-robust): optionaler Positional-Pfad + --notify-telegram.
  # Mehrfacher Positional = letzter gewinnt (konsistent mit restore). Default-Pfad nach der Schleife.
  # --to-host <ordner> (Docker-Verbund): das fertige Chiffrat in einen Ordner auf dem Rechner; ohne Pfad und
  # ohne --to-host nimmt der Verbund den gemerkten Ordner (BACKUP_HOST_DIR), nie die Docker-Platte.
  local out="" notify=0 a host="" want_host=0 prev=""
  for a in "$@"; do
    # --to-host [<ordner>]: ein folgender absoluter Pfad ist der Ordner; sonst gilt der gemerkte (backup auto).
    if [ "$prev" = --to-host ]; then
      prev=""
      case "$a" in /*|[A-Za-z]:\\*|[A-Za-z]:/*) host="$a"; continue ;; esac
    fi
    case "$a" in
      --notify-telegram) notify=1 ;;
      --to-host)         want_host=1; prev="$a" ;;
      --*)               die "Unbekannte Option: $a" ;;
      *)                 out="$a" ;;
    esac
  done
  if [ "$want_host" -eq 1 ] && [ -n "$out" ]; then die "Entweder ein Pfad im System oder --to-host — nicht beides."; fi
  if rt_is_compose && [ -z "$out" ]; then want_host=1; fi
  if [ "$want_host" -eq 1 ]; then
    rt_is_compose || die "--to-host gibt es nur im Docker-Verbund."
    [ -n "$host" ] || host="$(_bkp_host_dir)"
    [ -n "$host" ] || _bkp_fail folder "Kein Sicherungs-Ordner auf dem Rechner gewählt — einmalig: lifeagents backup host-dir <ordner>"
    local hprob; hprob="$(_bkp_folder_problem "$host")"
    [ -z "$hprob" ] || _bkp_fail "$(_bkp_reason_of "$hprob")" "Ordner '${host}' ist auf dem Rechner nicht erreichbar oder nicht beschreibbar (${hprob})."
  fi

  # Eine Sperre fuer Sicherung, Wiederherstellung und Update (bis 30 s: der Minuten-Takt haelt sie kurz). Belegt = Grund busy:
  # kein Alarm (doctor/Chat werten nur das Alter), der Takt versucht es stuendlich erneut.
  update_lock_acquire 30 || _bkp_fail busy "Gerade läuft ein Update oder eine Wiederherstellung — die Sicherung folgt später."
  local key; key="$(_bkp_key)"
  [ -n "$key" ] && [ "${#key}" -ge 16 ] || _bkp_fail key "Backup-Schluessel fehlt/zu kurz (core.backup_key '${BACKUP_KEY_NAME}', >=16 Zeichen). Der Installer setzt ihn out-of-band (bootstrap_owner _ensure_backup_secret)."
  local kid; kid="$(printf '%s' "$key" | backup_key_id)"
  local name; name="$(_bkp_file_name "$(date -u +%Y%m%d%H%M%S)" "$kid" "$(_bkp_release_tag)")"
  if [ -z "$out" ]; then out="$(pwd)/${name}"; fi

  local bulk; bulk="$(_bkp_bulk_tables)"
  [ -n "$bulk" ] || _bkp_fail dump "Keine zu sichernden Tabellen gefunden (aktive Pakete + backup-Block pruefen)."

  local tmp; tmp="$(_bkp_tmpdir)" || die "Konnte Arbeitsverzeichnis nicht anlegen."
  # Klartext-Reste immer aufraeumen (auch bei `die`->exit; RETURN feuert bei exit nicht). Die CLI
  # beendet sich direkt nach backup_cli -> EXIT-Trap deckt Normal-Rueckkehr und Fehler-exit. Pfad jetzt
  # in den Trap-String expandieren (Doppel-Quotes): $tmp ist function-local -> bei der global feuernden
  # EXIT-Trap waere es unter `set -u` "unbound variable".
  # shellcheck disable=SC2064  # bewusst JETZT expandieren: $tmp ist local -> bei der global feuernden EXIT-Trap unter `set -u` unbound
  trap "rm -rf -- '$tmp'" EXIT
  # Rechner-Ordner: das Chiffrat entsteht im tmpfs und geht danach in genau einem Kurzlauf-Container hinaus.
  if [ "$want_host" -eq 1 ]; then out="$tmp/${name}"; fi

  # --- (1) data.dump: pg_dump -a --disable-triggers -Fc mit -t je bulk-Tabelle (qualifiziert/validiert) ---
  local dump_args=() t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    _bkp_qual_ok "$t" || { warn "Ueberspringe ungueltigen Tabellennamen: $t"; continue; }
    dump_args+=( -t "$t" )
  done <<< "$bulk"
  # pg_dump laeuft als postgres (runuser/Peer-Auth) und darf das root-eigene 0700-tmpfs nicht beschreiben
  # -> Ausgabe auf stdout, die root-Shell leitet in die Datei um (postgres fasst das Verzeichnis nie an).
  # stderr erst nach dem Lauf gefiltert ausgeben (_bkp_pgdump_stderr), der Exit-Code bleibt der von pg_dump.
  local dump_rc=0
  pg_su_exec pg_dump -d "$N8N_DB_NAME" -a --disable-triggers -Fc "${dump_args[@]}" > "$tmp/data.dump" 2> "$tmp/dump.err" || dump_rc=$?
  _bkp_pgdump_stderr < "$tmp/dump.err" >&2 || true
  if [ "$dump_rc" -ne 0 ]; then
    _bkp_fail dump "pg_dump fehlgeschlagen."
  fi

  # --- (2) shared.json: gefilterte Tabellen als jsonb (pg_dump kann nicht zeilen-filtern) ---
  local sel=() qual cond
  while IFS=$'\t' read -r qual cond; do
    [ -n "$qual" ] || continue
    _bkp_qual_ok "$qual" || { warn "Ueberspringe ungueltige filtered-Tabelle: $qual"; continue; }
    sel+=("$(printf "'%s', COALESCE((SELECT jsonb_agg(x) FROM %s x WHERE %s), '[]'::jsonb)" "$qual" "$qual" "$cond")")
  done < <(_bkp_filtered)
  if [ "${#sel[@]}" -gt 0 ]; then
    _bkp_psql_scalar "SELECT $(_bkp_jsonb_obj "${sel[@]}")" > "$tmp/shared.json" || _bkp_fail dump "shared.json-Export fehlgeschlagen."
  else
    printf '{}' > "$tmp/shared.json"
  fi

  # --- (2b) weitere Teile (Kopf-Feld parts[]): Gespraeche (memory.*), geaenderte Einstellungen (config.json), Zugaenge ---
  _bkp_memory_write "$tmp" || _bkp_fail dump "Gesprächs-Gedächtnis ließ sich nicht sichern (pg_dump)."
  _bkp_psql_scalar "SELECT core.fn_config_export()" > "$tmp/config.json" || _bkp_fail dump "Einstellungen ließen sich nicht lesen."
  _bkp_access_write_bundle "$tmp" || _bkp_fail dump "Zugänge ließen sich nicht lesen."

  # --- (3) verify_counts: count(*) je bulk- + filtered-Tabelle (Korruptions-Pruefung) ---
  local vsel=() n
  while IFS= read -r t; do
    [ -n "$t" ] || continue; _bkp_qual_ok "$t" || continue
    vsel+=("$(printf "'%s', (SELECT count(*) FROM %s)" "$t" "$t")")
  done <<< "$bulk"
  while IFS=$'\t' read -r qual cond; do
    [ -n "$qual" ] || continue; _bkp_qual_ok "$qual" || continue
    vsel+=("$(printf "'%s', (SELECT count(*) FROM %s WHERE %s)" "$qual" "$qual" "$cond")")
  done < <(_bkp_filtered)
  local verify_json; verify_json="$(_bkp_psql_scalar "SELECT $(_bkp_jsonb_obj "${vsel[@]}")")" || _bkp_fail dump "verify_counts-Berechnung fehlgeschlagen."

  # --- (4) manifest.json (Header) ---
  local core_ver pkgs_json
  core_ver="$(_bkp_psql_scalar "SELECT value FROM core.config WHERE category='api' AND key='core_version'")"
  pkgs_json="$(_bkp_psql_scalar "SELECT COALESCE(jsonb_agg(jsonb_build_object('name',package,'version',version) ORDER BY package), '[]'::jsonb) FROM core.package_registry WHERE status='active'")"
  # Defaults als eigene Guards (nicht inline ${x:-{}} — bash matcht dort die erste '}' als Expansions-Ende
  # und haengt bei nicht-leerem Wert ein Streu-'}' an -> ungueltiges JSON fuer jq --argjson).
  # release + migrations (angewandte V__ je Paket): Felder nur dazu, bundle_format bleibt 2 (Leser pruefen nur das Format).
  #   release waehlt beim Restore den Satz; migrations hat noch keinen Leser: Voraussetzung fuer das Vorwaerts-Wiederherstellen
  #   (Kopf *Versions-Sperre*), sonst wuesste eine Sicherung nicht, welche Migrationen sie schon hatte.
  local mig_json
  mig_json="$(_bkp_psql_scalar "SELECT COALESCE(jsonb_object_agg(package, vs), '{}'::jsonb) FROM (SELECT package, jsonb_agg(version ORDER BY version) AS vs FROM core.schema_version WHERE kind = 'versioned' GROUP BY package) x")"
  [ -n "$pkgs_json" ]   || pkgs_json='[]'
  [ -n "$verify_json" ] || verify_json='{}'
  [ -n "$mig_json" ]    || mig_json='{}'
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cv "$core_ver" --arg rel "$(_bkp_release_tag)" \
        --argjson pkgs "$pkgs_json" --argjson vc "$verify_json" --argjson mig "$mig_json" --argjson parts "$(_bkp_parts_json "$tmp")" \
        '{bundle_format:2, created_at:$ts, core_version:$cv, release:$rel, packages:$pkgs, migrations:$mig, verify_counts:$vc, parts:$parts}' \
        > "$tmp/manifest.json" || _bkp_fail dump "manifest.json-Bau fehlgeschlagen."

  # --- (5) Tarball -> gpg (Passphrase via fd, nie argv) ---
  local tarf="$tmp/bundle.tar.gz"
  local tfiles=(manifest.json data.dump shared.json memory.counts config.json)
  [ ! -f "$tmp/memory.dump" ] || tfiles+=(memory.dump)
  [ ! -f "$tmp/access.json" ] || tfiles+=(access.json)
  tar -czf "$tarf" -C "$tmp" "${tfiles[@]}" || _bkp_fail dump "tar fehlgeschlagen."
  # umask in der Teilschale: gpg legt die Datei dann nie weltlesbar an; chmod danach deckt eine vorhandene Zieldatei ab.
  if ! ( umask 077; gpg_sym_encrypt "$key" "$out" "$tarf" ); then
    _bkp_fail encrypt "gpg-Verschluesselung fehlgeschlagen."
  fi
  chmod 0600 "$out"
  if [ "$want_host" -eq 1 ]; then
    rt_host_put "$(_bkp_hd "$host")" "$name" "$out" || _bkp_fail write "Sicherung ließ sich nicht in den Ordner '${host}' auf dem Rechner schreiben."
    _bkp_host_rotate "$host" "$kid"
    ok "Backup geschrieben: $(_bkp_join "$host" "$name") (Ordner auf dem Rechner)"
  else
    ok "Backup geschrieben: $out"
  fi
  _bkp_state_set LAST_OK "$(date +%s)"
  _bkp_state_set LAST_SIZE "$(stat -c '%s' "$out" 2>/dev/null || echo 0)"   # doctor: Warnung vor der 50-MB-Grenze der Telegram-Kopie
  log "Inhalt:$(printf '%s' "$bulk" | grep -c .) bulk-Tabelle(n) + $(_bkp_filtered | grep -c .) gefilterte; aktive Pakete: ${pkgs_json}"
  # Kopie im Telegram-Chat (best-effort, kippt den fertigen Export nie); im Verbund auch neben dem Rechner-Ordner.
  if [ "$notify" -eq 1 ]; then
    _bkp_notify_telegram "$out" || true
  elif [ "$want_host" -eq 0 ]; then
    log "Hinweis: Die Sicherung liegt auf der VM — per scp/Backup wegkopieren (der Schluessel liegt separat im Notfallblatt). Tipp: 'lifeagents backup export --notify-telegram' schickt eine verschluesselte Kopie an deinen Telegram-Chat."
  fi
}

# ============================================================
# restore — Schluessel vom Notfallblatt
# ============================================================
# _bkp_adopt_sql -> SQL fuer den Anfang der Restore-TX (braucht :'bk_new', je weiterem Blatt-Schluessel :'bk_o<j>'): der
#   bisher aktive Schluessel wird prev-Zeile, der zur Sicherung passende der aktive; weitere Schluessel vom selben Blatt
#   (die Datei traegt aktuellen + aeltere) kommen als prev dazu, damit ein spaeter gedrucktes Blatt alle kennt. Namen mit
#   Mikrosekunden + Laufnummer -> keine PK-Kollision. Schlaegt die TX spaeter fehl, rollt alles mit zurueck.
_bkp_adopt_sql() {
  local j="${1:-0}" i
  cat <<SQL
INSERT INTO core.backup_key(key, value)
  SELECT '${BACKUP_KEY_PREV_PREFIX}' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDD"T"HH24MISSUS'), value
  FROM core.backup_key WHERE key = '${BACKUP_KEY_NAME}' AND value <> :'bk_new'
    AND NOT EXISTS (SELECT 1 FROM core.backup_key WHERE value = :'bk_new' AND key <> '${BACKUP_KEY_NAME}');
INSERT INTO core.backup_key(key, value) VALUES ('${BACKUP_KEY_NAME}', :'bk_new')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
SQL
  for ((i = 0; i < j; i++)); do
    cat <<SQL
INSERT INTO core.backup_key(key, value)
  SELECT '${BACKUP_KEY_PREV_PREFIX}' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDD"T"HH24MISSUS') || '_${i}', :'bk_o${i}'
  WHERE NOT EXISTS (SELECT 1 FROM core.backup_key WHERE value = :'bk_o${i}');
SQL
  done
}

# _bkp_try_parsed <parse-ausgabe> <chiffrat> <klartext-ziel> <datei-id> — waehlt aus den eingegebenen Schluesseln den zur
#   Sicherung passenden (per ID im Dateinamen, ohne ID der Reihe nach) und entschluesselt. Erfolg: rc 0, _BKP_BROUGHT und
#   _BKP_OTHERS (die uebrigen Blatt-Schluessel, je Zeile). Sonst _BKP_TRY_MSG (Alltagssatz), _BKP_TRY_CODE (fester Code fuer
#   die Start-App, _bkp_rdie), _BKP_TRY_LINE, _BKP_TRY_ERR (Form-Code aus der Eingabe) und _BKP_TRY_FINAL=1, wenn ein neuer
#   Versuch nichts bringt (passende ID, Datei beschaedigt). Direkt rufen, nie in $(…) (die Variablen gingen verloren).
_BKP_BROUGHT=''; _BKP_OTHERS=''; _BKP_TRY_MSG=''; _BKP_TRY_ERR=''; _BKP_TRY_FINAL=0; _BKP_TRY_CODE=''; _BKP_TRY_LINE=0
_bkp_try_parsed() {
  local parsed="$1" enc="$2" out="$3" fkid="$4" l k kid ids='' tried=0 all=''
  _BKP_TRY_MSG=''; _BKP_TRY_ERR=''; _BKP_TRY_FINAL=0; _BKP_BROUGHT=''; _BKP_OTHERS=''; _BKP_TRY_CODE=''; _BKP_TRY_LINE=0
  while IFS= read -r l; do
    case "$l" in
      err:*) [ -n "$_BKP_TRY_ERR" ] || _BKP_TRY_ERR="${l#err:}" ;;
      key:*) all="${all}${l#key:}"$'\n' ;;
    esac
  done <<<"$parsed"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    kid="$(printf '%s' "$k" | backup_key_id)"
    if [ -n "$fkid" ] && [ "$kid" != "$fkid" ]; then ids="${ids:+$ids, }$kid"; continue; fi
    tried=1
    if gpg_sym_decrypt "$k" "$enc" > "$out" < /dev/null; then
      _BKP_BROUGHT="$k"
      while IFS= read -r l; do [ -n "$l" ] && [ "$l" != "$k" ] && _BKP_OTHERS="${_BKP_OTHERS}${l}"$'\n'; done <<<"$all"
      return 0
    fi
    : > "$out"
    if [ -n "$fkid" ]; then _BKP_TRY_FINAL=1; _BKP_TRY_CODE=corrupt; _BKP_TRY_MSG="$(backup_text msg.corrupt id "$fkid")"; return 1; fi
  done <<<"$all"
  case "$_BKP_TRY_ERR" in
    line[1-4]) _BKP_TRY_CODE=key_line; _BKP_TRY_LINE="${_BKP_TRY_ERR#line}"; _BKP_TRY_MSG="$(backup_text msg.line n "$_BKP_TRY_LINE")" ;;
    length)    _BKP_TRY_CODE=key_format; _BKP_TRY_MSG="$(backup_text msg.length)" ;;
    chars)     _BKP_TRY_CODE=key_format; _BKP_TRY_MSG="$(backup_text msg.chars)" ;;
  esac
  if [ -n "$ids" ] && [ -z "$_BKP_TRY_MSG" ]; then _BKP_TRY_CODE=key_foreign; _BKP_TRY_MSG="$(backup_text msg.other_key ids "$ids" id "$fkid")"
  elif [ "$tried" = 1 ] && [ -z "$_BKP_TRY_MSG" ]; then _BKP_TRY_CODE=key_no_open; _BKP_TRY_MSG="$(backup_text msg.no_open)"; fi
  if [ -z "$_BKP_TRY_MSG" ]; then _BKP_TRY_CODE=key_needed; _BKP_TRY_MSG="$(backup_text msg.none)"; fi
  return 1
}

# _bkp_ask_key_tty -> Eingabe vom Notfallblatt am Terminal (verdeckt) im Format von backup_key_parse. Zeile fuer Zeile mit
#   sofortiger Pruefung und eigener Meldung je Ursache (Pruefzeichen vs. Form), bis zu 3 Versuche je Zeile, danach
#   "err:line<n>"; wer in Zeile 1 den ganzen Schluessel eingibt, ist sofort fertig.
_bkp_ask_key_tty() {
  local n line d acc='' rc tries msg
  for n in 1 2 3 4; do
    tries=0
    while :; do
      tries=$((tries + 1))
      if [ "$n" = 1 ]; then line="$(ui_input "$(backup_text ask.line1)" 1)"
      else line="$(ui_input "$(backup_text ask.line n "$n")" 1)"; fi
      if [ "$n" = 1 ] && [ "$(printf '%s' "$line" | backup_key_normalize | wc -c)" -ge 64 ]; then
        printf '%s' "$line" | backup_key_parse; return 0
      fi
      rc=0; d="$(printf '%s' "$line" | backup_key_line "$n")" || rc=$?
      [ "$rc" -eq 0 ] && break
      if [ "$tries" -ge 3 ]; then printf 'err:line%s\n' "$n"; return 0; fi
      if [ "$rc" -eq 1 ]; then msg="$(backup_text ask.retry_check n "$n")"; else msg="$(backup_text ask.retry_form n "$n")"; fi
      { printf '  %s\n' "$msg" > /dev/tty; } 2>/dev/null || true
    done
    acc="${acc}${d}"
  done
  printf 'key:%s\n' "$acc"
}

# _bkp_brought_key <chiffrat> <klartext-ziel> <datei-id> <von-stdin:0|1> — kein gespeicherter Schluessel oeffnet die
#   Sicherung: Schluessel vom Notfallblatt holen (stdin, Blatt-Block aus --in-stdin bzw. Terminal) -> _BKP_BROUGHT/_BKP_OTHERS.
#   Am Terminal bis zu drei ganze Schluessel (falsches Blatt); ein Zeilenfehler nach drei Versuchen oder eine beschaedigte
#   Datei bricht sofort ab. Jeder Abbruch: nichts geaendert, Code ueber _bkp_rdie.
_bkp_brought_key() {
  local enc="$1" out="$2" fkid="$3" from_stdin="$4" parsed n un cmd
  un="$(backup_text msg.unchanged)"
  if [ "$from_stdin" = 1 ]; then
    if [ "$_BKP_SHEET_SET" = 1 ]; then
      [ -n "${_BKP_SHEET//[[:space:]]/}" ] || _bkp_rdie key_needed "$(backup_text msg.none) ${un}" --arg id "$fkid"
      parsed="$(printf '%s' "$_BKP_SHEET" | backup_key_parse)"
    else
      parsed="$(backup_key_parse)"
    fi
    _bkp_try_parsed "$parsed" "$enc" "$out" "$fkid" && return 0
    _bkp_rdie "$_BKP_TRY_CODE" "${_BKP_TRY_MSG} ${un}" --arg id "$fkid" --argjson line "${_BKP_TRY_LINE:-0}"
  fi
  if [ "$_BKP_JSON" = 1 ] || ! ui_interactive; then
    if rt_is_compose; then cmd="$(rt_master_cli_hint) backup restore <datei> --key-stdin < Notfallblatt.txt"
    else cmd="lifeagents backup restore <datei> --key-stdin < notfallblatt.txt"; fi
    _bkp_rdie key_needed "$(backup_text msg.no_tty cmd "$cmd") ${un}" --arg id "$fkid"
  fi
  if [ -n "$fkid" ]; then parsed="$(backup_text ask.intro_id id "$fkid")"; else parsed="$(backup_text ask.intro)"; fi
  { printf '\n  %s\n\n' "$parsed" > /dev/tty; } 2>/dev/null || true
  for n in 1 2 3; do
    parsed="$(_bkp_ask_key_tty)"
    if _bkp_try_parsed "$parsed" "$enc" "$out" "$fkid"; then return 0; fi
    if [ "$_BKP_TRY_FINAL" = 1 ] || [ -n "$_BKP_TRY_ERR" ]; then die "${_BKP_TRY_MSG} ${un}"; fi
    { printf '  %s\n' "$_BKP_TRY_MSG" > /dev/tty; } 2>/dev/null || true
  done
  die "$(backup_text msg.wrong_3) ${un}"
}

# _bkp_classify (stdin: Dateinamen im Rechner-Ordner) -> je Sicherung "name<TAB>id<TAB>own|other|legacy<TAB>zeit<TAB>version"
#   (zeit = 14 Ziffern UTC aus dem Namen). Die eine Stelle fuer eigen/fremd: Terminal-Auswahl, Fragebogen-Hinweis, App-Liste.
#   Namen ohne ID (legacy) gehoeren zu keinem bekannten Schluessel und zaehlen ueberall wie fremde.
_bkp_classify() {
  local ids b kid ts ver cls
  ids=$'\n'"$(_bkp_key_ids)"$'\n'
  while IFS= read -r b; do
    case "$b" in *.nla.enc) ;; *) continue ;; esac
    kid="$(_bkp_file_key_id "$b")"; ts=''; ver=''
    [[ "$b" =~ lifeagents-backup-([0-9]{14}) ]] && ts="${BASH_REMATCH[1]}"
    [[ "$b" =~ -(v[0-9][0-9A-Za-z.-]*|vdev)[^/]*\.nla\.enc$ ]] && ver="${BASH_REMATCH[1]}"
    if [ -z "$kid" ]; then cls=legacy; elif [[ "$ids" == *$'\n'"$kid"$'\n'* ]]; then cls=own; else cls=other; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$kid" "$cls" "$ts" "$ver"
  done
}
# _bkp_sorted (stdin: _bkp_classify) -> dieselben Zeilen, fremde und alte zuerst, darin neueste zuerst: auf einem neuen Rechner
#   im geteilten Ordner ist die eigene, neueste Sicherung die fast leere der Neuinstallation, gesucht ist die des alten Rechners.
_bkp_sorted() {
  awk -F '\t' 'BEGIN { OFS = "\t" } { print ($3 == "own" ? 1 : 0), $0 }' | sort -t "$(printf '\t')" -k1,1n -k5,5r -k2,2r | cut -f2-
}
# _bkp_pick_lines (stdin: Dateinamen im Rechner-Ordner) -> Auswahl-Zeilen "Datum · Version · was sie braucht<TAB>name".
_bkp_pick_lines() {
  local b kid cls ts ver when lbl
  _bkp_classify | _bkp_sorted | while IFS=$'\t' read -r b kid cls ts ver; do
    when="$b"
    [ "${#ts}" = 14 ] && when="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2} UTC"
    case "$cls" in
      own)    lbl="${when} · ${ver:-?} · $(backup_text pick.own)" ;;
      other)  lbl="${when} · ${ver:-?} · $(backup_text pick.other id "$kid")" ;;
      *)      lbl="${when} · $(backup_text pick.legacy)" ;;
    esac
    printf '%s\t%s\n' "$lbl" "$b"
  done
}

# --- Aufbau der Sicherung gegen diese Version (Versions-Sperre) ---------------------------------------------------------
# Verglichen wird der Aufbau, nicht eine Nummer: Paket-Versionen aendert kein Release, eine Sperre an der Release machte jede
# Sicherung nach dem naechsten Update wertlos. Muster wie Discourse/Nextcloud (Schema-Stand). Was der Abgleich nicht sieht:
# Migrationen, die bestehende Zeilen umformen, und Gesetze nur als Trigger/Fremdschluessel (pg_restore --disable-triggers);
# beides braucht ein Vorwaerts-Wiederherstellen ueber das Schema der Sicherungs-Version.

# _bkp_rel_older <a> <b> -> 0, wenn beide reine oder Vorab-Tags sind und a aelter als b (release_cmp, common.sh); dev und
#   unbekannte Staende sind nie aelter.
_bkp_rel_older() { [ "$(release_cmp "$1" "$2" 2>/dev/null)" = -1 ]; }
# _bkp_bundle_release <tmp> <dateiname> -> Release der Sicherung: Kopf-Feld release, sonst aus dem Dateinamen (Sicherungen
#   ohne Kopf-Feld), sonst leer. Nur Release- oder Vorab-Tags; verglichen wird ueber _bkp_rel_older (release_cmp).
_bkp_bundle_release() {
  local r; r="$(jq -r '.release // empty' "$1/manifest.json" 2>/dev/null)"
  if ! is_release_tag "$r" && ! is_prerelease_tag "$r"; then
    r=''; [[ "$2" =~ -(v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)\.nla\.enc$ ]] && r="${BASH_REMATCH[1]}"
    is_release_tag "$r" || is_prerelease_tag "$r" || r=''
  fi
  printf '%s' "$r"
}
# _bkp_deferred_tables <pakete…> -> Schema-Praefixe ("schema.") und Tabellen der Pakete, die der Lauf erst einrichtet:
#   ihre Tabellen gibt es hier noch nicht, _bkp_rs_apply prueft sie nach dem Einrichten.
_bkp_deferred_tables() {
  local pkg mf schema
  for pkg in "$@"; do
    mf="$(_pkg_dir)/$pkg/manifest.json"; [ -r "$mf" ] || continue
    schema="$(jq -r '.schema // empty' "$mf" 2>/dev/null)"
    [ -z "$schema" ] || printf '%s.\n' "$schema"
    jq -r '.backup.full_tables[]?, ((.backup.filtered_tables // {}) | keys[])' "$mf" 2>/dev/null
  done
}

# _bkp_schema_check <tmp> <aufgeschoben> [weitere-pakete] — Aufbau der Sicherung gegen die Ziel-Menge (aktive Pakete plus
#   weitere-pakete: bulk + gefiltert). rc 0 = vertraeglich; sonst _BKP_SC_CODE (version_newer|version_older) und _BKP_SC_DIFF
#   (Tabellen/Spalten, fuers Protokoll). <aufgeschoben> = Zeilen aus _bkp_deferred_tables ("schema." oder volle Tabelle),
#   die nicht geprueft werden. Bricht selbst ueber _bkp_rdie ab (corrupt/format/internal), wenn sich ein Aufbau nicht lesen
#   laesst — fail-closed, kein stiller Durchlass. Quellen der Sicherung: COPY-Kopfzeilen des Abzugs (pg_restore -f - nennt
#   Tabelle + Spaltenliste, auch in alten Sicherungen), Schluessel von shared.json und verify_counts, die Zeilen-Schluessel der
#   gefilterten Tabellen. Schreibt $tmp/sc.bundle (haengt nur am Bundle: einmal je Lauf, die Nachpruefung nutzt es wieder)
#   und $tmp/sc.target.
_BKP_SC_CODE=''; _BKP_SC_DIFF=''
_bkp_schema_check() {
  local tmp="$1" deferred="$2" extra="${3:-}" copies rc t cols c
  _BKP_SC_CODE=''; _BKP_SC_DIFF=''
  local bside="$tmp/sc.bundle" line
  if [ ! -f "$bside" ]; then
  # COPY-Kopf nur ausserhalb eines Datenblocks (ein Datenwert kann mit "COPY " beginnen); Block-Ende ist "\.".
  copies="$(pg_su_stdin pg_restore -a -f - < "$tmp/data.dump" \
    | awk 'inb { if ($0 == "\\.") inb = 0; next } /^COPY .* FROM stdin;$/ { print; inb = 1 }'; exit "${PIPESTATUS[0]}")"; rc=$?
  [ "$rc" -eq 0 ] || _bkp_rdie corrupt "Die Sicherung lässt sich nicht lesen (pg_restore). Es wurde NICHTS geaendert."
  local want_bulk
  # jq wertet bei "a - b" b zuerst aus -> beide Eingaben vorher binden, sonst vertauscht `input` die Dateien.
  want_bulk="$(jq -n 'input as $m | input as $s | ((($m.verify_counts // {}) | keys) - ($s | keys)) | length' "$tmp/manifest.json" "$tmp/shared.json" 2>/dev/null)"
  if [ -z "$copies" ] && [ "${want_bulk:-0}" != 0 ]; then
    _bkp_rdie corrupt "Die Sicherung ist unvollständig (Abzug ohne Tabellen). Es wurde NICHTS geaendert."
  fi
  # Sicherungs-Seite: "tabelle<TAB>b:spalte" (COPY), "tabelle<TAB>f:schluessel" (gefiltert) bzw. "tabelle<TAB>" (nur Name).
  : > "$bside.part"
  while IFS= read -r line; do
    [[ "$line" =~ ^COPY\ ([^ ]+)\ \((.*)\)\ FROM\ stdin\;$ ]] \
      || _bkp_rdie corrupt "Die Sicherung ist beschädigt (Tabellenkopf unlesbar). Es wurde NICHTS geaendert."
    t="${BASH_REMATCH[1]//\"/}"; cols="${BASH_REMATCH[2]}"
    printf '%s\t\n' "$t" >> "$bside.part"
    while IFS= read -r c; do
      c="${c#\"}"; c="${c%\"}"; c="${c//\"\"/\"}"
      printf '%s\tb:%s\n' "$t" "$c" >> "$bside.part"
    done < <(printf '%s\n' "$cols" | sed 's/, /\n/g')   # mit Zeilenende, sonst verwirft read die letzte Spalte
  done <<<"$copies"
  # Unlesbar = beschaedigt: ein still abgebrochenes jq liesse Tabellen weg und den Abgleich durch.
  if ! { jq -r '(.verify_counts // {}) | keys[] | . + "\t"' "$tmp/manifest.json" >> "$bside.part" 2>/dev/null \
         && jq -r 'to_entries[] | .key as $t | ($t + "\t"), ((.value // []) | if type == "array" then (map(keys[]) | unique[] | $t + "\tf:" + .) else empty end)' \
              "$tmp/shared.json" >> "$bside.part" 2>/dev/null; }; then
    _bkp_rdie corrupt "Die Sicherung ist beschädigt (Inhaltsliste unlesbar). Es wurde NICHTS geaendert."
  fi
  mv "$bside.part" "$bside"
  fi
  # Ziel-Menge: aktive Pakete plus die erst einzuschaltenden (deren Tabellen gibt es schon).
  local target
  target=$'\n'"$(_bkp_bulk_tables "$extra")"$'\n'"$(_bkp_filtered "$extra" | cut -f1)"$'\n'
  # Gefiltert: Regel je Spalte folgt dem Schreibweg in core.fn_backup_restore_filtered. monitor_triggers schreibt alle Spalten
  #   per jsonb_populate_recordset (fehlender Schluessel = NULL, der Standard greift nicht) -> Pflicht oder Standard ist
  #   unvertraeglich. core_contexts schreibt description/agent_name/load_strategy/content ausdruecklich (ebenso streng), den
  #   Rest per COALESCE bzw. INSERT-Standard (nur Pflicht ohne Standard). Unbekannte kuenftige Tabellen: streng.
  local diff_new='' diff_old='' tt
  local tabs; tabs="$(cut -f1 "$bside" | sort -u)"
  local q_in=''
  while IFS= read -r tt; do
    [ -n "$tt" ] || continue
    _bkp_qual_ok "$tt" || _bkp_rdie format "Ungueltiger Tabellenname in der Sicherung: $tt"
    if printf '%s\n' "$deferred" | grep -qxF -e "$tt" -e "${tt%%.*}."; then continue; fi
    if [[ "$target" != *$'\n'"$tt"$'\n'* ]]; then diff_new+="Tabelle ${tt}; "; continue; fi
    q_in+="${q_in:+,}'${tt}'"
  done <<<"$tabs"
  if [ -n "$q_in" ]; then
    # Ziel-Seite: je Spalte notnull, Standard, generiert, Identity (ohne geloeschte und Systemspalten).
    local tside="$tmp/sc.target" kind tnn tdef tgen tid
    _bkp_psql_scalar "SELECT n.nspname || '.' || c.relname || E'\t' || a.attname || E'\t' || a.attnotnull::int || E'\t'
                             || (a.atthasdef AND a.attgenerated = '')::int || E'\t' || (a.attgenerated <> '')::int || E'\t'
                             || (a.attidentity <> '')::int
                        FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE a.attnum > 0 AND NOT a.attisdropped AND (n.nspname || '.' || c.relname) IN (${q_in})" > "$tside" \
      || _bkp_rdie internal "Der Aufbau dieser Version ließ sich nicht lesen. Es wurde NICHTS geaendert."
    local filt_mode
    while IFS= read -r tt; do
      [ -n "$tt" ] || continue
      case ",${q_in}," in *",'${tt}',"*) ;; *) continue ;; esac
      local bcols fcols has_b=0 has_f=0
      bcols="$(awk -F'\t' -v t="$tt" '$1 == t && $2 ~ /^b:/ { print substr($2, 3) }' "$bside" | sort -u)"
      fcols="$(awk -F'\t' -v t="$tt" '$1 == t && $2 ~ /^f:/ { print substr($2, 3) }' "$bside" | sort -u)"
      [ -n "$bcols" ] && has_b=1; [ -n "$fcols" ] && has_f=1
      [ "$has_b$has_f" != 00 ] || continue   # leeres gefiltertes Array: keine Spalten-Aussage
      filt_mode=alle; [ "$tt" = agent.core_contexts ] && filt_mode=liste
      # Sicherung bringt Spalten, die das Ziel nicht hat (to_jsonb nimmt generierte Spalten mit; die gibt es im Ziel ja).
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        awk -F'\t' -v t="$tt" -v c="$c" '$1 == t && $2 == c { f = 1 } END { exit !f }' "$tside" || diff_new+="Spalte ${tt}.${c}; "
      done <<<"$(printf '%s\n%s\n' "$bcols" "$fcols")"
      # Ziel hat Spalten, die die Sicherung nicht liefert.
      while IFS=$'\t' read -r kind c tnn tdef tgen tid; do
        [ "$kind" = "$tt" ] || continue
        # Im Ziel berechnet, im Abzug noch gespeichert (pg_dump laesst berechnete Spalten im COPY weg): COPY scheitert in der TX.
        if [ "$tgen" = 1 ]; then
          [ "$has_b" = 1 ] && printf '%s\n' "$bcols" | grep -qxF -- "$c" && diff_old+="Spalte ${tt}.${c} (jetzt berechnet); "
          continue
        fi
        if [ "$has_b" = 1 ]; then
          printf '%s\n' "$bcols" | grep -qxF -- "$c" && continue
          [ "$tnn" = 1 ] && [ "$tdef" = 0 ] && [ "$tid" = 0 ] && diff_old+="Spalte ${tt}.${c} (Pflicht); "
        else
          printf '%s\n' "$fcols" | grep -qxF -- "$c" && continue
          if [ "$filt_mode" = alle ] || [[ " description agent_name load_strategy content " == *" $c "* ]]; then
            { [ "$tnn" = 1 ] || [ "$tdef" = 1 ]; } && diff_old+="Spalte ${tt}.${c} (Pflicht oder Standard); "
          else
            [ "$tnn" = 1 ] && [ "$tdef" = 0 ] && diff_old+="Spalte ${tt}.${c} (Pflicht); "
          fi
        fi
      done < "$tside"
    done <<<"$tabs"
  fi
  if [ -n "$diff_new" ]; then _BKP_SC_CODE=version_newer; _BKP_SC_DIFF="neu in der Sicherung: ${diff_new% }"; fi
  if [ -n "$diff_old" ]; then
    _BKP_SC_DIFF="${_BKP_SC_DIFF:+$_BKP_SC_DIFF / }fehlt in der Sicherung: ${diff_old% }"
    _BKP_SC_CODE=version_older
  fi
  [ -z "$_BKP_SC_CODE" ]
}

# --- Restore fuer die Start-App: feste Codes, Probelauf, Hintergrund-Lauf -------------------------------------------------
# Im JSON-Modus (--json) endet jeder Restore-Weg mit genau einem JSON-Objekt auf stdout ({ok:true,…} bzw. {ok:false, code,…});
# der Satz geht auf stderr. Codes (die App uebersetzt sie, report::ERROR_CODES): key_needed key_line key_format key_foreign
# key_no_open corrupt corrupt_stored bundle_incomplete format package_unknown version_older version_newer needs_setup no_tables
# unreadable safety folder nofolder busy internal. Eigene Funktion statt die_because: die schreibt die Ergebnis-Datei eines
# Updates, hier liest die App stdout bzw. backup.state.
_BKP_JSON=0; _BKP_CHILD=0; _BKP_SHEET=''; _BKP_SHEET_SET=0; _BKP_RELEASE=''
BACKUP_RESTORE_LOCK="${BACKUP_RESTORE_LOCK:-/run/lifeagents-restore.lock}"
# _bkp_rdie <code> <satz> [jq-argumente…] — Restore abbrechen: im Hintergrund-Lauf LAST_RESTORE_FAIL + Grund (+ Release der
#   Sicherung, die Texte der Versions-Codes nennen sie) in backup.state, im JSON-Modus das Fehler-Objekt (weitere Felder per
#   --arg/--argjson), sonst `die`. Immer exit 1.
_bkp_rdie() {
  local code="$1" msg="$2"; shift 2
  if [ "$_BKP_CHILD" = 1 ]; then
    _bkp_state_set LAST_RESTORE_FAIL "$(date +%s)"; _bkp_state_set LAST_RESTORE_REASON "$code"
    _bkp_state_set LAST_RESTORE_RELEASE "$_BKP_RELEASE"
  fi
  if [ "$_BKP_JSON" = 1 ]; then
    err "$msg"
    jq -cn --arg code "$code" "$@" '{ok: false} + $ARGS.named' 2>/dev/null || printf '{"ok":false,"code":"%s"}\n' "$code"
    exit 1
  fi
  die "$msg"
}
# _bkp_restore_running -> 0, wenn ein Hintergrund-Lauf die Restore-Sperre haelt.
_bkp_restore_running() {
  need_cmd flock || return 1
  [ -e "$BACKUP_RESTORE_LOCK" ] || return 1
  ! flock -n "$BACKUP_RESTORE_LOCK" true 2>/dev/null
}
# _bkp_system_tables -> qualifizierte Tabellen aus backup.system_tables aller aktiven Pakete (fuellt das System selbst: Code-Seed,
#   abgerufene Kurse, abgeleitete Salden, Onboarding-Zeilen der Einrichtung) — zaehlen nicht als „eigene Daten“.
_bkp_system_tables() {
  local active mf pkg schema t
  active="$(_bkp_active_names)"
  for mf in "$(_pkg_dir)"/*/manifest.json; do
    [ -r "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)" || continue
    _bkp_is_active "$pkg" "$active" || continue
    schema="$(jq -r '.schema // empty' "$mf" 2>/dev/null)"
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      case "$t" in *.*) printf '%s\n' "$t" ;; *) [ -n "$schema" ] && printf '%s.%s\n' "$schema" "$t" ;; esac
    done < <(jq -r '.backup.system_tables[]?' "$mf" 2>/dev/null)
  done
}
# _bkp_has_data <bulk> -> 0, wenn eine bulk-Tabelle ausser den System-Tabellen Zeilen hat (frisch eingerichtet = 1). Die
#   gefilterten Tabellen zaehlen nicht: die Einrichtung legt dort schon das Haushalts-Skelett an.
_bkp_has_data() {
  local sys t q=''
  sys=$'\n'"$(_bkp_system_tables)"$'\n'
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [[ "$sys" == *$'\n'"$t"$'\n'* ]] && continue
    _bkp_qual_ok "$t" || continue
    q="${q:+$q OR }EXISTS (SELECT 1 FROM ${t})"
  done <<<"$1"
  [ -n "$q" ] || return 1
  [ "$(_bkp_psql_scalar "SELECT (${q})::int")" = 1 ]
}
# _bkp_pkg_needs_setup <pkg> -> 0, wenn das Paket einen Pflicht-Zugang hat (credentials mit required:true): ohne Terminal
#   bricht die Einrichtung daran ab -> die App installiert es nicht selbst (Code needs_setup).
_bkp_pkg_needs_setup() {
  local mf; mf="$(_pkg_dir)/$1/manifest.json"
  [ -r "$mf" ] || return 1
  jq -e '(.credentials // {}) | [to_entries[] | select(.key != "_comment" and .value.required == true)] | length > 0' "$mf" >/dev/null 2>&1
}
# _bkp_pkg_has_access <pkg> -> 0, wenn das Paket ueberhaupt Zugaenge kennt (ohne Terminal eingerichtet fehlen sie danach).
_bkp_pkg_has_access() {
  local mf; mf="$(_pkg_dir)/$1/manifest.json"
  [ -r "$mf" ] || return 1
  jq -e '(.credentials // {}) | [to_entries[] | select(.key != "_comment")] | length > 0' "$mf" >/dev/null 2>&1
}
# _bkp_version_die [schluss-satz] — Abbruch nach einem Unterschied aus _bkp_schema_check (liest _BKP_SC_CODE/_BKP_SC_DIFF,
#   endet immer ueber _bkp_rdie mit exit 1). Sind beide Releases rein und verschieden, bestimmt die Release der Sicherung
#   (_BKP_RELEASE) gegen die laufende (_bkp_release_tag) Satz und Code: neuer -> erst updaten, aelter -> die Version der
#   Sicherung (ein Update hilft dann nicht; eine entfernte Spalte sieht der Abgleich als „neu in der Sicherung“). Sonst
#   (unbekannt, dev, gleiche Release) bleibt der Code aus dem Abgleich und der Satz nennt beide Wege. schluss-satz ersetzt
#   „nichts geaendert“, wenn vorher schon ein Paket eingerichtet wurde.
_bkp_version_die() {
  local rel="$_BKP_RELEASE" cur code="$_BKP_SC_CODE" tail="${1:-Es wurde NICHTS geaendert.}"
  cur="$(_bkp_release_tag)"
  log "Unterschied zum Aufbau dieser Version: ${_BKP_SC_DIFF}"
  local old_way="Life Agents ${rel:-in der Version der Sicherung} installieren, dort wiederherstellen, dann aktualisieren (Anleitung: ${BACKUP_GUIDE_URL})."
  if _bkp_rel_older "$rel" "$cur"; then
    _bkp_rdie version_older "Versions-Konflikt: die Sicherung ist älter (${rel}) und passt nicht mehr zum Aufbau dieser Version. Ein Update hilft hier nicht: ${old_way} ${tail}" --arg release "$rel"
  fi
  if _bkp_rel_older "$cur" "$rel"; then
    _bkp_rdie version_newer "Versions-Konflikt: die Sicherung ist neuer (${rel}) — erst 'lifeagents update', dann erneut wiederherstellen. ${tail}" --arg release "$rel"
  fi
  _bkp_rdie "$code" "Versions-Konflikt: die Sicherung passt nicht zum Aufbau dieser Version${rel:+ (Sicherung ${rel})}. Ist sie neuer: erst 'lifeagents update', dann erneut wiederherstellen. Ist sie älter: ${old_way} ${tail}" --arg release "$rel"
}
# _bkp_read_in_stdin <ziel> — --in-stdin (Start-App, 'Andere Datei waehlen'): erste Zeile "sheet <base64>" (Blatt-Text, leer =
#   kein Blatt), danach die Sicherung base64-codiert bis zum Ende. base64, weil `read` Zeichen der Locale zaehlt (Blatt UTF-8,
#   ko) und die App nur Text ueber stdin reicht; eine Zeile liest bash exakt, ohne vom Folgenden etwas zu verschlucken. Das
#   Blatt bleibt nur in der Shell-Variable _BKP_SHEET, nie in einer Datei.
_bkp_read_in_stdin() {
  local hdr
  IFS= read -r hdr || _bkp_rdie unreadable "Keine Eingabe auf stdin."
  [[ "$hdr" =~ ^sheet\ ?([A-Za-z0-9+/=]*)$ ]] || _bkp_rdie unreadable "Eingabe auf stdin hat nicht die erwartete Form."
  _BKP_SHEET=''
  if [ -n "${BASH_REMATCH[1]}" ]; then
    _BKP_SHEET="$(printf '%s' "${BASH_REMATCH[1]}" | base64 -d 2>/dev/null)" || _bkp_rdie key_format "$(backup_text msg.length)"
  fi
  _BKP_SHEET_SET=1
  base64 -d > "$1" 2>/dev/null && [ -s "$1" ] || _bkp_rdie unreadable "Die gewählte Sicherung ließ sich nicht lesen."
}

# backup_cmd_list --json — Sicherungen im gemerkten Rechner-Ordner fuer die Start-App, Reihenfolge wie die Terminal-Auswahl:
#   {ok:true, folder, backups:[{name, date (ISO UTC), release, key_id, own}]}; ohne Ordner {ok:false, code:"nofolder"}.
backup_cmd_list() {
  [ "${1:-}" = --json ] || die "Usage: lifeagents backup list --json"
  _BKP_JSON=1
  _bkp_resolve_db
  local hd names; hd="$(_bkp_host_dir)"
  [ -n "$hd" ] || _bkp_rdie nofolder "Noch kein Sicherungs-Ordner gewählt."
  # Nur lesen, ein Kurzlauf-Container (die App fragt bei jedem Öffnen der Startseite): keine Schreibprobe wie beim Sichern.
  if ! _bkp_host_dir_valid "$hd" || ! names="$(rt_host_ls "$(_bkp_hd "$hd")")"; then
    _bkp_rdie folder "Der Sicherungs-Ordner ist nicht erreichbar."
  fi
  printf '%s\n' "$names" | _bkp_classify | _bkp_sorted | jq -Rsc --arg folder "$hd" '
    [split("\n")[] | select(length > 0) | split("\t")
     | { name: .[0], key_id: (if .[1] == "" then null else .[1] end), own: (.[2] == "own"),
         date: (.[3] as $t | if ($t | length) == 14 then "\($t[0:4])-\($t[4:6])-\($t[6:8])T\($t[8:10]):\($t[10:12]):\($t[12:14])Z" else null end),
         release: (if .[4] == "" then null else .[4] end) }]
    | { ok: true, folder: $folder, backups: . }'
}

# backup_cmd_restore_status --json — Stand des letzten Hintergrund-Laufs: {ok:true, state: idle|running|ok|fail|unfinished,
#   code, converged, parts_failed, release, name, created, foreign, started}; parts_failed = Teile nach den Daten, die nicht
#   uebernommen wurden (memory|config|access; nachholen: backup restore <datei> --parts); release nur bei fail (Release der Sicherung, fuer die
#   Versions-Codes); converged nur bei ok (false = Daten eingespielt, Abgleich mit dieser Version brach ab, _bkp_converge);
#   unfinished = gestartet, ohne Ergebnis und die Restore-Sperre ist frei (Rechner aus, Container neu, Lauf abgebrochen) — die
#   TX hat dann nichts geaendert.
backup_cmd_restore_status() {
  [ "${1:-}" = --json ] || die "Usage: lifeagents backup restore-status --json"
  local st okt flt rs nm cr fg rl cv pf state=idle v
  for v in st:LAST_RESTORE_START okt:LAST_RESTORE_OK flt:LAST_RESTORE_FAIL rs:LAST_RESTORE_REASON nm:LAST_RESTORE_NAME \
           cr:LAST_RESTORE_CREATED fg:LAST_RESTORE_FOREIGN rl:LAST_RESTORE_RELEASE cv:LAST_RESTORE_CONVERGE \
           pf:LAST_RESTORE_PARTS; do
    printf -v "${v%%:*}" '%s' "$(read_env_value "$BACKUP_STATE_FILE" "${v#*:}" 2>/dev/null || true)"
  done
  case "$st" in ''|*[!0-9]*) st=0 ;; esac; case "$okt" in ''|*[!0-9]*) okt=0 ;; esac; case "$flt" in ''|*[!0-9]*) flt=0 ;; esac
  # Laeuft gerade einer, zaehlt das zuerst (ein Ergebnis aus derselben Sekunde gehoerte zum vorigen Lauf); der Start leert
  # ausserdem die Ergebnis-Felder.
  if [ "$st" -gt 0 ]; then
    if _bkp_restore_running; then state=running
    elif [ "$okt" -ge "$st" ]; then state=ok
    elif [ "$flt" -ge "$st" ]; then state=fail
    else
      state=unfinished
      # Hart abgebrochen (kill, Absturz): der EXIT-Trap des Laufs lief nicht, das entschluesselte Bundle laege noch im
      # tmpfs. Nur genau den gemerkten eigenen Ordner entfernen.
      local stale; stale="$(read_env_value "$BACKUP_STATE_FILE" LAST_RESTORE_TMP 2>/dev/null || true)"
      if [[ "$stale" =~ ^(/dev/shm|/tmp)/lifeagents-bkp\.[A-Za-z0-9]{6}$ ]] && [ -d "$stale" ]; then rm -rf -- "$stale"; fi
    fi
  fi
  jq -cn --arg state "$state" --arg code "$rs" --arg name "$nm" --arg created "$cr" --arg foreign "$fg" --argjson started "$st" \
    --arg release "$rl" --arg cv "$cv" --arg pf "$pf" \
    '{ok: true, state: $state, code: (if $state == "fail" then $code else null end),
      converged: (if $state == "ok" then $cv != "fail" else null end),
      parts_failed: (if $state == "ok" and $pf != "" then ($pf | split(" ")) else [] end),
      release: (if $state == "fail" and $release != "" then $release else null end), name: (if $name == "" then null else $name end),
      created: (if $created == "" then null else $created end), foreign: ($foreign == "1"), started: $started}'
}

# ============================================================
# restore
# ============================================================
# backup_cmd_restore [<datei>|<name>] [--from-host] [--key-stdin] [--in-stdin] [--yes] [--plan] [--detach] [--json]
#   Terminal: Auswahl, Wipe-Uebersicht, „ja“, dann eine TX und der Abgleich mit dieser Version. Start-App:
#   --plan --json  Probelauf: oeffnen, pruefen, nichts schreiben (auch kein Paket, kein backup.state) -> ein JSON-Objekt.
#   --detach --json  (mit --yes) pruefen wie der Probelauf, dann im Hintergrund: Pakete einrichten, Vorab-Sicherung, TX, Abgleich;
#                  Ergebnis in backup.state (backup restore-status). Der Aufrufer bekommt sofort {ok:true, started}.
#   --in-stdin     die Sicherung kommt ueber stdin (Rahmen _bkp_read_in_stdin, mit Blatt-Block) statt aus einem Ordner.
backup_cmd_restore() {
  require_cmd jq; _bkp_require_pg pg_restore; require_cmd gpg
  _bkp_resolve_db
  # --from-host (Docker-Verbund): <datei> liegt in einem Ordner auf dem Rechner — als voller Pfad oder als Name im gemerkten
  # Ordner (BACKUP_HOST_DIR). Im Verbund ist das ohne Pfad der Normalfall (die Auswahl listet den gemerkten Ordner).
  # --key-stdin: Schluessel vom Notfallblatt aus stdin (Text oder die ganze Notfallblatt-Datei), nur gelesen, wenn kein
  # gespeicherter Schluessel die Datei oeffnet. Nie als Argument (Prozessliste).
  local enc="" force=0 a from_host=0 key_stdin=0 in_stdin=0 plan=0 detach=0 parts_only=0
  for a in "$@"; do
    case "$a" in
      --yes|-y) force=1 ;;
      --from-host) from_host=1 ;;
      --key-stdin) key_stdin=1 ;;
      --in-stdin) in_stdin=1; key_stdin=1 ;;
      --plan) plan=1 ;;
      --detach) detach=1 ;;
      --parts) parts_only=1 ;;
      --json) _BKP_JSON=1 ;;
      --*)      die "Unbekannte Option: $a" ;;
      *)        enc="$a" ;;
    esac
  done
  if [ "$detach" = 1 ] && { [ "$force" != 1 ] || [ "$_BKP_JSON" != 1 ] || [ "$plan" = 1 ]; }; then
    die "--detach braucht --yes und --json (Start-App) und schliesst --plan aus."
  fi
  # Picker bei fehlendem Argument: *.nla.enc aus cwd + /root — realpath-dedupe (als root ist cwd oft
  # /root selbst, sonst Dubletten), dann absteigend nach Basename sortiert (der traegt den
  # Timestamp -> neueste zuerst; eine Voll-Pfad-Sortierung liesse das Verzeichnis-Praefix
  # dominieren). Danach laufen Wipe-Uebersicht + 'ja'-Confirm unveraendert.
  # Kein Treffer/Abbruch -> unveraenderte Usage.
  if [ "$in_stdin" = 0 ] && rt_is_compose && { [ -z "$enc" ] || [ ! -r "$enc" ]; }; then from_host=1; fi
  if [ -z "$enc" ] && [ "$in_stdin" = 0 ] && [ "$_BKP_JSON" = 0 ] && [ "$from_host" -eq 1 ] && ui_interactive; then
    ensure_gum
    local _hd _hpick
    _hd="$(_bkp_host_dir)"
    [ -n "$_hd" ] || die "Kein Sicherungs-Ordner auf dem Rechner gewählt — Datei mit vollem Pfad angeben: lifeagents backup restore --from-host <ordner>/<datei>"
    _hpick="$(rt_host_ls "$(_bkp_hd "$_hd")" | _bkp_pick_lines | ui_choose 'Backup wiederherstellen (Wipe-Uebersicht + Bestaetigung folgen):' 0 || true)"
    [ -n "$_hpick" ] && enc="$_hpick"
  elif [ -z "$enc" ] && [ "$in_stdin" = 0 ] && [ "$_BKP_JSON" = 0 ] && ui_interactive; then
    ensure_gum
    local _pick
    _pick="$( { ls -1 -- *.nla.enc /root/*.nla.enc 2>/dev/null || true; } \
      | while IFS= read -r f; do realpath -- "$f" 2>/dev/null; done | sort -u \
      | while IFS= read -r f; do printf '%s\t%s\n' "$(basename -- "$f")" "$f"; done \
      | sort -t "$(printf '\t')" -k1,1 -r \
      | while IFS=$'\t' read -r b f; do printf '%s   (%s)\t%s\n' "$b" "$f" "$f"; done \
      | ui_choose 'Backup wiederherstellen (Wipe-Uebersicht + Bestaetigung folgen):' 0 || true)"
    [ -n "$_pick" ] && enc="$_pick"
  fi
  [ -n "$enc" ] || _bkp_rdie unreadable "Usage: lifeagents backup restore <datei.nla.enc> [--from-host] [--key-stdin] [--yes]"
  local host_src=""
  if [ "$in_stdin" = 1 ]; then
    :
  elif [ "$from_host" -eq 1 ]; then
    case "$enc" in
      /*|[A-Za-z]:\\*|[A-Za-z]:/*)
        _bkp_host_dir_valid "$enc" || _bkp_rdie unreadable "Pfad '${enc}' lässt sich nicht an Docker geben (Komma, Anführungszeichen oder Zeilenumbruch)."
        host_src="$enc" ;;
      */*|*\\*) _bkp_rdie unreadable "Datei als Name im gemerkten Ordner oder mit vollem Pfad angeben: $enc" ;;
      *) host_src="$(_bkp_host_dir)"; [ -n "$host_src" ] || _bkp_rdie nofolder "Kein Sicherungs-Ordner auf dem Rechner gewählt — Datei mit vollem Pfad angeben."; host_src="$(_bkp_join "$host_src" "$enc")" ;;
    esac
  else
    [ -r "$enc" ] || _bkp_rdie unreadable "Backup-Datei nicht lesbar: $enc"
  fi

  local src_name; src_name="${host_src:-$enc}"; src_name="${src_name##*/}"; src_name="${src_name##*\\}"

  local tmp; tmp="$(_bkp_tmpdir)" || _bkp_rdie internal "Konnte Arbeitsverzeichnis nicht anlegen."
  # Pfad jetzt in den Trap-String expandieren (s. export): $tmp ist local -> bei der global feuernden
  # EXIT-Trap waere es unter `set -u` "unbound variable".
  # shellcheck disable=SC2064  # bewusst JETZT expandieren: $tmp ist local -> bei der global feuernden EXIT-Trap unter `set -u` unbound
  trap "rm -rf -- '$tmp'" EXIT

  # Sperren vor dem Lesen: der Probelauf schreibt nichts und nimmt keine; alles andere wartet bis 30 s auf die Update-Sperre
  # (der Minuten-Takt haelt sie kurz) und verlangt, dass kein Hintergrund-Lauf mehr laeuft.
  if [ "$plan" = 0 ]; then
    _bkp_restore_running && _bkp_rdie busy "Es läuft schon eine Wiederherstellung."
    update_lock_acquire 30 || _bkp_rdie busy "Gerade läuft ein Update oder eine Sicherung — gleich noch einmal versuchen."
  fi

  # --- (1) Holen + Entschluesseln + Header lesen (vor jedem Wipe) ---
  if [ "$in_stdin" = 1 ]; then
    _bkp_read_in_stdin "$tmp/in.nla.enc"
    enc="$tmp/in.nla.enc"
  elif [ -n "$host_src" ]; then
    # Rechner-Ordner: das Chiffrat zuerst in den tmpfs holen (nur lesend gemountet, genau dieser eine Ordner).
    local hs; hs="$(_bkp_hd "$host_src")"
    rt_host_get "$(dirname "$hs")" "$(basename "$hs")" > "$tmp/in.nla.enc" && [ -s "$tmp/in.nla.enc" ] \
      || _bkp_rdie unreadable "Sicherung '${host_src}' auf dem Rechner nicht lesbar. Es wurde NICHTS geaendert."
    enc="$tmp/in.nla.enc"
  fi
  # Erst alle gespeicherten Schluessel (aktiver zuerst); oeffnet keiner die Datei, kommt der Schluessel vom Notfallblatt.
  # Ein gespeicherter Schluessel mit der ID aus dem Dateinamen, der trotzdem scheitert = Datei beschaedigt (nicht fragen).
  local brought='' others='' file_kid; file_kid="$(_bkp_file_key_id "$src_name")"
  if ! gpg_sym_decrypt_any "$enc" "$tmp/bundle.tar.gz"; then
    local known; known=$'\n'"$(_bkp_key_ids)"$'\n'
    if [ -n "$file_kid" ] && [[ "$known" == *$'\n'"$file_kid"$'\n'* ]]; then
      _bkp_rdie corrupt_stored "$(backup_text msg.corrupt_stored id "$file_kid") (${src_name}) $(backup_text msg.unchanged)" --arg id "$file_kid"
    fi
    _bkp_brought_key "$enc" "$tmp/bundle.tar.gz" "$file_kid" "$key_stdin"
    brought="$_BKP_BROUGHT"; others="$_BKP_OTHERS"; _BKP_BROUGHT=''; _BKP_OTHERS=''
  fi
  _BKP_SHEET=''
  tar -xzf "$tmp/bundle.tar.gz" -C "$tmp" 2>/dev/null || _bkp_rdie corrupt "Tarball beschaedigt (kein gueltiges Bundle). Nichts geaendert."
  [ -r "$tmp/manifest.json" ] && [ -r "$tmp/data.dump" ] || _bkp_rdie bundle_incomplete "Bundle unvollstaendig (manifest.json/data.dump fehlt). Nichts geaendert."

  local fmt; fmt="$(jq -r '.bundle_format // empty' "$tmp/manifest.json" 2>/dev/null)"
  [ "$fmt" = "2" ] || _bkp_rdie format "Nicht unterstuetztes Backup-Format (bundle_format='${fmt:-?}', erwartet 2). Alt-/.enc-Bundles der frueheren In-DB-Engine sind inkompatibel. Nichts geaendert."
  local part
  for part in $(jq -r '(.parts // [])[]' "$tmp/manifest.json" 2>/dev/null); do
    case " $BACKUP_KNOWN_PARTS " in *" $part "*) ;; *) _bkp_rdie version_newer "Die Sicherung enthält einen Teil ($part), den diese Version nicht kennt — erst 'lifeagents update', dann erneut wiederherstellen. Es wurde NICHTS geaendert." --arg release "$(_bkp_bundle_release "$tmp" "$src_name")" ;; esac
  done

  # --- (2) Pre-Flight je Bundle-Paket gegen Registry bzw. Paket-Manifest — prueft nur, aendert nichts. Ein fehlendes Paket
  #     wird spaeter eingerichtet (--no-seed, der Restore bringt die Daten; eines ohne backup-Block nur gemeldet), ein
  #     ausgeschaltetes eingeschaltet; beides erst
  #     nach der Bestaetigung, vor der TX. ---
  local rel_hint; rel_hint="$(_bkp_bundle_release "$tmp" "$src_name")"; _BKP_RELEASE="$rel_hint"
  local pkg ver inst_status to_install='' to_activate='' to_skip='' missing_access='[]' pkgs_json='[]' pstate
  while IFS=$'\t' read -r pkg ver; do
    [ -n "$pkg" ] || continue
    printf '%s' "$pkg" | grep -qE '^[a-z][a-z0-9_]*$' || _bkp_rdie format "Ungueltiger Paketname im Bundle: $pkg"
    inst_status="$(_bkp_psql_scalar "SELECT status FROM core.package_registry WHERE package = '${pkg}'")"
    if [ -z "$inst_status" ]; then
      [ -r "$(_pkg_dir)/$pkg/manifest.json" ] || _bkp_rdie package_unknown "Die Sicherung enthält das Paket '$pkg', das diese Version nicht kennt. Es wurde NICHTS geaendert." --arg pkg "$pkg"
      if ! jq -e 'has("backup")' "$(_pkg_dir)/$pkg/manifest.json" >/dev/null 2>&1; then
        # Kein backup-Block = keine Daten in der Sicherung (der Kopf nennt nur alle damals aktiven Pakete): nichts einzuspielen,
        # und Einstellungen wie die Paperless-Adresse kommen ohnehin nicht mit -> nicht einrichten, nur melden.
        pstate=skip; to_skip="${to_skip}${pkg} "
      else
        # Ohne Terminal (App) entstuende ein Paket mit Pflicht-Zugang halb eingerichtet; freiwillige Zugaenge laesst die
        # Einrichtung dann aus (wie Enter im Terminal), sie sind spaeter nachtragbar.
        if { [ "$_BKP_JSON" = 1 ] || ! tty_usable; }; then
          if _bkp_pkg_needs_setup "$pkg" && ! _bkp_access_covers "$tmp" "$pkg" required; then
            _bkp_rdie needs_setup "Paket '$pkg' braucht Zugangsdaten — erst einrichten, dann erneut wiederherstellen. Es wurde NICHTS geaendert." --arg pkg "$pkg"
          fi
          _bkp_pkg_has_access "$pkg" && ! _bkp_access_covers "$tmp" "$pkg" && missing_access="$(jq -c --arg p "$pkg" '. + [$p]' <<<"$missing_access")"
        fi
        pstate=install; to_install="${to_install}${pkg} "
      fi
    elif [ "$inst_status" = active ]; then
      pstate=ok
    else
      pstate=activate; to_activate="${to_activate}${pkg} "
    fi
    pkgs_json="$(jq -c --arg n "$pkg" --arg v "$ver" --arg s "$pstate" '. + [{name: $n, version: $v, state: $s}]' <<<"$pkgs_json")"
  done < <(jq -r '.packages[]? | [.name, .version] | @tsv' "$tmp/manifest.json")
  # Versions-Sperre am Aufbau (vor jedem Wipe und jeder Vorab-Sicherung). Erst einzuschaltende Pakete zaehlen gleich mit (ihre
  # Tabellen gibt es schon), erst einzurichtende prueft _bkp_rs_apply nach dem Einrichten.
  # shellcheck disable=SC2086  # Paketlisten sind Namen ^[a-z][a-z0-9_]*$, bewusst wortgetrennt
  _bkp_schema_check "$tmp" "$(_bkp_deferred_tables $to_install)" "$to_activate" || _bkp_version_die

  # --- (3) Wipe-Menge (heute aktive Pakete) + eigene Daten. Nach dem Einrichten fehlender Pakete wird die Menge in
  #     _bkp_rs_apply neu bestimmt (deren Tabellen kommen dazu). ---
  local bulk has_data=0; bulk="$(_bkp_bulk_tables)"
  [ -n "$bulk" ] || [ -n "$to_install$to_activate" ] || _bkp_rdie no_tables "Keine Ziel-Tabellen (aktive Pakete + backup-Block) — Abbruch vor Wipe."
  [ -n "$bulk" ] && _bkp_has_data "$bulk" && has_data=1
  local created; created="$(jq -r '.created_at // empty' "$tmp/manifest.json" 2>/dev/null)"
  local adopt_id=''; [ -n "$brought" ] && adopt_id="$(printf '%s' "$brought" | backup_key_id)"
  # Ohne Ordner keine Vorab-Sicherung -> mit eigenen Daten keine Wiederherstellung (die Daten waeren ohne Rueckweg weg).
  # Schon im Probelauf, damit die Vorschau gar nicht erst zum Bestaetigen einlaedt.
  if [ "$has_data" = 1 ] && rt_is_compose && [ -z "$(_bkp_host_dir)" ]; then
    _bkp_rdie nofolder "Es sind schon eigene Daten da, aber kein Sicherungs-Ordner gewählt — erst einen wählen, dann wird vor dem Ersetzen gesichert."
  fi

  if [ "$plan" = 1 ]; then
    jq -cn --arg created "$created" --arg release "$rel_hint" --argjson packages "$pkgs_json" --arg adopt "$adopt_id" \
      --argjson has_data "$has_data" --arg name "$src_name" --argjson missing_access "$missing_access" \
      '{ok: true, name: $name, created: (if $created == "" then null else $created end),
        release: (if $release == "" then null else $release end), packages: $packages, missing_access: $missing_access,
        has_data: ($has_data == 1), safety_backup: ($has_data == 1),
        adopt_key_id: (if $adopt == "" then null else $adopt end)}'
    return 0
  fi

  local pkg_summary filt_disp filt_n qd cd
  pkg_summary="$(jq -r '[.packages[]? | "\(.name)@\(.version)"] | join(", ")' "$tmp/manifest.json" 2>/dev/null || true)"
  filt_disp=""; filt_n=0
  while IFS=$'\t' read -r qd cd; do
    [ -n "$qd" ] || continue
    [ -n "$filt_disp" ] && filt_disp+="; "
    filt_disp+="$qd ($cd)"; filt_n=$((filt_n + 1))
  done < <(_bkp_filtered)

  # Wipe-Uebersicht immer ausweisen (via warn/log -> stderr; auch unter --yes sichtbar, z. B. im Cron-Log).
  warn "RESTORE ueberschreibt ALLE aktuellen Nutzerdaten (Finanzen, Profil, Trigger, Plaene) mit dem Bundle-Inhalt. Betroffen:"
  log "  Pakete (Bundle): ${pkg_summary:-?}"
  [ -z "$to_install" ] || log "  Wird vorher eingerichtet (--no-seed): ${to_install% }"
  [ -z "$to_activate" ] || log "  Wird vorher eingeschaltet: ${to_activate% }"
  [ -z "$to_skip" ] || log "  Nicht eingerichtet (sichert keine Daten, bei Bedarf neu einrichten): ${to_skip% }"
  log "  Voll-Wipe (TRUNCATE), $(printf '%s' "$bulk" | grep -c .) Tabelle(n): $(printf '%s' "$bulk" | tr '\n' ' ')"
  log "  Zeilen-gefiltert, ${filt_n} Tabelle(n): ${filt_disp:-(keine)}"
  [ "$has_data" = 1 ] && log "  Vorher wird eine Sicherung der jetzigen Daten geschrieben."
  if [ -n "$brought" ]; then
    log "  $(backup_text msg.adopt id "$adopt_id")"
  fi

  # --- (3b) TTY-Bestaetigung (destruktiv) ---
  if [ "$force" -ne 1 ]; then
    tty_usable || die "Kein TTY und kein --yes -> Abbruch (Restore ueberschreibt ALLE Nutzerdaten)."
    printf 'Wirklich wiederherstellen? [ja/NEIN]: ' > /dev/tty
    local ans=""; read -r ans < /dev/tty
    [ "$ans" = "ja" ] || die "Abgebrochen."
  fi

  if [ "$detach" = 1 ]; then
    # Hintergrund-Lauf als bash-Unterschale ohne exec: der Schluessel bleibt in ihrem Speicher (kein neues Programm, also
    # nichts in argv/Umgebung). Sie erbt fd 9 (Update-Sperre) und nimmt fd 8 (Restore-Sperre); ihr eigener EXIT-Trap raeumt
    # den tmpfs. Der Aufrufer gibt den Trap ab (sonst loeschte er das Bundle unter dem Kind) und endet sofort; docker exec
    # kehrt zurueck, weil das Kind stdout/stderr gleich auf das Protokoll umlegt.
    # Protokoll ohne Schluessel (nur log/warn-Saetze, Tabellen- und Paketnamen), bleibt fuer die Diagnose liegen.
    local log_f; log_f="${LIFEAGENTS_LOG_DIR:-/var/log/lifeagents}/restore.log"
    { mkdir -p "${log_f%/*}" && ( umask 077; : > "$log_f" ); } 2>/dev/null || _bkp_rdie internal "Konnte das Protokoll nicht anlegen."
    { exec 8>>"$BACKUP_RESTORE_LOCK" && flock -n 8; } || _bkp_rdie busy "Es läuft schon eine Wiederherstellung."
    _bkp_state_set LAST_RESTORE_START "$(date +%s)"; _bkp_state_set LAST_RESTORE_NAME "$src_name"
    _bkp_state_set LAST_RESTORE_CREATED "$created"; _bkp_state_set LAST_RESTORE_FOREIGN "$([ -n "$brought" ] && printf 1 || printf 0)"
    _bkp_state_set LAST_RESTORE_TMP "$tmp"
    _bkp_state_set LAST_RESTORE_OK ''; _bkp_state_set LAST_RESTORE_FAIL ''; _bkp_state_set LAST_RESTORE_REASON ''
    _bkp_state_set LAST_RESTORE_RELEASE ''; _bkp_state_set LAST_RESTORE_CONVERGE ''; _bkp_state_set LAST_RESTORE_PARTS ''
    (
      exec </dev/null >"$log_f" 2>&1
      # shellcheck disable=SC2064  # bewusst JETZT expandieren (local $tmp)
      trap "rm -rf -- '$tmp'" EXIT
      # shellcheck disable=SC2030  # gilt bewusst nur in dieser Unterschale (der Aufrufer endet gleich danach)
      _BKP_CHILD=1
      # shellcheck disable=SC2030  # ebenso
      _BKP_JSON=0
      # UNATTENDED: ein Hintergrund-Lauf fragt nie, auch wenn er aus einem Terminal kam (/dev/tty bliebe sonst nutzbar und
      # die Paket-Einrichtung wartete dort auf Zugangsdaten, mit beiden Sperren in der Hand).
      # shellcheck disable=SC2034  # UNATTENDED liest ui_interactive (common.sh) in dieser Shell
      UNATTENDED=1
      _bkp_state_set LAST_RESTORE_PID "$BASHPID"
      _bkp_rs_apply "$tmp" "$brought" "$others" "$has_data" "$to_install" "$to_activate" "$to_skip"
      _bkp_state_set LAST_RESTORE_OK "$(date +%s)"
    ) &
    trap - EXIT
    jq -cn --argjson started "$(date +%s)" '{ok: true, started: $started}'
    return 0
  fi
  # --json ohne --detach (Aufrufer wartet auf ein JSON-Objekt): der Pre-Flight hat ohne Terminal entschieden, also fragt
  # auch die Paket-Einrichtung nicht.
  # shellcheck disable=SC2034,SC2031  # UNATTENDED liest ui_interactive (common.sh); _BKP_JSON aendert nur der Hintergrund-Zweig
  [ "$_BKP_JSON" != 1 ] || UNATTENDED=1
  _BKP_JSON=0
  _bkp_rs_apply "$tmp" "$brought" "$others" "$has_data" "$to_install" "$to_activate" "$to_skip"
}

# _bkp_rs_apply <tmp> <blatt-schluessel> <weitere> <eigene-daten:0|1> <pakete-einrichten> <pakete-einschalten>
#   <pakete-uebersprungen> — der aendernde Teil nach der Bestaetigung (Terminal und Hintergrund-Lauf): Pakete einrichten/
#   einschalten, Aufbau ihrer Tabellen pruefen, Vorab-Sicherung der jetzigen Daten, eine TX, danach _bkp_converge. Jeder
#   Abbruch bis einschliesslich der TX ueber _bkp_rdie (ein vorher eingerichtetes Paket bleibt); ein gescheiterter Abgleich
#   danach warnt nur, die Daten sind dann schon eingespielt.
_bkp_rs_apply() {
  local tmp="$1" brought="$2" others="$3" has_data="$4" to_install="$5" to_activate="$6" to_skip="${7:-}" pkg
  # Zugaenge aus der Sicherung vor der Einrichtung: pkg_install_one liest sie dann wie eingegebene Werte (kein Nachfragen,
  # kein Abbruch an einem Pflicht-Zugang).
  _bkp_access_write_env "$tmp"
  _pkg_menus_defer   # Menue einmal nach den Paketen (jeder Statuswechsel setzt es sonst neu)
  for pkg in $to_install; do
    log "Auto-Install '$pkg' --no-seed (Restore bringt die Daten) ..."
    # Subshell: ein internes `die` beendet nur den Install, dann sauberer Abbruch HIER (vor dem Wipe).
    ( pkg_install_one "$pkg" --no-seed ) || _bkp_rdie internal "Auto-Install '$pkg' fehlgeschlagen -> Abbruch VOR jedem Wipe (alte Welt intakt)."
    if ! ui_interactive && _bkp_pkg_has_access "$pkg" && ! _bkp_access_covers "$tmp" "$pkg"; then
      log "Paket '$pkg' ist ohne seine freiwilligen Zugänge eingerichtet — nachtragen: lifeagents package reconfigure $pkg"
    fi
  done
  for pkg in $to_activate; do
    ( _pkg_set_status "$pkg" active ) || _bkp_rdie internal "Paket '$pkg' ließ sich nicht einschalten -> Abbruch vor dem Wipe."
  done
  _pkg_menus_flush
  # Pre-Flight-Recheck nach Install/Einschalten — jedes Bundle-Paket ausser den uebersprungenen (to_skip, ohne backup-Block)
  # muss jetzt aktiv sein: _bkp_bulk_tables (Wipe/
  # Restore-Menge) zaehlt nur aktive Pakete, ein inaktives wuerde nicht truncatet (UNIQUE/PK-Konflikte, Rollback).
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    _bkp_is_active "$pkg" "$to_skip" && continue
    [ "$(_bkp_psql_scalar "SELECT status FROM core.package_registry WHERE package = '${pkg}'")" = active ] \
      || _bkp_rdie internal "Paket '$pkg' ist nach dem Einrichten nicht aktiv -> Abbruch vor dem Wipe."
  done < <(jq -r '.packages[]?.name' "$tmp/manifest.json")
  if [ -n "$to_install" ]; then
    _bkp_schema_check "$tmp" "" || _bkp_version_die "Eingerichtet wurde: ${to_install% }; deine Daten sind unverändert."
  fi
  local bulk; bulk="$(_bkp_bulk_tables)"
  [ -n "$bulk" ] || _bkp_rdie no_tables "Keine Ziel-Tabellen (aktive Pakete + backup-Block) — Abbruch vor Wipe."

  # --parts: nur die Teile nach den Daten (Gespraeche, Einstellungen, Zugaenge) nachholen, ohne die Daten erneut zu ersetzen.
  # parts_only ist die Option von backup_cmd_restore (Aufrufer-Variable; bash sieht locals des Aufrufers).
  if [ "$parts_only" = 1 ]; then _bkp_restore_parts "$tmp"; return; fi

  # Vorab-Sicherung: der einzige Rueckweg, wenn eigene Daten ersetzt werden. Eigene Teilschale (export setzt seinen Trap);
  # die Update-Sperre ist geerbt (LIFEAGENTS_UPDATE_LOCK_HELD).
  if [ "$has_data" = 1 ]; then
    log "Sichere die jetzigen Daten vor dem Ersetzen ..."
    if rt_is_compose; then
      ( backup_cmd_export --to-host ) || _bkp_rdie safety "Die Sicherung der jetzigen Daten ist fehlgeschlagen — nichts ersetzt."
    else
      mkdir -p /var/backups/lifeagents && chmod 0700 /var/backups/lifeagents 2>/dev/null || true
      ( cd /var/backups/lifeagents && backup_cmd_export ) || _bkp_rdie safety "Die Sicherung der jetzigen Daten ist fehlgeschlagen — nichts ersetzt."
    fi
  fi

  # --- (4) Atomarer Restore: TRUNCATE + pg_restore-SQL + fn + Count-Verify in einer psql -1-TX ---
  local restore_sql="$tmp/restore.sql"
  # lock_timeout: haelt n8n gerade eine Zeilen-/Tabellensperre (ein Mitglied schreibt), wartet TRUNCATE nicht endlos.
  printf "SET LOCAL lock_timeout = '30s';\n" > "$restore_sql"
  # (a) TRUNCATE der bulk-Tabellen (FK-/Trigger-frei dank --disable-triggers im pg_restore; CASCADE als Sicherung).
  #     filtered_tables nicht truncaten -> die fn macht den zeilen-gefilterten Wipe. Nur Tabellen, deren Daten im Bundle stehen
  #     ($tmp/sc.bundle aus _bkp_schema_check): eine aeltere Sicherung ohne eine neue Tabelle laesst sie auf dem Ziel unberuehrt.
  local trunc="" t n
  while IFS= read -r t; do
    [ -n "$t" ] || continue; _bkp_qual_ok "$t" || _bkp_rdie internal "Ungueltiger Tabellenname im bulk-Set: $t"
    # Prozess-Ersetzung statt Pipe: grep -q beendet frueh, cut bekaeme SIGPIPE und pipefail meldete "nicht gefunden".
    grep -qxF -- "$t" < <(cut -f1 "$tmp/sc.bundle") || { log "$t steht nicht in dieser Sicherung — bleibt unberuehrt."; continue; }
    [ -n "$trunc" ] && trunc+=", "
    trunc+="$t"
  done <<< "$bulk"
  [ -z "$trunc" ] || printf 'TRUNCATE %s CASCADE;\n' "$trunc" >> "$restore_sql"
  # (b) pg_restore -> SQL-Text (kein eigener DB-Connect; laeuft so in unserer einen TX).
  # pg_restore (postgres via runuser) liest die Archiv-Datei nicht direkt (root-eigenes 0700-tmpfs) -> die
  # root-Shell oeffnet sie per stdin-Redirect; pg_restore -f - schreibt das SQL auf stdout (in unsere EINE TX).
  if ! pg_su_stdin pg_restore -a --disable-triggers -f - < "$tmp/data.dump" >> "$restore_sql"; then
    _bkp_rdie corrupt "pg_restore (SQL-Generierung) fehlgeschlagen. Nichts geaendert."
  fi
  # (c) gefilterte Tabellen regel-bewusst (shared.json als base64 -> kein Quoting-Risiko).
  local shared_b64; shared_b64="$(base64 -w0 "$tmp/shared.json" 2>/dev/null || base64 "$tmp/shared.json" | tr -d '\n')"
  printf "SELECT core.fn_backup_restore_filtered(convert_from(decode('%s','base64'),'UTF8')::jsonb);\n" "$shared_b64" >> "$restore_sql"
  # (d) Count-Verify: post-Restore count(*) vs. manifest.verify_counts -> Mismatch = RAISE = Rollback der ganzen TX.
  {
    # shellcheck disable=SC2016  # $verify$ = SQL-Dollar-Quote-Tag (literal), keine Shell-Expansion gewollt
    printf 'DO $verify$ BEGIN\n'
    # bulk: plain count
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      n="$(jq -r --arg k "$t" '.verify_counts[$k] // empty' "$tmp/manifest.json")"
      [ -n "$n" ] || continue
      printf "  IF (SELECT count(*) FROM %s) <> %s THEN RAISE EXCEPTION 'verify failed: %s count %% (expected %s)', (SELECT count(*) FROM %s); END IF;\n" "$t" "$n" "$t" "$n" "$t"
    done <<< "$bulk"
    # filtered: count WHERE cond
    local qual cond
    while IFS=$'\t' read -r qual cond; do
      [ -n "$qual" ] || continue; _bkp_qual_ok "$qual" || continue
      n="$(jq -r --arg k "$qual" '.verify_counts[$k] // empty' "$tmp/manifest.json")"
      [ -n "$n" ] || continue
      # core.llm_usage fuehrt core.fn_backup_restore_filtered zusammen (die Kosten des Ziels bleiben): mindestens so viele Zeilen.
      local cmp='<>'; [ "$qual" = core.llm_usage ] && cmp='<'
      printf "  IF (SELECT count(*) FROM %s WHERE %s) %s %s THEN RAISE EXCEPTION 'verify failed: %s count %% (expected %s)', (SELECT count(*) FROM %s WHERE %s); END IF;\n" "$qual" "$cond" "$cmp" "$n" "$qual" "$n" "$qual" "$cond"
    done < <(_bkp_filtered)
    # shellcheck disable=SC2016  # $verify$ = SQL-Dollar-Quote-Tag (literal)
    printf 'END $verify$;\n'
  } >> "$restore_sql"

  # psql (postgres via runuser) liest das Skript ueber stdin (`-f -`; root oeffnet die Datei) — kein Dateipfad (das root-eigene
  # 0700-tmpfs ist fuer postgres nicht traversierbar). -1 = eine TX ueber den ganzen Strom; `-f -` statt nacktem stdin, weil
  # psql -1 nur fuer -c/-f zusagt. Ein mitgebrachter Schluessel steht vorn im Strom (\set), nie in restore.sql. stderr geht
  # in den tmpfs, damit ein Sperr-Timeout als busy erkennbar ist (Fehlertext enthaelt nie den Schluessel: \set echot nicht).
  if { if [ -n "$brought" ]; then
         local o j=0
         psql_setvar bk_new "$brought"
         while IFS= read -r o; do [ -n "$o" ] || continue; psql_setvar "bk_o$j" "$o"; j=$((j + 1)); done <<<"$others"
         _bkp_adopt_sql "$j"
       fi
       cat "$restore_sql"; } \
       | pg_su_psql -v ON_ERROR_STOP=1 -1 -X -q -d "$N8N_DB_NAME" -f - 2> "$tmp/psql.err"; then
    ok "Restore abgeschlossen (atomar, Count-Verify gruen): $(printf '%s' "$bulk" | grep -c .) bulk-Tabelle(n) + gefilterte Zeilen wiederhergestellt."
  else
    cat "$tmp/psql.err" >&2 2>/dev/null || true
    grep -q 'lock timeout' "$tmp/psql.err" 2>/dev/null \
      && _bkp_rdie busy "Restore wartete zu lange auf eine Sperre — Transaktion zurueckgerollt, nichts geaendert."
    _bkp_rdie internal "Restore fehlgeschlagen — Transaktion zurueckgerollt, die alte Welt ist intakt."
  fi
  # Ein Abbruch hier ist kein gescheiterter Restore: die Daten sind schon eingespielt, und die App sagt bei jedem Fehlschlag
  #   „Deine Daten sind unverändert“. Darum Warnung, im Hintergrund-Lauf zusaetzlich LAST_RESTORE_CONVERGE (restore-status:
  #   converged:false); Terminal und --json ohne --detach sehen nur die Warnung.
  _bkp_restore_parts "$tmp" || true
}

# _bkp_restore_parts <arbeitsordner> — nach den Daten: Gespraeche (eigene TX), Abgleich mit dieser Version (_bkp_converge),
#   geaenderte Einstellungen (nach dem Abgleich: erst dann gibt es die Zeilen eben eingerichteter Pakete), Zugaenge. Jeder Teil
#   fuer sich: die Daten sind schon eingespielt, ein gescheiterter Teil wird gemeldet (restore-status: converged:false,
#   parts_failed) und laesst sich mit `backup restore <datei> --parts` nachholen. Ein Teil, den die Sicherung nicht traegt
#   (aeltere Sicherung), bleibt auf dem Ziel unberuehrt.
_bkp_restore_parts() {
  local tmp="$1" bad='' rc res
  if _bkp_has_part "$tmp" memory; then
    rc=0; _bkp_memory_restore "$tmp/memory.dump" "$tmp/memory.counts" || rc=$?
    case "$rc" in
      0) ;;
      2) warn "Gespräche nicht übernommen: n8n hielt gerade eine Sperre."; bad+=' memory' ;;
      *) warn "Gespräche nicht übernommen."; bad+=' memory' ;;
    esac
  else
    log "Diese Sicherung enthält noch keine Gespräche — das Gesprächs-Gedächtnis bleibt, wie es ist."
  fi
  log "Gleiche die eingespielten Daten mit dieser Version ab (Schema-Inits + Seed wie beim Update) ..."
  if ! _bkp_converge; then
    warn "Die Daten sind eingespielt, aber der Abgleich mit dieser Version brach ab: Bezeichnungen und Rollen-Zuordnungen können bis dahin aus dem Stand der Sicherung stammen. Abhilfe: lifeagents update"
    # shellcheck disable=SC2031  # _BKP_CHILD=1 setzt die Hintergrund-Unterschale, in der diese Funktion dann laeuft
    [ "$_BKP_CHILD" != 1 ] || _bkp_state_set LAST_RESTORE_CONVERGE fail
  fi
  if _bkp_has_part "$tmp" config; then
    if res="$(config_import_rows "$tmp/config.json")" && [ -n "$res" ]; then config_import_report "$res" || true
    else warn "Einstellungen nicht übernommen."; bad+=' config'; fi
  else
    log "Diese Sicherung enthält noch keine Einstellungen — die Einstellungen bleiben, wie sie sind."
  fi
  if _bkp_has_part "$tmp" access; then
    _bkp_access_inject "$tmp" || { warn "Zugänge nicht übernommen."; bad+=' access'; }
  else
    log "Diese Sicherung enthält noch keine Zugänge — die Zugänge bleiben, wie sie sind."
  fi
  [ -n "$bad" ] || return 0
  warn "Nicht übernommen:${bad} — die Daten sind eingespielt; 'lifeagents backup restore <datei> --parts' holt es nach."
  # shellcheck disable=SC2031  # _BKP_CHILD=1 setzt die Hintergrund-Unterschale, in der diese Funktion dann laeuft
  if [ "$_BKP_CHILD" = 1 ]; then _bkp_state_set LAST_RESTORE_CONVERGE fail; _bkp_state_set LAST_RESTORE_PARTS "${bad# }"; fi
  return 1
}

# _bkp_converge — nach dem Einspielen fuer Core und jedes aktive Paket dieselben Schritte wie ein Update (apply_schema, dann
#   seed_data). Grund: eingespielte Tabellen tragen Code-Fakten im Stand der Sicherung (for_roles eines Onboarding-Abschnitts,
#   Katalog-Zeilen der *_init.sql, system_tables), die sonst bis zum naechsten Update falsch blieben. Beide Schritte laufen bei
#   jedem Update ueber Live-Daten und lassen Nutzer-Werte stehen (Seed-Guards: seed_data.sh, Kopf und _seed_onboarding_sections).
#   Core zuerst wie in provision.sh, sonst saehe ein Paket-R__ den Core nicht. Je Paket eine Teilschale: ein `die` endet dort.
#   Auch eben eingerichtete Pakete laufen voll: der Restore hat ihre system_tables danach aus der Sicherung ueberschrieben.
#   Rueckgabe 0 = alle abgeglichen; 1 beim ersten gescheiterten Paket, die folgenden bleiben dann unabgeglichen (der Aufrufer
#   verweist auf `lifeagents update`, das alle neu anwendet). Setzt die Globals von _pkg_resolve_env.
_bkp_converge() {
  local pkg
  _pkg_resolve_env
  for pkg in core $(_bkp_active_names | tr ' ' '\n' | grep -vx core | sort); do
    ( apply_schema "$pkg" && SEED_PKG="$pkg" seed_data ) || { err "Abgleich '$pkg' fehlgeschlagen."; return 1; }
  done
}

# ============================================================
# key — Notfallblatt
# ============================================================
# backup_cmd_key [--file <pfad>|-] — Notfallblatt ausgeben: ohne --file nur aufs Terminal (/dev/tty, nie in eine Pipe oder
#   ein Log); --file <pfad> legt eine neue 0600-Datei an (vorhandene wird nie ueberschrieben); --file - schreibt auf stdout
#   (Start-App, MasterCmd::BackupKit: `lifeagents backup key --file -` im master, Ausgabe nur in deren Datei).
backup_cmd_key() {
  local file='' a want=0 kit
  for a in "$@"; do
    if [ "$want" = 1 ]; then file="$a"; want=0; continue; fi
    case "$a" in
      --file)   want=1 ;;
      --file=*) file="${a#--file=}" ;;
      *)        die "Unbekannte Option: $a (erlaubt: --file <pfad> oder --file -)" ;;
    esac
  done
  [ "$want" = 0 ] || die "--file braucht einen Pfad (oder - für die Ausgabe auf stdout)."
  if [ -z "$file" ]; then
    tty_usable || die "Kein Terminal: das Notfallblatt erscheint nur im Terminal oder mit --file <pfad> (neue Datei, nur für root lesbar)."
  elif [ "$file" != - ] && { [ -e "$file" ] || [ -L "$file" ]; }; then
    die "'${file}' gibt es schon — einen anderen Namen wählen (das Notfallblatt überschreibt nichts)."
  fi
  _bkp_resolve_db
  kit="$(backup_kit_text)" || die "Kein Sicherungs-Schlüssel gespeichert (core.backup_key) — die Installation ist nicht fertig; 'lifeagents doctor' zeigt, was fehlt."
  if [ -z "$file" ]; then
    printf '\n%s\n\n' "$kit" > /dev/tty
  elif [ "$file" = - ]; then
    printf '%s\n' "$kit"
  else
    ( umask 077; set -o noclobber; printf '%s\n' "$kit" > "$file" ) 2>/dev/null \
      || die "Konnte '${file}' nicht anlegen (Ordner vorhanden und beschreibbar?)."
    chmod 0600 "$file"
    ok "Notfallblatt gespeichert: ${file} (nur für root lesbar). Ausdrucken oder im Passwort-Manager ablegen, nicht im Sicherungsordner."
  fi
}

# ============================================================
# Dispatcher
# ============================================================
backup_cli() {
  # Verb-Picker: nacktes `lifeagents backup` auf TTY -> Menue statt Hilfetext; ESC/non-TTY ->
  # Hilfetext (Exit 0).
  if [ "$#" -eq 0 ] && ui_interactive; then
    ensure_gum
    local _menu_verb
    _menu_verb="$(ui_choose 'lifeagents backup — was tun?' 0 <<'MENU'
export — Verschluesseltes Backup schreiben	export
restore — Backup wiederherstellen (Auswahl-Liste, fragt nach)	restore
key — Notfallblatt mit dem Sicherungs-Schlüssel anzeigen	key
help — Hilfe anzeigen	help
MENU
)"
    [ -n "$_menu_verb" ] && set -- "$_menu_verb"
  fi
  local verb="${1:-help}"; shift || true
  case "$verb" in
    export)  backup_cmd_export "$@" ;;
    host-dir) backup_cmd_host_dir "$@" ;;
    auto)    backup_cmd_auto "$@" ;;
    fingerprint) backup_fingerprint ;;
    restore) backup_cmd_restore "$@" ;;
    restore-status) backup_cmd_restore_status "$@" ;;
    list)    backup_cmd_list "$@" ;;
    key)     backup_cmd_key "$@" ;;
    help|--help|-h)
      cat >&2 <<'EOF'
lifeagents backup <verb> — Backup/Restore der Nutzerdaten (verschluesselt, paket-bewusst).

  export [pfad] [--notify-telegram]
                           Verschluesseltes Backup der Nutzerdaten schreiben (Default:
                           ./lifeagents-backup-<ts>-k<schlüssel-id>-v<version>.nla.enc).
                           Sichert NUR echte Nutzerdaten (Finanzen/Profil/Trigger/Plaene/Onboarding) via pg_dump —
                           NICHT Code/Workflows/Geheimnisse (die stellt der Installer wieder her).
                           --notify-telegram legt die fertige .nla.enc zusätzlich in die angeheftete Kopie-Nachricht
                           im Owner-Telegram-Chat (tauscht die Datei darin aus, keine neue Nachricht; gilt auch bei
                           ausgeschalteter Kopie, dann ohne Knopf und nicht angeheftet; best-effort: schlaegt der Versand fehl, bleibt das
                           lokale Backup gueltig).
  restore <datei> [--key-stdin] [--yes]
                           Backup wiederherstellen (ATOMAR: alles-oder-nichts). UEBERSCHREIBT alle Nutzerdaten;
                           zeigt VOR der Rückfrage die betroffenen Pakete + Tabellen. Ein fehlendes Bundle-Paket wird
                           nach der Rückfrage eingerichtet (--no-seed), ein ausgeschaltetes eingeschaltet. Eine
                           Sicherung aus einer anderen Version wird eingespielt, wenn ihre Tabellen zu dieser
                           passen; sonst Abbruch vor jeder Änderung (neuer: erst update; älter: die Version der
                           Sicherung installieren). Sind eigene Daten da, wird vorher gesichert. --yes überspringt
                           die Rückfrage.
                           Öffnet kein gespeicherter Schlüssel die Datei (neuer Rechner), fragt restore verdeckt nach
                           dem Schlüssel vom Notfallblatt; --key-stdin liest ihn (oder die Notfallblatt-Datei) aus stdin.
                           Danach gilt dieser Schlüssel, der bisherige bleibt für ältere Sicherungen gespeichert.
  key [--file <pfad>|-]    Notfallblatt mit dem Sicherungs-Schlüssel: ohne Option nur aufs Terminal; --file legt eine
                           neue Datei an (nur für root lesbar), --file - schreibt auf stdout. Ausdrucken oder im
                           Passwort-Manager ablegen — ohne den Schlüssel lässt sich keine Sicherung öffnen.
  auto [--scheduled]       Tägliche Sicherung jetzt machen (Docker: in den Rechner-Ordner, ohne Ordner nur ein Vermerk; LXC/Server:
                           nach /var/backups/lifeagents/daily). --scheduled (nur der Timer) tut nichts, wenn heute schon eine gelang.

Nur im Docker-Verbund (Mac/Windows-App) — Sicherungen liegen in einem Ordner AUF DEM RECHNER, nicht auf der Docker-Platte:
  host-dir [<ordner>]      Sicherungs-Ordner auf dem Rechner zeigen bzw. setzen (absoluter Pfad, wird auf Schreibrecht geprüft).
  export [--to-host [<ordner>]]
                           Ohne Pfad schreibt der Verbund immer in den Rechner-Ordner (behält die letzten 14 Sicherungen
                           mit dem eigenen Schlüssel; Sicherungen eines anderen Rechners im Ordner bleiben liegen).
  restore [<name>|<pfad>] [--from-host] [--key-stdin] [--yes]
                           Ohne Datei: Auswahl aus dem Rechner-Ordner; <name> = Datei im gewählten Ordner.
                           Für die Start-App: --plan --json (Probelauf, ändert nichts), --yes --detach --json (im
                           Hintergrund; Stand: restore-status --json), --in-stdin (Sicherung + Blatt über stdin).
  list --json              Sicherungen im Rechner-Ordner (für die Start-App).
  restore-status --json    Stand der letzten Wiederherstellung im Hintergrund (für die Start-App).
  restore <datei> --parts  Nur Gespräche, Einstellungen und Zugänge aus der Sicherung nachholen (die Daten bleiben, wie sie sind),
                           wenn ein Teil beim Einspielen scheiterte (restore-status: parts_failed).
  fingerprint              Vergleichswerte des ganzen Sicherungs-Umfangs (Zeilen + Prüfsummen, nie Werte); gleich vor dem
                           Sichern und nach dem Einspielen = alles wie vorher (auch lifeagents move check).

Automatisch (LXC/Server, klassischer Betrieb) — läuft von selbst, nichts einzurichten: der Timer lifeagents-backup sichert täglich ab
03:30 (Haushalts-Zeitzone) nach /var/backups/lifeagents/daily und behält die letzten 14. Verlauf: journalctl -u lifeagents-backup;
Stand: lifeagents doctor.

Kopie im Telegram-Chat (beide Betriebsarten): nach jeder automatischen Sicherung tauscht der Bot die Datei in einer angehefteten
Nachricht aus (keine neue Nachricht). Aus: Knopf an der Nachricht oder lifeagents config set cron_enable backup_telegram_copy false;
wieder an: /reminders im Chat oder derselbe Befehl mit true.

Schlüssel: liegt in core.backup_key (gpg-Passphrase, AES256). OFFLINE separat sichern (lifeagents backup key) — ohne
ihn kein Restore auf einem neuen Rechner.
EOF
      ;;
    *) err "lifeagents backup: unbekannter Verb: $verb"; backup_cli help; return 1 ;;
  esac
}
