#!/usr/bin/env bash
# answers_cases.sh — Fall-Runner von scripts/dev/reachability_test.ps1 (vierter Teil): Antwort-Datei der Install-Tests
# (scripts/ci/install_test_answers.sh) gegen eine Attrappe `curl` (Tailscale-API), ohne Netz, ohne Konto:
#   A  Datei 0600 mit den Antwort-Schluesseln; Schluessel je Lauf aus dem OAuth-Client (einmalig, fluechtig, vorab frei,
#      Tag tag:install-test, 1 h); Geheimnisse nie im argv, nie in der Ausgabe ausser in ::add-mask:: (nur in CI).
#   S  ohne Tailscale-Zugang: Tunnel-Teil uebersprungen (Exit 0, kein REACH_MODE/TS_AUTHKEY).
#   E  Pflichtwert fehlt oder ' im Wert -> Exit 1; OAuth abgelehnt / kein Schluessel / API nicht erreichbar -> Exit 2,
#      je eigene Meldung ohne Wert (Netz weg raet nicht zum Erneuern der Secrets).
# real-path-test: scripts/dev/tailscale_authkey_test.ps1 (dieselben Aufrufe gegen die echte Tailscale-API)
#
# Usage: bash answers_cases.sh <root>     Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2015  # "a && pass || fail" gewollt (pass = rc 0)
set -uo pipefail
ROOT="$1"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then pass "$1"; else fail "$1" "'$2' fehlt"; fi; }
hasnt() { if printf '%s' "$3" | grep -qF -- "$2"; then fail "$1" "'$2' steht drin"; else pass "$1"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/m"
# Attrappe: argv nach calls.log, die Konfiguration von stdin (-K -) nach cfg.log; Antwort je URL und Modus, letzte Zeile
# der HTTP-Status (wie -w '\n%{http_code}'); Modus down = curl erreicht nichts (Exit 6).
cat > "$W/bin/curl" <<'C'
#!/usr/bin/env bash
M="$CURL_MOCK_DIR"
printf '%s\n' "$*" >> "$M/calls.log"
cfg="$(cat)"; printf '%s\n--\n' "$cfg" >> "$M/cfg.log"
mode="$(cat "$M/mode" 2>/dev/null)"
reply() { printf '%s\n%s' "$1" "$2"; exit 0; }
[ "$mode" = down ] && exit 6
case "$cfg" in
  *'url = "https://api.tailscale.com/api/v2/oauth/token"'*)
    [ "$mode" = oauth_denied ] && reply '{"message":"invalid client"}' 401
    reply '{"access_token":"test-fake-FAKEaccess","token_type":"Bearer","expires_in":3600}' 200 ;;
  *'url = "https://api.tailscale.com/api/v2/tailnet/-/keys"'*)
    [ "$mode" = no_key ] && reply '{"message":"requested tags are invalid or not permitted"}' 400
    printf '%s' "$cfg" | grep -q 'Authorization: Bearer test-fake-FAKEaccess' || reply '{}' 401
    reply '{"id":"kFake1","key":"tskey-FAKEminted"}' 200 ;;
  *) exit 6 ;;
esac
C
chmod +x "$W/bin/curl"
export CURL_MOCK_DIR="$W/m" PATH="$W/bin:$PATH"
H="$ROOT/ci/install_test_answers.sh"
run() {   # run <ziel> — Helfer mit den Test-Zugaengen aus der Umgebung; Ausgabe (stdout+stderr) nach $W/out, rc nach RC
  rm -f "$W/m/calls.log" "$W/m/cfg.log"; RC=0
  bash "$H" "$1" >"$W/out" 2>&1 || RC=$?
}
creds() {
  export TEST_TELEGRAM_BOT_TOKEN='123456:FAKEbot' TEST_ANTHROPIC_API_KEY='test-fake-FAKEanthropic'  # hand-injected: erfundene Werte, die curl-Attrappe kennt nur FAKE-Muster
  export TEST_TS_OAUTH_CLIENT_ID='kFAKEclient' TEST_TS_OAUTH_CLIENT_SECRET='test-fake-client-FAKEsecret'  # hand-injected: erfundene Werte, die curl-Attrappe kennt nur FAKE-Muster
}

# --- A: voller Lauf in CI ---------------------------------------------------------------------------------------------
creds; export GITHUB_ACTIONS=true; : > "$W/m/mode"
run "$W/a.env"
eq A_rc 0 "$RC"
eq A_mode 600 "$(stat -c %a "$W/a.env" 2>/dev/null)"
A="$(cat "$W/a.env" 2>/dev/null)"
has A_tunnel "REACH_MODE='tunnel'" "$A"
has A_key "TS_AUTHKEY='tskey-FAKEminted'" "$A"
has A_bot "TELEGRAM_BOT_TOKEN='123456:FAKEbot'" "$A"
has A_llm "ANTHROPIC_API_KEY='test-fake-FAKEanthropic'" "$A"
has A_takeover "TELEGRAM_WEBHOOK_TAKEOVER='1'" "$A"
has A_no_keepalive "LLM_GATEWAY_KEEPALIVE_HOURS='0'" "$A"
has A_owner "OWNER_BIRTH_DATE='1990-01-01'" "$A"
grep -qE "^N8N_OWNER_PASSWORD='[A-Za-z0-9]{12,}'$" "$W/a.env" && pass A_owner_pw || fail A_owner_pw "Passwort fehlt/Form"
C="$(tr -d "\\\\" < "$W/m/cfg.log")"   # curl-Konfiguration maskiert " als \"
has A_oauth_id 'client_id=kFAKEclient' "$C"
has A_key_tag '"tags":["tag:install-test"]' "$C"
has A_key_once '"reusable":false' "$C"
has A_key_ephemeral '"ephemeral":true' "$C"
has A_key_preauth '"preauthorized":true' "$C"
has A_key_1h '"expirySeconds":3600' "$C"
L="$(cat "$W/m/calls.log")"
for v in FAKEsecret FAKEaccess FAKEminted FAKEbot FAKEanthropic; do hasnt "A_argv_no_$v" "$v" "$L"; done
grep -c -- '-K -' "$W/m/calls.log" | grep -qx 2 && pass A_curl_config_stdin || fail A_curl_config_stdin "$L"
O="$(cat "$W/out")"
has A_mask_key '::add-mask::tskey-FAKEminted' "$O"
has A_mask_access '::add-mask::test-fake-FAKEaccess' "$O"
for v in FAKEsecret FAKEbot FAKEanthropic; do hasnt "A_out_no_$v" "$v" "$O"; done
# Ausserhalb von CI: keine ::add-mask::-Zeile (sie zeigte den Wert im Terminal).
unset GITHUB_ACTIONS; run "$W/a2.env"
hasnt A_local_no_mask 'FAKEminted' "$(cat "$W/out")"

# --- S: ohne Tailscale-Zugang (Fork, lokaler Lauf) --------------------------------------------------------------------
creds; unset TEST_TS_OAUTH_CLIENT_ID TEST_TS_OAUTH_CLIENT_SECRET
run "$W/s.env"
eq S_rc 0 "$RC"
hasnt S_no_mode 'REACH_MODE' "$(cat "$W/s.env" 2>/dev/null)"
hasnt S_no_key 'TS_AUTHKEY' "$(cat "$W/s.env" 2>/dev/null)"
has S_note 'Tunnel-Teil übersprungen' "$(cat "$W/out")"
eq S_no_api '' "$(cat "$W/m/calls.log" 2>/dev/null)"

# --- E: Fehler -------------------------------------------------------------------------------------------------------
creds; unset TEST_TELEGRAM_BOT_TOKEN; run "$W/e1.env"
eq E_missing_bot_rc 1 "$RC"
has E_missing_bot_name TEST_TELEGRAM_BOT_TOKEN "$(cat "$W/out")"
[ -e "$W/e1.env" ] && fail E_missing_no_file "Datei trotz Fehler geschrieben" || pass E_missing_no_file
creds; echo oauth_denied > "$W/m/mode"; run "$W/e2.env"
eq E_oauth_rc 2 "$RC"
has E_oauth_msg 'OAuth' "$(cat "$W/out")"
hasnt E_oauth_no_secret FAKEsecret "$(cat "$W/out")"
[ -e "$W/e2.env" ] && fail E_oauth_no_file "Datei trotz Fehler geschrieben" || pass E_oauth_no_file
echo no_key > "$W/m/mode"; run "$W/e3.env"
eq E_key_rc 2 "$RC"
has E_key_hint 'tag:install-test' "$(cat "$W/out")"
# Netz weg: eigene Meldung, kein Rat zum Erneuern der Secrets.
echo down > "$W/m/mode"; run "$W/e5.env"
eq E_down_rc 2 "$RC"
has E_down_msg 'nicht erreichbar' "$(cat "$W/out")"
hasnt E_down_no_rotate 'widerrufen' "$(cat "$W/out")"
creds; : > "$W/m/mode"; TEST_TELEGRAM_BOT_TOKEN="12:ab'c"; run "$W/e4.env"
eq E_quote_rc 1 "$RC"
hasnt E_quote_no_value "ab'c" "$(cat "$W/out")"

printf 'answers_cases: %s Fehler\n' "$fails" >&2
exit "$fails"
