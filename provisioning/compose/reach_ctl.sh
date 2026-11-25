#!/usr/bin/env bash
# reach_ctl.sh — Weg nach aussen im Docker-Verbund steuern, IM master (Wizard, Start-App per `docker exec`). Mechanik und
# Zustaende: Kopf von lib/reach.sh.
#
# Usage (im master, root):
#   bash /opt/lifeagents/provisioning/compose/reach_ctl.sh status     eine JSON-Zeile (reach_status_json), Exit 0
#   bash /opt/lifeagents/provisioning/compose/reach_ctl.sh start      Tunnel VOR der Installation (Wizard): REACH_MODE=tunnel
#        merken, Tailscale-Container starten, Anmeldung anstossen (reach_prepare); ist der Knoten schon angemeldet und darf
#        Funnel, steht sein Name danach als DOMAIN in core.env, und die eine Installation laeuft gleich mit der Adresse.
#        Idempotent (ein Neustart des Wizards ruft es erneut). Danach eine JSON-Zeile wie `status`.
#   bash /opt/lifeagents/provisioning/compose/reach_ctl.sh activate   Tunnel steht -> Adresse uebernehmen: derselbe
#        Installer-Lauf wie ein Update (provision.sh --unattended, gespeicherte Antworten); n8n setzt dabei den
#        Telegram-Webhook auf die neue Adresse. LIFEAGENTS_RESULT_FILE wird durchgereicht. Nur noch fuer den Umzug
#        (lib/move_cli.sh: neue Maschine, neue Adresse); der Wizard meldet vor der Installation an (`start`).
#        Danach eine JSON-Zeile wie `status`. Exit = der des Installer-Laufs.
#   bash /opt/lifeagents/provisioning/compose/reach_ctl.sh relogin    neu anmelden, z. B. nach abgelaufener Anmeldung
#        (reach_login_start, bei Ablauf mit --force-reauth; ein Neustart des Containers gaebe ohne das Start-Programm des
#        Images keinen Link mehr). Nie `tailscale reset`/`logout`: der Knoten bleibt derselbe. Nur beim Tunnel-Weg.
# Voraussetzung: LIFEAGENTS_RUNTIME=compose (sonst Abbruch); start und activate brauchen root.
# Exit: status 0; start 0; activate = Exit des Installer-Laufs; relogin 0; Abbruch per die 1; unbekanntes Verb 2.
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
rt_is_compose || die "reach_ctl.sh gilt nur im Docker-Verbund (LIFEAGENTS_RUNTIME=compose)."

case "${1:-}" in
  status) reach_status_json ;;
  start)
    [ "$(id -u)" -eq 0 ] || die "reach_ctl.sh start braucht root."
    REACH_MODE=tunnel reach_prepare >&2
    reach_status_json
    ;;
  activate)
    [ "$(id -u)" -eq 0 ] || die "reach_ctl.sh activate braucht root."
    ans="$(mktemp)"; trap 'rm -f "$ans"' EXIT
    # Nur die Kopfzeile: alle Antworten liegen schon in core.env (wie bei einem Update), REACH_MODE ebenso.
    printf '# lifeagents-answers v1\n' > "$ans"
    rc=0
    bash "$HERE/../provision.sh" --profile release --unattended "$ans" >&2 || rc=$?
    reach_status_json
    exit "$rc"
    ;;
  relogin)
    [ "$(reach_mode)" = tunnel ] || die "relogin gibt es nur beim Tunnel-Weg."
    reach_login_start >&2 || die "Tailscale-Anmeldung ließ sich nicht anstoßen ($(rt_edge_logs_hint tailscale))."
    reach_status_json
    ;;
  *) printf 'Usage: reach_ctl.sh status | start | activate | relogin\n' >&2; exit 2 ;;
esac
