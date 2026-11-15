#!/usr/bin/env bash
# menu_once_cases.sh — Fall-Runner von scripts/dev/bot_profile_photo_test.ps1, laeuft IM Container (bash/curl/jq/node).
#
# Prueft gegen den Mock tests/mock_telegram/server.js, wie der Installer das Telegram-Menue setzt:
#   - ein Update-Lauf ueber mehrere Pakete setzt Menue, Bot-Name und Knoepfe genau einmal (am Ende), nicht je Paket;
#     Einzelpaket-Wechsel (lifeagents package ...) und refresh_bot_command_menus setzen weiter sofort;
#   - jeder Telegram-Aufruf bekommt genau einen Wiederholversuch (429: retry_after, gedeckelt);
#   - das Protokoll nennt HTTP-Code und Telegram-Beschreibung, nie Token oder App-Adresse.
# Die Datenbank ist ein Stub; die Regeln der Knoepfe prueft scripts/dev/bot_menu_test.ps1.
#
# Usage: bash menu_once_cases.sh <root> <port>     Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2034,SC2329  # Stubs gelten fuer die gesourcten Funktionen, die sie rufen
set -uo pipefail
ROOT="$1"; PORT="$2"
W=/tmp/menu_once_test
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "'$2' fehlt in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "'$2' steht in: $3" ;; *) pass "$1" ;; esac; }

# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/deploy_workflows.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/pkg_lifecycle.sh"

rm -rf "$W"; mkdir -p "$W/mock"; cp "$ROOT/mock_telegram/server.js" "$W/mock/server.js"
LOG="$W/requests.jsonl"
N8NTEST_MOCK_TG_PORT="$PORT" N8NTEST_MOCK_TG_LOG="$LOG" node "$W/mock/server.js" >/dev/null 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 25); do curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 || { fail setup 'Mock antwortet nicht'; exit 1; }

TOKEN='1000001:MARKERTOKENzz9'
SQL="$W/sql.log"; BTN="$W/buttons.log"
export LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$PORT" N8N_DB_NAME=testdb TELEGRAM_BOT_TOKEN="$TOKEN"
pg_su_psql() { printf '%s\n' "$*" >> "$SQL"; }
printf '{"name":"core","languages":{"list":[{"code":"de","ord":1},{"code":"en","ord":2}]},"commands":{"list":[{"cmd":"/help","visibility":"all"}]}}\n' > "$W/manifest.json"
_bot_command_manifests() { printf '%s\n' "$W/manifest.json"; }
_resolve_owner_chat_id() { echo 111; }
_set_bot_menu_buttons() { printf 'x\n' >> "$BTN"; }
_pkg_resolve_env() { :; }
refresh_capabilities_catalog() { :; }
fault() { curl -sf "http://127.0.0.1:$PORT/__fail?$1" >/dev/null; }
reset_case() { : > "$SQL"; : > "$LOG"; : > "$BTN"; unset LIFEAGENTS_MENU_DEFER LIFEAGENTS_TG_RETRY_MAX
  for m in setMyCommands getMyCommands getMe setChatMenuButton; do curl -sf "http://127.0.0.1:$PORT/__fail?method=$m&off=1" >/dev/null; done; }
calls() { local n; n="$(grep -c "\"method\":\"$1\"" "$LOG" 2>/dev/null)"; printf '%s' "${n:-0}"; }
btns() { local n; n="$(wc -l < "$BTN" | tr -d ' ')"; printf '%s' "${n:-0}"; }
writes() { local n; n="$(grep -c 'fn_set_bot_username' "$SQL" 2>/dev/null)"; printf '%s' "${n:-0}"; }

# --- Referenz: ein einzelnes Setzen
reset_case
( set -euo pipefail; _set_bot_command_menus "$TOKEN" ) >/dev/null 2>&1
BASE_CMDS="$(calls setMyCommands)"; BASE_ME="$(calls getMe)"; BASE_BTN="$(btns)"
eq 'referenz: sechs Menues (2 Sprachen x 2 Rollen + 2 Rueckfall)' 6 "$BASE_CMDS"
eq 'referenz: Bot-Name einmal' 1 "$BASE_ME"
eq 'referenz: Knoepfe einmal' 1 "$BASE_BTN"

# --- Update ueber drei Pakete: genau ein Setzen, am Ende
reset_case
( set -euo pipefail
  menus_defer_begin
  _set_bot_command_menus "$TOKEN"      # wie _wire_telegram vor den Paketen
  for _p in finance estate paperless; do _pkg_refresh_surfaces; done
  eq 'update: waehrend der Pakete noch nichts' 0 "$(calls setMyCommands)"
  menus_flush ) >/dev/null 2>&1
eq 'update: Menues wie ein Einzel-Setzen' "$BASE_CMDS" "$(calls setMyCommands)"
eq 'update: Bot-Name einmal' "$BASE_ME" "$(calls getMe)"
eq 'update: Knoepfe einmal' "$BASE_BTN" "$(btns)"

# --- Einzelpaket-Wechsel und refresh_bot_command_menus setzen sofort
reset_case
( set -euo pipefail; _pkg_refresh_surfaces ) >/dev/null 2>&1
eq 'einzelpaket: Menues sofort' "$BASE_CMDS" "$(calls setMyCommands)"
eq 'einzelpaket: Knoepfe sofort' "$BASE_BTN" "$(btns)"
reset_case
( set -euo pipefail; refresh_bot_command_menus ) >/dev/null 2>&1
eq 'refresh_bot_command_menus: Menues' "$BASE_CMDS" "$(calls setMyCommands)"

# --- Wiederholversuch: erster Versuch scheitert (429), zweiter gelingt
reset_case; fault 'method=setMyCommands&code=429&retry_after=1&times=1&desc=Too%20Many%20Requests%3A%20retry%20after%201'
OUT="$( ( set -euo pipefail; _push_bot_commands "$TOKEN" '[{"command":"help","description":"Hilfe"}]' '{"type":"default"}' Default ) 2>&1 )"; RC=$?
eq '429: Rueckgabe 0' 0 "$RC"
eq '429: genau zwei Aufrufe' 2 "$(calls setMyCommands)"
has '429: Protokoll nennt Code' 'HTTP 429' "$OUT"
has '429: Protokoll nennt Beschreibung' 'Too Many Requests' "$OUT"
has '429: zweiter Versuch gelungen' 'gesetzt' "$OUT"
hasnt '429: kein Schluessel im Protokoll' MARKERTOKENzz9 "$OUT"

# --- Beide Versuche scheitern: 5xx
reset_case; fault 'method=setMyCommands&code=502&desc=Bad%20Gateway'
OUT="$( ( set -euo pipefail; _push_bot_commands "$TOKEN" '[{"command":"help","description":"Hilfe"}]' '{"type":"default"}' Default ) 2>&1 )"; RC=$?
eq '5xx beide: Rueckgabe 0 (unkritisch)' 0 "$RC"
eq '5xx beide: genau zwei Aufrufe' 2 "$(calls setMyCommands)"
has '5xx beide: Protokoll nennt Code' 'HTTP 502' "$OUT"
has '5xx beide: Protokoll nennt Beschreibung' 'Bad Gateway' "$OUT"
hasnt '5xx beide: kein Schluessel' MARKERTOKENzz9 "$OUT"

# --- Kein Netz: Grund steht trotzdem im Protokoll
reset_case
OUT="$( ( set -euo pipefail; LIFEAGENTS_TELEGRAM_API=http://127.0.0.1:9
          _push_bot_commands "$TOKEN" '[{"command":"help","description":"Hilfe"}]' '{"type":"default"}' Default ) 2>&1 )"; RC=$?
eq 'kein-netz: Rueckgabe 0' 0 "$RC"
has 'kein-netz: Protokoll nennt Verbindung' 'keine Verbindung' "$OUT"
hasnt 'kein-netz: kein Schluessel' MARKERTOKENzz9 "$OUT"

# --- retry_after wird gedeckelt
reset_case; fault 'method=setMyCommands&code=429&retry_after=99&times=1'
T0="$(date +%s)"
( set -euo pipefail; LIFEAGENTS_TG_RETRY_MAX=1
  _push_bot_commands "$TOKEN" '[{"command":"help","description":"Hilfe"}]' '{"type":"default"}' Default ) >/dev/null 2>&1
T1="$(date +%s)"
eq 'deckel: zwei Aufrufe' 2 "$(calls setMyCommands)"
if [ $((T1 - T0)) -le 6 ]; then pass 'deckel: wartet nicht retry_after (99 s)'; else fail 'deckel: wartet nicht retry_after (99 s)' "$((T1 - T0)) s"; fi

# --- Knopf: Beschreibung ohne App-Adresse
reset_case; fault 'method=setChatMenuButton&code=400&times=2&desc=Bad%20Request%3A%20wrong%20URL%20https%3A%2F%2Fgeheim.example%2Fwebhook%2Fabc'
OUT="$( ( set -euo pipefail
          _tg_set_menu_button "$TOKEN" '{"chat_id":111,"menu_button":{"type":"commands"}}' || echo "WARN: Knopf nicht gesetzt: ${TG_ERR:-?}" ) 2>&1 )"
eq 'knopf: zwei Aufrufe' 2 "$(calls setChatMenuButton)"
has 'knopf: Protokoll nennt Code' 'HTTP 400' "$OUT"
hasnt 'knopf: keine App-Adresse' geheim.example "$OUT"
hasnt 'knopf: kein Schluessel' MARKERTOKENzz9 "$OUT"

# --- Bot-Name: erster getMe scheitert, zweiter gelingt
reset_case; fault 'method=getMe&code=500&times=1'
( set -euo pipefail; _sync_bot_username "$TOKEN" ) >/dev/null 2>&1
eq 'bot-name: zwei getMe' 2 "$(calls getMe)"
eq 'bot-name: Eintrag nach Wiederholung' 1 "$(writes)"

# --- provision.sh: Menue erst nach dem Paket-Lauf
P="$ROOT/provisioning/provision.sh"
L_BEGIN="$(grep -n '^  menus_defer_begin ' "$P" | head -1 | cut -d: -f1)"
L_OWNER="$(grep -n '^  bootstrap_owner$' "$P" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # Suchmuster, kein Ausdruck
L_LOOP="$(grep -n 'pkg_install_one "\$_pkg"' "$P" | head -1 | cut -d: -f1)"
L_FLUSH="$(grep -n '^  menus_flush$' "$P" | head -1 | cut -d: -f1)"
if [ -n "$L_BEGIN" ] && [ -n "$L_OWNER" ] && [ "$L_BEGIN" -lt "$L_OWNER" ]; then pass 'provision.sh: Aufschub vor dem Owner-Bootstrap'; else fail 'provision.sh: Aufschub vor dem Owner-Bootstrap' "begin=$L_BEGIN owner=$L_OWNER"; fi
if [ -n "$L_FLUSH" ] && [ -n "$L_LOOP" ] && [ "$L_FLUSH" -gt "$L_LOOP" ]; then pass 'provision.sh: Setzen nach dem Paket-Lauf'; else fail 'provision.sh: Setzen nach dem Paket-Lauf' "flush=$L_FLUSH loop=$L_LOOP"; fi


# --- Mehrfach-Schleifen ausser provision.sh: Paket-Befehl (beide Wege) und Restore setzen das Menue einmal danach
for pair in "pkg_lifecycle.sh:2" "backup_cli.sh:1"; do
  fl="${pair%%:*}"; want="${pair##*:}"
  d="$(grep -cE '^ +_pkg_menus_defer( |$)' "$ROOT/provisioning/lib/$fl")"; f="$(grep -cE '^ +_pkg_menus_flush( |$)' "$ROOT/provisioning/lib/$fl")"
  eq "$fl: Aufschub je Schleife ($want)" "$want/$want" "$d/$f"
done
exit "$fails"
