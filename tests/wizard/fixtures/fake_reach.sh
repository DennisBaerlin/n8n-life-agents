#!/usr/bin/env bash
# Attrappe von provisioning/compose/reach_ctl.sh: `start` (Tunnel vor der Installation: Container starten, Anmeldung
# anstossen) und `stop` („Zurück“ vom Tunnel-Schritt). Den Zustand liefert die Attrappe der Brücke (reach-status, Datei
# $WIZARD_FAKE_DIR/reach).
# real-path-test: scripts/dev/tailscale_login_wait_test.ps1 (Link bleibt stehen, Anmeldung wie reach_login_start) und tests/mock_reach/compose_cases.sh Gruppe T (reach_login_start/reach_prepare gegen den echten Lib-Code)
set -euo pipefail
D="${WIZARD_FAKE_DIR:?}"
case "${1:-}" in start|stop) echo "$1" >> "$D/reach_calls" ;; *) exit 64 ;; esac
