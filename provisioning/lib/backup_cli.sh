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
#   data.dump (pg_dump -Fc), shared.json (gefilterte Zeilen)}, gpg --symmetric AES256, Passphrase = aktiver Schluessel
#   aus core.backup_key (Lebenszyklus: common.sh *Sicherungs-Verschluesselung*). Klartext nur transient in /dev/shm.
#   Dateiname lifeagents-backup-<ts>-k<schluessel-id>-v<release>.nla.enc: die ID trennt "falscher Schluessel" von
#   "beschaedigt" und begrenzt das Aufraeumen auf eigene Sicherungen, die Version sagt, was ein Restore braucht.
# NOTFALLBLATT: `backup key` zeigt den Schluessel (common.sh backup_kit_text); ein Restore, den kein gespeicherter
#   Schluessel oeffnet, nimmt ihn vom Blatt an (TTY verdeckt oder --key-stdin, nie argv) und macht ihn in derselben
#   Restore-TX zum aktiven.
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
  pg_su_psql -v ON_ERROR_STOP=1 -X -tA -d "$N8N_DB_NAME" -c "$1"
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
    d="$(mktemp -d -p /tmp lifeagents-bkp.XXXXXX)" || return 1   # ohne -p entstuende der Ordner im aktuellen Verzeichnis
  fi
  chmod 0700 "$d"
  printf '%s' "$d"
}

# _bkp_notify_telegram <datei> -> Off-Site-Zustellung: das fertige (AES256-verschluesselte) Bundle per
# Telegram sendDocument an den gepairten Owner-Chat schicken. BEST-EFFORT: jeder Pfad endet mit `return 0`
# (das lokale Backup ist hier bereits sicher geschrieben -> der Versand darf den Export NIE kippen; der von
# der lifeagents-CLI geerbte `set -e` wuerde sonst bei rc!=0 abbrechen). Praezedenzfall:
# bootstrap_owner.sh _wire_telegram (curl an api.telegram.org, warn+skip). Token NIE ins argv -> 600-`mktemp`-
# curl-config (curl_cfg); nur die Nicht-Geheim-Felder (document/chat_id/caption)
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

# _bkp_require_pg <programm> — pg_dump/pg_restore muessen dort liegen, wo die Wrapper sie ausfuehren: auf dem LXC lokal,
#   im Docker-Verbund im Datenbank-Container (pg_su_exec = docker exec, im master gibt es sie nicht).
_bkp_require_pg() { if rt_is_compose; then require_cmd docker; else require_cmd "$1"; fi; }

# --- Sicherungs-Ordner auf dem Rechner (Docker-Verbund, Plan-Pruefung Fund 7) ------------------------------------------
# Die Docker-Platte kann mit allen Volumes verschwinden ("Clean up data", defekte VM-Platte) -> Sicherungen gehen in einen
# vom Nutzer gewaehlten Ordner AUF DEM RECHNER. Gemerkt als BACKUP_HOST_DIR in core.env (nicht geheim). Nur absolute
# Pfade ohne Komma (Trenner der --mount-Angabe) und ohne Zeilenumbruch.
BACKUP_HOST_KEEP="${BACKUP_HOST_KEEP:-14}"   # so viele automatische Sicherungen bleiben im Ordner (aelteste gehen zuerst)
_bkp_host_dir() { read_env_value "$(lifeagents_env_file core)" BACKUP_HOST_DIR 2>/dev/null || true; }
_bkp_host_dir_valid() {
  case "$1" in
    /*) ;; *) return 1 ;;
  esac
  case "$1" in *,*|*$'\n'*|*$'\r'*|*'"'*) return 1 ;; esac
  return 0
}
# _bkp_host_dir_ok <ordner> — gueltig UND auf dem Rechner beschreibbar (Probe-Datei anlegen und wieder loeschen).
_bkp_host_dir_ok() { _bkp_host_dir_valid "$1" && rt_host_check "$1"; }
# _bkp_rotate_victims <behalten> <schluessel-id> (stdin: Dateinamen) -> die zu loeschenden: nur Sicherungen mit DIESER
#   Schluessel-ID jenseits der neuesten <behalten>. Fremde IDs (ein alter Rechner im selben Ordner) und Namen ohne ID
#   bleiben immer liegen — sonst loeschte der neue Rechner nach 14 Tagen genau die Sicherungen, aus denen er herkommt.
_bkp_rotate_victims() {
  grep -E "^lifeagents-backup-[0-9]{14}-${2}-v[0-9A-Za-z.-]+\.nla\.enc\$" | sort -r | tail -n +$(( $1 + 1 ))
}
# _bkp_host_rotate <ordner> <schluessel-id> — eigene alte Sicherungen im Rechner-Ordner entfernen. Fehler = nur Warnung.
_bkp_host_rotate() {
  local v=()
  mapfile -t v < <(rt_host_ls "$1" | _bkp_rotate_victims "$BACKUP_HOST_KEEP" "$2" || true)
  [ "${#v[@]}" -gt 0 ] && [ -n "${v[0]}" ] || return 0
  rt_host_rm "$1" "${v[@]}" || warn "Alte Sicherungen im Ordner '$1' ließen sich nicht aufräumen."
}
# _bkp_release_tag -> Release der laufenden CLI (VERSION), sonst "dev" — fuer den Dateinamen.
_bkp_release_tag() { cat "$(lifeagents_version_marker)" 2>/dev/null | head -n1 | tr -d '[:space:]' || true; }
# _bkp_file_name <ts> <schluessel-id> <release> -> Dateiname einer Sicherung; kein stabiles Release -> "vdev".
_bkp_file_name() {
  local v="$3"
  [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || v=vdev
  printf 'lifeagents-backup-%s-%s-%s.nla.enc' "$1" "$2" "$v"
}
# _bkp_file_key_id <pfad|name> -> Schluessel-ID aus dem Dateinamen (leer bei Namen ohne ID).
_bkp_file_key_id() {
  local b; b="${1##*/}"
  # Nicht am Anfang verankert: umbenannte Kopien ("Kopie von …", "… (1).nla.enc", Cloud-Konfliktkopie) behalten ihre ID.
  [[ "$b" =~ lifeagents-backup-[0-9]{14}-(k[0-9a-f]{8})-v ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}
# _bkp_key_ids -> IDs aller gespeicherten Schluessel (aktiver zuerst), eine je Zeile.
_bkp_key_ids() {
  local k
  while IFS= read -r k; do [ -n "$k" ] && printf '%s' "$k" | backup_key_id && printf '\n'; done < <(backup_key_candidates 2>/dev/null || true)
}

# --- Ergebnis der Sicherungen (backup.state) ------------------------------------------------------------------------
# LAST_OK / LAST_FAIL (Epoch) + LAST_FAIL_REASON (fester Code folder|key|dump|encrypt|write) — doctor und der Chat-Hinweis
# lesen nur hier. Liegt im Verbund auf dem Volume var_la (uebersteht Neuanlage des master). Der Tick-Marker LAST_BACKUP
# (update_runner.sh) ist etwas anderes: der Zeitplan ("heute schon versucht").
BACKUP_STATE_FILE="${BACKUP_STATE_FILE:-/var/lib/lifeagents/backup.state}"
_bkp_state_set() { { env_upsert "$BACKUP_STATE_FILE" "$1" "$2" && chmod 0600 "$BACKUP_STATE_FILE"; } 2>/dev/null || true; }
# _bkp_fail <code> <meldung> — Fehlschlag einer Sicherung mit festem Grund festhalten, dann abbrechen.
_bkp_fail() { _bkp_state_set LAST_FAIL "$(date +%s)"; _bkp_state_set LAST_FAIL_REASON "$1"; shift; die "$@"; }

# backup_cmd_host_dir [<ordner>] — Sicherungs-Ordner auf dem Rechner zeigen bzw. setzen (Wizard/Start-App, Terminal).
backup_cmd_host_dir() {
  rt_is_compose || die "Der Sicherungs-Ordner auf dem Rechner gibt es nur im Docker-Verbund."
  if [ "$#" -eq 0 ]; then
    local d; d="$(_bkp_host_dir)"
    if [ -n "$d" ]; then printf '%s\n' "$d"; else log "Noch kein Sicherungs-Ordner gewählt."; fi
    return 0
  fi
  _bkp_host_dir_valid "$1" || die "Ungültiger Ordner '$1' (absoluter Pfad auf dem Rechner, ohne Komma)."
  rt_host_check "$1" || die "Ordner '$1' ist auf dem Rechner nicht vorhanden oder nicht beschreibbar (bei Docker Desktop: Ordner unter Einstellungen > Ressourcen > Dateifreigabe)."
  env_upsert "$(lifeagents_env_file core)" BACKUP_HOST_DIR "$1"
  ok "Sicherungen gehen ab jetzt nach '$1' (auf dem Rechner, verschlüsselt)."
}

# backup_cmd_auto — taegliche Sicherung in den Rechner-Ordner (Tick im master, update_runner.sh). Ohne gemerkten Ordner
#   still (der Wizard fragt ihn ab); jeder Fehler nur als Warnung, damit der Tick weiterlaeuft.
backup_cmd_auto() {
  [ -n "$(_bkp_host_dir)" ] || return 0
  ( backup_cmd_export --to-host ) || warn "Tägliche Sicherung in den Rechner-Ordner fehlgeschlagen — nächster Versuch morgen."
  return 0
}

# ============================================================
# export
# ============================================================
backup_cmd_export() {
  require_cmd jq; _bkp_require_pg pg_dump; require_cmd gpg
  _bkp_resolve_db
  # Arg-Parse wie backup_cmd_restore (reihenfolge-robust): optionaler Positional-Pfad + --notify-telegram.
  # Mehrfacher Positional = letzter gewinnt (konsistent mit restore). Default-Pfad NACH der Schleife.
  # --to-host <ordner> (Docker-Verbund): das fertige Chiffrat in einen Ordner AUF DEM RECHNER (Fund 7); ohne Pfad und
  # ohne --to-host nimmt der Verbund den gemerkten Ordner (BACKUP_HOST_DIR), nie die Docker-Platte.
  local out="" notify=0 a host="" want_host=0 prev=""
  for a in "$@"; do
    # --to-host [<ordner>]: ein folgender ABSOLUTER Pfad ist der Ordner; sonst gilt der gemerkte (backup auto).
    if [ "$prev" = --to-host ]; then
      prev=""
      case "$a" in /*) host="$a"; continue ;; esac
    fi
    case "$a" in
      --notify-telegram) notify=1 ;;
      --to-host)         want_host=1; prev="$a" ;;
      --*)               die "Unbekannte Option: $a" ;;
      *)                 out="$a" ;;
    esac
  done
  if [ "$want_host" -eq 1 ] && [ -n "$out" ]; then die "Entweder ein Pfad im System oder --to-host — nicht beides."; fi
  if rt_is_compose && [ -z "$out" ]; then want_host=1; fi
  if [ "$want_host" -eq 1 ]; then
    rt_is_compose || die "--to-host gibt es nur im Docker-Verbund."
    [ -n "$host" ] || host="$(_bkp_host_dir)"
    [ -n "$host" ] || _bkp_fail folder "Kein Sicherungs-Ordner auf dem Rechner gewählt — einmalig: lifeagents backup host-dir <ordner>"
    _bkp_host_dir_ok "$host" || _bkp_fail folder "Ordner '${host}' ist kein gültiger, beschreibbarer Ordner auf dem Rechner."
  fi

  local key; key="$(_bkp_key)"
  [ -n "$key" ] && [ "${#key}" -ge 16 ] || _bkp_fail key "Backup-Schluessel fehlt/zu kurz (core.backup_key '${BACKUP_KEY_NAME}', >=16 Zeichen). Der Installer setzt ihn out-of-band (bootstrap_owner _ensure_backup_secret)."
  local kid; kid="$(printf '%s' "$key" | backup_key_id)"
  local name; name="$(_bkp_file_name "$(date -u +%Y%m%d%H%M%S)" "$kid" "$(_bkp_release_tag)")"
  if [ -z "$out" ]; then out="$(pwd)/${name}"; fi

  local bulk; bulk="$(_bkp_bulk_tables)"
  [ -n "$bulk" ] || _bkp_fail dump "Keine zu sichernden Tabellen gefunden (aktive Pakete + backup-Block pruefen)."

  local tmp; tmp="$(_bkp_tmpdir)" || die "Konnte Arbeitsverzeichnis nicht anlegen."
  # Klartext-Reste IMMER aufraeumen (auch bei `die`->exit; RETURN feuert bei exit NICHT). Die CLI
  # beendet sich direkt nach backup_cli -> EXIT-Trap deckt Normal-Rueckkehr UND Fehler-exit. Pfad JETZT
  # in den Trap-String expandieren (Doppel-Quotes): $tmp ist function-local -> bei der global feuernden
  # EXIT-Trap waere es unter `set -u` "unbound variable".
  # shellcheck disable=SC2064  # bewusst JETZT expandieren: $tmp ist local -> bei der global feuernden EXIT-Trap unter `set -u` unbound
  trap "rm -rf -- '$tmp'" EXIT
  # Rechner-Ordner: das Chiffrat entsteht im tmpfs und geht danach in genau einem Kurzlauf-Container hinaus.
  if [ "$want_host" -eq 1 ]; then out="$tmp/${name}"; fi

  # --- (1) data.dump: pg_dump -a --disable-triggers -Fc mit -t je bulk-Tabelle (qualifiziert/validiert) ---
  local dump_args=() t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    _bkp_qual_ok "$t" || { warn "Ueberspringe ungueltigen Tabellennamen: $t"; continue; }
    dump_args+=( -t "$t" )
  done <<< "$bulk"
  # pg_dump laeuft als postgres (runuser/Peer-Auth) und darf das root-eigene 0700-tmpfs NICHT beschreiben
  # -> Ausgabe auf stdout, die root-Shell leitet in die Datei um (postgres fasst das Verzeichnis nie an).
  if ! pg_su_exec pg_dump -d "$N8N_DB_NAME" -a --disable-triggers -Fc "${dump_args[@]}" > "$tmp/data.dump"; then
    _bkp_fail dump "pg_dump fehlgeschlagen."
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
    _bkp_psql_scalar "SELECT jsonb_build_object($sel)" > "$tmp/shared.json" || _bkp_fail dump "shared.json-Export fehlgeschlagen."
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
  local verify_json; verify_json="$(_bkp_psql_scalar "SELECT jsonb_build_object($vsel)")" || _bkp_fail dump "verify_counts-Berechnung fehlgeschlagen."

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
        > "$tmp/manifest.json" || _bkp_fail dump "manifest.json-Bau fehlgeschlagen."

  # --- (5) Tarball -> gpg (Passphrase via fd, nie argv) ---
  local tarf="$tmp/bundle.tar.gz"
  tar -czf "$tarf" -C "$tmp" manifest.json data.dump shared.json || _bkp_fail dump "tar fehlgeschlagen."
  # umask in der Teilschale: gpg legt die Datei dann nie weltlesbar an; chmod danach deckt eine vorhandene Zieldatei ab.
  if ! ( umask 077; gpg_sym_encrypt "$key" "$out" "$tarf" ); then
    _bkp_fail encrypt "gpg-Verschluesselung fehlgeschlagen."
  fi
  chmod 0600 "$out"
  if [ "$want_host" -eq 1 ]; then
    rt_host_put "$host" "$name" < "$out" || _bkp_fail write "Sicherung ließ sich nicht in den Ordner '${host}' auf dem Rechner schreiben."
    _bkp_host_rotate "$host" "$kid"
    ok "Backup geschrieben: ${host}/${name} (Ordner auf dem Rechner)"
  else
    ok "Backup geschrieben: $out"
  fi
  _bkp_state_set LAST_OK "$(date +%s)"
  log "Inhalt:$(printf '%s' "$bulk" | grep -c .) bulk-Tabelle(n) + $(_bkp_filtered | grep -c .) gefilterte; aktive Pakete: ${pkgs_json}"
  # Off-Site: optional verschluesselt an den Telegram-Owner-Chat (best-effort, kippt den fertigen Export nie).
  if [ "$notify" -eq 1 ]; then
    _bkp_notify_telegram "$out" || true
  elif [ "$want_host" -eq 0 ]; then
    log "Off-Site-Hinweis: liegt auf der VM — per scp/Backup wegkopieren (der Schluessel liegt OFFLINE separat). Tipp: 'lifeagents backup export --notify-telegram' schickt eine verschluesselte Kopie an deinen Telegram-Chat."
  fi
}

# ============================================================
# restore — Schluessel vom Notfallblatt
# ============================================================
# _bkp_adopt_sql -> SQL fuer den Anfang der Restore-TX (braucht :'bk_new', je weiterem Blatt-Schluessel :'bk_o<j>'): der
#   bisher aktive Schluessel wird prev-Zeile, der zur Sicherung passende der aktive; weitere Schluessel vom selben Blatt
#   (die Datei traegt aktuellen + aeltere) kommen als prev dazu, damit ein spaeter gedrucktes Blatt alle kennt. Namen mit
#   Mikrosekunden + Laufnummer -> keine PK-Kollision. Schlaegt die TX spaeter fehl, rollt alles mit zurueck.
_bkp_adopt_sql() {
  local j="${1:-0}" i
  cat <<SQL
INSERT INTO core.backup_key(key, value)
  SELECT '${BACKUP_KEY_PREV_PREFIX}' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDD"T"HH24MISSUS'), value
  FROM core.backup_key WHERE key = '${BACKUP_KEY_NAME}' AND value <> :'bk_new'
    AND NOT EXISTS (SELECT 1 FROM core.backup_key WHERE value = :'bk_new' AND key <> '${BACKUP_KEY_NAME}');
INSERT INTO core.backup_key(key, value) VALUES ('${BACKUP_KEY_NAME}', :'bk_new')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
SQL
  for ((i = 0; i < j; i++)); do
    cat <<SQL
INSERT INTO core.backup_key(key, value)
  SELECT '${BACKUP_KEY_PREV_PREFIX}' || to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYYMMDD"T"HH24MISSUS') || '_${i}', :'bk_o${i}'
  WHERE NOT EXISTS (SELECT 1 FROM core.backup_key WHERE value = :'bk_o${i}');
SQL
  done
}

# _bkp_try_parsed <parse-ausgabe> <chiffrat> <klartext-ziel> <datei-id> — waehlt aus den eingegebenen Schluesseln den zur
#   Sicherung passenden (per ID im Dateinamen, ohne ID der Reihe nach) und entschluesselt. Erfolg: rc 0, _BKP_BROUGHT und
#   _BKP_OTHERS (die uebrigen Blatt-Schluessel, je Zeile). Sonst _BKP_TRY_MSG (Alltagssatz), _BKP_TRY_ERR (Form-Code aus der
#   Eingabe) und _BKP_TRY_FINAL=1, wenn ein neuer Versuch nichts bringt (passende ID, Datei beschaedigt). Direkt rufen.
_BKP_BROUGHT=''; _BKP_OTHERS=''; _BKP_TRY_MSG=''; _BKP_TRY_ERR=''; _BKP_TRY_FINAL=0
_bkp_try_parsed() {
  local parsed="$1" enc="$2" out="$3" fkid="$4" l k kid ids='' tried=0 all=''
  _BKP_TRY_MSG=''; _BKP_TRY_ERR=''; _BKP_TRY_FINAL=0; _BKP_BROUGHT=''; _BKP_OTHERS=''
  while IFS= read -r l; do
    case "$l" in
      err:*) [ -n "$_BKP_TRY_ERR" ] || _BKP_TRY_ERR="${l#err:}" ;;
      key:*) all="${all}${l#key:}"$'\n' ;;
    esac
  done <<<"$parsed"
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    kid="$(printf '%s' "$k" | backup_key_id)"
    if [ -n "$fkid" ] && [ "$kid" != "$fkid" ]; then ids="${ids:+$ids, }$kid"; continue; fi
    tried=1
    if gpg_sym_decrypt "$k" "$enc" > "$out" < /dev/null; then
      _BKP_BROUGHT="$k"
      while IFS= read -r l; do [ -n "$l" ] && [ "$l" != "$k" ] && _BKP_OTHERS="${_BKP_OTHERS}${l}"$'\n'; done <<<"$all"
      return 0
    fi
    : > "$out"
    if [ -n "$fkid" ]; then _BKP_TRY_FINAL=1; _BKP_TRY_MSG="$(backup_text msg.corrupt id "$fkid")"; return 1; fi
  done <<<"$all"
  case "$_BKP_TRY_ERR" in
    line[1-4]) _BKP_TRY_MSG="$(backup_text msg.line n "${_BKP_TRY_ERR#line}")" ;;
    length)    _BKP_TRY_MSG="$(backup_text msg.length)" ;;
    chars)     _BKP_TRY_MSG="$(backup_text msg.chars)" ;;
  esac
  if [ -n "$ids" ] && [ -z "$_BKP_TRY_MSG" ]; then _BKP_TRY_MSG="$(backup_text msg.other_key ids "$ids" id "$fkid")"
  elif [ "$tried" = 1 ] && [ -z "$_BKP_TRY_MSG" ]; then _BKP_TRY_MSG="$(backup_text msg.no_open)"; fi
  [ -n "$_BKP_TRY_MSG" ] || _BKP_TRY_MSG="$(backup_text msg.none)"
  return 1
}

# _bkp_ask_key_tty -> Eingabe vom Notfallblatt am Terminal (verdeckt) im Format von backup_key_parse. Zeile fuer Zeile mit
#   sofortiger Pruefung und eigener Meldung je Ursache (Pruefzeichen vs. Form), bis zu 3 Versuche je Zeile, danach
#   "err:line<n>"; wer in Zeile 1 den ganzen Schluessel eingibt, ist sofort fertig.
_bkp_ask_key_tty() {
  local n line d acc='' rc tries msg
  for n in 1 2 3 4; do
    tries=0
    while :; do
      tries=$((tries + 1))
      if [ "$n" = 1 ]; then line="$(ui_input "$(backup_text ask.line1)" 1)"
      else line="$(ui_input "$(backup_text ask.line n "$n")" 1)"; fi
      if [ "$n" = 1 ] && [ "$(printf '%s' "$line" | backup_key_normalize | wc -c)" -ge 64 ]; then
        printf '%s' "$line" | backup_key_parse; return 0
      fi
      rc=0; d="$(printf '%s' "$line" | backup_key_line "$n")" || rc=$?
      [ "$rc" -eq 0 ] && break
      if [ "$tries" -ge 3 ]; then printf 'err:line%s\n' "$n"; return 0; fi
      if [ "$rc" -eq 1 ]; then msg="$(backup_text ask.retry_check n "$n")"; else msg="$(backup_text ask.retry_form n "$n")"; fi
      { printf '  %s\n' "$msg" > /dev/tty; } 2>/dev/null || true
    done
    acc="${acc}${d}"
  done
  printf 'key:%s\n' "$acc"
}

# _bkp_brought_key <chiffrat> <klartext-ziel> <datei-id> <von-stdin:0|1> — kein gespeicherter Schluessel oeffnet die
#   Sicherung: Schluessel vom Notfallblatt holen (stdin bzw. Terminal) -> _BKP_BROUGHT/_BKP_OTHERS. Am Terminal bis zu drei
#   ganze Schluessel (falsches Blatt); ein Zeilenfehler nach drei Versuchen oder eine beschaedigte Datei bricht sofort ab.
#   Jeder Abbruch: nichts geaendert.
_bkp_brought_key() {
  local enc="$1" out="$2" fkid="$3" from_stdin="$4" parsed n un cmd
  un="$(backup_text msg.unchanged)"
  if [ "$from_stdin" = 1 ]; then
    parsed="$(backup_key_parse)"
    _bkp_try_parsed "$parsed" "$enc" "$out" "$fkid" || die "${_BKP_TRY_MSG} ${un}"
    return 0
  fi
  if ! ui_interactive; then
    if rt_is_compose; then cmd="docker exec -i ${LA_PROJECT:-lifeagents}-master lifeagents backup restore <datei> --key-stdin < Notfallblatt.txt"
    else cmd="lifeagents backup restore <datei> --key-stdin < notfallblatt.txt"; fi
    die "$(backup_text msg.no_tty cmd "$cmd") ${un}"
  fi
  if [ -n "$fkid" ]; then parsed="$(backup_text ask.intro_id id "$fkid")"; else parsed="$(backup_text ask.intro)"; fi
  { printf '\n  %s\n\n' "$parsed" > /dev/tty; } 2>/dev/null || true
  for n in 1 2 3; do
    parsed="$(_bkp_ask_key_tty)"
    if _bkp_try_parsed "$parsed" "$enc" "$out" "$fkid"; then return 0; fi
    if [ "$_BKP_TRY_FINAL" = 1 ] || [ -n "$_BKP_TRY_ERR" ]; then die "${_BKP_TRY_MSG} ${un}"; fi
    { printf '  %s\n' "$_BKP_TRY_MSG" > /dev/tty; } 2>/dev/null || true
  done
  die "$(backup_text msg.wrong_3) ${un}"
}

# _bkp_pick_lines (stdin: Dateinamen im Rechner-Ordner) -> Auswahl-Zeilen "Datum · Version · was sie braucht<TAB>name":
#   Sicherungen, die ein gespeicherter Schluessel oeffnet, zuerst, je neueste zuerst. Zeit in UTC wie im Dateinamen.
_bkp_pick_lines() {
  local ids b kid ts ver own='' other='' lbl
  ids=$'\n'"$(_bkp_key_ids)"$'\n'
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    kid="$(_bkp_file_key_id "$b")"; ts=''; ver=''
    [[ "$b" =~ lifeagents-backup-([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2}) ]] \
      && ts="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]} UTC"
    [[ "$b" =~ -(v[0-9][0-9A-Za-z.-]*|vdev)[^/]*\.nla\.enc$ ]] && ver="${BASH_REMATCH[1]}"
    if [ -n "$kid" ] && [[ "$ids" == *$'\n'"$kid"$'\n'* ]]; then
      lbl="${ts:-$b} · ${ver:-?} · $(backup_text pick.own)"; own="${own}${b}"$'\t'"${lbl}"$'\n'
    elif [ -n "$kid" ]; then
      lbl="${ts:-$b} · ${ver:-?} · $(backup_text pick.other id "$kid")"; other="${other}${b}"$'\t'"${lbl}"$'\n'
    else
      lbl="${ts:-$b} · $(backup_text pick.legacy)"; other="${other}${b}"$'\t'"${lbl}"$'\n'
    fi
  done
  { printf '%s' "$own" | sort -r; printf '%s' "$other" | sort -r; } | while IFS=$'\t' read -r b lbl; do
    [ -n "$b" ] && printf '%s\t%s\n' "$lbl" "$b"
  done
}

# ============================================================
# restore
# ============================================================
backup_cmd_restore() {
  require_cmd jq; _bkp_require_pg pg_restore; require_cmd gpg
  _bkp_resolve_db
  # --from-host (Docker-Verbund): <datei> liegt in einem Ordner AUF DEM RECHNER — als voller Pfad oder als Name im gemerkten
  # Ordner (BACKUP_HOST_DIR). Im Verbund ist das ohne Pfad der Normalfall (die Auswahl listet den gemerkten Ordner).
  # --key-stdin: Schluessel vom Notfallblatt aus stdin (Text oder die ganze Notfallblatt-Datei), nur gelesen, wenn kein
  # gespeicherter Schluessel die Datei oeffnet. Nie als Argument (Prozessliste).
  local enc="" force=0 a from_host=0 key_stdin=0
  for a in "$@"; do
    case "$a" in
      --yes|-y) force=1 ;;
      --from-host) from_host=1 ;;
      --key-stdin) key_stdin=1 ;;
      --*)      die "Unbekannte Option: $a" ;;
      *)        enc="$a" ;;
    esac
  done
  # Missing-Arg-Picker (E3): *.nla.enc aus cwd + /root — realpath-dedupe (als root ist cwd oft
  # /root selbst, sonst Dubletten), dann absteigend nach BASENAME sortiert (der traegt den
  # Timestamp -> neueste zuerst; eine Voll-Pfad-Sortierung liesse das Verzeichnis-Praefix
  # dominieren, Cold-Eyes A1). Danach laufen Wipe-Uebersicht + 'ja'-Confirm unveraendert (E8).
  # Kein Treffer/Abbruch -> unveraenderte Usage.
  if rt_is_compose && { [ -z "$enc" ] || [ ! -r "$enc" ]; }; then from_host=1; fi
  if [ -z "$enc" ] && [ "$from_host" -eq 1 ] && ui_interactive; then
    ensure_gum
    local _hd _hpick
    _hd="$(_bkp_host_dir)"
    [ -n "$_hd" ] || die "Kein Sicherungs-Ordner auf dem Rechner gewählt — Datei mit vollem Pfad angeben: lifeagents backup restore --from-host <ordner>/<datei>"
    _hpick="$(rt_host_ls "$_hd" | _bkp_pick_lines | ui_choose 'Backup wiederherstellen (Wipe-Uebersicht + Bestaetigung folgen):' 0 || true)"
    [ -n "$_hpick" ] && enc="$_hpick"
  elif [ -z "$enc" ] && ui_interactive; then
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
  [ -n "$enc" ] || die "Usage: lifeagents backup restore <datei.nla.enc> [--from-host] [--key-stdin] [--yes]"
  local host_src=""
  if [ "$from_host" -eq 1 ]; then
    case "$enc" in
      /*) host_src="$enc" ;;
      */*) die "Datei als Name im gemerkten Ordner oder mit vollem Pfad angeben: $enc" ;;
      *) host_src="$(_bkp_host_dir)"; [ -n "$host_src" ] || die "Kein Sicherungs-Ordner auf dem Rechner gewählt — Datei mit vollem Pfad angeben."; host_src="${host_src%/}/$enc" ;;
    esac
  else
    [ -r "$enc" ] || die "Backup-Datei nicht lesbar: $enc"
  fi

  local src_name; src_name="${host_src:-$enc}"; src_name="${src_name##*/}"

  local tmp; tmp="$(_bkp_tmpdir)" || die "Konnte Arbeitsverzeichnis nicht anlegen."
  # Pfad JETZT in den Trap-String expandieren (s. export): $tmp ist local -> bei der global feuernden
  # EXIT-Trap waere es unter `set -u` "unbound variable".
  # shellcheck disable=SC2064  # bewusst JETZT expandieren: $tmp ist local -> bei der global feuernden EXIT-Trap unter `set -u` unbound
  trap "rm -rf -- '$tmp'" EXIT

  # --- (1) Entschluesseln + Header lesen (VOR jedem Wipe) ---
  # Rechner-Ordner: das Chiffrat zuerst in den tmpfs holen (nur lesend gemountet, genau dieser eine Ordner).
  if [ -n "$host_src" ]; then
    rt_host_get "$(dirname "$host_src")" "$(basename "$host_src")" > "$tmp/in.nla.enc" && [ -s "$tmp/in.nla.enc" ] \
      || die "Sicherung '${host_src}' auf dem Rechner nicht lesbar. Es wurde NICHTS geaendert."
    enc="$tmp/in.nla.enc"
  fi
  # Erst alle gespeicherten Schluessel (aktiver zuerst); oeffnet keiner die Datei, kommt der Schluessel vom Notfallblatt.
  # Ein gespeicherter Schluessel mit der ID aus dem Dateinamen, der trotzdem scheitert = Datei beschaedigt (nicht fragen).
  local brought='' others='' file_kid; file_kid="$(_bkp_file_key_id "$src_name")"
  if ! gpg_sym_decrypt_any "$enc" "$tmp/bundle.tar.gz"; then
    local known; known=$'\n'"$(_bkp_key_ids)"$'\n'
    if [ -n "$file_kid" ] && [[ "$known" == *$'\n'"$file_kid"$'\n'* ]]; then
      die "$(backup_text msg.corrupt_stored id "$file_kid") (${src_name}) $(backup_text msg.unchanged)"
    fi
    _bkp_brought_key "$enc" "$tmp/bundle.tar.gz" "$file_kid" "$key_stdin"
    brought="$_BKP_BROUGHT"; others="$_BKP_OTHERS"; _BKP_BROUGHT=''; _BKP_OTHERS=''
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
      # zwischen >=2 Versionen (vertagt, Trigger: ein Restore scheitert real an der Versionssperre).
      # Aelteres Bundle: ein Update hilft nicht (es geht nur vorwaerts) -> die Version aus dem Dateinamen nennen.
      local rel_hint=''
      [[ "$src_name" =~ -(v[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.-]*)\.nla\.enc$ ]] && rel_hint="${BASH_REMATCH[1]}"
      if [ "$(printf '%s\n%s\n' "$ver" "$inst_ver" | sort -V | head -n1)" = "$ver" ]; then
        die "Versions-Konflikt fuer '$pkg': die Sicherung ist älter (Bundle=$ver, installiert=$inst_ver). Ein Update hilft hier nicht — die Sicherung lässt sich nur in genau ihre Version zurückspielen: Life Agents ${rel_hint:-in der Version der Sicherung} neu installieren, dann erneut restoren (Anleitung: ${BACKUP_GUIDE_URL}). Es wurde NICHTS geaendert."
      fi
      die "Versions-Konflikt fuer '$pkg': die Sicherung ist neuer (Bundle=$ver, installiert=$inst_ver) — erst 'lifeagents update'${rel_hint:+ (mindestens ${rel_hint})}, dann erneut restoren. Versions-uebergreifender Restore wird (wie pg_restore/Borg/restic) bewusst NICHT unterstuetzt. Es wurde NICHTS geaendert."
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
  if [ -n "$brought" ]; then
    log "  $(backup_text msg.adopt id "$(printf '%s' "$brought" | backup_key_id)")"
  fi

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
  if ! pg_su_stdin pg_restore -a --disable-triggers -f - < "$tmp/data.dump" >> "$restore_sql"; then
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

  # psql (postgres via runuser) liest das Skript ueber stdin (`-f -`; root oeffnet die Datei) — kein Dateipfad (das root-eigene
  # 0700-tmpfs ist fuer postgres nicht traversierbar). -1 = eine TX ueber den ganzen Strom; `-f -` statt nacktem stdin, weil
  # psql -1 nur fuer -c/-f zusagt. Ein mitgebrachter Schluessel steht vorn im Strom (\set), nie in restore.sql.
  if { if [ -n "$brought" ]; then
         local o j=0
         psql_setvar bk_new "$brought"
         while IFS= read -r o; do [ -n "$o" ] || continue; psql_setvar "bk_o$j" "$o"; j=$((j + 1)); done <<<"$others"
         _bkp_adopt_sql "$j"
       fi
       cat "$restore_sql"; } \
       | pg_su_psql -v ON_ERROR_STOP=1 -1 -X -q -d "$N8N_DB_NAME" -f -; then
    ok "Restore abgeschlossen (atomar, Count-Verify gruen): $(printf '%s' "$bulk" | grep -c .) bulk-Tabelle(n) + gefilterte Zeilen wiederhergestellt."
  else
    die "Restore fehlgeschlagen — Transaktion zurueckgerollt, die alte Welt ist intakt."
  fi
}

# ============================================================
# key — Notfallblatt
# ============================================================
# backup_cmd_key [--file <pfad>|-] — Notfallblatt ausgeben: ohne --file nur aufs Terminal (/dev/tty, nie in eine Pipe oder
#   ein Log); --file <pfad> legt eine neue 0600-Datei an (vorhandene wird nie ueberschrieben); --file - schreibt auf stdout
#   (Start-App: `docker exec … lifeagents backup key --file -`, Ausgabe nur in deren Datei).
backup_cmd_key() {
  local file='' a want=0 kit
  for a in "$@"; do
    if [ "$want" = 1 ]; then file="$a"; want=0; continue; fi
    case "$a" in
      --file)   want=1 ;;
      --file=*) file="${a#--file=}" ;;
      *)        die "Unbekannte Option: $a (erlaubt: --file <pfad> oder --file -)" ;;
    esac
  done
  [ "$want" = 0 ] || die "--file braucht einen Pfad (oder - für die Ausgabe auf stdout)."
  if [ -z "$file" ]; then
    tty_usable || die "Kein Terminal: das Notfallblatt erscheint nur im Terminal oder mit --file <pfad> (neue Datei, nur für root lesbar)."
  elif [ "$file" != - ] && { [ -e "$file" ] || [ -L "$file" ]; }; then
    die "'${file}' gibt es schon — einen anderen Namen wählen (das Notfallblatt überschreibt nichts)."
  fi
  _bkp_resolve_db
  kit="$(backup_kit_text)" || die "Kein Sicherungs-Schlüssel gespeichert (core.backup_key) — die Installation ist nicht fertig; 'lifeagents doctor' zeigt, was fehlt."
  if [ -z "$file" ]; then
    printf '\n%s\n\n' "$kit" > /dev/tty
  elif [ "$file" = - ]; then
    printf '%s\n' "$kit"
  else
    ( umask 077; set -o noclobber; printf '%s\n' "$kit" > "$file" ) 2>/dev/null \
      || die "Konnte '${file}' nicht anlegen (Ordner vorhanden und beschreibbar?)."
    chmod 0600 "$file"
    ok "Notfallblatt gespeichert: ${file} (nur für root lesbar). Ausdrucken oder im Passwort-Manager ablegen, nicht im Sicherungsordner."
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
key — Notfallblatt mit dem Sicherungs-Schlüssel anzeigen	key
help — Hilfe anzeigen	help
MENU
)"
    [ -n "$_menu_verb" ] && set -- "$_menu_verb"
  fi
  local verb="${1:-help}"; shift || true
  case "$verb" in
    export)  backup_cmd_export "$@" ;;
    host-dir) backup_cmd_host_dir "$@" ;;
    auto)    backup_cmd_auto ;;
    restore) backup_cmd_restore "$@" ;;
    key)     backup_cmd_key "$@" ;;
    help|--help|-h)
      cat >&2 <<'EOF'
lifeagents backup <verb> — Backup/Restore der Nutzerdaten (verschluesselt, paket-bewusst).

  export [pfad] [--notify-telegram]
                           Verschluesseltes Backup der Nutzerdaten schreiben (Default:
                           ./lifeagents-backup-<ts>-k<schlüssel-id>-v<version>.nla.enc).
                           Sichert NUR echte Nutzerdaten (Finanzen/Profil/Trigger/Plaene/Onboarding) via pg_dump —
                           NICHT Code/Workflows/Geheimnisse (die stellt der Installer wieder her).
                           --notify-telegram schickt die fertige .nla.enc zusätzlich als Off-Site-Kopie an den
                           Owner-Telegram-Chat (best-effort: schlaegt der Versand fehl, bleibt das lokale Backup gueltig).
  restore <datei> [--key-stdin] [--yes]
                           Backup wiederherstellen (ATOMAR: alles-oder-nichts). UEBERSCHREIBT alle Nutzerdaten;
                           zeigt VOR der Rückfrage die betroffenen Pakete + Tabellen. Fehlt ein Bundle-Paket ->
                           Angebot, es zu installieren (--no-seed); dann versionsgleich restoren (sonst sauberer
                           Abbruch). --yes überspringt Rückfrage + nimmt Auto-Install an.
                           Öffnet kein gespeicherter Schlüssel die Datei (neuer Rechner), fragt restore verdeckt nach
                           dem Schlüssel vom Notfallblatt; --key-stdin liest ihn (oder die Notfallblatt-Datei) aus stdin.
                           Danach gilt dieser Schlüssel, der bisherige bleibt für ältere Sicherungen gespeichert.
  key [--file <pfad>|-]    Notfallblatt mit dem Sicherungs-Schlüssel: ohne Option nur aufs Terminal; --file legt eine
                           neue Datei an (nur für root lesbar), --file - schreibt auf stdout. Ausdrucken oder im
                           Passwort-Manager ablegen — ohne den Schlüssel lässt sich keine Sicherung öffnen.

Nur im Docker-Verbund (Mac/Windows-App) — Sicherungen liegen in einem Ordner AUF DEM RECHNER, nicht auf der Docker-Platte:
  host-dir [<ordner>]      Sicherungs-Ordner auf dem Rechner zeigen bzw. setzen (absoluter Pfad, wird auf Schreibrecht geprüft).
  export [--to-host [<ordner>]]
                           Ohne Pfad schreibt der Verbund immer in den Rechner-Ordner (behält die letzten 14 Sicherungen
                           mit dem eigenen Schlüssel; Sicherungen eines anderen Rechners im Ordner bleiben liegen).
  restore [<name>|<pfad>] [--from-host] [--key-stdin] [--yes]
                           Ohne Datei: Auswahl aus dem Rechner-Ordner; <name> = Datei im gewählten Ordner.
  auto                     Tägliche Sicherung in den Rechner-Ordner (läuft von selbst um 03:30 im master; ohne Ordner still).

Automatisch (Off-Site, taeglich 03:30) — eine Zeile in die root-crontab ('crontab -e'):
  30 3 * * * cd /root && lifeagents backup export --notify-telegram >> /var/log/lifeagents-backup.log 2>&1
  (lokale Dateien sammeln sich an — keine Auto-Rotation; regelmaessig aufraeumen oder die Telegram-Historie als Generationen nutzen.)

Schlüssel: liegt in core.backup_key (gpg-Passphrase, AES256). OFFLINE separat sichern (lifeagents backup key) — ohne
ihn kein Restore auf einem neuen Rechner.
EOF
      ;;
    *) err "lifeagents backup: unbekannter Verb: $verb"; backup_cli help; return 1 ;;
  esac
}
