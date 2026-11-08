#!/usr/bin/env bash
# bot_username_cases.sh — Fall-Runner von scripts/dev/bot_profile_photo_test.ps1, laeuft IM Container (bash/curl/jq/node).
#
# Faehrt den echten Installer-Schritt _sync_bot_username (provisioning/lib/deploy_workflows.sh) gegen den Mock
# tests/mock_telegram/server.js. Die Datenbank ist ein Stub, der die SQL mitschreibt; die Regeln der fn prueft
# tests/db/core/test_fn_set_bot_username.sql.
#
# Usage: bash bot_username_cases.sh <root> <port>     Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2034,SC2329  # Stubs in den Subshells gelten fuer die gesourcten Funktionen, die sie rufen
set -uo pipefail
ROOT="$1"; PORT="$2"
W=/tmp/bot_username_test
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }

# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/deploy_workflows.sh"

rm -rf "$W"; mkdir -p "$W/mock"; cp "$ROOT/mock_telegram/server.js" "$W/mock/server.js"
LOG="$W/requests.jsonl"
N8NTEST_MOCK_TG_PORT="$PORT" N8NTEST_MOCK_TG_LOG="$LOG" node "$W/mock/server.js" >/dev/null 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 25); do curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 || { fail setup 'Mock antwortet nicht'; exit 1; }

TOKEN='1000001:MARKERTOKENzz9'
SQL="$W/sql.log"
export LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$PORT" N8N_DB_NAME=testdb
pg_su_psql() { printf '%s\n' "$*" >> "$SQL"; }

reset_case() { : > "$SQL"; : > "$LOG"; curl -sf "http://127.0.0.1:$PORT/__fail?method=getMe&off=1" >/dev/null; }
writes() { local n; n="$(grep -c 'fn_set_bot_username' "$SQL" 2>/dev/null)"; printf '%s' "${n:-0}"; }
run() { OUT="$( ( set -euo pipefail; _sync_bot_username "$TOKEN"; echo RC_REACHED ) 2>&1 )"; RC=$?; }

# --- Name aus getMe wird eingetragen
reset_case; run
eq 'getme-ok: Rueckgabe 0' 0 "$RC"
eq 'getme-ok: genau ein Eintrag' 1 "$(writes)"
eq 'getme-ok: Name aus getMe' 1 "$(grep -c "fn_set_bot_username('mock_test_bot')" "$SQL")"

# --- getMe scheitert: nichts schreiben, Lauf geht weiter
reset_case; curl -sf "http://127.0.0.1:$PORT/__fail?method=getMe" >/dev/null; run
eq 'getme-fehler: Rueckgabe 0' 0 "$RC"; eq 'getme-fehler: kein Eintrag' 0 "$(writes)"
LEAK_FAIL="$OUT"

reset_case
OUT="$( ( set -euo pipefail; LIFEAGENTS_TELEGRAM_API=http://127.0.0.1:9; _sync_bot_username "$TOKEN"; echo RC_REACHED ) 2>&1 )"; RC=$?
eq 'kein-netz: Rueckgabe 0' 0 "$RC"; eq 'kein-netz: kein Eintrag' 0 "$(writes)"
LEAK_NET="$OUT"

# --- Schiefe Namen erreichen die SQL nie
for name in "x'; DROP TABLE core.config; --" 'ab' 'mit leer zeichen' ''; do
  reset_case
  OUT="$( ( set -euo pipefail
            tg_api_curl() { jq -cn --arg u "$name" '{ok:true,result:{username:$u}}'; }
            _sync_bot_username "$TOKEN"; echo RC_REACHED ) 2>&1 )"; RC=$?
  eq "schief '$name': Rueckgabe 0" 0 "$RC"; eq "schief '$name': kein Eintrag" 0 "$(writes)"
done
reset_case
OUT="$( ( set -euo pipefail
          tg_api_curl() { jq -cn '{ok:true,result:{username:"muster_bot\nzweite"}}'; }
          _sync_bot_username "$TOKEN"; echo RC_REACHED ) 2>&1 )"; RC=$?
eq 'schief Zeilenumbruch: kein Eintrag' 0 "$(writes)"

# --- Der Schluessel taucht nirgends auf
reset_case; run
case "$OUT$LEAK_FAIL$LEAK_NET" in
  *MARKERTOKENzz9*) fail 'schluessel: Ausgabe' 'Bot-Schluessel steht in der Ausgabe' ;;
  *) pass 'schluessel: Ausgabe' ;;
esac
if grep -q MARKERTOKENzz9 "$SQL"; then fail 'schluessel: SQL' 'Bot-Schluessel in der SQL'; else pass 'schluessel: SQL'; fi

# --- Eingehaengt: der Schritt laeuft in _set_bot_command_menus vor den Knoepfen
reset_case
printf '{"languages":{"list":[]}}\n' > "$W/manifest.json"
OUT="$( ( set -euo pipefail
          _bot_command_manifests() { printf '%s\n' "$W/manifest.json"; }
          _resolve_owner_chat_id() { echo 0; }
          _bot_menu_cmds() { echo '[]'; }
          _push_bot_commands() { :; }
          _set_bot_menu_buttons() { printf 'BUTTONS writes=%s\n' "$(writes)"; }
          _set_bot_command_menus "$TOKEN"; echo RC_REACHED ) 2>&1 )"; RC=$?
eq 'eingehaengt: Rueckgabe 0' 0 "$RC"
eq 'eingehaengt: vor den Knoepfen' 1 "$(printf '%s' "$OUT" | grep -c 'BUTTONS writes=1')"

exit "$fails"
