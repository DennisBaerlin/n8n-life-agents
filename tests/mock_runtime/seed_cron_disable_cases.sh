#!/usr/bin/env bash
# seed_cron_disable_cases.sh — der Install-Schalter CRON_DISABLE des Daten-Seeds (provisioning/lib/seed_data.sh, _seed_cron_disable).
# Eine Test-Installation schaltet damit cron_enable.refresh_fx_rates ab, bevor das Paket seine Workflows bekommt
# (scripts/lib/test_install_env.ps1 Get-TestDevSwitches): der Wechselkurs-Cron holt sonst 30 s nach dem n8n-Start echte Kurse aus dem
# Netz. Die Faelle pruefen den erzeugten SQL-Text: nur cron_enable-Zeilen auf false, nur gueltige Schluessel, nie ein Wert ausserhalb der
# Anfuehrungszeichen, ohne den Schalter nichts. Dass der Wert in der Installation ankommt und kein Kurs-Abruf mehr laeuft, belegt der
# Rundlauf der Sicherung im Docker-Verbund (backup_roundtrip_test.ps1, Fall fxcfg).
#
# Faehrt den ECHTEN Code (common.sh, seed_data.sh); braucht bash 5.
# Usage: bash seed_cron_disable_cases.sh <root>   (<root>/provisioning/lib/ vorhanden)   Ausgabe je Fall PASS/FAIL, Exit = Anzahl FAIL.
# real-path-test: scripts/dev/backup_roundtrip_test.ps1 (Fall fxcfg: Config-Zeile und Kurs-Abruf im echten Verbund)
# shellcheck disable=SC2016,SC2034,SC1091,SC2154  # Fall-Ausdruecke in einfachen Quotes; gesourcte Lib setzt Globals
set -uo pipefail
ROOT="$1"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# _run [VAR=wert …] — die Funktion in einer eigenen Shell; Ausgabe in $W/out (SQL), $W/err (Warnungen), Exit in $rc.
_run() {
  rc=0
  env -u CRON_DISABLE "$@" bash -euo pipefail -c '. "$1/provisioning/lib/common.sh"; . "$1/provisioning/lib/seed_data.sh"; _seed_cron_disable' _ "$ROOT" \
    > "$W/out" 2> "$W/err" || rc=$?
}
want="UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'refresh_fx_rates' AND managed_by = 'owner';"

_run
if [ "$rc" -eq 0 ] && [ ! -s "$W/out" ]; then pass "D1 ohne Schalter: kein SQL"; else fail "D1 ohne Schalter" "exit $rc, $(wc -c < "$W/out") Byte"; fi

_run CRON_DISABLE=refresh_fx_rates
if [ "$rc" -eq 0 ] && [ "$(cat "$W/out")" = "$want" ]; then pass "D2 ein Schluessel: genau ein UPDATE auf die eine cron_enable-Zeile"; else fail "D2 ein Schluessel" "exit $rc: $(head -c 300 "$W/out")"; fi

_run "CRON_DISABLE=refresh_fx_rates, remind_interest learn_context"
if [ "$rc" -eq 0 ] && [ "$(grep -c '^UPDATE core.config' "$W/out")" -eq 3 ] && grep -q "key = 'remind_interest'" "$W/out" && grep -q "key = 'learn_context'" "$W/out"; then
  pass "D3 mehrere Schluessel (Komma und Leerzeichen)"
else fail "D3 mehrere Schluessel" "exit $rc: $(head -c 300 "$W/out")"; fi

# Ungueltige Eintraege: nie in den SQL-Text, gueltige daneben bleiben, die Warnung nennt den Eintrag.
_run "CRON_DISABLE=x';DROP TABLE core.config;-- refresh_fx_rates Gross cron_enable.refresh_fx_rates 9x"
if [ "$rc" -eq 0 ] && [ "$(cat "$W/out")" = "$want" ] && ! grep -qi 'drop' "$W/out"; then
  pass "D4 ungueltige Eintraege fallen weg (kein Text im SQL), der gueltige bleibt"
else fail "D4 ungueltige Eintraege" "exit $rc: $(head -c 300 "$W/out")"; fi
if [ "$(grep -c 'ungueltig' "$W/err")" -ge 4 ]; then pass "D5 jeder ungueltige Eintrag wird gemeldet"; else fail "D5 Warnungen" "$(head -c 300 "$W/err")"; fi

exit "$fails"
