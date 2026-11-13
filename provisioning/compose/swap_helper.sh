#!/usr/bin/env bash
# swap_helper.sh — der kurzlebige Helfer fuer den master-Wechsel im Docker-Verbund (der master kann sich nicht selbst
# ersetzen). Laeuft als eigener
# Container (lib/runtime.sh rt_swap_helper_start, `docker run --rm`) aus dem alten master-Image und sieht nur den
# Docker-Socket und das Volume var_la. Ablauf und Zustaende: lib/master_swap.sh (Kopf).
# Usage: bash swap_helper.sh <arbeitsordner>     (Umgebung: Interpolations-Werte aus <arbeitsordner>/stack.env)
# Exit: 0 = Endzustand in <arbeitsordner>/state geschrieben (PHASE swapped | rolled_back | rollback_failed);
# 1 = Zustandsdatei unvollstaendig oder <arbeitsordner> fehlt (`${1:?}`).
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
# shellcheck source=../lib/master_swap.sh
. "$HERE/../lib/master_swap.sh"
LA_COMPOSE_FILE="$HERE/compose.yml"   # nur Vorgabe; jeder Aufruf nennt seine Datei (alt/neu) selbst
swap_helper_main "${1:?Arbeitsordner fehlt}"
