#!/usr/bin/env bash
# old_sheet_lib.sh — Hilfe fuer tests/backup/cases.sh und tests/mock_runtime/cases.sh (gesourct, braucht _backup_key_check aus
# provisioning/lib/common.sh). old_paper erzeugt das gedruckte Blatt mit vier Zeilen ("n:  xxxx-xxxx-xxxx-xxxx  pp") fuer beliebige
# Test-Schluessel, damit die Einlese-Faelle dieses Format pruefen; die Produktion gibt es nicht mehr aus. Gegenprobe gegen eine
# echte Ausgabe dieses Formats: fixtures/notfallblatt-alt.txt (erfundene Schluessel).

# old_paper (stdin: 64 Hex) -> vier Zeilen "n:  xxxx-xxxx-xxxx-xxxx  pp".
old_paper() {
  local k n d; k="$(cat)"
  [[ "$k" =~ ^[0-9a-f]{64}$ ]] || return 1
  for n in 1 2 3 4; do
    d="${k:$(( (n - 1) * 16 )):16}"
    printf '%s:  %s-%s-%s-%s  %s\n' "$n" "${d:0:4}" "${d:4:4}" "${d:8:4}" "${d:12:4}" "$(_backup_key_check "$n" "$d")"
  done
}
