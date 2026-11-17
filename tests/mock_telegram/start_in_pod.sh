#!/usr/bin/env bash
# start_in_pod.sh — Telegram-Mock (tests/mock_telegram/server.js) im Netz-Namensraum des Verbunds <projekt>: ein eigener
# Container am anchor, damit n8n, master und Mock sich 127.0.0.1:8089 teilen und der Mock einen master-Wechsel (Update)
# ueberlebt. Er laeuft mit dem Image des master (Node ist dort), schreibt das Log in <logordner>/mock_telegram.jsonl auf dem
# Rechner und traegt kein Label des Verbunds (Abbau: docker rm -fv <projekt>-tgmock).
# Aufruf: bash tests/mock_telegram/start_in_pod.sh <projekt> <logordner>      Exit 0 = der Mock antwortet auf /__health.
set -euo pipefail
P="${1:?projekt}"; LOG_DIR="${2:?logordner}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Git Bash unter Windows (Entwickler-Rechner): docker.exe versteht nur Windows-Pfade.
if command -v cygpath >/dev/null 2>&1; then HERE="$(cygpath -m "$HERE")"; LOG_DIR="$(cygpath -m "$LOG_DIR")"; export MSYS_NO_PATHCONV=1; fi
mkdir -p "$LOG_DIR"; : > "$LOG_DIR/mock_telegram.jsonl"
img="$(docker inspect -f '{{.Config.Image}}' "$P-master")"
docker rm -fv "$P-tgmock" >/dev/null 2>&1 || true
# hand-injected: Port und Log-Datei sind die Einstellung des Mocks selbst, nicht des geprueften Installers
docker run -d --name "$P-tgmock" --network "container:$P-anchor" --entrypoint node -e N8NTEST_MOCK_TG_PORT=8089 -e N8NTEST_MOCK_TG_LOG=/log/mock_telegram.jsonl -v "$HERE/server.js:/m/server.js:ro" -v "$LOG_DIR:/log" "$img" /m/server.js >/dev/null
for _ in $(seq 1 25); do docker exec "$P-master" curl -sf http://127.0.0.1:8089/__health >/dev/null 2>&1 && exit 0; sleep 0.4; done
docker logs --tail 20 "$P-tgmock" 2>&1 || true
echo "FAIL der Telegram-Mock antwortet nicht" >&2; exit 1
