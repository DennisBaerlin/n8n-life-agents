#!/usr/bin/env bash
# cli_cases.sh — Fall-Runner von scripts/dev/reachability_test.ps1 (dritter Teil): Weg nach aussen der CLI-Installation
# (provisioning/lib/reach_cli.sh + die Dialoge in release_inputs.sh) gegen Attrappen, ohne Tailscale-Konto, ohne Netz:
#   M  Weg aus REACH_MODE/DOMAIN (Bestand mit Domain = eigener Proxy, nie neu gefragt).
#   T  TUN-Geraet vs. Userspace-Modus; /etc/default/tailscaled genau mit einem --tun=userspace-networking.
#   P  Funnel-Eintraege aus der EINEN Pfad-Liste LA_PUBLIC_PATHS; Einordnung ours/absent/partial/foreign.
#   E  Funnel einschalten/zuruecknehmen ueber eine Attrappe `tailscale` (fremde Konfiguration bleibt unberuehrt).
#   S  Tunnel-Stand (settle): Anmelden, Freigabe, fertig = DOMAIN + TRUSTED_PROXIES.
#   F  FritzBox: Zone aus dem Box-Zertifikat, DS-Lite mit dieser Zone, Adresse zeigt auf den Anschluss.
#   A  Dialoge (Wahl des Wegs, FritzBox-Pruefungen, MyFRITZ!-Adresse, Tunnel-Anmeldung, Uebersicht/reconfigure).
#
# Usage: bash cli_cases.sh <root>     Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2015,SC2329,SC2034  # Attrappen ruft der Lib-Code; "a && pass || fail" gewollt (pass = rc 0)
set -uo pipefail
ROOT="$1"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "'$2' fehlt"; fi; }
hasnt() { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1" "'$2' steht drin"; else pass "$1"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export LIFEAGENTS_DIR="$W/etc" REACH_CONF_DIR="$W/reach" REACH_RUN_DIR="$W/run" REPO_ROOT="$ROOT" LIFEAGENTS_RUNTIME=systemd
export INSTALL_ENV_FILE="$W/etc/core.env" N8N_PORT=5678 PROFILE=release UNATTENDED=0 N8N_USER=root
mkdir -p "$LIFEAGENTS_DIR" "$W/bin"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/release_inputs.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/owner_connect.sh"
REACH_CORE_ENV="$INSTALL_ENV_FILE"
ensure_lifeagents_dir() { mkdir -p "$LIFEAGENTS_DIR"; }
cfg() { rm -f "$INSTALL_ENV_FILE"; for kv in "$@"; do env_upsert "$INSTALL_ENV_FILE" "${kv%%=*}" "${kv#*=}"; done; }
clr() { unset REACH_MODE DOMAIN TRUSTED_PROXIES; }

# --- M: Weg ----------------------------------------------------------------------------------------------------------
clr; cfg;                         eq M_none        none     "$(reach_cli_mode)"
clr; cfg DOMAIN=bot.example.org;  eq M_legacy_dom  proxy    "$(reach_cli_mode)"
clr; cfg REACH_MODE=tunnel;       eq M_stored      tunnel   "$(reach_cli_mode)"
clr; cfg REACH_MODE=fritzbox; REACH_MODE=tunnel; eq M_env_first tunnel "$(reach_cli_mode)"
clr; cfg REACH_MODE=quatsch;      eq M_invalid     none     "$(reach_cli_mode)"
clr; cfg REACH_MODE= DOMAIN=bot.example.org; eq M_empty_dom proxy "$(reach_cli_mode)"

# --- T: TUN / FLAGS --------------------------------------------------------------------------------------------------
REACH_CLI_TUN_DEV="$W/keins";  eq T_no_tun userspace "$(reach_cli_tun_mode)"
: > "$W/datei"; REACH_CLI_TUN_DEV="$W/datei"; eq T_not_chardev userspace "$(reach_cli_tun_mode)"
REACH_CLI_TUN_DEV=/dev/null; eq T_null_not_tun userspace "$(reach_cli_tun_mode)"
D0='# Set the port to listen on for incoming VPN packets.
PORT="41641"

# Extra flags you might want to pass to tailscaled.
FLAGS=""'
r1="$(reach_cli_ts_defaults_render "$D0" userspace)"
has T_user_flag 'FLAGS="--tun=userspace-networking"' "$r1"
has T_port_kept 'PORT="41641"' "$r1"
eq T_idempotent "$r1" "$(reach_cli_ts_defaults_render "$r1" userspace)"
eq T_kernel_back "$D0" "$(reach_cli_ts_defaults_render "$r1" kernel)"
eq T_other_flag 'FLAGS="--verbose=1 --tun=userspace-networking"' "$(reach_cli_ts_defaults_render 'FLAGS="--verbose=1"' userspace)"
eq T_missing_file 'FLAGS="--tun=userspace-networking"' "$(reach_cli_ts_defaults_render '' userspace)"

# --- P: Funnel-Eintraege ---------------------------------------------------------------------------------------------
M="$(reach_cli_funnel_mounts 5678)"
eq P_count "$(printf '%s' "$LA_PUBLIC_PATHS" | wc -w | tr -d ' ')" "$(printf '%s\n' "$M" | grep -c .)"
has P_webhook "$(printf '/webhook\thttp://127.0.0.1:5678/webhook')" "$M"
has P_exact "$(printf '/webhook-waiting-telegram\thttp://127.0.0.1:5678/webhook-waiting-telegram')" "$M"
hasnt P_no_root "$(printf '/\t')" "$M"
hasnt P_no_star '*' "$M"
DNS=bot.tail-fantasy.ts.net
ours_json() {   # ours_json [extra-jq] -> Funnel-Status, wie Tailscale ihn mit genau unseren Eintraegen meldet
  reach_cli_funnel_mounts 5678 | jq -Rsc --arg k "$DNS:443" 'split("\n") | map(select(length > 0) | split("\t"))
    | {TCP:{"443":{HTTPS:true}}, Web:{($k):{Handlers:(map({key:.[0], value:{Proxy:.[1]}}) | from_entries)}}, AllowFunnel:{($k):true}}' \
    | jq -c "${1:-.}"
}
eq P_ours    ours    "$(reach_cli_funnel_eval "$DNS" "$(ours_json)" 5678)"
eq P_absent  absent  "$(reach_cli_funnel_eval "$DNS" '{}' 5678)"
eq P_empty   absent  "$(reach_cli_funnel_eval "$DNS" '' 5678)"
eq P_partial partial "$(reach_cli_funnel_eval "$DNS" "$(ours_json 'del(.Web[].Handlers["/webhook-test"])')" 5678)"
eq P_no_funnel partial "$(reach_cli_funnel_eval "$DNS" "$(ours_json '.AllowFunnel={}')" 5678)"
eq P_root_foreign foreign "$(reach_cli_funnel_eval "$DNS" "$(ours_json '.Web[].Handlers["/"]={Proxy:"http://127.0.0.1:8123"}')" 5678)"
eq P_other_port partial "$(reach_cli_funnel_eval "$DNS" "$(ours_json)" 9999)"
eq P_other_name absent "$(reach_cli_funnel_eval other.tail-fantasy.ts.net "$(ours_json)" 5678)"

# --- Attrappe `tailscale` (eine Datei im PATH: der Lib-Code ruft sie auch ueber `timeout`) ------------------------------
cat > "$W/bin/tailscale" <<'TS'
#!/usr/bin/env bash
S="$TS_MOCK_DIR"
printf 'ts %s\n' "$*" >> "$S/calls.log"
case "$1 $2" in
  'status --json') cat "$S/status.json" 2>/dev/null ;;
  'funnel status') cat "$S/funnel.json" 2>/dev/null || printf '{}' ;;
  'funnel --bg')
    m="$5"; t="$6"
    if [ "$(cat "$S/allowed" 2>/dev/null)" != 1 ]; then
      printf '\nFunnel is not enabled on your tailnet.\n\n    https://login.tailscale.com/f/funnel?node=nFantasy1\n'; exit 1
    fi
    f="$(cat "$S/funnel.json" 2>/dev/null || printf '{}')"
    printf '%s' "$f" | jq -c --arg k "$(cat "$S/dns"):443" --arg m "$m" --arg t "$t" \
      '.Web[$k].Handlers[$m] = {Proxy:$t} | .AllowFunnel[$k] = true' > "$S/funnel.json" ;;
  'funnel --https=443')
    m="$4"
    f="$(cat "$S/funnel.json" 2>/dev/null || printf '{}')"
    printf '%s' "$f" | jq -c --arg k "$(cat "$S/dns"):443" --arg m "$m" 'del(.Web[$k].Handlers[$m])' > "$S/funnel.json" ;;
  'up --hostname=bot') : ;;
  *) exit 1 ;;
esac
TS
chmod +x "$W/bin/tailscale"
export TS_MOCK_DIR="$W/ts" PATH="$W/bin:$PATH"
mkdir -p "$TS_MOCK_DIR"; printf '%s' "$DNS" > "$TS_MOCK_DIR/dns"
ts_reset() { rm -f "$TS_MOCK_DIR"/*.json "$TS_MOCK_DIR/calls.log" "$TS_MOCK_DIR/allowed"; printf '%s' "$DNS" > "$TS_MOCK_DIR/dns"; }
ts_state() {   # ts_state <BackendState> <AuthURL> <caps-json>
  jq -nc --arg b "$1" --arg u "$2" --argjson caps "$3" \
    '{BackendState:$b, AuthURL:$u, Self:{DNSName:"bot.tail-fantasy.ts.net.", CapMap:($caps | map({key:., value:null}) | from_entries)}}' \
    > "$TS_MOCK_DIR/status.json"
}

# --- E: Funnel ein/aus -----------------------------------------------------------------------------------------------
ts_reset; echo 1 > "$TS_MOCK_DIR/allowed"
reach_cli_funnel_ensure "$DNS" 5678; eq E_on_rc 0 "$?"
eq E_on_state ours "$(reach_cli_funnel_eval "$DNS" "$(cat "$TS_MOCK_DIR/funnel.json")" 5678)"
: > "$TS_MOCK_DIR/calls.log"; reach_cli_funnel_ensure "$DNS" 5678
hasnt E_idempotent 'funnel --bg' "$(cat "$TS_MOCK_DIR/calls.log")"
ts_reset; rc=0; reach_cli_funnel_ensure "$DNS" 5678 || rc=$?
eq E_not_allowed_rc 1 "$rc"
eq E_link "https://login.tailscale.com/f/funnel?node=nFantasy1" "$REACH_CLI_FUNNEL_URL"
ts_reset; ours_json '.Web[].Handlers["/"]={Proxy:"http://127.0.0.1:8123"}' > "$TS_MOCK_DIR/funnel.json"; echo 1 > "$TS_MOCK_DIR/allowed"
rc=0; reach_cli_funnel_ensure "$DNS" 5678 || rc=$?
eq E_foreign_rc 3 "$rc"
hasnt E_foreign_untouched 'funnel --bg' "$(cat "$TS_MOCK_DIR/calls.log")"
reach_cli_funnel_off "$DNS" 5678
eq E_off_keeps_foreign '["/"]' "$(jq -c --arg k "$DNS:443" '.Web[$k].Handlers | keys' "$TS_MOCK_DIR/funnel.json")"
ts_reset; reach_cli_funnel_off "$DNS" 5678
hasnt E_off_absent_noop 'off' "$(cat "$TS_MOCK_DIR/calls.log" 2>/dev/null)"

# --- S: Tunnel-Stand -------------------------------------------------------------------------------------------------
clr; ts_reset; ts_state NeedsLogin 'https://login.tailscale.com/a/fantasy1' '[]'
reach_cli_tunnel_settle 5678; eq S_login "needs_login|https://login.tailscale.com/a/fantasy1" "$REACH_CLI_STATE|$REACH_TS_URL"
ts_state NeedsMachineAuth '' '[]'; reach_cli_tunnel_settle 5678; eq S_machine needs_machine_auth "$REACH_CLI_STATE"
ts_state Running '' '["https"]'; reach_cli_tunnel_settle 5678
eq S_funnel_needed "needs_funnel|" "$REACH_CLI_STATE|${DOMAIN:-}"
ts_state Running '' '["https","funnel"]'; echo 1 > "$TS_MOCK_DIR/allowed"; reach_cli_tunnel_settle 5678
eq S_ready "ready|$DNS|127.0.0.1" "$REACH_CLI_STATE|${DOMAIN:-}|${TRUSTED_PROXIES:-}"
clr; ts_reset; ts_state Running '' '["https","funnel"]'; ours_json '.Web[].Handlers["/"]={Proxy:"http://127.0.0.1:8123"}' > "$TS_MOCK_DIR/funnel.json"
reach_cli_tunnel_settle 5678; eq S_busy "busy|" "$REACH_CLI_STATE|${DOMAIN:-}"
PATH_SAVE="$PATH"; PATH="/usr/bin:/bin"; hash -r
need_cmd tailscale && fail S_missing "Test-Umgebung hat ein echtes tailscale" || { reach_cli_tunnel_settle; eq S_missing missing "$REACH_CLI_STATE"; }
PATH="$PATH_SAVE"; hash -r

# --- F: FritzBox -----------------------------------------------------------------------------------------------------
_reach_cli_box_cert_names() { printf '%s\n' fritz.box '*.deine-domain.myfritz.net' 'Deine-Domain.MyFritz.net' 192.168.178.10; }
eq F_zone deine-domain.myfritz.net "$(reach_cli_myfritz_zone)"
_reach_cli_box_cert_names() { printf '%s\n' fritz.box; }
eq F_no_zone '' "$(reach_cli_myfritz_zone)"
reach_dslite() { printf 'zone=%s\n' "$(reach_myfritz_zone)"; }
eq F_dslite_zone 'zone=deine-domain.myfritz.net' "$(reach_cli_dslite deine-domain.myfritz.net)"
_reach_cli_dns4() { case "$1" in ok.*) printf '203.0.113.7' ;; wrong.*) printf '198.51.100.9' ;; *) : ;; esac; }
reach_public_ipv4() { printf '203.0.113.7'; }
eq F_ok      ok      "$(reach_cli_domain_check ok.deine-domain.myfritz.net)"
eq F_wrong   wrong   "$(reach_cli_domain_check wrong.deine-domain.myfritz.net)"
eq F_pending pending "$(reach_cli_domain_check neu.deine-domain.myfritz.net)"
reach_public_ipv4() { :; }
eq F_unknown unknown "$(reach_cli_domain_check ok.deine-domain.myfritz.net)"
reach_public_ipv4() { printf '203.0.113.7'; }

# --- A: Dialoge (Eingaben aus Warteschlangen-Dateien; ui_* laufen auch in $(…)-Subshells) ------------------------------
ui_interactive() { return 0; }
ensure_gum() { :; }
pop() { local f="$W/q.$1" v; v="$(head -n1 "$f" 2>/dev/null)"; sed -i '1d' "$f" 2>/dev/null; printf '%s' "$v"; }
ui_choose() { { printf -- '--- %s [vor: %s]\n' "$1" "${3:-}"; cat; } >> "$W/choose.log"; pop choose; }
ui_input()  { printf -- '--- %s\n' "$1" >> "$W/input.log"; pop input; }
ui_box() { { printf -- '=== %s\n' "${1:-}"; cat; } >> "$W/box.log"; }
ui_step() { :; }; ui_step_done() { :; }; ui_step_bad() { :; }
q() { local k="$1"; shift; printf '%s\n' "$@" > "$W/q.$k"; }
newrun() { clr; cfg; rm -f "$W"/q.* "$W"/*.log; UI_ASKED=0; UI_ASKED_KEYS=''; _TP_SKIPPED=0; }
TUNNEL_LABEL="$(pkg_text core wizard.opt.reach_tunnel)"

newrun; q choose tunnel
_ask_reach_mode 2>/dev/null
eq A_tunnel "tunnel|tunnel" "${REACH_MODE:-}|$(read_env_value "$INSTALL_ENV_FILE" REACH_MODE)"
has A_label_from_catalog "$TUNNEL_LABEL" "$(cat "$W/choose.log")"
has A_preselect_tunnel "[vor: $TUNNEL_LABEL (empfohlen)]" "$(cat "$W/choose.log")"
has A_box_title "$(pkg_text core wizard.page.reach_title)" "$(cat "$W/box.log")"
_key_not_offered DOMAIN && pass A_tunnel_no_domain || fail A_tunnel_no_domain "Adresse beim Tunnel angeboten"
_key_not_offered TRUSTED_PROXIES && pass A_tunnel_no_proxy || fail A_tunnel_no_proxy "Proxy-Ort beim Tunnel angeboten"
DOMAIN=bot.tail-fantasy.ts.net; : > "$W/choose.log"; _ask_trusted_proxies 2>/dev/null
eq A_tunnel_never_proxy_q '' "$(cat "$W/choose.log")"

newrun; cfg DOMAIN=bot.example.org; DOMAIN=bot.example.org
_ask_reach_mode 2>/dev/null
eq A_legacy_silent "proxy|" "${REACH_MODE:-}|$(cat "$W/choose.log" 2>/dev/null)"

newrun; q choose ''
_ask_reach_mode 2>/dev/null
eq A_esc_home "|none" "${REACH_MODE:-}|$(reach_cli_mode)"
env_has_key "$INSTALL_ENV_FILE" REACH_MODE && pass A_esc_seen || fail A_esc_seen "keine gesehen-Zeile"

reach_cli_dslite() { printf '%s\n' "$A_DSL"; }
reach_cli_myfritz_zone() { printf '%s' "$A_ZONE"; }
A_ZONE=deine-domain.myfritz.net
newrun; A_DSL=no; q choose fritzbox created
_ask_reach_mode 2>/dev/null
eq A_fritz "fritzbox" "${REACH_MODE:-}"
has A_fritz_guide "$(pkg_text core wizard.page.fb_guide_title)" "$(cat "$W/box.log")"
has A_fritz_note "$(pkg_text core wizard.page.fb_guide_note | cut -c1-40)" "$(cat "$W/box.log")"
newrun; A_DSL=yes; q choose fritzbox tunnel
_ask_reach_mode 2>/dev/null
eq A_dslite_to_tunnel tunnel "${REACH_MODE:-}"
newrun; A_DSL=unknown; q choose fritzbox yes tunnel
_ask_reach_mode 2>/dev/null
eq A_dslite_asked tunnel "${REACH_MODE:-}"
has A_dslite_question "$(pkg_text core wizard.page.dslite_title)" "$(cat "$W/choose.log" "$W/box.log")"
newrun; A_DSL=no; q choose fritzbox back proxy
_ask_reach_mode 2>/dev/null
eq A_fritz_back proxy "${REACH_MODE:-}"

# MyFRITZ!-Adresse: Geraetename + Zone, nur Geprueftes ohne Rueckfrage.
newrun; REACH_MODE=fritzbox; q input ok
_ask_fritz_domain 2>/dev/null
eq A_fdom_ok "ok.$A_ZONE|ok.$A_ZONE" "${DOMAIN:-}|$(read_env_value "$INSTALL_ENV_FILE" DOMAIN)"
has A_fdom_suffix "$A_ZONE" "$(cat "$W/input.log")"
newrun; REACH_MODE=fritzbox; q input neu; q choose retry
_reach_cli_dns4() { case "$1" in ok.*|neu.*) printf '203.0.113.7' ;; esac; }
cnt=0; reach_cli_domain_check() { cnt=$((cnt+1)); if [ -f "$W/second" ]; then printf ok; else : > "$W/second"; printf pending; fi; }
rm -f "$W/second"; _ask_fritz_domain 2>/dev/null
eq A_fdom_retry "neu.$A_ZONE" "${DOMAIN:-}"
newrun; REACH_MODE=fritzbox; q input falsch; q choose anyway
reach_cli_domain_check() { printf wrong; }
_ask_fritz_domain 2>/dev/null
eq A_fdom_anyway "falsch.$A_ZONE" "${DOMAIN:-}"
newrun; REACH_MODE=fritzbox; A_ZONE=''; q input 'https://meinproxy.deine-domain.myfritz.net/'
reach_cli_domain_check() { printf ok; }
_ask_fritz_domain 2>/dev/null
eq A_fdom_full "meinproxy.deine-domain.myfritz.net" "${DOMAIN:-}"
A_ZONE=deine-domain.myfritz.net

# Ganze Fragen-Reihe: Tunnel fragt weder Adresse noch Proxy-Ort.
newrun; q choose tunnel
_ask_reach_mode 2>/dev/null; _reach_ask_domain 2>/dev/null; _ask_trusted_proxies 2>/dev/null
eq A_tunnel_flow_inputs '' "$(cat "$W/input.log" 2>/dev/null | grep -v '^$' | grep -c . | sed 's/^0$//')"

# Uebersicht/reconfigure: Wechsel auf Tunnel leert die alte Adresse; Wechsel auf eigenen Proxy fragt Adresse + Proxy-Ort.
newrun; REACH_MODE=proxy; DOMAIN=bot.example.org; TRUSTED_PROXIES=127.0.0.1; q choose tunnel
_host_key_reask REACH_MODE 2>/dev/null
eq A_reask_to_tunnel "tunnel||127.0.0.1" "${REACH_MODE:-}|${DOMAIN:-}|${TRUSTED_PROXIES:-}"
eq A_reask_no_store '' "$(read_env_value "$INSTALL_ENV_FILE" REACH_MODE 2>/dev/null)"
newrun; REACH_MODE=tunnel; q choose proxy local; q input bot.example.org
_host_key_reask REACH_MODE 2>/dev/null
eq A_reask_to_proxy "proxy|bot.example.org|127.0.0.1" "${REACH_MODE:-}|${DOMAIN:-}|${TRUSTED_PROXIES:-}"
newrun; cfg REACH_MODE=tunnel; REACH_MODE=tunnel
eq A_review_status "$(reach_cli_mode_label tunnel)" "$(_review_status host - REACH_MODE)"
has A_editable_mode REACH_MODE "$(_host_editable_keys)"
hasnt A_editable_no_domain_tunnel DOMAIN "$(_host_editable_keys)"

# Tunnel-Anmeldung vor dem langen Teil.
reach_cli_ts_install() { return 0; }
reach_cli_ts_wait_url() { reach_ts_eval "$(cat "$TS_MOCK_DIR/status.json")"; }
reach_cli_qr() { printf '[QR %s]\n' "$1"; }
newrun; REACH_MODE=tunnel; ts_reset; ts_state NeedsLogin 'https://login.tailscale.com/a/fantasy1' '[]'; q choose later
reach_tunnel_connect 2>/dev/null
has A_conn_link 'https://login.tailscale.com/a/fantasy1' "$(cat "$W/box.log")"
has A_conn_qr '[QR https://login.tailscale.com/a/fantasy1]' "$(cat "$W/box.log")"
has A_conn_title "$(pkg_text core wizard.reach.needs_login_title)" "$(cat "$W/box.log")"
eq A_conn_later '' "${DOMAIN:-}"
newrun; REACH_MODE=tunnel; ts_reset; ts_state NeedsLogin 'https://login.tailscale.com/a/fantasy1' '[]'; q choose retry
ui_choose() { local v; v="$(pop choose)"; [ "$v" = retry ] && { ts_state Running "" "[\"https\",\"funnel\"]"; echo 1 > "$TS_MOCK_DIR/allowed"; }; cat >> "$W/choose.log"; printf "%s" "$v"; }
reach_tunnel_connect 2>/dev/null
eq A_conn_ready "$DNS|$DNS|127.0.0.1" "${DOMAIN:-}|$(read_env_value "$INSTALL_ENV_FILE" DOMAIN)|$(read_env_value "$INSTALL_ENV_FILE" TRUSTED_PROXIES)"
hasnt A_conn_bot_no_warn 'öffentlich sichtbar' "$(reach_tunnel_connect 2>&1)"
newrun; REACH_MODE=tunnel; ts_reset; printf meinnas.tail-fantasy.ts.net > "$TS_MOCK_DIR/dns"; echo 1 > "$TS_MOCK_DIR/allowed"
jq -nc '{BackendState:"Running", Self:{DNSName:"meinnas.tail-fantasy.ts.net.", CapMap:{https:null, funnel:null}}}' > "$TS_MOCK_DIR/status.json"
has A_conn_own_node_warn 'meinnas' "$(reach_tunnel_connect 2>&1 | grep 'öffentlich sichtbar')"
eq A_conn_own_node_stored meinnas "$(read_env_value "$INSTALL_ENV_FILE" TS_HOSTNAME)"
hasnt A_conn_own_node_once 'öffentlich sichtbar' "$(reach_tunnel_connect 2>&1)"
printf '%s' "$DNS" > "$TS_MOCK_DIR/dns"
newrun; REACH_MODE=tunnel; UNATTENDED=1; ts_reset; ts_state Running '' '["https","funnel"]'; echo 1 > "$TS_MOCK_DIR/allowed"
ui_interactive() { [ "${UNATTENDED:-0}" -ne 1 ]; }
reach_tunnel_connect 2>/dev/null
eq A_conn_unattended "$DNS" "${DOMAIN:-}"
UNATTENDED=0; ui_interactive() { return 0; }
newrun; REACH_MODE=proxy; ts_reset; reach_tunnel_connect 2>/dev/null
eq A_conn_other_mode '' "$(cat "$TS_MOCK_DIR/calls.log" 2>/dev/null)"

# Review-Funde: Verbund bietet den Weg nicht zum Aendern an; Bestand wird schon beim Laden eigener Proxy; Funnel ohne
# Freigabe wartet nur einmal; FritzBox-Beschriftung im Verbund ohne „eigener Reverse Proxy".
newrun; LIFEAGENTS_RUNTIME=compose; REACH_MODE=tunnel
hasnt R_compose_no_mode REACH_MODE "$(_host_editable_keys)"
eq R_compose_label FritzBox "$(reach_cli_mode_label fritzbox)"
LIFEAGENTS_RUNTIME=systemd
newrun; cfg DOMAIN=bot.example.org; load_install_env
eq R_legacy_load proxy "${REACH_MODE:-}"
ts_reset; rc=0; reach_cli_funnel_ensure "$DNS" 5678 || rc=$?
eq R_funnel_once "1|1" "$rc|$(grep -c 'funnel --bg' "$TS_MOCK_DIR/calls.log")"

# Wechsel weg vom Tunnel: nur unsere Eintraege gehen, ein fremder bleibt.
newrun; REACH_MODE=proxy; DOMAIN=bot.example.org; ts_reset; ts_state Running '' '["https","funnel"]'
ours_json '.Web[].Handlers["/ha"]={Proxy:"http://127.0.0.1:8123"}' > "$TS_MOCK_DIR/funnel.json"
reach_cli_leave_tunnel
eq L_leave_keeps_foreign '["/ha"]' "$(jq -c --arg k "$DNS:443" '.Web[$k].Handlers | keys' "$TS_MOCK_DIR/funnel.json")"
newrun; REACH_MODE=tunnel; ts_reset; ts_state Running '' '["https","funnel"]'; ours_json > "$TS_MOCK_DIR/funnel.json"
reach_cli_leave_tunnel
eq L_tunnel_stays ours "$(reach_cli_funnel_eval "$DNS" "$(cat "$TS_MOCK_DIR/funnel.json")" 5678)"

# doctor: liest nur, meldet je Zustand eine Zeile; Ablauf der Anmeldung in <= 14 Tagen als Hinweis.
ts_reset; ts_state Running '' '["https","funnel"]'; ours_json > "$TS_MOCK_DIR/funnel.json"
out="$(reach_cli_doctor 5678)"
has D_ready "$(printf 'pass\tTunnel steht')" "$out"
hasnt D_no_write 'funnel --bg' "$(cat "$TS_MOCK_DIR/calls.log" 2>/dev/null)"
jq -c --arg ke "$(date -u -d '+5 days' +%Y-%m-%dT%H:%M:%SZ)" '.Self.KeyExpiry=$ke' "$TS_MOCK_DIR/status.json" > "$W/s.json" && mv "$W/s.json" "$TS_MOCK_DIR/status.json"
has D_key_soon "$(printf 'warn\tTailscale-Anmeldung läuft in')" "$(reach_cli_doctor 5678)"
ts_reset; ts_state Running '' '["https","funnel"]'
has D_entries_missing "$(printf 'red\tTunnel: Funnel-Einträge')" "$(reach_cli_doctor 5678)"
ts_state NeedsLogin 'https://login.tailscale.com/a/fantasy1' '[]'
has D_login "$(printf 'red\tTunnel: bei Tailscale anmelden')" "$(reach_cli_doctor 5678)"

# Gefuehrtes Ende: Tunnel bekommt die Tunnel-Hilfe statt eines Caddyfiles.
newrun; REACH_MODE=tunnel; DOMAIN="$DNS"; _INGRESS_HELP_SHOWN=0
emit_ingress_help "$ROOT/provisioning/templates" "$DNS" 5678 "https://$DNS/" 2>/dev/null
has H_tunnel_box 'Tunnel (Tailscale Funnel)' "$(cat "$W/box.log")"
[ -e "$LIFEAGENTS_DIR/reverse-proxy.caddyfile" ] && fail H_no_caddyfile "Caddyfile geschrieben" || pass H_no_caddyfile

printf 'cli_cases: %s Fehler\n' "$fails" >&2
exit "$fails"
