# shellcheck disable=SC1111,SC2034  # SC1111: deutsche Anfuehrungszeichen in Nutzertexten gewollt; SC2034: REACH_* lesen die Aufrufer
# reach.sh — Weg nach aussen im Docker-Verbund (LIFEAGENTS_RUNTIME=compose; Plan docker-installer-freunde *Der Rand*).
# GESOURCT (kein Shebang, kein set -e). Docker nur ueber lib/runtime.sh (rt_edge_*, rt_stack_up,
# rt_host_port_free). Die CLI-Installation (systemd) beruehrt diese Datei nicht.
#
# Der Rand (`edge`, Caddy, compose.yml LA_CADDYFILE) hat drei Eingaenge: :8080 Editor und :8081 Wizard nur ueber
# 127.0.0.1 des Rechners, :8088 = die EINE Liste oeffentlicher Pfade (templates/Caddyfile.tpl, contract_lint 34). Beide
# Wege nach aussen enden auf :8088:
#   tunnel   (empfohlen) Dienst `tailscale` (Profil tunnel) im Netz-Namensraum des Rands, Zustand im Volume ts_state.
#            Anmeldung ohne Schluessel: Tailscale stellt einen Anmelde-Link aus (Status-Feld AuthURL). Funnel nimmt HTTPS
#            auf 443 an, beendet TLS und reicht an 127.0.0.1:8088 weiter (`tailscale funnel --bg`, bleibt im Zustand
#            gespeichert). Die Internet-Adresse ist der Tailscale-Name <rechner>.<tailnet>.ts.net: reach_prepare
#            uebernimmt ihn als DOMAIN, n8n setzt beim Aktivieren des Telegram-Ausloesers den Webhook darauf. Ein Tailscale
#            auf dem Rechner selbst bleibt unberuehrt (eigener Knoten, eigener Namensraum); nie `tailscale reset`/`logout`.
#   fritzbox Dienst `wan` (Caddy, Profil fritzbox) veroeffentlicht 80/443 am Rechner, holt das Zertifikat fuer DOMAIN
#            (MyFRITZ!-Adresse) selbst und reicht an edge:8088 weiter. Vorher muessen 80 und 443 frei sein (Pruefliste
#            Nr. 13); sonst startet nichts und der Status raet zum Tunnel — nie etwas ueberschreiben.
# Den Weg waehlt der Wizard (REACH_MODE in der Antwort-Datei); gespeichert in core.env, damit ein Update ihn behaelt.

REACH_CORE_ENV="${LIFEAGENTS_DIR:-/etc/lifeagents}/core.env"
REACH_CONF_DIR="${REACH_CONF_DIR:-/var/lib/lifeagents-reach}"   # Volume reach_conf (master rw, wan ro): Adresse fuer wan
REACH_RUN_DIR="${REACH_RUN_DIR:-/run/lifeagents-reach}"          # fluechtig: zuletzt gesehener Freigabe-Link (Zwischenspeicher)
REACH_PUBLIC_TARGET='http://127.0.0.1:8088'                      # Funnel-Ziel im Namensraum des Rands (= edge :8088)
REACH_LOGIN_RE='^https://login\.tailscale\.com/[A-Za-z0-9/?=&._~%+-]*$'

# reach_mode -> tunnel | fritzbox | none. REACH_MODE aus der Umgebung (Antwort-Datei) vor dem gespeicherten Wert.
reach_mode() {
  local m="${REACH_MODE:-}"
  [ -n "$m" ] || m="$(read_env_value "$REACH_CORE_ENV" REACH_MODE 2>/dev/null || true)"
  case "$m" in tunnel|fritzbox) printf '%s' "$m" ;; *) printf 'none' ;; esac
}

# --- Tunnel (Tailscale) ---------------------------------------------------------------------------------------------
# reach_ts_eval <status-json> [jetzt-epoch] — `tailscale status --json` einordnen (rein, ohne Docker; Fall-Tests mit
#   Attrappen-JSON). Setzt REACH_TS_STATE (starting | needs_login | needs_machine_auth | needs_funnel | key_expired |
#   stopped | running), REACH_TS_URL (Anmelde-Link, nur login.tailscale.com), REACH_TS_DNS (ohne Schluss-Punkt),
#   REACH_TS_KEY_EXPIRY (RFC 3339 oder leer = Ablauf abgeschaltet), REACH_TS_KEY_DAYS (ganze Tage, leer = kein Ablauf).
#   `running` heisst: angemeldet UND der Knoten darf HTTPS + Funnel (Node-Faehigkeiten "https" und "funnel"; fehlt eine,
#   muss der Nutzer Funnel im Konto freigeben -> needs_funnel). Felder laut ipn/ipnstate (BackendState, AuthURL,
#   Self.DNSName/KeyExpiry/Expired/CapMap).
reach_ts_eval() {
  local js="$1" now="${2:-$(date +%s)}" row
  REACH_TS_STATE=starting; REACH_TS_URL=''; REACH_TS_DNS=''; REACH_TS_KEY_EXPIRY=''; REACH_TS_KEY_DAYS=''
  [ -n "$js" ] || return 0
  row="$(printf '%s' "$js" | jq -r --argjson now "$now" '
    def caps: (((.Self.CapMap // {}) | keys) + (.Self.Capabilities // []));
    def epoch: try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch null;
    (.BackendState // "") as $b
    | (.Self.KeyExpiry // "") as $ke
    | (if $ke == "" then null else ($ke | epoch) end) as $ks
    | (if $ks == null then null else ((($ks - $now) / 86400) | floor) end) as $days
    | ((.Self.Expired // false) or ($ks != null and $ks <= $now)) as $exp
    | (if $b == "NeedsLogin" then (if $exp then "key_expired" elif (.AuthURL // "") != "" then "needs_login" else "starting" end)
       elif $b == "NeedsMachineAuth" then "needs_machine_auth"
       elif $b == "Running" then (if $exp then "key_expired"
                                  elif ((caps | index("https")) != null and (caps | index("funnel")) != null) then "running"
                                  else "needs_funnel" end)
       elif $b == "Stopped" then "stopped"
       else "starting" end) as $st
    | [$st, (.AuthURL // ""), ((.Self.DNSName // "") | rtrimstr(".")), $ke, (if $days == null then "" else ($days | tostring) end)]
    | join("\u001f")' 2>/dev/null)" || return 0
  [ -n "$row" ] || return 0
  # Trenner \x1f statt Tab: Tab ist Leerraum fuer `read`, zwei Tabs (leeres Feld) verschmelzen sonst zu einem.
  IFS=$'\x1f' read -r REACH_TS_STATE REACH_TS_URL REACH_TS_DNS REACH_TS_KEY_EXPIRY REACH_TS_KEY_DAYS <<<"$row"
  printf '%s' "$REACH_TS_URL" | grep -qE "$REACH_LOGIN_RE" || REACH_TS_URL=''
  printf '%s' "$REACH_TS_DNS" | grep -qiE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' || REACH_TS_DNS=''
  return 0
}

# _reach_ts_status -> `tailscale status --json` aus dem Tailscale-Container (leer, wenn er nicht laeuft/antwortet).
_reach_ts_status() {
  rt_edge_active tailscale || return 0
  rt_edge_exec tailscale tailscale status --json --peers=false 2>/dev/null || true
}

# reach_funnel_configured <dns> <funnel-status-json> -> 0, wenn Funnel fuer <dns>:443 an ist und auf :8088 zeigt.
reach_funnel_configured() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  [ "$(printf '%s' "$2" | jq -r --arg k "$1:443" --arg t "$REACH_PUBLIC_TARGET" \
        '((.AllowFunnel[$k] // false) == true) and ((.Web[$k].Handlers["/"].Proxy // "") == $t)' 2>/dev/null)" = true ]
}

# reach_funnel_ensure <dns> — Funnel auf 443 -> :8088 einschalten, falls noch nicht (idempotent; der Nutzer hat dem
#   Tunnel in der 2. Bestaetigung zugestimmt). Nur bei REACH_TS_STATE=running sinnvoll. rc 0 = an.
reach_funnel_ensure() {
  local dns="$1" st
  st="$(rt_edge_exec tailscale tailscale funnel status --json 2>/dev/null || true)"
  reach_funnel_configured "$dns" "$st" && return 0
  rt_edge_exec tailscale timeout 20 tailscale funnel --bg --yes "$REACH_PUBLIC_TARGET" >/dev/null 2>&1 || true
  st="$(rt_edge_exec tailscale tailscale funnel status --json 2>/dev/null || true)"
  reach_funnel_configured "$dns" "$st"
}

# reach_funnel_link — Link zur Freigabe-Seite im Tailscale-Konto (HTTPS + Funnel fuer diesen Knoten). Tailscale gibt ihn
#   nur aus, wenn man Funnel einschalten will (CLI: enableFeatureInteractive -> QueryFeature); der Aufruf wartet danach
#   auf die Freigabe -> kurze Frist, Link 5 Min zwischengespeichert (der Wizard fragt alle paar Sekunden). Gibt der Nutzer
#   frei, waehrend der Aufruf wartet, schaltet derselbe Aufruf Funnel gleich ein.
reach_funnel_link() {
  local f="$REACH_RUN_DIR/funnel-link" url age
  if [ -s "$f" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    if [ "$age" -lt 300 ]; then cat "$f"; return 0; fi
  fi
  url="$(rt_edge_exec tailscale timeout 8 tailscale funnel --bg --yes "$REACH_PUBLIC_TARGET" 2>&1 \
          | grep -oE 'https://login\.tailscale\.com/[A-Za-z0-9/?=&._~%+-]+' | head -n1 || true)"
  printf '%s' "$url" | grep -qE "$REACH_LOGIN_RE" || return 0
  ( umask 077; mkdir -p "$REACH_RUN_DIR" && printf '%s' "$url" > "$f" ) 2>/dev/null || true
  printf '%s' "$url"
}

# --- Telegram -------------------------------------------------------------------------------------------------------
# reach_webhook_state <domain> -> ours | none | foreign | unknown: zeigt der Bot (getWebhookInfo) auf https://<domain>/?
#   Nur lesend; ein Netz-Wackler ist "unknown", nie "none" (owner_connect.sh _oc_webhook_known).
reach_webhook_state() {
  local tok js url
  tok="${TELEGRAM_BOT_TOKEN:-$(read_env_value "$REACH_CORE_ENV" TELEGRAM_BOT_TOKEN 2>/dev/null || true)}"
  [ -n "$tok" ] || { printf 'unknown'; return 0; }
  js="$(tg_api_curl "$tok" getWebhookInfo -fsS --max-time 8 2>/dev/null || true)"
  [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = true ] || { printf 'unknown'; return 0; }
  url="$(printf '%s' "$js" | jq -r '.result.url // ""' 2>/dev/null)"
  if [ -z "$url" ]; then printf 'none'
  elif [ -n "$1" ] && [ "${url#"https://${1}/"}" != "$url" ]; then printf 'ours'
  else printf 'foreign'; fi
}

# --- FritzBox (wan) -------------------------------------------------------------------------------------------------
# reach_ports_free -> 0, wenn 80 UND 443 am Rechner frei sind (rt_host_port_free: Kurzlauf-Container, Pruefliste Nr. 13).
reach_ports_free() { rt_host_port_free 80 && rt_host_port_free 443; }

# reach_wan_write_domain <domain> -> 0 = Datei geaendert (wan muss neu starten), 1 = unveraendert. Nur geprueft gueltige
#   Namen (domain_problem); wan liest die Datei beim Start und prueft sie selbst noch einmal.
reach_wan_write_domain() {
  local d="$1" f="$REACH_CONF_DIR/domain"
  [ -z "$(domain_problem "$d")" ] || die "Internet-Adresse für den FritzBox-Weg ungültig: $(domain_problem "$d")."
  [ "$(cat "$f" 2>/dev/null || true)" = "$d" ] && return 1
  mkdir -p "$REACH_CONF_DIR" && printf '%s\n' "$d" > "$f.tmp" && chmod 0644 "$f.tmp" && mv -f "$f.tmp" "$f"
}

# --- Status fuer Wizard und Start-App -------------------------------------------------------------------------------
# reach_status_json — EINE JSON-Zeile (Format: docs/reference/provisioning.md *Docker-Verbund: Erreichbarkeit*):
#   {"mode","state","url","dns_name","key_expiry","key_days_left","webhook","reason"}. Aendert nichts, ausser beim Tunnel
#   den Funnel einzuschalten, sobald das Konto ihn erlaubt (die Zustimmung kam mit der 2. Bestaetigung).
reach_status_json() {
  local mode state='unavailable' url='' dns='' kexp='' kdays='' wh='unknown' reason='' dom
  mode="$(reach_mode)"
  dom="$(read_env_value "$REACH_CORE_ENV" DOMAIN 2>/dev/null || true)"
  case "$mode" in
    tunnel)
      if ! rt_edge_active tailscale; then reason='not_started'
      else
        reach_ts_eval "$(_reach_ts_status)"
        state="$REACH_TS_STATE"; url="$REACH_TS_URL"; dns="$REACH_TS_DNS"; kexp="$REACH_TS_KEY_EXPIRY"; kdays="$REACH_TS_KEY_DAYS"
        case "$state" in
          stopped) state=unavailable; reason='stopped' ;;
          needs_funnel) url="$(reach_funnel_link)" ;;
          running)
            if [ -z "$dns" ] || ! reach_funnel_ensure "$dns"; then state=needs_funnel; url="$(reach_funnel_link)"
            else
              wh="$(reach_webhook_state "$dns")"
              if [ "$dom" = "$dns" ] && [ "$wh" = ours ]; then state=ready; else state=pending_activation; fi
            fi ;;
        esac
      fi ;;
    fritzbox)
      dns="$dom"
      if [ -z "$dom" ]; then reason='no_domain'
      elif rt_edge_active wan; then
        wh="$(reach_webhook_state "$dom")"
        if [ "$wh" = ours ]; then state=ready; else state=pending_activation; fi
      elif ! reach_ports_free; then state=ports_busy
      else state=starting; reason='not_started'; fi ;;
    *) reason='no_mode' ;;
  esac
  jq -nc --arg mode "$mode" --arg state "$state" --arg url "$url" --arg dns "$dns" --arg kexp "$kexp" \
    --arg kdays "$kdays" --arg wh "$wh" --arg reason "$reason" \
    '{mode:$mode, state:$state, url:$url, dns_name:$dns, key_expiry:$kexp,
      key_days_left:(if $kdays == "" then null else ($kdays | tonumber) end), webhook:$wh, reason:$reason}'
}

# --- Installer-Haken (provision.sh, nur im Verbund) -----------------------------------------------------------------
# reach_prepare — frueh im Lauf (nach load_install_env, vor derive_network_config): Weg pruefen und merken; beim Tunnel
#   den Tailscale-Knoten starten (Anmelde-Link liegt bereit, bis der Wizard zum Schritt „Verbinden" kommt) und, sobald er
#   angemeldet ist und Funnel darf, dessen Namen als DOMAIN uebernehmen. Ohne fertigen Tunnel bleibt DOMAIN, wie es ist
#   (ein Update mit kurz abwesendem Tailscale loescht die Adresse nie).
reach_prepare() {
  local m
  if [ -n "${REACH_MODE:-}" ]; then
    case "$REACH_MODE" in tunnel|fritzbox) : ;; *) die "REACH_MODE ungültig: erwartet tunnel oder fritzbox." ;; esac
    if [ "$(read_env_value "$REACH_CORE_ENV" REACH_MODE 2>/dev/null || true)" != "$REACH_MODE" ]; then
      ensure_lifeagents_dir
      env_upsert "$REACH_CORE_ENV" REACH_MODE "$REACH_MODE"
    fi
  fi
  m="$(reach_mode)"
  [ "$m" = tunnel ] || return 0
  rt_stack_up --no-deps tailscale >/dev/null 2>&1 || { warn "Tunnel: Tailscale-Container ließ sich nicht starten ($(rt_edge_logs_hint tailscale))."; return 0; }
  reach_ts_eval "$(_reach_ts_status)"
  if [ "$REACH_TS_STATE" = running ] && [ -n "$REACH_TS_DNS" ] && reach_funnel_ensure "$REACH_TS_DNS"; then
    if [ "${DOMAIN:-}" != "$REACH_TS_DNS" ]; then
      log "Tunnel steht: Internet-Adresse ${REACH_TS_DNS} (Tailscale Funnel)."
      DOMAIN="$REACH_TS_DNS"; export DOMAIN
      ensure_lifeagents_dir
      env_upsert "$REACH_CORE_ENV" DOMAIN "$DOMAIN"
    fi
  else
    log "Tunnel noch nicht fertig (Tailscale: ${REACH_TS_STATE}) — die Internet-Adresse folgt nach der Anmeldung."
  fi
}

# reach_converge — spaet im Lauf (nach dem Deploy): FritzBox-Weg anwerfen. Adresse fuer wan schreiben; laeuft wan noch
#   nicht, vorher 80/443 pruefen (belegt -> nichts starten, Hinweis auf den Tunnel); geaenderte Adresse -> wan neu starten.
reach_converge() {
  [ "$(reach_mode)" = fritzbox ] || return 0
  [ -n "${DOMAIN:-}" ] || { warn "FritzBox-Weg ohne Internet-Adresse (DOMAIN) — nichts gestartet."; return 0; }
  local changed=1
  reach_wan_write_domain "$DOMAIN" && changed=0
  if rt_edge_active wan; then
    [ "$changed" -eq 0 ] && { rt_edge_restart wan || warn "FritzBox-Weg: wan ließ sich nicht neu starten."; }
    return 0
  fi
  if ! reach_ports_free; then
    warn "FritzBox-Weg: Port 80 oder 443 ist auf diesem Rechner schon belegt — nichts gestartet, nichts überschrieben. Empfehlung: der Tunnel."
    return 0
  fi
  rt_stack_up --no-deps wan >/dev/null 2>&1 || warn "FritzBox-Weg: wan ließ sich nicht starten ($(rt_edge_logs_hint wan))."
}

# reach_ingress_help — was der Nutzer fuer seinen Weg tun muss (Ersatz fuer das Caddyfile der CLI, emit_ingress_help).
reach_ingress_help() {
  case "$(reach_mode)" in
    tunnel) ui_box 'Erreichbarkeit: Tunnel (Tailscale Funnel)' <<EOF
Telegram erreicht deinen Rechner über ${DOMAIN:-die Tailscale-Adresse} — dafür ist im Router nichts einzustellen.
Den Stand zeigt die App (Anmeldung, Freigabe im Tailscale-Konto). Öffentlich sind nur die Telegram- und
Bestätigungs-Pfade; der n8n-Editor bleibt auf diesem Rechner (http://127.0.0.1:${LA_EDGE_PORT:-<port>}).
Läuft die Geräte-Anmeldung bei Tailscale ab, schweigt der Bot: im Tailscale-Konto unter Machines beim Gerät
„Disable key expiry“ wählen. Schritt für Schritt: Doku-Seite „Tunnel“.
EOF
      ;;
    fritzbox) ui_box 'Erreichbarkeit: FritzBox' <<EOF
Telegram erreicht deinen Rechner über https://${DOMAIN:-<MyFRITZ!-Adresse>}/ — die FritzBox gibt dafür die Ports
80 und 443 an diesen Rechner frei (MyFRITZ!-Freigabe „HTTPS-Server“ plus Port 80). Das Zertifikat holt der Rand
selbst. Öffentlich sind nur die Telegram- und Bestätigungs-Pfade; der n8n-Editor bleibt auf diesem Rechner.
Schritt für Schritt: Doku-Seite „FritzBox einrichten“. Klappt es nicht (z. B. DS-Lite), nimm den Tunnel.
EOF
      ;;
    *) ui_box 'Erreichbarkeit' <<EOF
Noch kein Weg nach außen gewählt — Telegram erreicht den Bot erst mit Tunnel oder FritzBox (Wizard bzw. App).
EOF
      ;;
  esac
  _INGRESS_HELP_SHOWN=1
}
