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

# _bkp_pgdump_stderr (stdin: stderr von `pg_dump -a`) -> dieselben Zeilen ohne den Block „circular foreign-key constraints“
#   (Warnung, detail-Zeilen mit Tabellennamen, die zwei festen hint-Zeilen). pg_dump meldet Fremdschluessel-Ringe nur bei
#   --data-only (pg_dump.c: getTableDataFKConstraints nur bei dataOnly; Text in pg_dump_sort.c repairDependencyLoop) und raet
#   genau zu --disable-triggers, mit dem wir sichern und zurueckspielen -> fuer uns harmlos, fuer Laien erschreckend. Jede
#   andere Zeile (auch andere Warnungen samt ihren Hinweisen, Fehler) bleibt.
_bkp_pgdump_stderr() {
  awk '
    /^pg_dump: warning: there are circular foreign-key constraints (on this table|among these tables):$/ { ring = 1; next }
    ring && /^pg_dump: detail: / { next }
    ring && /^pg_dump: hint: (You might not be able to restore the dump without using --disable-triggers|Consider using a full dump instead of a --data-only dump)/ { next }
    { ring = 0; print }
  '
}

# _bkp_jsonb_obj <"'key', wert">… -> SQL-Ausdruck fuer ein jsonb-Objekt aus beliebig vielen Paaren: PostgreSQL nimmt hoechstens
#   100 Argumente je Funktion ("cannot pass more than 100 arguments"), jsonb_build_object also hoechstens 50 Paare -> Bloecke
#   zu 50, mit || verbunden. Ohne Paare '{}'.
_bkp_jsonb_obj() {
  local out='' chunk='' i=0 p
  [ "$#" -gt 0 ] || { printf "'{}'::jsonb"; return 0; }
  for p in "$@"; do
    chunk="${chunk:+$chunk, }$p"; i=$((i + 1))
    if [ "$i" -eq 50 ]; then out="${out:+$out || }jsonb_build_object($chunk)"; chunk=''; i=0; fi
  done
  [ -z "$chunk" ] || out="${out:+$out || }jsonb_build_object($chunk)"
  printf '%s' "$out"
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
# vom Nutzer gewaehlten Ordner AUF DEM RECHNER. Gemerkt als BACKUP_HOST_DIR in core.env (nicht geheim) in der Schreibweise des
# Nutzers (Mac/Linux /…, Windows C:\…); an Docker geht immer die Docker-Form (_bkp_hd). Kein Komma (Trenner der --mount-
# Angabe), kein Anfuehrungszeichen, kein Zeilenumbruch.
BACKUP_HOST_KEEP="${BACKUP_HOST_KEEP:-14}"   # so viele automatische Sicherungen bleiben im Ordner (aelteste gehen zuerst)
_bkp_host_dir() { read_env_value "$(lifeagents_env_file core)" BACKUP_HOST_DIR 2>/dev/null || true; }
_bkp_host_dir_valid() {
  case "$1" in
    /*|[A-Za-z]:\\*|[A-Za-z]:/*) ;; *) return 1 ;;
  esac
  case "$1" in *,*|*$'\n'*|*$'\r'*|*'"'*) return 1 ;; esac
  return 0
}
# _bkp_hd <pfad> -> Docker-Form eines Rechner-Pfads: Windows "C:\Daten\x" -> "/run/desktop/mnt/host/c/Daten/x" (so muss ein
#   Container, der ueber den Docker-Socket einen weiteren startet, Laufwerke unter Docker Desktop/WSL2 angeben; "/C/Users/…"
#   scheitert mit "bind source path does not exist" — nur Erfahrungsberichte, Abnahme auf echtem Windows). Sonst unveraendert;
#   ein abschliessender Trenner faellt weg.
_bkp_hd() {
  local p="$1" d
  if [[ "$p" =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
    d="${BASH_REMATCH[1],,}"
    p="${BASH_REMATCH[2]//\\//}"
    p="/run/desktop/mnt/host/${d}/${p}"
  fi
  [ "$p" = / ] || p="${p%/}"
  printf '%s' "$p"
}
# _bkp_join <ordner> <name> -> Pfad in der Schreibweise des Ordners (Windows mit "\", sonst "/").
_bkp_join() { case "$1" in *\\*|[A-Za-z]:) printf '%s\\%s' "${1%\\}" "$2" ;; *) printf '%s/%s' "${1%/}" "$2" ;; esac; }
# _bkp_rotate_victims <behalten> <schluessel-id> (stdin: Dateinamen) -> die zu loeschenden: nur Sicherungen mit DIESER
#   Schluessel-ID jenseits der neuesten <behalten>. Fremde IDs (ein alter Rechner im selben Ordner) und Namen ohne ID
#   bleiben immer liegen — sonst loeschte der neue Rechner nach 14 Tagen genau die Sicherungen, aus denen er herkommt.
_bkp_rotate_victims() {
  grep -E "^lifeagents-backup-[0-9]{14}-${2}-v[0-9A-Za-z.-]+\.nla\.enc\$" | sort -r | tail -n +$(( $1 + 1 ))
}
# _bkp_host_rotate <ordner> <schluessel-id> — eigene alte Sicherungen im Rechner-Ordner entfernen. Fehler = nur Warnung.
_bkp_host_rotate() {
  local v=() hd; hd="$(_bkp_hd "$1")"
  mapfile -t v < <(rt_host_ls "$hd" | _bkp_rotate_victims "$BACKUP_HOST_KEEP" "$2" || true)
  [ "${#v[@]}" -gt 0 ] && [ -n "${v[0]}" ] || return 0
  rt_host_rm "$hd" "${v[@]}" || warn "Alte Sicherungen im Ordner '$1' ließen sich nicht aufräumen."
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
_bkp_state_set() { { env_upsert "$BACKUP_STATE_FILE" "$1" "$2" && chmod 0600 "$BACKUP_STATE_FILE"; } 2>/dev/null || true; }
# _bkp_fail <code> <meldung> — Fehlschlag einer Sicherung mit festem Grund festhalten, dann abbrechen.
_bkp_fail() { _bkp_state_set LAST_FAIL "$(date +%s)"; _bkp_state_set LAST_FAIL_REASON "$1"; shift; die "$@"; }

# _bkp_path_clean <pfad> -> Eingabe bereinigt: Leerraum und umschliessende Anfuehrungszeichen am Rand weg ("Als Pfad
#   kopieren" unter Windows liefert "C:\…" in Anfuehrungszeichen, der Finder-Pfad kommt oft mit Leerzeichen).
_bkp_path_clean() {
  local p="$1"
  p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
  case "$p" in \"*\"|\'*\') p="${p:1:${#p}-2}" ;; esac
  printf '%s' "$p"
}
# _bkp_folder_problem <ordner> -> fester Code, warum der Ordner nicht taugt (leer = taugt): invalid | missing | access |
#   readonly. Eine Adresse fuer CLI (host-dir), Fragebogen (bridge.sh backup-dir) und jede Sicherung (Grund in backup.state).
#   "missing" vs. "access" trennt Docker Desktop nicht verlaesslich (beides scheitert als Bind-Pfad) -> Texte nennen beides.
_bkp_folder_problem() {
  _bkp_host_dir_valid "$1" || { printf invalid; return 0; }
  local hd; hd="$(_bkp_hd "$1")"
  rt_host_exists "$hd" || { printf missing; return 0; }
  rt_host_readable "$hd" || { printf access; return 0; }
  rt_host_check "$hd" || { printf readonly; return 0; }
  return 0
}
# _bkp_reason_of <problem> -> Grund-Code fuer backup.state (folder = nicht erreichbar, write = nicht beschreibbar).
_bkp_reason_of() { case "$1" in readonly) printf write ;; *) printf folder ;; esac; }
# _bkp_folder_target <eltern-ordner> -> der Ordner, in den gesichert wird (Schreibweise des Nutzers): liegen im gewaehlten Ordner
#   schon Sicherungen, dieser selbst (sonst entstuende ".../Life Agents Sicherungen/Life Agents Sicherungen"); gibt es darin einen
#   Unterordner mit dem Namen aus IRGENDEINER Katalog-Sprache (alter Rechner auf Deutsch, neuer auf Englisch), dieser; sonst der
#   Name in der Owner-Sprache (Owner-Entscheid F4). Legt nichts an.
_bkp_folder_target() {
  local dir="$1" n f
  if rt_host_ls "$(_bkp_hd "$dir")" 2>/dev/null | grep -q .; then printf '%s' "$dir"; return 0; fi
  for f in "$(_pkg_dir)"/core/locales/*.json; do
    n="$(jq -r '.["core.backup.folder_name"] // empty' "$f" 2>/dev/null || true)"
    [ -n "$n" ] || continue
    if rt_host_exists "$(_bkp_hd "$(_bkp_join "$dir" "$n")")"; then _bkp_join "$dir" "$n"; return 0; fi
  done
  n="$(backup_text folder_name)"
  _bkp_join "$dir" "${n:-Life Agents Sicherungen}"
}
# _bkp_foreign_ids <ordner> -> Schluessel-IDs der Sicherungen im Ordner, die zu keinem gespeicherten Schluessel gehoeren
#   (Einteilung _bkp_classify; Namen ohne ID haben keine ID zum Nennen und fehlen hier).
_bkp_foreign_ids() {
  local b k cls _ts _v out=''
  while IFS=$'\t' read -r b k cls _ts _v; do
    [ "$cls" = other ] && [[ " $out " != *" $k "* ]] && out="${out:+$out }$k"
  done < <(rt_host_ls "$(_bkp_hd "$1")" 2>/dev/null | _bkp_classify || true)
  printf '%s' "$out"
}

# backup_cmd_host_dir [<ordner> [--create]] — Sicherungs-Ordner auf dem Rechner zeigen bzw. setzen (Fragebogen, Terminal).
#   --create: <ordner> ist der Eltern-Ordner (z. B. iCloud Drive); Ziel nach _bkp_folder_target, fehlt es, wird es angelegt,
#   die Schreibprobe laeuft dort, erst dann wird es gemerkt. Sicherungen eines anderen Schluessels bleiben, es gibt einen Hinweis.
backup_cmd_host_dir() {
  rt_is_compose || die "Der Sicherungs-Ordner auf dem Rechner gibt es nur im Docker-Verbund."
  if [ "$#" -eq 0 ]; then
    local d; d="$(_bkp_host_dir)"
    if [ -n "$d" ]; then printf '%s\n' "$d"; else log "Noch kein Sicherungs-Ordner gewählt."; fi
    return 0
  fi
  local dir create=0 prob target foreign
  dir="$(_bkp_path_clean "$1")"
  [ "${2:-}" = --create ] && create=1
  if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$create" != 1 ]; }; then die "Usage: lifeagents backup host-dir [<ordner> [--create]]"; fi
  prob="$(_bkp_folder_problem "$dir")"
  case "$prob" in
    '') ;;
    invalid)  die "Ungültiger Ordner '${dir}' (voller Pfad auf dem Rechner, z. B. /Users/… oder C:\\Users\\…, ohne Komma)." ;;
    readonly) die "In den Ordner '${dir}' lässt sich nicht schreiben (schreibgeschützt oder voll)." ;;
    *)        die "Ordner '${dir}' ist für Docker nicht erreichbar (gibt es ihn? Mac: Systemeinstellungen > Datenschutz & Sicherheit > Dateien und Ordner > Docker erlauben; Windows: Laufwerk und Schreibweise prüfen)." ;;
  esac
  target="$dir"
  if [ "$create" = 1 ]; then
    target="$(_bkp_folder_target "$dir")"
    if [ "$target" != "$dir" ]; then
      rt_host_mkdir "$(_bkp_hd "$dir")" "${target##*[\\/]}" || die "Konnte in '${dir}' den Ordner '${target##*[\\/]}' nicht anlegen."
    fi
    rt_host_check "$(_bkp_hd "$target")" || die "In den Ordner '${target}' lässt sich nicht schreiben."
  fi
  env_upsert "$(lifeagents_env_file core)" BACKUP_HOST_DIR "$target"
  ok "Sicherungen gehen ab jetzt nach '${target}' (auf dem Rechner, verschlüsselt)."
  foreign="$(_bkp_foreign_ids "$target")"
  if [ -n "$foreign" ]; then
    log "Hier liegen Sicherungen eines anderen Rechners (${foreign}). Sie bleiben erhalten; wiederherstellen: ${BACKUP_GUIDE_URL}"
  fi
}

# _bkp_stale_notify — Docker-Verbund: ist die Bezugszeit (backup_ref_epoch) aelter als BACKUP_STALE_S, bekommt der Owner eine
#   Telegram-Nachricht mit dem festen Grund als Alltagssatz (Ordnername ja, Pfad und Schluessel nie). Nur tagsueber
#   (BACKUP_NOTIFY_HOURS, Haushalts-Zeitzone; der Takt laeuft um 03:30 und danach stuendlich bis zum Erfolg), hoechstens alle
#   20 h, ohne gewaehlten Ordner nur woechentlich (dort hilft taegliches Erinnern nicht, Owner-Entscheid F1). Sperre LAST_NOTIFY.
#   Best-effort, immer rc 0.
BACKUP_NOTIFY_EVERY_S="${BACKUP_NOTIFY_EVERY_S:-72000}"          # 20 h
BACKUP_NOTIFY_NOFOLDER_S="${BACKUP_NOTIFY_NOFOLDER_S:-604800}"   # 7 Tage
BACKUP_NOTIFY_HOURS="${BACKUP_NOTIFY_HOURS:-09-20}"               # HH-HH, beide einschliesslich
_bkp_stale_notify() {
  local now ref ok_at last_n reason days folder txt every tz h from to
  now="$(date +%s)"
  ref="$(backup_ref_epoch)"; case "$ref" in ''|*[!0-9]*) ref=0 ;; esac
  [ $((now - ref)) -gt "$BACKUP_STALE_S" ] || return 0
  tz="$(read_env_value "$(lifeagents_env_file core)" HOUSEHOLD_TIMEZONE 2>/dev/null || true)"
  h="$(TZ="${tz:-Europe/Berlin}" date +%H)"; from="${BACKUP_NOTIFY_HOURS%-*}"; to="${BACKUP_NOTIFY_HOURS#*-}"
  [ "$((10#$h))" -ge "$((10#$from))" ] && [ "$((10#$h))" -le "$((10#$to))" ] || return 0
  reason="$(read_env_value "$BACKUP_STATE_FILE" LAST_FAIL_REASON 2>/dev/null || true)"
  case "$reason" in folder|nofolder|key|dump|encrypt|write) ;; *) reason=dump ;; esac
  every="$BACKUP_NOTIFY_EVERY_S"; [ "$reason" = nofolder ] && every="$BACKUP_NOTIFY_NOFOLDER_S"
  last_n="$(read_env_value "$BACKUP_STATE_FILE" LAST_NOTIFY 2>/dev/null || true)"; case "$last_n" in ''|*[!0-9]*) last_n=0 ;; esac
  [ "$last_n" -le "$now" ] || last_n=0   # Uhr zurueckgestellt
  [ $((now - last_n)) -ge "$every" ] || return 0
  ok_at="$(read_env_value "$BACKUP_STATE_FILE" LAST_OK 2>/dev/null || true)"; case "$ok_at" in ''|*[!0-9]*) ok_at=0 ;; esac
  folder="$(_bkp_host_dir)"; folder="${folder//\\//}"; folder="${folder##*/}"
  if [ "$ok_at" -gt 0 ]; then days=$(( (now - ok_at) / 86400 )); txt="$(backup_text notify.stale_since days "$days")"
  else txt="$(backup_text notify.stale_never)"; fi
  txt="${txt} $(backup_text "notify.reason.${reason}" folder "${folder:-?}")"$'\n'"$(backup_text notify.guide url "$BACKUP_GUIDE_URL")"
  notify_owner_telegram "$txt" >/dev/null 2>&1 || return 0
  _bkp_state_set LAST_NOTIFY "$now"
  return 0
}

# backup_cmd_auto — taegliche Sicherung in den Rechner-Ordner (Tick im master, update_runner.sh: 03:30, nach einem Fehlschlag
#   stuendlich). Ohne gemerkten Ordner nur der Vermerk "nofolder" (Bestand ohne Ordner, Owner-Entscheid F1: doctor ROT +
#   Chat-Hinweis statt Dialog); jeder Fehler nur als Warnung, damit der Tick weiterlaeuft. Danach ggf. der Chat-Hinweis.
backup_cmd_auto() {
  if [ -z "$(_bkp_host_dir)" ]; then
    _bkp_state_set LAST_FAIL "$(date +%s)"; _bkp_state_set LAST_FAIL_REASON nofolder
  else
    ( backup_cmd_export --to-host ) || warn "Tägliche Sicherung in den Rechner-Ordner fehlgeschlagen — nächster Versuch in einer Stunde."
  fi
  _bkp_resolve_db
  _bkp_stale_notify
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
      case "$a" in /*|[A-Za-z]:\\*|[A-Za-z]:/*) host="$a"; continue ;; esac
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
    local hprob; hprob="$(_bkp_folder_problem "$host")"
    [ -z "$hprob" ] || _bkp_fail "$(_bkp_reason_of "$hprob")" "Ordner '${host}' ist auf dem Rechner nicht erreichbar oder nicht beschreibbar (${hprob})."
  fi

  # Eine Sperre fuer Sicherung, Wiederherstellung und Update (bis 30 s: der Minuten-Takt haelt sie kurz). Belegt = Grund busy:
  # kein Alarm (doctor/Chat werten nur das Alter), der Takt versucht es stuendlich erneut.
  update_lock_acquire 30 || _bkp_fail busy "Gerade läuft ein Update oder eine Wiederherstellung — die Sicherung folgt später."
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
  # stderr erst nach dem Lauf gefiltert ausgeben (_bkp_pgdump_stderr), der Exit-Code bleibt der von pg_dump.
  local dump_rc=0
  pg_su_exec pg_dump -d "$N8N_DB_NAME" -a --disable-triggers -Fc "${dump_args[@]}" > "$tmp/data.dump" 2> "$tmp/dump.err" || dump_rc=$?
  _bkp_pgdump_stderr < "$tmp/dump.err" >&2 || true
  if [ "$dump_rc" -ne 0 ]; then
    _bkp_fail dump "pg_dump fehlgeschlagen."
  fi

  # --- (2) shared.json: gefilterte Tabellen als jsonb (pg_dump kann nicht zeilen-filtern) ---
  local sel=() qual cond
  while IFS=$'\t' read -r qual cond; do
    [ -n "$qual" ] || continue
    _bkp_qual_ok "$qual" || { warn "Ueberspringe ungueltige filtered-Tabelle: $qual"; continue; }
    sel+=("$(printf "'%s', COALESCE((SELECT jsonb_agg(x) FROM %s x WHERE %s), '[]'::jsonb)" "$qual" "$qual" "$cond")")
  done < <(_bkp_filtered)
  if [ "${#sel[@]}" -gt 0 ]; then
    _bkp_psql_scalar "SELECT $(_bkp_jsonb_obj "${sel[@]}")" > "$tmp/shared.json" || _bkp_fail dump "shared.json-Export fehlgeschlagen."
  else
    printf '{}' > "$tmp/shared.json"
  fi

  # --- (3) verify_counts: count(*) je bulk- + filtered-Tabelle (Korruptions-Versicherung, Opus B3) ---
  local vsel=() n
  while IFS= read -r t; do
    [ -n "$t" ] || continue; _bkp_qual_ok "$t" || continue
    vsel+=("$(printf "'%s', (SELECT count(*) FROM %s)" "$t" "$t")")
  done <<< "$bulk"
  while IFS=$'\t' read -r qual cond; do
    [ -n "$qual" ] || continue; _bkp_qual_ok "$qual" || continue
    vsel+=("$(printf "'%s', (SELECT count(*) FROM %s WHERE %s)" "$qual" "$qual" "$cond")")
  done < <(_bkp_filtered)
  local verify_json; verify_json="$(_bkp_psql_scalar "SELECT $(_bkp_jsonb_obj "${vsel[@]}")")" || _bkp_fail dump "verify_counts-Berechnung fehlgeschlagen."

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
    rt_host_put "$(_bkp_hd "$host")" "$name" < "$out" || _bkp_fail write "Sicherung ließ sich nicht in den Ordner '${host}' auf dem Rechner schreiben."
    _bkp_host_rotate "$host" "$kid"
    ok "Backup geschrieben: $(_bkp_join "$host" "$name") (Ordner auf dem Rechner)"
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
#   _BKP_OTHERS (die uebrigen Blatt-Schluessel, je Zeile). Sonst _BKP_TRY_MSG (Alltagssatz), _BKP_TRY_CODE (fester Code fuer
#   die Start-App, _bkp_rdie), _BKP_TRY_LINE, _BKP_TRY_ERR (Form-Code aus der Eingabe) und _BKP_TRY_FINAL=1, wenn ein neuer
#   Versuch nichts bringt (passende ID, Datei beschaedigt). Direkt rufen, nie in $(…) (die Variablen gingen verloren).
_BKP_BROUGHT=''; _BKP_OTHERS=''; _BKP_TRY_MSG=''; _BKP_TRY_ERR=''; _BKP_TRY_FINAL=0; _BKP_TRY_CODE=''; _BKP_TRY_LINE=0
_bkp_try_parsed() {
  local parsed="$1" enc="$2" out="$3" fkid="$4" l k kid ids='' tried=0 all=''
  _BKP_TRY_MSG=''; _BKP_TRY_ERR=''; _BKP_TRY_FINAL=0; _BKP_BROUGHT=''; _BKP_OTHERS=''; _BKP_TRY_CODE=''; _BKP_TRY_LINE=0
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
    if [ -n "$fkid" ]; then _BKP_TRY_FINAL=1; _BKP_TRY_CODE=corrupt; _BKP_TRY_MSG="$(backup_text msg.corrupt id "$fkid")"; return 1; fi
  done <<<"$all"
  case "$_BKP_TRY_ERR" in
    line[1-4]) _BKP_TRY_CODE=key_line; _BKP_TRY_LINE="${_BKP_TRY_ERR#line}"; _BKP_TRY_MSG="$(backup_text msg.line n "$_BKP_TRY_LINE")" ;;
    length)    _BKP_TRY_CODE=key_format; _BKP_TRY_MSG="$(backup_text msg.length)" ;;
    chars)     _BKP_TRY_CODE=key_format; _BKP_TRY_MSG="$(backup_text msg.chars)" ;;
  esac
  if [ -n "$ids" ] && [ -z "$_BKP_TRY_MSG" ]; then _BKP_TRY_CODE=key_foreign; _BKP_TRY_MSG="$(backup_text msg.other_key ids "$ids" id "$fkid")"
  elif [ "$tried" = 1 ] && [ -z "$_BKP_TRY_MSG" ]; then _BKP_TRY_CODE=key_no_open; _BKP_TRY_MSG="$(backup_text msg.no_open)"; fi
  if [ -z "$_BKP_TRY_MSG" ]; then _BKP_TRY_CODE=key_needed; _BKP_TRY_MSG="$(backup_text msg.none)"; fi
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
#   Sicherung: Schluessel vom Notfallblatt holen (stdin, Blatt-Block aus --in-stdin bzw. Terminal) -> _BKP_BROUGHT/_BKP_OTHERS.
#   Am Terminal bis zu drei ganze Schluessel (falsches Blatt); ein Zeilenfehler nach drei Versuchen oder eine beschaedigte
#   Datei bricht sofort ab. Jeder Abbruch: nichts geaendert, Code ueber _bkp_rdie.
_bkp_brought_key() {
  local enc="$1" out="$2" fkid="$3" from_stdin="$4" parsed n un cmd
  un="$(backup_text msg.unchanged)"
  if [ "$from_stdin" = 1 ]; then
    if [ "$_BKP_SHEET_SET" = 1 ]; then
      [ -n "${_BKP_SHEET//[[:space:]]/}" ] || _bkp_rdie key_needed "$(backup_text msg.none) ${un}" --arg id "$fkid"
      parsed="$(printf '%s' "$_BKP_SHEET" | backup_key_parse)"
    else
      parsed="$(backup_key_parse)"
    fi
    _bkp_try_parsed "$parsed" "$enc" "$out" "$fkid" && return 0
    _bkp_rdie "$_BKP_TRY_CODE" "${_BKP_TRY_MSG} ${un}" --arg id "$fkid" --argjson line "${_BKP_TRY_LINE:-0}"
  fi
  if [ "$_BKP_JSON" = 1 ] || ! ui_interactive; then
    if rt_is_compose; then cmd="$(rt_master_cli_hint) backup restore <datei> --key-stdin < Notfallblatt.txt"
    else cmd="lifeagents backup restore <datei> --key-stdin < notfallblatt.txt"; fi
    _bkp_rdie key_needed "$(backup_text msg.no_tty cmd "$cmd") ${un}" --arg id "$fkid"
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

# _bkp_classify (stdin: Dateinamen im Rechner-Ordner) -> je Sicherung "name<TAB>id<TAB>own|other|legacy<TAB>zeit<TAB>version"
#   (zeit = 14 Ziffern UTC aus dem Namen). Die eine Stelle fuer eigen/fremd: Terminal-Auswahl, Fragebogen-Hinweis, App-Liste.
#   Namen ohne ID (legacy) gehoeren zu keinem bekannten Schluessel und zaehlen ueberall wie fremde.
_bkp_classify() {
  local ids b kid ts ver cls
  ids=$'\n'"$(_bkp_key_ids)"$'\n'
  while IFS= read -r b; do
    case "$b" in *.nla.enc) ;; *) continue ;; esac
    kid="$(_bkp_file_key_id "$b")"; ts=''; ver=''
    [[ "$b" =~ lifeagents-backup-([0-9]{14}) ]] && ts="${BASH_REMATCH[1]}"
    [[ "$b" =~ -(v[0-9][0-9A-Za-z.-]*|vdev)[^/]*\.nla\.enc$ ]] && ver="${BASH_REMATCH[1]}"
    if [ -z "$kid" ]; then cls=legacy; elif [[ "$ids" == *$'\n'"$kid"$'\n'* ]]; then cls=own; else cls=other; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$kid" "$cls" "$ts" "$ver"
  done
}
# _bkp_sorted (stdin: _bkp_classify) -> dieselben Zeilen, fremde und alte zuerst, darin neueste zuerst: auf einem neuen Rechner
#   im geteilten Ordner ist die eigene, neueste Sicherung die fast leere der Neuinstallation, gesucht ist die des alten Rechners.
_bkp_sorted() {
  awk -F '\t' 'BEGIN { OFS = "\t" } { print ($3 == "own" ? 1 : 0), $0 }' | sort -t "$(printf '\t')" -k1,1n -k5,5r -k2,2r | cut -f2-
}
# _bkp_pick_lines (stdin: Dateinamen im Rechner-Ordner) -> Auswahl-Zeilen "Datum · Version · was sie braucht<TAB>name".
_bkp_pick_lines() {
  local b kid cls ts ver when lbl
  _bkp_classify | _bkp_sorted | while IFS=$'\t' read -r b kid cls ts ver; do
    when="$b"
    [ "${#ts}" = 14 ] && when="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:8:2}:${ts:10:2} UTC"
    case "$cls" in
      own)    lbl="${when} · ${ver:-?} · $(backup_text pick.own)" ;;
      other)  lbl="${when} · ${ver:-?} · $(backup_text pick.other id "$kid")" ;;
      *)      lbl="${when} · $(backup_text pick.legacy)" ;;
    esac
    printf '%s\t%s\n' "$lbl" "$b"
  done
}

# --- Restore fuer die Start-App: feste Codes, Probelauf, Hintergrund-Lauf -------------------------------------------------
# Im JSON-Modus (--json) endet jeder Restore-Weg mit genau einem JSON-Objekt auf stdout ({ok:true,…} bzw. {ok:false, code,…});
# der Satz geht auf stderr. Codes (die App uebersetzt sie, report::ERROR_CODES): key_needed key_line key_format key_foreign
# key_no_open corrupt corrupt_stored bundle_incomplete format package_unknown version_older version_newer needs_setup no_tables
# unreadable safety
# folder nofolder busy internal. Eigene Funktion statt die_because: die schreibt die Ergebnis-Datei eines Updates, hier
# liest die App stdout bzw. backup.state.
_BKP_JSON=0; _BKP_CHILD=0; _BKP_SHEET=''; _BKP_SHEET_SET=0
BACKUP_RESTORE_LOCK="${BACKUP_RESTORE_LOCK:-/run/lifeagents-restore.lock}"
# _bkp_rdie <code> <satz> [jq-argumente…] — Restore abbrechen: im Hintergrund-Lauf LAST_RESTORE_FAIL + Grund in backup.state,
#   im JSON-Modus das Fehler-Objekt (weitere Felder per --arg/--argjson), sonst die wie bisher. Immer exit 1.
_bkp_rdie() {
  local code="$1" msg="$2"; shift 2
  if [ "$_BKP_CHILD" = 1 ]; then _bkp_state_set LAST_RESTORE_FAIL "$(date +%s)"; _bkp_state_set LAST_RESTORE_REASON "$code"; fi
  if [ "$_BKP_JSON" = 1 ]; then
    err "$msg"
    jq -cn --arg code "$code" "$@" '{ok: false} + $ARGS.named' 2>/dev/null || printf '{"ok":false,"code":"%s"}\n' "$code"
    exit 1
  fi
  die "$msg"
}
# _bkp_restore_running -> 0, wenn ein Hintergrund-Lauf die Restore-Sperre haelt.
_bkp_restore_running() {
  need_cmd flock || return 1
  [ -e "$BACKUP_RESTORE_LOCK" ] || return 1
  ! flock -n "$BACKUP_RESTORE_LOCK" true 2>/dev/null
}
# _bkp_system_tables -> qualifizierte Tabellen aus backup.system_tables aller aktiven Pakete (fuellt das System selbst: Code-Seed,
#   abgerufene Kurse, abgeleitete Salden, Onboarding-Zeilen der Einrichtung) — zaehlen nicht als „eigene Daten“.
_bkp_system_tables() {
  local active mf pkg schema t
  active="$(_bkp_active_names)"
  for mf in "$(_pkg_dir)"/*/manifest.json; do
    [ -r "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)" || continue
    _bkp_is_active "$pkg" "$active" || continue
    schema="$(jq -r '.schema // empty' "$mf" 2>/dev/null)"
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      case "$t" in *.*) printf '%s\n' "$t" ;; *) [ -n "$schema" ] && printf '%s.%s\n' "$schema" "$t" ;; esac
    done < <(jq -r '.backup.system_tables[]?' "$mf" 2>/dev/null)
  done
}
# _bkp_has_data <bulk> -> 0, wenn eine bulk-Tabelle ausser den System-Tabellen Zeilen hat (frisch eingerichtet = 1). Die
#   gefilterten Tabellen zaehlen nicht: die Einrichtung legt dort schon das Haushalts-Skelett an.
_bkp_has_data() {
  local sys t q=''
  sys=$'\n'"$(_bkp_system_tables)"$'\n'
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [[ "$sys" == *$'\n'"$t"$'\n'* ]] && continue
    _bkp_qual_ok "$t" || continue
    q="${q:+$q OR }EXISTS (SELECT 1 FROM ${t})"
  done <<<"$1"
  [ -n "$q" ] || return 1
  [ "$(_bkp_psql_scalar "SELECT (${q})::int")" = 1 ]
}
# _bkp_pkg_needs_setup <pkg> -> 0, wenn das Paket Zugangsdaten verlangt (credentials im Manifest): ohne Terminal entstuende es
#   halb eingerichtet -> die App installiert es nicht selbst (Code needs_setup).
_bkp_pkg_needs_setup() {
  local mf; mf="$(_pkg_dir)/$1/manifest.json"
  [ -r "$mf" ] || return 1
  jq -e '(.credentials // {}) | [to_entries[] | select(.key != "_comment")] | length > 0' "$mf" >/dev/null 2>&1
}
# _bkp_read_in_stdin <ziel> — --in-stdin (Start-App, 'Andere Datei waehlen'): erste Zeile "sheet <base64>" (Blatt-Text, leer =
#   kein Blatt), danach die Sicherung base64-codiert bis zum Ende. base64, weil `read` Zeichen der Locale zaehlt (Blatt UTF-8,
#   ko) und die App nur Text ueber stdin reicht; eine Zeile liest bash exakt, ohne vom Folgenden etwas zu verschlucken. Das
#   Blatt bleibt nur in der Shell-Variable _BKP_SHEET, nie in einer Datei.
_bkp_read_in_stdin() {
  local hdr
  IFS= read -r hdr || _bkp_rdie unreadable "Keine Eingabe auf stdin."
  [[ "$hdr" =~ ^sheet\ ?([A-Za-z0-9+/=]*)$ ]] || _bkp_rdie unreadable "Eingabe auf stdin hat nicht die erwartete Form."
  _BKP_SHEET=''
  if [ -n "${BASH_REMATCH[1]}" ]; then
    _BKP_SHEET="$(printf '%s' "${BASH_REMATCH[1]}" | base64 -d 2>/dev/null)" || _bkp_rdie key_format "$(backup_text msg.length)"
  fi
  _BKP_SHEET_SET=1
  base64 -d > "$1" 2>/dev/null && [ -s "$1" ] || _bkp_rdie unreadable "Die gewählte Sicherung ließ sich nicht lesen."
}

# backup_cmd_list --json — Sicherungen im gemerkten Rechner-Ordner fuer die Start-App, Reihenfolge wie die Terminal-Auswahl:
#   {ok:true, folder, backups:[{name, date (ISO UTC), release, key_id, own}]}; ohne Ordner {ok:false, code:"nofolder"}.
backup_cmd_list() {
  [ "${1:-}" = --json ] || die "Usage: lifeagents backup list --json"
  _BKP_JSON=1
  _bkp_resolve_db
  local hd prob; hd="$(_bkp_host_dir)"
  [ -n "$hd" ] || _bkp_rdie nofolder "Noch kein Sicherungs-Ordner gewählt."
  prob="$(_bkp_folder_problem "$hd")"
  [ -z "$prob" ] || _bkp_rdie folder "Der Sicherungs-Ordner ist nicht erreichbar (${prob})." --arg problem "$prob"
  rt_host_ls "$(_bkp_hd "$hd")" | _bkp_classify | _bkp_sorted | jq -Rsc --arg folder "$hd" '
    [split("\n")[] | select(length > 0) | split("\t")
     | { name: .[0], key_id: (if .[1] == "" then null else .[1] end), own: (.[2] == "own"),
         date: (.[3] as $t | if ($t | length) == 14 then "\($t[0:4])-\($t[4:6])-\($t[6:8])T\($t[8:10]):\($t[10:12]):\($t[12:14])Z" else null end),
         release: (if .[4] == "" then null else .[4] end) }]
    | { ok: true, folder: $folder, backups: . }'
}

# backup_cmd_restore_status --json — Stand des letzten Hintergrund-Laufs: {ok:true, state: idle|running|ok|fail|unfinished,
#   code, name, created, foreign, started}; unfinished = gestartet, ohne Ergebnis und die Restore-Sperre ist frei (Rechner aus,
#   Container neu, Lauf abgebrochen) — die TX hat dann nichts geaendert.
backup_cmd_restore_status() {
  [ "${1:-}" = --json ] || die "Usage: lifeagents backup restore-status --json"
  local st okt flt rs nm cr fg state=idle v
  for v in st:LAST_RESTORE_START okt:LAST_RESTORE_OK flt:LAST_RESTORE_FAIL rs:LAST_RESTORE_REASON nm:LAST_RESTORE_NAME \
           cr:LAST_RESTORE_CREATED fg:LAST_RESTORE_FOREIGN; do
    printf -v "${v%%:*}" '%s' "$(read_env_value "$BACKUP_STATE_FILE" "${v#*:}" 2>/dev/null || true)"
  done
  case "$st" in ''|*[!0-9]*) st=0 ;; esac; case "$okt" in ''|*[!0-9]*) okt=0 ;; esac; case "$flt" in ''|*[!0-9]*) flt=0 ;; esac
  if [ "$st" -gt 0 ]; then
    if [ "$okt" -ge "$st" ]; then state=ok
    elif [ "$flt" -ge "$st" ]; then state=fail
    elif _bkp_restore_running; then state=running
    else
      state=unfinished
      # Hart abgebrochen (kill, Absturz): der EXIT-Trap des Laufs lief nicht, das entschluesselte Bundle laege noch im
      # tmpfs. Nur genau den gemerkten eigenen Ordner entfernen.
      local stale; stale="$(read_env_value "$BACKUP_STATE_FILE" LAST_RESTORE_TMP 2>/dev/null || true)"
      if [[ "$stale" =~ ^(/dev/shm|/tmp)/lifeagents-bkp\.[A-Za-z0-9]{6}$ ]] && [ -d "$stale" ]; then rm -rf -- "$stale"; fi
    fi
  fi
  jq -cn --arg state "$state" --arg code "$rs" --arg name "$nm" --arg created "$cr" --arg foreign "$fg" --argjson started "$st" \
    '{ok: true, state: $state, code: (if $state == "fail" then $code else null end), name: (if $name == "" then null else $name end),
      created: (if $created == "" then null else $created end), foreign: ($foreign == "1"), started: $started}'
}

# ============================================================
# restore
# ============================================================
# backup_cmd_restore [<datei>|<name>] [--from-host] [--key-stdin] [--in-stdin] [--yes] [--plan] [--detach] [--json]
#   Terminal: Auswahl, Wipe-Uebersicht, „ja“, dann EINE TX. Start-App (Plan restore-ohne-terminal):
#   --plan --json  Probelauf: oeffnen, pruefen, nichts schreiben (auch kein Paket, kein backup.state) -> ein JSON-Objekt.
#   --detach --json  (mit --yes) pruefen wie der Probelauf, dann im Hintergrund: Pakete einrichten, Vorab-Sicherung, TX;
#                  Ergebnis in backup.state (backup restore-status). Der Aufrufer bekommt sofort {ok:true, started}.
#   --in-stdin     die Sicherung kommt ueber stdin (Rahmen _bkp_read_in_stdin, mit Blatt-Block) statt aus einem Ordner.
backup_cmd_restore() {
  require_cmd jq; _bkp_require_pg pg_restore; require_cmd gpg
  _bkp_resolve_db
  # --from-host (Docker-Verbund): <datei> liegt in einem Ordner AUF DEM RECHNER — als voller Pfad oder als Name im gemerkten
  # Ordner (BACKUP_HOST_DIR). Im Verbund ist das ohne Pfad der Normalfall (die Auswahl listet den gemerkten Ordner).
  # --key-stdin: Schluessel vom Notfallblatt aus stdin (Text oder die ganze Notfallblatt-Datei), nur gelesen, wenn kein
  # gespeicherter Schluessel die Datei oeffnet. Nie als Argument (Prozessliste).
  local enc="" force=0 a from_host=0 key_stdin=0 in_stdin=0 plan=0 detach=0
  for a in "$@"; do
    case "$a" in
      --yes|-y) force=1 ;;
      --from-host) from_host=1 ;;
      --key-stdin) key_stdin=1 ;;
      --in-stdin) in_stdin=1; key_stdin=1 ;;
      --plan) plan=1 ;;
      --detach) detach=1 ;;
      --json) _BKP_JSON=1 ;;
      --*)      die "Unbekannte Option: $a" ;;
      *)        enc="$a" ;;
    esac
  done
  if [ "$detach" = 1 ] && { [ "$force" != 1 ] || [ "$_BKP_JSON" != 1 ] || [ "$plan" = 1 ]; }; then
    die "--detach braucht --yes und --json (Start-App) und schliesst --plan aus."
  fi
  # Missing-Arg-Picker (E3): *.nla.enc aus cwd + /root — realpath-dedupe (als root ist cwd oft
  # /root selbst, sonst Dubletten), dann absteigend nach BASENAME sortiert (der traegt den
  # Timestamp -> neueste zuerst; eine Voll-Pfad-Sortierung liesse das Verzeichnis-Praefix
  # dominieren, Cold-Eyes A1). Danach laufen Wipe-Uebersicht + 'ja'-Confirm unveraendert (E8).
  # Kein Treffer/Abbruch -> unveraenderte Usage.
  if [ "$in_stdin" = 0 ] && rt_is_compose && { [ -z "$enc" ] || [ ! -r "$enc" ]; }; then from_host=1; fi
  if [ -z "$enc" ] && [ "$in_stdin" = 0 ] && [ "$_BKP_JSON" = 0 ] && [ "$from_host" -eq 1 ] && ui_interactive; then
    ensure_gum
    local _hd _hpick
    _hd="$(_bkp_host_dir)"
    [ -n "$_hd" ] || die "Kein Sicherungs-Ordner auf dem Rechner gewählt — Datei mit vollem Pfad angeben: lifeagents backup restore --from-host <ordner>/<datei>"
    _hpick="$(rt_host_ls "$(_bkp_hd "$_hd")" | _bkp_pick_lines | ui_choose 'Backup wiederherstellen (Wipe-Uebersicht + Bestaetigung folgen):' 0 || true)"
    [ -n "$_hpick" ] && enc="$_hpick"
  elif [ -z "$enc" ] && [ "$in_stdin" = 0 ] && [ "$_BKP_JSON" = 0 ] && ui_interactive; then
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
  [ -n "$enc" ] || _bkp_rdie unreadable "Usage: lifeagents backup restore <datei.nla.enc> [--from-host] [--key-stdin] [--yes]"
  local host_src=""
  if [ "$in_stdin" = 1 ]; then
    :
  elif [ "$from_host" -eq 1 ]; then
    case "$enc" in
      /*|[A-Za-z]:\\*|[A-Za-z]:/*)
        _bkp_host_dir_valid "$enc" || _bkp_rdie unreadable "Pfad '${enc}' lässt sich nicht an Docker geben (Komma, Anführungszeichen oder Zeilenumbruch)."
        host_src="$enc" ;;
      */*|*\\*) _bkp_rdie unreadable "Datei als Name im gemerkten Ordner oder mit vollem Pfad angeben: $enc" ;;
      *) host_src="$(_bkp_host_dir)"; [ -n "$host_src" ] || _bkp_rdie nofolder "Kein Sicherungs-Ordner auf dem Rechner gewählt — Datei mit vollem Pfad angeben."; host_src="$(_bkp_join "$host_src" "$enc")" ;;
    esac
  else
    [ -r "$enc" ] || _bkp_rdie unreadable "Backup-Datei nicht lesbar: $enc"
  fi

  local src_name; src_name="${host_src:-$enc}"; src_name="${src_name##*/}"; src_name="${src_name##*\\}"

  local tmp; tmp="$(_bkp_tmpdir)" || _bkp_rdie internal "Konnte Arbeitsverzeichnis nicht anlegen."
  # Pfad JETZT in den Trap-String expandieren (s. export): $tmp ist local -> bei der global feuernden
  # EXIT-Trap waere es unter `set -u` "unbound variable".
  # shellcheck disable=SC2064  # bewusst JETZT expandieren: $tmp ist local -> bei der global feuernden EXIT-Trap unter `set -u` unbound
  trap "rm -rf -- '$tmp'" EXIT

  # Sperren VOR dem Lesen: der Probelauf schreibt nichts und nimmt keine; alles andere wartet bis 30 s auf die Update-Sperre
  # (der Minuten-Takt haelt sie kurz) und verlangt, dass kein Hintergrund-Lauf mehr laeuft.
  if [ "$plan" = 0 ]; then
    _bkp_restore_running && _bkp_rdie busy "Es läuft schon eine Wiederherstellung."
    update_lock_acquire 30 || _bkp_rdie busy "Gerade läuft ein Update oder eine Sicherung — gleich noch einmal versuchen."
  fi

  # --- (1) Holen + Entschluesseln + Header lesen (VOR jedem Wipe) ---
  if [ "$in_stdin" = 1 ]; then
    _bkp_read_in_stdin "$tmp/in.nla.enc"
    enc="$tmp/in.nla.enc"
  elif [ -n "$host_src" ]; then
    # Rechner-Ordner: das Chiffrat zuerst in den tmpfs holen (nur lesend gemountet, genau dieser eine Ordner).
    local hs; hs="$(_bkp_hd "$host_src")"
    rt_host_get "$(dirname "$hs")" "$(basename "$hs")" > "$tmp/in.nla.enc" && [ -s "$tmp/in.nla.enc" ] \
      || _bkp_rdie unreadable "Sicherung '${host_src}' auf dem Rechner nicht lesbar. Es wurde NICHTS geaendert."
    enc="$tmp/in.nla.enc"
  fi
  # Erst alle gespeicherten Schluessel (aktiver zuerst); oeffnet keiner die Datei, kommt der Schluessel vom Notfallblatt.
  # Ein gespeicherter Schluessel mit der ID aus dem Dateinamen, der trotzdem scheitert = Datei beschaedigt (nicht fragen).
  local brought='' others='' file_kid; file_kid="$(_bkp_file_key_id "$src_name")"
  if ! gpg_sym_decrypt_any "$enc" "$tmp/bundle.tar.gz"; then
    local known; known=$'\n'"$(_bkp_key_ids)"$'\n'
    if [ -n "$file_kid" ] && [[ "$known" == *$'\n'"$file_kid"$'\n'* ]]; then
      _bkp_rdie corrupt_stored "$(backup_text msg.corrupt_stored id "$file_kid") (${src_name}) $(backup_text msg.unchanged)" --arg id "$file_kid"
    fi
    _bkp_brought_key "$enc" "$tmp/bundle.tar.gz" "$file_kid" "$key_stdin"
    brought="$_BKP_BROUGHT"; others="$_BKP_OTHERS"; _BKP_BROUGHT=''; _BKP_OTHERS=''
  fi
  _BKP_SHEET=''
  tar -xzf "$tmp/bundle.tar.gz" -C "$tmp" 2>/dev/null || _bkp_rdie corrupt "Tarball beschaedigt (kein gueltiges Bundle). Nichts geaendert."
  [ -r "$tmp/manifest.json" ] && [ -r "$tmp/data.dump" ] || _bkp_rdie bundle_incomplete "Bundle unvollstaendig (manifest.json/data.dump fehlt). Nichts geaendert."

  local fmt; fmt="$(jq -r '.bundle_format // empty' "$tmp/manifest.json" 2>/dev/null)"
  [ "$fmt" = "2" ] || _bkp_rdie format "Nicht unterstuetztes Backup-Format (bundle_format='${fmt:-?}', erwartet 2). Alt-/.enc-Bundles der frueheren In-DB-Engine sind inkompatibel. Nichts geaendert."

  # --- (2) Pre-Flight je Bundle-Paket gegen Registry bzw. Paket-Manifest — prueft nur, aendert nichts. Ein fehlendes Paket
  #     wird spaeter eingerichtet (--no-seed, der Restore bringt die Daten), ein ausgeschaltetes eingeschaltet; beides erst
  #     nach der Bestaetigung, vor der TX. ---
  local rel_hint=''
  [[ "$src_name" =~ -(v[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.-]*)\.nla\.enc$ ]] && rel_hint="${BASH_REMATCH[1]}"
  local pkg ver inst_status inst_ver to_install='' to_activate='' pkgs_json='[]' pstate
  while IFS=$'\t' read -r pkg ver; do
    [ -n "$pkg" ] || continue
    printf '%s' "$pkg" | grep -qE '^[a-z][a-z0-9_]*$' || _bkp_rdie format "Ungueltiger Paketname im Bundle: $pkg"
    inst_status="$(_bkp_psql_scalar "SELECT status FROM core.package_registry WHERE package = '${pkg}'")"
    if [ -z "$inst_status" ]; then
      [ -r "$(_pkg_dir)/$pkg/manifest.json" ] || _bkp_rdie package_unknown "Die Sicherung enthält das Paket '$pkg', das diese Version nicht kennt. Es wurde NICHTS geaendert." --arg pkg "$pkg"
      inst_ver="$(jq -r '.version // empty' "$(_pkg_dir)/$pkg/manifest.json" 2>/dev/null)"
      # Terminal: Pakete mit Zugangsdaten fragt pkg_install_one am Terminal; ohne Terminal (App) entstuende es halb eingerichtet.
      if { [ "$_BKP_JSON" = 1 ] || ! tty_usable; } && _bkp_pkg_needs_setup "$pkg"; then
        _bkp_rdie needs_setup "Paket '$pkg' braucht Zugangsdaten — erst einrichten, dann erneut wiederherstellen. Es wurde NICHTS geaendert." --arg pkg "$pkg"
      fi
      pstate=install; to_install="${to_install}${pkg} "
    elif [ "$inst_status" = active ]; then
      inst_ver="$(_bkp_psql_scalar "SELECT version FROM core.package_registry WHERE package = '${pkg}'")"; pstate=ok
    else
      inst_ver="$(_bkp_psql_scalar "SELECT version FROM core.package_registry WHERE package = '${pkg}'")"; pstate=activate
      to_activate="${to_activate}${pkg} "
    fi
    if [ -n "$ver" ] && [ "$ver" != "$inst_ver" ]; then
      # Versions-Gate (fail-closed VOR jedem Wipe): pg_restore -a passt Daten NICHT an ein per Migration
      # veraendertes Ziel-Schema an -> bewusst KEIN Cross-Version-Restore (Branchen-Standard: pg_restore/
      # Borg/restic verweigern Cross-Version ebenso). Echtes Forward-Migrate braeuchte eine Migrationskette
      # zwischen >=2 Versionen (vertagt, Trigger: ein Restore scheitert real an der Versionssperre).
      # Aelteres Bundle: ein Update hilft nicht (es geht nur vorwaerts) -> die Version aus dem Dateinamen nennen.
      if [ "$(printf '%s\n%s\n' "$ver" "$inst_ver" | sort -V | head -n1)" = "$ver" ]; then
        _bkp_rdie version_older "Versions-Konflikt fuer '$pkg': die Sicherung ist älter (Bundle=$ver, installiert=$inst_ver). Ein Update hilft hier nicht — die Sicherung lässt sich nur in genau ihre Version zurückspielen: Life Agents ${rel_hint:-in der Version der Sicherung} neu installieren, dann erneut restoren (Anleitung: ${BACKUP_GUIDE_URL}). Es wurde NICHTS geaendert." \
          --arg pkg "$pkg" --arg release "$rel_hint"
      fi
      _bkp_rdie version_newer "Versions-Konflikt fuer '$pkg': die Sicherung ist neuer (Bundle=$ver, installiert=$inst_ver) — erst 'lifeagents update'${rel_hint:+ (mindestens ${rel_hint})}, dann erneut restoren. Versions-uebergreifender Restore wird (wie pg_restore/Borg/restic) bewusst NICHT unterstuetzt. Es wurde NICHTS geaendert." \
        --arg pkg "$pkg" --arg release "$rel_hint"
    fi
    pkgs_json="$(jq -c --arg n "$pkg" --arg v "$ver" --arg s "$pstate" '. + [{name: $n, version: $v, state: $s}]' <<<"$pkgs_json")"
  done < <(jq -r '.packages[]? | [.name, .version] | @tsv' "$tmp/manifest.json")

  # --- (3) Wipe-Menge (heute aktive Pakete) + eigene Daten. Nach dem Einrichten fehlender Pakete wird die Menge in
  #     _bkp_rs_apply neu bestimmt (deren Tabellen kommen dazu). ---
  local bulk has_data=0; bulk="$(_bkp_bulk_tables)"
  [ -n "$bulk" ] || [ -n "$to_install$to_activate" ] || _bkp_rdie no_tables "Keine Ziel-Tabellen (aktive Pakete + backup-Block) — Abbruch vor Wipe."
  [ -n "$bulk" ] && _bkp_has_data "$bulk" && has_data=1
  local created; created="$(jq -r '.created_at // empty' "$tmp/manifest.json" 2>/dev/null)"
  local adopt_id=''; [ -n "$brought" ] && adopt_id="$(printf '%s' "$brought" | backup_key_id)"

  if [ "$plan" = 1 ]; then
    jq -cn --arg created "$created" --arg release "$rel_hint" --argjson packages "$pkgs_json" --arg adopt "$adopt_id" \
      --argjson has_data "$has_data" --arg name "$src_name" \
      '{ok: true, name: $name, created: (if $created == "" then null else $created end),
        release: (if $release == "" then null else $release end), packages: $packages,
        has_data: ($has_data == 1), safety_backup: ($has_data == 1),
        adopt_key_id: (if $adopt == "" then null else $adopt end)}'
    return 0
  fi

  # Ohne Ordner keine Vorab-Sicherung -> mit eigenen Daten keine Wiederherstellung (die Daten waeren ohne Rueckweg weg).
  if [ "$has_data" = 1 ] && rt_is_compose && [ -z "$(_bkp_host_dir)" ]; then
    _bkp_rdie nofolder "Es sind schon eigene Daten da, aber kein Sicherungs-Ordner gewählt — erst einen wählen, dann wird vor dem Ersetzen gesichert."
  fi

  local pkg_summary filt_disp filt_n qd cd
  pkg_summary="$(jq -r '[.packages[]? | "\(.name)@\(.version)"] | join(", ")' "$tmp/manifest.json" 2>/dev/null || true)"
  filt_disp=""; filt_n=0
  while IFS=$'\t' read -r qd cd; do
    [ -n "$qd" ] || continue
    [ -n "$filt_disp" ] && filt_disp+="; "
    filt_disp+="$qd ($cd)"; filt_n=$((filt_n + 1))
  done < <(_bkp_filtered)

  # Wipe-Uebersicht IMMER ausweisen (via warn/log -> STDERR; auch unter --yes sichtbar, Z.B. im Cron-Log).
  warn "RESTORE ueberschreibt ALLE aktuellen Nutzerdaten (Finanzen, Profil, Trigger, Plaene) mit dem Bundle-Inhalt. Betroffen:"
  log "  Pakete (Bundle): ${pkg_summary:-?}"
  [ -z "$to_install" ] || log "  Wird vorher eingerichtet (--no-seed): ${to_install% }"
  [ -z "$to_activate" ] || log "  Wird vorher eingeschaltet: ${to_activate% }"
  log "  Voll-Wipe (TRUNCATE), $(printf '%s' "$bulk" | grep -c .) Tabelle(n): $(printf '%s' "$bulk" | tr '\n' ' ')"
  log "  Zeilen-gefiltert, ${filt_n} Tabelle(n): ${filt_disp:-(keine)}"
  [ "$has_data" = 1 ] && log "  Vorher wird eine Sicherung der jetzigen Daten geschrieben."
  if [ -n "$brought" ]; then
    log "  $(backup_text msg.adopt id "$adopt_id")"
  fi

  # --- (3b) TTY-Bestaetigung (destruktiv) ---
  if [ "$force" -ne 1 ]; then
    tty_usable || die "Kein TTY und kein --yes -> Abbruch (Restore ueberschreibt ALLE Nutzerdaten)."
    printf 'Wirklich wiederherstellen? [ja/NEIN]: ' > /dev/tty
    local ans=""; read -r ans < /dev/tty
    [ "$ans" = "ja" ] || die "Abgebrochen."
  fi

  if [ "$detach" = 1 ]; then
    # Hintergrund-Lauf als bash-Unterschale OHNE exec: der Schluessel bleibt in ihrem Speicher (kein neues Programm, also
    # nichts in argv/Umgebung). Sie erbt fd 9 (Update-Sperre) und nimmt fd 8 (Restore-Sperre); ihr eigener EXIT-Trap raeumt
    # den tmpfs. Der Aufrufer gibt den Trap ab (sonst loeschte er das Bundle unter dem Kind) und endet sofort; docker exec
    # kehrt zurueck, weil das Kind stdout/stderr gleich auf das Protokoll umlegt.
    # Protokoll ohne Schluessel (nur log/warn-Saetze, Tabellen- und Paketnamen), bleibt fuer die Diagnose liegen.
    local log_f; log_f="${LIFEAGENTS_LOG_DIR:-/var/log/lifeagents}/restore.log"
    { mkdir -p "${log_f%/*}" && ( umask 077; : > "$log_f" ); } 2>/dev/null || _bkp_rdie internal "Konnte das Protokoll nicht anlegen."
    { exec 8>>"$BACKUP_RESTORE_LOCK" && flock -n 8; } || _bkp_rdie busy "Es läuft schon eine Wiederherstellung."
    _bkp_state_set LAST_RESTORE_START "$(date +%s)"; _bkp_state_set LAST_RESTORE_NAME "$src_name"
    _bkp_state_set LAST_RESTORE_CREATED "$created"; _bkp_state_set LAST_RESTORE_FOREIGN "$([ -n "$brought" ] && printf 1 || printf 0)"
    _bkp_state_set LAST_RESTORE_TMP "$tmp"
    (
      exec </dev/null >"$log_f" 2>&1
      # shellcheck disable=SC2064  # bewusst JETZT expandieren (local $tmp)
      trap "rm -rf -- '$tmp'" EXIT
      _BKP_CHILD=1; _BKP_JSON=0
      _bkp_state_set LAST_RESTORE_PID "$BASHPID"
      _bkp_rs_apply "$tmp" "$brought" "$others" "$has_data" "$to_install" "$to_activate"
      _bkp_state_set LAST_RESTORE_OK "$(date +%s)"
    ) &
    trap - EXIT
    jq -cn --argjson started "$(date +%s)" '{ok: true, started: $started}'
    return 0
  fi
  _BKP_JSON=0
  _bkp_rs_apply "$tmp" "$brought" "$others" "$has_data" "$to_install" "$to_activate"
}

# _bkp_rs_apply <tmp> <blatt-schluessel> <weitere> <eigene-daten:0|1> <pakete-einrichten> <pakete-einschalten> — der
#   aendernde Teil nach der Bestaetigung (Terminal und Hintergrund-Lauf): Pakete einrichten/einschalten, Vorab-Sicherung der
#   jetzigen Daten, dann EINE TX. Jeder Abbruch ueber _bkp_rdie; ein vorher eingerichtetes Paket bleibt.
_bkp_rs_apply() {
  local tmp="$1" brought="$2" others="$3" has_data="$4" to_install="$5" to_activate="$6" pkg
  for pkg in $to_install; do
    log "Auto-Install '$pkg' --no-seed (Restore bringt die Daten) ..."
    # Subshell: ein internes `die` beendet nur den Install, dann sauberer Abbruch HIER (vor dem Wipe).
    ( pkg_install_one "$pkg" --no-seed ) || _bkp_rdie internal "Auto-Install '$pkg' fehlgeschlagen -> Abbruch VOR jedem Wipe (alte Welt intakt)."
  done
  for pkg in $to_activate; do
    ( _pkg_set_status "$pkg" active ) || _bkp_rdie internal "Paket '$pkg' ließ sich nicht einschalten -> Abbruch vor dem Wipe."
  done
  # M2: Pre-Flight-Recheck nach Install/Einschalten — jedes Bundle-Paket muss jetzt aktiv sein: _bkp_bulk_tables (Wipe/
  # Restore-Menge) zaehlt nur aktive Pakete, ein inaktives wuerde nicht truncatet (UNIQUE/PK-Konflikte, Rollback).
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    [ "$(_bkp_psql_scalar "SELECT status FROM core.package_registry WHERE package = '${pkg}'")" = active ] \
      || _bkp_rdie internal "Paket '$pkg' ist nach dem Einrichten nicht aktiv -> Abbruch vor dem Wipe."
  done < <(jq -r '.packages[]?.name' "$tmp/manifest.json")
  local bulk; bulk="$(_bkp_bulk_tables)"
  [ -n "$bulk" ] || _bkp_rdie no_tables "Keine Ziel-Tabellen (aktive Pakete + backup-Block) — Abbruch vor Wipe."

  # Vorab-Sicherung: der einzige Rueckweg, wenn eigene Daten ersetzt werden. Eigene Teilschale (export setzt seinen Trap);
  # die Update-Sperre ist geerbt (LIFEAGENTS_UPDATE_LOCK_HELD).
  if [ "$has_data" = 1 ]; then
    log "Sichere die jetzigen Daten vor dem Ersetzen ..."
    if rt_is_compose; then
      ( backup_cmd_export --to-host ) || _bkp_rdie safety "Die Sicherung der jetzigen Daten ist fehlgeschlagen — nichts ersetzt."
    else
      mkdir -p /var/backups/lifeagents && chmod 0700 /var/backups/lifeagents 2>/dev/null || true
      ( cd /var/backups/lifeagents && backup_cmd_export ) || _bkp_rdie safety "Die Sicherung der jetzigen Daten ist fehlgeschlagen — nichts ersetzt."
    fi
  fi

  # --- (4) ATOMARER Restore: TRUNCATE + pg_restore-SQL + fn + Count-Verify in EINER psql -1-TX (Opus B1) ---
  local restore_sql="$tmp/restore.sql"
  # lock_timeout: haelt n8n gerade eine Zeilen-/Tabellensperre (ein Mitglied schreibt), wartet TRUNCATE nicht endlos.
  printf "SET LOCAL lock_timeout = '30s';\n" > "$restore_sql"
  # (a) TRUNCATE der bulk-Tabellen (FK-/Trigger-frei dank --disable-triggers im pg_restore; CASCADE als Sicherung).
  #     filtered_tables (core_contexts/monitor_triggers) NICHT truncaten -> die fn macht den zeilen-gefilterten Wipe.
  local trunc="" t n
  while IFS= read -r t; do
    [ -n "$t" ] || continue; _bkp_qual_ok "$t" || _bkp_rdie internal "Ungueltiger Tabellenname im bulk-Set: $t"
    [ -n "$trunc" ] && trunc+=", "
    trunc+="$t"
  done <<< "$bulk"
  printf 'TRUNCATE %s CASCADE;\n' "$trunc" >> "$restore_sql"
  # (b) pg_restore -> SQL-TEXT (KEIN eigener DB-Connect; laeuft so in unserer einen TX).
  # pg_restore (postgres via runuser) liest die Archiv-Datei NICHT direkt (root-eigenes 0700-tmpfs) -> die
  # root-Shell oeffnet sie per stdin-Redirect; pg_restore -f - schreibt das SQL auf stdout (in unsere EINE TX).
  if ! pg_su_stdin pg_restore -a --disable-triggers -f - < "$tmp/data.dump" >> "$restore_sql"; then
    _bkp_rdie corrupt "pg_restore (SQL-Generierung) fehlgeschlagen. Nichts geaendert."
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
  # psql -1 nur fuer -c/-f zusagt. Ein mitgebrachter Schluessel steht vorn im Strom (\set), nie in restore.sql. stderr geht
  # in den tmpfs, damit ein Sperr-Timeout als busy erkennbar ist (Fehlertext enthaelt nie den Schluessel: \set echot nicht).
  if { if [ -n "$brought" ]; then
         local o j=0
         psql_setvar bk_new "$brought"
         while IFS= read -r o; do [ -n "$o" ] || continue; psql_setvar "bk_o$j" "$o"; j=$((j + 1)); done <<<"$others"
         _bkp_adopt_sql "$j"
       fi
       cat "$restore_sql"; } \
       | pg_su_psql -v ON_ERROR_STOP=1 -1 -X -q -d "$N8N_DB_NAME" -f - 2> "$tmp/psql.err"; then
    ok "Restore abgeschlossen (atomar, Count-Verify gruen): $(printf '%s' "$bulk" | grep -c .) bulk-Tabelle(n) + gefilterte Zeilen wiederhergestellt."
  else
    cat "$tmp/psql.err" >&2 2>/dev/null || true
    grep -q 'lock timeout' "$tmp/psql.err" 2>/dev/null \
      && _bkp_rdie busy "Restore wartete zu lange auf eine Sperre — Transaktion zurueckgerollt, nichts geaendert."
    _bkp_rdie internal "Restore fehlgeschlagen — Transaktion zurueckgerollt, die alte Welt ist intakt."
  fi
}

# ============================================================
# key — Notfallblatt
# ============================================================
# backup_cmd_key [--file <pfad>|-] — Notfallblatt ausgeben: ohne --file nur aufs Terminal (/dev/tty, nie in eine Pipe oder
#   ein Log); --file <pfad> legt eine neue 0600-Datei an (vorhandene wird nie ueberschrieben); --file - schreibt auf stdout
#   (Start-App, MasterCmd::BackupKit: `lifeagents backup key --file -` im master, Ausgabe nur in deren Datei).
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
    restore-status) backup_cmd_restore_status "$@" ;;
    list)    backup_cmd_list "$@" ;;
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
                           Für die Start-App: --plan --json (Probelauf, ändert nichts), --yes --detach --json (im
                           Hintergrund; Stand: restore-status --json), --in-stdin (Sicherung + Blatt über stdin).
  list --json              Sicherungen im Rechner-Ordner (für die Start-App).
  restore-status --json    Stand der letzten Wiederherstellung im Hintergrund (für die Start-App).
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
