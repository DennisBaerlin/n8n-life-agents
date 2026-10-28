# common.sh — shared helpers for the provisioning core.
# SOURCED, never executed: no shebang, no `set -e` here (the top-level script owns the
# error mode per the plan: "set -euo pipefail nur im Top-Script"). Every helper is
# idempotent or guarded so a second install run is a no-op.

# --- logging -----------------------------------------------------------------
# All diagnostics go to stderr so a caller can capture a helper's stdout cleanly.
# Farb-Guard nach no-color.org/clig.dev: Farbe NUR wenn der Ziel-Strom ein TTY ist UND NO_COLOR
# nicht gesetzt UND TERM != dumb. Praefixe bleiben ASCII (Owner-Entscheid 2026-07-03).
# ui_color_enabled <fd> = DIE Pruefung fuer beide Stroeme: fd 2 fuer die log/ok/warn-Farben unten, fd 1 fuer
# Anzeige-Listen auf stdout (`lifeagents config list`) — dort VOR jeder Pipe zum Pager auswerten (danach ist
# stdout die Pipe, nicht mehr das Terminal).
ui_color_enabled() { [ -t "${1:-1}" ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; }
if ui_color_enabled 2; then
  _C_RST=$'\033[0m'; _C_CYAN=$'\033[0;36m'; _C_GREEN=$'\033[0;32m'; _C_YELLOW=$'\033[0;33m'; _C_RED=$'\033[0;31m'
else
  _C_RST=''; _C_CYAN=''; _C_GREEN=''; _C_YELLOW=''; _C_RED=''
fi
log()  { printf '%s[*]%s %s\n' "$_C_CYAN"   "$_C_RST" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$_C_GREEN"  "$_C_RST" "$*" >&2; }
# warn: im Quiet-Modus (ui_log_begin) ZUSAETZLICH aufs Terminal (fd3) — eine Warnung soll der Nutzer
# sehen, nicht nur das Log. Explizites `return 0`: warn steht oft als letzter Befehl einer `|| warn`-Kette.
warn() {
  printf '%s[!]%s %s\n' "$_C_YELLOW" "$_C_RST" "$*" >&2
  if [ "${UI_QUIET:-0}" = 1 ]; then _ui_term_note "$*"; fi
  return 0
}
err()  { printf '%s[x]%s %s\n' "$_C_RED"    "$_C_RST" "$*" >&2; }
# die: nur in der HAUPT-Shell zaehlt ein Abbruch als gescheitertes Update (Ergebnis-Datei, s. result_set) — ein `die` in
# einer Subshell (Paket-Install `( pkg_install_one )`, $(...)) beendet nur diesen Teil, der Lauf geht weiter.
die()  { err "$*"; [ "${BASH_SUBSHELL:-0}" -eq 0 ] && result_set status failed; exit 1; }
# die_because <reason_code> <text> — wie die, merkt aber den festen Grund fuer die Fehler-Hilfe im Chat
# (core.fn_update_report: net, rate_limit, not_found, checksum, signature, disk, backup, db, n8n_start, locked, downgrade).
die_because() { [ "${BASH_SUBSHELL:-0}" -eq 0 ] && result_set reason_code "$1"; shift; die "$@"; }

# --- Ergebnis-Datei eines Laufs (Update im Chat) -----------------------------------------------------------------
# Der Chat-Runner (lib/update_runner.sh) setzt LIFEAGENTS_RESULT_FILE und liest danach KEY=VALUE-Zeilen statt aus
# Exit-Code + Marker-Dateien zu raten (ein Halt endet mit exit 0, ein Paket-Fehler auch): status (running|ok|partial|
# held|failed), stage (Schritt-Code aus ui_step), changed (true ab der ersten Systemaenderung), reason_code,
# failed_packages, missing_keys, backup. Ohne Variable (Terminal-Lauf) ist alles ein no-op. Immer rc 0.
result_set() {
  [ -n "${LIFEAGENTS_RESULT_FILE:-}" ] || return 0
  env_upsert "$LIFEAGENTS_RESULT_FILE" "$1" "$(printf '%s' "$2" | tr '\n' ' ')" 2>/dev/null || true
  return 0
}

# --- Update-Sperre: EINE fuer alle Wege, die das System umbauen ----------------------------------------------------
# provision.sh main (Installer, `lifeagents update`, `reconfigure`, `package install`) und der Chat-Runner nehmen sie;
# zwei gleichzeitige Laeufe (Terminal-Update waehrend eines Chat-Updates) sind so ausgeschlossen. fd 9 + flock; der
# Runner nie wartend (-n, naechste Minute), Terminal-Laeufe bis 30 s: der minuetliche Runner haelt die Sperre zur
# vollen Minute fuer Sekundenbruchteile auch ohne Auftrag (CI-Befund 2026-10-26: Update zur Minute :00 brach ab).
# Ein Kind-Lauf erbt die Sperre ueber den offenen fd und LIFEAGENTS_UPDATE_LOCK_HELD=1 (exec-fest).
LIFEAGENTS_UPDATE_LOCK="${LIFEAGENTS_UPDATE_LOCK:-/run/lifeagents-update.lock}"
# update_lock_acquire [wait_s] — 0 = Sperre gehalten (oder geerbt), 1 = belegt (ohne wait_s sofort, sonst nach wait_s).
update_lock_acquire() {
  [ "${LIFEAGENTS_UPDATE_LOCK_HELD:-0}" = 1 ] && return 0
  need_cmd flock || return 0   # util-linux ist auf Debian immer da; fehlt es, lieber ohne Sperre als nie
  exec 9>>"$LIFEAGENTS_UPDATE_LOCK" || return 0
  if [ -n "${1:-}" ]; then flock -w "$1" 9 || return 1; else flock -n 9 || return 1; fi
  export LIFEAGENTS_UPDATE_LOCK_HELD=1
}
# update_lock_free — 0, wenn gerade niemand die Sperre haelt (read-only Probe fuer doctor).
update_lock_free() {
  need_cmd flock || return 0
  [ -e "$LIFEAGENTS_UPDATE_LOCK" ] || return 0
  flock -n "$LIFEAGENTS_UPDATE_LOCK" true 2>/dev/null
}

# --- guards ------------------------------------------------------------------
require_root() { [ "$(id -u)" -eq 0 ] || die "Provisioning muss als root laufen (sudo)."; }
need_cmd()     { command -v "$1" >/dev/null 2>&1; }
require_cmd()  { need_cmd "$1" || die "Pflicht-Kommando fehlt: $1"; }

# pg_db_encoding <db> — Kodierung der Datenbank (z. B. UTF8/SQL_ASCII); leer, wenn PG fehlt, nicht laeuft oder die DB
# nicht existiert. Als postgres-Superuser (Peer-Auth) -> nur als root. EINE Abfrage fuer Installer-Guard + doctor
# (UTF-8 ist Gesetz, provisioning/CLAUDE.md). Der DB-Name kommt aus der eigenen Config, nie vom Nutzer.
pg_db_encoding() {
  need_cmd psql && need_cmd runuser || return 0
  runuser -u postgres -- psql -X -tA -c "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='$1'" 2>/dev/null || true
}

# --- random secrets (hex → safe in env files, sed, and shell, no escaping) ----
rand_hex()    { openssl rand -hex "${1:-24}"; }

# --- atomic / idempotent file writes -----------------------------------------
# write_file <path> [mode] [owner]  — content from stdin, atomic temp→mv.
write_file() {
  local path="$1" mode="${2:-0644}" owner="${3:-}"
  mkdir -p "$(dirname "$path")"
  local tmp; tmp="$(mktemp "${path}.XXXXXX")"
  cat > "$tmp"
  chmod "$mode" "$tmp"
  [ -n "$owner" ] && chown "$owner" "$tmp"
  mv -f "$tmp" "$path"
}

# write_if_changed <path> [mode] [owner]  — content from stdin. Writes only when the
# content differs; prints nothing. Returns 0 if it wrote (changed), 1 if unchanged.
# Lets callers gate expensive follow-ups (daemon-reload, service restart) on real change.
write_if_changed() {
  local path="$1" mode="${2:-0644}" owner="${3:-}"
  local new; new="$(cat)"
  if [ -f "$path" ] && [ "$new" = "$(cat "$path")" ]; then
    return 1
  fi
  printf '%s\n' "$new" | write_file "$path" "$mode" "$owner"
  return 0
}

# env_upsert <file> <key> <value>  — set KEY=value in an env file, preserving every other line
# and comment (Coolify .env-merge pattern: replace the key's line if present, else append). The
# content replace keeps the existing file's mode/owner; a fresh file inherits the umask (callers
# that create the file first set 640 root:n8n). Atomic via temp. Values are tokens/paths/hex with
# no newline by construction.
env_upsert() {
  local file="$1" key="$2" val="$3"
  mkdir -p "$(dirname "$file")"
  local tmp; tmp="$(mktemp "${file}.XXXXXX")"
  if [ -f "$file" ]; then grep -vE "^${key}=" "$file" > "$tmp" || true; fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# read_env_value <file> <key>  → value on stdout, or non-zero if absent. Used to
# PRESERVE generated secrets across re-runs (the encryption key must never change once
# n8n has booted, or all stored credentials become undecryptable).
read_env_value() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 1
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1)" || true
  [ -n "$line" ] || return 1
  printf '%s' "${line#*=}"
}

# env_has_key <file> <key>  → 0 wenn eine KEY=-Zeile existiert (auch mit LEEREM Wert).
# Das ist das SEEN-Bit des debconf-Modells (Spec C, E2.1): "Zeile existiert" = die Frage wurde
# schon gestellt/beantwortet — orthogonal zum Wert (read_env_value liefert den).
env_has_key() { [ -f "$1" ] && grep -qE "^${2}=" "$1"; }

# drop_legacy_repo_token <env-file...> — Einmal-Migration Public-Repo (2026-10-24): der Release-Download ist anonym,
#   ein GH_TOKEN aus der privaten Zeit wird nie mehr gelesen. Steht er noch in einer Env-Datei, die Zeile entfernen und
#   einmal daran erinnern, ihn auf GitHub zu widerrufen (ein liegengelassener gueltiger Token ist ein Risiko ohne Nutzen).
drop_legacy_repo_token() {
  local f
  for f in "$@"; do
    env_has_key "$f" GH_TOKEN || continue
    env_remove_key "$f" GH_TOKEN
    warn "Alter GitHub-Token (GH_TOKEN) aus $f entfernt — der Download braucht keinen mehr. Bitte den Token auf GitHub widerrufen (Settings > Developer settings > Personal access tokens)."
  done
}

# env_remove_key <file> <key>  — die KEY=-Zeile entfernen (Einmal-Migrations-Helfer, Opus-Review F3;
# Kommentare/andere Zeilen bleiben, atomar via temp wie env_upsert).
env_remove_key() {
  local file="$1" key="$2" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp "${file}.XXXXXX")"
  grep -vE "^${key}=" "$file" > "$tmp" || true
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# ---- /etc/lifeagents secret namespace (Phase 5) -------------------------------------------------
# Installer-eigener Secret-Namespace (FHS §3.7: ein Installer besitzt SEIN /etc-Verzeichnis, nicht
# n8ns). `core.env` = Host/Core-Secrets (API-Key, core_ro/context_ro-PW) + Nutzer-Eingaben (Domain,
# Owner-Identitaet, LLM-/Telegram-Keys); `<pkg>.env` = Secrets EINES Pakets (<pkg>_rw/_ro-PW) — install
# legt an, `uninstall --purge` loescht (`rm`), ein Schreiber pro Datei. n8n.env bleibt n8n-eigen in
# /etc/n8n (n8n liest es selbst). NIE im Repo; 640 root:<n8n-Gruppe>.
LIFEAGENTS_DIR="${LIFEAGENTS_DIR:-/etc/lifeagents}"

# lifeagents_env_file <pkg>  -> Pfad der per-Paket-env-Datei (core -> /etc/lifeagents/core.env).
lifeagents_env_file() { printf '%s/%s.env' "$LIFEAGENTS_DIR" "$1"; }

# Release-Quelle: EINE Adresse fuer die Runtime (fetch_release.sh = lifeagents update, upgrade_guard.sh = Rueckweg-
# Hinweis). install.sh (self-contained Bootstrap, sourct nichts) traegt bewusst eine eigene Kopie.
PROVISION_REPO_SLUG="${PROVISION_REPO_SLUG:-DennisBaerlin/n8n-life-agents}"
# shellcheck disable=SC2034  # gelesen von fetch_release.sh + upgrade_guard.sh (gesourct)
PROVISION_GH_API="${PROVISION_GH_API:-https://api.github.com}"   # Override nur Test (Mock); Download immer anonym

# Installierter Runtime-Baum (install_cli spiegelt provisioning/ + packages/ hierhin) und sein Marker VERSION: install_cli
# schreibt ihn, sobald Core + Pakete einmal durchgelaufen sind (auch wenn der Deploy uebersprungen wurde oder ein Paket
# scheiterte — „Core konvergiert", postgres-Entrypoint-Muster PG_VERSION) -> fehlt er, ist die Maschine frisch
# (_is_first_install). EINE Adresse fuer install_cli, _is_first_install, run_installed_release und den Uninstall
# (Install-UX-Phase 7).
lifeagents_runtime_dir()    { printf '%s' "${LIFEAGENTS_LIB:-/usr/local/lib/lifeagents}"; }
# lifeagents_db_name — N8N_DB_NAME fuer Runtime-Verben ausserhalb provision.sh setzen (n8n.env, Standard n8n) und auf
#   stdout geben. EINE Adresse fuer die vorher in jeder *_cli.sh kopierte Aufloesung. Setzt die Variable global (nie
#   in $(...) aufrufen, sonst bleibt sie im Subshell; Aufruf `lifeagents_db_name >/dev/null`).
lifeagents_db_name() {
  if [ -z "${N8N_DB_NAME:-}" ]; then
    local envf="${N8N_ENV_FILE:-/etc/n8n/n8n.env}" val=""
    if [ -r "$envf" ]; then
      val="$(grep -E '^DB_POSTGRESDB_DATABASE=' "$envf" 2>/dev/null | tail -n1)"
      val="${val#*=}"
    fi
    N8N_DB_NAME="${val:-n8n}"
  fi
  printf '%s' "$N8N_DB_NAME"
}
lifeagents_version_marker() { printf '%s/VERSION' "$(lifeagents_runtime_dir)"; }

# ensure_lifeagents_dir  -> /etc/lifeagents 750 root:<n8n-Gruppe> (idempotent).
ensure_lifeagents_dir() {
  mkdir -p "$LIFEAGENTS_DIR"
  chmod 0750 "$LIFEAGENTS_DIR" 2>/dev/null || true
  chown "root:${N8N_USER:-n8n}" "$LIFEAGENTS_DIR" 2>/dev/null || true
}

# psql_setvar <name> <value>  -> eine psql-`\set name 'value'`-Zeile (escaped fuer den Single-Quote-
#   Kontext: \ -> \\, ' -> \'). Fuer einen 600/postgres-eigenen Treiber — der Wert steht NIE in der
#   Kommandozeile (kein /proc/cmdline-Leak; Hard-Rule "Secret nie als CLI-Argument").
psql_setvar() {
  local v="$2"; v="${v//\\/\\\\}"; v="${v//\'/\\\'}"
  printf "\\set %s '%s'\n" "$1" "$v"
}

# psql_superuser_driver [psql-args...]  -> liest \set-Zeilen + SQL von STDIN, fuehrt sie als
#   postgres-Superuser ueber eine 600/postgres-eigene Temp-Datei aus (Werte bleiben in der 600-Datei).
#   Reads globals: DB_SUPERUSER (default postgres), N8N_DB_NAME.
# shellcheck disable=SC2120  # generischer Treiber: optionale psql-Args via "$@"; aktueller Caller bare
psql_superuser_driver() {
  local su="${DB_SUPERUSER:-postgres}" drv; drv="$(mktemp /tmp/la_drv.XXXXXX.sql)"
  cat > "$drv"; chmod 600 "$drv"; chown "$su" "$drv" 2>/dev/null || true
  local rc=0
  runuser -u "$su" -- psql -v ON_ERROR_STOP=1 -X -d "$N8N_DB_NAME" "$@" -f "$drv" || rc=$?
  rm -f "$drv"; return $rc
}

# provision_role_password <role> <env_file> <var_name>  -> einer LOGIN-Rolle ein Passwort sicherstellen,
#   persistiert in env_file (override-first reuse: Prozess-Env $var_name ODER die Datei gewinnt -> ein
#   funktionierendes Passwort wird NIE rotiert; nach `--purge` ist die Rolle frisch+passwortlos -> die
#   persistierte Datei liefert dasselbe PW -> Rolle <-> Credential bleiben in Sync, B2), exportiert als
#   var_name fuer die Credential-Injektion. GENERISCH fuer Host-Rollen (core_ro/context_ro) UND
#   Paket-Rollen (<pkg>_rw/_ro) — ein Mechanismus, keine hartkodierte Rollen-Liste. Die Rolle muss
#   existieren (apply_schema/fn_provision_package_roles legt sie LOGIN ohne Passwort an). Wert NIE im argv.
#   Reads globals: N8N_DB_NAME, N8N_USER (Datei-Owner). 0 = ok, !=0 = ALTER ROLE fehlgeschlagen.
provision_role_password() {
  local role="$1" envf="$2" var="$3" val
  eval "val=\${$var:-}"
  [ -n "$val" ] || val="$(read_env_value "$envf" "$var" || true)"
  [ -n "$val" ] || val="$(rand_hex 24)"
  # shellcheck disable=SC2119  # psql_superuser_driver bewusst ohne extra psql-Args
  if { psql_setvar rolepw "$val"; printf "ALTER ROLE %s PASSWORD :'rolepw';\n" "$role"; } \
       | psql_superuser_driver >/dev/null 2>&1; then
    eval "$var=\$val; export $var"
    if [ ! -f "$envf" ]; then
      mkdir -p "$(dirname "$envf")"; : > "$envf"
      chmod 0640 "$envf" 2>/dev/null || true; chown "root:${N8N_USER:-n8n}" "$envf" 2>/dev/null || true
    fi
    env_upsert "$envf" "$var" "$val"
    chmod 0640 "$envf" 2>/dev/null || true; chown "root:${N8N_USER:-n8n}" "$envf" 2>/dev/null || true
    return 0
  fi
  return 1
}

# --- template rendering -------------------------------------------------------
# render_template <tpl> KEY=VAL KEY=VAL ...  → rendered text on stdout.
# Replaces @@KEY@@ tokens. Values are hex/codenames/paths (no |, &, or \) by
# construction (secrets are rand_hex), so sed with | delimiter is safe; we still
# escape the three sed-actives defensively.
render_template() {
  local tpl="$1"; shift
  [ -f "$tpl" ] || die "Template fehlt: $tpl"
  local content kv key val
  content="$(cat "$tpl")"
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    val="$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')"
    content="$(printf '%s' "$content" | sed "s|@@${key}@@|${val}|g")"
  done
  printf '%s\n' "$content"
}

# --- systemd helpers ---------------------------------------------------------
# install_unit <name> <changed?>  — daemon-reload only if the unit changed, then
# enable + (re)start. <changed?> is the exit status of the write (0=changed).
enable_start_unit() {
  local unit="$1" changed="${2:-1}"
  if [ "$changed" -eq 0 ]; then
    systemctl daemon-reload
  fi
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if [ "$changed" -eq 0 ] || ! systemctl is-active --quiet "$unit"; then
    systemctl restart "$unit"
  fi
}

# --- apt: idempotent repo + key registration ---------------------------------
# add_apt_key <url> <keyring-path>  — dearmor the key only if the keyring is missing.
add_apt_key() {
  local url="$1" keyring="$2"
  if [ -s "$keyring" ]; then return 0; fi
  mkdir -p "$(dirname "$keyring")"
  curl -fsSL "$url" | gpg --dearmor --yes -o "$keyring"
  chmod 0644 "$keyring"
}

# add_apt_source <list-path> <line>  — write the sources.list.d entry if absent/different.
add_apt_source() {
  local list="$1" line="$2"
  printf '%s\n' "$line" | write_if_changed "$list" 0644 || true
}

# apt_update_once — run `apt-get update` at most once per install invocation.
_APT_UPDATED=0
apt_update_once() {
  if [ "$_APT_UPDATED" -eq 0 ]; then
    log "apt-get update ..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    _APT_UPDATED=1
  fi
}
# force_apt_update — invalidate the once-guard (call after adding a new repo).
force_apt_update() { _APT_UPDATED=0; apt_update_once; }

apt_install() {
  log "apt-get install: $*"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

# --- terminal UX (ui_*-Schicht) ------------------------------------------------
# EINE Ausgabe-/Eingabe-Schicht fuer beide Install-Pfade (Haupt-Install + Paket-Install), Spec D
# der Install-UX-Phase: jede ui_*-Funktion hat einen gum-Zweig (huebsch, optional) UND einen
# plain-ANSI-Fallback (funktional identisch). gum ist NIE eine Hard-Dependency: Feature-Detection
# + best-effort ensure_gum (SHA256-gepinnter GitHub-Release-Download, KEIN Fremd-APT-Repo);
# unattended/kein TTY laeuft IMMER plain (deterministische Substrat-Ausgabe). gum zeichnet in den
# normalen Scrollback (kein Alternate-Screen wie whiptail) -> Pairing-Code/Zugaenge bleiben kopierbar.

# tty_usable — 0 nur, wenn sich /dev/tty WIRKLICH oeffnen laesst. `[ -r /dev/tty ]` prueft nur die
# Dateirechte (crw-rw-rw-) und ist darum auch OHNE steuerndes Terminal wahr (ssh ohne -t, cron,
# docker exec ohne -t) -> der erste read/printf auf /dev/tty scheiterte dann mit ENXIO (Install-UX-
# Phase 3, live auf der Dev-Instanz belegt). Muster rustup-init (`-t`-Probe statt Rechte-Test).
tty_usable() { { : </dev/tty; } 2>/dev/null; }

# ui_interactive — DAS eine Interaktivitaets-Praedikat (Befund 1 der Install-UX-Phase):
# TTY nutzbar UND NICHT --unattended. ${UNATTENDED:-0} ist default-safe im lifeagents-CLI-Kontext
# (dort ist die Variable nicht gesetzt = interaktiv erlaubt). JEDER interaktive Zweig im
# provisioning-Baum gatet hierueber (contract_lint Prompt-Gate-Guard; Einzeiler, der Lint prueft
# UNATTENDED auf derselben Zeile).
ui_interactive() { [ "${UNATTENDED:-0}" -ne 1 ] && tty_usable; }

# gum-Pins: Update = Version + BEIDE Hashes aus checksums.txt des Releases eintragen
# (github.com/charmbracelet/gum/releases). Best-effort — ein falscher/alter Pin degradiert
# nur auf plain ANSI, bricht nie den Install.
GUM_VERSION="0.17.0"
GUM_SHA256_X86_64="69ee169bd6387331928864e94d47ed01ef649fbfe875baed1bbf27b5377a6fdb"
GUM_SHA256_ARM64="b0b9ed95cbf7c8b7073f17b9591811f5c001e33c7cfd066ca83ce8a07c576f9c"
GUM_INSTALL_DIR="${LIFEAGENTS_LIB:-/usr/local/lib/lifeagents}/bin"

# gum-choose-Theme ZENTRAL (ein Look fuer alle ui_choose-Picker, passend zum cyan ui_section-Stil;
# ANSI-Farbcodes: 6=cyan, 14=hellcyan). NO_COLOR/TERM=dumb respektiert gum selbst (termenv);
# Auswahl-Praefixe bleiben gum-Default (die ASCII-Praefix-Regel gilt fuer UNSERE printf-Ausgaben).
export GUM_CHOOSE_CURSOR_FOREGROUND="6" GUM_CHOOSE_HEADER_FOREGROUND="6" \
       GUM_CHOOSE_SELECTED_FOREGROUND="14" GUM_CHOOSE_SELECTED_BOLD="true"

# _ui_term_capable → 0 wenn das Terminal ein TUI-Widget tragen kann. bubbletea/gum HAENGT auf
# TERM=unset/dumb (statt sauber zu failen — live in der pty-Probe getroffen) -> ohne brauchbares
# TERM IMMER plain (der read-Fallback braucht kein TERM). Schliesst "seltsames Terminal = Hang".
_ui_term_capable() { [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ]; }

# _ui_gum_bin → Pfad eines nutzbaren gum-Binaries auf stdout (nonzero = plain-Zweig nehmen).
# Nur im interaktiven Kontext (unattended bleibt byte-deterministisch plain).
# GUM_DISABLE=1 erzwingt plain (deterministische pty-Proben + Owner-Opt-out ohne Deinstallation).
_ui_gum_bin() {
  [ "${GUM_DISABLE:-0}" != "1" ] || return 1
  _ui_term_capable || return 1
  ui_interactive || return 1
  if [ -x "$GUM_INSTALL_DIR/gum" ]; then printf '%s' "$GUM_INSTALL_DIR/gum"; return 0; fi
  command -v gum 2>/dev/null && return 0
  return 1
}

# ensure_gum — gum best-effort bereitstellen (nur interaktiv; nie fatal). Statisches Go-Binary
# vom GitHub-Release, SHA256-VOR-dem-Entpacken verifiziert (dasselbe "safer curl|bash"-Muster wie
# install.sh/fetch_release). Jeder Fehlschlag -> log + plain weiter. GUM_DISABLE=1 -> no-op.
ensure_gum() {
  [ "${GUM_DISABLE:-0}" != "1" ] || return 0
  _ui_term_capable || return 0
  ui_interactive || return 0
  _ui_gum_bin >/dev/null 2>&1 && return 0
  need_cmd curl || return 0
  need_cmd sha256sum || return 0
  need_cmd tar || return 0
  local arch sha
  case "$(uname -m)" in
    x86_64)  arch="x86_64"; sha="$GUM_SHA256_X86_64" ;;
    aarch64) arch="arm64";  sha="$GUM_SHA256_ARM64" ;;
    *) log "gum: Architektur $(uname -m) nicht gepinnt — Ausgabe bleibt plain ANSI."; return 0 ;;
  esac
  local url="https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${arch}.tar.gz"
  local tmpd; tmpd="$(mktemp -d)" || return 0
  log "gum ${GUM_VERSION} laden (optionale Terminal-UX; Fehlschlag = plain ANSI) ..."
  if ! curl -fsSL --max-time 30 -o "$tmpd/gum.tgz" "$url" 2>/dev/null; then
    log "gum-Download fehlgeschlagen — plain ANSI."; rm -rf "$tmpd"; return 0
  fi
  if ! printf '%s  %s\n' "$sha" "$tmpd/gum.tgz" | sha256sum -c --quiet - >/dev/null 2>&1; then
    warn "gum: SHA256-Mismatch (Pin ${GUM_VERSION}) — Download verworfen, plain ANSI."
    rm -rf "$tmpd"; return 0
  fi
  local bin
  if tar -xzf "$tmpd/gum.tgz" -C "$tmpd" 2>/dev/null && bin="$(find "$tmpd" -type f -name gum | head -n1)" && [ -n "$bin" ]; then
    # `|| …return 0`: als Non-Root (z. B. Hauptmenue der lifeagents-CLI) ist das Zielverzeichnis
    # nicht schreibbar — ein nacktes mkdir -p wuerde unter dem geerbten set -e den ganzen Lauf
    # killen statt best-effort auf plain ANSI zu degradieren (Plan-Kritik A2).
    mkdir -p "$GUM_INSTALL_DIR" 2>/dev/null || { log "gum: ${GUM_INSTALL_DIR} nicht schreibbar (kein root?) — plain ANSI."; rm -rf "$tmpd"; return 0; }
    if install -m 0755 "$bin" "$GUM_INSTALL_DIR/gum" 2>/dev/null; then
      ok "gum ${GUM_VERSION} installiert (${GUM_INSTALL_DIR}/gum) — huebsche Prompts aktiv."
    else
      log "gum-Install fehlgeschlagen — plain ANSI."
    fi
  else
    log "gum-Archiv unlesbar — plain ANSI."
  fi
  rm -rf "$tmpd"
  return 0
}

# ui_section <titel> — benannter Sektions-Banner (Owner-Entscheid: OHNE x/y-Zaehler, Hermes-Stil)
# auf stderr (Fortschritts-Narration). gum: gestylter Titel; plain: cyan '--- Titel ---'.
ui_section() {
  local title="$1" gum fd=2
  if [ "${UI_QUIET:-0}" = 1 ]; then
    # Quiet: Ueberschrift aufs Terminal (fd3), Marker ins Log (Orientierung beim Lesen).
    _ui_spin_stop
    printf '\n== %s ==\n' "$title" >&2
    fd=3
  fi
  if gum="$(_ui_gum_bin)"; then
    { printf '\n'; printf '%s' "$title" | "$gum" style --bold --foreground 6 --border normal --padding "0 1" 2>/dev/null; } >&"$fd" && return 0
  fi
  printf '\n%s--- %s ---%s\n' "${_T_CYAN:-$_C_CYAN}" "$title" "${_T_RST:-$_C_RST}" >&"$fd"
}

# ui_box <titel> — Ergebnis-Box auf STDOUT (Body von STDIN; scrollback-persistent, kopierbar —
# der EINE Helfer fuer Pairing-Code / Zugangs-Recap / End-Recap, ersetzt die hand-gerollten
# ====-Boxen). Secrets laufen via STDIN-Pipe, NIE ins argv (Projekt-Hard-Rule). Im Quiet-Modus geht
# die Box NUR aufs Terminal (fd3), NIE ins Log: Boxen tragen Pairing-Code + generierte Passwoerter.
ui_box() {
  local title="$1" body gum fd=1
  body="$(cat)"
  if [ "${UI_QUIET:-0}" = 1 ]; then _ui_spin_stop; fd=3; fi
  if gum="$(_ui_gum_bin)"; then
    if { printf '%s\n\n%s\n' "$title" "$body" | "$gum" style --border rounded --padding "0 2" --margin "1 0" 2>/dev/null; } >&"$fd"; then
      return 0
    fi
  fi
  {
    printf '\n============================================================\n'
    printf '  %s\n' "$title"
    printf -- '------------------------------------------------------------\n'
    printf '%s\n' "$body" | sed 's/^/  /'
    printf '============================================================\n\n'
  } >&"$fd"
}

# ui_page — Anzeige-Text von STDIN auf stdout; auf einem Terminal ueber den Pager des Owners (clig.dev: Pager nur
# bei interaktivem stdout; git/systemctl-Muster: $PAGER, sonst less, LESS=FRX nur wenn LESS leer -> passt der Text
# auf einen Bildschirm, wird nicht geblaettert). Pager = LIFEAGENTS_USER_PAGER (merkt lifeagents.tpl VOR seinem
# eigenen PAGER=cat-Export), sonst less; leer->less, `cat`/nicht vorhanden/kein brauchbares TERM (less haengt bei
# TERM=dumb) -> direkt. LESSCHARSET=utf-8: root-Shells im LXC laufen oft mit C-Locale, less zeigte Umlaute sonst
# als <C3><A4>. Der Text wird erst komplett gelesen -> ein Fehler des Erzeugers bricht ab, BEVOR der Pager startet.
# `|| true`: beendet der Owner den Pager vorzeitig (q), endet der Schreiber mit SIGPIPE — unter set -e/pipefail
# kein Fehler.
ui_page() {
  local text pager
  text="$(cat)"
  pager="${LIFEAGENTS_USER_PAGER:-less}"
  if [ -t 1 ] && _ui_term_capable && [ "$pager" != "cat" ] && need_cmd "${pager%% *}"; then
    # shellcheck disable=SC2086  # $pager darf Optionen tragen (PAGER='less -S'), wie bei git/systemctl
    printf '%s\n' "$text" | LESS="${LESS:-FIRX}" LESSCHARSET="${LESSCHARSET:-utf-8}" $pager || true
    return 0
  fi
  printf '%s\n' "$text"
}

# Fragen-Buchfuehrung (Install-UX-Phase 7; vorbelegt fuer set -u in JEDEM Einstieg, der common.sh sourct):
# UI_ASKED=1, sobald in diesem Lauf WIRKLICH eine Frage gestellt wurde (nur dann — oder bei der Erstinstallation —
# erscheint die Uebersicht vor dem Installieren); UI_ASKED_KEYS = die dabei gefragten Keys; UI_ABORT_MSG s. ui_abort.
# shellcheck disable=SC2034  # gelesen/geschrieben von release_inputs.sh, pkg_lifecycle.sh, provision.sh
UI_ASKED=0
UI_ABORT_MSG=''
# Reihenfolge bewusst: UI_ASKED_KEYS steht als LETZTE Zuweisung vor einer Leerzeile — gitleaks' generic-api-key-Regel
# las sonst „…KEYS=''" + den Namen der Folgezeile als Schluessel-Wert (Fehlalarm, Install-UX-Phase 7).
# shellcheck disable=SC2034  # s. o.
UI_ASKED_KEYS=''

# ui_input <prompt> <secret?> — EIN interaktiver Wert auf stdout (leer = kein TTY/unattended/skip).
# gum: gum input [--password]; plain: read aus /dev/tty (curl|bash-sicher). secret=1 -> maskiert.
# Der EINE Eingabe-Primitiv — Aufrufer sind die sanktionierten Wrapper (_prompt_validated & Co.,
# contract_lint Prompt-Gate-Guard).
# ui_abort — Strg-C in einem gum-Feld (gum faengt die Taste im Raw-Modus selbst und endet mit 130, das Skript
# bekommt KEIN SIGINT): den ganzen Befehl beenden statt die Eingabe als „leer = überspringen" zu werten (sonst
# entstuende still eine „schon gefragt"-Zeile). Laeuft in der $(…)-Subshell des Aufrufers -> beendet per TERM die
# Haupt-Shell ($$ = Haupt-PID auch in Subshells). Bereits beantwortete Fragen sind sofort gespeichert
# (_prompt_validated) -> ein erneuter Lauf fragt nur den Rest. UI_ABORT_MSG ersetzt den Text, wo „gespeichert" nicht
# stimmt (`lifeagents reconfigure` speichert erst nach der letzten Antwort -> „nichts geändert").
ui_abort() {
  { printf '\n%s\n' "${UI_ABORT_MSG:-Abgebrochen (Strg-C). Bisherige Antworten sind gespeichert — ein erneuter Aufruf fragt nur den Rest.}" > /dev/tty; } 2>/dev/null || true
  kill -TERM "$$" 2>/dev/null || true
  exit 130
}

ui_input() {
  local prompt="$1" secret="${2:-0}" gum val="" rc=0
  ui_interactive || return 0
  if gum="$(_ui_gum_bin)"; then
    if [ "$secret" = "1" ]; then
      val="$("$gum" input --password --prompt "$prompt" --placeholder '' --width 0 </dev/tty 2>/dev/tty)" || rc=$?
    else
      val="$("$gum" input --prompt "$prompt" --placeholder '' --width 0 </dev/tty 2>/dev/tty)" || rc=$?
    fi
    [ "$rc" -eq 130 ] && ui_abort   # Strg-C in gum = Abbruch, NICHT „leer = überspringen"
    printf '%s' "$val"
    return 0
  fi
  printf '%s' "$prompt" > /dev/tty
  # `|| true`: EOF am (p)tty (z. B. Skript-Probe mit endlichem Input) darf unter dem geerbten
  # set -e nicht den ganzen Lauf killen — EOF verhaelt sich wie "leer = skip".
  if [ "$secret" = "1" ]; then
    read -rs val < /dev/tty || true; printf '\n' > /dev/tty
  else
    read -r val < /dev/tty || true
  fi
  printf '%s' "$val"
}

# ui_choose <header> <multi:0|1> [<preselect-csv>] — DER interaktive Listen-Picker (Pfeiltasten/
# Leertaste). Optionen von STDIN, eine je Zeile als "label<TAB>value" (ohne TAB gilt label==value).
# Rueckgabe: gewaehlte value(s) newline-separiert auf stdout; LEER = kein TTY/unattended/Abbruch/
# keine Optionen — der Aufrufer faellt auf seinen Bestandspfad zurueck (derselbe Vertrag wie
# ui_input: leer + return 0, KEIN Exit-Code-Signal — schuetzt val=$(ui_choose ...) vor dem
# set -e-Kommandosubstitutions-Footgun; arch-challenge REJECT 2.3). gum-Zweig: gum choose macht
# den TAB-Split NATIV (--label-delimiter, arch-challenge ADOPT 2.2) — Optionen laufen als stdin-
# Pipe, bubbletea holt sich die Tastatur selbst von /dev/tty, TUI auf /dev/tty (nie stderr, eine
# 2>&1-Umleitung des Aufrufers darf die UI nicht verschlucken). Plain-Fallback: nummerierte Liste
# + Nummern-Eingabe (yay-Muster; Multi = Space/Komma), Anzeige+read via /dev/tty wie ui_input.
# preselect-csv ist reine Komfort-Vorbelegung im gum-Zweig (--selected) und matcht gegen die
# LABELS, nicht die Values (gum choose/command.go ersetzt Options bei --label-delimiter durch die
# Labels VOR dem Selected-Abgleich — Cold-Eyes A2; die Aufrufer mit Vorbelegung — Funktions-Wahl und Einstellungen in
# der Uebersicht, Install-UX-Phase 7 — reichen darum kommafreie LABELS);
# der Plain-Pfad ignoriert sie bewusst (explizite Nummern-Eingabe, Semantik identisch). Das Echo
# der Wahl (E7, die gum-TUI loescht sich selbst) liegt ZENTRAL hier und zeigt die LABELS (nie interne
# Werte wie __later__). Endet IMMER mit return 0.
# Werte sollen stabile, nicht-leere Tags sein (debconf Choices-C). Ein LEERER Wert ist erlaubt und heisst
# „nichts gewaehlt" (= Esc-Vertrag, in beiden Zweigen gleich): gum v0.17 liest stdin mit TrimSpace ueber die
# GANZE Eingabe -> eine letzte Zeile "label<TAB>" verloere ihr TAB ("invalid option format") -> der gum-Zweig
# reicht leere Werte intern als _UI_EMPTY_VALUE durch und entfernt sie danach wieder.
_UI_EMPTY_VALUE='__ui_empty__'
ui_choose() {
  local header="$1" multi="${2:-0}" pre="${3:-}" gum out="" options
  ui_interactive || return 0
  _ui_spin_stop   # ein laufender Spinner wuerde die Picker-TUI zerschiessen (Arbiter-Blocker 3)
  options="$(cat)"
  [ -n "$options" ] || return 0
  # Zeilen ohne TAB auf "label<TAB>value" normalisieren (label==value) — gum-Zweig UND Plain-
  # Fallback sehen dieselbe kanonische Form.
  options="$(printf '%s\n' "$options" | awk -F '\t' '{ if (index($0, "\t") == 0) print $0 "\t" $0; else print $0 }')"
  if gum="$(_ui_gum_bin)"; then
    local -a args=(choose --label-delimiter "$(printf '\t')" --header "$header")
    [ "$multi" = "1" ] && args+=(--no-limit)
    [ -n "$pre" ] && args+=(--selected "$pre")
    # ESC (gum exit 1 "nothing selected") = leer (der Aufrufer faellt auf seinen Bestandspfad zurueck);
    # Strg-C (130) = Abbruch des ganzen Befehls (ui_abort), wie in jedem anderen Terminal-Programm.
    local rc=0
    out="$(printf '%s\n' "$options" \
      | awk -v e="$_UI_EMPTY_VALUE" '{ if (substr($0, index($0, "\t") + 1) == "") print $0 e; else print $0 }' \
      | "$gum" "${args[@]}" 2>/dev/tty)" || rc=$?
    [ "$rc" -eq 130 ] && ui_abort
  else
    local -a labels=() values=()
    local label value
    while IFS=$'\t' read -r label value; do
      labels+=("$label"); values+=("$value")
    done <<<"$options"
    {
      printf '%s\n' "$header"
      local i
      for i in "${!labels[@]}"; do printf '  %2d) %s\n' "$((i + 1))" "${labels[$i]}"; done
      if [ "$multi" = "1" ]; then
        printf 'Nummer(n), Space/Komma-getrennt (leer = Abbruch): '
      else
        printf 'Nummer (leer = Abbruch): '
      fi
    } > /dev/tty
    local reply="" n
    read -r reply < /dev/tty || true
    reply="${reply//,/ }"
    for n in $reply; do
      case "$n" in *[!0-9]* | '') continue ;; esac
      [ "$n" -ge 1 ] && [ "$n" -le "${#values[@]}" ] || continue
      out="${out:+$out
}${values[$((n - 1))]}"
      [ "$multi" = "1" ] || break
    done
  fi
  # Leere Werte (Platzhalter bzw. leere Plain-Werte) fallen aus der Ausgabe -> beide Zweige liefern dasselbe.
  # awk statt grep -v: grep endet bei leerem Ergebnis mit 1 (set -e in der Kommandosubstitution).
  out="$(printf '%s\n' "$out" | awk -v e="$_UI_EMPTY_VALUE" '$0 != "" && $0 != e')"
  if [ -n "$out" ]; then
    printf '[*] Auswahl: %s\n' "$(printf '%s\n' "$out" | UI_CHOOSE_OPTS="$options" awk '
      BEGIN { n = split(ENVIRON["UI_CHOOSE_OPTS"], rows, "\n")
              for (r = 1; r <= n; r++) { i = index(rows[r], "\t"); v = substr(rows[r], i + 1)
                                         if (!(v in lab)) lab[v] = substr(rows[r], 1, i - 1) } }
      { printf "%s%s", (c++ ? ", " : ""), (($0 in lab) ? lab[$0] : $0) }')" > /dev/tty
    printf '%s\n' "$out"
  fi
  return 0
}

# --- Ruhige Ausgabe: Schritte + Logdatei (Install-UX-Phase 3) -----------------------------------
# Interaktiv (TTY) zeigt der Installer eine Zeile je Schritt (Spinner -> ✓/✗); die komplette
# technische Ausgabe (apt/dpkg, npm, psql, n8n-CLI, log/ok-Zeilen) landet in einer Logdatei. Bei
# einem Fehler zeigt er die letzten Log-Zeilen + den Pfad (clig.dev "print the logs on error").
# Muster: Coolify install.sh (`exec >>log 2>&1`, fd3 = Terminal, EXIT-Trap mit Log-Ende) + Proxmox
# community-scripts core.func (msg_info/msg_ok + Spinner, silent/verbose). Non-TTY/--unattended/
# --verbose: KEIN Quiet -> byte-identisch die bisherige Ausgabe (Haus-Regel Install-UX).
# UI_QUIET=1 heisst "Log aktiv, fd3 = Terminal" und wird NUR von ui_log_begin gesetzt; bewusst NICHT
# exportiert (runuser/`bash doctor.sh`-Kinder duerfen den Modus nicht erben, sie haben kein fd3).
UI_QUIET=0
UI_LOG_DIR="${UI_LOG_DIR:-/var/log/lifeagents}"
UI_LOG_FILE=''
_UI_STEP_TEXT=''
_UI_SPIN_PID=''
_UI_FAILED=0

# ui_quiet_wanted <verbose:0|1> -> 0 wenn der Quiet-Modus sinnvoll ist: interaktiv, TUI-faehiges
# Terminal (TERM != dumb, sonst wird der \r-Spinner zu Zeichenmuell), stderr ist ein TTY, kein --verbose.
ui_quiet_wanted() {
  [ "${1:-0}" = 1 ] && return 1
  if ui_interactive && _ui_term_capable && [ -t 2 ]; then return 0; fi
  return 1
}

# ui_log_begin <prefix> — Quiet-Modus scharf schalten: Logdatei anlegen (0600, Verzeichnis 0700, die
# letzten 5 behalten, Symlink <prefix>.log -> neueste), fd3 = bisheriges stderr (Terminal), stdout+
# stderr -> Log, stdin </dev/null (ein versteckter Tool-Prompt kann so nicht unsichtbar haengen — alle
# eigenen Prompts lesen explizit /dev/tty). Danach EXIT-/Signal-Trap fuer Spinner-Stopp + Fehlerbild.
ui_log_begin() {
  local prefix="${1:-install}" ts old_umask
  ts="$(date +%Y%m%d-%H%M%S)"
  old_umask="$(umask)"; umask 077
  mkdir -p "$UI_LOG_DIR"; chmod 0700 "$UI_LOG_DIR" 2>/dev/null || true
  UI_LOG_FILE="$UI_LOG_DIR/${prefix}-${ts}.log"
  install -m 0600 /dev/null "$UI_LOG_FILE"
  umask "$old_umask"
  ln -sfn "$(basename "$UI_LOG_FILE")" "$UI_LOG_DIR/${prefix}.log" 2>/dev/null || true
  # shellcheck disable=SC2012  # Dateinamen sind unsere eigenen <prefix>-<ts>.log (kein Sonderzeichen)
  ls -1t "$UI_LOG_DIR/${prefix}-"*.log 2>/dev/null | tail -n +6 | xargs -r rm -f --
  # Terminal-Farben retten (fd3), Log-Farben aus (kein ANSI im Logfile).
  _T_RST="$_C_RST"; _T_CYAN="$_C_CYAN"; _T_GREEN="$_C_GREEN"; _T_YELLOW="$_C_YELLOW"; _T_RED="$_C_RED"
  _C_RST=''; _C_CYAN=''; _C_GREEN=''; _C_YELLOW=''; _C_RED=''
  exec 3>&2
  exec >>"$UI_LOG_FILE" 2>&1
  exec 0</dev/null
  UI_QUIET=1
  trap '_ui_on_exit' EXIT
  trap '_ui_on_signal' INT TERM HUP
  printf '== lifeagents %s — %s ==\n' "$prefix" "$(date -Is)"
}

# _ui_spin_stop — laufenden Spinner beenden + Zeile leeren (idempotent; nie fatal).
_ui_spin_stop() {
  if [ -n "${_UI_SPIN_PID:-}" ]; then
    kill "$_UI_SPIN_PID" 2>/dev/null || true
    wait "$_UI_SPIN_PID" 2>/dev/null || true
    _UI_SPIN_PID=''
    { printf '\r\033[2K' >&3; } 2>/dev/null || true
  fi
  return 0
}

# _ui_term_note <text> — Hinweis-Zeile aufs Terminal (Quiet), ohne den Spinner zu zerreissen: Zeile
# leeren, Hinweis drucken; der Spinner zeichnet beim naechsten Frame in der Folgezeile weiter.
_ui_term_note() {
  { printf '\r\033[2K    %s!%s %s\n' "${_T_YELLOW:-}" "${_T_RST:-}" "$*" >&3; } 2>/dev/null || true
}

# _ui_spin_loop — der Spinner selbst (laeuft als Hintergrund-Subshell von ui_step).
_ui_spin_loop() {
  trap - EXIT INT TERM HUP
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0
  while :; do
    { printf '\r\033[2K  %s%s%s %s …' "${_T_CYAN:-}" "${frames[$i]}" "${_T_RST:-}" "$_UI_STEP_TEXT" >&3; } 2>/dev/null || exit 0
    i=$(( (i + 1) % ${#frames[@]} ))
    sleep 0.1
  done
}

# ui_step <text> [stage] — einen Schritt beginnen. Quiet: Spinner-Hintergrundprozess auf fd3 (reines printf;
# gum spin kann keine Shell-Funktionen mit geteiltem Zustand ausfuehren). Sonst: Sektions-Banner wie
# bisher (ui_section) — die volle Ausgabe darunter bleibt gegliedert lesbar (Substrat/CI/--verbose).
# stage = fester Schritt-Code fuer die Ergebnis-Datei (Fehler-Hilfe im Chat nennt den Schritt; Codes = Keys
# core.update.stage.<code>, gemappt in core.fn_update_report). Ohne stage bleibt der vorige Code stehen.
ui_step() {
  _ui_spin_stop
  if [ -n "${2:-}" ]; then result_set stage "$2"; fi
  _UI_STEP_TEXT="$1"
  if [ "${UI_QUIET:-0}" != 1 ]; then ui_section "$1"; return 0; fi
  printf '\n== %s ==\n' "$1"   # Marker im Log
  _ui_spin_loop &
  _UI_SPIN_PID=$!
  return 0
}

# ui_step_done [detail] — laufenden Schritt als erledigt markieren (✓ text (detail)).
ui_step_done() {
  local detail="${1:-}" text="$_UI_STEP_TEXT"
  _ui_spin_stop
  _UI_STEP_TEXT=''
  ok "${text}${detail:+ (${detail})}"
  if [ "${UI_QUIET:-0}" = 1 ]; then
    { printf '  %s✓%s %s%s\n' "${_T_GREEN:-}" "${_T_RST:-}" "$text" "${detail:+ ($detail)}" >&3; } 2>/dev/null || true
  fi
  return 0
}

# ui_step_fail [hinweis] — laufenden Schritt als gescheitert markieren: ✗ + letzte 25 Log-Zeilen +
# Log-Pfad (Quiet). Ein Paket-Fehler ist NICHT fatal fuer den Lauf — der Aufrufer entscheidet.
ui_step_fail() {
  local hint="${1:-}" text="${_UI_STEP_TEXT:-Installation}"
  _ui_spin_stop
  _UI_STEP_TEXT=''
  if [ "${UI_QUIET:-0}" != 1 ]; then warn "${text} fehlgeschlagen${hint:+ — ${hint}}"; return 0; fi
  printf '[x] %s fehlgeschlagen%s\n' "$text" "${hint:+ — $hint}"
  {
    printf '  %s✗%s %s%s\n' "${_T_RED:-}" "${_T_RST:-}" "$text" "${hint:+ — $hint}"
    printf '\n    Letzte Zeilen aus dem Protokoll:\n'
    tail -n 25 "$UI_LOG_FILE" 2>/dev/null | sed 's/^/    │ /'
    printf '\n    Vollständiges Protokoll: %s\n\n' "$UI_LOG_FILE"
  } >&3 2>/dev/null || true
  _UI_FAILED=1
  return 0
}

# EXIT-Trap (nur Quiet): ein unerwarteter Abbruch (set -e/die) zeigt den gerade laufenden Schritt als
# ✗ + Log-Ende. Ersetzt im Quiet-Modus die Sichtbarkeit des ERR-Traps aus provision.sh (der nur in
# der Top-Ebene greift und ohnehin ins Log schreibt).
_ui_on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "${_UI_FAILED:-0}" != 1 ]; then
    [ -n "${_UI_STEP_TEXT:-}" ] || _UI_STEP_TEXT='Installation'
    ui_step_fail "abgebrochen (Exit $rc)"
  else
    _ui_spin_stop
  fi
  return "$rc"
}
_ui_on_signal() {
  _ui_spin_stop
  { printf '\n  Abgebrochen. Protokoll: %s\n' "$UI_LOG_FILE" >&3; } 2>/dev/null || true
  _UI_FAILED=1
  exit 130
}

# ui_wait_key <sekunden> — EINE Taste mit Timeout lesen (Warteschleifen, z. B. Pairing). Ergebnis in
# der globalen UI_KEY (NICHT per $(...): eine Subshell bekaeme Strg-C parallel zur Haupt-Shell).
# Rueckgabe: 0 = Taste (UI_KEY; Enter = Zeilenumbruch), 1 = Timeout/kein TTY, 2 = Strg-C.
# `-d ''`: Enter wird als Zeichen gelesen statt als leerer Timeout (Homebrew getc/wait_for_user);
# stty wird gesichert + zurueckgesetzt, Strg-C ist hier ein normales "spaeter", kein Abbruch des Laufs.
UI_KEY=''
_UI_KEY_INT=0
# shellcheck disable=SC2034  # UI_KEY liest der Aufrufer (owner_connect.sh) — Rueckgabekanal per Global
ui_wait_key() {
  local t="${1:-1}" rc=0 old_int stty_save=''
  UI_KEY=''
  if ! ui_interactive; then sleep "$t"; return 1; fi
  _ui_spin_stop
  stty_save="$(stty -g </dev/tty 2>/dev/null || true)"
  old_int="$(trap -p INT)"
  _UI_KEY_INT=0
  trap '_UI_KEY_INT=1' INT
  IFS= read -rsn1 -t "$t" -d '' UI_KEY </dev/tty || rc=$?
  if [ -n "$old_int" ]; then eval "$old_int"; else trap - INT; fi
  if [ -n "$stty_save" ]; then stty "$stty_save" </dev/tty 2>/dev/null || true; fi
  if [ "$_UI_KEY_INT" = 1 ]; then UI_KEY=''; return 2; fi
  if [ "$rc" -ne 0 ]; then UI_KEY=''; return 1; fi
  return 0
}

# --- HTTP mit Secrets: nie im argv ---------------------------------------------------------------
# curl_cfg <key> <value> -> eine curl-Config-Zeile (`key = "value"`, \ und " escaped). Fuer curl_secret.
curl_cfg() {
  local v="$2"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
  printf '%s = "%s"\n' "$1" "$v"
}
# curl_secret [curl-args...] — curl mit der Config von STDIN (`-K -`): URL mit Token, Header mit Keys
# und Request-Bodies mit Passwoertern stehen so NIE in der Prozessliste (/proc/<pid>/cmdline ist fuer
# jeden lokalen Nutzer lesbar). Aufrufer: `{ curl_cfg url "…"; curl_cfg header "…"; } | curl_secret -fsS`.
# Muster: release_inputs._http_status_secret (600-Config-Datei) — hier ohne Temp-Datei via stdin.
curl_secret() { curl -K - "$@"; }

# --- n8n-Gesundheit ------------------------------------------------------------------------------
# wait_n8n_health [versuche] — /healthz/readiness pollen (2 s Takt, Default 60 Versuche = 2 Min). 0 = bereit.
# Readiness statt /healthz: /healthz meldet schon, wenn der Prozess lauscht; /healthz/readiness erst, wenn die
# DB verbunden UND migriert ist (n8n-Doku hosting/logging-monitoring/monitoring) — nach einem Versionssprung
# laufen die Migrationen minutenlang, REST-Aufrufe davor scheitern. Ein Helfer fuer alle Warteschleifen
# (install_n8n, bootstrap_owner, deploy_workflows, pkg_teardown). URL-Fallback fuer install_n8n (laeuft vor N8N_URL).
wait_n8n_health() {
  local n="${1:-60}" url="${N8N_URL:-http://127.0.0.1:${N8N_PORT:-5678}}" _
  for _ in $(seq 1 "$n"); do
    curl -fsS --max-time 3 -o /dev/null "${url}/healthz/readiness" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

# --- Sicherungs-Verschluesselung (EINE Adresse: `lifeagents backup` + Upgrade-Sicherung) -----------------------
# Schluessel = core.backup_key('backup_encryption_key') — der Installer setzt ihn out-of-band
# (bootstrap_owner _ensure_backup_secret), nie rotiert. gpg --symmetric AES256; die Passphrase laeuft ueber fd 3
# (nie argv), damit stdin fuer den Klartext frei bleibt (Upgrade-Sicherung streamt pg_dump direkt hinein ->
# kein Klartext-Dump auf der Platte).
BACKUP_KEY_NAME="backup_encryption_key"
# backup_key_read [tabelle] -> Schluessel auf stdout (leer, wenn keiner gesetzt; rc!=0, wenn die Tabelle fehlt).
#   Tabelle Standard core.backup_key; upgrade_guard.sh liest auf v0.1.0-Bestand auch core.secret (vor core:V006).
#   Reads globals: N8N_DB_NAME, DB_SUPERUSER.
backup_key_read() {
  local tab="${1:-core.backup_key}"
  case "$tab" in core.backup_key|core.secret) ;; *) return 1 ;; esac   # fester Satz -> kein SQL-Einschleusen
  runuser -u "${DB_SUPERUSER:-postgres}" -- psql -v ON_ERROR_STOP=1 -X -tA -d "${N8N_DB_NAME:-n8n}" \
    -c "SELECT value FROM ${tab} WHERE key = '${BACKUP_KEY_NAME}'"
}
# gpg_sym_encrypt <key> <out> [in] — <in> fehlt oder '-' = stdin.
gpg_sym_encrypt() {
  local key="$1" out="$2" in="${3:--}"
  gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 \
    -o "$out" "$in" 3< <(printf '%s' "$key")
}
# gpg_sym_decrypt <key> <in> -> Klartext auf stdout (gpg-Meldungen verworfen; rc!=0 = falscher Schluessel/kaputt).
gpg_sym_decrypt() {
  local key="$1" in="$2"
  gpg --batch --pinentry-mode loopback --passphrase-fd 3 -d "$in" 3< <(printf '%s' "$key") 2>/dev/null
}
# n8n_api_curl <api-key> <url> [curl-args...] — REST-Call gegen n8n mit X-N8N-API-KEY im curl-Config-
# Kanal (stdin) statt im argv. Ersetzt das bisherige `curl … -H "X-N8N-API-KEY: $KEY"`-Muster.
n8n_api_curl() {
  local key="$1" url="$2"; shift 2
  { curl_cfg url "$url"; curl_cfg header "X-N8N-API-KEY: ${key}"; } | curl_secret "$@"
}
# n8n_set_published <publish|unpublish> <id> [curl-args...] — DER Veroeffentlichen-/Abmelden-Aufruf (Public API seit
#   n8n 2.33; /activate + /deactivate sind veraltet und fallen mit n8n 3 weg). Body {} + Content-Type sind Pflicht
#   (sonst 415). Fehler-/Ausgabe-Modus (-fsS -o … -w …) waehlt der Aufrufer.
n8n_set_published() {
  local action="$1" id="$2"; shift 2
  n8n_api_curl "$N8N_API_KEY" "$N8N_URL/api/v1/workflows/$id/$action" -X POST \
    -H 'Content-Type: application/json' --data '{}' "$@"
}
# n8n_delete_workflow <id> — REST-DELETE eines Workflows; 0 = geloescht ODER schon weg (404), 1 = Fehler
# (Netz/Auth/5xx). Der HTTP-Code wird ausgewertet (-fsS allein machte 404 und einen Auth-Fehler ununter-
# scheidbar). Geteilt von pkg_teardown (Paket-Uninstall) und deploy_workflows (retire_workflows).
n8n_delete_workflow() {
  local code body i
  # Seit n8n 2.4x lehnt DELETE einen veroeffentlichten Workflow ab (409 "Unpublish it before deleting", Substrat-
  # Upgrade-Test 2026-10-20) -> erst unpublish (meldet im n8n-Prozess auch den Ausloeser ab); best effort: schon
  # unveroeffentlicht/weg (404) ist kein Fehler, das DELETE danach entscheidet.
  n8n_set_published unpublish "$1" -sS -o /dev/null 2>/dev/null || true
  # 2.44.4: unpublish antwortet 200, bevor die Abmeldung fertig ist -> DELETE kurz danach = 409 "Workflow is still
  # being unpublished. Please try again in a few moments." (genericity-CI, zufaellig je Workflow) -> 409 bis ~30 s
  # wiederholen; jeder andere Code entscheidet sofort.
  body="$(mktemp)"
  for i in $(seq 1 30); do
    code="$(n8n_api_curl "$N8N_API_KEY" "$N8N_URL/api/v1/workflows/$1" -sS -o "$body" -w '%{http_code}' -X DELETE 2>/dev/null || true)"
    [ "$code" = 409 ] && [ "$i" -lt 30 ] || break
    sleep 1
  done
  case "$code" in 200|204|404) rm -f "$body"; return 0 ;; esac
  warn "Workflow $1: DELETE HTTP ${code:-?} $(head -c 200 "$body" 2>/dev/null)"
  rm -f "$body"
  return 1
}
# n8n_list_credentials — ALLE n8n-Credentials als 'id<TAB>name<TAB>type'-Zeilen (cursor-paginiert); rc 1 bei
# GET-Fehler (der Aufrufer entscheidet: warn+skip bzw. fail-closed). EINE Paginierung fuer pkg_teardown (Uninstall),
# deploy_workflows (retire_credentials) und inject_credentials::_list_existing_creds (wandelt nur in JSON).
n8n_list_credentials() {
  local url="$N8N_URL/api/v1/credentials?limit=250" resp cursor
  while :; do
    resp="$(n8n_api_curl "$N8N_API_KEY" "$url" -fsS -H 'accept: application/json' 2>/dev/null)" || return 1
    jq -r '(.data // [])[] | [.id, .name, .type] | @tsv' <<<"$resp" 2>/dev/null || true
    cursor="$(jq -r '.nextCursor // empty' <<<"$resp" 2>/dev/null || true)"
    [ -n "$cursor" ] || break
    url="$N8N_URL/api/v1/credentials?limit=250&cursor=$cursor"
  done
}
# n8n_delete_credential <id> — REST-DELETE einer Credential; 0 = geloescht ODER schon weg (404), 1 = Fehler
# (Muster n8n_delete_workflow).
n8n_delete_credential() {
  local code
  code="$(n8n_api_curl "$N8N_API_KEY" "$N8N_URL/api/v1/credentials/$1" -sS -o /dev/null -w '%{http_code}' -X DELETE 2>/dev/null || true)"
  case "$code" in 200|204|404) return 0 ;; *) return 1 ;; esac
}
# tg_api_curl <bot-token> <methode> [curl-args...] — Telegram-Bot-API-Call; der Token steckt in der URL
# und geht darum ebenfalls nur ueber den Config-Kanal. LIFEAGENTS_TELEGRAM_API (nur Test-Substrat:
# scripts/dev/bot_menu_test.ps1 zeigt ihn auf den Mock-Telegram im selben Container) ersetzt die Basis-URL;
# Default = die echte Bot-API.
tg_api_curl() {
  local token="$1" method="$2"; shift 2
  curl_cfg url "${LIFEAGENTS_TELEGRAM_API:-https://api.telegram.org}/bot${token}/${method}" | curl_secret "$@"
}

# _ingress_uuid <key> <seed> -> UUID (Version-4-Form), deterministisch je Instanz aus sha256(key:seed). Fuer die
#   telegramTrigger-ids (s. deploy_workflows): stabil ueber Deploys (Fingerprint/Only-changed), aber ohne den
#   Instanz-Schluessel nicht aus dem oeffentlichen Repo ableitbar. printf ist ein Builtin -> der Schluessel steht in
#   keiner Prozess-Argumentliste.
_ingress_uuid() {
  local h; h="$(printf '%s:%s' "$1" "$2" | sha256sum | cut -c1-32)"
  printf '%s-%s-4%s-%x%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" $(( (16#${h:16:1} & 3) | 8 )) "${h:17:3}" "${h:20:12}"
}

# _app_path -> Pfad der Mini-App „Übersicht“ unter /webhook/ (docs/package-contract.md §3.12), je Instanz aus
#   INGRESS_ID_KEY abgeleitet wie die Telegram-Eingangs-ids: das Repo nennt nur den Platzhalter __APP_PATH__, die echte
#   Adresse kennt nur diese Instanz (Verteidigung in der Tiefe; den Zugriff schuetzt die initData-Pruefung in der DB).
#   Leer, wenn der Schluessel fehlt. EINE Adresse fuer den Workflow-Patch und den Menue-Knopf.
_app_path() {
  local k; k="$(read_env_value "${N8N_OWNER_ENV_FILE:-/etc/lifeagents/core.env}" INGRESS_ID_KEY || true)"
  [ -n "$k" ] || return 0
  printf 'app-%s' "$(_ingress_uuid "$k" app_path)"
}

# --- Paket-Baum + Textkatalog (docs/package-contract.md §3.11) ----------------------------------------------
# _pkg_dir -> Paket-Quelle: der gespiegelte Runtime-Baum (`/usr/local/lib/lifeagents/packages/<pkg>/…`) bzw. im
# Dev der Repo-Baum. v1 = lokaler Baum (D13); kuenftige Per-Paket-Release-Quellen abstrahiert der `pkg_source`-
# Resolver (BACKLOG).
_pkg_dir() {
  if [ -n "${LIFEAGENTS_LIB:-}" ] && [ -d "${LIFEAGENTS_LIB}/packages" ]; then
    printf '%s' "${LIFEAGENTS_LIB}/packages"
  elif [ -n "${REPO_ROOT:-}" ] && [ -d "${REPO_ROOT}/packages" ]; then
    printf '%s' "${REPO_ROOT}/packages"
  else
    printf '%s' "${LIFEAGENTS_LIB:-/usr/local/lib/lifeagents}/packages"
  fi
}
# pkg_text <pkg> <key-suffix> [<lang>] -> Text des Katalog-Keys <pkg>.<key-suffix> aus packages/<pkg>/locales/<lang>.json
#   (Default de = Sprache der Konsole/des Installers; fehlt der Key -> en -> leer). Die Dateien sind die Wahrheit (der
#   Seed spiegelt sie nach core.ui_texts); der Host liest sie direkt wie die Manifeste — auch ohne DB. Immer rc 0.
pkg_text() {
  local pkg="$1" key="$1.$2" lang="${3:-de}" l f v
  command -v jq >/dev/null 2>&1 || return 0
  for l in "$lang" en; do
    f="$(_pkg_dir)/$pkg/locales/$l.json"
    [ -r "$f" ] || continue
    v="$(jq -r --arg k "$key" '.[$k] // empty' "$f" 2>/dev/null || true)"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 0
}
# pkg_display_name <pkg> [<lang>] -> Anzeigename (<pkg>.package.name), Fallback die Paket-id. Immer rc 0.
pkg_display_name() {
  local n; n="$(pkg_text "$1" package.name "${2:-de}")"
  printf '%s' "${n:-$1}"
}

# --- Owner per Telegram erreichen (best-effort; Backup-Off-Site + "Update wartet") -----------------
# owner_tg_token -> Bot-Token auf stdout (Prozess-Env, sonst core.env), leer = keins. Immer rc 0 (set -e-sicher in $(…)).
owner_tg_token() {
  local t="${TELEGRAM_BOT_TOKEN:-}"
  [ -n "$t" ] || t="$(read_env_value "$(lifeagents_env_file core)" TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
  printf '%s' "$t"
  return 0
}
# owner_tg_chat_id -> die gepairte Owner-chat_id auf stdout, leer = unbekannt/ungepairt. Braucht _resolve_owner_chat_id
#   (deploy_workflows.sh) + N8N_DB_NAME. Immer rc 0.
owner_tg_chat_id() {
  local c=''
  if declare -F _resolve_owner_chat_id >/dev/null; then c="$(_resolve_owner_chat_id 2>/dev/null || true)"; fi
  case "$c" in '' | 0 | *[!0-9]*) c='' ;; esac
  printf '%s' "$c"
  return 0
}
# notify_owner_telegram <text> — Klartext (ohne parse_mode, kein Escaping noetig) an den gepairten Owner. 0 = gesendet,
#   1 = nicht moeglich (kein curl/Token, Owner ungepairt, Netz). Token nie im argv (tg_api_curl). Aufrufer: `|| true`.
notify_owner_telegram() {
  local token chat
  need_cmd curl || return 1
  token="$(owner_tg_token)"; chat="$(owner_tg_chat_id)"
  [ -n "$token" ] && [ -n "$chat" ] || return 1
  tg_api_curl "$token" sendMessage -fsS --max-time 20 -o /dev/null \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=$1" >/dev/null 2>&1
}

# note <text> — ERWARTBARER Hinweis (bewusst uebersprungener Schluessel, noch nicht gepairter Owner):
# ohne Quiet wie warn; im Quiet-Modus nur ins Log — der End-Recap fasst diese Faelle zusammen, statt
# dass sie den ruhigen Lauf zwischen den ✓-Zeilen unterbrechen.
note() {
  if [ "${UI_QUIET:-0}" = 1 ]; then log "$*"; else warn "$*"; fi
  return 0
}

# ui_step_bad <hinweis> — Schritt ohne Erfolg beenden, ABER ohne Log-Auszug (erwartbarer Zustand wie
# "Domain noch nicht erreichbar" — kein Programmfehler): ✗ text — hinweis.
ui_step_bad() {
  local hint="${1:-}" text="$_UI_STEP_TEXT"
  _ui_spin_stop
  _UI_STEP_TEXT=''
  if [ "${UI_QUIET:-0}" != 1 ]; then warn "${text}${hint:+ — ${hint}}"; return 0; fi
  log "${text}${hint:+ — ${hint}}"
  { printf '  %s✗%s %s%s\n' "${_T_RED:-}" "${_T_RST:-}" "$text" "${hint:+ — $hint}" >&3; } 2>/dev/null || true
  return 0
}

# ui_fd — die Ziel-fd fuer eigene Terminal-Ausgaben (3 im Quiet-Modus, sonst 2/stderr).
ui_fd() { if [ "${UI_QUIET:-0}" = 1 ]; then printf '3'; else printf '2'; fi; }

# --- Erreichbarkeit (geteilt von doctor.sh + owner_connect.sh) ------------------------------------
# https_code <domain> -> HTTP-Status von https://<domain>/ (000 = keine TLS-Verbindung). JEDE Antwort
# (auch 404 = gesunder webhook-only-Zustand) heisst "TLS-Endpunkt + Reverse Proxy antworten".
https_code() {
  # curl schreibt bei Verbindungsfehler SELBST '000' (-w) UND endet != 0 -> ein `|| printf 000` ergaebe '000000'.
  local code; code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "https://$1/" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

# --- Internet-Adresse (Domain): EINE Regel fuer alle Eingabewege ----------------------------------------------------
# normalize_domain <eingabe> -> die Adresse, wie Installer, core.env und n8n sie fuehren: Rand-Leerzeichen, Gross-
#   schreibung, http(s)://, Pfad/Query/Fragment, Schluss-Slash, :443 und Schluss-Punkt weg (eingefuegt wird oft die
#   ganze URL aus dem Browser). Ein anderer Port bleibt stehen -> domain_problem meldet ihn. Ein Leerzeichen innen
#   bleibt stehen (ungueltig, kein stilles Zusammenziehen).
normalize_domain() {
  local d="$1"
  d="${d#"${d%%[![:space:]]*}"}"; d="${d%"${d##*[![:space:]]}"}"
  d="${d,,}"
  d="${d#http://}"; d="${d#https://}"
  d="${d%%/*}"; d="${d%%\?*}"; d="${d%%#*}"
  d="${d%:443}"; d="${d%.}"
  printf '%s' "$d"
}

# domain_problem <domain> -> leer = gueltig, sonst der Grund im Klartext (EINE Quelle fuer _validate_domain, die Meldung
#   im Prompt und den Abbruch bei vorgegebener DOMAIN). Erwartet einen normalisierten Wert. Immer rc 0.
domain_problem() {
  case "$1" in
    *:*) printf 'Port %s wird nicht unterstützt — die Adresse muss über Port 443 (HTTPS) erreichbar sein; bitte ohne Port eintragen (z. B. bot.example.org)' "${1##*:}"; return 0 ;;
  esac
  printf '%s' "$1" | grep -qiE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
    || printf 'kein gültiger Name (erwartet z. B. bot.example.org)'
  return 0
}

# is_router_myfritz_name <domain> -> 0, wenn das die MyFRITZ!-Adresse der FritzBox SELBST ist (<kennung>.myfritz.net);
#   die Adresse einer MyFRITZ!-Freigabe fuer ein Geraet hat ein Label mehr (<geraet>.<kennung>.myfritz.net). Ohne Netz:
#   erkennt die IPv6-Falle (AAAA = die Box) auch, wenn der Server selbst keinen IPv6-Weg hat.
is_router_myfritz_name() { printf '%s' "$1" | grep -qiE '^[^.]+\.myfritz\.net$'; }

# --- Erreichbarkeit fuer Handy und Laptop (geteilt von doctor.sh + owner_connect.sh) ------------------------------
# Telegram stellt nur ueber IPv4 zu; Handy und Laptop oeffnen Seiten unter der Domain direkt und nehmen oft IPv6. Ein
# falscher AAAA-Eintrag (MyFRITZ!-Adresse der Box = die Box selbst) faellt deshalb im Chat nie auf. Gemessen wird das
# Ergebnis, nicht die IP (der Proxy kann auf einem anderen Rechner laufen): je Adressfamilie dieselbe Anfrage ueber
# die Domain (--resolve auf die DNS-Adresse) und direkt an dieses n8n, Status + Body muessen gleich sein. Nie
# blockierend (arch-challenge 2026-10-28: Mailcow-Muster statt der harten Sperre von Nextcloud AIO).

# dns_first_addr <host> <4|6> -> erste Adresse der Familie aus dem DNS, an /etc/hosts VORBEI (node/c-ares): der Pin aus
#   hitl_chat_reachable zeigt die Domain auf dem Server auf den Proxy und verdeckte sonst genau den Weg der Geraete.
dns_first_addr() {
  need_cmd node || return 0
  node -e 'require("dns").promises["resolve"+process.argv[2]](process.argv[1]).then(a=>{if(a.length)console.log(a[0])},()=>{})' \
    "$1" "$2" 2>/dev/null || true
}

# url_host <url> / url_port <url> -> Host bzw. Port von scheme://host[:port]/… (Port: der angegebene, sonst https 443,
#   http 80). EINE Stelle fuer alle Probes (--resolve braucht beides).
url_host() { local h="${1#*://}"; h="${h%%/*}"; printf '%s' "${h%%:*}"; }
url_port() {
  local h="${1#*://}"; h="${h%%/*}"
  case "$h" in *:*) printf '%s' "${h##*:}" ;; *) case "$1" in https://*) printf 443 ;; *) printf 80 ;; esac ;; esac
}

# http_fp <url> [curl-args...] -> "<status>|<sha256 des Body>|<1 = FRITZ!Box-Seite, sonst 0>|<curl-rc>" — der EINE
#   Fingerabdruck fuer „ist die Anfrage bei DIESEM n8n gelandet?“ (Geraete-Check, Bestaetigungs-Route): dieselbe Anfrage
#   direkt an n8n und ueber die Domain, die ersten beiden Felder muessen gleich sein. Die URL geht nur ueber die
#   curl-Config auf stdin, nie ins argv (der App-Pfad ist je Instanz geheim, provisioning/CLAUDE.md).
http_fp() {
  local url="$1" out rc=0 code body; shift
  out="$(curl_cfg url "$url" | curl_secret -sS --connect-timeout 3 --max-time 8 -w '\n%{http_code}' "$@" 2>/dev/null)" || rc=$?
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  printf '%s|%s|%s|%s' "${code:-000}" "$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)" \
    "$(case "$body" in *'FRITZ!Box'*) echo 1 ;; *) echo 0 ;; esac)" "$rc"
}

# reach_probe_ip <base> <path> <ip> -> ok | fritz | cert | down | other:<status> | nolocal. <base> = http(s)://host[:port]
#   (Port aus dem Schema, sonst der angegebene), <path> beginnt mit /. Vergleich mit derselben Anfrage an dieses n8n
#   (${N8N_URL}, sonst 127.0.0.1:N8N_PORT). cert NUR bei curl-rc 60 (falscher Name, abgelaufen und selbstsigniert enden
#   alle so; 51 gibt es seit curl 7.62 nicht mehr). nolocal = das lokale n8n antwortet selbst nicht (kein Befund).
reach_probe_ip() {
  local base="${1%/}" path="$2" ip="$3" host port ref res
  host="$(url_host "$base")"; port="$(url_port "$base")"
  case "$ip" in *:*) ip="[${ip}]" ;; esac
  ref="$(http_fp "${N8N_URL:-http://127.0.0.1:${N8N_PORT:-5678}}${path}")"
  case "$ref" in 000\|*) printf 'nolocal'; return 0 ;; esac
  res="$(http_fp "${base}${path}" --resolve "${host}:${port}:${ip}")"
  if [ "${res%|*|*}" = "${ref%|*|*}" ]; then printf 'ok'
  elif [ "${res##*|}" = 60 ]; then printf 'cert'
  else
    case "$res" in
      *\|1\|*) printf 'fritz' ;;
      000\|*)  printf 'down' ;;
      *)       printf 'other:%s' "${res%%|*}" ;;
    esac
  fi
  return 0
}

# reach_family <base> <path> <4|6> -> nodns | noaddr | noroute | <reach_probe_ip-Ergebnis>. nodns = node fehlt fuer die
#   DNS-Abfrage am Pin vorbei; noroute = der Server hat keinen IPv6-Weg (dann ist IPv6 von hier nicht pruefbar).
reach_family() {
  local base="${1%/}" path="$2" fam="$3" host addr
  need_cmd node || { printf 'nodns'; return 0; }
  host="$(url_host "$base")"
  addr="$(dns_first_addr "$host" "$fam")"
  [ -n "$addr" ] || { printf 'noaddr'; return 0; }
  if [ "$fam" = 6 ] && [ -z "$(ip -6 route show default 2>/dev/null || true)" ]; then printf 'noroute'; return 0; fi
  reach_probe_ip "$base" "$path" "$addr"
}

# Die Handgriffe (EINE Quelle fuer doctor + Installer; Schritt fuer Schritt: Doku-Seite „FritzBox einrichten“).
REACH_HINT_FRITZ='Die Adresse zeigt über IPv6 auf die FRITZ!Box selbst — Handy und Laptop öffnen dann zufällig eine FritzBox-Seite statt deines Servers. Abhilfe: beim Rechner mit dem Reverse Proxy eine MyFRITZ!-Freigabe „HTTPS-Server“ anlegen (Internet → Freigaben → Portfreigaben → Stift beim Gerät → Neue Freigabe → MyFRITZ!-Freigabe) und dessen eigene MyFRITZ!-Adresse (<gerät>.<kennung>.myfritz.net) als Internet-Adresse nehmen: lifeagents reconfigure core. Schritt für Schritt: Doku „FritzBox einrichten“.'
REACH_HINT_CERT='Das Zertifikat passt nicht zur Adresse oder ist ungültig — der Reverse Proxy braucht ein gültiges Zertifikat für genau diesen Namen (Caddy holt es selbst; dafür muss Port 80 freigegeben bleiben).'
REACH_HINT_V6='Über IPv6 antwortet unter dieser Adresse nicht dein Reverse Proxy — der IPv6-Eintrag (AAAA) der Adresse muss auf den Proxy-Rechner zeigen oder ganz fehlen (FritzBox: Doku „FritzBox einrichten“).'
REACH_HINT_V4='Über IPv4 antwortet unter dieser Adresse nicht dein Reverse Proxy — DNS-Eintrag (A) und die Weiterleitung von Port 443 auf den Proxy-Rechner prüfen.'

# reach_assess <r4> <r6> <telegram_ok 0|1> <host> — Ergebnis je Familie (reach_family) in Zeilen + EINEN Handgriff
#   uebersetzen. Setzt REACH_LINES ("ok|bad|info<TAB>Text" je Zeile), REACH_HINT (leer = nichts zu tun) und REACH_BAD (0/1).
#   Regeln: das Zertifikat zaehlt aus IPv4 (rc 60 nur ueber IPv6 = IPv6 landet woanders); IPv4 scheitert vom Server aus
#   (auch mit rc 60: dann antwortet z. B. die Router-Oberflaeche mit eigenem Zertifikat), obwohl Telegram an genau diese
#   Adresse zustellt (telegram_ok = tg_webhook_delivers, Telegram verlangt ein gueltiges Zertifikat) = Hairpin-NAT
#   (neutral); Server ohne IPv6 + Box-Name = die Falle trotzdem. Prioritaet des Handgriffs: FritzBox > Zertifikat > IPv6 > IPv4.
# shellcheck disable=SC2034  # REACH_* lesen die Aufrufer (doctor.sh _doctor_app_check, owner_connect.sh _oc_device_check)
REACH_LINES=''; REACH_HINT=''; REACH_BAD=0
# shellcheck disable=SC2034  # s. o.
reach_assess() {
  local r4="$1" r6="$2" tg="$3" host="$4" l4 l6 h=''
  REACH_BAD=0
  case "$r4" in
    ok)      l4="ok	Über IPv4 antwortet dein Reverse Proxy" ;;
    noaddr)  l4="bad	Die Adresse hat keine IPv4 (A-Eintrag fehlt)"; h="$REACH_HINT_V4" ;;
    nodns|nolocal) l4="info	Über IPv4 hier nicht prüfbar" ;;
    *)
      if [ "$tg" = 1 ]; then l4="info	Über IPv4 vom Server aus nicht prüfbar (Heimnetz-Umweg des Routers) — Telegram kommt an, das genügt"
      elif [ "$r4" = cert ]; then l4="bad	Zertifikat ungültig"; h="$REACH_HINT_CERT"
      else l4="bad	Über IPv4 antwortet nicht dein Reverse Proxy"; h="$REACH_HINT_V4"; fi ;;
  esac
  case "$r6" in
    ok)      l6="ok	Über IPv6 antwortet dein Reverse Proxy" ;;
    noaddr)  l6="ok	Kein IPv6-Eintrag (in Ordnung: alle Geräte nehmen IPv4)" ;;
    fritz)   l6="bad	Über IPv6 antwortet die FRITZ!Box statt deines Servers"; h="$REACH_HINT_FRITZ" ;;
    noroute)
      if is_router_myfritz_name "$host"; then l6="bad	Die Adresse ist die MyFRITZ!-Adresse der FRITZ!Box selbst (über IPv6 landen Geräte bei der Box)"; h="$REACH_HINT_FRITZ"
      else l6="info	Über IPv6 nicht prüfbar (dieser Server hat keinen IPv6-Weg)"; fi ;;
    nodns|nolocal) l6="info	Über IPv6 hier nicht prüfbar" ;;
    *)
      l6="bad	Über IPv6 antwortet nicht dein Reverse Proxy"
      case "$h" in "$REACH_HINT_FRITZ"|"$REACH_HINT_CERT") : ;; *) h="$REACH_HINT_V6" ;; esac ;;
  esac
  REACH_LINES="${l4}"$'\n'"${l6}"
  REACH_HINT="$h"
  case "$l4" in bad*) REACH_BAD=1 ;; esac
  case "$l6" in bad*) REACH_BAD=1 ;; esac
  return 0
}

# tg_webhook_delivers <getWebhookInfo-JSON> <domain> -> 0, wenn Telegram nachweislich an https://<domain>/ zustellt:
#   gueltige Antwort, Webhook zeigt auf genau diese Adresse, kein Stau mit frischem Zustellfehler (< 15 Min; dieselbe
#   Regel wie doctor (3) ROT). Eine Adresse fuer doctor + Installer (telegram_ok von reach_assess). Braucht jq.
tg_webhook_delivers() {
  local url pending errd
  [ "$(printf '%s' "$1" | jq -r '.ok // false' 2>/dev/null || echo false)" = "true" ] || return 1
  url="$(printf '%s' "$1" | jq -r '.result.url // ""' 2>/dev/null || true)"
  [ -n "$2" ] && [ "${url#"https://${2}/"}" != "$url" ] || return 1
  pending="$(printf '%s' "$1" | jq -r '.result.pending_update_count // 0' 2>/dev/null || echo 0)"
  errd="$(printf '%s' "$1" | jq -r '.result.last_error_date // 0' 2>/dev/null || echo 0)"
  if [ "${pending:-0}" -gt 0 ] 2>/dev/null && [ $(( $(date +%s) - ${errd:-0} )) -lt 900 ] 2>/dev/null; then return 1; fi
  return 0
}

# --- Bestaetigen im Chat: Selbst-Erreichbarkeit (geteilt von deploy_workflows.sh + doctor.sh) -------------------
# Ein Tipp auf einen Bestaetigungs-Knopf kommt von Telegram beim Orchestrator-Trigger an; der POSTet ihn an
# <WEBHOOK_URL>/webhook-waiting-telegram weiter (n8n TelegramTrigger hitlForwardUrl, best-effort: ein Fehlschlag
# verschluckt den Tipp still). Diese Weiterleitung laeuft VOM SERVER SELBST ueber die oeffentliche Domain -> im
# Heimnetz droht Hairpin-NAT bzw. der IPv6-Abzweig zur FritzBox (MyFRITZ!-AAAA = die Box selbst).
HITL_ROUTE_SUFFIX='/webhook-waiting-telegram'

# hitl_route_probe <webhook-url> [<ip>] -> rc0, wenn ein leerer Callback-POST an <webhook-url>/webhook-waiting-telegram
#   (ueber DNS bzw. per --resolve auf <ip>) denselben Fingerabdruck (http_fp: Status + Body) liefert wie derselbe POST
#   direkt an dieses n8n = die Anfrage ist bei DIESEM n8n gelandet (n8n antwortet ohne gueltigen Callback deterministisch
#   und ohne Seiteneffekt). Vergleich statt fester Statuscode: FritzBox/Home Assistant/Proxy antworten auch 403/404.
hitl_route_probe() {
  local base="${1%/}" ip="${2:-}" host local_fp pub_fp post=(-X POST -H 'Content-Type: application/json' --data '{}')
  case "$base" in https://*) ;; *) return 1 ;; esac
  host="$(url_host "$base")"
  local_fp="$(http_fp "${N8N_URL:-http://127.0.0.1:${N8N_PORT:-5678}}${HITL_ROUTE_SUFFIX}" "${post[@]}")"
  case "$local_fp" in 000\|*) return 1 ;; esac
  if [ -n "$ip" ]; then pub_fp="$(http_fp "${base}${HITL_ROUTE_SUFFIX}" "${post[@]}" --resolve "${host}:$(url_port "$base"):${ip}")"
  else pub_fp="$(http_fp "${base}${HITL_ROUTE_SUFFIX}" "${post[@]}")"; fi
  [ "${local_fp%|*|*}" = "${pub_fp%|*|*}" ]
}

# Verwalteter /etc/hosts-Block (Split-Horizon): die eigene Domain zeigt auf dem Server direkt auf den Reverse Proxy
# (LAN-IP bzw. 127.0.0.1), nur IPv4. Den Proxmox-Block (# --- BEGIN PVE ---) und fremde Zeilen fassen wir nie an.
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
_HOSTS_BEGIN='# BEGIN lifeagents (Bestaetigungs-Knoepfe: eigene Domain -> Reverse Proxy)'
_HOSTS_END='# END lifeagents'
# hosts_pin_get <host> -> gepinnte IP oder leer.
hosts_pin_get() {
  [ -f "$HOSTS_FILE" ] || return 0
  awk -v b="$_HOSTS_BEGIN" -v e="$_HOSTS_END" -v h="$1" '$0==b{f=1;next} $0==e{f=0} f && $2==h {print $1; exit}' "$HOSTS_FILE"
}
# hosts_pin_set <host> <ip> | hosts_pin_clear — idempotent (Datei nur bei echter Aenderung neu geschrieben).
hosts_pin_set() {
  [ "$(hosts_pin_get "$1")" = "$2" ] && return 0
  hosts_pin_clear
  # Fehlt der Datei der Schluss-Zeilenumbruch, klebte der BEGIN-Marker an der letzten Zeile (nie mehr exakt findbar).
  if [ -s "$HOSTS_FILE" ] && [ -n "$(tail -c1 "$HOSTS_FILE")" ]; then printf '\n' >> "$HOSTS_FILE"; fi
  printf '%s\n%s %s\n%s\n' "$_HOSTS_BEGIN" "$2" "$1" "$_HOSTS_END" >> "$HOSTS_FILE"
}
hosts_pin_clear() {
  [ -f "$HOSTS_FILE" ] && grep -qxF "$_HOSTS_BEGIN" "$HOSTS_FILE" || return 0
  local tmp; tmp="$(mktemp)"
  awk -v b="$_HOSTS_BEGIN" -v e="$_HOSTS_END" '$0==b{f=1;next} $0==e{f=0;next} !f' "$HOSTS_FILE" > "$tmp"
  cat "$tmp" > "$HOSTS_FILE"; rm -f "$tmp"   # cat statt mv: Inode/Rechte von /etc/hosts bleiben (Container-Bind-Mounts)
}
# hosts_pin_prune <behalten> — den Block entfernen, wenn er NICHT genau <behalten> pinnt (leer = immer): nach einem
#   Domain-Wechsel bliebe sonst der Pin des alten Namens stehen (hosts_pin_get findet nur den aktuellen). Immer rc 0.
hosts_pin_prune() {
  [ -f "$HOSTS_FILE" ] && grep -qxF "$_HOSTS_BEGIN" "$HOSTS_FILE" || return 0
  if [ -n "$1" ] && [ -n "$(hosts_pin_get "$1")" ]; then return 0; fi
  hosts_pin_clear
  log "Veralteten /etc/hosts-Eintrag einer früheren Internet-Adresse entfernt."
  return 0
}

# hitl_chat_state -> "true"/"false": der beim letzten Core-Deploy entschiedene Knopf-Modus (core.env HITL_CHAT_APPROVAL,
#   EIN Fakt fuer alle Workflows + doctor); leer = noch nie entschieden. Immer rc 0 (set -e-sicher in $(…)).
hitl_chat_state() { read_env_value "$(lifeagents_env_file core)" HITL_CHAT_APPROVAL 2>/dev/null || true; return 0; }

# hitl_chat_reachable <webhook-url> -> rc0, wenn der Server seinen Bestaetigungs-Endpunkt ueber die Domain erreicht.
#   Klappt es ueber DNS nicht, aber ueber den Reverse Proxy direkt (erste Einzel-IP aus TRUSTED_PROXIES, sonst
#   127.0.0.1 = Proxy auf diesem Rechner), wird die Domain in /etc/hosts darauf gepinnt (nur dann — ein Pin ohne
#   Beleg koennte einen funktionierenden Weg kaputt machen). Ein veralteter Pin wird zuerst entfernt.
hitl_chat_reachable() {
  local wh="$1" host cand
  host="$(url_host "$wh")"
  [ -n "$host" ] || return 1
  hosts_pin_prune "$host"   # Pin einer frueheren Domain (Domain-Wechsel) zuerst weg
  hitl_route_probe "$wh" && return 0
  if [ -n "$(hosts_pin_get "$host")" ]; then hosts_pin_clear; hitl_route_probe "$wh" && return 0; fi
  for cand in $(printf '%s' "${TRUSTED_PROXIES:-}" | tr ',' ' ') 127.0.0.1; do
    case "$cand" in */*|*:*) continue ;; esac   # nur Einzel-IPv4 (CIDR/IPv6 nie pinnen: der Block ist bewusst IPv4)
    if hitl_route_probe "$wh" "$cand"; then
      hosts_pin_set "$host" "$cand"
      note "Eigene Domain zeigt auf diesem Server jetzt direkt auf den Reverse Proxy (${cand}, /etc/hosts) — sonst landeten Bestätigungs-Tipps im Heimnetz beim Router."
      hitl_route_probe "$wh"; return
    fi
  done
  return 1
}

# n8n_orchestrator_state <api-key> <base-url> -> "<id><TAB><true|false>" des Orchestrator-Workflows
# (Telegram-Trigger) oder leer (API nicht erreichbar / Workflow fehlt). `.active|tostring` VOR `//`:
# sonst fiele ein rohes JSON-false auf `empty` zurueck (doctor-Befund).
n8n_orchestrator_state() {
  n8n_api_curl "$1" "$2/api/v1/workflows?limit=250" -fsS --max-time 5 2>/dev/null \
    | jq -r 'first(.data[]? | select(.name | test("orchestrator")) | "\(.id)\t\(.active | tostring)") // empty' 2>/dev/null || true
}
