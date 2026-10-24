#!/usr/bin/env bash
# update_cases.sh — Fall-Runner von scripts/dev/update_chat_test.ps1 (Update im Chat), laeuft IM Substrat-Container (root).
#
# Faehrt den INSTALLIERTEN Runtime-Stand (/usr/local/lib/lifeagents + /usr/local/bin/lifeagents; der Treiber bringt ihn
# vorher auf den Stand des Worktrees) gegen den GitHub-Mock (tests/mock_github/server.js) und den Telegram-Mock
# (n8ntest-mock-telegram, enable_mock_telegram.ps1). Die Fake-Releases tragen einen Stub-provision.sh, der je Szenario
# (/tmp/upd_test/scenario) genau das in die Ergebnis-Datei schreibt, was provision.sh schreiben wuerde — so laesst sich
# jede Fehlerklasse der Fehler-Hilfe gezielt ausloesen, ohne echtes Update.
#   Karte: faellig/einmal/erst nach erfolgreichem Senden gemerkt, Prerelease ausgefiltert, Signatur-Pflicht.
#   Runner: succeeded, already_current, superseded, partial, held, failed (mittendrin), Sperre belegt, interrupted.
#   Signatur (Phase 2): gueltig / fremder Schluessel / fehlend — lifeagents update UND install.sh; Downgrade-Sperre.
#
# Usage: bash update_cases.sh <root> <gh-port> <tg-port>    Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>".
set -uo pipefail
ROOT="$1"; PORT="$2"; TGPORT="$3"
LIB=/usr/local/lib/lifeagents; VER="$LIB/VERSION"
API="http://127.0.0.1:${PORT}"; SLUG="owner/repo"
W=/tmp/upd_test; REL="$W/releases"; BODIES="$W/bodies"; TGLOG=/tmp/mock_telegram.jsonl; GNUPGHOME="$W/gnupg"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1 GNUPGHOME
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

DB="$(grep -E '^DB_POSTGRESDB_DATABASE=' /etc/n8n/n8n.env | tail -n1 | cut -d= -f2)"; DB="${DB:-n8n}"
sql() { runuser -u postgres -- psql -X -tA -q -v ON_ERROR_STOP=1 -d "$DB" -c "$1"; }

ORIG_VER="$(cat "$VER" 2>/dev/null || printf dev)"
MOCK_PID=''
# shellcheck disable=SC2329  # aufgerufen ueber trap EXIT
cleanup() {
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  printf '%s\n' "$ORIG_VER" > "$VER"
  sql "DELETE FROM core.update_requests; DELETE FROM core.notification_state WHERE source = 'release_update';" >/dev/null 2>&1
}
trap cleanup EXIT

# --- Fake-Releases ---------------------------------------------------------------------------------------------
rm -rf "$W"; mkdir -p "$REL" "$BODIES" "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
mk_release() {   # mk_release <tag> <body> [flags]
  local tag="$1" src="$W/src/$1/n8n-life-agents-$1/provisioning"
  mkdir -p "$src" "$REL/$tag"
  cat > "$src/provision.sh" <<'STUB'
# Stub-Applier (update_cases.sh): Ergebnis je Szenario, genau wie provision.sh es in die Ergebnis-Datei schreibt.
. /usr/local/lib/lifeagents/provisioning/lib/common.sh
sc="$(cat /tmp/upd_test/scenario 2>/dev/null || printf ok)"
result_set status running; result_set stage preflight
case "$sc" in
  ok)      printf '%s\n' "$RELEASE_TAG" > /usr/local/lib/lifeagents/VERSION; result_set stage final; result_set status ok ;;
  partial) printf '%s\n' "$RELEASE_TAG" > /usr/local/lib/lifeagents/VERSION; result_set changed true
           result_set failed_packages Finanzen; result_set reason_code package; result_set status partial ;;
  held)    result_set missing_keys 'Anthropic (ANTHROPIC_API_KEY)'; result_set changed false; result_set status held ;;
  fail)    result_set changed true; result_set stage workflows; die "Workflow-Import fehlgeschlagen (Test)" ;;
esac
STUB
  tar -czf "$REL/$tag/n8n-life-agents-$tag.tar.gz" -C "$W/src/$tag" "n8n-life-agents-$tag"
  ( cd "$REL/$tag" && sha256sum "n8n-life-agents-$tag.tar.gz" > "n8n-life-agents-$tag.tar.gz.sha256" )
  printf 'echo fake-install\n' > "$REL/$tag/install.sh"
  printf '%s\n' "$2" > "$BODIES/$tag.md"
  [ -z "${3:-}" ] || printf '%s' "$3" > "$BODIES/$tag.flags"
}
mk_release v9.9.8 'Alt acht.'
mk_release v9.9.9 $'Kurz neun.\n\n## Details\n- x'
mk_release v9.9.10 $'Kurz **zehn**.\n\n---\nInstall'
mk_release v9.9.11-rc1 'RC-Text.' prerelease

# Signatur: Projekt-Schluessel (Bund = $W/kr.gpg) + fremder Schluessel; sign <tag> <uid> schreibt SHA256SUMS(.sig).
gpg --batch --passphrase '' --quick-generate-key 'update-test project' ed25519 sign never >/dev/null 2>&1
gpg --batch --passphrase '' --quick-generate-key 'update-test evil' ed25519 sign never >/dev/null 2>&1
gpg --batch --export 'update-test project' > "$W/kr.gpg"
sign() {
  ( cd "$REL/$1" && sha256sum "n8n-life-agents-$1.tar.gz" install.sh > SHA256SUMS )
  gpg --batch --yes --pinentry-mode loopback --passphrase '' --local-user "$2" --detach-sign -o "$REL/$1/SHA256SUMS.sig" "$REL/$1/SHA256SUMS"
}

# --- Mock starten -------------------------------------------------------------------------------------------
for d in /proc/[0-9]*; do
  if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q "^node .*mock_github/server\.js"; then kill "${d#/proc/}" 2>/dev/null || true; fi
done
sleep 0.2
MOCK_GH_PORT="$PORT" MOCK_GH_SLUG="$SLUG" MOCK_GH_RELEASE_DIR="$REL" MOCK_GH_BODY_DIR="$BODIES" MOCK_GH_LATEST=v9.9.10 \
  node "$ROOT/mock_github/server.js" > "$W/mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do [ "$(curl -s "$API/__pid" | jq -r '.pid // empty' 2>/dev/null)" = "$MOCK_PID" ] && break; sleep 0.1; done
[ "$(curl -s "$API/__pid" | jq -r '.pid // empty' 2>/dev/null)" = "$MOCK_PID" ] || { echo "FAIL setup: GitHub-Mock nicht bereit $(cat "$W/mock.log")"; exit 1; }
curl -fsS "http://127.0.0.1:${TGPORT}/__health" >/dev/null || { echo "FAIL setup: Telegram-Mock (Port ${TGPORT}) nicht erreichbar — enable_mock_telegram.ps1"; exit 1; }

# --- Helfer -------------------------------------------------------------------------------------------------
# Schluesselbund-Modus immer AUSDRUECKLICH: der Substrat-Baum traegt den echten Projekt-Schluessel (install_release_keyring
# legt ihn nach /etc) — die Faelle 1-12 pruefen den Sidecar-Modus (Bund-Override auf eine fehlende Datei), ab 13 setzt
# EXTRA_ENV das Bund des Test-Schluessels (eine spaetere Zuweisung gewinnt bei env).
RUNENV=(LIFEAGENTS_RELEASE_KEYRING=/nonexistent/release-signing.gpg
        PROVISION_GH_API="$API" PROVISION_REPO_SLUG="$SLUG" LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:${TGPORT}"
        TELEGRAM_BOT_TOKEN=mock-token OWNER_CHAT_ID=4242 N8N_DB_NAME="$DB")
cli() { OUT="$(env "${RUNENV[@]}" ${EXTRA_ENV:+$EXTRA_ENV} lifeagents update "$@" 2>&1 </dev/null)"; RC=$?; }
installed() { printf '%s\n' "$1" > "$VER"; }
scenario() { printf '%s' "$1" > "$W/scenario"; }
reset_db() { sql "DELETE FROM core.update_requests;" >/dev/null; }
latch_clear() { sql "DELETE FROM core.notification_state WHERE source = 'release_update';" >/dev/null; }
request() { sql "INSERT INTO core.update_requests (tag, kind) VALUES ('$1', '${2:-update}') RETURNING id;"; }
outcome() { sql "SELECT outcome || '|' || COALESCE(stage,'') || '|' || COALESCE(reason_code,'') || '|' || COALESCE(changed::text,'') FROM core.update_requests WHERE id = $1;"; }
tg_clear() { : > "$TGLOG"; }
urldec() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
tg_n() { jq -r 'select(.method == "sendMessage") | .method' "$TGLOG" 2>/dev/null | wc -l; }
tg_all() { jq -r 'select(.method == "sendMessage") | .body' "$TGLOG" 2>/dev/null | while IFS= read -r b; do urldec "$b"; printf '\n'; done; }
tg_has() { tg_all | grep -qF -- "$1"; }
show() { printf '%s' "$1" | tr '\r\n' '  ' | cut -c1-300; }

# 0 Knopf-Verdrahtung: der Installer hat 'upd' aus dem Manifest in die Registry geseedet (owner-only), und ein Tap des
#   Owners ueber den echten Dispatcher (wie der Orchestrator ihn ruft) legt genau einen Auftrag an.
reg="$(sql "SELECT handler_fn || '|' || member_permeable FROM core.callback_handlers WHERE prefix = 'upd'")"
owner_tg="$(sql "SELECT pp->>'telegram_user_id' FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons','[]'::jsonb)) pp WHERE c.name='family' AND pp->>'role'='owner' LIMIT 1")"
reset_db; latch_clear; sql "SELECT core.fn_release_card_sent('v9.9.10');" >/dev/null
if [ -n "$owner_tg" ] && [ "$owner_tg" != null ]; then
  tap="$(sql "SELECT core.fn_dispatch_callback(jsonb_build_object('data','upd:now:v9.9.10','chat_id','$owner_tg','chat_type','private'))->>'ok'")"
  n="$(sql "SELECT count(*) FROM core.update_requests WHERE finished_at IS NULL AND tag = 'v9.9.10'")"
else tap=skip; n=1; fi
if [ "$reg" = 'core.fn_handle_update_cb|false' ] && { [ "$tap" = true ] || [ "$tap" = skip ]; } && [ "$n" = 1 ]; then pass callback_wired
else fail callback_wired "registry=[$reg] tap=$tap open=$n owner=$owner_tg"; fi
reset_db; latch_clear

# 1-3 Release-Karte: faellig, genau einmal, erst nach erfolgreichem Senden gemerkt
installed v9.9.8; reset_db; latch_clear; tg_clear; cli --check
if [ "$(tg_n)" = 1 ] && tg_has 'upd:now:v9.9.10' && tg_has 'Kurz zehn.' && tg_has 'Kurz neun.' && ! tg_has 'RC-Text' && ! tg_has 'Alt acht' \
   && [ "$(sql "SELECT state FROM core.notification_state WHERE source='release_update' AND key='v9.9.10'")" = fired ]; then
  pass card_due; else fail card_due "sends=$(tg_n) $(show "$(tg_all)") out=$(show "$OUT")"; fi
tg_clear; cli --check
if [ "$(tg_n)" = 0 ]; then pass card_once; else fail card_once "sends=$(tg_n)"; fi
latch_clear; tg_clear; curl -s "http://127.0.0.1:${TGPORT}/__fail?method=sendMessage" >/dev/null; cli --check
curl -s "http://127.0.0.1:${TGPORT}/__fail?method=sendMessage&off=1" >/dev/null
n1="$(sql "SELECT count(*) FROM core.notification_state WHERE source='release_update' AND state='fired'")"
cli --check
if [ "$n1" = 0 ] && [ "$(sql "SELECT count(*) FROM core.notification_state WHERE source='release_update' AND state='fired'")" = 1 ]; then
  pass card_latch_after_send; else fail card_latch_after_send "nach Fehler gemerkt=$n1 $(show "$OUT")"; fi

# 4 Runner: Erfolg -> Start- + Fertig-Meldung, VERSION neu
installed v9.9.8; reset_db; scenario ok; tg_clear; id="$(request v9.9.10)"; cli --run-requested
o="$(outcome "$id")"
if [ "${o%%|*}" = succeeded ] && [ "$(cat "$VER")" = v9.9.10 ] && [ "$(tg_n)" = 2 ]; then pass run_succeeded
else fail run_succeeded "outcome=$o ver=$(cat "$VER") sends=$(tg_n) $(show "$OUT")"; fi

# 5 schon aktuell (alter Knopf) -> nichts installiert, eine Meldung
installed v9.9.10; reset_db; tg_clear; id="$(request v9.9.10)"; cli --run-requested
o="$(outcome "$id")"
if [ "${o%%|*}" = already_current ] && [ "$(tg_n)" = 1 ]; then pass run_already_current; else fail run_already_current "outcome=$o sends=$(tg_n)"; fi

# 6 ueberholt (Auftrag fuer v9.9.9, latest = v9.9.10) -> superseded, kein Install
installed v9.9.8; reset_db; tg_clear; id="$(request v9.9.9)"; cli --run-requested
o="$(outcome "$id")"
if [ "${o%%|*}" = superseded ] && [ "$(cat "$VER")" = v9.9.8 ]; then pass run_superseded; else fail run_superseded "outcome=$o ver=$(cat "$VER")"; fi

# 7 teilweise -> partial + [Erneut versuchen]
installed v9.9.8; reset_db; scenario partial; tg_clear; id="$(request v9.9.10)"; cli --run-requested
o="$(outcome "$id")"
if [ "${o%%|*}" = partial ] && tg_has 'upd:retry:v9.9.10' && tg_has 'Finanzen'; then pass run_partial
else fail run_partial "outcome=$o $(show "$(tg_all)")"; fi

# 8 wartet auf eine Angabe -> held, genau Start + Halt-Meldung mit der fehlenden Angabe
installed v9.9.8; reset_db; scenario held; tg_clear; id="$(request v9.9.10)"; cli --run-requested
o="$(outcome "$id")"
if [ "${o%%|*}" = held ] && [ "$(tg_n)" = 2 ] && tg_has 'ANTHROPIC_API_KEY' && tg_has 'lifeagents reconfigure'; then pass run_held
else fail run_held "outcome=$o sends=$(tg_n) $(show "$(tg_all)")"; fi

# 9 mittendrin abgebrochen -> failed/workflows/changed + Wiederholen, Rueckweg, Problem melden (ohne Detail im Link)
installed v9.9.8; reset_db; scenario fail; tg_clear; id="$(request v9.9.10)"; cli --run-requested
o="$(outcome "$id")"
if [ "$o" = 'failed|workflows||true' ] || [ "$o" = 'failed|workflows|unknown|true' ]; then
  if tg_has 'upd:retry:v9.9.10' && tg_has 'lifeagents rollback' && tg_has 'issues/new' && tg_has 'Workflow-Import fehlgeschlagen' \
     && ! jq -r 'select(.method=="sendMessage") | .body' "$TGLOG" | grep -o 'reply_markup=[^&]*' | grep -q 'Workflow-Import'; then
    pass run_failed_midway; else fail run_failed_midway "$(show "$(tg_all)")"; fi
else fail run_failed_midway "outcome=$o $(show "$OUT")"; fi
# 9b [Erneut versuchen] -> Auftrag kind=retry, diesmal ok
scenario ok; tg_clear; id2="$(request v9.9.10 retry)"; cli --run-requested
o="$(outcome "$id2")"
if [ "${o%%|*}" = succeeded ] && [ "$(cat "$VER")" = v9.9.10 ]; then pass run_retry_ok; else fail run_retry_ok "outcome=$o"; fi

# 10 Sperre belegt (anderes Update laeuft) -> Auftrag bleibt unangetastet
installed v9.9.8; reset_db; tg_clear; id="$(request v9.9.10)"
# Halter laeuft von selbst ab (kill traefe nur flock, das Kind `sleep` hielte die Sperre weiter).
flock /run/lifeagents-update.lock sleep 6 & LOCKER=$!
for _ in $(seq 1 50); do flock -n /run/lifeagents-update.lock true 2>/dev/null || break; sleep 0.1; done   # erst wenn wirklich gehalten
cli --run-requested
claimed="$(sql "SELECT claimed_at IS NOT NULL FROM core.update_requests WHERE id = $id")"
wait "$LOCKER" 2>/dev/null
if [ "$claimed" = f ] && [ "$(tg_n)" = 0 ]; then pass run_lock_busy; else fail run_lock_busy "claimed=$claimed sends=$(tg_n)"; fi

# 11 Runner starb mittendrin (uebernommen, nie abgeschlossen) -> interrupted + Meldung
reset_db; tg_clear
id="$(sql "INSERT INTO core.update_requests (tag, claimed_at, from_version) VALUES ('v9.9.10', now(), 'v9.9.8') RETURNING id;")"
installed v9.9.8; cli --run-requested
o="$(outcome "$id")"
if [ "${o%%|*}" = interrupted ] && [ "$(tg_n)" = 1 ]; then pass run_interrupted; else fail run_interrupted "outcome=$o sends=$(tg_n) $(show "$OUT")"; fi

# 12 Downgrade-Sperre (Terminal) + bewusster Rueckschritt
installed v9.9.10; scenario ok; cli --version v9.9.9
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'älter als die installierte'; then pass downgrade_refused; else fail downgrade_refused "rc=$RC $(show "$OUT")"; fi
cli --version v9.9.9 --allow-downgrade
if [ "$RC" = 0 ] && [ "$(cat "$VER")" = v9.9.9 ]; then pass downgrade_allowed; else fail downgrade_allowed "rc=$RC ver=$(cat "$VER") $(show "$OUT")"; fi

# 13-15 Signatur (Schluesselbund gesetzt): gueltig -> Erfolg; fremder Schluessel / fehlend -> Abbruch vor dem Entpacken
EXTRA_ENV="LIFEAGENTS_RELEASE_KEYRING=$W/kr.gpg"
sign v9.9.10 'update-test project'
installed v9.9.8; reset_db; scenario ok; tg_clear; id="$(request v9.9.10)"; cli --run-requested
o="$(outcome "$id")"
if [ "${o%%|*}" = succeeded ]; then pass sig_valid; else fail sig_valid "outcome=$o $(show "$OUT")"; fi
sign v9.9.10 'update-test evil'
installed v9.9.8; reset_db; tg_clear; id="$(request v9.9.10)"; cli --run-requested
o="$(outcome "$id")"
if [ "${o%%|*}" = failed ] && [ "$(echo "$o" | cut -d'|' -f3)" = signature ] && [ "$(cat "$VER")" = v9.9.8 ] \
   && tg_has 'issues/new' && ! tg_has 'upd:retry'; then pass sig_foreign_key; else fail sig_foreign_key "outcome=$o $(show "$(tg_all)")"; fi
rm -f "$REL/v9.9.10/SHA256SUMS.sig"; sign v9.9.9 'update-test project'   # nur v9.9.9 ist jetzt signiert
latch_clear; tg_clear; cli --check
if [ "$(tg_n)" = 1 ] && tg_has 'upd:now:v9.9.9' && ! tg_has 'upd:now:v9.9.10'; then pass sig_missing_no_card
else fail sig_missing_no_card "sends=$(tg_n) $(show "$(tg_all)")"; fi
installed v9.9.8; reset_db; tg_clear; id="$(request v9.9.10)"; cli --run-requested
o="$(outcome "$id")"
if [ "${o%%|*}" = failed ] && [ "$(echo "$o" | cut -d'|' -f3)" = signature ]; then pass sig_missing_refused; else fail sig_missing_refused "outcome=$o"; fi
# 16 install.sh (Bootstrap) prueft gegen dasselbe Bund
sign v9.9.10 'update-test project'
OUT="$(env "${RUNENV[@]}" LIFEAGENTS_RELEASE_KEYRING="$W/kr.gpg" bash "$LIB/provisioning/install.sh" --version v9.9.10 --profile dev 2>&1 </dev/null)"; RC=$?
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'Unterschrift + SHA256 verifiziert'; then pass install_sig_valid; else fail install_sig_valid "rc=$RC $(show "$OUT")"; fi
sign v9.9.10 'update-test evil'
OUT="$(env "${RUNENV[@]}" LIFEAGENTS_RELEASE_KEYRING="$W/kr.gpg" bash "$LIB/provisioning/install.sh" --version v9.9.10 --profile dev 2>&1 </dev/null)"; RC=$?
if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q 'Unterschrift von Release v9.9.10 ist ungültig'; then pass install_sig_foreign; else fail install_sig_foreign "rc=$RC $(show "$OUT")"; fi
unset EXTRA_ENV

exit "$fails"
