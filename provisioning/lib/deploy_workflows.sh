# deploy_workflows.sh — getrackte Workflow-JSONs auf die Instanz bringen (Phase 5: paket-skopiert).
# Sourced by provision.sh + der Runtime-CLI (`lifeagents package`). Definiert deploy_workflows [pkg].
#
# SCOPE (Phase 5): `deploy_workflows core` (Default) deployt die CORE-Workflows = alle, die KEINEM
# Nicht-Core-Paket gehoeren (Orchestrator/monitor/guide + geteilte tool_/sub_-Infra + Harnesses).
# Test-Harnesses (*.test_harness) nur auf Test-Instanzen (TEST_HARNESS_SECRET gesetzt oder Harness-Credential live);
# eine Prod-/Dev-Instanz stagt sie nicht und entfernt vorhandene Live-Kopien (retire_stale).
# `deploy_workflows <pkg>` deployt NUR die Workflows DIESES Pakets (Wortgrenze-Prefix aus provides.agents,
# wie pkg_teardown — symmetrisch zum Uninstall). Jedes Paket haelt seine Workflows unter
# packages/<pkg>/workflows -> Scope ueber den NAMEN, nicht das Verzeichnis.
#
# WARUM CLI-Import statt REST-POST: `n8n import:workflow` BEHAELT die ids aus dem JSON (ids = Import-Keys),
# REST-POST vergibt neue -> das dichte executeWorkflow-Referenznetz (Orchestrator->Agenten->Tools->Gate,
# errorWorkflow, load_context/load_config) bliebe zerrissen. CLI-Import = ids stabil.
#
# CREDENTIAL-REMAP per NAME-Aufloesung (Phase 5, D2): inject_credentials setzt die Creds id-STABIL
# (import:credentials-Upsert, stabile id); HIER loesen wir jeden im Workflow gefundenen `__CRED_*__`-
# Platzhalter ueber die Platzhalter<->Name-Map (inject_credentials.sh) gegen die LIVE-n8n-Credential-Liste
# (GET, name+type) auf. Robust fuer Provision-Zeit UND Standalone-CLI. Kein Remap-File-Handoff.
#
# KEIN Deploy-Restart: seit die Credential-id stabil ist (kein DELETE), referenziert ein laufender
# In-Memory-Trigger nie eine geloeschte id -> der Geister-Cron (WS-B4b, #21770) kann strukturell nicht
# entstehen. Und ein geaenderter Ausloeser (z. B. ein neuer Zeitplan) laeuft nicht doppelt, weil jeder aktive
# Workflow mit eigenem Ausloeser VOR dem Import per REST deaktiviert wird (_deactivate_live_triggers). (Der
# Paket-UNINSTALL-Restart in pkg_teardown.sh BLEIBT — echte Workflow-Loeschung = andere Ursache.)
#
# NUR GEAENDERTE: `import:workflow` vergibt JEDEM importierten Workflow eine neue versionId, setzt ihn unpublished
# und meldet einen Telegram-Trigger ab (deleteWebhook) — auch bei identischem Inhalt (n8n 2.44.4 import.service).
# Darum merkt sich der Server je Workflow einen Fingerabdruck (sha256 der fertig gepatchten Datei + Deploy-Kontext:
# n8n-Version, WEBHOOK_URL, sha256 des Bot-Tokens) und die versionId nach dem Einspielen (WF_DEPLOY_STATE_FILE).
# Eingespielt wird nur, was neu/geaendert ist, live fehlt oder live eine andere versionId traegt (am Server
# veraendert, DB zurueckgespielt); unveraendert + unpublished -> nur publish; unveraendert + published -> nichts.
# Ausnahme Telegram-Trigger: immer ab- und wieder anmelden (der Installer loescht den Bot-Webhook bei jedem Lauf).
# Ein Bot-/Adress-/Versionswechsel aendert den Kontext -> alles neu (Telegram registriert die Adresse neu).
# Jeder Zweifel (Live-Liste nicht abrufbar, LIFEAGENTS_DEPLOY_FULL=1) = der fruehere Weg: alles einspielen.
#
# ZEITPLAENE: die Workflows tragen statt eines Cron-Ausdrucks den Platzhalter `__CFG_SCHEDULE_<KEY>__`
# (Build-ScheduleTrigger); der Wert kommt beim Einspielen aus core.config (category 'schedule') — ein per
# `lifeagents config set` geaenderter Zeitplan ueberlebt so jedes Update. Bleibt ein Platzhalter ohne Wert, bricht
# der Deploy mit Klartext ab (nie ein Platzhalter als Cron).
#
# Reads globals: REPO_ROOT, N8N_URL, N8N_API_KEY, N8N_USER, N8N_ENV_FILE, N8N_DB_NAME, OWNER_CHAT_ID (opt).
# Reuses (sourced siblings): _list_existing_creds/_cred_host_placeholder_names/_cred_pkg_placeholder_names
#   (inject_credentials.sh).

DB_SUPERUSER="${DB_SUPERUSER:-postgres}"

# _owner_chat_id_db — Owner-chat_id NUR aus der DB (family-Facts role=owner.telegram_user_id; leer =
#   noch nicht gepairt). Das Pairing-Warten (owner_connect.sh) braucht genau dieses Praedikat OHNE den
#   OWNER_CHAT_ID-Env-Fallback — ein gesetzter Env-Wert (Substrat/Dev) taeuschte sonst sofort Erfolg vor.
_owner_chat_id_db() {
  local v=''
  if need_cmd runuser && [ -n "${N8N_DB_NAME:-}" ]; then
    v="$(runuser -u "$DB_SUPERUSER" -- psql -tA -X -v ON_ERROR_STOP=1 -d "$N8N_DB_NAME" -c \
      "SELECT pp->>'telegram_user_id' FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons','[]'::jsonb)) pp WHERE c.name='family' AND pp->>'role'='owner' AND jsonb_typeof(pp->'telegram_user_id') <> 'null' LIMIT 1;" \
      2>/dev/null | head -n1 || true)"
  fi
  # Nur reine Ziffern (Telegram-uid): der Wert landet in einem root-sed-Ausdruck (deploy_workflows) — ein anderer
  # DB-Inhalt wird verworfen statt ausgefuehrt (Security-Audit 2026-10).
  if [ -n "$v" ] && ! printf '%s' "$v" | grep -qE '^[0-9]+$'; then
    warn "Owner-chat_id in der DB ist keine Zahl — ignoriert (family-Facts pruefen)."
    v=''
  fi
  printf '%s' "$v"
}

# activate_inactive_workflows — nach dem Bundle-Loop (provision.sh): Workflows, deren Aktivierung im
#   Core-Pass an n8ns Sub-Workflow-Validierung scheiterte, jetzt nachaktivieren (Fixpunkt). Real getroffen
#   (Install-UX-Phase 3, Substrat-Journal "Workflow activation failed sub-workflow validation"): der
#   Orchestrator ruft Paket-Agenten, die erst NACH `deploy_workflows core` importiert werden -> er blieb
#   inaktiv, bis ein spaeteres `lifeagents update` den Core erneut deployte (Bot taub nach Erstinstall).
#   Non-fatal; was dann noch inaktiv ist (Telegram-Trigger ohne erreichbare Domain), holt das gefuehrte
#   Ende bzw. `lifeagents household pair-owner` nach — fehlt die Adresse ganz, `lifeagents reconfigure`.
activate_inactive_workflows() {
  local ids id n=0 progressed
  local -a pending next
  ids="$(n8n_api_curl "$N8N_API_KEY" "$N8N_URL/api/v1/workflows?active=false&limit=250" -fsS 2>/dev/null \
           | jq -r '.data[]?.id' 2>/dev/null || true)"
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2206  # bewusstes Wort-Splitting: n8n-ids sind [A-Za-z0-9]
  pending=($ids)
  while [ "${#pending[@]}" -gt 0 ]; do
    next=(); progressed=0
    for id in "${pending[@]}"; do
      if n8n_set_published publish "$id" -fsS -o /dev/null 2>/dev/null; then
        n=$((n + 1)); progressed=1
      else next+=("$id"); fi
    done
    pending=("${next[@]}")
    [ "$progressed" -eq 1 ] || break
  done
  if [ "$n" -gt 0 ]; then ok "${n} Workflow(s) nachaktiviert (ihre Sub-Workflows sind jetzt vorhanden)."; fi
  if [ "${#pending[@]}" -gt 0 ]; then
    note "${#pending[@]} Workflow(s) weiterhin inaktiv: ${pending[*]} (Telegram-Trigger ohne erreichbare Internet-Adresse — das Pairing am Ende bzw. 'lifeagents household pair-owner' holt es nach; fehlt die Adresse ganz: 'lifeagents reconfigure')."
  fi
  return 0
}

# _resolve_owner_chat_id  — reale Owner-chat_id (DB nach dem Pairing, sonst OWNER_CHAT_ID-env, sonst '0').
_resolve_owner_chat_id() {
  local v
  v="$(_owner_chat_id_db)"
  [ -n "$v" ] || v="${OWNER_CHAT_ID:-}"
  printf '%s' "$v" | grep -qE '^[0-9]+$' || v='0'
  printf '%s' "$v"
}

# _ingress_id_map <workflow.json> <key> -> JSON-Objekt {Repo-id: Instanz-id} fuer id + webhookId jedes telegramTrigger.
_ingress_id_map() {
  local f="$1" key="$2" v
  jq -r '.nodes[]? | select(.type == "n8n-nodes-base.telegramTrigger") | .id, (.webhookId // empty)' "$f" \
    | while IFS= read -r v; do
        [ -n "$v" ] && printf '%s\t%s\n' "$v" "$(_ingress_uuid "$key" "$v")"
      done \
    | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}'
}

# (Der gegatete Deploy-Restart + seine Helfer _list_active_workflow_ids/_deploy_wait_health sind ENTFERNT:
#  seit inject_credentials id-STABIL upsertet [import:credentials, kein DELETE], referenziert ein laufender
#  In-Memory-Trigger nie eine geloeschte Credential-id → der Geister-Cron kann strukturell nicht entstehen,
#  der Restart-Workaround ist gegenstandslos. Der Paket-UNINSTALL-Restart in pkg_teardown.sh BLEIBT — dort
#  werden Workflows wirklich geloescht [echte In-Memory-Waise, #21770], ein anderer Kausalpfad.)

# _WF_OWN_TRIGGER_JQ — jq-Funktion `own_trigger`: hat der Workflow einen EIGENEN Ausloeser, den n8n beim Aktivieren
#   im laufenden Prozess registriert (Cron/Webhook/Telegram/Error-Trigger)? executeWorkflowTrigger zaehlt nicht
#   (reiner Sub-Workflow-Eingang). Geteilt von retire_workflows (Neustart noetig?) und _deactivate_live_triggers.
_WF_OWN_TRIGGER_JQ='def own_trigger: [.nodes[]?.type | select((test("Trigger$") and (. != "n8n-nodes-base.executeWorkflowTrigger")) or . == "n8n-nodes-base.webhook")] | length > 0;'

# _schedule_placeholder_map — {"__CFG_SCHEDULE_<KEY>__": "<cron>", …} aus core.config (category 'schedule'; die DB
#   nimmt dort nur gueltige Crons an, trg_config_check_value_type). Leer bei DB-Fehler -> der Rest-Platzhalter-Check
#   in deploy_workflows bricht dann mit Klartext ab.
_schedule_placeholder_map() {
  [ -n "${N8N_DB_NAME:-}" ] || return 0
  runuser -u "$DB_SUPERUSER" -- psql -tA -X -v ON_ERROR_STOP=1 -d "$N8N_DB_NAME" -c \
    "SELECT COALESCE(jsonb_object_agg('__CFG_SCHEDULE_' || upper(key) || '__', value), '{}'::jsonb) FROM core.config WHERE category = 'schedule';" \
    2>/dev/null | head -n1 || true
}

# _hitl_chat_approval <scope> — "true"/"false" fuer den Platzhalter __HITL_CHAT_APPROVAL__ (Telegram-Node chatApproval
#   in New-TelegramSendAndWaitNode): true = Bestaetigungs-Knoepfe antworten im Chat (callback_data, kein Browser). NUR,
#   wenn der Server seinen eigenen /webhook-waiting-telegram ueber die n8n-WEBHOOK_URL erreicht (hitl_chat_reachable,
#   pinnt bei Bedarf /etc/hosts) — sonst verschluckte n8n jeden Tipp still. Sonst false = Link-Knoepfe ueber
#   /webhook-waiting/* wie bisher (kein Update verschlechtert eine laufende Installation). Entschieden wird NUR beim
#   Core-Deploy (Installation/update/reconfigure) und in core.env HITL_CHAT_APPROVAL festgehalten; Paket-Deploys
#   (package install, config set schedule) uebernehmen diesen Wert -> alle Workflows im selben Modus, doctor liest ihn.
#   LIFEAGENTS_HITL_CHAT_APPROVAL=true|false erzwingt den Wert (NUR Test-Substrat, bootstrap_test_n8n -HitlChatApproval;
#   dort gibt es keinen /etc/hosts-Pin, darum raeumt dieser Zweig bewusst nichts auf).
_hitl_chat_approval() {
  local scope="${1:-core}" envf; envf="$(lifeagents_env_file core)"
  if [ -z "${_HITL_CHAT_APPROVAL_VAL:-}" ] && [ "$scope" != core ] && [ -z "${LIFEAGENTS_HITL_CHAT_APPROVAL:-}" ]; then
    case "$(hitl_chat_state)" in true|false) _HITL_CHAT_APPROVAL_VAL="$(hitl_chat_state)" ;; esac
  fi
  if [ -z "${_HITL_CHAT_APPROVAL_VAL:-}" ]; then
    case "${LIFEAGENTS_HITL_CHAT_APPROVAL:-}" in
      true|false) _HITL_CHAT_APPROVAL_VAL="$LIFEAGENTS_HITL_CHAT_APPROVAL" ;;
      *)
        local wh; wh="$(read_env_value "$N8N_ENV_FILE" WEBHOOK_URL 2>/dev/null || true)"
        [ -n "${TRUSTED_PROXIES:-}" ] || TRUSTED_PROXIES="$(read_env_value "$(lifeagents_env_file core)" TRUSTED_PROXIES 2>/dev/null || true)"
        _HITL_CHAT_APPROVAL_VAL=false
        if [ -n "$wh" ] && [ "$wh" != "https://example.com/" ]; then   # example.com = Dev-Platzhalter (provision.sh)
          if hitl_chat_reachable "$wh"; then _HITL_CHAT_APPROVAL_VAL=true
          else
            warn "Bestätigen im Chat bleibt AUS: ${wh%/}${HITL_ROUTE_SUFFIX} erreicht n8n nicht. Ergänze im Reverse Proxy die Weiterleitung von ${HITL_ROUTE_SUFFIX} (wie /webhook-waiting/*) und führe danach 'lifeagents update' erneut aus. Bis dahin öffnen die Bestätigungs-Knöpfe eine Webseite."
          fi
        else
          hosts_pin_prune ''   # keine echte Domain (mehr) -> ein Pin einer frueheren Adresse ist nur noch Drift
        fi ;;
    esac
    [ "$_HITL_CHAT_APPROVAL_VAL" = true ] && log "Bestätigen im Chat: an (Knöpfe antworten über Telegram)."
    # Festhalten NUR beim Core-Deploy (er spielt das HITL-Gate ein); ein Paket-Deploy ohne Eintrag probt nur fuer sich.
    if [ "$scope" = core ] && [ -d "$(dirname "$envf")" ] && [ "$(hitl_chat_state)" != "$_HITL_CHAT_APPROVAL_VAL" ]; then
      env_upsert "$envf" HITL_CHAT_APPROVAL "$_HITL_CHAT_APPROVAL_VAL"
    fi
  fi
  printf '%s' "$_HITL_CHAT_APPROVAL_VAL"
}

# _deactivate_live_triggers <id…> — VOR dem Import: jeden Workflow des Deploy-Sets, der live AKTIV ist und einen
#   eigenen Ausloeser hat, per REST deaktivieren. WARUM: `n8n import:workflow` laeuft in einem eigenen Prozess und
#   meldet den im laufenden n8n registrierten Ausloeser NICHT ab; das Aktivieren danach registriert den neuen
#   zusaetzlich -> ein geaenderter Zeitplan liefe bis zum naechsten n8n-Neustart DOPPELT (alt + neu; belegt an n8n 2.21.7, auf 2.44.4 beibehalten —
#   import.service/workflow.service.activateWorkflow/scheduled-task-manager). Das REST-Deaktivieren laeuft IM
#   n8n-Prozess und meldet den Ausloeser dort ab. Telegram-Trigger: Deaktivieren loescht den Webhook, das Aktivieren
#   danach setzt ihn neu; Nachrichten dazwischen haelt Telegram vor (setWebhook ohne drop_pending_updates).
#   Ergebnis: _DEPLOY_DEACTIVATED (ids, fuer die Wieder-Aktivierung bei Import-Fehler) + _DEPLOY_DEACT_FAILED
#   (Anzahl; > 0 -> deploy_workflows startet n8n am Ende einmal neu = der fruehere, immer korrekte Weg).
_deactivate_live_triggers() {
  _DEPLOY_DEACTIVATED=(); _DEPLOY_DEACT_FAILED=0
  local live id w want
  if ! live="$(_wf_live_pages 'active=true' "${_WF_OWN_TRIGGER_JQ} (.data // [])[] | select(own_trigger) | .id")"; then
    warn "Aktive Workflows nicht abrufbar -> alte Ausloeser werden erst mit einem n8n-Neustart abgemeldet (folgt am Ende)."
    _DEPLOY_DEACT_FAILED=1
    return 0
  fi
  for id in $live; do
    want=0
    for w in "$@"; do if [ "$w" = "$id" ]; then want=1; break; fi; done
    [ "$want" -eq 1 ] || continue
    if n8n_set_published unpublish "$id" -fsS -o /dev/null 2>/dev/null; then
      _DEPLOY_DEACTIVATED+=("$id")
    else
      _DEPLOY_DEACT_FAILED=$((_DEPLOY_DEACT_FAILED + 1))
      warn "Workflow $id liess sich nicht deaktivieren -> n8n wird am Ende einmal neu gestartet (sonst liefe sein alter Ausloeser weiter)."
    fi
  done
  return 0
}

# --- NUR GEAENDERTE (s. Kopf) ---------------------------------------------------------------------------------------
# Zustand: je Workflow eine Zeile <id>\t<fingerprint>\t<versionId>; neben dem upgrade_guard-Marker (/var/lib/lifeagents).
# Eine fehlende/kaputte Datei heisst nur "alles einspielen" (sicher).
WF_DEPLOY_STATE_FILE="${WF_DEPLOY_STATE_FILE:-/var/lib/lifeagents/workflow_deploy.state}"

# _wf_deploy_context — der Teil des Fingerabdrucks, der nicht in der Datei steht, aber eine Neu-Registrierung
#   braucht: n8n-Version (package.json neben dem Binary, sonst der Pin N8N_VERSION; kein CLI-Start), WEBHOOK_URL,
#   sha256 des Bot-Tokens (owner_tg_token = die eine Token-Quelle).
_wf_deploy_context() {
  local bin ver='' wh
  bin="$(command -v n8n 2>/dev/null || true)"
  [ -z "$bin" ] || ver="$(jq -r '.version // empty' "$(dirname "$(dirname "$(readlink -f "$bin")")")/package.json" 2>/dev/null || true)"
  [ -n "$ver" ] || ver="${N8N_VERSION:-}"
  wh="$(read_env_value "$N8N_ENV_FILE" WEBHOOK_URL 2>/dev/null || true)"
  printf 'n8n=%s|webhook=%s|bot=%s' "$ver" "$wh" "$(owner_tg_token | sha256sum | cut -c1-64)"
}

# _wf_live_pages <query> <jq-filter> — GET /workflows?<query> ueber ALLE Seiten (limit <= 250, nextCursor), jede Seite
#   durch <jq-filter> (auf das Seiten-Objekt). rc1 bei jedem Fehler.
_wf_live_pages() {
  local query="$1" filter="$2" cursor='' page
  while :; do
    page="$(n8n_api_curl "$N8N_API_KEY" "$N8N_URL/api/v1/workflows?${query}&limit=250${cursor:+&cursor=$cursor}" -fsS 2>/dev/null)" || return 1
    printf '%s' "$page" | jq -r "$filter" 2>/dev/null || return 1
    cursor="$(printf '%s' "$page" | jq -r '.nextCursor // empty | @uri' 2>/dev/null)" || return 1
    [ -n "$cursor" ] || return 0
  done
}

# _wf_live_versions — alle Live-Workflows als <id>|<versionId>|<activeVersionId> (leer = nicht published). '|' statt
#   Tab: read faltet aufeinanderfolgende Tabs (IFS-Whitespace) -> ein leeres Mittelfeld verschoebe die Spalten.
_wf_live_versions() {
  _wf_live_pages 'excludePinnedData=true' '.data[] | [.id, (.versionId // ""), (.activeVersionId // "")] | join("|")'
}

# _wf_state_commit <tsv-datei> — die Zeilen der Datei (<id>\t<fp>\t<versionId>) in den Zustand uebernehmen: direkt vor
#   dem Schreiben neu lesen, nur diese ids ersetzen (andere Scopes bleiben), atomar per mktemp + mv. Nie fatal.
_wf_state_commit() {
  local upd="$1" dir tmp
  [ -s "$upd" ] || return 0
  dir="$(dirname "$WF_DEPLOY_STATE_FILE")"
  if ! { mkdir -p "$dir" && chmod 0700 "$dir"; } 2>/dev/null; then
    warn "Deploy-Zustand nicht schreibbar ($dir) -> naechstes Update spielt alles ein."; return 0
  fi
  tmp="$(mktemp "$dir/.workflow_deploy.XXXXXX" 2>/dev/null)" || { warn "Deploy-Zustand nicht schreibbar ($dir)."; return 0; }
  if { if [ -r "$WF_DEPLOY_STATE_FILE" ]; then awk -F'\t' 'NR==FNR {skip[$1]=1; next} NF==3 && !($1 in skip)' "$upd" "$WF_DEPLOY_STATE_FILE"; fi
       cat "$upd"; } > "$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$WF_DEPLOY_STATE_FILE"; then
    return 0
  fi
  rm -f "$tmp"; warn "Deploy-Zustand nicht geschrieben -> naechstes Update spielt die betroffenen Workflows erneut ein."
  return 0
}

# _reactivate_ids <id…> — best effort (Import gescheitert): die eben deaktivierten Workflows mit ihrem ALTEN Stand
#   wieder einschalten, damit ein abgebrochener Deploy keine Zeitplaene/den Bot stilllegt.
_reactivate_ids() {
  local id
  for id in "$@"; do
    n8n_set_published publish "$id" -fsS -o /dev/null 2>/dev/null || warn "Workflow $id bleibt inaktiv — 'lifeagents update' holt es nach."
  done
}

# _wf_pkg_agents <pkg>  -> provides.agents als CSV aus dem Manifest PLUS der Paketname selbst als
#   Praefix-Kandidat: die Pipeline-/Tool-/Cron-Workflows eines Pakets tragen den Scope agent.<pkg>.*
#   (z. B. agent.career.cron_score_jobs), NICHT den Agent-Namen agent.<pkg>_advisor — ohne den
#   Kandidaten fielen sie in den Core-Sweep (falsche Credential-Remap-Scope) bzw. blieben beim
#   Uninstall als Waisen (paperless-WS-0 Naht 5, heilt career gleich mit; volle Paritaet zur
#   build-seitigen Get-WorkflowHomeMap-Regel — segment-genau via _wf_name_matches inkl. '_'-Suffix).
_wf_pkg_agents() {
  local mf; mf="$REPO_ROOT/packages/$1/manifest.json"
  [ -r "$mf" ] || return 0
  jq -r --arg pkg "$1" '([$pkg] + [(.provides.agents // [])[] | if type=="object" then .name else . end]) | unique | join(",")' "$mf" 2>/dev/null || true
}

# _wf_name_matches <name> <agents_csv>  -> 0 wenn name == 'agent.<a>' ODER startswith 'agent.<a>.'
#   ODER startswith 'agent.<a>_' (segment-genaue Wortgrenzen — volle Paritaet zur build-seitigen
#   Get-WorkflowHomeDir-Regel: ein Paket beansprucht agent.<pkg> exakt, mit '.'- UND '_'-Suffix).
_wf_name_matches() {
  local name="$1" csv="$2" a oldifs="$IFS"
  IFS=','
  # shellcheck disable=SC2086  # bewusstes Wort-Splitting (Agent-Namen [a-z0-9_], kein Globbing)
  for a in $csv; do
    [ -n "$a" ] || continue
    if [ "$name" = "agent.$a" ] || [ "${name#agent."$a".}" != "$name" ] || [ "${name#agent."$a"_}" != "$name" ]; then IFS="$oldifs"; return 0; fi
  done
  IFS="$oldifs"; return 1
}

# _wf_noncore_agents  -> CSV ALLER provides.agents + Paketnamen der Nicht-Core-Pakete (zum Aussondern
#   beim Core-Deploy; symmetrisch zu _wf_pkg_agents — sonst zoege der Core-Sweep agent.<pkg>.*-Workflows).
_wf_noncore_agents() {
  local mf pkg out=""
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -r "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)" || continue
    [ -n "$pkg" ] && [ "$pkg" != core ] || continue
    out="${out:+$out,}$(_wf_pkg_agents "$pkg")"
  done
  printf '%s' "$out"
}

# _build_cred_remap <scope>  -> jq-Objekt {placeholder: live-id} per NAME-Aufloesung gegen die Live-Cred-Liste.
#   scope='core' -> nur Host-Platzhalter; scope='<pkg>' -> Host + die 2 Paket-Platzhalter. Unreferenzierte
#   Platzhalter schaden nicht (jq-walk ersetzt nur vorhandene). Fehlt eine Cred live -> Platzhalter bleibt
#   (dangling Ref; warn). _EXISTING_CREDS_JSON wurde vom Aufrufer via _list_existing_creds geladen.
_build_cred_remap() {
  local scope="$1" ph name typ id obj='{}'
  # Prozess-Substitution (kein Pipe) -> die while-Schleife laeuft in DIESER Shell, obj bleibt erhalten.
  while IFS=$'\t' read -r ph name typ; do
    [ -n "$ph" ] || continue
    id="$(printf '%s' "$_EXISTING_CREDS_JSON" | jq -r --arg n "$name" --arg t "$typ" 'map(select(.name==$n and .type==$t)) | (.[0].id // empty)' 2>/dev/null)"
    [ -n "$id" ] && obj="$(jq -cn --argjson o "$obj" --arg p "$ph" --arg i "$id" '$o + {($p): $i}')"
  done < <(_cred_host_placeholder_names; [ "$scope" != core ] && _cred_pkg_placeholder_names "$scope")
  printf '%s' "$obj"
}

# retire_workflows <scope> [staging-ids...]  — stillgelegte Workflows des Scopes von der Instanz entfernen.
#   Quelle: der Manifest-Block `retired_workflows.list: [{id, name, since}]` des BESITZENDEN Pakets (explizite
#   Tombstones, dpkg-`rm_conffile`-Analogon — KEIN mengen-basiertes Prune: n8n-Workflows tragen kein
#   Ownership-Label, ein Prune ueber Namens-Praefixe waere heuristisch; arch-challenge D6).
#   Je Eintrag: GET /workflows/{id} -> 404 = schon weg (ok); Name != Tombstone-Name -> warn + NICHT loeschen
#   (fremde/neu vergebene id); eine id aus dem aktuellen Deploy-Set wird nie geloescht. Laeuft NACH dem
#   Import: der Import ersetzt jeden Aufrufer id-erhaltend in place, danach verweist kein getrackter
#   Workflow mehr auf eine retired id (contract_lint) -> das Loeschen kann keinen laufenden Pfad brechen.
#   Hatte ein geloeschter Workflow einen eigenen aktiven Ausloeser (Cron/Webhook/Telegram/Error-Trigger),
#   setzt es _RETIRE_NEEDS_RESTART — retire_stale startet n8n danach EINMAL neu (single-main raeumt In-Memory-
#   Trigger nur per Neustart, #21770 — Muster pkg_teardown). Non-fatal: Fehler werden nur gewarnt, nie per `die` abgebrochen.
retire_workflows() {
  local scope="$1"; shift
  local mf="$REPO_ROOT/packages/$scope/manifest.json"
  [ -r "$mf" ] || return 0
  local entries; entries="$(jq -r '(.retired_workflows.list // [])[] | [.id, .name] | @tsv' "$mf" 2>/dev/null || true)"
  _retire_workflow_entries "$scope" retired_workflows "$entries" "$@"
}

# _retire_workflow_entries <scope> <label> <entries-tsv: id<TAB>name je Zeile> [staging-ids...]  — die EINE
#   Loesch-Schleife mit den Schutzregeln von retire_workflows (id aus dem Deploy-Set nie, abweichender Live-Name nie,
#   404 = schon weg, eigener aktiver Ausloeser -> _RETIRE_NEEDS_RESTART). Konsumenten: retire_workflows (Manifest-
#   Tombstones) und retire_stale (Test-Harnesses, die eine Prod-Instanz nicht deployt, s. deploy_workflows).
_retire_workflow_entries() {
  local scope="$1" label="$2" entries="$3"; shift 3
  [ -n "$entries" ] || return 0
  local id name wf live_name had_trigger n_del=0 need_restart=0 s skip
  while IFS=$'\t' read -r id name; do
    [ -n "$id" ] || continue
    skip=0
    for s in "$@"; do [ "$s" = "$id" ] && skip=1; done
    if [ "$skip" -eq 1 ]; then warn "$label: $id ($name) ist Teil des aktuellen Deploys -> nicht geloescht (Manifest pruefen)."; continue; fi
    wf="$(n8n_api_curl "$N8N_API_KEY" "$N8N_URL/api/v1/workflows/$id" -sS -w '\n%{http_code}' 2>/dev/null || true)"
    case "$(printf '%s' "$wf" | tail -n1)" in
      404) continue ;;                       # schon weg (frische Instanz / frueherer Lauf)
      200) ;;
      *) warn "$label: GET $id fehlgeschlagen -> uebersprungen (naechster Lauf holt es nach)."; continue ;;
    esac
    wf="$(printf '%s' "$wf" | sed '$d')"
    live_name="$(printf '%s' "$wf" | jq -r '.name // empty' 2>/dev/null)" || live_name=""
    if [ "$live_name" != "$name" ]; then
      warn "$label: $id heisst live '$live_name' statt '$name' -> NICHT geloescht."
      continue
    fi
    had_trigger="$(printf '%s' "$wf" | jq -r "${_WF_OWN_TRIGGER_JQ} (.active // false) and own_trigger" 2>/dev/null || echo false)"
    if n8n_delete_workflow "$id"; then
      n_del=$((n_del + 1))
      [ "$had_trigger" = "true" ] && need_restart=1
      ok "Workflow entfernt ($label): $name ($id)."
    else
      warn "$label: DELETE $id ($name) fehlgeschlagen -> naechster Lauf versucht es erneut."
    fi
  done <<< "$entries"
  [ "$need_restart" -eq 1 ] && _RETIRE_NEEDS_RESTART=1   # Neustart macht retire_stale EINMAL am Ende
  [ "$n_del" -eq 0 ] || log "Scope '$scope': $n_del Workflow(s) entfernt ($label)."
  return 0
}

# retire_credentials <scope>  — stillgelegte n8n-Credentials des Scopes entfernen (Manifest-Block
#   `retired_credentials.list[{name, type, env_keys[], since}]`, docs/package-contract.md §2 — Geschwister von
#   retired_workflows, dpkg-rm_conffile-Analog). Laeuft NACH retire_workflows (die stillgelegten Workflows
#   referenzierten diese Credentials). Geloescht wird NUR bei gleichem Name UND Typ (eine gleichnamige fremde
#   Credential bleibt, warn); nicht vorhanden/404 = schon weg. Danach verschwinden GENAU die gelisteten env_keys
#   aus /etc/lifeagents/<scope>.env (kein Secret als Leiche, z. B. ein Service-Account-PEM). Nie abbrechend:
#   jeder Fehler = warn, der naechste Deploy versucht es erneut (idempotent).
retire_credentials() {
  local scope="$1"
  local mf="$REPO_ROOT/packages/$scope/manifest.json"
  [ -r "$mf" ] || return 0
  local entries; entries="$(jq -r '(.retired_credentials.list // [])[] | [.name, .type, ((.env_keys // []) | join(" "))] | @tsv' "$mf" 2>/dev/null || true)"
  [ -n "$entries" ] || return 0
  local creds envf name type keys cid cname ctype k n_del=0
  if ! creds="$(n8n_list_credentials)"; then
    warn "retired_credentials: GET /credentials fehlgeschlagen -> uebersprungen (naechster Lauf holt es nach)."
    return 0
  fi
  envf="$(lifeagents_env_file "$scope")"
  while IFS=$'\t' read -r name type keys; do
    [ -n "$name" ] || continue
    while IFS=$'\t' read -r cid cname ctype; do
      [ -n "$cid" ] && [ "$cname" = "$name" ] || continue
      if [ "$ctype" != "$type" ]; then
        warn "retired_credentials: '$name' ($cid) hat Typ '$ctype' statt '$type' -> NICHT geloescht."
        continue
      fi
      if n8n_delete_credential "$cid"; then
        n_del=$((n_del + 1)); ok "Stillgelegte Credential entfernt: $name ($cid)."
      else
        warn "retired_credentials: DELETE $cid ($name) fehlgeschlagen -> naechster Lauf versucht es erneut."
      fi
    done <<< "$creds"
    for k in $keys; do
      if env_has_key "$envf" "$k"; then env_remove_key "$envf" "$k"; log "Stillgelegter Schluessel $k aus $(basename "$envf") entfernt."; fi
    done
  done <<< "$entries"
  [ "$n_del" -eq 0 ] || log "Scope '$scope': $n_del stillgelegte Credential(s) entfernt."
  return 0
}

# retire_stale <scope> [staging-ids...]  — EIN Einstieg fuer die Stilllegung: Workflows, dann Credentials, dann
#   hoechstens EIN n8n-Neustart ZULETZT. Der Neustart darf nicht zwischen den Schritten liegen: /healthz meldet
#   gesund, bevor die REST-API antwortet (live im Substrat: GET /credentials scheiterte direkt nach dem Neustart).
#   Auch der Deploy-Fall "ein laufender Ausloeser liess sich vor dem Import nicht abmelden" (_DEPLOY_DEACT_FAILED,
#   _deactivate_live_triggers) laeuft ueber DIESEN einen Neustart-Weg.
#   Test-Harnesses, die deploy_workflows auf einer Prod-Instanz herausgefiltert hat (_DEPLOY_HARNESS_RETIRE), raeumt
#   derselbe Schritt mit denselben Schutzregeln ab.
retire_stale() {
  _RETIRE_NEEDS_RESTART=0
  if [ "${_DEPLOY_DEACT_FAILED:-0}" -gt 0 ]; then _RETIRE_NEEDS_RESTART=1; fi
  retire_workflows "$@"
  _retire_workflow_entries "$1" test_harness "${_DEPLOY_HARNESS_RETIRE:-}" "${@:2}"
  retire_credentials "$1"
  if [ "$_RETIRE_NEEDS_RESTART" -eq 1 ]; then
    log "Alte In-Memory-Ausloeser (entfernter Workflow oder nicht abgemeldeter Zeitplan) -> n8n einmal neu starten (#21770) ..."
    enable_start_unit n8n 0
    if wait_n8n_health; then ok "n8n neu gestartet."; else warn "n8n /healthz antwortet noch nicht — doctor.sh prueft erneut."; fi
  fi
  return 0
}

# deploy_workflows [scope]  — scope='core' (Default) | '<pkg>'. Deployt die Workflows des Scopes.
deploy_workflows() {
  local scope="${1:-core}"
  _DEPLOY_DEACTIVATED=(); _DEPLOY_DEACT_FAILED=0; _DEPLOY_HARNESS_RETIRE=''   # kein Rest eines frueheren Aufrufs (retire_stale liest es)
  [ -n "${N8N_API_KEY:-}" ] || die "N8N_API_KEY nicht gesetzt (Owner-Bootstrap)."
  require_cmd jq; require_cmd curl; require_cmd runuser
  local n8n_bin; n8n_bin="$(command -v n8n || true)"
  [ -n "$n8n_bin" ] || die "n8n-Binary nicht im PATH (install_n8n muss vorher laufen)."

  # Scope-Praedikat aufbauen: package -> dessen agents; core -> alles NICHT-Nicht-Core.
  local incl_agents="" excl_agents=""
  if [ "$scope" = core ]; then excl_agents="$(_wf_noncore_agents)"
  else
    incl_agents="$(_wf_pkg_agents "$scope")"
    # Agent-loses Paket (WS-0 Scaffold, z. B. career): nichts zu deployen -> sauberer No-op (frueher: die).
    # So konvergiert pkg_install_one Stage 6 -> 7 (active) auch fuer ein Paket ohne provides.agents.
    if [ -z "$incl_agents" ]; then
      log "Paket '$scope': keine provides.agents -> Workflow-Deploy uebersprungen."
      retire_stale "$scope"
      return 0
    fi
  fi

  # Quell-Verzeichnisse: packages/*/workflows (jedes Paket besitzt seine Workflows).
  local wf_dirs=() d
  for d in "$REPO_ROOT"/packages/*/workflows; do [ -d "$d" ] && wf_dirs+=("$d"); done
  [ "${#wf_dirs[@]}" -gt 0 ] || die "Keine Workflow-Verzeichnisse."

  # Live-Cred-Liste laden + Remap (NAME-Aufloesung) bauen. _list_existing_creds ist seit dem id-stabilen
  # inject fail-closed (rc1 bei GET-Fehlschlag); deploy bleibt bewusst MILD (leere Liste -> Remap ggf.
  # unvollstaendig -> unaufgeloeste Platzhalter werden nur gewarnt, kein Abbruch — anders als inject, das
  # abbricht, weil es sonst blind IDs generieren wuerde).
  local creds_ok=1
  _EXISTING_CREDS_JSON="$(_list_existing_creds)" || { warn "GET /credentials fehlgeschlagen -> Remap ggf. unvollstaendig."; _EXISTING_CREDS_JSON='[]'; creds_ok=0; }
  local remap_json; remap_json="$(_build_cred_remap "$scope")"
  # Test-Harnesses (*.test_harness) nur auf Test-Instanzen: Marker = TEST_HARNESS_SECRET gesetzt (Substrat-Erstlauf)
  # ODER die installer-eigene Harness-Credential ('lifeagents test harness auth', inject_credentials.sh; bewusst
  # nicht n8ns Standardname) existiert live (Folge-Deploys ohne das Secret in der Env, z. B. lifeagents update auf
  # dem Substrat). Sonst (Prod/Dev-Instanz) werden sie nicht gestaged und eine Live-Kopie per retire_stale entfernt —
  # aber nur bei erfolgreich geladener Credential-Liste (fail-safe: bei GET-Fehler bleibt alles wie bisher).
  local keep_harness=1
  if [ -z "${TEST_HARNESS_SECRET:-}" ] && [ "$creds_ok" -eq 1 ] \
     && ! printf '%s' "$_EXISTING_CREDS_JSON" | jq -e 'any(.[]; .name == "lifeagents test harness auth" and .type == "httpHeaderAuth")' >/dev/null 2>&1; then
    keep_harness=0
  fi
  [ -n "$remap_json" ] || remap_json='{}'

  local owner_chat; owner_chat="$(_resolve_owner_chat_id)"
  if [ "$owner_chat" = "0" ]; then
    note "Owner-chat_id noch unbekannt -> Platzhalter '0' (das Pairing am Ende der Installation bzw. 'lifeagents household pair-owner' setzt sie)."
  fi

  local cfg_map; cfg_map="$(_schedule_placeholder_map)"
  printf '%s' "$cfg_map" | jq -e 'type == "object"' >/dev/null 2>&1 || cfg_map='{}'
  # Geheime Telegram-Eingangs-ids je Instanz (Security-Audit 2026-10): der secret_token <workflowId>_<nodeId> und die
  # Route <webhookId>/webhook stehen build-stabil im oeffentlichen Repo -> id + webhookId jedes telegramTrigger werden
  # hier aus INGRESS_ID_KEY (core.env, bootstrap_owner._ensure_ingress_id_key) abgeleitet. Ohne Schluessel: Abbruch
  # beim ersten Trigger-Workflow, nie ein Rueckfall auf die oeffentlichen ids.
  local ingress_key; ingress_key="$(read_env_value "${N8N_OWNER_ENV_FILE:-/etc/lifeagents/core.env}" INGRESS_ID_KEY || true)"
  local hitl_chat; _hitl_chat_approval "$scope" >/dev/null; hitl_chat="$_HITL_CHAT_APPROVAL_VAL"   # Cache im Eltern-Prozess setzen
  local app_path; app_path="$(_app_path)"

  local staging; staging="$(mktemp -d /tmp/n8n_wf_deploy.XXXXXX)"; chmod 0755 "$staging"
  log "Workflows patchen (Scope '$scope': Credential-Remap + Zeitplaene + Owner-chat_id) -> $staging ..."
  local f base name count=0
  for d in "${wf_dirs[@]}"; do
    for f in "$d"/*.json; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"; case "$base" in _*) continue ;; esac
      name="$(jq -r '.name // empty' "$f")"
      # Scope-Filter ueber den Namen.
      if [ "$scope" = core ]; then
        [ -n "$excl_agents" ] && _wf_name_matches "$name" "$excl_agents" && continue   # gehoert einem Paket
      else
        _wf_name_matches "$name" "$incl_agents" || continue                            # nur dieses Paket
      fi
      # Test-Harness auf einer Prod-Instanz: nicht stagen, (id, name) aus dem Baum zum Entfernen vormerken.
      if [ "$keep_harness" -eq 0 ]; then
        case "$name" in
          *.test_harness)
            _DEPLOY_HARNESS_RETIRE+="$(jq -r '[.id // "", .name] | @tsv' "$f")"$'\n'
            continue ;;
        esac
      fi
      local ing_map='{}'
      if jq -e 'any(.nodes[]?; .type == "n8n-nodes-base.telegramTrigger")' "$f" >/dev/null 2>&1; then
        if [ -z "$ingress_key" ]; then
          rm -rf "$staging"
          die "Eingangs-Schlüssel INGRESS_ID_KEY fehlt in core.env — ohne ihn wäre die Telegram-Eingangsadresse öffentlich ableitbar. Abhilfe: 'lifeagents update' (bzw. provision.sh) erneut ausführen."
        fi
        ing_map="$(_ingress_id_map "$f" "$ingress_key")"
      fi
      if [ -z "$app_path" ] && grep -q '"__APP_PATH__"' "$f"; then
        rm -rf "$staging"
        die "Eingangs-Schlüssel INGRESS_ID_KEY fehlt in core.env — ohne ihn wäre die Adresse der Übersicht öffentlich ableitbar. Abhilfe: 'lifeagents update' (bzw. provision.sh) erneut ausführen."
      fi
      # Zeitplan-Platzhalter: NUR exakte String-Werte ersetzen (jq --argjson, kein sed — ein Cron enthaelt '/').
      jq --argjson map "$remap_json" --argjson cfg "$cfg_map" --argjson hitl "$hitl_chat" --argjson ing "$ing_map" \
         --arg app "$app_path" '
        walk(
          if (type == "object") and (has("credentials")) and ((.credentials | type) == "object")
          then .credentials |= map_values(
                 if (type == "object") and (.id != null) and ($map[.id] != null)
                 then .id = $map[.id] else . end)
          elif (type == "string") and ($cfg[.] != null) then $cfg[.]
          elif . == "__HITL_CHAT_APPROVAL__" then $hitl
          elif . == "__APP_PATH__" then $app
          else . end)
        | if has("nodes") then .nodes |= map(
            if .type == "n8n-nodes-base.telegramTrigger"
            then .id = ($ing[.id] // .id) | (if has("webhookId") then .webhookId = ($ing[.webhookId] // .webhookId) else . end)
            else . end) else . end
      ' "$f" | sed "s/__OWNER_CHAT_ID__/${owner_chat}/g" > "$staging/$base"
      chmod 0644 "$staging/$base"
      count=$((count + 1))
    done
  done
  if [ "$count" -eq 0 ]; then
    # Ein Paket ohne (verbliebene) Workflows ist legitim (z. B. paperless v0.3.0: alle stillgelegt) — die
    # Stilllegung MUSS trotzdem laufen, sonst blieben genau dann die Alt-Workflows/-Creds liegen.
    rm -rf "$staging"; note "Scope '$scope': keine Workflows im Baum."
    retire_stale "$scope"
    return 0
  fi
  # Rest-Platzhalter = ein Zeitplan ohne Wert in core.config (Seed fehlt/DB nicht lesbar) -> abbrechen, BEVOR
  # irgendetwas live geaendert wird (ein Platzhalter als Cron-Ausdruck liesse den Workflow nie oder falsch laufen).
  local missing; missing="$(grep -oh '__CFG_[A-Z0-9_]*__\|"__APP_PATH__"' "$staging"/*.json 2>/dev/null | sort -u | tr '\n' ' ' || true)"
  if [ -n "$missing" ]; then
    rm -rf "$staging"
    die "Workflow-Einstellung(en) ohne Wert in core.config: ${missing}— die Paket-Einstellungen sind nicht eingespielt (Seed). Abhilfe: 'lifeagents update'."
  fi
  ok "$count Workflow(s) im Scope '$scope' gepatcht."

  # Plan je Workflow (s. Kopf NUR GEAENDERTE): import | publish (unveraendert, aber nicht published) | skip.
  # all_ids = das ganze Deploy-Set (Schutzliste fuer retire_stale); id-lose Dateien werden immer importiert.
  # Telegram-Trigger (refresh_ids): auch unveraendert jedes Mal ab- und wieder anmelden — bootstrap_owner::_wire_telegram
  # loescht bei JEDEM Installer-Lauf den Bot-Webhook (deleteWebhook), erst das Aktivieren setzt ihn neu (setWebhook).
  local id all_ids=() import_ids=() publish_ids=() refresh_ids=() n_skip=0 full=0 ctx fp
  local -A st_fp=() st_vid=() lv_vid=() lv_avid=() fp_of=()
  local lv_id lv_v lv_a s_id s_fp s_v live
  if [ "${LIFEAGENTS_DEPLOY_FULL:-0}" = 1 ]; then full=1; log "LIFEAGENTS_DEPLOY_FULL=1 -> alle Workflows des Scopes werden neu eingespielt."
  elif ! live="$(_wf_live_versions)"; then full=1; warn "Live-Workflow-Liste nicht abrufbar -> alle Workflows des Scopes werden neu eingespielt."
  else
    while IFS='|' read -r lv_id lv_v lv_a; do [ -n "$lv_id" ] && { lv_vid[$lv_id]="$lv_v"; lv_avid[$lv_id]="$lv_a"; }; done <<< "$live"
    if [ -r "$WF_DEPLOY_STATE_FILE" ]; then
      while IFS=$'\t' read -r s_id s_fp s_v; do [ -n "$s_id" ] && [ -n "$s_v" ] && { st_fp[$s_id]="$s_fp"; st_vid[$s_id]="$s_v"; }; done < "$WF_DEPLOY_STATE_FILE"
    fi
  fi
  ctx="$(_wf_deploy_context)"
  mkdir -p "$staging/import"; chmod 0755 "$staging/import"
  for f in "$staging"/*.json; do
    id="$(jq -r '.id // empty' "$f")"
    if [ -z "$id" ]; then mv "$f" "$staging/import/"; continue; fi
    all_ids+=("$id")
    fp="$({ printf '%s\n' "$ctx"; cat "$f"; } | sha256sum | cut -c1-64)"
    fp_of[$id]="$fp"
    if [ "$full" = 1 ] || [ -z "${lv_vid[$id]+x}" ] || [ "${st_fp[$id]:-}" != "$fp" ] \
       || [ -z "${lv_vid[$id]}" ] || [ "${st_vid[$id]:-}" != "${lv_vid[$id]}" ]; then
      import_ids+=("$id"); publish_ids+=("$id"); mv "$f" "$staging/import/"
    elif jq -e 'any(.nodes[]?; .type == "n8n-nodes-base.telegramTrigger")' "$f" >/dev/null 2>&1; then
      refresh_ids+=("$id"); publish_ids+=("$id")
    elif [ "${lv_avid[$id]}" != "${lv_vid[$id]}" ]; then
      publish_ids+=("$id")
    else
      n_skip=$((n_skip + 1))
    fi
  done

  # Laufende Ausloeser (Zeitplaene, Bot-Webhook) der NEU einzuspielenden Workflows VOR dem Import abmelden (s.
  # _deactivate_live_triggers) — sonst liefe ein geaenderter Zeitplan bis zum naechsten n8n-Neustart doppelt.
  # Dazu die Telegram-Trigger (refresh_ids, s. o.): das Aktivieren im Fixpunkt registriert ihren Webhook neu.
  if [ "$(( ${#import_ids[@]} + ${#refresh_ids[@]} ))" -gt 0 ]; then
    _deactivate_live_triggers "${import_ids[@]}" "${refresh_ids[@]}"
    [ "${#_DEPLOY_DEACTIVATED[@]}" -eq 0 ] || log "${#_DEPLOY_DEACTIVATED[@]} laufende(r) Ausloeser vor dem Import abgemeldet."
  fi

  local n_import; n_import="$(find "$staging/import" -maxdepth 1 -name '*.json' | wc -l)"
  if [ "$n_import" -gt 0 ]; then
    log "n8n import:workflow --separate (id-erhaltend, Scope '$scope': $n_import neu/geaendert, $n_skip unveraendert) ..."
    # shellcheck disable=SC2016
    if ! runuser -u "$N8N_USER" -- bash -c '
          set -a; . "$1"; set +a
          exec "$2" import:workflow --separate --input="$3"
        ' _ "$N8N_ENV_FILE" "$n8n_bin" "$staging/import"; then
      warn "Staging zur Fehlersuche behalten: $staging"
      [ "${#_DEPLOY_DEACTIVATED[@]}" -eq 0 ] || _reactivate_ids "${_DEPLOY_DEACTIVATED[@]}"
      die "n8n import:workflow fehlgeschlagen."
    fi
  else
    log "Scope '$scope': alle $n_skip Workflow(s) unveraendert -> kein Import."
  fi

  log "Workflows publishen/aktivieren (Fixpunkt, Dependency-Order) ..."
  local pending=("${publish_ids[@]}") activated=0 pass=0
  while [ "${#pending[@]}" -gt 0 ]; do
    pass=$((pass + 1))
    local next=() progressed=0
    for id in "${pending[@]}"; do
      if n8n_set_published publish "$id" -fsS -o /dev/null 2>/dev/null; then
        activated=$((activated + 1)); progressed=1
      else next+=("$id"); fi
    done
    pending=("${next[@]}")
    [ "$progressed" -eq 1 ] || break
  done

  # Zustand der eingespielten Workflows festhalten — NACH dem Publish (der laesst die versionId stehen) und nur bei
  # NEUER versionId: hat ein Import still nicht gegriffen (versionId wie vorher), bleibt der alte Eintrag und der
  # naechste Lauf spielt ihn erneut ein, statt ihn fuer immer zu ueberspringen.
  local upd="$staging/state.tsv" after
  local -A new_vid=()
  : > "$upd"
  if [ "${#import_ids[@]}" -gt 0 ] && after="$(_wf_live_versions)"; then
    while IFS='|' read -r lv_id lv_v lv_a; do [ -n "$lv_id" ] && new_vid[$lv_id]="$lv_v"; done <<< "$after"
    for id in "${import_ids[@]}"; do
      if [ -n "${new_vid[$id]:-}" ] && [ "${new_vid[$id]}" != "${lv_vid[$id]:-}" ]; then
        printf '%s\t%s\t%s\n' "$id" "${fp_of[$id]}" "${new_vid[$id]}" >> "$upd"
      fi
    done
  fi
  _wf_state_commit "$upd"

  rm -rf "$staging"
  # Lief ein Workflow vor dem Import (wir haben ihn deaktiviert) und ist jetzt NICHT wieder aktiv, haben WIR ihn
  # stillgelegt (z. B. ein Zeitplan-Workflow) -> laut warnen, nicht als erwartbarer Core-Pass-Hinweis verstecken.
  # DEPLOY_STRICT_ACTIVATE=1 (lifeagents config set schedule) macht daraus einen Fehler-Rueckgabewert.
  local lost=() p
  for id in "${pending[@]}"; do
    for p in "${_DEPLOY_DEACTIVATED[@]}"; do if [ "$p" = "$id" ]; then lost+=("$id"); break; fi; done
  done
  if [ "${#lost[@]}" -gt 0 ]; then
    warn "${#lost[@]} vorher laufende(r) Workflow(s) liess(en) sich nicht wieder aktivieren: ${lost[*]} — 'lifeagents doctor' / 'lifeagents update'."
  fi
  if [ "${#pending[@]}" -gt 0 ]; then
    # note statt warn: im Core-Pass erwartbar (Orchestrator ruft Paket-Agenten, die erst danach kommen) —
    # provision.sh holt das per activate_inactive_workflows nach; was dann noch fehlt, meldet jenes.
    note "${#pending[@]} Workflow(s) nach $pass Pass/Pässen nicht published (ggf. Sub-Workflows noch nicht da oder Trigger ohne WEBHOOK_URL): ${pending[*]}"
  fi
  ok "Scope '$scope' deployed: $n_import neu eingespielt, $((${#publish_ids[@]} - ${#import_ids[@]})) nur (neu) veröffentlicht, $n_skip unverändert ($activated published/aktiviert)."
  # KEIN Deploy-Restart (id-stabile Credentials + Deaktivieren vor dem Import; s. Kopf-Kommentar) — ausser
  # retire_workflows entfernt einen stillgelegten Workflow mit eigenem aktiven Ausloeser, oder ein laufender
  # Ausloeser liess sich vor dem Import nicht abmelden.
  retire_stale "$scope" "${all_ids[@]}"   # startet n8n auch neu, wenn ein Ausloeser nicht abgemeldet werden konnte
  if [ "${DEPLOY_STRICT_ACTIVATE:-0}" = 1 ] && [ "${#lost[@]}" -gt 0 ]; then return 1; fi
  return 0
}

# === Telegram-Befehlsmenue (BotFather setMyCommands) — folgt den AKTIVEN Paketen, je Katalogsprache ===============
# Hier (nicht in bootstrap_owner.sh), weil jeder Arm, der Pakete installiert/schaltet (provision.sh,
# `lifeagents package|household|backup`), deploy_workflows.sh sourct (Install-UX-Phase 4).
#
# Textkatalog Phase B (docs/package-contract.md §3.11): Telegram waehlt das Menue im Privatchat in der Reihenfolge
# Chat+language_code -> Chat -> AllPrivateChats(+lc) -> Default+language_code -> Default
# (core.telegram.org/bots/api#determining-list-of-commands). Bei uns anders als „ein Menue je Person": das Menue
# folgt der Sprache des TELEGRAM-PROGRAMMS (language_code), nicht der Personen-Sprache — n8n hat keine
# setMyCommands-Operation und sein Telegram-Credential kann der HTTP-Node nicht einsetzen (kein `authenticate`),
# ein Menue je Person muesste bei jedem Sprachwechsel/Pairing aus n8n mit dem Bot-Token im Workflow gesetzt werden.
# Darum setzt NUR der Host: je Katalogsprache L Default+lc=L und Owner-Chat+lc=L, dazu ohne lc Default + Owner-Chat
# in der OWNER-Sprache (Fallback fuer andere App-Sprachen = die Kette Person -> Owner). Chat+lc schlaegt Chat -> kein
# Verschatten. Texte = Katalog-Keys <pkg>.cmd.<name> direkt aus den getrackten locales/<lang>.json (Datei = Wahrheit,
# der Host liest schon die Manifeste; Key fehlt -> en -> Befehlsname).

# _push_bot_commands <bot-token> <cmds-json> <scope-json> <label> [<language_code>] — EINEN BotCommandScope (+ Sprache)
# setzen + SOFORT verifizieren (Haus-Muster Sofort-Validierung, wie inject_credentials::_cred_test). <cmds-json>
# ist die jq-c-Ausgabe (gueltiges kompaktes JSON), <scope-json> ein validiertes JSON-Fragment
# ({"type":"default"} bzw. {"type":"chat","chat_id":N} mit numerisch-validierter N), <language_code> ein validierter
# ISO-639-1-Code oder leer. Body per String-Konkatenation der JSON-Fragmente (KEIN Re-Parse durch jq -> keine
# Double-Precision auf der chat_id). LEERE Liste -> skip (ein leeres commands-Array LOESCHT bei setMyCommands das
# Scope-Menue -> nie senden). Best-effort: jeder curl-Fehler -> warn + weiter, nie die.
_push_bot_commands() {
  local token="$1" cmds="$2" scope="$3" label="$4" lc="${5:-}"
  local count names got lcf=''
  count="$(printf '%s' "$cmds" | jq 'length' 2>/dev/null || printf '0')"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac   # numerisch-Garantie vor dem -gt-Test (set -e: nicht-num. -> [ ] rc2 -> Abbruch)
  [ "$count" -gt 0 ] || { log "Telegram-${label}-Menue: keine Befehle (visibility) -> uebersprungen."; return 0; }
  names="$(printf '%s' "$cmds" | jq -r 'map(.command)|join(", ")' 2>/dev/null || printf '?')"
  if [ -n "$lc" ]; then
    printf '%s' "$lc" | grep -qE '^[a-z]{2}$' || { warn "Telegram-${label}-Menue: ungueltiger language_code '$lc' — uebersprungen."; return 0; }
    lcf=",\"language_code\":\"${lc}\""
  fi

  if tg_api_curl "$token" setMyCommands -fsS --max-time 10 -X POST -H 'content-type: application/json' \
       --data "{\"commands\":${cmds},\"scope\":${scope}${lcf}}" >/dev/null 2>&1; then
    ok "Telegram-${label}-Menue gesetzt: ${names}."
  else
    warn "Telegram-${label}-Menue (setMyCommands) fehlgeschlagen (Token/Netz/Chat?) — unkritisch, spaeter nachziehbar."
    return 0
  fi

  # Sofort-Verify: denselben Scope (+ Sprache) per getMyCommands zuruecklesen + Befehls-Anzahl abgleichen.
  got="$(tg_api_curl "$token" getMyCommands -fsS --max-time 10 -X POST -H 'content-type: application/json' \
           --data "{\"scope\":${scope}${lcf}}" 2>/dev/null | jq '.result | length' 2>/dev/null || printf '')"
  if [ "$got" = "$count" ]; then
    ok "Telegram-${label}-Menue verifiziert (${got} Befehle gesetzt)."
  else
    warn "Telegram-${label}-Menue-Verifikation: erwartet ${count}, gelesen '${got:-?}' (Cache/Scope/Chat?) — unkritisch."
  fi
}


# _bot_command_manifests — Manifest-Pfade, deren `commands`-Block ins Menue gehoert: core + jedes Paket mit
# core.package_registry.status='active' (Install-UX-Phase 4: ein nicht installiertes/ausgeschaltetes Paket
# bietet keine Befehle an, z. B. /notfall nur mit estate). DB nicht lesbar -> nur core (sicherer Default).
_bot_command_manifests() {
  local p
  printf '%s\n' "$REPO_ROOT/packages/core/manifest.json"
  runuser -u "$DB_SUPERUSER" -- psql -X -tA -d "$N8N_DB_NAME" \
      -c "SELECT package FROM core.package_registry WHERE status = 'active' AND package <> 'core' ORDER BY package" 2>/dev/null |
  while IFS= read -r p; do
    printf '%s' "$p" | grep -qE '^[a-z][a-z0-9_]*$' || continue
    [ -r "$REPO_ROOT/packages/$p/manifest.json" ] && printf '%s\n' "$REPO_ROOT/packages/$p/manifest.json"
  done
}

# _bot_menu_cmds <lang> <visibility-regex> <manifest...> -> kompaktes JSON-Array [{command, description}] (core zuerst,
# dann die Pakete in Registry-Reihenfolge). `command` ohne fuehrenden Slash = Telegram-Form (BotCommand.command);
# description = Katalog-Text <pkg>.cmd.<name> in <lang> (Fallback en, dann der Befehlsname — Telegram lehnt eine
# leere description mit 400 ab; command_lint erzwingt die Keys).
_bot_menu_cmds() {
  local lang="$1" vis="$2"; shift 2
  local mf pkg dir loc en part out='[]'
  for mf in "$@"; do
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)"; [ -n "$pkg" ] || continue
    dir="$(dirname "$mf")/locales"
    loc="$dir/$lang.json"; [ -r "$loc" ] || loc=/dev/null
    en="$dir/en.json";     [ -r "$en" ]  || en=/dev/null
    part="$(jq -c --arg pkg "$pkg" --arg vis "$vis" --slurpfile L "$loc" --slurpfile E "$en" \
      '[(.commands.list // [])[] | select(.visibility | test($vis)) | (.cmd | ltrimstr("/")) as $c
        | {command: $c, description: (($L[0] // {})[$pkg + ".cmd." + $c] // ($E[0] // {})[$pkg + ".cmd." + $c] // $c)}]' \
      "$mf" 2>/dev/null)" || part='[]'
    out="$(jq -cn --argjson a "$out" --argjson b "${part:-[]}" '$a + $b' 2>/dev/null || printf '%s' "$out")"
  done
  printf '%s' "$out"
}

# Rollen-skopiertes BotFather-Menue aus den `commands`-Bloecken (WS-6; SoT je Paket-Manifest, Ableitungsregel
# im core commands._comment) von core + aktiven Paketen. Default {type:default} = visibility IN (member,all) fuer
# jeden; Owner {type:chat,chat_id:OWNER} = visibility IN (owner,all) als Override NUR fuer den Owner-Chat. Je
# Katalogsprache (Core-Manifest languages.list) mit language_code, plus je ein Fallback ohne language_code in der
# Owner-Sprache ZUM ZEITPUNKT DES SETZENS (agent.fn_person_lang; DB nicht lesbar -> de) — ein spaeterer /language-
# Wechsel des Owners zieht erst beim naechsten Setzen nach (Update, Paket-Statuswechsel); betrifft nur Telegram-Programme
# in einer Sprache AUSSERHALB des Katalogs, alle Katalogsprachen haben ihr eigenes Menue. Owner noch nicht gepairt (chat_id '0'/leer/nicht-
# numerisch) -> Owner-Scopes UEBERSPRUNGEN; das Pairing (owner_connect.sh) setzt sie danach.
_set_bot_command_menus() {
  local token="$1"
  need_cmd jq || { warn "jq fehlt -> Telegram-Befehlsmenue uebersprungen."; return 0; }
  local -a mfs=()
  local m lang owner_chat owner_lang owner_ok=0
  while IFS= read -r m; do [ -n "$m" ] && mfs+=("$m"); done < <(_bot_command_manifests)
  [ -r "${mfs[0]:-}" ] || { warn "Core-Manifest fehlt -> Telegram-Befehlsmenue uebersprungen."; return 0; }

  # Owner-chat_id numerisch-validiert (household_cli::_hh_num_ok-Muster), dann direkt ins JSON-Fragment
  # (kein jq-Re-Parse -> keine Double-Precision auf grossen IDs).
  owner_chat="$(_resolve_owner_chat_id)"
  if printf '%s' "$owner_chat" | grep -qE '^[0-9]+$' && [ "$owner_chat" != "0" ]; then owner_ok=1; fi
  owner_lang="$(runuser -u "$DB_SUPERUSER" -- psql -X -tA -d "$N8N_DB_NAME" \
      -c "SELECT agent.fn_person_lang(agent.fn_owner_person_id())->>'lang'" 2>/dev/null || true)"
  printf '%s' "$owner_lang" | grep -qE '^[a-z]{2}$' || owner_lang=de

  for lang in $(jq -r '.languages.list | sort_by(.ord) | .[].code' "${mfs[0]}" 2>/dev/null); do
    printf '%s' "$lang" | grep -qE '^[a-z]{2}$' || continue
    _push_bot_commands "$token" "$(_bot_menu_cmds "$lang" '^(member|all)$' "${mfs[@]}")" '{"type":"default"}' "Default/$lang" "$lang"
    [ "$owner_ok" = 1 ] && _push_bot_commands "$token" "$(_bot_menu_cmds "$lang" '^(owner|all)$' "${mfs[@]}")" \
      "{\"type\":\"chat\",\"chat_id\":${owner_chat}}" "Owner/$lang" "$lang"
  done
  _push_bot_commands "$token" "$(_bot_menu_cmds "$owner_lang" '^(member|all)$' "${mfs[@]}")" '{"type":"default"}' "Default"
  if [ "$owner_ok" = 1 ]; then
    _push_bot_commands "$token" "$(_bot_menu_cmds "$owner_lang" '^(owner|all)$' "${mfs[@]}")" \
      "{\"type\":\"chat\",\"chat_id\":${owner_chat}}" "Owner"
  else
    note "Telegram-Owner-Menue noch nicht gesetzt (Owner noch nicht verbunden) — das Pairing setzt es danach automatisch."
  fi
  # Mini-App „Übersicht“ (docs/package-contract.md §3.12): die Menue-Knoepfe haengen an denselben Aufrufern (Install,
  # Update, Pairing, Paket-Statuswechsel) wie das Befehlsmenue. Den Pruef-Schluessel setzt _wire_telegram eigenstaendig.
  _set_bot_menu_buttons "$token"
}

# _ensure_app_secret <bot-token> — Pruef-Schluessel der Mini-App = HMAC_SHA256(key="WebAppData", msg=Bot-Token)
#   (core.telegram.org/bots/webapps) nach core.app_secret (ACL wie core.backup_key). Bei JEDEM Install/Update neu
#   abgeleitet (bootstrap_owner._wire_telegram, eigener Schritt, nicht am Menue haengend) -> ein Token-Wechsel greift
#   sofort; geschrieben nur bei Aenderung. Token nur per stdin an openssl (printf = Builtin), der Schluessel nur per stdin
#   an psql — nie im argv. Best-effort: Fehler -> warn (die App lehnt dann mit no_secret/bad_signature ab).
_ensure_app_secret() {
  local token="$1" key
  need_cmd openssl || { warn "openssl fehlt -> Schlüssel der Übersicht nicht gesetzt."; return 0; }
  key="$(printf '%s' "$token" | openssl dgst -sha256 -hmac 'WebAppData' -r 2>/dev/null | cut -c1-64)" || key=''
  printf '%s' "$key" | grep -qE '^[0-9a-f]{64}$' || { warn "Schlüssel der Übersicht nicht ableitbar (openssl) — die Übersicht lehnt bis zum nächsten Update ab."; return 0; }
  if printf "INSERT INTO core.app_secret (id, webapp_key) VALUES (TRUE, decode('%s', 'hex'))
ON CONFLICT (id) DO UPDATE SET webapp_key = EXCLUDED.webapp_key, updated_at = now()
WHERE core.app_secret.webapp_key IS DISTINCT FROM EXCLUDED.webapp_key;\n" "$key" |
     runuser -u "$DB_SUPERUSER" -- psql -X -q -v ON_ERROR_STOP=1 -d "$N8N_DB_NAME" >/dev/null 2>&1; then
    ok "Schlüssel der Übersicht (Mini-App) gesetzt."
  else
    warn "Schlüssel der Übersicht nicht gespeichert (DB) — die Übersicht lehnt bis zum nächsten Update ab."
  fi
  key=''
}

# _tg_set_menu_button <bot-token> <body-json> — EIN setChatMenuButton. Der Body traegt die je Instanz geheime App-Adresse
#   -> URL UND Body nur ueber die curl-Config auf stdin (curl_cfg/curl_secret), nie im argv (/proc/<pid>/cmdline).
_tg_set_menu_button() {
  { curl_cfg url "${LIFEAGENTS_TELEGRAM_API:-https://api.telegram.org}/bot$1/setChatMenuButton"; curl_cfg data "$2"; } |
    curl_secret -fsS --max-time 10 -X POST -H 'content-type: application/json' >/dev/null 2>&1
}

# _set_bot_menu_buttons <bot-token> — der dauerhafte Knopf „📊 Übersicht“ links neben dem Eingabefeld
#   (setChatMenuButton mit chat_id, Typ web_app; Text = core.app.menu_button in der Sprache der Person). NUR pro Chat
#   fuer berechtigte Personen (app.enabled, app.audience owner|household, mind. ein Bildschirm eines aktiven Pakets),
#   nie als Standard-Knopf: der waere fuer jeden Fremden sichtbar. Alle anderen bekannten Chats und alle Chats aus der
#   Merkliste $LIFEAGENTS_DIR/app-menu-chats, die nicht mehr im Haushalt sind, bekommen das Befehlsmenue zurueck; ein
#   gescheitertes Zuruecksetzen bleibt auf der Merkliste (naechstes Update versucht es erneut). URL = WEBHOOK_URL +
#   webhook/<_app_path>, nur https (Telegram verlangt es). Spalten mit '|' getrennt (Tab ist IFS-Leerraum: leere Felder
#   wuerden verschmelzen). Best-effort, nie fatal.
_set_bot_menu_buttons() {
  local token="$1" wh path url enabled audience screens rows tid role lang text tj uj body kind ok_n=0 reset_n=0
  local state="${LIFEAGENTS_DIR:-/etc/lifeagents}/app-menu-chats" core_loc keep=' ' seen=' '
  need_cmd jq || return 0
  wh="$(read_env_value "${N8N_ENV_FILE:-/etc/n8n/n8n.env}" WEBHOOK_URL 2>/dev/null || true)"
  path="$(_app_path)"
  url=''
  case "$wh" in https://*) [ -n "$path" ] && url="${wh%/}/webhook/${path}" ;; esac
  # Ein psql-Aufruf liefert Schalter + Personen (tid|role|lang); DB nicht lesbar -> nichts aendern.
  rows="$(runuser -u "$DB_SUPERUSER" -- psql -X -tA -F '|' -d "$N8N_DB_NAME" -c "
    SELECT 'cfg', COALESCE(core.fn_config_get('core','app','enabled'), ''), COALESCE(core.fn_config_get('core','app','audience'), ''),
           (SELECT count(*) FROM core.app_screens s WHERE core.fn_package_active(s.package))::text
    UNION ALL
    SELECT p->>'telegram_user_id', regexp_replace(COALESCE(p->>'role', ''), '[^a-z_]', '', 'g'),
           COALESCE(agent.fn_person_lang(p->>'person_id')->>'lang', 'en'), ''
      FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) p
     WHERE c.name = 'family' AND COALESCE(p->>'telegram_user_id', '') ~ '^[0-9]{1,18}\$'" 2>/dev/null)" || { warn "Übersicht-Knopf: DB nicht lesbar — Knöpfe unverändert."; return 0; }
  enabled="$(printf '%s\n' "$rows" | awk -F'|' '$1=="cfg"{print $2}')"
  audience="$(printf '%s\n' "$rows" | awk -F'|' '$1=="cfg"{print $3}')"
  screens="$(printf '%s\n' "$rows" | awk -F'|' '$1=="cfg"{print $4}')"
  case "$screens" in ''|*[!0-9]*) screens=0 ;; esac
  [ -n "$url" ] || [ "$enabled" != true ] || [ "$screens" -eq 0 ] || note "Übersicht-Knopf: keine https-WEBHOOK_URL bzw. kein INGRESS_ID_KEY — nur Befehlsmenüs."
  uj="$(jq -Rn --arg u "$url" '$u')"
  core_loc="$REPO_ROOT/packages/core/locales"
  while IFS='|' read -r tid role lang _; do
    [ "$tid" = cfg ] && continue
    printf '%s' "$tid" | grep -qE '^[0-9]{1,18}$' || continue
    seen="${seen}${tid} "
    kind=commands
    if [ -n "$url" ] && [ "$enabled" = true ] && [ "$screens" -gt 0 ] && { [ "$audience" = household ] || [ "$role" = owner ]; }; then
      kind=web_app
    fi
    if [ "$kind" = web_app ]; then
      printf '%s' "$lang" | grep -qE '^[a-z]{2}$' || lang=en
      text="$(jq -r '."core.app.menu_button" // empty' "$core_loc/$lang.json" 2>/dev/null)"
      [ -n "$text" ] || text="$(jq -r '."core.app.menu_button" // empty' "$core_loc/en.json" 2>/dev/null)"
      [ -n "$text" ] || text='📊'
      tj="$(jq -Rn --arg t "$text" '$t')"
      body="{\"chat_id\":${tid},\"menu_button\":{\"type\":\"web_app\",\"text\":${tj},\"web_app\":{\"url\":${uj}}}}"
    else
      body="{\"chat_id\":${tid},\"menu_button\":{\"type\":\"commands\"}}"
    fi
    if _tg_set_menu_button "$token" "$body"; then
      if [ "$kind" = web_app ]; then ok_n=$((ok_n + 1)); else reset_n=$((reset_n + 1)); fi
    else
      warn "Übersicht-Knopf für einen Chat nicht gesetzt (Token/Netz/Chat?) — unkritisch, das nächste Update versucht es erneut."
    fi
  done <<EOF
$rows
EOF
  # Chats von der Merkliste, die nicht mehr im Haushalt sind -> Befehlsmenue zurueck; gescheitert -> bleibt gemerkt.
  if [ -r "$state" ]; then
    while IFS= read -r tid; do
      printf '%s' "$tid" | grep -qE '^[0-9]{1,18}$' || continue
      case "$seen" in *" $tid "*) continue ;; esac
      if _tg_set_menu_button "$token" "{\"chat_id\":${tid},\"menu_button\":{\"type\":\"commands\"}}"; then
        reset_n=$((reset_n + 1))
      else
        keep="${keep}${tid} "
        warn "Befehlsmenü für einen früheren Chat nicht zurückgesetzt — das nächste Update versucht es erneut."
      fi
    done < "$state"
  fi
  if [ -d "$(dirname "$state")" ]; then
    # shellcheck disable=SC2086  # numerisch geprüfte ids, Leerzeichen-Liste -> bewusst aufgeteilt
    { printf '%s\n' $seen $keep > "$state" && chmod 0600 "$state"; } 2>/dev/null || true
  fi
  ok "Übersicht-Knopf: ${ok_n} Chat(s) mit Knopf, ${reset_n} mit Befehlsmenü."
}

# refresh_bot_command_menus — Menue nach einem Paket-Statuswechsel neu setzen (pkg_lifecycle.sh). Token aus
# der Prozess-Env (provision.sh) bzw. core.env (CLI); fehlt er -> still ueberspringen. Nie fatal.
refresh_bot_command_menus() {
  local token="${TELEGRAM_BOT_TOKEN:-}"
  [ -n "$token" ] || token="$(read_env_value "$(lifeagents_env_file core)" TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
  [ -n "$token" ] || return 0
  need_cmd curl || return 0
  _set_bot_command_menus "$token" || true
  return 0
}
