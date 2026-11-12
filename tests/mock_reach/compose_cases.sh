#!/usr/bin/env bash
# compose_cases.sh — Fall-Runner von scripts/dev/reachability_test.ps1 (zweiter Teil): Weg nach aussen im Docker-Verbund
# (provisioning/lib/reach.sh) gegen Attrappen, ohne Docker, ohne Tailscale-Konto, ohne Telegram:
#   E  Einordnung von `tailscale status --json` (Anmelde-Link nur von login.tailscale.com, Geraete-Freigabe, Funnel fehlt,
#      Ablauf der Anmeldung in Tagen, abgelaufen, kaputtes JSON).
#   F  Funnel: erkannt nur fuer <name>:443 -> 127.0.0.1:8088; Einschalten ruft `tailscale funnel --bg` genau dann.
#   S  reach_status_json je Weg und Zustand (Format, Telegram-Webhook ours/foreign/none/unknown, Ports belegt).
#   P  Installer-Haken: REACH_MODE pruefen und merken, Tunnel-Adresse als DOMAIN nur bei fertigem Tunnel, FritzBox-Weg
#      startet wan nur bei freien Ports und ueberschreibt nichts, ungueltige Adresse = Abbruch.
#   C  Rand-Konfiguration: die oeffentlichen Pfade in compose.yml = die der CLI (templates/Caddyfile.tpl), Editor/Wizard
#      aus dem eigenen Namensraum gesperrt, wan reicht nur an edge:8088.
#   D  DS-Lite automatisch (reach_dslite): UPnP der FritzBox zuerst, dann MyFRITZ!; kein Wert in der Ausgabe.
#   N  Tailscale-Rechnername: Wortliste, Pruefwerte der Zieh-Regel (auch fuer die Start-App), einmal ziehen, Bestand bleibt.
# Die Attrappen ersetzen nur die Docker-/Telegram-Wrapper (rt_edge_*, rt_stack_up, rt_host_port_free, tg_api_curl);
# alles andere ist der echte Lib-Code des Checkouts.
#
# Usage: bash compose_cases.sh <root>     Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2015,SC2329,SC2034,SC2016  # Attrappen ruft der Lib-Code; "a && pass || fail" gewollt (pass = rc 0); $() in Testwerten absichtlich unausgewertet
set -uo pipefail
ROOT="$1"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export LIFEAGENTS_DIR="$W/etc" REACH_CONF_DIR="$W/reach" REACH_RUN_DIR="$W/run" LIFEAGENTS_RUNTIME=compose LA_PROJECT=t
mkdir -p "$LIFEAGENTS_DIR"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# Der Lib-Kopf liest LIFEAGENTS_DIR beim Sourcen.
REACH_CORE_ENV="$LIFEAGENTS_DIR/core.env"
ensure_lifeagents_dir() { mkdir -p "$LIFEAGENTS_DIR"; }

NOW=1800000000   # feste Zeit: 2027-01-15
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ts_json() {   # ts_json <BackendState> <AuthURL> <caps-json-array> [KeyExpiry] [Expired]
  jq -nc --arg b "$1" --arg u "$2" --argjson caps "$3" --arg ke "${4:-}" --argjson ex "${5:-false}" \
    '{BackendState:$b, AuthURL:$u, Self:({DNSName:"bot.tail-fantasy.ts.net.", Expired:$ex,
      CapMap:($caps | map({key:., value:null}) | from_entries)} + (if $ke == "" then {} else {KeyExpiry:$ke} end))}'
}

# --- E: Einordnung -------------------------------------------------------------------------------------------------
st() { reach_ts_eval "$1" "$NOW"; printf '%s|%s|%s|%s' "$REACH_TS_STATE" "$REACH_TS_URL" "$REACH_TS_DNS" "$REACH_TS_KEY_DAYS"; }
LOGIN='https://login.tailscale.com/a/1a2b3c4d5e'
eq E_needs_login   "needs_login|$LOGIN|bot.tail-fantasy.ts.net|" "$(st "$(ts_json NeedsLogin "$LOGIN" '[]')")"
eq E_foreign_link  "needs_login||bot.tail-fantasy.ts.net|"       "$(st "$(ts_json NeedsLogin 'https://evil.example.com/a/1' '[]')")"
eq E_link_lookalike "needs_login||bot.tail-fantasy.ts.net|"      "$(st "$(ts_json NeedsLogin 'https://login.tailscale.com.example.com/a' '[]')")"
eq E_no_link_yet   "starting||bot.tail-fantasy.ts.net|"          "$(st "$(ts_json NeedsLogin '' '[]')")"
eq E_machine_auth  "needs_machine_auth||bot.tail-fantasy.ts.net|" "$(st "$(ts_json NeedsMachineAuth '' '[]')")"
eq E_no_funnel     "needs_funnel||bot.tail-fantasy.ts.net|"      "$(st "$(ts_json Running '' '["https"]')")"
eq E_no_https      "needs_funnel||bot.tail-fantasy.ts.net|"      "$(st "$(ts_json Running '' '["funnel"]')")"
eq E_running       "running||bot.tail-fantasy.ts.net|"           "$(st "$(ts_json Running '' '["https","funnel"]')")"
eq E_caps_url_form "running||bot.tail-fantasy.ts.net|" \
  "$(st "$(ts_json Running '' '["https://tailscale.com/cap/https","https://tailscale.com/cap/funnel"]')")"
eq E_caps_array   "running||bot.tail-fantasy.ts.net|" \
  "$(st "$(ts_json Running '' '[]' | jq -c '.Self.Capabilities=["https","funnel"]')")"
eq E_key_days      "running||bot.tail-fantasy.ts.net|10"         "$(st "$(ts_json Running '' '["https","funnel"]' "$(iso $((NOW + 10*86400 + 60)))")")"
eq E_key_fraction  "running||bot.tail-fantasy.ts.net|10" \
  "$(st "$(ts_json Running '' '["https","funnel"]' "$(date -u -d "@$((NOW + 10*86400 + 60))" +%Y-%m-%dT%H:%M:%S.123456789Z)")")"
eq E_key_past      "key_expired||bot.tail-fantasy.ts.net|-2"     "$(st "$(ts_json Running '' '["https","funnel"]' "$(iso $((NOW - 2*86400 + 60)))")")"
eq E_expired_flag  "key_expired|$LOGIN|bot.tail-fantasy.ts.net|"       "$(st "$(ts_json NeedsLogin "$LOGIN" '[]' '' true)")"
eq E_stopped       "stopped||bot.tail-fantasy.ts.net|"           "$(st "$(ts_json Stopped '' '[]')")"
eq E_garbage       "starting|||"                                  "$(st 'kein json {')"
eq E_empty         "starting|||"                                  "$(st '')"
eq E_bad_dns       "running|||" "$(st "$(ts_json Running '' '["https","funnel"]' | jq -c '.Self.DNSName="x;rm -rf /."')")"

# --- F: Funnel -----------------------------------------------------------------------------------------------------
FUN_ON='{"TCP":{"443":{"HTTPS":true}},"Web":{"bot.tail-fantasy.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8088"}}}},"AllowFunnel":{"bot.tail-fantasy.ts.net:443":true}}'
reach_funnel_configured bot.tail-fantasy.ts.net "$FUN_ON" && pass F_on || fail F_on "nicht erkannt"
reach_funnel_configured bot.tail-fantasy.ts.net "$(printf '%s' "$FUN_ON" | jq -c '.AllowFunnel={}')" \
  && fail F_serve_only "nur Serve (Tailnet) als Funnel gewertet" || pass F_serve_only
reach_funnel_configured bot.tail-fantasy.ts.net "$(printf '%s' "$FUN_ON" | jq -c '.Web[].Handlers["/"].Proxy="http://127.0.0.1:8080"')" \
  && fail F_wrong_target "Ziel :8080 (Editor) als richtig gewertet" || pass F_wrong_target
reach_funnel_configured other.tail-fantasy.ts.net "$FUN_ON" && fail F_other_name "fremder Name" || pass F_other_name
reach_funnel_configured bot.tail-fantasy.ts.net '' && fail F_empty "leer" || pass F_empty

# --- Attrappen fuer S/P ----------------------------------------------------------------------------------------------
LOG="$W/calls.log"; : > "$LOG"
A_TS_UP=1; A_WAN_UP=0; A_TS_JSON=''; rm -f "$W/funnel.json"; A_FUNNEL_JSON='{}'; A_FUNNEL_ALLOWED=0; A_PORTS_FREE=1; A_TG=''
# Attrappe der beiden SOAP-Aufrufe an die FritzBox (Gruppe D): A_UP_STATUS = NewConnectionStatus, A_UP_IP =
# NewExternalIPAddress (Wert '-' = Tag fehlt), A_UP_DOWN=1 = keine Antwort (kein fritz.box, UPnP-Status aus).
A_UP_DOWN=1; A_UP_STATUS=Connected; A_UP_IP=''
upx() { printf '<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:%sResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">%s</u:%sResponse></s:Body></s:Envelope>' "$1" "$2" "$1"; }
_reach_upnp() {
  printf 'upnp %s\n' "$1" >> "$LOG"
  [ "$A_UP_DOWN" = 1 ] && return 0
  case "$1" in
    GetStatusInfo) upx GetStatusInfo "<NewConnectionStatus>$A_UP_STATUS</NewConnectionStatus><NewUptime>42</NewUptime>" ;;
    GetExternalIPAddress) if [ "$A_UP_IP" = - ]; then upx GetExternalIPAddress ''
      else upx GetExternalIPAddress "<NewExternalIPAddress>$A_UP_IP</NewExternalIPAddress>"; fi ;;
  esac
}
rt_edge_active() { case "$1" in tailscale) [ "$A_TS_UP" = 1 ] ;; wan) [ "$A_WAN_UP" = 1 ] ;; *) return 2 ;; esac; }
rt_edge_restart() { printf 'restart %s\n' "$1" >> "$LOG"; }
rt_edge_logs_hint() { printf 'logs %s' "$1"; }
rt_stack_up() { printf 'up %s\n' "$*" >> "$LOG"; case "$*" in *wan*) A_WAN_UP=1 ;; esac; }
rt_host_port_free() { printf 'portprobe %s\n' "$1" >> "$LOG"; [ "$A_PORTS_FREE" = 1 ]; }
rt_edge_exec() {
  [ "$1" = tailscale ] || return 2; shift
  printf 'exec %s\n' "$*" >> "$LOG"
  case "$*" in
    'tailscale status --json --peers=false') printf '%s' "$A_TS_JSON" ;;
    'tailscale funnel status --json') if [ -s "$W/funnel.json" ]; then cat "$W/funnel.json"; else printf '%s' "$A_FUNNEL_JSON"; fi ;;
    *'tailscale funnel --bg --yes http://127.0.0.1:8088')
      # Zustand in einer Datei: der Lib-Code ruft die Attrappe in $(…)-Subshells (wie Tailscale: bleibt gespeichert).
      if [ "$A_FUNNEL_ALLOWED" = 1 ]; then printf '%s' "$FUN_ON" > "$W/funnel.json"
      else printf '\nFunnel is not enabled on your tailnet.\n\n         https://login.tailscale.com/f/funnel?node=nFantasy1\n\n'; return 124; fi ;;
    *) return 1 ;;
  esac
}
tg_api_curl() { printf 'tg %s\n' "$2" >> "$LOG"; [ -n "$A_TG" ] && printf '%s' "$A_TG"; [ -n "$A_TG" ]; }
tg_url() { jq -nc --arg u "$1" '{ok:true, result:{url:$u, pending_update_count:0}}'; }
cfg() { rm -f "$REACH_CORE_ENV"; for kv in "$@"; do env_upsert "$REACH_CORE_ENV" "${kv%%=*}" "${kv#*=}"; done; }
js() { reach_status_json; }
field() { printf '%s' "$1" | jq -r ".$2 | if . == null then \"null\" else tostring end"; }

# --- S: Status je Weg ----------------------------------------------------------------------------------------------
unset REACH_MODE
cfg TELEGRAM_BOT_TOKEN=123:fantasy
out="$(js)"
eq S_no_mode "none|unavailable|no_mode" "$(field "$out" mode)|$(field "$out" state)|$(field "$out" reason)"
eq S_keys "dns_name,ipv4,ipv4_reason,key_days_left,key_expiry,mode,reason,state,ts_hostname,url,webhook,webhook_error,webhook_error_at,webhook_pending" "$(printf '%s' "$out" | jq -r 'keys | join(",")')"

cfg REACH_MODE=tunnel TELEGRAM_BOT_TOKEN=123:fantasy
A_TS_UP=0; out="$(js)"
eq S_ts_not_started "unavailable|not_started" "$(field "$out" state)|$(field "$out" reason)"
A_TS_UP=1; A_TS_JSON="$(ts_json NeedsLogin "$LOGIN" '[]')"; out="$(js)"
eq S_ts_login "needs_login|$LOGIN" "$(field "$out" state)|$(field "$out" url)"
A_TS_JSON="$(ts_json Running '' '["https"]')"; : > "$LOG"; out="$(js)"
eq S_ts_funnel_link "needs_funnel|https://login.tailscale.com/f/funnel?node=nFantasy1" "$(field "$out" state)|$(field "$out" url)"
: > "$LOG"; out="$(js)"
eq S_ts_funnel_cached "https://login.tailscale.com/f/funnel?node=nFantasy1" "$(field "$out" url)"
grep -q 'funnel --bg' "$LOG" && fail S_ts_funnel_cache_hit "Link nicht zwischengespeichert (zweiter funnel-Aufruf)" || pass S_ts_funnel_cache_hit
rm -f "$REACH_RUN_DIR/funnel-link"

# Funnel erlaubt, aber noch nicht eingeschaltet -> Status schaltet ihn ein; Bot zeigt noch nirgends hin.
A_TS_JSON="$(ts_json Running '' '["https","funnel"]' "$(iso $((NOW + 100*86400)))")"; rm -f "$W/funnel.json"; A_FUNNEL_JSON='{}'; A_FUNNEL_ALLOWED=1
A_TG="$(tg_url '')"; : > "$LOG"; out="$(js)"
eq S_ts_pending "pending_activation|none|bot.tail-fantasy.ts.net" "$(field "$out" state)|$(field "$out" webhook)|$(field "$out" dns_name)"
grep -q 'exec timeout 8 tailscale funnel --bg --yes http://127.0.0.1:8088' "$LOG" && pass S_ts_funnel_switched_on || fail S_ts_funnel_switched_on "$(tr '\n' ';' < "$LOG")"
[ "$(field "$out" key_days_left)" -ge 1 ] 2>/dev/null && pass S_ts_key_days || fail S_ts_key_days "$(field "$out" key_days_left)"
: > "$LOG"; js >/dev/null
grep -q 'funnel --bg' "$LOG" && fail S_ts_funnel_idempotent "schon an, trotzdem neu eingeschaltet" || pass S_ts_funnel_idempotent
A_TG="$(tg_url 'https://old.example.org/webhook/x')"; out="$(js)"
eq S_ts_foreign "pending_activation|foreign" "$(field "$out" state)|$(field "$out" webhook)"
cfg REACH_MODE=tunnel TELEGRAM_BOT_TOKEN=123:fantasy DOMAIN=bot.tail-fantasy.ts.net
A_TG="$(tg_url 'https://bot.tail-fantasy.ts.net/webhook/abc/webhook')"; out="$(js)"
eq S_ts_ready "ready|ours" "$(field "$out" state)|$(field "$out" webhook)"
A_TG="$(tg_url 'https://bot.tail-fantasy.ts.net.evil.example/webhook/abc')"; out="$(js)"
eq S_ts_lookalike_webhook "pending_activation|foreign" "$(field "$out" state)|$(field "$out" webhook)"
A_TG=''; out="$(js)"
eq S_ts_tg_down "pending_activation|unknown" "$(field "$out" state)|$(field "$out" webhook)"
A_TS_JSON="$(ts_json Stopped '' '[]')"; out="$(js)"
eq S_ts_stopped "unavailable|stopped" "$(field "$out" state)|$(field "$out" reason)"

cfg REACH_MODE=fritzbox TELEGRAM_BOT_TOKEN=123:fantasy
out="$(js)"
eq S_fb_no_domain "unavailable|no_domain" "$(field "$out" state)|$(field "$out" reason)"
cfg REACH_MODE=fritzbox TELEGRAM_BOT_TOKEN=123:fantasy DOMAIN=meinproxy.deine-domain.myfritz.net
# Status prueft keine Ports selbst (kein Kurzlauf-Container je Abfrage): ports_busy = Marke der letzten Pruefung.
A_WAN_UP=0; A_PORTS_FREE=1; mkdir -p "$REACH_CONF_DIR"; : > "$REACH_CONF_DIR/ports-busy"; : > "$LOG"; out="$(js)"
eq S_fb_ports_busy "ports_busy" "$(field "$out" state)"
grep -q portprobe "$LOG" && fail S_fb_status_no_probe "Status startet eine Port-Probe" || pass S_fb_status_no_probe
rm -f "$REACH_CONF_DIR/ports-busy"; out="$(js)"
eq S_fb_not_started "starting|not_started" "$(field "$out" state)|$(field "$out" reason)"
A_WAN_UP=1; A_TG="$(tg_url 'https://meinproxy.deine-domain.myfritz.net/webhook/abc/webhook')"; out="$(js)"
eq S_fb_ready "ready|ours|meinproxy.deine-domain.myfritz.net" "$(field "$out" state)|$(field "$out" webhook)|$(field "$out" dns_name)"
A_TG="$(tg_url '')"; out="$(js)"
eq S_fb_pending "pending_activation|none" "$(field "$out" state)|$(field "$out" webhook)"

# --- P: Installer-Haken --------------------------------------------------------------------------------------------
cfg TELEGRAM_BOT_TOKEN=123:fantasy
( REACH_MODE='tunnel;id' reach_prepare ) >/dev/null 2>&1 && fail P_bad_mode "ungueltiger Weg angenommen" || pass P_bad_mode
eq P_bad_mode_not_saved "" "$(read_env_value "$REACH_CORE_ENV" REACH_MODE 2>/dev/null || true)"

# Tunnel noch ohne Anmeldung: Container wird gestartet, DOMAIN bleibt leer.
A_TS_UP=1; A_TS_JSON="$(ts_json NeedsLogin "$LOGIN" '[]')"; : > "$LOG"
DOMAIN=''; REACH_MODE=tunnel reach_prepare >/dev/null 2>&1
eq P_mode_saved tunnel "$(read_env_value "$REACH_CORE_ENV" REACH_MODE)"
grep -q '^up --no-deps tailscale$' "$LOG" && pass P_ts_started || fail P_ts_started "$(tr '\n' ';' < "$LOG")"
eq P_no_domain_before_login "|" "${DOMAIN}|$(read_env_value "$REACH_CORE_ENV" DOMAIN 2>/dev/null || true)"
# Bestand mit Adresse, Tailscale gerade weg: die gespeicherte Adresse bleibt.
env_upsert "$REACH_CORE_ENV" DOMAIN bot.tail-fantasy.ts.net
DOMAIN=bot.tail-fantasy.ts.net; A_TS_JSON=''; unset REACH_MODE
reach_prepare >/dev/null 2>&1
eq P_keep_domain "bot.tail-fantasy.ts.net|bot.tail-fantasy.ts.net" "${DOMAIN}|$(read_env_value "$REACH_CORE_ENV" DOMAIN)"
# Angemeldet + Funnel erlaubt: Funnel an, Name wird DOMAIN (Umgebung + core.env).
cfg REACH_MODE=tunnel TELEGRAM_BOT_TOKEN=123:fantasy
A_TS_JSON="$(ts_json Running '' '["https","funnel"]')"; rm -f "$W/funnel.json"; A_FUNNEL_JSON='{}'; A_FUNNEL_ALLOWED=1; DOMAIN=''
reach_prepare >/dev/null 2>&1
eq P_domain_from_tunnel "bot.tail-fantasy.ts.net|bot.tail-fantasy.ts.net" "${DOMAIN}|$(read_env_value "$REACH_CORE_ENV" DOMAIN)"
# Funnel im Konto nicht erlaubt: keine Adresse (sonst zeigte der Webhook ins Leere).
cfg REACH_MODE=tunnel TELEGRAM_BOT_TOKEN=123:fantasy
A_TS_JSON="$(ts_json Running '' '["https"]')"; rm -f "$W/funnel.json"; A_FUNNEL_JSON='{}'; A_FUNNEL_ALLOWED=0; DOMAIN=''
reach_prepare >/dev/null 2>&1
eq P_no_domain_without_funnel "|" "${DOMAIN}|$(read_env_value "$REACH_CORE_ENV" DOMAIN 2>/dev/null || true)"
# FritzBox: Prepare startet nichts.
cfg TELEGRAM_BOT_TOKEN=123:fantasy; : > "$LOG"
REACH_MODE=fritzbox reach_prepare >/dev/null 2>&1
[ -s "$LOG" ] && fail P_fb_prepare_quiet "$(tr '\n' ';' < "$LOG")" || pass P_fb_prepare_quiet

# reach_converge (FritzBox)
cfg REACH_MODE=fritzbox TELEGRAM_BOT_TOKEN=123:fantasy; unset REACH_MODE
A_WAN_UP=0; A_PORTS_FREE=0; : > "$LOG"; rm -rf "$REACH_CONF_DIR"
DOMAIN=meinproxy.deine-domain.myfritz.net reach_converge >/dev/null 2>&1
grep -q '^up' "$LOG" && fail P_fb_busy_no_start "wan trotz belegter Ports gestartet" || pass P_fb_busy_no_start
[ -e "$REACH_CONF_DIR/ports-busy" ] && pass P_fb_busy_marked || fail P_fb_busy_marked "Marke ports-busy fehlt"
A_PORTS_FREE=1; : > "$LOG"
DOMAIN=meinproxy.deine-domain.myfritz.net reach_converge >/dev/null 2>&1
grep -q '^up --no-deps wan$' "$LOG" && pass P_fb_start || fail P_fb_start "$(tr '\n' ';' < "$LOG")"
eq P_fb_domain_file meinproxy.deine-domain.myfritz.net "$(cat "$REACH_CONF_DIR/domain" 2>/dev/null)"
[ -e "$REACH_CONF_DIR/ports-busy" ] && fail P_fb_busy_cleared "Marke nach freiem Start noch da" || pass P_fb_busy_cleared
: > "$LOG"; DOMAIN=meinproxy.deine-domain.myfritz.net reach_converge >/dev/null 2>&1
[ -s "$LOG" ] && fail P_fb_second_run_noop "$(tr '\n' ';' < "$LOG")" || pass P_fb_second_run_noop
: > "$LOG"; DOMAIN=zweiter.deine-domain.myfritz.net reach_converge >/dev/null 2>&1
grep -q '^restart wan$' "$LOG" && pass P_fb_domain_change_restart || fail P_fb_domain_change_restart "$(tr '\n' ';' < "$LOG")"
( DOMAIN='evil.example.org;touch /tmp/x' reach_converge ) >/dev/null 2>&1 && fail P_fb_bad_domain "ungueltige Adresse geschrieben" || pass P_fb_bad_domain
eq P_fb_bad_domain_untouched zweiter.deine-domain.myfritz.net "$(cat "$REACH_CONF_DIR/domain")"
# Grossbuchstaben: wan nimmt nur Kleinschreibung -> klein gespeichert, gleiche Adresse = kein Neustart.
: > "$LOG"; DOMAIN=Zweiter.Deine-Domain.MyFritz.net reach_converge >/dev/null 2>&1
eq P_fb_lowercase "zweiter.deine-domain.myfritz.net|" "$(cat "$REACH_CONF_DIR/domain")|$(cat "$LOG")"
cfg REACH_MODE=tunnel; : > "$LOG"; DOMAIN=bot.tail-fantasy.ts.net reach_converge >/dev/null 2>&1
[ -s "$LOG" ] && fail P_tunnel_converge_noop "$(tr '\n' ';' < "$LOG")" || pass P_tunnel_converge_noop

# Wrapper-Grenze (echter runtime.sh-Code, nicht die Attrappe): nur edge|tailscale|wan.
( unset -f rt_edge_exec; . "$ROOT/provisioning/lib/runtime.sh"; rt_edge_exec postgres true ) >/dev/null 2>&1
eq P_wrapper_fixed_list 2 "$?"

# --- C: Rand-Konfiguration -----------------------------------------------------------------------------------------
CY="$ROOT/provisioning/compose/compose.yml"
# Eine Liste: der Baustein fuer edge kommt aus derselben Vorlage + LA_PUBLIC_PATHS wie das Caddyfile der CLI.
rm -rf "$REACH_CONF_DIR"; reach_edge_public_write && pass C_edge_block_written || fail C_edge_block_written "nicht geschrieben"
blk="$(cat "$REACH_CONF_DIR/edge-public.caddy" 2>/dev/null)"
eq C_edge_paths "$LA_PUBLIC_PATHS" "$(printf '%s\n' "$blk" | sed -n 's/^@lifeagents path //p')"
printf '%s' "$blk" | grep -q 'reverse_proxy anchor:5678' && pass C_edge_upstream || fail C_edge_upstream "Upstream nicht anchor:5678"
cli="$(render_template "$ROOT/provisioning/templates/Caddyfile.tpl" SITE_ADDRESS=x.example.org N8N_UPSTREAM=127.0.0.1:5678 PUBLIC_PATHS="$LA_PUBLIC_PATHS" | sed -n 's/^[[:space:]]*@lifeagents path //p')"
eq C_cli_paths "$LA_PUBLIC_PATHS" "$cli"
reach_edge_public_write && fail C_edge_block_noop "Zweitlauf schrieb neu" || pass C_edge_block_noop
grep -q '@lifeagents path' "$CY" && fail C_no_second_list "compose.yml traegt eine eigene Liste" || pass C_no_second_list
[ "$(grep -c 'abort @own_netns' "$CY")" = 2 ] && pass C_editor_wizard_netns_blocked || fail C_editor_wizard_netns_blocked "erwartet 2 Sperren (8080, 8081)"
[ "$(grep -cE '^[[:space:]]+admin off$' "$CY")" = 2 ] && pass C_admin_off || fail C_admin_off "edge und wan brauchen admin off"
grep -q 'reverse_proxy edge:8088' "$CY" && ! grep -qE 'reverse_proxy edge:(8080|8081)' "$CY" && pass C_wan_only_public || fail C_wan_only_public "wan muss nur an edge:8088"
grep -q "REACH_PUBLIC_TARGET='http://127.0.0.1:8088'" "$ROOT/provisioning/lib/reach.sh" && pass C_funnel_target || fail C_funnel_target "Funnel-Ziel nicht :8088"

# Nur lib/ ohne templates/ (Basis-Image des Test-Substrats) unter set -euo pipefail: das Einlesen darf nicht abbrechen.
mkdir -p "$W/libonly/lib" && cp "$ROOT/provisioning/lib/"{common,runtime,reach,reach_cli}.sh "$W/libonly/lib/"
bash -c "set -euo pipefail; . '$W/libonly/lib/common.sh'; echo geladen" 2>/dev/null | grep -qx geladen \
  && pass C_source_without_templates || fail C_source_without_templates "common.sh/reach.sh brechen ohne templates/ ab"

# --- I: eigene IPv4 (DS-Lite/Carrier-NAT) ----------------------------------------------------------------------------
A_DNS4=''; A_DNS6=''; A_ECHO=''
_reach_dns4() { printf 'dns4 %s\n' "$1" >> "$LOG"; printf '%s' "$A_DNS4"; }
_reach_dns6() { printf 'dns6 %s\n' "$1" >> "$LOG"; printf '%s' "$A_DNS6"; }
_reach_echo4() { printf 'echo\n' >> "$LOG"; printf '%s' "$A_ECHO"; }
v4() { rm -f "$REACH_RUN_DIR/public-ipv4"; reach_ipv4_eval; printf '%s|%s' "$REACH_IPV4" "$REACH_IPV4_REASON"; }
# reach_public_ipv4: eine Stelle fuer den Echo-Dienst (DS-Lite-Pruefung + Adress-Vorschlag im Wizard).
pub() { rm -f "$REACH_RUN_DIR/public-ipv4"; A_ECHO="$1"; reach_public_ipv4; }
eq U_valid       203.0.113.7 "$(pub 203.0.113.7)"
eq U_trailing_nl 203.0.113.7 "$(pub "$(printf '203.0.113.7\n')")"
eq U_empty       ''          "$(pub '')"
eq U_garbage     ''          "$(pub '<html>')"
eq U_bad_octet   ''          "$(pub 999.1.1.1)"
eq U_shared      ''          "$(pub 100.72.1.2)"
eq U_private     ''          "$(pub 192.168.178.20)"
rm -f "$REACH_RUN_DIR/public-ipv4"; A_ECHO=203.0.113.7; reach_public_ipv4 >/dev/null; A_ECHO=198.51.100.9; : > "$LOG"
eq U_cached 203.0.113.7 "$(reach_public_ipv4)"
grep -q '^echo$' "$LOG" && fail U_cached_no_echo "Echo trotz Zwischenspeicher" || pass U_cached_no_echo
rm -f "$REACH_RUN_DIR/public-ipv4"; A_ECHO=''; reach_public_ipv4 >/dev/null; A_ECHO=203.0.113.7
eq U_failure_not_cached 203.0.113.7 "$(reach_public_ipv4)"
rm -f "$REACH_RUN_DIR/public-ipv4"; A_ECHO=''
# Zone nur aus der fluechtigen Hinweis-Datei der Start-App, nie aus der Umgebung (docker inspect) oder aus DOMAIN.
export REACH_HINTS_FILE="$W/hints.env"
hint() { rm -f "$REACH_HINTS_FILE"; [ -n "$1" ] && printf '%s\n' "$@" > "$REACH_HINTS_FILE"; return 0; }
cfg TELEGRAM_BOT_TOKEN=123:fantasy; hint ''; DOMAIN=''
eq I_no_zone "unknown|no_zone" "$(v4)"
LA_MYFRITZ_ZONE=deine-domain.myfritz.net; export LA_MYFRITZ_ZONE
eq I_env_ignored "unknown|no_zone" "$(v4)"
unset LA_MYFRITZ_ZONE
DOMAIN=meinproxy.deine-domain.myfritz.net; eq I_domain_ignored "unknown|no_zone" "$(v4)"; DOMAIN=''
hint 'LA_MYFRITZ_ZONE=Deine-Domain.MyFritz.net'
A_DNS4=''; A_DNS6='2001:db8::1'; eq I_dslite "none|no_a_record" "$(v4)"
A_DNS4=''; A_DNS6='';            eq I_dns_down "unknown|dns_failed" "$(v4)"
A_DNS4='100.72.1.2';             eq I_cgnat "none|shared_address" "$(v4)"
A_DNS4='192.168.178.10';         eq I_private "none|shared_address" "$(v4)"
A_DNS4='100.128.0.1'; A_ECHO='100.128.0.1'; eq I_not_cgnat_edge "own|matches" "$(v4)"
A_DNS4='203.0.113.7'; A_ECHO='203.0.113.7'; eq I_own "own|matches" "$(v4)"
A_DNS4='203.0.113.7'; A_ECHO='198.51.100.9'; eq I_differs "unknown|differs" "$(v4)"
A_DNS4='203.0.113.7'; A_ECHO='';            eq I_echo_down "unknown|echo_failed" "$(v4)"
A_DNS4='203.0.113.7'; A_ECHO='<html>';      eq I_echo_garbage "unknown|echo_failed" "$(v4)"
hint 'LA_MYFRITZ_ZONE=zone.example.org'; eq I_bad_zone "unknown|no_zone" "$(v4)"
hint 'LA_MYFRITZ_ZONE=$(touch /tmp/reach-pwned).myfritz.net'; v4 >/dev/null
[ -e /tmp/reach-pwned ] && fail I_hint_not_executed "Hinweis ausgefuehrt" || pass I_hint_not_executed
eq I_hint_injection "unknown|no_zone" "$(v4)"
ln -sf "$W/elsewhere" "$REACH_HINTS_FILE.tmp"; printf 'LA_MYFRITZ_ZONE=deine-domain.myfritz.net\n' > "$W/elsewhere"
rm -f "$REACH_HINTS_FILE"; mv "$REACH_HINTS_FILE.tmp" "$REACH_HINTS_FILE"
eq I_hint_symlink_ignored "unknown|no_zone" "$(v4)"
hint 'LA_MYFRITZ_ZONE=deine-domain.myfritz.net' "X=$(head -c 5000 /dev/zero | tr '\0' a)"
eq I_hint_too_big_ignored "unknown|no_zone" "$(v4)"
# Status: vor der Wahl und beim FritzBox-Weg mit Ergebnis, zwischengespeichert (kein Echo je Abfrage).
hint 'LA_MYFRITZ_ZONE=deine-domain.myfritz.net'; rm -f "$REACH_RUN_DIR/ipv4" "$REACH_RUN_DIR/public-ipv4"
cfg TELEGRAM_BOT_TOKEN=123:fantasy; A_DNS4='203.0.113.7'; A_ECHO='203.0.113.7'; : > "$LOG"
out="$(js)"; eq I_status_none_mode "own|matches" "$(field "$out" ipv4)|$(field "$out" ipv4_reason)"
: > "$LOG"; js >/dev/null
grep -q '^echo$' "$LOG" && fail I_status_cached "Echo bei jeder Abfrage" || pass I_status_cached
cfg REACH_MODE=tunnel TELEGRAM_BOT_TOKEN=123:fantasy; A_TS_UP=0; out="$(js)"
eq I_tunnel_not_checked "unknown|not_checked" "$(field "$out" ipv4)|$(field "$out" ipv4_reason)"
hint ''
# --- D: DS-Lite automatisch (UPnP der FritzBox, ohne Anmeldung; danach MyFRITZ!) -------------------------------------
ds() { rm -f "$REACH_RUN_DIR/public-ipv4" "$REACH_RUN_DIR/ipv4"; reach_dslite_json; }
dsf() { local j; j="$(ds)"; printf '%s|%s' "$(field "$j" dslite)" "$(field "$j" source)"; }
hint ''; A_DNS4=''; A_DNS6=''; A_ECHO=''
A_UP_DOWN=1;                                 eq D_nothing          "unknown|none"   "$(dsf)"
A_UP_DOWN=0; A_UP_IP='';                     eq D_upnp_empty       "yes|upnp"       "$(dsf)"
A_UP_IP='0.0.0.0';                           eq D_upnp_zero        "yes|upnp"       "$(dsf)"
A_UP_IP='192.0.0.2';                         eq D_upnp_b4_address  "yes|upnp"       "$(dsf)"
A_UP_IP='100.72.1.2';                        eq D_upnp_cgnat       "yes|upnp"       "$(dsf)"
A_UP_IP='203.0.113.7'; A_ECHO='203.0.113.7'; eq D_upnp_own         "no|upnp"        "$(dsf)"
A_UP_IP='203.0.113.7'; A_ECHO='';            eq D_upnp_own_no_echo "no|upnp"        "$(dsf)"
A_UP_IP='203.0.113.7'; A_ECHO='198.51.100.9'; eq D_upnp_differs    "unknown|upnp"   "$(dsf)"
# Leere Adresse zaehlt nur bei bestehender Verbindung (sonst: Box gerade offline, kein Beleg fuer DS-Lite).
A_UP_IP=''; A_UP_STATUS=Disconnected;        eq D_upnp_offline     "unknown|none"   "$(dsf)"
A_UP_STATUS=Connected; A_UP_IP='-';          eq D_upnp_no_tag      "unknown|none"   "$(dsf)"
A_UP_IP='999.1.1.1';                         eq D_upnp_garbage     "unknown|none"   "$(dsf)"
A_UP_IP='1.2.3.4<x>';                        eq D_upnp_markup      "unknown|none"   "$(dsf)"
# Kaskade (FritzBox hinter einem anderen Router): private WAN-Adresse entscheidet nichts, MyFRITZ! darf weiter.
A_UP_IP='192.168.1.50'; hint 'LA_MYFRITZ_ZONE=deine-domain.myfritz.net'; A_DNS4=''; A_DNS6='2001:db8::1'
eq D_cascade_myfritz "yes|myfritz" "$(dsf)"
A_UP_DOWN=1; A_DNS4='203.0.113.7'; A_ECHO='203.0.113.7'; eq D_myfritz_own "no|myfritz" "$(dsf)"
# Kein Wert in der Ausgabe, genau ein Wort aus reach_dslite.
A_UP_DOWN=0; A_UP_IP='203.0.113.7'; A_ECHO='203.0.113.7'; out="$(ds)"
case "$out" in *203.0.113*|*myfritz.net*) fail D_no_value "Wert in der Ausgabe" ;; *) pass D_no_value ;; esac
rm -f "$REACH_RUN_DIR/ipv4"; eq D_word "no" "$(reach_dslite)"
# Zwischenspeicher: zweiter Aufruf fragt weder Box noch Echo; das Statusfeld ipv4 nutzt dieselbe Pruefung.
: > "$LOG"; reach_dslite >/dev/null
grep -qE '^(upnp|echo)' "$LOG" && fail D_cached "Box/Echo trotz Zwischenspeicher" || pass D_cached
cfg TELEGRAM_BOT_TOKEN=123:fantasy; rm -f "$REACH_RUN_DIR/ipv4"; A_UP_IP=''; out="$(js)"
eq D_status_field "none|upnp_no_ipv4" "$(field "$out" ipv4)|$(field "$out" ipv4_reason)"
A_UP_DOWN=1; hint ''; A_DNS4=''; A_DNS6=''; A_ECHO=''; rm -f "$REACH_RUN_DIR/ipv4"
# --- W: Webhook-Angaben fuer den Selbsttest nach „Verbinden" ----------------------------------------------------------
cfg REACH_MODE=fritzbox TELEGRAM_BOT_TOKEN=123:fantasy DOMAIN=meinproxy.deine-domain.myfritz.net; A_WAN_UP=1
A_TG="$(jq -nc '{ok:true, result:{url:"https://meinproxy.deine-domain.myfritz.net/webhook/a/webhook", pending_update_count:3,
  last_error_date:1800000000, last_error_message:"Connection timed out\nzweite Zeile"}}')"
out="$(js)"
eq W_fields "ours|3|1800000000" "$(field "$out" webhook)|$(field "$out" webhook_pending)|$(field "$out" webhook_error_at)"
eq W_error_one_line "Connection timed out zweite Zeile" "$(field "$out" webhook_error)"
A_TG="$(tg_url 'https://meinproxy.deine-domain.myfritz.net/webhook/a/webhook')"; out="$(js)"
eq W_no_error "0||null" "$(field "$out" webhook_pending)|$(field "$out" webhook_error)|$(field "$out" webhook_error_at)"
A_TG=''; out="$(js)"
eq W_unknown "unknown|null" "$(field "$out" webhook)|$(field "$out" webhook_pending)"

# --- N: Tailscale-Rechnername aus zwei Woertern (lib/reach.sh ts_name_ensure, eine Liste lib/ts_names.json) ---------------------
L="$ROOT/provisioning/lib/ts_names.json"
jq -e '[.adjectives, .nouns] | all(length >= 40 and (unique | length) == length and all(test("^[a-z]+$")))' "$L" >/dev/null \
  && pass N_list_shape || fail N_list_shape "Woerter nicht a-z, doppelt oder zu wenige"
bad=0
while IFS=$'\t' read -r s n; do [ "$(ts_name_from_seed "$s")" = "$n" ] || bad=$((bad + 1)); done \
  < <(jq -r '.vectors[] | "\(.seed)\t\(.name)"' "$L")
eq N_vectors 0 "$bad"
words=" $(jq -r '[.adjectives[] as $a | .nouns[] | $a + "-" + .] | join(" ")' "$L") "
bad=0; seen=''
for _ in $(seq 1 60); do
  n="$(ts_name_new)"
  printf '%s' "$n" | grep -qE '^[a-z]+-[a-z]+$' && [ "${#n}" -le 63 ] && case "$words" in *" $n "*) true ;; *) false ;; esac \
    || bad=$((bad + 1))
  seen="$seen$n"$'\n'
done
eq N_random_valid 0 "$bad"
[ "$(printf '%s' "$seen" | sort -u | wc -l)" -gt 5 ] && pass N_random_varies || fail N_random_varies "immer derselbe Name"
E="$W/ts.env"; rm -f "$E"
n1="$(ts_name_ensure "$E" LA_TS_HOSTNAME)"; n2="$(ts_name_ensure "$E" LA_TS_HOSTNAME)"
eq N_ensure_stored "$n1" "$(read_env_value "$E" LA_TS_HOSTNAME)"
eq N_ensure_stable "$n1" "$n2"
printf 'LA_TS_HOSTNAME=calm-otter\n' > "$E"; eq N_keeps_existing calm-otter "$(ts_name_ensure "$E" LA_TS_HOSTNAME)"
printf 'LA_TS_HOSTNAME=bot\n' > "$E";        eq N_keeps_bot      bot        "$(ts_name_ensure "$E" LA_TS_HOSTNAME)"
printf 'LA_TS_HOSTNAME=Bad;name\n' > "$E"; ts_name_ensure "$E" LA_TS_HOSTNAME >/dev/null; rc=$?
eq N_invalid_kept "1|LA_TS_HOSTNAME=Bad;name" "$rc|$(cat "$E")"
eq N_valid_label_long 1 "$(ts_name_valid "$(head -c 64 /dev/zero | tr '\0' a)"; echo $?)"
eq N_seed_garbage "1|" "$(ts_name_from_seed 'abc'; echo "$?|")"
rm -f "$E"; out="$(TS_NAMES_FILE="$W/missing.json" ts_name_ensure "$E" LA_TS_HOSTNAME)"; rc=$?
eq N_no_list "1||absent" "$rc|$out|$([ -e "$E" ] && echo present || echo absent)"
# Der Wizard zeigt den Namen schon vor der Anmeldung: Feld ts_hostname aus der Umgebung des master, nur gueltig.
cfg TELEGRAM_BOT_TOKEN=123:fantasy
eq N_status_hostname calm-otter "$(LA_TS_HOSTNAME=calm-otter reach_status_json | jq -r .ts_hostname)"
eq N_status_hostname_bad ''     "$(LA_TS_HOSTNAME='x;rm -rf /' reach_status_json | jq -r .ts_hostname)"
eq N_status_hostname_unset ''   "$(unset LA_TS_HOSTNAME; reach_status_json | jq -r .ts_hostname)"


# --- L: LAN-Antwort des FritzBox-Wegs (doctor, reach_lan_doctor) ------------------------------------------------------
# Antwortet wan am Rechner nicht (Docker-Neustart, Port-Weiterleitung weg), merkt es sonst nur der Nutzer. doctor misst
# TCP 443 ueber die LAN-Adresse (Hinweis der Start-App) bzw. den Docker-Zugang des Rechners, startet bei Ausbleiben wan
# einmal neu und misst erneut. Attrappen: Messfolge in L_SEQ (1 = antwortet, 0 = Port zu, E = Probe lief nicht; danach bleibt der letzte Wert).
L_SEQ="$W/lan.seq"
rt_host_gateway() { printf '172.30.0.1'; }
rt_probe_host() {
  local v; printf 'probe %s %s\n' "$1" "$2" >> "$LOG"
  v="$(head -n1 "$L_SEQ" 2>/dev/null)"; [ -n "$v" ] || v=1
  [ "$(wc -l < "$L_SEQ")" -gt 1 ] && sed -i 1d "$L_SEQ"
  case "$v" in 1) return 0 ;; E) return 2 ;; *) return 1 ;; esac
}
A_SETTLE=1
rt_edge_settle() { printf 'settle %s\n' "$1" >> "$LOG"; [ "$A_SETTLE" = 1 ]; }
REACH_HINTS_FILE="$W/hints.env"; REACH_LAN_TRIES=3; REACH_LAN_SLEEP=0
lan() { : > "$LOG"; printf '%s\n' "${1:-1}" | tr ' ' '\n' > "$L_SEQ"; reach_lan_doctor; }
lvl() { printf '%s' "$1" | cut -f1 | paste -sd,; }
mkdir -p "$REACH_CONF_DIR"; rm -f "$REACH_CONF_DIR/ports-busy"; printf 'bot.example.org\n' > "$REACH_CONF_DIR/domain"
rm -f "$REACH_HINTS_FILE"; A_WAN_UP=1

cfg REACH_MODE=tunnel; eq L_tunnel_silent '' "$(lan 0)"
cfg REACH_MODE=fritzbox; rm -f "$REACH_CONF_DIR/domain"; eq L_no_domain_silent '' "$(lan 0)"
printf 'bot.example.org\n' > "$REACH_CONF_DIR/domain"

A_WAN_UP=0; out="$(lan 1)"; eq L_wan_down_red red "$(lvl "$out")"
: > "$REACH_CONF_DIR/ports-busy"; out="$(lan 1)"; eq L_ports_busy_warn warn "$(lvl "$out")"; rm -f "$REACH_CONF_DIR/ports-busy"
A_WAN_UP=1

out="$(lan 1)"; eq L_ok_gateway_level pass "$(lvl "$out")"
grep -q '^probe 172.30.0.1 443$' "$LOG" && pass L_ok_gateway_target || fail L_ok_gateway_target "$(tr '\n' ';' < "$LOG")"
grep -q '^restart' "$LOG" && fail L_ok_no_restart "Neustart trotz Antwort" || pass L_ok_no_restart
printf '%s' "$out" | grep -q 'Docker' && pass L_gateway_wording || fail L_gateway_wording "$out"

printf 'LA_HOST_IP=192.0.2.20\n' > "$REACH_HINTS_FILE"
out="$(lan 1)"; grep -q '^probe 192.0.2.20 443$' "$LOG" && pass L_hint_target || fail L_hint_target "$(tr '\n' ';' < "$LOG")"
printf '%s' "$out" | grep -q 'LAN' && pass L_hint_wording || fail L_hint_wording "$out"
printf 'LA_HOST_IP=evil;rm\n' > "$REACH_HINTS_FILE"
lan 1 >/dev/null; grep -q '^probe 172.30.0.1 443$' "$LOG" && pass L_bad_hint_ignored || fail L_bad_hint_ignored "$(tr '\n' ';' < "$LOG")"
rm -f "$REACH_HINTS_FILE"

out="$(lan '0 1')"; eq L_fail_then_ok_levels warn,pass "$(lvl "$out")"
eq L_fail_then_ok_restart_once 1 "$(grep -c '^restart wan$' "$LOG")"
printf '%s' "$out" | grep -q 'Neustart' && pass L_fail_wording || fail L_fail_wording "$out"
out="$(lan '0 0 0 0')"; eq L_fail_twice_levels warn,red "$(lvl "$out")"
eq L_fail_twice_restart_once 1 "$(grep -c '^restart wan$' "$LOG")"
eq L_fail_twice_measures_again 4 "$(grep -c '^probe' "$LOG")"
rt_edge_restart() { printf 'restart %s\n' "$1" >> "$LOG"; return 1; }
out="$(lan 0)"; eq L_restart_fails_levels warn,red "$(lvl "$out")"
rt_edge_restart() { printf 'restart %s\n' "$1" >> "$LOG"; }

# ASCII-Zeilen der Matrix duerfen kein rohes Tab im Text tragen (Format <stufe>\t<text>).
eq L_one_tab_per_line 1 "$(printf '%s\n' "$(lan 0)" | awk -F'\t' 'NF!=2{bad=1} END{print bad?0:1}')"


# Probe, die nicht laufen kann (Image fehlt, Docker-Fehler): eigener Zustand, nie "antwortet nicht", kein Neustart.
out="$(lan E)"; eq L_probe_error_levels warn "$(lvl "$out")"
grep -q '^restart' "$LOG" && fail L_probe_error_no_restart "Neustart trotz nicht gelaufener Probe" || pass L_probe_error_no_restart
printf '%s' "$out" | grep -q 'nicht gemessen' && pass L_probe_error_wording || fail L_probe_error_wording "$out"
out="$(lan '0 E')"; eq L_probe_error_after_restart warn,warn "$(lvl "$out")"
eq L_probe_error_after_restart_once 1 "$(grep -c '^restart wan$' "$LOG")"

# Zeitpuffer: erst auf einen ruhig laufenden wan warten, dann messen; ein nie ruhig laufender wan = ROT, nicht gemessen.
lan 1 >/dev/null; eq L_settle_first "settle wan" "$(grep -nE '^(settle|probe)' "$LOG" | head -n1 | cut -d: -f2)"
A_SETTLE=0; out="$(lan 1)"; eq L_unsettled_red red "$(lvl "$out")"
grep -q '^probe' "$LOG" && fail L_unsettled_no_probe "gemessen, obwohl wan nicht ruhig laeuft" || pass L_unsettled_no_probe
A_SETTLE=1

# doctor.sh-Verdrahtung (echter Code, Teilschale): Stufen -> [ OK ]/[WARN]/[FAIL]; nur ROT zaehlt in den Exit-Wert.
dr() {   # dr <messfolge> -> Ausgabe der Zeilen von _doctor_compose_pod + "fail=<n>" (nur FritzBox-Zeilen)
  : > "$LOG"; printf '%s\n' "$1" | tr ' ' '\n' > "$L_SEQ"
  ( . "$ROOT/provisioning/doctor.sh" >/dev/null 2>&1
    LA_PROJECT=t; N8N_PORT=5678; _fail=0
    rt_netns() { echo net:1; }; rt_container_running() { return 0; }; rt_probe_internal() { [ "$1" = 5678 ]; }
    rt_host_gateway() { printf '172.30.0.1'; }
    rt_probe_host() { local v; v="$(head -n1 "$L_SEQ")"; [ "$(wc -l < "$L_SEQ")" -gt 1 ] && sed -i 1d "$L_SEQ"; case "$v" in 1) return 0 ;; E) return 2 ;; *) return 1 ;; esac; }
    rt_edge_active() { [ "$1" = wan ]; }; rt_edge_restart() { :; }; rt_edge_settle() { :; }; rt_edge_logs_hint() { printf 'logs'; }
    REACH_LAN_TRIES=2; REACH_LAN_SLEEP=0
    _doctor_compose_pod 0.0.0.0 > "$W/dp.out"; grep FritzBox "$W/dp.out"; echo "fail=$_fail" )
}
out="$(dr 1)";     printf '%s' "$out" | grep -q '^  \[ OK \] FritzBox-Weg' && eq L_doctor_ok_fail 'fail=0' "$(printf '%s' "$out" | tail -n1)" || fail L_doctor_ok "$out"
out="$(dr '0 1')"; printf '%s' "$out" | grep -q '^  \[WARN\] FritzBox-Weg' && printf '%s' "$out" | grep -q '^  \[ OK \] FritzBox-Weg antwortet nach' && eq L_doctor_recovered_fail 'fail=0' "$(printf '%s' "$out" | tail -n1)" || fail L_doctor_recovered "$out"
out="$(dr '0 0')"; eq L_doctor_dead_fail 'fail=1' "$(printf '%s' "$out" | tail -n1)"
out="$(dr E)";     printf '%s' "$out" | grep -q '^  \[WARN\] FritzBox-Weg.*nicht gemessen' && eq L_doctor_notmeasured_fail 'fail=0' "$(printf '%s' "$out" | tail -n1)" || fail L_doctor_notmeasured "$out"
printf 'compose_cases: %s Fehler\n' "$fails"
exit "$fails"
