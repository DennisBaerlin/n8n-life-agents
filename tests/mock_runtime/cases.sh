#!/usr/bin/env bash
# cases.sh — Fall-Runner von scripts/dev/runtime_test.ps1, laeuft IM Substrat-Container (root, bash 5, jq).
#
# Faehrt den ECHTEN Code des Worktrees (provisioning/lib/common.sh -> runtime.sh, release_inputs.sh) gegen Attrappen:
#   A  Antwort-Datei (install_answers_load): liest 'Text', "Text", Woerter, '\'', Kommentare; fuehrt NIE etwas aus
#      ($(), Backticks, ;, Leerzeichen-Befehl), Zeilenumbruch im Wert bleibt Wert, gesperrte Schluessel, CR, Meldung ohne Wert.
#   W  Betriebsart-Wrapper: systemd-Zweig ruft runuser/systemctl genau wie vorher; compose-Zweig ruft docker exec mit
#      festem Container, -i nur, wenn psql stdin liest (Probelauf-Fund: `docker exec -i` frass die Paket-Schleife).
#   V  rt_volumes_ensure: legt fehlende Volumes mit Label an, bricht bei fremdem Volume gleichen Namens ab.
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
case "$me $1 ${2:-}" in
  "docker volume inspect") [ -n "${STUB_VOL_LABEL+x}" ] && { printf '%s\n' "$STUB_VOL_LABEL"; exit 0; }; exit 1 ;;
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

exit "$fails"
