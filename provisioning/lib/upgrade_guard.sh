# upgrade_guard.sh — Schutz fuer Versionswechsel auf Bestands-Instanzen (n8n, Node.js, PostgreSQL-Minor).
# Sourced by provision.sh (kein Shebang, kein `set -e` — erbt den Error-Mode des Top-Skripts).
#
# WARUM: n8n migriert beim ersten Start einer neuen Version seine Tabellen (nicht automatisch umkehrbar, nur
# `n8n db:revert` je Migration), und n8n + alle lifeagents-Schemas liegen in EINER Datenbank (N8N_DB_NAME).
# Darum „erst sichern, dann aendern" (Muster GitLab Omnibus: Auto-Backup vor jedem Paket-Upgrade):
#   upgrade_detect   — gibt es etwas zu schuetzen? (Versionswechsel n8n, Node oder PG-Minor auf einer Instanz mit DB,
#                      oder ein unvollendeter frueherer Tausch = Merkzettel vorhanden)
#   upgrade_prepare  — VOR install_postgres: Merkzettel -> laufende Ausfuehrungen abwarten -> n8n stoppen ->
#                      ganze DB per pg_dump -Fc verschluesselt sichern (common.sh gpg_sym_encrypt, core.backup_key).
#                      Danach tauschen install_postgres/install_n8n bei STEHENDEM n8n (PG-Neustart gefahrlos, kein
#                      Absturz-Neustart auf halb getauschte Dateien); install_n8n_unit startet + wartet hart auf
#                      /healthz/readiness (UPGRADE_ACTIVE).
#   upgrade_finish   — sobald der Tausch steht (n8n bereit + Gateway neu gestartet): Merkzettel weg, Sicherungen bis
#                      auf die letzten UPGRADE_KEEP raeumen. Das Workflow-Deploy danach ist ein normaler, wiederholbarer
#                      Schritt — ein dort gescheiterter Lauf soll beim naechsten Update nicht erneut stoppen/neu starten.
# Der MERKZETTEL (upgrade.pending) haelt den Zustand ueber Abbrueche: existiert er, setzt jeder Wiederholungslauf
# die Sicherung voraus (fehlt sie, wird sie gezogen, solange noch etwas zu tauschen ist) und startet n8n + Gateway neu.
# Rueckweg bewusst MANUELL (upgrade_rollback_hint): ein automatisches Zurueckspielen auf eine halb migrierte DB waere
# riskanter als ein Mensch im Loop.
# Ein normales Update ohne Versionswechsel beruehrt nichts davon (kein Stopp, keine Sicherung).
# Reads globals: N8N_VERSION, NODE_MAJOR, PG_VERSION, N8N_DB_NAME, N8N_PORT, N8N_OWNER_ENV_FILE.

UPGRADE_STATE_DIR="${UPGRADE_STATE_DIR:-/var/lib/lifeagents}"
UPGRADE_MARKER="${UPGRADE_STATE_DIR}/upgrade.pending"
UPGRADE_BACKUP_DIR="${UPGRADE_BACKUP_DIR:-/var/backups/lifeagents}"
UPGRADE_KEEP=2
UPGRADE_DRAIN_SECS="${UPGRADE_DRAIN_SECS:-120}"
UPGRADE_ACTIVE=0      # 1 = dieser Lauf tauscht Versionen (oder setzt einen abgebrochenen Tausch fort)
UPGRADE_CHANGES=''    # von upgrade_detect gefuellt: eine Zeile je anstehendem Tausch

# _upg_pg_versions -> "<installiert> <kandidat>" von postgresql-<PG_VERSION> (leer, wenn nicht installiert).
# Setzt ein vorheriges apt-get update voraus (install_base_packages). Ein apt-Hold aendert den Kandidaten nicht.
_upg_pg_versions() {
  dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1 || return 0
  LC_ALL=C apt-cache policy "postgresql-${PG_VERSION}" 2>/dev/null \
    | awk '/Installed:/ {i=$2} /Candidate:/ {c=$2} END {print i, c}'
}

# _upg_n8n_version -> installierte n8n-Version (leer, wenn keins). Gecacht: der n8n-CLI-Start dauert Sekunden, und
# preflight, upgrade_detect und upgrade_prepare fragen VOR dem Tausch mehrfach (danach liest ensure_n8n_package frisch).
_UPG_N8N_VER=''
_UPG_N8N_VER_SET=0
_upg_n8n_version() {
  if [ "$_UPG_N8N_VER_SET" -eq 0 ]; then
    if need_cmd n8n; then _UPG_N8N_VER="$(n8n --version 2>/dev/null || true)"; fi
    _UPG_N8N_VER_SET=1
  fi
  printf '%s' "$_UPG_N8N_VER"
}

# _upg_changes -> eine Zeile je anstehendem Tausch (leer = nichts zu tun).
_upg_changes() {
  local cur inst cand
  if need_cmd n8n; then
    cur="$(_upg_n8n_version)"
    if [ -n "$cur" ] && [ "$cur" != "$N8N_VERSION" ]; then printf 'n8n %s -> %s\n' "$cur" "$N8N_VERSION"; fi
  fi
  if need_cmd node; then
    cur="$(node_major)"
    if [ -n "$cur" ] && [ "$cur" != "$NODE_MAJOR" ]; then printf 'Node.js %s -> %s\n' "$cur" "$NODE_MAJOR"; fi
  fi
  read -r inst cand <<<"$(_upg_pg_versions)"
  if [ -n "${inst:-}" ] && [ -n "${cand:-}" ] && [ "$cand" != "(none)" ] \
     && dpkg --compare-versions "$cand" gt "$inst"; then
    printf 'PostgreSQL %s -> %s\n' "$inst" "$cand"
  fi
  # Release-Wechsel (Update im Chat; GitLab Omnibus sichert vor JEDEM Paket-Upgrade): ein neues Release bringt Schema-
  # Migrationen mit, die sich nicht automatisch umkehren -> auch ohne n8n-/Node-/PG-Wechsel erst sichern. So hat jeder
  # Rueckweg (lifeagents rollback) eine Sicherung von direkt davor. Erneut anwenden (gleiches Tag) sichert nicht.
  cur="$(_upg_installed_release)"
  if [ -n "$cur" ] && [ -n "${RELEASE_TAG:-}" ] && [ "$RELEASE_TAG" != dev ] && [ "$cur" != "$RELEASE_TAG" ]; then
    printf 'Release %s -> %s\n' "$cur" "$RELEASE_TAG"
  fi
  return 0
}

# _upg_installed_release -> das installierte stabile Release-Tag (VERSION), leer bei dev/keinem.
_upg_installed_release() {
  local v
  v="$(cat "$(lifeagents_version_marker)" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s' "$v"
  return 0
}

# _upg_db_exists — 0, wenn PG laeuft und die App-DB existiert (sonst: Erstinstallation, nichts zu schuetzen).
_upg_db_exists() {
  [ "$(runuser -u postgres -- psql -X -tAc "SELECT 1 FROM pg_database WHERE datname='${N8N_DB_NAME}'" 2>/dev/null)" = 1 ]
}

# _upg_load_backup_key — Sicherungsschluessel nach _UPG_KEY, seine Tabelle nach _UPG_KEY_TABLE (direkt rufen, NICHT in
# $(…) — die Globals muessen im Aufrufer ankommen). rc 0 = gelesen (_UPG_KEY leer = es gibt noch keine Schluessel-Tabelle
# bzw. -Zeile -> die Erstinstallation kam nie bis zum Owner-Bootstrap, keine Nutzerdaten); rc 1 = nicht lesbar -> der
# Aufrufer bricht ab (nie still "ohne Sicherung" weiter). Vor core:V006 hiess die Tabelle core.secret (v0.1.0-Bestand;
# die Umbenennung laeuft erst in apply_schema, also NACH der Sicherung).
_UPG_KEY=''
_UPG_KEY_TABLE=''
_upg_load_backup_key() {
  local tables t
  _UPG_KEY=''; _UPG_KEY_TABLE=''
  tables="$(runuser -u postgres -- psql -v ON_ERROR_STOP=1 -X -tA -d "$N8N_DB_NAME" -c \
    "SELECT concat_ws(' ', CASE WHEN to_regclass('core.backup_key') IS NOT NULL THEN 'core.backup_key' END,
                           CASE WHEN to_regclass('core.secret') IS NOT NULL THEN 'core.secret' END)" 2>/dev/null)" || return 1
  # Erste Tabelle MIT Schluessel gewinnt (zwischen Init und V006 koennen beide existieren, der Wert steht in core.secret).
  for t in $tables; do
    _UPG_KEY="$(backup_key_read "$t" 2>/dev/null)" || return 1
    if [ -n "$_UPG_KEY" ]; then _UPG_KEY_TABLE="$t"; return 0; fi
  done
  return 0
}

# _upg_has_user_data — 0, wenn die Instanz echte Daten traegt (das core-Schema existiert = apply_schema lief, der
# Owner-Bootstrap legt den Schluessel im selben Lauf direkt danach an). Fehlt dann der Schluessel, ist das ein Defekt,
# keine "nie abgeschlossene Erstinstallation" -> nie still ohne Sicherung weiter.
_upg_has_user_data() {
  [ "$(runuser -u postgres -- psql -X -tA -d "$N8N_DB_NAME" -c "SELECT to_regnamespace('core') IS NOT NULL" 2>/dev/null)" = t ]
}

# _upg_new_backup_path -> Zieldatei einer neuen Sicherung (Versionsname: welches n8n die DB beschrieb).
_upg_new_backup_path() {
  printf '%s/pre-upgrade-n8n-%s-%s.dump.gpg' "$UPGRADE_BACKUP_DIR" "$(_upg_n8n_version || true)" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# _upg_drain — laufende Ausfuehrungen begrenzt abwarten (UPGRADE_DRAIN_SECS), damit ein Agenten-Lauf nicht mitten im
# Schritt abbricht. Wartende HITL-Bestaetigungen (status=waiting) ueberleben den Stopp ohnehin (in der DB persistiert).
# Ohne API-Key oder ohne laufendes n8n: nichts abzuwarten. Die "Bot denkt nach"-Schleife (core.sub_show_thinking)
# zaehlt nicht: sie laeuft rein kosmetisch Minuten lang (auch waehrend einer offenen Karte), ein Abbruch schadet nicht
# -> sonst reizte jede offene Karte die volle Wartezeit aus. Workflow-ID aus dem Dateinamen im Paket-Baum (_pkg_dir,
# stabile IDs).
_upg_drain() {
  local key n f skip='' left="$UPGRADE_DRAIN_SECS"
  key="$(read_env_value "$N8N_OWNER_ENV_FILE" N8N_API_KEY 2>/dev/null || true)"
  if [ -z "$key" ] || ! systemctl is-active --quiet n8n; then return 0; fi
  for f in "$(_pkg_dir)"/core/workflows/*-core.sub_show_thinking.json; do
    [ -e "$f" ] && skip="$(basename "$f" '-core.sub_show_thinking.json')"
  done
  while [ "$left" -gt 0 ]; do
    n="$(n8n_api_curl "$key" "http://127.0.0.1:${N8N_PORT}/api/v1/executions?status=running&limit=100" \
           -fsS -H 'accept: application/json' 2>/dev/null \
         | jq -r --arg skip "$skip" '[(.data // [])[] | select(.workflowId != $skip)] | length' 2>/dev/null || true)"
    case "$n" in ''|0) return 0 ;; esac
    log "Warte auf ${n} laufende Ausführung(en), bevor n8n für das Update anhält (noch höchstens ${left} s) ..."
    sleep 5; left=$((left - 5))
  done
  warn "Nach ${UPGRADE_DRAIN_SECS} s laufen noch Ausführungen — n8n hält trotzdem an (offene Bestätigungen bleiben erhalten)."
}

# _upg_snapshot <key> <ziel> — pg_dump -Fc der GANZEN App-DB, direkt in gpg gestreamt (kein Klartext auf der Platte).
# Schreibt erst <ziel>.part und benennt nur bei Erfolg um -> ein halbes Chiffrat gilt nie als Sicherung.
_upg_snapshot() {
  local key="$1" out="$2" part="${2}.part"
  mkdir -p "$UPGRADE_BACKUP_DIR"; chmod 0700 "$UPGRADE_BACKUP_DIR"
  log "Datenbank verschlüsselt sichern -> ${out} ..."
  rm -f "$part"
  if ( umask 077; cd /; runuser -u postgres -- pg_dump -Fc -d "$N8N_DB_NAME" | gpg_sym_encrypt "$key" "$part" ) \
     && [ -s "$part" ]; then
    mv -f "$part" "$out"; chmod 0600 "$out"
    ok "Sicherung geschrieben: ${out} ($(du -h "$out" | cut -f1))"
    return 0
  fi
  rm -f "$part"
  return 1
}

# _upg_stop_n8n — n8n anhalten (idempotent).
_upg_stop_n8n() {
  if systemctl is-active --quiet n8n; then
    log "n8n für das Update anhalten ..."
    systemctl stop n8n
  fi
}

# upgrade_detect — 0, wenn dieser Lauf geschuetzt tauschen muss (fuellt UPGRADE_CHANGES). Nach install_base_packages
# rufen (apt-Kandidaten aktuell), VOR install_postgres.
upgrade_detect() {
  [ -f "$UPGRADE_MARKER" ] && return 0
  UPGRADE_CHANGES="$(_upg_changes)"
  [ -n "$UPGRADE_CHANGES" ] || return 1
  dpkg -s "postgresql-${PG_VERSION}" >/dev/null 2>&1 || return 1
  _upg_db_exists || return 1
  return 0
}

# upgrade_prepare — Merkzettel, Abwarten, Stopp, Sicherung (siehe Kopf). Fehlgeschlagene Sicherung = Abbruch, bevor
# irgendetwas getauscht wurde; n8n laeuft dann in der alten Version weiter.
upgrade_prepare() {
  local from backup line
  # shellcheck disable=SC2034  # gelesen von install_n8n.sh + install_llm_gateway.sh (erzwungener Neustart)
  UPGRADE_ACTIVE=1
  # PostgreSQL sicher an (ein frueher Lauf kann mitten im PG-Tausch abgebrochen sein; install_postgres startet es sonst
  # erst NACH dieser Stelle) -> dann den Schluessel ZUERST: ist er nicht lesbar, bricht der Lauf ab, bevor etwas
  # (weiter) getauscht wird.
  systemctl start postgresql >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do runuser -u postgres -- pg_isready -q 2>/dev/null && break; sleep 1; done
  _upg_load_backup_key \
    || die "Sicherungsschlüssel nicht lesbar (Datenbank-Fehler) — Update angehalten, es wird nichts getauscht. Diagnose: lifeagents doctor"
  # Kein Schluessel, aber echte Daten -> Defekt, nicht still ohne Sicherung weiter (Notschalter fuer den bewussten Fall).
  if [ -z "$_UPG_KEY" ] && _upg_has_user_data && [ "${UPGRADE_ALLOW_NO_BACKUP:-0}" != 1 ]; then
    die "Kein Sicherungsschlüssel gefunden, die Datenbank enthält aber Daten — Update angehalten, es wird nichts getauscht. Bewusst ohne Sicherung fortfahren: UPGRADE_ALLOW_NO_BACKUP=1 lifeagents update"
  fi

  if [ -f "$UPGRADE_MARKER" ]; then
    backup="$(read_env_value "$UPGRADE_MARKER" BACKUP || true)"
    UPGRADE_CHANGES="$(_upg_changes)"
    warn "Ein früheres Update wurde nicht abgeschlossen — setze es fort (Sicherung: ${backup:-keine})."
    if [ -z "$UPGRADE_CHANGES" ]; then _upg_backup_recorded "$backup"; return 0; fi   # alles schon getauscht -> nur Neustart + Pruefung
    _upg_drain; _upg_stop_n8n
    # Damals ohne Schluessel, inzwischen mit -> jetzt doch sichern (der Merkzettel bekommt den Pfad nachgetragen).
    if [ -z "$backup" ] && [ -n "$_UPG_KEY" ]; then
      backup="$(_upg_new_backup_path)"
      env_upsert "$UPGRADE_MARKER" BACKUP "$backup"
      env_upsert "$UPGRADE_MARKER" KEY_TABLE "$_UPG_KEY_TABLE"
    fi
    if [ -n "$backup" ] && [ ! -s "$backup" ]; then
      [ -n "$_UPG_KEY" ] \
        || die "Sicherungsschlüssel fehlt, die Sicherung ${backup} aber auch — Update angehalten, n8n bleibt gestoppt. Diagnose: lifeagents doctor"
      _upg_snapshot "$_UPG_KEY" "$backup" \
        || die_because backup "Sicherung fehlgeschlagen — Update angehalten, n8n bleibt gestoppt. Platz prüfen (df -h ${UPGRADE_BACKUP_DIR}) und 'lifeagents update' erneut starten."
    fi
    _upg_backup_recorded "$backup"
    return 0
  fi

  log "Versionswechsel erkannt — erst sichern, dann tauschen:"
  while IFS= read -r line; do [ -n "$line" ] && log "  ${line}"; done <<<"$UPGRADE_CHANGES"
  from="$(_upg_n8n_version)"; from="${from:-unbekannt}"
  backup=''
  [ -n "$_UPG_KEY" ] && backup="$(_upg_new_backup_path)"
  mkdir -p "$UPGRADE_STATE_DIR"; chmod 0700 "$UPGRADE_STATE_DIR"
  # FROM_RELEASE = das noch installierte Release (install_cli schreibt VERSION erst am Ende dieses Laufs neu) ->
  # der Rueckweg kann genau dieses wieder installieren. KEY_TABLE: wo der Rueckweg den Schluessel findet.
  printf 'FROM_N8N=%s\nFROM_NODE=%s\nFROM_RELEASE=%s\nBACKUP=%s\nKEY_TABLE=%s\nSTARTED=%s\n' \
    "$from" "$(node_major)" "$(cat "$(lifeagents_version_marker)" 2>/dev/null || true)" "$backup" \
    "$_UPG_KEY_TABLE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | write_file "$UPGRADE_MARKER" 0600

  _upg_drain
  _upg_stop_n8n
  if [ -z "$_UPG_KEY" ]; then
    # Ohne Schluessel UND ohne core-Schema kam die Erstinstallation nie bis zu den Nutzerdaten (oder der Owner hat
    # UPGRADE_ALLOW_NO_BACKUP=1 gesetzt) -> ohne Sicherung weiter.
    warn "Kein Sicherungsschlüssel — Update ohne Sicherung (Erstinstallation nie abgeschlossen bzw. bewusst so gewählt)."
  elif _upg_snapshot "$_UPG_KEY" "$backup"; then
    _upg_backup_recorded "$backup"
  else
    rm -f "$UPGRADE_MARKER"
    systemctl start n8n || true
    die_because backup "Sicherung fehlgeschlagen — Update abgebrochen, es wurde nichts getauscht (n8n läuft weiter in Version ${from}). Platz prüfen: df -h ${UPGRADE_BACKUP_DIR}"
  fi
}

# _upg_backup_recorded <sicherung> — eine vorhandene Sicherung fuer den Rueckweg + die Chat-Meldung festhalten (frischer
#   UND fortgesetzter Lauf): Begleitdatei <sicherung>.meta = Kopie des Merkzettels (lifeagents rollback kennt den
#   Vorgaenger so auch NACH upgrade_finish, wenn der Merkzettel weg ist) + result_set backup. Ohne Sicherung no-op.
_upg_backup_recorded() {
  local b="$1"
  [ -n "$b" ] && [ -s "$b" ] || return 0
  if [ ! -s "${b}.meta" ] && [ -f "$UPGRADE_MARKER" ]; then cp -f "$UPGRADE_MARKER" "${b}.meta" && chmod 0600 "${b}.meta"; fi
  result_set backup "$b"
}

# upgrade_node_switched — 0, wenn dieser (ggf. fortgesetzte) Tausch die Node-Hauptversion wechselt (native n8n-
# Bausteine wie isolated-vm muessen dann gegen die neue Node-Version neu gebaut werden).
upgrade_node_switched() {
  local from
  [ -f "$UPGRADE_MARKER" ] || return 1
  from="$(read_env_value "$UPGRADE_MARKER" FROM_NODE || true)"
  [ -n "$from" ] && [ "$from" != "$NODE_MAJOR" ]
}

# upgrade_finish — sobald der Tausch steht (n8n bereit, Gateway neu gestartet; vor dem Workflow-Deploy): Merkzettel weg,
# alte Sicherungen bis auf die letzten UPGRADE_KEEP raeumen (erst JETZT, damit ein gescheiterter Tausch nie die juengste loescht).
upgrade_finish() {
  [ -f "$UPGRADE_MARKER" ] || return 0
  local backup
  backup="$(read_env_value "$UPGRADE_MARKER" BACKUP || true)"
  rm -f "$UPGRADE_MARKER"
  if [ -d "$UPGRADE_BACKUP_DIR" ]; then
    local old
    find "$UPGRADE_BACKUP_DIR" -maxdepth 1 -name 'pre-upgrade-*.dump.gpg' -printf '%T@\t%p\n' 2>/dev/null \
      | sort -rn | tail -n +$((UPGRADE_KEEP + 1)) | cut -f2- \
      | while IFS= read -r old; do rm -f -- "$old" "${old}.meta"; done
  fi
  ok "Update abgeschlossen${backup:+ — Sicherung von vorher: ${backup}}."
}

# upgrade_rollback_hint — der manuelle Rueckweg (nur wenn n8n nach dem Update nicht bereit wird). Druckt die
# Kommandos mit eingesetzten Pfaden; Ablauf: n8n stoppen -> DB aus der Sicherung neu anlegen -> alte Version
# installieren. Die DB wird komplett neu angelegt (dropdb + pg_restore --create), damit keine Tabellen der neuen
# n8n-Version liegen bleiben, an denen ein spaeteres Update erneut scheitern wuerde.
upgrade_rollback_hint() {
  local backup from_n8n from_node from_rel ktab reinstall txt
  backup="$(read_env_value "$UPGRADE_MARKER" BACKUP 2>/dev/null || true)"
  from_n8n="$(read_env_value "$UPGRADE_MARKER" FROM_N8N 2>/dev/null || true)"
  from_node="$(read_env_value "$UPGRADE_MARKER" FROM_NODE 2>/dev/null || true)"
  from_rel="$(read_env_value "$UPGRADE_MARKER" FROM_RELEASE 2>/dev/null || true)"
  ktab="$(read_env_value "$UPGRADE_MARKER" KEY_TABLE 2>/dev/null || true)"
  # Das Vorgaenger-Release ueber den Bootstrap-Launcher install.sh — NICHT ueber `lifeagents update`: scheitert der Tausch,
  # ist noch die ALTE CLI installiert (install_cli laeuft erst am Ende) und kennt keine Versionswahl. install.sh ist
  # self-contained und prueft die SHA256-Summe. Geladen wird das install.sh des NEUEN Release (Release-Asset, anonym; ein
  # Alt-Release-install.sh verlangte zwingend einen Token). URL fest auf github.com (PROVISION_GH_API = nur Test-Override).
  local boot_rel="latest/download"
  case "${RELEASE_TAG:-}" in v[0-9]*) boot_rel="download/${RELEASE_TAG}" ;; esac
  # Releases vor v0.14.0 stammen aus der privaten Zeit (Repo-Neustart ohne Historie): im oeffentlichen Repo gibt es ihr
  # Tag nicht. Dann KEINE Rueckweg-Kommandos drucken — alte Daten ohne den alten Programmstand liessen n8n erst recht
  # nicht starten (neue n8n-Version, altes Schema).
  case "$from_rel" in
    v0.[0-9].*|v0.1[0-3].*)
      txt="
  KEIN RÜCKWEG über das öffentliche Repo: der vorherige Stand ${from_rel} stammt aus der Zeit vor v0.14.0 und ist dort
  nicht mehr ladbar. Die Daten NICHT zurückspielen. Die Sicherung von vor dem Update liegt unverändert unter
  ${backup:-?}; die Diagnose (journalctl -u n8n -n 100) bitte an den Entwickler geben.
"
      printf '%s\n' "$txt" >&2
      if [ "$(ui_fd)" = 3 ]; then { printf '%s\n' "$txt" >&3; } 2>/dev/null || true; fi
      return 0 ;;
    v[0-9]*) reinstall="    curl -fsSL 'https://github.com/${PROVISION_REPO_SLUG}/releases/${boot_rel}/install.sh' -o /root/install.sh \\
      && bash /root/install.sh --version ${from_rel} --profile ${PROFILE:-release}" ;;
    *)       reinstall="    # Der vorherige Stand war kein Release ('${from_rel:-unbekannt}') -> den alten Baum erneut mit provision.sh einspielen." ;;
  esac
  if [ -z "$backup" ]; then
    txt='
  Es gibt keine Sicherung von vor dem Update (die Erstinstallation war nie abgeschlossen) — Installation neu aufsetzen.
'
  else
    txt="
  RÜCKWEG — nur nötig, wenn n8n nach dem Update dauerhaft nicht startet (Diagnose zuerst: journalctl -u n8n -n 100).
  Am einfachsten: lifeagents rollback (führt genau die Schritte unten aus, mit Rückfrage). Von Hand:
  Als root ausführen; holt die Daten von VOR dem Update zurück und spielt danach wieder den vorherigen Stand ein
  (${from_rel:-?}, n8n ${from_n8n:-?}; vorher Node.js ${from_node:-?}):

    systemctl stop n8n
    K=\"\$(runuser -u postgres -- psql -X -tA -d ${N8N_DB_NAME} -c \"SELECT value FROM ${ktab:-core.backup_key} WHERE key='${BACKUP_KEY_NAME}'\")\"
    runuser -u postgres -- dropdb ${N8N_DB_NAME}
    gpg --batch --pinentry-mode loopback --passphrase-fd 3 -d ${backup} 3< <(printf '%s' \"\$K\") \\
      | runuser -u postgres -- pg_restore --create -d postgres
    rm -f ${UPGRADE_MARKER}
${reinstall}
"
  fi
  # Ins Protokoll (stderr) UND — im ruhigen TUI-Modus — aufs Terminal (fd3): dort sieht der Owner sonst nur die ✗-Zeile.
  printf '%s\n' "$txt" >&2
  if [ "$(ui_fd)" = 3 ]; then { printf '%s\n' "$txt" >&3; } 2>/dev/null || true; fi
}

# upgrade_rollback — `lifeagents rollback`: der GEFUEHRTE Rueckweg (fuehrt aus, was upgrade_rollback_hint druckt).
#   Quelle: der Merkzettel eines unvollendeten Updates, sonst die juengste pre-upgrade-Sicherung samt Begleitdatei .meta
#   (upgrade_prepare). Zeigt, was passiert, fragt nach (nur mit Terminal: Daten seit der Sicherung gehen verloren -> nie
#   automatisch, auch nicht aus dem Chat), prueft den Schluessel an der Sicherung, stellt die GANZE DB her und spielt den
#   vorherigen Stand ueber dessen install.sh ein (--version, anonym, SHA256). Sicherheitsnetz: die aktuelle DB wird nur
#   UMBENANNT (<db>_before_rollback); scheitert das Herstellen, kommt sie unveraendert zurueck. Erst nach einem
#   erfolgreichen Einspielen wird sie geloescht.
# _rb_resume — nach einem Abbruch des Rueckwegs n8n UND die Update-Timer wieder an (sonst kaeme keine Release-Karte mehr
#   und Chat-Auftraege blieben liegen, bis zum naechsten vollen Provision).
_rb_resume() { systemctl start n8n lifeagents-update-run.timer lifeagents-update-check.timer 2>/dev/null || true; }

#   Braucht: common.sh, fetch_release.sh (_gh_release_json/_gh_fetch), deploy_workflows.sh (Owner-chat_id fuer die Meldung).
upgrade_rollback() {
  require_root
  lifeagents_db_name >/dev/null
  local src backup from_rel ktab key choice when work url kr profile rc=0 keep="${N8N_DB_NAME}_before_rollback"
  if [ -f "$UPGRADE_MARKER" ]; then
    src="$UPGRADE_MARKER"; backup="$(read_env_value "$src" BACKUP || true)"
  else
    backup="$(find "$UPGRADE_BACKUP_DIR" -maxdepth 1 -name 'pre-upgrade-*.dump.gpg' -printf '%T@\t%p\n' 2>/dev/null \
                | sort -rn | head -n1 | cut -f2-)"
    src="${backup:+${backup}.meta}"
  fi
  [ -n "$backup" ] && [ -s "$backup" ] && [ -n "$src" ] && [ -r "$src" ] \
    || die "Keine Sicherung von vor einem Update gefunden (${UPGRADE_BACKUP_DIR}) — ein Rückweg ist nicht möglich."
  from_rel="$(read_env_value "$src" FROM_RELEASE || true)"
  ktab="$(read_env_value "$src" KEY_TABLE || true)"
  case "$from_rel" in
    v0.[0-9].*|v0.1[0-3].*)
      die "Der vorherige Stand ${from_rel} stammt aus der Zeit vor v0.14.0 und ist im öffentlichen Repo nicht ladbar — kein Rückweg. Die Sicherung bleibt unter ${backup}." ;;
    v[0-9]*) [[ "$from_rel" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Vorherige Version '${from_rel}' ist kein stabiles Release — kein automatischer Rückweg." ;;
    *) die "Vorherige Version unbekannt ('${from_rel:-?}') — kein automatischer Rückweg (Einzelschritte: docs/reference/provisioning.md *Versionswechsel*)." ;;
  esac
  when="$(date -r "$backup" '+%d.%m.%Y %H:%M' 2>/dev/null || printf '?')"
  printf '\n  Rückweg auf %s\n  Die Daten werden auf den Stand der Sicherung vom %s zurückgesetzt:\n    %s\n  Alles, was seitdem gespeichert wurde, geht dabei verloren.\n\n' \
    "$from_rel" "$when" "$backup" >&2
  choice="$(printf '%s\t%s\n%s\t%s\n' "Ja, zurück auf ${from_rel}" yes 'Abbrechen' no | ui_choose 'Wirklich zurücksetzen?')"
  [ "$choice" = yes ] || die "Abgebrochen — es wurde nichts geändert (der Rückweg braucht ein Terminal für die Bestätigung)."

  update_lock_acquire || die_because locked "Gerade läuft ein Update oder eine Einrichtung — danach erneut starten."
  case "$ktab" in core.secret) ;; *) ktab=core.backup_key ;; esac
  key="$(backup_key_read "$ktab" 2>/dev/null || true)"
  [ -n "$key" ] || die "Sicherungsschlüssel nicht lesbar (${ktab}) — Rückweg abgebrochen, es wurde nichts geändert."
  gpg_sym_decrypt "$key" "$backup" >/dev/null \
    || die "Die Sicherung lässt sich mit dem Schlüssel nicht öffnen (beschädigt?) — Rückweg abgebrochen, es wurde nichts geändert."

  # Vorab das install.sh des Vorgaengers holen UND pruefen — Netz- oder Signaturfehler fallen so auf, bevor irgendetwas
  # geaendert ist. Mit Schluesselbund: Unterschrift + exakte Zeile in SHA256SUMS (gh-download-Block). Ein unsigniertes
  # Vorgaenger-Release scheitert damit HIER (sein install.sh verlangte mit dem installierten Bund dieselbe Unterschrift
  # erst NACH dem Zuruecksetzen der Daten). Ohne Bund: Abbruch (Security-Audit 2026-10 — nie ein ungepruefter
  # install.sh als root; Paritaet fetch_and_run_release).
  work="$(mktemp -d)"
  _gh_release_json "${PROVISION_GH_API}/repos/${PROVISION_REPO_SLUG}/releases/tags/${from_rel}" "$work/rel.json"
  url="$(_asset_url "$work/rel.json" install.sh)"
  [ -n "$url" ] || die "Release ${from_rel} hat kein install.sh — kein automatischer Rückweg, es wurde nichts geändert."
  kr="$(_release_keyring)"
  [ -n "$kr" ] || die "Der Release-Signierschlüssel fehlt (/etc/lifeagents/release-signing.gpg) — der Rückweg lädt nichts Ungeprüftes, es wurde nichts geändert. Abhilfe: install.sh der gewünschten Version erneut ausführen."
  _release_fetch_verify "$work/rel.json" "$work" install.sh "$from_rel" "$kr"

  log "Dienste anhalten und die Datenbank aus der Sicherung herstellen ..."
  systemctl stop lifeagents-update-run.timer lifeagents-update-check.timer n8n 2>/dev/null || true
  runuser -u postgres -- dropdb --if-exists --force "$keep" >/dev/null 2>&1 || true
  runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d postgres \
      -c "ALTER DATABASE \"${N8N_DB_NAME}\" RENAME TO \"${keep}\"" \
    || { _rb_resume; die "Datenbank ließ sich nicht beiseitelegen (noch Verbindungen?) — Rückweg abgebrochen, es wurde nichts geändert."; }
  if ! gpg_sym_decrypt "$key" "$backup" | runuser -u postgres -- pg_restore --create -d postgres; then
    runuser -u postgres -- dropdb --if-exists --force "$N8N_DB_NAME" >/dev/null 2>&1 || true
    runuser -u postgres -- psql -X -q -d postgres -c "ALTER DATABASE \"${keep}\" RENAME TO \"${N8N_DB_NAME}\"" || true
    _rb_resume
    die "Herstellen der Sicherung fehlgeschlagen — die bisherige Datenbank ist unverändert zurück. Diagnose: journalctl -u postgresql -n 50"
  fi
  rm -f "$UPGRADE_MARKER"
  ok "Daten vom ${when} wiederhergestellt."

  profile="$(read_env_value "$(lifeagents_env_file core)" INSTALL_PROFILE 2>/dev/null || true)"
  log "Vorherigen Stand ${from_rel} einspielen ..."
  LIFEAGENTS_ALLOW_DOWNGRADE=1 bash "$work/install.sh" --version "$from_rel" --profile "${profile:-release}" || rc=$?
  rm -rf -- "$work"
  if [ "$rc" -ne 0 ]; then
    _rb_resume
    warn "Die Daten sind zurückgesetzt, das Einspielen von ${from_rel} ist aber gescheitert (Exit ${rc}). Die vorige Datenbank liegt noch als ${keep}. Nur das Einspielen erneut starten (die Daten NICHT noch einmal zurücksetzen): curl -fsSL '${url}' -o /root/install.sh && bash /root/install.sh --version ${from_rel}"
    return 1
  fi
  runuser -u postgres -- dropdb --if-exists --force "$keep" >/dev/null 2>&1 || true
  notify_owner_telegram "Rückweg fertig: dein System läuft wieder auf ${from_rel}, mit den Daten vom ${when}." || true
  ok "Rückweg fertig: ${from_rel} mit den Daten vom ${when}."
}
