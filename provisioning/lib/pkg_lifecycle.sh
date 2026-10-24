# pkg_lifecycle.sh — CLI-Lebenszyklus der Fach-Pakete (Core/Package-Architektur).
# SOURCED (kein Shebang, kein `set -e` — der Top-Aufrufer `lifeagents` traegt den Error-Mode).
#
# Voll verdrahtet (Phasen 1/4a/5): Verb-Dispatch + die Prereq-/Dep-/core_api-GATES (gegen die DB-
# Wahrheit core.package_registry + core.fn_pkg_*); read-only-Verben (catalog/list/doctor); die reinen
# Status-Flips (activate/deactivate); **install** (Phase 5, der per-Paket-Zustandsfluss Gate->Migration->
# Rollen->Credentials->Seed->Deploy->active, dpkg-analog installing->active) und **uninstall**
# (Phase 4a, --keep-data|--purge). Der install-Pfad ist DERSELBE Code, den provision.sh je gebuendeltem
# Nicht-Core-Paket aufruft (ein Code-Pfad, zwei Aufrufer) und den die Restore-vor-Install nutzt.
#
# Aufruf: `lifeagents package <verb> [args]` (die CLI sourct diese Datei + common.sh).
# DB-Zugriff: postgres-Superuser via runuser/Peer-Auth am lokalen Socket (wie apply_schema.sh).

DB_SUPERUSER="${DB_SUPERUSER:-postgres}"

# Paket-Quelle (_pkg_dir) + Katalog-Texte (pkg_text/pkg_display_name) leben in common.sh.

# N8N_DB_NAME aus der n8n.env ableiten (Runtime-CLI laeuft ausserhalb von provision.sh) — eine Adresse: common.sh.
_pkg_resolve_db() { lifeagents_db_name >/dev/null; }

# _pkg_psql_scalar <sql>  -> einzelner Skalar auf stdout (leer wenn NULL/keine Zeile).
_pkg_psql_scalar() {
  _pkg_resolve_db
  runuser -u "$DB_SUPERUSER" -- psql -v ON_ERROR_STOP=1 -X -tA -d "$N8N_DB_NAME" -c "$1"
}

# _pkg_psql_exec <sql>  -> SQL ausfuehren (Rueckgabe verworfen; Fehler -> nonzero via ON_ERROR_STOP).
_pkg_psql_exec() {
  _pkg_resolve_db
  runuser -u "$DB_SUPERUSER" -- psql -v ON_ERROR_STOP=1 -X -q -d "$N8N_DB_NAME" -c "$1"
}

# _pkg_name_ok <name>  -> 0 wenn ^[a-z][a-z0-9_]*$ (= Schema-/Rollen-Praefix-Vertrag, docs/package-contract.md §2).
_pkg_name_ok() { printf '%s' "$1" | grep -qE '^[a-z][a-z0-9_]*$'; }

# _pkg_manifest_field <pkg> <jq-filter>  -> Feldwert aus dem Manifest (oder leer).
#   Caller stellen jq via require_cmd sicher (catalog/install); hier hart, damit die Helfer-fn
#   nicht still ein leeres Feld liefert, falls ein kuenftiger Verb das require_cmd vergisst.
_pkg_manifest_field() {
  local mf; mf="$(_pkg_dir)/$1/manifest.json"
  [ -r "$mf" ] || return 1
  require_cmd jq
  jq -r "$2 // empty" "$mf" 2>/dev/null
}

# _pkg_catalog_rows -> TAB-Zeilen "pkg<TAB>version<TAB>status<TAB>beschreibung" ueber den Manifest-
# Katalog (Status aus der Registry, '—' = nicht registriert). Die EINE maschinenlesbare Quelle fuer
# pkg_cmd_catalog (Anzeige) UND die ui_choose-Picker — nie Anzeige-Output parsen (Plan-Kritik C9).
_pkg_catalog_rows() {
  local dir mf pkg ver desc status
  dir="$(_pkg_dir)"
  [ -d "$dir" ] || return 0
  require_cmd jq
  for mf in "$dir"/*/manifest.json; do
    [ -r "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf")"; ver="$(jq -r '.version // empty' "$mf")"
    # Install-UX-Phase 6: Anzeigename + deutscher Owner-Einzeiler aus dem Textkatalog (Fallback: die englische description).
    desc="$(pkg_text "$pkg" package.summary)"; [ -n "$desc" ] || desc="$(jq -r '.description // ""' "$mf")"; desc="$(pkg_display_name "$pkg") — $desc"
    # Name gegen den Schema-/Rollen-Vertrag pruefen, BEVOR er in die SQL-Query interpoliert wird
    # (ein kaputter Manifest-Name liefe sonst in einen Syntaxfehler statt eines sauberen Skip).
    _pkg_name_ok "$pkg" || { warn "Manifest '$mf': ungueltiger Paketname '$pkg' — uebersprungen."; continue; }
    status="$(_pkg_psql_scalar "SELECT status FROM core.package_registry WHERE package = '${pkg//\'/\'\'}'" || true)"
    printf '%s\t%s\t%s\t%s\n' "$pkg" "$ver" "${status:-—}" "$desc"
  done
}

# _pkg_registry_rows -> TAB-Zeilen "pkg<TAB>version<TAB>status<TAB>beschreibung" aus der Registry
# (Picker-Quelle; `|| true`: fehlendes Schema liefert leer -> der Picker faellt auf die Usage zurueck).
_pkg_registry_rows() {
  _pkg_psql_scalar "SELECT package || E'\t' || version || E'\t' || status || E'\t' || description FROM core.package_registry ORDER BY package" || true
}

# --- catalog: verfuegbare Pakete (Name · Version · Beschreibung · Installations-Status) -------------
pkg_cmd_catalog() {
  local dir; dir="$(_pkg_dir)"
  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null || true)" ]; then
    log "Keine Pakete im Katalog (kein packages/<pkg>/manifest.json im Baum gefunden)."
    return 0
  fi
  require_cmd jq
  printf '%-16s %-10s %-10s %s\n' "PAKET" "VERSION" "STATUS" "BESCHREIBUNG"
  local pkg ver status desc
  while IFS=$'\t' read -r pkg ver status desc; do
    [ -n "$pkg" ] || continue
    printf '%-16s %-10s %-10s %s\n' "$pkg" "$ver" "$status" "$desc"
  done <<<"$(_pkg_catalog_rows)"
}

# --- list: installierte Pakete + Status (aus der Registry) ------------------------------------------
pkg_cmd_list() {
  local rows
  rows="$(_pkg_psql_scalar "SELECT format('%-16s %-10s %-10s %s', package, version, status, description) FROM core.package_registry ORDER BY package")" || {
    die "Registry-Abfrage fehlgeschlagen (Schema angewandt?)."
  }
  if [ -z "$rows" ]; then log "Kein Paket installiert."; return 0; fi
  printf '%-16s %-10s %-10s %s\n' "PAKET" "VERSION" "STATUS" "BESCHREIBUNG"
  printf '%s\n' "$rows"
}

# --- _pkg_gate_install: Prereq + Dep + core_api VOR jeder Mutation (npm/apt-Standard) --------------
# Gibt 0 zurueck, wenn das Paket installiert werden DARF; sonst nonzero mit Begruendung.
_pkg_gate_install() {
  local pkg="$1"
  _pkg_name_ok "$pkg" || { err "Ungueltiger Paketname (erwarte ^[a-z][a-z0-9_]*$): $pkg"; return 1; }

  # PREREQ: der Core muss vollstaendig + aktiv sein (DEP1).
  local core_status
  core_status="$(_pkg_psql_scalar "SELECT status FROM core.package_registry WHERE package = 'core'" || true)"
  if [ "$core_status" != "active" ]; then
    err "Prereq nicht erfuellt: Core ist nicht 'active' (status=${core_status:-fehlt}). Erst Core installieren."
    return 1
  fi

  # Manifest-getriebene Dep-/core_api-Pruefung (DEP2/DEP3) via core.fn_pkg_check_deps.
  local core_api requires_json
  core_api="$(_pkg_manifest_field "$pkg" '.core_api')"
  requires_json="$(_pkg_manifest_field "$pkg" '.requires')"
  [ -n "$requires_json" ] || requires_json='[]'
  [ -n "$core_api" ]      || core_api=''

  local payload res
  payload="$(jq -cn --arg p "$pkg" --arg api "$core_api" --argjson req "$requires_json" \
    '{package:$p, core_api:$api, requires:$req}')" || { err "Konnte Dep-Check-Payload nicht bauen."; return 1; }
  res="$(_pkg_psql_scalar "SELECT (core.fn_pkg_check_deps('${payload//\'/\'\'}'::jsonb))::text")" || { err "Dep-Check (fn_pkg_check_deps) fehlgeschlagen."; return 1; }

  if ! printf '%s' "$res" | jq -e '.ok == true' >/dev/null 2>&1; then
    err "Install-Gate fehlgeschlagen fuer '$pkg':"
    printf '%s' "$res" | jq -r '
      (if (.core_api_ok|not) then "  - core_api inkompatibel: braucht \(.required_core_api), Core ist \(.current_core_api)" else empty end),
      (if (.missing_deps|length)  > 0 then "  - fehlende Abhaengigkeiten: \(.missing_deps|join(\", \"))"  else empty end),
      (if (.inactive_deps|length) > 0 then "  - inaktive Abhaengigkeiten: \(.inactive_deps|join(\", \"))" else empty end)
    ' 2>/dev/null >&2 || printf '%s\n' "$res" >&2
    return 1
  fi
  ok "Install-Gate gruen fuer '$pkg' (Prereq + Deps + core_api)."
  return 0
}

# --- _pkg_resolve_env: Laufzeit-Umgebung fuer den per-Paket-Install (Provision- UND Standalone-CLI-Kontext) -
# Setzt die Globals, die apply_schema/seed_data/inject/deploy erwarten. In provision.sh sind sie schon
# gesetzt (keine Ueberschreibung); im CLI-Kontext leitet sie sie aus dem gespiegelten Baum + n8n.env +
# /etc/lifeagents/core.env ab (B1: n8n-Erreichbarkeit; D8: API-Key aus core.env).
_pkg_resolve_env() {
  [ -n "${REPO_ROOT:-}" ] || REPO_ROOT="${LIFEAGENTS_LIB:-/usr/local/lib/lifeagents}"
  export REPO_ROOT
  _pkg_resolve_db   # N8N_DB_NAME
  : "${N8N_ENV_FILE:=/etc/n8n/n8n.env}"
  : "${N8N_USER:=n8n}"
  [ -n "${N8N_DB_USER:-}" ] || N8N_DB_USER="$(read_env_value "$N8N_ENV_FILE" DB_POSTGRESDB_USER || true)"
  if [ -z "${N8N_API_KEY:-}" ]; then
    N8N_API_KEY="$(read_env_value "${N8N_OWNER_ENV_FILE:-/etc/lifeagents/core.env}" N8N_API_KEY || true)"
  fi
  if [ -z "${N8N_PORT:-}" ]; then
    N8N_PORT="$(read_env_value "$N8N_ENV_FILE" N8N_PORT || true)"; [ -n "${N8N_PORT:-}" ] || N8N_PORT=5678
  fi
  N8N_URL="${N8N_URL:-http://127.0.0.1:${N8N_PORT}}"
  export N8N_DB_NAME N8N_ENV_FILE N8N_USER N8N_DB_USER N8N_API_KEY N8N_URL N8N_PORT
}

# --- Paket-Secrets-Wizard (Stage 4, Install-UX-Phase; docs/package-contract.md §3.8) ----------------
# Manifest-`credentials`-Block = DEKLARATION (Paket); dieser Wizard + inject_package_credentials =
# AUSFUEHRUNG (Host, generisch — kein Paket-Literal, Naht-Guard-gelintet).

# _pkg_validator_fn <enum>  -> Name der Validator-fn (release_inputs.sh). GESCHLOSSENES Enum
#   (arch-challenge E3.3: Name-Bindung wie context_validators, NIE ausfuehrbarer Code im Manifest);
#   contract_lint prueft deklarierte Werte schon beim Commit. Unbekannt -> nonzero (Aufrufer warnt).
_pkg_validator_fn() {
  case "$1" in
    none|'')              printf '_validate_any' ;;
    url)                  printf '_validate_url' ;;
    email)                printf '_validate_email' ;;
    live_check:telegram)  printf '_validate_telegram' ;;
    live_check:google)    printf '_validate_google' ;;
    live_check:anthropic) printf '_validate_anthropic' ;;
    *) return 1 ;;
  esac
}

# _pkg_migrate_legacy_env <pkg> <envf>  — Einmal-Migration (Opus-Review F3): vor der Install-UX-Phase
#   lebten Paket-Secret-Keys im HOST-Store core.env (_INSTALL_ENV_KEYS-Aera). Generisch fuer jeden
#   deklarierten env-Key: non-empty in core.env + noch KEINE Zeile in <pkg>.env -> Wert uebernehmen
#   + aus core.env entfernen (ein Schreiber pro Datei, Secret-Modell §3.0a). Evidenz sagt dormant
#   (Owner-Keys nie angelegt, kein lebendes Prod), aber die Zeilen schliessen den Silent-Loss-Pfad.
_pkg_migrate_legacy_env() {
  local pkg="$1" envf="$2" coreenv="${INSTALL_ENV_FILE:-/etc/lifeagents/core.env}"
  [ -f "$coreenv" ] || return 0
  local mf k v; mf="$(_pkg_dir)/$pkg/manifest.json"
  [ -r "$mf" ] || return 0
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    env_has_key "$envf" "$k" && continue
    v="$(read_env_value "$coreenv" "$k" || true)"
    [ -n "$v" ] || continue
    env_upsert "$envf" "$k" "$v"
    env_remove_key "$coreenv" "$k"
    log "Secret-Migration: $k von core.env nach $(basename "$envf") uebernommen (Alt-Bestand der Host-Aera)."
  done <<<"$(jq -r '(.credentials // {}) | to_entries[] | select(.key != "_comment") | .value.env | keys[]' "$mf" 2>/dev/null)"
  return 0   # Loop kann mit continue-Status enden -> nie den geerbten set -e des Aufrufers triggern
}

# _pkg_secret_value <envf> <KEY> -> der wirksame Wert eines Paket-Keys: Prozess-Env, sonst <pkg>.env (leer = keiner).
#   EINE Regel fuer Persistenz, Uebersichts-Status und die „beide oder keine"-Pruefung des Wizards.
_pkg_secret_value() {
  local v="${!2:-}"
  [ -n "$v" ] || v="$(read_env_value "$1" "$2" 2>/dev/null || true)"
  printf '%s' "$v"
}

# _pkg_cred_label <pkg> <credential> -> "Paketname: Frage1 + Frage2" (dieselbe Beschriftung wie die Uebersicht).
_pkg_cred_label() {
  local mf name label='' one
  mf="$(_pkg_dir)/$1/manifest.json"
  name="$(pkg_display_name "$1")"
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    label="${label:+$label + }$(_prompt_label "$one")"
  done <<<"$(jq -r --arg c "$2" '(.credentials[$c].env // {}) | to_entries[]
      | (.value.prompt // .key)' "$mf" 2>/dev/null)"
  printf '%s: %s' "$name" "$label"
}

# _pkg_secret_ask <entry-json> <envf> <reask> — EINEN env-Key ueber _prompt_validated erfragen. Setzt
#   _PKG_SECRET_ASKED=1, wenn wirklich eine Frage gestellt wurde (UI_ASKED-Schnappschuss; UI_ASKED bleibt gesetzt).
_PKG_SECRET_ASKED=0
_pkg_secret_ask() {
  local entry="$1" envf="$2" reask="$3" ekey eprompt ehelp esec01=0 req01=0 evalidator vfn was="$UI_ASKED"
  ekey="$(jq -r '.k' <<<"$entry")"
  eprompt="$(jq -r '.prompt // (.k + ": ")' <<<"$entry")"
  ehelp="$(jq -r '.help // empty' <<<"$entry")"
  [ "$(jq -r '.secret' <<<"$entry")" = "true" ] && esec01=1
  [ "$(jq -r '.required' <<<"$entry")" = "true" ] && req01=1
  evalidator="$(jq -r '.validator' <<<"$entry")"
  if ! vfn="$(_pkg_validator_fn "$evalidator")"; then
    warn "Unbekannter validator '$evalidator' ($ekey) — Eingabe ohne Validierung."
    vfn='_validate_any'
  fi
  # reask (reconfigure/Uebersicht): dieselbe Schleife wie die Erstfrage (_prompt_validated reask=1 — Enter =
  # behalten, 3x ungueltig = alter Wert, speichert NICHT; die Persistenz-Schleife des Wizards schreibt nach der
  # letzten Antwort, damit sich ein Mehr-Key-Credential nur als Ganzes aendert).
  UI_ASKED=0
  _prompt_validated "$ekey" "$eprompt" "$esec01" "$vfn" "$req01" "$envf" "$ehelp" 0 "$reask"
  _PKG_SECRET_ASKED="$UI_ASKED"
  if [ "$was" = 1 ]; then UI_ASKED=1; fi
  return 0
}

# _pkg_secrets_wizard <pkg> <envf> [reask] [credential]  — die manifest-deklarierten env-Keys erfragen.
#   env-override-first -> SEEN-Gate (KEY=-Zeile in <pkg>.env, debconf) -> interaktiv (ui_interactive:
#   TTY ∧ ¬UNATTENDED — kein Prompt erreicht je den unattended-Pfad). Optional + Enter = skip mit
#   Nachtrag-Hinweis; required + non-interaktiv failt spaeter fail-fast im Inject. reask=1
#   (reconfigure, Uebersicht vor dem Installieren): auch gesetzte Keys erneut anbieten — Enter = behalten; ein Secret
#   wird NIE angezeigt, ein secret:false-Wert als Vorgabe (debconf-Standard, Install-UX-Phase 7). credential = nur die
#   env-Keys DIESES Credentials (Uebersicht „Eine Angabe ändern": Mehr-Key-Credentials gemeinsam). Persistenz: Wert
#   bzw. leere Seen-Zeile nach <pkg>.env (640 root:n8n), im reask-Fall erst nach der letzten Antwort.
_pkg_secrets_wizard() {
  local pkg="$1" envf="$2" reask="${3:-0}" only="${4:-}"
  local mf; mf="$(_pkg_dir)/$pkg/manifest.json"
  [ -r "$mf" ] || return 0
  jq -e '(.credentials // {}) | [to_entries[] | select(.key != "_comment")] | length > 0' "$mf" >/dev/null 2>&1 || return 0
  _pkg_migrate_legacy_env "$pkg" "$envf"
  if ! ui_interactive; then
    log "Paket-Secrets ($pkg): keine interaktive Eingabe (unattended/kein TTY) — Env-/Store-Werte werden genutzt, Fehlendes skippt graceful."
    return 0
  fi
  # Kein Sektions-Banner im Install-Pfad (Install-UX-Phase 4, Runde 2): jede WIRKLICH gestellte Frage bringt
  # ihre eigene Erklaer-Box mit (_prompt_validated <help>); ist alles schon beantwortet, bleibt es still.
  # Nur `reconfigure` (reask, ganzes Paket) fragt bewusst alles erneut -> dort ein Banner mit dem Paketnamen.
  [ "${UI_QUIET:-0}" = 1 ] || ensure_gum
  if [ "$reask" -eq 1 ] && [ -z "$only" ]; then
    local _pname; _pname="$(pkg_text "$pkg" package.name)"
    ui_section "Zugangsdaten: ${_pname:-$pkg}"
  fi
  # „Beide oder keine" schon beim Fragen (§3.8 Atomaritaet, gilt nur fuer OPTIONALE Zugaenge mit >1 Key): bleibt der
  # ERSTE Key leer, fragt der Wizard den Rest nicht; ist der Zugang am Ende halb ausgefuellt und wurde in DIESEM Aufruf
  # etwas gefragt, folgt „Nochmal eingeben / Zugang auslassen" (reask: „Nichts ändern"). „Leer" = Endzustand
  # (_pkg_secret_value), nie „wurde gefragt" — der Wizard laeuft je Installation zweimal und nach Strg-C erneut.
  local entry ekey ecred eidx en req01 skip_rest=0 asked_cred=0 suppressed=0 cname choice e k v
  local -a grp=()
  local -A snap=()
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    ekey="$(jq -r '.k' <<<"$entry")"; ecred="$(jq -r '.cred' <<<"$entry")"
    eidx="$(jq -r '.i' <<<"$entry")"; en="$(jq -r '.n' <<<"$entry")"
    req01=0; [ "$(jq -r '.required' <<<"$entry")" = "true" ] && req01=1
    if [ "$eidx" -eq 0 ]; then skip_rest=0; asked_cred=0; suppressed=0; grp=(); snap=(); fi
    grp+=("$entry"); snap[$ekey]="$(_pkg_secret_value "$envf" "$ekey")"   # Stand VOR dieser Frage (Env, sonst Datei)
    if [ "$skip_rest" -eq 1 ] && [ -z "$(_pkg_secret_value "$envf" "$ekey")" ]; then
      # Frage unterdrueckt — Hinweis nur, wenn sie sonst wirklich gestellt worden waere (kein Nagen bei jedem update).
      if [ "$reask" -eq 1 ] || ! env_has_key "$envf" "$ekey"; then suppressed=1; fi
    else
      _pkg_secret_ask "$entry" "$envf" "$reask"
      [ "$_PKG_SECRET_ASKED" = 1 ] && asked_cred=1
      if [ "$eidx" -eq 0 ] && [ "$req01" -eq 0 ] && [ "$en" -gt 1 ] && [ -z "$(_pkg_secret_value "$envf" "$ekey")" ]; then
        skip_rest=1
      fi
    fi
    [ "$((eidx + 1))" -eq "$en" ] || continue
    # --- Gruppenende ---
    [ "$req01" -eq 0 ] && [ "$en" -gt 1 ] || continue
    cname="$(_pkg_cred_label "$pkg" "$ecred")"
    [ "$suppressed" -eq 1 ] && note "${cname}: übersprungen — dieser Zugang braucht alle Angaben; nachtragen: lifeagents reconfigure ${pkg}"
    [ "$asked_cred" -eq 1 ] || continue
    while [ "$(_pkg_review_cred_status "$pkg" "$ecred")" = 'unvollständig' ]; do
      if [ "$reask" -eq 1 ]; then
        choice="$(printf '%s\n' "Nochmal eingeben	retry" "Nichts ändern	keep" \
          | ui_choose "${cname}: unvollständig — dieser Zugang braucht alle Angaben." 0 || true)"
      else
        choice="$(printf '%s\n' "Nochmal eingeben	retry" "Zugang auslassen (Eingaben verwerfen)	drop" \
          | ui_choose "${cname}: unvollständig — dieser Zugang braucht alle Angaben." 0 || true)"
      fi
      if [ "$choice" = 'retry' ]; then
        # reask=1: der leere Key hat schon eine Seen-Zeile (Gate 2 kaeme sonst still zurueck); gespeichert wird unten.
        for e in "${grp[@]}"; do
          k="$(jq -r '.k' <<<"$e")"
          [ -n "$(_pkg_secret_value "$envf" "$k")" ] || _pkg_secret_ask "$e" "$envf" 1
        done
        continue
      fi
      # Auslassen / Nichts ändern / Esc: NUR die Eingaben dieses Aufrufs verwerfen = jeden Key auf seinen Stand vor der
      # Frage zuruecksetzen (snap) — ein schon vorher gespeicherter Wert bleibt (Phase-4-Regel: nie still leeren). Die
      # Erstfrage hat schon gespeichert (_store_answer) -> dort auch die Datei zuruecksetzen; reask schrieb nichts.
      for e in "${grp[@]}"; do
        k="$(jq -r '.k' <<<"$e")"
        printf -v "$k" '%s' "${snap[$k]:-}"; export "${k?}"
        [ "$reask" -eq 1 ] || _store_answer "$envf" "$k" "${snap[$k]:-}"
      done
      if [ "$(_pkg_review_cred_status "$pkg" "$ecred")" = 'unvollständig' ]; then
        warn "${cname}: bleibt unvollständig — dieser Zugang bleibt aus; nachtragen: lifeagents reconfigure ${pkg}"
      elif [ "$reask" -eq 0 ]; then
        note "${cname}: ausgelassen — nachtragen: lifeagents reconfigure ${pkg}"
      fi
      break
    done
  done <<<"$(jq -c --arg only "$only" '(.credentials // {}) | to_entries[] | select(.key != "_comment") | select($only == "" or .key == $only)
      | .key as $cred | .value as $c | [$c.env | to_entries[]] as $ks
      | ($ks | length) as $n | $ks | to_entries[]
      | {cred:$cred, i:.key, n:$n, k:.value.key, prompt:.value.value.prompt, help:.value.value.help,
         secret:(.value.value.secret // false), validator:(.value.value.validator // "none"), required:($c.required // false)}' "$mf")"
  # Persistenz: jeden deklarierten Key nach <pkg>.env — Wert oder leere Seen-Zeile (interaktiv
  # angeboten + uebersprungen = seen -> Zweitlauf fragt nie erneut; E2.1).
  # NIE leer ueber einen gespeicherten Wert schreiben (Install-UX-Phase 4, Datenverlust-Bug): das Seen-Gate
  # in _prompt_validated ueberspringt einen schon gespeicherten Key, OHNE ihn in die Env zu laden -> $k war
  # hier leer und ein Zweitlauf (update / package install) loeschte einen gespeicherten Paket-Schluessel.
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    v="$(_pkg_secret_value "$envf" "$k")"
    env_upsert "$envf" "$k" "$v"
  done <<<"$(jq -r '(.credentials // {}) | to_entries[] | select(.key != "_comment") | .value.env | keys[]' "$mf")"
  chmod 0640 "$envf" 2>/dev/null || true
  chown "root:${N8N_USER:-n8n}" "$envf" 2>/dev/null || true
  return 0
}

# _bundled_packages -> die gebuendelten Nicht-Core-Pakete des vorliegenden Baums ($REPO_ROOT), eins je
#   Zeile, Glob-Reihenfolge. EINE Aufzaehlung fuer die Fragen-Phase (collect_package_inputs) UND den
#   Install-Loop in provision.sh main() — die zwei Schleifen duerfen nicht driften (Install-UX-Phase 3).
_bundled_packages() {
  local d p
  for d in "$REPO_ROOT"/packages/*/; do
    p="$(basename "$d")"
    [ "$p" = "core" ] && continue
    [ -f "${d}manifest.json" ] || continue
    printf '%s\n' "$p"
  done
}

# ensure_jq_quiet — jq sicherstellen, BEVOR install_base_packages laeuft (frisches Debian hat keins; install.sh/
#   fetch_release bringen es mit, ein direkter provision.sh-Lauf nicht). Still, nie fatal (0 = jq da).
ensure_jq_quiet() {
  need_cmd jq && return 0
  { apt_update_once && apt_install jq; } >/dev/null 2>&1 || true
  need_cmd jq
}

# _installed_packages -> die installierten Nicht-Core-Pakete (jede Registry-Zeile, egal welcher Status), eins je
#   Zeile. Leer, solange es noch keine Datenbank gibt (frische Installation) — `|| true`, nie fatal.
_installed_packages() {
  need_cmd psql || return 0
  _pkg_psql_scalar "SELECT package FROM core.package_registry WHERE package <> 'core' ORDER BY package" 2>/dev/null || true
}

# _packages_to_process <spec> -> die Pakete, die ein provision.sh-Lauf anfasst (Install-UX-Phase 4, apt/dnf-
#   Muster "die installierte Menge"): alle INSTALLIERTEN (Update, Status bleibt — pkg_install_one schaltet ein
#   deaktiviertes nie still ein) + die per --packages ZUSAETZLICH gewuenschten (none|all|a,b). Ein deinstalliertes
#   Paket hat keine Registry-Zeile mehr -> bleibt weg. Sortiert nach requires (Abhaengigkeiten zuerst).
_packages_to_process() {
  local spec="${1:-none}" list
  list="$(_installed_packages)"
  case "$spec" in
    none) : ;;
    all)  list="$(printf '%s\n%s\n' "$list" "$(_bundled_packages)")" ;;
    *)    list="$(printf '%s\n%s\n' "$list" "$(printf '%s\n' "${spec//,/$'\n'}")")" ;;
  esac
  list="$(printf '%s\n' "$list" | grep -v '^$' | sort -u || true)"
  [ -n "$list" ] || return 0
  _pkg_sort_by_requires "$list"
}

# collect_package_inputs [paket…] — die Paket-Schluessel der GENANNTEN Pakete VOR der Installation erfragen
#   (Install-UX-Phase 3/4, debconf/dpkg-preconfigure-Muster: erst alle Fragen, dann unbeaufsichtigt
#   installieren). Ruft je Paket den bestehenden _pkg_secrets_wizard — kein eigener Prompt-Code; Stage 4 von
#   pkg_install_one findet danach jeden Key ueber das Seen-Gate vor und laeuft still. Nur interaktiv
#   (unattended/kein TTY: unveraendert). umask 077:
#   die <pkg>.env entstehen jetzt VOR dem n8n-User — Stage 4 setzt danach 640 root:n8n wie bisher.
#   jq fehlt auf einem frischen Debian vor install_base_packages (install.sh/fetch_release bringen ihn
#   mit, ein direkter provision.sh-Lauf nicht) -> still nachinstallieren, bevor der Wizard liest.
# --- Paket-EINSTELLUNGEN erfragen (Install-UX-Phase 4; docs/package-contract.md §3.6) -----------------------
# Ein Manifest-`.config`-Eintrag MIT `prompt` wird bei der Installation erfragt (debconf-Template-Muster; gleiches
# Vokabular wie §3.8 credentials.env: prompt/validator/help — plus optional `choices` [{value,label}] = Auswahl-
# liste statt Freitext, debconf `Choices`). Nur interaktiv; Enter/„Später" = ueberspringen (Manifest-Default
# bleibt; Nachtrag `lifeagents config set`). Schon gesetzte Werte (core.config non-empty) fragt er nie erneut.
# Antworten werden GEPUFFERT (PKG_SETTINGS_ANSWERS: pkg<TAB>category<TAB>key<TAB>value je Zeile) und erst NACH
# dem Seed geschrieben (pkg_install_one Stufe 5b) — die core.config-Zeile entsteht erst dort.
PKG_SETTINGS_ANSWERS=''

# _pkg_setting_current <category> <key> -> aktueller core.config-Wert (leer: keine DB/Zeile/leer). Nie fatal.
_pkg_setting_current() {
  need_cmd psql || return 0
  _pkg_psql_scalar "SELECT value FROM core.config WHERE category = '$1' AND key = '$2'" 2>/dev/null || true
}

# Wert der „Später festlegen"-Option einer Auswahl-Einstellung (reserviert — contract_lint 12e lehnt ihn als choices-Wert ab).
_PKG_SETTING_LATER='__later__'

# _pkg_settings_wizard <pkg> [reask] [cat.key] — die erfragbaren Paket-Einstellungen. reask=1 (Uebersicht „Eine Angabe
#   ändern", Install-UX-Phase 7): fragt auch schon gesetzte/übersprungene Einstellungen; Vorgabe = gepufferte Antwort
#   bzw. der core.config-Wert; Esc/Enter = behalten; „Später festlegen" (_PKG_SETTING_LATER, ≠ Esc) entfernt dort die
#   gepufferte Antwort; ein neuer Wert ersetzt sie und loescht eine fruehere „übersprungen"-Zeile (sonst fragte nach einem
#   Abbruch an der Uebersicht niemand mehr nach). In der Erstfrage heissen „Später festlegen" und Esc beide „übersprungen".
#   cat.key = nur diese eine Einstellung.
# shellcheck disable=SC2034  # UI_ASKED liest provision.sh (Uebersicht nur, wenn wirklich gefragt wurde)
_pkg_settings_wizard() {
  local pkg="$1" reask="${2:-0}" only="${3:-}" mf entry cat key prompt help validator choices vfn val i seenkey envf cur pre header
  mf="$(_pkg_dir)/$pkg/manifest.json"
  [ -r "$mf" ] || return 0
  ui_interactive || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    cat="$(jq -r '.cat' <<<"$entry")"; key="$(jq -r '.key' <<<"$entry")"
    printf '%s\n%s\n' "$cat" "$key" | grep -qvE '^[a-z][a-z0-9_]*$' && continue   # SQL-Identifier-Schutz
    if [ -n "$only" ] && [ "$only" != "${cat}.${key}" ]; then continue; fi
    # Seen-Gate wie _pkg_secrets_wizard (debconf): eine bewusst uebersprungene Einstellung hinterlaesst eine leere
    # CONFIG_<CAT>_<KEY>=-Zeile in <pkg>.env -> kein Update fragt sie erneut (Nachtrag: lifeagents config set).
    envf="$(lifeagents_env_file "$pkg")"; seenkey="CONFIG_$(printf "%s_%s" "$cat" "$key" | tr "[:lower:]" "[:upper:]")"
    cur=''
    if [ "$reask" = "1" ]; then
      cur="$(_pkg_setting_buffered "$pkg" "$cat" "$key")"
      [ -n "$cur" ] || cur="$(_pkg_setting_current "$cat" "$key")"
    else
      [ -n "$(_pkg_setting_current "$cat" "$key")" ] && continue                  # schon gesetzt -> nie neu fragen
      env_has_key "$envf" "$seenkey" && continue
    fi
    prompt="$(jq -r '.prompt' <<<"$entry")"
    help="$(jq -r '.help // empty' <<<"$entry")"
    validator="$(jq -r '.validator // "none"' <<<"$entry")"
    choices="$(jq -r '(.choices // [])[] | "\(.label)\t\(.value)"' <<<"$entry")"
    UI_ASKED=1
    [ -n "$help" ] && printf '%s\n' "$help" | ui_box "$prompt"
    val=''
    if [ -n "$choices" ]; then
      # EINE „Später festlegen"-Option fuer Erstfrage und Ändern-Pfad (stabiler Wert statt leer — debconf Choices-C).
      pre=''; header="$prompt"
      if [ "$reask" = "1" ]; then
        pre="$(jq -r --arg v "$cur" '(.choices // [])[] | select(.value == $v) | .label' <<<"$entry" | head -n1)"
        header="$prompt (Esc = unverändert)"
      fi
      val="$(printf '%s\nSpäter festlegen\t%s\n' "$choices" "$_PKG_SETTING_LATER" | ui_choose "$header" 0 "$pre" || true)"
      if [ "$reask" = "1" ]; then
        [ -n "$val" ] || continue                                                   # Esc = behalten
        if [ "$val" = "$_PKG_SETTING_LATER" ]; then
          _pkg_setting_unbuffer "$pkg" "$cat" "$key"
          _store_answer "$envf" "$seenkey" ""
          note "Später festlegen — mit: lifeagents config set ${cat} ${key} <wert>"
          continue
        fi
      elif [ "$val" = "$_PKG_SETTING_LATER" ]; then
        val=''                                                                      # Erstfrage: wie Esc = übersprungen
      fi
    else
      vfn="$(_pkg_validator_fn "$validator")" || vfn='_validate_any'
      i=0
      while [ "$i" -lt 3 ]; do
        if [ "$reask" = "1" ] && [ -n "$cur" ]; then
          val="$(ui_input "${prompt}: [${cur} — Enter = behalten] " 0)"
        elif [ "$reask" = "1" ]; then
          val="$(ui_input "${prompt}: " 0)"
        else
          val="$(ui_input "${prompt} (Enter = überspringen): " 0)"
        fi
        val="$(printf '%s' "$val" | tr -d '\r\n\t')"
        [ -z "$val" ] && break
        local _rc=0; "$vfn" "$val" || _rc=$?
        [ "$_rc" -eq 0 ] && break
        if [ "$_rc" -eq 2 ]; then warn "  Konnte gerade nicht online prüfen — übernommen."; break; fi
        i=$((i + 1)); val=''
        [ "$i" -lt 3 ] && warn "  Ungültige Eingabe — bitte erneut."
      done
      if [ "$i" -ge 3 ]; then
        if [ "$reask" = "1" ]; then warn "  Dreimal ungültig — die Einstellung bleibt unverändert."
        else warn "  Dreimal ungültig — diese Einstellung wird übersprungen."; fi
      fi
      if [ "$reask" = "1" ] && [ -z "$val" ]; then continue; fi                    # Enter/3x ungueltig = behalten
    fi
    if [ -n "$val" ]; then
      _pkg_setting_unbuffer "$pkg" "$cat" "$key"
      PKG_SETTINGS_ANSWERS="${PKG_SETTINGS_ANSWERS}${pkg}"$'\t'"${cat}"$'\t'"${key}"$'\t'"${val}"$'\n'
      if [ "$reask" = "1" ]; then env_remove_key "$envf" "$seenkey"; fi
    else
      note "Übersprungen — später: lifeagents config set ${cat} ${key} <wert>"
      _store_answer "$envf" "$seenkey" ""
    fi
  done <<<"$(jq -c '(.config // {}) | to_entries[] | select(.key != "_comment") | .key as $c | .value | to_entries[] | select(.value | type == "object" and has("prompt")) | {cat:$c, key:.key, prompt:.value.prompt, help:.value.help, validator:.value.validator, choices:.value.choices}' "$mf" 2>/dev/null)"
  return 0
}

# _pkg_setting_buffered <pkg> <cat> <key> -> die in diesem Lauf gepufferte Antwort (PKG_SETTINGS_ANSWERS) oder leer.
_pkg_setting_buffered() {
  [ -n "$PKG_SETTINGS_ANSWERS" ] || return 0
  printf '%s' "$PKG_SETTINGS_ANSWERS" | awk -F '\t' -v p="$1" -v c="$2" -v k="$3" '$1 == p && $2 == c && $3 == k { v = $4 } END { if (v != "") printf "%s", v }'
}

# _pkg_setting_unbuffer <pkg> <cat> <key> — eine gepufferte Antwort entfernen (vor dem Ersetzen bzw. bei „Später").
_pkg_setting_unbuffer() {
  [ -n "$PKG_SETTINGS_ANSWERS" ] || return 0
  PKG_SETTINGS_ANSWERS="$(printf '%s' "$PKG_SETTINGS_ANSWERS" | awk -F '\t' -v p="$1" -v c="$2" -v k="$3" '!($1 == p && $2 == c && $3 == k)')"
  if [ -n "$PKG_SETTINGS_ANSWERS" ]; then PKG_SETTINGS_ANSWERS="${PKG_SETTINGS_ANSWERS}"$'\n'; fi
  return 0
}

# --- Uebersicht vor dem Installieren: Paket-Punkte (Install-UX-Phase 7; die Engine lebt in release_inputs.sh) ---------
# _pkg_review_items <pkg> -> Uebersichts-Zeilen "cred<TAB>pkg<TAB>credential<TAB>label" je Credential (alle nicht
#   generierten env-Keys gemeinsam) + "setting<TAB>pkg<TAB>cat.key<TAB>label" je erfragbarer Einstellung. Beschriftung
#   = Paketname + die Frage-Beschriftungen (_pkg_cred_label / _prompt_label, EINE Quelle mit den Wizards).
_pkg_review_items() {
  local pkg="$1" mf name cred ck prompt
  mf="$(_pkg_dir)/$pkg/manifest.json"
  [ -r "$mf" ] || return 0
  name="$(pkg_display_name "$pkg")"
  while IFS= read -r cred; do
    [ -n "$cred" ] || continue
    printf 'cred\t%s\t%s\t%s\n' "$pkg" "$cred" "$(_pkg_cred_label "$pkg" "$cred")"
  done <<<"$(jq -r '(.credentials // {}) | to_entries[] | select(.key != "_comment")
      | select([.value.env | to_entries[]] | length > 0) | .key' "$mf" 2>/dev/null)"
  while IFS=$'\t' read -r ck prompt; do
    [ -n "$ck" ] || continue
    printf 'setting\t%s\t%s\t%s: %s\n' "$pkg" "$ck" "$name" "$(_prompt_label "$prompt")"
  done <<<"$(jq -r '(.config // {}) | to_entries[] | select(.key != "_comment") | .key as $c | .value | to_entries[]
      | select(.value | type == "object" and has("prompt")) | "\($c).\(.key)\t\(.value.prompt)"' "$mf" 2>/dev/null)"
  return 0
}

# _pkg_review_cred_status <pkg> <credential> -> gesetzt | unvollständig | übersprungen (nie der Wert).
_pkg_review_cred_status() {
  local mf envf k n=0 nset=0
  mf="$(_pkg_dir)/$1/manifest.json"; envf="$(lifeagents_env_file "$1")"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    n=$((n + 1))
    if [ -n "$(_pkg_secret_value "$envf" "$k")" ]; then nset=$((nset + 1)); fi
  done <<<"$(jq -r --arg c "$2" '(.credentials[$c].env // {}) | keys_unsorted[]' "$mf" 2>/dev/null)"
  if [ "$nset" -eq 0 ]; then printf 'übersprungen'
  elif [ "$nset" -lt "$n" ]; then printf 'unvollständig'
  else printf 'gesetzt'; fi
  return 0
}

# _pkg_review_setting_status <pkg> <cat.key> -> Wert (bei Auswahllisten dessen Beschriftung) bzw. „später festlegen".
_pkg_review_setting_status() {
  local pkg="$1" cat="${2%%.*}" key="${2#*.}" mf v label
  mf="$(_pkg_dir)/$pkg/manifest.json"
  v="$(_pkg_setting_buffered "$pkg" "$cat" "$key")"
  [ -n "$v" ] || v="$(_pkg_setting_current "$cat" "$key")"
  if [ -z "$v" ]; then printf 'später festlegen'; return 0; fi
  label="$(jq -r --arg c "$cat" --arg k "$key" --arg v "$v" '(.config[$c][$k].choices // [])[] | select(.value == $v) | .label' "$mf" 2>/dev/null | head -n1)"
  printf '%s' "${label:-$v}"
  return 0
}

# _pkg_has_questions <pkg…> -> 0, wenn mindestens ein Paket erfragbare Zugangsdaten oder Einstellungen
#   (`.config` mit prompt) deklariert — nur dann zeigt `package install` die Uebersicht.
_pkg_has_questions() {
  local p mf
  for p in "$@"; do
    mf="$(_pkg_dir)/$p/manifest.json"
    [ -r "$mf" ] || continue
    if jq -e '([(.credentials // {}) | to_entries[] | select(.key != "_comment") | .value.env | to_entries[]] | length > 0)
              or ([(.config // {}) | to_entries[] | select(.key != "_comment") | .value | to_entries[] | select(.value | type == "object" and has("prompt"))] | length > 0)' \
         "$mf" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# _pkg_apply_settings <pkg> — die gepufferten Antworten dieses Pakets schreiben (UPDATE-only wie
# `lifeagents config set`; die Zeile legt der Seed an). Ein abgelehnter Wert (z. B. Modell-Trigger) -> warn.
_pkg_apply_settings() {
  local pkg="$1" p c k v
  [ -n "$PKG_SETTINGS_ANSWERS" ] || return 0
  while IFS=$'\t' read -r p c k v; do
    [ "$p" = "$pkg" ] && [ -n "$c" ] || continue
    if _pkg_psql_exec "UPDATE core.config SET value = '${v//\'/\'\'}' WHERE category = '${c}' AND key = '${k}' AND package = '${pkg}'"; then
      ok "Einstellung ${c}.${k} gesetzt."
    else
      warn "Einstellung ${c}.${k} wurde abgelehnt — später: lifeagents config set ${c} ${k} <wert>"
    fi
  done <<<"$PKG_SETTINGS_ANSWERS"
  return 0
}

collect_package_inputs() {
  ui_interactive || return 0
  local pkgs pkg old_umask
  pkgs="$(printf '%s\n' "$@" | grep -v '^$' || true)"
  [ -n "$pkgs" ] || return 0
  ensure_jq_quiet || { warn "jq fehlt und liess sich nicht installieren — Paket-Zugangsdaten werden später je Paket gefragt."; return 0; }
  old_umask="$(umask)"; umask 077
  ensure_lifeagents_dir
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    _pkg_secrets_wizard "$pkg" "$(lifeagents_env_file "$pkg")" 0
    _pkg_settings_wizard "$pkg"
  done <<<"$pkgs"
  umask "$old_umask"
  return 0
}

# _pkg_sort_by_requires <liste> -> die newline-Liste so sortiert, dass ein markiertes Paket NACH
# seinen ebenfalls markierten requires laeuft (Best-effort-Topo fuer den Batch-Install; Zyklen/
# Unaufloesbares haengt unveraendert hinten an — der eigentliche Dep-Waechter bleibt _pkg_gate_install,
# und ein Re-Run konvergiert wie beim provision.sh-Bundle).
_pkg_sort_by_requires() {
  local remaining="$1" sorted="" progress=1 next p r blocked
  while [ -n "$remaining" ] && [ "$progress" -eq 1 ]; do
    progress=0; next=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      blocked=0
      for r in $(_pkg_manifest_field "$p" '(.requires // [])[]' || true); do
        if printf '%s\n' "$remaining" | grep -qx "$r"; then blocked=1; break; fi
      done
      if [ "$blocked" -eq 0 ]; then
        sorted="${sorted:+$sorted
}$p"; progress=1
      else
        next="${next:+$next
}$p"
      fi
    done <<<"$remaining"
    remaining="$next"
  done
  [ -n "$remaining" ] && sorted="${sorted:+$sorted
}$remaining"
  printf '%s\n' "$sorted"
}

# --- install (CLI-Eingangstuer): Auswahl -> ALLE Fragen -> ruhige Installation je Paket -> Uebersicht ----------
# Install-UX-Phase 4: `lifeagents package install` laeuft wie die Erstinstallation (debconf-preconfigure-Muster):
# erst alle Fragen aller gewaehlten Pakete (Zugangsdaten + Einstellungen), dann eine ✓/✗-Zeile je Paket (Details
# in /var/log/lifeagents/package.log), am Ende eine Uebersicht. Nicht interaktiv (unattended/kein TTY) oder
# --no-seed (Restore-vor-Install, bleibt fragelos) -> direkt pkg_install_one, Ausgabe wie bisher.
pkg_cmd_install() {
  local no_seed=0 a
  local -a pkgs=() extra=()
  for a in "$@"; do
    case "$a" in
      --no-seed) no_seed=1 ;;
      --*)       die "Unbekannte Option: $a" ;;
      *)         pkgs+=("$a") ;;
    esac
  done
  [ "$no_seed" -eq 1 ] && extra+=(--no-seed)
  # Missing-Arg-Picker (E2): ohne Paketname interaktiv den Katalog anbieten — MULTI-Select (Leertaste
  # markiert). Kandidaten = nur echte Install-Faelle: ≠ core, ohne Registry-Zeile ('—') oder haengen-
  # geblieben ('installing'); ein 'inactive' gehoert zu `activate` (Plan-Kritik A3). Abbruch/leer -> Usage.
  if [ "${#pkgs[@]}" -eq 0 ] && ui_interactive; then
    ensure_gum
    local picked p
    picked="$(_pkg_catalog_rows \
      | awk -F '\t' '$1 != "core" && ($3 == "—" || $3 == "installing") { printf "%s\t%s\n", $4, $1 }' \
      | ui_choose 'Pakete installieren (Leertaste = markieren, Enter = los):' 1)"
    while IFS= read -r p; do [ -n "$p" ] && pkgs+=("$p"); done <<<"$picked"
  fi
  [ "${#pkgs[@]}" -gt 0 ] || die "Usage: lifeagents package install <pkg>… [--no-seed]"

  local work p
  work="$(_pkg_sort_by_requires "$(printf '%s\n' "${pkgs[@]}")")"
  for p in "${pkgs[@]}"; do
    [ "$p" = "core" ] && die "Das Core-Paket wird mit dem System installiert (install.sh), nicht per 'package install'."
    _pkg_name_ok "$p" || die "Ungueltiger Paketname: $p"
    [ -r "$(_pkg_dir)/$p/manifest.json" ] || die "Paket '$p' nicht im Katalog gefunden (lifeagents package catalog)."
  done

  # Nicht-interaktiv / Restore / schon im ruhigen Lauf (provision.sh): der bisherige Weg, ohne Fragen-Phase.
  if [ "$no_seed" -eq 1 ] || ! ui_interactive || [ "${UI_QUIET:-0}" = 1 ]; then
    if [ "${#pkgs[@]}" -eq 1 ]; then pkg_install_one "${pkgs[0]}" "${extra[@]}"; return; fi
    local done_n=0 failed=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # Subshell: ein die in Paket k bricht die restlichen nicht ab (Muster provision.sh-Bundle-Loop).
      if ( pkg_install_one "$p" "${extra[@]}" ); then done_n=$((done_n + 1)); else failed="${failed:+$failed }$p"; fi
    done <<<"$work"
    [ -z "$failed" ] || { warn "Installiert: ${done_n}/${#pkgs[@]}; fehlgeschlagen: ${failed} — erneut ausführen setzt fort."; return 1; }
    return 0
  fi

  # (1) ALLE Fragen vorab (Zugangsdaten + Einstellungen), dann laeuft die Installation ohne Unterbrechung.
  local -a work_arr=()
  mapfile -t work_arr <<<"$work"
  collect_package_inputs "${work_arr[@]}"
  # (1b) Uebersicht vor dem Installieren (Install-UX-Phase 7): alle Antworten pruefen, einzeln aendern oder abbrechen
  # (Esc = abbrechen, nichts installiert) — nur wenn die Pakete ueberhaupt etwas fragen.
  if _pkg_has_questions "${work_arr[@]}"; then
    review_install_answers package "${work_arr[@]}"
    if [ "$REVIEW_RESULT" = "abort" ]; then
      printf '\nAbgebrochen — es wurde nichts installiert. Zugangsdaten sind gespeichert, Einstellungen fragt der nächste Aufruf erneut.\nWeitermachen: lifeagents package install %s\n\n' "${pkgs[*]}" >&2
      return 1
    fi
  fi

  # (2) Ruhige Ausgabe (Muster provision.sh): eine Zeile je Paket, Details ins Log. Ohne TUI-Terminal -> volle Ausgabe.
  ui_quiet_wanted 0 && ui_log_begin package
  local name ok_list="" fail_list=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    name="$(pkg_display_name "$p")"
    ui_step "Paket ${name} installieren"
    if ( pkg_install_one "$p" ); then
      ui_step_done; ok_list="${ok_list:+$ok_list, }${name}"
    else
      ui_step_fail "ein erneutes 'lifeagents package install ${p}' setzt fort"; fail_list="${fail_list:+$fail_list, }${name}"
    fi
  done <<<"$work"
  _ui_spin_stop

  # (3) Uebersicht (fd3-faehig: im ruhigen Modus aufs Terminal).
  {
    [ -n "$ok_list" ]   && printf 'Installiert und eingeschaltet: %s\n' "$ok_list"
    [ -n "$fail_list" ] && printf 'Nicht fertig geworden:        %s\n' "$fail_list"
    printf '\nDein Bot kennt die neuen Funktionen sofort. In Telegram zeigt /onboarding die neuen Bereiche zum Einrichten.\n'
    printf 'Übersprungene Zugangsdaten nachtragen: lifeagents reconfigure <paket>\n'
    printf 'Einstellungen ändern:                  lifeagents config\n'
    if [ -n "${UI_LOG_FILE:-}" ]; then printf 'Protokoll:                             %s\n' "$UI_LOG_FILE"; fi
  } | ui_box 'Pakete'
  [ -z "$fail_list" ]
}

# --- pkg_install_one: Gate -> register(installing) -> Migration -> Rollen -> Creds -> Seed -> Deploy -> active -
# Der per-Paket-Install-Zustandsfluss (dpkg-analog, zwei Status-Stufen installing->active). Idempotent;
# bei Teil-Fehler bleibt status='installing' (kein Auto-Rollback) -> ein Re-Run konvergiert. EIN Code-Pfad
# fuer provision.sh (Bundle-Loop) UND die CLI (`package install`, Restore-vor-Install via --no-seed). Fragt
# selbst nichts Neues (die Fragen-Phase liegt davor; das Seen-Gate des Wizards greift still). Sourct keine
# eigenen Libs — provision.sh + lifeagents.tpl `package` sourcen apply_schema/seed_data/inject/deploy daneben.
pkg_install_one() {
  local pkg="" no_seed=0 a
  for a in "$@"; do
    case "$a" in
      --no-seed) no_seed=1 ;;
      --*)       die "Unbekannte Option: $a" ;;
      *)         pkg="$a" ;;
    esac
  done
  [ -n "$pkg" ] || die "Usage: lifeagents package install <pkg> [--no-seed]"
  [ "$pkg" = "core" ] && die "Das privilegierte Core-Paket wird mit dem System installiert (provision.sh/install.sh), nicht per CLI."
  _pkg_name_ok "$pkg" || die "Ungueltiger Paketname: $pkg"
  require_cmd jq
  local mf; mf="$(_pkg_dir)/$pkg/manifest.json"
  [ -r "$mf" ] || die "Paket '$pkg' nicht im Katalog gefunden ($mf fehlt)."

  # Stufe 0: Gate (Prereq Core active + Dep/core_api).
  _pkg_gate_install "$pkg" || die "Install abgebrochen (Gate, siehe oben)."
  # Stufe 0b: Laufzeit-Umgebung + n8n-Erreichbarkeit (B1; Install kann ohne n8n nicht abschliessen).
  _pkg_resolve_env
  [ -n "${N8N_API_KEY:-}" ] || die "Kein N8N_API_KEY (/etc/lifeagents/core.env) — der Install braucht die n8n-REST-API. Owner-Bootstrap/Provision zuerst."

  log "Installiere Paket '$pkg'$([ "$no_seed" -eq 1 ] && printf ' (--no-seed)') ..."

  # Vorher-Status merken: ein vom Owner DEAKTIVIERTES Paket bleibt inaktiv (Install-UX-Phase 4 — vorher
  # schaltete jedes `lifeagents update` es per Stufe 7 still wieder ein). Leer = nicht installiert.
  local prior_status
  prior_status="$(_pkg_psql_scalar "SELECT status FROM core.package_registry WHERE package = '${pkg}'" 2>/dev/null || true)"

  # Stufe 1: register -> status='installing' (Lebenszyklus-Start; fn_pkg_register laesst Status bei Re-Register).
  register_package "$pkg" || die "Registrierung '$pkg' fehlgeschlagen."

  # Stufe 2: Migration (Schema-Inits->V->R + Owner-Grant aufs <pkg>-Schema), EINE psql-TX je Datei.
  apply_schema "$pkg"

  # Stufe 3: Paket-Rollen <pkg>_rw/<pkg>_ro (LOGIN ohne Passwort) + Isolation, idempotent.
  _pkg_psql_exec "DO \$do\$ DECLARE r jsonb; BEGIN r := core.fn_provision_package_roles(jsonb_build_object('package','${pkg}')); IF NOT (r->>'ok')::bool THEN RAISE EXCEPTION 'fn_provision_package_roles(%): %', '${pkg}', r; END IF; END \$do\$;" \
    || die "Rollen-Provisionierung '$pkg' fehlgeschlagen."

  # Stufe 4: Passwoerter (generisch, override-first -> /etc/lifeagents/<pkg>.env, IMMER ALTER ROLE)
  #   + Paket-Secrets-Wizard (manifest-deklarierte Fremd-API-Keys, interaktiv-gegatet; Install-UX-Phase)
  #   + ALLE Paket-n8n-Creds (2 Postgres + Manifest-Creds) id-stabil injizieren.
  ensure_lifeagents_dir
  local envf up; envf="$(lifeagents_env_file "$pkg")"; up="$(printf '%s' "$pkg" | tr '[:lower:]' '[:upper:]')"
  provision_role_password "${pkg}_rw" "$envf" "${up}_RW_PASSWORD" || warn "Passwort fuer ${pkg}_rw fehlgeschlagen -> Schreib-Credential wird uebersprungen."
  provision_role_password "${pkg}_ro" "$envf" "${up}_RO_PASSWORD" || warn "Passwort fuer ${pkg}_ro fehlgeschlagen -> Lese-Credential wird uebersprungen."
  _pkg_secrets_wizard "$pkg" "$envf" 0
  inject_package_credentials "$pkg"

  # Stufe 5: Seed paket-skopiert (config/contexts/validators/protected/onboarding/services NUR fuer <pkg>).
  #   --no-seed ueberspringt NUR <pkg>.onboarding_state (Restore bringt sie); Code-Seeds laufen IMMER.
  if [ "$no_seed" -eq 1 ]; then SEED_PKG="$pkg" SEED_SKIP_ONBOARDING=1 seed_data
  else                          SEED_PKG="$pkg" seed_data; fi
  # Stufe 5b: vorab erfragte Paket-Einstellungen (Manifest .config.prompt) in die eben geseedeten Zeilen.
  _pkg_apply_settings "$pkg"

  # Stufe 6: nur die Paket-Workflows deployen (Wortgrenze-Prefix aus provides.agents) + aktivieren.
  deploy_workflows "$pkg"

  # Stufe 7: status=active (ZULETZT, R7) -> der Pre-Router routet sofort auf das Paket. Ausnahme: war es
  # vorher 'inactive' (Owner-Entscheid `package deactivate`), bleibt es inaktiv — Install/Update aktualisiert
  # nur Code + Schema, schaltet aber nie still wieder ein.
  if [ "$prior_status" = "inactive" ]; then
    _pkg_set_status "$pkg" inactive
    ok "Paket '$pkg' aktualisiert — bleibt ausgeschaltet (einschalten: lifeagents package activate $pkg)."
  else
    _pkg_set_status "$pkg" active
    ok "Paket '$pkg' installiert + aktiv (installing->active)."
  fi
  # (Keine Einzel-Box mehr: die Uebersicht liefern pkg_cmd_install bzw. der provision.sh-End-Recap.)
}

# --- reconfigure: Paket-Secrets erneut erfragen + Credentials re-injizieren (dpkg-reconfigure-Parität) -
# Arbiter E2.4: EIGENSTAENDIGES Verb — NICHT install-Re-Run (install = Lifecycle-Anlage), NICHT unter
# `lifeagents config` (dort lebt core.config-Runtime). Re-ask erlaubt Ueberschreiben (Enter = behalten; ein Secret
# wird nie angezeigt, ein secret:false-Wert als Vorgabe — Install-UX-Phase 7); danach id-stabiler Credential-Upsert —
# KEIN Redeploy/Restart noetig (n8n liest Creds per-Execution aus Postgres). Auch erreichbar als `lifeagents reconfigure <pkg>`.
# _pkg_reconfigure_rows -> Picker-Zeilen "anzeige<TAB>pkg" der installierten Pakete MIT credentials-Block — Registry ∩
#   Manifest-jq (die Registry allein kennt den Block nicht; Plan-Kritik C4). Geteilt von `package reconfigure` und
#   `lifeagents reconfigure` (Install-UX-Phase 7). Gibt immer 0 zurueck.
_pkg_reconfigure_rows() {
  local _p _v _s _d _mf
  while IFS=$'\t' read -r _p _v _s _d; do
    [ -n "$_p" ] || continue
    [ "$_p" = "core" ] && continue
    _mf="$(_pkg_dir)/$_p/manifest.json"
    [ -r "$_mf" ] || continue
    jq -e '(.credentials // {}) | [to_entries[] | select(.key != "_comment")] | length > 0' "$_mf" >/dev/null 2>&1 || continue
    printf '%s %s (%s) — %s\t%s\n' "$_p" "$_v" "$_s" "$_d" "$_p"
  done <<<"$(_pkg_registry_rows)"
  return 0
}

pkg_cmd_reconfigure() {
  local pkg="${1:-}"
  # Missing-Arg-Picker (E3): installierte Pakete MIT credentials-Block.
  if [ -z "$pkg" ] && ui_interactive; then
    ensure_gum
    require_cmd jq
    pkg="$(_pkg_reconfigure_rows | ui_choose 'Paket-Zugangsdaten erneut erfragen:' 0)"
  fi
  [ -n "$pkg" ] || die "Usage: lifeagents package reconfigure <pkg>"
  [ "$pkg" = "core" ] && die "Das Grundsystem hat keine Paket-Zugangsdaten — die Grund-Zugänge (Internet-Adresse, Telegram-Bot, Anthropic, Google) änderst du mit 'lifeagents reconfigure core'."
  _pkg_name_ok "$pkg" || die "Ungueltiger Paketname: $pkg"
  require_cmd jq
  local mf; mf="$(_pkg_dir)/$pkg/manifest.json"
  [ -r "$mf" ] || die "Paket '$pkg' nicht im Katalog gefunden ($mf fehlt)."
  local status
  status="$(_pkg_psql_scalar "SELECT status FROM core.package_registry WHERE package = '${pkg//\'/\'\'}'" || true)"
  [ -n "$status" ] || die "Paket '$pkg' ist nicht installiert (erst: lifeagents package install $pkg)."
  if ! jq -e '(.credentials // {}) | [to_entries[] | select(.key != "_comment")] | length > 0' "$mf" >/dev/null 2>&1; then
    log "Paket '$pkg' deklariert keine Zugangsdaten (kein credentials-Block im Manifest) — nichts zu tun."
    return 0
  fi
  ui_interactive || die "reconfigure ist interaktiv (TTY noetig). Unattended-Alternative: Werte als Env-Variablen setzen bzw. in /etc/lifeagents/${pkg}.env pflegen und 'lifeagents update' fahren."
  # Strg-C mittendrin = nichts gespeichert: der Wizard schreibt erst nach der letzten Antwort (Install-UX-Phase 7).
  # shellcheck disable=SC2034  # gelesen von ui_abort (common.sh)
  UI_ABORT_MSG='Abgebrochen — nichts geändert.'
  _pkg_resolve_env   # F8b: VOR dem Inject (N8N_API_KEY/URL/ENV_FILE — sonst _inject_preflight-die)
  [ -n "${N8N_API_KEY:-}" ] || die "Kein N8N_API_KEY (/etc/lifeagents/core.env) — reconfigure braucht die n8n-REST-API."
  ensure_lifeagents_dir
  local envf; envf="$(lifeagents_env_file "$pkg")"
  # Rollen-Passwoerter aus <pkg>.env in die Prozess-Env laden (override-first): inject re-asserted
  # dann auch die 2 Postgres-Paket-Creds statt sie mit irrefuehrender Warnung zu skippen.
  local up _pw; up="$(printf '%s' "$pkg" | tr '[:lower:]' '[:upper:]')"
  _pw="$(read_env_value "$envf" "${up}_RW_PASSWORD" || true)"
  if [ -n "$_pw" ]; then eval "${up}_RW_PASSWORD=\$_pw; export ${up}_RW_PASSWORD"; fi
  _pw="$(read_env_value "$envf" "${up}_RO_PASSWORD" || true)"
  if [ -n "$_pw" ]; then eval "${up}_RO_PASSWORD=\$_pw; export ${up}_RO_PASSWORD"; fi
  _pkg_secrets_wizard "$pkg" "$envf" 1
  inject_package_credentials "$pkg"
  ok "Paket '$pkg' rekonfiguriert — Credentials id-stabil aktualisiert (sofort wirksam, kein Redeploy)."
}

# --- activate / deactivate: reiner Runtime-Status-Flip (KEIN Redeploy, KEINE Daten geloescht) ------
_pkg_set_status() {
  local pkg="$1" status="$2"
  _pkg_name_ok "$pkg" || die "Ungueltiger Paketname: $pkg"
  local payload res
  payload="$(jq -cn --arg p "$pkg" --arg s "$status" '{package:$p, status:$s}')"
  res="$(_pkg_psql_scalar "SELECT (core.fn_pkg_set_status('${payload//\'/\'\'}'::jsonb))::text")" || die "fn_pkg_set_status fehlgeschlagen."
  if ! printf '%s' "$res" | jq -e '.ok == true' >/dev/null 2>&1; then
    die "Status-Flip abgelehnt: $(printf '%s' "$res" | jq -r '.reason // .' 2>/dev/null)"
  fi
  ok "Paket '$pkg' -> status=$status (Pre-Router-Gate greift sofort, kein Redeploy)."
  # /help-Katalog + Telegram-Befehlsmenue folgen dem Paket-Status (Install-UX-Phase 4).
  _pkg_refresh_surfaces
  return 0
}

# _pkg_refresh_surfaces — /help-Katalog (seed_data.sh) + Telegram-Befehlsmenue (deploy_workflows.sh) nach
# einem Paket-Statuswechsel neu setzen (beide zeigen nur aktive Pakete). Nie fatal; _pkg_resolve_env stellt
# REPO_ROOT/N8N_DB_NAME auch im Standalone-CLI-Kontext sicher (die psql-Helfer laufen in Subshells).
_pkg_refresh_surfaces() {
  _pkg_resolve_env
  if declare -F refresh_capabilities_catalog >/dev/null; then refresh_capabilities_catalog; fi
  if declare -F refresh_bot_command_menus >/dev/null; then refresh_bot_command_menus; fi
  return 0
}
# Missing-Arg-Picker (E3): der Statusfilter folgt der Verb-Semantik (Plan-Kritik A4) —
# deactivate zeigt nur 'active' (≠ core), activate nur 'inactive'.
pkg_cmd_deactivate() {
  local pkg="${1:-}"
  if [ -z "$pkg" ] && ui_interactive; then
    ensure_gum
    pkg="$(_pkg_registry_rows \
      | awk -F '\t' '$1 != "core" && $3 == "active" { printf "%s %s — %s\t%s\n", $1, $2, $4, $1 }' \
      | ui_choose 'Paket deaktivieren (Daten bleiben, Router-Gate kappt):' 0)"
  fi
  _pkg_set_status "${pkg:?Usage: lifeagents package deactivate <pkg>}" inactive
}
pkg_cmd_activate() {
  local pkg="${1:-}"
  if [ -z "$pkg" ] && ui_interactive; then
    ensure_gum
    pkg="$(_pkg_registry_rows \
      | awk -F '\t' '$3 == "inactive" { printf "%s %s — %s\t%s\n", $1, $2, $4, $1 }' \
      | ui_choose 'Paket aktivieren:' 0)"
  fi
  _pkg_set_status "${pkg:?Usage: lifeagents package activate <pkg>}" active
}

# --- _pkg_confirm <force> <prompt> -> TTY-Rueckfrage (nur exaktes 'ja'); --yes (force=1) ueberspringt.
#   Muster wie uninstall.sh::_u_confirm (eigenstaendig: pkg_lifecycle.sh sourct uninstall.sh nicht —
#   das traegt provision.sh-Globals; KISS).
_pkg_confirm() {
  local force="$1" prompt="$2" a=""
  [ "$force" -eq 1 ] && return 0
  tty_usable || { warn "Kein TTY und kein --yes -> Abbruch (Sicherheit)."; return 1; }
  printf '%s [ja/NEIN]: ' "$prompt" > /dev/tty
  read -r a < /dev/tty
  [ "$a" = "ja" ]
}

# --- uninstall: --keep-data (Default, = apt remove) | --purge (= apt purge: + Schema/Rollen/Daten weg) -----
# Ablauf (WS-2): core-Reject -> Reverse-Dep-Guard -> Confirm -> n8n-Teardown (Workflows + 2 Paket-Creds +
#   gegateter Restart, pkg_teardown.sh) -> DB-Teardown (keep-data: nur Dereg; purge: EINE psql-TX mit
#   fn_pkg_purge_data + DROP SCHEMA CASCADE + fn_drop_package_roles + fn_pkg_remove, all-or-nothing).
pkg_cmd_uninstall() {
  local pkg="" purge=0 force=0 a
  for a in "$@"; do
    case "$a" in
      --purge)     purge=1 ;;
      --keep-data) purge=0 ;;
      --yes|-y)    force=1 ;;
      --*)         die "Unbekannte Option: $a" ;;
      *)           pkg="$a" ;;
    esac
  done
  # Missing-Arg-Picker (E3): NUR das fehlende Paket-Argument — die Flag-Schleife oben parst
  # positionsunabhaengig, und die bestehenden Confirms ('ja'/--yes) bleiben unveraendert dahinter (E8).
  if [ -z "$pkg" ] && ui_interactive; then
    ensure_gum
    pkg="$(_pkg_registry_rows \
      | awk -F '\t' '$1 != "core" { printf "%s %s (%s) — %s\t%s\n", $1, $2, $3, $4, $1 }' \
      | ui_choose 'Paket deinstallieren (Bestaetigung folgt):' 0)"
  fi
  [ -n "$pkg" ] || die "Usage: lifeagents package uninstall <pkg> [--keep-data|--purge] [--yes]"
  _pkg_name_ok "$pkg" || die "Ungueltiger Paketname: $pkg"
  require_cmd jq

  # 1) core-Reject GANZ OBEN (vor jeder Mutation/DDL): der privilegierte Host ist nie deinstallierbar.
  [ "$pkg" = "core" ] && die "Das privilegierte Core-Paket kann nicht deinstalliert werden."

  # 2) Reverse-Dep-Guard: kein AKTIVES Paket darf <pkg> in requires fuehren (sonst risse der Abbau
  #    dessen Abhaengigkeit weg — apt/dpkg-rdepends-Muster).
  local rd dependents esc="${pkg//\'/\'\'}"
  rd="$(_pkg_psql_scalar "SELECT (core.fn_pkg_reverse_deps(jsonb_build_object('package','${esc}')))::text")" \
    || die "Reverse-Dep-Pruefung (fn_pkg_reverse_deps) fehlgeschlagen."
  if ! printf '%s' "$rd" | jq -e '.ok == true' >/dev/null 2>&1; then
    die "Reverse-Dep-Pruefung abgelehnt: $(printf '%s' "$rd" | jq -r '.reason // .' 2>/dev/null)"
  fi
  dependents="$(printf '%s' "$rd" | jq -r '.dependents[]?' 2>/dev/null)"
  if [ -n "$dependents" ]; then
    err "Deinstallation abgebrochen — aktive Pakete haengen von '$pkg' ab:"
    printf '%s\n' "$dependents" | while IFS= read -r d; do [ -n "$d" ] && printf '  - %s\n' "$d" >&2; done
    die "Erst diese Pakete deinstallieren/deaktivieren."
  fi

  # 3) Confirm (destruktiv; --yes/-y ueberspringt).
  if [ "$purge" -eq 1 ]; then
    warn "PURGE '$pkg': entfernt Workflows + Credentials, DROP SCHEMA $pkg CASCADE, DROP ROLE ${pkg}_rw/${pkg}_ro"
    warn "  + alle paket-besessenen Host-Daten (Contexts/Config/Services/Validator-/Schutz-Registries). UNWIDERRUFLICH."
    _pkg_confirm "$force" "Paket '$pkg' wirklich VOLL purgen (Schema + Rollen + Daten unwiderruflich)?" || die "Abgebrochen."
  else
    log "uninstall --keep-data '$pkg': entfernt nur die Laufzeit-Artefakte (n8n-Workflows + Paket-Credentials)"
    log "  + deregistriert; Schema/Rollen/Daten bleiben (Re-Install findet sie wieder)."
    _pkg_confirm "$force" "Paket '$pkg' deinstallieren (Workflows/Credentials weg, Daten bleiben)?" || die "Abgebrochen."
  fi

  # 4) n8n-Teardown (Workflows nach provides.agents-Namenspraefix + die 2 Paket-Creds + gegateter Restart).
  #    Der Paketname selbst ist zusaetzlicher Praefix-Kandidat (agent.<pkg>.*-Pipeline-Workflows —
  #    Symmetrie zu deploy_workflows._wf_pkg_agents, paperless-WS-0 Naht 5; sonst blieben sie als Waisen).
  local agents; agents="$(_pkg_manifest_field "$pkg" "([\"$pkg\"] + [(.provides.agents // [])[] | if type==\"object\" then .name else . end]) | unique | join(\",\")")" || agents="$pkg"
  _pkgt_teardown "$pkg" "$agents"

  # 5) DB-Teardown.
  if [ "$purge" -eq 1 ]; then
    # EINE psql-Transaktion (ein DO-Block = atomar): PG-DDL (DROP SCHEMA/ROLE) ist transaktional ->
    # all-or-nothing (Atomaritaet-ist-Gesetz). Single-App-DB-Annahme: der cluster-globale DROP-ROLE-
    # Dependency-Check ist nur unter genau einer App-DB unkritisch. Ein fn-{ok:false} -> RAISE -> Rollback,
    # nichts geloescht. (KEIN CASE...1/0-Guard: ein konstantes 1/0 wird vom Planner gefaltet und faellt
    # IMMER, nicht nur im ELSE-Zweig.) DROP SCHEMA via format %I (pkg ist _pkg_name_ok-validiert).
    if _pkg_psql_exec "
DO \$do\$
DECLARE r jsonb;
BEGIN
  r := core.fn_pkg_purge_data(jsonb_build_object('package','${esc}'));
  IF NOT (r->>'ok')::bool THEN RAISE EXCEPTION 'fn_pkg_purge_data: %', r; END IF;
  EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', '${esc}');
  r := core.fn_drop_package_roles(jsonb_build_object('package','${esc}'));
  IF NOT (r->>'ok')::bool THEN RAISE EXCEPTION 'fn_drop_package_roles: %', r; END IF;
  PERFORM core.fn_pkg_remove(jsonb_build_object('package','${esc}'));
END
\$do\$;"; then
      # Secret-Modell §3.0a: die per-Paket-env-Datei mit-loeschen (rm) — spiegelt DROP SCHEMA/ROLE,
      # kein chirurgisches Heraus-Editieren (ein Schreiber pro Datei). --keep-data laesst sie stehen
      # (Re-Install reused das Passwort override-first).
      local _penv; _penv="$(lifeagents_env_file "$pkg")"
      [ -f "$_penv" ] && { rm -f "$_penv" && ok "Paket-Secrets ${_penv} entfernt."; }
      ok "Purge '$pkg' abgeschlossen: Schema + Rollen + Host-Daten + Secret-Datei entfernt, Registry dereg (atomar)."
    else
      die "Purge '$pkg' fehlgeschlagen — Transaktion zurueckgerollt, nichts geloescht."
    fi
  else
    local res
    res="$(_pkg_psql_scalar "SELECT (core.fn_pkg_remove(jsonb_build_object('package','${esc}')))::text")" \
      || die "fn_pkg_remove fehlgeschlagen."
    ok "Paket '$pkg' deinstalliert (Registry dereg, removed=$(printf '%s' "$res" | jq -r '.removed' 2>/dev/null)); Schema/Rollen/Daten bleiben."
    log "Re-Install: 'lifeagents package install ${pkg}' (redeployt Workflows + Credentials)."
  fi
  # /help-Katalog + Telegram-Befehlsmenue ohne das entfernte Paket (Install-UX-Phase 4).
  _pkg_refresh_surfaces
  return 0
}

# --- doctor: Registry <-> DB-Realitaet (read-only Orphan-Diagnose) ---------------------------------
pkg_cmd_doctor() {
  log "Paket-Registry:"
  pkg_cmd_list || true
  log "Orphan-/Konsistenz-Diagnose (Registry <-> DB-Realitaet):"
  # (a) Paket-Schemata (nicht core/agent/system) ohne aktive Registry-Zeile; (b) Rollen-Paare
  #     <x>_rw + <x>_ro ohne aktive Registry-Zeile (das _rw+_ro-Paar grenzt Host-Rollen core_ro/
  #     context_ro sauber aus — die haben kein _rw-Gegenstueck). Rein read-only (Anzeige).
  local diag
  diag="$(_pkg_psql_scalar "$(cat <<'SQL'
WITH active AS (SELECT package FROM core.package_registry WHERE status = 'active'),
     pkg_schema AS (
       SELECT nspname AS package FROM pg_namespace
        WHERE nspname NOT IN ('core','agent','public','information_schema')
          AND nspname NOT LIKE 'pg\_%'
     ),
     pkg_roles AS (
       SELECT rw.pkg FROM (
         SELECT regexp_replace(rolname,'_rw$','') AS pkg FROM pg_roles WHERE rolname ~ '_rw$'
       ) rw
       JOIN (SELECT regexp_replace(rolname,'_ro$','') AS pkg FROM pg_roles WHERE rolname ~ '_ro$') ro
         ON rw.pkg = ro.pkg
     )
SELECT string_agg(line, E'\n') FROM (
  SELECT '  [orphan-schema] Schema '||package||' ohne aktive Registry-Zeile' AS line
    FROM pkg_schema WHERE package NOT IN (SELECT package FROM active)
  UNION ALL
  SELECT '  [orphan-roles]  Rollen '||pkg||'_rw/_ro ohne aktive Registry-Zeile'
    FROM pkg_roles WHERE pkg NOT IN (SELECT package FROM active)
  UNION ALL
  SELECT '  [missing-schema] aktives Paket '||package||' ohne Schema'
    FROM active WHERE package <> 'core'
      AND package NOT IN (SELECT package FROM pkg_schema)
) s
SQL
)" 2>/dev/null || true)"
  if [ -n "$diag" ]; then printf '%s\n' "$diag" >&2; else ok "Keine Orphans (Registry deckt sich mit Schemata/Rollen)."; fi
  return 0
}

# --- Dispatcher: `lifeagents package <verb> [args]` ------------------------------------------------
pkg_lifecycle() {
  # Verb-Picker: nacktes `lifeagents package` auf TTY -> Menue statt Hilfetext; ESC/non-TTY ->
  # Hilfetext wie bisher (Exit 0, E5b). Danach greifen die Missing-Arg-Picker der Verben rekursiv
  # (durchklickbare Kette). Bei uns anders (arch-challenge 1.4) -> docs/reference/provisioning.md *Install-UX* + *Entscheidungen*.
  if [ "$#" -eq 0 ] && ui_interactive; then
    ensure_gum
    local _menu_verb
    _menu_verb="$(ui_choose 'lifeagents package — was tun?' 0 <<'MENU'
catalog — Verfügbare Pakete anzeigen	catalog
list — Installierte Pakete anzeigen	list
install — Paket(e) installieren (Mehrfach-Auswahl)	install
reconfigure — Paket-Zugangsdaten erneut erfragen	reconfigure
activate — Paket aktivieren	activate
deactivate — Paket deaktivieren	deactivate
uninstall — Paket deinstallieren (fragt vorher nach)	uninstall
doctor — Registry-Diagnose (read-only)	doctor
help — Hilfe anzeigen	help
MENU
)"
    [ -n "$_menu_verb" ] && set -- "$_menu_verb"
  fi
  local verb="${1:-help}"; shift || true
  case "$verb" in
    catalog)     pkg_cmd_catalog "$@" ;;
    list)        pkg_cmd_list "$@" ;;
    install)     pkg_cmd_install "$@" ;;
    reconfigure) pkg_cmd_reconfigure "$@" ;;
    activate)    pkg_cmd_activate "$@" ;;
    deactivate)  pkg_cmd_deactivate "$@" ;;
    uninstall)   pkg_cmd_uninstall "$@" ;;
    doctor)      pkg_cmd_doctor "$@" ;;
    help|--help|-h)
      cat >&2 <<'EOF'
lifeagents package <verb> — Fach-Pakete verwalten (Core/Package-Architektur).

  catalog                       Verfügbare Pakete (Name/Version/Status/Beschreibung).
  list                          Installierte Pakete + Status.
  install [<pkg>…] [--no-seed]  Erst alle Fragen (Zugangsdaten + Einstellungen) + Übersicht zum
                                Prüfen (einzeln ändern, Esc = abbrechen), dann je Paket
                                Gate -> Migration/Rollen/Credentials/Seed/Deploy -> aktiv. Ohne
                                Paketname: Auswahl-Liste (Mehrfachauswahl). --no-seed laesst
                                <pkg>.onboarding_state aus (Restore-vor-Install, fragt nichts).
  reconfigure <pkg>             Manifest-deklarierte Paket-Secrets erneut erfragen (Enter = behalten)
                                + Credentials id-stabil re-injizieren (dpkg-reconfigure-Analog;
                                interaktiv, kein Redeploy). Dasselbe wie `lifeagents reconfigure
                                <pkg>`; Grund-Zugänge: `lifeagents reconfigure core`.
  activate <pkg>                Paket aktivieren (Runtime-Status-Flip, kein Redeploy).
  deactivate <pkg>              Paket deaktivieren (Daten bleiben, Pre-Router-Gate kappt).
  uninstall <pkg> [--keep-data|--purge] [--yes]
                                Deinstallieren. --keep-data (Default, = apt remove): Workflows +
                                Paket-Credentials weg + dereg, Schema/Rollen/Daten bleiben. --purge
                                (= apt purge): zusätzlich DROP SCHEMA/Rollen + alle Host-Daten des
                                Pakets (atomar). --yes: ohne Rückfrage.
  doctor                        Registry-Diagnose (read-only).
EOF
      ;;
    *) err "lifeagents package: unbekannter Verb: $verb"; pkg_lifecycle help; return 1 ;;
  esac
}
