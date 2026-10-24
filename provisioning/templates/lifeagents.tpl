#!/usr/bin/env bash
# lifeagents — Runtime-CLI der n8n-life-agents-Instanz. GENERIERT von provisioning (install_cli);
# nicht hand-editieren — `lifeagents update` ueberschreibt die Datei mit der Release-Version.
#
# Muster: ein Verb-Dispatcher wie `openclaw <verb>` / `rustup <verb>` — DER einzige Runtime-Einstieg
# fuer den ganzen Lebenszyklus. Die Logik liegt im gespiegelten Provisioning-Baum
# (@@LIBDIR@@/provisioning). `update` traegt die Fetch-Logik selbst (gespiegelte lib/fetch_release.sh),
# laedt das neueste Release und startet den neuen provision.sh — ruft NIE install.sh (der Wegwerf-
# Bootstrap lebt nicht in der Runtime).
set -euo pipefail
# UTF-8 ist Gesetz (provisioning/CLAUDE.md): alle Verben (doctor, config list, Pager) laufen in UTF-8, egal was das
# System sagt (Proxmox-Vorlagen: LANG="C" -> Umlaute als <C3><A4> im Pager).
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# psql-Pager hart aus (erbt in jede runuser/psql-Kette): auf dem interaktiven Terminal wuerde psql
# sonst seine Ausgaben pagen ('--More--', wartet auf Tastendruck) — package install/list etc. hingen.
# Den Pager des Owners VORHER merken: lange Anzeige-Listen (`config list`, ui_page in common.sh) blaettern
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
              rufen intern --check (taeglicher Release-Check) und --run-requested auf.
  rollback    Nach einem gescheiterten Update zurück zur vorherigen Version: stellt die Daten
              der Sicherung von vor dem Update her und spielt den vorherigen Stand ein. Daten
              seit der Sicherung gehen verloren -> fragt vorher nach. Braucht root + Terminal.
  package     Fach-Pakete verwalten: catalog/list/install/reconfigure/activate/deactivate/
              uninstall/doctor (Core/Package-Architektur). `lifeagents package help` für Details.
  reconfigure Angaben nach der Installation ändern oder neu anwenden: Grundsystem (Internet-Adresse,
              Telegram-Bot, Google-/Anthropic-Schlüssel) oder die Zugangsdaten eines Pakets; ohne
              Argument mit Auswahl-Liste. `lifeagents reconfigure help` für Details. Braucht root.
  config      Zentralen Config-Store (core.config) ansehen/ändern: list/set. Cron-Schalter +
              Modell-/Tuning-Werte zur Laufzeit. `lifeagents config help` für Details.
  proxy       Reverse Proxy: show (Stand + Proxy-Konfiguration erneut) / set <ip> (Proxy auf einem
              anderen Rechner: n8n nur für diese Adresse öffnen; 127.0.0.1 = dieser Rechner). Braucht root.
  household   Owner-Lifecycle am Haushalt: list/add/remove/unlink/pair-owner (Personen) + block/unblock/
              blocked (unbekannte Anklopfer sperren). `lifeagents household help` für Details. Braucht root.
  backup      Nutzerdaten sichern/wiederherstellen: export/restore (verschluesselt, paket-bewusst,
              atomar). `lifeagents backup help` für Details. Braucht root.
  doctor      Diagnose (Dienste/Schema/Routen; read-only). Exit = Anzahl ROT.
  uninstall   Instanz abbauen (Schema DROP, Dienste stop); --purge-data für den Voll-Wipe,
              --yes für ohne Rückfrage durchreichen: `lifeagents uninstall --purge-data --yes`. Braucht root.
  version     Installierte Release-Version anzeigen.
  help        Diese Hilfe.

Beispiel: lifeagents update
EOF
}

# Hauptmenue (Pfeiltasten-Picker) bei NACKTEM Aufruf auf einem TTY. Der $#-Check MUSS VOR der
# cmd-Default-Substitution stehen: eine Zeile weiter kollabieren "kein Argument" und explizites
# `lifeagents help` beide auf cmd='help' und sind nicht mehr unterscheidbar. Non-TTY/unattended/
# ESC -> Usage wie bisher (Exit 0, byte-identisch; Skripte sehen NIE ein Menue). common.sh wird
# NUR in diesem Zweig gesourct (Existenz-Guard analog der Verb-Arme) — doctor/version/help/
# uninstall funktionieren weiter auch ohne libs. Bei uns anders (arch-challenge, Opus-adjudiziert):
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
[ "$#" -gt 0 ] && shift || true

case "$cmd" in
  update)
    # Fetch-Logik SELBST tragen (kein install.sh-Aufruf): die gespiegelte lib/ sourcen und
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
    upgrade_rollback
    ;;
  package)
    # Fach-Paket-Lebenszyklus: common.sh + pkg_lifecycle.sh + pkg_teardown.sh sourcen und dispatchen.
    # Braucht root (DB-Zugriff via runuser postgres-Peer-Auth; uninstall stoppt/startet n8n). pkg_teardown.sh
    # traegt die n8n-REST-Teardown-Helfer fuer `uninstall` (WS-2). release_inputs.sh liefert
    # _prompt_validated + die Validator-fns fuer den Stage-4-Secrets-Wizard/`reconfigure` (Install-UX).
    # install braucht die paket-skopierten Primitive (apply_schema/seed_data/inject_credentials/
    # deploy_workflows) — DENSELBEN Code wie provision.sh (ein Code-Pfad, zwei Aufrufer).
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
    # Angaben nach der Installation aendern (Install-UX-Phase 7): Grundsystem (core.env-Host-Keys -> voller Converge des
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
    # Reverse Proxy (Install-UX-Phase 5): wo laeuft er, wem ist n8n geoeffnet (TRUSTED_PROXIES in core.env).
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
    # Owner-Lifecycle am Haushalt (Personen-CRUD + Knocker-Sperre, WS-5d): common.sh + household_cli.sh
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
    # Backup/Restore der Nutzerdaten (Phase 4b/5): common.sh + backup_cli.sh + die Install-Primitive
    # (Restore-vor-Install ruft pkg_install_one --no-seed). Braucht root (pg_dump/pg_restore + core.backup_key
    # + ggf. per-Paket-Install). DENSELBE Install-Code wie `lifeagents package install`.
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
    printf 'lifeagents: unbekannter Befehl: %s\n' "$cmd" >&2
    usage
    exit 1
    ;;
esac
