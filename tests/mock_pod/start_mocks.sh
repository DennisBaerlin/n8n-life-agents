#!/usr/bin/env bash
# start_mocks.sh — Telegram-, KI- und Paperless-Attrappe als eigene Container im Netz-Namensraum des Verbunds <projekt>:
# n8n, master, Gateway und Attrappen teilen sich 127.0.0.1 (Telegram :8089, KI :8088, Paperless :8092), und eine Attrappe
# ueberlebt einen master-Wechsel (Update). Eigene Container statt Compose-Override: der master ruft Compose mit seiner
# eingebauten compose.yml, ein Override risse beim naechsten `up --no-deps`/`down --remove-orphans` mit (Einwand 2 des
# /arch-challenge). Darum tragen sie kein Compose-Etikett.
# Etiketten (Vertrag mit dem Session-Ende-Haken): io.lifeagents.install=<projekt> und lifeagents.worktree=<Checkout-Pfad>.
# Die Attrappen laufen mit dem Abbild des master (Node ist dort), Skripte schreibgeschuetzt eingehaengt, Logs je Attrappe in
# <logordner>/mock_<name>.jsonl auf dem Rechner. Die Attrappen sind dependency-frei.
# Aufruf:  bash tests/mock_pod/start_mocks.sh <projekt> <logordner> [tg] [llm] [pl]    (ohne Auswahl: alle drei)
# Umgebung: MOCK_LLM_TODAY (YYYY-MM-DD) wird an die KI-Attrappe durchgereicht, falls gesetzt. MOCK_TG_DOCS = Ordner der
# Test-Dokumente fuer die Telegram-Attrappe (/m/docs), Standard tests/mock_telegram/docs; enable_mock_telegram.ps1 gibt einen
# Ordner mit aufgeloesten Datums-Platzhaltern.
# Idempotent (entfernt vorhandene Attrappen mit `docker rm -fv`, auch nach einem Schnappschuss-Reset). Exit 0 = alle
# gewaehlten antworten auf /__health.
# Abbau: docker rm -fv <projekt>-tgmock <projekt>-mock-llm <projekt>-mock-pl
set -euo pipefail
P="${1:?projekt}"; LOG_DIR="${2:?logordner}"; shift 2
want=("$@"); [ "${#want[@]}" -gt 0 ] || want=(tg llm pl)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS="$(cd "$HERE/.." && pwd)"
# Git Bash unter Windows (Entwickler-Rechner): git.exe und docker.exe verstehen nur Windows-Pfade (auch wenn der Aufrufer
# MSYS_NO_PATHCONV schon gesetzt hat, wird /c/... nicht mehr umgewandelt).
GIT_HERE="$HERE"
TG_DOCS="${MOCK_TG_DOCS:-$TESTS/mock_telegram/docs}"
if command -v cygpath >/dev/null 2>&1; then GIT_HERE="$(cygpath -m "$HERE")"; TESTS="$(cygpath -m "$TESTS")"; LOG_DIR="$(cygpath -m "$LOG_DIR")"; TG_DOCS="$(cygpath -m "$TG_DOCS")"; export MSYS_NO_PATHCONV=1; fi
[ -d "$TG_DOCS" ] || { echo "FAIL Dokumente-Ordner '$TG_DOCS' fehlt" >&2; exit 2; }
WORKTREE="$(git -C "$GIT_HERE" rev-parse --show-toplevel)"
mkdir -p "$LOG_DIR"
img="$(docker inspect -f '{{.Config.Image}}' "$P-master")"

# start <name> <port> <log> <skript> <einhaengen:ordner|datei> <ziel> [-e K=V ...]
start() {
  local name="$1" port="$2" log="$3" script="$4" src="$5" dst="$6"; shift 6
  docker rm -fv "$name" >/dev/null 2>&1 || true
  : > "$LOG_DIR/$log"
  # hand-injected: Port und Log-Datei sind die Einstellung der Attrappe selbst, nicht des geprueften Installers
  docker run -d --name "$name" --network "container:$P-anchor" \
    --label "io.lifeagents.install=$P" --label "lifeagents.worktree=$WORKTREE" \
    --entrypoint node "$@" -v "$src:$dst:ro" -v "$LOG_DIR:/log" "$img" "$script" >/dev/null
  local _
  for _ in $(seq 1 25); do docker exec "$P-master" curl -sf "http://127.0.0.1:$port/__health" >/dev/null 2>&1 && return 0; sleep 0.4; done
  docker logs --tail 20 "$name" 2>&1 || true
  echo "FAIL die Attrappe $name antwortet nicht auf 127.0.0.1:$port" >&2; return 1
}

for w in "${want[@]}"; do
  case "$w" in
    tg)  start "$P-tgmock" 8089 mock_telegram.jsonl /m/server.js "$TESTS/mock_telegram/server.js" /m/server.js \
           -e N8NTEST_MOCK_TG_PORT=8089 -e N8NTEST_MOCK_TG_LOG=/log/mock_telegram.jsonl -v "$TG_DOCS:/m/docs:ro" ;;
    llm) start "$P-mock-llm" 8088 mock_llm.jsonl /m/server.js "$TESTS/mock_llm" /m \
           -e MOCK_LLM_PORT=8088 -e MOCK_LLM_LOG=/log/mock_llm.jsonl -e MOCK_LLM_SCENARIOS=/m/scenarios.json \
           ${MOCK_LLM_TODAY:+-e "MOCK_LLM_TODAY=$MOCK_LLM_TODAY"} ;;
    pl)  start "$P-mock-pl" 8092 mock_paperless.jsonl /m/server.js "$TESTS/mock_paperless/server.js" /m/server.js \
           -e N8NTEST_MOCK_PL_PORT=8092 -e N8NTEST_MOCK_PL_LOG=/log/mock_paperless.jsonl ;;
    *)   echo "FAIL unbekannte Attrappe '$w' (tg, llm, pl)" >&2; exit 2 ;;
  esac
done
