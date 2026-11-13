#!/usr/bin/env bash
# cases.sh — Fall-Runner von scripts/dev/backup_test.ps1, laeuft IM Substrat-Container (root, echtes PostgreSQL, die CLI
# DIESES Baums unter <root>/lifeagents). Prueft Notfallblatt und Schluessel-Uebernahme Ende zu Ende:
#   E  Export: Dateiname mit Schluessel-ID + Version, backup.state.
#   R  Restore auf "neuem Rechner" (anderer aktiver Schluessel): ohne Eingabe Abbruch, falscher Schluessel, Tippfehler,
#      beschaedigte Datei, gescheiterte TX -> jeweils nichts geaendert; mit Notfallblatt -> Daten da, Blatt-Schluessel aktiv,
#      bisheriger als prev; prev-Sicherung ohne Eingabe; zweimal hintereinander.
#   K  `backup key`: nur Terminal/--file/--file -, Datei 0600, nie ueberschreiben; die Datei selbst taugt als --key-stdin.
#   U  Rueckweg nach Update: _upg_carry_backup_keys behaelt den uebernommenen Schluessel.
#   L  Leck-Probe: kein Schluessel in Ausgaben, /proc/*/cmdline|environ waehrend eines Restores, Resten im tmpfs.
# Schluessel: der echte Test-Schluessel des Substrats (zufaellig) + erfundene. Meldungen nennen nie einen Schluesselwert.
# Am Ende steht core.backup_key wieder wie vorher.
#
# Usage: bash cases.sh <root>      Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2016,SC2034,SC2012,SC2329  # Pruef-Ausdruecke in einfachen Quotes (eval in ok_if); nur eigene Dateinamen; cleanup laeuft per trap
set -uo pipefail
ROOT="$1"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
ok_if() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-Bedingung falsch}"; fi; }

W="$(mktemp -d)"; chmod 0700 "$W"
CLI="$ROOT/lifeagents"
sed "s|@@LIBDIR@@|$ROOT|" "$ROOT/provisioning/templates/lifeagents.tpl" > "$CLI"; chmod 0700 "$CLI"
[ -r "$ROOT/VERSION" ] || cp /usr/local/lib/lifeagents/VERSION "$ROOT/VERSION" 2>/dev/null || printf 'v0.0.0\n' > "$ROOT/VERSION"
export BACKUP_STATE_FILE="$W/backup.state"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
lifeagents_db_name >/dev/null

# --- Hilfen: Schluessel nur ueber \set im Strom, nie im argv ---
sqlk() { { psql_setvar k "$1"; printf '%s\n' "$2"; } | psql_superuser_driver -tA -q 2>/dev/null; }
set_active() { sqlk "$1" "UPDATE core.backup_key SET value = :'k' WHERE key = '${BACKUP_KEY_NAME}'; DELETE FROM core.backup_key WHERE starts_with(key, '${BACKUP_KEY_PREV_PREFIX}');" >/dev/null; }
active_is() { [ "$(sqlk "$1" "SELECT value = :'k' FROM core.backup_key WHERE key = '${BACKUP_KEY_NAME}';")" = t ]; }
prev_has() { [ "$(sqlk "$1" "SELECT count(*) > 0 FROM core.backup_key WHERE starts_with(key, '${BACKUP_KEY_PREV_PREFIX}') AND value = :'k';")" = t ]; }
prev_n() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT count(*) FROM core.backup_key WHERE starts_with(key, '${BACKUP_KEY_PREV_PREFIX}')"; }
# Daten-Fingerabdruck: die vom Agenten gepflegten Kontexte stehen in jeder Sicherung (filtered_tables), auch ohne Fixtures.
rows() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT count(*) FROM agent.core_contexts WHERE managed_by = 'agent'"; }
n=0
cli() { n=$((n + 1)); "$CLI" "$@" > "$W/out.$n" 2>&1 < /dev/null; }
cli_in() { local f="$1"; shift; n=$((n + 1)); "$CLI" "$@" > "$W/out.$n" 2>&1 < "$f"; }
said() { grep -qF -- "$1" "$W/out.$n"; }

ORIG="$(pg_su_psql -X -tA -F $'\t' -d "$N8N_DB_NAME" -c "SELECT key, value FROM core.backup_key ORDER BY key")"
KA="$(printf '%s\n' "$ORIG" | awk -F'\t' -v k="$BACKUP_KEY_NAME" '$1 == k {print $2}')"
restore_orig() {
  { printf 'BEGIN;\nDELETE FROM core.backup_key;\n'
    local i=0 k v
    while IFS=$'\t' read -r k v; do
      [ -n "$k" ] || continue
      psql_setvar "k$i" "$k"; psql_setvar "v$i" "$v"
      printf "INSERT INTO core.backup_key(key, value) VALUES (:'k%s', :'v%s');\n" "$i" "$i"; i=$((i + 1))
    done <<<"$ORIG"
    printf 'COMMIT;\n'; } | psql_superuser_driver -q >/dev/null 2>&1
}
new_backups() { local f; for f in /var/backups/lifeagents/lifeagents-backup-*.nla.enc; do [ -e "$f" ] && ! grep -qxF "$f" "$W/bk_before" && printf '%s\n' "$f"; done; return 0; }
cleanup() { restore_orig; new_backups | xargs -r rm -f;pg_su_psql -X -q -d "$N8N_DB_NAME" -c "DROP TABLE IF EXISTS public.bk_leer, public.bk_voll" >/dev/null 2>&1; pg_su_psql -X -q -d "$N8N_DB_NAME" -c "ALTER TABLE agent.core_contexts DROP CONSTRAINT IF EXISTS bk_test_fail" >/dev/null 2>&1; pg_su_exec dropdb --if-exists bk_carry >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
if [ "${#KA}" -ne 64 ]; then fail setup "Substrat-Schluessel fehlt oder ist kein 64-Hex"; exit "$fails"; fi
# Erfundene Schluessel (Repo oeffentlich): "frische Installation" und "falsch".
KB="$(printf '0123456789abcdef%.0s' 1 2 3 4)"
KC="$(printf 'fedcba9876543210%.0s' 1 2 3 4)"
printf '%s\n%s\n%s\n' "$KA" "$KB" "$KC" > "$W/needles"
for k in "$KA" "$KB" "$KC"; do printf '%s' "${k:0:16}" >> "$W/needles"; printf '\n' >> "$W/needles"; done
kidA="$(printf '%s' "$KA" | backup_key_id)"
paper() { printf '%s' "$1" | backup_key_paper; }
N0="$(rows)"
BACKUP_RESTORE_LOCK_T="$W/restore.lock"
: > "$W/bk_before"; for _f in /var/backups/lifeagents/lifeagents-backup-*.nla.enc; do [ -e "$_f" ] && printf '%s\n' "$_f" >> "$W/bk_before"; done

# ---------------------------------------------------------------------------- E: Export
cli backup export "$W/x.nla.enc"; rc=$?
# Export mit Pfad schreibt genau dorthin; den Standard-Namen pruefen wir ueber ein Export ohne Pfad im Arbeitsordner.
( cd "$W" && "$CLI" backup export > "$W/out.e2" 2>&1 < /dev/null ); rc2=$?
fa="$(cd "$W" && ls -1 lifeagents-backup-*.nla.enc 2>/dev/null | head -n1)"
ok_if E.export-ok '[ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -s "$W/x.nla.enc" ]' "rc=$rc/$rc2"
# Alle Pakete = Fremdschluessel-Ringe (accounts, recurring_payments, ...): pg_dump -a warnt darueber; mit --disable-triggers
# harmlos, darum nicht in der Ausgabe (Live-Fund v0.43.1). Sonstige Ausgabe bleibt.
ok_if E.export-ohne-ring-warnung '! grep -q "circular foreign-key" "$W/out.e2" && grep -q "Backup geschrieben" "$W/out.e2"' \
  "$(grep -m1 'circular\|pg_dump' "$W/out.e2" || true)"
ok_if E.name-mit-id-und-version '[[ "$fa" =~ ^lifeagents-backup-[0-9]{14}-${kidA}-v[0-9A-Za-z.-]+\.nla\.enc$ ]]' "Name: $fa"
ok_if E.state-last-ok 'grep -qE "^LAST_OK=[0-9]+$" "$BACKUP_STATE_FILE"' "backup.state ohne LAST_OK"
ok_if E.schluessel-unveraendert 'active_is "$KA" && [ "$(prev_n)" = 0 ]'
A="$W/$fa"

# Sicherung mit dem "frischen" Schluessel KB (fuer den prev-Fall), dann ist KB aktiv wie auf einem neuen Rechner.
set_active "$KB"
( mkdir -p "$W/b" && cd "$W/b" && "$CLI" backup export > "$W/out.eb" 2>&1 < /dev/null )
B="$(ls -1 "$W"/b/lifeagents-backup-*.nla.enc 2>/dev/null | head -n1)"
ok_if E.export-mit-zweitem-schluessel '[ -s "$B" ]'

# ---------------------------------------------------------------------------- R: Restore auf "neuem Rechner"
cli backup restore "$A" --yes; rc=$?
ok_if R.ohne-eingabe-abbruch '[ "$rc" -ne 0 ] && said -- "--key-stdin" && active_is "$KB" && [ "$(prev_n)" = 0 ]' "rc=$rc"
paper "$KC" > "$W/kc"; cli_in "$W/kc" backup restore "$A" --key-stdin --yes; rc=$?
ok_if R.falscher-schluessel '[ "$rc" -ne 0 ] && said "gehört nicht zu dieser Sicherung" && active_is "$KB" && [ "$(prev_n)" = 0 ]' "rc=$rc"
c3="$(paper "$KA" | sed -n 3p | cut -c5)"; [ "$c3" = f ] && c3=e || c3=f
paper "$KA" | sed -E "3s/^(3:  )./\\1${c3}/" > "$W/typo"
cli_in "$W/typo" backup restore "$A" --key-stdin --yes; rc=$?
ok_if R.tippfehler-zeile3 '[ "$rc" -ne 0 ] && said "Zeile 3 stimmt nicht" && active_is "$KB"' "rc=$rc"
# Beschaedigt: gleicher Name (ID passt), halbe Datei; mit dem passenden Blatt -> "beschaedigt", nichts geaendert.
mkdir -p "$W/kaputt"; head -c "$(( $(stat -c %s "$A") / 2 ))" "$A" > "$W/kaputt/$fa"
paper "$KA" > "$W/ka"; cli_in "$W/ka" backup restore "$W/kaputt/$fa" --key-stdin --yes; rc=$?
ok_if R.beschaedigt '[ "$rc" -ne 0 ] && said "beschädigt" && active_is "$KB" && [ "$(prev_n)" = 0 ]' "rc=$rc"
# Gescheiterte TX (Constraint lehnt die wiederhergestellten Kontext-Zeilen ab): Uebernahme rollt mit zurueck.
if [ "${N0:-0}" -gt 0 ]; then
  pg_su_psql -X -q -d "$N8N_DB_NAME" -c "ALTER TABLE agent.core_contexts ADD CONSTRAINT bk_test_fail CHECK (false) NOT VALID" >/dev/null 2>&1
  cli_in "$W/ka" backup restore "$A" --key-stdin --yes; rc=$?
  pg_su_psql -X -q -d "$N8N_DB_NAME" -c "ALTER TABLE agent.core_contexts DROP CONSTRAINT IF EXISTS bk_test_fail" >/dev/null 2>&1
  ok_if R.tx-fehler-nichts-geaendert '[ "$rc" -ne 0 ] && active_is "$KB" && [ "$(prev_n)" = 0 ] && [ "$(rows)" = "$N0" ]' "rc=$rc"
else
  fail R.tx-fehler-nichts-geaendert "keine Agenten-Kontexte im Substrat"
fi
# Mit dem Blatt (Grossbuchstaben, Bindestriche) — dabei /proc beobachten (Leck-Probe L).
paper "$KA" | tr 'a-f' 'A-F' > "$W/kaU"
: > "$W/proc_hits"
( "$CLI" backup restore "$A" --key-stdin --yes > "$W/out.r4" 2>&1 < "$W/kaU"; echo $? > "$W/rc.r4" ) &
bg=$!
while kill -0 "$bg" 2>/dev/null; do
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$BASHPID" ] && continue
    { tr '\0' '\n' < "$p/cmdline"; tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qFf "$W/needles" && printf '%s\n' "${p#/proc/}" >> "$W/proc_hits"
  done
done
wait "$bg"; rc="$(cat "$W/rc.r4")"
ok_if R.mit-notfallblatt '[ "$rc" -eq 0 ] && active_is "$KA" && prev_has "$KB" && [ "$(prev_n)" = 1 ] && [ "$(rows)" = "$N0" ]' "rc=$rc"
ok_if L.kein-schluessel-in-proc '[ ! -s "$W/proc_hits" ]' "Treffer in $(wc -l < "$W/proc_hits") Prozess(en)"
# Danach gilt das Blatt: eigene Sicherung ohne Eingabe; prev-Sicherung (KB) ohne Eingabe und ohne Aenderung.
cli backup restore "$A" --yes; rc=$?
ok_if R.danach-ohne-eingabe '[ "$rc" -eq 0 ] && active_is "$KA" && [ "$(prev_n)" = 1 ]' "rc=$rc"
cli backup restore "$B" --yes; rc=$?
ok_if R.prev-sicherung-aendert-nichts '[ "$rc" -eq 0 ] && active_is "$KA" && [ "$(prev_n)" = 1 ]' "rc=$rc"
cli_in "$W/ka" backup restore "$A" --key-stdin --yes; rc=$?
ok_if R.zweimal-gleicher-schluessel '[ "$rc" -eq 0 ] && active_is "$KA" && [ "$(prev_n)" = 1 ]' "rc=$rc"

# Jede Wiederherstellung mit eigenen Daten schreibt vorher eine Sicherung (Server: /var/backups/lifeagents).
ok_if R.vorab-sicherung '[ -n "$(new_backups)" ]' \
  "keine neue Sicherung vor dem Ersetzen"

# ---------------------------------------------------------------------------- P: Start-App (Probelauf, stdin, Hintergrund)
# Fingerabdruck fuer „schreibt nichts“: Nutzerdaten, Schluessel, Paket-Liste, backup.state.
fp() { printf '%s|' "$(rows)" "$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT md5(string_agg(key || value, ',' ORDER BY key)) FROM core.backup_key")" \
  "$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT string_agg(package || status || version, ',' ORDER BY package) FROM core.package_registry")" \
  "$(cksum < "$BACKUP_STATE_FILE" 2>/dev/null)"; }
js() { jq -r "$1" "$W/out.$n" 2>/dev/null | tail -n1; }   # letzte Zeile mit JSON (stderr steht davor)
frame() { { printf 'sheet %s\n' "$( [ -s "$1" ] && base64 -w0 < "$1")"; base64 < "$2"; } > "$W/frame"; }
set_active "$KB"
F0="$(fp)"
n=$((n + 1)); "$CLI" backup restore "$A" --plan --json > "$W/out.$n" 2>/dev/null < /dev/null; rc=$?
ok_if P.probe-ohne-blatt '[ "$rc" -ne 0 ] && [ "$(js .code)" = key_needed ] && [ "$(fp)" = "$F0" ]' "rc=$rc $(js .code)"
frame "$W/ka" "$A"; n=$((n + 1)); "$CLI" backup restore "$(basename "$A")" --in-stdin --plan --json > "$W/out.$n" 2>/dev/null < "$W/frame"; rc=$?
ok_if P.probe-mit-blatt '[ "$rc" -eq 0 ] && [ "$(js .ok)" = true ] && [ "$(js .adopt_key_id)" = "$kidA" ] && [ "$(js .has_data)" = true ] && [ "$(js ".packages | length")" -gt 0 ] && [ "$(fp)" = "$F0" ]' \
  "rc=$rc $(js .code) / Fingerabdruck $( [ "$(fp)" = "$F0" ] && echo gleich || echo geaendert)"
frame "$W/typo" "$A"; n=$((n + 1)); "$CLI" backup restore "$(basename "$A")" --in-stdin --plan --json > "$W/out.$n" 2>/dev/null < "$W/frame"; rc=$?
ok_if P.probe-tippfehler '[ "$rc" -ne 0 ] && [ "$(js .code)" = key_line ] && [ "$(js .line)" = 3 ]' "$(js .code)/$(js .line)"
frame "$W/kc" "$A"; n=$((n + 1)); "$CLI" backup restore "$(basename "$A")" --in-stdin --plan --json > "$W/out.$n" 2>/dev/null < "$W/frame"
ok_if P.probe-falsches-blatt '[ "$(js .code)" = key_foreign ] && [ "$(js .id)" = "$kidA" ]' "$(js .code)"
printf 'Einkaufsliste: Milch\n' > "$W/keinblatt"; frame "$W/keinblatt" "$A"
n=$((n + 1)); "$CLI" backup restore "$(basename "$A")" --in-stdin --plan --json > "$W/out.$n" 2>/dev/null < "$W/frame"
ok_if P.probe-kein-blatt '[ "$(js .code)" = key_format ]' "$(js .code)"
# Version: dieselbe Sicherung mit verstellter Paket-Version (aelter/neuer) -> Code + Release, nichts geaendert.
mkdir -p "$W/ver"; gpg_sym_decrypt "$KA" "$A" > "$W/ver/b.tgz" < /dev/null; tar -xzf "$W/ver/b.tgz" -C "$W/ver"
for v in 0.0.1:version_older 999.0.0:version_newer; do
  jq --arg v "${v%%:*}" '.packages[0].version = $v' "$W/ver/manifest.json" > "$W/ver/m2" && cp "$W/ver/m2" "$W/ver/manifest.json"
  tar -czf "$W/ver/n.tgz" -C "$W/ver" manifest.json data.dump shared.json
  rm -f "$W/ver/$fa"; gpg_sym_encrypt "$KA" "$W/ver/$fa" "$W/ver/n.tgz"
  frame "$W/ka" "$W/ver/$fa"; n=$((n + 1)); "$CLI" backup restore "$fa" --in-stdin --plan --json > "$W/out.$n" 2>/dev/null < "$W/frame"
  want_rel="$(printf '%s' "$fa" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[^.]*' | head -n1)"; got_rel="$(js '.release // ""')"
  ok_if "P.probe-${v#*:}" '[ "$(js .code)" = "${v#*:}" ] && [ "$got_rel" = "$want_rel" ] && [ "$(fp)" = "$F0" ]' "$(js .code)/${got_rel}"
done
# Sperre: laeuft schon eine Wiederherstellung, startet keine zweite.
( flock "$BACKUP_RESTORE_LOCK_T" sleep 4 ) & lk=$!; sleep 1
frame "$W/ka" "$A"; n=$((n + 1)); BACKUP_RESTORE_LOCK="$BACKUP_RESTORE_LOCK_T" "$CLI" backup restore "$(basename "$A")" --in-stdin --yes --detach --json > "$W/out.$n" 2>/dev/null < "$W/frame"; rc=$?
wait "$lk"
ok_if P.zweiter-lauf-belegt '[ "$rc" -ne 0 ] && [ "$(js .code)" = busy ] && active_is "$KB"' "rc=$rc $(js .code)"
# Hintergrund-Lauf: kehrt sofort zurueck, Stand ueber restore-status; danach gilt das Blatt. /proc + Protokoll ohne Schluessel.
rs_state() { BACKUP_RESTORE_LOCK="$BACKUP_RESTORE_LOCK_T" "$CLI" backup restore-status --json 2>/dev/null | jq -r '.state + ":" + (.code // "")'; }
: > "$W/proc_hits2"
frame "$W/ka" "$A"; n=$((n + 1)); BACKUP_RESTORE_LOCK="$BACKUP_RESTORE_LOCK_T" LIFEAGENTS_LOG_DIR="$W/log" "$CLI" backup restore "$(basename "$A")" --in-stdin --yes --detach --json > "$W/out.$n" 2>/dev/null < "$W/frame"; rc=$?
ok_if P.hintergrund-startet '[ "$rc" -eq 0 ] && [ "$(js .ok)" = true ]' "rc=$rc $(js .code)"
for _ in $(seq 1 240); do
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$BASHPID" ] && continue
    { tr '\0' '\n' < "$p/cmdline"; tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qFf "$W/needles" && printf '%s\n' "${p#/proc/}" >> "$W/proc_hits2"
  done
  [ "$(rs_state)" = running: ] || break
  sleep 0.5
done
ok_if P.hintergrund-fertig '[ "$(rs_state)" = ok: ] && active_is "$KA" && prev_has "$KB" && [ "$(rows)" = "$N0" ]' "$(rs_state)"
ok_if P.hintergrund-kein-leck '[ ! -s "$W/proc_hits2" ] && ! grep -qFf "$W/needles" "$W/log/restore.log" "$BACKUP_STATE_FILE"' "Schluessel in /proc, Protokoll oder backup.state"
# Abbruch mitten im Lauf (kill -9 vor der TX, Kind sichert gerade vorab): Stand „nicht abgeschlossen“, nichts geaendert.
set_active "$KB"; env_upsert "$BACKUP_STATE_FILE" LAST_RESTORE_PID ''
frame "$W/ka" "$A"; n=$((n + 1)); BACKUP_RESTORE_LOCK="$BACKUP_RESTORE_LOCK_T" LIFEAGENTS_LOG_DIR="$W/log" "$CLI" backup restore "$(basename "$A")" --in-stdin --yes --detach --json > "$W/out.$n" 2>/dev/null < "$W/frame"
kpid=''
for _ in $(seq 1 30); do kpid="$(read_env_value "$BACKUP_STATE_FILE" LAST_RESTORE_PID)"; [ -n "$kpid" ] && break; sleep 0.1; done
kill -9 "$kpid" 2>/dev/null
# Enkel (Vorab-Sicherung) halten die geerbte Sperre, bis sie enden — erst danach ist der Lauf „nicht abgeschlossen“.
for _ in $(seq 1 120); do [ "$(rs_state)" = running: ] || break; sleep 0.5; done
ok_if P.abbruch-nicht-abgeschlossen '[ "$(rs_state)" = unfinished: ] && active_is "$KB" && [ "$(prev_n)" = 0 ] && [ "$(rows)" = "$N0" ]' "$(rs_state)"
ok_if P.abbruch-raeumt-klartext '[ ! -d "$(read_env_value "$BACKUP_STATE_FILE" LAST_RESTORE_TMP)" ]' "entschluesseltes Bundle blieb im tmpfs"
# „Eigene Daten“: System-Tabellen (Code-Seed, abgerufene Kurse) zaehlen nicht.
pg_su_psql -X -q -d "$N8N_DB_NAME" -c "CREATE TABLE public.bk_leer(x int); CREATE TABLE public.bk_voll(x int); INSERT INTO public.bk_voll VALUES (1);" >/dev/null 2>&1
# shellcheck source=/dev/null
hd() { ( for f in release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh backup_cli.sh; do . "$ROOT/provisioning/lib/$f"; done
         _sys="${2:-}"
         [ -n "$_sys" ] && _bkp_system_tables() { printf '%s\n' "$_sys"; }
         _bkp_has_data "$1" && echo ja || echo nein ) 2>/dev/null; }
ok_if P.eigene-daten '[ "$(hd public.bk_leer)" = nein ] && [ "$(hd public.bk_voll)" = ja ] && [ "$(hd public.bk_voll public.bk_voll)" = nein ]' "$(hd public.bk_leer)/$(hd public.bk_voll)/$(hd public.bk_voll public.bk_voll)"
pg_su_psql -X -q -d "$N8N_DB_NAME" -c "DROP TABLE IF EXISTS public.bk_leer, public.bk_voll" >/dev/null 2>&1

# ---------------------------------------------------------------------------- K: backup key
# Stand fuer K wie nach R: Blatt-Schluessel KA aktiv, KB als prev.
set_active "$KB"; cli_in "$W/ka" backup restore "$A" --key-stdin --yes
cli backup key; rc=$?
ok_if K.ohne-terminal-abbruch '[ "$rc" -ne 0 ] && said "Kein Terminal"' "rc=$rc"
cli backup key --file "$W/blatt.txt"; rc=$?
ok_if K.datei-0600 '[ "$rc" -eq 0 ] && [ "$(stat -c %a "$W/blatt.txt")" = 600 ]' "rc=$rc"
ok_if K.datei-inhalt '[ "$(grep -cE "^  [1-4]:  [0-9a-f]{4}(-[0-9a-f]{4}){3}  [0-9a-f]{2}$" "$W/blatt.txt")" = 8 ] && grep -qF "$kidA" "$W/blatt.txt"' "erwartet 2 Schluessel à 4 Zeilen + ID"
cli backup key --file "$W/blatt.txt"; rc=$?
ok_if K.nie-ueberschreiben '[ "$rc" -ne 0 ] && [ "$(stat -c %a "$W/blatt.txt")" = 600 ]' "rc=$rc"
cli backup key --file -; rc=$?
ok_if K.stdout '[ "$rc" -eq 0 ] && said "$kidA"' "rc=$rc"
# Die gespeicherte Datei taugt als Eingabe auf einem neuen Rechner (traegt den aktuellen und den aelteren Schluessel).
set_active "$KB"
cli_in "$W/blatt.txt" backup restore "$A" --key-stdin --yes; rc=$?
ok_if K.datei-als-eingabe '[ "$rc" -eq 0 ] && active_is "$KA" && prev_has "$KB"' "rc=$rc"
# Dasselbe Blatt (aktueller + aelterer Schluessel), die Sicherung passt zum aelteren: der wird aktiv, der andere vom Blatt
# bleibt als prev erhalten (ein neu gedrucktes Blatt kennt dann beide), der Schluessel der Neuinstallation ebenso.
set_active "$KC"
cli_in "$W/blatt.txt" backup restore "$B" --key-stdin --yes; rc=$?
ok_if K.blatt-aelterer-passt '[ "$rc" -eq 0 ] && active_is "$KB" && prev_has "$KA" && prev_has "$KC"' "rc=$rc"

# ---------------------------------------------------------------------------- U: Rueckweg behaelt den Blatt-Schluessel
# Lage nach pg_restore --create: die hergestellte DB traegt den alten Schluessel (KB), die beiseitegelegte den uebernommenen
# (KA aktiv, KB prev).
pg_su_exec dropdb --if-exists bk_carry >/dev/null 2>&1
pg_su_exec createdb bk_carry >/dev/null 2>&1
pg_su_psql -X -q -d bk_carry -c "CREATE SCHEMA core; CREATE TABLE core.backup_key (key text PRIMARY KEY, value text NOT NULL, updated_at timestamptz NOT NULL DEFAULT now());" >/dev/null 2>&1
{ psql_setvar a "$KA"; psql_setvar b "$KB"
  printf "INSERT INTO core.backup_key(key, value) VALUES ('%s', :'a'), ('%s20261101T000000000000', :'b');\n" "$BACKUP_KEY_NAME" "$BACKUP_KEY_PREV_PREFIX"; } \
  | N8N_DB_NAME=bk_carry psql_superuser_driver -q >/dev/null 2>&1
set_active "$KB"
# shellcheck source=/dev/null
( . "$ROOT/provisioning/lib/upgrade_guard.sh"; _upg_carry_backup_keys bk_carry ) > "$W/out.u1" 2>&1; rc=$?
ok_if U.rueckweg-behaelt-blatt '[ "$rc" -eq 0 ] && active_is "$KA" && prev_has "$KB"' "rc=$rc"

# ---------------------------------------------------------------------------- L: Leck-Probe Ausgaben + tmpfs
leak=0
for f in "$W"/out.* ; do
  [ -f "$f" ] || continue
  grep -qFf "$W/needles" "$f" && { leak=1; printf 'LEAK in %s\n' "${f##*/}" >&2; }
done
ok_if L.kein-schluessel-in-ausgaben '[ "$leak" = 0 ]' "Schluessel in einer CLI-Ausgabe"
printf '%s\n' "$KA" > "$W/needle_a"
ok_if L.blatt-ohne-rohschluessel '! grep -qFf "$W/needle_a" "$W/blatt.txt"' "Rohform statt Papierform"
ok_if L.tmpfs-leer '[ -z "$(ls -d /dev/shm/lifeagents-bkp.* /tmp/la_drv.* 2>/dev/null)" ]' "Reste im tmpfs"

exit "$fails"
