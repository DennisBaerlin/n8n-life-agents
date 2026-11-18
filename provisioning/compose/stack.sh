#!/usr/bin/env bash
# stack.sh — Kern des Docker-Verbunds (Logik: lib/stack_core.sh). Im master-Abbild als Befehl `stack` (master.Dockerfile).
# Jeder Einstieg (Start-App, setup.sh, CI) startet den Verbund nur ueber genau diese Form, nie mit eigener Start-Logik:
#
#   docker run --rm -i --name <projekt>-core --label io.lifeagents.install=<projekt> \
#     --env LA_CORE=1 [--env LA_PROJECT=<projekt>] \
#     --mount type=bind,src=<socket des rechners>,dst=/var/run/docker.sock \
#     <register>/master@sha256:<…> stack <verb> [--json] [optionen]
#
# Abbild immer in der Schreibweise des Release-Pins (der Kern setzt sie als LA_MASTER_IMAGE ein). Kein Wert im Aufruf: Ports,
# Passwort und Tailscale-Name erzeugt und merkt sich der Kern im Volume <projekt>_var_la. Der feste Name sperrt einen zweiten
# Kern (Docker scheitert mit Exit 125 „name already in use“, bevor etwas geschieht); ein Einstieg fragt vorher
# `docker inspect <projekt>-core`, laeuft er, ist das busy.
#
# Verben:
#   check                       Faehigkeits-Pruefung (Docker, Linux-Container, Engine >= 26.0, Unterpfad, Socket, Platz)
#   up                          Werte anlegen (einmalig), Volumes, anchor/postgres/master/edge; Zweitlauf aendert nichts
#   start                       nur vorhandene Container starten
#   status                      Zustand (auch `docker exec <projekt>-master stack status`)
#   wizard-url [--hints-stdin]  Einmal-Link zum Fragebogen (stdin = hints.env fuer den Fragebogen)
#   install [-- <optionen>]     Antwort-Datei ueber stdin, provision.sh --unattended im master (Automatik, CI)
#   uninstall [--delete-data]   Webhook loesen, Container + Netze + abgeleitete Volumes entfernen; mit --delete-data auch
#                               Daten-Volumes (nur mit unserem Label) und die selbst geladenen Abbilder der compose.yml
# Ausgabe mit --json: JSON-Zeilen auf stdout (Vertrag: Kopf von lib/stack_core.sh), Text auf stderr.
# Exit: 0 = ok, 1 = abgelehnt/gescheitert (reason im result), 2 = Aufruf falsch.
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
# shellcheck source=../lib/stack_core.sh
. "$HERE/../lib/stack_core.sh"
sc_main "$@"
