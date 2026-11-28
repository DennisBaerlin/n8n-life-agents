# shell_trap_cases.sh — Faelle SH*: Fallen der Shell im Lib-Code, die kein Wrapper-Fall sieht (Geheimnis im argv eines
# Hilfsprogramms, dauerhaft umgeleitetes stderr, vererbte Update-Sperre, stiller Abbruch unter pipefail); eingebunden von
# cases.sh (dieselben Attrappen, $W, $STUB_LOG, pass/fail/eq).
# real-path-test: scripts/dev/update_chat_test.ps1 (Runner und Sperre im echten Substrat); das Rendern von n8n.env faehrt jede Installation (scripts/dev/bootstrap_test_n8n.ps1)
# shellcheck shell=bash disable=SC2016,SC2030,SC2031,SC2034,SC2154,SC2329  # Attrappen-Funktionen ruft der Lib-Code; Pruef-Ausdruecke in einfachen Quotes; fails/W/ROOT setzt cases.sh

# ---------------------------------------------------------------------------- SH-A: render_template ohne Hilfsprogramm
# Die Werte (N8N_ENCRYPTION_KEY, Datenbank-Passwort) duerfen in keiner Befehlszeile stehen: /proc/<pid>/cmdline liest jeder Nutzer.
# Eine Attrappe vorn im PATH schreibt jede sed-Befehlszeile mit.
mkdir -p "$W/shbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/sh.sed.argv"\nexec "%s" "$@"\n' "$W" "$(command -v sed)" > "$W/shbin/sed"
chmod +x "$W/shbin/sed"
printf 'KEY=@@GEHEIM@@\nPFAD=@@PFAD@@\nZWEIMAL=@@GEHEIM@@ @@GEHEIM@@\nFREMD=@@ANDERS@@\n' > "$W/sh.tpl"
: > "$W/sh.sed.argv"
_sh_out="$( ( PATH="$W/shbin:$PATH"; render_template "$W/sh.tpl" GEHEIM=marker0123abc 'PFAD=/a|b&c\d' ) )"
if grep -q 'marker0123abc' "$W/sh.sed.argv"; then fail SH-A.wert-nicht-im-argv "sed-Befehlszeile traegt den Wert"; else pass SH-A.wert-nicht-im-argv; fi
eq SH-A.ersetzt $'KEY=marker0123abc\nPFAD=/a|b&c\\d\nZWEIMAL=marker0123abc marker0123abc\nFREMD=@@ANDERS@@' "$_sh_out"
# Ein Wert, der selbst wie ein Platzhalter aussieht, wird nicht noch einmal ersetzt (und haengt die Schleife nicht auf).
eq SH-A.wert-wie-platzhalter 'KEY=@@GEHEIM@@x' "$(render_template "$W/sh.tpl" 'GEHEIM=@@GEHEIM@@x' | head -n1)"

# ---------------------------------------------------------------------------- SH-B: Sperre abgeben laesst stderr stehen
# `exec 9>&- 2>/dev/null` leitete stderr des ganzen Runners dauerhaft um: jede Zeile danach (log, warn, die) fehlte im Journal.
_sh_out="$( ( exec 9>"$W/sh.lock"; _ur_lock_release; printf 'noch-da\n' >&2 ) 2>&1 )"
eq SH-B.stderr-bleibt noch-da "$_sh_out"
_sh_out="$( ( exec 9>"$W/sh.lock"; _ur_lock_release; if { : >&9; } 2>/dev/null; then echo offen; else echo zu; fi ) 2>/dev/null )"
eq SH-B.sperre-zu zu "$_sh_out"
# Ohne offene Sperre (zweiter Aufruf) bleibt es still und rc 0.
_sh_out="$( ( _ur_lock_release; _ur_lock_release; echo "rc=$?" ) 2>&1 )"
eq SH-B.ohne-sperre-still 'rc=0' "$_sh_out"

# ---------------------------------------------------------------------------- SH-C: Hintergrund-Anmeldung erbt die Update-Sperre nicht
# `tailscale up` wartet bis zu 15 Minuten auf die Anmeldung; mit geerbtem fd 9 hielte er die Sperre so lange (Runner, Sicherung, Update).
printf '#!/bin/sh\nif [ -e "/proc/$$/fd/9" ]; then echo offen; else echo zu; fi > "%s/sh.fd9"\n' "$W" > "$W/shbin/setsid"
printf '#!/bin/sh\nexit 0\n' > "$W/shbin/tailscale"
chmod +x "$W/shbin/setsid" "$W/shbin/tailscale"
rm -f "$W/sh.fd9"
( exec 9>"$W/sh.lock"; INSTALL_ENV_FILE="$W/sh.core.env"; PATH="$W/shbin:$PATH"; reach_cli_ts_login_start )
for _ in $(seq 1 50); do [ -s "$W/sh.fd9" ] && break; sleep 0.1; done
eq SH-C.sperre-nicht-geerbt zu "$(cat "$W/sh.fd9" 2>/dev/null)"

# ---------------------------------------------------------------------------- SH-D: kein stiller Abbruch unter pipefail
# lifeagents_db_name: fehlt die Zeile in n8n.env, gilt der Standard (grep ohne Treffer darf den Aufrufer nicht beenden).
printf 'N8N_PORT=5678\n' > "$W/sh.n8n.env"
_sh_out="$( ( set -euo pipefail; unset N8N_DB_NAME; N8N_ENV_FILE="$W/sh.n8n.env" lifeagents_db_name ) 2>&1; echo " rc=$?" )"
eq SH-D.db-name-standard 'n8n rc=0' "$_sh_out"
printf 'DB_POSTGRESDB_DATABASE=alt\nDB_POSTGRESDB_DATABASE=meine\n' > "$W/sh.n8n.env"
eq SH-D.db-name-aus-datei meine "$( ( set -euo pipefail; unset N8N_DB_NAME; N8N_ENV_FILE="$W/sh.n8n.env" lifeagents_db_name ) 2>&1 )"
# rt_target_precheck: laesst sich der Pin des Ziel-Stands nicht lesen, ist das „keine Aussage“ und der Lauf geht weiter.
_sh_out="$( (
  set -euo pipefail
  _rt_compose() { return 1; }; pg_su_exec() { printf '17\n'; }; rt_container_running() { return 1; }; rt_stack_pull() { echo "pull $*"; }
  rt_target_precheck "$W/sh.compose.yml" reg.example/master@sha256:aaaa; echo weiter
) 2>&1 )"
case "$_sh_out" in *weiter) pass SH-D.pin-unlesbar-keine-aussage ;; *) fail SH-D.pin-unlesbar-keine-aussage "${_sh_out:-stiller Abbruch}" ;; esac
case "$_sh_out" in *'pull postgres n8n gateway edge'*) pass SH-D.pin-unlesbar-laedt-trotzdem ;; *) fail SH-D.pin-unlesbar-laedt-trotzdem "${_sh_out:-nichts}" ;; esac
# upgrade_rollback: ohne Merkzettel und ohne Sicherungs-Ordner (es gab nie ein Update) kommt der Satz, kein stiller Abbruch.
_sh_out="$( (
  set -euo pipefail
  require_root() { :; }; lifeagents_db_name() { :; }; N8N_DB_NAME=n8n; upgrade_move_guard() { :; }; rt_is_compose() { return 0; }
  UPGRADE_MARKER="$W/sh.kein.pending"; UPGRADE_BACKUP_DIR="$W/sh.kein-ordner"
  upgrade_rollback --yes
) 2>&1; echo " rc=$?" )"
case "$_sh_out" in *'Keine Sicherung von vor einem Update gefunden'*' rc=1') pass SH-D.rueckweg-ohne-sicherung-satz ;; *) fail SH-D.rueckweg-ohne-sicherung-satz "${_sh_out}" ;; esac
rm -rf "$W/shbin" "$W"/sh.*
