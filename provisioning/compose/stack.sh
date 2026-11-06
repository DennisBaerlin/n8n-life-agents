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
#   bash provisioning/compose/stack.sh uninstall [--delete-data]
#                                                               Entfernen (Pruefliste Nr. 17): Container + Netze dieses Projekts;
#                                                               mit --delete-data (die App fragt VORHER ausdruecklich) auch die
#                                                               Daten-Volumes — jedes nur mit unserem Label. Images bleiben (die
#                                                               App entfernt nur, was ihr Journal als selbst geladen fuehrt).
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
  uninstall)
    del=0
    case "${2:-}" in --delete-data) del=1 ;; '') ;; *) die "Unbekannte Option: $2" ;; esac
    rt_docker_ok || die "Docker antwortet nicht."
    # Kein noch laufender master-Wechsel: der Helfer legte den master sonst gleich wieder an.
    if rt_swap_helper_running; then die "Gerade läuft ein Update (master-Wechsel) — danach erneut entfernen. Nichts geändert."; fi
    rt_stack_down || die "Container ließen sich nicht entfernen — Daten unberührt."
    # Abgeleitete Volumes (jeder Installer-Lauf schreibt sie neu, keine Nutzerdaten) gehen immer; Compose nennt sie
    # <projekt>_<name> und versieht sie mit unserem Label (compose.yml).
    for v in shared gw_code n8n_patches; do rt_volume_rm_own "${LA_PROJECT}_${v}" || true; done
    if [ "$del" -eq 1 ]; then
      rc=0
      for v in $LA_STATE_VOLUMES; do rt_volume_rm_own "${LA_PROJECT}_${v}" || rc=1; done
      [ "$rc" -eq 0 ] || die "Mindestens ein Volume trug nicht unser Label und blieb stehen (siehe oben)."
      ok "Verbund ${LA_PROJECT} entfernt, Daten gelöscht."
    else
      ok "Verbund ${LA_PROJECT} entfernt; die Daten bleiben (Volumes ${LA_PROJECT}_*) — eine neue Installation findet sie wieder."
    fi
    ;;
  *) printf 'Usage: stack.sh up | install <antwort-datei> [flags…] | ps | uninstall [--delete-data]\n' >&2; exit 2 ;;
esac
