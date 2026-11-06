#!/usr/bin/env bash
# Attrappe von provisioning/compose/reach_ctl.sh (Paket 3): nur `activate` — der Installer-Nachlauf nach der Tunnel-Anmeldung.
# Danach meldet die Attrappe der Brücke den Zustand ready. Fehlschlag auf Wunsch: Datei $WIZARD_FAKE_DIR/activate_fail.
set -euo pipefail
D="${WIZARD_FAKE_DIR:?}"
[ "${1:-}" = activate ] || exit 64
[ -n "${LIFEAGENTS_RESULT_FILE:-}" ] || exit 66
echo activate >> "$D/reach_calls"
if [ -e "$D/activate_fail" ]; then printf 'status=failed\n' > "$LIFEAGENTS_RESULT_FILE"; exit 1; fi
printf '{"mode":"tunnel","state":"ready","url":"","dns_name":"beispiel.tailnet-beispiel.ts.net","key_days_left":12}\n' > "$D/reach"
printf 'status=ok\n' > "$LIFEAGENTS_RESULT_FILE"
