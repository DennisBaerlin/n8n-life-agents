# telegram_cli.sh — `lifeagents telegram <verb>`: Wartung am Telegram-Bot, die kein Paket und keine Person betrifft.
# Gesourct von templates/lifeagents.tpl (mit common.sh + deploy_workflows.sh fuer _tg_post).
#
# Verben:
#   release-webhook   Webhook des Bots loesen (deleteWebhook, ohne drop_pending_updates). Die Start-App ruft das vor dem
#                     Abbau des Docker-Verbunds, damit der Bot nicht auf eine tote Adresse zeigt
#                     (provisioning/desktop/core/src/contract.rs, MasterCmd::ReleaseWebhook).
# Exit: 0 = Webhook gelost oder nichts zu loesen (kein Bot-Schluessel); 1 = Telegram nicht erreichbar/abgelehnt
#   (Grund auf stderr, nie der Schluessel); 2 = unbekanntes Verb. Die App wertet nur 0 gegen != 0 aus.
# Der Schluessel kommt wie bei den anderen Telegram-Aufrufen aus TELEGRAM_BOT_TOKEN bzw. core.env (owner_tg_token);
# im Docker-Verbund liegt core.env im master an derselben Stelle (LIFEAGENTS_DIR).

telegram_usage() {
  cat >&2 <<'USAGE'
lifeagents telegram — Wartung am Telegram-Bot.

Usage: lifeagents telegram <verb>

  release-webhook   Webhook des Bots loesen (deleteWebhook); Exit 0 = geloest oder nichts zu loesen.
  help              Diese Hilfe.
USAGE
}

telegram_cmd_release_webhook() {
  local token; token="$(owner_tg_token)"
  if [ -z "$token" ]; then
    log "Kein Telegram-Bot-Schluessel hinterlegt -> kein Webhook zu loesen."
    return 0
  fi
  if _tg_post "$token" deleteWebhook '{}'; then
    [ -z "$TG_RETRIED" ] || note "Webhook loesen: erster Versuch scheiterte (${TG_RETRIED}), zweiter gelungen."
    ok "Telegram-Webhook geloest."
    return 0
  fi
  warn "Telegram-Webhook nicht geloest: ${TG_ERR}"
  return 1
}

telegram_cli() {
  local verb="${1:-help}"; [ "$#" -gt 0 ] && shift || true
  case "$verb" in
    release-webhook) telegram_cmd_release_webhook "$@" ;;
    help|--help|-h) telegram_usage ;;
    *) telegram_usage; printf '\nlifeagents telegram: unbekanntes Verb: %s\n' "$verb" >&2; return 2 ;;
  esac
}
