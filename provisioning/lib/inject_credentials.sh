# inject_credentials.sh — n8n-Credentials id-stabil setzen (host- vs. paket-skopiert).
# Gesourct von provision.sh + der Runtime-CLI (`lifeagents package`). Definiert inject_credentials (Host/
# geteilt) + inject_package_credentials <pkg> (die 2 Postgres-Paket-Creds + die im Manifest-
# `credentials`-Block deklarierten Fremd-API-Creds, §3.8) + die Platzhalter<->Name-Map, die
# deploy_workflows zur Namens-Aufloesung nutzt.
#
# Mechanik (id-stabil, empirisch verifiziert auf n8n 2.21.7 und 2.44.4): kein DELETE+POST. Pro Credential:
# die bestehende id aus der Live-Liste (GET /credentials, name+type) aufloesen oder — nur wenn die
# Liste geladen wurde und kein Match hat (echter Erstinstall) — eine frische 16-char-id generieren;
# alle als ein Array `[{id,name,type,data}, …]` sammeln und mit einem `n8n import:credentials --input=<datei>`
# upserten. `import:credentials` upsertet auf id-Match in-place (n8n-PR #5231, `upsert(…,['id'])`) → die id
# bleibt stabil ueber Re-Applies, der Secret-Wert wird trotzdem frisch geschrieben. Damit referenziert ein
# bereits laufender In-Memory-Trigger nie eine geloeschte id → kein Geister-Cron, kein Deploy-Restart noetig.
# (Der Teardown-Restart bei Paket-Uninstall bleibt — dort werden Workflows wirklich geloescht, anderer
# Kausalpfad.)
#
# Warum CLI statt REST: `import:credentials` ist der id-stabile Upsert-Pfad (PATCH /credentials/{id} [PR #18082]
# waere eine gleichwertige Alternative, bewusst nicht gebaut). Gleiche Mechanik wie das Schwester-
# `deploy_workflows.sh::import:workflow`: `runuser -u $N8N_USER` mit gesourcter n8n.env (N8N_ENCRYPTION_KEY).
# Kein --userId noetig — n8n weist CLI-Importe dem Instanz-Owner zu (getProject()/GLOBAL_OWNER_ROLE). n8n liest
# Creds per-Execution aus Postgres → ein Wert-Update ist ohne Neustart live. Die id-Discovery laeuft per REST-GET
# (fail-closed).
#
# Secret-Policy: der Installer ist die einzige Quelle der Secrets — jeder Lauf setzt den aktuellen Key (aus
# .env/n8n.env) in-place; nie ein Alt-Secret adoptiert. Die id ist adoptiert (stabil), der Secret nicht (immer
# frisch). Fehlt ein Secret → die Credential wird uebersprungen (nicht ins Import-Array).
#
# Secrets aus Prozess-Env: Host = N8N_DB_PASSWORD, CORE_RO_PASSWORD, CONTEXT_RO_PASSWORD, TELEGRAM_BOT_TOKEN,
# GOOGLE_API_KEY, ANTHROPIC_API_KEY, TEST_HARNESS_SECRET (+ TEST_HARNESS_HEADER). Paket = <PKG>_RW_PASSWORD,
# <PKG>_RO_PASSWORD (setzt provision_role_password aus /etc/lifeagents/<pkg>.env) plus die im
# packages/<pkg>/manifest.json `credentials`-Block deklarierten Fremd-API-Keys (z. B. career
# Adzuna/JSearch) — Prozess-Env override-first, sonst /etc/lifeagents/<pkg>.env.
# Host-Code traegt keine Paket-Secret-Literale (contract_lint Naht-Guard).
#
# Liest Globals: N8N_URL, N8N_API_KEY (GET/Test), N8N_USER, N8N_ENV_FILE (CLI-Import), N8N_DB_NAME, N8N_DB_USER, N8N_DB_PASSWORD.

# --- Platzhalter <-> Credential-Name/Typ-Map (eine Quelle fuer inject + deploy-Namens-Aufloesung) -------
# _cred_host_placeholder_names  -> "placeholder<TAB>name<TAB>type" je geteilter Host-Credential.
_cred_host_placeholder_names() {
  printf '__CRED_POSTGRES_WRITE__\tPostgres account\tpostgres\n'
  printf '__CRED_POSTGRES_CORE_RO__\tPostgres core_ro (read-only)\tpostgres\n'
  printf '__CRED_POSTGRES_CONTEXT_RO__\tagent.core_contexts read-only\tpostgres\n'
  printf '__CRED_TELEGRAM__\tTelegram account\ttelegramApi\n'
  printf '__CRED_TELEGRAM_RELAY__\tTelegram relay (gateway)\thttpHeaderAuth\n'
  printf '__CRED_GEMINI__\tGoogle Gemini(PaLM) Api account\tgooglePalmApi\n'
  printf '__CRED_ANTHROPIC__\tAnthropic account\tanthropicApi\n'
  printf '__CRED_HARNESS__\tlifeagents test harness auth\thttpHeaderAuth\n'
}

# _cred_pkg_manifest <pkg>  -> Pfad des Paket-Manifests (REPO_ROOT in provision.sh gesetzt,
#   im Standalone-CLI-Kontext exportiert _pkg_resolve_env REPO_ROOT=$LIFEAGENTS_LIB; deploy_workflows
#   laeuft in denselben zwei Kontexten -> derselbe Fallback).
_cred_pkg_manifest() {
  printf '%s/packages/%s/manifest.json' "${REPO_ROOT:-${LIFEAGENTS_LIB:-/usr/local/lib/lifeagents}}" "$1"
}

# _cred_pkg_placeholder_names <pkg>  -> "placeholder<TAB>name<TAB>type" aller Paket-Creds:
#   (a) die 2 Postgres-Rollen-Creds aus der Rollen-Konvention <pkg>_rw/<pkg>_ro (dieselbe Adresse,
#       aus der pkg_teardown die zu loeschenden Creds ableitet), plus
#   (b) die im Manifest-`credentials`-Block deklarierten Fremd-API-Creds (docs/package-contract.md
#       §3.8) — generisch materialisiert wie _seed_services aus provides.services (kein Paket-Literal).
#   deploy_workflows loest beide Klassen per Name gegen live n8n auf.
_cred_pkg_placeholder_names() {
  local pkg="$1" up; up="$(printf '%s' "$pkg" | tr '[:lower:]' '[:upper:]')"
  printf '__CRED_POSTGRES_%s_RW__\tPostgres %s_rw (read-write)\tpostgres\n' "$up" "$pkg"
  printf '__CRED_POSTGRES_%s_RO__\tPostgres %s_ro (read-only)\tpostgres\n'  "$up" "$pkg"
  local mf; mf="$(_cred_pkg_manifest "$pkg")"
  [ -r "$mf" ] || return 0
  jq -r '(.credentials // {}) | to_entries[] | select(.key != "_comment") | [.value.placeholder, .value.name, .value.type] | @tsv' "$mf" 2>/dev/null || true
}

_EXISTING_CREDS_JSON='[]'
_N8N_BIN=''            # in-Modul aufgeloest (Standalone-lifeagents-package-Pfad reicht n8n_bin NICHT durch)
_CRED_ITEMS='[]'       # Sammel-Array {id,name,type,data} je inject-Aufruf
_CRED_TEST_IDS=''      # "id<TAB>name"-Zeilen fuer die Post-Import-Validierung

# _list_existing_creds → JSON-Array [{id,name,type}, …] ueber alle Seiten (cursor-paginiert).
#   Fail-closed: bei GET-Fehlschlag return 1 (der Aufrufer entscheidet — inject bricht ab, sonst wuerde eine
#   leere Liste als „Erstinstall" fehlgedeutet und fuer existierende Creds eine frische id generiert →
#   Dublette + verwaiste id → Geister-Cron). Erfolg mit leerem Ergebnis = echter Erstinstall (rc 0).
_list_existing_creds() {
  local tsv
  tsv="$(n8n_list_credentials)" || { warn "GET /credentials fehlgeschlagen."; return 1; }
  # Paginierung lebt in common.sh::n8n_list_credentials (id<TAB>name<TAB>type) -> hier nur in JSON wandeln.
  jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t") | {id: .[0], name: .[1], type: .[2]}]' <<<"$tsv"
}

# _cred_matching_ids <name> <type> → alle ids gleichen Namens+Typs (eine pro Zeile; inkl. Dubletten).
_cred_matching_ids() {
  printf '%s' "$_EXISTING_CREDS_JSON" \
    | jq -r --arg n "$1" --arg t "$2" '.[] | select(.name==$n and .type==$t) | .id' 2>/dev/null
}

# _gen_cred_id → 16-char [A-Za-z0-9] (n8n-nanoid-Form), pipefail-sicher (kein `tr </dev/urandom | head`,
#   das unter `set -o pipefail` per SIGPIPE spurious failt: bounded Block vor dem tr) + Kollisions-Regen
#   gegen die schon geladene Live-Liste (Kollision praktisch 0, aber beweisbar 0).
_gen_cred_id() {
  local id block
  while :; do
    block="$(head -c 96 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' 2>/dev/null || true)"
    id="$(printf '%s' "$block" | head -c 16)"
    [ "${#id}" -eq 16 ] || continue
    printf '%s' "$_EXISTING_CREDS_JSON" | jq -e --arg i "$id" 'any(.[]?; .id==$i)' >/dev/null 2>&1 || { printf '%s' "$id"; return 0; }
  done
}

# _cred_test <id> → validiert die Credential gegen den echten Dienst. Echo = "OK" | "ERROR:<msg>" |
#   "NA:<msg>" | "" (nicht erreichbar). Non-fatal (nur deutliche Warnung). Laeuft nach dem Import.
_cred_test() {
  local resp
  resp="$(n8n_api_curl "$N8N_API_KEY" "$N8N_URL/api/v1/credentials/$1/test" -fsS -X POST \
            -H 'Content-Type: application/json' --data '{}' 2>/dev/null)" || { printf ''; return 0; }
  local st msg
  st="$(printf '%s' "$resp" | jq -r '.status // empty' 2>/dev/null)"
  msg="$(printf '%s' "$resp" | jq -r '.message // empty' 2>/dev/null)"
  case "$st" in
    OK) printf 'OK' ;;
    Error)
      case "$msg" in
        *"No testing function"*|*"not implemented"*|*"not supported"*) printf 'NA:%s' "$msg" ;;
        *) printf 'ERROR:%s' "$msg" ;;
      esac ;;
    *) printf '' ;;
  esac
}

# _pg_cred_data <user> <password>  → n8n-postgres-Credential-data-JSON (lokale DB). Die Datenform entspricht dem
#   verifizierten REST-POST-Payload (Validator: sshTunnel:false Pflicht).
_pg_cred_data() {
  jq -n --arg h '127.0.0.1' --arg db "$N8N_DB_NAME" --arg u "$1" --arg p "$2" \
    '{host:$h, port:5432, database:$db, user:$u, password:$p, ssl:"disable", sshTunnel:false}'
}

# _cred_stage <name> <type> <data>  — id aufloesen (Discovery oder Erstinstall-Generierung) + {id,name,type,data}
#   ins Sammel-Array haengen. Nur aufgerufen, wenn das Secret vorliegt (Aufrufer-Guard). Die Liste ist
#   fail-closed geladen → eine leere Discovery bedeutet zuverlaessig „Cred existiert nicht" (kein Blind-Gen).
_cred_stage() {
  local name="$1" type="$2" data="$3" id
  # `|| true`: bei >=2 gleichnamigen Dubletten schliesst `head -n1` die Pipe ->
  # `jq` bekommt SIGPIPE (rc141) -> unter dem von provision.sh geerbten `set -o pipefail` wuerde die Zuweisung
  # provision.sh still abbrechen. head liefert trotzdem die erste id.
  id="$(_cred_matching_ids "$name" "$type" | head -n1 || true)"
  [ -n "$id" ] || id="$(_gen_cred_id)"
  _CRED_ITEMS="$(jq -c --arg i "$id" --arg n "$name" --arg t "$type" --argjson d "$data" \
                   '. + [{id:$i, name:$n, type:$t, data:$d}]' <<<"$_CRED_ITEMS")"
  _CRED_TEST_IDS="${_CRED_TEST_IDS}${id}"$'\t'"${name}"$'\n'
}

# _cred_import_and_test  — das Sammel-Array in eine Datei schreiben, einen `n8n import:credentials`-Upsert
#   fahren (als $N8N_USER, gesourcte n8n.env → N8N_ENCRYPTION_KEY), danach je Cred `_cred_test` auf der
#   bekannten id. Die transiente Klartext-Secret-Datei ist n8n-owned 600, sofort geloescht.
_cred_import_and_test() {
  local n; n="$(jq 'length' <<<"$_CRED_ITEMS" 2>/dev/null || echo 0)"
  if [ "$n" -le 0 ]; then warn "Keine Credentials zu importieren (alle Secrets fehlten)."; return 0; fi
  local f; f="$(mktemp "${TMPDIR:-/tmp}/n8n_creds.XXXXXX.json")"
  printf '%s' "$_CRED_ITEMS" > "$f"; chmod 600 "$f"; chown "$N8N_USER" "$f" 2>/dev/null || true
  if ! n8n_cli_env "$N8N_ENV_FILE" import:credentials --input="$f"; then
    rm -f "$f"; die "n8n import:credentials fehlgeschlagen ($n Credential(s))."
  fi
  rm -f "$f"
  ok "Credentials via import:credentials gesetzt (id-stabil, $n Credential(s))."
  local id name v
  while IFS=$'\t' read -r id name; do
    [ -n "$id" ] || continue
    v="$(_cred_test "$id")"
    case "$v" in
      OK)      ok   "  Validierung '$name': OK (Verbindung/Key gueltig)." ;;
      ERROR:*) warn "  VALIDIERUNG FEHLGESCHLAGEN '$name': ${v#ERROR:} — Key/Passwort/Tier pruefen!" ;;
      NA:*)    log  "  Validierung '$name': nicht testbar (kein Test-Endpoint) — uebersprungen." ;;
      *)       log  "  Validierung '$name': kein Testergebnis (Endpoint nicht erreichbar) — uebersprungen." ;;
    esac
  done <<< "$_CRED_TEST_IDS"
}

# _inject_preflight  — Vorbedingungen + einmal die Live-Cred-Liste laden (fail-closed) + CLI-Kontext
#   in-Modul aufloesen (der Standalone-`lifeagents package install`-Pfad reicht n8n_bin NICHT durch).
_inject_preflight() {
  [ -n "${N8N_URL:-}" ] || die "N8N_URL nicht gesetzt."
  [ -n "${N8N_API_KEY:-}" ] || die "N8N_API_KEY nicht gesetzt (Owner-Bootstrap)."
  [ -n "${N8N_DB_NAME:-}" ] || die "N8N_DB_NAME nicht gesetzt (Postgres-Credential 'database'-Feld)."
  [ -n "${N8N_USER:-}" ] || die "N8N_USER nicht gesetzt (CLI-Import als n8n-User)."
  [ -n "${N8N_ENV_FILE:-}" ] || die "N8N_ENV_FILE nicht gesetzt (n8n.env fuer den CLI-Import / N8N_ENCRYPTION_KEY)."
  require_cmd jq; require_cmd curl; require_su_tools
  _N8N_BIN="$(n8n_bin_path)"
  [ -n "$_N8N_BIN" ] || die "n8n-Binary nicht im PATH (install_n8n muss vorher laufen)."
  # Fail-closed: eine fehlgeschlagene Discovery darf nicht als Erstinstall durchgehen (sonst id-Regen fuer
  # existierende Creds → Dublette + Geister-Cron). Erfolg-mit-leer = echter Erstinstall (rc 0, leeres Array).
  _EXISTING_CREDS_JSON="$(_list_existing_creds)" \
    || die "Credential-Liste (GET /credentials) fehlgeschlagen — Injektion abgebrochen (fail-closed: keine blind generierten IDs fuer existierende Credentials)."
}

# inject_credentials  — die geteilten Host-Credentials (ohne die Paket-Creds, die kommen per Paket).
inject_credentials() {
  _inject_preflight
  _CRED_ITEMS='[]'; _CRED_TEST_IDS=''
  log "n8n-Host-Credentials id-stabil setzen (import:credentials Upsert) — $(printf '%s' "$_EXISTING_CREDS_JSON" | jq 'length' 2>/dev/null || echo 0) vorhanden ..."

  # 1) Postgres WRITE (n8n-Owner) — Passwort immer vorhanden (prepare_n8n_env).
  _cred_stage 'Postgres account' 'postgres' "$(_pg_cred_data "$N8N_DB_USER" "$N8N_DB_PASSWORD")"

  # 2) Postgres core_ro — Frei-SQL-Lesepfad der Core-Agenten (monitor/guide).
  if [ -n "${CORE_RO_PASSWORD:-}" ]; then
    _cred_stage 'Postgres core_ro (read-only)' 'postgres' "$(_pg_cred_data 'core_ro' "$CORE_RO_PASSWORD")"
  else
    warn "CORE_RO_PASSWORD fehlt — Credential 'Postgres core_ro (read-only)' uebersprungen."
  fi

  # 3) Postgres context_ro — load_context.
  if [ -n "${CONTEXT_RO_PASSWORD:-}" ]; then
    _cred_stage 'agent.core_contexts read-only' 'postgres' "$(_pg_cred_data 'context_ro' "$CONTEXT_RO_PASSWORD")"
  else
    warn "CONTEXT_RO_PASSWORD fehlt — Credential 'agent.core_contexts read-only' uebersprungen."
  fi

  # 4) Telegram Bot.
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    _cred_stage 'Telegram account' 'telegramApi' \
         "$(jq -n --arg t "$TELEGRAM_BOT_TOKEN" --arg b "${LIFEAGENTS_TELEGRAM_API:-https://api.telegram.org}" '{accessToken:$t, baseUrl:$b}')"
    # 4b) Dasselbe Token als Header fuer den Telegram-Relay des LLM-Gateways (Reaktion + Sticker, Kopf von
    #     llm_gateway/server.js): der telegramApi-Typ hat kein authenticate, ein HTTP-Knoten kaeme sonst nicht an
    #     das Token. Jeder Lauf setzt beide aus TELEGRAM_BOT_TOKEN -> ein Token-Wechsel (reconfigure/update) zieht mit.
    _cred_stage 'Telegram relay (gateway)' 'httpHeaderAuth' \
         "$(jq -n --arg v "$TELEGRAM_BOT_TOKEN" '{name:"x-telegram-bot-token", value:$v, allowedDomains:""}')"
  else
    note "TELEGRAM_BOT_TOKEN fehlt — Credentials 'Telegram account' + 'Telegram relay (gateway)' uebersprungen."
  fi

  # 5) Google Gemini (PaLM).  (allowedDomains ist Pflichtfeld des Credential-Validators.)
  if [ -n "${GOOGLE_API_KEY:-}" ]; then
    _cred_stage 'Google Gemini(PaLM) Api account' 'googlePalmApi' \
         "$(jq -n --arg h 'https://generativelanguage.googleapis.com' --arg k "$GOOGLE_API_KEY" '{host:$h, apiKey:$k, allowedDomains:""}')"
  else
    note "GOOGLE_API_KEY fehlt — Credential 'Google Gemini(PaLM) Api account' uebersprungen."
  fi

  # 6) Anthropic.  (headerName/headerValue/allowedDomains Pflicht-Feldform.) url = der lokale LLM-Gateway
  #    (install_llm_gateway.sh, lief vorher und ist nachweislich gesund): er setzt die Cache-Haltepunkte und
  #    reicht an api.anthropic.com weiter. Jeder Lauf setzt url neu -> Bestands-Installationen wechseln beim Update.
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    _cred_stage 'Anthropic account' 'anthropicApi' \
         "$(jq -n --arg k "$ANTHROPIC_API_KEY" --arg u "${LLM_GATEWAY_URL:-http://127.0.0.1:8090}" '{apiKey:$k, url:$u, headerName:"", headerValue:"", allowedDomains:""}')"
  else
    note "ANTHROPIC_API_KEY fehlt — Credential 'Anthropic account' uebersprungen."
  fi

  # 7) Header-Auth (Test-Harness — Dev/Test; in Prod nicht noetig). Eigener, installer-eigener Name (nicht n8ns
  #    Standard 'Header Auth account'): deploy_workflows erkennt eine Test-Instanz an genau dieser Credential.
  if [ -n "${TEST_HARNESS_SECRET:-}" ]; then
    _cred_stage 'lifeagents test harness auth' 'httpHeaderAuth' \
         "$(jq -n --arg n "${TEST_HARNESS_HEADER:-x-harness-secret}" --arg v "$TEST_HARNESS_SECRET" '{name:$n, value:$v, allowedDomains:""}')"
  else
    note "TEST_HARNESS_SECRET fehlt — Credential 'lifeagents test harness auth' uebersprungen (nur Dev/Test)."
  fi

  # Paket-Fremd-API-Creds sind manifest-deklariert (`credentials`-Block) und laufen paket-skopiert ueber
  # inject_package_credentials — Host-Code traegt keine Paket-Literale (Naht-Guard-gelintet).

  _cred_import_and_test
  ok "Host-Credentials gesetzt."
}

# _cred_assemble_data <type> <fields_json>  — n8n-Credential-data-JSON je Typ. Die Typ-Quirks
#   (allowedDomains-Pflichtfeld, httpCustomAuth = ein stringifiziertes json-Feld) leben hier, nie im
#   Manifest (kein data-Template/Code im Manifest — es deklariert nur type + env->field-Bindings).
#   fields_json = {"<field>":"<wert>", …} aus den Manifest-Bindings. Unbekannter Typ -> die (Enum
#   geschlossen; contract_lint prueft ihn schon beim Commit). httpCustomAuth non-qs-Formen (headers/body)
#   = vertagt.
_cred_assemble_data() {
  local type="$1" fields="$2"
  case "$type" in
    httpCustomAuth)
      jq -c '{json: ({qs:.}|tojson), allowedDomains:""}' <<<"$fields" ;;
    httpHeaderAuth)
      jq -c 'to_entries[0] | {name:.key, value:.value, allowedDomains:""}' <<<"$fields" ;;
    *)
      die "Credential-Typ '$type' nicht unterstuetzt (Assembler-Enum: httpCustomAuth|httpHeaderAuth) — Manifest pruefen." ;;
  esac
}

# _inject_manifest_credentials <pkg>  — die im Manifest deklarierten Fremd-API-Creds des Pakets stagen
#   (Deklaration-vs-Ausfuehrung, docs/package-contract.md §3.8). Je Credential: alle env-Keys
#   aufloesen (Prozess-Env override-first, sonst /etc/lifeagents/<pkg>.env) -> Credential-Atomaritaet
#   (alle-oder-keiner): unvollstaendig + optional -> warn + graceful skip (Nachtrag: lifeagents package
#   reconfigure <pkg>); unvollstaendig + required -> die (fail-fast; derzeit sind alle realen Paket-Creds
#   optional).
_inject_manifest_credentials() {
  local pkg="$1" mf envf
  mf="$(_cred_pkg_manifest "$pkg")"
  [ -r "$mf" ] || return 0
  jq -e '(.credentials // {}) | [to_entries[] | select(.key != "_comment")] | length > 0' "$mf" >/dev/null 2>&1 || return 0
  envf="$(lifeagents_env_file "$pkg")"
  local entry cred_name cred_type cred_required fields missing ekey efield eprefix v
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    cred_name="$(jq -r '.value.name' <<<"$entry")"
    cred_type="$(jq -r '.value.type' <<<"$entry")"
    cred_required="$(jq -r '.value.required // false' <<<"$entry")"
    fields='{}'; missing=''
    while IFS=$'\t' read -r ekey efield eprefix; do
      [ -n "$ekey" ] || continue
      eval "v=\${$ekey:-}"
      [ -n "$v" ] || v="$(read_env_value "$envf" "$ekey" || true)"
      if [ -n "$v" ]; then
        # value_prefix: flaches Deklarativ-Feld — der Host konkateniert nur (prefix+wert), parst nichts;
        # kein Template-Marker (§3.8). Fall: Paperless-Token muss als "Token <wert>" in den
        # Authorization-Header, der Owner gibt das rohe Token ein.
        [ -n "$eprefix" ] && v="${eprefix}${v}"
        fields="$(jq -c --arg f "$efield" --arg v "$v" '. + {($f): $v}' <<<"$fields")"
      else
        missing="${missing}${missing:+/}$ekey"
      fi
    done <<<"$(jq -r '.value.env | to_entries[] | [.key, .value.field, (.value.value_prefix // "")] | @tsv' <<<"$entry")"
    if [ -n "$missing" ]; then
      if [ "$cred_required" = "true" ]; then
        die "Pflicht-Credential '$cred_name' ($pkg): Secret(s) fehlen: $missing. Abhilfe: lifeagents package reconfigure $pkg"
      fi
      note "$missing fehlt — Credential '$cred_name' uebersprungen ($pkg, optional; nachtragen: lifeagents package reconfigure $pkg)."
      continue
    fi
    _cred_stage "$cred_name" "$cred_type" "$(_cred_assemble_data "$cred_type" "$fields")"
  done <<<"$(jq -c '(.credentials // {}) | to_entries[] | select(.key != "_comment")' "$mf")"
  return 0   # Loop kann mit continue-/Skip-Status enden -> nie den geerbten set -e triggern
}

# inject_package_credentials <pkg>  — alle Paket-Creds: die 2 engen Postgres-Creds <pkg>_rw/<pkg>_ro
#   (aus den per provision_role_password gesetzten Passwoertern) + die manifest-deklarierten Fremd-
#   API-Creds (`credentials`-Block, _inject_manifest_credentials). Genutzt von pkg_install_one Stage 4
#   und pkg_cmd_reconfigure (Standalone-Pfad: _inject_preflight loest n8n_bin/runuser selbst auf,
#   da _pkg_resolve_env sie nicht durchreicht).
inject_package_credentials() {
  local pkg="$1" up; up="$(printf '%s' "$pkg" | tr '[:lower:]' '[:upper:]')"
  _inject_preflight
  _CRED_ITEMS='[]'; _CRED_TEST_IDS=''
  log "n8n-Credentials fuer Paket '$pkg' id-stabil setzen ($pkg""_rw/$pkg""_ro + Manifest-Creds) ..."
  local rw_pw ro_pw; eval "rw_pw=\${${up}_RW_PASSWORD:-}"; eval "ro_pw=\${${up}_RO_PASSWORD:-}"
  if [ -n "$rw_pw" ]; then
    _cred_stage "Postgres ${pkg}_rw (read-write)" 'postgres' "$(_pg_cred_data "${pkg}_rw" "$rw_pw")"
  else
    warn "${up}_RW_PASSWORD fehlt — Credential 'Postgres ${pkg}_rw (read-write)' uebersprungen."
  fi
  if [ -n "$ro_pw" ]; then
    _cred_stage "Postgres ${pkg}_ro (read-only)" 'postgres' "$(_pg_cred_data "${pkg}_ro" "$ro_pw")"
  else
    warn "${up}_RO_PASSWORD fehlt — Credential 'Postgres ${pkg}_ro (read-only)' uebersprungen."
  fi
  _inject_manifest_credentials "$pkg"
  _cred_import_and_test
}
