#!/usr/bin/env bash
# move_cases.sh — Fall-Runner von scripts/dev/move_test.ps1, laeuft IM klassischen Substrat (root, systemd, echtes n8n +
# PostgreSQL, die CLI DIESES Baums unter <root>/lifeagents). Echter Weg von `lifeagents move` (lib/move_cli.sh) und `config import`:
#   Erzeugung  B1-`retire` schreibt den Umzugs-Ordner (erfundene Daten: Gedaechtnis-Tabelle, eine geaenderte Einstellung), `retire --undo`
#              holt das Substrat zurueck; danach wird der Zustand „frisch eingerichtete Maschine“ nachgebaut (Gedaechtnis weg,
#              Einstellung auf Standard, Owner ohne chat_id, Workflows MIT Platzhalter-chat_id = genau der Zustand nach `setup.sh --answers`).
#   A  apply   Vorpruefung „Maschine in Gebrauch“ greift; apply spielt alles ein: Daten (family-Kontext mit der chat_id), Gedaechtnis samt
#              Wasserstand, Einstellung, 0 Platzhalter in den n8n-Workflows, Geheimnis-Dateien weg, Sicherung bleibt, Vergleich gruen.
#   U  Sperre  Update, rollback und provision.sh mit anderer Release enden mit Satz (gleiche Release laeuft); doctor zeigt „Umzug offen“ nur als Hinweis; zweiter apply-Lauf spielt nichts doppelt ein.
#   D  done    Abnahme hebt die Sperre auf; danach schuetzt „in Gebrauch“ die Daten vor einem versehentlichen apply.
#   Verbund (N8NTEST_RUNTIME=compose, im master): nur lock_cases (Versions-Sperre), Merker vom Test gelegt.
# Testdaten erfunden; eigene Gedaechtnis-Tabelle agent.uzprobe_chat_memory (wird entfernt). Am Ende laeuft alles wie vorher.
# real-path-test fuer tests/mock_runtime/move_cases.sh (die Attrappen dort ersetzen Tunnel, Rechner-Ordner und Notfallblatt-Eingabe; der
#   Verbund-Zweig hat seinen echten Weg in der Probe auf zwei Test-LXC bzw. im CI-Job linux-setup).
#
# Usage: bash move_cases.sh <root> <mock-port> <mock-log>   Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2016,SC2329,SC2015,SC2031,SC2086,SC2034  # cleanup laeuft per trap; A && pass || fail ist gewollt (pass scheitert nie); ${CK} ist „category key“ und wird bewusst zerlegt; INSTALL_ENV_FILE liest load_install_env
set -uo pipefail
ROOT="$1"; PORT="$2"   # $3 (Telegram-Protokoll) braucht dieser Lauf nicht; der Runner reicht es wie bei retire_test mit
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }

W="$(mktemp -d)"; chmod 0700 "$W"
OUT="$W/move"
CLI="$ROOT/lifeagents"
sed "s|@@LIBDIR@@|$ROOT|" "$ROOT/provisioning/templates/lifeagents.tpl" > "$CLI"; chmod 0700 "$CLI"
[ -r "$ROOT/VERSION" ] || cp /usr/local/lib/lifeagents/VERSION "$ROOT/VERSION" 2>/dev/null || true
grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/VERSION" 2>/dev/null || printf 'v9.9.0\n' > "$ROOT/VERSION"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
lifeagents_db_name >/dev/null
sql() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "$1"; }
MEM=agent.uzprobe_chat_memory
UNITS="n8n lifeagents-llm-gateway lifeagents-update-check.timer lifeagents-update-run.timer lifeagents-backup.timer"
# hand-injected: Telegram = Attrappe im Container (nie der echte Bot); kurze Warte-/Abwartezeiten fuer den Testlauf
export LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$PORT" RETIRE_WEBHOOK_WAIT_SECS=5 RETIRE_DRAIN_SECS=60
# hand-injected: Substrat ohne Bot-Schluessel; ein erfundener (Umgebung vor core.env) schickt Loesen, Pruefen und Menue ueber die Attrappe
export TELEGRAM_BOT_TOKEN=1000001:MOVETESTzz9

CK=''; CV=''; OWNER_SET=0; VM=''; V_BEFORE=''; V_SAVED=0
# setowner <json-wert> — telegram_user_id des Owners in den family-Fakten (null = noch nicht gekoppelt).
setowner() {
  sql "UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}',
         (SELECT jsonb_agg(CASE WHEN p->>'role' = 'owner' THEN jsonb_set(p, '{telegram_user_id}', '$1'::jsonb) ELSE p END)
            FROM jsonb_array_elements(metadata->'facts'->'persons') p)) WHERE name = 'family'" >/dev/null
}
# v_restore — VERSION-Marker wie vor den provision.sh-Faellen (fehlte er, wieder weg: sonst saehe das Substrat installiert aus).
v_restore() {
  if [ -n "$V_BEFORE" ]; then printf '%s\n' "$V_BEFORE" > "$VM"; else rm -f "$VM"; fi
  V_SAVED=0
}
cleanup() {
  find /var/backups/lifeagents -type f 2>/dev/null | grep -vxF -f "$W/bk_before" | xargs -r rm -f
  local u
  rm -f "$(la_retired_file)" "$(la_move_file)"
  for u in $UNITS; do systemctl enable "$u" >/dev/null 2>&1; systemctl start "$u" >/dev/null 2>&1; done
  sql "DROP TABLE IF EXISTS ${MEM}; DELETE FROM agent.guide_learn_watermark WHERE agent_name = 'uzprobe'" >/dev/null 2>&1
  [ -z "$CK" ] || "$CLI" config set ${CK} "$CV" >/dev/null 2>&1
  [ "$OWNER_SET" != 1 ] || setowner null
  [ "$V_SAVED" != 1 ] || v_restore
  curl -sf "http://127.0.0.1:$PORT/__webhook?off=1&track=0" >/dev/null 2>&1; rm -rf "$W" "$CLI"
}
find /var/backups/lifeagents -type f 2>/dev/null > "$W/bk_before" || : > "$W/bk_before"
trap cleanup EXIT
n=0
cli() { n=$((n + 1)); "$CLI" "$@" > "$W/out.$n" 2>&1 < /dev/null; }
said() { grep -qF -- "$1" "$W/out.$n"; }
last() { tail -n6 "$W/out.$n" | tr '\n' ' '; }
ready() { for _ in $(seq 1 90); do curl -fsS -o /dev/null "http://127.0.0.1:5678/healthz/readiness" 2>/dev/null && return 0; sleep 2; done; return 1; }
# lock_cases — Versions-Sperre bei offenem Umzug: update, rollback und provision.sh mit anderer Version enden mit dem Satz, vor jeder
#   Aenderung; dieselbe Version laeuft. Klassisch im Abschnitt U, im Verbund allein (unten).
lock_cases() {
  cli update --version v0.0.1; rc=$?
  { [ "$rc" = 1 ] && said 'move done'; } && pass U.update-gesperrt || fail U.update-gesperrt "rc=$rc $(last)"
  # Jeder andere Versionswechsel sperrt mit demselben Satz, vor jeder Aenderung: rollback spielte sonst die pre-upgrade-Sicherung (Stand vor dem
  # Umzug) ein, und ein provision.sh mit anderer Release (install.sh --version …) braeche den Rueckweg (verlangt dieselbe Release).
  cli rollback; rc=$?
  { [ "$rc" = 1 ] && said 'move done'; } && pass U.rollback-gesperrt || fail U.rollback-gesperrt "rc=$rc $(last)"
  # provn <release> — provision.sh dieses Baums wie install.sh/fetch_release ihn starten (RELEASE_TAG exportiert).
  # hand-injected: RELEASE_TAG ist genau der Wert, den install.sh/fetch_release exportieren; TRUSTED_PROXIES=kaputt bricht kurz hinter der Sperre ab, bevor etwas installiert wird (davor Sperre/Ergebnis-Datei, DOMAIN-Schreibweise und im Verbund reach_prepare: der Tailscale-Container des Test-Verbunds startet und bleibt ohne Anmeldung): so laeuft auch ein Lauf ohne Sperre nie durch.
  provn() { n=$((n + 1)); RELEASE_TAG="$1" TRUSTED_PROXIES=kaputt bash "$ROOT/provisioning/provision.sh" > "$W/out.$n" 2>&1 < /dev/null; }
  # Installierte Version fuer diese Faelle eine Release (das Substrat traegt oft „dev“, dann schriebe ein Lauf ohne Tag dasselbe = kein Wechsel).
  VM="$(lifeagents_version_marker)"; V_BEFORE="$(cat "$VM" 2>/dev/null)"; V_SAVED=1; [ -e "$VM" ] || V_BEFORE=''; _v0=v9.9.1; printf '%s\n' "$_v0" > "$VM"
  provn v0.0.2; rc=$?
  { [ "$rc" = 1 ] && said 'move done'; } && pass U.provision-andere-release-gesperrt || fail U.provision-andere-release-gesperrt "rc=$rc $(last)"
  # Ohne Tag schriebe klassisch VERSION=dev, im Verbund die Nummer des laufenden Abbilds (release_tag_resolve, Fall „Abbild ≠ VERSION“):
  # beides weicht von der installierten Release ab und sperrt.
  provn ''; rc=$?
  { [ "$rc" = 1 ] && said 'move done'; } && pass U.provision-ohne-tag-gesperrt || fail U.provision-ohne-tag-gesperrt "rc=$rc $(last)"
  provn "$_v0"; rc=$?
  { [ "$rc" = 1 ] && said 'TRUSTED_PROXIES' && ! said 'move done'; } && pass U.provision-gleiche-release-frei || fail U.provision-gleiche-release-frei "rc=$rc $(last)"
  eq U.version-unveraendert "$_v0" "$(cat "$(lifeagents_version_marker)" 2>/dev/null)"
  v_restore
}

# Verbund: nur die Versions-Sperre. Annahme und Abnahme im Verbund prueft die Probe auf zwei Test-LXC bzw. der CI-Job linux-setup (Kopf);
# den Merker legt hier der Test selbst (Stufe wie nach apply). Die Tick-Schleife des master haelt der Treiber an (Update-Sperre).
if rt_is_compose; then
  [ ! -e "$(la_move_file)" ] || { fail setup 'Merker liegt schon (fremder Lauf?)'; exit "$fails"; }
  trap 'rm -f "$(la_move_file)"; [ "$V_SAVED" != 1 ] || v_restore; rm -rf "$W" "$CLI"' EXIT
  printf 'STAGE=applied\nMOVE=uzprobe\nAT=test\n' > "$(la_move_file)"
  lock_cases
  exit "$fails"
fi
curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 || { fail setup 'Telegram-Attrappe antwortet nicht'; exit "$fails"; }
[ ! -e "$(la_retired_file)" ] && [ ! -e "$(la_move_file)" ] || { fail setup 'Merker liegt schon (fremder Lauf?)'; exit "$fails"; }
curl -sf "http://127.0.0.1:$PORT/__webhook?off=1&track=1" >/dev/null || { fail setup 'Attrappe ohne Webhook-Merkmodus'; exit "$fails"; }

# --- Ausgangslage („alte Maschine“): Gedaechtnis wie der n8n-Knoten es anlegt, eine geaenderte Einstellung ----------------------------
_owner="$(read_env_value /etc/n8n/n8n.env DB_POSTGRESDB_USER)"
sql "CREATE TABLE ${MEM} (id SERIAL PRIMARY KEY, session_id VARCHAR(255) NOT NULL, message JSONB NOT NULL);
     ALTER TABLE ${MEM} OWNER TO ${_owner};
     INSERT INTO ${MEM}(session_id, message) SELECT 'uz-' || g, jsonb_build_object('type','human','data',jsonb_build_object('content','Testfrage ' || g)) FROM generate_series(1,5) g;" >/dev/null \
  || { fail setup 'Gedaechtnis-Tabelle nicht anlegbar'; exit "$fails"; }
CK="$(sql "SELECT category || ' ' || key FROM core.config WHERE managed_by = 'owner' AND category <> 'schedule' AND value IN ('true','false') ORDER BY 1 LIMIT 1")"
[ -n "$CK" ] || { fail setup 'keine boolesche Einstellung im Substrat'; exit "$fails"; }
CV="$(sql "SELECT value FROM core.config WHERE category = '${CK% *}' AND key = '${CK#* }'")"
CV2=true; [ "$CV" = true ] && CV2=false
# Install-Primitive wie der household-Arm (deploy_workflows, _oc_finalize): fuer die Vorbereitung und den Platzhalter-Zustand unten.
for f in release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh bootstrap_owner.sh firewall.sh owner_connect.sh; do
  # shellcheck source=/dev/null
  . "$ROOT/provisioning/lib/$f"
done
INSTALL_ENV_FILE=/etc/lifeagents/core.env
_pkg_resolve_env; load_install_env
N8N_API_KEY="$(read_env_value /etc/lifeagents/core.env N8N_API_KEY)"; N8N_URL="http://127.0.0.1:5678"; export N8N_API_KEY N8N_URL
# Der Owner muss in der Sicherung stehen: hat das Substrat keine chat_id in den family-Fakten, bekommt er eine erfundene (Aufraeumen: zurueck auf null).
OWNER_BEFORE="$(sql "SELECT pp->>'telegram_user_id' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp WHERE c.name='family' AND pp->>'role'='owner' LIMIT 1")"
if ! [[ $OWNER_BEFORE =~ ^[0-9]+$ ]]; then OWNER_BEFORE=4711000; OWNER_SET=1; setowner "$OWNER_BEFORE"; fi
[[ "$(_owner_chat_id_db)" =~ ^[0-9]+$ ]] || { fail setup 'Owner in den family-Fakten nicht herstellbar (keine family-Personen?)'; exit "$fails"; }
# Ein Owner in der DB und Workflows mit Platzhalter-chat_id waere ein doctor-ROT (und genau der Fehler, den apply behebt): Vorbedingung herstellen.
if [ "$(owner_chat_placeholder_count)" != 0 ]; then
  ( _oc_finalize ) >"$W/prep.out" 2>&1 || { fail setup "Workflows mit chat_id einspielen: $(tail -n3 "$W/prep.out" | tr '\n' ' ')"; exit "$fails"; }
fi
cli config set ${CK} "$CV2" || { fail setup "config set: $(last)"; exit "$fails"; }
# Der Intro-Merker des Owners steht in der Sicherung, damit A.intro-merker-gesetzt das Mitreisen prueft. Setzen statt dem Substrat
# ueberlassen: der Menue-Lauf merkt ihn nur bei bereitem Uebersicht-Knopf (core.fn_app_button_ready, haengt am Onboarding-Stand).
sql "SELECT core.fn_should_notify('app_intro', '${OWNER_BEFORE}')" >/dev/null
cli backup auto || { fail setup "backup auto: $(last)"; exit "$fails"; }
cli retire --out "$OUT"; rc=$?
eq E.retire-ok 0 "$rc"
[ "$rc" = 0 ] || { printf '# %s\n' "$(cat "$W/out.$n")" | tail -n 12; exit "$fails"; }
# Antworten nur verschluesselt (Sicherungs-Schluessel wie die Sicherung). Der Entsperr-Schritt von setup.sh (compose/move_unlock.sh, Terminal
# ueber script) fragt einmal, entschluesselt und legt den Schluessel fuer das Einspielen ab; apply loescht ihn wieder (A.schluessel-weg).
[ -s "$OUT/move.env.gpg" ] && [ ! -e "$OUT/move.env" ] && pass E.antworten-verschluesselt || fail E.antworten-verschluesselt "$(find "$OUT" -mindepth 1 -printf '%f ')"
SHEET_KEY="$(dirname "$(la_move_file)")/move-sheet.key"
if command -v script >/dev/null 2>&1; then
  MU="$ROOT/provisioning/compose/move_unlock.sh"
  bash "$MU" put < "$OUT/move.env.gpg"
  backup_key_candidates | head -n1 | script -qec "GUM_DISABLE=1 bash '$MU' open" /dev/null > "$W/unlock.out" 2>&1
  bash "$MU" take > "$W/move.ans" 2>/dev/null || true; bash "$MU" drop
  grep -qx "REACH_MODE='tunnel'" "$W/move.ans" 2>/dev/null && pass E.entsperrt || fail E.entsperrt "$(tail -n3 "$W/unlock.out" | tr '\n' ' ')"
  [ "$(stat -c %a "$SHEET_KEY" 2>/dev/null)" = 600 ] && pass E.schluessel-abgelegt || fail E.schluessel-abgelegt "fehlt"
else printf 'SKIP E.entsperrt: kein script(1)\n'; fi
cli retire --undo; eq E.undo-ok 0 "$?"
ready || { fail E.n8n-wieder-da "n8n antwortet nicht"; exit "$fails"; }
grep -q "^config .*${CK#* } " "$OUT/vorher.txt" && pass E.vorher-nennt-einstellung || fail E.vorher-nennt-einstellung "$(grep '^config' "$OUT/vorher.txt")"

# --- Zustand „frisch eingerichtete Maschine“ nachbauen ---------------------------------------------------------------------------------
sql "DROP TABLE ${MEM}; DELETE FROM agent.guide_learn_watermark WHERE agent_name = 'uzprobe'" >/dev/null
cli config reset ${CK}; eq E.einstellung-auf-standard "$CV" "$(sql "SELECT value FROM core.config WHERE category = '${CK% *}' AND key = '${CK#* }'")"
setowner null
eq E.owner-ohne-chat-id '' "$(_owner_chat_id_db)"
( unset OWNER_CHAT_ID; deploy_workflows core ) >"$W/deploy.out" 2>&1 || { fail E.platzhalter-herstellen "deploy_workflows core: $(tail -n3 "$W/deploy.out" | tr '\n' ' ')"; exit "$fails"; }
PH0="$(owner_chat_placeholder_count)"
[ "${PH0:-0}" -gt 0 ] && pass E.platzhalter-da || fail E.platzhalter-da "Anzahl ${PH0:-?}"

# --- A: apply ------------------------------------------------------------------------------------------------------------------------
# Maschine in Gebrauch (Owner schon gekoppelt): nichts wird eingespielt. Hier: erst einen Owner eintragen, dann zurueck auf „frisch“.
setowner "$OWNER_BEFORE"
cli move apply "$OUT"; rc=$?
{ [ "$rc" = 1 ] && said 'in Gebrauch'; } && pass A.in-gebrauch-abbruch || fail A.in-gebrauch-abbruch "rc=$rc $(last)"
[ ! -e "$(la_move_file)" ] && pass A.in-gebrauch-kein-merker || fail A.in-gebrauch-kein-merker "Merker liegt"
[ -e "$OUT/move.env.gpg" ] && pass A.in-gebrauch-dateien-bleiben || fail A.in-gebrauch-dateien-bleiben "move.env.gpg weg"
setowner null
# Vorpruefung: falsche Release im Manifest -> nichts.
cp "$OUT/move.manifest" "$W/manifest.bak"; sed -i 's/^RELEASE=.*/RELEASE=v0.0.1/' "$OUT/move.manifest"
cli move apply "$OUT"; rc=$?
{ [ "$rc" = 1 ] && said 'v0.0.1'; } && pass A.andere-release-abbruch || fail A.andere-release-abbruch "rc=$rc $(last)"
cp "$W/manifest.bak" "$OUT/move.manifest"; chmod 0600 "$OUT/move.manifest"
[ ! -e "$(la_move_file)" ] && pass A.andere-release-kein-merker || fail A.andere-release-kein-merker "Merker liegt"

cli move apply "$OUT"; rc=$?
eq A.apply-ok 0 "$rc"
[ "$rc" = 0 ] || printf '# %s\n' "$(cat "$W/out.$n")" | tail -n 14
eq A.stufe applied "$(read_env_value "$(la_move_file)" STAGE)"
eq A.owner-chat-id-da "$OWNER_BEFORE" "$(_owner_chat_id_db)"
eq A.null-platzhalter 0 "$(owner_chat_placeholder_count)"
eq A.gedaechtnis-zeilen 5 "$(sql "SELECT count(*) FROM ${MEM}")"
eq A.wasserstand-max 5 "$(sql "SELECT last_seen_id FROM agent.guide_learn_watermark WHERE agent_name = 'uzprobe'")"
eq A.eigentuemer-n8n "$_owner" "$(sql "SELECT tableowner FROM pg_tables WHERE schemaname || '.' || tablename = '${MEM}'")"
eq A.einstellung-da "$CV2" "$(sql "SELECT value FROM core.config WHERE category = '${CK% *}' AND key = '${CK#* }'")"
_f0=$fails
for f in move.env.gpg move.env memory.dump memory.counts; do [ ! -e "$OUT/$f" ] || fail "A.geloescht-$f" "liegt noch"; done
[ "$fails" = "$_f0" ] && pass A.geheimnisse-geloescht
[ ! -e "$SHEET_KEY" ] && pass A.schluessel-weg || fail A.schluessel-weg "$SHEET_KEY liegt noch"
BF="$(read_env_value "$OUT/move.manifest" BACKUP_FILE)"
[ -s "$OUT/$BF" ] && pass A.sicherung-bleibt || fail A.sicherung-bleibt "weg"
[ -s "$OUT/nachher.txt" ] && pass A.nachher-geschrieben || fail A.nachher-geschrieben "fehlt"
eq A.ordner-rechte 700 "$(stat -c %a "$OUT")"
eq A.dateien-rechte 600 "$(stat -c %a "$OUT"/* | sort -u | tr '\n' ' ' | sed 's/ $//')"
# Das Ziel merkt sich nach dem Einspielen eigene Hinweise (Intro fuer jemanden, der es auf der alten Maschine nie sah): kein
# Unterschied im Vergleich (backup_fingerprint laesst core.notification_state aus). Direkt gesetzt, Grund wie beim Owner-Merker oben.
sql "SELECT core.fn_should_notify('app_intro', '4711999')" >/dev/null
cli move check; _rcc=$?; eq A.check-gleich 0 "$_rcc"
sql "DELETE FROM core.notification_state WHERE source = 'app_intro' AND key = '4711999'" >/dev/null
[ "$_rcc" = 0 ] || printf '# %s
' "$(cat "$W/out.$n")" | tail -n 12
cli move status; eq A.status-offen 11 "$?"
# Die Intro-Merker reisen mit (core.notification_state in der Sicherung): kein zweites Mal die Animation fuer jede Person.
_ids="$(sql "SELECT p->>'telegram_user_id' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') p WHERE c.name='family' AND COALESCE(p->>'telegram_user_id','') ~ '^[0-9]{1,18}\$'")"
_miss=0; for _i in $_ids; do [ "$(sql "SELECT core.fn_app_intro_pending('${_i}')")" = f ] || _miss=$((_miss + 1)); done
eq A.intro-merker-gesetzt 0 "$_miss"

# --- U: Sperre -------------------------------------------------------------------------------------------------------------------------
lock_cases
cli doctor; _rcd=$?
{ grep -q 'Umzug offen' "$W/out.$n"; } && pass U.doctor-nennt-move || fail U.doctor-nennt-move "$(last)"
{ grep 'Umzug offen' "$W/out.$n" | grep -q 'FAIL'; } && fail U.doctor-move-nie-rot "als FAIL" || pass U.doctor-move-nie-rot
# Zweiter apply-Lauf: Daten, die inzwischen entstanden sind, bleiben (kein zweites Einspielen).
sql "INSERT INTO ${MEM}(session_id, message) VALUES ('uz-neu', '{\"type\":\"human\",\"data\":{\"content\":\"nach dem Einspielen\"}}')" >/dev/null
# Der Vergleich sieht die neue Zeile (Exit 1, Tabelle genannt): das beweist zugleich, dass nichts eingespielt wurde.
cli move apply "$OUT"; eq U.nochmal-vergleich-meldet-abweichung 1 "$?"
said "memory ${MEM}" && pass U.nochmal-nennt-tabelle || fail U.nochmal-nennt-tabelle "$(last)"
eq U.nochmal-kein-restore 6 "$(sql "SELECT count(*) FROM ${MEM}")"
sql "DELETE FROM ${MEM} WHERE session_id = 'uz-neu'" >/dev/null

# --- D: Abnahme ------------------------------------------------------------------------------------------------------------------------
cli move 'done'; rc=$?
{ [ "$rc" = 1 ] && [ -e "$(la_move_file)" ]; } && pass D.ohne-terminal-ohne-yes-nein || fail D.ohne-terminal-ohne-yes-nein "rc=$rc $(last)"
cli move 'done' --yes; eq D.yes-ok 0 "$?"
[ ! -e "$(la_move_file)" ] && pass D.merker-weg || fail D.merker-weg "liegt noch"
cli move apply "$OUT"; rc=$?
{ [ "$rc" = 1 ] && said 'in Gebrauch'; } && pass D.danach-in-gebrauch-schuetzt || fail D.danach-in-gebrauch-schuetzt "rc=$rc $(last)"
eq D.daten-unberuehrt 5 "$(sql "SELECT count(*) FROM ${MEM}")"

# abort: der Ausweg aus einem stehengebliebenen Umzug nimmt nur die Update-Sperre weg.
printf 'STAGE=restored\nMOVE=x\nAT=y\n' > "$(la_move_file)"
cli move abort --yes; eq D.abort-ok 0 "$?"
[ ! -e "$(la_move_file)" ] && pass D.abort-merker-weg || fail D.abort-merker-weg "liegt noch"
eq D.abort-daten-unberuehrt 5 "$(sql "SELECT count(*) FROM ${MEM}")"

exit "$fails"
