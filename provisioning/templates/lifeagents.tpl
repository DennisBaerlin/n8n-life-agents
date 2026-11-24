#!/usr/bin/env bash
# lifeagents — Runtime-CLI der n8n-life-agents-Instanz. Generiert von provisioning (install_cli);
# nicht hand-editieren — `lifeagents update` ueberschreibt die Datei mit der Release-Version.
#
# Muster: ein Verb-Dispatcher wie `openclaw <verb>` / `rustup <verb>` — der einzige Runtime-Einstieg
# fuer den ganzen Lebenszyklus. Die Logik liegt im gespiegelten Provisioning-Baum
# (@@LIBDIR@@/provisioning). `update` traegt die Fetch-Logik selbst (gespiegelte lib/fetch_release.sh),
# laedt das neueste Release und startet den neuen provision.sh — ruft nie install.sh (der Wegwerf-
# Bootstrap lebt nicht in der Runtime).
#
# Aufruf: lifeagents <befehl> [optionen] (Liste: `lifeagents help`). Exit: help/version 0; unbekannter Befehl, fehlende
# lib/ im Baum oder fehlendes root 1; sonst der Exit des Verbs (doctor = Anzahl ROT).
set -euo pipefail
# UTF-8 ist Gesetz (provisioning/CLAUDE.md): alle Verben (doctor, config list, Pager) laufen in UTF-8, egal was das
# System sagt (Proxmox-Vorlagen: LANG="C" -> Umlaute als <C3><A4> im Pager).
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# psql-Pager hart aus (erbt in jede runuser/psql-Kette): auf dem interaktiven Terminal wuerde psql
# sonst seine Ausgaben pagen ('--More--', wartet auf Tastendruck) — package install/list etc. hingen.
# Den Pager des Owners vorher merken: lange Anzeige-Listen (`config list`, ui_page in common.sh) blaettern
# bewusst ueber ihn (sonst less) — der PAGER=cat-Export unten gilt psql und kuenftigen systemctl-Ausgaben.
# shellcheck disable=SC2034  # gelesen von ui_page (lib/common.sh, im selben Prozess gesourct)
LIFEAGENTS_USER_PAGER="${PAGER-}"
export PSQL_PAGER=cat PAGER=cat

LIFEAGENTS_LIB="@@LIBDIR@@"
LIFEAGENTS_PROV="${LIFEAGENTS_LIB}/provisioning"
LIFEAGENTS_PROVISION="${LIFEAGENTS_PROV}/provision.sh"
LIFEAGENTS_DOCTOR="${LIFEAGENTS_PROV}/doctor.sh"
LIFEAGENTS_VERSION_FILE="${LIFEAGENTS_LIB}/VERSION"

usage() {
  cat >&2 <<'EOF'
lifeagents — Verwaltung der n8n-life-agents-Instanz.

Usage: lifeagents <befehl> [optionen]
       lifeagents            (ohne Befehl auf einem Terminal: interaktives Menue —
                              Pfeiltasten + Enter; fehlende Argumente werden per
                              Auswahl-Liste erfragt, Leertaste markiert bei Mehrfachwahl)

  update      Neuestes Release ziehen und installieren (SHA256-verifiziert).
              Idempotent -> wendet neue DB-Migrationen (V__/R__) automatisch mit an und
              laeuft am Ende doctor. Braucht root (kein GitHub-Konto/-Token: Download
              aus dem oeffentlichen Repo). Sichert vor jedem Versionswechsel die ganze DB.
              --version <tag> = genau dieses Release; aelter als installiert nur mit
              --allow-downgrade (besser: lifeagents rollback). Die Timer des Updates im Chat
              rufen intern --check --scheduled (Release-Check alle 2 Stunden) und --run-requested auf; im Docker-Verbund
              ersetzt die Schleife im master beide durch --tick (jede Minute).
  rollback    Nach einem gescheiterten Update zurück zur vorherigen Version: stellt die Daten
              der Sicherung von vor dem Update her und spielt den vorherigen Stand ein. Daten
              seit der Sicherung gehen verloren -> fragt vorher nach. Braucht root + Terminal; im
              Docker-Verbund --yes, wenn die Start-App schon selbst nachgefragt hat.
  package     Fach-Pakete verwalten: catalog/list/install/reconfigure/activate/deactivate/
              uninstall/doctor (Core/Package-Architektur). `lifeagents package help` für Details.
  reconfigure Angaben nach der Installation ändern oder neu anwenden: Grundsystem (Internet-Adresse,
              Telegram-Bot, Google-/Anthropic-Schlüssel) oder die Zugangsdaten eines Pakets; ohne
              Argument mit Auswahl-Liste. `lifeagents reconfigure help` für Details. Braucht root.
  config      Zentralen Config-Store (core.config) ansehen/ändern: list/set/reset/import. Cron-Schalter +
              Modell-/Tuning-Werte zur Laufzeit. `lifeagents config help` für Details.
  proxy       Reverse Proxy: show (Stand + Proxy-Konfiguration erneut) / set <ip> (Proxy auf einem
              anderen Rechner: n8n nur für diese Adresse öffnen; 127.0.0.1 = dieser Rechner). Braucht root.
  household   Owner-Lifecycle am Haushalt: list/add/remove/unlink/pair-owner (Personen) + block/unblock/
              blocked (unbekannte Anklopfer sperren). `lifeagents household help` für Details. Braucht root.
  backup      Nutzerdaten sichern/wiederherstellen: export/restore/key (verschluesselt, paket-bewusst,
              atomar); im Docker-Verbund außerdem host-dir/auto (Sicherungs-Ordner auf dem Rechner).
              `lifeagents backup help` für Details. Braucht root.
  telegram    Telegram-Bot warten: release-webhook (Webhook loesen; ruft die Start-App beim Abbau), relink (Bot wieder
              mit dieser Installation verbinden, wenn Telegram ihn nicht erreicht). `lifeagents telegram help` für Details.
  images      Docker-Verbund: keep = Abbilder, die Betrieb und Rückweg noch brauchen (JSON für die Start-App;
              nur lesen, löscht nichts). `lifeagents images help` für Details. Braucht root.
  retire      Umzug auf eine neue Maschine: diese Installation stilllegen und alles für die neue in einen
              Ordner legen; --check (Trockenlauf), --status, --undo [--restore <ordner>] (zurück).
              `lifeagents retire help` für Details. Braucht root.
  move        Umzug auf dieser (neuen) Maschine annehmen: apply <ordner> spielt Sicherung, Gedächtnis und Einstellungen ein,
              check (Vergleich mit der alten Maschine), status, done (Abnahme; bis dahin keine Updates), abort (Ausweg).
              `lifeagents move help` für Details. Braucht root.
  doctor      Diagnose (Dienste/Schema/Routen; read-only). Exit = Anzahl ROT.
  uninstall   Instanz abbauen (Schema DROP, Dienste stop; im Docker-Verbund entfernt die Start-App); --purge-data für den Voll-Wipe,
              --yes für ohne Rückfrage durchreichen: `lifeagents uninstall --purge-data --yes`. Braucht root.
  version     Installierte Release-Version anzeigen.
  help        Diese Hilfe.

Beispiel: lifeagents update
EOF
}

# Hauptmenue (Pfeiltasten-Picker) bei nacktem Aufruf auf einem TTY. Der $#-Check muss vor der
# cmd-Default-Substitution stehen: eine Zeile weiter kollabieren "kein Argument" und explizites
# `lifeagents help` beide auf cmd='help' und sind nicht mehr unterscheidbar. Non-TTY/unattended/
# ESC -> Usage (Exit 0, byte-identisch; Skripte sehen nie ein Menue). common.sh wird
# nur in diesem Zweig gesourct (Existenz-Guard analog der Verb-Arme) — doctor/version/help/
# uninstall funktionieren auch ohne libs. Bei uns anders:
# bare-Invocation-Menue statt gh-/clig.dev-Hilfetext -> docs/reference/provisioning.md *Entscheidungen*.
if [ "$#" -eq 0 ] && [ -f "${LIFEAGENTS_PROV}/lib/common.sh" ]; then
  # shellcheck source=/dev/null
  . "${LIFEAGENTS_PROV}/lib/common.sh"
  if ui_interactive; then
    ensure_gum
    menu_choice="$(ui_choose 'lifeagents — was moechtest du tun?' 0 <<'MENU'
update — Neuestes Release ziehen und installieren	update
package — Fach-Pakete verwalten (Katalog/Install/...)	package
reconfigure — Angaben ändern (Telegram-Bot, Schlüssel, Adresse, Paket-Zugänge)	reconfigure
config — Zentrale Einstellungen ansehen/ändern	config
proxy — Reverse Proxy anzeigen/ändern	proxy
household — Haushalt: Personen + Sperrliste	household
backup — Nutzerdaten sichern/wiederherstellen	backup
rollback — Nach einem gescheiterten Update zurück zur vorherigen Version	rollback
doctor — Diagnose (read-only)	doctor
version — Installierte Version anzeigen	version
uninstall — Instanz abbauen (fragt vorher nach)	uninstall
help — Hilfe anzeigen	help
MENU
)"
    [ -n "$menu_choice" ] && exec "$0" "$menu_choice"
  fi
fi

cmd="${1:-help}"
# Befehle unabhaengig von der Schreibweise (z. B. "lifeagents Update" vom Handy).
cmd="${cmd,,}"
[ "$#" -gt 0 ] && shift || true

# Stillgelegt (lib/retire_cli.sh): nur lesende Befehle, Sicherungen, der Abbau und `retire` selbst laufen; alles andere (n8n
# starten, umbauen, Daten aendern: der Umzugs-Ordner ist geschrieben, Geaendertes fehlte der neuen Maschine) endet hier mit einem
# Satz statt tief im Lauf an der Sperre in lib/runtime.sh. Positivliste: ein neues Verb ist gesperrt, bis es hier steht. Der
# Minuten-Takt (`update --tick`) darf durch, er setzt selbst aus.
_retired=0
if [ -f "${LIFEAGENTS_PROV}/lib/runtime.sh" ]; then
  # shellcheck source=/dev/null
  . "${LIFEAGENTS_PROV}/lib/runtime.sh"
  if la_is_retired; then _retired=1; fi
fi
# _retired_allows <befehl> [args…] — 0, wenn der Befehl auf einer stillgelegten Installation laufen darf. Eigene Funktion statt einer
#   zweiten `case "$cmd"`-Stelle: die Verb-Arme des Verteilers liest contract_lint (Hilfe <-> Arme) an der ersten.
_retired_allows() {
  local verb="$1"; shift
  case "$verb" in
    retire|doctor|version|--version|-v|help|--help|-h|images|uninstall) return 0 ;;
    telegram)  case "${1:-}" in release-webhook|help|--help|-h) return 0 ;; esac ;;   # relink holt den Bot zurueck: auf einer stillgelegten Installation nie
    update) [ "${1:-}" = --tick ]; return ;;
    backup)
      case "${1:-}" in
        export|key|list|auto|host-dir|restore-status|help|--help|-h) return 0 ;;
        restore) case " $* " in *" --plan "*) return 0 ;; esac ;;   # der Probelauf aendert nichts
      esac ;;
    config)    case "${1:-}" in list|help|--help|-h) return 0 ;; esac ;;
    household) case "${1:-}" in list|blocked|help|--help|-h) return 0 ;; esac ;;
    package)   case "${1:-}" in list|catalog|doctor|help|--help|-h) return 0 ;; esac ;;
    proxy)     case "${1:-}" in show|help|--help|-h) return 0 ;; esac ;;
  esac
  return 1
}
if [ "$_retired" = 1 ]; then
  if ! _retired_allows "$cmd" "$@"; then
    printf 'lifeagents %s: diese Installation ist stillgelegt (Umzug). Zurück: lifeagents retire --undo\n' "$cmd" >&2
    exit 1
  fi
fi

case "$cmd" in
  update)
    # Fetch-Logik selbst tragen (kein install.sh-Aufruf): die gespiegelte lib/ sourcen und
    # fetch_and_run_release fahren -> laedt 'latest', verifiziert, entpackt, exec't den NEUEN
    # provision.sh (re-spiegelt CLI + Baum -> self-updating). Root erzwingt die Lib; der Download ist anonym (keine
    # Frage -> release_inputs.sh wird hier nicht gebraucht).
    for f in common.sh fetch_release.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
    done
    # shellcheck source=/dev/null
    . "${LIFEAGENTS_PROV}/lib/common.sh"
    # shellcheck source=/dev/null
    . "${LIFEAGENTS_PROV}/lib/fetch_release.sh"
    # Optionen (--version/--allow-downgrade) + die Timer-Modi des Updates im Chat (--check/--run-requested) wertet
    # update_cli aus (lib/update_runner.sh); deploy_workflows.sh = Owner-chat_id aus der DB fuer die Chat-Meldungen.
    for f in deploy_workflows.sh update_runner.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    update_cli "$@"
    ;;
  rollback)
    # Gefuehrter Rueckweg nach einem gescheiterten Update (lib/upgrade_guard.sh upgrade_rollback): Daten von vor dem
    # Update + vorheriger Stand, mit Rueckfrage. fetch_release.sh = Download des alten install.sh, deploy_workflows.sh =
    # Owner-chat_id fuer die Fertig-Meldung.
    for f in common.sh fetch_release.sh deploy_workflows.sh upgrade_guard.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    upgrade_rollback "$@"
    ;;
  package)
    # Fach-Paket-Lebenszyklus: common.sh + pkg_lifecycle.sh + pkg_teardown.sh sourcen und dispatchen.
    # Braucht root (DB-Zugriff via runuser postgres-Peer-Auth; uninstall stoppt/startet n8n). pkg_teardown.sh
    # traegt die n8n-REST-Teardown-Helfer fuer `uninstall`. release_inputs.sh liefert
    # _prompt_validated + die Validator-fns fuer den Stage-4-Secrets-Wizard/`reconfigure`.
    # install braucht die paket-skopierten Primitive (apply_schema/seed_data/inject_credentials/
    # deploy_workflows) — denselben Code wie provision.sh (ein Code-Pfad, zwei Aufrufer).
    for f in common.sh release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
    done
    [ "$(id -u)" -eq 0 ] || { printf 'lifeagents package: braucht root (DB-Zugriff).\n' >&2; exit 1; }
    # LIFEAGENTS_LIB ist oben gesetzt + in dieser Shell sichtbar -> _pkg_dir/_pkg_resolve_env finden den Baum.
    # shellcheck source=/dev/null
    . "${LIFEAGENTS_PROV}/lib/common.sh"
    for f in release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh; do
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    pkg_lifecycle "$@"
    ;;
  reconfigure)
    # Angaben nach der Installation aendern: Grundsystem (core.env-Host-Keys -> voller Converge des
    # installierten Baums, run_installed_release) oder ein Paket (pkg_cmd_reconfigure). Braucht die household-
    # Bibliotheken (Owner-Skelett-Pruefung, Proxy-Frage, Proxy-Vorlage) + fetch_release.sh. Braucht root.
    for f in common.sh release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh bootstrap_owner.sh firewall.sh owner_connect.sh fetch_release.sh reconfigure_cli.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
    done
    [ "$(id -u)" -eq 0 ] || { printf 'lifeagents reconfigure: braucht root (core.env + DB-Zugriff).\n' >&2; exit 1; }
    # shellcheck disable=SC2034  # von der dynamisch gesourcten release_inputs.sh gelesen (load_install_env/_store_answer)
    INSTALL_ENV_FILE="/etc/lifeagents/core.env"
    # shellcheck source=/dev/null
    . "${LIFEAGENTS_PROV}/lib/common.sh"
    for f in release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh bootstrap_owner.sh firewall.sh owner_connect.sh fetch_release.sh reconfigure_cli.sh; do
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    reconfigure_cli "$@"
    ;;
  config)
    # Zentraler Config-Store (core.config): config_cli.sh sourcen und dispatchen. Braucht root (DB-Zugriff via
    # runuser postgres-Peer-Auth, host-vermittelt). list = read-only, set = UPDATE-only (kein INSERT;
    # package-Ownership unveraenderbar). Ein geaenderter Zeitplan spielt die Workflows des Pakets neu ein ->
    # dieselben Deploy-Primitive wie der `package`-Arm (deploy_workflows + _pkg_resolve_env, ein Code-Pfad).
    for f in common.sh release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh config_cli.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
    done
    [ "$(id -u)" -eq 0 ] || { printf 'lifeagents config: braucht root (DB-Zugriff).\n' >&2; exit 1; }
    # shellcheck source=/dev/null
    . "${LIFEAGENTS_PROV}/lib/common.sh"
    for f in release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh config_cli.sh; do
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    config_cli "$@"
    ;;
  proxy)
    # Reverse Proxy: wo laeuft er, wem ist n8n geoeffnet (TRUSTED_PROXIES in core.env).
    # show = Stand + Proxy-Konfiguration erneut; set = speichern + ueber provision.sh --apply-network anwenden.
    for f in common.sh release_inputs.sh firewall.sh owner_connect.sh proxy_cli.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
    done
    for f in common.sh release_inputs.sh firewall.sh owner_connect.sh proxy_cli.sh; do
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    proxy_cli "$@"
    ;;
  household)
    # Owner-Lifecycle am Haushalt (Personen-CRUD + Knocker-Sperre): common.sh + household_cli.sh
    # sourcen und dispatchen. Braucht root (DB-Zugriff via runuser postgres-Peer-Auth, host-vermittelt).
    # `pair-owner` faehrt das gefuehrte Ende der Installation (owner_connect.sh: Erreichbarkeit, Pairing,
    # Workflows mit der chat_id neu deployen) -> dieselben Install-Primitive wie der package-/backup-Arm.
    for f in common.sh release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh bootstrap_owner.sh firewall.sh owner_connect.sh household_cli.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
    done
    [ "$(id -u)" -eq 0 ] || { printf 'lifeagents household: braucht root (DB-Zugriff).\n' >&2; exit 1; }
    # shellcheck disable=SC2034  # von der dynamisch gesourcten release_inputs.sh gelesen (load_install_env)
    INSTALL_ENV_FILE="/etc/lifeagents/core.env"
    # shellcheck source=/dev/null
    . "${LIFEAGENTS_PROV}/lib/common.sh"
    for f in release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh bootstrap_owner.sh firewall.sh owner_connect.sh household_cli.sh; do
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    household_cli "$@"
    ;;
  backup)
    # Backup/Restore der Nutzerdaten: common.sh + backup_cli.sh + die Install-Primitive
    # (Restore-vor-Install ruft pkg_install_one --no-seed). Braucht root (pg_dump/pg_restore + core.backup_key
    # + ggf. per-Paket-Install). Derselbe Install-Code wie `lifeagents package install`.
    for f in common.sh release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh backup_cli.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
    done
    [ "$(id -u)" -eq 0 ] || { printf 'lifeagents backup: braucht root (DB-Zugriff).\n' >&2; exit 1; }
    # shellcheck source=/dev/null
    . "${LIFEAGENTS_PROV}/lib/common.sh"
    for f in release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh backup_cli.sh; do
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    backup_cli "$@"
    ;;
  telegram)
    # Bot-Wartung (release-webhook fuer die Start-App beim Abbau, relink). Kein root-Zwang: der Schluessel kommt aus Env/core.env.
    for f in common.sh deploy_workflows.sh owner_connect.sh telegram_cli.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    telegram_cli "$@"
    ;;
  images)
    # Lesende Liste fuer die Start-App (lib/images_cli.sh); Pfade von Sicherungen und master-Wechsel kommen aus
    # upgrade_guard.sh bzw. master_swap.sh (ueber fetch_release.sh).
    for f in common.sh fetch_release.sh deploy_workflows.sh upgrade_guard.sh images_cli.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    images_cli "$@"
    ;;
  retire)
    # Umzug (lib/retire_cli.sh): Sicherung + Restore wie der backup-Arm, Bot ueber telegram_cli.sh, Unit-Namen aus den
    # Install-Libs der Timer und des Gateways (nur Namen, nichts wird installiert).
    for f in common.sh release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh backup_cli.sh telegram_cli.sh install_update_timers.sh install_backup_timer.sh install_llm_gateway.sh retire_cli.sh; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
    done
    # shellcheck source=/dev/null
    . "${LIFEAGENTS_PROV}/lib/common.sh"
    for f in release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh backup_cli.sh telegram_cli.sh install_update_timers.sh install_backup_timer.sh install_llm_gateway.sh retire_cli.sh; do
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    export LIFEAGENTS_DOCTOR
    retire_cli "$@"
    ;;
  move)
    # Annahme auf der neuen Maschine (lib/move_cli.sh): Sicherung + Restore wie der backup-Arm, Gedaechtnis und Ordner-Zugriff aus
    # retire_cli.sh, Einstellungen aus config_cli.sh, der Abschluss (Bot auf die chat_id einstellen) aus owner_connect.sh wie bei
    # `household pair-owner`. Auf einer stillgelegten (alten) Maschine gibt es ihn nicht (_retired_allows).
    _move_libs="release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh bootstrap_owner.sh firewall.sh owner_connect.sh backup_cli.sh telegram_cli.sh install_update_timers.sh install_backup_timer.sh install_llm_gateway.sh retire_cli.sh config_cli.sh move_cli.sh"
    # shellcheck disable=SC2086  # bewusst in Dateinamen zerlegt
    for f in common.sh $_move_libs; do
      [ -f "${LIFEAGENTS_PROV}/lib/$f" ] || { printf 'lifeagents: lib/%s fehlt (%s) — Baum beschaedigt.\n' "$f" "${LIFEAGENTS_PROV}/lib/$f" >&2; exit 1; }
    done
    # shellcheck disable=SC2034  # von der dynamisch gesourcten release_inputs.sh gelesen (load_install_env)
    INSTALL_ENV_FILE="/etc/lifeagents/core.env"
    # shellcheck source=/dev/null
    . "${LIFEAGENTS_PROV}/lib/common.sh"
    # shellcheck disable=SC2086  # bewusst in Dateinamen zerlegt
    for f in $_move_libs; do
      # shellcheck source=/dev/null
      . "${LIFEAGENTS_PROV}/lib/$f"
    done
    move_cli "$@"
    ;;
  doctor)
    [ -f "$LIFEAGENTS_DOCTOR" ] || { printf 'lifeagents: doctor.sh fehlt (%s).\n' "$LIFEAGENTS_DOCTOR" >&2; exit 1; }
    exec bash "$LIFEAGENTS_DOCTOR" "$@"
    ;;
  uninstall)
    [ -f "$LIFEAGENTS_PROVISION" ] || { printf 'lifeagents: provision.sh fehlt (%s).\n' "$LIFEAGENTS_PROVISION" >&2; exit 1; }
    exec bash "$LIFEAGENTS_PROVISION" --uninstall "$@"
    ;;
  version|--version|-V)
    # Ohne VERSION (der Erfolgs-Marker von install_cli; das reversible Deinstallieren entfernt ihn) gibt es keine
    # installierte Release-Version.
    if [ -r "$LIFEAGENTS_VERSION_FILE" ]; then cat "$LIFEAGENTS_VERSION_FILE"; else echo "keine installierte Release-Version (Entwicklungs-Stand oder deinstalliert)"; fi
    ;;
  --update)
    # openclaw-Stil: das Flag schreibt auf das Verb um.
    exec "$0" update "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    # Hinweis nach der (langen) Liste: davor scrollte er aus dem Bild und es sah aus, als zeige der Befehl nur die Hilfe.
    usage
    printf '\nlifeagents: unbekannter Befehl: %s (siehe Liste oben)\n' "$cmd" >&2
    exit 1
    ;;
esac
