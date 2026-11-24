#!/usr/bin/env bash
# relink_cases.sh — Fall-Runner von scripts/dev/bot_menu_test.ps1, laeuft IM Container (bash/curl/jq/node).
#
# Prueft `lifeagents telegram relink` (Bot wieder mit dieser Installation verbinden) ueber die echte CLI-Vorlage gegen den
# Mock tests/mock_telegram/server.js und die n8n-Attrappe fake_n8n_api.js: fremde Adresse -> Re-Publish -> Adresse stimmt;
# schon verbunden -> nichts anfassen (ein Re-Publish verwirft wartende Nachrichten); Fehlerwege mit Klartext, nie der
# Schluessel; stillgelegte Installation lehnt ab; doctor nennt den Befehl.
#
# Usage: bash relink_cases.sh <root> <port>     (<port> = Mock-Telegram, <port>+1 = n8n-Attrappe)
# Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
set -uo pipefail
ROOT="$1"; PORT="$2"; NPORT=$((PORT + 1))
W=/tmp/relink_test
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "'$2' fehlt in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "'$2' steht in: $3" ;; *) pass "$1" ;; esac; }

rm -rf "$W"; mkdir -p "$W/mock" "$W/etc" "$W/state"
cp "$ROOT/mock_telegram/server.js" "$W/mock/server.js"
cp "$ROOT/mock_telegram/fake_n8n_api.js" "$W/mock/fake_n8n_api.js"
sed "s#@@LIBDIR@@#$ROOT#g" "$ROOT/provisioning/templates/lifeagents.tpl" > "$W/lifeagents"
LOG="$W/requests.jsonl"
N8NTEST_MOCK_TG_PORT="$PORT" N8NTEST_MOCK_TG_LOG="$LOG" node "$W/mock/server.js" >/dev/null 2>&1 &
TG_PID=$!
MOCK_TG_PORT="$PORT" FAKE_N8N_PORT="$NPORT" WEBHOOK_HOST=home.example.test node "$W/mock/fake_n8n_api.js" >/dev/null 2>&1 &
N8N_PID=$!
trap 'kill "$TG_PID" "$N8N_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 25); do curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 && curl -sf "http://127.0.0.1:$NPORT/__health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 || { fail setup 'Mock-Telegram antwortet nicht'; exit 1; }
curl -sf "http://127.0.0.1:$NPORT/__health" >/dev/null 2>&1 || { fail setup 'n8n-Attrappe antwortet nicht'; exit 1; }

TOKEN='1000001:MARKERTOKENzz9'
write_env() { printf 'TELEGRAM_BOT_TOKEN=%s\nN8N_API_KEY=apikey-marker-77\nDOMAIN=home.example.test\nOWNER_LAST_NAME=Mustermann Test\n' "$TOKEN" > "$W/etc/core.env"; }
write_env
hook() { curl -sf "http://127.0.0.1:$PORT/__webhook?$1" >/dev/null; }
mode() { curl -sf "http://127.0.0.1:$NPORT/__mode?publish=$1" >/dev/null; }
n8n_calls() { curl -sf "http://127.0.0.1:$NPORT/__calls" | jq -r .calls; }
cur_url() { curl -sf "http://127.0.0.1:$PORT/__webhook?track=0" ; }
# run <api-port> [env...] [-- verb-args] -> OUT, RC
run() { local api="$1"; shift; OUT="$(env -u TELEGRAM_BOT_TOKEN -u N8N_API_KEY -u DOMAIN LIFEAGENTS_DIR="$W/etc" LIFEAGENTS_STATE_DIR="$W/state" N8N_URL="http://127.0.0.1:$NPORT" LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$api" "$@" bash "$W/lifeagents" telegram relink 2>&1)"; RC=$?; }

# 1) Fremde Adresse (anderes System hat den Bot): Re-Publish stellt die eigene Adresse her.
hook 'url=https%3A%2F%2Fexample.com%2Fwebhook%2Fabc%2Fwebhook&track=0'; mode ok
run "$PORT" env
eq 'fremde Adresse: Exit 0' 0 "$RC"
eq 'fremde Adresse: Telegram zeigt jetzt auf die eigene Domain' 'https://home.example.test/webhook/x/webhook' "$(cur_url)"
has 'fremde Adresse: Klartext nennt die Domain' 'home.example.test' "$OUT"
hasnt 'fremde Adresse: kein Bot-Schluessel in der Ausgabe' 'MARKERTOKEN' "$OUT"
hasnt 'fremde Adresse: kein n8n-Schluessel in der Ausgabe' 'apikey-marker' "$OUT"

# 2) Schon verbunden: nichts anfassen (ein Re-Publish verwirft wartende Nachrichten).
before="$(n8n_calls)"
run "$PORT" env
eq 'schon verbunden: Exit 0' 0 "$RC"
eq 'schon verbunden: kein Publish/Unpublish' "$before" "$(n8n_calls)"
has 'schon verbunden: Klartext' 'schon' "$OUT"

# 3) Wert mit Leerzeichen in core.env (OWNER_LAST_NAME): die Datei wird gelesen, nie gesourct.
write_env
hook 'url=https%3A%2F%2Fexample.com%2Fwebhook%2Fabc%2Fwebhook'
run "$PORT" env
eq 'core.env mit Leerzeichen im Wert: Exit 0' 0 "$RC"

# 4) n8n lehnt das Veroeffentlichen ab: Exit 1, Grund im Klartext.
hook 'url=https%3A%2F%2Fexample.com%2Fwebhook%2Fabc%2Fwebhook'; mode fail
run "$PORT" env
eq 'Publish scheitert: Exit 1' 1 "$RC"
has 'Publish scheitert: Grund steht da' 'IP address is not allowed' "$OUT"
hasnt 'Publish scheitert: kein Bot-Schluessel' 'MARKERTOKEN' "$OUT"

# 5) Publish ok, aber Telegram hat danach keine Adresse fuer die Domain.
hook 'url=https%3A%2F%2Fexample.com%2Fwebhook%2Fabc%2Fwebhook'; mode noop
run "$PORT" env
eq 'Telegram uebernimmt nicht: Exit 1' 1 "$RC"
has 'Telegram uebernimmt nicht: nennt die Domain' 'home.example.test' "$OUT"
mode ok

# 6) Voraussetzungen fehlen.
: > "$W/etc/core.env"; printf 'N8N_API_KEY=k\nDOMAIN=home.example.test\n' > "$W/etc/core.env"
run "$PORT" env
eq 'kein Bot-Schluessel: Exit 1' 1 "$RC"
has 'kein Bot-Schluessel: Klartext' 'Schluessel' "$OUT"
printf 'TELEGRAM_BOT_TOKEN=%s\nDOMAIN=home.example.test\n' "$TOKEN" > "$W/etc/core.env"
run "$PORT" env
eq 'kein n8n-Schluessel: Exit 1' 1 "$RC"
printf 'TELEGRAM_BOT_TOKEN=%s\nN8N_API_KEY=k\n' "$TOKEN" > "$W/etc/core.env"
run "$PORT" env
eq 'keine Internet-Adresse: Exit 1' 1 "$RC"
write_env

# 7) Telegram nicht erreichbar: Exit 1, nichts angefasst.
before="$(n8n_calls)"
run 1 env
eq 'Telegram nicht erreichbar: Exit 1' 1 "$RC"
eq 'Telegram nicht erreichbar: n8n unberuehrt' "$before" "$(n8n_calls)"

# 8) Stillgelegte Installation (Umzug): relink lehnt ab, release-webhook bleibt erlaubt.
: > "$W/state/retired"
hook 'url=https%3A%2F%2Fexample.com%2Fwebhook%2Fabc%2Fwebhook'
before="$(n8n_calls)"
run "$PORT" env
eq 'stillgelegt: Exit 1' 1 "$RC"
has 'stillgelegt: Satz nennt den Umzug' 'stillgelegt' "$OUT"
eq 'stillgelegt: n8n unberuehrt' "$before" "$(n8n_calls)"
OUT="$(env -u TELEGRAM_BOT_TOKEN LIFEAGENTS_DIR="$W/etc" LIFEAGENTS_STATE_DIR="$W/state" LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$PORT" bash "$W/lifeagents" telegram release-webhook 2>&1)"; RC=$?
eq 'stillgelegt: release-webhook laeuft weiter' 0 "$RC"
rm -f "$W/state/retired"

# 9) Hilfe und doctor nennen den Befehl; die Diagnose-Helfer trennen fremd von eigen.
OUT="$(bash "$W/lifeagents" help 2>&1)"
has 'lifeagents help nennt telegram relink' 'relink' "$OUT"
OUT="$(LIFEAGENTS_DIR="$W/etc" bash "$W/lifeagents" telegram help 2>&1)"
has 'telegram help nennt relink' 'relink' "$OUT"
doc="$(cat "$ROOT/provisioning/doctor.sh")"
has 'doctor nennt die Abhilfe lifeagents telegram relink' 'lifeagents telegram relink' "$doc"
OUT="$(. "$ROOT/provisioning/lib/common.sh"
  fremd='{"ok":true,"result":{"url":"https://example.com/webhook/a/webhook"}}'
  eigen='{"ok":true,"result":{"url":"https://home.example.test/webhook/a/webhook"}}'
  leer='{"ok":true,"result":{"url":""}}'
  tg_webhook_foreign "$fremd" home.example.test && printf 'fremd-ja '
  tg_webhook_foreign "$eigen" home.example.test || printf 'eigen-nein '
  tg_webhook_foreign "$leer" home.example.test || printf 'leer-nein '
  tg_webhook_foreign '' home.example.test || printf 'unbekannt-nein')"
eq 'tg_webhook_foreign: nur eine fremde Adresse zaehlt' 'fremd-ja eigen-nein leer-nein unbekannt-nein' "$OUT"

exit "$fails"
