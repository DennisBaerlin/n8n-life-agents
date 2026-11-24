# telegram_cli.sh — `lifeagents telegram <verb>`: Wartung am Telegram-Bot, die kein Paket und keine Person betrifft.
# Gesourct von templates/lifeagents.tpl (mit common.sh, deploy_workflows.sh fuer _tg_post, owner_connect.sh fuer relink).
#
# Verben:
#   release-webhook   Webhook des Bots loesen (deleteWebhook, ohne drop_pending_updates). Die Start-App ruft das vor dem
#                     Abbau des Docker-Verbunds, damit der Bot nicht auf eine tote Adresse zeigt
#                     (provisioning/desktop/core/src/contract.rs, MasterCmd::ReleaseWebhook).
#   relink            Bot wieder mit DIESER Installation verbinden: Orchestrator abmelden + neu veroeffentlichen (n8n ruft dann
#                     setWebhook; ein Neustart von n8n tut das nicht), danach getWebhookInfo gegen die eigene Domain pruefen.
#                     Nur auf Zuruf, nie im Hintergrund: zwei Systeme mit demselben Bot nahmen ihn sich sonst gegenseitig weg.
#                     Umzug: retire gibt den Webhook frei, erst die neue Maschine verbindet; eine stillgelegte Installation
#                     lehnt relink ab (lifeagents.tpl _retired_allows). Schon verbunden = nichts tun (ein Re-Publish verwirft
#                     bei Telegram wartende Nachrichten).
# Exit: 0 = Webhook gelost oder nichts zu loesen (kein Bot-Schluessel); 1 = Telegram nicht erreichbar/abgelehnt
#   (Grund auf stderr, nie der Schluessel); 2 = unbekanntes Verb. Die App wertet nur 0 gegen != 0 aus.
#   relink: 0 = verbunden oder schon verbunden; 1 = Voraussetzung fehlt, n8n oder Telegram lehnt ab.
# Der Schluessel kommt wie bei den anderen Telegram-Aufrufen aus TELEGRAM_BOT_TOKEN bzw. core.env (owner_tg_token);
# im Docker-Verbund liegt core.env im master an derselben Stelle (LIFEAGENTS_DIR).

telegram_usage() {
  cat >&2 <<'USAGE'
lifeagents telegram — Wartung am Telegram-Bot.

Usage: lifeagents telegram <verb>

  release-webhook   Webhook des Bots loesen (deleteWebhook); Exit 0 = geloest oder nichts zu loesen.
  relink            Bot wieder mit dieser Installation verbinden (wenn Telegram ihn nicht erreicht, z. B. weil ein anderes System
                    denselben Bot nutzt); aendert nichts, wenn er schon verbunden ist.
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

telegram_cmd_relink() {
  # Bewusst mit Anfangswert: ein bloesses `local N8N_URL` verdeckte den Wert aus der Prozess-Umgebung (override-first).
  local TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" N8N_API_KEY="${N8N_API_KEY:-}" N8N_URL="${N8N_URL:-}" DOMAIN="${DOMAIN:-}" core port st id info url
  need_cmd jq || { warn "jq fehlt — der Bot laesst sich so nicht neu verbinden."; return 1; }
  TELEGRAM_BOT_TOKEN="$(owner_tg_token)"
  if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    warn "Kein Telegram-Bot-Schluessel hinterlegt — es gibt keinen Bot zu verbinden (lifeagents reconfigure, Grundsystem)."
    return 1
  fi
  # core.env wird nur gelesen (read_env_value), nie gesourct: Werte stehen roh ohne Anfuehrungszeichen (Namen mit Leerzeichen).
  core="$(lifeagents_env_file core)"
  N8N_API_KEY="${N8N_API_KEY:-$(read_env_value "$core" N8N_API_KEY 2>/dev/null || true)}"
  DOMAIN="$(normalize_domain "${DOMAIN:-$(read_env_value "$core" DOMAIN 2>/dev/null || true)}")"
  if [ -z "$N8N_API_KEY" ]; then warn "Kein n8n-Zugangsschluessel in ${core} — die Installation ist nicht fertig eingerichtet."; return 1; fi
  if [ -z "$DOMAIN" ]; then warn "Keine Internet-Adresse hinterlegt — ohne sie kann Telegram den Bot nicht erreichen (lifeagents reconfigure, Grundsystem)."; return 1; fi
  port="$(read_env_value "${N8N_ENV_FILE:-/etc/n8n/n8n.env}" N8N_PORT 2>/dev/null || true)"
  N8N_URL="${N8N_URL:-http://127.0.0.1:${port:-5678}}"

  info="$(_oc_webhook_info)"
  if ! _oc_webhook_known "$info"; then warn "$_OC_TG_UNKNOWN"; return 1; fi
  if tg_webhook_delivers "$info" "$DOMAIN"; then
    ok "Der Bot ist schon mit dieser Installation verbunden (${DOMAIN}) — nichts geaendert."
    return 0
  fi
  url="$(printf '%s' "$info" | jq -r '.result.url // ""')"
  if tg_webhook_foreign "$info" "$DOMAIN"; then
    log "Telegram stellt den Bot gerade an $(url_host "$url") zu — ein anderes System nutzt denselben Bot. Es wird jetzt auf diese Installation zurueckgestellt; das andere System bekommt dann keine Nachrichten mehr."
  fi
  st="$(n8n_orchestrator_state "$N8N_API_KEY" "$N8N_URL")"
  if [ -z "$st" ]; then warn "n8n antwortet nicht oder der Bot-Workflow fehlt (lifeagents doctor zeigt Details)."; return 1; fi
  id="${st%%$'\t'*}"
  # Abmelden + neu veroeffentlichen erzwingt ein frisches setWebhook; ein Neustart von n8n tut das nicht. Nachrichten, die
  # Telegram noch fuer die fremde Adresse vorhielt, gehen dabei verloren.
  if ! _oc_activate_orchestrator "$id"; then
    warn "n8n konnte den Bot nicht neu veroeffentlichen: ${_OC_ACT_ERR}"
    return 1
  fi
  info="$(_oc_webhook_info)"
  if ! _oc_webhook_known "$info"; then warn "$_OC_TG_UNKNOWN"; return 1; fi
  if ! tg_webhook_points_to "$info" "$DOMAIN"; then
    url="$(printf '%s' "$info" | jq -r '.result.url // ""')"
    warn "Telegram hat keine Adresse fuer ${DOMAIN} gespeichert (aktuell: $(url_host "$url")). Ist die Adresse von aussen erreichbar? lifeagents doctor zeigt es."
    return 1
  fi
  ok "Der Bot ist wieder mit dieser Installation verbunden (${DOMAIN})."
  return 0
}

telegram_cli() {
  local verb="${1:-help}"; [ "$#" -gt 0 ] && shift || true
  case "$verb" in
    release-webhook) telegram_cmd_release_webhook "$@" ;;
    relink) telegram_cmd_relink "$@" ;;
    help|--help|-h) telegram_usage ;;
    *) telegram_usage; printf '\nlifeagents telegram: unbekanntes Verb: %s\n' "$verb" >&2; return 2 ;;
  esac
}
