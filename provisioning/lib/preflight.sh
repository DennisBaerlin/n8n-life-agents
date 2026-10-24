# preflight.sh — fail-fast environment checks before any package is touched.
# Sourced by provision.sh. Defines preflight(); does not run anything on source.

# Freier Platz auf / — Bedarf haengt davon ab, was NOCH zu installieren ist (Install-UX-Phase 3: pauschal
# 3000 MB blockierte jedes `lifeagents update` auf einem 8-GB-Container, obwohl n8n laengst installiert
# war). Reserve fuer Schema/Workflows/Logs + n8n (node_modules + npm-Peak), falls die Zielversion fehlt,
# + PostgreSQL, falls das Paket fehlt. Ein n8n-Versionssprung verlangt bewusst wieder den vollen Bedarf
# (genau dann laedt npm neu). Ein explizites PREFLIGHT_MIN_DISK_MB (Env) gewinnt als harte Vorgabe.
PREFLIGHT_MIN_DISK_MB="${PREFLIGHT_MIN_DISK_MB:-}"
PREFLIGHT_RESERVE_MB=500
PREFLIGHT_N8N_MB=2300
PREFLIGHT_PG_MB=200

# _preflight_disk_need -> benoetigte MB auf STDOUT (siehe oben).
_preflight_disk_need() {
  if [ -n "$PREFLIGHT_MIN_DISK_MB" ]; then printf '%s' "$PREFLIGHT_MIN_DISK_MB"; return 0; fi
  local need="$PREFLIGHT_RESERVE_MB"
  if ! { need_cmd n8n && [ "$(_upg_n8n_version)" = "${N8N_VERSION:-}" ]; }; then
    need=$((need + PREFLIGHT_N8N_MB))
  fi
  # Jeder Versionswechsel (n8n, Node ODER PG-Minor) auf einer Bestands-Instanz: upgrade_guard.sh legt vorher eine
  # Sicherung der ganzen DB an. Obergrenze = DB-Groesse (der komprimierte Dump ist kleiner); die schon liegenden
  # Sicherungen stecken bereits im belegten Platz. Frische Hosts haben noch kein PG -> 0.
  if [ -n "$(_upg_changes)" ]; then
    need=$((need + $(_preflight_db_mb)))
  fi
  dpkg -s "postgresql-${PG_VERSION:-17}" >/dev/null 2>&1 || need=$((need + PREFLIGHT_PG_MB))
  printf '%s' "$need"
}

# _preflight_db_mb -> Groesse der App-DB in MB (0, wenn PG/DB noch fehlen oder nicht erreichbar).
_preflight_db_mb() {
  local mb=''
  if need_cmd psql && dpkg -s "postgresql-${PG_VERSION:-17}" >/dev/null 2>&1; then
    mb="$(runuser -u postgres -- psql -X -tAc \
            "SELECT pg_database_size(datname) / 1048576 FROM pg_database WHERE datname = '${N8N_DB_NAME:-n8n}'" 2>/dev/null || true)"
  fi
  case "$mb" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$mb" ;; esac
}

preflight() {
  log "Preflight ..."
  require_root
  _upg_n8n_version >/dev/null   # n8n-Version EINMAL im Eltern-Prozess lesen (der CLI-Start dauert Sekunden) -> alle
                                # spaeteren $(…)-Aufrufe vor dem Tausch erben den Cache (upgrade_guard.sh)

  # OS: Debian (the only supported target — LXC base image).
  [ -r /etc/os-release ] || die "/etc/os-release fehlt — kein unterstütztes System."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian) : ;;
    ubuntu) warn "Ubuntu erkannt — getestet ist Debian; das PGDG-Repo funktioniert i. d. R. trotzdem." ;;
    *)      die "Nicht unterstütztes OS: ${ID:-unbekannt} (erwartet: debian)." ;;
  esac
  [ -n "${VERSION_CODENAME:-}" ] || die "VERSION_CODENAME fehlt in /etc/os-release (für PGDG-Repo nötig)."
  ok "OS: ${PRETTY_NAME:-$ID} (codename: $VERSION_CODENAME)"

  # systemd is the service manager we target (n8n.service / postgresql).
  need_cmd systemctl || die "systemctl fehlt — dieses Provisioning setzt systemd voraus."
  [ -d /run/systemd/system ] || die "systemd läuft nicht als PID 1 (kein /run/systemd/system) — LXC braucht systemd-Init."

  # Bootstrap tools that must exist on a near-bare image (packages.sh installs the rest).
  local missing=()
  for c in curl gpg openssl; do need_cmd "$c" || missing+=("$c"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Bootstrap-Tools fehlen (${missing[*]}) — werden in packages.sh nachinstalliert."
  fi

  # Disk space.
  local avail_mb need_mb
  avail_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  need_mb="$(_preflight_disk_need)"
  if [ -n "$avail_mb" ] && [ "$avail_mb" -lt "$need_mb" ]; then
    die "Zu wenig freier Speicher auf / : ${avail_mb} MB frei, ${need_mb} MB nötig."
  fi
  ok "Freier Speicher auf / : ${avail_mb:-?} MB (nötig: ${need_mb} MB)"

  # Outbound network (apt.postgresql.org / cloudsmith / npm / deb.nodesource).
  if ! curl -fsS --max-time 10 -o /dev/null https://deb.debian.org 2>/dev/null; then
    warn "Kein HTTPS zu deb.debian.org erreichbar — apt/npm-Downloads könnten scheitern."
  fi

  # UTF-8-Gesetz VOR jedem Eingriff: eine bestehende Nicht-UTF8-App-DB bricht hier ab, bevor upgrade_prepare n8n
  # anhaelt (sonst bliebe der Bot nach einem abgebrochenen Update aus). Funktion: install_pg.sh.
  require_utf8_db

  ok "Preflight bestanden."
}
