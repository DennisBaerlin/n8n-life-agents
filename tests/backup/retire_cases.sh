#!/usr/bin/env bash
# retire_cases.sh — Fall-Runner von scripts/dev/retire_test.ps1, laeuft IM klassischen Substrat (root, systemd, echtes n8n +
# PostgreSQL, die CLI DIESES Baums unter <root>/lifeagents). Echter Weg von `lifeagents retire` (lib/retire_cli.sh):
#   L  Lauf: Bot geloest (die Telegram-Attrappe des Substrats, an der auch n8n haengt), n8n + Gateway + Timer aus UND deaktiviert, PostgreSQL an, Umzugs-Ordner vollstaendig,
#      Sicherung laesst sich pruefen (restore --plan), Gedaechtnis-Abzug mit Zeilenzahl, Antwort-Datei liest sich zurueck.
#   G  Sperre: update/config set enden mit Satz, doctor zeigt den Ruhezustand gruen.
#   U  Rueckweg: Bot hoert woanders -> nichts; --undo --restore: Daten + Gedaechtnis + Wasserstand zurueck, alles wieder an.
#      Die Attrappe merkt sich setWebhook/deleteWebhook (/__webhook?track=1): nach dem Lauf ist der Webhook wirklich leer.
# Testdaten erfunden; eigene Gedaechtnis-Tabelle agent.rtprobe_chat_memory (wird entfernt). Am Ende laeuft alles wie vorher.
#
# Usage: bash retire_cases.sh <root> <mock-port> <mock-log>   Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2016,SC2329,SC2015,SC2031  # cleanup laeuft per trap; A && pass || fail ist gewollt (pass scheitert nie)
set -uo pipefail
ROOT="$1"; PORT="$2"; TGLOG="$3"
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
MEM=agent.rtprobe_chat_memory

# Aufrufe dieses Laufs: Zeilen des Attrappen-Protokolls ab jetzt.
L0="$(wc -l < "$TGLOG" 2>/dev/null || echo 0)"
tgcalls() { tail -n +"$((L0 + 1))" "$TGLOG" 2>/dev/null | grep -c "\"method\":\"$1\""; }
webhook_url() { curl -sf "http://127.0.0.1:$PORT/botx/getWebhookInfo" | jq -r '.result.url // ""'; }
# Im Dev-Substrat meldet n8n ohne oeffentliche Adresse keinen Webhook an (Orchestrator-Trigger inaktiv): „wieder hier“ belegt erst
#   die Probe mit echtem Test-Bot, darum hier eine kurze Wartezeit.
# hand-injected: Telegram = Attrappe im Container (nie der echte Bot); kurze Warte-/Abwartezeiten fuer den Testlauf
export LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$PORT" RETIRE_WEBHOOK_WAIT_SECS=5 RETIRE_DRAIN_SECS=60
# hand-injected: Substrat ohne Bot-Schluessel; ein erfundener (Umgebung vor core.env) schickt Loesen + Pruefen ueber die Attrappe
export TELEGRAM_BOT_TOKEN=1000001:RETIRETESTzz9
UNITS="n8n lifeagents-llm-gateway lifeagents-update-check.timer lifeagents-update-run.timer lifeagents-backup.timer"

cleanup() {
  find /var/backups/lifeagents -type f 2>/dev/null | grep -vxF -f "$W/bk_before" | xargs -r rm -f
  local u
  rm -f "$(la_retired_file)"
  for u in $UNITS; do systemctl enable "$u" >/dev/null 2>&1; systemctl start "$u" >/dev/null 2>&1; done
  sql "DROP TABLE IF EXISTS ${MEM}; DELETE FROM agent.guide_learn_watermark WHERE agent_name = 'rtprobe'" >/dev/null 2>&1
  curl -sf "http://127.0.0.1:$PORT/__webhook?off=1&track=0" >/dev/null 2>&1; rm -rf "$W" "$CLI"
}
find /var/backups/lifeagents -type f 2>/dev/null > "$W/bk_before" || : > "$W/bk_before"
trap cleanup EXIT
n=0
cli() { n=$((n + 1)); "$CLI" "$@" > "$W/out.$n" 2>&1 < /dev/null; }
said() { grep -qF -- "$1" "$W/out.$n"; }
last() { tail -n4 "$W/out.$n" | tr '\n' ' '; }

curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 || { fail setup 'Telegram-Attrappe antwortet nicht'; exit "$fails"; }
[ ! -e "$(la_retired_file)" ] || { fail setup 'Merker liegt schon (fremder Lauf?)'; exit "$fails"; }
curl -sf "http://127.0.0.1:$PORT/__webhook?off=1&track=1" >/dev/null || { fail setup 'Attrappe ohne Webhook-Merkmodus'; exit "$fails"; }
# Gedaechtnis-Tabelle wie der n8n-Knoten sie anlegt (Rolle n8n, Event-Trigger haengt den Guard an); Inhalte erfunden.
_owner="$(read_env_value /etc/n8n/n8n.env DB_POSTGRESDB_USER)"
sql "CREATE TABLE ${MEM} (id SERIAL PRIMARY KEY, session_id VARCHAR(255) NOT NULL, message JSONB NOT NULL);
     ALTER TABLE ${MEM} OWNER TO ${_owner};
     INSERT INTO ${MEM}(session_id, message) SELECT 'rt-' || g, jsonb_build_object('type','human','data',jsonb_build_object('content','Testfrage ' || g)) FROM generate_series(1,5) g;" >/dev/null \
  || { fail setup 'Gedaechtnis-Tabelle nicht anlegbar'; exit "$fails"; }
# Vorpruefung „Sicherung < 26 h“ ueber den echten Weg erfuellen.
cli backup auto || { fail setup "backup auto: $(last)"; exit "$fails"; }

# --- L: Lauf ---------------------------------------------------------------------------------------------------------
cli retire --check; eq L.check-gruen 0 "$?"
cli retire --out "$OUT"; rc=$?
eq L.lauf-ok 0 "$rc"
[ "$rc" = 0 ] || printf '# %s\n' "$(cat "$W/out.$n")" | tail -n 12
# Zweimal: vor der Wartezeit und nach dem Stopp (n8n kann ihn in der Wartezeit neu angemeldet haben).
eq L.webhook-geloest 2 "$(tgcalls deleteWebhook)"
eq L.webhook-leer '' "$(webhook_url)"
_f0=$fails
for u in $UNITS; do
  systemctl is-active --quiet "$u" && fail "L.aus-$u" "laeuft"
  [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ] && fail "L.deaktiviert-$u" "enabled"
done; [ "$fails" = "$_f0" ] && pass L.dienste-aus-und-deaktiviert
systemctl is-active --quiet postgresql && pass L.postgres-an || fail L.postgres-an "aus"
eq L.stand 'done' "$(read_env_value "$(la_retired_file)" STAGE)"
eq L.ordner-rechte 700 "$(stat -c %a "$OUT")"
eq L.dateien-rechte 600 "$(stat -c %a "$OUT"/* | sort -u | tr '\n' ' ' | sed 's/ $//')"
BF="$(read_env_value "$OUT/move.manifest" BACKUP_FILE)"
cli backup restore "$OUT/$BF" --plan --json
eq L.sicherung-pruefbar true "$(tail -n1 "$W/out.$n" | jq -r .ok 2>/dev/null)"
eq L.sicherung-release "$(cat "$ROOT/VERSION")" "$(tail -n1 "$W/out.$n" | jq -r .release 2>/dev/null)"
[ ! -e "$OUT/memory.counts" ] && [ ! -e "$OUT/memory.dump" ] && pass L.gedaechtnis-in-der-sicherung || fail L.gedaechtnis-in-der-sicherung "eigener Abzug im Ordner"
grep -q "^memory-md5 ${MEM} " "$OUT/vorher.txt" && pass L.vorher-gedaechtnis-md5 || fail L.vorher-gedaechtnis-md5 "$(grep memory "$OUT/vorher.txt")"
grep -qx "memory ${MEM} 5" "$OUT/vorher.txt" && pass L.vorher-gedaechtnis || fail L.vorher-gedaechtnis "$(grep memory "$OUT/vorher.txt")"
grep -q '^md5 ' "$OUT/vorher.txt" && pass L.vorher-fingerabdruck || fail L.vorher-fingerabdruck "kein md5"
_back="$( ( . "$ROOT/provisioning/lib/release_inputs.sh"; install_answers_load "$OUT/move.env" 2>"$W/load.err"; printf '%s' "$REACH_MODE" ) )"
eq L.antworten-tunnel tunnel "$_back"
eq L.antworten-ohne-warnung '' "$(cat "$W/load.err")"
if grep -qE '^(TELEGRAM_WEBHOOK_TAKEOVER|DOMAIN|TRUSTED_PROXIES)=' "$OUT/move.env"; then fail L.antworten-nie "$(grep -oE '^[A-Z_]+=' "$OUT/move.env" | tr '\n' ' ')"; else pass L.antworten-nie; fi
cli retire; eq L.zweiter-lauf-nichts 2 "$(tgcalls deleteWebhook)"
cli retire --status; eq L.status-fertig 11 "$?"

# --- G: Sperre -------------------------------------------------------------------------------------------------------
cli update; rc=$?; { [ "$rc" = 1 ] && said stillgelegt; } && pass G.update-gesperrt || fail G.update-gesperrt "rc=$rc $(last)"
cli config set system tz x; rc=$?; { [ "$rc" = 1 ] && said stillgelegt; } && pass G.config-gesperrt || fail G.config-gesperrt "rc=$rc $(last)"
systemctl is-active --quiet n8n && fail G.n8n-bleibt-aus "laeuft" || pass G.n8n-bleibt-aus
# Auch ein Start von Hand (oder ein Neustart, Restart=on-failure) holt n8n nicht zurueck: Unit-Bedingung ConditionPathExists.
systemctl start n8n >/dev/null 2>&1; sleep 3
systemctl is-active --quiet n8n && fail G.systemctl-start-wirkungslos "n8n laeuft" || pass G.systemctl-start-wirkungslos
cli doctor; eq G.doctor-ruhezustand-gruen 0 "$?"
said 'Stillgelegt' && pass G.doctor-satz || fail G.doctor-satz "$(last)"

# --- U: Rueckweg -----------------------------------------------------------------------------------------------------
curl -sf "http://127.0.0.1:$PORT/__webhook?url=https://neu.example.ts.net/webhook/x/webhook" >/dev/null
cli retire --undo; rc=$?
{ [ "$rc" = 1 ] && said woanders; } && pass U.fremd-abbruch || fail U.fremd-abbruch "rc=$rc $(last)"
systemctl is-active --quiet n8n && fail U.fremd-n8n-aus "laeuft" || pass U.fremd-n8n-aus
curl -sf "http://127.0.0.1:$PORT/__webhook?off=1" >/dev/null
# Zwischenstand „auf der neuen Maschine geaendert“: Gedaechtnis-Zeile weg, Wasserstand falsch -> die Rueck-Sicherung stellt her.
sql "DELETE FROM ${MEM} WHERE id = 1; INSERT INTO agent.guide_learn_watermark(agent_name, last_seen_id) VALUES ('rtprobe', 0)
     ON CONFLICT (agent_name) DO UPDATE SET last_seen_id = 0" >/dev/null
cli retire --undo --restore "$OUT"; rc=$?
eq U.restore-ok 0 "$rc"
[ "$rc" = 0 ] || printf '# %s\n' "$(cat "$W/out.$n")" | tail -n 12
eq U.gedaechtnis-zurueck 5 "$(sql "SELECT count(*) FROM ${MEM}")"
eq U.wasserstand-max 5 "$(sql "SELECT last_seen_id FROM agent.guide_learn_watermark WHERE agent_name = 'rtprobe'")"
eq U.eigentuemer-n8n "$_owner" "$(sql "SELECT tableowner FROM pg_tables WHERE schemaname || '.' || tablename = '${MEM}'")"
eq U.guard-einmal 1 "$(sql "SELECT count(*) FROM pg_trigger WHERE tgrelid = '${MEM}'::regclass AND tgname = 'trg_chat_memory_strip_thinking'")"
_seq="$(sql "SELECT nextval(pg_get_serial_sequence('${MEM}', 'id'))")"
[ "${_seq:-0}" -gt 5 ] && pass U.folge-nummer || fail U.folge-nummer "nextval=$_seq"
_f0=$fails
for u in $UNITS; do
  [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ] || fail "U.aktiviert-$u" "$(systemctl is-enabled "$u" 2>&1)"
done; [ "$fails" = "$_f0" ] && pass U.alles-aktiviert
for _ in $(seq 1 60); do curl -fsS -o /dev/null "http://127.0.0.1:5678/healthz/readiness" 2>/dev/null && break; sleep 2; done
systemctl is-active --quiet n8n && pass U.n8n-laeuft || fail U.n8n-laeuft "aus"
[ ! -e "$(la_retired_file)" ] && pass U.merker-weg || fail U.merker-weg "liegt"
cli retire --status; eq U.status-nicht 0 "$?"

exit "$fails"
