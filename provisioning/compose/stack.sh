#!/usr/bin/env bash
# stack.sh — Docker-Verbund von aussen anwerfen (Rechner-Seite): CI-Lauf (genericity.yml) und Vorlage fuer die Start-App.
# Fuehrt nur die Schritte aus, die VOR dem master liegen; alles Weitere erledigt provision.sh IM master. Jeder
# Docker-Aufruf laeuft ueber lib/runtime.sh (eine Datei, Positivliste) mit festem Projekt.
#
# Usage (Variablen wie in compose.yml: LA_PROJECT, LA_EDGE_PORT, LA_WIZARD_PORT, LA_PG_SUPERPW, LA_MASTER_IMAGE):
#   bash provisioning/compose/stack.sh up                       Volumes anlegen, Datei pruefen, anchor/postgres/master/edge
#   bash provisioning/compose/stack.sh install <antwort-datei> [provision.sh-Flags…]
#                                                               Antwort-Datei in den master legen, provision.sh dort fahren
#   bash provisioning/compose/stack.sh ps                       Zustand der eigenen Container
# Abbau (Volumes nur nach Rueckfrage) gehoert dem Deinstaller (Paket 2), nicht hierher.
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
LA_COMPOSE_FILE="$HERE/compose.yml"
# Git Bash unter Windows (Entwickler-Rechner): docker.exe versteht nur Windows-Pfade.
if command -v cygpath >/dev/null 2>&1; then LA_COMPOSE_FILE="$(cygpath -m "$LA_COMPOSE_FILE")"; export MSYS_NO_PATHCONV=1; fi

_answers_in_master=/run/lifeagents-wizard/answers.env   # tmpfs im master (compose.yml): nie auf einer Platte

case "${1:-}" in
  up)
    rt_docker_ok || die "Docker antwortet nicht."
    rt_stack_config_check || die "compose.yml ungültig oder Pflicht-Variable fehlt (LA_EDGE_PORT, LA_WIZARD_PORT, LA_PG_SUPERPW, LA_MASTER_IMAGE)."
    rt_volumes_ensure
    rt_stack_up anchor postgres master edge
    rt_wait_healthy "$LA_PG_CONTAINER" 180 || die "Datenbank wurde nicht gesund ($(svc_logs_hint postgresql))."
    ok "Verbund ${LA_PROJECT} läuft (anchor, postgres, master, edge)."
    ;;
  install)
    [ -r "${2:-}" ] || die "Antwort-Datei fehlt: stack.sh install <datei>"
    rt_master_write "$_answers_in_master" < "$2"
    shift 2
    rc=0
    rt_master_exec bash /opt/lifeagents/provisioning/provision.sh --unattended "$_answers_in_master" "$@" || rc=$?
    rt_master_exec rm -f "$_answers_in_master" || true
    exit "$rc"
    ;;
  ps) rt_stack_ps ;;
  *) printf 'Usage: stack.sh up | install <antwort-datei> [flags…] | ps\n' >&2; exit 2 ;;
esac
