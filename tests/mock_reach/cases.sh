#!/usr/bin/env bash
# cases.sh — Fall-Runner von scripts/dev/reachability_test.ps1, laeuft IM Substrat-Container (root, bash/curl/node/openssl).
#
# Faehrt den ECHTEN Erreichbarkeits-Code des Worktrees (provisioning/lib/common.sh, release_inputs.sh, owner_connect.sh)
# gegen den Mock tests/mock_reach/server.js (Gegenstellen je Loopback-Adresse): Domain-Normalisierung, Box-Namen-Regel,
# Abruf je Adresse mit Vergleich gegen das "lokale n8n" (ok/fritz/fremd/aus/Zertifikat), die Einstufung fuer den
# Installer (Hairpin neutral, IPv6-Zertifikatsfehler = IPv6 woanders, Server ohne IPv6 + Box-Name), den Hinweis-Text,
# das Aufraeumen des /etc/hosts-Pins und den Geraete-Check ohne TTY. Braucht kein n8n und kein Netz.
#
# Usage: bash cases.sh <root> <port>      Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>" / "SKIP <fall>: <grund>";
#                                          Exit = Anzahl FAIL. Belegt <port> und <port>+1.
# shellcheck disable=SC2015  # "Bedingung && pass || fail" ist hier gewollt: pass gibt immer 0 zurueck (kein falsches fail)
set -uo pipefail
ROOT="$1"; PORT="$2"
W=/tmp/mock_reach
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
skip() { printf 'SKIP %s: %s\n' "$1" "$2"; }
# eq <fall> <erwartet> <ist>
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }

# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/release_inputs.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/owner_connect.sh"

# --- Mock starten ---------------------------------------------------------------------------------------------
rm -rf "$W"; mkdir -p "$W"
for d in /proc/[0-9]*; do
  if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q "^node .*mock_reach/server\.js"; then kill "${d#/proc/}" 2>/dev/null || true; fi
done
sleep 0.2
HAVE_V6=0; grep -q '^0\{31\}1 ' /proc/net/if_inet6 2>/dev/null && HAVE_V6=1
HAVE_TLS=0
if command -v openssl >/dev/null 2>&1 \
   && openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=reach.test' -addext 'subjectAltName=DNS:reach.test' \
        -keyout "$W/k.pem" -out "$W/c.pem" >/dev/null 2>&1; then
  HAVE_TLS=1
fi
MOCK_REACH_PORT="$PORT" MOCK_REACH_IPV6="$HAVE_V6" \
  MOCK_REACH_TLS_CERT="$([ "$HAVE_TLS" = 1 ] && printf '%s' "$W/c.pem")" MOCK_REACH_TLS_KEY="$([ "$HAVE_TLS" = 1 ] && printf '%s' "$W/k.pem")" \
  node "$ROOT/mock_reach/server.js" > "$W/mock.log" 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
mock_ready() { kill -0 "$MOCK_PID" 2>/dev/null && [ "$(curl -s "http://127.0.0.1:${PORT}/__pid" 2>/dev/null)" = "{\"pid\":${MOCK_PID}}" ]; }
for _ in $(seq 1 50); do mock_ready && break; sleep 0.1; done
mock_ready || { echo "FAIL setup: Mock nicht bereit (Port ${PORT} belegt?) $(cat "$W/mock.log")"; exit 1; }

# --- 1 Domain-Normalisierung (eine Regel fuer alle Eingabewege) -------------------------------------------------
eq norm_scheme_port_slash 'name.example.org' "$(normalize_domain 'https://Name.Example.org:443/')"
eq norm_trim_dot          'name.example.org' "$(normalize_domain '  name.example.org.  ')"
eq norm_http_path_query   'x.example.org'    "$(normalize_domain 'http://x.example.org/pfad?q=1#a')"
eq norm_keeps_other_port  'x.example.org:8443' "$(normalize_domain 'https://x.example.org:8443/')"
eq norm_plain_unchanged   'bot.example.org'  "$(normalize_domain 'bot.example.org')"
p="$(domain_problem 'x.example.org:8443')"
case "$p" in *8443*443*) pass problem_other_port ;; *) fail problem_other_port "Meldung ohne Port-Hinweis: '$p'" ;; esac
[ -n "$(domain_problem 'na me.example.org')" ] && pass problem_inner_space || fail problem_inner_space "Leerzeichen innen akzeptiert"
[ -z "$(domain_problem 'meinproxy.deine-domain.myfritz.net')" ] && pass problem_valid_empty || fail problem_valid_empty "gueltiger Name bemaengelt"
_validate_domain 'x.example.org:8443' && fail validate_port_rejected "Port 8443 akzeptiert" || pass validate_port_rejected
_validate_domain 'bot.example.org' && pass validate_plain_ok || fail validate_plain_ok "gueltiger Name abgelehnt"
eq input_norm_domain 'name.example.org' "$(_input_normalize DOMAIN 'https://NAME.example.org:443/')"
eq input_norm_other  ' Wert mit Rand '  "$(_input_normalize OWNER_FIRST_NAME ' Wert mit Rand ')"

# --- 2 Box-Namen-Regel (ohne Netz) ---------------------------------------------------------------------------
is_router_myfritz_name 'deine-domain.myfritz.net' && pass router_name_box || fail router_name_box "Box-Name nicht erkannt"
is_router_myfritz_name 'meinproxy.deine-domain.myfritz.net' && fail router_name_device "Geraete-Name als Box erkannt" || pass router_name_device
is_router_myfritz_name 'bot.example.org' && fail router_name_other "fremde Domain als Box erkannt" || pass router_name_other

# --- 3 Abruf je Adresse, Vergleich mit dem lokalen n8n ---------------------------------------------------------
export N8N_URL="http://127.0.0.1:${PORT}"
B="http://reach.test:${PORT}"; P="/webhook/lifeagents-probe-test"
eq probe_ok    ok      "$(reach_probe_ip "$B" "$P" 127.0.0.1)"
eq probe_fritz fritz   "$(reach_probe_ip "$B" "$P" 127.0.0.2)"
eq probe_other other:200 "$(reach_probe_ip "$B" "$P" 127.0.0.3)"
eq probe_down  down    "$(reach_probe_ip "$B" "$P" 127.0.0.4)"
eq probe_nolocal nolocal "$(N8N_URL="http://127.0.0.4:${PORT}" reach_probe_ip "$B" "$P" 127.0.0.1)"
if [ "$HAVE_TLS" = 1 ]; then
  BS="https://reach.test:$((PORT + 1))"
  eq probe_cert cert "$(reach_probe_ip "$BS" "$P" 127.0.0.1)"
  # Mit dem Test-Zertifikat als vertrauenswuerdig (CURL_CA_BUNDLE): HTTPS-Weg ok + die Bestaetigungs-Probe (POST ueber
  # denselben Fingerabdruck-Baustein http_fp) erkennt "bei diesem n8n gelandet" bzw. "nicht erreichbar".
  eq probe_https_trusted ok "$(CURL_CA_BUNDLE="$W/c.pem" reach_probe_ip "$BS" "$P" 127.0.0.1)"
  CURL_CA_BUNDLE="$W/c.pem" hitl_route_probe "$BS/" 127.0.0.1 && pass hitl_probe_same_n8n || fail hitl_probe_same_n8n "gleiche Antwort nicht erkannt"
  CURL_CA_BUNDLE="$W/c.pem" hitl_route_probe "$BS/" 127.0.0.4 && fail hitl_probe_down "nicht erreichbar als ok gewertet" || pass hitl_probe_down
  hitl_route_probe "$BS/" 127.0.0.1 && fail hitl_probe_untrusted "selbstsigniert als ok gewertet" || pass hitl_probe_untrusted
else skip probe_cert "openssl fehlt im Container"; fi
if [ "$HAVE_V6" = 1 ]; then
  eq probe_ipv6_brackets ok "$(reach_probe_ip "$B" "$P" ::1)"
else skip probe_ipv6_brackets "Container ohne IPv6-Loopback"; fi

# --- 4 Einstufung fuer den Installer (reach_assess <r4> <r6> <telegram_ok> <host>) ------------------------------
has_line() { printf '%s\n' "$REACH_LINES" | grep -q "^$1	.*$2"; }
reach_assess ok noaddr 1 meinproxy.deine-domain.myfritz.net
{ [ "$REACH_BAD" = 0 ] && has_line ok 'IPv6'; } && pass assess_no_aaaa_fine || fail assess_no_aaaa_fine "bad=$REACH_BAD lines=$REACH_LINES"
reach_assess ok ok 1 meinproxy.deine-domain.myfritz.net
{ [ "$REACH_BAD" = 0 ] && [ -z "$REACH_HINT" ]; } && pass assess_all_ok || fail assess_all_ok "bad=$REACH_BAD hint=$REACH_HINT"
reach_assess ok fritz 1 deine-domain.myfritz.net
{ [ "$REACH_BAD" = 1 ] && has_line bad 'IPv6' && case "$REACH_HINT" in *'MyFRITZ!-Freigabe'*) true ;; *) false ;; esac; } \
  && pass assess_fritz || fail assess_fritz "bad=$REACH_BAD hint=$REACH_HINT"
case "$REACH_HINT" in *'auch für IPv6 freigeben'*|*'IPv4 und IPv6'*) fail hint_not_old_way "alter Portfreigabe-Weg im Hinweis" ;; *) pass hint_not_old_way ;; esac
reach_assess down ok 1 bot.example.org
{ [ "$REACH_BAD" = 0 ] && has_line info 'Heimnetz'; } && pass assess_hairpin_neutral || fail assess_hairpin_neutral "bad=$REACH_BAD lines=$REACH_LINES"
reach_assess down noaddr 0 bot.example.org
[ "$REACH_BAD" = 1 ] && pass assess_v4_down_without_telegram || fail assess_v4_down_without_telegram "bad=$REACH_BAD"
reach_assess ok cert 1 bot.example.org
{ [ "$REACH_BAD" = 1 ] && case "$REACH_HINT" in *IPv6*) true ;; *) false ;; esac && case "$REACH_HINT" in *Zertifikat*) false ;; *) true ;; esac; } \
  && pass assess_v6_cert_is_v6_elsewhere || fail assess_v6_cert_is_v6_elsewhere "hint=$REACH_HINT"
reach_assess cert cert 0 bot.example.org
{ [ "$REACH_BAD" = 1 ] && case "$REACH_HINT" in *Zertifikat*) true ;; *) false ;; esac; } && pass assess_cert || fail assess_cert "hint=$REACH_HINT"
# Telegram stellt an genau diese Adresse zu (verlangt ein gueltiges Zertifikat) -> rc 60 vom Server aus = Router-Oberflaeche
reach_assess cert noaddr 1 bot.example.org
{ [ "$REACH_BAD" = 0 ] && has_line info 'Heimnetz'; } && pass assess_cert_hairpin_with_telegram || fail assess_cert_hairpin_with_telegram "bad=$REACH_BAD lines=$REACH_LINES"

# --- 4b Stellt Telegram an genau diese Adresse zu? (tg_webhook_delivers <getWebhookInfo> <domain>) -------------------
now="$(date +%s)"
wh() { printf '{"ok":%s,"result":{"url":"%s","pending_update_count":%s,"last_error_date":%s}}' "$1" "$2" "$3" "$4"; }
tg_webhook_delivers "$(wh true https://bot.example.org/webhook/x 0 0)" bot.example.org && pass tg_delivers_ok || fail tg_delivers_ok "gueltiger Webhook abgelehnt"
tg_webhook_delivers "$(wh true https://alt.example.org/webhook/x 0 0)" bot.example.org && fail tg_delivers_old_domain "Webhook der alten Adresse akzeptiert" || pass tg_delivers_old_domain
tg_webhook_delivers "$(wh true https://bot.example.org/webhook/x 3 "$now")" bot.example.org && fail tg_delivers_jam "Stau mit frischem Fehler akzeptiert" || pass tg_delivers_jam
tg_webhook_delivers "$(wh true https://bot.example.org/webhook/x 3 $((now - 3600)))" bot.example.org && pass tg_delivers_old_error || fail tg_delivers_old_error "alter Fehler als Stau gewertet"
tg_webhook_delivers "$(wh false '' 0 0)" bot.example.org && fail tg_delivers_unknown "ungueltige Antwort akzeptiert" || pass tg_delivers_unknown
tg_webhook_delivers '' bot.example.org && fail tg_delivers_empty "leere Antwort akzeptiert" || pass tg_delivers_empty
reach_assess ok noroute 1 deine-domain.myfritz.net
{ [ "$REACH_BAD" = 1 ] && case "$REACH_HINT" in *'MyFRITZ!-Freigabe'*) true ;; *) false ;; esac; } \
  && pass assess_noroute_boxname || fail assess_noroute_boxname "bad=$REACH_BAD hint=$REACH_HINT"
reach_assess ok noroute 1 meinproxy.deine-domain.myfritz.net
{ [ "$REACH_BAD" = 0 ] && has_line info 'nicht prüfbar'; } && pass assess_noroute_neutral || fail assess_noroute_neutral "bad=$REACH_BAD lines=$REACH_LINES"

# --- 5 /etc/hosts-Pin aufraeumen (hosts_pin_prune <behalten>) -------------------------------------------------
H="$W/hosts"
mk_hosts() {
  printf '127.0.0.1 localhost\n# --- BEGIN PVE ---\n10.0.0.5 pve.example.org pve\n# --- END PVE ---\n' > "$H"
  [ -n "${1:-}" ] && printf '%s\n%s %s\n%s\n' "$_HOSTS_BEGIN" 192.168.178.20 "$1" "$_HOSTS_END" >> "$H"
  return 0
}
mk_hosts alt.example.org
HOSTS_FILE="$H" hosts_pin_prune neu.example.org
{ ! grep -q 'alt.example.org' "$H" && grep -q 'pve.example.org' "$H" && grep -q '^127.0.0.1 localhost' "$H"; } \
  && pass pin_prune_old_host || fail pin_prune_old_host "$(tr '\n' '|' < "$H")"
mk_hosts neu.example.org; cp "$H" "$W/hosts.before"
HOSTS_FILE="$H" hosts_pin_prune neu.example.org
cmp -s "$H" "$W/hosts.before" && pass pin_keep_current || fail pin_keep_current "aktueller Pin angefasst"
mk_hosts alt.example.org
HOSTS_FILE="$H" hosts_pin_prune ''
! grep -q 'alt.example.org' "$H" && pass pin_prune_no_domain || fail pin_prune_no_domain "Pin ohne Domain stehen geblieben"
mk_hosts; cp "$H" "$W/hosts.before"
( set -e; HOSTS_FILE="$H" hosts_pin_prune neu.example.org ) && cmp -s "$H" "$W/hosts.before" \
  && pass pin_no_block_rc0 || fail pin_no_block_rc0 "rc!=0 oder Datei veraendert"
( set -e; HOSTS_FILE="$W/fehlt" hosts_pin_prune neu.example.org ) && [ ! -e "$W/fehlt" ] \
  && pass pin_missing_file_rc0 || fail pin_missing_file_rc0 "rc!=0 oder Datei angelegt"
printf '127.0.0.1 localhost' > "$H"; HOSTS_FILE="$H" hosts_pin_set neu.example.org 192.168.178.20
HOSTS_FILE="$H" hosts_pin_prune anders.example.org
{ grep -qx '127.0.0.1 localhost' "$H" && ! grep -q 'neu.example.org' "$H"; } \
  && pass pin_no_trailing_newline || fail pin_no_trailing_newline "$(tr '\n' '|' < "$H")"

# --- 6 Geraete-Check ohne TTY: kein Prompt, keine Ausgabe ---------------------------------------------------------
out="$(DOMAIN=bot.example.org _oc_device_check report < /dev/null 2>&1)"; rc=$?
{ [ "$rc" = 0 ] && [ -z "$out" ]; } && pass device_check_no_tty_silent || fail device_check_no_tty_silent "rc=$rc out=$out"

exit "$fails"
