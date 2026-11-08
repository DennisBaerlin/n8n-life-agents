# shellcheck disable=SC1111,SC2034  # SC1111: deutsche Anfuehrungszeichen in Nutzertexten gewollt; SC2034: REACH_CLI_* lesen die Aufrufer
# reach_cli.sh — Weg nach aussen fuer die CLI-Installation (systemd/LXC). GESOURCT von common.sh (kein Shebang, kein
# set -e), keine Eingaben (die Dialoge leben in release_inputs.sh, contract_lint 12d). Gegenstueck im Docker-Verbund:
# lib/reach.sh — von dort nur die reinen Funktionen (reach_ts_eval, reach_public_ipv4, reach_dslite) lesend genutzt.
#
# EIN Fakt REACH_MODE in core.env (derselbe Schluessel wie im Verbund), Werte in der CLI:
#   tunnel   Tailscale Funnel. tailscaled laeuft direkt auf dem Rechner (offizielle apt-Quelle); ohne /dev/net/tun
#            (unprivilegierter LXC, Proxmox-Standard) im Userspace-Modus — Funnel/Serve brauchen kein TUN, der Verbund
#            laeuft genauso (compose.yml TS_USERSPACE). Die Tuer ist Tailscale selbst: je oeffentlichem Pfad aus der EINEN
#            Liste LA_PUBLIC_PATHS ein Serve-Eintrag auf 127.0.0.1:<n8n-port><pfad>, alles andere 404; n8n bleibt auf
#            127.0.0.1 (TRUSTED_PROXIES=127.0.0.1), kein Caddy, keine Firewall-Oeffnung. Tailscale schneidet den Eintrags-
#            Pfad vor dem Weiterreichen ab (tailscale/tailscale#6571) -> das Ziel traegt den Pfad selbst.
#            Internet-Adresse = <rechner>.<tailnet>.ts.net (DOMAIN). Ein schon vorhandener Knoten (eigenes Tailnet des
#            Nutzers) wird mitbenutzt, nie `reset`/`logout`; eine fremde Serve-Konfiguration auf :443 wird nie
#            ueberschrieben (dann: anderer Weg).
#   fritzbox MyFRITZ!-Freigabe + eigener Reverse Proxy (bring your own, Caddyfile wie beim eigenen Proxy). Hier nur die
#            Pruefungen: DS-Lite (reach_dslite, UPnP der FritzBox) und „zeigt die Adresse auf meinen Anschluss?".
#   proxy    eigene Domain + eigener Reverse Proxy (der Weg vor dieser Datei).
#   leer     nur Heimnetz. Bestand ohne REACH_MODE, aber mit DOMAIN -> proxy (abgeleitet, nie neu gefragt).

# Neutraler Rechnername (Zertifikats-Protokolle sind oeffentlich): einmal gezogen und als TS_HOSTNAME in core.env
# gemerkt (ts_name_ensure aus lib/reach.sh, dieselbe Regel wie die Start-App); fehlt die Funktion, `bot`.
reach_cli_ts_host() {
  local f="${INSTALL_ENV_FILE:-$REACH_CORE_ENV}" n
  if declare -F ts_name_ensure >/dev/null && n="$(ts_name_ensure "$f" TS_HOSTNAME)" && [ -n "$n" ]; then printf '%s' "$n"; return 0; fi
  n="$(read_env_value "$f" TS_HOSTNAME 2>/dev/null || true)"
  printf '%s' "${n:-bot}"
}
REACH_CLI_TS_KEYRING="${REACH_CLI_TS_KEYRING:-/usr/share/keyrings/tailscale-archive-keyring.gpg}"
REACH_CLI_TS_LIST="${REACH_CLI_TS_LIST:-/etc/apt/sources.list.d/tailscale.list}"
REACH_CLI_TS_DEFAULTS="${REACH_CLI_TS_DEFAULTS:-/etc/default/tailscaled}"
REACH_CLI_TUN_DEV="${REACH_CLI_TUN_DEV:-/dev/net/tun}"
REACH_CLI_LOGIN_RE='https://login\.tailscale\.com/[A-Za-z0-9/?=&._~%+-]+'

# reach_cli_mode -> tunnel | fritzbox | proxy | none. REACH_MODE aus der Umgebung vor core.env; leer + DOMAIN = proxy.
reach_cli_mode() {
  local m="${REACH_MODE:-}" d="${DOMAIN:-}"
  [ -n "$m" ] || m="$(read_env_value "${INSTALL_ENV_FILE:-$REACH_CORE_ENV}" REACH_MODE 2>/dev/null || true)"
  case "$m" in
    tunnel|fritzbox|proxy) printf '%s' "$m"; return 0 ;;
  esac
  [ -n "$d" ] || d="$(read_env_value "${INSTALL_ENV_FILE:-$REACH_CORE_ENV}" DOMAIN 2>/dev/null || true)"
  if [ -n "$d" ]; then printf 'proxy'; else printf 'none'; fi
}

# reach_cli_mode_label <mode> -> Anzeige (Uebersicht, proxy show, Recap).
reach_cli_mode_label() {
  case "$1" in
    tunnel)   printf 'Tunnel (Tailscale)' ;;
    fritzbox) if rt_is_compose; then printf 'FritzBox'; else printf 'FritzBox (MyFRITZ!-Freigabe + eigener Reverse Proxy)'; fi ;;
    proxy)    printf 'eigene Domain + eigener Reverse Proxy' ;;
    *)        printf 'nur Heimnetz (Telegram erreicht den Bot dann nicht)' ;;
  esac
}

# --- Tailscale auf dem Rechner ----------------------------------------------------------------------------------------
# reach_cli_tun_mode -> kernel | userspace. Nur ein nutzbares TUN-Geraet (Zeichengeraet, laesst sich oeffnen) heisst
#   kernel; ein unprivilegierter LXC hat es ohne Durchreichen am Proxmox-Host nicht (tailscale.com/kb/1130).
reach_cli_tun_mode() {
  # 10:200 = das TUN-Geraet (/dev/null waere auch ein oeffnebares Zeichengeraet).
  if [ -c "$REACH_CLI_TUN_DEV" ] && [ "$(stat -c %t:%T "$REACH_CLI_TUN_DEV" 2>/dev/null)" = a:c8 ] \
     && { : <>"$REACH_CLI_TUN_DEV"; } 2>/dev/null; then printf kernel; else printf userspace; fi
}

# _reach_cli_os <feld> -> ID bzw. VERSION_CODENAME aus /etc/os-release (Quelle der Paket-Adresse).
# shellcheck source=/dev/null
_reach_cli_os() { ( . /etc/os-release 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" ); }

# reach_cli_ts_defaults_render <alt> <modus> -> /etc/default/tailscaled mit passender FLAGS-Zeile (rein, testbar): beim
#   Userspace-Modus genau ein --tun=userspace-networking, beim Kernel-Modus keins; fremde Schalter bleiben.
reach_cli_ts_defaults_render() {
  local old="$1" mode="$2" flags
  flags="$(printf '%s\n' "$old" | sed -n 's/^FLAGS="\(.*\)"$/\1/p' | head -n1)"
  flags="$(printf '%s' "$flags" | sed -E 's/(^| )--tun=userspace-networking( |$)/ /g; s/^ +| +$//g; s/  +/ /g')"
  [ "$mode" = userspace ] && flags="${flags:+$flags }--tun=userspace-networking"
  if printf '%s\n' "$old" | grep -q '^FLAGS='; then
    printf '%s\n' "$old" | awk -v f="FLAGS=\"$flags\"" 'BEGIN{d=0} /^FLAGS=/ { if (!d) print f; d=1; next } { print }'
  else
    { [ -n "$old" ] && printf '%s\n' "$old"; printf 'FLAGS="%s"\n' "$flags"; }
  fi
}

# reach_cli_ts_install — tailscale + qrencode aus der offiziellen, signierten Quelle (pkgs.tailscale.com) und tailscaled
#   passend zum TUN-Geraet starten. Idempotent: vorhandenes tailscale bleibt (auch eins, das der Nutzer selbst
#   eingerichtet hat); FLAGS werden nur bei Bedarf geaendert, dann einmal neu gestartet. rc 0 = tailscaled laeuft.
reach_cli_ts_install() {
  local id code old new changed=1
  if ! need_cmd tailscale; then
    id="$(_reach_cli_os ID)"; code="$(_reach_cli_os VERSION_CODENAME)"
    case "$id" in debian|ubuntu) : ;; *) warn "Tunnel: ${id:-unbekanntes System} — Tailscale bitte selbst installieren (tailscale.com/download), dann erneut starten."; return 1 ;; esac
    [ -n "$code" ] || { warn "Tunnel: Debian-Version unbekannt (VERSION_CODENAME fehlt) — Tailscale bitte selbst installieren."; return 1; }
    add_apt_key "https://pkgs.tailscale.com/stable/${id}/${code}.gpg" "$REACH_CLI_TS_KEYRING"
    add_apt_source "$REACH_CLI_TS_LIST" "deb [signed-by=${REACH_CLI_TS_KEYRING}] https://pkgs.tailscale.com/stable/${id} ${code} main"
    force_apt_update
    apt_install tailscale
  fi
  # QR-Code nur fuer den Dialog; ein unbeaufsichtigtes Update braucht ihn nicht.
  if ui_interactive && ! need_cmd qrencode; then apt_install qrencode || warn "qrencode fehlt — der Anmelde-Link kommt ohne QR-Code."; fi
  old="$(cat "$REACH_CLI_TS_DEFAULTS" 2>/dev/null || true)"
  new="$(reach_cli_ts_defaults_render "$old" "$(reach_cli_tun_mode)")"
  if [ "$new" != "$old" ]; then
    printf '%s\n' "$new" | write_if_changed "$REACH_CLI_TS_DEFAULTS" 0644 && changed=0
  fi
  if [ "$changed" -eq 0 ] && svc_is_active tailscaled; then svc_restart tailscaled; else svc_up tailscaled; fi
  svc_is_active tailscaled
}

# reach_cli_ts_status -> `tailscale status --json` (leer, wenn tailscale fehlt/nicht antwortet).
reach_cli_ts_status() {
  need_cmd tailscale || return 0
  timeout 10 tailscale status --json --peers=false 2>/dev/null || true
}

# reach_cli_ts_login_start — Anmeldung anstossen, ohne zu warten: `tailscale up` im Hintergrund (es wartet selbst auf die
#   Anmeldung und endet danach; nach 15 Min gibt es auf). Den Anmelde-Link liefert danach `tailscale status` (AuthURL).
#   Nur fuer einen Knoten, der noch nie angemeldet war — ein laufender Knoten bekommt nie andere Schalter (up wuerde
#   sonst die Einstellungen des Nutzers ueberschreiben bzw. ablehnen).
reach_cli_ts_login_start() {
  need_cmd tailscale || return 1
  ( setsid timeout 900 tailscale up --hostname="$(reach_cli_ts_host)" --accept-dns=false </dev/null >/dev/null 2>&1 & ) 2>/dev/null || true
  return 0
}

# reach_cli_ts_wait_url [sekunden] — bis zu N s (Standard 15) auf einen Anmelde-Link warten; Ergebnis in REACH_TS_*.
reach_cli_ts_wait_url() {
  local n="${1:-15}" i=0
  while :; do
    reach_ts_eval "$(reach_cli_ts_status)"
    [ -n "$REACH_TS_URL" ] && return 0
    case "$REACH_TS_STATE" in running|needs_funnel|needs_machine_auth|key_expired) return 0 ;; esac
    [ "$i" -ge "$n" ] && return 0
    sleep 1; i=$((i+1))
  done
}

# reach_cli_qr <url> -> QR-Code fuers Terminal (qrencode, UTF-8-Bloecke); leer, wenn qrencode fehlt.
reach_cli_qr() { need_cmd qrencode || return 0; qrencode -t UTF8 -m 1 "$1" 2>/dev/null || true; }

# --- Funnel: nur die oeffentlichen Pfade ------------------------------------------------------------------------------
# reach_cli_funnel_mounts [port] -> Zeilen "<pfad><TAB><ziel>" aus LA_PUBLIC_PATHS: "/webhook/*" -> "/webhook" (Tailscale
#   haengt alles darunter an), exakte Pfade bleiben; Ziel http://127.0.0.1:<port><pfad>.
reach_cli_funnel_mounts() {
  local port="${1:-${N8N_PORT:-5678}}" p
  for p in $LA_PUBLIC_PATHS; do
    p="${p%/\*}"
    printf '%s\thttp://127.0.0.1:%s%s\n' "$p" "$port" "$p"
  done
}

# reach_cli_funnel_eval <dns> <funnel-status-json> [port] -> ours | absent | partial | foreign
#   ours    = Funnel an :443 erlaubt UND genau unsere Eintraege mit unseren Zielen (kein „/" fuer alles).
#   absent  = auf <dns>:443 gibt es nichts.   partial = nur Eintraege von uns, aber unvollstaendig/abweichend.
#   foreign = ein Eintrag, der nicht von uns ist (der Nutzer nutzt Serve selbst) -> nie anfassen.
reach_cli_funnel_eval() {
  local dns="$1" js="$2" want
  want="$(reach_cli_funnel_mounts "${3:-}" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {key:.[0], value:.[1]}) | from_entries')"
  [ -n "$js" ] || js='{}'
  printf '%s' "$js" | jq -r --arg k "$dns:443" --argjson want "$want" '
    ((.Web // {})[$k].Handlers // {}) as $h
    | ($h | to_entries | map({key, value:(.value.Proxy // "")}) | from_entries) as $got
    | if ($h | length) == 0 then "absent"
      elif ([$got | keys[] | . as $x | select(($want | has($x)) | not)] | length) > 0 then "foreign"
      elif $got == $want and ((.AllowFunnel // {})[$k] // false) == true then "ours"
      else "partial" end' 2>/dev/null || printf 'absent'
}

# _reach_cli_funnel_status -> `tailscale funnel status --json` (leer bei Fehler).
_reach_cli_funnel_status() { timeout 10 tailscale funnel status --json 2>/dev/null || true; }

# reach_cli_funnel_ensure <dns> [port] — unsere Eintraege anlegen (idempotent). rc 0 = an; 1 = noch nicht (z. B. Funnel im
#   Konto nicht erlaubt: der Freigabe-Link steht dann in REACH_CLI_FUNNEL_URL); 3 = fremde Konfiguration auf :443 (nichts
#   geaendert). Darf der Knoten Funnel noch nicht, gibt `tailscale funnel` den Link aus und wartet — kurze Frist (8 s).
REACH_CLI_FUNNEL_URL=''
reach_cli_funnel_ensure() {
  local dns="$1" port="${2:-}" st m t out
  REACH_CLI_FUNNEL_URL=''
  st="$(reach_cli_funnel_eval "$dns" "$(_reach_cli_funnel_status)" "$port")"
  case "$st" in ours) return 0 ;; foreign) return 3 ;; esac
  while IFS=$'\t' read -r m t; do
    [ -n "$m" ] || continue
    out="$(timeout 8 tailscale funnel --bg --yes --set-path "$m" "$t" 2>&1 || true)"
    REACH_CLI_FUNNEL_URL="$(printf '%s' "$out" | grep -oE "$REACH_CLI_LOGIN_RE" | head -n1 || true)"
    # Freigabe fehlt: jeder weitere Pfad wartete nur dieselben 8 s auf denselben Link.
    [ -n "$REACH_CLI_FUNNEL_URL" ] && return 1
  done <<<"$(reach_cli_funnel_mounts "$port")"
  [ "$(reach_cli_funnel_eval "$dns" "$(_reach_cli_funnel_status)" "$port")" = ours ]
}

# reach_cli_funnel_off <dns> [port] — NUR unsere Eintraege zuruecknehmen (Wechsel weg vom Tunnel). Fremde bleiben.
reach_cli_funnel_off() {
  local dns="$1" port="${2:-}" m t
  need_cmd tailscale || return 0
  [ "$(reach_cli_funnel_eval "$dns" "$(_reach_cli_funnel_status)" "$port")" = absent ] && return 0
  while IFS=$'\t' read -r m t; do
    [ -n "$m" ] || continue
    timeout 8 tailscale funnel --https=443 --set-path "$m" off >/dev/null 2>&1 || true
  done <<<"$(reach_cli_funnel_mounts "$port")"
  return 0
}

# reach_cli_tunnel_settle [port] — Stand des Tunnels feststellen und, wo moeglich, fertigstellen (ohne Fragen). Setzt
#   REACH_CLI_STATE (missing | starting | needs_login | needs_machine_auth | needs_funnel | key_expired | busy | ready),
#   REACH_TS_* (reach_ts_eval) und bei ready DOMAIN=<dns> + TRUSTED_PROXIES=127.0.0.1 (exportiert; speichern tut der
#   Aufrufer). busy = auf :443 liegt eine fremde Serve-Konfiguration.
REACH_CLI_STATE=''
reach_cli_tunnel_settle() {
  local port="${1:-}" rc=0
  REACH_CLI_STATE=missing
  need_cmd tailscale || return 0
  reach_ts_eval "$(reach_cli_ts_status)"
  REACH_CLI_STATE="$REACH_TS_STATE"
  case "$REACH_TS_STATE" in running|needs_funnel) : ;; stopped) REACH_CLI_STATE=starting; return 0 ;; *) return 0 ;; esac
  [ -n "$REACH_TS_DNS" ] || { REACH_CLI_STATE=starting; return 0; }
  reach_cli_funnel_ensure "$REACH_TS_DNS" "$port" || rc=$?
  case "$rc" in
    0) REACH_CLI_STATE=ready
       DOMAIN="$REACH_TS_DNS"; TRUSTED_PROXIES=127.0.0.1; export DOMAIN TRUSTED_PROXIES ;;
    3) REACH_CLI_STATE=busy ;;
    *) REACH_CLI_STATE=needs_funnel ;;
  esac
  return 0
}

# --- FritzBox ---------------------------------------------------------------------------------------------------------
# _reach_cli_box_cert_names -> die Namen im Zertifikat der FritzBox (fritz.box:443), eins je Zeile; leer ohne Box/openssl.
_reach_cli_box_cert_names() {
  need_cmd openssl || return 0
  timeout 5 openssl s_client -connect fritz.box:443 -servername fritz.box </dev/null 2>/dev/null \
    | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/^ *DNS://p' || true
}

# reach_cli_myfritz_zone -> <kennung>.myfritz.net aus dem Zertifikat der FritzBox (wie die Start-App) oder leer.
reach_cli_myfritz_zone() {
  _reach_cli_box_cert_names | tr '[:upper:]' '[:lower:]' \
    | grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?\.myfritz\.net$' | head -n1 || true
}

# reach_cli_dslite [zone] -> yes | no | unknown — die Pruefung des Verbunds (reach_dslite: UPnP der FritzBox, sonst
#   MyFRITZ!-Eintrag gegen die eigene IPv4). Die Zone kommt hier aus dem Zertifikat statt aus den Hinweisen der Start-App.
reach_cli_dslite() {
  local z="${1-$(reach_cli_myfritz_zone)}" f
  f="$REACH_RUN_DIR/cli-hints.env"
  ( umask 077; mkdir -p "$REACH_RUN_DIR" && printf 'LA_MYFRITZ_ZONE=%s\n' "$z" > "$f" ) 2>/dev/null || true
  REACH_HINTS_FILE="$f" reach_dslite
}

# _reach_cli_dns4 <name> -> erste IPv4 aus dem DNS (ohne node vor dessen Installation: getent).
_reach_cli_dns4() {
  local a
  a="$(dns_first_addr "$1" 4)"
  [ -n "$a" ] || a="$( { getent ahostsv4 "$1" 2>/dev/null || true; } | awk 'NR==1 {print $1}')"
  printf '%s' "$a"
}

# reach_cli_domain_check <name> -> ok | pending | wrong | unknown: zeigt der Name (IPv4, ueber die Telegram zustellt) auf
#   den eigenen Anschluss? pending = noch kein Eintrag (MyFRITZ! braucht etwa eine Minute); unknown = eigene IPv4 nicht
#   ermittelbar (kein Netz, Echo-Dienst aus) — dann prueft der Installer am Ende ohnehin noch einmal.
reach_cli_domain_check() {
  local a me
  a="$(_reach_cli_dns4 "$1")"
  [ -n "$a" ] || { printf pending; return 0; }
  me="$(reach_public_ipv4)"
  [ -n "$me" ] || { printf unknown; return 0; }
  if [ "$a" = "$me" ]; then printf ok; else printf wrong; fi
}

# --- Hinweise fuer das gefuehrte Ende ---------------------------------------------------------------------------------
# reach_cli_tunnel_help — Ersatz fuer das Caddyfile beim Tunnel (emit_ingress_help).
reach_cli_tunnel_help() {
  ui_box 'Erreichbarkeit: Tunnel (Tailscale Funnel)' <<EOF
Telegram erreicht deinen Server über ${DOMAIN:+https://${DOMAIN}/}${DOMAIN:-die Tailscale-Adresse} — am Router ist nichts einzustellen,
einen Reverse Proxy brauchst du nicht. Öffentlich sind nur diese Pfade, alles andere antwortet 404:
  $(printf '%s' "$LA_PUBLIC_PATHS" | sed 's/ /   /g')
Der n8n-Editor bleibt nur auf diesem Rechner (http://127.0.0.1:${N8N_PORT:-5678}).
Läuft die Geräte-Anmeldung bei Tailscale ab, schweigt der Bot: im Tailscale-Konto unter Machines beim Gerät
„Disable key expiry“ wählen. Stand jederzeit: lifeagents proxy show · Schritt für Schritt: https://dennisbaerlin.github.io/n8n-life-agents/docs/tunnel.html
EOF
  _INGRESS_HELP_SHOWN=1
}

# reach_cli_state_text <state> -> ein Satz (proxy show, Recap, doctor).
reach_cli_state_text() {
  case "$1" in
    ready)              printf 'bereit — Tailscale reicht die Telegram-Pfade an n8n weiter' ;;
    needs_login)        printf 'bei Tailscale anmelden: lifeagents reconfigure core → „Unverändert neu anwenden“' ;;
    needs_machine_auth) printf 'Gerät im Tailscale-Konto freigeben (Machines)' ;;
    needs_funnel)       printf 'Funnel im Tailscale-Konto erlauben (lifeagents reconfigure core zeigt den Link)' ;;
    key_expired)        printf 'Tailscale-Anmeldung abgelaufen — neu anmelden: lifeagents reconfigure core' ;;
    busy)               printf 'Port 443 von Tailscale ist schon für etwas anderes eingerichtet — nichts geändert' ;;
    missing)            printf 'Tailscale ist nicht installiert' ;;
    *)                  printf 'startet …' ;;
  esac
}

# reach_cli_leave_tunnel — anderer Weg als der Tunnel gewaehlt: unsere Funnel-Eintraege zuruecknehmen (fremde und der
#   Tailscale-Knoten selbst bleiben; der Nutzer nutzt ihn vielleicht weiter). Ohne tailscale oder ohne Namen: nichts.
reach_cli_leave_tunnel() {
  [ "$(reach_cli_mode)" = tunnel ] && return 0
  need_cmd tailscale || return 0
  reach_ts_eval "$(reach_cli_ts_status)"
  [ -n "$REACH_TS_DNS" ] || return 0
  reach_cli_funnel_off "$REACH_TS_DNS" "${N8N_PORT:-5678}"
}

# reach_cli_doctor [port] -> Zeilen "<pass|warn|red><TAB><text>" fuer doctor (nur lesen; schaltet nichts ein).
reach_cli_doctor() {
  local port="${1:-${N8N_PORT:-5678}}" st
  need_cmd tailscale || { printf 'red\tTunnel: Tailscale ist nicht installiert — lifeagents reconfigure core richtet es ein\n'; return 0; }
  reach_ts_eval "$(reach_cli_ts_status)"
  case "$REACH_TS_STATE" in
    running) : ;;
    needs_funnel) printf 'red\tTunnel: %s\n' "$(reach_cli_state_text needs_funnel)"; return 0 ;;
    *) printf 'red\tTunnel: %s\n' "$(reach_cli_state_text "$REACH_TS_STATE")"; return 0 ;;
  esac
  st="$(reach_cli_funnel_eval "$REACH_TS_DNS" "$(_reach_cli_funnel_status)" "$port")"
  case "$st" in
    ours)    printf 'pass\tTunnel steht (Tailscale Funnel %s, nur die Telegram-Pfade)\n' "$REACH_TS_DNS" ;;
    foreign) printf 'red\tTunnel: %s\n' "$(reach_cli_state_text busy)" ;;
    *)       printf 'red\tTunnel: Funnel-Einträge fehlen oder weichen ab — lifeagents reconfigure core → „Unverändert neu anwenden“\n' ;;
  esac
  if [ -n "$REACH_TS_KEY_DAYS" ] && [ "$REACH_TS_KEY_DAYS" -le 14 ] 2>/dev/null; then
    printf 'warn\tTailscale-Anmeldung läuft in %s Tag(en) ab — danach schweigt der Bot. Im Tailscale-Konto: Machines → Gerät → „Disable key expiry“\n' "$REACH_TS_KEY_DAYS"
  fi
  return 0
}
