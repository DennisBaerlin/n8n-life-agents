# uninstall.sh — die Instanz wieder abbauen (Phase 6). Sourced by provision.sh. Definiert uninstall().
#
# ZWEI Stufen (destruktives gated, Default reversibel):
#   --uninstall              : Dienste stoppen+entfernen (n8n-Unit) + die APP-Schemata
#                              agent/core DROPpen. PostgreSQL, die n8n-DB-Engine und /etc/n8n bleiben
#                              -> ein erneuter Installer-Lauf stellt die App wieder her (Encryption-Key
#                              bleibt erhalten = n8n-Credentials weiter entschluesselbar). REVERSIBEL.
#   --uninstall --purge-data : ZUSAETZLICH die n8n-DATENBANK + alle Rollen (n8n-Owner + Host-RO
#                              core_ro/context_ro + je Paket <pkg>_rw/<pkg>_ro, dynamisch ueber das
#                              _rw/_ro-Suffix) + Daten-/Config-Verzeichnisse (/var/lib/n8n, /etc/n8n,
#                              /etc/lifeagents) entfernen. Voller Wipe (die PG-Engine bleibt). DESTRUKTIV.
#
# Idempotent + guarded: jeder Schritt prueft Existenz (Unit/DB/Rolle/Verzeichnis) -> Zweitlauf no-op.
# Bestaetigung per /dev/tty, sofern nicht --yes (destruktiv -> opt-in/Confirm-Prinzip).
#
# Reads globals (provision.sh): PROFILE, ASSUME_YES, PURGE_DATA, N8N_DB_NAME, N8N_DB_USER,
#   N8N_HOME, N8N_ENV_FILE (-> /etc/n8n), N8N_USER.

DB_SUPERUSER="${DB_SUPERUSER:-postgres}"

# _u_psql … — als postgres-Superuser gegen eine DB (Default die wartungs-sichere 'postgres'-DB, damit
# DROP DATABASE n8n keine offene Verbindung auf das Ziel haelt).
_u_psql() { runuser -u "$DB_SUPERUSER" -- psql -v ON_ERROR_STOP=1 -X "$@"; }

_u_db_exists()   { _u_psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$1';" 2>/dev/null | grep -q 1; }
_u_role_exists() { _u_psql -d postgres -tAc "SELECT 1 FROM pg_roles    WHERE rolname = '$1';" 2>/dev/null | grep -q 1; }

# _u_confirm <prompt>  — TTY-Rueckfrage (nur exaktes 'ja' bestaetigt). --yes -> ohne Frage ja.
_u_confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  tty_usable || { warn "Kein TTY und kein --yes -> Abbruch (Sicherheit)."; return 1; }
  local a=""
  printf '%s [ja/NEIN]: ' "$1" > /dev/tty
  read -r a < /dev/tty
  [ "$a" = "ja" ]
}

# _u_stop_unit <unit> [remove-unit-file?]  — stop+disable; optional die Unit-Datei entfernen.
_u_stop_unit() {
  local unit="$1" remove="${2:-0}"
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" >/dev/null 2>&1 || true
  if [ "$remove" = "1" ]; then
    rm -f "/etc/systemd/system/${unit}" "/lib/systemd/system/${unit}" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
  fi
  ok "Dienst gestoppt/deaktiviert: $unit"
}

uninstall() {
  require_root
  require_cmd runuser

  if [ "$PURGE_DATA" -eq 1 ]; then
    warn "DESTRUKTIV: --purge-data loescht die n8n-Datenbank '${N8N_DB_NAME}', die Rollen und /var/lib/n8n + /etc/n8n."
    _u_confirm "Wirklich ALLE Daten unwiderruflich loeschen?" || die "Abgebrochen."
  else
    _u_confirm "App entfernen (Dienste + Schemata agent/core; Daten bleiben)?" || die "Abgebrochen."
  fi

  log "Dienste stoppen ..."
  # Update-Timer zuerst (install_update_timers.sh): kein Release-Check und kein Chat-Update mitten im Abbau. Beide
  # Modi; ein erneuter Installer-Lauf legt sie wieder an.
  if declare -F uninstall_update_timers >/dev/null; then uninstall_update_timers; fi
  _u_stop_unit n8n.service 1
  # LLM-Gateway (install_llm_gateway.sh) nach n8n: Unit + Code-Ordner weg (beide Modi; ein erneuter Installer-
  # Lauf legt ihn wieder an — er haelt keine Daten).
  if declare -F uninstall_llm_gateway >/dev/null; then uninstall_llm_gateway; fi
  # Firewall-Freigabe fuer einen Proxy auf einem anderen Rechner (Install-UX-Phase 5): NACH dem n8n-Stop
  # (Reihenfolge: n8n nie offen ohne Tabelle) Unit + n8n-Drop-in + Tabelle + Datei entfernen — in beiden Modi
  # (--uninstall und --purge-data), sonst blockierte ein Rest-Drop-in den naechsten n8n-Start.
  if declare -F firewall_remove >/dev/null; then firewall_remove; fi
  # Verwalteter /etc/hosts-Block (Bestaetigen im Chat, hitl_chat_reachable) — in beiden Modi weg; ein erneuter
  # Installer-Lauf setzt ihn bei Bedarf wieder.
  if declare -F hosts_pin_clear >/dev/null; then hosts_pin_clear && ok "Eigene-Domain-Eintrag in /etc/hosts entfernt (falls vorhanden)."; fi
  # Kein caddy-Stop mehr: der Reverse Proxy ist bring-your-own (Install-UX-Phase 2), nie von uns
  # installiert -> er ist nicht unser Dienst zum Abbauen (ein bestehender Proxy des Nutzers bleibt).

  # --- App-Schemata DROPpen (agent/core) — nur wenn die DB existiert ----------
  if _u_db_exists "$N8N_DB_NAME"; then
    log "App-Schemata agent/core in '${N8N_DB_NAME}' entfernen ..."
    if _u_psql -d "$N8N_DB_NAME" -c "DROP SCHEMA IF EXISTS agent CASCADE; DROP SCHEMA IF EXISTS core CASCADE;" >/dev/null 2>&1; then
      ok "Schemata agent/core entfernt (n8n-interne Tabellen unberuehrt)."
    else
      warn "DROP SCHEMA agent/core fehlgeschlagen — manuell pruefen."
    fi
  else
    log "Datenbank '${N8N_DB_NAME}' existiert nicht — Schema-Drop uebersprungen."
  fi

  if [ "$PURGE_DATA" -ne 1 ]; then
    # Erfolgs-Marker VERSION entfernen (Install-UX-Phase 7): die CLI bleibt fuer update/doctor stehen, aber ein Neu-Install
    # danach ist wieder eine Erstinstallation (_is_first_install: Funktions-Wahl, Uebersicht, Pflicht-Pruefung).
    rm -f "$(lifeagents_version_marker)" 2>/dev/null || true
    ok "Uninstall (reversibel) fertig: Dienste weg, agent/core gedroppt. PG + n8n-DB + /etc/n8n bleiben."
    ok "  Wiederherstellen: 'lifeagents update' (oder install.sh) erneut laufen lassen (Encryption-Key in /etc/n8n bleibt gueltig)."
    return 0
  fi

  # --- PURGE: Datenbank + Rollen + Verzeichnisse ------------------------------
  log "Voller Wipe (--purge-data) ..."
  if _u_db_exists "$N8N_DB_NAME"; then
    # offene Verbindungen kappen (n8n ist gestoppt; Sicherheits-Halber), dann DROP von der postgres-DB aus.
    _u_psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${N8N_DB_NAME}' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
    if _u_psql -d postgres -c "DROP DATABASE IF EXISTS \"${N8N_DB_NAME}\";" >/dev/null 2>&1; then
      ok "Datenbank '${N8N_DB_NAME}' gedroppt."
    else
      warn "DROP DATABASE '${N8N_DB_NAME}' fehlgeschlagen (offene Verbindung?) — manuell pruefen."
    fi
  fi
  # Rollen: der n8n-Owner + ALLE Host-/Paket-Lese-/Schreib-Rollen. Seit Phase 5 sind das core_ro/
  # context_ro (Host) PLUS je installiertem Paket <pkg>_rw/<pkg>_ro -> dynamisch ueber das _rw/_ro-
  # Suffix enumerieren (statt einer hartkodierten Liste, die einen Paket-Rollen-Rest stehen liesse).
  # Nach DROP DATABASE sind sie referenzlos (Single-App-DB-Annahme, wie der Paket-Purge).
  local r pkg_roles
  pkg_roles="$(_u_psql -d postgres -tAc "SELECT rolname FROM pg_roles WHERE rolname ~ '_(rw|ro)\$'" 2>/dev/null | tr -d ' ' || true)"
  # shellcheck disable=SC2086  # bewusstes Wort-Splitting (Rollennamen sind [a-z0-9_], kein Globbing)
  for r in "$N8N_DB_USER" $pkg_roles; do
    if _u_role_exists "$r"; then
      if _u_psql -d postgres -c "DROP ROLE IF EXISTS \"$r\";" >/dev/null 2>&1; then
        ok "Rolle '$r' gedroppt."
      else
        warn "DROP ROLE '$r' fehlgeschlagen (noch referenziert?)."
      fi
    fi
  done

  rm -rf "$N8N_HOME" 2>/dev/null && ok "Datenverzeichnis $N8N_HOME entfernt." || true
  rm -rf /etc/n8n  2>/dev/null && ok "Config/Secrets /etc/n8n entfernt." || true
  rm -rf "${LIFEAGENTS_DIR:-/etc/lifeagents}" 2>/dev/null && ok "Installer-Secrets ${LIFEAGENTS_DIR:-/etc/lifeagents} entfernt." || true
  # Installations-Protokolle (Quiet-Modus, Install-UX-Phase 3) — koennen PII aus psql-Fehlern enthalten.
  rm -rf "${UI_LOG_DIR:-/var/log/lifeagents}" 2>/dev/null && ok "Installations-Protokolle ${UI_LOG_DIR:-/var/log/lifeagents} entfernt." || true
  # Deploy-Zustand (deploy_workflows.sh, NUR GEAENDERTE) gehoert zur geloeschten n8n-DB.
  [ -z "${WF_DEPLOY_STATE_FILE:-}" ] || rm -f "$WF_DEPLOY_STATE_FILE" 2>/dev/null || true
  # lifeagents-Admin-CLI + gespiegelter Provisioning-Baum (install_cli) — nur beim Voll-Wipe.
  rm -f  /usr/local/bin/lifeagents 2>/dev/null && ok "lifeagents-CLI entfernt." || true
  rm -rf /usr/local/lib/lifeagents 2>/dev/null && ok "lifeagents-Verzeichnis /usr/local/lib/lifeagents entfernt." || true
  ok "Voller Wipe fertig. PostgreSQL/n8n-Binaries bleiben installiert (apt/npm); für einen Neuaufbau: install.sh (Bootstrap)."
}
