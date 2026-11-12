#!/usr/bin/env bash
# cases.sh — Fall-Runner von scripts/dev/runtime_test.ps1, laeuft IM Substrat-Container (root, bash 5, jq).
#
# Faehrt den ECHTEN Code des Worktrees (provisioning/lib/common.sh -> runtime.sh, release_inputs.sh) gegen Attrappen:
#   A  Antwort-Datei (install_answers_load): liest 'Text', "Text", Woerter, '\'', Kommentare; fuehrt NIE etwas aus
#      ($(), Backticks, ;, Leerzeichen-Befehl), Zeilenumbruch im Wert bleibt Wert, gesperrte Schluessel, CR, Meldung ohne Wert.
#   W  Betriebsart-Wrapper: systemd-Zweig ruft runuser/systemctl genau wie vorher; compose-Zweig ruft docker exec mit
#      festem Container, -i nur, wenn psql stdin liest (Probelauf-Fund: `docker exec -i` frass die Paket-Schleife).
#   V  rt_volumes_ensure: legt fehlende Volumes mit Label an, bricht bei fremdem Volume gleichen Namens ab.
#   N  PG-Minor-Neustart (install_pg.sh): laufende Minor != Paket-Minor -> gezielter Neustart, Zweitlauf/Verbund no-op.
#   T  Telegram-Pruefung (Pruefliste Nr. 10): frei / unser Webhook / fremder Webhook / 409 Long-Polling / nicht pruefbar;
#      unattended Erstinstallation bricht ohne TELEGRAM_WEBHOOK_TAKEOVER=1 ab, nie mit offset/drop_pending_updates.
# Braucht kein n8n, kein Docker und kein Netz.
#
# Usage: bash cases.sh <root>      Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2016,SC2329  # Pruef-Ausdruecke stehen bewusst in einfachen Quotes (eval im Fall); Attrappen-Funktionen ruft der Lib-Code
set -uo pipefail
ROOT="$1"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
# Attrappen: protokollieren argv (eine Zeile, Felder mit | getrennt) und ob stdin Daten lieferte.
for c in docker systemctl runuser; do
  cat > "$W/bin/$c" <<'STUB'
#!/usr/bin/env bash
me="$(basename "$0")"
# Wie das echte docker: stdin wird nur mit `exec -i` gelesen (dann bis EOF) — genau das frass die Paket-Schleife.
in=''
if [ -n "${STUB_STDIN:-}" ] && [ "$me" = docker ] && [ "${1:-}" = exec ] && [ "${2:-}" = -i ]; then in="$(cat)"; fi
{ printf '%s' "$me"; printf '|%s' "$@"; printf '|stdin=%s\n' "${in:+ja}"; } >> "$STUB_LOG"
# Compose-Aufrufe: mit welcher Datei und welchem master-Image (Umgebung) — der master-Wechsel haengt genau daran.
if [ "$me" = docker ] && [ "${1:-}" = compose ]; then printf '%s|%s\n' "${5:-}" "${LA_MASTER_IMAGE:--}" >> "${STUB_LOG}.env"; fi
# Abbau: welche Profile Compose dabei kannte (sonst blieben Container aus Profilen stehen).
case "$(printf '|%s' "$@")" in *'|down|'*) printf '%s\n' "${COMPOSE_PROFILES:-}" >> "${STUB_LOG}.profiles" ;; esac
# Gezielter Fehlschlag: STUB_FAIL = Teilstring der argv-Zeile (z. B. "pull", "run|--rm|-d", "exec|lifeagents-master|bash").
if [ -n "${STUB_FAIL:-}" ]; then case "$(printf '|%s' "$@")" in *"$STUB_FAIL"*) echo "stub: Daemon-Fehler" >&2; exit 1 ;; esac; fi
case "$me $1 ${2:-}" in
  "docker volume inspect") [ -n "${STUB_VOL_LABEL+x}" ] && { printf '%s\n' "$STUB_VOL_LABEL"; exit 0; }; exit 1 ;;
  "docker image inspect")  [ "${STUB_IMAGE_PRESENT:-1}" = 1 ]; exit $? ;;
  "docker ps --format")    printf '%s' "${STUB_PS:-}"; exit 0 ;;   # STUB_PS = Zeilen wie aus dem festen JSON-Format
  "docker inspect -f")
    # STUB_RUNNING = laufende Container (Leerzeichen-Liste); STUB_IMG_<name mit _> = Image eines Containers.
    n="${*: -1}"
    case "$3" in
      *State.Running*) case " ${STUB_RUNNING:-} " in *" $n "*) echo true ;; *) echo false ;; esac ;;
      *Config.Image*)  v="STUB_IMG_$(printf '%s' "$n" | tr -c 'A-Za-z0-9\n' _)"; [ -n "${!v:-}" ] || exit 1; printf '%s\n' "${!v}" ;;
    esac
    exit 0 ;;
esac
case "$(printf '|%s' "$@")" in
  *"|config|--format|json|"*) printf '%s' "${STUB_CONFIG_JSON:-}"; exit 0 ;;
  *"|config|--profiles") printf '%s' "${STUB_PROFILES:-}"; exit 0 ;;
  *"|cat|/var/lib/postgresql/data/PG_VERSION"*) printf '%s\n' "${STUB_PG_MAJOR:-17}"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$W/bin/$c"
done
export PATH="$W/bin:$PATH" STUB_LOG="$W/log"

# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/release_inputs.sh"
# Abbruch statt exit: die laeuft in den Faellen in einer Subshell.
die() { printf 'DIE: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------- A: Antwort-Datei
P="$W/pwned"
ok_ans() { if ( install_answers_load "$W/a"; eval "$2" ) 2>"$W/err"; then pass "$1"; else fail "$1" "$(head -c 300 "$W/err")"; fi; }
no_ans() { if ( install_answers_load "$W/a" ) 2>"$W/err"; then fail "$1" "kein Abbruch"; else pass "$1"; fi; }
printf '%s\n' "A='x y'" > "$W/a";                       ok_ans A.einfach-quotiert '[ "$A" = "x y" ]'
printf '%s\n' "A='it'\''s'" > "$W/a";                   ok_ans A.apostroph "[ \"\$A\" = \"it's\" ]"
printf '%s\n' "A=0" "B=foo.bar@x.com" > "$W/a";         ok_ans A.woerter '[ "$A" = 0 ] && [ "$B" = foo.bar@x.com ]'
printf '%s' 'A="hello world"' > "$W/a";                  ok_ans A.doppelt-ohne-umbruch '[ "$A" = "hello world" ]'
printf '%s\n' '# k' '' 'A=1 # rest' "  export B='2'" > "$W/a"; ok_ans A.kommentare-export '[ "$A" = 1 ] && [ "$B" = 2 ] && env | grep -q "^B=2$"'
cat > "$W/a" <<X
A='\$(touch $P)'
X
ok_ans A.dollar-klammer-bleibt-text "[ \"\$A\" = '\$(touch $P)' ] && [ ! -e $P ]"
printf '%s\n' "A='a" "PATH=/evil'" > "$W/a";            ok_ans A.zeilenumbruch-bleibt-wert '[ "$A" = "a"$'"'"'\n'"'"'"PATH=/evil" ] && [ "$PATH" != /evil ]'
printf '%s\n' "A=''" "B=" > "$W/a";                     ok_ans A.leer '[ -z "$A" ] && [ -z "$B" ]'
cat > "$W/a" <<'X'
N8N_OWNER_PASSWORD='Ab1'\'';$(x)`y`\'
X
ok_ans A.passwort-sonderzeichen '[ "$N8N_OWNER_PASSWORD" = "Ab1'"'"';\$(x)\`y\`\\" ]'
printf '%s\n' "A=\$(touch $P)" > "$W/a";                no_ans A.befehl-ersetzung
printf '%s\n' 'A=`touch '"$P"'`' > "$W/a";              no_ans A.backticks
printf '%s\n' 'A="$HOME"' > "$W/a";                     no_ans A.doppelt-mit-dollar
printf '%s\n' "A=x touch $P" > "$W/a";                  no_ans A.leerzeichen-befehl
printf '%s\n' "A=x;touch $P" > "$W/a";                  no_ans A.semikolon
printf '%s\n' "A='offen" > "$W/a";                      no_ans A.offenes-quote
# Gesperrte Schluessel: uebersprungen (Warnung), nie gesetzt, die uebrigen Zeilen gelten weiter.
printf '%s\n' 'PATH=/x' 'A=1' > "$W/a";                 ok_ans A.gesperrt-PATH '[ "$PATH" != /x ] && [ "$A" = 1 ]'
printf '%s\n' 'LD_PRELOAD=/x' > "$W/a";                 ok_ans A.gesperrt-LD '[ "${LD_PRELOAD:-}" != /x ]'
printf '%s\n' 'LIFEAGENTS_RUNTIME=ausdatei' > "$W/a";   ok_ans A.gesperrt-runtime '[ "${LIFEAGENTS_RUNTIME:-}" != ausdatei ]'
printf '%s\n' 'LIFEAGENTS_TELEGRAM_API=http://x.invalid' > "$W/a"; ok_ans A.gesperrt-telegram-ziel '[ "${LIFEAGENTS_TELEGRAM_API:-}" != http://x.invalid ]'
printf '%s\n' "TZ='Europe/Vienna'" 'B=2' > "$W/a";      ok_ans A.gesperrt-alte-datei-laeuft-weiter '[ "${TZ:-}" != Europe/Vienna ] && [ "$B" = 2 ]'
printf 'A=1\n# Ende' > "$W/a";                          ok_ans A.kommentar-am-ende-ohne-umbruch '[ "$A" = 1 ]'
printf "PATH='\$(touch %s)'\n" "$P" > "$W/a";           ok_ans A.gesperrt-wert-nie-ausgefuehrt "[ ! -e '$P' ]"
printf '%s\n' 'a=1' > "$W/a";                           no_ans A.kleinbuchstaben
printf 'A=1\r\n' > "$W/a";                              no_ans A.crlf
printf '%s\n' "touch $P" > "$W/a";                      no_ans A.nackter-befehl
printf '%s\n' 'A=~/x' > "$W/a";                         no_ans A.tilde
printf '%s\n' 'A=1' "B='geheimwert" > "$W/a"; ( install_answers_load "$W/a" ) 2>"$W/err" || true
if grep -q geheimwert "$W/err"; then fail A.meldung-ohne-wert "Wert steht in der Meldung"; else pass A.meldung-ohne-wert; fi
if [ -e "$P" ]; then fail A.nichts-ausgefuehrt "Datei $P entstand"; else pass A.nichts-ausgefuehrt; fi

# ---------------------------------------------------------------------------- W: Wrapper
last() { tail -n1 "$STUB_LOG"; }
: > "$STUB_LOG"
LIFEAGENTS_RUNTIME=systemd
pg_su_psql -X -tA -c 'SELECT 1' >/dev/null;   eq W.systemd-psql 'runuser|-u|postgres|--|psql|-X|-tA|-c|SELECT 1|stdin=' "$(last)"
svc_up postgresql;                            eq W.systemd-svc_up 'systemctl|enable|--now|postgresql|stdin=' "$(last)"
svc_is_active n8n;                            eq W.systemd-is-active 'systemctl|is-active|--quiet|n8n|stdin=' "$(last)"
svc_stop lifeagents-update-run.timer n8n;     eq W.systemd-stop-mehrere 'systemctl|stop|lifeagents-update-run.timer|n8n|stdin=' "$(last)"
N8N_USER=n8n n8n_cli_env /etc/n8n/n8n.env import:workflow --separate --input=/tmp/x
case "$(last)" in 'runuser|-u|n8n|--|bash|-c|'*'|_|/etc/n8n/n8n.env|'*'|import:workflow|--separate|--input=/tmp/x|stdin=') pass W.systemd-n8n-cli ;; *) fail W.systemd-n8n-cli "$(last)" ;; esac

export LIFEAGENTS_RUNTIME=compose STUB_STDIN=1
pg_su_psql -X -tA -c 'SELECT 1' >/dev/null </dev/null; eq W.compose-psql-c-ohne-i 'docker|exec|-u|postgres|lifeagents-postgres|psql|-X|-tA|-c|SELECT 1|stdin=' "$(last)"
printf 'SELECT 2;\n' | pg_su_psql -X -q -d n8n;      eq W.compose-psql-stdin-mit-i 'docker|exec|-i|-u|postgres|lifeagents-postgres|psql|-X|-q|-d|n8n|stdin=ja' "$(last)"
printf 'SELECT 3;\n' > "$W/drv.sql"
pg_su_psql -v ON_ERROR_STOP=1 -X -d n8n -f "$W/drv.sql" </dev/null
eq W.compose-psql-datei-als-stdin 'docker|exec|-i|-u|postgres|lifeagents-postgres|psql|-v|ON_ERROR_STOP=1|-X|-d|n8n|-f|-|stdin=ja' "$(last)"
# Paket-Schleife (Probelauf-Fund 2): ein psql -c in `while read` darf den Rest der Liste nicht verschlucken.
n=0; while IFS= read -r _x; do pg_su_psql -tA -c 'SELECT 1' >/dev/null; n=$((n + 1)); done <<<"$(printf 'a\nb\nc\n')"
eq W.compose-schleife-behaelt-stdin 3 "$n"
svc_up n8n;                                   eq W.compose-svc_up "docker|compose|-p|lifeagents|-f|$LA_COMPOSE_FILE|up|-d|--no-deps|n8n|stdin=" "$(last)"
: > "$STUB_LOG"; svc_stop lifeagents-update-run.timer n8n
eq W.compose-stop-nur-dienste "docker|compose|-p|lifeagents|-f|$LA_COMPOSE_FILE|stop|n8n|stdin=" "$(last)"
: > "$STUB_LOG"; svc_stop lifeagents-update-run.timer; eq W.compose-stop-timer-noop '' "$(cat "$STUB_LOG")"
svc_daemon_reload; svc_enable n8n;            eq W.compose-systemd-verwaltung-noop '' "$(cat "$STUB_LOG")"
unset STUB_STDIN

# ---------------------------------------------------------------------------- V: Volumes
: > "$STUB_LOG"
( rt_volumes_ensure ) 2>/dev/null; c="$(grep -c '^docker|volume|create|--label|io.lifeagents.install=lifeagents|lifeagents_' "$STUB_LOG")"
read -ra _vols <<<"$LA_STATE_VOLUMES"; eq V.anlegen-mit-label "${#_vols[@]}" "$c"
: > "$STUB_LOG"
if ( STUB_VOL_LABEL='' rt_volumes_ensure ) 2>/dev/null; then fail V.fremdes-volume "kein Abbruch"; else pass V.fremdes-volume; fi
if grep -q 'volume|create' "$STUB_LOG"; then fail V.fremdes-unberuehrt "es wurde angelegt"; else pass V.fremdes-unberuehrt; fi
: > "$STUB_LOG"; ( STUB_VOL_LABEL=lifeagents rt_volumes_ensure ) 2>/dev/null
if grep -q 'volume|create' "$STUB_LOG"; then fail V.eigenes-bleibt "doppelt angelegt"; else pass V.eigenes-bleibt; fi
unset LIFEAGENTS_RUNTIME

# ---------------------------------------------------------------------------- T: Telegram
# tg_api_curl-Attrappe: Antwort je Methode aus TG_WH (getWebhookInfo-JSON|Code) und TG_UP (getUpdates-Code).
tg_api_curl() {
  printf '%s\n' "$2" >> "$W/tg_calls"
  case "$2" in
    getWebhookInfo) [ "${TG_WH_CODE:-200}" = 000 ] && return 7; printf '%s\n%s' "${TG_WH:-}" "${TG_WH_CODE:-200}" ;;
    getUpdates*)    printf '%s' "${TG_UP:-200}" ;;
  esac
}
need_cmd() { command -v "$1" >/dev/null 2>&1; }
probe() { _tg_webhook_probe tok "$1"; printf '%s' "$TG_WEBHOOK_STATE"; }
TG_WH='{"ok":true,"result":{"url":"","pending_update_count":0}}'; TG_UP=200; eq T.frei free "$(probe '')"
TG_UP=409;                                                                eq T.long-polling-409 foreign "$(probe '')"
TG_WH='{"ok":true,"result":{"url":"https://bot.example.com/webhook/abc/webhook","pending_update_count":2}}'
eq T.unser-webhook ours "$(probe 'https://bot.example.com/')"
# JSON darf / als \/ schreiben; die Pruefung laeuft ohne jq.
TG_WH='{"ok":true,"result":{"url":"https:\/\/bot.example.com\/webhook\/abc\/webhook","has_custom_certificate":false,"pending_update_count":0}}'
eq T.unser-webhook-escaped ours "$(probe 'https://bot.example.com/')"
_tg_webhook_probe tok ''; eq T.nur-rechnername bot.example.com "$TG_WEBHOOK_HOST"
eq T.fremder-webhook foreign "$(probe 'https://other.example.org/')"
eq T.erstinstallation-fremd foreign "$(probe '')"
TG_WH_CODE=401;                                                           eq T.token-abgelehnt unknown "$(probe '')"
TG_WH_CODE=000;                                                           eq T.netz-weg unknown "$(probe '')"
unset TG_WH_CODE
if grep -qiE 'offset|drop_pending' "$W/tg_calls"; then fail T.nie-offset "$(grep -iE 'offset|drop' "$W/tg_calls" | head -1)"; else pass T.nie-offset; fi
# Entscheidung: unattended (kein TTY), Erstinstallation, fremder Webhook.
export TELEGRAM_BOT_TOKEN=tok N8N_ENV_FILE="$W/n8n.env" LIFEAGENTS_DIR="$W/etc" UNATTENDED=1
lifeagents_version_marker() { printf '%s' "$W/VERSION"; }
if ( telegram_webhook_preflight ) >/dev/null 2>&1; then fail T.unattended-erst-bricht-ab "kein Abbruch"; else pass T.unattended-erst-bricht-ab; fi
if ( TELEGRAM_WEBHOOK_TAKEOVER=1 telegram_webhook_preflight ) >/dev/null 2>&1; then pass T.uebernahme-ausdruecklich; else fail T.uebernahme-ausdruecklich "Abbruch trotz Schalter"; fi
if [ -s "$W/etc/telegram-webhook-before" ] && [ "$(stat -c %a "$W/etc/telegram-webhook-before")" = 600 ]; then pass T.alte-adresse-gemerkt; else fail T.alte-adresse-gemerkt "Datei fehlt oder nicht 0600"; fi
: > "$W/VERSION"
if ( telegram_webhook_preflight ) >/dev/null 2>&1; then pass T.bestand-ohne-terminal-weiter; else fail T.bestand-ohne-terminal-weiter "Bestand brach ab"; fi
printf 'WEBHOOK_URL=https://bot.example.com/\n' > "$W/n8n.env"; rm -f "$W/VERSION"
if ( telegram_webhook_preflight ) >/dev/null 2>&1; then pass T.eigener-webhook-ohne-frage; else fail T.eigener-webhook-ohne-frage "brach ab"; fi

# Maschinenlesbar fuer den Wizard (eine JSON-Zeile, Token nur aus der Umgebung).
TG_WH='{"ok":true,"result":{"url":"https://other.example.org/hook","pending_update_count":3}}'
eq T.json-fremd '{"ok":true,"state":"foreign","webhook_host":"other.example.org","pending":3,"polling_conflict":false}' "$(telegram_webhook_json)"
TG_WH='{"ok":true,"result":{"url":"","pending_update_count":0}}'; TG_UP=409
eq T.json-polling '{"ok":true,"state":"foreign","webhook_host":"","pending":0,"polling_conflict":true}' "$(telegram_webhook_json)"
TG_WH_CODE=401; eq T.json-token-abgelehnt '{"ok":false,"reason":"unauthorized"}' "$(telegram_webhook_json)"; unset TG_WH_CODE
eq T.json-ohne-token '{"ok":false,"reason":"no_token"}' "$(TELEGRAM_BOT_TOKEN='' telegram_webhook_json)"

# ---------------------------------------------------------------------------- Z: Wizard-Form der Antwort-Datei
H='# lifeagents-answers v1'
printf '%s\n' "$H" "OWNER_LAST_NAME=O'Muster \$(touch $P) \`x\`" 'GOOGLE_API_KEY=' 'A=b=c' > "$W/a"
ok_ans Z.roh-wortgetreu "[ \"\$OWNER_LAST_NAME\" = \"O'Muster \\\$(touch $P) \\\`x\\\`\" ] && [ -z \"\$GOOGLE_API_KEY\" ] && [ \"\$A\" = b=c ] && [ ! -e '$P' ]"
printf '%s\n' "$H" 'A=1' 'A=2' > "$W/a";                no_ans Z.doppelt
printf '%s\n' "$H" '' 'A=1' > "$W/a";                   no_ans Z.leerzeile
printf '%s\n' "$H" '# k' > "$W/a";                      no_ans Z.kommentar
printf '%s\n' "$H" 'PATH=/x' > "$W/a";                  no_ans Z.gesperrt-bricht-ab
printf '%s\r\n' "$H" 'A=1' > "$W/a";                    no_ans Z.crlf-kopf-ist-env-form-fehler
printf '%s\n' "$H" > "$W/a"; printf 'A=1\r\n' >> "$W/a"; no_ans Z.cr-im-wert
printf '%s\n' "$H" "A=$(head -c 4097 /dev/zero | tr '\0' x)" > "$W/a"; no_ans Z.zu-lang
printf '%s\n' "$H" 'a=1' > "$W/a";                      no_ans Z.kleinbuchstaben
printf '%s\n' "$H" 'B=2' > "$W/a"; printf 'C=3' >> "$W/a"; ok_ans Z.ohne-umbruch-am-ende '[ "$B" = 2 ] && [ "$C" = 3 ]'

# ---------------------------------------------------------------------------- P: Paket-Antworten ohne Terminal
# Erfundenes Paket "demo": eine Auswahl-Einstellung, eine Freitext-Einstellung mit URL-Validator, ein Zugang mit 2 Keys.
if command -v jq >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$ROOT/provisioning/lib/pkg_lifecycle.sh"
  mkdir -p "$W/pk/demo" "$W/la"
  cat > "$W/pk/demo/manifest.json" <<'JSON'
{ "config": { "general": {
    "region": { "prompt": "Region", "choices": [ {"value": "nord", "label": "Nord"}, {"value": "sued", "label": "Süd"} ] },
    "base_url": { "prompt": "Adresse", "validator": "url" },
    "plain": { "value": "x" } } },
  "credentials": { "demo_api": { "type": "httpHeaderAuth", "env": { "DEMO_ID": {"field": "a"}, "DEMO_KEY": {"field": "b", "secret": true} } } } }
JSON
  _pkg_dir() { printf '%s' "$W/pk"; }
  export LIFEAGENTS_DIR="$W/la"
  _pkg_setting_current() { [ "$1.$2" = "${DEMO_ALREADY_SET:-}" ] && printf 'gesetzt'; return 0; }
  pset() { PKG_SETTINGS_ANSWERS=''; rm -f "$W/la/demo.env"; ( _pkg_settings_from_env demo; printf '%s' "$PKG_SETTINGS_ANSWERS" ) 2>/dev/null; }
  r="$(CONFIG_GENERAL_REGION=sued pset)";                          eq P.auswahl-gepuffert $'demo\tgeneral\tregion\tsued' "$r"
  r="$(CONFIG_GENERAL_REGION=west pset)";                     eq P.auswahl-unbekannt-uebersprungen '' "$r"
  r="$(CONFIG_GENERAL_BASE_URL='http://192.0.2.10:8000' pset)"; eq P.freitext-validiert $'demo\tgeneral\tbase_url\thttp://192.0.2.10:8000' "$r"
  r="$(CONFIG_GENERAL_BASE_URL='kein url' pset)";              eq P.freitext-ungueltig-uebersprungen '' "$r"
  r="$(CONFIG_GENERAL_REGION=nord DEMO_ALREADY_SET=general.region pset)"; eq P.schon-gesetzt-nie-ueberschreiben '' "$r"
  r="$(CONFIG_GENERAL_PLAIN=y pset)";                          eq P.ohne-prompt-ignoriert '' "$r"
  PKG_SETTINGS_ANSWERS=''; rm -f "$W/la/demo.env"; ( CONFIG_GENERAL_REGION='' _pkg_settings_from_env demo ) 2>/dev/null
  if grep -qx 'CONFIG_GENERAL_REGION=' "$W/la/demo.env" 2>/dev/null; then pass P.leer-ist-uebersprungen; else fail P.leer-ist-uebersprungen "keine Seen-Zeile"; fi
  # Zugaenge aus der Umgebung landen ohne Terminal in demo.env; ein leerer Env-Wert loescht nie einen gespeicherten.
  rm -f "$W/la/demo.env"; printf 'DEMO_KEY=alt\n' > "$W/la/demo.env"
  ( DEMO_ID=id-1 DEMO_KEY='' _pkg_secrets_wizard demo "$W/la/demo.env" 0 ) >/dev/null 2>&1
  eq P.zugang-gespeichert id-1 "$(read_env_value "$W/la/demo.env" DEMO_ID)"
  eq P.leer-loescht-nie alt "$(read_env_value "$W/la/demo.env" DEMO_KEY)"
else
  fail P.jq "jq fehlt im Container (Pflicht fuer die Paket-Faelle)"
fi

# ---------------------------------------------------------------------------- S: master-Wechsel (Update im Verbund, Fund 6)
# Rolle 1 (master_swap_begin), Rolle 2 (swap_helper_main) und die Entscheidung von Rolle 3 (master_swap_resolve) gegen die
# docker-Attrappe: vor dem Helfer aendert sich nichts am Verbund; der Helfer kommt aus dem ALTEN Image; Rueckweg bei Fehler.
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/master_swap.sh"
export LIFEAGENTS_RUNTIME=compose LA_PROJECT=lifeagents LA_EDGE_PORT=5880 LA_WIZARD_PORT=5881 LA_PG_SUPERPW=pw-erfunden \
  LA_MASTER_IMAGE=reg.example/master@sha256:aaaa LA_PROBE_IMAGE=busybox:test LIFEAGENTS_UPDATE_LOCK="$W/upd.lock"
unset LIFEAGENTS_UPDATE_LOCK_HELD
SWAP_DIR="$W/swap"; SWAP_STATE="$SWAP_DIR/state"
printf 'services: {}\n' > "$W/compose.old.src"; printf 'services: {new: 1}\n' > "$W/compose.new.src"
LA_COMPOSE_FILE="$W/compose.old.src"
NEW=reg.example/master@sha256:bbbb
sget() { read_env_value "$SWAP_STATE" "$1" 2>/dev/null || true; }
: > "$STUB_LOG"; : > "${STUB_LOG}.env"
if ( LIFEAGENTS_UPDATE_REQUEST_ID=7 master_swap_begin v9.1.0 "$W/compose.new.src" "$NEW" ) >/dev/null 2>&1; then pass S.begin-ok; else fail S.begin-ok "Abbruch"; fi
eq S.zustand-handoff "handoff|v9.1.0|$LA_MASTER_IMAGE|$NEW|7" "$(sget PHASE)|$(sget TAG)|$(sget FROM)|$(sget TO)|$(sget REQUEST_ID)"
eq S.env-datei-0600 600 "$(stat -c %a "$SWAP_DIR/stack.env" 2>/dev/null)"
eq S.env-datei-ziel-image "LA_MASTER_IMAGE=$NEW" "$(grep '^LA_MASTER_IMAGE=' "$SWAP_DIR/stack.env")"
if grep -qx 'LA_PG_SUPERPW=pw-erfunden' "$SWAP_DIR/stack.env"; then pass S.env-datei-vollstaendig; else fail S.env-datei-vollstaendig "Passwort fehlt"; fi
if cmp -s "$SWAP_DIR/compose.new.yml" "$W/compose.new.src" && cmp -s "$SWAP_DIR/compose.old.yml" "$W/compose.old.src"; then pass S.beide-dateien-abgelegt; else fail S.beide-dateien-abgelegt "compose.old/new fehlen"; fi
r="$(grep '^docker|run|' "$STUB_LOG" | head -1)"
case "$r" in
  "docker|run|--rm|-d|--name|lifeagents-swap|"*"|--network|none|"*"|$LA_MASTER_IMAGE|/opt/lifeagents/provisioning/compose/swap_helper.sh|$SWAP_DIR|stdin=") pass S.helfer-aus-altem-image ;;
  *) fail S.helfer-aus-altem-image "$r" ;;
esac
if grep -q '|up|' "$STUB_LOG"; then fail S.vor-helfer-nichts-geaendert "compose up schon im alten master"; else pass S.vor-helfer-nichts-geaendert; fi
if ( master_swap_begin v9.1.0 "$W/compose.new.src" "$NEW" ) >/dev/null 2>&1; then fail S.zweiter-wechsel-gesperrt "kein Abbruch"; else pass S.zweiter-wechsel-gesperrt; fi
# Helfer laeuft -> warten; Helfer fertig + eigenes Image = Ziel -> fortsetzen; = Ausgang -> zurueckgerollt.
eq S.resolve-helfer-laeuft wait "$(STUB_RUNNING=lifeagents-swap master_swap_resolve)"
eq S.resolve-handoff-frisch-wartet wait "$(master_swap_resolve)"
_swap_set PHASE swapped
eq S.resolve-ziel apply "$(LA_MASTER_IMAGE=$NEW master_swap_resolve)"
eq S.resolve-ausgang rolled_back "$(master_swap_resolve)"
_swap_set PHASE applying;    eq S.resolve-abgebrochen-nie-wiederholen interrupted "$(LA_MASTER_IMAGE=$NEW master_swap_resolve)"
_swap_set PHASE rolled_back; eq S.resolve-zurueck rolled_back "$(LA_MASTER_IMAGE=$NEW master_swap_resolve)"
# Rolle 2: gelingt der Selbsttest, bleibt das neue Image; scheitert er, legt der Helfer den alten master mit alter Datei an.
_swap_set PHASE handoff; cp "$W/compose.new.src" "$SWAP_DIR/compose.new.yml"; cp "$W/compose.old.src" "$SWAP_DIR/compose.old.yml"
: > "${STUB_LOG}.env"
( SWAP_GRACE_SECS=0 SWAP_CHECK_SECS=1 STUB_RUNNING=lifeagents-master swap_helper_main "$SWAP_DIR" ) >/dev/null 2>&1
eq S.helfer-erfolg swapped "$(sget PHASE)"
eq S.helfer-neue-datei-neues-image "$SWAP_DIR/compose.new.yml|$NEW" "$(head -n1 "${STUB_LOG}.env")"
if [ -e "$SWAP_DIR/stack.env" ]; then fail S.helfer-raeumt-env "stack.env blieb liegen"; else pass S.helfer-raeumt-env; fi
# Selbsttest scheitert (master laeuft nicht) -> Rueckweg mit alter Datei + altem Image; scheitert auch der, bleibt das sichtbar.
_swap_set PHASE handoff; : > "${STUB_LOG}.env"; printf 'LA_PROJECT=lifeagents\n' > "$SWAP_DIR/stack.env"
( SWAP_GRACE_SECS=0 SWAP_CHECK_SECS=1 STUB_RUNNING='' swap_helper_main "$SWAP_DIR" ) >/dev/null 2>&1
eq S.helfer-rueckweg-ausgefuehrt "$SWAP_DIR/compose.old.yml|$LA_MASTER_IMAGE" "$(sed -n 2p "${STUB_LOG}.env")"
eq S.helfer-rueckweg-zustand rollback_failed "$(sget PHASE)"
master_swap_close
if [ -e "$SWAP_STATE" ] || [ ! -e "$SWAP_DIR/compose.prev.yml" ]; then fail S.abschluss "state blieb oder compose.prev fehlt"; else pass S.abschluss; fi
# Image nicht ladbar / Helfer startet nicht -> Abbruch, KEIN Zustand bleibt liegen.
rm -rf "$SWAP_DIR"
if ( STUB_IMAGE_PRESENT=0 STUB_FAIL='|pull|' master_swap_begin v9.1.0 "$W/compose.new.src" "$NEW" ) >/dev/null 2>&1; then fail S.pull-fehler-bricht-ab "kein Abbruch"; else pass S.pull-fehler-bricht-ab; fi
if [ -e "$SWAP_STATE" ]; then fail S.pull-fehler-kein-zustand "state angelegt"; else pass S.pull-fehler-kein-zustand; fi
if ( STUB_FAIL='|run|--rm|-d|' master_swap_begin v9.1.0 "$W/compose.new.src" "$NEW" ) >/dev/null 2>&1; then fail S.helfer-startfehler "kein Abbruch"; else pass S.helfer-startfehler; fi
if [ -e "$SWAP_STATE" ] || [ -e "$SWAP_DIR/stack.env" ]; then fail S.helfer-startfehler-raeumt "Reste"; else pass S.helfer-startfehler-raeumt; fi
# Rueckweg: Zusatz-Angaben stehen schon VOR dem Helfer-Start in der Datei (kein zweiter Schreiber neben dem Helfer).
( SWAP_DROP_DB_AFTER=n8n_before_rollback SWAP_NOTIFY='Fertig, mit Komma' master_swap_begin v9.0.0 "$W/compose.old.src" "$NEW" rollback ) >/dev/null 2>&1
eq S.rueckweg-angaben-vor-helfer 'n8n_before_rollback|Fertig, mit Komma|rollback' "$(sget DROP_DB_AFTER)|$(sget NOTIFY)|$(sget MODE)"
rm -rf "$SWAP_DIR"
# Ziel-Image steht in der Release-compose.yml, NIE aus der Umgebung des laufenden master (sonst waere jedes Ziel = Ist).
: > "${STUB_LOG}.env"
eq S.ziel-aus-datei "$NEW" "$(STUB_CONFIG_JSON="{\"services\":{\"master\":{\"image\":\"$NEW\"}}}" rt_master_image_of "$W/compose.new.src")"
eq S.ziel-ohne-umgebung "$W/compose.new.src|-" "$(head -n1 "${STUB_LOG}.env")"
eq S.ziel-fehlt-leer '' "$(STUB_CONFIG_JSON='' rt_master_image_of "$W/compose.new.src")"

# ---------------------------------------------------------------------------- U: Upgrade-Erkennung im Verbund
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/upgrade_guard.sh"
export LA_N8N_IMAGE=n8nio/n8n:neu LA_PG_IMAGE=postgres:17@neu PG_VERSION=17
eq U.gleich-kein-tausch '' "$(STUB_IMG_lifeagents_n8n=n8nio/n8n:neu STUB_IMG_lifeagents_postgres=postgres:17@neu _upg_changes_compose)"
eq U.n8n-image-wechsel 'n8n-Image n8nio/n8n:alt -> n8nio/n8n:neu' "$(STUB_IMG_lifeagents_n8n=n8nio/n8n:alt STUB_IMG_lifeagents_postgres=postgres:17@neu _upg_changes_compose)"
eq U.pg-image-wechsel 'PostgreSQL-Image postgres:17@alt -> postgres:17@neu' "$(STUB_IMG_lifeagents_n8n=n8nio/n8n:neu STUB_IMG_lifeagents_postgres=postgres:17@alt _upg_changes_compose)"
eq U.erstinstallation-kein-tausch '' "$(_upg_changes_compose)"
if ( STUB_RUNNING=lifeagents-postgres STUB_PG_MAJOR=16 upgrade_detect ) >/dev/null 2>&1; then fail U.pg-hauptversion-bricht-ab "kein Abbruch"; else pass U.pg-hauptversion-bricht-ab; fi
eq U.sicherung-auf-volume /var/lib/lifeagents/backups "$UPGRADE_BACKUP_DIR"

# ---------------------------------------------------------------------------- R: Sicherungs-Ordner auf dem Rechner (Fund 7)
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/backup_cli.sh"
for d in /Users/erika/Sicherung '/Users/erika/Meine Sicherung'; do
  if _bkp_host_dir_valid "$d"; then pass "R.ordner-gueltig:$d"; else fail "R.ordner-gueltig:$d" "abgelehnt"; fi
done
for d in relativ/pfad '/a,b' "$(printf '/a\nb')" ''; do
  n="$(printf '%s' "${d:-leer}" | tr '\n' '~')"
  if _bkp_host_dir_valid "$d"; then fail "R.ordner-ungueltig:$n" "angenommen"; else pass "R.ordner-ungueltig:$n"; fi
done
: > "$STUB_LOG"; printf 'chiffrat' | rt_host_put /Users/erika/Sicherung lifeagents-backup-1.nla.enc
case "$(last)" in
  "docker|run|--rm|-i|--label|io.lifeagents.install=lifeagents|--network|none|--mount|type=bind,src=/Users/erika/Sicherung,dst=/out|busybox:test|sh|-c|"*"|_|lifeagents-backup-1.nla.enc|stdin=") pass R.schreiben-nur-dieser-ordner ;;
  *) fail R.schreiben-nur-dieser-ordner "$(last)" ;;
esac
: > "$STUB_LOG"; rt_host_get /Users/erika/Sicherung x.nla.enc >/dev/null
case "$(last)" in *"type=bind,src=/Users/erika/Sicherung,dst=/in,readonly|"*) pass R.lesen-nur-lesend ;; *) fail R.lesen-nur-lesend "$(last)" ;; esac
if grep -qE '\|-v\||prune' "$STUB_LOG"; then fail R.kein-breiter-schalter "$(cat "$STUB_LOG")"; else pass R.kein-breiter-schalter; fi

# ---------------------------------------------------------------------------- D: Entfernen (Pruefliste Nr. 17, stack.sh)
unset LIFEAGENTS_RUNTIME
dst() { : > "$STUB_LOG"; ( cd "$W" && LA_PROJECT=lifeagents bash "$ROOT/provisioning/compose/stack.sh" uninstall "$@" ) >/dev/null 2>&1; }
STUB_VOL_LABEL=lifeagents STUB_PROFILES=$'fritzbox\ntunnel\n' dst
if grep -q '^docker|compose|-p|lifeagents|-f|.*|down|--remove-orphans|stdin=$' "$STUB_LOG"; then pass D.down-ohne-v; else fail D.down-ohne-v "$(grep compose "$STUB_LOG")"; fi
# Container aus Profilen (tailscale, wan) sind keine Waisen: Compose entfernt sie nur, wenn ihr Profil beim down aktiv ist.
eq D.down-alle-profile 'fritzbox,tunnel' "$(tail -n1 "${STUB_LOG}.profiles" 2>/dev/null)"
# Erwartung aus compose.yml selbst: jedes von Compose verwaltete (nicht externe) Volume ist abgeleitet und geht immer.
_derived="$(awk '/^volumes:/{v=1;next} v&&/^[^ #]/{v=0} v&&/^  [a-z_0-9]+:/{if(n)print n; sub(/:.*/,"");n=$1;next} v&&/external: *true/{n=""} END{if(n)print n}' "$ROOT/provisioning/compose/compose.yml" | sed 's/^/lifeagents_/' | sort | tr '\n' ' ' | sed 's/ $//')"
eq D.ohne-daten-nur-abgeleitete "$_derived" "$(grep '^docker|volume|rm|' "$STUB_LOG" | cut -d'|' -f4 | sort | tr '\n' ' ' | sed 's/ $//')"
STUB_VOL_LABEL=lifeagents dst --delete-data
read -ra _vols <<<"$LA_STATE_VOLUMES"; read -ra _dv <<<"$_derived"
eq D.mit-daten-alle-eigenen "$(( ${#_vols[@]} + ${#_dv[@]} ))" "$(grep -c '^docker|volume|rm|' "$STUB_LOG")"
# Ein Volume, das sich nicht entfernen laesst (z. B. noch belegt), ist kein Label-Fall: die Meldung nennt den wahren Grund.
: > "$STUB_LOG"
if _out="$( ( cd "$W" && STUB_VOL_LABEL=lifeagents STUB_FAIL='|volume|rm|lifeagents_pgdata' LA_PROJECT=lifeagents bash "$ROOT/provisioning/compose/stack.sh" uninstall --delete-data ) 2>&1 )"; then fail D.rm-fehler-abbruch "Exit 0"; else pass D.rm-fehler-abbruch; fi
case "$_out" in *Label*) fail D.rm-fehler-wahrer-grund "meldet Label: $_out" ;; *"Daemon-Fehler"*) pass D.rm-fehler-wahrer-grund ;; *) fail D.rm-fehler-wahrer-grund "Grund fehlt: $_out" ;; esac
if STUB_VOL_LABEL=fremd dst --delete-data; then fail D.fremdes-label-abbruch "Exit 0"; else pass D.fremdes-label-abbruch; fi
eq D.fremdes-label-unberuehrt 0 "$(grep -c '^docker|volume|rm|' "$STUB_LOG")"
if grep -qE 'prune|\|-v\||--volumes|--rmi|\|-a\||--all' "$STUB_LOG"; then fail D.nie-breit "$(grep -E 'prune|-v|--rmi' "$STUB_LOG" | head -1)"; else pass D.nie-breit; fi
if STUB_RUNNING=lifeagents-swap dst; then fail D.nicht-waehrend-wechsel "Exit 0"; else pass D.nicht-waehrend-wechsel; fi
if grep -q '|down|' "$STUB_LOG"; then fail D.waehrend-wechsel-unberuehrt "down lief"; else pass D.waehrend-wechsel-unberuehrt; fi

# ---------------------------------------------------------------------------- K: Tick (Ersatz der Update-Timer im Verbund)
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/update_runner.sh"

# Eine Meldung beendet den Runner nie, auch nicht unter set -e und ohne DB.
out="$( set -e; _ur_sql() { return 1; }; _up_close() { :; }; _ur_report 7 result bot_up=true; echo weiter )"
eq K.report-ohne-db-kein-abbruch weiter "$(printf '%s' "$out" | tail -n1)"
out="$( set -e; _ur_sql() { return 1; }; owner_tg_token() { echo t; }; owner_tg_chat_id() { echo 1; }; UP_STATE="$W/up.none"; _up_start 7 "$W/rf"; echo weiter )"
eq K.helfer-ohne-db-kein-abbruch weiter "$(printf '%s' "$out" | tail -n1)"

# Release-Check unter der Update-Sperre: belegt = auslassen (sonst liest er mitten im Update die alte VERSION und schickt eine
# ueberfluessige Karte), frei oder vom eigenen Lauf gehalten = prueft wie bisher. Die Sperre haelt ein echter flock-Prozess.
# Sperr-Halter: ein Prozess, der den fd behaelt (kein `flock <cmd>`, das forkt und liess das Kind die Sperre weiter halten).
_hold() { ( exec 8>>"$1"; flock -n 8 || exit 1; exec sleep 20 ) & }
_unhold() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
_chk_case() ( require_root() { :; }; lifeagents_db_name() { :; }; _ur_installed() { echo v9.0.0; }
              _ur_check_in() { echo "check $2 $3" >> "$W/chk.log"; }; log() { echo "log $*" >> "$W/chk.log"; }
              LIFEAGENTS_UPDATE_LOCK="$W/chk.lock"; update_check "$@" )
: > "$W/chk.lock"; : > "$W/chk.log"
( unset LIFEAGENTS_UPDATE_LOCK_HELD; _chk_case scheduled ) >/dev/null 2>&1
eq K.check-sperre-frei-prueft "check v9.0.0 true" "$(cat "$W/chk.log")"
: > "$W/chk.log"; _hold "$W/chk.lock"; chk_holder=$!; sleep 1
( unset LIFEAGENTS_UPDATE_LOCK_HELD; _chk_case scheduled ) >/dev/null 2>&1
case "$(cat "$W/chk.log")" in "log "*Update-Sperre*) pass K.check-sperre-belegt-ausgelassen ;; *) fail K.check-sperre-belegt-ausgelassen "$(cat "$W/chk.log")" ;; esac
: > "$W/chk.log"
( LIFEAGENTS_UPDATE_LOCK_HELD=1 _chk_case scheduled ) >/dev/null 2>&1
case "$(cat "$W/chk.log")" in "check "*) pass K.check-eigene-sperre-prueft ;; *) fail K.check-eigene-sperre-prueft "$(cat "$W/chk.log")" ;; esac
_unhold "$chk_holder"

# `lifeagents update` liest VERSION (Rueckschritt-Schutz) erst unter der Sperre: ein zweites Update waehrend eines laufenden
# sah sonst die alte VERSION. Belegt = Abbruch "locked" vor jedem Schritt; frei = laeuft los.
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/fetch_release.sh"
_fetch_case() ( require_root() { :; }; result_set() { :; }; die_because() { echo "die $1" >> "$W/fr.log"; exit 1; }
                _ensure_release_deps() { echo deps >> "$W/fr.log"; exit 0; }
                LIFEAGENTS_UPDATE_LOCK="$W/fr.lock"; export LIFEAGENTS_UPDATE_LOCK_WAIT_S=1; fetch_and_run_release v9.1.0 )
: > "$W/fr.lock"; : > "$W/fr.log"
_hold "$W/fr.lock"; fr_holder=$!; sleep 1
( unset LIFEAGENTS_UPDATE_LOCK_HELD; _fetch_case ) >/dev/null 2>&1
eq K.update-sperre-belegt-bricht-ab "die locked" "$(cat "$W/fr.log")"
_unhold "$fr_holder"
: > "$W/fr.log"
( unset LIFEAGENTS_UPDATE_LOCK_HELD; _fetch_case ) >/dev/null 2>&1
eq K.update-sperre-frei-laeuft deps "$(cat "$W/fr.log")"

# Umstieg: Ohne die Faellig-fn geht das Ergebnis direkt hinaus, im Leerlauf bleibt es still.
out="$( _ur_lock_release() { :; }; _ur_sql() { return 1; }; _ur_bot_up() { return 0; }; _ur_report() { echo "report $*"; }; _ur_reports_flush 7 )"
eq K.flush-ohne-fn-direkt 'report 7 result bot_up=true' "$out"
out="$( _ur_lock_release() { :; }; _ur_sql() { return 1; }; _ur_report() { echo "report $*"; }; _ur_reports_flush )"
eq K.flush-ohne-fn-leerlauf '' "$out"
# Port: Prozess-Env, sonst n8n.env, sonst Standard.
printf 'N8N_PORT=5999\n' > "$W/n8n.env"
eq K.port-aus-env-datei 5999 "$(unset N8N_PORT; N8N_ENV_FILE="$W/n8n.env" _ur_n8n_port)"
eq K.port-prozess-vor-datei 1234 "$(N8N_PORT=1234 N8N_ENV_FILE="$W/n8n.env" _ur_n8n_port)"
eq K.port-standard 5678 "$(unset N8N_PORT; N8N_ENV_FILE="$W/fehlt.env" _ur_n8n_port)"

# Bereit heisst: n8n bereit UND Orchestrator aktiv; ein API-Fehler zaehlt als nicht bereit.
printf 'N8N_API_KEY=k\n' > "$W/ready.env"
_ready_case() ( lifeagents_env_file() { printf '%s' "$W/ready.env"; }; curl() { return 0; }
                n8n_orchestrator_state() { printf '%b' "$STATE"; }; if _ur_bot_ready; then echo ja; else echo nein; fi )
eq K.bereit-aktiv ja "$(STATE='id\ttrue' _ready_case)"
eq K.bereit-inaktiv nein "$(STATE='id\tfalse' _ready_case)"
eq K.bereit-api-fehler nein "$(STATE='' _ready_case)"
: > "$W/ready.env"
eq K.bereit-ohne-schluessel ja "$(STATE='' _ready_case)"

# Nach dem master-Wechsel macht der neue Helfer bei derselben Nachricht weiter, ohne Rueckschritt.
# shellcheck disable=SC2034  # UP_* lesen die Funktionen aus update_progress.sh
up_case() (
  UP_STATE="$W/up.state"; UP_MIN_GAP_S=0; _UP_NEXT=0; _UP_BACKOFF=15; _UP_GONE=0
  _up_api() { shift; echo "$*" >> "$W/up.calls"; printf '{"ok":true,"result":{"message_id":55}}'; }
  printf 'stage=%s\n' "$1" > "$W/up.rf"
  _up_tick "$W/up.rf" tok 1
)
_up_plan='{"id":7,"message_id":55,"pct":45,"stage":"n8n","text":"t45","plan":{"start":{"pct":0,"text":"t0"},"stages":{"n8n":{"pct":45,"text":"t45"},"schema":{"pct":66,"text":"t66"},"backup":{"pct":25,"text":"t25"}}}}'
printf '%s' "$_up_plan" > "$W/up.state"; : > "$W/up.calls"
up_case schema
case "$(cat "$W/up.calls")" in *message_id=55*text=t66*) pass K.helfer-gleiche-nachricht ;; *) fail K.helfer-gleiche-nachricht "$(cat "$W/up.calls")" ;; esac
: > "$W/up.calls"; up_case backup
eq K.helfer-nie-rueckwaerts '' "$(cat "$W/up.calls")"
: > "$W/up.calls"; up_case unbekannter_schritt
eq K.helfer-unbekannter-schritt '' "$(cat "$W/up.calls")"

export LIFEAGENTS_RUNTIME=compose
update_run_requested() { echo run >> "$W/tick.log"; }
update_check() { echo check >> "$W/tick.log"; echo "$*" >> "$W/check.args"; }
printf '#!/usr/bin/env bash\necho "cli $*" >> "$TICK_LOG"\n' > "$W/bin/lifeagents"
chmod +x "$W/bin/lifeagents"; export TICK_LOG="$W/tick.log"
lifeagents_version_marker() { printf '%s' "$W/VERSION_TICK"; }
lifeagents_env_file() { printf '%s' "$W/core.env"; }
printf 'HOUSEHOLD_TIMEZONE=UTC\n' > "$W/core.env"
UPDATE_TICK_STATE="$W/tick.state"; rm -f "$W/VERSION_TICK" "$W/tick.log" "$UPDATE_TICK_STATE"
( update_tick ); eq K.vor-installation-still '' "$(cat "$W/tick.log" 2>/dev/null)"
echo v9.0.0 > "$W/VERSION_TICK"
( UPDATE_CHECK_AT=0000 BACKUP_AUTO_AT=0000 update_tick )
eq K.erster-tick-alles 'run check cli backup auto' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
: > "$W/tick.log"; ( UPDATE_CHECK_AT=0000 BACKUP_AUTO_AT=0000 update_tick )
eq K.einmal-am-tag 'run' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
case "$(read_env_value "$UPDATE_TICK_STATE" LAST_TICK)" in ''|*[!0-9]*) fail K.lebenszeichen "LAST_TICK fehlt" ;; *) pass K.lebenszeichen ;; esac
# Vertragsaenderung: der Check laeuft im Intervall (UPDATE_CHECK_EVERY_S), nicht mehr ab einer Uhrzeit. BACKUP_AUTO_AT=2400
# bleibt gesetzt -> deckt weiter "Sicherung nicht vor der Uhrzeit" ab.
rm -f "$UPDATE_TICK_STATE"; : > "$W/tick.log"; env_upsert "$UPDATE_TICK_STATE" LAST_CHECK "$(date -u +%s)"
( BACKUP_AUTO_AT=2400 update_tick )
eq K.frisch-geprueft-nur-auftraege 'run' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
env_upsert "$UPDATE_TICK_STATE" LAST_CHECK "$(( $(date -u +%s) - 7300 ))"; : > "$W/tick.log"
( BACKUP_AUTO_AT=2400 update_tick )
eq K.intervall-abgelaufen-prueft-wieder 'run check' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
env_upsert "$UPDATE_TICK_STATE" LAST_CHECK 2026-11-08; : > "$W/tick.log"
( BACKUP_AUTO_AT=2400 update_tick )
eq K.alter-datumswert-prueft 'run check' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
case "$(read_env_value "$UPDATE_TICK_STATE" LAST_CHECK)" in ''|*[!0-9]*) fail K.epoch-nach-datum "LAST_CHECK kein Epoch-Wert" ;; *) pass K.epoch-nach-datum ;; esac
env_upsert "$UPDATE_TICK_STATE" LAST_CHECK 0; : > "$W/tick.log"; : > "$W/check.args"
( BACKUP_AUTO_AT=2400 update_tick )
eq K.tick-prueft-geplant 'scheduled' "$(cat "$W/check.args")"
env_upsert "$UPDATE_TICK_STATE" LAST_CHECK "$(( $(date -u +%s) + 99999 ))"; : > "$W/tick.log"
( BACKUP_AUTO_AT=2400 update_tick )
eq K.uhr-zurueck-prueft-wieder 'run check' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
unset LIFEAGENTS_RUNTIME

# ---------------------------------------------------------------------------- O: veroeffentlichte Ports (Wizard, Paperless)
_ps_rows='{"image":"ghcr.io/paperless-ngx/paperless-ngx:2","ports":"0.0.0.0:8010->8000/tcp, [::]:8010->8000/tcp"}
{"image":"postgres:17","ports":"0.0.0.0:8000->8000/tcp"}
{"image":"paperless-ngx/paperless-ngx","ports":"127.0.0.1:9000->8000/tcp, :::8011->8000/tcp, 8000/tcp, 0.0.0.0:7000->7000/tcp"}
{"image":"paperless-ngx/paperless-ngx","ports":"0.0.0.0:8020-8021->8000-8001/tcp"}'
: > "$STUB_LOG"
eq O.treffer-nur-image-und-port '[{"ip":"0.0.0.0","port":8010},{"ip":"127.0.0.1","port":9000},{"ip":"::","port":8010},{"ip":"::","port":8011}]' \
  "$(STUB_PS="$_ps_rows" rt_published_ports_json paperless-ngx 8000)"
eq O.nur-festes-format 'docker|ps|--format|{"image":{{json .Image}},"ports":{{json .Ports}}}|stdin=' "$(cat "$STUB_LOG")"
eq O.keine-container '[]' "$(STUB_PS='' rt_published_ports_json paperless-ngx 8000)"
out="$(STUB_FAIL='|ps|' rt_published_ports_json paperless-ngx 8000)"; rc=$?
eq O.ohne-docker " rc=1" "$out rc=$rc"
out="$(STUB_PS='kein json' rt_published_ports_json paperless-ngx 8000)"; rc=$?
eq O.kaputte-ausgabe " rc=1" "$out rc=$rc"

# ---------------------------------------------------------------------------- N: PG-Minor-Neustart (install_pg.sh)
# Paket-Skripte duerfen im Substrat nicht starten (policy-rc.d) -> der Server laeuft nach --only-upgrade mit alter Minor.
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/install_pg.sh"
pg_minor_stale "17.11 (Debian 17.11-1.pgdg12+1)" "17.12-1.pgdg12+1"; eq N.alt-gegen-neu-veraltet 0 $?
pg_minor_stale "17.12 (Debian 17.12-1.pgdg12+1)" "17.12-1.pgdg12+1"; eq N.gleich-nicht-veraltet 1 $?
pg_minor_stale "" "17.12-1.pgdg12+1"; eq N.laufend-unbekannt-nicht-veraltet 1 $?
pg_minor_stale "17.11" ""; eq N.paket-unbekannt-nicht-veraltet 1 $?
# pg_n_run <laufend> <ready:0|1> <runtime> — fuehrt install_postgres mit Attrappen in einem SUBSHELL aus (Attrappen
# bleiben lokal) und gibt die Zahl der Neustarts aus; `die` am Ende (kein N8N_DB_PASSWORD) beendet nur den Subshell.
pg_n_run() {
  local cnt="$W/pg_restarts"; : > "$cnt"
  (
    PG_VERSION=17; LIFEAGENTS_RUNTIME="$3"; RUN_VER="$1"; PG_READY="$2"; unset N8N_DB_PASSWORD
    need_su_tools() { return 0; }
    pg_ready() { [ "$PG_READY" = 0 ]; }
    pg_wait_ready() { return 0; }
    pg_su_psql() { printf '%s\n' "$RUN_VER"; }
    dpkg-query() { printf '17.12-1.pgdg12+1'; }
    install_pg_packages() { :; }
    svc_up() { :; }
    rt_wait_healthy() { return 0; }
    _pg_super() { return 0; }
    svc_restart() { echo x >> "$cnt"; RUN_VER="17.12 (Debian 17.12-1.pgdg12+1)"; }
    install_postgres
    install_postgres
  ) >/dev/null 2>&1 || true
  wc -l < "$cnt" | tr -d ' '
}
eq N.install_postgres-veraltet-startet-neu-einmal 1 "$(pg_n_run '17.11 (Debian 17.11-1.pgdg12+1)' 0 systemd)"
eq N.install_postgres-aktuell-kein-neustart 0 "$(pg_n_run '17.12 (Debian 17.12-1.pgdg12+1)' 0 systemd)"
eq N.install_postgres-server-steht-kein-neustart 0 "$(pg_n_run '17.11' 1 systemd)"
eq N.install_postgres-verbund-kein-neustart 0 "$(pg_n_run '17.11' 0 compose)"

exit "$fails"
