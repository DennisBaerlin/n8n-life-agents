# apply_schema.sh — bash-Reimpl von db_apply.ps1 fuer den Auslieferungs-Kern.
# Sourced by provision.sh. Definiert apply_schema().
#
# Faehrt DASSELBE Schema wie die Dev-Werkzeugkette (db_apply.ps1), aus denselben
# getrackten packages/*/db-Artefakten — Drift nur in dieser duennen Ausfuehrungslogik. Flyway-Modell,
# vier Phasen (Liste darunter):
#   1. idempotente Baseline-Inits (packages/<pkg>/db/*.sql: Tabellen/Trigger/inline-Baseline-fns)  — laufen IMMER
#   2. versionierte Einmal-Migrationen (packages/<pkg>/db/migrations/V{NNN}__*.sql)  — je GENAU einmal,
#      gated ueber core.migration_should_apply (unveraenderlich).
#   3. Repeatables (packages/<pkg>/db/migrations/R__*.sql: Views + ~100 Tool-Functions)  — bei Inhalts-
#      Aenderung neu, gated ueber core.repeatable_should_apply (Checksum). BEIDE Typen leben
#      in der EINEN Tabelle core.schema_version (packages/core/db/core.schema_version_init.sql, Flyway-Single-Table).
#   4. Hardening + drei DB-Rollen + Laufzeit-Grants (packages/core/db/util/util_*.sql)  — laufen IMMER, NACH den
#      R__-Repeatables (GRANT SELECT ON ALL TABLES deckt die Views, GRANT EXECUTE die R__-Functions).
#
# Laeuft als postgres-Superuser (runuser, peer-Auth am lokalen Socket): CREATE ROLE
# (core_ro/context_ro + per-Paket finance_rw/finance_ro via fn_provision_package_roles),
# CREATE EXTENSION pgcrypto und REVOKE auf schema public brauchen Superuser. Alles in EINER psql-Session, ON_ERROR_STOP=1 (Fail-fast,
# identische Semantik zum PowerShell-Pendant).
#
# Reads globals (provision.sh setzt Defaults): REPO_ROOT, N8N_DB_NAME, N8N_DB_USER.

DB_SUPERUSER="postgres"

# _schema_psql … — psql als postgres-Superuser gegen die n8n-DB. Peer-Auth am Socket,
# kein Passwort. ON_ERROR_STOP=1 + -X (ignoriert ~/.psqlrc des postgres-Users).
_schema_psql() {
  runuser -u "$DB_SUPERUSER" -- psql -v ON_ERROR_STOP=1 -X -d "$N8N_DB_NAME" "$@"
}

# _emit_sql_file <path>  — Datei-Inhalt INLINE in den Treiber-Stream (statt psql \i,
# damit der postgres-User die root-eigenen Repo-Dateien nicht selbst lesen muss; nur
# die 0644-Treiberdatei in /tmp wird von postgres geoeffnet).
_emit_sql_file() {
  printf '\n-- ===== %s =====\n' "${1#"$REPO_ROOT/"}"
  cat "$1"
  printf '\n'
}

# _emit_migration <path>  — eine versionierte Migration als atomar-gegatete Einheit:
# Reservierung (core.migration_should_apply) + Anwendung in EINER Transaktion. Schon
# angewandt -> \if-FALSE ueberspringt den Inhalt; Fehler -> ON_ERROR_STOP rollt die
# offene Transaktion (inkl. Reservierung) zurueck -> laeuft beim naechsten Mal erneut.
_emit_migration() {
  local path="$1" base ver sum
  base="$(basename "$path")"
  ver="${base%%__*}"                         # 'V001__foo.sql' -> 'V001'
  sum="$(md5sum "$path" | awk '{print $1}')"
  printf '\nBEGIN;\n'
  printf "SELECT CASE WHEN core.migration_should_apply('%s', '%s', '%s') THEN 'true' ELSE 'false' END AS _mig \\gset\n" \
    "$ver" "$base" "$sum"
  printf '\\if :_mig\n'
  # %s-Form (NICHT printf-Format fuer das \echo): printf interpretiert im FORMAT-String `\e` als
  # ESC (0x1B) -> aus `\echo` wuerde `<ESC>cho` und psql wirft einen Syntaxfehler. Als %s-Argument
  # werden Backslash-Escapes nicht verarbeitet -> der Meta-Befehl bleibt intakt.
  printf '%s\n' "\\echo '  [MIGRATION] anwenden: ${base}'"
  cat "$path"
  printf '\n\\else\n'
  printf '%s\n' "\\echo '  [MIGRATION] bereits angewandt, uebersprungen: ${base}'"
  printf '\\endif\n'
  printf 'COMMIT;\n'
}

# _emit_repeatable <path>  — ein Flyway-REPEATABLE (Views/Tool-Functions, packages/<pkg>/db/migrations/R__*.sql)
# als checksum-gegatete Einheit: core.repeatable_should_apply(relpfad, md5) entscheidet, ob der
# Inhalt neu ist. Unveraendert -> \if-FALSE ueberspringt; geaendert/neu -> anwenden. Tracking-Key =
# relativer Pfad (Forward-Slashes). Fehler -> ON_ERROR_STOP rollt die offene Transaktion (inkl.
# Reservierung/Update) zurueck -> laeuft beim naechsten Mal erneut.
_emit_repeatable() {
  local path="$1" base rel sum
  base="$(basename "$path")"
  rel="${path#"$REPO_ROOT/"}"                 # relativer Pfad = Tracking-Key
  sum="$(md5sum "$path" | awk '{print $1}')"
  printf '\nBEGIN;\n'
  printf "SELECT CASE WHEN core.repeatable_should_apply('%s', '%s') THEN 'true' ELSE 'false' END AS _rep \\gset\n" \
    "$rel" "$sum"
  printf '\\if :_rep\n'
  printf '%s\n' "\\echo '  [REPEATABLE] anwenden: ${base}'"   # %s-Form: s. _emit_migration (printf \e = ESC)
  cat "$path"
  printf '\n\\else\n'
  printf '%s\n' "\\echo '  [REPEATABLE] unveraendert, uebersprungen: ${base}'"
  printf '\\endif\n'
  printf 'COMMIT;\n'
}

# _emit_set_package <pkg>  — Session-GUC fuer das Ledger-Eigentum (B1). Steht BEWUSST ausserhalb der
# per-Datei-BEGIN/COMMIT von _emit_migration/_emit_repeatable (Session-Level) -> wirkt fuer alle folgenden
# gegateten Dateien dieses Batches, bis der naechste Batch sie umsetzt. Inits/util sind ungegated -> die GUC
# ist dort wirkungslos, wird aber konsistent gesetzt.
_emit_set_package() { printf "\nSET lifeagents.package = '%s';\n" "$1"; }

# _emit_inits_for_dir <db_dir> <is_core 0|1>  — Phase-1-Baseline-Inits eines Verzeichnisses.
#   is_core=1: schema_version ZUERST (der Treiber braucht core.migration_should_apply), dann ai_models VOR
#   core.config (Modell-Trigger), dann der Rest sortiert. is_core=0: nur sortiert (Paket-/Flach-Inits sind
#   reihenfolge-tolerant: CREATE … IF NOT EXISTS, Helfer im selben *_init.sql).
_emit_inits_for_dir() {
  local d="$1" core="$2" f
  if [ "$core" = "1" ]; then
    local ord=("$d/core.schema_version_init.sql" "$d/agent.ai_models_init.sql" "$d/core.config_init.sql")
    for f in "${ord[@]}"; do [ -f "$f" ] || die "Pflicht-Init fehlt: $f"; _emit_sql_file "$f"; done
    for f in "$d"/*.sql; do
      case "$f" in "${ord[0]}"|"${ord[1]}"|"${ord[2]}") continue ;; esac
      [ -f "$f" ] && _emit_sql_file "$f"
    done
  else
    for f in "$d"/*.sql; do [ -f "$f" ] && _emit_sql_file "$f"; done
  fi
}

# _emit_core_role_phase  — Core-Phase 4: Hardening + RO-Rollen + Laufzeit-Owner-Grants auf agent,core.
#   NUR im Core-Apply (is_core). util_create_*_ro: LOGIN ohne Passwort bis bootstrap_owner es setzt.
_emit_core_role_phase() {
  local repo_db="$REPO_ROOT/packages/core/db" f
  _emit_set_package core
  for f in util_harden_db_security.sql util_create_core_ro.sql util_create_context_ro.sql; do
    [ -f "$repo_db/util/$f" ] || die "Pflicht-Util fehlt: $repo_db/util/$f"
    _emit_sql_file "$repo_db/util/$f"
  done
  printf '\n-- ===== runtime write-role grants core (%s) =====\n' "$N8N_DB_USER"
  printf 'GRANT USAGE ON SCHEMA agent, core TO %s;\n' "$N8N_DB_USER"
  # CREATE auf schema agent: der n8n-Memory-Node (memoryPostgresChat) legt agent.<agent>_chat_memory
  # ZUR LAUFZEIT selbst an -> ohne CREATE faellt der erste Agent-Turn mit "permission denied for schema agent".
  printf 'GRANT CREATE ON SCHEMA agent TO %s;\n' "$N8N_DB_USER"
  printf 'GRANT ALL ON ALL TABLES IN SCHEMA agent, core TO %s;\n' "$N8N_DB_USER"
  printf 'GRANT ALL ON ALL SEQUENCES IN SCHEMA agent, core TO %s;\n' "$N8N_DB_USER"
  printf 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA agent, core TO %s;\n' "$N8N_DB_USER"
  printf 'ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA agent GRANT ALL ON TABLES TO %s;\n' "$DB_SUPERUSER" "$N8N_DB_USER"
  printf 'ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA core  GRANT ALL ON TABLES TO %s;\n' "$DB_SUPERUSER" "$N8N_DB_USER"
  printf 'ALTER ROLE %s SET search_path = pg_catalog, agent, core;\n' "$N8N_DB_USER"
  # KEINE Mitgliedschaft in core_ro mehr (Security-Audit 2026-10): die Monitor-Specs laufen ueber das DEFINER-Fenster
  # agent.fn_monitor_ro_eval (EXECUTE oben per Sammel-Grant); der fruehere SET-ROLE-Weg brauchte sie. REVOKE raeumt
  # Bestands-Installationen auf (ohne Mitgliedschaft nur eine WARNING).
  printf 'REVOKE core_ro FROM %s;\n' "$N8N_DB_USER"
  # core.backup_key bleibt dem Owner-Schreibpfad vorbehalten, nie an Leserollen (REVOKE in
  # core.backup_key_init / util_create_core_ro).
}

# _emit_pkg_owner_grants <pkg>  — Laufzeit-Owner-Grants NUR aufs <pkg>-Schema (Owner-Cred-Nodes:
#   die Crons schreiben/lesen finance.* schema-qualifiziert). KEIN CREATE (R11). Die ENGE Paket-Rolle
#   <pkg>_rw/_ro provisioniert pkg_install_one Stufe 3 (core.fn_provision_package_roles), NICHT hier.
#   search_path: generisch je Paket-Install via core.fn_sync_role_search_paths(<owner>) — Desired-State
#   aus core.package_registry (Basis pg_catalog,agent,core + Tail je existierendem Paket-Schema), NICHT
#   ueberschreibend (Multi-Paket: das 2. Paket haengt an, statt das 1. zu verdraengen; B).
_emit_pkg_owner_grants() {
  local pkg="$1"
  printf '\n-- ===== runtime write-role grants %s (%s) =====\n' "$pkg" "$N8N_DB_USER"
  printf 'GRANT USAGE ON SCHEMA %s TO %s;\n' "$pkg" "$N8N_DB_USER"
  printf 'GRANT ALL ON ALL TABLES IN SCHEMA %s TO %s;\n' "$pkg" "$N8N_DB_USER"
  printf 'GRANT ALL ON ALL SEQUENCES IN SCHEMA %s TO %s;\n' "$pkg" "$N8N_DB_USER"
  printf 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %s TO %s;\n' "$pkg" "$N8N_DB_USER"
  printf 'ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA %s GRANT ALL ON TABLES TO %s;\n' "$DB_SUPERUSER" "$pkg" "$N8N_DB_USER"
  # Owner-search_path GENERISCH recomputen (Full-Replace aus core.package_registry) statt zu ueberschreiben —
  # sonst verdraengt das 2. Paket das 1. (B). Der Owner-Rollen-NAME (nie current_user=postgres) geht rein; die
  # fn ist zu diesem Zeitpunkt appliziert (Core-R__ vor jedem Paket-Apply). Das gerade installierende Paket ist
  # registriert (pkg_install_one Stage 1) + Schema existiert (Phase-1-Inits dieses Applys) -> im Tail.
  printf "SELECT core.fn_sync_role_search_paths('%s');\n" "$N8N_DB_USER"
}

# apply_schema [pkg]  — EIN Paket anwenden (paket-major; Phase 5: bare-core ist der Standard).
#   pkg='core' (Default, bare Core: Schema + Hardening/RO-Rollen + Owner-Grants agent,core) |
#   pkg='<paket>' (per-Paket: Schema + Owner-Grants aufs <pkg>-Schema; Rollen via pkg_install_one Stage 3).
#   provision.sh installiert Core, dann jedes Paket ueber den per-Paket-Pfad (Bundle = Metapackage) —
#   Core ist immer VOR den Paketen voll angewandt, also sieht ein Paket-R__ den Core; ein Core-R__ mit
#   finance.*-Bezug ist plpgsql (runtime-resolved) -> CREATE ok ohne finance (bare-core sicher).
#   Reads globals: REPO_ROOT, N8N_DB_NAME, N8N_DB_USER (CLI-Kontext: aus n8n.env abgeleitet).
apply_schema() {
  local only="${1:-core}"
  printf '%s' "$only" | grep -qE '^[a-z][a-z0-9_]*$' || die "Ungueltiger Paketname: $only"
  [ -n "${N8N_DB_NAME:-}" ] || die "N8N_DB_NAME nicht gesetzt."
  # N8N_DB_USER aus der n8n.env ableiten, falls nicht gesetzt (Runtime-CLI laeuft ausserhalb provision.sh).
  if [ -z "${N8N_DB_USER:-}" ]; then
    N8N_DB_USER="$(read_env_value "${N8N_ENV_FILE:-/etc/n8n/n8n.env}" DB_POSTGRESDB_USER || true)"
    [ -n "${N8N_DB_USER:-}" ] || die "N8N_DB_USER nicht gesetzt + nicht in n8n.env ableitbar."
  fi
  require_cmd runuser
  require_cmd md5sum

  local is_core=0 db_dir f
  if [ "$only" = "core" ]; then db_dir="$REPO_ROOT/packages/core/db"; is_core=1
  else                          db_dir="$REPO_ROOT/packages/$only/db"; fi
  [ -d "$db_dir" ] || die "packages/$only/db fehlt: $db_dir (unvollstaendiges Paket)."

  log "Schema anwenden: Paket '$only' (Flyway 3-Phasen$([ "$is_core" = 1 ] && printf ' + Hardening/RO-Rollen'))..."

  local driver; driver="$(mktemp /tmp/apply_schema.XXXXXX.sql)"
  chmod 0644 "$driver"   # postgres-User oeffnet den Treiber; Repo-Dateien bleiben root-only

  {
    printf '\\set ON_ERROR_STOP on\n'
    _emit_set_package "$only"
    # Phase 1: Baseline-Inits (core: schema_version->ai_models->config->Rest; sonst sortiert).
    _emit_inits_for_dir "$db_dir" "$is_core"
    # Phase 2: versionierte V__-Migrationen (je gegated).
    for f in "$db_dir"/migrations/V*.sql; do [ -f "$f" ] && _emit_migration "$f"; done
    # Phase 3: R__-Repeatables (Views + Tool-Functions, checksum-gegatet).
    for f in "$db_dir"/migrations/R__*.sql; do [ -f "$f" ] && _emit_repeatable "$f"; done
    # Phase 4: Hardening/RO-Rollen (Core) bzw. Owner-Grants aufs Paket-Schema (NACH den Views/Functions).
    if [ "$is_core" = 1 ]; then _emit_core_role_phase; else _emit_pkg_owner_grants "$only"; fi
  } > "$driver"

  if _schema_psql -f "$driver"; then
    rm -f "$driver"
    ok "Schema '$only' angewandt (Baseline-Inits + V__ + R__ + $([ "$is_core" = 1 ] && printf 'Hardening/Rollen' || printf 'Owner-Grants'))."
  else
    local rc=$?
    warn "Treiber zur Fehlersuche behalten: $driver"
    die "Schema-Apply '$only' fehlgeschlagen (psql exit $rc) — Fehlerstelle in der Ausgabe oben."
  fi
}
