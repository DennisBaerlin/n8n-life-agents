#!/usr/bin/env bash
# move_unlock.sh — verschluesselte Umzugs-Antworten (move.env.gpg aus `lifeagents retire`) IM master entschluesseln, bevor
#   setup.sh --answers einrichtet: vor der ersten Installation gibt es den Befehl lifeagents im master noch nicht. Fragt einmal den
#   Schluessel vom Notfallblatt und legt ihn fuer `lifeagents move apply` ab (Mechanik: lib/move_cli.sh move_unlock). Feste Pfade im
#   tmpfs /run/lifeagents-wizard, damit setup.sh genau eine Aufruf-Form braucht (contract_lint, Positivliste von setup.sh).
#
# Usage (im master, root; setup.sh ruft es per docker exec):
#   bash /opt/lifeagents/provisioning/compose/move_unlock.sh put    stdin -> verschluesselte Datei (0600)
#   bash /opt/lifeagents/provisioning/compose/move_unlock.sh open   mit Terminal: Schluessel fragen, entschluesseln (0600)
#   bash /opt/lifeagents/provisioning/compose/move_unlock.sh take   Klartext auf stdout
#   bash /opt/lifeagents/provisioning/compose/move_unlock.sh drop [all]   beide Dateien loeschen; mit all auch den abgelegten
#        Schluessel (Einrichtung gescheitert oder abgebrochen), solange kein Umzug offen ist (dann braucht ihn move apply)
# Exit: 0 ok; 1 Abbruch (kein Terminal, Schluessel passte dreimal nicht, Datei fehlt), nichts geaendert; 2 unbekanntes Verb.
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"   # Texte (packages/core/locales) vor der Installation: der Baum des master-Abbilds
export REPO_ROOT
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
# shellcheck source=../lib/backup_cli.sh
. "$HERE/../lib/backup_cli.sh"
# shellcheck source=../lib/move_cli.sh
. "$HERE/../lib/move_cli.sh"
d=/run/lifeagents-wizard enc=/run/lifeagents-wizard/move.env.gpg plain=/run/lifeagents-wizard/move.answers
case "${1:-}" in
  put)  ( umask 077; mkdir -p "$d" && cat > "$enc" ) || die "Die Umzugs-Antworten ließen sich nicht ablegen ($enc)." ;;
  open) move_unlock "$enc" "$plain" ;;
  take) [ -r "$plain" ] || die "Keine entschlüsselten Umzugs-Antworten ($plain)."; cat "$plain" ;;
  drop) rm -f -- "$enc" "$plain"; if [ "${2:-}" = all ] && ! la_move_open; then rm -f -- "$(_mv_key_file)"; fi ;;
  *)    printf 'Aufruf: move_unlock.sh put|open|take|drop\n' >&2; exit 2 ;;
esac
