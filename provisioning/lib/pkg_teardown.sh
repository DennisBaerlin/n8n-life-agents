# pkg_teardown.sh — n8n-Laufzeit-Artefakte eines Pakets entfernen (per-Paket-Uninstall, WS-2).
# SOURCED (kein Shebang, kein `set -e` — der Top-Aufrufer `lifeagents` traegt den Error-Mode).
#
# Warum eine eigene Datei: die Runtime-CLI (`lifeagents package uninstall`) laeuft AUSSERHALB von
# provision.sh und sourct daher weder deploy_workflows.sh noch inject_credentials.sh — die n8n-REST-
# Helfer (Workflow-Liste) leben hier; Credential-Liste/-DELETE + Workflow-DELETE teilt common.sh
# (n8n_list_credentials/n8n_delete_credential/n8n_delete_workflow — auch retire_* in deploy_workflows.sh).
#
# Gegenstueck zu deploy_workflows.sh: dort werden die Paket-Workflows importiert+aktiviert, hier
# geloescht. WORKFLOW-IDENTIFIKATION ueber den live `GET /workflows`-Namen + Wort-Grenze-Praefix aus
# `provides.agents` (arch-challenge Verdikt A: Label-Selektor-Muster wie `kubectl delete -l app=<name>`;
# wir haben KEIN gespeichertes Install-Manifest, live n8n ist die Wahrheit, der getrackte Baum driftet).
# CREDENTIAL-IDENTIFIKATION aus der Rollen-Konvention `<pkg>_rw`/`<pkg>_ro` (Verdikt B: keine zweite SSOT,
# kein Manifest-Feld) -> `Postgres <pkg>_rw (read-write)` + `Postgres <pkg>_ro (read-only)`. Die geteilten
# Host-Creds (`Postgres account`/core_ro/context_ro/Telegram/LLM/Header-Auth) matchen `<pkg>_*` NICHT.
#
# GEGATETER n8n-NEUSTART (WS-B4b-Muster): wie beim Deploy raeumt n8n single-main einen bereits im Speicher
# laufenden Trigger bei DELETE NICHT ab -> ein zuvor aktiver Paket-Cron feuerte sonst weiter gegen die
# geloeschte Workflow-id. War >=1 Paket-Workflow aktiv -> einmal neu starten (frische Registrierung aus der DB).
#
# Reads/derives globals: N8N_OWNER_ENV_FILE (Default /etc/lifeagents/core.env), N8N_ENV_FILE (Default
#   /etc/n8n/n8n.env), N8N_PORT, N8N_URL, N8N_API_KEY. Reuses common.sh (log/ok/warn/require_cmd/
#   enable_start_unit/read_env_value).

# _pkgt_resolve_n8n  — N8N_API_KEY (aus core.env) + N8N_PORT (aus n8n.env, Default 5678) + N8N_URL
#   bereitstellen. Rueckgabe nonzero, wenn kein API-Key vorliegt (-> Aufrufer: warn+skip, non-fatal).
_pkgt_resolve_n8n() {
  local owner_env="${N8N_OWNER_ENV_FILE:-/etc/lifeagents/core.env}"
  local n8n_env="${N8N_ENV_FILE:-/etc/n8n/n8n.env}"
  if [ -z "${N8N_API_KEY:-}" ]; then
    N8N_API_KEY="$(read_env_value "$owner_env" N8N_API_KEY || true)"
  fi
  [ -n "${N8N_API_KEY:-}" ] || return 1
  if [ -z "${N8N_PORT:-}" ]; then
    N8N_PORT="$(read_env_value "$n8n_env" N8N_PORT || true)"
    [ -n "${N8N_PORT:-}" ] || N8N_PORT=5678
  fi
  N8N_URL="${N8N_URL:-http://127.0.0.1:${N8N_PORT}}"
  return 0
}

# _pkgt_list_workflows → ALLE Workflows als 'id<TAB>name<TAB>active'-Zeilen (cursor-paginiert).
#   GET-Fehler -> LEER (non-fatal: dann findet der Filter nichts -> kein DELETE, kein Bounce).
_pkgt_list_workflows() {
  local url="$N8N_URL/api/v1/workflows?limit=250" resp cursor
  while :; do
    resp="$(n8n_api_curl "$N8N_API_KEY" "$url" -fsS -H 'accept: application/json' 2>/dev/null)" \
      || { warn "GET /workflows fehlgeschlagen -> n8n-Teardown findet keine Workflows (manuell pruefen)."; return 0; }
    jq -r '(.data // [])[] | [.id, .name, (.active // false)] | @tsv' <<<"$resp" 2>/dev/null || true
    cursor="$(jq -r '.nextCursor // empty' <<<"$resp" 2>/dev/null || true)"
    [ -n "$cursor" ] || break
    url="$N8N_URL/api/v1/workflows?limit=250&cursor=$cursor"
  done
}

# _pkgt_pkg_cred_names <pkg> → ALLE Paket-Credential-Namen (eine pro Zeile): die zwei Postgres-Creds
#   aus der Rollen-Konvention (= dieselbe Konvention, unter der inject_credentials sie anlegt) PLUS
#   die im Manifest-`credentials`-Block deklarierten Fremd-API-Creds (Uninstall-Symmetrie, §6 —
#   was pkg_install_one Stage 4 anlegt, raeumt der Teardown auch ab). Manifest-Pfad wie _pkg_dir
#   (LIFEAGENTS_LIB im CLI-Kontext, REPO_ROOT unter provision.sh); fehlt es -> nur die 2 Rollen-Creds.
_pkgt_pkg_cred_names() {
  printf 'Postgres %s_rw (read-write)\n' "$1"
  printf 'Postgres %s_ro (read-only)\n'  "$1"
  local mf="${LIFEAGENTS_LIB:-/usr/local/lib/lifeagents}/packages/$1/manifest.json"
  [ -r "$mf" ] || mf="${REPO_ROOT:-}/packages/$1/manifest.json"
  if [ -r "$mf" ] && need_cmd jq; then
    jq -r '(.credentials // {}) | to_entries[] | select(.key != "_comment") | .value.name' "$mf" 2>/dev/null || true
  fi
  return 0
}

# _pkgt_wait_health  — kurze /healthz-Warteschleife nach dem Restart (non-fatal; doctor.sh prueft erneut).
#   Eigenstaendig (install_n8n.sh wird vom CLI-package-Pfad nicht gesourct).
_pkgt_wait_health() {
  if wait_n8n_health; then ok "n8n Health OK."; return 0; fi
  warn "n8n /healthz antwortet noch nicht — doctor.sh prueft erneut."
}

# _pkgt_teardown <pkg> <agents_csv>  — alle Workflows des Pakets (Name-Praefix aus provides.agents) UND
#   die zwei Paket-Credentials aus n8n entfernen, danach gegateter Neustart. Non-fatal bei fehlendem
#   API-Key / nicht erreichbarem n8n (warn+skip -> der DB-Teardown des Aufrufers laeuft trotzdem).
_pkgt_teardown() {
  local pkg="$1" agents_csv="$2"
  if ! _pkgt_resolve_n8n; then
    warn "n8n-Teardown uebersprungen: kein N8N_API_KEY (core.env) — Workflows/Credentials ggf. manuell entfernen."
    return 0
  fi
  require_cmd curl
  require_cmd jq

  # --- Workflows des Pakets bestimmen (Wort-Grenze-Praefix: name == 'agent.<a>' ODER startswith
  #     'agent.<a>.' ODER 'agent.<a>_' — volle Paritaet zu deploy_workflows._wf_name_matches /
  #     der build-seitigen Get-WorkflowHomeDir-Regel, paperless-WS-0 Naht 5) ---
  local wf_lines; wf_lines="$(_pkgt_list_workflows)"
  local del_ids=() id name active a matched n_active=0
  while IFS=$'\t' read -r id name active; do
    [ -n "$id" ] || continue
    matched=0
    local oldifs="$IFS"; IFS=','
    # shellcheck disable=SC2086  # bewusstes Wort-Splitting auf der CSV (IFS=','); Agent-Namen sind [a-z0-9_], kein Globbing
    for a in $agents_csv; do
      [ -n "$a" ] || continue
      if [ "$name" = "agent.$a" ] || [ "${name#agent."$a".}" != "$name" ] || [ "${name#agent."$a"_}" != "$name" ]; then matched=1; break; fi
    done
    IFS="$oldifs"
    [ "$matched" -eq 1 ] || continue
    del_ids+=("$id")
    [ "$active" = "true" ] && n_active=$((n_active + 1))
  done <<< "$wf_lines"

  # --- Workflows loeschen ---
  local ndel=0
  if [ "${#del_ids[@]}" -gt 0 ]; then
    for id in "${del_ids[@]}"; do
      if n8n_delete_workflow "$id"; then ndel=$((ndel + 1)); else warn "Workflow $id: DELETE fehlgeschlagen (fahre fort)."; fi
    done
  fi
  ok "n8n-Teardown: $ndel Workflow(s) des Pakets '$pkg' entfernt ($n_active war(en) aktiv)."

  # --- die zwei Paket-Credentials loeschen (aus der Rollen-Konvention abgeleitet) ---
  local creds_json cn cid ncred=0
  creds_json="$(n8n_list_credentials)" || { warn "GET /credentials fehlgeschlagen -> Paket-Credentials bleiben (manuell pruefen)."; creds_json=""; }
  while IFS= read -r cn; do
    [ -n "$cn" ] || continue
    while IFS=$'\t' read -r cid name _; do
      [ -n "$cid" ] || continue
      if [ "$name" = "$cn" ]; then
        if n8n_delete_credential "$cid"; then ncred=$((ncred + 1)); ok "Credential '$cn' ($cid) entfernt."
        else warn "Credential '$cn' ($cid): DELETE fehlgeschlagen (fahre fort)."; fi
      fi
    done <<< "$creds_json"
  done <<< "$(_pkgt_pkg_cred_names "$pkg")"
  [ "$ncred" -gt 0 ] || log "Keine Paket-Credentials gefunden (bereits entfernt / nie angelegt)."

  # --- gegateter n8n-Neustart: stale In-Memory-Trigger abraeumen (nur wenn >=1 Paket-Workflow aktiv war) ---
  if [ "$n_active" -gt 0 ]; then
    log "$n_active aktive(r) Paket-Workflow(s) entfernt -> n8n einmal neu starten, damit veraltete In-Memory-Trigger (auf geloeschte Workflow-ids) verschwinden (#21770; deactivate/activate raeumt sie single-main NICHT) ..."
    enable_start_unit n8n 0
    _pkgt_wait_health
    ok "n8n neu gestartet -> stale Trigger des Pakets abgeraeumt."
  else
    log "Kein Restart noetig (kein zuvor aktiver Paket-Workflow)."
  fi
}
