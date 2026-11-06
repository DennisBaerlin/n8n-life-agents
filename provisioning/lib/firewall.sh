# shellcheck disable=SC1111,SC2034  # SC1111: deutsche Anführungszeichen in Nutzertexten gewollt; SC2034: N8N_LISTEN_ADDRESS_EFF/LA_FW_* lesen die gesourcten Aufrufer (install_n8n.sh, doctor.sh)
# firewall.sh — n8n fuer einen Reverse Proxy auf einem ANDEREN Rechner oeffnen, aber NUR fuer ihn
# (Install-UX-Phase 5). Sourced by provision.sh + doctor.sh + der Runtime-CLI (`lifeagents proxy`).
#
# EIN Fakt: TRUSTED_PROXIES (core.env; Komma-Liste IPv4/CIDR; leer = 127.0.0.1) — Muster Home Assistant
# `trusted_proxies` / Gitea `REVERSE_PROXY_TRUSTED_PROXIES` / Immich `IMMICH_TRUSTED_PROXIES`. Daraus abgeleitet
# (nie separat gespeichert): n8n-Bind (nur Loopback -> 127.0.0.1, sonst 0.0.0.0) + die Freigabe-Liste der Firewall.
#
# Firewall = EIGENE nftables-Tabelle `inet lifeagents` (Muster fail2ban `inet f2b-table`): /etc/nftables.conf und
# nftables.service bleiben unberuehrt (deren `flush ruleset` wuerde fremde Tabellen loeschen). Geladen von der
# oneshot-Unit lifeagents-firewall.service (After/PartOf/ReloadPropagatedFrom=nftables.service -> nach dessen
# flush/reload wieder da). FAIL-CLOSED: n8n-Drop-in Requires= + ExecStartPre=+nft list table -> n8n laeuft nie
# offen ohne Tabelle; scheitert nft schon bei der Einrichtung, bleibt der Bind 127.0.0.1 (laute Warnung,
# doctor ROT). Reihenfolge: Oeffnen = Firewall zuerst, dann n8n auf 0.0.0.0 (provision: firewall_converge VOR
# prepare_n8n_env); Schliessen = n8n stoppen, dann Tabelle/Unit/Drop-in weg, dann n8n auf 127.0.0.1 starten.
#
# Reads globals: LIFEAGENTS_DIR, N8N_PORT, N8N_ENV_FILE, TEMPLATE_DIR, TRUSTED_PROXIES.
# Sets: N8N_LISTEN_ADDRESS_EFF (vom Aufrufer in n8n.env gerendert).

LA_FW_TABLE="lifeagents"
LA_FW_FILE="${LIFEAGENTS_DIR:-/etc/lifeagents}/firewall.nft"
LA_FW_UNIT_NAME="lifeagents-firewall.service"
LA_FW_UNIT="/etc/systemd/system/${LA_FW_UNIT_NAME}"
LA_FW_DROPIN_DIR="/etc/systemd/system/n8n.service.d"
LA_FW_DROPIN="${LA_FW_DROPIN_DIR}/lifeagents-firewall.conf"
N8N_LISTEN_ADDRESS_EFF="127.0.0.1"

# _ipv4_ok <a.b.c.d> — vier Oktette 0..255 OHNE fuehrende Null (010 waere je nach Parser oktal = mehrdeutig).
_ipv4_ok() {
  printf '%s' "$1" | grep -qE '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' || return 1
  local o
  for o in ${1//./ }; do [ "$o" -le 255 ] || return 1; done
  return 0
}

# _proxy_entry_ok <ip|ip/len> — IPv4 oder IPv4-CIDR /16../32. Breitere Netze (bis hin zu 0.0.0.0/1 = halbes
# Internet) nie — ein Proxy ist ein Rechner, kein Weltausschnitt. IPv6 bewusst nicht: n8n bindet 0.0.0.0 (IPv4),
# ein IPv6-Proxy kaeme nie an; Heimnetz-Proxys sprechen IPv4.
_proxy_entry_ok() {
  local e="$1" ip len
  ip="${e%%/*}"
  _ipv4_ok "$ip" || return 1
  if [ "$ip" != "$e" ]; then
    len="${e#*/}"
    printf '%s' "$len" | grep -qE '^[1-9][0-9]?$' || return 1
    [ "$len" -ge 16 ] && [ "$len" -le 32 ] || return 1
  fi
  return 0
}

# _ip2int <a.b.c.d> -> 32-bit-Zahl;  _cidr_range <ip[/len]> -> "<start> <ende>" (Netzanfang..Netzende).
_ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; printf '%s' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"; }
_int2ip() { printf "%d.%d.%d.%d" $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 8) & 255 )) $(( $1 & 255 )); }
_cidr_range() {
  local ip="${1%%/*}" len=32 n mask
  [ "$ip" != "$1" ] && len="${1#*/}"
  n="$(_ip2int "$ip")"
  mask=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
  printf '%s %s' "$(( n & mask ))" "$(( (n & mask) | (~mask & 0xFFFFFFFF) ))"
}

# normalize_trusted_proxies <roh> -> normalisierte Komma-Liste auf stdout (Leer/Komma/Leerzeichen-getrennt,
# /32 entfernt, dedupliziert, Eintraege, die in einem anderen Eintrag ENTHALTEN sind, fallen weg — sonst lehnt das
# nft-Intervall-Set ueberlappende Elemente ab; Reihenfolge erhalten). Ungueltig -> Meldung auf stderr + rc 1.
normalize_trusted_proxies() {
  local raw="${1:-}" e f out="" list="" s1 e1 s2 e2 keep
  for e in ${raw//,/ }; do
    [ -n "$e" ] || continue
    if ! _proxy_entry_ok "$e"; then
      printf 'Ungültige Proxy-Adresse: %s (erwartet IPv4 wie 192.168.178.10 oder ein Netz ab /16 wie 192.168.178.0/24)\n' "$e" >&2
      return 1
    fi
    e="${e%/32}"
    if [ "${e%%/*}" != "$e" ]; then   # Netz auf seine Grundform (Netzadresse) bringen: 192.168.1.7/24 -> 192.168.1.0/24
      read -r s1 e1 <<<"$(_cidr_range "$e")"
      e="$(_int2ip "$s1")/${e#*/}"
    fi
    list="${list} $e"
  done
  for e in $list; do
    read -r s1 e1 <<<"$(_cidr_range "$e")"
    keep=1
    for f in $list; do
      [ "$f" = "$e" ] && continue
      read -r s2 e2 <<<"$(_cidr_range "$f")"
      # in f enthalten (bei Gleichheit des Bereichs gewinnt der fruehere Eintrag -> Duplikate fallen weg)
      if [ "$s2" -le "$s1" ] && [ "$e1" -le "$e2" ]; then
        if [ "$s1" -ne "$s2" ] || [ "$e1" -ne "$e2" ]; then keep=0; break; fi
      fi
    done
    case ",$out," in *",$e,"*) keep=0 ;; esac
    [ "$keep" -eq 1 ] && out="${out:+$out,}$e"
  done
  printf '%s' "${out:-127.0.0.1}"
}

# _proxy_nonloop <liste> -> die Eintraege ausserhalb 127.0.0.0/8, je Zeile (leer = nur lokal).
_proxy_nonloop() {
  local e
  for e in ${1//,/ }; do
    case "$e" in 127.*) : ;; *) printf '%s\n' "$e" ;; esac
  done
}

# _proxy_is_private <ip|ip/len> -> 0 fuer Heimnetz-Bereiche (RFC 1918, CGNAT/Tailscale 100.64/10).
_proxy_is_private() {
  local ip="${1%%/*}" a b
  a="${ip%%.*}"; b="${ip#*.}"; b="${b%%.*}"
  case "$a" in
    10) return 0 ;;
    192) [ "$b" = "168" ] && return 0 ;;
    172) [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0 ;;
    100) [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0 ;;
  esac
  return 1
}

# _proxy_wide <ip|ip/len> -> 0, wenn der Eintrag ein ganzes Netz ist (Praefix < 32).
_proxy_wide() { case "$1" in */*) return 0 ;; esac; return 1; }

# trusted_proxies_warnings <liste> — Hinweise fuer breite Netze / oeffentliche Adressen (nie fatal).
trusted_proxies_warnings() {
  local e
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    _proxy_wide "$e" && warn "Freigabe für ein ganzes Netz (${e}): jedes Gerät darin erreicht die n8n-Anmeldeseite. Besser nur die IP des Proxy-Rechners."
    _proxy_is_private "$e" || warn "${e} ist keine Heimnetz-Adresse — n8n würde dafür geöffnet. Bitte prüfen."
  done <<<"$(_proxy_nonloop "$1")"
  return 0
}

# _fw_render <liste> — /etc/lifeagents/firewall.nft (atomar: create -> delete -> define in EINER nft -f-Transaktion;
# nft 1.0.6 in Debian 12 kennt kein `destroy`). Port gerendert (N8N_PORT kann ueberschrieben sein).
_fw_render() {
  local elems port="${N8N_PORT:-5678}"
  elems="$(_proxy_nonloop "$1" | paste -sd, - | sed 's/,/, /g')"
  ensure_lifeagents_dir
  cat > "$LA_FW_FILE" <<EOF
# GENERATED by lifeagents (lib/firewall.sh) — nicht von Hand aendern.
# Aendern: lifeagents proxy set <adresse>   (Quelle: TRUSTED_PROXIES in /etc/lifeagents/core.env)
table inet ${LA_FW_TABLE} {}
delete table inet ${LA_FW_TABLE}
table inet ${LA_FW_TABLE} {
	set trusted_v4 {
		type ipv4_addr
		flags interval
		elements = { ${elems} }
	}
	chain input {
		type filter hook input priority filter - 1; policy accept;
		iif "lo" accept
		tcp dport ${port} ip saddr @trusted_v4 accept
		tcp dport ${port} drop
	}
}
EOF
  chmod 0644 "$LA_FW_FILE"
}

# _fw_install_units — Firewall-Unit + n8n-Drop-in schreiben (aus Templates) + daemon-reload.
_fw_install_units() {
  render_template "$TEMPLATE_DIR/lifeagents-firewall.service.tpl" FW_FILE="$LA_FW_FILE" FW_TABLE="$LA_FW_TABLE" \
    > "$LA_FW_UNIT"
  chmod 0644 "$LA_FW_UNIT"
  mkdir -p "$LA_FW_DROPIN_DIR"
  render_template "$TEMPLATE_DIR/n8n-firewall.conf.tpl" FW_UNIT="$LA_FW_UNIT_NAME" FW_TABLE="$LA_FW_TABLE" \
    > "$LA_FW_DROPIN"
  chmod 0644 "$LA_FW_DROPIN"
  systemctl daemon-reload
}

# firewall_present -> 0, wenn Unit/Drop-in/Tabelle (irgendein Rest) existieren.
firewall_present() {
  [ -f "$LA_FW_UNIT" ] || [ -f "$LA_FW_DROPIN" ] || [ -f "$LA_FW_FILE" ] && return 0
  need_cmd nft && nft list table inet "$LA_FW_TABLE" >/dev/null 2>&1
}

# firewall_remove — Schliessen in sicherer Reihenfolge: lauscht n8n offen (0.0.0.0), zuerst n8n stoppen (es darf
# nie ohne Tabelle offen laufen); dann Unit/Drop-in/Tabelle/Datei weg. Der Aufrufer rendert danach den Bind
# 127.0.0.1 und startet n8n (provision.sh: prepare_n8n_env + install_n8n). Idempotent, nie fatal.
firewall_remove() {
  firewall_present || return 0
  if systemctl is-active --quiet n8n 2>/dev/null \
     && [ "$(read_env_value "${N8N_ENV_FILE:-/etc/n8n/n8n.env}" N8N_LISTEN_ADDRESS 2>/dev/null || true)" != "127.0.0.1" ]; then
    log "n8n stoppen, bevor die Freigabe entfernt wird (n8n darf nie offen ohne Firewall laufen) ..."
    systemctl stop n8n 2>/dev/null || true
  fi
  rm -f "$LA_FW_DROPIN" 2>/dev/null || true
  rmdir "$LA_FW_DROPIN_DIR" 2>/dev/null || true
  systemctl stop "$LA_FW_UNIT_NAME" 2>/dev/null || true
  systemctl disable "$LA_FW_UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$LA_FW_UNIT" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  if need_cmd nft; then nft delete table inet "$LA_FW_TABLE" >/dev/null 2>&1 || true; fi
  rm -f "$LA_FW_FILE" 2>/dev/null || true
  ok "n8n-Freigabe für einen Proxy auf einem anderen Rechner entfernt (n8n wieder nur lokal)."
  return 0
}

# firewall_converge — Ist-Zustand an TRUSTED_PROXIES angleichen (idempotent; provision.sh + `lifeagents proxy`).
# Ergebnis in N8N_LISTEN_ADDRESS_EFF: 0.0.0.0 NUR wenn die Tabelle nachweislich geladen ist, sonst 127.0.0.1.
firewall_converge() {
  local list nonloop
  N8N_LISTEN_ADDRESS_EFF="127.0.0.1"
  if ! list="$(normalize_trusted_proxies "${TRUSTED_PROXIES:-}")"; then
    warn "TRUSTED_PROXIES ungültig — n8n bleibt nur lokal erreichbar (ändern: lifeagents proxy set <adresse>)."
    firewall_remove
    return 0
  fi
  nonloop="$(_proxy_nonloop "$list")"
  if [ -z "$nonloop" ]; then
    firewall_remove   # nur lokal: evtl. Reste (auch aus Hand-Edits von core.env) aufraeumen
    return 0
  fi
  if ! need_cmd nft; then
    { apt_update_once && apt_install nftables; } >/dev/null 2>&1 || true
  fi
  if ! need_cmd nft; then
    warn "nftables ließ sich nicht installieren — n8n bleibt nur lokal erreichbar (Proxy auf anderem Rechner geht so nicht)."
    firewall_remove
    return 0
  fi
  trusted_proxies_warnings "$list"
  _fw_render "$list"
  if ! nft -c -f "$LA_FW_FILE" >/dev/null 2>&1; then
    warn "Die Firewall-Regel lässt sich hier nicht setzen (z. B. stark eingeschränkter Container) — n8n bleibt aus Sicherheitsgründen nur lokal erreichbar. Ausweg: die Firewall deines Servers bzw. Hosts (bei Proxmox: Firewall des Containers) so einstellen, dass Port ${N8N_PORT:-5678} nur vom Proxy-Rechner erreichbar ist. Ohne eigene Sperre öffnet sich n8n hier bewusst nicht (Details: Doku-Seite „Installation“)."
    firewall_remove
    return 0
  fi
  _fw_install_units
  systemctl enable "$LA_FW_UNIT_NAME" >/dev/null 2>&1 || true
  # Aktiv -> reload (atomarer nft -f, n8n bleibt laufen); sonst start.
  if systemctl is-active --quiet "$LA_FW_UNIT_NAME"; then
    systemctl reload "$LA_FW_UNIT_NAME" || systemctl restart "$LA_FW_UNIT_NAME" || true
  else
    systemctl start "$LA_FW_UNIT_NAME" || true
  fi
  if firewall_set_matches "$list"; then   # nachweislich GENAU die gewuenschte Liste geladen (nicht nur irgendeine Tabelle)
    N8N_LISTEN_ADDRESS_EFF="0.0.0.0"
    ok "Firewall aktiv: n8n-Port ${N8N_PORT:-5678} nur für $(printf '%s' "$nonloop" | paste -sd, - | sed 's/,/, /g') (+ diesen Rechner)."
  else
    warn "Firewall-Dienst ließ sich nicht starten — n8n bleibt nur lokal erreichbar (Details: journalctl -u ${LA_FW_UNIT_NAME})."
    firewall_remove
  fi
  return 0
}

# firewall_set_matches <liste> -> 0, wenn das geladene Set genau den Nicht-Loopback-Eintraegen entspricht
# (beidseitig normalisiert: nft kuerzt /32, Sortierung egal). Fuer doctor.
firewall_set_matches() {
  local want have
  want="$(_proxy_nonloop "$1" | sort -u)"
  have="$(nft list set inet "$LA_FW_TABLE" trusted_v4 2>/dev/null \
          | tr -d '\n' | sed -n 's/.*elements = { \([^}]*\) }.*/\1/p' | tr ',' '\n' | tr -d ' \t' | sed 's#/32$##' | grep -v '^$' | sort -u)"
  [ -n "$want" ] && [ "$want" = "$have" ]
}

# this_host_lan_ip <ziel-ip> -> die eigene Absender-IP Richtung <ziel-ip> (die Adresse, unter der der Proxy uns
# erreicht); Fallback erste `hostname -I`-Adresse.
this_host_lan_ip() {
  local src=''
  if need_cmd ip; then src="$(ip -4 route get "${1%%/*}" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)"; fi
  [ -n "$src" ] || src="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -n1)"
  printf '%s' "$src"
}
