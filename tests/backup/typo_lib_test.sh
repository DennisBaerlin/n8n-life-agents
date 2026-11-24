#!/usr/bin/env bash
# typo_lib_test.sh — Selbsttest von typo_lib.sh ohne Substrat: ein Schluessel, dessen Zeile 3 den alten festen Tausch (erstes Zeichen
# -> f, sonst e) ueberlebt, wuerde im Fall P.probe-tippfehler als "fremdes Blatt" statt "Zeile 3" erscheinen. typo_char muss dort ein
# anderes Zeichen waehlen, und die Zeile muss danach wirklich durchfallen (backup_key_line rc 1).
# Usage: bash tests/backup/typo_lib_test.sh [<root>]     Exit = Anzahl Fehler. Gate: der Fall R.typo-lib in cases.sh (backup-Suite).
# shellcheck disable=SC2016,SC2034  # Pruef-Ausdruecke in einfachen Quotes (eval in ok), Variablen nur dort benutzt
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$(cd "$HERE/../.." && pwd)}"   # im Substrat liegt backup/ neben provisioning/ (cases.sh reicht ROOT durch)
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$HERE/typo_lib.sh"
fails=0
ok() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# Erfundener Schluessel, Zeile 3 = 1aad34c63aadb822: der alte Tausch (1 -> f) traegt dasselbe Pruefzeichen.
D3=1aad34c63aadb822
old="f${D3:1}"
ok 'Vorbedingung: der alte feste Tausch ueberlebt das Pruefzeichen' '[ "$(_backup_key_check 3 "$D3")" = "$(_backup_key_check 3 "$old")" ]'
c="$(typo_char 3 "$D3")"
ok 'typo_char waehlt ein anderes Zeichen' '[ -n "$c" ] && [ "$c" != "${D3:0:1}" ] && [ "$c" != f ]'
rc=0; printf '3:  %s-%s-%s-%s  %s\n' "${c}${D3:1:3}" "${D3:4:4}" "${D3:8:4}" "${D3:12:4}" "$(_backup_key_check 3 "$D3")" | backup_key_line 3 >/dev/null || rc=$?
ok 'die Zeile mit dem gewaehlten Tippfehler faellt durch (rc 1)' '[ "$rc" = 1 ]'

# Quer: fuer viele Zeilen gilt dasselbe.
bad=0
for i in $(seq 1 24); do
  d="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  c="$(typo_char $(( i % 4 + 1 )) "$d")" || { bad=$((bad + 1)); continue; }
  [ "$(_backup_key_check $(( i % 4 + 1 )) "${c}${d:1}")" != "$(_backup_key_check $(( i % 4 + 1 )) "$d")" ] || bad=$((bad + 1))
done
ok '24 Zufallszeilen: das Pruefzeichen faellt immer durch' '[ "$bad" = 0 ]'
# typo_token: ein erfundener Schluessel als Token, der Tausch faellt sicher durch die Pruefsumme.
T="$(printf "%s" "$D3$D3$D3$D3" | backup_key_token)"
bt="$(typo_token "$T")"
ok "typo_token aendert genau ein Zeichen" '[ ${#bt} = ${#T} ] && [ "$bt" != "$T" ]'
ok "typo_token faellt durch die Pruefsumme" '! printf "%s" "${bt#*_}" | backup_key_untoken >/dev/null'
exit "$fails"
