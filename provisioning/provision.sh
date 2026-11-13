#!/usr/bin/env bash
# provision.sh — interner Applier des Provisioning-Kerns (PostgreSQL + n8n + Schema + Seeds +
# Owner-Bootstrap + Workflows/Credentials). Faehrt die Schritte auf einem bereits vorliegenden Baum:
# kein Fetch, kein --version, kein Endnutzer-Einstieg. Der HTTPS-Reverse-Proxy (Ingress) wird nicht
# mitinstalliert: der Nutzer bringt seinen eigenen (NPM/Traefik/nginx/Caddy); der Installer gibt am Ende
# ein fertiges Caddyfile + die Anforderungen aus.
#
# Aufruf: `bash provision.sh [--profile dev|release] [--unattended <env-file>] [--domain <fqdn>] ...`
# (alle Flags: `--help`). Voraussetzung: root (`require_root`; `--uninstall` prueft root in `uninstall()`). Nimmt
# die Update-Sperre selbst (wartet 30 s, sonst Abbruch `locked`).
# Aufgerufen u. a. von (weitere: proxy_cli.sh --apply-network, reset_dev_instance.ps1, CI genericity.yml):
#   1. install.sh        — der Bootstrap-Launcher exec't uns nach dem verifizierten Entpacken.
#   2. lifeagents update — die Runtime-CLI laedt frisch (lib/fetch_release.sh) und exec't den neuen
#                          provision.sh (self-replacing) -> re-spiegelt CLI + Baum.
#   3. Test-Substrat     — bootstrap_test_n8n.ps1 ruft uns direkt auf dem cp'ten lokalen Baum
#                          (`--profile dev --unattended`, kein Fetch/Token).
#
# Exit: 0 bei Erfolg (auch bei roten doctor-Punkten am Ende, die nur angezeigt werden), bei `--uninstall`/
# `--apply-network`/`--help` und beim Halt wegen fehlender Pflicht-Eingaben im Bestand (`_hold_update_for_missing_keys`);
# 1 bei `die` und bei Abbruch in der Antworten-Uebersicht; 130 bei Strg-C in einer Frage; bei unerwartetem Abbruch der
# Code des gescheiterten Befehls (der ERR-Trap nennt Zeile und Code). Der Chat-Runner liest das Ergebnis aus der
# Ergebnis-Datei (`result_set`), nicht aus dem Exit-Code.
#
# Idempotent: jeder Schritt ist guarded, ein Zweitlauf ist no-op. `set -euo pipefail` lebt nur hier
# (dem Top-Script dieses Laufs); die gesourcten lib/*.sh erben diesen Error-Mode.
set -euo pipefail
# UTF-8 unabhaengig von der System-Locale (Proxmox-Vorlagen: LANG="C"). C.UTF-8 ist unter Debian 12 immer
# vorhanden; fuer ASCII verhaelt es sich wie C (Code-Punkt-Sortierung), Parser-Stellen mit eigenem
# LC_ALL=C-Praefix behalten das lokal.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# Macht stille set-e-Abbrueche sichtbar (sonst endet das Skript ohne Meldung). Reines printf -> keine
# Abhaengigkeit von common.sh.
# shellcheck disable=SC2154  # false positive: ShellCheck doesn't parse assignments inside the trap
                            # string argument, so it can't see that rc=$? is set at the trap body start.
trap 'rc=$?; printf "\n[x] provision.sh: unerwarteter Abbruch bei Zeile %s (Exit %s).\n" "$LINENO" "$rc" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
# Repo-Wurzel = provisioning/.. — traegt die getrackte Installationsquelle (packages/*/db, packages/*/workflows/).
# Im Release-Tarball bleibt der Baum erhalten, im gespiegelten Runtime-Baum (/usr/local/lib/lifeagents)
# liegt packages/ als Geschwister daneben.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
. "$LIB_DIR/common.sh"
# shellcheck source=lib/preflight.sh
. "$LIB_DIR/preflight.sh"
# shellcheck source=lib/packages.sh
. "$LIB_DIR/packages.sh"
# shellcheck source=lib/install_pg.sh
. "$LIB_DIR/install_pg.sh"
# shellcheck source=lib/install_n8n.sh
. "$LIB_DIR/install_n8n.sh"
# shellcheck source=lib/n8n_patches.sh
. "$LIB_DIR/n8n_patches.sh"   # bekannte n8n-Fehler korrigieren, bis n8n sie selbst liefert (apply_n8n_patches)
# shellcheck source=lib/install_llm_gateway.sh
. "$LIB_DIR/install_llm_gateway.sh"   # lokaler LLM-Gateway: Prompt-Caching + Nutzungs-Messung (vor inject_credentials)
# shellcheck source=lib/install_update_timers.sh
. "$LIB_DIR/install_update_timers.sh"   # Update im Chat: Release-Check alle 2 Stunden + Runner fuer Update-Auftraege
# shellcheck source=lib/upgrade_guard.sh
. "$LIB_DIR/upgrade_guard.sh"   # Versionswechsel auf Bestands-Instanzen: erst sichern, dann tauschen
# shellcheck source=lib/master_swap.sh
. "$LIB_DIR/master_swap.sh"   # Docker-Verbund: master-Wechsel (Merkzettel des Rueckwegs, upgrade_guard.sh)
# shellcheck source=lib/apply_schema.sh
. "$LIB_DIR/apply_schema.sh"
# shellcheck source=lib/seed_data.sh
. "$LIB_DIR/seed_data.sh"
# shellcheck source=lib/bootstrap_owner.sh
. "$LIB_DIR/bootstrap_owner.sh"
# shellcheck source=lib/inject_credentials.sh
. "$LIB_DIR/inject_credentials.sh"
# shellcheck source=lib/deploy_workflows.sh
. "$LIB_DIR/deploy_workflows.sh"
# shellcheck source=lib/pkg_teardown.sh
. "$LIB_DIR/pkg_teardown.sh"
# shellcheck source=lib/pkg_lifecycle.sh
. "$LIB_DIR/pkg_lifecycle.sh"   # Bundle = Metapackage: main() installiert jedes Nicht-Core-Paket ueber pkg_install_one
# shellcheck source=lib/release_inputs.sh
. "$LIB_DIR/release_inputs.sh"
# shellcheck source=lib/uninstall.sh
. "$LIB_DIR/uninstall.sh"
# shellcheck source=lib/owner_connect.sh
. "$LIB_DIR/owner_connect.sh"   # gefuehrtes Ende: Erreichbarkeit + Telegram-Pairing (auch `household pair-owner`)
# shellcheck source=lib/firewall.sh
. "$LIB_DIR/firewall.sh"        # Proxy auf anderem Rechner: Bind + nft-Freigabe aus TRUSTED_PROXIES
# fetch_release.sh wird hier bewusst nicht gesourct — der Fetch lebt im Bootstrap-Launcher
# (install.sh, self-contained) bzw. fuer Updates in `lifeagents update` (sourct die Lib selbst).

# psql-Pager hart aus (eine Adresse, erbt in jede runuser/psql-Kindkette): auf einem echten Terminal/pty
# schaltet psql sonst seinen Pager an ('--More-- (END)', wartet auf Tastendruck) -> interaktive
# Install-/Package-Laeufe haengen an apply_schema. Unattended (kein TTY) ist nie betroffen.
export PSQL_PAGER=cat PAGER=cat

# --- defaults (overridable via flags / env) ----------------------------------
PROFILE="dev"
PROFILE_EXPLICIT=0       # --profile gesetzt? Sonst gewinnt das persistierte INSTALL_PROFILE
UNATTENDED=0
UNATTENDED_ENV_FILE=""   # --unattended <pfad>: die einzige Eingabe-Quelle (gelesen, nie ausgefuehrt: install_answers_load)
ASSUME_YES=0             # --yes: ueberspringt die Uninstall-Sicherheits-Rueckfrage (nur Abbau-Pfad)
UNINSTALL=0
PURGE_DATA=0
CORE_ONLY=0              # --core-only: Alias fuer --packages none (Bare-Core-Generizitaets-Beweis der CI)
PACKAGES_SPEC=""         # --packages none|all|a,b: ZUSAETZLICH zu installierende Pakete (Default none = nur Core);
                         #   bereits installierte Pakete werden bei jedem Lauf aktualisiert
VERBOSE=0                # --verbose: volle technische Ausgabe im Terminal statt Schritt-Zeilen + Logdatei
APPLY_NETWORK=0          # --apply-network: NUR Bind + Firewall aus core.env neu anwenden (lifeagents proxy set)
DOMAIN="${DOMAIN:-}"
TRUSTED_PROXIES="${TRUSTED_PROXIES:-}"   # --trusted-proxies: Reverse Proxy auf ANDEREM Rechner (IPv4/CIDR-Liste)

# Version pins (the whole point of reproducible provisioning).
PG_VERSION="${PG_VERSION:-17}"
N8N_VERSION="${N8N_VERSION:-2.45.7}"
NODE_MAJOR="${NODE_MAJOR:-24}"

# Fixed paths / identities.
N8N_USER="n8n"
N8N_HOME="/var/lib/n8n"
if rt_is_compose; then N8N_HOME="/home/node"; fi   # Verbund: Home des Image-Nutzers "node" (Volume n8n_home)
N8N_USER_FOLDER="${N8N_HOME}/.n8n"
N8N_ENV_FILE="/etc/n8n/n8n.env"           # n8ns eigene Config (n8n liest sie), bleibt /etc/n8n
# Secret-Modell §3.0a: Installer-Namespace /etc/lifeagents/. core.env = Host/Core-Secrets (API-Key,
# core_ro/context_ro-PW) + Nutzer-Eingaben (Domain/Owner/LLM) — beide Schreiber (bootstrap_owner +
# release_inputs) upserten per Key (env_upsert), kein Clobber. Paket-Secrets -> /etc/lifeagents/<pkg>.env.
N8N_OWNER_ENV_FILE="${LIFEAGENTS_DIR:-/etc/lifeagents}/core.env"   # Host/Core-Secrets + API key (bootstrap_owner.sh)
INSTALL_ENV_FILE="${LIFEAGENTS_DIR:-/etc/lifeagents}/core.env"     # release inputs merge-store (release_inputs.sh)
N8N_PORT="${N8N_PORT:-5678}"
N8N_DB_NAME="${N8N_DB_NAME:-n8n}"
N8N_DB_USER="${N8N_DB_USER:-n8n}"

# Secret-Overrides (nur First-Init; eine bestehende Env-Datei gewinnt immer). Erst nach dem Laden der
# --unattended-Env-Datei erfasst (main()), sonst saehen sie deren Werte nicht. Hier nur vordeklariert (set -u).
OPT_ENCRYPTION_KEY=""
OPT_DB_PASSWORD=""

usage() {
  cat >&2 <<EOF
Usage: provision.sh [--profile dev|release] [--unattended <env-file>] [--domain <fqdn>]

  Interner Applier — laeuft auf einem bereits vorliegenden Baum (kein Fetch). Endnutzer nutzen
  den Bootstrap-Launcher install.sh (Erstinstallation) bzw. 'lifeagents update' (Updates).

  --profile dev          LAN dev/test instance (default). No public ingress.
  --profile release      public instance; --domain (or DOMAIN env) recommended; without it no public ingress (warning, asked interactively). The HTTPS reverse
                         proxy is NOT installed — bring your own; the installer emits a Caddyfile.
  --unattended <file>    non-interactive: load ALL inputs from the given env file
                         (KEY='value' lines, read and never executed) instead of prompting. The path is REQUIRED — pick any
                         directory. Both profiles. (Uninstall confirmation uses --yes, not this.)
                         Release profile: a FIRST install stops before changing anything if a
                         mandatory input is missing (OWNER_FIRST_NAME, OWNER_LAST_NAME, OWNER_BIRTH_DATE,
                         TELEGRAM_BOT_TOKEN, ANTHROPIC_API_KEY) and lists all of them; an existing
                         instance holds the update (changes nothing, tells the owner once via
                         Telegram; 'lifeagents reconfigure' fills them in, the next update proceeds).
                         A first install also stops if the Telegram bot is already connected elsewhere
                         (webhook or another poller), unless TELEGRAM_WEBHOOK_TAKEOVER=1 is set.
  --domain <fqdn>       external hostname (n8n WEBHOOK_URL + the emitted reverse-proxy config).
  --trusted-proxies <ip>[,…]   (alias: --trusted-proxy)
                         your reverse proxy runs on ANOTHER host (e.g. a central Caddy/NPM/Traefik
                         container): its IPv4 address (or a CIDR). n8n then listens on the LAN, and a
                         firewall table admits ONLY these addresses to the n8n port. Default 127.0.0.1
                         (proxy on this host). Stored in /etc/lifeagents/core.env (TRUSTED_PROXIES);
                         change later with 'lifeagents proxy set <ip>'.
  --apply-network        internal (used by 'lifeagents proxy set'): re-apply only the n8n listen
                         address + firewall from core.env, restart n8n, print the proxy config.
  --uninstall            stop+remove the services and DROP the app schema (agent/core).
                         PostgreSQL, the n8n database engine and /etc/n8n stay (reversible).
  --purge-data           with --uninstall: ALSO drop the n8n database + roles + data dirs
                         (destructive full wipe; the PG engine itself stays installed).
  --packages <list>      which bundled packages to install IN ADDITION to the Core: none (default),
                         all, or a comma list (e.g. finance,career). Packages that are already
                         installed are always updated (status kept: a deactivated package stays
                         off; an uninstalled one stays away). Add packages later with
                         'lifeagents package install <pkg>'.
  --core-only            alias for --packages none (the bare-core genericity proof).
  --yes, -y              skip the uninstall safety confirmation (for --uninstall only).
  --verbose              show the full technical output in the terminal. Default on a terminal: one
                         line per step, details in /var/log/lifeagents/install.log. (Without a
                         terminal / with --unattended the full output is always shown.)
  --help                 this help.

Env overrides: DOMAIN, PG_VERSION, N8N_VERSION, NODE_MAJOR, N8N_PORT,
               HOUSEHOLD_TIMEZONE (default Europe/Berlin, kept in /etc/lifeagents/core.env),
               N8N_ENCRYPTION_KEY, N8N_DB_PASSWORD (first-init only).
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)    PROFILE="${2:-}"; PROFILE_EXPLICIT=1; shift 2 ;;
      --profile=*)  PROFILE="${1#*=}"; PROFILE_EXPLICIT=1; shift ;;
      --domain)     DOMAIN="${2:-}"; shift 2 ;;
      --domain=*)   DOMAIN="${1#*=}"; shift ;;
      --trusted-proxies|--trusted-proxy)
        case "${2:-}" in ''|-*) die "--trusted-proxies braucht die IPv4-Adresse deines Proxy-Rechners (z. B. --trusted-proxies 192.168.178.10)." ;; esac
        TRUSTED_PROXIES="$2"; shift 2 ;;
      --trusted-proxies=*|--trusted-proxy=*) TRUSTED_PROXIES="${1#*=}"; [ -n "$TRUSTED_PROXIES" ] || die "--trusted-proxies= braucht eine Adresse."; shift ;;
      --apply-network) APPLY_NETWORK=1; shift ;;
      --unattended)
        # Pflicht-Pfad zur Env-Datei. Guard gegen verschluckte Folge-Flags ('' oder -*): so faengt
        # `--unattended --profile dev` den Fehler, statt '--profile' als Pfad zu nehmen.
        case "${2:-}" in
          ''|-*) die "--unattended braucht einen Pfad zur Env-Datei (z.B. --unattended /srv/install.env). Fuer unbeaufsichtigtes uninstall: --yes." ;;
        esac
        UNATTENDED=1; UNATTENDED_ENV_FILE="$2"; shift 2 ;;
      --unattended=*)
        UNATTENDED_ENV_FILE="${1#*=}"
        [ -n "$UNATTENDED_ENV_FILE" ] || die "--unattended= braucht einen Pfad zur Env-Datei."
        UNATTENDED=1; shift ;;
      --yes|-y)     ASSUME_YES=1; shift ;;
      --uninstall)  UNINSTALL=1; shift ;;
      --purge-data) PURGE_DATA=1; shift ;;
      --core-only)  CORE_ONLY=1; shift ;;
      --packages)
        case "${2:-}" in ''|-*) die "--packages braucht eine Angabe: none, all oder eine Liste (z.B. --packages finance,career)." ;; esac
        PACKAGES_SPEC="$2"; shift 2 ;;
      --packages=*) PACKAGES_SPEC="${1#*=}"; [ -n "$PACKAGES_SPEC" ] || die "--packages= braucht eine Angabe."; shift ;;
      --verbose)    VERBOSE=1; shift ;;
      --help|-h)    usage; exit 0 ;;
      *) die "Unbekanntes Argument: $1 (--help für Optionen)." ;;
    esac
  done
  case "$PROFILE" in
    dev|release) : ;;
    *) die "Ungültiges --profile: '$PROFILE' (dev|release)." ;;
  esac
  if [ "$PURGE_DATA" -eq 1 ] && [ "$UNINSTALL" -ne 1 ]; then
    die "--purge-data gilt nur zusammen mit --uninstall."
  fi
  if [ "$CORE_ONLY" -eq 1 ]; then
    [ -z "$PACKAGES_SPEC" ] || die "--core-only und --packages schliessen sich aus (--core-only = --packages none)."
    PACKAGES_SPEC="none"
  fi
  # Paketliste gegen den gebuendelten Katalog pruefen (Tippfehler = Abbruch, nicht still ignoriert).
  case "${PACKAGES_SPEC:-none}" in
    none|all) : ;;
    *)
      local _p _known
      _known=" $(_bundled_packages | tr '\n' ' ')"
      for _p in ${PACKAGES_SPEC//,/ }; do
        case "$_known" in *" $_p "*) : ;; *) die "--packages: unbekanntes Paket '$_p' (verfügbar:${_known})." ;; esac
      done ;;
  esac
  # if-Form statt &&-Kette: als letzte Zeile gaebe eine &&-Kette bei falschem ersten Test Exit 1 als
  # Rueckgabewert von parse_args zurueck -> set -e beendet main still.
  if [ "$PROFILE" = "release" ] && [ -z "$DOMAIN" ] && [ "$UNATTENDED" -eq 1 ] && [ "${REACH_MODE:-}" != tunnel ]; then
    warn "--profile release ohne --domain: kein oeffentlicher Ingress (kein Reverse-Proxy-Caddyfile ausgegeben)."
  fi
}

# resolve_household_timezone — die eine Haushalts-Zeitzone (Kalendertag "heute" der Datenbank, n8n-Zeitplaene,
# Zeitstempel in Alarmen). Aufloesung: HOUSEHOLD_TIMEZONE (Env / --unattended-Datei) > persistiert in core.env >
# Europe/Berlin. Bewusst nicht die Container-Zeitzone (/etc/timezone, TZ): eine LXC-Vorlage steht meist auf UTC,
# das ist der Rechner, nicht der Haushalt. Persistiert wie INSTALL_PROFILE/TRUSTED_PROXIES -> ein Update oder
# `lifeagents proxy set` behaelt sie. Setzt TIMEZONE (n8n GENERIC_TIMEZONE + DB-Zeitzone in install_postgres).
resolve_household_timezone() {
  local persisted
  persisted="$(read_env_value "$INSTALL_ENV_FILE" HOUSEHOLD_TIMEZONE 2>/dev/null || true)"
  TIMEZONE="${HOUSEHOLD_TIMEZONE:-${persisted:-Europe/Berlin}}"
  # Zeichen-Whitelist zuerst (der Wert landet als SQL-Literal in ALTER DATABASE), dann gegen die tz-Datenbank.
  case "$TIMEZONE" in
    *[!A-Za-z0-9_+/-]*|'') die "HOUSEHOLD_TIMEZONE ungültig: '${TIMEZONE}' (erwartet z. B. Europe/Berlin)." ;;
  esac
  if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    die "HOUSEHOLD_TIMEZONE unbekannt: '${TIMEZONE}' (keine Datei unter /usr/share/zoneinfo; erwartet z. B. Europe/Berlin)."
  fi
  if [ "$TIMEZONE" != "$persisted" ]; then
    env_upsert "$INSTALL_ENV_FILE" HOUSEHOLD_TIMEZONE "$TIMEZONE"
    chmod 0640 "$INSTALL_ENV_FILE" 2>/dev/null || true
    chown "root:${N8N_USER}" "$INSTALL_ENV_FILE" 2>/dev/null || true
  fi
}

# Leitet die URL-/Host-Variablen aus DOMAIN ab. Mit Domain emittiert n8n https-Webhook-URLs (das ausgegebene
# Caddyfile nimmt die Domain direkt, owner_connect.emit_ingress_help); ohne Domain (dev) localhost
# (Long-Polling), kein oeffentlicher Ingress.
derive_network_config() {
  resolve_household_timezone

  if [ -n "$DOMAIN" ]; then
    N8N_PROTOCOL="https"
    N8N_HOST="$DOMAIN"
    N8N_EDITOR_BASE_URL="https://${DOMAIN}/"
    WEBHOOK_URL="https://${DOMAIN}/"
  else
    N8N_PROTOCOL="http"
    N8N_HOST="localhost"
    N8N_EDITOR_BASE_URL=""
    if [ "$PROFILE" = "dev" ]; then
      # Dev/Test: kein echter Ingress (kein Konflikt mit dem Router-Port 443 des Prod-Systems). Aber n8n
      # aktiviert den Telegram-Trigger nur mit einer gueltigen https-WEBHOOK_URL: beim Activate ruft die
      # create()-webhookMethod `setWebhook` mit der abgeleiteten Node-Webhook-URL; bei leerer/localhost-URL
      # lehnt Telegram ab -> create() wirft -> /activate 400 -> der Orchestrator bleibt inaktiv -> keine
      # lokal routbare /webhook-Route (webhook_entity bleibt leer). Ein RFC-2606-Platzhalter (example.com)
      # erfuellt Telegrams Syntax-/DNS-Pruefung -> Activate gruen -> n8n registriert die Produktiv-Route
      # `<webhookId>/webhook` und leitet den secret_token (`<wfId>_<nodeId>`; beide Trigger-ids je Instanz
      # geheim, deploy_workflows) ab. Telegram liefert nie echte Updates dorthin; die Test-Tiers feuern ueber
      # die Harness-Webhooks. Prod/Release nutzt --domain (echte URL).
      WEBHOOK_URL="https://example.com/"
    else
      WEBHOOK_URL=""
    fi
  fi
}

# apply_network_only — `--apply-network` (aufgerufen von `lifeagents proxy set`): nur Firewall + n8n-Bind aus
# core.env neu anwenden, mit demselben Code wie die Installation (firewall_converge -> prepare_n8n_env ->
# install_n8n_unit). Startet n8n bei geaenderter Env neu und zeigt danach die passende Proxy-Konfiguration
# (Caddyfile bzw. Einfuege-Baustein).
apply_network_only() {
  derive_network_config
  ensure_lifeagents_dir
  firewall_converge
  prepare_n8n_env
  install_n8n_unit
  if [ -n "$DOMAIN" ]; then
    emit_ingress_help "$TEMPLATE_DIR" "$DOMAIN" "$N8N_PORT" "$WEBHOOK_URL"
    # Neuer Proxy -> der /etc/hosts-Eintrag der eigenen Domain (Bestaetigen im Chat) muss neu belegt werden: sonst
    # gingen Knopf-Tipps still an den alten Proxy. hitl_chat_reachable raeumt einen veralteten Eintrag ab und pinnt neu.
    if [ "$(hitl_chat_state)" = true ]; then
      wait_n8n_health >/dev/null 2>&1 || true
      N8N_URL="http://127.0.0.1:${N8N_PORT}" hitl_chat_reachable "$WEBHOOK_URL" \
        || warn "Bestätigungs-Knöpfe erreichen n8n über ${DOMAIN} gerade nicht — Proxy-Route ${HITL_ROUTE_SUFFIX} prüfen, dann 'lifeagents update' (schaltet sonst auf Webseiten-Knöpfe zurück)."
    fi
  fi
  ok "Netzwerk angewendet: n8n lauscht auf ${N8N_LISTEN_ADDRESS_EFF}:${N8N_PORT}."
}

main() {
  parse_args "$@"

  # Abbau-Pfad: Dienste/Schema (+ optional Daten) entfernen und beenden. Liest keine Env-Datei (die
  # Sicherheits-Rueckfrage haengt an --yes/ASSUME_YES) -> vor dem Einlesen unten.
  if [ "$UNINSTALL" -eq 1 ]; then
    log "Abbau-Modus (--uninstall${PURGE_DATA:+ --purge-data})."
    uninstall
    exit 0
  fi

  # --unattended <env-file>: die Datei frueh in die Umgebung laden — sie ist die einzige Eingabe-Quelle
  # (Owner-Identitaet, Domain, LLM-/Telegram-Keys und die First-Init-Secret-Overrides). Muss vor der
  # OPT_-Erfassung + load_install_env laufen, damit jeder spaetere `${VAR:-}`-Read die Werte sieht.
  # Form wie ein .env (KEY='value'), aber gelesen, nie ausgefuehrt (install_answers_load, release_inputs.sh):
  # die Datei kann Antworten eines Nutzers aus dem Wizard tragen.
  if [ "$UNATTENDED" -eq 1 ]; then
    install_answers_load "$UNATTENDED_ENV_FILE"
  fi
  # Secret-Overrides (nur First-Init; bestehende n8n.env gewinnt immer) NACH dem Einlesen erfassen.
  OPT_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-}"
  OPT_DB_PASSWORD="${N8N_DB_PASSWORD:-}"

  # Früh root erzwingen: collect_release_inputs schreibt /etc/lifeagents/core.env (root), noch vor
  # preflight; sonst mkdir-/chown-Fehler tief im Lauf.
  require_root
  # Update-Sperre (common.sh): nie zwei Umbau-Laeufe gleichzeitig (z. B. Terminal-Update waehrend eines Chat-Updates);
  # ein vom Chat-Runner gestarteter Lauf erbt sie. Danach traegt die Ergebnis-Datei (falls gesetzt) den Fortschritt.
  update_lock_acquire 30 \
    || die_because locked "Gerade läuft schon ein Update oder eine Einrichtung (Sperre ${LIFEAGENTS_UPDATE_LOCK}) — danach erneut starten."
  result_set status running
  result_set stage preflight

  # Release-Eingaben: erst den Merge-Store laden (override-first, idempotent), dann fehlende
  # interaktiv erfragen (nur Release+TTY). Vor derive_network_config — DOMAIN bestimmt die
  # Ingress-/WEBHOOK_URL-Ableitung (Public-HTTPS vs. dev/:80).
  load_install_env

  # Internet-Adresse: load_install_env hat DOMAIN normalisiert (eine Regel fuer alle Eingabewege). Steht in core.env
  # dieselbe Adresse nur anders geschrieben (https://name:443/), wird sie einmal korrigiert zurueckgeschrieben (danach
  # Zweitlauf no-op); eine per Flag neue Adresse speichert erst collect_release_inputs.
  if [ -n "$DOMAIN" ]; then
    local _dom_stored
    _dom_stored="$(read_env_value "$INSTALL_ENV_FILE" DOMAIN 2>/dev/null || true)"
    if [ -n "$_dom_stored" ] && [ "$_dom_stored" != "$DOMAIN" ] && [ "$(normalize_domain "$_dom_stored")" = "$DOMAIN" ]; then
      env_upsert "$INSTALL_ENV_FILE" DOMAIN "$DOMAIN"
      chmod 0640 "$INSTALL_ENV_FILE" 2>/dev/null || true
      chown "root:${N8N_USER}" "$INSTALL_ENV_FILE" 2>/dev/null || true
    fi
  fi
  # Docker-Verbund: Weg nach aussen (REACH_MODE) merken; beim Tunnel kommt die Internet-Adresse von Tailscale, sobald der
  # Knoten angemeldet ist (lib/reach.sh) — darum VOR derive_network_config.
  if rt_is_compose; then reach_prepare; fi

  # `lifeagents update` reicht leere Args durch -> ohne Persistenz liefe jedes Prod-Update als PROFILE=dev
  # und die release-gegateten Schritte (collect_release_inputs = Host-Key-Nachprompt neuer Releases,
  # End-Recap) fielen still aus. Aufloesung: Flag > persistiertes INSTALL_PROFILE (core.env) > Default dev.
  # Das Substrat setzt --profile dev explizit.
  local _persisted_profile
  if [ "$PROFILE_EXPLICIT" -ne 1 ]; then
    _persisted_profile="$(read_env_value "$INSTALL_ENV_FILE" INSTALL_PROFILE 2>/dev/null || true)"
    case "$_persisted_profile" in
      dev|release) PROFILE="$_persisted_profile" ;;
      '') : ;;
      *) warn "Ignoriere ungueltiges INSTALL_PROFILE='$_persisted_profile' in $INSTALL_ENV_FILE (erwarte dev|release)." ;;
    esac
  fi

  # TRUSTED_PROXIES (Flag / Env / --unattended-Datei / core.env) validieren und profilunabhaengig sofort
  # persistieren (Muster INSTALL_PROFILE) — sonst fiele ein Dev-Profil-Update still auf "nur lokal" zurueck
  # und der Proxy auf dem anderen Rechner bekaeme 502. Nicht-interaktiv nur IPs (keine Namensaufloesung);
  # die interaktive Frage (mit Hostname-Aufloesung) stellt collect_release_inputs.
  if [ -n "$TRUSTED_PROXIES" ]; then
    TRUSTED_PROXIES="$(normalize_trusted_proxies "$TRUSTED_PROXIES")" \
      || die "TRUSTED_PROXIES / --trusted-proxies ungültig (erwartet IPv4 wie 192.168.178.10, mehrere mit Komma)."
    env_upsert "$INSTALL_ENV_FILE" TRUSTED_PROXIES "$TRUSTED_PROXIES"
    chmod 0640 "$INSTALL_ENV_FILE" 2>/dev/null || true
    chown "root:${N8N_USER}" "$INSTALL_ENV_FILE" 2>/dev/null || true
  fi
  if [ "$APPLY_NETWORK" -eq 1 ]; then
    apply_network_only
    exit 0
  fi

  collect_release_inputs
  _ask_initial_packages   # Funktions-Wahl bei der Erstinstallation (setzt PACKAGES_SPEC)
  if [ "$PROFILE" = "release" ]; then
    env_upsert "$INSTALL_ENV_FILE" INSTALL_PROFILE release
    chmod 0640 "$INSTALL_ENV_FILE" 2>/dev/null || true
    chown "root:${N8N_USER}" "$INSTALL_ENV_FILE" 2>/dev/null || true
  fi

  # Alle Fragen vor der Installation (debconf-Muster): nach den Host-Keys die Schluessel der Pakete, die
  # dieser Lauf anfasst (installierte + per --packages gewuenschte; Standard-Erstinstallation = nur Core ->
  # keine Paket-Fragen). Danach laeuft der Rest ohne Rueckfrage.
  if ui_interactive && ensure_jq_quiet; then
    # shellcheck disable=SC2046  # Paketnamen sind ^[a-z][a-z0-9_]*$ (kein Globbing/Leerzeichen)
    collect_package_inputs $(_packages_to_process "$PACKAGES_SPEC")
  fi

  # Uebersicht vor dem Installieren: alle Antworten pruefen + einzeln aendern, Esc = Abbrechen
  # (nichts installiert). Nur Release + interaktiv, und nur wenn in diesem Lauf etwas gefragt wurde oder es die
  # Erstinstallation ist — ein stilles Update bleibt still. Die Prompts leben in release_inputs.sh (contract_lint 12d).
  if [ "$PROFILE" = "release" ] && ui_interactive && { [ "$UI_ASKED" = 1 ] || _is_first_install; }; then
    review_install_answers install
    if [ "$REVIEW_RESULT" = "abort" ]; then
      local _cont='lifeagents update'
      if _is_first_install; then _cont='denselben Installationsbefehl erneut starten'; fi
      printf '\n  Abgebrochen — es wurde nichts installiert. Deine Angaben sind gespeichert (Paket-Einstellungen fragt\n  der nächste Aufruf noch einmal). Weitermachen: %s\n\n' "$_cont" >&2
      exit 1
    fi
  fi
  # Weg ins Internet der CLI: der Tunnel steht vor dem langen Teil, seine Adresse braucht prepare_n8n_env (WEBHOOK_URL);
  # ein Wechsel weg vom Tunnel nimmt nur unsere Funnel-Eintraege zurueck (lib/reach_cli.sh).
  if [ "$PROFILE" = "release" ] && ! rt_is_compose; then
    ensure_jq_quiet || true
    reach_tunnel_connect
    reach_cli_leave_tunnel
  fi
  # Erst nach der Uebersicht: DOMAIN kann sich dort noch aendern (die abgeleiteten Werte liest erst prepare_n8n_env).
  derive_network_config
  # Pruefliste Nr. 10: hoert der Bot schon woanders zu? Nach den Fragen, vor der ersten Aenderung (fragt bzw. bricht ab).
  telegram_webhook_preflight
  # Domain gewechselt (egal ob per reconfigure, Uebersicht, --domain oder Hand-Edit): der abgeleitete Ist-Zustand
  # WEBHOOK_URL in n8n.env (vor prepare_n8n_env) ist die eine Quelle -> das gefuehrte Ende prueft Handy/Laptop dann
  # mit „Erneut prüfen" (owner_connect.sh _oc_device_check ask).
  local _wh_before
  _wh_before="$(read_env_value "$N8N_ENV_FILE" WEBHOOK_URL 2>/dev/null || true)"
  if [ -n "$_wh_before" ] && [ -n "$WEBHOOK_URL" ] && [ "$_wh_before" != "$WEBHOOK_URL" ]; then
    # shellcheck disable=SC2034  # gelesen von owner_connect.sh (owner_connect_guided)
    LIFEAGENTS_DOMAIN_CHANGED=1
  fi

  # Ruhige Ausgabe (nur interaktiv + TUI-faehiges Terminal + ohne --verbose): ab hier eine Zeile je
  # Schritt, die technische Ausgabe geht in /var/log/lifeagents/install-<zeit>.log. Grenze = nach den
  # Fragen (die gehoeren aufs Terminal).
  if ui_quiet_wanted "$VERBOSE"; then
    printf '\n  Ab hier läuft alles ohne Rückfrage — das dauert einige Minuten.\n\n' >&2
    ui_log_begin install
  fi

  log "Provisioning-Kern — Profil '${PROFILE}', n8n ${N8N_VERSION}, PG ${PG_VERSION}, Node ${NODE_MAJOR}.x"
  if [ -n "$DOMAIN" ]; then log "Domain: ${DOMAIN}"; else log "Keine Domain (nur LAN, kein oeffentlicher Ingress)."; fi

  # Fehlendes Template vorab abfangen: render_template stirbt in einer Pipeline-Subshell, was die
  # `if … | write_if_changed`-Aufrufer sonst als "unveraendert" lesen.
  local t
  for t in n8n.env.tpl n8n.service.tpl Caddyfile.tpl lifeagents.tpl lifeagents-firewall.service.tpl n8n-firewall.conf.tpl firewall.nft.tpl lifeagents-llm-gateway.service.tpl \
           lifeagents-update-check.service.tpl lifeagents-update-check.timer.tpl lifeagents-update-run.service.tpl lifeagents-update-run.timer.tpl; do
    [ -f "$TEMPLATE_DIR/$t" ] || die "Template fehlt: $TEMPLATE_DIR/$t (unvollständiges Paket)."
  done

  ui_step 'System prüfen' preflight
  preflight
  ui_step_done "$(_preflight_summary)"
  ui_step 'Basis-Pakete installieren' base
  result_set changed true   # ab hier aendert der Lauf das System (Fehler-Hilfe: nicht mehr "nichts geaendert")
  if rt_is_compose; then log "Compose-Betrieb: die Basis-Pakete stecken im master-Image."; else install_base_packages; fi
  # Reihenfolge (fail-closed): erst die Firewall angleichen, dann den Bind daraus ableiten — n8n lauscht
  # nur dann im Heimnetz (0.0.0.0), wenn die Freigabe-Tabelle nachweislich geladen ist.
  firewall_converge      # setzt N8N_LISTEN_ADDRESS_EFF (127.0.0.1 | 0.0.0.0)
  prepare_n8n_env        # mint/preserve secrets + render env (PG needs the DB password)
  ui_step_done
  # Versionswechsel (n8n, Node, PG-Minor) auf einer Bestands-Instanz: n8n anhalten + DB verschluesselt sichern, bevor
  # install_postgres/install_n8n irgendetwas tauschen (upgrade_guard.sh). Ein normales Update ueberspringt das.
  if upgrade_detect; then
    ui_step 'Update absichern (Datenbank-Sicherung)' backup
    # Verbund: neue Images zuerst laden — scheitert der Pull, bricht das Update ab, bevor n8n angehalten wird.
    if rt_is_compose; then
      rt_stack_pull postgres n8n gateway \
        || die "Die neuen Images ließen sich nicht laden (Netz oder Platz?) — Update abgebrochen, es wurde nichts angehalten oder getauscht."
    fi
    upgrade_prepare
    ui_step_done
  fi
  ui_step "PostgreSQL ${PG_VERSION} einrichten" postgres
  install_postgres
  ui_step_done
  ui_step "n8n ${N8N_VERSION} installieren" n8n
  install_n8n
  ui_step_done
  # LLM-Gateway nach install_n8n (Node da) und vor inject_credentials (fail-closed: antwortet er nicht, bricht
  # der Lauf hier ab, bevor die Anthropic-Credential auf ihn zeigt) — install_llm_gateway.sh.
  ui_step 'KI-Gateway (Prompt-Caching) einrichten' gateway
  install_llm_gateway
  # Versionswechsel steht (n8n bereit, Gateway neu gestartet) -> Merkzettel weg, alte Sicherungen raeumen. Das Deploy
  # danach ist ein normaler, wiederholbarer Schritt; ein Abbruch vor hier laesst den Merkzettel stehen (naechster Lauf setzt fort).
  upgrade_finish
  ui_step_done
  # Der HTTPS-Reverse-Proxy ist bring-your-own; das fertige Caddyfile + die Anforderungen zeigt das
  # gefuehrte Ende (owner_connect_guided) bei Bedarf.

  # --- Core-Install (bare; lokales psql, kein API-Key noetig) — Bundle = Metapackage ----
  # Erst den Core bare, dann jedes gebuendelte Paket ueber denselben per-Paket-Installpfad (pkg_install_one).
  ui_step 'Datenbank vorbereiten' schema
  ensure_lifeagents_dir  # /etc/lifeagents 750 root:n8n (Installer-Secret-Namespace, Secret-Modell §3.0a)
  apply_schema core      # bare Core: Schema (Flyway 3-Phasen) + Hardening/RO-Rollen + Owner-Grants agent,core
  SEED_PKG=core seed_data   # Core-Daten: ai_models + core.config + Core-Instruktions-Contexts (no-PII)
  register_package core active   # Core registriert+active (Routing-Status-Gate liest es)
  ui_step_done

  # --- owner bootstrap: owner-setup + API key + host-only RO-secrets + Telegram-Basis -------------
  # n8n bootet in install_n8n im setup-pending-Zustand; der Owner wird hier via /rest/owner/setup
  # eingerichtet (versions-stabil) und der API-Key aus der Session geminted. RO-Secrets sind host-only
  # (core_ro/context_ro -> /etc/lifeagents/core.env); die Paket-Passwoerter mintet pkg_install_one.
  # Der Pairing-Code kommt erst im gefuehrten Ende (owner_connect_guided).
  ui_step 'Zugänge einrichten' access
  N8N_URL="http://127.0.0.1:${N8N_PORT}"
  bootstrap_owner
  ui_step_done

  # --- n8n-Deploy (gated auf den geminteten N8N_API_KEY) ----------------------
  # Schlaegt der Mint fehl (skip), faellt dieser Schritt sauber aus; Schema/Seed oben sind live, der
  # Deploy ist danach erneut laufbar.
  INSTALLED_PACKAGES=''; FAILED_PACKAGES=''; _DEPLOY_SKIPPED=0
  if [ -n "${N8N_API_KEY:-}" ]; then
    ui_step 'Agenten und Workflows einspielen' workflows
    inject_credentials      # geteilte Host-Creds (REST, autoritativ); Paket-Creds kommen per pkg_install_one
    deploy_workflows core   # Core-Workflows (NAME-Remap gegen live n8n) -> import:workflow -> activate
    ui_step_done
    # Pakete ueber den per-Paket-Installpfad (Migration/Rollen/Creds/Seed/Deploy): die installierten (Update,
    # Status bleibt) + die per --packages zusaetzlich gewuenschten (Standard = nur Core; weitere per
    # `lifeagents package install <pkg>`). Deinstallierte bleiben weg.
    local _work _pkg _pname
    _work="$(_packages_to_process "$PACKAGES_SPEC")"
    if [ -z "$_work" ]; then
      log "Keine Pakete zu installieren/aktualisieren (nur Core) — weitere per 'lifeagents package install <paket>'."
    else
      while IFS= read -r _pkg; do
        [ -n "$_pkg" ] || continue
        _pname="$(pkg_text "$_pkg" package.name)"
        ui_step "Paket ${_pname:-$_pkg} installieren" packages
        # Subshell: ein internes `die` (z. B. apply_schema-Fehler) beendet nur den Paket-Install, nicht das
        # ganze provision.sh — der Core ist oben schon live; status bleibt 'installing', Re-Run konvergiert.
        # ✓/✗ aus dem Subshell-Rueckgabewert (die Subshell erbt weder set -e-Abbruch noch den EXIT-Trap).
        if ( pkg_install_one "$_pkg" ); then
          ui_step_done
          INSTALLED_PACKAGES="${INSTALLED_PACKAGES:+$INSTALLED_PACKAGES, }${_pname:-$_pkg}"
        else
          ui_step_fail "Status bleibt 'installing' — ein erneuter Lauf setzt fort"
          FAILED_PACKAGES="${FAILED_PACKAGES:+$FAILED_PACKAGES, }${_pname:-$_pkg}"
        fi
      done <<<"$_work"
    fi
    # Die Funktions-Wahl der Erstinstallation ist verbraucht (Einmal-Merkzeile, s.
    # release_inputs._ask_initial_packages) — ein gescheitertes Paket bleibt 'installing' und der naechste Lauf
    # setzt ueber die Registry fort; die Zeile darf nie ein spaeter deinstalliertes Paket zurueckholen.
    if [ -n "${INSTALL_ENV_FILE:-}" ] && env_has_key "$INSTALL_ENV_FILE" PACKAGES_SELECTED; then
      env_remove_key "$INSTALL_ENV_FILE" PACKAGES_SELECTED
    fi
    # Workflows, die im Core-Pass auf noch fehlende Paket-Sub-Workflows trafen (Orchestrator), jetzt aktivieren.
    activate_inactive_workflows
  else
    _DEPLOY_SKIPPED=1
    warn "Workflows/Credentials/Pakete uebersprungen: Owner-Bootstrap lieferte keinen N8N_API_KEY (Mint skip/Fehler) — Deploy danach erneut laufbar."
  fi

  ui_step 'Verwaltungsbefehl lifeagents einrichten' cli
  install_cli            # lifeagents-Admin-CLI nach /usr/local/bin + Provisioning-Baum spiegeln
  rt_is_compose || install_update_timers  # Verbund: kein systemd-Timer, Ersatz im master. Braucht die CLI (ExecStart=/usr/local/bin/lifeagents update --check|--run-requested)
  install_release_keyring  # einmalig: ab jetzt nur noch unterschriebene Updates (nie ueberschrieben)
  ui_step_done
  # Ein altes GH_TOKEN (aus core.env + Alt-Bootstrap-Env) braucht die neue CLI nicht mehr. Erst nach install_cli:
  # scheitert der Lauf vorher, bleibt die alte CLI installiert, die es noch braucht.
  drop_legacy_repo_token "$INSTALL_ENV_FILE" /etc/n8n/install.env
  # Docker-Verbund: erst jetzt die oeffentlichen Pfade am Rand freigeben; beim FritzBox-Weg wan (80/443, Zertifikat)
  # starten, nachdem 80/443 als frei geprueft sind (lib/reach.sh).
  if rt_is_compose; then reach_converge; fi
  # Docker-Verbund: Sicherungsordner aus dem Fragebogen anlegen + erste Sicherung (braucht die CLI von install_cli).
  if rt_is_compose && [ -n "${BACKUP_PARENT_DIR:-}" ]; then _setup_backup_folder; fi

  # Gefuehrtes Ende (interaktiv): Erreichbarkeit pruefen (ggf. Caddyfile + "Erneut pruefen/Spaeter"),
  # Pairing-Code als Deep-Link, auf /start warten, danach den Bot fertig einstellen. Ohne TTY / ohne
  # Voraussetzungen: nur ein Recap-Eintrag ("spaeter: lifeagents household pair-owner").
  OC_TEMPLATE_DIR="$TEMPLATE_DIR"
  if [ "$PROFILE" = "release" ]; then
    owner_connect_guided
    # Nicht verbunden + Domain gesetzt -> Proxy-Anleitung mindestens einmal ausgeben (non-TTY wie bisher).
    if [ "$OWNER_CONNECT_RESULT" != "connected" ] && [ "$OWNER_CONNECT_RESULT" != "unfinished" ] && [ "$_INGRESS_HELP_SHOWN" -eq 0 ] && [ -n "$DOMAIN" ]; then
      if rt_is_compose || [ "$(reach_cli_mode)" = tunnel ]; then ui_section 'Erreichbarkeit'; else ui_section 'Ingress (Reverse Proxy — bring your own)'; fi
      emit_ingress_help "$TEMPLATE_DIR" "$DOMAIN" "$N8N_PORT" "$WEBHOOK_URL"
    fi
  fi

  # Diagnose nach dem gefuehrten Ende (spiegelt den Endzustand). Quiet: Ausgabe ins Log, Terminal ✓/✗
  # nach Exit-Code (Anzahl ROT).
  ui_step 'Abschlussprüfung' final
  local _doc_out _doc_rc=0 _l
  _doc_out="$(bash "$SCRIPT_DIR/doctor.sh" 2>&1)" || _doc_rc=$?
  printf '%s\n' "$_doc_out" >&2   # volle Diagnose: Quiet -> Log, sonst Terminal
  if [ "$_doc_rc" -eq 0 ]; then
    ui_step_done 'alles grün'
  else
    ui_step_bad "${_doc_rc} offene(r) Punkt(e) — Details: lifeagents doctor"
    if [ "${UI_QUIET:-0}" = 1 ]; then
      # Die ROT-Zeilen (doctor-Praefix [FAIL]) direkt unter dem ✗.
      while IFS= read -r _l; do
        [ -n "$_l" ] || continue
        { printf '      %s\n' "${_l#*\[FAIL\] }" >&3; } 2>/dev/null || true
      done <<<"$(printf '%s\n' "$_doc_out" | grep -F '[FAIL]' || true)"
    fi
  fi

  display_install_recap   # nur Release: End-Recap (Status + generierte Zugaenge + offene Schritte)
  _recap_backup_kit
  if [ "${UI_QUIET:-0}" = 1 ]; then
    { printf '  Protokoll dieser Installation: %s\n\n' "$UI_LOG_FILE" >&3; } 2>/dev/null || true
  fi

  # Ergebnis fuer den Chat-Runner (common.sh result_set): ok, oder partial, wenn ein Paket bzw. der Workflow-Deploy
  # ausfiel (beides nicht fatal fuer den Lauf). Rote doctor-Punkte allein sind kein partial (oft Umgebung, z. B. Proxy).
  if [ -n "$FAILED_PACKAGES" ] || [ "$_DEPLOY_SKIPPED" -eq 1 ]; then
    result_set failed_packages "${FAILED_PACKAGES:-$(pkg_text core update.stage.workflows "${OWNER_LANGUAGE:-de}")}"
    result_set reason_code package
    result_set status partial
  else
    result_set status ok
  fi
}

# _preflight_summary — Kurzinfo fuer die ✓-Zeile "System pruefen" (OS + freier Platz).
_preflight_summary() {
  local os free
  # shellcheck disable=SC1091  # Laufzeit-Datei des Zielsystems
  os="$(. /etc/os-release 2>/dev/null && printf '%s %s' "${NAME:-Linux}" "${VERSION_ID:-}")"
  free="$(df -Pm / 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024}')"
  printf '%s, %s GB frei' "${os:-Linux}" "${free:-?}"
}

# _recap_status <wert> <hinweis> [pflicht] — 'gesetzt' | 'übersprungen (<hinweis>)' bzw. bei Pflicht-Keys
#   (nicht ueberspringbar, fehlen nur nach einem unbeaufsichtigten Bestandslauf) 'FEHLT (Pflicht — <hinweis>)'. Nie der Wert.
_recap_status() {
  if [ -n "$1" ]; then printf 'gesetzt'
  elif [ "${3:-0}" = 1 ]; then printf 'FEHLT (Pflicht — %s)' "$2"
  else printf 'übersprungen (%s)' "$2"; fi
}

# _recap_skipped_pkg_keys -> je Paket eine Zeile "<Name>: KEY1, KEY2 -> lifeagents reconfigure <pkg>"
#   fuer leer gebliebene, im Manifest deklarierte (nicht generierte) Schluessel. Leer = nichts offen.
_recap_skipped_pkg_keys() {
  local pkg envf k p v missing name
  while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    envf="$(lifeagents_env_file "$pkg")"
    missing=''
    # Menschenlesbar: die Frage-Beschriftung aus dem Manifest statt des Env-Namens.
    while IFS=$'\t' read -r k p; do
      [ -n "$k" ] || continue
      v="$(read_env_value "$envf" "$k" 2>/dev/null || true)"
      [ -n "$v" ] || missing="${missing:+$missing, }$(_prompt_label "$p")"
    done <<<"$(_pkg_manifest_field "$pkg" '(.credentials // {}) | to_entries[] | select(.key != "_comment") | .value.env | to_entries[] | "\(.key)\t\(.value.prompt // .key)"' || true)"
    [ -n "$missing" ] || continue
    name="$(pkg_text "$pkg" package.name)"
    printf '  %s: %s\n    nachtragen: lifeagents reconfigure %s\n' "${name:-$pkg}" "$missing" "$pkg"
  done <<<"$(_installed_packages)"   # nur installierte Pakete
}

# display_install_recap — End-Recap, nur im Release-Profil (beim Test wird der Container/LXC verworfen).
# Terminal via ui_box (im Quiet-Modus nur fd3, nie ins Log — die Box traegt generierte Passwoerter).
# Gliederung: Installiert · Uebersprungen (je Schluessel + exakter Nachtrag-Befehl) · Generierte Zugaenge
# (einmalig) · Noch zu tun (nur wenn offen — Proxy/Pairing spaeter). Selbst eingegebene Secrets erscheinen
# nie; das n8n-Login-Passwort nur, wenn es generiert wurde (N8N_OWNER_PASSWORD leer -> OWNER_PLAINTEXT).
display_install_recap() {
  [ "$PROFILE" = "release" ] || return 0
  local _pw_line='' _skipped _todo='' _n=1
  # Nur in dem Lauf, der das n8n-Konto wirklich angelegt hat (OWNER_SETUP_DONE): bei jedem spaeteren Lauf
  # wuerfelt _resolve_owner_creds ein neues, ungueltiges Passwort (der Owner existiert, Login laeuft ueber den
  # API-Key).
  if [ "${OWNER_SETUP_DONE:-0}" = 1 ] && [ -z "${N8N_OWNER_PASSWORD:-}" ] && [ -n "${OWNER_PLAINTEXT:-}" ]; then
    _pw_line="Passwort       : ${OWNER_PLAINTEXT}  (erzeugt — wird nur jetzt angezeigt, bitte notieren)"
  fi
  _skipped="$(_recap_skipped_pkg_keys)"

  # Noch zu tun — nur offene Punkte, in der Reihenfolge, in der sie zu erledigen sind.
  if [ -n "${FAILED_PACKAGES:-}" ]; then
    _todo="${_todo}  ${_n}. Nicht fertig installiert: ${FAILED_PACKAGES} — Installation erneut starten (setzt fort).
"; _n=$((_n + 1))
  fi
  # Fehlende Pflicht-Schluessel (interaktiv nicht ueberspringbar — erreichbar nur ueber ein unbeaufsichtigtes
  # Update einer Bestandsinstanz) -> der eine Nachtrag-Weg `lifeagents reconfigure`.
  local _miss=''
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] || _miss="${_miss:+$_miss, }Telegram-Bot-Token"
  [ -n "${ANTHROPIC_API_KEY:-}" ]  || _miss="${_miss:+$_miss, }Anthropic-API-Schlüssel"
  if [ -n "$_miss" ]; then
    _todo="${_todo}  ${_n}. ${_miss} nachtragen: lifeagents reconfigure (Grundsystem)
"; _n=$((_n + 1))
  fi
  case "${OWNER_CONNECT_RESULT:-}" in
    connected) : ;;
    unfinished)
      _todo="${_todo}  ${_n}. Telegram ist verbunden, der Bot aber noch nicht auf dich eingestellt (Bestätigungen gehen so nicht) —
     ${OWNER_CONNECT_FIX}
"; _n=$((_n + 1)) ;;
    unavailable)
      _todo="${_todo}  ${_n}. Telegram-Verbindung noch nicht möglich (${OWNER_CONNECT_REASON:-Voraussetzung fehlt}) —
     ${OWNER_CONNECT_FIX:-danach verbinden mit: lifeagents household pair-owner}
"; _n=$((_n + 1)) ;;
    *)
      if [ "$(reach_cli_mode)" = tunnel ] && ! rt_is_compose; then
        _todo="${_todo}  ${_n}. Tunnel fertig einrichten: lifeagents reconfigure core → 'Unverändert neu anwenden'
     (zeigt den Tailscale-Link; Stand: lifeagents proxy show).
"; _n=$((_n + 1))
      elif [ -n "$DOMAIN" ]; then
        _todo="${_todo}  ${_n}. Reverse Proxy einrichten (Vorlage oben bzw. ${LIFEAGENTS_DIR:-/etc/lifeagents}/reverse-proxy.caddyfile)
     und im Router Port 443 auf diesen Server weiterleiten.
"; _n=$((_n + 1))
      fi
      _todo="${_todo}  ${_n}. Mit Telegram verbinden:   lifeagents household pair-owner
     (prüft die Erreichbarkeit, zeigt deinen Verbindungs-Link und wartet auf dich)
"; _n=$((_n + 1)) ;;
  esac
  [ -n "$_skipped" ] && { _todo="${_todo}  ${_n}. Übersprungene Zugangsdaten nachtragen (siehe oben), wenn du die Funktionen nutzen willst.
"; _n=$((_n + 1)); }

  # So geht's weiter — der gefuehrte naechste Schritt:
  # (1) Telegram (die Begruessung mit „Haushalt einrichten" hat owner_connect nach dem Einrichten geschickt),
  # (2) Funktionen dazunehmen — gebuendelte, aber nicht aktive Pakete mit Einzeiler; ausgeschaltete mit
  #     `activate` (ein install wuerde sie nicht einschalten), (3) Hilfe/Diagnose.
  local _more='' _off='' _ap _an _as _st _reg
  # `|| true`: set -euo pipefail — ein psql-Fehler am Ende darf den Recap nicht abbrechen (wie _installed_packages).
  _reg=" $( { _pkg_psql_scalar "SELECT package || ':' || status FROM core.package_registry" 2>/dev/null || true; } | tr '\n' ' ') "
  while IFS= read -r _ap; do
    [ -n "$_ap" ] || continue
    case "$_reg" in
      *" ${_ap}:active "*)   continue ;;
      *" ${_ap}:inactive "*) _st=inactive ;;
      *)                     _st=absent ;;
    esac
    _an="$(pkg_text "$_ap" package.name)"
    _as="$(pkg_text "$_ap" package.summary)"
    if [ "$_st" = inactive ]; then
      _off="${_off}       • ${_an:-$_ap} — ${_as}  (lifeagents package activate ${_ap})
"
    else
      _more="${_more}       • ${_an:-$_ap} — ${_as}
"
    fi
  done <<<"$(_bundled_packages)"
  local _next _tg
  case "${OWNER_CONNECT_RESULT:-}" in
    connected)
      if [ "${OWNER_WELCOME_SENT:-0}" = 1 ]; then
        _tg='  1. In Telegram: dein Bot hat dir gerade geschrieben — tippe dort „Haushalt einrichten"
     (jederzeit wieder: /onboarding). Dich kennt er schon aus dieser Installation.'
      else
        _tg="  1. In Telegram: schreib deinem Bot /start — er zeigt dir den nächsten Schritt
     (Haushalt einrichten bzw. Stand ansehen: /onboarding)."
      fi ;;
    *)
      _tg='  1. Telegram verbinden (siehe „Noch zu tun"), danach in Telegram /start schreiben.' ;;
  esac
  _next="${_tg}
"
  if [ -n "$_more$_off" ]; then
    _next="${_next}  2. Funktionen dazunehmen — jederzeit, mit Auswahl-Liste: lifeagents package install
${_more}${_off:+     Ausgeschaltet (wieder einschalten mit dem Befehl dahinter):
${_off}}"
  else
    _next="${_next}  2. Alle Funktionen sind installiert. Einzelne ausschalten: lifeagents package deactivate <paket>
"
  fi
  _next="${_next}  3. Überblick im Chat: /help · Zustand prüfen: lifeagents doctor"

  # Keine Datenbank-Passwoerter im Terminal: sie liegen root-only in den Env-Dateien; ein Ausdruck landete
  # nur in Scrollback/Screenshots.
  ui_box 'Installation abgeschlossen' <<EOF
Installiert
  Weg ins Internet: $(reach_cli_mode_label "$(reach_cli_mode)")
  Internet-Adresse: ${DOMAIN:-— (nur Heimnetz, kein Zugang von außen)}
  Funktionen      : Grundsystem${INSTALLED_PACKAGES:+, ${INSTALLED_PACKAGES}}
  Telegram        : $( [ "${OWNER_CONNECT_RESULT:-}" = "connected" ] && printf 'verbunden' || printf 'noch nicht verbunden (siehe „Noch zu tun")')

n8n-Anmeldung (Verwaltungsoberfläche, nur für Wartung)
  E-Mail         : ${N8N_OWNER_EMAIL:-owner@${DOMAIN:-example.com}}
  ${_pw_line:-Passwort       : nicht erneut angezeigt (selbst gewählt bzw. bei der Erstinstallation angezeigt)}

Schlüssel
  Telegram-Bot   : $(_recap_status "${TELEGRAM_BOT_TOKEN:-}" 'ohne Bot keine Chats — nachtragen s. „Noch zu tun"' 1)
  Anthropic      : $(_recap_status "${ANTHROPIC_API_KEY:-}" 'ohne ihn antworten die Agenten nicht — nachtragen s. „Noch zu tun"' 1)
  Google         : $(_recap_status "${GOOGLE_API_KEY:-}" 'ohne ihn keine Sprachnachrichten — nachtragen: lifeagents reconfigure')
${_skipped:+
Übersprungene Zugangsdaten
${_skipped}
}
Gespeichert (nur für Wartung nötig)
  Interne Zugänge und Datenbank-Passwörter: ${LIFEAGENTS_DIR:-/etc/lifeagents}/ und /etc/n8n/n8n.env
  Protokoll dieser Installation: ${UI_LOG_FILE:-/var/log/lifeagents/install.log}

${_todo:+Noch zu tun
${_todo}
}So geht's weiter
${_next}
EOF
}

# _setup_backup_folder — Antwort BACKUP_PARENT_DIR des Fragebogens (der Eltern-Ordner, z. B. iCloud Drive; eigener Name, weil
#   core.env unter BACKUP_HOST_DIR den angelegten Unterordner fuehrt — ein Wiederholungslauf legte sonst einen Ordner im
#   Ordner an): Unterordner anlegen, merken, sofort die erste Sicherung. Fehler = Warnung, kein Abbruch (der Tick versucht es
#   erneut, doctor und der Chat-Hinweis melden es).
_setup_backup_folder() {
  local cli="${LIFEAGENTS_BIN:-/usr/local/bin/lifeagents}"
  ui_step 'Sicherung einrichten' backup
  if "$cli" backup host-dir "$BACKUP_PARENT_DIR" --create </dev/null && "$cli" backup export </dev/null; then
    ui_step_done
  else
    ui_step_bad 'erste Sicherung nicht geschrieben — sie wird von selbst erneut versucht (lifeagents doctor)'
  fi
}

# _recap_backup_kit — nach der Erstinstallation, die den Sicherungs-Schluessel gerade erzeugt hat (BACKUP_KEY_NEW):
#   das Notfallblatt einmal zeigen, aber nur auf einem Kanal ohne Log — Quiet-Modus fd3 (Terminal), sonst direkt /dev/tty
#   (an `| tee` vorbei). Ohne Terminal (unattended, Wizard, Pipe) nur der Hinweis-Befehl; im Docker-Verbund speichert die
#   Start-App das Blatt. Plain statt ui_box: Rahmenzeichen vor den Schluesselzeilen stoerten beim Abtippen/Kopieren.
_recap_backup_kit() {
  [ "$PROFILE" = "release" ] && [ "${BACKUP_KEY_NEW:-0}" = 1 ] || return 0
  local kit='' lang sep='============================================================'
  lang="$(backup_kit_lang)"
  if { [ "${UI_QUIET:-0}" = 1 ] || ui_interactive; } && kit="$(backup_kit_text 2>/dev/null)" && [ -n "$kit" ]; then
    kit="$(printf '%s\n%s\n\n%s\n%s' "$sep" "$(pkg_text core backup.kit.recap_once "$lang")" "$kit" "$sep")"
    if [ "${UI_QUIET:-0}" = 1 ]; then
      _ui_spin_stop
      { printf '\n%s\n\n' "$kit" >&3; } 2>/dev/null || true
    else
      { printf '\n%s\n\n' "$kit" > /dev/tty; } 2>/dev/null || true
    fi
    return 0
  fi
  local line
  if rt_is_compose; then line="$(pkg_text core backup.kit.recap_line_app "$lang")"; else line="$(pkg_text core backup.kit.recap_line "$lang")"; fi
  printf '\n  %s\n\n' "$line"
  if [ "${UI_QUIET:-0}" = 1 ]; then { printf '\n  %s\n\n' "$line" >&3; } 2>/dev/null || true; fi
}

# install_cli — die `lifeagents`-Admin-CLI nach /usr/local/bin legen (Verbund: <Baum>/bin im Volume rt_tree) + den
# Runtime-Baum nach lifeagents_runtime_dir (Standard /usr/local/lib/lifeagents) spiegeln, damit
# `lifeagents update/doctor/uninstall` ohne Netz laufen. Gespiegelt wird der gesamte provisioning/-Baum ohne
# install.sh (der Wegwerf-Bootstrap gehoert nicht in die Runtime) + packages/ (REPO_ROOT-relativ, damit der
# gespiegelte provision.sh self-contained bleibt) + der Marker VERSION. Die CLI schreibt write_if_changed nur
# bei Aenderung; der Baum wird je Lauf frisch gespiegelt (atomarer Swap je Top-Eintrag).
install_cli() {
  local libdir bindir="/usr/local/bin"
  libdir="$(lifeagents_runtime_dir)"   # eine Adresse (common.sh) — auch fuer den Erfolgs-Marker VERSION unten
  # Docker-Verbund: /usr/local/bin liegt im Container-Dateisystem des master und waere nach seiner Neuanlage (Update =
  # Image-Wechsel) weg -> die CLI liegt im Baum-Volume rt_tree, das Image verlinkt /usr/local/bin/lifeagents dorthin.
  if rt_is_compose; then bindir="$libdir/bin"; mkdir -p "$bindir"; fi
  log "lifeagents-Admin-CLI installieren (${bindir}/lifeagents) + Runtime-Baum spiegeln ..."
  mkdir -p "$libdir"
  rm -rf "$libdir"/.staging.* 2>/dev/null || true   # Reste eines abgebrochenen Laufs raeumen

  # In ein Staging spiegeln, dann je Top-Eintrag atomar einschwenken — ein abgebrochenes cp (Disk
  # voll, Kill) laesst den alten Baum intakt (statt einem halb-gespiegelten Verzeichnis).
  local staging="$libdir/.staging.$$"
  rm -rf "$staging"; mkdir -p "$staging"
  cp -a "$REPO_ROOT/provisioning" "$staging/provisioning"
  rm -f "$staging/provisioning/install.sh"   # Bootstrap-Launcher gehoert nicht in die Runtime
  [ -d "$REPO_ROOT/packages" ] && cp -a "$REPO_ROOT/packages" "$staging/packages"   # Paket-Baum (Core + Pakete)
  # Installierte Version: fetch_release/Bootstrap exportieren RELEASE_TAG vor dem exec des gepinnten Kerns
  # (`--version <tag>`/`latest`); ein direkter dev-Lauf hat keinen Tag -> 'dev'.
  printf '%s\n' "${RELEASE_TAG:-dev}" > "$staging/VERSION"
  chmod 0644 "$staging/VERSION"

  local d
  for d in provisioning packages VERSION; do
    [ -e "$staging/$d" ] || continue           # packages/ ist optional (cp oben nur wenn vorhanden)
    rm -rf "$libdir/$d.old"
    [ -e "$libdir/$d" ] && mv "$libdir/$d" "$libdir/$d.old"
    mv "$staging/$d" "$libdir/$d"
    rm -rf "$libdir/$d.old"
  done
  rm -rf "$staging"

  if render_template "$TEMPLATE_DIR/lifeagents.tpl" LIBDIR="$libdir" | write_if_changed "$bindir/lifeagents" 0755; then
    ok "lifeagents-CLI installiert/aktualisiert (${bindir}/lifeagents) — 'lifeagents update' zieht das neueste Release."
  else
    log "lifeagents-CLI unveraendert."
  fi
}

main "$@"
