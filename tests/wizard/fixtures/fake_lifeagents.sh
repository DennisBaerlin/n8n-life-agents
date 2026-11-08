#!/usr/bin/env bash
# Attrappe der lifeagents-CLI: nur `household pair-owner --machine <verb>` (owner_connect_machine). Verbunden ist der Owner,
# sobald $WIZARD_FAKE_DIR/paired existiert; reach scheitert, solange $WIZARD_FAKE_DIR/unreachable existiert.
set -euo pipefail
D="${WIZARD_FAKE_DIR:?}"
[ "${1:-} ${2:-} ${3:-}" = "household pair-owner --machine" ] || exit 64
case "${4:-}" in
  reach)    echo reach >> "$D/cli_reach_calls"; if [ -e "$D/unreachable" ]; then jq -nc '{ok:false, problem:"https://beispiel.example antwortet nicht"}'; else jq -nc '{ok:true}'; fi ;;
  arm)      echo arm >> "$D/pair_calls"; jq -nc '{ok:true, connected:false, bot:"beispiel_bot", link:"https://t.me/beispiel_bot?start=0123456789abcdef", expires_at:"2026-01-01T00:10:00Z"}' ;;
  status)   if [ -e "$D/paired" ]; then jq -nc '{ok:true, connected:true}'; else jq -nc '{ok:true, connected:false}'; fi ;;
  finalize) echo finalize >> "$D/pair_calls"; jq -nc '{ok:true, welcome_sent:true}' ;;
  *) exit 64 ;;
esac
