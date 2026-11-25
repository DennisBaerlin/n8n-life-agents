#!/usr/bin/env bash
# backup_notify_cases.sh — Fall-Runner von scripts/dev/bot_menu_test.ps1, laeuft IM Container (bash/curl/jq/node).
#
# Prueft gegen den Mock tests/mock_telegram/server.js die Kopie der Sicherung im Owner-Chat (_bkp_notify_telegram,
# _bkp_notify_reconcile, Schalter core.config cron_enable.backup_telegram_copy):
#   - eine angeheftete Nachricht; jede weitere Kopie tauscht Datei + Text darin (editMessageMedia), keine neue Nachricht;
#   - neu angelegt nur bei echtem Verlust (feste Telegram-Fehlertexte), nie bei 5xx (kein Duplikat);
#   - an-/losgeheftet nur beim Zustandswechsel, ein voruebergehender Fehler wird wiederholt; Knopf cron_off:backup_telegram_copy;
#   - Schalter aus (Abgleich oder Hand-Befehl): Aus-Text ohne Knopf, losgeheftet, die Datei bleibt; Schalter-Regel wie /reminders;
#   - Texte aus dem Textkatalog in der Sprache des Owners; ungepairt, > 50 MB, Versand scheitert: kein Absturz.
# Datenbank und Owner-Aufloesung sind Stubs.
# real-path-test: none (gegen die echte Bot-API ungeprueft: Hinweis beim Bearbeiten, genaue Fehlertexte, Bearbeiten nach > 48 h)
#
# Usage: bash backup_notify_cases.sh <root> <port>     Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2034,SC2329  # Stubs gelten fuer die gesourcten Funktionen, die sie rufen
set -uo pipefail
ROOT="$1"; PORT="$2"
W=/tmp/backup_notify_test
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "'$2' fehlt in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "'$2' steht in: $3" ;; *) pass "$1" ;; esac; }
# eqc: wie eq, aber ein leerer Katalogtext ist selbst ein Fehler (sonst passte "leer == leer").
eqc() { if [ -z "$2" ]; then fail "$1" 'Katalogtext fehlt'; else eq "$1" "$2" "$3"; fi; }

rm -rf "$W"; mkdir -p "$W/mock"; cp "$ROOT/mock_telegram/server.js" "$W/mock/server.js"
LOG="$W/requests.jsonl"
export LIFEAGENTS_LIB="$ROOT" BACKUP_STATE_FILE="$W/backup.state" LIFEAGENTS_DIR="$W/etc"
mkdir -p "$LIFEAGENTS_DIR"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/deploy_workflows.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/backup_cli.sh"

N8NTEST_MOCK_TG_PORT="$PORT" N8NTEST_MOCK_TG_LOG="$LOG" node "$W/mock/server.js" >/dev/null 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 25); do curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 || { fail setup 'Mock antwortet nicht'; exit 1; }

TOKEN='1000001:MARKERTOKENzz9'
# LIFEAGENTS_TG_RETRY_MAX=0: der eine Wiederholversuch von _tg_post wartet nicht (die Fehler-Faelle schalten den Fehler dauerhaft).
# hand-injected: N8N_DB_NAME kommt im echten Weg aus der n8n-Env-Datei, die DB ist hier ein Stub; RETRY_MAX nur gegen Wartezeit.
export LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$PORT" N8N_DB_NAME=testdb TELEGRAM_BOT_TOKEN="$TOKEN" LIFEAGENTS_TG_RETRY_MAX=0
_bkp_resolve_db() { :; }
CHAT=111
_resolve_owner_chat_id() { echo "$CHAT"; }
# Stub der DB: Schalter (SWITCH: true|false|leer|err) und das Datum (fn_fmt_date -> 'D:<iso>', so ist das Quelldatum pruefbar).
SWITCH=true
_bkp_psql_scalar() {
  case "$1" in
    *backup_telegram_copy*) [ "$SWITCH" = err ] && return 2; printf '%s' "$SWITCH" ;;
    *fn_fmt_date*) printf 'D:%s' "$(printf '%s' "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1)" ;;
    *) return 2 ;;
  esac
}
FILE="$W/lifeagents-backup-20261115033000-k0000000a-v0.46.0.nla.enc"
head -c 2048 /dev/zero > "$FILE"
catalog() { pkg_text core "backup.notify.$1" "${2:-de}"; }
TODAY="$(TZ=Europe/Berlin date +%Y-%m-%d)"
capt() { catalog "$1" "${2:-de}" | sed "s/{date}/D:${3:-$TODAY}/g"; }
state() { read_env_value "$BACKUP_STATE_FILE" "$1" 2>/dev/null || true; }
docs() { jq -c "select(.method==\"$1\")" "$LOG" 2>/dev/null; }
ndocs() { docs "$1" | grep -c . || true; }
ncalls() { grep -c '"method":"[a-zA-Z]' "$LOG" || true; }
fault() { curl -sf "http://127.0.0.1:$PORT/__fail?$1" >/dev/null; }
unfault() { local m; for m in sendDocument deleteMessage editMessageMedia editMessageCaption pinChatMessage unpinChatMessage; do curl -sf "http://127.0.0.1:$PORT/__fail?method=$m&off=1" >/dev/null; done; }
reset_case() { : > "$LOG"; rm -f "$BACKUP_STATE_FILE"; _BACKUP_LANG=de; CHAT=111; SWITCH=true; unfault; }
clear_log() { : > "$LOG"; }
send() { OUT="$( ( _bkp_notify_telegram "$FILE" ) 2>&1 )"; RC=$?; }
reconcile() { OUT="$( ( _bkp_notify_reconcile ) 2>&1 )"; RC=$?; }
NOTFOUND='code=400&desc=Bad%20Request%3A%20message%20to%20edit%20not%20found'
OFFCB='cron_off:backup_telegram_copy'
kb_cb() { jq -r '.body.reply_markup | fromjson | .inline_keyboard[0][0].callback_data'; }

# --- erste Kopie: neue Nachricht, stumm, angeheftet, mit Knopf
reset_case; send
eq 'neu: rc 0' 0 "$RC"
eq 'neu: ein sendDocument' 1 "$(ndocs sendDocument)"
J="$(docs sendDocument | head -n1)"; MID="$(printf '%s' "$J" | jq -r '.result_message_id')"
eqc 'neu: Text = Katalog doc_pinned (de) mit Datum' "$(capt doc_pinned de)" "$(printf '%s' "$J" | jq -r '.body.caption')"
eq 'neu: stumm' true "$(printf '%s' "$J" | jq -r '.body.disable_notification')"
eq 'neu: Dateiname bleibt' "$(basename "$FILE")" "$(printf '%s' "$J" | jq -r '.body.doc_name')"
eq 'neu: Knopf cron_off' "$OFFCB" "$(printf '%s' "$J" | kb_cb)"
eqc 'neu: Knopf-Text = Katalog btn_off' "$(catalog btn_off de)" "$(printf '%s' "$J" | jq -r '.body.reply_markup | fromjson | .inline_keyboard[0][0].text')"
eq 'neu: einmal angeheftet' 1 "$(ndocs pinChatMessage)"
eq 'neu: angeheftet ohne Hinweis' true "$(docs pinChatMessage | jq -r '.body.disable_notification')"
eq 'neu: angeheftet wird die neue Nachricht' "$MID" "$(docs pinChatMessage | jq -r '.body.message_id')"
eq 'neu: Nachricht gemerkt' "${CHAT}:${MID}" "$(state NOTIFY_DOC)"
eq 'neu: Zustand an' on "$(state NOTIFY_SHOWN)"
hasnt 'neu: kein Schluessel in der Ausgabe' MARKERTOKEN "$OUT"

# --- Folgenacht: Austausch in derselben Nachricht, keine neue, nicht neu angeheftet
clear_log; send
eq 'Austausch: rc 0' 0 "$RC"
eq 'Austausch: kein sendDocument' 0 "$(ndocs sendDocument)"
eq 'Austausch: kein deleteMessage' 0 "$(ndocs deleteMessage)"
eq 'Austausch: kein pinChatMessage' 0 "$(ndocs pinChatMessage)"
eq 'Austausch: ein editMessageMedia' 1 "$(ndocs editMessageMedia)"
E="$(docs editMessageMedia | head -n1)"
eq 'Austausch: dieselbe Nachricht' "$MID" "$(printf '%s' "$E" | jq -r '.body.message_id')"
eq 'Austausch: Owner-Chat' "$CHAT" "$(printf '%s' "$E" | jq -r '.body.chat_id')"
eq 'Austausch: Datei angehaengt' "$(basename "$FILE")" "$(printf '%s' "$E" | jq -r '.body.doc_name')"
eq 'Austausch: media = Dokument' document "$(printf '%s' "$E" | jq -r '.body.media | fromjson | .type')"
eq 'Austausch: media zeigt auf den Anhang' 'attach://doc' "$(printf '%s' "$E" | jq -r '.body.media | fromjson | .media')"
eqc 'Austausch: Text = doc_pinned' "$(capt doc_pinned de)" "$(printf '%s' "$E" | jq -r '.body.media | fromjson | .caption')"
eq 'Austausch: Knopf bleibt' "$OFFCB" "$(printf '%s' "$E" | kb_cb)"
eq 'Austausch: Merker unveraendert' "${CHAT}:${MID}" "$(state NOTIFY_DOC)"

# --- "not modified" zaehlt als Erfolg
clear_log; fault 'method=editMessageMedia&code=400&desc=Bad%20Request%3A%20message%20is%20not%20modified'; send
eq 'not modified: kein sendDocument' 0 "$(ndocs sendDocument)"
eq 'not modified: Merker unveraendert' "${CHAT}:${MID}" "$(state NOTIFY_DOC)"
unfault

# --- 5xx: Warnung, kein Duplikat
clear_log; fault 'method=editMessageMedia&code=502&desc=Bad%20Gateway'; send
eq '5xx: rc 0' 0 "$RC"
eq '5xx: kein sendDocument (kein Duplikat)' 0 "$(ndocs sendDocument)"
eq '5xx: Merker unveraendert' "${CHAT}:${MID}" "$(state NOTIFY_DOC)"
has '5xx: Grund im Protokoll' 'HTTP 502' "$OUT"
unfault

# --- Nachricht weg: einmal neu und angeheftet
clear_log; fault "method=editMessageMedia&$NOTFOUND"; send
eq 'verloren: rc 0' 0 "$RC"
eq 'verloren: genau ein sendDocument' 1 "$(ndocs sendDocument)"
MID2="$(docs sendDocument | head -n1 | jq -r '.result_message_id')"
eq 'verloren: neue Nachricht angeheftet' "$MID2" "$(docs pinChatMessage | jq -r '.body.message_id')"
eq 'verloren: neue Nachricht gemerkt' "${CHAT}:${MID2}" "$(state NOTIFY_DOC)"
unfault
for d in 'message%20can%27t%20be%20edited' 'MESSAGE_ID_INVALID'; do
  clear_log; fault "method=editMessageMedia&code=400&desc=Bad%20Request%3A%20$d"; send
  eq "verloren ($d): genau ein sendDocument" 1 "$(ndocs sendDocument)"
  unfault
done

# --- Altbestand: NOTIFY_DOC ohne NOTIFY_SHOWN/NOTIFY_PINNED -> uebernehmen + einmal anheften, nichts neu
reset_case; _bkp_state_set NOTIFY_DOC "${CHAT}:4242"; _bkp_state_set NOTIFY_EXPLAINED 1; send
eq 'Umstellung: kein sendDocument' 0 "$(ndocs sendDocument)"
eq 'Umstellung: editMessageMedia auf die alte Nachricht' 4242 "$(docs editMessageMedia | jq -r '.body.message_id')"
eq 'Umstellung: einmal angeheftet' 1 "$(ndocs pinChatMessage)"
eq 'Umstellung: Zustand an' on "$(state NOTIFY_SHOWN)"
eq 'Umstellung: Merker ohne Leser entfernt' '' "$(state NOTIFY_EXPLAINED)"
clear_log; send
eq 'Umstellung: danach nicht erneut angeheftet' 0 "$(ndocs pinChatMessage)"

# --- Merker aus einem anderen Chat (neues Owner-Pairing): neu im aktuellen Chat, fremde Nachricht unberuehrt
reset_case; _bkp_state_set NOTIFY_DOC "999:77"; _bkp_state_set NOTIFY_SHOWN on; send
eq 'fremder Chat: kein editMessageMedia' 0 "$(ndocs editMessageMedia)"
eq 'fremder Chat: ein sendDocument im aktuellen Chat' "$CHAT" "$(docs sendDocument | jq -r '.body.chat_id')"
eq 'fremder Chat: fremde Nachricht nicht geloescht' 0 "$(ndocs deleteMessage)"

# --- Schalter aus: Abgleich zeigt einmal den Aus-Text, ohne Knopf, losgeheftet; Datei bleibt (kein Media-Tausch)
reset_case; send; MID="$(docs sendDocument | head -n1 | jq -r '.result_message_id')"; clear_log
SWITCH=false; reconcile
eq 'aus: rc 0' 0 "$RC"
eq 'aus: ein editMessageCaption' 1 "$(ndocs editMessageCaption)"
C="$(docs editMessageCaption | head -n1)"
eq 'aus: dieselbe Nachricht' "$MID" "$(printf '%s' "$C" | jq -r '.body.message_id')"
eqc 'aus: Text = doc_off mit Datum' "$(capt doc_off de)" "$(printf '%s' "$C" | jq -r '.body.caption')"
eq 'aus: Knopf weg' 0 "$(printf '%s' "$C" | jq -r '.body.reply_markup.inline_keyboard | length')"
eq 'aus: losgeheftet' "$MID" "$(docs unpinChatMessage | jq -r '.body.message_id')"
eq 'aus: keine Datei verschickt' 0 "$(( $(ndocs sendDocument) + $(ndocs editMessageMedia) ))"
eq 'aus: Zustand aus' off "$(state NOTIFY_SHOWN)"
clear_log; reconcile
eq 'aus: zweiter Abgleich ohne Telegram-Aufruf' 0 "$(ncalls)"

# --- Schalter an: Abgleich tut nichts; naechste Kopie tauscht + heftet wieder an
clear_log; SWITCH=true; reconcile
eq 'an: Abgleich ohne Telegram-Aufruf' 0 "$(ncalls)"
send
eq 'wieder an: Austausch in derselben Nachricht' "$MID" "$(docs editMessageMedia | jq -r '.body.message_id')"
eq 'wieder an: einmal angeheftet' 1 "$(ndocs pinChatMessage)"
eq 'wieder an: Knopf wieder da' "$OFFCB" "$(docs editMessageMedia | kb_cb)"
eq 'wieder an: Zustand an' on "$(state NOTIFY_SHOWN)"

# --- Abgleich: Nachricht weg -> Zustand aus; nie gesendet -> nichts; 5xx -> naechste Stunde erneut
reset_case; send; clear_log; SWITCH=false; fault "method=editMessageCaption&$NOTFOUND"; reconcile
eq 'aus, Nachricht weg: Zustand aus' off "$(state NOTIFY_SHOWN)"
unfault
reset_case; SWITCH=false; reconcile
eq 'aus, nie gesendet: kein Telegram-Aufruf' 0 "$(ncalls)"
reset_case; send; clear_log; SWITCH=false; fault 'method=editMessageCaption&code=502&desc=Bad%20Gateway'; reconcile
eq 'aus, 5xx: rc 0' 0 "$RC"
eq 'aus, 5xx: Zustand bleibt an' on "$(state NOTIFY_SHOWN)"
unfault

# --- Losheften scheitert voruebergehend: Zustand bleibt an, der naechste Abgleich holt es nach; 4xx gilt als erledigt
reset_case; send; MID="$(docs sendDocument | head -n1 | jq -r '.result_message_id')"; clear_log
SWITCH=false; fault 'method=unpinChatMessage&code=502&desc=Bad%20Gateway'; reconcile
eq 'Losheften 5xx: Zustand bleibt an' on "$(state NOTIFY_SHOWN)"
unfault; clear_log; fault 'method=editMessageCaption&code=400&desc=Bad%20Request%3A%20message%20is%20not%20modified'; reconcile
eq 'Losheften 5xx: naechster Abgleich heftet los' "$MID" "$(docs unpinChatMessage | jq -r '.body.message_id')"
eq 'Losheften 5xx: danach Zustand aus' off "$(state NOTIFY_SHOWN)"
unfault
reset_case; send; clear_log; SWITCH=false; fault 'method=unpinChatMessage&code=400&desc=Bad%20Request%3A%20message%20is%20not%20pinned'; reconcile
eq 'Losheften 4xx (schon losgeheftet): Zustand aus' off "$(state NOTIFY_SHOWN)"
unfault

# --- Anheften scheitert voruebergehend: naechste Kopie versucht es erneut; vom Owner losgeheftet (4xx) bleibt so
reset_case; fault 'method=pinChatMessage&code=502&desc=Bad%20Gateway'; send
eq 'Anheften 5xx: Nachricht trotzdem gemerkt' 1 "$(ndocs sendDocument)"
unfault; clear_log; send
eq 'Anheften 5xx: naechste Kopie heftet an' 1 "$(ndocs pinChatMessage)"
clear_log; send
eq 'Anheften erledigt: danach kein Anheften mehr' 0 "$(ndocs pinChatMessage)"

# --- Hand-Befehl bei Schalter aus: Datei getauscht, Aus-Text ohne Knopf, losgeheftet, nicht neu angeheftet
reset_case; send; MID="$(docs sendDocument | head -n1 | jq -r '.result_message_id')"; clear_log; SWITCH=false; send
E="$(docs editMessageMedia | head -n1)"
eq 'Hand aus: Datei in derselben Nachricht' "$MID" "$(printf '%s' "$E" | jq -r '.body.message_id')"
eqc 'Hand aus: Text = doc_off' "$(capt doc_off de)" "$(printf '%s' "$E" | jq -r '.body.media | fromjson | .caption')"
eq 'Hand aus: ohne Knopf' 0 "$(printf '%s' "$E" | jq -r '.body.reply_markup | fromjson | .inline_keyboard | length')"
eq 'Hand aus: nicht angeheftet' 0 "$(ndocs pinChatMessage)"
eq 'Hand aus: losgeheftet' "$MID" "$(docs unpinChatMessage | jq -r '.body.message_id')"
eq 'Hand aus: Zustand aus (Abgleich dreht nichts zurueck)' off "$(state NOTIFY_SHOWN)"
clear_log; reconcile
eq 'Hand aus: folgender Abgleich ohne Telegram-Aufruf' 0 "$(ncalls)"

# --- Altbestand ohne Datum: der Aus-Text nennt den Tag der letzten gelungenen Sicherung (Haushalts-Zeitzone)
reset_case; _bkp_state_set NOTIFY_DOC "${CHAT}:4242"; _bkp_state_set LAST_OK 1763170200; SWITCH=false; reconcile
eqc 'Altbestand aus: Datum = Tag von LAST_OK' "$(capt doc_off de 2025-11-15)" "$(docs editMessageCaption | jq -r '.body.caption')"

# --- Nachricht weg: neue zuerst, dann die alte loeschen; Loeschfehler bleibt still
reset_case; send; MID="$(docs sendDocument | head -n1 | jq -r '.result_message_id')"; clear_log
fault "method=editMessageMedia&$NOTFOUND"; fault 'method=deleteMessage&code=400&desc=Bad%20Request%3A%20message%20to%20delete%20not%20found'; send
eq 'neu + loeschen: alte Nachricht geloescht' "$MID" "$(docs deleteMessage | head -n1 | jq -r '.body.message_id')"
SENDL="$(grep -n '"method":"sendDocument"' "$LOG" | head -n1 | cut -d: -f1)"; DELL="$(grep -n '"method":"deleteMessage"' "$LOG" | head -n1 | cut -d: -f1)"
if [ -n "$SENDL" ] && [ -n "$DELL" ] && [ "$DELL" -gt "$SENDL" ]; then pass 'neu + loeschen: erst senden, dann loeschen'; else fail 'neu + loeschen: Reihenfolge' "send=$SENDL delete=$DELL"; fi
hasnt 'neu + loeschen: Loeschfehler ohne Warnung' '[!]' "$OUT"
unfault

# --- Versand: erster Versuch scheitert (429), der zweite klappt
reset_case; fault 'method=sendDocument&code=429&retry_after=1&desc=Too%20Many%20Requests&times=1'; send
eq 'Wiederholversuch: zwei sendDocument-Aufrufe' 2 "$(ndocs sendDocument)"
eq 'Wiederholversuch: Nachricht gemerkt' "${CHAT}:$(docs sendDocument | tail -n1 | jq -r '.result_message_id')" "$(state NOTIFY_DOC)"
has 'Wiederholversuch: Protokoll nennt den ersten Fehlschlag' 'HTTP 429' "$OUT"

# --- Schalter lesen: Regel wie /reminders (nur "true" = an, fehlende Zeile = aus); nur DB-Fehler = an; kein set-e-Abbruch
for v in true err; do
  SWITCH="$v"
  if ( set -e; _bkp_copy_enabled ); then pass "Schalter '$v' = an"; else fail "Schalter '$v'" 'gilt als aus'; fi
done
for v in false ''; do
  SWITCH="$v"
  if ( set -e; _bkp_copy_enabled ); then fail "Schalter '$v'" 'gilt als an'; else pass "Schalter '$v' = aus"; fi
done

# --- Versand scheitert (neu): Merker bleibt leer
reset_case; fault 'method=sendDocument&code=502&desc=Bad%20Gateway'; send
eq 'Versand scheitert: rc 0' 0 "$RC"
eq 'Versand scheitert: kein Merker' '' "$(state NOTIFY_DOC)"
has 'Versand scheitert: Grund im Protokoll' 'HTTP 502' "$OUT"
hasnt 'Versand scheitert: kein Schluessel in der Ausgabe' MARKERTOKEN "$OUT"
unfault

# --- ungepairt, zu gross
reset_case; CHAT=0; send
eq 'ungepairt: rc 0' 0 "$RC"
eq 'ungepairt: kein Telegram-Aufruf' 0 "$(ncalls)"
reset_case; BIG="$W/big.nla.enc"; truncate -s 51M "$BIG"; OUT="$( ( _bkp_notify_telegram "$BIG" ) 2>&1 )"; RC=$?; rm -f "$BIG"
eq '> 50 MB: rc 0' 0 "$RC"
eq '> 50 MB: kein Telegram-Aufruf' 0 "$(ndocs sendDocument)"

# --- Sprachen
for L in en ko; do
  reset_case; _BACKUP_LANG="$L"; send
  eqc "Sprache $L: Text = Katalog" "$(capt doc_pinned "$L")" "$(docs sendDocument | head -n1 | jq -r '.body.caption')"
  eqc "Sprache $L: Knopf = Katalog" "$(catalog btn_off "$L")" "$(docs sendDocument | head -n1 | jq -r '.body.reply_markup | fromjson | .inline_keyboard[0][0].text')"
done
for L in de en ko; do
  if [ -n "$(catalog doc_off "$L")" ] && [ -n "$(pkg_text core cron.backup_telegram_copy.label "$L")" ]; then pass "Katalog $L: doc_off + Label"; else fail "Katalog $L" 'doc_off oder Label leer'; fi
done
if [ -z "$(catalog doc_next de)$(catalog doc_first de)" ]; then pass 'Katalog: alte Texte doc_first/doc_next entfernt'; else fail 'Katalog' 'doc_first/doc_next noch da'; fi

# --- Einstiege: Abgleich zuerst, Kopie nur mit Schalter (Docker auch mit Rechner-Ordner)
SRC="$ROOT/provisioning/lib/backup_cli.sh"
body_of() { awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$SRC"; }
for fn in backup_cmd_auto _bkp_auto_local; do
  first="$(body_of "$fn" | grep -m1 -E '_bkp_notify_reconcile|_bkp_auto_due|_bkp_auto_local_run|backup_cmd_export|_bkp_host_dir')"
  has "$fn: Abgleich vor jeder Verzweigung" '_bkp_notify_reconcile' "$first"
done
has 'backup_cmd_auto: Kopie nur mit Schalter' '_bkp_copy_enabled' "$(body_of backup_cmd_auto)"
has '_bkp_auto_local_run: Kopie nur mit Schalter' '_bkp_copy_enabled' "$(body_of _bkp_auto_local_run)"
hasnt 'export: Rechner-Ordner sperrt die Kopie nicht mehr' 'keine Kopie in den Telegram-Chat' "$(body_of backup_cmd_export)"
hasnt 'Skript: "Off-Site" kommt nicht vor' 'Off-Site' "$(cat "$SRC")"

exit "$fails"
