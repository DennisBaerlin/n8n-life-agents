#!/usr/bin/env bash
# release_webhook_cases.sh — Fall-Runner von scripts/dev/bot_menu_test.ps1, laeuft IM Container (bash/curl/jq/node).
#
# Prueft `lifeagents telegram release-webhook` (die Schnittstelle der Start-App beim Abbau, contract.rs
# MasterCmd::ReleaseWebhook) gegen den Mock tests/mock_telegram/server.js: ueber die echte CLI-Vorlage, nicht ueber die
# Funktion. Vertrag: Exit 0 = Webhook geloest oder nichts zu loesen; != 0 = Telegram lehnt ab/nicht erreichbar;
# Grund im Protokoll, der Bot-Schluessel nie in der Ausgabe.
#
# Usage: bash release_webhook_cases.sh <root> <port>     Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
set -uo pipefail
ROOT="$1"; PORT="$2"
W=/tmp/release_webhook_test
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "'$2' fehlt in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "'$2' steht in: $3" ;; *) pass "$1" ;; esac; }

rm -rf "$W"; mkdir -p "$W/mock" "$W/etc"
cp "$ROOT/mock_telegram/server.js" "$W/mock/server.js"
sed "s#@@LIBDIR@@#$ROOT#g" "$ROOT/provisioning/templates/lifeagents.tpl" > "$W/lifeagents"
LOG="$W/requests.jsonl"
N8NTEST_MOCK_TG_PORT="$PORT" N8NTEST_MOCK_TG_LOG="$LOG" node "$W/mock/server.js" >/dev/null 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 25); do curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 || { fail setup 'Mock antwortet nicht'; exit 1; }

TOKEN='1000001:MARKERTOKENzz9'
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" > "$W/etc/core.env"
calls() { local n; n="$(grep -c "\"method\":\"$1\"" "$LOG" 2>/dev/null)"; printf '%s' "${n:-0}"; }
reset_case() { : > "$LOG"; curl -sf "http://127.0.0.1:$PORT/__fail?method=deleteWebhook&off=1" >/dev/null; }
fault() { curl -sf "http://127.0.0.1:$PORT/__fail?$1" >/dev/null; }
# run <api-port> [env...] -> OUT (stdout+stderr), RC
run() { local api="$1"; shift; OUT="$(env -u TELEGRAM_BOT_TOKEN LIFEAGENTS_DIR="$W/etc" LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$api" "$@" bash "$W/lifeagents" telegram release-webhook 2>&1)"; RC=$?; }

reset_case; run "$PORT" env
eq 'Erfolg: Exit 0' 0 "$RC"
eq 'Erfolg: genau ein deleteWebhook' 1 "$(calls deleteWebhook)"
hasnt 'Erfolg: kein Schluessel in der Ausgabe' 'MARKERTOKEN' "$OUT"

reset_case; : > "$W/etc/core.env"; run "$PORT" env TELEGRAM_BOT_TOKEN='2000002:ENVTOKENyy8'
eq 'Schluessel nur in der Umgebung: Exit 0' 0 "$RC"
eq 'Schluessel nur in der Umgebung: ein deleteWebhook' 1 "$(calls deleteWebhook)"
hasnt 'Schluessel nur in der Umgebung: nicht in der Ausgabe' ENVTOKEN "$OUT"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" > "$W/etc/core.env"

reset_case; : > "$W/etc/core.env"; run "$PORT" env
eq 'Schluessel fehlt: Exit 0 (nichts zu loesen)' 0 "$RC"
eq 'Schluessel fehlt: kein Telegram-Aufruf' 0 "$(calls deleteWebhook)"
has 'Schluessel fehlt: Protokoll nennt den Grund' 'Schluessel' "$OUT"
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" > "$W/etc/core.env"

reset_case; fault 'method=deleteWebhook&code=429&retry_after=1&desc=Too%20Many%20Requests&times=1'; run "$PORT" env
eq '429 einmal: Exit 0 nach Wiederholversuch' 0 "$RC"
eq '429 einmal: zwei Aufrufe' 2 "$(calls deleteWebhook)"

reset_case; fault 'method=deleteWebhook&code=502&desc=Bad%20Gateway'; run "$PORT" env
eq 'beide scheitern: Exit 1' 1 "$RC"
eq 'beide scheitern: genau zwei Aufrufe' 2 "$(calls deleteWebhook)"
has 'beide scheitern: Grund mit HTTP-Code und Beschreibung' 'HTTP 502 — Bad Gateway' "$OUT"
hasnt 'beide scheitern: kein Schluessel in der Ausgabe' 'MARKERTOKEN' "$OUT"
reset_case

run 1 env
eq 'Telegram nicht erreichbar: Exit 1' 1 "$RC"
has 'Telegram nicht erreichbar: Grund im Protokoll' 'keine Verbindung' "$OUT"
hasnt 'Telegram nicht erreichbar: kein Schluessel in der Ausgabe' 'MARKERTOKEN' "$OUT"

OUT="$(LIFEAGENTS_DIR="$W/etc" bash "$W/lifeagents" telegram nonsense 2>&1)"; RC=$?
eq 'unbekanntes Verb: Exit 2' 2 "$RC"
OUT="$(bash "$W/lifeagents" help 2>&1)"
has 'lifeagents help nennt telegram release-webhook' 'release-webhook' "$OUT"

exit "$fails"
