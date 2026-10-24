# bootstrap_owner.sh — Owner-Bootstrap + Multi-User-Erstidentitaet (Phase 4/5 Dev/Release-Split-Plan).
# Sourced by provision.sh. Definiert bootstrap_owner(). Laeuft NACH apply_schema und VOR der
# (API-Key-gegateten) Credential-/Workflow-Injektion — denn der hier gemintete N8N_API_KEY ist
# genau deren Tor.
#
# OWNER-MECHANISMUS (Phase-5-Redesign, ersetzt das fragile managed-env):
#   Der Owner wird ueber n8ns INTERNEN Setup-Flow eingerichtet — `POST /rest/owner/setup`
#   (firstName/lastName/email/password) -> Session-Cookie -> `POST /rest/api-keys`. Das ist
#   genau der Pfad des Setup-Assistenten und damit VERSIONS-STABIL.
#   Verworfen: N8N_INSTANCE_OWNER_MANAGED_BY_ENV (+ bcrypt-Hash). Recherche (n8n PR #27859):
#   managed-env provisioniert den Owner NUR beim allerersten Boot und no-opt still, wenn die
#   Vars erst NACH dem ersten Start dazukommen — genau die Reihenfolge in provision.sh
#   (n8n startet in install_n8n, core.env entstand erst danach) -> Mint-Login 401 -> Deploy
#   blockiert (der Phase-5-Blocker). `/rest/owner/setup` haengt an KEINEM Boot-Timing:
#   n8n bootet im Setup-Pending-Zustand, der Bootstrap richtet den Owner danach ein.
#
# Schritte (jeder idempotent + guarded; ein zweiter Lauf ist ein no-op bzw. reuse):
#   1. n8n-API-Key  : Override-first (N8N_API_KEY aus der Env ODER bereits in core.env -> reuse,
#                     kein erneutes Minten = keine dangling Keys). Sonst Session beschaffen —
#                     erst `/rest/login` (Owner existiert schon, z.B. Re-Run mit gepinntem
#                     Passwort), sonst `/rest/owner/setup` (frische Instanz) -> Cookie ->
#                     `POST /rest/api-keys`. RESILIENT: jeder Fehlschlag -> warn + skip (die
#                     Cred-/Workflow-Injektion ist auf N8N_API_KEY gegatet, faellt sauber aus).
#                     Persistiert in core.env (640 root:n8n) fuer den idempotenten Reuse.
#   2. Telegram-Basis: setMyCommands ROLLEN-SKOPIERT (WS-6, visibility-skopiert aus dem core-
#                      `commands`-Block: Owner-Befehle via {type:chat}, Default-Befehle via
#                      {type:default}; je Scope sofort per getMyCommands verifiziert) + deleteWebhook
#                      (drop_pending_updates) — clean slate. (Den eigentlichen setWebhook mit secret_token managt
#                      n8n SELBST beim Aktivieren des Telegram-Trigger-Workflows; ein manueller
#                      setWebhook hier wuerde von n8ns Aktivierung ueberschrieben -> Phase 6.)
#   3. Owner-Person-Skelett: packages/core/db/util/util_seed_owner_skeleton.sql (family-Zeile; finance_profile legt seit
#                            Install-UX-Phase 6 das finance-Paket selbst an, context_skeletons) anlegen, falls fehlend. MUSS existieren, BEVOR der Owner seinen Code
#                            eintippt — fn_consume_pairing_challenge mergt nur in eine bestehende
#                            Person (birth_date-Validator = Backstop). PII via psql-Variablen.
#   4. Owner-Pairing-Code  : NICHT mehr hier (Install-UX-Phase 3) — _arm_owner_challenge armiert ihn erst im
#                            gefuehrten Ende (owner_connect.sh), wenn der Bot erreichbar ist; Code NUR im Terminal,
#                            NIE ueber Telegram. `/start <code>` -> Orchestrator-Pre-Router bindet role=owner.
#
# Reads globals (provision.sh): N8N_USER, N8N_OWNER_ENV_FILE, N8N_PORT, N8N_URL, PROFILE,
#   UNATTENDED, DOMAIN, REPO_ROOT, N8N_DB_NAME.
# Inputs via Prozess-Env (override-first; Dev/Test: aus dem .env-Test-Block, Release/Phase 6: TTY):
#   N8N_OWNER_EMAIL (default owner@localhost) · N8N_OWNER_PASSWORD (sonst generiert, n8n-konform) ·
#   OWNER_FIRST_NAME / OWNER_LAST_NAME / OWNER_BIRTH_DATE (Skelett; fehlt -> Seed+Arm uebersprungen) ·
#   OWNER_LANGUAGE (Sprache fester Bot-Texte, default 'de') ·
#   OWNER_PERSONA (Bot-Charakter, default neutral; ungueltig -> neutral, nie Abbruch) ·
#   OWNER_PERSON_ID (default 'owner') · TELEGRAM_BOT_TOKEN (sonst Telegram-Schritt skip) ·
#   N8N_API_KEY (sonst minten).

DB_SUPERUSER="${DB_SUPERUSER:-postgres}"

# psql als postgres-Superuser gegen die n8n-DB (Peer-Auth, identisch zu apply_schema).
_owner_psql() {
  runuser -u "$DB_SUPERUSER" -- psql -v ON_ERROR_STOP=1 -X -d "$N8N_DB_NAME" "$@"
}

# _psql_setvar <name> <value> -> eine psql-`\set name 'value'`-Zeile fuer einen 600/postgres-eigenen
# Treiber (NIE als `-v` auf die Kommandozeile -> kein /proc/cmdline-Leak von Code/PII; Plan-Checkliste
# "Secret nie als CLI-Argument"). Escaping fuer den psql-Single-Quote-Kontext: \ -> \\, ' -> \'.
_psql_setvar() {
  local v="$2"
  v="${v//\\/\\\\}"
  v="${v//\'/\\\'}"
  printf "\\set %s '%s'\n" "$1" "$v"
}

# _owner_psql_driver [psql-args...] -> liest Treiber-Inhalt (\set-Zeilen + SQL) von STDIN, fuehrt ihn
# ueber eine 600/postgres-eigene Temp-Datei aus. Werte stehen NUR in der 600-Datei, nie in der CLI.
_owner_psql_driver() {
  local drv; drv="$(mktemp /tmp/owner_drv.XXXXXX.sql)"
  cat > "$drv"
  chmod 600 "$drv"; chown "$DB_SUPERUSER" "$drv" 2>/dev/null || true
  local rc=0
  _owner_psql "$@" -f "$drv" || rc=$?
  rm -f "$drv"
  return $rc
}

# Owner-Credentials aufloesen (Email + Klartext-Passwort). KEIN bcrypt/managed-env mehr —
# /rest/owner/setup nimmt das Klartext-Passwort und hasht selbst. Das generierte Passwort MUSS
# n8ns Policy erfuellen (>=8 Zeichen, >=1 Ziffer, >=1 Grossbuchstabe; rand_hex liefert nur
# Kleinbuchstaben+Ziffern -> Prefix 'Pw' + Suffix-Ziffer ergaenzt Gross/Ziffer garantiert).
# n8n-Passwort-Policy (verifiziert in 2.21.7-Source: passwordSchema; Owner-Setup auf 2.44.4 bestaetigt): 8–64 Zeichen, >=1 Ziffer,
# >=1 Grossbuchstabe. Verletzung -> /rest/owner/setup 400 (still). 0 = konform.
_owner_password_ok() {
  local p="$1"
  [ "${#p}" -ge 8 ] && [ "${#p}" -le 64 ] || return 1
  printf '%s' "$p" | grep -q '[0-9]' || return 1
  printf '%s' "$p" | grep -q '[A-Z]' || return 1
  return 0
}

# Default-Email MUSS ein FQDN sein: n8ns /rest/owner/setup validiert per zod-`.email()` und lehnt
# `owner@localhost` ab ("Invalid email"). Mit Domain -> owner@<domain>, sonst valider Platzhalter.
# Generiertes Passwort ist policy-konform by construction (Prefix 'Pw' + Suffix-Ziffer); ein per Env
# gepinntes Passwort wird gegen die Policy geprueft und bei Verstoss klar gewarnt (sonst opaker 400).
_resolve_owner_creds() {
  OWNER_EMAIL="${N8N_OWNER_EMAIL:-owner@${DOMAIN:-example.com}}"
  OWNER_FIRST="${OWNER_FIRST_NAME:-Owner}"
  OWNER_LAST="${OWNER_LAST_NAME:-Account}"
  OWNER_PLAINTEXT="${N8N_OWNER_PASSWORD:-Pw$(rand_hex 12)7}"
  if [ -n "${N8N_OWNER_PASSWORD:-}" ] && ! _owner_password_ok "$OWNER_PLAINTEXT"; then
    warn "N8N_OWNER_PASSWORD verletzt n8ns Policy (8–64 Zeichen, >=1 Ziffer, >=1 Grossbuchstabe) -> Owner-Setup wird 400en. Bitte korrigieren."
  fi
}

_bootstrap_wait_health() {
  wait_n8n_health && return 0
  warn "n8n /healthz antwortet noch nicht — Owner-/API-Schritte koennen nachlaufen."
  return 1
}

# Body + HTTP-Code einer JSON-POST gegen die interne REST-API holen. Gibt "<body>\n<code>" aus
# (Cookie -> Jar via -c). KEIN -f: wir wollen den 4xx-Body (Validierungsfehler) sehen. Der Body
# eines FEHLERs enthaelt nur Validierungstext (kein Secret) -> sicher loggbar; Erfolg loggen wir nie.
_owner_post() {
  local jar="$1" path="$2" data="$3"
  # Body (enthaelt das Owner-Passwort) ueber den curl-Config-Kanal, NIE im argv (curl_secret).
  curl_cfg data "$data" | curl_secret -sS --max-time 15 -c "$jar" -o - -w '\n%{http_code}' -X POST "${N8N_URL}${path}" \
       -H 'content-type: application/json' 2>/dev/null || true
}

# Bestehenden Owner einloggen -> Session-Cookie in den Jar. 0 = Login ok (Owner existiert),
# !=0 = Login fehlgeschlagen (z.B. frische Instanz ohne Owner -> 401). Still (erwarteter Fall).
_owner_login() {
  local jar="$1" resp code
  resp="$(_owner_post "$jar" /rest/login \
            "$(jq -nc --arg e "$OWNER_EMAIL" --arg p "$OWNER_PLAINTEXT" '{emailOrLdapLoginId:$e, password:$p}')")"
  code="$(printf '%s' "$resp" | tail -n1)"
  [ "$code" = "200" ]
}

# Frische Instanz: Owner via n8ns internem Setup-Endpoint anlegen -> Session-Cookie in den Jar.
# Das ist der Pfad des Setup-Assistenten (versions-stabil). 0 = eingerichtet, !=0 = fehlgeschlagen
# (z.B. Owner schon vorhanden -> 400, Passwort-Policy/Email-Format) -> Grund (Body) in den warn.
_owner_setup() {
  local jar="$1" resp code body
  resp="$(_owner_post "$jar" /rest/owner/setup \
            "$(jq -nc --arg e "$OWNER_EMAIL" --arg f "$OWNER_FIRST" --arg l "$OWNER_LAST" --arg p "$OWNER_PLAINTEXT" \
                 '{email:$e, firstName:$f, lastName:$l, password:$p}')")"
  code="$(printf '%s' "$resp" | tail -n1)"
  if [ "$code" = "200" ] || [ "$code" = "201" ]; then
    ok "n8n-Owner via /rest/owner/setup eingerichtet (${OWNER_EMAIL})."
    # shellcheck disable=SC2034  # liest display_install_recap (provision.sh): das generierte Passwort gilt NUR in diesem Lauf
    OWNER_SETUP_DONE=1
    return 0
  fi
  body="$(printf '%s' "$resp" | sed '$d')"
  warn "owner/setup HTTP ${code:-?}: ${body}"
  return 1
}

# Den n8n-API-Key in /etc/lifeagents/core.env persistieren (640 root:n8n) — per-Key-Upsert (env_upsert),
# damit die Nutzer-Eingaben von release_inputs in derselben Datei NICHT geclobbert werden (ein Schreiber
# je Key, kein Whole-File-Write; Secret-Modell §3.0a). Die RO-Rollen-Passwoerter persistiert
# provision_role_password selbst. core.env ist KEINE n8n-Config (n8n ignoriert die Keys); EnvironmentFile=-
# der Unit toleriert unbekannte Keys.
_persist_owner_env() {
  local envf="$N8N_OWNER_ENV_FILE"
  ensure_lifeagents_dir
  if [ ! -f "$envf" ]; then
    mkdir -p "$(dirname "$envf")"
    {
      printf '# Managed by lifeagents provisioning — Host/Core-Secrets + Nutzer-Eingaben (Secret-Modell §3.0a).\n'
      printf '# Keine n8n-Config; idempotenter Reuse via read_env_value. chmod 640 root:%s, nie ins Repo.\n' "$N8N_USER"
    } > "$envf"
    chmod 0640 "$envf" 2>/dev/null || true; chown "root:${N8N_USER}" "$envf" 2>/dev/null || true
  fi
  if [ -n "${N8N_API_KEY:-}" ]; then env_upsert "$envf" N8N_API_KEY "$N8N_API_KEY"; fi
  chmod 0640 "$envf" 2>/dev/null || true; chown "root:${N8N_USER}" "$envf" 2>/dev/null || true
}

# Bestehende Host-Secrets aus core.env in die Env zurueckladen (Reuse), falls nicht schon per
# Prozess-Env gesetzt — damit ein Re-Run dieselben Werte wiederverwendet (kein Rotieren). Host-only
# (API-Key + core_ro/context_ro-PW); die Paket-Passwoerter liegen in /etc/lifeagents/<pkg>.env und
# laedt der per-Paket-Install. NUR if-Form (set-e-Falle, leerer Wert).
_load_owner_env_state() {
  local v
  if [ -z "${N8N_API_KEY:-}" ]; then
    v="$(read_env_value "$N8N_OWNER_ENV_FILE" N8N_API_KEY || true)"
    if [ -n "$v" ]; then N8N_API_KEY="$v"; export N8N_API_KEY; fi
  fi
  if [ -z "${CONTEXT_RO_PASSWORD:-}" ]; then
    v="$(read_env_value "$N8N_OWNER_ENV_FILE" CONTEXT_RO_PASSWORD || true)"
    if [ -n "$v" ]; then CONTEXT_RO_PASSWORD="$v"; fi
  fi
  if [ -z "${CORE_RO_PASSWORD:-}" ]; then
    v="$(read_env_value "$N8N_OWNER_ENV_FILE" CORE_RO_PASSWORD || true)"
    if [ -n "$v" ]; then CORE_RO_PASSWORD="$v"; fi
  fi
}

# Die HOST-Read-Only-Login-Rollen (core_ro/context_ro) brauchen ein Passwort, damit n8n sie ueber
# 127.0.0.1 + scram nutzen kann (peer-Auth gilt nur am Unix-Socket fuer postgres). apply_schema legt
# sie als LOGIN OHNE Passwort an -> HIER setzen wir es (Superuser, generischer common-Helfer) und
# persistieren es in /etc/lifeagents/core.env + reichen es als CORE_RO_PASSWORD/CONTEXT_RO_PASSWORD an
# inject_credentials. **NUR Host-Rollen** (Secret-Modell §3.0a, D1): die PAKET-Rollen <pkg>_rw/_ro
# mintet der per-Paket-Install selbst (pkg_lifecycle Stufe 4, eigene /etc/lifeagents/<pkg>.env) — der
# fruehere finance_ro/finance_rw-Mint hier lief VOR der Rollen-Anlage (Reihenfolge-Blocker).
# OHNE diesen Schritt verweisen die Core-Postgres-Nodes (Pairing-Pre-Router, Frei-SQL-Lesepfad der
# Core-Agenten unter core_ro, load_context unter context_ro) auf eine nicht existente Credential.
_provision_ro_secrets() {
  ensure_lifeagents_dir
  local envf; envf="$(lifeagents_env_file core)"
  if provision_role_password context_ro "$envf" CONTEXT_RO_PASSWORD; then
    ok "RO-Rolle context_ro: Passwort gesetzt (lifeagents/core.env) + an die Credential-Injektion gereicht."
  else
    warn "context_ro-Passwort setzen fehlgeschlagen -> Lese-Credential 'agent.core_contexts read-only' wird uebersprungen."
  fi
  # core_ro: Frei-SQL-Lesepfad der CORE-Agenten (monitor/guide) — agent+core+finance read-only (B3).
  if provision_role_password core_ro "$envf" CORE_RO_PASSWORD; then
    ok "RO-Rolle core_ro: Passwort gesetzt (lifeagents/core.env) + an die Credential-Injektion gereicht."
  else
    warn "core_ro-Passwort setzen fehlgeschlagen -> Lese-Credential 'core read-only' wird uebersprungen."
  fi
}

# N8N_API_KEY ueber die INTERNE REST-API minten (kein Public-Endpoint dafuer). Session beschaffen
# (Login ODER Owner-Setup) -> POST /rest/api-keys. Bewusst RESILIENT: jeder Fehlschlag -> warn +
# skip (die Cred-/Workflow-Injektion ist auf N8N_API_KEY gegatet und faellt dann sauber aus).
_mint_api_key() {
  # Override-first: schon vorhanden -> nichts tun.
  if [ -n "${N8N_API_KEY:-}" ]; then ok "N8N_API_KEY aus der Env uebernommen (kein Minten)."; export N8N_API_KEY; return 0; fi
  local existing; existing="$(read_env_value "$N8N_OWNER_ENV_FILE" N8N_API_KEY || true)"
  if [ -n "$existing" ]; then N8N_API_KEY="$existing"; export N8N_API_KEY; ok "N8N_API_KEY aus core.env reused."; return 0; fi

  need_cmd curl || { warn "curl fehlt -> API-Key-Minten uebersprungen."; return 1; }
  need_cmd jq   || { warn "jq fehlt -> API-Key-Minten uebersprungen (Dev/Test installiert jq)."; return 1; }
  _bootstrap_wait_health || true

  local jar; jar="$(mktemp /tmp/n8n_owner_cookies.XXXXXX)"; chmod 600 "$jar"   # Session-Cookie nie world-readable
  # Session beschaffen: erst Login (Owner existiert), sonst Owner-Setup (frische Instanz).
  if _owner_login "$jar"; then
    log "Bestehender n8n-Owner eingeloggt."
  elif _owner_setup "$jar"; then
    :
  else
    rm -f "$jar"
    warn "Keine n8n-Session (Login + Owner-Setup fehlgeschlagen, Grund oben) -> API-Key nicht geminted."
    return 1
  fi

  # Scopes sind seit n8n 2.x Pflicht im CreateApiKeyRequestDto. Die fuer den Owner gueltige Liste
  # liefert n8n selbst -> GET /rest/api-keys/scopes (versions-proof, exakt wie es die UI macht).
  # Voller Owner-Scope = Vollzugriff (Community erzwingt Scopes nicht, aber das DTO verlangt das Array).
  local scopes
  scopes="$(curl -sS --max-time 10 -b "$jar" "${N8N_URL}/rest/api-keys/scopes" 2>/dev/null | jq -c '.data // .' 2>/dev/null || true)"
  case "$scopes" in ''|null) scopes='[]' ;; esac

  # API-Key anlegen. Antwort-Shape variiert je n8n-Version -> defensiv mehrere Felder probieren.
  # -w fuer den HTTP-Code (Diagnose); ein 2xx-Body kann den Key enthalten -> nur Fehler-Body loggen.
  local resp code key
  resp="$(curl -sS --max-time 10 -b "$jar" -o - -w '\n%{http_code}' -X POST "${N8N_URL}/rest/api-keys" \
              -H 'content-type: application/json' \
              --data "$(jq -nc --argjson s "$scopes" '{label:"life-agents-provisioning", expiresAt:null, scopes:$s}')" 2>/dev/null || true)"
  rm -f "$jar"
  code="$(printf '%s' "$resp" | tail -n1)"
  key="$(printf '%s' "$resp" | sed '$d' | jq -r '.data.rawApiKey // .data.apiKey // .rawApiKey // .apiKey // empty' 2>/dev/null || true)"
  if [ -z "$key" ]; then
    local fbody; fbody="$(printf '%s' "$resp" | sed '$d')"
    case "$code" in 2*) fbody="" ;; esac   # 2xx-Body kann den Key enthalten -> nie loggen
    resp=""
    warn "API-Key nicht erhalten (HTTP ${code:-?})${fbody:+: $fbody} -> Cred-/Workflow-Deploy uebersprungen."
    return 1
  fi
  resp=""   # die Roh-Antwort enthaelt den Key -> nie loggen
  N8N_API_KEY="$key"; export N8N_API_KEY
  # Persistenz zentral via _persist_owner_env (zusammen mit den RO-Passwoertern).
  ok "n8n-API-Key geminted."
}

# Telegram-Basis: rollen-skopiertes BotFather-Menue (WS-6, aus dem core-`commands`-Block) + clean slate.
# PROSA-Gotcha (n8n-Doku-Pflicht): den produktiven setWebhook (URL + secret_token) setzt n8n SELBST,
# sobald der Telegram-Trigger-Workflow aktiviert wird (deploy_workflows). Ein manueller setWebhook hier
# liefe ihm voraus und wuerde ueberschrieben -> wir beschraenken uns auf das Menue + drop_pending_updates
# (clearing). Den secret_token macht _ensure_ingress_id_key je Instanz geheim (deploy_workflows leitet die ids ab).
_wire_telegram() {
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || { log "Kein TELEGRAM_BOT_TOKEN -> Telegram-Schritt uebersprungen."; return 0; }
  need_cmd curl || { warn "curl fehlt -> Telegram-Schritt uebersprungen."; return 0; }
  # Token steckt in der Bot-API-URL -> nur ueber tg_api_curl (Config-Kanal), nie im argv.

  # BotFather-Menue rollen-getrennt aus der EINEN Befehls-SoT (Owner /help+/onboarding via {type:chat},
  # Default /help via {type:default}); je Scope sofort per getMyCommands verifiziert.
  _set_bot_command_menus "$TELEGRAM_BOT_TOKEN"

  # Clean slate: haengende Updates verwerfen. Loescht einen ggf. veralteten Webhook; n8n
  # registriert ihn beim Trigger-Activate frisch (Webhook-Profil) bzw. Long-Polling kann
  # dann getUpdates nutzen (Dev). drop_pending_updates verhindert eine Alt-Nachrichten-Flut.
  if tg_api_curl "$TELEGRAM_BOT_TOKEN" deleteWebhook -fsS --max-time 10 -X POST -H 'content-type: application/json' \
       --data '{"drop_pending_updates":true}' >/dev/null 2>&1; then
    ok "Telegram-Webhook-State bereinigt (drop_pending_updates)."
  else
    warn "Telegram deleteWebhook fehlgeschlagen — unkritisch."
  fi
}

# Owner-Person-Skelett seeden (idempotent: ON CONFLICT DO NOTHING). Ohne Identitaetsfelder kann der
# Owner spaeter nicht pairen (consume braucht die Person) -> dann ueberspringen + warnen.
_seed_owner_skeleton() {
  if [ -z "${OWNER_FIRST_NAME:-}" ] || [ -z "${OWNER_LAST_NAME:-}" ] || [ -z "${OWNER_BIRTH_DATE:-}" ]; then
    warn "OWNER_FIRST_NAME/OWNER_LAST_NAME/OWNER_BIRTH_DATE fehlen -> Owner-Skelett uebersprungen (ohne Name + Geburtsdatum kein Telegram-Pairing)."
    warn "  (Ohne vollstaendiges family-Skelett kann fn_consume_pairing_challenge nichts mergen — birth_date ist Validator-Gesetz.)"
    return 0
  fi
  local seed="$REPO_ROOT/packages/core/db/util/util_seed_owner_skeleton.sql"
  [ -f "$seed" ] || die "Seed fehlt: $seed (unvollstaendiges Paket)."

  # PII (Name/Geburtsdatum) ueber \set in einem 600-Treiber, NICHT als -v (Prozessliste). Der
  # postgres-User liest die 600/postgres-eigene Treiberdatei; die Repo-Datei bleibt root-only.
  if {
        _psql_setvar owner_first     "$OWNER_FIRST_NAME"
        _psql_setvar owner_last      "$OWNER_LAST_NAME"
        _psql_setvar owner_birth     "$OWNER_BIRTH_DATE"
        _psql_setvar owner_language  "${OWNER_LANGUAGE:-de}"   # Sprache fester Texte (Textkatalog), Standard Deutsch
        _psql_setvar owner_persona   "${OWNER_PERSONA:-neutral}"   # Bot-Charakter (Skelett schreibt nur gueltige, nie neutral)
        _psql_setvar owner_person_id "${OWNER_PERSON_ID:-owner}"
        cat "$seed"
      } | _owner_psql_driver; then
    ok "Owner-Person-Skelett gesichert (family)."
  else
    warn "Owner-Skelett-Seed fehlgeschlagen — Telegram-Pairing ist so nicht moeglich (Details im Protokoll)."
  fi
}

# _arm_owner_challenge <code> — Owner-Pairing-Code in der DB armieren; das jsonb-Ergebnis von
# fn_arm_pairing_challenge ({ok, expires_at} bzw. {ok:false, reason}) auf STDOUT. Gibt NICHTS aus — die
# Anzeige (Deep-Link + Warten) macht owner_connect_guided am ENDE des Laufs, wenn der Bot erreichbar ist
# (Install-UX-Phase 3: frueher stand die Code-Box mitten im Lauf, vor der Webhook-Aktivierung, und war
# bis zum Ende abgelaufen). fn_arm guardt selbst: bereits gepairter Owner -> {ok:false}; ein neuer Code
# ersetzt eine offene Owner-Challenge. Code via \set im 600-Treiber (nie als -v / argv).
_arm_owner_challenge() {
  { _psql_setvar code "$1"
    printf "SELECT agent.fn_arm_pairing_challenge(jsonb_build_object('role','owner','challenge', :'code'));\n"
  } | _owner_psql_driver -At 2>/dev/null || true
}

# core.backup_key-Backup-Key sicherstellen: generiert einen backup_encryption_key, falls NOCH KEINER
# da ist (ON CONFLICT DO NOTHING — NIE rotieren, sonst werden bereits erstellte Export-Backups
# unentschluesselbar). Lebt sync-frei in der DB (packages/core/CLAUDE.md Backup/Restore), ACL-gefenct gegen
# die Leserollen. Generiert via openssl rand; Wert NUR ueber den 600-Treiber (Secret, kein argv-Leak).
_ensure_backup_secret() {
  local val; val="$(rand_hex 32)"
  if { _psql_setvar bkey "$val"
       printf "INSERT INTO core.backup_key(key, value) VALUES ('backup_encryption_key', :'bkey') ON CONFLICT (key) DO NOTHING;\n"
     } | _owner_psql_driver >/dev/null 2>&1; then
    ok "core.backup_key backup_encryption_key sichergestellt (generiert, falls fehlend; bestehender unberuehrt)."
  else
    warn "core.backup_key backup_encryption_key konnte nicht gesetzt werden — provision.sh erneut laufen lassen (bzw. den Key als Credential-Owner direkt per psql in core.backup_key eintragen); Export/Restore bleibt bis dahin ungenutzt."
  fi
}

# Eingangs-Schluessel INGRESS_ID_KEY sicherstellen (Security-Audit 2026-10): n8n prueft echte Telegram-Zustellungen ueber
# secret_token = <workflowId>_<nodeId> auf der Route <webhookId>/webhook — im Repo build-stabil und damit oeffentlich.
# deploy_workflows leitet beide ids des telegramTrigger je Instanz aus diesem Schluessel ab. EINMAL erzeugen, nie
# rotieren (sonst re-registriert jeder Deploy den Webhook neu); Wert nur ueber env_upsert (kein argv).
_ensure_ingress_id_key() {
  if [ -n "$(read_env_value "$N8N_OWNER_ENV_FILE" INGRESS_ID_KEY || true)" ]; then return 0; fi
  env_upsert "$N8N_OWNER_ENV_FILE" INGRESS_ID_KEY "$(rand_hex 32)"
  chmod 0640 "$N8N_OWNER_ENV_FILE" 2>/dev/null || true; chown "root:${N8N_USER}" "$N8N_OWNER_ENV_FILE" 2>/dev/null || true
  ok "Eingangs-Schlüssel erzeugt (core.env) — die Telegram-Eingangsadresse ist je Installation geheim."
}

bootstrap_owner() {
  [ -n "${N8N_DB_NAME:-}" ] || die "N8N_DB_NAME nicht gesetzt."
  [ -n "${N8N_URL:-}" ]     || die "N8N_URL nicht gesetzt."
  require_cmd runuser

  log "Owner-Bootstrap (Owner-Setup + API-Key + RO-Rollen + Backup-Key + Telegram-Basis + Pairing) ..."
  _load_owner_env_state    # Reuse bestehender Secrets (API-Key + RO-Passwoerter) aus core.env
  _resolve_owner_creds
  _provision_ro_secrets    # RO-Rollen-Passwoerter setzen + fuer inject_credentials exportieren
  _ensure_backup_secret    # core.backup_key Backup-Key (idempotent, nie rotieren)
  _mint_api_key || true
  _persist_owner_env       # kohaerent persistieren (API-Key + RO-Passwoerter)
  _ensure_ingress_id_key   # geheime Telegram-Eingangs-ids je Instanz (deploy_workflows)
  _wire_telegram
  _seed_owner_skeleton
  # Kein Pairing-Code mehr hier: der kommt im gefuehrten Ende (owner_connect_guided), sobald der Bot
  # erreichbar ist. Ohne TTY: `lifeagents household pair-owner` (derselbe Ablauf).
  ok "Owner-Bootstrap abgeschlossen."
}
