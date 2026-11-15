#!/usr/bin/env bash
# backup_notify_cases.sh — Fall-Runner von scripts/dev/bot_menu_test.ps1, laeuft IM Container (bash/curl/jq/node).
#
# Prueft gegen den Mock tests/mock_telegram/server.js die Kopie der Sicherung im Owner-Chat (_bkp_notify_telegram):
#   - Text aus dem Textkatalog in der Sprache des Owners (erstes Mal lang, danach kurz), kein fester Text im Skript;
#   - stumm gesendet (disable_notification); nur die neueste Datei im Chat (die alte wird erst nach dem Erfolg geloescht,
#     ein Fehler dabei oder beim Senden kippt nie den Export);
#   - ungepairt, > 50 MB, Versand scheitert: kein Absturz, Merker unveraendert; Sicherung im Rechner-Ordner geht nie in den Chat.
# Die Datenbank ist ein Stub.
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
export LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$PORT" N8N_DB_NAME=testdb TELEGRAM_BOT_TOKEN="$TOKEN"
_bkp_resolve_db() { :; }
CHAT=111
_resolve_owner_chat_id() { echo "$CHAT"; }
FILE="$W/lifeagents-backup-20261115033000-k0000000a-v0.46.0.nla.enc"
head -c 2048 /dev/zero > "$FILE"
catalog() { pkg_text core "backup.notify.$1" "${2:-de}"; }
state() { read_env_value "$BACKUP_STATE_FILE" "$1" 2>/dev/null || true; }
docs() { jq -c "select(.method==\"$1\")" "$LOG" 2>/dev/null; }
ndocs() { docs "$1" | grep -c . || true; }
fault() { curl -sf "http://127.0.0.1:$PORT/__fail?$1" >/dev/null; }
reset_case() {
  : > "$LOG"; rm -f "$BACKUP_STATE_FILE"; _BACKUP_LANG=de; CHAT=111
  for m in sendDocument deleteMessage; do curl -sf "http://127.0.0.1:$PORT/__fail?method=$m&off=1" >/dev/null; done
}
send() { OUT="$( ( _bkp_notify_telegram "$FILE" ) 2>&1 )"; RC=$?; }

# --- erstes Mal
reset_case; send
eq 'erstes Mal: rc 0' 0 "$RC"
eq 'erstes Mal: ein sendDocument' 1 "$(ndocs sendDocument)"
J="$(docs sendDocument | head -n1)"
eqc 'erstes Mal: Text = Katalog (lang, de)' "$(catalog doc_first de)" "$(printf '%s' "$J" | jq -r '.body.caption')"
eq 'erstes Mal: stumm' true "$(printf '%s' "$J" | jq -r '.body.disable_notification')"
eq 'erstes Mal: Dateiname bleibt (Schluessel-ID + Version im Namen)' "$(basename "$FILE")" "$(printf '%s' "$J" | jq -r '.body.doc_name')"
eq 'erstes Mal: Owner-Chat' "$CHAT" "$(printf '%s' "$J" | jq -r '.body.chat_id')"
eq 'erstes Mal: nichts zu loeschen' 0 "$(ndocs deleteMessage)"
eq 'erstes Mal: erklaert-Merker gesetzt' 1 "$(state NOTIFY_EXPLAINED)"
eq 'erstes Mal: Nachricht gemerkt' "${CHAT}:$(printf '%s' "$J" | jq -r '.result_message_id')" "$(state NOTIFY_DOC)"
hasnt 'erstes Mal: kein Schluessel in der Ausgabe' MARKERTOKEN "$OUT"
hasnt 'erstes Mal: "Off-Site" nirgends in der Ausgabe' 'Off-Site' "$OUT"

# --- Folgetage: kurz, neue Datei zuerst, dann die alte weg
send
eq 'Folgetag: zwei sendDocument' 2 "$(ndocs sendDocument)"
J2="$(docs sendDocument | tail -n1)"
eqc 'Folgetag: Text = Katalog (kurz)' "$(catalog doc_next de)" "$(printf '%s' "$J2" | jq -r '.body.caption')"
eq 'Folgetag: ein deleteMessage' 1 "$(ndocs deleteMessage)"
eq 'Folgetag: geloescht wird die alte Nachricht' "$(printf '%s' "$J" | jq -r '.result_message_id')" "$(docs deleteMessage | jq -r '.body.message_id')"
eq 'Folgetag: neue Nachricht gemerkt' "${CHAT}:$(printf '%s' "$J2" | jq -r '.result_message_id')" "$(state NOTIFY_DOC)"
LAST_SEND="$(grep -n '"method":"sendDocument"' "$LOG" | tail -n1 | cut -d: -f1)"
DEL="$(grep -n '"method":"deleteMessage"' "$LOG" | head -n1 | cut -d: -f1)"
if [ "$DEL" -gt "$LAST_SEND" ]; then pass 'Folgetag: geloescht erst nach dem Senden'; else fail 'Folgetag: Reihenfolge' "send=$LAST_SEND delete=$DEL"; fi

# --- Loeschen scheitert: Export unberuehrt, neue Nachricht trotzdem gemerkt
reset_case; send
fault 'method=deleteMessage&code=400&desc=Bad%20Request%3A%20message%20to%20delete%20not%20found'; send
eq 'Loeschen scheitert: rc 0' 0 "$RC"
eq 'Loeschen scheitert: neue Nachricht gemerkt' "${CHAT}:$(docs sendDocument | tail -n1 | jq -r '.result_message_id')" "$(state NOTIFY_DOC)"
hasnt 'Loeschen scheitert: keine Warnung (still)' '[!]' "$OUT"

# --- Versand scheitert: nichts loeschen, Merker bleibt
reset_case; send; PREV="$(state NOTIFY_DOC)"; N_DEL="$(ndocs deleteMessage)"
fault 'method=sendDocument&code=502&desc=Bad%20Gateway'; send
eq 'Versand scheitert: rc 0' 0 "$RC"
eq 'Versand scheitert: nichts geloescht' "$N_DEL" "$(ndocs deleteMessage)"
eq 'Versand scheitert: Merker unveraendert' "$PREV" "$(state NOTIFY_DOC)"
has 'Versand scheitert: Grund im Protokoll' 'HTTP 502' "$OUT"
hasnt 'Versand scheitert: kein Schluessel in der Ausgabe' MARKERTOKEN "$OUT"

# --- Versand: erster Versuch scheitert, der zweite klappt (ein Wiederholversuch wie bei jedem Telegram-Aufruf)
reset_case; fault 'method=sendDocument&code=429&retry_after=1&desc=Too%20Many%20Requests&times=1'; send
eq 'Wiederholversuch: rc 0' 0 "$RC"
eq 'Wiederholversuch: zwei sendDocument-Aufrufe' 2 "$(ndocs sendDocument)"
eq 'Wiederholversuch: Nachricht gemerkt' "${CHAT}:$(docs sendDocument | tail -n1 | jq -r '.result_message_id')" "$(state NOTIFY_DOC)"
has 'Wiederholversuch: Protokoll nennt den ersten Fehlschlag' 'HTTP 429' "$OUT"

# --- ungepairt, zu gross
reset_case; CHAT=0; send
eq 'ungepairt: rc 0' 0 "$RC"
eq 'ungepairt: kein Telegram-Aufruf' 0 "$(ndocs sendDocument)"
reset_case; BIG="$W/big.nla.enc"; truncate -s 51M "$BIG"; OUT="$( ( _bkp_notify_telegram "$BIG" ) 2>&1 )"; RC=$?; rm -f "$BIG"
eq '> 50 MB: rc 0' 0 "$RC"
eq '> 50 MB: kein Telegram-Aufruf' 0 "$(ndocs sendDocument)"

# --- Sprachen
for L in en ko; do
  reset_case; _BACKUP_LANG="$L"; send
  eqc "Sprache $L: Text = Katalog" "$(catalog doc_first "$L")" "$(docs sendDocument | head -n1 | jq -r '.body.caption')"
done
if [ -n "$(catalog doc_first ko)" ] && [ -n "$(catalog doc_next en)" ]; then pass 'Katalog: Texte in allen Sprachen vorhanden'; else fail 'Katalog' 'doc_first ko oder doc_next en leer'; fi
hasnt 'Katalog: Text ohne "Off-Site"' 'Off-Site' "$(catalog doc_first de)$(catalog doc_next de)"

# --- Skript: kein fester Text, Rechner-Ordner nie in den Chat
SRC="$ROOT/provisioning/lib/backup_cli.sh"
hasnt 'Skript: kein fester Kopie-Text mehr' 'n8n-life-agents Off-Site' "$(cat "$SRC")"
hasnt 'Skript: "Off-Site" kommt nicht mehr vor' 'Off-Site' "$(cat "$SRC")"
# shellcheck disable=SC2016  # das Suchmuster nennt den Aufruf wortwoertlich, nichts soll expandieren
N="$(grep -n '_bkp_notify_telegram "\$out"' "$SRC" | head -n1 | cut -d: -f1)"
case "$(sed -n "$((N - 3)),${N}p" "$SRC")" in
  *want_host*) pass 'Skript: Versand nur ohne Rechner-Ordner (want_host)' ;;
  *) fail 'Skript: Rechner-Ordner' 'want_host-Pruefung vor dem Versand fehlt' ;;
esac

exit "$fails"
