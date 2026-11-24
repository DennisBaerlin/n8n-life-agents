#!/usr/bin/env bash
# old_sheet_lib.sh — Hilfe fuer tests/backup/cases.sh und tests/mock_runtime/cases.sh (gesourct, braucht _backup_key_check aus
# provisioning/lib/common.sh). Das Notfallblatt zeigt den Schluessel als Token; gedruckte Blaetter im alten Format (vier Zeilen
# "n:  xxxx-xxxx-xxxx-xxxx  pp") bleiben gueltig und muessen sich weiter einlesen lassen. Die Produktion erzeugt das alte Format
# nicht mehr, darum lebt der Erzeuger hier. Beweis gegen das echte alte Format ist fixtures/notfallblatt-alt.txt (Ausgabe des
# Stands vor dem Token, erfundene Schluessel); diese Funktion liefert dieselbe Form fuer beliebige Test-Schluessel.

# old_paper (stdin: 64 Hex) -> vier Zeilen "n:  xxxx-xxxx-xxxx-xxxx  pp".
old_paper() {
  local k n d; k="$(cat)"
  [[ "$k" =~ ^[0-9a-f]{64}$ ]] || return 1
  for n in 1 2 3 4; do
    d="${k:$(( (n - 1) * 16 )):16}"
    printf '%s:  %s-%s-%s-%s  %s\n' "$n" "${d:0:4}" "${d:4:4}" "${d:8:4}" "${d:12:4}" "$(_backup_key_check "$n" "$d")"
  done
}
