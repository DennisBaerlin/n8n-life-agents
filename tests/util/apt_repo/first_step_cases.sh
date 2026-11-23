#!/usr/bin/env bash
# first_step_cases.sh — Fall-Runner von scripts/dev/apt_repo_test.ps1: der dokumentierte erste Schritt (Einzeiler im Kopf von
# provisioning/setup.sh, einzige Quelle der Doku) auf einem frischen debian:12 ohne curl. Nur die Download-Adresse wird gegen eine
# lokale Datei getauscht (stub-setup.sh), der Rest des Befehls laeuft unveraendert.
#
# Usage: bash first_step_cases.sh <root>   Ausgabe "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2015  # "a && pass || fail" gewollt
set -uo pipefail
ROOT="$1"
# hand-injected: apt laeuft im Wegwerf-Container ohne Rueckfragen (gleiche Einstellung wie install.sh/provision.sh)
export LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

command -v curl >/dev/null 2>&1 && { echo "FAIL setup: curl schon da"; exit 1; }

cmd="$(grep -m1 'curl -fsSL' "$ROOT/provisioning/setup.sh" | sed -E 's/^#[[:space:]]*//')"
[ -n "$cmd" ] && pass F_command_documented || { fail F_command_documented "kein curl-Einzeiler im Kopf von setup.sh"; exit 1; }
# Nur die Adresse tauschen: die Attrappe tut, was setup.sh tut (ein Lebenszeichen), ohne ein Release zu brauchen.
printf '#!/bin/sh\necho STUB-SETUP-RAN\n' > /srv/stub-setup.sh
cmd="$(printf '%s' "$cmd" | sed -E 's#https://github\.com/[^ ]+/setup\.sh#file:///srv/stub-setup.sh#')"
mkdir -p /tmp/w && cd /tmp/w || exit 1
out="$(bash -c "$cmd" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q STUB-SETUP-RAN; then pass F_first_step_on_fresh_debian
else fail F_first_step_on_fresh_debian "rc $rc: $(printf '%s' "$out" | tail -n3)"; fi
# https muss auch gehen (ca-certificates), sonst scheitert der echte Download trotz curl.
out="$(curl -fsS -o /dev/null https://github.com 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then pass F_https_works; else fail F_https_works "rc $rc: $out"; fi

printf '# %s Fehler\n' "$fails"
exit "$fails"
