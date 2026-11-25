#!/usr/bin/env bash
# cases.sh — Fall-Runner von scripts/dev/backup_test.ps1, laeuft IM Substrat-Container (root, echtes PostgreSQL, die CLI
# DIESES Baums unter <root>/lifeagents). Prueft Notfallblatt und Schluessel-Uebernahme Ende zu Ende:
#   E  Export: Dateiname mit Schluessel-ID + Version, backup.state.
#   R  Restore auf "neuem Rechner" (anderer aktiver Schluessel): ohne Eingabe Abbruch, falscher Schluessel, Tippfehler,
#      beschaedigte Datei, gescheiterte TX -> jeweils nichts geaendert; mit Notfallblatt -> Daten da, Blatt-Schluessel aktiv,
#      bisheriger als prev; prev-Sicherung ohne Eingabe; zweimal hintereinander.
#   K  `backup key`: nur Terminal/--file/--file -, Datei 0600, nie ueberschreiben; die Datei selbst taugt als --key-stdin.
#   U  Rueckweg nach Update: _upg_carry_backup_keys behaelt den uebernommenen Schluessel.
#   F  `backup auto` (klassisch): Ordner, 14 behalten (Fremdes bleibt), --scheduled nur einmal am Tag, doctor ROT/gruen.
#   L  Leck-Probe: kein Schluessel in Ausgaben, /proc/*/cmdline|environ waehrend eines Restores, Resten im tmpfs.
#   P  Start-App: Probelauf, Blatt ueber stdin, Hintergrund-Lauf, Sperre, Abbruch.
#   V  Aufbau der Sicherung gegen diese Version (Versions-Sperre): neuer/aelter/vertraeglich, Release im Kopf.
#   S  Abgleich nach dem Einspielen: Code-Fakten im Stand dieser Version, Nutzer-Werte aus der Sicherung.
#   N  Fehlende Pakete ohne Terminal: ohne backup-Block uebersprungen, mit Daten ohne freiwillige Zugaenge eingerichtet.
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
# Faelle, die das Ziel der automatischen Sicherung im Dateisystem des Fall-Runners lesen (Ordner BACKUP_LOCAL_DIR, /var/backups/lifeagents):
# im Docker-Verbund liegt das Ziel in einem Ordner auf dem Rechner, den nur ein Helfer-Container erreicht, der master sieht ihn nicht.
# Dort ein sichtbares SKIP statt eines Falls, der nichts pruefen koennte.
ok_if_local() { if rt_is_compose; then printf 'SKIP %s: Ziel im Verbund = Ordner auf dem Rechner, vom master nicht lesbar\n' "$1"; else ok_if "$@"; fi; }
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
# exp_to <ordner> <ausgabe-datei> -- Export in einen Ordner. Klassisch ohne Pfad (Standard-Name im Arbeitsordner); im Verbund mit Pfad,
# denn ohne Pfad landet er in einem Ordner auf dem Rechner, den der master nicht liest. Der Name traegt die Schluessel-ID des aktiven
# Schluessels und die Release wie der Standard-Name: die Faelle zu "falscher Schluessel" erkennen den Schluessel am Dateinamen.
exp_to() {
  if rt_is_compose; then
    local kid v
    kid="$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT value FROM core.backup_key WHERE key = '${BACKUP_KEY_NAME}'" | tr -d '\n' | backup_key_id)"
    v="$(tr -d '[:space:]' < "$ROOT/VERSION")"; [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || v=vdev
    "$CLI" backup export "$1/lifeagents-backup-$(date -u +%Y%m%d%H%M%S)-${kid}-${v}.nla.enc" > "$2" 2>&1 < /dev/null
  else ( cd "$1" && "$CLI" backup export > "$2" 2>&1 < /dev/null ); fi
}
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
cleanup() { restore_orig; new_backups | xargs -r rm -f;pg_su_psql -X -q -d "$N8N_DB_NAME" -c "DROP TABLE IF EXISTS public.bk_leer, public.bk_voll" >/dev/null 2>&1; pg_su_psql -X -q -d "$N8N_DB_NAME" -c "ALTER TABLE agent.core_contexts DROP CONSTRAINT IF EXISTS bk_test_fail" >/dev/null 2>&1; pg_su_exec dropdb --if-exists bk_carry >/dev/null 2>&1
  pg_su_psql -X -q -d "$N8N_DB_NAME" -c "DROP TABLE IF EXISTS finance.bk_neu, finance.bk_ziel; ALTER TABLE finance.accounts DROP COLUMN IF EXISTS bk_neu, DROP COLUMN IF EXISTS bk_ziel, DROP COLUMN IF EXISTS bk_pflicht, DROP COLUMN IF EXISTS bk_alt, DROP COLUMN IF EXISTS bk_dev, DROP COLUMN IF EXISTS bk_ber; ALTER TABLE agent.monitor_triggers DROP COLUMN IF EXISTS bk_neu, DROP COLUMN IF EXISTS bk_std; DELETE FROM agent.monitor_triggers WHERE origin = 'user' AND label = 'bk Testfrist'; DELETE FROM finance.accounts WHERE name = 'bk Testkonto'" >/dev/null 2>&1
  [ -z "${VER0:-}" ] || printf '%s\n' "$VER0" > "$ROOT/VERSION"
  [ ! -s "$W/career.manifest" ] || cp "$W/career.manifest" "$ROOT/packages/career/manifest.json"
  [ ! -s "$W/career.sections" ] || cp "$W/career.sections" "$ROOT/packages/career/onboarding/sections.json"
  rm -rf "$W"; }
trap cleanup EXIT
# Die Zeitgeber des Substrats ruhen waehrend der Faelle (Suspend-TestTimers im Treiber, scripts/lib/test_stack.ps1): ein
# 'backup auto --scheduled' schriebe dasselbe Lebenszeichen (Signal backup), das die F.hb-Faelle pruefen.
if [ "${#KA}" -ne 64 ]; then fail setup "Substrat-Schluessel fehlt oder ist kein 64-Hex"; exit "$fails"; fi
# Erfundene Schluessel (Repo oeffentlich): "frische Installation" und "falsch".
KB="$(printf '0123456789abcdef%.0s' 1 2 3 4)"
KC="$(printf 'fedcba9876543210%.0s' 1 2 3 4)"
# Nadeln der Leck-Probe je Schluessel: Hex ganz und die ersten 16, das Token, sein 56er-Rumpf, die RFC-4648-Form vor base32 -d
# und je die ersten 16 Zeichen davon (Suche ohne Gross/klein: grep -iF).
: > "$W/needles"
for k in "$KA" "$KB" "$KC"; do
  t="$(printf '%s' "$k" | backup_key_token)"; r="${t#"${BACKUP_TOKEN_PREFIX}_"}"; f="$(printf '%s' "$r" | tr "$_BK_B32_CRO" "$_BK_B32_RFC")"
  for v in "$k" "$t" "$r" "$f"; do printf '%s\n%s\n' "$v" "${v:0:16}" >> "$W/needles"; done
done
kidA="$(printf '%s' "$KA" | backup_key_id)"
# shellcheck source=old_sheet_lib.sh
. "$ROOT/backup/old_sheet_lib.sh"
paper() { printf '%s' "$1" | old_paper; }   # gedrucktes Blatt im alten Format (bleibt gueltig)
token() { printf '%s\n' "$(printf '%s' "$1" | backup_key_token)"; }
N0="$(rows)"
BACKUP_RESTORE_LOCK_T="$W/restore.lock"
: > "$W/bk_before"; for _f in /var/backups/lifeagents/lifeagents-backup-*.nla.enc; do [ -e "$_f" ] && printf '%s\n' "$_f" >> "$W/bk_before"; done

# ---------------------------------------------------------------------------- E: Export
cli backup export "$W/x.nla.enc"; rc=$?
# Export mit Pfad schreibt genau dorthin; den Standard-Namen pruefen wir ueber ein Export ohne Pfad im Arbeitsordner.
( cd "$W" && "$CLI" backup export > "$W/out.e2" 2>&1 < /dev/null ); rc2=$?
fa="$(cd "$W" && ls -1 lifeagents-backup-*.nla.enc 2>/dev/null | head -n1)"
# Verbund: ein Export ohne Pfad landet im Ordner auf dem Rechner, nicht im Arbeitsordner; der Name steht in der Meldung.
if rt_is_compose; then
  fa="$(grep -m1 -o 'lifeagents-backup-[0-9]\{14\}-[0-9A-Za-z]*-v[0-9A-Za-z.-]*\.nla\.enc' "$W/out.e2" || true)"
  # Ohne Namen in der Meldung gaebe es keine Datei unter dem Standard-Namen: abbrechen, statt mit einer anderen Datei weiterzupruefen.
  [ -n "$fa" ] || { fail E.name-aus-meldung "kein Standard-Name in der Meldung: $(tr '\n' ' ' < "$W/out.e2" | cut -c1-200)"; exit "$fails"; }
fi
ok_if E.export-ok '[ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -s "$W/x.nla.enc" ]' "rc=$rc/$rc2"
# Alle Pakete = Fremdschluessel-Ringe (accounts, recurring_payments, ...): pg_dump -a warnt darueber; mit --disable-triggers
# harmlos, darum nicht in der Ausgabe (Live-Fund v0.43.1). Sonstige Ausgabe bleibt.
ok_if E.export-ohne-ring-warnung '! grep -q "circular foreign-key" "$W/out.e2" && grep -q "Backup geschrieben" "$W/out.e2"' \
  "$(grep -m1 'circular\|pg_dump' "$W/out.e2" || true)"
ok_if E.name-mit-id-und-version '[[ "$fa" =~ ^lifeagents-backup-[0-9]{14}-${kidA}-v[0-9A-Za-z.-]+\.nla\.enc$ ]]' "Name: $fa"
ok_if E.state-last-ok 'grep -qE "^LAST_OK=[0-9]+$" "$BACKUP_STATE_FILE"' "backup.state ohne LAST_OK"
ok_if E.schluessel-unveraendert 'active_is "$KA" && [ "$(prev_n)" = 0 ]'
A="$W/$fa"; if rt_is_compose; then cp "$W/x.nla.enc" "$A"; fi   # Verbund: der Export mit Pfad unter dem Standard-Namen (die Datei ohne Pfad liegt auf dem Rechner)

# Vollstaendigkeit: Der Export traegt jedes aktive Paket mit backup-Block. Soll = Manifest + information_schema (nicht
# _bkp_bulk_tables, sonst pruefte der Test den Code mit sich selbst); Ist = manifest.json im Bundle (Kopf, verify_counts)
# und das Inhaltsverzeichnis von data.dump. Ein Paket OHNE Block darf keine eigene Tabelle haben (z. B. Paperless: leeres
# Schema, kein Block) - sonst fehlten seine Daten still in der Sicherung.
EX="$W/ex"; mkdir -p "$EX"
gpg_sym_decrypt_any "$A" "$EX/bundle.tar.gz" && tar -xzf "$EX/bundle.tar.gz" -C "$EX"
pg_su_stdin pg_restore -l < "$EX/data.dump" 2>/dev/null | awk '/ TABLE DATA / { print $(NF-2) "." $(NF-1) }' | sort -u > "$EX/toc"
act="$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT package FROM core.package_registry WHERE status = 'active' ORDER BY package" | sort)"
miss=''; blockless=''; checked=0
for pkg in $act; do
  mf="$ROOT/packages/$pkg/manifest.json"
  [ -r "$mf" ] || { miss+="$pkg(ohne Manifest) "; continue; }
  schema="$(jq -r '.schema // empty' "$mf")"
  ntab=0
  [ -z "$schema" ] || ntab="$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = '$schema' AND table_type = 'BASE TABLE'")"
  if [ "$(jq -r 'has("backup")' "$mf")" != true ]; then
    [ "$ntab" = 0 ] || blockless+="$pkg($ntab Tabellen) "
    continue
  fi
  checked=$((checked + 1))
  want="$(jq -r '.backup.full_tables[]?' "$mf")"
  if [ "$(jq -r '.backup.schema_dump // false' "$mf")" = true ]; then
    want+=$'\n'"$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_schema = '$schema' AND table_type = 'BASE TABLE'" \
      | grep -vxF -f <(jq -r --arg s "$schema" '.backup.exclude_tables[]? | $s + "." + .' "$mf") || true)"
  fi
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    grep -qxF "$t" "$EX/toc" || miss+="$t(nicht im Dump) "
    [ "$(jq -r --arg t "$t" '.verify_counts | has($t)' "$EX/manifest.json")" = true ] || miss+="$t(nicht in verify_counts) "
  done <<< "$want"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ "$(jq -r --arg t "$t" 'has($t)' "$EX/shared.json")" = true ] || miss+="$t(nicht in shared.json) "
  done < <(jq -r '.backup.filtered_tables // {} | keys[]' "$mf")
done
ok_if E.kopf-nennt-alle-aktiven-pakete '[ -n "$act" ] && [ "$(jq -r ".packages[].name" "$EX/manifest.json" | sort)" = "$act" ]' "aktiv: ${act//$'\n'/ } / Kopf: $(jq -r '.packages[].name' "$EX/manifest.json" 2>/dev/null | sort | tr '\n' ' ')"
ok_if E.alle-bloecke-im-export '[ "$checked" -gt 0 ] && [ -z "$miss" ]' "geprueft=$checked, fehlt: $miss"
ok_if E.paket-ohne-block-hat-keine-tabellen '[ -z "$blockless" ]' "Paket ohne backup-Block, aber mit eigenen Tabellen (landet nicht im Export): $blockless"
# Schema core nur mit den Tabellen der Positivliste (contract_lint 8a: Kosten, Hinweis-Merker), nie core.backup_key.
ok_if E.export-ohne-core-schluessel '[ "$(jq -r "[.verify_counts | keys[] | select(startswith(\"core.\") and . != \"core.llm_usage\" and . != \"core.notification_state\")] | length" "$EX/manifest.json")" = 0 ] && ! grep -q "^core\." "$EX/toc" && ! grep -q backup_key "$EX/shared.json"' "core.* im Export"

# Sicherung mit dem "frischen" Schluessel KB (fuer den prev-Fall), dann ist KB aktiv wie auf einem neuen Rechner.
set_active "$KB"
mkdir -p "$W/b"; exp_to "$W/b" "$W/out.eb"
B="$(ls -1 "$W"/b/lifeagents-backup-*.nla.enc 2>/dev/null | head -n1)"
ok_if E.export-mit-zweitem-schluessel '[ -s "$B" ]'

# ---------------------------------------------------------------------------- R: Restore auf "neuem Rechner"
cli backup restore "$A" --yes; rc=$?
ok_if R.ohne-eingabe-abbruch '[ "$rc" -ne 0 ] && said -- "--key-stdin" && active_is "$KB" && [ "$(prev_n)" = 0 ]' "rc=$rc"
paper "$KC" > "$W/kc"; cli_in "$W/kc" backup restore "$A" --key-stdin --yes; rc=$?
ok_if R.falscher-schluessel '[ "$rc" -ne 0 ] && said "gehört nicht zu dieser Sicherung" && active_is "$KB" && [ "$(prev_n)" = 0 ]' "rc=$rc"
# Tippfehler in Zeile 3 so, dass das Pruefzeichen sicher nicht passt (typo_lib.sh; ein fester Tausch rutschte bei 1 von 256 Schluesseln durch).
# shellcheck source=typo_lib.sh
. "$ROOT/backup/typo_lib.sh"
l3="$(paper "$KA" | sed -n 3p | sed -E 's/^3:[[:space:]]+//; s/-//g; s/[[:space:]].*$//')"
c3="$(typo_char 3 "$l3")"
bash "$ROOT/backup/typo_lib_test.sh" "$ROOT" > "$W/typo_lib.out" 2>&1; rc=$?
ok_if R.typo-lib '[ "$rc" -eq 0 ] && [ -n "$c3" ]' "rc=$rc c3='$c3' $(tail -n 5 "$W/typo_lib.out" | tr '\n' ' ')"
# Kein Zugangsschluessel im argv beim Bau der Credentials (Restore setzt Zugaenge ueber denselben Weg).
bash "$ROOT/backup/secret_argv_cases.sh" "$ROOT" > "$W/secret_argv.out" 2>&1; rc=$?
ok_if S.secret-argv '[ "$rc" -eq 0 ] && grep -q "^PASS" "$W/secret_argv.out"' "rc=$rc $(grep '^FAIL' "$W/secret_argv.out" | tr '\n' ' ')"
paper "$KA" | sed -E "3s/^(3:  )./\\1${c3}/" > "$W/typo"
cli_in "$W/typo" backup restore "$A" --key-stdin --yes; rc=$?
ok_if R.tippfehler-zeile3 '[ "$rc" -ne 0 ] && said "Zeile 3 stimmt nicht" && active_is "$KB"' "rc=$rc"
# Notfallschluessel als Token mit einem Tippfehler (typo_token: Ersatz, bei dem die Pruefsumme sicher nicht passt).
typo_token "$(printf '%s' "$KA" | backup_key_token)" > "$W/tok_typo"
cli_in "$W/tok_typo" backup restore "$A" --key-stdin --yes; rc=$?
ok_if R.token-tippfehler '[ -s "$W/tok_typo" ] && [ "$rc" -ne 0 ] && said "hat einen Fehler" && active_is "$KB" && [ "$(prev_n)" = 0 ]' "rc=$rc"
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
# Nur der Notfallschluessel (eine Zeile, wie kopiert) — dabei /proc beobachten (Leck-Probe L). Das alte Blatt fuehrt unten
# (K.altes-blatt-gueltig, P.hintergrund-*) ebenfalls bis zur Uebernahme.
token "$KA" > "$W/kaT"
: > "$W/proc_hits"
( "$CLI" backup restore "$A" --key-stdin --yes > "$W/out.r4" 2>&1 < "$W/kaT"; echo $? > "$W/rc.r4" ) &
bg=$!
while kill -0 "$bg" 2>/dev/null; do
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$BASHPID" ] && continue
    { tr '\0' '\n' < "$p/cmdline"; tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qiFf "$W/needles" && printf '%s\n' "${p#/proc/}" >> "$W/proc_hits"
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
# --parts holt nur Gespraeche, Einstellungen und Zugaenge nach: der Text behauptet kein Ersetzen aller Nutzerdaten.
cli backup restore "$A" --parts --yes; rc=$?
ok_if R.parts-text-wahr '[ "$rc" -eq 0 ] && ! said "ALLE aktuellen Nutzerdaten" && said "nachgeholt"' "rc=$rc $(head -c 160 "$W/out.$n" | tr '\n' ' ')"
# _bkp_rs_apply liest die Option --parts aus seinen Argumenten, nicht aus einer Variablen des Aufrufers (set -u: sonst "unbound").
mkdir -p "$W/leer"
ok_if R.rs-apply-parts-ohne-aufrufer '( set -u; for f in release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh backup_cli.sh; do . "$ROOT/provisioning/lib/$f"; done; unset parts_only; _bkp_rs_apply "$W/leer" "" "" 0 "" "" "" 1 ) > "$W/out.rsa" 2>&1' "$(head -c 200 "$W/out.rsa" 2>/dev/null | tr '\n' ' ')"
# Fehlt die Option, scheitert der Aufruf laut, statt still den ersetzenden Weg zu nehmen.
ok_if R.rs-apply-ohne-option-laut '! ( set -u; for f in release_inputs.sh apply_schema.sh seed_data.sh inject_credentials.sh deploy_workflows.sh pkg_teardown.sh pkg_lifecycle.sh backup_cli.sh; do . "$ROOT/provisioning/lib/$f"; done; _bkp_rs_apply "$W/leer" "" "" 0 "" "" "" ) > "$W/out.rsb" 2>&1 && grep -q "parts_only" "$W/out.rsb"' "$(head -c 200 "$W/out.rsb" 2>/dev/null | tr '\n' ' ')"

# Jede Wiederherstellung mit eigenen Daten schreibt vorher eine Sicherung (Server: /var/backups/lifeagents).
ok_if_local R.vorab-sicherung '[ -n "$(new_backups)" ]' \
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
# Notfallschluessel als Token: als Datei-Inhalt, und so, wie die heutige App das Feld "Zeile 1" schickt (restore::Sheet::typed).
frame "$W/kaT" "$A"; n=$((n + 1)); "$CLI" backup restore "$(basename "$A")" --in-stdin --plan --json > "$W/out.$n" 2>/dev/null < "$W/frame"; rc=$?
ok_if P.probe-token '[ "$rc" -eq 0 ] && [ "$(js .adopt_key_id)" = "$kidA" ] && [ "$(fp)" = "$F0" ]' "rc=$rc $(js .code)"
printf '1: %s\n2: \n3: \n4: \n' "$(printf '%s' "$KA" | backup_key_token)" > "$W/kaF1"
frame "$W/kaF1" "$A"; n=$((n + 1)); "$CLI" backup restore "$(basename "$A")" --in-stdin --plan --json > "$W/out.$n" 2>/dev/null < "$W/frame"; rc=$?
ok_if P.probe-token-app-feld1 '[ "$rc" -eq 0 ] && [ "$(js .adopt_key_id)" = "$kidA" ]' "rc=$rc $(js .code)"
# Kaputtes Token: fuer die Start-App key_line mit Zeile 1 (eine aeltere App kennt keinen neuen Code).
frame "$W/tok_typo" "$A"; n=$((n + 1)); "$CLI" backup restore "$(basename "$A")" --in-stdin --plan --json > "$W/out.$n" 2>/dev/null < "$W/frame"; rc=$?
ok_if P.probe-token-tippfehler '[ "$rc" -ne 0 ] && [ "$(js .code)" = key_line ] && [ "$(js .line)" = 1 ] && [ "$(fp)" = "$F0" ]' "$(js .code)/$(js .line)"
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
    { tr '\0' '\n' < "$p/cmdline"; tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qiFf "$W/needles" && printf '%s\n' "${p#/proc/}" >> "$W/proc_hits2"
  done
  [ "$(rs_state)" = running: ] || break
  sleep 0.5
done
ok_if P.hintergrund-fertig '[ "$(rs_state)" = ok: ] && active_is "$KA" && prev_has "$KB" && [ "$(rows)" = "$N0" ]' "$(rs_state)"
ok_if P.hintergrund-kein-leck '[ ! -s "$W/proc_hits2" ] && ! grep -qiFf "$W/needles" "$W/log/restore.log" "$BACKUP_STATE_FILE"' "Schluessel in /proc, Protokoll oder backup.state"
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

# ---------------------------------------------------------------------------- V: Aufbau der Sicherung gegen diese Version
# Die Sperre vergleicht Tabellen und Spalten der Sicherung (COPY-Kopf des Abzugs, shared.json, verify_counts) mit dem Aufbau
# hier, nicht Paket-Nummern. Den Unterschied erzeugt echtes DDL im Substrat vor bzw. nach einem echten Export; jede Ablehnung
# muss vor jeder Aenderung kommen (Fingerabdruck gleich, keine Vorab-Sicherung). VERSION steuert die Release im Kopf.
set_active "$KA"
VER0="$(cat "$ROOT/VERSION")"
# hand-injected: das Substrat hat keinen Release-Build; VERSION ist die Quelle von _bkp_release_tag, der Export laeuft echt.
setver() { printf '%s\n' "$1" > "$ROOT/VERSION"; }
# q <sql> — Aufbau-Schritt des Tests; Fehler landen in q.err und erscheinen in der Fall-Meldung (sonst sucht man blind).
q() { pg_su_psql -X -q -v ON_ERROR_STOP=1 -d "$N8N_DB_NAME" -c "$1" >/dev/null 2>>"$W/q.err" || { printf 'q: %s\n' "${1:0:80}" >> "$W/q.err"; return 1; }; }
fin() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT count(*) || ':' || md5(COALESCE(string_agg(t::text, ',' ORDER BY t.id), '')) FROM (SELECT id, name, account_type FROM finance.accounts) t"; }
# vfp -> Fingerabdruck fuer „nichts geaendert“: Kontexte/Schluessel/Pakete/backup.state (fp) | Konten (fin) | neue Sicherungsdateien.
vfp() { printf '%s|%s|%s' "$(fp)" "$(fin)" "$(new_backups | wc -l)"; }
# vexp <ordner> -> Pfad der frischen Sicherung (Standard-Name, traegt die Release aus VERSION)
vexp() { mkdir -p "$W/v/$1"; exp_to "$W/v/$1" "$W/out.v$1"; ls -1 "$W/v/$1"/lifeagents-backup-*.nla.enc 2>/dev/null | head -n1; }
vplan() { n=$((n + 1)); "$CLI" backup restore "$1" --plan --json > "$W/out.$n" 2>"$W/err.$n" < /dev/null; }
vyes() { n=$((n + 1)); "$CLI" backup restore "$1" --yes --json > "$W/out.$n" 2>"$W/err.$n" < /dev/null; }
# vblock <fall> <bundle> <code> [release] — Probelauf und echter Lauf lehnen mit <code> ab, nichts geaendert.
vblock() {
  local f="$1" b="$2" want="$3" rel="${4:-}" v0 c1 r1 c2
  v0="$(vfp)"
  vplan "$b"; c1="$(js .code)"; r1="$(js '.release // ""')"
  vyes "$b"; c2="$(js .code)"
  ok_if "$f" '[ "$c1" = "$want" ] && [ "$c2" = "$want" ] && { [ -z "$rel" ] || [ "$r1" = "$rel" ]; } && [ "$(vfp)" = "$v0" ]' \
    "Probelauf=$c1 echt=$c2 release=$r1 / $( [ "$(vfp)" = "$v0" ] && echo unveraendert || echo GEAENDERT) / $(tail -n2 "$W/q.err" 2>/dev/null)"
}
# Ein Nutzer-Trigger, damit agent.monitor_triggers in shared.json Zeilen (und damit Spalten) traegt.
trg="$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT agent.fn_create_monitor_trigger('{\"label\": \"bk Testfrist\", \"trigger_type\": \"date\", \"due_date\": \"2030-01-01\", \"action_note\": \"Testfrist\", \"check_interval\": \"1 day\"}'::jsonb)" 2>&1)"
ntr="$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT count(*) FROM agent.monitor_triggers WHERE origin = 'user' AND label = 'bk Testfrist'")"
ok_if V.vorbereitet-trigger '[ "$ntr" = 1 ]' "n=$ntr $trg"
# Eine erfundene Konto-Zeile, damit „Daten vorher = nachher“ etwas vergleicht (das Substrat hat ohne Fixtures keine).
q "INSERT INTO finance.accounts (name, account_type) VALUES ('bk Testkonto', 'cash')"
setver v0.2.0

q "CREATE TABLE finance.bk_neu (id int PRIMARY KEY); INSERT INTO finance.bk_neu VALUES (1)"
V1="$(vexp neu-tabelle)"; q "DROP TABLE finance.bk_neu"
vblock V.neuer-tabelle "$V1" version_newer v0.2.0
q "ALTER TABLE finance.accounts ADD COLUMN bk_neu text"
V2="$(vexp neu-spalte)"; q "ALTER TABLE finance.accounts DROP COLUMN bk_neu"
vblock V.neuer-spalte "$V2" version_newer
q "ALTER TABLE agent.monitor_triggers ADD COLUMN bk_neu text"
V3="$(vexp neu-spalte-gefiltert)"; q "ALTER TABLE agent.monitor_triggers DROP COLUMN bk_neu"
vblock V.neuer-spalte-gefiltert "$V3" version_newer
# hand-injected: kein Export erzeugt heute einen fremden shared.json-Schluessel (neue gefilterte Tabelle eines neueren Stands).
V0="$(vexp basis)"
mkdir -p "$W/v/hand"; gpg_sym_decrypt "$KA" "$V0" > "$W/v/hand/b.tgz" < /dev/null; tar -xzf "$W/v/hand/b.tgz" -C "$W/v/hand"
jq '. + {"agent.bk_neu": []}' "$W/v/hand/shared.json" > "$W/v/hand/s2" && mv "$W/v/hand/s2" "$W/v/hand/shared.json"
tar -czf "$W/v/hand/n.tgz" -C "$W/v/hand" manifest.json data.dump shared.json
V4="$W/v/hand/${V0##*/}"; rm -f "$V4"; gpg_sym_encrypt "$KA" "$V4" "$W/v/hand/n.tgz"
vblock V.neuer-schluessel "$V4" version_newer
# hand-injected: eine gefilterte Zeile, die kein Objekt ist, erzeugt kein Export; die Inhaltsliste ist dann unlesbar.
mkdir -p "$W/v/kaputt"; cp "$W/v/hand/manifest.json" "$W/v/hand/data.dump" "$W/v/kaputt/"
jq '. + {"agent.monitor_triggers": [1]}' "$W/v/hand/shared.json" > "$W/v/kaputt/shared.json"
tar -czf "$W/v/kaputt/n.tgz" -C "$W/v/kaputt" manifest.json data.dump shared.json
V10="$W/v/kaputt/${V0##*/}"; rm -f "$V10"; gpg_sym_encrypt "$KA" "$V10" "$W/v/kaputt/n.tgz"
vblock V.inhalt-unlesbar "$V10" corrupt

# Aelter + vertraeglich: das Ziel bekommt nach dem Export eine leer erlaubte Spalte und eine Tabelle -> einspielen.
v0="$(fin)"
q "ALTER TABLE finance.accounts ADD COLUMN bk_ziel text; CREATE TABLE finance.bk_ziel (id int)"; qa=$?
vplan "$V0"; c1="$(js .ok)"; vyes "$V0"; rc=$?
ok_if V.aelter-vertraeglich '[ "$qa" -eq 0 ] && [ "$c1" = true ] && [ "$rc" -eq 0 ] && [ "$(fin)" = "$v0" ]' "Aufbau=$qa Probelauf=$c1/$(js .code) echt rc=$rc / $(fin) vs $v0 / $(tail -n2 "$W/q.err" 2>/dev/null)"
q "ALTER TABLE finance.accounts DROP COLUMN bk_ziel; DROP TABLE finance.bk_ziel"
# Aelter + Pflicht-Spalte ohne Standard (an einer Tabelle mit Zeilen: erst mit Standard anlegen, dann den Standard entfernen).
q "ALTER TABLE finance.accounts ADD COLUMN bk_pflicht int NOT NULL DEFAULT 0; ALTER TABLE finance.accounts ALTER COLUMN bk_pflicht DROP DEFAULT"
vblock V.aelter-pflichtspalte "$V0" version_older v0.2.0
q "ALTER TABLE finance.accounts DROP COLUMN bk_pflicht"
# Aelter + Spalte im Ziel jetzt berechnet: der Abzug liefert sie noch gespeichert, COPY wuerde erst in der TX scheitern.
q "ALTER TABLE finance.accounts ADD COLUMN bk_ber text"
V9="$(vexp berechnet)"
q "ALTER TABLE finance.accounts DROP COLUMN bk_ber; ALTER TABLE finance.accounts ADD COLUMN bk_ber text GENERATED ALWAYS AS (name) STORED"
vblock V.aelter-berechnet "$V9" version_older
q "ALTER TABLE finance.accounts DROP COLUMN bk_ber"
# Nachweislich neuere Sicherung (v0.3.0 > v0.2.0), der eine Ziel-Spalte fehlt (dort entfernt): das hilft nur ein Update.
setver v0.3.0; V8="$(vexp neuer-ohne-spalte)"; setver v0.2.0
q "ALTER TABLE finance.accounts ADD COLUMN bk_pflicht int NOT NULL DEFAULT 0; ALTER TABLE finance.accounts ALTER COLUMN bk_pflicht DROP DEFAULT"
vblock V.neuer-release-entscheidet "$V8" version_newer v0.3.0
q "ALTER TABLE finance.accounts DROP COLUMN bk_pflicht"
# Gefilterte Tabelle: die fn schreibt fehlende Schluessel als NULL (Standard greift nicht) -> Spalte mit Standard = unvertraeglich.
q "ALTER TABLE agent.monitor_triggers ADD COLUMN bk_std text DEFAULT 'x'"
vblock V.aelter-gefiltert-standard "$V0" version_older
q "ALTER TABLE agent.monitor_triggers DROP COLUMN bk_std"
# ... aber ohne Nutzer-Trigger traegt die Sicherung keine Spalten dieser Tabelle -> kein Abbruch.
q "DELETE FROM agent.monitor_triggers WHERE origin = 'user' AND label = 'bk Testfrist'"
V5="$(vexp ohne-trigger)"
q "ALTER TABLE agent.monitor_triggers ADD COLUMN bk_std text DEFAULT 'x'"
vplan "$V5"; ok_if V.gefiltert-leer '[ "$(js .ok)" = true ]' "$(js .code)"
q "ALTER TABLE agent.monitor_triggers DROP COLUMN bk_std"

# Entfernte Spalte: die Sicherung ist nachweislich aelter (v0.1.0 < v0.2.0) -> "aelter", nicht "erst aktualisieren".
setver v0.1.0; q "ALTER TABLE finance.accounts ADD COLUMN bk_alt text"
V6="$(vexp entfernt)"; q "ALTER TABLE finance.accounts DROP COLUMN bk_alt"; setver v0.2.0
vblock V.aelter-entfernt "$V6" version_older v0.1.0
# Release unbekannt (dev): Code version_newer, der Satz nennt beide Wege.
setver dev; q "ALTER TABLE finance.accounts ADD COLUMN bk_dev text"
V7="$(vexp unbekannt)"; q "ALTER TABLE finance.accounts DROP COLUMN bk_dev"
vplan "$V7"
ok_if V.release-unbekannt '[ "$(js .code)" = version_newer ] && grep -q "lifeagents update" "$W/err.$n" && grep -qF "$BACKUP_GUIDE_URL" "$W/err.$n"' "$(js .code): $(tail -n1 "$W/err.$n")"
setver v0.2.0

# Die Paket-Nummer entscheidet nichts: gleiche Tabellen, Paket-Version von Hand verstellt -> Probelauf ok.
# hand-injected: kein Export schreibt eine fremde Paket-Version.
for pv in 0.0.1 999.0.0; do
  mkdir -p "$W/v/pn$pv"; tar -xzf "$W/v/hand/b.tgz" -C "$W/v/pn$pv"
  jq --arg v "$pv" '.packages[0].version = $v' "$W/v/pn$pv/manifest.json" > "$W/v/pn$pv/m2" && mv "$W/v/pn$pv/m2" "$W/v/pn$pv/manifest.json"
  tar -czf "$W/v/pn$pv/n.tgz" -C "$W/v/pn$pv" manifest.json data.dump shared.json
  rm -f "$W/v/pn$pv/${V0##*/}"; gpg_sym_encrypt "$KA" "$W/v/pn$pv/${V0##*/}" "$W/v/pn$pv/n.tgz"
  vplan "$W/v/pn$pv/${V0##*/}"; ok_if "V.paketnummer-egal-$pv" '[ "$(js .ok)" = true ]' "$(js .code)"
done
# Kopf: neue Sicherungen tragen Release und angewandte Migrationen.
ok_if V.kopf '[ "$(jq -r .release "$W/v/hand/manifest.json")" = v0.2.0 ] && [ "$(jq -r "(.migrations // {}) | has(\"core\")" "$W/v/hand/manifest.json")" = true ]' \
  "release=$(jq -r .release "$W/v/hand/manifest.json") migrations=$(jq -c '.migrations | keys?' "$W/v/hand/manifest.json")"
# Ausgeschaltetes Paket: seine Tabellen zaehlen erst nach dem Einschalten -> keine falsche Sperre im Probelauf.
cli package deactivate estate
vplan "$V0"
ok_if V.paket-aus '[ "$(js .ok)" = true ] && [ "$(js ".packages[] | select(.name == \"estate\") | .state")" = activate ]' "$(js .code)"
cli package activate estate

# ---------------------------------------------------------------------------- S: Abgleich mit dieser Version nach dem Einspielen
# Eingespielte Tabellen tragen auch Code-Fakten (Rollen eines Onboarding-Abschnitts aus sections.json, Katalog-Zeilen einer
# *_init.sql); eine Sicherung aus einem aelteren Stand bringt dort ihren alten Wert mit. Nach dem Einspielen muessen sie dem
# Stand dieser Version entsprechen, Nutzer-Werte (Status eines Abschnitts) aber denen der Sicherung.
cro() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT count(*) || ':' || md5(COALESCE(string_agg(section_key || person_id || COALESCE(for_roles::text, '-'), ',' ORDER BY section_key, person_id), '')) FROM career.onboarding_state"; }
dlab() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT label FROM estate.directive_types WHERE doc_type = 'testament'"; }
cst() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT status FROM career.onboarding_state WHERE section_key = 'profile_basics' ORDER BY person_id LIMIT 1"; }
S_RO="$(cro)"; S_LAB="$(dlab)"; S_ST="$(cst)"
ok_if S.vorbereitet '[ "${S_RO%%:*}" -gt 0 ] && [ "$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT count(*) FROM career.onboarding_state WHERE for_roles IS NULL")" = 0 ] && [ -n "$S_LAB" ] && [ -n "$S_ST" ]' \
  "Abschnitte=$S_RO Bezeichnung=$S_LAB Status=$S_ST"
# hand-injected: kein Export eines frueheren Release im Substrat; den aelteren Stand stellt ein UPDATE vor dem Export nach
# (Rollen leer wie vor ihrer Einfuehrung, alte Katalog-Bezeichnung), dazu ein Nutzer-Status (skipped). Danach geht der Status
# im Ziel auf unknown, damit nur die Sicherung skipped zurueckbringen kann.
q "UPDATE career.onboarding_state SET for_roles = NULL; UPDATE career.onboarding_state SET status = 'skipped' WHERE section_key = 'profile_basics'; UPDATE estate.directive_types SET label = 'bk alt' WHERE doc_type = 'testament'"
S1="$(vexp abgleich)"
q "UPDATE career.onboarding_state SET status = 'unknown' WHERE section_key = 'profile_basics'"
# hand-injected: Registry-Altreste, wie sie ein frueherer Stand hinterlaesst (Eintrag aus dem Manifest entfernt, Zeile aus der Zeit
# vor der package-Spalte). Der Abgleich nach dem Einspielen (seed_data) muss sie entfernen; Manifest-Zeilen bleiben.
q "INSERT INTO core.context_validators (context_name, validate_fn, package) VALUES ('career_planning', 'career.fn_validate_career_planning', 'career'), ('bk_ohne_paket', 'core.fn_bk_alt', '') ON CONFLICT DO NOTHING;
   INSERT INTO core.context_scopes (context_name, scope, write_permission, package) VALUES ('bk_alt_scope', 'household', 'owner_only', 'core') ON CONFLICT DO NOTHING;
   INSERT INTO core.context_renderers (context_name, render_fn, package) VALUES ('bk_alt_render', 'core.fn_bk_alt', 'core') ON CONFLICT DO NOTHING"
regn() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT (SELECT count(*) FROM core.context_validators WHERE context_name IN ('career_planning','bk_ohne_paket')) + (SELECT count(*) FROM core.context_scopes WHERE context_name = 'bk_alt_scope') + (SELECT count(*) FROM core.context_renderers WHERE context_name = 'bk_alt_render')"; }
regk() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT count(*) FROM core.context_validators WHERE context_name = 'career_profile'"; }
S_REG="$(regn)"
vyes "$S1"; rc=$?
ok_if S.rollen '[ "$rc" -eq 0 ] && [ "$(cro)" = "$S_RO" ]' "rc=$rc $(js .code) / Abschnitte $(cro) statt $S_RO / $(tail -n2 "$W/err.$n")"
ok_if S.registry-altreste '[ "$S_REG" = 4 ] && [ "$(regn)" = 0 ] && [ "$(regk)" = 1 ]' "vorher $S_REG Altreste, nachher $(regn); career_profile $(regk)"
ok_if S.katalog '[ "$(dlab)" = "$S_LAB" ]' "Bezeichnung '$(dlab)'"
ok_if S.nutzerwert '[ "$(cst)" = skipped ]' "Status '$(cst)' statt skipped aus der Sicherung"
# Bricht der Abgleich ab, sind die Daten trotzdem eingespielt: der Hintergrund-Lauf endet ok, restore-status meldet
# converged:false (die App sagt bei fail „Deine Daten sind unverändert“).
# hand-injected: kein ausgeliefertes Paket laesst den Seed scheitern; eine Rolle ausserhalb des CHECK erzwingt es.
cp "$ROOT/packages/career/onboarding/sections.json" "$W/career.sections"
jq '.[0].for_roles = ["bk_keine_rolle"]' "$W/career.sections" > "$ROOT/packages/career/onboarding/sections.json"
q "UPDATE career.onboarding_state SET status = 'unknown' WHERE section_key = 'profile_basics'"
n=$((n + 1)); BACKUP_RESTORE_LOCK="$BACKUP_RESTORE_LOCK_T" LIFEAGENTS_LOG_DIR="$W/log" "$CLI" backup restore "$S1" --yes --detach --json > "$W/out.$n" 2>/dev/null < /dev/null
for _ in $(seq 1 600); do case "$(rs_state)" in running:|idle:|"") sleep 0.5 ;; *) break ;; esac; done
cp "$W/career.sections" "$ROOT/packages/career/onboarding/sections.json"
rcv() { BACKUP_RESTORE_LOCK="$BACKUP_RESTORE_LOCK_T" "$CLI" backup restore-status --json 2>/dev/null | jq -r '.converged'; }
ok_if S.abgleich-scheitert '[ "$(rs_state)" = ok: ] && [ "$(rcv)" = false ] && [ "$(cst)" = skipped ] && grep -q "Abhilfe: lifeagents update" "$W/log/restore.log"' \
  "$(rs_state) converged=$(rcv) Status=$(cst) / $(tail -n2 "$W/log/restore.log" 2>/dev/null)"
q "UPDATE career.onboarding_state SET status = '${S_ST}' WHERE section_key = 'profile_basics'"

# ---------------------------------------------------------------------------- B: vollstaendige Sicherung (Kosten, Merker, Sperrliste)
# Kostenverlauf wird zusammengefuehrt (die Kosten des Ziels bleiben), "schon gezeigt"-Merker = Stand der Sicherung ohne die
# Installations-Merker dieses Bots, Sperrliste fremder Telegram-Nutzer reist ganz mit. Eine Sicherung vom Stand davor laesst
# alle drei auf dem Ziel unberuehrt.
LU_A='1762000000000-bbbbbb-000001'; LU_B='1763000000000-cccccc-000001'
bsum() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT (SELECT string_agg(id, ',' ORDER BY id) FROM core.llm_usage WHERE id IN ('$LU_A','$LU_B'))
  || '|' || (SELECT COALESCE(string_agg(source || '/' || key, ',' ORDER BY source, key), '') FROM core.notification_state WHERE key IN ('bk_alt','bk_spaeter','ready'))
  || '|' || (SELECT COALESCE(string_agg(telegram_user_id::text, ',' ORDER BY telegram_user_id), '') FROM agent.access_blocks WHERE telegram_user_id IN (90001, 90002))"; }
q "DELETE FROM core.llm_usage WHERE id IN ('$LU_A','$LU_B'); DELETE FROM core.notification_state WHERE key IN ('bk_alt','bk_spaeter');
   DELETE FROM agent.access_blocks WHERE telegram_user_id IN (90001, 90002);
   INSERT INTO core.llm_usage (id, ts, model, input_tokens) VALUES ('$LU_A', now(), 'bk', 3);
   INSERT INTO core.notification_state (source, key, state) VALUES ('plan_news', 'bk_alt', 'fired'), ('app_button', 'ready', 'fired') ON CONFLICT DO NOTHING;
   INSERT INTO agent.access_blocks (telegram_user_id, reason) VALUES (90001, 'bk')"
B1="$(vexp voll)"
q "DELETE FROM core.llm_usage WHERE id = '$LU_A'; INSERT INTO core.llm_usage (id, ts, model, input_tokens) VALUES ('$LU_B', now(), 'bk', 5);
   DELETE FROM core.notification_state WHERE key = 'bk_alt'; INSERT INTO core.notification_state (source, key, state) VALUES ('plan_news', 'bk_spaeter', 'fired');
   DELETE FROM agent.access_blocks WHERE telegram_user_id = 90001; INSERT INTO agent.access_blocks (telegram_user_id) VALUES (90002)"
vyes "$B1"; rc=$?
ok_if B.voll-eingespielt '[ "$rc" -eq 0 ] && [ "$(bsum)" = "$LU_A,$LU_B|app_button/ready,plan_news/bk_alt|90001" ]' \
  "rc=$rc $(js .code) / $(bsum) / $(tail -n2 "$W/err.$n")"
# hand-injected: eine Sicherung vom Stand vor diesen Teilen gibt es im Substrat nicht; ein Manifest ohne sie erzeugt dieselbe Form.
cp "$ROOT/packages/core/manifest.json" "$W/core.manifest"
jq '.backup.full_tables -= ["agent.access_blocks"] | del(.backup.filtered_tables["core.llm_usage"], .backup.filtered_tables["core.notification_state"])' \
  "$W/core.manifest" > "$ROOT/packages/core/manifest.json"
B0="$(vexp alt)"
cp "$W/core.manifest" "$ROOT/packages/core/manifest.json"
B_VOR="$(bsum)"
vyes "$B0"; rc=$?
ok_if B.alte-sicherung-laesst-neue-teile '[ "$rc" -eq 0 ] && [ -n "$B_VOR" ] && [ "$(bsum)" = "$B_VOR" ]' "rc=$rc $(js .code) / vorher $B_VOR nachher $(bsum)"
q "DELETE FROM core.llm_usage WHERE id IN ('$LU_A','$LU_B'); DELETE FROM core.notification_state WHERE key IN ('bk_alt','bk_spaeter');
   DELETE FROM agent.access_blocks WHERE telegram_user_id IN (90001, 90002)"

# ---------------------------------------------------------------------------- N: fehlende Pakete, Start-App (ohne Terminal)
# Neuer Rechner ohne Karriere und Paperless. Beide werden eingerichtet (Paperless hat keine Daten, sein backup-Block macht es
# einspielbar). Zugaenge kommen aus der Sicherung (access.json): Karriere traegt nur den JSearch-Schluessel, Adzuna fehlt -> der
# Zugang gilt weiter als fehlend; Paperless traegt seinen Schluessel, wenn das Substrat einen hat.
# hand-injected: das Substrat installiert Karriere ohne Fremd-Schluessel; ein erfundener JSearch-Wert zeigt den Rueckweg.
ZK='bk-jsearch\erfunden-0042'   # mit Rueckwaertsstrich: der Zugangs-Rundlauf darf ihn nicht veraendern
( umask 077; env_upsert "$(lifeagents_env_file career)" JSEARCH_API_KEY "$ZK" )
ZP="$(read_env_value "$(lifeagents_env_file paperless)" PAPERLESS_API_TOKEN 2>/dev/null || true)"
NB="$(vexp pakete)"
mkdir -p "$W/v/zg"; gpg_sym_decrypt "$KA" "$NB" > "$W/v/zg/b.tgz" < /dev/null; tar -xzf "$W/v/zg/b.tgz" -C "$W/v/zg"
ok_if Z.zugang-im-bundle '[ "$(jq -r ".career.JSEARCH_API_KEY // empty" "$W/v/zg/access.json")" = "$ZK" ] && [ "$(jq -r ".parts | index(\"access\") != null" "$W/v/zg/manifest.json")" = true ]' \
  "$(jq -c 'keys' "$W/v/zg/access.json" 2>/dev/null) / $(jq -c .parts "$W/v/zg/manifest.json" 2>/dev/null)"
rm -rf "$W/v/zg"
cli package uninstall career --purge --yes; cli package uninstall paperless --purge --yes
reg() { pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT COALESCE(string_agg(package || ':' || status, ',' ORDER BY package), '') FROM core.package_registry WHERE package IN ('career', 'paperless')"; }
ok_if N.vorbereitet '[ -z "$(reg)" ]' "$(reg)"
# hand-injected: kein ausgeliefertes Paket hat einen Pflicht-Zugang; das Manifest wird nur fuer diesen Fall umgestellt.
cp "$ROOT/packages/career/manifest.json" "$W/career.manifest"
jq '.credentials.adzuna.required = true' "$W/career.manifest" > "$ROOT/packages/career/manifest.json"
vplan "$NB"; ok_if N.pflicht-zugang '[ "$(js .code)" = needs_setup ] && [ "$(js .pkg)" = career ]' "$(js .code)/$(js .pkg)"
# Pflicht-Zugang, den die Sicherung traegt (JSearch): kein Abbruch, die Einrichtung liest ihn aus access.json.
jq '.credentials.jsearch.required = true' "$W/career.manifest" > "$ROOT/packages/career/manifest.json"
vplan "$NB"; ok_if N.pflicht-zugang-im-bundle '[ "$(js .ok)" = true ]' "$(js .code)/$(js .pkg)"
cp "$W/career.manifest" "$ROOT/packages/career/manifest.json"
ZEXP='["career","paperless"]'; [ -z "$ZP" ] || ZEXP='["career"]'   # Paperless-Zugang deckt die Sicherung, wenn das Substrat einen hat
vplan "$NB"
ok_if N.probelauf '[ "$(js .ok)" = true ] && [ "$(js ".packages[] | select(.name == \"career\") | .state")" = install ] && [ "$(js ".packages[] | select(.name == \"paperless\") | .state")" = install ] && [ "$(js ".missing_access | tojson")" = "$ZEXP" ] && [ -z "$(reg)" ]' \
  "$(js .code) / $(js ".packages | tojson") / $(js ".missing_access | tojson") / $(reg)"
n=$((n + 1)); BACKUP_RESTORE_LOCK="$BACKUP_RESTORE_LOCK_T" LIFEAGENTS_LOG_DIR="$W/log" "$CLI" backup restore "$NB" --yes --detach --json > "$W/out.$n" 2>/dev/null < /dev/null
for _ in $(seq 1 600); do case "$(rs_state)" in running:|idle:|"") sleep 0.5 ;; *) break ;; esac; done
ok_if N.eingespielt '[ "$(rs_state)" = ok: ] && [ "$(reg)" = career:active,paperless:active ] && grep -q "package reconfigure career" "$W/log/restore.log"' "$(rs_state) / $(reg) / $(tail -c 300 "$W/out.$n") / $(tail -n3 "$W/log/restore.log" 2>/dev/null)"
ok_if Z.zugang-zurueck '[ "$(read_env_value "$(lifeagents_env_file career)" JSEARCH_API_KEY 2>/dev/null)" = "$ZK" ] && grep -q "JSearch RapidAPI" "$W/log/restore.log" && ! grep -qF "$ZK" "$W/log/restore.log"' \
  "career.env JSEARCH=$(read_env_value "$(lifeagents_env_file career)" JSEARCH_API_KEY 2>/dev/null | head -c 4)… / $(grep -c "JSearch" "$W/log/restore.log" 2>/dev/null)"
if [ -n "$ZP" ]; then ok_if Z.paperless-zugang '[ "$(read_env_value "$(lifeagents_env_file paperless)" PAPERLESS_API_TOKEN 2>/dev/null)" = "$ZP" ]' "Paperless-Schluessel fehlt nach dem Einspielen"; fi
# Erst eingerichtetes Paket mit abweichendem Aufbau: der Probelauf kann es nicht pruefen, der Hintergrund-Lauf prueft nach dem
# Einrichten und bricht vor der Vorab-Sicherung ab; restore-status nennt die Release fuer den App-Text.
ct="$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'career' AND table_type = 'BASE TABLE' ORDER BY table_name LIMIT 1")"
q "ALTER TABLE career.${ct} ADD COLUMN bk_neu text"
NB2="$(vexp pakete-neu)"; q "ALTER TABLE career.${ct} DROP COLUMN bk_neu"
cli package uninstall career --purge --yes
nb0="$(new_backups | wc -l)"
n=$((n + 1)); BACKUP_RESTORE_LOCK="$BACKUP_RESTORE_LOCK_T" LIFEAGENTS_LOG_DIR="$W/log" "$CLI" backup restore "$NB2" --yes --detach --json > "$W/out.$n" 2>/dev/null < /dev/null
for _ in $(seq 1 600); do case "$(rs_state)" in running:|idle:|"") sleep 0.5 ;; *) break ;; esac; done
rsr() { BACKUP_RESTORE_LOCK="$BACKUP_RESTORE_LOCK_T" "$CLI" backup restore-status --json 2>/dev/null | jq -r '.release // ""'; }
ok_if V.status-release '[ "$(rs_state)" = fail:version_newer ] && [ "$(rsr)" = v0.2.0 ] && [ "$(new_backups | wc -l)" = "$nb0" ]' "$(rs_state) release=$(rsr)"
# Paperless fuer die folgenden Faelle wieder einrichten (wie die Einrichtung ohne Terminal; Ergebnis nicht Teil der Pruefung).
cli package install paperless
setver "$VER0"
set_active "$KB"

# ---------------------------------------------------------------------------- K: backup key
# Stand fuer K wie nach R: Blatt-Schluessel KA aktiv, KB als prev.
set_active "$KB"; cli_in "$W/ka" backup restore "$A" --key-stdin --yes
cli backup key; rc=$?
ok_if K.ohne-terminal-abbruch '[ "$rc" -ne 0 ] && said "Kein Terminal"' "rc=$rc"
cli backup key --file "$W/blatt.txt"; rc=$?
ok_if K.datei-0600 '[ "$rc" -eq 0 ] && [ "$(stat -c %a "$W/blatt.txt")" = 600 ]' "rc=$rc"
# Je Schluessel eine Token-Zeile, keine Zeilen des alten Blatts, ID, und eine Zeile "1:" (Pruefung der heutigen Start-App beim Speichern).
ok_if K.blatt-token '[ "$(grep -cE "^  labk1_[0-9a-hjkmnp-tv-z]{56}$" "$W/blatt.txt")" = 2 ] && ! grep -qE "^ *[1-4]: +[0-9a-f]{4}-" "$W/blatt.txt" && grep -qF "$kidA" "$W/blatt.txt" && grep -qF "$(printf "%s" "$KA" | backup_key_token)" "$W/blatt.txt" && grep -qE "^1: " "$W/blatt.txt"' \
  "erwartet 2 Token-Zeilen + ID + Schritt 1:"
cli backup key --file "$W/blatt.txt"; rc=$?
ok_if K.nie-ueberschreiben '[ "$rc" -ne 0 ] && [ "$(stat -c %a "$W/blatt.txt")" = 600 ]' "rc=$rc"
cli backup key --file -; rc=$?; k_stdout_n=$n   # diese Ausgabe ist das Blatt selbst (L ueberspringt sie)
ok_if K.stdout '[ "$rc" -eq 0 ] && said "$kidA"' "rc=$rc"
# Nur der Notfallschluessel (Start-App „Notfallschluessel kopieren“): genau eine Zeile, das Token des aktiven Schluessels.
cli backup key --token; rc=$?; k_token_n=$n   # diese Ausgabe ist der Schluessel selbst (L ueberspringt sie)
ok_if K.token-nur-zeile '[ "$rc" -eq 0 ] && [ "$(cat "$W/out.$n")" = "$(printf "%s" "$KA" | backup_key_token)" ] && [ "$(wc -l < "$W/out.$n")" = 1 ]' "rc=$rc"
cli backup key --token --file -; rc=$?
ok_if K.token-nicht-mit-file '[ "$rc" -ne 0 ]' "rc=$rc"
# Die gespeicherte Datei taugt als Eingabe auf einem neuen Rechner (traegt den aktuellen und den aelteren Schluessel).
set_active "$KB"
cli_in "$W/blatt.txt" backup restore "$A" --key-stdin --yes; rc=$?
ok_if K.datei-als-eingabe '[ "$rc" -eq 0 ] && active_is "$KA" && prev_has "$KB"' "rc=$rc"
# Dasselbe Blatt (aktueller + aelterer Schluessel), die Sicherung passt zum aelteren: der wird aktiv, der andere vom Blatt
# bleibt als prev erhalten (ein neu gedrucktes Blatt kennt dann beide), der Schluessel der Neuinstallation ebenso.
set_active "$KC"
cli_in "$W/blatt.txt" backup restore "$B" --key-stdin --yes; rc=$?
ok_if K.blatt-aelterer-passt '[ "$rc" -eq 0 ] && active_is "$KB" && prev_has "$KA" && prev_has "$KC"' "rc=$rc"
# Gedrucktes Blatt im alten Format (fixtures/notfallblatt-alt.txt: Ausgabe vor dem Token, erfundene Schluessel KB aktuell + KC
# aelter) bleibt gueltig: Sicherung B (KB) auf einem Rechner mit KC.
set_active "$KC"
cli_in "$ROOT/backup/fixtures/notfallblatt-alt.txt" backup restore "$B" --key-stdin --yes; rc=$?
ok_if K.altes-blatt-gueltig '[ "$rc" -eq 0 ] && active_is "$KB" && prev_has "$KC"' "rc=$rc"

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

# ---------------------------------------------------------------------------- F: automatische Sicherung (klassischer Betrieb)
# `backup auto` im LXC: Ordner BACKUP_LOCAL_DIR (hier ein Wegwerf-Ordner), die letzten 14, Vorab-Sicherungen und fremde Schluessel
# bleiben, --scheduled nur wenn heute noch nichts gelang. curl ist eine Attrappe (die Off-Site-Kopie ginge sonst ans Netz).
set_active "$KA"
mkdir -p "$W/shim"; printf '#!/bin/sh\nexit 0\n' > "$W/shim/curl"; chmod +x "$W/shim/curl"
export BACKUP_LOCAL_DIR="$W/local"; PATH_VOR_F="$PATH"; export PATH="$W/shim:$PATH"
own_n() { find "$W/local" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | grep -cE "^lifeagents-backup-[0-9]{14}-${kidA}-v[0-9A-Za-z.-]+\.nla\.enc\$"; }
rm -f "$BACKUP_STATE_FILE"
cli backup auto; rc=$?
ok_if_local F.auto-schreibt-in-ordner '[ "$rc" -eq 0 ] && [ "$(own_n)" = 1 ]' "rc=$rc n=$(own_n)"
ok_if_local F.ordner-nur-fuer-root '[ "$(stat -c %a "$W/local")" = 700 ]'
ok_if F.auto-last-ok '[ "$(( $(date +%s) - $(read_env_value "$BACKUP_STATE_FILE" LAST_OK) ))" -lt 120 ]'
ok_if F.auto-ohne-schluessel-in-ausgabe '! grep -qiFf "$W/needles" "$W/out.$n"'
erste="$(ls -1 "$W/local" | head -n1)"
# --scheduled: heute schon gesichert -> nichts; seit 3 Tagen nicht -> eine neue Datei.
cli backup auto --scheduled; rc=$?
ok_if_local F.scheduled-heute-schon-gesichert '[ "$rc" -eq 0 ] && [ "$(own_n)" = 1 ]' "rc=$rc n=$(own_n)"
env_upsert "$BACKUP_STATE_FILE" LAST_OK "$(( $(date +%s) - 3 * 86400 ))"
sleep 1; cli backup auto --scheduled; rc=$?
ok_if_local F.scheduled-nach-3-tagen-sichert '[ "$rc" -eq 0 ] && [ "$(own_n)" = 2 ]' "rc=$rc n=$(own_n)"
# Aufbewahrung: 16 alte eigene + 1 fremder Schluessel + 1 Vorab-Sicherung; danach bleiben 14 eigene (die neuesten).
for i in $(seq 1 16); do : > "$W/local/lifeagents-backup-2026010100$(printf %02d "$i")00-${kidA}-v0.0.1.nla.enc"; done
: > "$W/local/lifeagents-backup-20250101000000-kdeadbeef-v0.0.1.nla.enc"
: > "$W/local/pre-upgrade-n8n-1.0.0-20260101T000000Z.dump.gpg"
env_upsert "$BACKUP_STATE_FILE" LAST_OK "$(( $(date +%s) - 3 * 86400 ))"
sleep 1; cli backup auto; rc=$?
ok_if_local F.rotation-behaelt-14 '[ "$rc" -eq 0 ] && [ "$(own_n)" = 14 ]' "rc=$rc n=$(own_n)"
ok_if_local F.rotation-loescht-die-aeltesten '[ ! -e "$W/local/lifeagents-backup-20260101000100-${kidA}-v0.0.1.nla.enc" ] && [ -e "$W/local/lifeagents-backup-20260101001600-${kidA}-v0.0.1.nla.enc" ] && [ -e "$W/local/$erste" ]' "Reihenfolge"
ok_if_local F.rotation-laesst-fremdes-liegen '[ -e "$W/local/lifeagents-backup-20250101000000-kdeadbeef-v0.0.1.nla.enc" ] && [ -e "$W/local/pre-upgrade-n8n-1.0.0-20260101T000000Z.dump.gpg" ]'
# Ordner nicht anlegbar: kein Abbruch (rc 0), Grund "write" in backup.state.
BACKUP_LOCAL_DIR=/proc/nirgends/sicherung cli backup auto; rc=$?
ok_if_local F.ordner-fehlt-grund-write '[ "$rc" -eq 0 ] && [ "$(read_env_value "$BACKUP_STATE_FILE" LAST_FAIL_REASON)" = write ]' "rc=$rc"
# Lebenszeichen fuer den Waechter (core.heartbeats, Signal backup): jeder Lauf am Ende, mit der letzten eigenen Meldung;
# ein abgebrochener Lauf (Zeitgrenze) schreibt keins. gpg haengt per Attrappe, damit der Lauf sicher vor dem Ende stirbt.
hbq() { pg_su_psql -X -tA -q -d "$N8N_DB_NAME" -c "SELECT status || '|' || COALESCE(extract(epoch FROM notified_at)::bigint::text, '') || '|' || (beat_at > now() - interval '60 seconds') FROM core.heartbeats WHERE signal = 'backup'" 2>/dev/null; }
hbr() { q "DELETE FROM core.heartbeats; DELETE FROM core.heartbeat_observer;"; }
hbr; env_upsert "$BACKUP_STATE_FILE" LAST_OK "$(( $(date +%s) - 3 * 86400 ))"; sleep 1; cli backup auto --scheduled
ok_if F.hb-versuch 'h="$(hbq)"; [ "$h" = "attempted||true" ]' "backup=[$(hbq)]"
hbr; cli backup auto --scheduled
ok_if F.hb-heute-schon-gesichert '[ "$(hbq)" = "current||true" ]' "backup=[$(hbq)]"
hbr; env_upsert "$BACKUP_STATE_FILE" LAST_NOTIFY 1781000000
# Wie der minuetliche Runner (Timer lifeagents-update-run, Beat vor der Sperre): sein erstes Lebenszeichen legt die
# backup-Zeile als 'pending' an. Fest gesetzt, damit der Fall nicht davon abhaengt, ob die volle Minute hineinfaellt.
heartbeat_record loop ok
mkdir -p "$W/shim2"; printf '#!/bin/sh\nexec sleep 6\n' > "$W/shim2/gpg"; chmod +x "$W/shim2/gpg"
shm_vor="$(ls -d /dev/shm/lifeagents-bkp.* /tmp/la_drv.* 2>/dev/null || true)"
PATH="$W/shim2:$PATH" timeout -s KILL 3 "$CLI" backup auto > /dev/null 2>&1 < /dev/null
ok_if F.hb-abgebrochen-ohne-beat '[ "$(hbq)" = "pending||true" ]' "backup=[$(hbq)]"
# KILL laesst keinen trap laufen: nur die Reste DIESES Laufs entfernen, damit L.tmpfs-leer die anderen Faelle prueft.
for d in $(ls -d /dev/shm/lifeagents-bkp.* /tmp/la_drv.* 2>/dev/null || true); do
  case "$(printf '\n%s\n' "$shm_vor")" in *$'\n'"$d"$'\n'*) ;; *) rm -rf -- "$d" ;; esac
done
sleep 4; cli backup auto
ok_if F.hb-mit-letzter-meldung '[ "$(hbq)" = "attempted|1781000000|true" ]' "backup=[$(hbq)]"
hbr
# doctor (klassisch): ROT statt WARN; frisch = gruen. Echter Code von doctor.sh in einer Teilschale.
dr_backup() {   # dr_backup <LAST_OK-Alter in s|-> <grund|-> <VERSION-Alter-Tage> -> Zeile + fail=<n>
  local st="$W/dr.state" ver="$W/dr.VERSION"; rm -f "$st"; : > "$ver"
  [ "$1" = - ] || env_upsert "$st" LAST_OK "$(( $(date +%s) - $1 ))"
  [ "$2" = - ] || env_upsert "$st" LAST_FAIL_REASON "$2"
  [ -z "${DR_SIZE:-}" ] || env_upsert "$st" LAST_SIZE "$DR_SIZE"
  touch -d "$3 days ago" "$ver"
  ( . "$ROOT/provisioning/doctor.sh" >/dev/null 2>&1
    BACKUP_STATE_FILE="$st"; _fail=0; unset LIFEAGENTS_RUNTIME
    lifeagents_version_marker() { printf '%s' "$ver"; }
    _doctor_backup; echo "fail=$_fail" )
}
out="$(dr_backup 3600 - 30)"; ok_if F.doctor-heute-gruen 'printf "%s" "$out" | grep -q "^  \[ OK \] Letzte Sicherung: heute" && [ "$(printf "%s" "$out" | tail -n1)" = fail=0 ]' "$out"
out="$(dr_backup $((3 * 86400)) - 30)"; ok_if F.doctor-veraltet-rot 'printf "%s" "$out" | grep -q "^  \[FAIL\] Letzte Sicherung: vor 3 Tagen — Verlauf: journalctl -u lifeagents-backup" && [ "$(printf "%s" "$out" | tail -n1)" = fail=1 ]' "$out"
out="$(dr_backup $((3 * 86400)) encrypt 30)"; ok_if F.doctor-volles-ziel-rot-mit-platzhinweis 'printf "%s" "$out" | grep -q "^  \[FAIL\] Letzte Sicherung.*Platz prüfen: df -h " && [ "$(printf "%s" "$out" | tail -n1)" = fail=1 ]' "$out"
out="$(dr_backup - - 0)"; ok_if F.doctor-frische-installation-gruen 'printf "%s" "$out" | grep -q "^  \[ OK \] Letzte Sicherung: noch keine erfasst" && [ "$(printf "%s" "$out" | tail -n1)" = fail=0 ]' "$out"
out="$(DR_SIZE=$((45 * 1024 * 1024)) dr_backup 3600 - 30)"; ok_if F.doctor-grosse-sicherung-gelb 'printf "%s" "$out" | grep -q "Sicherung ist 45 MB groß" && [ "$(printf "%s" "$out" | tail -n1)" = fail=0 ]' "$out"
out="$(dr_backup - - 5)"; ok_if F.doctor-nie-gesichert-nach-frist-rot 'printf "%s" "$out" | grep -q "^  \[FAIL\] Letzte Sicherung: noch keine" && [ "$(printf "%s" "$out" | tail -n1)" = fail=1 ]' "$out"
export PATH="$PATH_VOR_F"; unset BACKUP_LOCAL_DIR

# ---------------------------------------------------------------------------- L: Leck-Probe Ausgaben + tmpfs
leak=0
for f in "$W"/out.* ; do
  [ -f "$f" ] || continue
  [ "$f" != "$W/out.${k_stdout_n:-x}" ] && [ "$f" != "$W/out.${k_token_n:-x}" ] || continue
  grep -qiFf "$W/needles" "$f" && { leak=1; printf 'LEAK in %s\n' "${f##*/}" >&2; }
done
ok_if L.kein-schluessel-in-ausgaben '[ "$leak" = 0 ]' "Schluessel in einer CLI-Ausgabe"
printf '%s\n' "$KA" > "$W/needle_a"
ok_if L.blatt-ohne-rohschluessel '! grep -qFf "$W/needle_a" "$W/blatt.txt"' "Rohform statt Token"
ok_if L.tmpfs-leer '[ -z "$(ls -d /dev/shm/lifeagents-bkp.* /tmp/la_drv.* 2>/dev/null)" ]' "Reste im tmpfs"

exit "$fails"
