# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) in den Nutzertexten sind gewollt
# proxy_cli.sh — `lifeagents proxy show|set` (Install-UX-Phase 5): wo laeuft der Reverse Proxy, wem ist n8n
# geoeffnet? EIN Fakt TRUSTED_PROXIES in /etc/lifeagents/core.env; `set` schreibt ihn und wendet ihn ueber
# DENSELBEN Pfad wie die Installation an (`provision.sh --apply-network`: firewall_converge -> prepare_n8n_env ->
# install_n8n_unit) — keine zweite Render-Logik. Sourced by templates/lifeagents.tpl (mit common.sh, release_inputs.sh,
# firewall.sh, owner_connect.sh). Kein `refresh`: es werden nie Namen gespeichert (arch-challenge REJECT-mit-Notiz).

PROXY_CORE_ENV="${LIFEAGENTS_DIR:-/etc/lifeagents}/core.env"
PROXY_N8N_ENV="/etc/n8n/n8n.env"

# _proxy_load — TRUSTED_PROXIES/DOMAIN/N8N_PORT aus den Env-Dateien (Env-Override gewinnt).
_proxy_load() {
  TRUSTED_PROXIES="${TRUSTED_PROXIES:-$(read_env_value "$PROXY_CORE_ENV" TRUSTED_PROXIES 2>/dev/null || true)}"
  DOMAIN="${DOMAIN:-$(read_env_value "$PROXY_CORE_ENV" DOMAIN 2>/dev/null || true)}"
  N8N_PORT="${N8N_PORT:-$(read_env_value "$PROXY_N8N_ENV" N8N_PORT 2>/dev/null || true)}"
  N8N_PORT="${N8N_PORT:-5678}"
  # shellcheck disable=SC2034  # gelesen von emit_ingress_help/firewall.sh (gesourcte Geschwister)
  N8N_ENV_FILE="$PROXY_N8N_ENV"
}

proxy_cmd_show() {
  # root noetig: core.env ist 640 root:n8n — ohne Leserecht saehe show "kein Proxy" und laege falsch.
  [ "$(id -u)" -eq 0 ] || die "lifeagents proxy show braucht root (liest /etc/lifeagents/core.env)."
  _proxy_load
  local list nonloop bind fw
  list="$(normalize_trusted_proxies "${TRUSTED_PROXIES:-}" 2>/dev/null || printf 'UNGÜLTIG: %s' "$TRUSTED_PROXIES")"
  nonloop="$(_proxy_nonloop "$list")"
  bind="$(read_env_value "$PROXY_N8N_ENV" N8N_LISTEN_ADDRESS 2>/dev/null || echo '?')"
  if [ -z "$nonloop" ]; then
    fw="keine (nicht nötig)"
  elif [ "$(id -u)" -ne 0 ]; then
    fw="(Prüfung braucht root)"   # unerreichbar seit dem root-Gate oben; bleibt als Absicherung
  elif systemctl is-active --quiet lifeagents-firewall.service && firewall_set_matches "$list"; then
    fw="aktiv — n8n nur für $(printf '%s' "$nonloop" | paste -sd, - | sed 's/,/, /g')"
  else
    fw="FEHLT/weicht ab — erneut anwenden: lifeagents proxy set ${list}"
  fi
  ui_box 'Reverse Proxy' <<EOF
Proxy läuft:      $( [ -z "$nonloop" ] && printf 'auf diesem Rechner' || printf 'auf einem anderen Rechner (%s)' "$(printf '%s' "$nonloop" | paste -sd, - | sed 's/,/, /g')" )
n8n lauscht auf:  ${bind}:${N8N_PORT}
Firewall:         ${fw}
Internet-Adresse: ${DOMAIN:-— (keine, nur Heimnetz)}

Ändern: lifeagents proxy set <IP des Proxy-Rechners>   (zurück auf diesen Rechner: lifeagents proxy set 127.0.0.1)
EOF
  if [ -n "${DOMAIN:-}" ]; then
    emit_ingress_help "${LIFEAGENTS_PROV:-/usr/local/lib/lifeagents/provisioning}/templates" "$DOMAIN" "$N8N_PORT" "https://${DOMAIN}/"
  fi
}

proxy_cmd_set() {
  local raw="${1:-}" list ip confirm
  [ "$(id -u)" -eq 0 ] || die "lifeagents proxy set braucht root (ändert Firewall + n8n-Einstellungen)."
  if [ -z "$raw" ] && ui_interactive; then
    raw="$(ui_input "IP-Adresse des Proxy-Rechners (127.0.0.1 = Proxy auf diesem Rechner): " 0)"
  fi
  [ -n "$raw" ] || die "Usage: lifeagents proxy set <IP des Proxy-Rechners>[,…]   (127.0.0.1 = Proxy auf diesem Rechner)"
  if printf '%s' "$raw" | grep -qE '[A-Za-z]'; then
    ip="$( { getent ahostsv4 "$raw" 2>/dev/null || true; } | awk 'NR==1 {print $1}')"
    [ -n "$ip" ] || die "„${raw}“ lässt sich nicht auflösen — bitte die IP-Adresse angeben."
    log "${raw} → ${ip} (gespeichert wird die IP; ändert sie sich, erneut 'lifeagents proxy set')"
    raw="$ip"
  fi
  list="$(normalize_trusted_proxies "$raw")" || die "Ungültige Adresse."
  if printf '%s' "$list" | grep -q '/' && ui_interactive; then
    confirm="$(printf '%s\n' "Nein, abbrechen	no" "Ja, das ganze Netz freigeben	yes" \
                 | ui_choose "„${list}“ enthält ein ganzes Netz — jedes Gerät darin käme an die n8n-Anmeldeseite. Wirklich?" 0)"
    [ "$confirm" = "yes" ] || die "Abgebrochen — nichts geändert."
  fi
  ensure_lifeagents_dir
  env_upsert "$PROXY_CORE_ENV" TRUSTED_PROXIES "$list"
  chmod 0640 "$PROXY_CORE_ENV" 2>/dev/null || true
  chown "root:n8n" "$PROXY_CORE_ENV" 2>/dev/null || true
  ok "Gespeichert: TRUSTED_PROXIES=${list} — wende an (n8n startet dabei neu) ..."
  exec bash "${LIFEAGENTS_PROV:-/usr/local/lib/lifeagents/provisioning}/provision.sh" --apply-network
}

proxy_cli() {
  local verb="${1:-show}"; shift || true
  case "$verb" in
    show)  proxy_cmd_show "$@" ;;
    set)   proxy_cmd_set "$@" ;;
    help|--help|-h)
      cat >&2 <<'EOF'
lifeagents proxy <verb> — wo läuft dein Reverse Proxy, und wem ist n8n geöffnet?

  show                 Aktuellen Stand anzeigen + die passende Proxy-Konfiguration erneut ausgeben
                       (komplettes Caddyfile bzw. Einfüge-Baustein für einen Proxy auf einem anderen Rechner).
  set <ip>[,…]         Proxy läuft auf einem ANDEREN Rechner mit dieser IPv4-Adresse: n8n lauscht dann im
                       Heimnetz, eine Firewall lässt NUR diese Adresse(n) an n8n. 127.0.0.1 = Proxy auf
                       diesem Rechner (n8n wieder nur lokal). Startet n8n neu. Braucht root.
EOF
      ;;
    *) die "Unbekanntes Verb: proxy ${verb} (lifeagents proxy help)." ;;
  esac
}
