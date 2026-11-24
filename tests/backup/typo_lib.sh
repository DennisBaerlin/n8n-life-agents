#!/usr/bin/env bash
# typo_lib.sh — Hilfe fuer tests/backup/cases.sh (gesourct, braucht _backup_key_check und backup_key_untoken aus provisioning/lib/common.sh).
# Das Pruefzeichen einer Blatt-Zeile hat 2 Hex-Zeichen: ein einzelner Tippfehler rutscht mit Wahrscheinlichkeit 1/256 durch
# (Produktgrenze, kein Fehler). Ein Test, der "Tippfehler wird erkannt" prueft, darf diesen Zufall nicht dem Schluessel ueberlassen:
# typo_char waehlt das ersetzende Zeichen so, dass das Pruefzeichen der Zeile sicher nicht mehr passt.
# Test ohne Substrat: bash tests/backup/typo_lib_test.sh

# typo_char <zeilennummer> <16 hex der Zeile> -> ein Hex-Zeichen != erstes Zeichen, bei dem das Pruefzeichen der Zeile nicht passt.
typo_char() {
  local n="$1" d="$2" c want
  [[ "$d" =~ ^[0-9a-f]{16}$ ]] || return 1   # eine anders gelesene Blatt-Zeile soll laut scheitern, nicht still ein Zeichen liefern
  want="$(_backup_key_check "$n" "$d")"
  for c in f e d c b a 9 8 7 6 5 4 3 2 1 0; do
    [ "$c" != "${d:0:1}" ] || continue
    [ "$(_backup_key_check "$n" "${c}${d:1}")" != "$want" ] || continue
    printf '%s' "$c"; return 0
  done
  return 1
}

# typo_token <token> -> dasselbe Token mit einem geaenderten Rumpf-Zeichen (Stelle 10), bei dem die Pruefsumme sicher nicht
#   passt (braucht backup_key_untoken). Ersatz nur aus Zeichen ohne Crockford-Alias (o/0, i/l/1 waeren kein Fehler).
typo_token() {
  local t="$1" b c
  b="${t#*_}"
  [[ "$b" =~ ^[0-9a-hjkmnp-tv-z]{56}$ ]] || return 1
  for c in 2 3 4 5 6 7 8 9; do
    [ "$c" != "${b:10:1}" ] || continue
    ! printf '%s' "${b:0:10}${c}${b:11}" | backup_key_untoken > /dev/null || continue
    printf '%s_%s\n' "${t%%_*}" "${b:0:10}${c}${b:11}"; return 0
  done
  return 1
}
