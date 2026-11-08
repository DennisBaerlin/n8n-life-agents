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
eq 'fehler: Rueckgabe 1 (Lauf gilt als gescheitert)' 1 "$RC"; eq 'fehler: nicht gemerkt' 0 "$(marks)"
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

# --- Ganzer Menue-Lauf: Merkliste, einmalige Ankuendigung, Bestandsnutzer ---------------------------------------------
R="$W/r"; ETC="$W/etc"; L="$W/latch"
mkdir -p "$R/packages/core/locales" "$R/packages/core/build/stickers" "$ETC" "$L"
cp "$W/core/locales/"* "$R/packages/core/locales/"; cp "$W/core/build/stickers/"* "$R/packages/core/build/stickers/"
printf 'WEBHOOK_URL=https://example.com/\n' > "$W/n8n.env"
export REPO_ROOT="$R" LIFEAGENTS_DIR="$ETC" N8N_ENV_FILE="$W/n8n.env" LIFEAGENTS_MENU_LOCK="$W/menu.lock"
LIST="$ETC/app-menu-chats"; READY="$W/ready"
_app_path() { echo app-1; }
pg_su_psql() {
  printf '%s\n' "$*" >> "$SQL"
  case "$*" in
    *fn_menu_refresh_claim*) echo 5 ;;
    *fn_app_button_ready*) printf 'cfg|true|household|1|%s\n111|owner|de||\n' "$(cat "$READY")" ;;
    *fn_app_intro_pending*)
      k="$(printf '%s' "$*" | sed -n "s/.*fn_app_intro_pending('\([^']*\)').*/\1/p")"
      if [ -e "$L/$k" ]; then echo f; else echo t; fi ;;
    *"fn_should_notify('app_intro'"*)
      k="$(printf '%s' "$*" | sed -n "s/.*'app_intro', '\([^']*\)').*/\1/p")"; : > "$L/$k" ;;
    *"fn_should_notify('app_button', 'ready')"*) echo true > "$READY" ;;
  esac
}
full_reset() { : > "$SQL"; : > "$LOG"; rm -f "$L"/* "$LIST"; echo false > "$READY"; curl -sf "http://127.0.0.1:$PORT/__fail?method=sendAnimation&off=1" >/dev/null; }
run_menu() { OUT="$( ( set -euo pipefail; _set_bot_menu_buttons_run "$TOKEN"; echo RC_REACHED ) 2>&1 )"; RC=$?; }
webapp_calls() { local n; n="$(grep '"method":"setChatMenuButton"' "$LOG" | grep -c '"web_app"')"; printf '%s' "${n:-0}"; }
finished() { grep -c "fn_menu_refresh_finish(5, $1)" "$SQL"; }
on_list() { if grep -qx 111 "$LIST" 2>/dev/null; then echo ja; else echo nein; fi; }
set_button() { curl -sf -H 'content-type: application/json' -d "{\"chat_id\":111,\"menu_button\":{\"type\":\"$1\"}}" "http://127.0.0.1:$PORT/bot$TOKEN/setChatMenuButton" >/dev/null; }

full_reset; run_menu
eq 'einrichtung-offen: Rueckgabe 0' 0 "$RC"; eq 'einrichtung-offen: kein Knopf' 0 "$(webapp_calls)"; eq 'einrichtung-offen: nicht auf der Merkliste' nein "$(on_list)"
echo true > "$READY"; : > "$LOG"; run_menu
eq 'fertig: Knopf' 1 "$(webapp_calls)"; eq 'fertig: genau eine Animation' 1 "$(calls)"; eq 'fertig: auf der Merkliste' ja "$(on_list)"
: > "$LOG"; run_menu
eq 'zweitlauf: keine zweite Animation' 0 "$(calls)"

# Versand scheitert: Lauf zaehlt als gescheitert, der naechste holt nach
full_reset; echo true > "$READY"; curl -sf "http://127.0.0.1:$PORT/__fail?method=sendAnimation" >/dev/null; run_menu
eq 'versand-fehler: Auftrag bleibt offen' 1 "$(finished false)"
curl -sf "http://127.0.0.1:$PORT/__fail?method=sendAnimation&off=1" >/dev/null; : > "$LOG"; run_menu
eq 'versand-fehler: naechster Lauf holt nach' 1 "$(calls)"; eq 'versand-fehler: danach geschlossen' 1 "$(finished true)"

# Bestand: alte Liste, Knopf bei Telegram nachweisbar, Einrichtung offen -> Knopf bleibt, keine Ankuendigung
full_reset; printf '111\n' > "$LIST"; set_button web_app; : > "$LOG"; run_menu
eq 'bestand-knopf: bleibt' 1 "$(webapp_calls)"; eq 'bestand-knopf: bereit gemerkt' true "$(cat "$READY")"; eq 'bestand-knopf: keine Animation' 0 "$(calls)"

# Alte Liste ohne Knopf bei Telegram: kein Nachweis
full_reset; printf '111\n' > "$LIST"; set_button commands; : > "$LOG"; run_menu
eq 'bestand-ohne-knopf: kein Knopf' 0 "$(webapp_calls)"; eq 'bestand-ohne-knopf: nicht bereit' false "$(cat "$READY")"

# Nachweis nur beim ersten Lauf: ein Reset nimmt den Knopf wirklich
full_reset; : > "$L/legacy_checked"; printf '111\n' > "$LIST"; set_button web_app; : > "$LOG"; run_menu
eq 'nach-reset: Knopf weg' 0 "$(webapp_calls)"; eq 'nach-reset: nicht bereit' false "$(cat "$READY")"

exit "$fails"
