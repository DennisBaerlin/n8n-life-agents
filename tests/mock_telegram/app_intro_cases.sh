#!/usr/bin/env bash
# app_intro_cases.sh — Fall-Runner von scripts/dev/bot_profile_photo_test.ps1, laeuft IM Container (bash/curl/jq/node).
#
# Faehrt _app_intro_announce (provisioning/lib/deploy_workflows.sh) gegen den Mock: einmal je Chat, Datei in der Sprache der
# Person, Bestandsnutzer ohne Nachricht, Fehlversand wird nicht gemerkt. Die Datenbank ist ein Stub; die Regeln der fn prueft
# tests/db/core/test_fn_app_button_state.sql.
#
# Usage: bash app_intro_cases.sh <root> <port>     Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2034,SC2329  # Stubs in den Subshells gelten fuer die gesourcten Funktionen, die sie rufen
set -uo pipefail
ROOT="$1"; PORT="$2"
W=/tmp/app_intro_test
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }

# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/deploy_workflows.sh"

rm -rf "$W"; mkdir -p "$W/mock" "$W/core/locales" "$W/core/build/stickers"; cp "$ROOT/mock_telegram/server.js" "$W/mock/server.js"
LOG="$W/requests.jsonl"
N8NTEST_MOCK_TG_PORT="$PORT" N8NTEST_MOCK_TG_LOG="$LOG" node "$W/mock/server.js" >/dev/null 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 25); do curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 || { fail setup 'Mock antwortet nicht'; exit 1; }

printf 'GIF89a-de' > "$W/core/build/stickers/app_intro_de.gif"
printf 'GIF89a-en' > "$W/core/build/stickers/app_intro_en.gif"
printf '{"core.app.intro_caption":"Bereit"}\n' > "$W/core/locales/de.json"
printf '{"core.app.intro_caption":"Ready"}\n' > "$W/core/locales/en.json"
TOKEN='1000001:MARKERTOKENzz9'
SQL="$W/sql.log"; PEND="$W/pending"
export LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$PORT" N8N_DB_NAME=testdb
pg_su_psql() { printf '%s\n' "$*" >> "$SQL"; case "$*" in *fn_app_intro_pending*) cat "$PEND" ;; esac; }

reset_case() { : > "$SQL"; : > "$LOG"; printf 't\n' > "$PEND"; curl -sf "http://127.0.0.1:$PORT/__fail?method=sendAnimation&off=1" >/dev/null; }
calls() { local n; n="$(grep -c '"method":"sendAnimation"' "$LOG" 2>/dev/null)"; printf '%s' "${n:-0}"; }
marks() { local n; n="$(grep -c "fn_should_notify('app_intro', '111')" "$SQL" 2>/dev/null)"; printf '%s' "${n:-0}"; }
run() { OUT="$( ( set -euo pipefail; _app_intro_announce "$TOKEN" 111 "$1" "$W/core/locales" "$2"; echo RC_REACHED ) 2>&1 )"; RC=$?; }

reset_case; run de 0
eq 'neu: Rueckgabe 0' 0 "$RC"; eq 'neu: eine Animation' 1 "$(calls)"; eq 'neu: gemerkt' 1 "$(marks)"

reset_case; printf 'f\n' > "$PEND"; run de 0
eq 'schon-angekuendigt: keine Animation' 0 "$(calls)"; eq 'schon-angekuendigt: nicht erneut gemerkt' 0 "$(marks)"

reset_case; run de 1
eq 'bestand: keine Animation' 0 "$(calls)"; eq 'bestand: gemerkt' 1 "$(marks)"

reset_case; curl -sf "http://127.0.0.1:$PORT/__fail?method=sendAnimation" >/dev/null; run de 0
eq 'fehler: Rueckgabe 0' 0 "$RC"; eq 'fehler: nicht gemerkt' 0 "$(marks)"
LEAK="$OUT"

# Fehlende Sprache: Englisch als Rueckfall
reset_case
fallback_out="$( ( tg_api_curl() { printf '%s\n' "$*" > "$W/args"; }; set -euo pipefail; _app_intro_announce "$TOKEN" 111 ko "$W/core/locales" 0 ) 2>&1 )"
if grep -q 'app_intro_en.gif' "$W/args"; then pass 'sprache: Rueckfall en'; else fail 'sprache: Rueckfall en' "$(cat "$W/args")"; fi
if grep -q 'caption=Ready' "$W/args"; then pass 'sprache: Text en'; else fail 'sprache: Text en' "$(cat "$W/args")"; fi

case "$OUT$LEAK$fallback_out" in
  *MARKERTOKENzz9*) fail 'schluessel: Ausgabe' 'Bot-Schluessel steht in der Ausgabe' ;;
  *) pass 'schluessel: Ausgabe' ;;
esac

exit "$fails"
