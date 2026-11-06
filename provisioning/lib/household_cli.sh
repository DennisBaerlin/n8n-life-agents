# household_cli.sh — Runtime-CLI fuer Owner-Lifecycle-Operationen am Haushalt (WS-5d).
# SOURCED (kein Shebang, kein `set -e` — der Top-Aufrufer `lifeagents` traegt den Error-Mode).
#
# Aufruf: `lifeagents household <verb> [args]` (die CLI sourct diese Datei + common.sh).
# DB-Zugriff: postgres-Superuser via runuser/Peer-Auth am lokalen Socket (host-vermittelt, wie
# config_cli.sh/pkg_lifecycle.sh). Die Autorisierung ist der OS-/SSH-Root-Zugang — diese seltenen
# Wartungs-/Defense-Ereignisse laufen bewusst NICHT ueber das LLM/den Chat (deterministisch).
#
# Verben (noun-then-verb wie config/package/backup; EIN Noun `household` buendelt Personen-Lifecycle
# UND Knocker-Sperre — lokales Mehr-Concern-pro-Noun-Muster, s. docs/reference/provisioning.md *Entscheidungen*):
#   list                                   Haushalts-Personen + Telegram-Verknuepfung anzeigen (read-only)
#   add <first> <last> <birth_date> <role> Person anlegen ("Geburt"); role = owner|partner|child
#   remove <person_id>                     Person loeschen ("Tod"); abgelehnt, solange finance-Daten referenzieren
#   unlink <person_id>                     Telegram-ID von einer Person trennen (Mitglied hat neues Konto)
#   block <telegram_user_id> [grund]       Unbekannten Anklopfer sperren (keine Notiz + keine Pairing-Moeglichkeit)
#   unblock <telegram_user_id>             Sperre aufheben
#   blocked                                Gesperrte Identitaeten anzeigen (read-only)
# Die eigentliche Logik + Validierung leben in den agent.fn_*-Functions (DB ist Gesetz); die CLI
# uebersetzt nur Args -> fn-Aufruf -> freundliche Meldung ({ok:false} -> die).

DB_SUPERUSER="${DB_SUPERUSER:-postgres}"

# N8N_DB_NAME aus der n8n.env ableiten (Runtime-CLI laeuft ausserhalb von provision.sh) — eine Adresse: common.sh.
_hh_resolve_db() { lifeagents_db_name >/dev/null; }

# _hh_psql <psql-args...>  -> psql als postgres-Superuser am lokalen Socket (ON_ERROR_STOP, quiet).
_hh_psql() {
  _hh_resolve_db
  runuser -u "$DB_SUPERUSER" -- psql -v ON_ERROR_STOP=1 -X -q -d "$N8N_DB_NAME" "$@"
}

# _hh_sql_lit <s>  -> SQL-String-Literal-Inhalt (Single-Quotes verdoppelt; Injection-Schutz).
_hh_sql_lit() { printf '%s' "${1//\'/\'\'}"; }

# _hh_slug_ok <s>  -> 0 wenn ^[a-z0-9_]+$ (person_id-Vertrag).
_hh_slug_ok() { printf '%s' "$1" | grep -qE '^[a-z0-9_]+$'; }
# _hh_num_ok <s>   -> 0 wenn rein numerisch (telegram_user_id).
_hh_num_ok()  { printf '%s' "$1" | grep -qE '^[0-9]+$'; }

# _hh_call_fn <fn> <jsonb-sql>  -> ruft agent.<fn>(<jsonb>) und setzt $HH_OK/$HH_DETAIL/$HH_REASON.
#   HH_OK = 'true'/'false' (jsonb-Boolean ->> ergibt 'true'/'false', NICHT 't'/'f'!). HH_DETAIL =
#   person_id/freed_telegram_user_id/was_blocked je nach fn. Rueckgabe 0 wenn der DB-Call lief (nicht == ok).
#   Feldtrenner = ASCII Unit Separator (0x1F, NICHT TAB): TAB ist IFS-WHITESPACE -> `read` kollabiert
#   aufeinanderfolgende Tabs + verschluckt ein LEERES Mittelfeld (ok:false hat ein leeres detail) ->
#   die reason rutschte sonst nach HH_DETAIL. Ein Nicht-Whitespace-Trenner bewahrt leere Felder.
_hh_call_fn() {
  local fn="$1" payload="$2" row
  row="$(_hh_psql -tA -F $'\x1f' -c \
    "WITH r AS (SELECT agent.${fn}(${payload}) AS j)
     SELECT (j->>'ok'),
            COALESCE(j->>'person_id', j->>'freed_telegram_user_id', j->>'was_blocked', j->>'telegram_user_id', ''),
            COALESCE(j->>'reason','') FROM r")" \
    || { die "DB-Aufruf agent.${fn} fehlgeschlagen (Schema angewandt? Dienst laeuft?)."; }
  IFS=$'\x1f' read -r HH_OK HH_DETAIL HH_REASON <<EOF
$row
EOF
}

# _hh_person_rows [linked_only:0|1] -> "label<TAB>person_id"-Zeilen fuer die Personen-Picker
# (remove/unlink); dieselbe Quelle wie household_cmd_list, nur maschinenlesbar (nie Anzeige-Output
# parsen). linked_only=1 filtert auf Personen MIT Telegram-Verknuepfung (unlink-Kandidaten).
# `|| true`: fehlendes Schema -> leer -> der Picker faellt auf die Usage zurueck.
_hh_person_rows() {
  local linked="${1:-0}" cond=""
  [ "$linked" = "1" ] && cond="WHERE EXISTS (SELECT 1 FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp WHERE c.name='family' AND pp->>'person_id'=p.person_id AND jsonb_typeof(pp->'telegram_user_id') <> 'null')"
  _hh_psql -tA -F $'\t' -c \
    "SELECT p.person_id || '   ' || COALESCE(p.full_name,'-') || ' (' || COALESCE(p.role,'-') || ')', p.person_id
     FROM agent.persons p ${cond} ORDER BY p.role, p.person_id" 2>/dev/null || true
}

# --- list: Personen + Telegram-Verknuepfung ------------------------------------------------------
household_cmd_list() {
  local rows
  rows="$(_hh_psql -tA -F $'\t' -c \
    "SELECT p.person_id, COALESCE(p.full_name,'-'), COALESCE(p.role,'-'),
            COALESCE((SELECT pp->>'telegram_user_id' FROM agent.core_contexts c,
                        jsonb_array_elements(c.metadata->'facts'->'persons') pp
                      WHERE c.name='family' AND pp->>'person_id'=p.person_id
                        AND jsonb_typeof(pp->'telegram_user_id') <> 'null'), '-')
     FROM agent.persons p ORDER BY p.role, p.person_id")" \
    || die "Personen-Abfrage fehlgeschlagen (Schema angewandt?)."
  printf '%-20s %-26s %-9s %s\n' "PERSON_ID" "NAME" "ROLLE" "TELEGRAM"
  if [ -z "$rows" ]; then log "Keine Personen im Haushalt."; return 0; fi
  printf '%s\n' "$rows" | while IFS=$'\t' read -r pid name role tg; do
    printf '%-20s %-26s %-9s %s\n' "$pid" "$name" "$role" "$tg"
  done
}

# --- add: Person anlegen -------------------------------------------------------------------------
household_cmd_add() {
  # Rollen-Picker (E3-Sonderfall Mehr-Arg-Verb): NUR wenn genau die Rolle fehlt ($#==3) —
  # die Freitextfelder (Namen, Geburtsdatum) bleiben getippt (kein Wizard, YAGNI).
  if [ "$#" -eq 3 ] && ui_interactive; then
    ensure_gum
    local _role
    _role="$(ui_choose "Rolle für $1 $2:" 0 <<'MENU'
owner — Haushalts-Owner	owner
partner — Erwachsenes Mitglied	partner
child — Kind	child
MENU
)"
    [ -n "$_role" ] && set -- "$@" "$_role"
  fi
  # Sprach-Picker (Textkatalog): Sprache der festen Bot-Texte fuer diese Person, NUR aus den unterstuetzten Sprachen
  # (core.ui_languages = Laufzeit-Spiegel der Manifest-Liste). Esc/kein TTY -> ohne Sprache (Laufzeit-Fallback: die
  # Sprache des Owners; spaeter per Chat aenderbar). Die fn normiert und lehnt Nicht-Unterstuetztes ab.
  if [ "$#" -eq 4 ] && ui_interactive; then
    local _lang
    _lang="$(_hh_psql -tA -F $'\t' -c "SELECT name, code FROM core.ui_languages ORDER BY ord" 2>/dev/null \
               | ui_choose "Sprache der Bot-Nachrichten für $1 $2:" 0 || true)"
    [ -n "$_lang" ] && set -- "$@" "$_lang"
  fi
  if [ "$#" -lt 4 ]; then
    local _codes
    _codes="$(_hh_psql -tA -c "SELECT string_agg(code, '|' ORDER BY ord) FROM core.ui_languages" 2>/dev/null || true)"
    die "Usage: lifeagents household add <vorname> <nachname> <geburtsdatum YYYY-MM-DD> <rolle owner|partner|child> [sprache ${_codes:-code}]"
  fi
  local first="$1" last="$2" bdate="$3" role="$4" lang="${5:-}"
  case "$role" in owner|partner|child) ;; *) die "Ungueltige rolle '$role' (erwarte owner|partner|child)." ;; esac
  _hh_call_fn fn_add_household_person \
    "jsonb_build_object('first_name','$(_hh_sql_lit "$first")','last_name','$(_hh_sql_lit "$last")','birth_date','$(_hh_sql_lit "$bdate")','role','$(_hh_sql_lit "$role")','language',NULLIF('$(_hh_sql_lit "$lang")',''))"
  [ "$HH_OK" = "true" ] || die "Anlegen abgelehnt: ${HH_REASON:-unbekannter Grund}."
  ok "Person angelegt: ${first} ${last} (${role}${lang:+, Sprache $lang}), person_id='${HH_DETAIL}'."
}

# --- remove: Person loeschen ---------------------------------------------------------------------
household_cmd_remove() {
  # Missing-Arg-Picker (E3): Personen-Liste; der fn-Guard (Owner/FK-referenziert) bleibt dahinter (E8-Klasse).
  if [ "$#" -lt 1 ] && ui_interactive; then
    ensure_gum
    local _pick
    _pick="$(_hh_person_rows | ui_choose 'Person loeschen (Owner/referenzierte Personen lehnt die DB ab):' 0)"
    [ -n "$_pick" ] && set -- "$_pick"
  fi
  if [ "$#" -lt 1 ]; then die "Usage: lifeagents household remove <person_id>"; fi
  local pid="$1"
  _hh_slug_ok "$pid" || die "Ungueltige person_id (erwarte ^[a-z0-9_]+\$): $pid"
  _hh_call_fn fn_remove_household_person "jsonb_build_object('person_id','$(_hh_sql_lit "$pid")')"
  [ "$HH_OK" = "true" ] || die "Loeschen abgelehnt: ${HH_REASON:-unbekannter Grund}."
  ok "Person '${pid}' geloescht."
}

# --- unlink: Telegram-ID von einer Person trennen ------------------------------------------------
household_cmd_unlink() {
  # Missing-Arg-Picker (E3): nur Personen MIT Telegram-Verknuepfung (unlink-Kandidaten).
  if [ "$#" -lt 1 ] && ui_interactive; then
    ensure_gum
    local _pick
    _pick="$(_hh_person_rows 1 | ui_choose 'Telegram-ID von welcher Person trennen?' 0)"
    [ -n "$_pick" ] && set -- "$_pick"
  fi
  if [ "$#" -lt 1 ]; then die "Usage: lifeagents household unlink <person_id>"; fi
  local pid="$1"
  _hh_slug_ok "$pid" || die "Ungueltige person_id (erwarte ^[a-z0-9_]+\$): $pid"
  _hh_call_fn fn_unlink_member_identity "jsonb_build_object('person_id','$(_hh_sql_lit "$pid")')"
  [ "$HH_OK" = "true" ] || die "Entknuepfen abgelehnt: ${HH_REASON:-unbekannter Grund}."
  ok "Telegram-ID ${HH_DETAIL} von '${pid}' getrennt. Die Person kann per neuer Einladung re-verbunden werden."
}

# --- block: unbekannten Anklopfer sperren --------------------------------------------------------
household_cmd_block() {
  if [ "$#" -lt 1 ]; then die "Usage: lifeagents household block <telegram_user_id> [grund]"; fi
  local uid="$1"; shift
  _hh_num_ok "$uid" || die "Ungueltige telegram_user_id (erwarte rein numerisch): $uid"
  local reason="$*" rfrag=""
  [ -n "$reason" ] && rfrag=",'reason','$(_hh_sql_lit "$reason")'"
  _hh_call_fn fn_block_knocker "jsonb_build_object('telegram_user_id','${uid}'${rfrag})"
  [ "$HH_OK" = "true" ] || die "Sperren abgelehnt: ${HH_REASON:-unbekannter Grund}."
  ok "Identitaet ${uid} gesperrt (keine Owner-Notiz mehr + kein Pairing)."
}

# --- unblock: Sperre aufheben --------------------------------------------------------------------
household_cmd_unblock() {
  # Missing-Arg-Picker (E3): Auswahl aus der Sperrliste. (`block` bleibt bewusst picker-los —
  # fuer einen noch-nicht-geblockten Anklopfer existiert keine Enumerationsquelle.)
  if [ "$#" -lt 1 ] && ui_interactive; then
    ensure_gum
    local _pick
    _pick="$(_hh_psql -tA -F $'\t' -c \
      "SELECT telegram_user_id || '   gesperrt ' || to_char(blocked_at,'YYYY-MM-DD') || ' (' || COALESCE(reason,'-') || ')', telegram_user_id
       FROM agent.access_blocks ORDER BY blocked_at" 2>/dev/null \
      | ui_choose 'Sperre aufheben fuer:' 0 || true)"
    [ -n "$_pick" ] && set -- "$_pick"
  fi
  if [ "$#" -lt 1 ]; then die "Usage: lifeagents household unblock <telegram_user_id>"; fi
  local uid="$1"
  _hh_num_ok "$uid" || die "Ungueltige telegram_user_id (erwarte rein numerisch): $uid"
  _hh_call_fn fn_unblock_knocker "jsonb_build_object('telegram_user_id','${uid}')"
  [ "$HH_OK" = "true" ] || die "Entsperren abgelehnt: ${HH_REASON:-unbekannter Grund}."
  if [ "$HH_DETAIL" = "true" ]; then ok "Identitaet ${uid} entsperrt."; else ok "Identitaet ${uid} war nicht gesperrt (nichts zu tun)."; fi
}

# --- blocked: gesperrte Identitaeten anzeigen ----------------------------------------------------
household_cmd_blocked() {
  local rows
  rows="$(_hh_psql -tA -F $'\t' -c \
    "SELECT telegram_user_id, to_char(blocked_at,'YYYY-MM-DD HH24:MI'), COALESCE(reason,'-')
     FROM agent.access_blocks ORDER BY blocked_at")" \
    || die "Sperrlisten-Abfrage fehlgeschlagen (Schema angewandt?)."
  printf '%-16s %-18s %s\n' "TELEGRAM_ID" "GESPERRT_AM" "GRUND"
  if [ -z "$rows" ]; then log "Keine gesperrten Identitaeten."; return 0; fi
  printf '%s\n' "$rows" | while IFS=$'\t' read -r uid at reason; do
    printf '%-16s %-18s %s\n' "$uid" "$at" "$reason"
  done
}

# --- pair-owner: den Owner mit Telegram verbinden (Erstverbindung ODER Re-Link nach `unlink <owner>`) ---
# Install-UX-Phase 3: derselbe gefuehrte Ablauf wie am Ende der Installation (owner_connect_guided —
# ein Code-Pfad, zwei Aufrufer): Erreichbarkeit pruefen (ggf. Caddyfile + "Erneut pruefen/Spaeter"),
# Deep-Link t.me/<bot>?start=<code> zeigen, auf /start warten, danach den Bot auf die chat_id einstellen.
# Ein bereits verbundener Owner wird abgelehnt (fn_arm_pairing_challenge lehnt ihn ab) — Re-Link erst nach
# `unlink`. Der Code laeuft ueber den 600-Treiber (bootstrap_owner._arm_owner_challenge), nie im argv.
household_cmd_pair_owner() {
  local chat
  ui_interactive || die "pair-owner braucht ein Terminal (der Ablauf zeigt einen Link und wartet auf deine Telegram-Nachricht)."
  _pkg_resolve_env
  load_install_env
  chat="$(_owner_chat_id_db)"
  if _oc_is_chat_id "$chat"; then
    die "Der Owner ist bereits mit Telegram verbunden. Für ein anderes Telegram-Konto erst 'lifeagents household unlink <owner-person-id>'."
  fi
  ensure_gum
  owner_connect_guided
  case "$OWNER_CONNECT_RESULT" in
    connected)
      # Install-UX-Phase 6: owner_connect_guided hat ggf. schon die Begruessung geschickt (OWNER_WELCOME_SENT).
      if [ "${OWNER_WELCOME_SENT:-0}" = 1 ]; then
        ok 'Fertig — dein Bot hat dir in Telegram geschrieben; tippe dort „Haushalt einrichten" (oder /onboarding).'
      else
        ok "Fertig — schreib deinem Bot in Telegram /start; er zeigt dir den nächsten Schritt."
      fi ;;
    unavailable) die "Verbinden nicht möglich: ${OWNER_CONNECT_REASON:-Voraussetzung fehlt}${OWNER_CONNECT_FIX:+ — ${OWNER_CONNECT_FIX}}." ;;
    *)           log "Nicht verbunden${OWNER_CONNECT_REASON:+ (${OWNER_CONNECT_REASON})} — später erneut: lifeagents household pair-owner" ;;
  esac
}

# --- Dispatcher: `lifeagents household <verb> [args]` --------------------------------------------
household_cli() {
  # Verb-Picker: nacktes `lifeagents household` auf TTY -> Menue statt Hilfetext; ESC/non-TTY ->
  # Hilfetext wie bisher (Exit 0, E5b). `add`/`block` verlangen danach weiter getippte Argumente
  # (Freitext/keine Enumerationsquelle) — deren Usage-Meldung nennt die Syntax.
  if [ "$#" -eq 0 ] && ui_interactive; then
    ensure_gum
    local _menu_verb
    _menu_verb="$(ui_choose 'lifeagents household — was tun?' 0 <<'MENU'
list — Personen + Telegram-Verknuepfung anzeigen	list
add — Person anlegen (braucht getippte Angaben)	add
remove — Person löschen (Auswahl-Liste)	remove
unlink — Telegram-ID trennen (Auswahl-Liste)	unlink
pair-owner — Owner mit Telegram verbinden (geführt)	pair-owner
block — Anklopfer sperren (braucht getippte ID)	block
unblock — Sperre aufheben (Auswahl-Liste)	unblock
blocked — Gesperrte Identitaeten anzeigen	blocked
help — Hilfe anzeigen	help
MENU
)"
    [ -n "$_menu_verb" ] && set -- "$_menu_verb"
  fi
  local verb="${1:-help}"; shift || true
  case "$verb" in
    list)    household_cmd_list "$@" ;;
    add)     household_cmd_add "$@" ;;
    remove)  household_cmd_remove "$@" ;;
    unlink)  household_cmd_unlink "$@" ;;
    block)   household_cmd_block "$@" ;;
    unblock) household_cmd_unblock "$@" ;;
    blocked) household_cmd_blocked "$@" ;;
    pair-owner) household_cmd_pair_owner "$@" ;;
    help|--help|-h)
      cat >&2 <<'EOF'
lifeagents household <verb> — Owner-Lifecycle am Haushalt (Personen + Knocker-Sperre).

  list                                   Haushalts-Personen + Telegram-Verknuepfung (read-only).
  add <vorname> <nachname> <geburtsdatum> <rolle>
                                         Person anlegen ("Geburt"). rolle = owner|partner|child.
  remove <person_id>                     Person löschen ("Tod"). Abgelehnt, solange finance-Daten
                                         (Konten/Kredite/…) sie referenzieren; Owner nicht loeschbar.
  unlink <person_id>                     Telegram-ID von einer Person trennen (neues Konto) -> danach
                                         per Einladung (Mitglied) bzw. pair-owner (Owner) re-verbindbar.
  pair-owner                             Owner mit Telegram verbinden (geführt: Erreichbarkeit prüfen, Link
                                         zeigen, auf /start warten; auch Re-Link nach unlink). Braucht ein Terminal.
  block <telegram_user_id> [grund]       Unbekannten Anklopfer sperren (keine Notiz mehr + kein Pairing).
  unblock <telegram_user_id>             Sperre aufheben.
  blocked                                Gesperrte Identitaeten anzeigen (read-only).

Sperren/Entsperren geht auch per Telegram-Button (an der "Unbekannter hat angeschrieben"-Meldung).
Löschen des Owners (remove) ist blockiert; entknuepfen (unlink) + pair-owner sind erlaubt.
EOF
      ;;
    *) err "lifeagents household: unbekannter Verb: $verb"; household_cli help; return 1 ;;
  esac
}
