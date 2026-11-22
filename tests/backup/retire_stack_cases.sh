#!/usr/bin/env bash
# retire_stack_cases.sh — Fall-Runner des Verbund-Wegs von scripts/dev/retire_test.ps1 (N8NTEST_RUNTIME=compose), laeuft IM master
# des Docker-Verbunds (Docker-Socket des master, echte CLI dieses Baums unter <root>/lifeagents). Zwei Phasen, dazwischen faehrt der
# Treiber auf dem Rechner `stack start` (der Kurzlauf-Container des Kerns laeuft nie im master):
#   retire  `lifeagents retire` im Verbund: Bot geloest (eigene Telegram-Attrappe), n8n angehalten, Merker im Volume var_la, Stand done.
#   undo    `lifeagents retire --undo`: Merker weg, n8n wieder gestartet.
# Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL. Die Zustandspruefungen der Container und `stack start`
# selbst macht der Treiber (er sieht die Container von aussen, wie die Start-App).
#
# Usage: bash retire_stack_cases.sh <root> <phase:retire|undo> <projekt> <telegram-port>
# shellcheck disable=SC2016,SC2329,SC2015  # cleanup laeuft per trap; A && pass || fail ist gewollt (pass scheitert nie)
set -uo pipefail
ROOT="$1"; PHASE="$2"; PROJECT="$3"; TGPORT="$4"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }

W="$(mktemp -d)"; chmod 0700 "$W"
CLI="$ROOT/lifeagents"
sed "s|@@LIBDIR@@|$ROOT|" "$ROOT/provisioning/templates/lifeagents.tpl" > "$CLI"; chmod 0700 "$CLI"
# Die Vorpruefung verlangt ein Release (Test-Verbund: dev). Der Marker liegt neben dieser CLI unter <root>, nicht im Volume des master.
[ -r "$ROOT/VERSION" ] || cp /usr/local/lib/lifeagents/VERSION "$ROOT/VERSION" 2>/dev/null || true
grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/VERSION" 2>/dev/null || printf 'v9.9.0\n' > "$ROOT/VERSION"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
export LA_PROJECT="$PROJECT"
rt_is_compose || { fail setup 'LIFEAGENTS_RUNTIME ist nicht compose (dieser Runner ist der Verbund-Weg)'; exit "$fails"; }
TGLOG="$W/mock_telegram.jsonl"
# Eigene Attrappe (die des Pods loggt auf den Rechner); der Webhook steht nach dem Loesen leer.
# hand-injected: Telegram = Attrappe im master (nie der echte Bot); kurze Warte-/Abwartezeiten fuer den Testlauf
export LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$TGPORT" RETIRE_WEBHOOK_WAIT_SECS=5 RETIRE_DRAIN_SECS=60
# hand-injected: ein erfundener Bot-Schluessel (Umgebung vor core.env) schickt Loesen + Pruefen ueber die Attrappe
export TELEGRAM_BOT_TOKEN=1000001:RETIRETESTzz9
N8NTEST_MOCK_TG_PORT="$TGPORT" N8NTEST_MOCK_TG_LOG="$TGLOG" node "$ROOT/mock_telegram/server.js" > "$W/mock_tg.log" 2>&1 &
TGPID=$!
cleanup() { kill "$TGPID" 2>/dev/null; wait "$TGPID" 2>/dev/null; rm -rf "$W" "$CLI"; }
trap cleanup EXIT
for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:${TGPORT}/__health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$TGPID" 2>/dev/null || { fail setup "Telegram-Attrappe auf Port ${TGPORT} gestorben: $(tr '\n' ' ' < "$W/mock_tg.log" | cut -c1-200)"; exit "$fails"; }
curl -sf "http://127.0.0.1:$TGPORT/__webhook?off=1&track=1" >/dev/null || { fail setup 'Attrappe ohne Webhook-Merkmodus'; exit "$fails"; }

n=0
cli() { n=$((n + 1)); "$CLI" "$@" > "$W/out.$n" 2>&1 < /dev/null; }
last() { tail -n4 "$W/out.$n" | tr '\n' ' '; }
retired_here() { [ -e "$(la_retired_file)" ]; }

case "$PHASE" in
  retire)
    retired_here && { fail setup 'Merker liegt schon (fremder Lauf?)'; exit "$fails"; }
    # Vorpruefung „Sicherung < 26 h“ ueber den echten Weg erfuellen.
    cli backup auto || { fail setup "backup auto: $(last)"; exit "$fails"; }
    cli retire; rc=$?
    eq L.lauf-ok 0 "$rc"
    [ "$rc" = 0 ] || printf '# %s\n' "$(tail -n 12 "$W/out.$n")"
    retired_here && pass L.merker-im-volume || fail L.merker-im-volume "Merker fehlt"
    eq L.stand 'done' "$(read_env_value "$(la_retired_file)" STAGE 2>/dev/null)"
    cli retire --status; eq L.status-fertig 11 "$?"
    ;;
  undo)
    retired_here || { fail setup 'kein Merker: retire lief nicht'; exit "$fails"; }
    cli retire --undo; rc=$?
    eq U.undo-ok 0 "$rc"
    [ "$rc" = 0 ] || printf '# %s\n' "$(tail -n 12 "$W/out.$n")"
    retired_here && fail U.merker-weg "liegt noch" || pass U.merker-weg
    cli retire --status; eq U.status-nicht 0 "$?"
    ;;
  *) fail setup "unbekannte Phase '$PHASE'" ;;
esac
exit "$fails"
