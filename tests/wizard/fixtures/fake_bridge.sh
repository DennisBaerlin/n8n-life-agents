#!/usr/bin/env bash
# Attrappe der Wizard-Brücke für die Gratis-Tests: Fragen, lokale Prüfregeln und Paperless-Prüfung kommen aus der ECHTEN
# bridge.sh; nur Live-Dienste (Telegram, Anthropic, Google) und die Schnittstellen zu Paket 1/3 sind fest verdrahtet.
# Steuerung über Dateien in $WIZARD_FAKE_DIR: reach (Tunnel-Zustand), ports (free|busy), tg_conflict (Host).
set -euo pipefail
REAL="${WIZARD_FAKE_REAL_BRIDGE:?}"
D="${WIZARD_FAKE_DIR:?}"
case "${1:-}" in
  validate)
    case "${2:-}" in
      host:TELEGRAM_BOT_TOKEN|host:ANTHROPIC_API_KEY|host:GOOGLE_API_KEY)
        v="$(cat)"
        case "$v" in
          *bad*)     jq -nc '{rc:1, value:"", problem:""}' ;;
          *offline*) jq -nc --arg v "$v" '{rc:2, value:$v, problem:""}' ;;
          *)         jq -nc --arg v "$v" '{rc:0, value:$v, problem:""}' ;;
        esac ;;
      *) exec bash "$REAL" "$@" ;;
    esac ;;
  tg-check)
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || { jq -nc '{ok:false, reason:"unauthorized"}'; exit 0; }
    printf '%s' "$TELEGRAM_BOT_TOKEN" > "$D/tg_token_seen"
    host="$(cat "$D/tg_conflict" 2>/dev/null || true)"
    jq -nc --arg h "$host" '{ok:true, bot:"beispiel_bot", webhook_host:$h, polling_conflict:false}' ;;
  reach-status)
    st="$(cat "$D/reach" 2>/dev/null || echo ready)"
    jq -nc --arg s "$st" '{state:$s, url:(if $s == "needs_login" then "https://login.tailscale.com/a/beispiel123" elif $s == "needs_funnel" then "https://evil.example/phish" else "" end)}' ;;
  reach-ports)
    jq -nc --arg s "$(cat "$D/ports" 2>/dev/null || echo unknown)" '{state:$s}' ;;
  *) exec bash "$REAL" "$@" ;;
esac
