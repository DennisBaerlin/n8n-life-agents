# install_n8n.sh — Node.js (pinned major), n8n@<version> via npm, dedicated system user,
# rendered env file (encryption key generated ONCE), systemd unit.
# Sourced by provision.sh. Reads globals: N8N_VERSION, NODE_MAJOR, N8N_USER, N8N_HOME,
# N8N_USER_FOLDER, N8N_ENV_FILE, N8N_PORT, N8N_DB_NAME, N8N_DB_USER, plus the n8n
# URL/host vars provision.sh derives from DOMAIN. Sets N8N_DB_PASSWORD (read by install_pg).

NODE_KEYRING="/usr/share/keyrings/nodesource.gpg"
NODE_LIST="/etc/apt/sources.list.d/nodesource.list"
N8N_UNIT="/etc/systemd/system/n8n.service"

# --- dedicated unprivileged service user -------------------------------------
ensure_n8n_user() {
  if ! id -u "$N8N_USER" >/dev/null 2>&1; then
    log "System-User '$N8N_USER' anlegen ..."
    useradd --system -m -d "$N8N_HOME" -s /usr/sbin/nologin "$N8N_USER"
  fi
  mkdir -p "$N8N_USER_FOLDER"
  chown -R "${N8N_USER}:${N8N_USER}" "$N8N_HOME"
}

# --- env file: secrets generated once, then preserved across re-runs ----------
# The encryption key must NEVER change once n8n booted (else every stored credential
# becomes undecryptable). Existing file wins over any override env var.
prepare_n8n_env() {
  ensure_n8n_user
  local envf="$N8N_ENV_FILE" existing

  existing="$(read_env_value "$envf" N8N_ENCRYPTION_KEY || true)"
  if [ -n "$existing" ]; then
    N8N_ENCRYPTION_KEY="$existing"
  elif [ -n "${OPT_ENCRYPTION_KEY:-}" ]; then
    N8N_ENCRYPTION_KEY="$OPT_ENCRYPTION_KEY"
  else
    N8N_ENCRYPTION_KEY="$(rand_hex 32)"
  fi

  existing="$(read_env_value "$envf" DB_POSTGRESDB_PASSWORD || true)"
  if [ -n "$existing" ]; then
    N8N_DB_PASSWORD="$existing"
  elif [ -n "${OPT_DB_PASSWORD:-}" ]; then
    N8N_DB_PASSWORD="$OPT_DB_PASSWORD"
  else
    N8N_DB_PASSWORD="$(rand_hex 24)"
  fi

  N8N_ENV_CHANGED=1
  if render_template "$TEMPLATE_DIR/n8n.env.tpl" \
        N8N_ENCRYPTION_KEY="$N8N_ENCRYPTION_KEY" \
        N8N_DB_NAME="$N8N_DB_NAME" \
        N8N_DB_USER="$N8N_DB_USER" \
        N8N_DB_PASSWORD="$N8N_DB_PASSWORD" \
        N8N_USER_FOLDER="$N8N_USER_FOLDER" \
        N8N_HOST="$N8N_HOST" \
        N8N_PORT="$N8N_PORT" \
        N8N_LISTEN_ADDRESS="${N8N_LISTEN_ADDRESS_EFF:-127.0.0.1}" \
        N8N_PROTOCOL="$N8N_PROTOCOL" \
        N8N_EDITOR_BASE_URL="$N8N_EDITOR_BASE_URL" \
        WEBHOOK_URL="$WEBHOOK_URL" \
        TIMEZONE="$TIMEZONE" \
      | write_if_changed "$envf" 0640 "root:${N8N_USER}"; then
    N8N_ENV_CHANGED=0
    ok "n8n-Env geschrieben/aktualisiert ($envf)."
  else
    log "n8n-Env unverändert ($envf)."
  fi
}

# --- Node.js -----------------------------------------------------------------
# Genau die gepinnte Hauptversion (NODE_MAJOR) — gleiches Pin-Prinzip wie N8N_VERSION. n8n 2.44 verlangt
# Node >= 24 (npm-engines); ungerade Versionen (25) brechen isolated-vm. Der Rueckweg auf ein altes Release laeuft
# ueber dessen eigenen Installer (upgrade_guard.sh upgrade_rollback_hint), nicht per Override dieser Pins.
node_major() { node -v 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p'; }
_node_ok() { need_cmd node && [ "$(node_major)" = "$NODE_MAJOR" ]; }

ensure_node() {
  if _node_ok; then ok "Node.js $(node -v) (Hauptversion ${NODE_MAJOR})."; return; fi
  log "Node.js ${NODE_MAJOR}.x via NodeSource installieren ..."
  add_apt_key "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" "$NODE_KEYRING"
  add_apt_source "$NODE_LIST" \
    "deb [signed-by=${NODE_KEYRING}] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main"
  force_apt_update
  # Explizit die neueste Version DIESER Hauptversion: ein schon installiertes hoeheres Node bliebe sonst apt-Kandidat
  # (Rueckweg 24 -> 22), und Debians eigenes nodejs-Paket koennte dazwischenfunken. --allow-downgrades fuer den Rueckweg.
  local ver
  ver="$(apt-cache madison nodejs 2>/dev/null | awk -v m="$NODE_MAJOR" '$3 ~ ("^" m "\\.") {print $3; exit}')"
  [ -n "$ver" ] || die "Das NodeSource-Repo bietet kein Node.js ${NODE_MAJOR}.x an (apt-cache madison nodejs)."
  apt_install --allow-downgrades "nodejs=${ver}"
  # Ein schon installiertes n8n wurde gegen die alte Node-ABI gebaut -> ensure_n8n_package baut neu (auch ohne
  # Merkzettel, z. B. nach einer frueher abgebrochenen Erstinstallation).
  need_cmd n8n && NODE_SWITCHED=1
  _node_ok || die "Node-Installation ergab nicht Hauptversion ${NODE_MAJOR}: $(node -v 2>/dev/null)."
}

# --- n8n npm package (version-pinned) ----------------------------------------
ensure_n8n_package() {
  if need_cmd n8n && [ "$(n8n --version 2>/dev/null)" = "$N8N_VERSION" ]; then
    ok "n8n ${N8N_VERSION} bereits installiert."
    # Nur Node gewechselt (gleiche n8n-Version): die nativen Bausteine (isolated-vm, sqlite3) gegen die neue
    # Node-ABI neu bauen — npm-Doku `npm rebuild` (upgrade_guard.sh merkt sich die alte Node-Version).
    if upgrade_node_switched || [ "${NODE_SWITCHED:-0}" = 1 ]; then
      log "Node-Hauptversion gewechselt — native n8n-Bausteine neu bauen (npm rebuild) ..."
      # Im n8n-Paketbaum OHNE Paketnamen: `npm rebuild -g n8n` baute nur das Hauptpaket, nicht die verschachtelten
      # nativen Bausteine darunter.
      ( cd "$(npm root -g)/n8n" && npm rebuild --no-audit --no-fund )
    fi
    return
  fi
  log "n8n@${N8N_VERSION} global via npm installieren (dauert einige Minuten) ..."
  npm install -g --no-audit --no-fund "n8n@${N8N_VERSION}"
  # npm-Download-Cache (~1 GB unter ~/.npm) wird danach nicht mehr gebraucht -> Platz zurueckgeben
  # (npm-Doku: `cache clean` ist genau fuer "reclaiming disk space"). Nie fatal.
  npm cache clean --force >/dev/null 2>&1 || true
  local got; got="$(n8n --version 2>/dev/null || true)"
  [ "$got" = "$N8N_VERSION" ] || warn "n8n-Version weicht ab: '${got}' (erwartet ${N8N_VERSION})."
}

# --- systemd unit + boot/health ----------------------------------------------
install_n8n_unit() {
  local bin; bin="$(command -v n8n || true)"
  [ -n "$bin" ] || die "n8n-Binary nicht im PATH gefunden."

  local changed=1
  if render_template "$TEMPLATE_DIR/n8n.service.tpl" \
        N8N_USER="$N8N_USER" \
        N8N_ENV_FILE="$N8N_ENV_FILE" \
        N8N_OWNER_ENV_FILE="${N8N_OWNER_ENV_FILE:-/etc/lifeagents/core.env}" \
        N8N_BIN="$bin" \
        N8N_HOME="$N8N_HOME" \
      | write_if_changed "$N8N_UNIT" 0644; then
    changed=0
  fi
  # A changed env file also warrants a restart so n8n picks up new config.
  [ "${N8N_ENV_CHANGED:-1}" -eq 0 ] && changed=0
  # Neue DB-Zeitzone (install_pg.sh apply_db_timezone) gilt nur fuer neue Verbindungen -> n8n neu verbinden lassen.
  [ "${PG_TZ_CHANGED:-0}" -eq 1 ] && changed=0
  # Versionswechsel (upgrade_guard.sh): n8n steht bereits bzw. ein abgebrochener Tausch wird fortgesetzt -> der
  # (Neu-)Start laedt die getauschten Dateien; ohne das liefe nach npm install die alte Version im Speicher weiter.
  [ "${UPGRADE_ACTIVE:-0}" -eq 1 ] && changed=0
  # Eine n8n-Korrektur wurde gerade angewendet (apply_n8n_patches) -> der Neustart laedt die korrigierte Datei.
  [ "${N8N_PATCH_CHANGED:-0}" -eq 1 ] && changed=0

  enable_start_unit n8n "$changed"
  if [ "${UPGRADE_ACTIVE:-0}" -eq 1 ]; then
    # Nach einem Versionssprung migriert n8n seine Tabellen beim Start — das kann Minuten dauern. Hart warten
    # (450 x 2 s = 15 Min): Deploy-Schritte gegen ein halb migriertes n8n schlagen sonst fehl.
    log "Warte, bis n8n seine Datenbank umgestellt hat (kann einige Minuten dauern) ..."
    if wait_n8n_health 450; then
      ok "n8n ${N8N_VERSION} bereit (Datenbank umgestellt)."
    else
      upgrade_rollback_hint
      die "n8n wurde nach dem Update nicht bereit (/healthz/readiness) — Diagnose: journalctl -u n8n -n 100"
    fi
  elif wait_n8n_health; then
    ok "n8n bereit (http://127.0.0.1:${N8N_PORT}/healthz/readiness)."
  else
    warn "n8n meldet sich noch nicht bereit — doctor.sh prüft erneut (Erststart kann dauern)."
  fi
}

# Orchestration entrypoint for provision.sh (env was prepared earlier so install_pg had the pw).
install_n8n() {
  ensure_node
  ensure_n8n_package
  apply_n8n_patches   # lib/n8n_patches.sh: bekannte n8n-Fehler korrigieren, bis n8n sie selbst liefert (bei JEDEM Lauf)
  install_n8n_unit
}
