#!/usr/bin/env bash
# heartbeat_e2e.sh — Waechter des Hintergrund-Teils Ende zu Ende auf einer laufenden Installation mit gepaartem Owner und
# Telegram-Mock (docs/reference/core.md *Waechter des Hintergrund-Teils*). Laeuft auf dem Rechner und fasst nur das Ziel an:
#   systemd: <ziel> = Substrat-Container (bootstrap_test_n8n.ps1, enable_mock_telegram.ps1), <log> = Mock-Log IM Container.
#   compose: <ziel> = Projekt des Docker-Verbunds (genericity.yml nach pair_and_finalize.sh), <log> = Mock-Log auf dem Rechner.
# Echter Weg: echte Lebenszeichen der echten Schleife, echter n8n-Zeitgeber core.cron_heartbeat_watch, Telegram = nur der Mock.
# Kurze Schwellen nur per `lifeagents config set` (watch.*, Zeitplan jede Minute, Fenster rund um die Uhr), am Ende zurueck.
#   a) Schleife angehalten (systemd: Timer lifeagents-update-run gestoppt; compose: Tick findet die CLI nicht ausfuehrbar)
#      -> Schleifen-Alarm des Betriebswegs kommt an, Stufe 1 gemerkt; wieder an -> Entwarnung, Vorfall geschlossen.
#   b) Rechner schlaeft (docker pause laenger als watch.gap_s) -> danach keine Meldung.
# Aufruf: bash tests/mock_telegram/heartbeat_e2e.sh <systemd|compose> <ziel> <log>   Exit = Anzahl FAIL.
set -uo pipefail
RT="${1:?systemd|compose}"; T="${2:?ziel}"; LOG="${3:?mock-log}"
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

case "$RT" in
  systemd) M="$T"
           q()   { docker exec "$T" runuser -u postgres -- psql -X -d n8n -tAc "$1" 2>/dev/null | tr -d '\r'; }
           tgl() { docker exec "$T" sh -c "cat '$LOG' 2>/dev/null"; }
           jqx() { docker exec -i "$T" jq "$@"; }   # jq liegt im Substrat, nicht zwingend auf dem Rechner
           loop_stop()  { docker exec "$T" systemctl stop lifeagents-update-run.timer; }
           loop_start() { docker exec "$T" systemctl start lifeagents-update-run.timer; }
           sleep_on()   { docker pause "$T" >/dev/null; }
           sleep_off()  { docker unpause "$T" >/dev/null; } ;;
  compose) M="$T-master"
           q()   { docker exec "$T-postgres" psql -U postgres -X -d n8n -tAc "$1" 2>/dev/null | tr -d '\r'; }
           tgl() { cat "$LOG" 2>/dev/null; }
           jqx() { jq "$@"; }
           # Die Schleife im master ruft die CLI nur, wenn sie ausfuehrbar ist (provisioning/compose/compose.yml).
           loop_stop()  { docker exec "$M" chmod a-x /usr/local/bin/lifeagents; }
           loop_start() { docker exec "$M" chmod 0755 /usr/local/bin/lifeagents; }
           # Nur die Container des Verbunds (Etikett von Compose), der Telegram-Mock am anchor laeuft weiter.
           sleep_on()   { docker ps -q --filter "label=com.docker.compose.project=$T" | xargs -r docker pause >/dev/null; }
           sleep_off()  { docker ps -q --filter "label=com.docker.compose.project=$T" --filter status=paused | xargs -r docker unpause >/dev/null; } ;;
  *) echo "FAIL setup: Betriebsart '$RT' unbekannt"; exit 1 ;;
esac
# Die n8n-Datenbank heisst im Substrat und im Verbund 'n8n' (Installer-Standard).
cfg() { docker exec "$M" lifeagents config "$@" >/dev/null 2>&1; }
# Owner-Sprache und die festen Stuecke eines Katalog-Texts vor dem ersten Platzhalter (der Mock-Log traegt den gesendeten Text).
lang="$(q "SELECT agent.fn_person_lang(NULL)->>'lang'")"
frag() { q "SELECT split_part(text, '{', 1) FROM core.ui_texts WHERE key = '$1' AND lang = '${lang:-de}'"; }
# Gesendete Texte seit Zeile <n> des Mock-Logs (n8n schickt JSON, die CLI Formular-Daten; beides auf Text zurueck).
sent_since() { tgl | tail -n +"$(( $1 + 1 ))" | jqx -r 'select(.method == "sendMessage") | (.body.text? // .body) | tostring' 2>/dev/null; }
log_n() { tgl | wc -l | tr -d ' '; }
# wait_for <sekunden> <sql> <erwartet> — bis die erste Ergebniszeile <erwartet> ist; rc 0 = erreicht.
wait_for() { local _; for _ in $(seq 1 "$1"); do [ "$(q "$2")" = "$3" ] && return 0; sleep 1; done; return 1; }

chat="$(q "SELECT agent.fn_person_chat_id(agent.fn_owner_person_id())")"
[ -n "$chat" ] || { echo "FAIL setup: kein gepaarter Owner"; exit 1; }

# shellcheck disable=SC2329  # aufgerufen ueber trap EXIT
cleanup() {
  sleep_off 2>/dev/null || true
  loop_start 2>/dev/null || true
  for k in loop_s gap_s step_cap_s; do cfg reset watch "$k"; done
  cfg reset general reminders_from; cfg reset general reminders_until
  cfg reset schedule heartbeat_watch
}
trap cleanup EXIT

# Kurze Schwellen: 180 s beobachtet (ein Durchlauf der Docker-Schleife dauert 60 s Pause + Tick, also ueber 60 s), jede
# Minute ein Lauf (step_cap = Takt), Luecken ueber 150 s zaehlen nicht.
if ! { cfg set watch step_cap_s 60 && cfg set watch gap_s 150 && cfg set watch loop_s 180 \
        && cfg set general reminders_from 0 && cfg set general reminders_until 24 \
        && cfg set schedule heartbeat_watch '* * * * *'; }; then echo "FAIL setup: config set"; exit 1; fi
q "DELETE FROM core.notification_state WHERE source = 'heartbeat'" >/dev/null
wait_for 150 "SELECT count(*) FROM core.heartbeats WHERE signal = 'loop' AND beat_at > now() - interval '90 seconds'" 1 \
  || { echo "FAIL setup: die Schleife schreibt kein Lebenszeichen"; exit 1; }

# ---- a) Schleife steht -> Alarm, wieder an -> Entwarnung ----------------------------------------------------------------
key="core.heartbeat.alert.loop.$RT"
n0="$(log_n)"; loop_stop
if wait_for 420 "SELECT alert_stage FROM core.heartbeats WHERE signal = 'loop'" 1; then
  f="$(frag "$key")"
  if [ -n "$f" ] && sent_since "$n0" | grep -qF -- "$f"; then pass "a_alert_$RT"; else fail "a_alert_$RT" "Text '$f' nicht im Mock ($(sent_since "$n0" | tail -n 2 | tr '\n' ' '))"; fi
else fail "a_alert_$RT" "keine Stufe 1 binnen 7 min ($(q "SELECT row_to_json(h) FROM core.heartbeats h WHERE signal = 'loop'"))"; fi
n1="$(log_n)"; loop_start
if wait_for 300 "SELECT alert_stage || '|' || (last_clear_at IS NOT NULL) FROM core.heartbeats WHERE signal = 'loop'" '0|true'; then
  f="$(frag "core.heartbeat.clear.loop.$RT")"
  if [ -n "$f" ] && sent_since "$n1" | grep -qF -- "$f"; then pass "a_clear_$RT"; else fail "a_clear_$RT" "Entwarnung '$f' nicht im Mock"; fi
else fail "a_clear_$RT" "keine Entwarnung binnen 5 min"; fi
# Ursache vor Folge: im Docker-Verbund steht danach kein Merker fuer Pruefung oder Sicherung.
if [ "$RT" = compose ] && [ "$(q "SELECT count(*) FROM core.notification_state WHERE source = 'heartbeat' AND key LIKE ANY (ARRAY['check:%', 'backup:%'])")" != 0 ]; then
  fail a_cause_first "Pruefung/Sicherung als Folge gemeldet"
elif [ "$RT" = compose ]; then pass a_cause_first; fi

# ---- b) Rechner schlaeft laenger als gap_s -> keine Meldung ------------------------------------------------------------
# Flatter-Sperre (24 h nach der Entwarnung) wuerde jede neue Stufe 1 ohnehin zurueckhalten -> vorher aufheben.
q "UPDATE core.heartbeats SET last_clear_at = NULL" >/dev/null
q "DELETE FROM core.notification_state WHERE source = 'heartbeat'" >/dev/null
n2="$(log_n)"; sleep_on; sleep 200; sleep_off
sleep 150
if [ "$(q "SELECT alert_stage FROM core.heartbeats WHERE signal = 'loop'")" = 0 ] && ! sent_since "$n2" | grep -qF -- "$(frag "$key")"; then
  pass "b_sleep_$RT"; else fail "b_sleep_$RT" "Meldung nach Schlaf ($(sent_since "$n2" | tail -n 2 | tr '\n' ' '))"; fi

exit "$fails"
