#!/usr/bin/env bash
# cases.sh — Fall-Runner von scripts/dev/backup_test.ps1, laeuft IM Substrat-Container (root, echtes PostgreSQL, die CLI
# DIESES Baums unter <root>/lifeagents). Prueft `lifeagents backup` Ende zu Ende:
#   E  Export mit allen Paketen: mehr als 50 gesicherte Tabellen (PostgreSQL nimmt hoechstens 100 Funktions-Argumente,
#      jsonb_build_object zwei je Tabelle) -> die Sicherung entsteht trotzdem und laesst sich wieder einspielen.
#
# Usage: bash cases.sh <root>      Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2016  # Pruef-Ausdruecke in einfachen Quotes (eval in ok_if)
set -uo pipefail
ROOT="$1"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
ok_if() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-Bedingung falsch}"; fi; }

W="$(mktemp -d)"; chmod 0700 "$W"
trap 'rm -rf "$W"' EXIT
CLI="$ROOT/lifeagents"
sed "s|@@LIBDIR@@|$ROOT|" "$ROOT/provisioning/templates/lifeagents.tpl" > "$CLI"; chmod 0700 "$CLI"
[ -r "$ROOT/VERSION" ] || cp /usr/local/lib/lifeagents/VERSION "$ROOT/VERSION" 2>/dev/null || printf 'v0.0.0\n' > "$ROOT/VERSION"

# Vorbedingung: das Substrat sichert genug Tabellen, sonst beweist der Fall nichts (Installation mit --packages all).
n="$(LIFEAGENTS_LIB="$ROOT" bash -c '. "$1/provisioning/lib/common.sh"; . "$1/provisioning/lib/backup_cli.sh"; lifeagents_db_name >/dev/null; { _bkp_bulk_tables; _bkp_filtered; } | grep -c .' _ "$ROOT" 2>/dev/null)"
ok_if E.mehr-als-50-tabellen '[ "${n:-0}" -gt 50 ]' "nur ${n:-0} Tabellen (Substrat ohne alle Pakete?)"

"$CLI" backup export "$W/x.nla.enc" > "$W/out.e1" 2>&1 < /dev/null; rc=$?
ok_if E.export-ok '[ "$rc" -eq 0 ] && [ -s "$W/x.nla.enc" ]' "rc=$rc: $(grep -m1 -E 'ERROR|\[x\]' "$W/out.e1" | cut -c1-160)"
"$CLI" backup restore "$W/x.nla.enc" --yes > "$W/out.e2" 2>&1 < /dev/null; rc=$?
ok_if E.restore-der-sicherung '[ "$rc" -eq 0 ]' "rc=$rc"

exit "$fails"
