#!/usr/bin/env bash
# secret_argv_cases.sh — kein Geheimnis im argv beim Bau der n8n-Credentials (provisioning/lib/inject_credentials.sh).
#   /proc/<pid>/cmdline ist fuer jeden Nutzer lesbar (provisioning/CLAUDE.md *Secrets nie im argv*). Ein jq-Shim vorn im PATH
#   schreibt jede Kommandozeile mit, die der Credential-Bau startet; kein Markerwert darf darin stehen.
#   Gerufen aus tests/backup/cases.sh (S.secret-argv); laeuft auch allein in jedem Container mit bash + jq.
# real-path-test: tests/backup/cases.sh (Restore mit Zugang -> echter Upsert gegen n8n)
#
# Usage: bash secret_argv_cases.sh <root>      Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2034,SC2329  # Stubs gelten fuer die gesourcten Funktionen, die sie rufen
set -uo pipefail
ROOT="$1"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

REAL_JQ="$(command -v jq)"
mkdir -p "$W/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/argv.log"\nexec "%s" "$@"\n' "$W" "$REAL_JQ" > "$W/bin/jq"
chmod +x "$W/bin/jq"
export PATH="$W/bin:$PATH"
: > "$W/argv.log"

export LIFEAGENTS_LIB="$ROOT" LIFEAGENTS_DIR="$W/etc" LANG=C.UTF-8 LC_ALL=C.UTF-8
mkdir -p "$LIFEAGENTS_DIR"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/inject_credentials.sh"

M_DB='MARKERdbPW71'; M_TG='MARKERtg72'; M_GO='MARKERgo73'; M_AN='MARKERan74'; M_PKG='MARKERpkg75'
N8N_DB_NAME=testdb
_EXISTING_CREDS_JSON='[]'; _CRED_ITEMS='[]'; _CRED_TEST_IDS=''

# Bausteine, die Geheimnisse anfassen: Postgres-Daten, Sammel-Array, Manifest-Zugang (Paket mit Token-Prefix).
_cred_stage 'Postgres account' 'postgres' "$(_pg_cred_data n8n "$M_DB")"
mkdir -p "$W/pkg/packages/zzprobe"
cat > "$W/pkg/packages/zzprobe/manifest.json" <<'JSON'
{ "name": "zzprobe", "credentials": { "probe": { "name": "ZZ Probe API", "type": "httpHeaderAuth", "required": false,
  "placeholder": "__CRED_ZZPROBE__", "env": { "ZZPROBE_API_TOKEN": { "field": "Authorization", "value_prefix": "Token " } } } } }
JSON
printf 'ZZPROBE_API_TOKEN=%s\n' "$M_PKG" > "$LIFEAGENTS_DIR/zzprobe.env"
REPO_ROOT="$W/pkg" _inject_manifest_credentials zzprobe

items="$("$REAL_JQ" -c '.' <<<"$_CRED_ITEMS")"
case "$items" in *"$M_DB"*) pass 'Sammel-Array traegt das DB-Passwort' ;; *) fail 'Sammel-Array' 'DB-Passwort fehlt (Test baut nichts)' ;; esac
case "$items" in *"Token $M_PKG"*) pass 'Sammel-Array traegt den Paket-Zugang mit Prefix' ;; *) fail 'Sammel-Array' 'Paket-Zugang fehlt' ;; esac
if [ -s "$W/argv.log" ]; then pass 'jq-Shim hat mitgeschrieben'; else fail 'jq-Shim' 'leer (Test prueft nichts)'; fi
for m in "$M_DB" "$M_PKG"; do
  if grep -qF "$m" "$W/argv.log"; then fail "kein Geheimnis im argv ($m)" 'Wert steht in einer jq-Kommandozeile'; else pass "kein Geheimnis im argv ($m)"; fi
done

# Host-Zugaenge: ihre Zeilen in inject_credentials() bauen das JSON nur ueber _cred_json (env), nie ueber --arg/--argjson.
for v in TELEGRAM_BOT_TOKEN GOOGLE_API_KEY ANTHROPIC_API_KEY TEST_HARNESS_SECRET; do
  if grep -nE -- "--arg(json)? [a-z]+ \"\\\$\\{?${v}" "$ROOT/provisioning/lib/inject_credentials.sh" >/dev/null; then
    fail "Host-Zugang $v nicht per --arg" 'Zeile mit --arg gefunden'
  else pass "Host-Zugang $v nicht per --arg"; fi
done
: > "$W/argv.log"
out="$(_cred_json '{a:env.LA_C_T, b:env.LA_C_K}' "LA_C_T=$M_TG" "LA_C_K=$M_GO$M_AN")"
case "$out" in *"$M_TG"*"$M_GO$M_AN"*) pass '_cred_json setzt die Werte' ;; *) fail '_cred_json' "Ausgabe ohne Werte: $out" ;; esac
if grep -qE "$M_TG|$M_GO|$M_AN" "$W/argv.log"; then fail '_cred_json ohne argv' 'Wert in der jq-Kommandozeile'; else pass '_cred_json ohne argv'; fi

exit "$fails"
