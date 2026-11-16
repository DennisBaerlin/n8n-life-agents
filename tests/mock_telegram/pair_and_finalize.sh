#!/usr/bin/env bash
# pair_and_finalize.sh — Koppeln des Owners im Docker-Verbund (Schritt des Einrichtungs-Assistenten) und der Abschluss danach,
# gegen den Telegram-Mock (start_in_pod.sh: 127.0.0.1:8089 im Namensraum des Verbunds, Log im <logordner>). Laeuft auf dem
# Rechner (genericity.yml), fasst nur den Verbund <projekt> an. Vorbedingung: Installation mit Token fertig, Mock laeuft.
# Echter Weg: `lifeagents household pair-owner --machine arm|status|finalize` (wie provisioning/wizard/server.js) und ein
# Telegram-Update `/start <Code>` an den ECHTEN Trigger-Webhook des Orchestrators mit der Kopfzeile, die n8n beim Aktivieren
# als secret_token vergibt ({workflowId}_{nodeId}). Nur der Bot (api.telegram.org) ist der Mock.
# Aufruf: bash tests/mock_telegram/pair_and_finalize.sh <projekt> <logordner>   Exit 0 = gekoppelt, Abschluss ok, Begruessung im Mock.
set -euo pipefail
P="${1:?projekt}"
m="$P-master"
CHAT=770000001
TG_LOG="${2:?logordner (wie bei start_in_pod.sh)}/mock_telegram.jsonl"
q() { docker exec "$P-postgres" psql -U postgres -d n8n -tAc "$1" | tr -d '[:space:]'; }
# hand-injected: LIFEAGENTS_TELEGRAM_API zeigt auf den Mock (im Wizard erbt die CLI die Variable aus der Umgebung des master, die compose.yml nicht setzt)
pair() { docker exec -e LIFEAGENTS_TELEGRAM_API=http://127.0.0.1:8089 "$m" lifeagents household pair-owner --machine "$1"; }

arm="$(pair arm)"; printf '%s\n' "$arm" | sed -E 's/start=[A-Za-z0-9_-]+/start=<code>/'
[ "$(jq -r .ok <<<"$arm")" = true ] || { echo "FAIL arm"; exit 1; }
code="$(jq -r .link <<<"$arm" | sed -E 's/.*start=//')"
[ "$(pair status | jq -r .connected)" = false ] || { echo "FAIL schon gekoppelt vor dem Code"; exit 1; }

row="$(q "SELECT w.id||'|'||(n->>'id')||'|'||(n->>'webhookId') FROM public.workflow_entity w, jsonb_array_elements(w.nodes::jsonb) n WHERE w.name='agent.orchestrator.main_route' AND n->>'type'='n8n-nodes-base.telegramTrigger'")"
IFS='|' read -r wf node hook <<<"$row"
[ -n "$hook" ] || { echo "FAIL Telegram-Trigger des Orchestrators nicht gefunden"; exit 1; }
secret="$(printf '%s_%s' "$wf" "$node" | tr -cd 'a-zA-Z0-9_-')"
body="$(jq -nc --arg t "/start $code" --argjson d "$(date +%s)" --argjson c "$CHAT" \
  '{update_id:1, message:{message_id:1, from:{id:$c, is_bot:false, first_name:"Ci", language_code:"de"}, chat:{id:$c, type:"private"}, date:$d, text:$t, entities:[{offset:0, length:6, type:"bot_command"}]}}')"
http="$(docker exec "$m" curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Telegram-Bot-Api-Secret-Token: $secret" -H 'Content-Type: application/json' --data "$body" "http://127.0.0.1:5678/webhook/$hook/webhook")"
[ "$http" = 200 ] || { echo "FAIL Eingang antwortet $http (200)"; exit 1; }
ok=''
for _ in $(seq 1 30); do [ "$(pair status | jq -r .connected)" = true ] && { ok=1; break; }; sleep 3; done
[ -n "$ok" ] || { echo "FAIL Kopplung ueber den Eingang kam nicht an"; tail -n 30 "$TG_LOG"; exit 1; }

# Der Abschluss nach dem Koppeln: Workflows mit der echten chat_id neu einspielen, Menues, Begruessung.
fin="$(pair finalize)"; echo "$fin"
[ "$(jq -r .ok <<<"$fin")" = true ] || { echo "FAIL Abschluss"; exit 1; }
[ "$(jq -r .welcome_sent <<<"$fin")" = true ] || { echo "FAIL Begruessung nicht gesendet"; exit 1; }
grep -h '"method":"sendMessage"' "$TG_LOG" | grep -q "\"chat_id\":$CHAT" \
  || { echo "FAIL Begruessung kam nicht im Mock an"; exit 1; }
# Zweite Meinung der Datenbank: kein Telegram-Knoten traegt mehr die Platzhalter-chat_id 0, die echte steht drin, alles veroeffentlicht.
tg() { q "SELECT count(*) FROM public.workflow_entity w, jsonb_array_elements(w.nodes::jsonb) n WHERE n->>'type'='n8n-nodes-base.telegram' AND n->'parameters'->>'chatId'='$1'"; }
[ "$(tg 0)" = 0 ] || { echo "FAIL Telegram-Knoten mit chat_id 0"; exit 1; }
[ "$(tg "$CHAT")" -gt 0 ] || { echo "FAIL keine Telegram-Knoten mit der echten chat_id"; exit 1; }
[ "$(q "SELECT count(*) FROM public.workflow_entity WHERE \"activeVersionId\" IS NULL")" = 0 ] || { echo "FAIL unveroeffentlichte Workflows"; exit 1; }
docker exec "$m" bash /opt/lifeagents/provisioning/doctor.sh
