# install_pg.sh — PostgreSQL from PGDG, major-version-pinned (PG_VERSION), with the n8n DB + role.
# Sourced by provision.sh (and scripts/dev/substrate-image/build_base.sh). Defines install_pg_packages() (package step
# only, no running service) and install_postgres() (= packages + service + DB/role). Reads these globals (provision.sh
# sets defaults): PG_VERSION, N8N_DB_NAME, N8N_DB_USER, N8N_DB_PASSWORD, TIMEZONE (install_postgres only).

PG_KEYRING="/usr/share/keyrings/postgresql-archive-keyring.gpg"
PG_LIST="/etc/apt/sources.list.d/pgdg.list"
# Long-lived PGDG signing key (id ACCC4CF8) — ASCII-armored, dearmored once by add_apt_key.
PG_KEY_URL="https://www.postgresql.org/media/keys/ACCC4CF8.asc"

# Run a command as the postgres superuser. runuser (util-linux) is always present; avoids
# a hard dependency on sudo on a minimal image.
_pg_super() { runuser -u postgres -- "$@"; }

# require_utf8_db — UTF-8 ist Gesetz (provisioning/CLAUDE.md): eine bestehende Nicht-UTF8-App-DB (angelegt von <= v0.4.0
# auf einem System mit LANG="C", Proxmox-Vorlage) speichert Umlaute nur als Bytes. Nie still weiter, nie automatisch
# loeschen. Laeuft ZWEIMAL: in preflight() (vor upgrade_prepare -> ein Update haelt n8n gar nicht erst an) und nach
# createdb in install_postgres. Fehlt die DB (oder PG), ist nichts zu pruefen.
require_utf8_db() {
  local enc
  enc="$(pg_db_encoding "${N8N_DB_NAME}")"
  if [ -z "$enc" ] || [ "$enc" = "UTF8" ]; then return 0; fi
  if [ "$(_pg_super psql -X -tA -d "${N8N_DB_NAME}" -c "SELECT 1 FROM pg_namespace WHERE nspname='core'" 2>/dev/null)" = "1" ]; then
    # Bestand MIT Daten: kein Loesch-Rat (purge vernichtet alles). Ein Umzugs-Pfad (Dump -> UTF8-DB -> Restore) ist
    # bewusst nicht gebaut, solange keine solche Instanz existiert (BACKLOG).
    die "Die Datenbank '${N8N_DB_NAME}' ist nicht UTF-8 (sondern ${enc}) und enthält bereits Daten. NICHTS löschen — \
dieser Installer bricht ab, n8n läuft unverändert weiter. Für den Umzug auf UTF-8 bitte melden (Projekt-BACKLOG: \
Bestands-DB auf UTF-8 umziehen)."
  fi
  die "Die Datenbank '${N8N_DB_NAME}' ist nicht UTF-8 (sondern ${enc}) — angelegt von einer älteren Installer-Version auf \
einem System ohne Spracheinstellung; Umlaute würden darin nicht korrekt gespeichert. Sie enthält noch keine Daten \
(fehlgeschlagene Erstinstallation): 'bash install.sh --uninstall --purge-data' (bzw. 'lifeagents uninstall \
--purge-data') löscht sie, danach neu installieren."
}

# apply_db_timezone — Sitzungs-Zeitzone der App-DB = Haushalts-Zeitzone (TIMEZONE, provision.sh
# resolve_household_timezone). Jede SQL-Stelle mit CURRENT_DATE / ::date / core.fn_today() rechnet "heute" in der
# Sitzungs-Zeitzone; ohne das gilt die initdb-Zeitzone des Clusters (LXC: meist UTC -> zwischen 00 und 02 Uhr ein
# anderer Tag). PostgreSQL-Weg: Default je Datenbank (ALTER DATABASE … SET, gilt fuer neue Sitzungen jeder Rolle);
# PostgreSQL prueft den Namen selbst gegen seine tz-Datenbank. Idempotent: nur bei Abweichung (pg_db_role_setting),
# dann PG_TZ_CHANGED=1 -> install_n8n_unit startet n8n neu (seine offenen DB-Verbindungen behielten sonst die alte).
apply_db_timezone() {
  [ -n "${TIMEZONE:-}" ] || die "TIMEZONE nicht gesetzt (derive_network_config muss vorher laufen)."
  local cur
  cur="$(_pg_super psql -X -tA -d "${N8N_DB_NAME}" -c "SELECT split_part(s, '=', 2) FROM pg_db_role_setting r \
JOIN pg_database d ON d.oid = r.setdatabase CROSS JOIN LATERAL unnest(r.setconfig) s \
WHERE d.datname = current_database() AND r.setrole = 0 AND lower(split_part(s, '=', 1)) = 'timezone'")"
  if [ "$cur" = "$TIMEZONE" ]; then
    log "Datenbank-Zeitzone ${TIMEZONE} (unverändert)."
    return 0
  fi
  _pg_super psql -X -q -v ON_ERROR_STOP=1 -d "${N8N_DB_NAME}" \
    -c "ALTER DATABASE \"${N8N_DB_NAME}\" SET timezone = '${TIMEZONE}';" \
    || die "Datenbank-Zeitzone '${TIMEZONE}' konnte nicht gesetzt werden (PostgreSQL kennt den Namen nicht?)."
  # shellcheck disable=SC2034  # liest install_n8n_unit (install_n8n.sh, gesourct): Neustart nach Zeitzonen-Wechsel
  PG_TZ_CHANGED=1
  ok "Datenbank-Zeitzone auf ${TIMEZONE} gesetzt${cur:+ (vorher ${cur})}."
}

# install_pg_packages — nur der Paket-Schritt (Repo, UTF-8-Drop-in, Server-Paket, Hold), ohne laufenden Dienst.
# Zweiter Konsument: das Basis-Image des Test-Substrats (scripts/dev/substrate-image/build_base.sh, docker build
# ohne systemd) — dieselbe Funktion statt einer Kopie, damit Image und Installer nicht auseinanderlaufen.
install_pg_packages() {
  local codename="${VERSION_CODENAME:-}"
  # /etc/os-release is a runtime system file (absent on the lint host) — not statically followable.
  # shellcheck disable=SC1091
  [ -n "$codename" ] || { . /etc/os-release; codename="$VERSION_CODENAME"; }

  # --- repo (idempotent: key dearmored once, source line written if changed) ---
  log "PGDG-Repo einrichten ..."
  add_apt_key "$PG_KEY_URL" "$PG_KEYRING"
  if add_apt_source "$PG_LIST" \
      "deb [signed-by=${PG_KEYRING}] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main"; then
    : # changed → force_apt_update below picks it up
  fi
  force_apt_update

  # --- UTF-8 ist Gesetz (provisioning/CLAUDE.md) ---
  # postgresql-common legt den Cluster beim Paket-Install mit der SYSTEM-Locale aus /etc/default/locale an
  # (maintscripts-functions::set_system_locale; die Sitzung zaehlt bewusst nicht). Proxmox-Debian-Vorlagen tragen dort
  # LANG="C" -> initdb waehlt SQL_ASCII (v0.4.0 brach daran ab). Der offizielle Drop-in-Weg (createcluster.conf(5),
  # include_dir createcluster.d) erzwingt UTF-8 unabhaengig davon; die Hauptdatei bleibt unberuehrt (kein ucf-Konflikt).
  # C.UTF-8 ist unter Debian 12 immer da (glibc, ohne locales-Paket) und sortiert stabil nach Code-Punkt (keine
  # Kollations-Drift bei glibc-Updates). Folge: ORDER BY reiht „Ä…" hinter „Z…" — wie zuvor die SQL_ASCII-Instanzen
  # (Byte-Order); sprachrichtige Sortierung waere eine eigene Entscheidung (ICU), kein Teil dieses Gesetzes.
  install -d -m 0755 /etc/postgresql-common/createcluster.d
  printf '%s\n' "# n8n-life-agents: Cluster immer UTF-8, egal was /etc/default/locale sagt (install_pg.sh)" \
    "initdb_options = '--encoding=UTF8 --locale=C.UTF-8'" > /etc/postgresql-common/createcluster.d/lifeagents-utf8.conf

  # --- server (Hauptversion im Paketnamen; Minor-Updates NUR ueber diesen Lauf) ---
  # Die Hauptversion kann nie springen: postgresql-<PG_VERSION> ist ein eigenes Paket (PGDG-Wiki „Apt"), nur das
  # Metapaket `postgresql` wuerde wechseln. Der Hold bleibt, damit KEIN anderer Weg (apt upgrade von Hand,
  # unattended-upgrades) den Cluster unter laufendem n8n neu startet. Frueher blockierte er aber auch jedes
  # 17.x-Sicherheits-Update (PostgreSQL: „always run the current minor release") -> hier gezielt loesen, die Minor
  # nachziehen, wieder halten. n8n steht dabei bereits (upgrade_guard.sh, PG-Minor zaehlt als Versionswechsel).
  if ! dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1; then
    apt_install "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
  else
    apt-mark unhold "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" >/dev/null 2>&1 || true
    apt_install --only-upgrade "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
    log "postgresql-${PG_VERSION} auf aktuellem Stand ($(dpkg-query -W -f='${Version}' "postgresql-${PG_VERSION}" 2>/dev/null))."
  fi
  apt-mark hold "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" >/dev/null
}

install_postgres() {
  install_pg_packages
  systemctl enable --now postgresql >/dev/null 2>&1 || systemctl enable --now postgresql

  # Wait until the cluster accepts connections (fresh install can lag a beat).
  for _ in $(seq 1 30); do
    if _pg_super pg_isready -q; then break; fi
    sleep 1
  done
  _pg_super pg_isready -q || die "PostgreSQL-Cluster nimmt keine Verbindungen an."

  # --- role + database (guarded). Passwort nur ueber die 600-Treiberdatei als psql-Variable (nie im argv, quoting-sicher). ---
  log "n8n-DB-Rolle/Datenbank sicherstellen ..."
  [ -n "${N8N_DB_PASSWORD:-}" ] || die "N8N_DB_PASSWORD nicht gesetzt (prepare_n8n_env muss vorher laufen)."

  local verb=CREATE
  if [ "$(_pg_super psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${N8N_DB_USER}'")" = "1" ]; then verb=ALTER; fi
  # N8N_DB_NAME=postgres: die App-Datenbank existiert beim Erstlauf noch nicht (createdb folgt unten).
  { psql_setvar dbpw "$N8N_DB_PASSWORD"
    printf "%s ROLE %s WITH LOGIN PASSWORD :'dbpw';\n" "$verb" "$N8N_DB_USER"
  } | N8N_DB_NAME=postgres psql_superuser_driver -q || die "n8n-DB-Rolle '${N8N_DB_USER}' konnte nicht angelegt/aktualisiert werden."

  if [ "$(_pg_super psql -tAc "SELECT 1 FROM pg_database WHERE datname='${N8N_DB_NAME}'")" != "1" ]; then
    # Kodierung ausdruecklich (template0, sonst erbt sie template1 des Clusters) — contract_lint Check 20.
    _pg_super createdb -O "${N8N_DB_USER}" -E UTF8 --locale=C.UTF-8 -T template0 "${N8N_DB_NAME}"
  fi

  # Guard vor jedem Schema-/Seed-Schritt (der erste Lauf in preflight sah eine frische DB noch nicht).
  require_utf8_db
  apply_db_timezone

  ok "PostgreSQL ${PG_VERSION} bereit (DB '${N8N_DB_NAME}', Rolle '${N8N_DB_USER}')."
}
