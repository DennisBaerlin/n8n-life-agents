# shellcheck disable=SC1111,SC2034  # SC1111: deutsche Anfuehrungszeichen in Nutzertexten gewollt; SC2034: REACH_* lesen die Aufrufer
# reach.sh — Weg nach aussen im Docker-Verbund (LIFEAGENTS_RUNTIME=compose; Plan docker-installer-freunde *Der Rand*).
# GESOURCT (kein Shebang, kein set -e). Docker nur ueber lib/runtime.sh (rt_edge_*, rt_stack_up,
# rt_host_port_free). Die CLI-Installation (systemd) beruehrt diese Datei nicht.
#
# Der Rand (`edge`, Caddy, compose.yml LA_CADDYFILE) hat drei Eingaenge: :8080 Editor und :8081 Wizard nur ueber
# 127.0.0.1 des Rechners, :8088 = die EINE Liste oeffentlicher Pfade (common.sh LA_PUBLIC_PATHS, reach_edge_public_write,
# contract_lint 34). Beide
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
    def caps: ((((.Self.CapMap // {}) | keys) + (.Self.Capabilities // [])) | map(sub("^https://tailscale\\.com/cap/"; "")));
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

# _reach_funnel_on — DER eine Aufruf zum Einschalten: `tailscale funnel --bg` auf :8088. Darf der Knoten noch nicht,
#   gibt Tailscale den Link zur Freigabe-Seite im Konto aus (CLI: enableFeatureInteractive -> QueryFeature) und wartet
#   auf die Freigabe -> kurze Frist (8 s). Ein ausgegebener Link landet im Zwischenspeicher (5 Min, der Wizard fragt alle
#   paar Sekunden). Gibt der Nutzer frei, waehrend der Aufruf wartet, schaltet derselbe Aufruf Funnel gleich ein.
_reach_funnel_on() {
  local url
  url="$(rt_edge_exec tailscale timeout 8 tailscale funnel --bg --yes "$REACH_PUBLIC_TARGET" 2>&1 \
          | grep -oE 'https://login\.tailscale\.com/[A-Za-z0-9/?=&._~%+-]+' | head -n1 || true)"
  printf '%s' "$url" | grep -qE "$REACH_LOGIN_RE" || return 0
  ( umask 077; mkdir -p "$REACH_RUN_DIR" && printf '%s' "$url" > "$REACH_RUN_DIR/funnel-link" ) 2>/dev/null || true
}

# reach_funnel_link — zwischengespeicherter Freigabe-Link (juenger als 5 Min) oder leer.
reach_funnel_link() {
  local f="$REACH_RUN_DIR/funnel-link"
  [ -s "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) )) -lt 300 ] && cat "$f"
  return 0
}

# reach_funnel_ensure <dns> — Funnel fuer <dns>:443 -> :8088 an? Sonst einmal einschalten (idempotent; der Nutzer hat dem
#   Tunnel in der 2. Bestaetigung zugestimmt). Nur bei REACH_TS_STATE=running (der Knoten darf Funnel): dann kehrt der
#   Aufruf sofort zurueck; ein alter Freigabe-Link ist damit erledigt. rc 0 = an.
reach_funnel_ensure() {
  local dns="$1" st
  st="$(rt_edge_exec tailscale tailscale funnel status --json 2>/dev/null || true)"
  reach_funnel_configured "$dns" "$st" && return 0
  _reach_funnel_on
  st="$(rt_edge_exec tailscale tailscale funnel status --json 2>/dev/null || true)"
  reach_funnel_configured "$dns" "$st" || return 1
  rm -f "$REACH_RUN_DIR/funnel-link" 2>/dev/null || true
}

# --- Telegram -------------------------------------------------------------------------------------------------------
# reach_webhook_eval <domain> — zeigt der Bot (getWebhookInfo) auf https://<domain>/? Nur lesend. Setzt REACH_WH_STATE
#   (ours | none | foreign | unknown; ein Netz-Wackler ist "unknown", nie "none", owner_connect.sh _oc_webhook_known) und
#   fuer den Selbsttest nach „Verbinden" die Zustell-Angaben von Telegram: REACH_WH_PENDING (wartende Updates, leer =
#   unbekannt), REACH_WH_ERROR (last_error_message, hoechstens 200 Zeichen) und REACH_WH_ERROR_AT (last_error_date, Epoch).
reach_webhook_eval() {
  local tok js url
  REACH_WH_STATE=unknown; REACH_WH_PENDING=''; REACH_WH_ERROR=''; REACH_WH_ERROR_AT=''
  tok="${TELEGRAM_BOT_TOKEN:-$(read_env_value "$REACH_CORE_ENV" TELEGRAM_BOT_TOKEN 2>/dev/null || true)}"
  [ -n "$tok" ] || return 0
  js="$(tg_api_curl "$tok" getWebhookInfo -fsS --max-time 8 2>/dev/null || true)"
  [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = true ] || return 0
  url="$(printf '%s' "$js" | jq -r '.result.url // ""' 2>/dev/null)"
  REACH_WH_PENDING="$(printf '%s' "$js" | jq -r '.result.pending_update_count // 0 | floor | tostring' 2>/dev/null || true)"
  REACH_WH_ERROR="$(printf '%s' "$js" | jq -r '.result.last_error_message // "" | gsub("[[:cntrl:]]"; " ") | .[0:200]' 2>/dev/null || true)"
  REACH_WH_ERROR_AT="$(printf '%s' "$js" | jq -r '.result.last_error_date // "" | tostring' 2>/dev/null || true)"
  if [ -z "$url" ]; then REACH_WH_STATE=none
  elif [ -n "$1" ] && [ "${url#"https://${1}/"}" != "$url" ]; then REACH_WH_STATE=ours
  else REACH_WH_STATE=foreign; fi
  return 0
}

# --- Eigene IPv4 (DS-Lite/CGNAT erkennen, FritzBox-Weg) -------------------------------------------------------------
# Telegram stellt Webhooks nur ueber IPv4 zu (Bot-API); ohne eigene oeffentliche IPv4 (DS-Lite, Carrier-NAT) kommt ueber
# die FritzBox nichts an -> Tunnel. MyFRITZ! traegt fuer die Box ihre IPv4 im Internet ein; bei DS-Lite ist die Box laut
# AVM nur ueber IPv6 erreichbar. Pruefung, ohne Nutzer und mit genau einem Fremd-Dienst:
#   0. UPnP der FritzBox (fritz.box:49000, WANIPConnection:1, ohne Anmeldung, solange "Statusinformationen ueber UPnP
#      uebertragen" an ist; je Aufruf 2 s). Nur bei NewConnectionStatus=Connected entscheidet NewExternalIPAddress:
#      leer, 0.0.0.0 oder 192.0.0.0/29 (B4-Adresse des DS-Lite-Tunnels, RFC 6333) -> none; 100.64.0.0/10 -> none;
#      oeffentlich -> own (anders als der Echo -> unknown, etwa VPN am Rechner). Privat (Box hinter einem anderen
#      Router), keine Antwort, kein fritz.box -> weiter mit 1. SSDP-Suche nach anderen Routern verworfen: Multicast
#      kommt aus dem Docker-Desktop-VM nicht ins Heimnetz.
#   1. Zone <kennung>.myfritz.net (LA_MYFRITZ_ZONE in den Hinweisen der Start-App, aus dem Zertifikat der Box); fehlt
#      sie -> unknown.
#   2. A-Eintrag fehlt, AAAA da -> none. A in 100.64.0.0/10 (Carrier-NAT) oder privat -> none.
#   3. A oeffentlich: nur mit Gegenprobe "own" — die IPv4, unter der dieser Rechner nach aussen sichtbar ist (ein Echo-
#      Dienst, 4 s, nur IPv4: api.ipify.org, quelloffen, keine Anmeldung). Gleich -> own; anders (veralteter Eintrag,
#      Carrier-NAT mit oeffentlichem Bereich) oder nicht pruefbar -> unknown. Nie eine falsche Sicherheit: unknown
#      fuehrt zum Weg von Hand (Online-Monitor der FritzBox), wie bisher.
# Beide Adressen per Umgebung uebersteuerbar: Tests duerfen nie die echte Box oder den Echo-Dienst des Rechners treffen.
REACH_IPV4_ECHO="${REACH_IPV4_ECHO:-https://api.ipify.org}"
REACH_UPNP_URL="${REACH_UPNP_URL:-http://fritz.box:49000/igdupnp/control/WANIPConn1}"

# _reach_ipv4_shared <ipv4> -> 0, wenn die Adresse nicht oeffentlich ist (privat, Carrier-NAT, Loopback, Link-Local).
_reach_ipv4_shared() {
  local a b
  IFS=. read -r a b _ _ <<<"$1"
  case "$a" in 10|127|0) return 0 ;; esac
  [ "$a" = 100 ] && [ "$b" -ge 64 ] 2>/dev/null && [ "$b" -le 127 ] && return 0
  [ "$a" = 172 ] && [ "$b" -ge 16 ] 2>/dev/null && [ "$b" -le 31 ] && return 0
  [ "$a" = 192 ] && [ "$b" = 168 ] && return 0
  [ "$a" = 169 ] && [ "$b" = 254 ] && return 0
  return 1
}

# Hinweise der Start-App: fluechtige Datei im master (0600, KEY=wert, vor jedem Oeffnen des Fragebogens neu), NICHT als
# Umgebung — die bliebe in `docker inspect` dauerhaft sichtbar (Entscheid der Leitung). Gelesen, nie ausgefuehrt; nur
# eine gewoehnliche Datei (kein Link), hoechstens 4 KB. Fehlt sie, gibt es keinen Hinweis.
REACH_HINTS_FILE="${REACH_HINTS_FILE:-/run/lifeagents-wizard/hints.env}"
_reach_hint() {
  local f="$REACH_HINTS_FILE"
  [ -f "$f" ] && [ ! -L "$f" ] && [ "$(stat -c %s "$f" 2>/dev/null || echo 99999)" -le 4096 ] || return 0
  read_env_value "$f" "$1" 2>/dev/null | tr -d '\r' || true
}

# reach_myfritz_zone -> <kennung>.myfritz.net aus den Hinweisen (LA_MYFRITZ_ZONE, aus dem Zertifikat der Box) oder leer.
reach_myfritz_zone() {
  local z
  z="$(_reach_hint LA_MYFRITZ_ZONE | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$z" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?\.myfritz\.net$' && printf '%s' "$z"
  return 0
}

# reach_ipv4_eval — setzt REACH_IPV4 (own | none | unknown) und REACH_IPV4_REASON (no_zone | no_a_record | shared_address |
#   matches | differs | dns_failed | echo_failed; aus UPnP: upnp_no_ipv4 | upnp_shared | upnp_public | upnp_differs). Fuer
#   die Fall-Tests sind DNS, Echo und UPnP eigene Funktionen.
_reach_dns4() { dns_first_addr "$1" 4; }
_reach_dns6() { dns_first_addr "$1" 6; }
_reach_echo4() { curl -4 -fsS --max-time 4 "$REACH_IPV4_ECHO" 2>/dev/null | head -c 64 || true; }

# reach_public_ipv4 -> die oeffentliche IPv4, unter der dieser Rechner nach aussen sichtbar ist, oder leer (nicht
#   pruefbar, kein gueltiger Wert, oder die Adresse ist selbst geteilt/privat). rc 0. DIE eine Stelle fuer den Echo-Dienst
#   (DS-Lite-Pruefung hier, Adress-Vorschlag im Wizard): ein Erfolg gilt 10 Min (Zwischenspeicher), ein Fehlschlag nicht.
reach_public_ipv4() {
  local f="$REACH_RUN_DIR/public-ipv4" ip
  if [ -s "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) )) -lt 600 ]; then cat "$f"; return 0; fi
  ip="$(_reach_echo4 | tr -d '[:space:]')"
  _reach_ipv4_valid "$ip" || return 0
  _reach_ipv4_shared "$ip" && return 0
  ( umask 077; mkdir -p "$REACH_RUN_DIR" && printf '%s' "$ip" > "$f" ) 2>/dev/null || true
  printf '%s' "$ip"
}

_reach_ipv4_valid() {
  local a b c d
  printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
  IFS=. read -r a b c d <<<"$1"
  [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ]
}

# _reach_upnp <Aktion> -> SOAP-Antwort der FritzBox (hoechstens 8 KB) oder leer. Kein Wert geht in ein Log.
_reach_upnp() {
  local svc='urn:schemas-upnp-org:service:WANIPConnection:1'
  curl -fsS --connect-timeout 1 --max-time 2 --max-filesize 8192 -H 'Content-Type: text/xml; charset="utf-8"' \
    -H "SOAPAction: $svc#$1" --data-binary "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:$1 xmlns:u=\"$svc\"/></s:Body></s:Envelope>" \
    "$REACH_UPNP_URL" 2>/dev/null | head -c 8192 || true
}

# _reach_upnp_field <Aktion> <Feld> -> Inhalt von <Feld> in der Antwort auf <Aktion>; rc 1, wenn die Antwort fehlt oder
#   das Feld nicht enthaelt (leeres Feld = rc 0, leere Ausgabe).
_reach_upnp_field() {
  local x
  x="$(_reach_upnp "$1" | tr -d '\r\n')"
  case "$x" in *"$1Response"*) ;; *) return 1 ;; esac
  case "$x" in *"<$2/>"*) return 0 ;; esac
  # Ohne Treffer waere die Ausgabe leer und saehe aus wie "keine IPv4" (Markup im Feld) -> rc 1.
  printf '%s' "$x" | grep -q "<$2>[^<]*</$2>" || return 1
  printf '%s' "$x" | sed -n "s#.*<$2>\([^<]*\)</$2>.*#\1#p" | head -c 64
}

# _reach_ipv4_upnp — Schritt 0; rc 0 = entschieden (REACH_IPV4/REACH_IPV4_REASON gesetzt), rc 1 = weiter mit MyFRITZ!.
_reach_ipv4_upnp() {
  local st ip me a b
  st="$(_reach_upnp_field GetStatusInfo NewConnectionStatus)" || return 1
  [ "$st" = Connected ] || return 1
  ip="$(_reach_upnp_field GetExternalIPAddress NewExternalIPAddress)" || return 1
  ip="$(printf '%s' "$ip" | tr -d '[:space:]')"
  if [ -z "$ip" ] || [ "$ip" = 0.0.0.0 ]; then REACH_IPV4=none; REACH_IPV4_REASON=upnp_no_ipv4; return 0; fi
  _reach_ipv4_valid "$ip" || return 1
  IFS=. read -r a b _ _ <<<"$ip"
  case "$ip" in 192.0.0.[0-7]) REACH_IPV4=none; REACH_IPV4_REASON=upnp_no_ipv4; return 0 ;; esac
  if [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; then REACH_IPV4=none; REACH_IPV4_REASON=upnp_shared; return 0; fi
  _reach_ipv4_shared "$ip" && return 1
  me="$(reach_public_ipv4)"
  if [ -n "$me" ] && [ "$me" != "$ip" ]; then REACH_IPV4=unknown; REACH_IPV4_REASON=upnp_differs; return 0; fi
  REACH_IPV4=own; REACH_IPV4_REASON=upnp_public
}

reach_ipv4_eval() {
  local z a6 a4 me
  REACH_IPV4=unknown; REACH_IPV4_REASON=''
  _reach_ipv4_upnp && return 0
  z="$(reach_myfritz_zone)"
  [ -n "$z" ] || { REACH_IPV4_REASON=no_zone; return 0; }
  a4="$(_reach_dns4 "$z")"
  if [ -z "$a4" ]; then
    a6="$(_reach_dns6 "$z")"
    if [ -n "$a6" ]; then REACH_IPV4=none; REACH_IPV4_REASON=no_a_record; else REACH_IPV4_REASON=dns_failed; fi
    return 0
  fi
  printf '%s' "$a4" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || { REACH_IPV4_REASON=dns_failed; return 0; }
  if _reach_ipv4_shared "$a4"; then REACH_IPV4=none; REACH_IPV4_REASON=shared_address; return 0; fi
  me="$(reach_public_ipv4)"
  [ -n "$me" ] || { REACH_IPV4_REASON=echo_failed; return 0; }
  if [ "$me" = "$a4" ]; then REACH_IPV4=own; REACH_IPV4_REASON=matches; else REACH_IPV4_REASON=differs; fi
  return 0
}

# --- Oeffentliche Pfade fuer den Rand -------------------------------------------------------------------------------
# reach_edge_public_write — den Baustein der CLI (common.sh caddy_webhook_block, Upstream anchor:5678) nach
#   reach_conf/edge-public.caddy schreiben; edge laedt ihn binnen 5 s ohne Neustart (compose.yml). rc 0 = geaendert.
# `|| true`: gesourcte Libs laufen unter dem set -e des Aufrufers; ohne templates/ daneben (Basis-Image des
# Test-Substrats kopiert nur lib/) braeche sonst schon das Einlesen ab.
REACH_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates" 2>/dev/null && pwd || true)"
reach_edge_public_write() {
  local f="$REACH_CONF_DIR/edge-public.caddy" new
  new="$(caddy_webhook_block "${TEMPLATE_DIR:-$REACH_TEMPLATE_DIR}" anchor:5678)" || return 1
  printf '%s' "$new" | grep -q '^@lifeagents path ' || die "Baustein der öffentlichen Pfade leer (templates/Caddyfile.tpl)."
  [ "$(cat "$f" 2>/dev/null || true)" = "$new" ] && return 1
  mkdir -p "$REACH_CONF_DIR" && printf '%s\n' "$new" > "$f.tmp" && chmod 0644 "$f.tmp" && mv -f "$f.tmp" "$f"
}

# --- FritzBox (wan) -------------------------------------------------------------------------------------------------
# reach_ports_free -> 0, wenn 80 UND 443 am Rechner frei sind (rt_host_port_free: Kurzlauf-Container, Pruefliste Nr. 13).
reach_ports_free() { rt_host_port_free 80 && rt_host_port_free 443; }

# reach_wan_write_domain <domain> -> 0 = Datei geaendert (wan muss neu starten), 1 = unveraendert. Nur geprueft gueltige
#   Namen (domain_problem); wan liest die Datei beim Start und prueft sie selbst noch einmal.
reach_wan_write_domain() {
  local d f="$REACH_CONF_DIR/domain"
  d="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')"   # wan nimmt nur Kleinschreibung
  [ -z "$(domain_problem "$d")" ] || die "Internet-Adresse für den FritzBox-Weg ungültig: $(domain_problem "$d")."
  [ "$(cat "$f" 2>/dev/null || true)" = "$d" ] && return 1
  mkdir -p "$REACH_CONF_DIR" && printf '%s\n' "$d" > "$f.tmp" && chmod 0644 "$f.tmp" && mv -f "$f.tmp" "$f"
}

# --- Status fuer Wizard und Start-App -------------------------------------------------------------------------------
# reach_status_json — EINE JSON-Zeile (Format: docs/reference/provisioning.md *Docker-Verbund: Erreichbarkeit*):
#   {mode, state, url, dns_name, key_expiry, key_days_left, webhook, webhook_pending, webhook_error, webhook_error_at,
#   ipv4, ipv4_reason, reason}. ipv4 (own|none|unknown) nur beim FritzBox-Weg und vor der Wahl. Aendert nichts, ausser beim Tunnel
#   den Funnel einzuschalten, sobald das Konto ihn erlaubt (die Zustimmung kam mit der 2. Bestaetigung). Prueft keine
#   Ports: ports_busy ist das Ergebnis der letzten Pruefung in reach_converge (Marke ports-busy in reach_conf) — eine
#   Probe je Abfrage kostete zwei Container und stiesse bei gleichzeitigen Abfragen (Wizard + App) auf den festen Namen.
# reach_ipv4_cached — reach_ipv4_eval hoechstens alle 10 Min (der Wizard fragt alle paar Sekunden; der Echo-Dienst soll
#   nicht bei jeder Abfrage gefragt werden). Ergebnis in REACH_IPV4/REACH_IPV4_REASON.
reach_ipv4_cached() {
  local f="$REACH_RUN_DIR/ipv4" z
  z="$(reach_myfritz_zone)"
  if [ -s "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) )) -lt 600 ] \
     && [ "$(sed -n 3p "$f")" = "$z" ]; then
    REACH_IPV4="$(sed -n 1p "$f")"; REACH_IPV4_REASON="$(sed -n 2p "$f")"; return 0
  fi
  reach_ipv4_eval
  ( umask 077; mkdir -p "$REACH_RUN_DIR" && printf '%s\n%s\n%s\n' "$REACH_IPV4" "$REACH_IPV4_REASON" "$z" > "$f" ) 2>/dev/null || true
}

# reach_dslite -> yes | no | unknown (ein Wort). yes = keine eigene oeffentliche IPv4 (DS-Lite oder Carrier-NAT), der
#   FritzBox-Weg kann nicht klappen; unknown = der Wizard fragt von Hand. Dieselbe Pruefung wie das Statusfeld ipv4.
#   REACH_DSLITE_SOURCE = upnp | myfritz | none (gilt nur ohne $(...)-Subshell, darum reach_dslite_json fuer bridge.sh).
_reach_dslite_eval() {
  reach_ipv4_cached
  case "$REACH_IPV4" in own) REACH_DSLITE=no ;; none) REACH_DSLITE=yes ;; *) REACH_DSLITE=unknown ;; esac
  case "$REACH_IPV4_REASON" in
    upnp_*) REACH_DSLITE_SOURCE=upnp ;;
    no_a_record|shared_address|matches|differs) REACH_DSLITE_SOURCE=myfritz ;;
    *) REACH_DSLITE_SOURCE=none ;;
  esac
}
reach_dslite() { _reach_dslite_eval; printf '%s\n' "$REACH_DSLITE"; }
reach_dslite_json() { _reach_dslite_eval; jq -nc --arg d "$REACH_DSLITE" --arg s "$REACH_DSLITE_SOURCE" '{dslite:$d, source:$s}'; }

reach_status_json() {
  local mode state='unavailable' url='' dns='' kexp='' kdays='' reason='' dom
  mode="$(reach_mode)"
  dom="$(read_env_value "$REACH_CORE_ENV" DOMAIN 2>/dev/null || true)"
  REACH_WH_STATE=unknown; REACH_WH_PENDING=''; REACH_WH_ERROR=''; REACH_WH_ERROR_AT=''
  REACH_IPV4=unknown; REACH_IPV4_REASON='not_checked'
  case "$mode" in
    tunnel)
      if ! rt_edge_active tailscale; then reason='not_started'
      else
        reach_ts_eval "$(_reach_ts_status)"
        state="$REACH_TS_STATE"; url="$REACH_TS_URL"; dns="$REACH_TS_DNS"; kexp="$REACH_TS_KEY_EXPIRY"; kdays="$REACH_TS_KEY_DAYS"
        case "$state" in
          stopped) state=unavailable; reason='stopped' ;;
          needs_funnel)
            url="$(reach_funnel_link)"
            [ -n "$url" ] || { _reach_funnel_on; url="$(reach_funnel_link)"; } ;;
          running)
            if [ -z "$dns" ] || ! reach_funnel_ensure "$dns"; then state=needs_funnel; url="$(reach_funnel_link)"
            else
              reach_webhook_eval "$dns"
              if [ "$dom" = "$dns" ] && [ "$REACH_WH_STATE" = ours ]; then state=ready; else state=pending_activation; fi
            fi ;;
        esac
      fi ;;
    fritzbox)
      dns="$dom"
      reach_ipv4_cached
      if [ -z "$dom" ]; then reason='no_domain'
      elif rt_edge_active wan; then
        reach_webhook_eval "$dom"
        if [ "$REACH_WH_STATE" = ours ]; then state=ready; else state=pending_activation; fi
      elif [ -e "$REACH_CONF_DIR/ports-busy" ]; then state=ports_busy   # Ergebnis der letzten Pruefung (reach_converge)
      else state=starting; reason='not_started'; fi ;;
    *) reason='no_mode'; reach_ipv4_cached ;;   # vor der Wahl: hilft dem Wizard bei der Empfehlung
  esac
  jq -nc --arg mode "$mode" --arg state "$state" --arg url "$url" --arg dns "$dns" --arg kexp "$kexp" \
    --arg kdays "$kdays" --arg wh "$REACH_WH_STATE" --arg whp "$REACH_WH_PENDING" --arg whe "$REACH_WH_ERROR" \
    --arg whd "$REACH_WH_ERROR_AT" --arg v4 "$REACH_IPV4" --arg v4r "$REACH_IPV4_REASON" --arg reason "$reason" \
    'def num: if . == "" then null else (try tonumber catch null) end;
     {mode:$mode, state:$state, url:$url, dns_name:$dns, key_expiry:$kexp, key_days_left:($kdays | num),
      webhook:$wh, webhook_pending:($whp | num), webhook_error:$whe, webhook_error_at:($whd | num),
      ipv4:$v4, ipv4_reason:$v4r, reason:$reason}'
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
  # Beide Wege enden auf edge:8088: die Liste der oeffentlichen Pfade erst jetzt freigeben (n8n ist eingerichtet).
  if reach_edge_public_write; then log "Rand: Liste der öffentlichen Pfade aktualisiert (edge lädt sie binnen 5 s)."; fi
  [ "$(reach_mode)" = fritzbox ] || return 0
  [ -n "${DOMAIN:-}" ] || { warn "FritzBox-Weg ohne Internet-Adresse (DOMAIN) — nichts gestartet."; return 0; }
  local changed=1
  reach_wan_write_domain "$DOMAIN" && changed=0
  if rt_edge_active wan; then
    [ "$changed" -eq 0 ] && { rt_edge_restart wan || warn "FritzBox-Weg: wan ließ sich nicht neu starten."; }
    return 0
  fi
  if ! reach_ports_free; then
    : > "$REACH_CONF_DIR/ports-busy"
    warn "FritzBox-Weg: Port 80 oder 443 ist auf diesem Rechner schon belegt — nichts gestartet, nichts überschrieben. Empfehlung: der Tunnel."
    return 0
  fi
  rm -f "$REACH_CONF_DIR/ports-busy"
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
