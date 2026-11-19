#!/usr/bin/env bash
# smoke.sh — Nachweis fuer tests/mock_pod/start_mocks.sh im echten Docker: Attrappen am anchor, Aufruf von aussen im
# Namensraum, Log auf dem Rechner, beide Etiketten, Wiederholung, Abbau.
# Der Pod ist hier nachgebaut: ein anchor (haelt den Namensraum) und ein "master" (nur sleep), beide aus <image> (braucht
# Node und curl, z. B. das master-Abbild eines Verbunds). Kein Ersatz fuer genericity.yml: ob Compose die Attrappen in Ruhe
# laesst, zeigt erst ein echter Verbund.
# real-path-test: none (der Nachbau des Verbunds ist der Gegenstand; der echte Verbund laeuft in .github/workflows/genericity.yml)
# Aufruf: bash tests/mock_pod/smoke.sh <image> [projekt]   (projekt Standard s4m1; Exit = Anzahl FAIL)
set -uo pipefail
IMG="${1:?image}"; P="${2:-s4m1}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$(mktemp -d)"; fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }
down() { docker rm -fv "$P-tgmock" "$P-mock-llm" "$P-mock-pl" "$P-master" "$P-anchor" >/dev/null 2>&1 || true; }
trap 'down; rm -rf "$LOG"' EXIT
down
docker run -d --name "$P-anchor" --entrypoint sleep "$IMG" infinity >/dev/null || { echo "FAIL anchor startet nicht" >&2; exit 1; }
docker run -d --name "$P-master" --network "container:$P-anchor" --entrypoint sleep "$IMG" infinity >/dev/null || { echo "FAIL master startet nicht" >&2; exit 1; }
inpod() { docker exec "$P-master" "$@"; }

if bash "$HERE/start_mocks.sh" "$P" "$LOG"; then pass M.start; else fail M.start "start_mocks.sh scheitert"; fi
for pair in tg:8089 llm:8088 pl:8092; do
  if inpod curl -sf "http://127.0.0.1:${pair#*:}/__health" >/dev/null 2>&1; then pass "M.health-${pair%%:*}"; else fail "M.health-${pair%%:*}" "keine Antwort"; fi
done
# Ein KI-Aufruf aus dem Namensraum landet im Log auf dem Rechner.
inpod curl -s -o /dev/null -X POST http://127.0.0.1:8088/v1/messages -H 'content-type: application/json' \
  -d '{"model":"claude-haiku-latest","max_tokens":16,"messages":[{"role":"user","content":"hallo"}]}'
if grep -q '"url":"/v1/messages"' "$LOG/mock_llm.jsonl" 2>/dev/null; then pass M.ki-aufruf-im-log; else fail M.ki-aufruf-im-log "kein Eintrag in mock_llm.jsonl"; fi
# Etiketten-Vertrag: beide Etiketten, und nur die drei Attrappen tragen das Verbund-Etikett dieses Projekts.
GIT_HERE="$HERE"; command -v cygpath >/dev/null 2>&1 && GIT_HERE="$(cygpath -m "$HERE")"   # git.exe versteht kein /c/...
want_wt="$(git -C "$GIT_HERE" rev-parse --show-toplevel)"
for c in tgmock mock-llm mock-pl; do
  eq "M.etikett-install-$c" "$P" "$(docker inspect -f '{{index .Config.Labels "io.lifeagents.install"}}' "$P-$c")"
  eq "M.etikett-worktree-$c" "$want_wt" "$(docker inspect -f '{{index .Config.Labels "lifeagents.worktree"}}' "$P-$c")"
done
eq M.nur-die-drei "$P-mock-llm $P-mock-pl $P-tgmock" "$(docker ps --filter "label=io.lifeagents.install=$P" --format '{{.Names}}' | sort | tr '\n' ' ' | sed 's/ $//')"
# Wiederholung (nach einem Schnappschuss-Reset): idempotent, wieder erreichbar.
if bash "$HERE/start_mocks.sh" "$P" "$LOG" llm && inpod curl -sf http://127.0.0.1:8088/__health >/dev/null 2>&1; then pass M.wiederholung; else fail M.wiederholung "zweiter Start scheitert"; fi
down
eq M.abbau-leer "" "$(docker ps -a --filter "label=io.lifeagents.install=$P" --format '{{.Names}}')"
exit "$fails"
