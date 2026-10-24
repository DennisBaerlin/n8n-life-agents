# backup_cli.sh — Runtime-CLI fuer Backup/Restore der Nutzerdaten (Phase 4b, Strang A).
# SOURCED (kein Shebang, kein `set -e` — der Top-Aufrufer `lifeagents` traegt den Error-Mode).
#
# Aufruf: `lifeagents backup <verb> [args]` (die CLI sourct diese Datei + common.sh).
# DB-Zugriff: postgres-Superuser via runuser/Peer-Auth am lokalen Socket (wie config_cli/pkg_lifecycle/
# apply_schema). Superuser ist Pflicht: pg_restore --disable-triggers schaltet auch die internen RI-(FK-)
# Trigger ab (-> keine Topo-Sort/Saldo-Recompute noetig), das geht nur als Superuser.
#
# ARCHITEKTUR (Owner-Pivot 2026-06-20, Plan glowing-shimmying-waffle): Standard-Werkzeug pg_dump statt
# selbstgebauter In-DB-Engine. Gesichert wird NUR die echte Nutzerdaten-Teilmenge (nicht die ganze DB:
# der Rest ist Code aus dem Repo, n8n-Interna, verschluesselte Geheimnisse, Wegwerf-Logs). Deklariert
# rein im manifest.json (`backup`-Block, je Paket) — Manifest = einzige SSOT.
#   * schema_dump-Pakete (finance): das GANZE Schema via pg_dump -a --disable-triggers -Fc (materialisierte
#     Tabellen 1:1, kein Recompute), exclude_tables raus.
#   * full_tables (agent.advisor_plans/guide_onboarding_state): ganz, via pg_dump -t.
#   * filtered_tables (agent.core_contexts managed_by='agent', monitor_triggers origin='user'): pg_dump kann
#     NICHT zeilen-filtern -> Export als jsonb (SELECT ... WHERE), Restore regel-bewusst via
#     core.fn_backup_restore_filtered (protected Contexts nur UPDATE, family vor finance_profile, monitor entdoppelt).
# pg_dump ignoriert -n (Schema), sobald -t gesetzt ist -> wir enumerieren ALLE bulk-Tabellen explizit per -t.
#
# BUNDLE = verschluesseltes Tarball {manifest.json (Header: bundle_format/packages/versions/verify_counts),
#   data.dump (pg_dump -Fc), shared.json (gefilterte Zeilen)}, gpg --symmetric AES256, Passphrase aus
#   core.backup_key('backup_encryption_key') (nie rotieren). Klartext nur transient in /dev/shm (tmpfs).
#
# RESTORE ist ATOMAR (Opus B1): pg_restore -f - erzeugt SQL-TEXT (kein eigener DB-Connect); TRUNCATE +
#   Restore-SQL + fn_backup_restore_filtered + Count-Verify laufen als EIN `psql -1`-Skript (eine TX) ->
#   jeder Fehler rollt alles zurueck, die alte Welt bleibt intakt. Decrypt/Header-/Pre-Flight-Checks
#   passieren VOR dem Wipe. Fehlt ein Bundle-Paket -> Auto-Install `pkg_install_one --no-seed` (seit Phase 5 live;
#   der Restore bringt die Daten), dann Pre-Flight-Recheck; Fehlschlag = Abbruch VOR jedem Wipe.

DB_SUPERUSER="${DB_SUPERUSER:-postgres}"
# BACKUP_KEY_NAME, Schluessel-Lesen und gpg-Ver-/Entschluesselung leben in common.sh (geteilt mit der Upgrade-Sicherung).

# N8N_DB_NAME aus der n8n.env ableiten — eine Adresse: common.sh.
_bkp_resolve_db() { lifeagents_db_name >/dev/null; }

# _bkp_psql_scalar <sql> -> einzelner Wert auf stdout (leer bei NULL/keine Zeile).
_bkp_psql_scalar() {
  _bkp_resolve_db
  runuser -u "$DB_SUPERUSER" -- psql -v ON_ERROR_STOP=1 -X -tA -d "$N8N_DB_NAME" -c "$1"
}

# _bkp_qual_ok <schema.table> -> 0 wenn beide Teile ^[a-z][a-z0-9_]*$ (Injection-Schutz vor Interpolation).
_bkp_qual_ok() { printf '%s' "$1" | grep -qE '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'; }

# _bkp_active_names -> aktive Paketnamen (space-separiert) aus der Registry.
_bkp_active_names() { _bkp_psql_scalar "SELECT string_agg(package, ' ') FROM core.package_registry WHERE status = 'active'"; }

# _bkp_is_active <pkg> <active-list> -> 0 wenn pkg in der Liste.
_bkp_is_active() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# _bkp_bulk_tables -> qualifizierte Tabellen (eine/Zeile, sortiert/unique), die pg_dump per -t sichert:
#   schema_dump-Pakete = alle BASE TABLEs des Paket-Schemas minus exclude_tables; + full_tables.
#   (filtered_tables sind NICHT dabei — die laufen ueber jsonb/fn.) EINE Quelle fuer Export-Args,
#   Restore-TRUNCATE und Count-Verify -> kein Drift.
_bkp_bulk_tables() {
  local active mf pkg schema t out=""
  active="$(_bkp_active_names)"
  for mf in "$(_pkg_dir)"/*/manifest.json; do
    [ -r "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)" || continue
    [ -n "$pkg" ] || continue
    _bkp_is_active "$pkg" "$active" || continue
    [ "$(jq -r 'has("backup")' "$mf" 2>/dev/null)" = "true" ] || continue
    # schema_dump: alle BASE TABLEs des Schemas minus excludes
    if [ "$(jq -r '.backup.schema_dump // false' "$mf" 2>/dev/null)" = "true" ]; then
      schema="$(jq -r '.schema // empty' "$mf" 2>/dev/null)"
      if [ -n "$schema" ] && printf '%s' "$schema" | grep -qE '^[a-z][a-z0-9_]*$'; then
        local excl_list; excl_list="$(jq -r '.backup.exclude_tables[]?' "$mf" 2>/dev/null)"
        while IFS= read -r t; do
          [ -n "$t" ] || continue
          # exclude?
          case $'\n'"$excl_list"$'\n' in *$'\n'"$t"$'\n'*) continue ;; esac
          out+="${schema}.${t}"$'\n'
        done < <(_bkp_psql_scalar "SELECT table_name FROM information_schema.tables WHERE table_schema = '${schema}' AND table_type = 'BASE TABLE' ORDER BY table_name")
      fi
    fi
    # full_tables: qualifiziert, as-is
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      out+="${t}"$'\n'
    done < <(jq -r '.backup.full_tables[]?' "$mf" 2>/dev/null)
  done
  printf '%s' "$out" | grep -v '^$' | sort -u
}

# _bkp_filtered -> "qualified<TAB>condition"-Zeilen aller aktiven Pakete (filtered_tables).
_bkp_filtered() {
  local active mf pkg
  active="$(_bkp_active_names)"
  for mf in "$(_pkg_dir)"/*/manifest.json; do
    [ -r "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)" || continue
    [ -n "$pkg" ] || continue
    _bkp_is_active "$pkg" "$active" || continue
    jq -r '(.backup.filtered_tables // {}) | to_entries[] | [.key, .value] | @tsv' "$mf" 2>/dev/null || true
  done
}

# _bkp_key -> Backup-Schluessel aus core.backup_key (oder leer).
_bkp_key() { _bkp_resolve_db; backup_key_read; }

# _bkp_tmpdir -> sicheres tmpfs-Arbeitsverzeichnis (/dev/shm = RAM; PII-Klartext nie auf Disk). 0700.
_bkp_tmpdir() {
  local d
  if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    d="$(mktemp -d -p /dev/shm lifeagents-bkp.XXXXXX)" || return 1
  else
    warn "/dev/shm (tmpfs) nicht verfuegbar -> Klartext-Dump liegt transient auf Disk (mktemp). Off-Site-Hygiene beachten."
    d="$(mktemp -d lifeagents-bkp.XXXXXX)" || return 1
  fi
  chmod 0700 "$d"
  printf '%s' "$d"
}

# _bkp_notify_telegram <datei> -> Off-Site-Zustellung: das fertige (AES256-verschluesselte) Bundle per
# Telegram sendDocument an den gepairten Owner-Chat schicken. BEST-EFFORT: jeder Pfad endet mit `return 0`
# (das lokale Backup ist hier bereits sicher geschrieben -> der Versand darf den Export NIE kippen; der von
# der lifeagents-CLI geerbte `set -e` wuerde sonst bei rc!=0 abbrechen). Praezedenzfall:
# bootstrap_owner.sh _wire_telegram (curl an api.telegram.org, warn+skip). Token NIE ins argv -> 600-`mktemp`-
# curl-config wie release_inputs.sh _http_status_secret; nur die Nicht-Geheim-Felder (document/chat_id/caption)
# als -F-Flags. Token + Owner ueber die geteilten Helfer owner_tg_token/owner_tg_chat_id (common.sh; der Owner via
# _resolve_owner_chat_id aus deploy_workflows.sh) -> braucht N8N_DB_NAME, also _bkp_resolve_db ZUERST (sonst faellt
# der Resolver still auf '0'). DATENSCHUTZ: das Bundle landet im persistenten Telegram-Cloud-Speicher (bleibt dort auch nach
# Loeschen vorerst als Kopie), aber als Doppel-Chiffrat (gpg-Schluessel nur OFFLINE) -> Telegram sieht nie
# Klartext; Restexposition = Metadaten + nicht-sofort-loeschbare Chiffrat-Kopie.
_bkp_notify_telegram() {
  local file="$1"
  need_cmd curl || { warn "curl fehlt -> Off-Site-Versand (Telegram) uebersprungen. Backup liegt lokal: $file"; return 0; }

  local token; token="$(owner_tg_token)"   # common.sh, geteilt mit notify_owner_telegram
  [ -n "$token" ] || { warn "Kein TELEGRAM_BOT_TOKEN in $(lifeagents_env_file core) -> Off-Site-Versand uebersprungen. Backup liegt lokal: $file"; return 0; }

  _bkp_resolve_db   # _resolve_owner_chat_id liest N8N_DB_NAME (sonst still '0')
  local chat; chat="$(owner_tg_chat_id)"
  if [ -z "$chat" ]; then
    warn "Owner-chat_id unbekannt/ungepairt -> Off-Site-Versand uebersprungen. Backup liegt lokal: $file"
    return 0
  fi

  # 50-MB-Sicherheitsgurt (Telegram-sendDocument-Limit; unsere Bundles <<1 MB). Numerischer Guard vor -gt
  # (set -e: nicht-numerisch -> [ ] rc2 -> Abbruch).
  local size; size="$(stat -c '%s' "$file" 2>/dev/null || echo 0)"
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$size" -gt $((50 * 1024 * 1024)) ]; then
    warn "Backup ${size} Byte > 50 MB (Telegram-sendDocument-Limit) -> Off-Site-Versand uebersprungen. Backup liegt lokal: $file"
    return 0
  fi

  # Token NIE ins argv: URL (mit Token) ueber eine 600-curl-config; document/chat_id/caption als -F (kein Secret).
  # Config bevorzugt in tmpfs (/dev/shm, analog _bkp_tmpdir: Klartext-Secret nie auf Disk; mktemp legt 0600 an),
  # Fallback /tmp. mktemp via '|| true' -> set -e kippt den fertigen Export nicht; Fehlschlag = warn+skip.
  local cfg=""
  if [ -d /dev/shm ] && [ -w /dev/shm ]; then cfg="$(mktemp -p /dev/shm la_tg.XXXXXX 2>/dev/null || true)"; fi
  [ -n "$cfg" ] || cfg="$(mktemp 2>/dev/null || true)"
  [ -n "$cfg" ] && [ -f "$cfg" ] || { warn "Konnte curl-Config nicht anlegen -> Off-Site-Versand uebersprungen. Backup liegt lokal: $file"; return 0; }
  chmod 600 "$cfg"
  printf 'url = "https://api.telegram.org/bot%s/sendDocument"\n' "$token" > "$cfg"
  local cap; cap="n8n-life-agents Off-Site-Backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local rc=0
  curl -fsS --max-time 60 -K "$cfg" \
       -F "chat_id=${chat}" -F "document=@${file}" -F "caption=${cap}" >/dev/null 2>&1 || rc=$?
  rm -f "$cfg"
  if [ "$rc" -eq 0 ]; then
    ok "Off-Site-Kopie an Telegram-Owner-Chat gesendet (${size} Byte)."
  else
    warn "Off-Site-Versand (Telegram sendDocument) fehlgeschlagen (Token/Netz/Chat?) -> unkritisch, Backup liegt lokal: $file"
  fi
  return 0
}

# ============================================================
# export
# ============================================================
backup_cmd_export() {
  require_cmd jq; require_cmd pg_dump; require_cmd gpg
  _bkp_resolve_db
  # Arg-Parse wie backup_cmd_restore (reihenfolge-robust): optionaler Positional-Pfad + --notify-telegram.
  # Mehrfacher Positional = letzter gewinnt (konsistent mit restore). Default-Pfad NACH der Schleife.
  local out="" notify=0 a
  for a in "$@"; do
    case "$a" in
      --notify-telegram) notify=1 ;;
      --*)               die "Unbekannte Option: $a" ;;
      *)                 out="$a" ;;
    esac
  done
  if [ -z "$out" ]; then out="$(pwd)/lifeagents-backup-$(date -u +%Y%m%d%H%M%S).nla.enc"; fi

  local key; key="$(_bkp_key)"
  [ -n "$key" ] && [ "${#key}" -ge 16 ] || die "Backup-Schluessel fehlt/zu kurz (core.backup_key '${BACKUP_KEY_NAME}', >=16 Zeichen). Der Installer setzt ihn out-of-band (bootstrap_owner _ensure_backup_secret)."

  local bulk; bulk="$(_bkp_bulk_tables)"
  [ -n "$bulk" ] || die "Keine zu sichernden Tabellen gefunden (aktive Pakete + backup-Block pruefen)."

  local tmp; tmp="$(_bkp_tmpdir)" || die "Konnte Arbeitsverzeichnis nicht anlegen."
  # Klartext-Reste IMMER aufraeumen (auch bei `die`->exit; RETURN feuert bei exit NICHT). Die CLI
  # beendet sich direkt nach backup_cli -> EXIT-Trap deckt Normal-Rueckkehr UND Fehler-exit. Pfad JETZT
  # in den Trap-String expandieren (Doppel-Quotes): $tmp ist function-local -> bei der global feuernden
  # EXIT-Trap waere es unter `set -u` "unbound variable".
  # shellcheck disable=SC2064  # bewusst JETZT expandieren: $tmp ist local -> bei der global feuernden EXIT-Trap unter `set -u` unbound
  trap "rm -rf -- '$tmp'" EXIT

  # --- (1) data.dump: pg_dump -a --disable-triggers -Fc mit -t je bulk-Tabelle (qualifiziert/validiert) ---
  local dump_args=() t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    _bkp_qual_ok "$t" || { warn "Ueberspringe ungueltigen Tabellennamen: $t"; continue; }
    dump_args+=( -t "$t" )
  done <<< "$bulk"
  # pg_dump laeuft als postgres (runuser/Peer-Auth) und darf das root-eigene 0700-tmpfs NICHT beschreiben
  # -> Ausgabe auf stdout, die root-Shell leitet in die Datei um (postgres fasst das Verzeichnis nie an).
  if ! runuser -u "$DB_SUPERUSER" -- pg_dump -d "$N8N_DB_NAME" -a --disable-triggers -Fc "${dump_args[@]}" > "$tmp/data.dump"; then
    die "pg_dump fehlgeschlagen."
  fi

  # --- (2) shared.json: gefilterte Tabellen als jsonb (pg_dump kann nicht zeilen-filtern) ---
  local sel="" qual cond
  while IFS=$'\t' read -r qual cond; do
    [ -n "$qual" ] || continue
    _bkp_qual_ok "$qual" || { warn "Ueberspringe ungueltige filtered-Tabelle: $qual"; continue; }
    [ -n "$sel" ] && sel+=", "
    sel+="$(printf "'%s', COALESCE((SELECT jsonb_agg(x) FROM %s x WHERE %s), '[]'::jsonb)" "$qual" "$qual" "$cond")"
  done < <(_bkp_filtered)
  if [ -n "$sel" ]; then
    _bkp_psql_scalar "SELECT jsonb_build_object($sel)" > "$tmp/shared.json" || die "shared.json-Export fehlgeschlagen."
  else
    printf '{}' > "$tmp/shared.json"
  fi

  # --- (3) verify_counts: count(*) je bulk- + filtered-Tabelle (Korruptions-Versicherung, Opus B3) ---
  local vsel="" n
  while IFS= read -r t; do
    [ -n "$t" ] || continue; _bkp_qual_ok "$t" || continue
    [ -n "$vsel" ] && vsel+=", "
    vsel+="$(printf "'%s', (SELECT count(*) FROM %s)" "$t" "$t")"
  done <<< "$bulk"
  while IFS=$'\t' read -r qual cond; do
    [ -n "$qual" ] || continue; _bkp_qual_ok "$qual" || continue
    [ -n "$vsel" ] && vsel+=", "
    vsel+="$(printf "'%s', (SELECT count(*) FROM %s WHERE %s)" "$qual" "$qual" "$cond")"
  done < <(_bkp_filtered)
  local verify_json; verify_json="$(_bkp_psql_scalar "SELECT jsonb_build_object($vsel)")" || die "verify_counts-Berechnung fehlgeschlagen."

  # --- (4) manifest.json (Header) ---
  local core_ver pkgs_json
  core_ver="$(_bkp_psql_scalar "SELECT value FROM core.config WHERE category='api' AND key='core_version'")"
  pkgs_json="$(_bkp_psql_scalar "SELECT COALESCE(jsonb_agg(jsonb_build_object('name',package,'version',version) ORDER BY package), '[]'::jsonb) FROM core.package_registry WHERE status='active'")"
  # Defaults als eigene Guards (NICHT inline ${x:-{}} — bash matcht dort die erste '}' als Expansions-Ende
  # und haengt bei nicht-leerem Wert ein Streu-'}' an -> ungueltiges JSON fuer jq --argjson).
  [ -n "$pkgs_json" ]   || pkgs_json='[]'
  [ -n "$verify_json" ] || verify_json='{}'
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cv "$core_ver" \
        --argjson pkgs "$pkgs_json" --argjson vc "$verify_json" \
        '{bundle_format:2, created_at:$ts, core_version:$cv, packages:$pkgs, verify_counts:$vc}' \
        > "$tmp/manifest.json" || die "manifest.json-Bau fehlgeschlagen."

  # --- (5) Tarball -> gpg (Passphrase via fd, nie argv) ---
  local tarf="$tmp/bundle.tar.gz"
  tar -czf "$tarf" -C "$tmp" manifest.json data.dump shared.json || die "tar fehlgeschlagen."
  if ! gpg_sym_encrypt "$key" "$out" "$tarf"; then
    die "gpg-Verschluesselung fehlgeschlagen."
  fi
  ok "Backup geschrieben: $out"
  log "Inhalt: $(printf '%s' "$bulk" | grep -c .) bulk-Tabelle(n) + $(_bkp_filtered | grep -c .) gefilterte; aktive Pakete: ${pkgs_json}"
  # Off-Site: optional verschluesselt an den Telegram-Owner-Chat (best-effort, kippt den fertigen Export nie).
  if [ "$notify" -eq 1 ]; then
    _bkp_notify_telegram "$out" || true
  else
    log "Off-Site-Hinweis: liegt auf der VM — per scp/Backup wegkopieren (der Schluessel liegt OFFLINE separat). Tipp: 'lifeagents backup export --notify-telegram' schickt eine verschluesselte Kopie an deinen Telegram-Chat."
  fi
}

# ============================================================
# restore
# ============================================================
backup_cmd_restore() {
  require_cmd jq; require_cmd pg_restore; require_cmd gpg
  _bkp_resolve_db
  local enc="" force=0 a
  for a in "$@"; do
    case "$a" in
      --yes|-y) force=1 ;;
      --*)      die "Unbekannte Option: $a" ;;
      *)        enc="$a" ;;
    esac
  done
  # Missing-Arg-Picker (E3): *.nla.enc aus cwd + /root — realpath-dedupe (als root ist cwd oft
  # /root selbst, sonst Dubletten), dann absteigend nach BASENAME sortiert (der traegt den
  # Timestamp -> neueste zuerst; eine Voll-Pfad-Sortierung liesse das Verzeichnis-Praefix
  # dominieren, Cold-Eyes A1). Danach laufen Wipe-Uebersicht + 'ja'-Confirm unveraendert (E8).
  # Kein Treffer/Abbruch -> unveraenderte Usage.
  if [ -z "$enc" ] && ui_interactive; then
    ensure_gum
    local _pick
    _pick="$( { ls -1 -- *.nla.enc /root/*.nla.enc 2>/dev/null || true; } \
      | while IFS= read -r f; do realpath -- "$f" 2>/dev/null; done | sort -u \
      | while IFS= read -r f; do printf '%s\t%s\n' "$(basename -- "$f")" "$f"; done \
      | sort -t "$(printf '\t')" -k1,1 -r \
      | while IFS=$'\t' read -r b f; do printf '%s   (%s)\t%s\n' "$b" "$f" "$f"; done \
      | ui_choose 'Backup wiederherstellen (Wipe-Uebersicht + Bestaetigung folgen):' 0 || true)"
    [ -n "$_pick" ] && enc="$_pick"
  fi
  [ -n "$enc" ] || die "Usage: lifeagents backup restore <datei.nla.enc> [--yes]"
  [ -r "$enc" ] || die "Backup-Datei nicht lesbar: $enc"

  local key; key="$(_bkp_key)"
  [ -n "$key" ] && [ "${#key}" -ge 16 ] || die "Backup-Schluessel fehlt/zu kurz (core.backup_key '${BACKUP_KEY_NAME}')."

  local tmp; tmp="$(_bkp_tmpdir)" || die "Konnte Arbeitsverzeichnis nicht anlegen."
  # Pfad JETZT in den Trap-String expandieren (s. export): $tmp ist local -> bei der global feuernden
  # EXIT-Trap waere es unter `set -u` "unbound variable".
  # shellcheck disable=SC2064  # bewusst JETZT expandieren: $tmp ist local -> bei der global feuernden EXIT-Trap unter `set -u` unbound
  trap "rm -rf -- '$tmp'" EXIT

  # --- (1) Entschluesseln + Header lesen (VOR jedem Wipe) ---
  if ! gpg_sym_decrypt "$key" "$enc" > "$tmp/bundle.tar.gz"; then
    die "Entschluesselung fehlgeschlagen — falscher Backup-Schluessel oder beschaedigte Datei. Es wurde NICHTS geaendert."
  fi
  tar -xzf "$tmp/bundle.tar.gz" -C "$tmp" || die "Tarball beschaedigt (kein gueltiges Bundle). Nichts geaendert."
  [ -r "$tmp/manifest.json" ] && [ -r "$tmp/data.dump" ] || die "Bundle unvollstaendig (manifest.json/data.dump fehlt). Nichts geaendert."

  local fmt; fmt="$(jq -r '.bundle_format // empty' "$tmp/manifest.json" 2>/dev/null)"
  [ "$fmt" = "2" ] || die "Nicht unterstuetztes Backup-Format (bundle_format='${fmt:-?}', erwartet 2). Alt-/.enc-Bundles der frueheren In-DB-Engine sind inkompatibel. Nichts geaendert."

  # --- (2) Pre-Flight je Bundle-Paket gegen die Registry (Opus B2: Paket muss vorinstalliert sein) ---
  local pkg ver inst_status inst_ver ans
  while IFS=$'\t' read -r pkg ver; do
    [ -n "$pkg" ] || continue
    inst_status="$(_bkp_psql_scalar "SELECT status FROM core.package_registry WHERE package = '${pkg//\'/\'\'}'")"
    if [ -z "$inst_status" ]; then
      # Restore-vor-Install (live seit Phase 5, VF1-Beweis): fehlt das Paket -> Auto-Install --no-seed anbieten
      # (der Restore bringt die Daten ohnehin). Passiert VOR jedem Wipe -> ein Fehlschlag laesst die alte Welt intakt.
      if [ "$force" -ne 1 ]; then
        tty_usable || die "Paket '$pkg' nicht installiert + kein TTY/--yes -> Abbruch (kein Teil-Restore)."
        printf "Bundle enthaelt Daten des Pakets '%s', das NICHT installiert ist. Jetzt installieren (--no-seed)? [ja/NEIN]: " "$pkg" > /dev/tty
        read -r ans < /dev/tty
        [ "$ans" = "ja" ] || die "Abgebrochen (kein Teil-Restore)."
      fi
      log "Auto-Install '$pkg' --no-seed (Restore bringt die Daten) ..."
      # Subshell: ein internes `die` beendet nur den Install, dann sauberer Abbruch HIER (vor dem Wipe).
      if ! ( pkg_install_one "$pkg" --no-seed ); then
        die "Auto-Install '$pkg' fehlgeschlagen -> Abbruch VOR jedem Wipe (alte Welt intakt)."
      fi
      # M2: Pre-Flight-Recheck nach dem Install — Status/Version erneut pruefen (kein continue-skip).
      inst_status="$(_bkp_psql_scalar "SELECT status FROM core.package_registry WHERE package = '${pkg//\'/\'\'}'")"
      [ -n "$inst_status" ] || die "Paket '$pkg' nach Auto-Install nicht registriert -> Abbruch vor Wipe."
    fi
    # status MUSS 'active' sein: _bkp_bulk_tables (Wipe/Restore-Menge) zaehlt nur aktive Pakete -> ein
    # inaktives Bundle-Paket wuerde seine Tabellen NICHT truncaten, pg_restore liefe in UNIQUE/PK-Konflikte
    # (Rollback, aber irrefuehrend). Explizit abfangen (Cold-Eyes A).
    if [ "$inst_status" != "active" ]; then
      die "Paket '$pkg' ist installiert, aber nicht aktiv (status=$inst_status). Erst aktivieren: 'lifeagents package activate $pkg', dann erneut restoren."
    fi
    inst_ver="$(_bkp_psql_scalar "SELECT version FROM core.package_registry WHERE package = '${pkg//\'/\'\'}'")"
    if [ -n "$ver" ] && [ "$ver" != "$inst_ver" ]; then
      # Versions-Gate (fail-closed VOR jedem Wipe): pg_restore -a passt Daten NICHT an ein per Migration
      # veraendertes Ziel-Schema an -> bewusst KEIN Cross-Version-Restore (Branchen-Standard: pg_restore/
      # Borg/restic verweigern Cross-Version ebenso). Echtes Forward-Migrate braeuchte eine Migrationskette
      # zwischen >=2 Versionen (BACKLOG, Re-Eval ab v0.2.0 + echtem Mismatch).
      die "Versions-Konflikt fuer '$pkg': Bundle=$ver, installiert=$inst_ver. Versions-uebergreifender Restore wird (wie pg_restore/Borg/restic) bewusst NICHT unterstuetzt — installierte Version an die Bundle-Version angleichen ('lifeagents update'), dann erneut restoren."
    fi
  done < <(jq -r '.packages[]? | [.name, .version] | @tsv' "$tmp/manifest.json")

  # --- (3) Wipe-Menge bestimmen + ausweisen (Transparenz, Cold-Eyes Phase 5) ---
  # _bkp_bulk_tables/_bkp_filtered sind read-only (information_schema + Manifeste) -> gefahrlos VOR dem
  # Confirm. NACH dem Pre-Flight (der Pakete auto-aktivieren kann) -> die Menge steht endgueltig fest.
  # Das hier berechnete $bulk wird in Schritt (4) wiederverwendet (kein zweites _bkp_bulk_tables -> kein Drift).
  local bulk; bulk="$(_bkp_bulk_tables)"
  [ -n "$bulk" ] || die "Keine Ziel-Tabellen (aktive Pakete + backup-Block) — Abbruch vor Wipe."
  local pkg_summary bulk_disp filt_disp filt_n qd cd
  pkg_summary="$(jq -r '[.packages[]? | "\(.name)@\(.version)"] | join(", ")' "$tmp/manifest.json" 2>/dev/null || true)"
  bulk_disp="$(printf '%s' "$bulk" | tr '\n' ' ')"
  filt_disp=""; filt_n=0
  while IFS=$'\t' read -r qd cd; do
    [ -n "$qd" ] || continue
    [ -n "$filt_disp" ] && filt_disp+="; "
    filt_disp+="$qd ($cd)"; filt_n=$((filt_n + 1))
  done < <(_bkp_filtered)

  # Wipe-Uebersicht IMMER ausweisen (via warn/log -> STDERR; auch unter --yes sichtbar, Z.B. im Cron-Log).
  warn "RESTORE ueberschreibt ALLE aktuellen Nutzerdaten (Finanzen, Profil, Trigger, Plaene) mit dem Bundle-Inhalt. Betroffen:"
  log "  Pakete (Bundle): ${pkg_summary:-?}"
  log "  Voll-Wipe (TRUNCATE), $(printf '%s' "$bulk" | grep -c .) Tabelle(n): ${bulk_disp}"
  log "  Zeilen-gefiltert, ${filt_n} Tabelle(n): ${filt_disp:-(keine)}"

  # --- (3b) TTY-Bestaetigung (destruktiv) ---
  if [ "$force" -ne 1 ]; then
    tty_usable || die "Kein TTY und kein --yes -> Abbruch (Restore ueberschreibt ALLE Nutzerdaten)."
    printf 'Wirklich wiederherstellen? [ja/NEIN]: ' > /dev/tty
    local ans=""; read -r ans < /dev/tty
    [ "$ans" = "ja" ] || die "Abgebrochen."
  fi

  # --- (4) ATOMARER Restore: TRUNCATE + pg_restore-SQL + fn + Count-Verify in EINER psql -1-TX (Opus B1) ---
  local restore_sql="$tmp/restore.sql"
  : > "$restore_sql"
  # (a) TRUNCATE der bulk-Tabellen (FK-/Trigger-frei dank --disable-triggers im pg_restore; CASCADE als Sicherung).
  #     filtered_tables (core_contexts/monitor_triggers) NICHT truncaten -> die fn macht den zeilen-gefilterten Wipe.
  local trunc="" t
  while IFS= read -r t; do
    [ -n "$t" ] || continue; _bkp_qual_ok "$t" || die "Ungueltiger Tabellenname im bulk-Set: $t"
    [ -n "$trunc" ] && trunc+=", "
    trunc+="$t"
  done <<< "$bulk"
  printf 'TRUNCATE %s CASCADE;\n' "$trunc" >> "$restore_sql"
  # (b) pg_restore -> SQL-TEXT (KEIN eigener DB-Connect; laeuft so in unserer einen TX).
  # pg_restore (postgres via runuser) liest die Archiv-Datei NICHT direkt (root-eigenes 0700-tmpfs) -> die
  # root-Shell oeffnet sie per stdin-Redirect; pg_restore -f - schreibt das SQL auf stdout (in unsere EINE TX).
  if ! runuser -u "$DB_SUPERUSER" -- pg_restore -a --disable-triggers -f - < "$tmp/data.dump" >> "$restore_sql"; then
    die "pg_restore (SQL-Generierung) fehlgeschlagen. Nichts geaendert."
  fi
  # (c) gefilterte Tabellen regel-bewusst (shared.json als base64 -> kein Quoting-Risiko).
  local shared_b64; shared_b64="$(base64 -w0 "$tmp/shared.json" 2>/dev/null || base64 "$tmp/shared.json" | tr -d '\n')"
  printf "SELECT core.fn_backup_restore_filtered(convert_from(decode('%s','base64'),'UTF8')::jsonb);\n" "$shared_b64" >> "$restore_sql"
  # (d) Count-Verify: post-Restore count(*) vs. manifest.verify_counts -> Mismatch = RAISE = Rollback der ganzen TX.
  {
    # shellcheck disable=SC2016  # $verify$ = SQL-Dollar-Quote-Tag (literal), keine Shell-Expansion gewollt
    printf 'DO $verify$ BEGIN\n'
    # bulk: plain count
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      n="$(jq -r --arg k "$t" '.verify_counts[$k] // empty' "$tmp/manifest.json")"
      [ -n "$n" ] || continue
      printf "  IF (SELECT count(*) FROM %s) <> %s THEN RAISE EXCEPTION 'verify failed: %s count %% (expected %s)', (SELECT count(*) FROM %s); END IF;\n" "$t" "$n" "$t" "$n" "$t"
    done <<< "$bulk"
    # filtered: count WHERE cond
    local qual cond
    while IFS=$'\t' read -r qual cond; do
      [ -n "$qual" ] || continue; _bkp_qual_ok "$qual" || continue
      n="$(jq -r --arg k "$qual" '.verify_counts[$k] // empty' "$tmp/manifest.json")"
      [ -n "$n" ] || continue
      printf "  IF (SELECT count(*) FROM %s WHERE %s) <> %s THEN RAISE EXCEPTION 'verify failed: %s count %% (expected %s)', (SELECT count(*) FROM %s WHERE %s); END IF;\n" "$qual" "$cond" "$n" "$qual" "$n" "$qual" "$cond"
    done < <(_bkp_filtered)
    # shellcheck disable=SC2016  # $verify$ = SQL-Dollar-Quote-Tag (literal)
    printf 'END $verify$;\n'
  } >> "$restore_sql"

  # psql (postgres via runuser) liest das Skript per stdin-Redirect (root oeffnet die Datei) — nicht -f
  # (das root-eigene 0700-tmpfs ist fuer postgres nicht traversierbar). -1 = eine TX ueber den ganzen Strom.
  if runuser -u "$DB_SUPERUSER" -- psql -v ON_ERROR_STOP=1 -1 -X -q -d "$N8N_DB_NAME" < "$restore_sql"; then
    ok "Restore abgeschlossen (atomar, Count-Verify gruen): $(printf '%s' "$bulk" | grep -c .) bulk-Tabelle(n) + gefilterte Zeilen wiederhergestellt."
  else
    die "Restore fehlgeschlagen — Transaktion zurueckgerollt, die alte Welt ist intakt."
  fi
}

# ============================================================
# Dispatcher
# ============================================================
backup_cli() {
  # Verb-Picker: nacktes `lifeagents backup` auf TTY -> Menue statt Hilfetext; ESC/non-TTY ->
  # Hilfetext wie bisher (Exit 0, E5b).
  if [ "$#" -eq 0 ] && ui_interactive; then
    ensure_gum
    local _menu_verb
    _menu_verb="$(ui_choose 'lifeagents backup — was tun?' 0 <<'MENU'
export — Verschluesseltes Backup schreiben	export
restore — Backup wiederherstellen (Auswahl-Liste, fragt nach)	restore
help — Hilfe anzeigen	help
MENU
)"
    [ -n "$_menu_verb" ] && set -- "$_menu_verb"
  fi
  local verb="${1:-help}"; shift || true
  case "$verb" in
    export)  backup_cmd_export "$@" ;;
    restore) backup_cmd_restore "$@" ;;
    help|--help|-h)
      cat >&2 <<'EOF'
lifeagents backup <verb> — Backup/Restore der Nutzerdaten (verschluesselt, paket-bewusst).

  export [pfad] [--notify-telegram]
                           Verschluesseltes Backup der Nutzerdaten schreiben (Default: ./lifeagents-backup-<ts>.nla.enc).
                           Sichert NUR echte Nutzerdaten (Finanzen/Profil/Trigger/Plaene/Onboarding) via pg_dump —
                           NICHT Code/Workflows/Geheimnisse (die stellt der Installer wieder her).
                           --notify-telegram schickt die fertige .nla.enc zusätzlich als Off-Site-Kopie an den
                           Owner-Telegram-Chat (best-effort: schlaegt der Versand fehl, bleibt das lokale Backup gueltig).
  restore <datei> [--yes]  Backup wiederherstellen (ATOMAR: alles-oder-nichts). UEBERSCHREIBT alle Nutzerdaten;
                           zeigt VOR der Rückfrage die betroffenen Pakete + Tabellen. Fehlt ein Bundle-Paket ->
                           Angebot, es zu installieren (--no-seed); dann versionsgleich restoren (sonst sauberer
                           Abbruch). --yes überspringt Rückfrage + nimmt Auto-Install an.

Automatisch (Off-Site, taeglich 03:30) — eine Zeile in die root-crontab ('crontab -e'):
  30 3 * * * cd /root && lifeagents backup export --notify-telegram >> /var/log/lifeagents-backup.log 2>&1
  (lokale Dateien sammeln sich an — keine Auto-Rotation; regelmaessig aufraeumen oder die Telegram-Historie als Generationen nutzen.)

Schlüssel: liegt in core.backup_key (gpg-Passphrase, AES256). OFFLINE separat sichern — ohne ihn kein Restore.
EOF
      ;;
    *) err "lifeagents backup: unbekannter Verb: $verb"; backup_cli help; return 1 ;;
  esac
}
