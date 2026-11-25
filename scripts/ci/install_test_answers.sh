#!/usr/bin/env bash
# install_test_answers.sh — Antwort-Datei fuer die Install-Tests in CI aus den Test-Zugaengen des GitHub-Environments
# install-test. Erzeugt je Lauf ueber den OAuth-Client des Test-Tailnets einen frischen Tailscale-Anmeldeschluessel
# (einmalig, fluechtig, vorab freigegeben, Tag tag:install-test, 1 h gueltig; tailscale.com/kb/1215) und gibt ihn dem
# Installer als TS_AUTHKEY (lib/reach.sh _reach_key_login). Ein gewoehnlicher tskey-auth statt des OAuth-Geheimnisses:
# so braucht der Installer kein --advertise-tags, Nutzer und Test gehen denselben Weg.
#
# Aufruf (direkt vor setup.sh --answers / provision.sh --unattended; der Schluessel gilt 1 h und nur einmal):
#   bash scripts/ci/install_test_answers.sh "$RUNNER_TEMP/answers.env"
# Umgebung (nur im env: des aufrufenden Schritts): TEST_TELEGRAM_BOT_TOKEN, TEST_ANTHROPIC_API_KEY (Pflicht);
#   TEST_TS_OAUTH_CLIENT_ID + TEST_TS_OAUTH_CLIENT_SECRET (fehlt einer: Tunnel-Teil uebersprungen, kein REACH_MODE;
#   sind sie gesetzt, braucht der Lauf curl + jq).
#   GITHUB_ACTIONS=true -> abgeleitete Geheimnisse (Zugangs-Token, Schluessel) per ::add-mask:: melden; GitHub schwaerzt
#   nur die Secrets selbst. Lokal keine Maske (die Zeile zeigte den Wert im Terminal).
# Geheimnisse nur ueber curl -K - (stdin), nie argv; Fehlermeldungen nennen nie einen Wert. Einrichtung und Aufruf-Stelle:
#   docs/reference/tests.md *Test-Zugänge*. Test: tests/mock_reach/answers_cases.sh.
# Exit: 0 = Datei geschrieben (0600); 1 = Argument/Pflichtwert fehlt, Wert unzulaessig oder curl/jq fehlen;
#   2 = Tailscale lehnt ab, erzeugt keinen Schluessel oder ist nicht erreichbar.
set -euo pipefail

TS_API='https://api.tailscale.com/api/v2'
TS_TAG='tag:install-test'
out="${1:?Aufruf: install_test_answers.sh <ziel-datei>}"

err() { printf 'install_test_answers: %s\n' "$*" >&2; }
mask() { [ "${GITHUB_ACTIONS:-}" = true ] && printf '::add-mask::%s\n' "$1"; return 0; }
# curl-Konfigurationszeile; \ und " maskiert (curl-Syntax), der Wert bleibt so aus dem argv.
cfg() { local v="$2"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s = "%s"\n' "$1" "$v"; }

for k in TEST_TELEGRAM_BOT_TOKEN TEST_ANTHROPIC_API_KEY; do
  [ -n "${!k:-}" ] || { err "$k fehlt (Secret im Environment install-test, nur im env: dieses Schritts)."; exit 1; }
done
# Die Datei hat die .env-Form KEY='wert' (install_answers_load): ' oder ein Zeilenumbruch im Wert braeche sie.
for k in TEST_TELEGRAM_BOT_TOKEN TEST_ANTHROPIC_API_KEY TEST_TS_OAUTH_CLIENT_ID TEST_TS_OAUTH_CLIENT_SECRET; do
  case "${!k:-}" in *"'"*|*$'\n'*|*$'\r'*) err "$k enthält ein unzulässiges Zeichen."; exit 1 ;; esac
done

# api — curl mit der Konfiguration von stdin; Ausgabe: Antwort-Text, letzte Zeile HTTP-Status. rc 3 = nicht erreichbar
#   (Netz, DNS, Zeit) — getrennt von einer Ablehnung, sonst riete die Meldung zum Erneuern gueltiger Secrets.
api() { curl -K - -sS --max-time 20 -w '\n%{http_code}' 2>/dev/null || return 3; }
# api_fail <rc> <status> <was> — Meldung je Fehlerart, Exit 2.
api_fail() {
  case "$1:$2" in
    3:*) err "Tailscale-API nicht erreichbar ($3) — Netz/DNS des Runners prüfen, die Secrets sind nicht schuld." ;;
    *:401|*:403) err "Tailscale lehnt den OAuth-Zugang ab ($3; TEST_TS_OAUTH_CLIENT_ID/SECRET widerrufen oder falsch?) — Einrichtung: docs/reference/tests.md *Test-Zugänge*." ;;
    *) err "Tailscale antwortet mit HTTP $2 ($3) — darf der OAuth-Client Auth Keys mit ${TS_TAG} schreiben? tagOwners in der Richtlinie? (docs/reference/tests.md *Test-Zugänge*)" ;;
  esac
  exit 2
}

key=''
if [ -n "${TEST_TS_OAUTH_CLIENT_ID:-}" ] && [ -n "${TEST_TS_OAUTH_CLIENT_SECRET:-}" ]; then
  for c in curl jq; do command -v "$c" >/dev/null || { err "$c fehlt auf dem Runner."; exit 1; }; done
  rc=0; res="$({ cfg url "$TS_API/oauth/token"
                 cfg data "client_id=${TEST_TS_OAUTH_CLIENT_ID}"
                 cfg data "client_secret=${TEST_TS_OAUTH_CLIENT_SECRET}"; } | api)" || rc=$?
  code="${res##*$'\n'}"; tok="$(printf '%s' "${res%$'\n'*}" | jq -r '.access_token // empty' 2>/dev/null || true)"
  { [ "$rc" -eq 0 ] && [ "$code" = 200 ] && [ -n "$tok" ]; } || api_fail "$rc" "$code" 'Zugangs-Token'
  mask "$tok"
  body="$(jq -nc --arg tag "$TS_TAG" '{capabilities:{devices:{create:{reusable:false, ephemeral:true, preauthorized:true,
            tags:[$tag]}}}, expirySeconds:3600, description:"install-test"}')"
  rc=0; res="$({ cfg url "$TS_API/tailnet/-/keys"
                 cfg header "Authorization: Bearer ${tok}"
                 cfg header 'Content-Type: application/json'
                 cfg data "$body"; } | api)" || rc=$?
  unset tok
  code="${res##*$'\n'}"; key="$(printf '%s' "${res%$'\n'*}" | jq -r '.key // empty' 2>/dev/null || true)"
  # Dieselbe Praefix-Pruefung wie der Installer (_answers_ts_authkey_guard); tskey-auth- verlangte im Test einen Wert
  # in echter Anbieter-Form (standin_lint Teil E).
  case "$rc:$code:$key" in
    0:200:tskey-?*) mask "$key" ;;
    *) api_fail "$rc" "$code" 'Anmeldeschlüssel' ;;
  esac
else
  err "Tunnel-Teil übersprungen: kein Tailscale-Zugang (TEST_TS_OAUTH_CLIENT_ID/SECRET) in diesem Lauf."
fi

# Owner-Passwort je Lauf (Policy: 8–64, Ziffer, Grossbuchstabe); erfundene Owner-Daten.
pw="La1$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 16 || true)"
mask "$pw"
umask 077
tmp="$(mktemp "${out}.XXXXXX")"
{
  printf "N8N_OWNER_EMAIL='install-test@example.com'\n"
  printf "N8N_OWNER_PASSWORD='%s'\n" "$pw"
  printf "OWNER_FIRST_NAME='CI'\nOWNER_LAST_NAME='Runner'\nOWNER_BIRTH_DATE='1990-01-01'\nOWNER_LANGUAGE='de'\n"
  printf "TELEGRAM_BOT_TOKEN='%s'\n" "$TEST_TELEGRAM_BOT_TOKEN"
  printf "ANTHROPIC_API_KEY='%s'\n" "$TEST_ANTHROPIC_API_KEY"
  # Der Test-Bot zeigte nach dem letzten Lauf evtl. noch auf dessen (verschwundenen) Rechner.
  printf "TELEGRAM_WEBHOOK_TAKEOVER='1'\n"
  printf "LLM_GATEWAY_KEEPALIVE_HOURS='0'\n"
  [ -z "$key" ] || printf "REACH_MODE='tunnel'\nTS_AUTHKEY='%s'\n" "$key"
} > "$tmp"
mv -f "$tmp" "$out"
