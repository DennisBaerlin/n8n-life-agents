#!/usr/bin/env bash
# seed_pipe_cases.sh — der Daten-Seed (provisioning/lib/seed_data.sh) bricht unter `set -euo pipefail` nie an einer
# Pipe mit fruehem Leser ab. Fund: eine kalte Installation endete direkt nach „Daten-Seeds laden ..." still mit 141.
# Mechanik: ein Leser, der vor dem Ende der Eingabe aussteigt (awk `exit`, `head -n1`), laesst den Schreiber an SIGPIPE
# sterben; pipefail macht daraus den Status 141 der ganzen Pipeline, set -e beendet das Skript ohne Fehlerzeile. Haengt am
# Groessenverhaeltnis (Eingabe gegen Pipe-Puffer), nicht an der Eingabe: heute gewinnt meist der Schreiber das Rennen.
# Die Faelle machen es deterministisch, indem die Eingabe weit ueber dem Pipe-Puffer (64 KiB) liegt.
#
# Faehrt den ECHTEN Code (common.sh, seed_data.sh) gegen einen kleinen erfundenen Baum; braucht bash 5, jq, openssl.
# Usage: bash seed_pipe_cases.sh <root>   (<root>/provisioning/lib/ vorhanden)   Ausgabe je Fall PASS/FAIL, Exit = Anzahl FAIL.
# Eingabe ueber dem Pipe-Puffer erzwingt nur dieser Test; dass der Seed im echten Ablauf durchlaeuft, belegt die kalte Installation
# (bootstrap_test_n8n.ps1 -Reset -Cold).
# real-path-test: none (echter Code auf erfundenem Baum, keine Attrappe; der Pipe-Puffer-Fall tritt in der kalten Installation nur zufaellig auf)
# shellcheck disable=SC2016,SC2034,SC1091,SC2154  # Fall-Ausdruecke in einfachen Quotes; gesourcte Lib setzt Globals
set -uo pipefail
ROOT="$1"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# --- Baum: 2 Dienste, deren Workflows als erste Dateien liegen (der Leser steigt dort aus), dahinter ~100 KiB Rest ---
REPO="$W/repo"
mkdir -p "$REPO/packages/core/workflows"
printf '%s\n' '{"name":"core","provides":{"services":{"svc_a":"wf.first.a","svc_b":"wf.first.b"}}}' > "$REPO/packages/core/manifest.json"
printf '%s\n' '{"name":"wf.first.a","id":"id-first-a"}' > "$REPO/packages/core/workflows/0001.json"
printf '%s\n' '{"name":"wf.first.b","id":"id-first-b"}' > "$REPO/packages/core/workflows/0002.json"
pad="$(printf 'x%.0s' $(seq 1 80))"
for i in $(seq 1 1200); do
  printf '{"name":"wf.filler.%s.%s","id":"id-filler-%s"}\n' "$pad" "$i" "$i" > "$REPO/packages/core/workflows/f$(printf '%05d' "$i").json"
done

# _run <funktion-und-argumente…> — wie provision.sh: eigene Shell mit -euo pipefail, Lib gesourct; Ausgabe in $W/out, Exit in $rc.
# Eigene Shell statt Subshell: in `( … ) || rc=$?` waere set -e abgeschaltet, und der Abbruch bliebe unsichtbar.
_run() {
  rc=0
  REPO_ROOT="$REPO" bash -euo pipefail -c '. "$1/provisioning/lib/common.sh"; . "$1/provisioning/lib/seed_data.sh"; shift; "$@"' _ "$ROOT" "$@" \
    > "$W/out" 2> "$W/err" || rc=$?
}

# S1: core.services — der Lesezugriff auf die Name->id-Liste steigt nach dem ersten Treffer nicht aus der Pipe aus.
_run _seed_services
if [ "$rc" -eq 0 ] && [ "$(grep -c 'INSERT INTO core.services' "$W/out")" -eq 2 ] && grep -q "'id-first-b'" "$W/out"; then
  pass "S1 core.services: Dienst-Suche in grosser Workflow-Liste laeuft durch"
else
  fail "S1 core.services: Dienst-Suche in grosser Workflow-Liste" "exit $rc, $(grep -c 'INSERT INTO core.services' "$W/out") von 2 Zeilen (141 = SIGPIPE)"
fi

# S2: Kopf eines Context — description/agent_name/load_strategy lesen nach dem ersten Treffer nicht aus der Pipe aus.
{
  printf -- '---\n'
  for _ in $(seq 1 4000); do printf 'description: %s\n' "$pad"; done
  printf 'agent_name: guide\nload_strategy: static\n---\nBody\n'
} > "$W/ctx.md"
_run _seed_context_md "$W/ctx.md" seed core
if [ "$rc" -eq 0 ] && grep -q "'guide'" "$W/out" && grep -q "'static'" "$W/out"; then
  pass "S2 Context-Kopf: erster Treffer ohne Pipe-Abbruch"
else
  fail "S2 Context-Kopf: erster Treffer" "exit $rc (141 = SIGPIPE)"
fi

exit "$fails"
