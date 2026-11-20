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
#   R  Netz-Wiederholung (rt_stack_up dreimal, add_apt_key curl --retry-all-errors).
#   I  Sicherungs-Timer (install_backup_timer.sh): Units, Zweitlauf no-op, alte crontab-Zeile (nur diese), Abbau, "faellig"-Rechnung.
#   D  doctor im Docker-Verbund: Alter von Release-Check und Sicherungs-Versuch, Tunnel (Tailscale).
#   G  Fingerabdruck des Workflow-Deploys: n8n-Version je Einstieg gleich, Versionswechsel aendert ihn.
#   H  doctor-Warnung: ein Dienst laeuft noch mit dem alten Node (ersetzte Binary in /proc).
#   SU Linux-Einrichter provisioning/setup.sh (Pruefungen vor jeder Aenderung, Docker-Einrichtung, Kern-Aufruf, Befehl + Systemd-Einheit,
#      Abbau); eigene Datei setup_cases.sh, hier eingebunden.
# Braucht kein n8n, kein Docker und kein Netz.
#
# Usage: bash cases.sh <root>      Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2016,SC2329,SC1003,SC2034,SC2015,SC2030,SC2031  # Windows-Pfade mit Backslash am Ende; Env-Prefixe fuer Funktionen; Pruef-Ausdruecke stehen bewusst in einfachen Quotes (eval im Fall); Attrappen-Funktionen ruft der Lib-Code
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
# STUB_FAIL_FROM=N: erst ab dem N-ten passenden Aufruf scheitern (ein Fehler mitten im Lauf, nicht schon beim ersten Blick).
if [ -n "${STUB_FAIL:-}" ]; then case "$(printf '|%s' "$@")" in *"$STUB_FAIL"*)
  if [ -n "${STUB_FAIL_FROM:-}" ]; then echo x >> "${STUB_LOG}.failn"; [ "$(wc -l < "${STUB_LOG}.failn")" -ge "$STUB_FAIL_FROM" ] || exit_ok=1; fi
  [ -n "${exit_ok:-}" ] || { echo "stub: Daemon-Fehler" >&2; exit 1; } ;; esac; fi
if [ -n "${STUB_FAIL2:-}" ]; then case "$(printf '|%s' "$@")" in *"$STUB_FAIL2"*) echo "stub: Daemon-Fehler" >&2; exit 1 ;; esac; fi
# Kern (lib/stack_core.sh): Kurzlauf-Container. STUB_CAT_<pfad mit _> = Inhalt einer Datei im Volume (rt_vol_get),
# stdin von `run -i` landet in ${STUB_LOG}.put (rt_vol_put), STUB_BUSY_PORTS = belegte Ports (rt_host_port_free),
# STUB_DF_KB = freier Platz, STUB_DELEGATE_RC = Exit einer Weitergabe (core-next).
if [ "$me" = docker ] && [ -n "${STUB_VOLS+x}" ] && [ "${1:-}" = volume ]; then
  case "${2:-}" in
    create) printf '%s\n' "${*: -1}" >> "${STUB_LOG}.vols" ;;
    rm) grep -vxF -- "${*: -1}" "${STUB_LOG}.vols" > "${STUB_LOG}.vols.n" 2>/dev/null; mv -f "${STUB_LOG}.vols.n" "${STUB_LOG}.vols" ;;
  esac
fi
if [ "$me" = docker ] && [ "${1:-}" = run ]; then
  a="$(printf '|%s' "$@")"
  case "$a" in *'|-i|'*) { printf '== %s\n' "${*: -1}"; cat; } >> "${STUB_LOG}.put" ;; esac
  case "$a" in
    # STUB_DELEGATE_SLEEP: der innere Kern laeuft so lange; ein weitergeleitetes TERM beantwortet er wie der echte (result, Exit 1).
    *'|--name|'*'-core-next|'*)
      if [ -n "${STUB_DELEGATE_SLEEP:-}" ]; then
        # STUB_DELEGATE_DEAF: ein innerer Kern, der TERM ignoriert (aelterer Stand ohne Handler).
        if [ -n "${STUB_DELEGATE_DEAF:-}" ]; then trap '' TERM; else
        trap 'printf "%s\n" "{\"v\":1,\"type\":\"result\",\"verb\":\"up\",\"ok\":false,\"reason\":\"internal\",\"detail\":\"innen\"}"; exit 1' TERM; fi
        sleep "$STUB_DELEGATE_SLEEP" & wait $!
      fi
      exit "${STUB_DELEGATE_RC:-0}" ;;
    *'-portprobe-'*) p="${a##*-portprobe-}"; p="${p%%|*}"; case " ${STUB_BUSY_PORTS:-} " in *" $p "*) exit 125 ;; esac; exit 0 ;;
    *'|cat|/r/f') echo ok; exit 0 ;;
    *'|df|-Pk|/') printf 'Filesystem 1024-blocks Used Available Capacity Mounted\noverlay 1 1 %s 1%% /\n' "${STUB_DF_KB:-50000000}"; exit 0 ;;
  esac
  # rt_vol_get: Datei im nur lesend gemounteten Volume; fehlt sie, endet der Container wie `[ -e ] || exit 3`.
  case "$a" in *',readonly|'*) case "${*: -1}" in /var_la/*|/rt_tree/*|/pgdata/*)
    v="STUB_CAT_$(printf '%s' "${*: -1}" | tr -c 'A-Za-z0-9\n' _)"; [ -n "${!v:-}" ] || exit 3; printf '%s\n' "${!v}"; exit 0 ;; esac ;; esac
  exit 0
fi
# STUB_SLOW_UP / STUB_SLOW_EXEC = Sekunden, die `compose up --wait` bzw. provision.sh im master dauern (Abbruch per Signal).
case "$(printf '|%s' "$@")" in
  *'|up|-d|--wait|'*) [ -z "${STUB_SLOW_UP:-}" ] || sleep "$STUB_SLOW_UP" ;;
  *'|exec|lifeagents-master|bash|/opt/lifeagents/provisioning/provision.sh|'*) [ -z "${STUB_SLOW_EXEC:-}" ] || sleep "$STUB_SLOW_EXEC" ;;
  *'|down|--remove-orphans'*) [ -z "${STUB_SLOW_DOWN:-}" ] || sleep "$STUB_SLOW_DOWN" ;;
esac
case "$me $1 ${2:-}" in
  "docker version --format")
    case "${3:-}" in *Os*) printf '%s\n' "${STUB_SRV_OS:-linux}" ;; *) printf '%s\n' "${STUB_SRV_VERSION:-27.5.1}" ;; esac; exit 0 ;;
  "docker info --format") printf '%s\n' "${STUB_MEM:-8000000000}"; exit 0 ;;
  "docker volume inspect")
    # STUB_VOLS gesetzt = nur diese Volumes gibt es (Label STUB_VOL_LABEL, Standard lifeagents); sonst gilt STUB_VOL_LABEL fuer alle.
    # Dazu zaehlen dann auch die mit `volume create` angelegten (${STUB_LOG}.vols), bis `volume rm` sie entfernt.
    # STUB_WARN = die CLI warnt auf stderr, auch wenn die Abfrage gelingt (z. B. DOCKER_HOST ueberschreibt den Kontext).
    [ -z "${STUB_WARN:-}" ] || echo "WARNING: DOCKER_HOST environment variable overrides the active context." >&2
    if [ -n "${STUB_VOLS+x}" ]; then
      case " $STUB_VOLS $(tr '\n' ' ' < "${STUB_LOG}.vols" 2>/dev/null) " in *" ${*: -1} "*) printf '%s\n' "${STUB_VOL_LABEL:-lifeagents}"; exit 0 ;; esac
      echo "Error: No such volume: ${*: -1}" >&2; exit 1
    fi
    [ -n "${STUB_VOL_LABEL+x}" ] && { printf '%s\n' "$STUB_VOL_LABEL"; exit 0; }; echo "Error: No such volume: ${*: -1}" >&2; exit 1 ;;
  "docker image inspect")  # mit -f: Umgebung + Versions-Etikett des Abbilds wie unten bei inspect -f
    if [ "${3:-}" = -f ]; then
      case "${4:-}" in *io.lifeagents.core*) case " ${STUB_CORE_IMAGES:-} " in *" ${*: -1} "*) echo 1 ;; *) echo '<no value>' ;; esac; exit 0 ;; esac
      printf 'PATH=/usr/bin\n%s%s\n' "${STUB_REL_ENV:+RELEASE_TAG=$STUB_REL_ENV
}" "${STUB_REL_LABEL:-}"; exit 0
    fi
    case " ${STUB_IMAGES_ABSENT:-} " in *" ${3:-} "*) exit 1 ;; esac
    [ "${STUB_IMAGE_PRESENT:-1}" = 1 ]; exit $? ;;
  "docker ps --format")    printf '%s' "${STUB_PS:-}"; exit 0 ;;   # STUB_PS = Zeilen wie aus dem festen JSON-Format
  "docker inspect -f")
    # STUB_RUNNING = laufende Container (Leerzeichen-Liste); STUB_IMG_<name mit _> = Image eines Containers.
    n="${*: -1}"
    case "$3" in
      *State.Running*) case " ${STUB_RUNNING:-} " in *" $n "*) echo true ;; *) echo false ;; esac ;;
      *Config.Image*)  v="STUB_IMG_$(printf '%s' "$n" | tr -c 'A-Za-z0-9\n' _)"; [ -n "${!v:-}" ] || exit 1; printf '%s\n' "${!v}" ;;
      # Umgebung + Versions-Etikett des master (STUB_REL_ENV leer = Abbild ohne RELEASE_TAG, STUB_REL_LABEL leer = ohne Etikett);
      # STUB_MASTER_ENV = weitere Zeilen der Umgebung (Werte einer Installation der Start-App).
      *Config.Env*)    printf 'PATH=/usr/bin\n%s%s%s\n' "${STUB_MASTER_ENV:+$STUB_MASTER_ENV
}" "${STUB_REL_ENV:+RELEASE_TAG=$STUB_REL_ENV
}" "${STUB_REL_LABEL:-}" ;;
      # STUB_EXISTING = vorhandene Container (Kennung id-<name>); ohne Eintrag gibt es den Container nicht.
      # Argumente eines Containers (Kern: welches Verb laeuft); STUB_ARGS_<name mit _>, Standard 'up --json'.
      *'.Args'*)       v="STUB_ARGS_$(printf '%s' "$n" | tr -c 'A-Za-z0-9\n' _)"; printf '%s\n' "${!v:-up --json}" ;;
      *'{{.Id}}'*)     case " ${STUB_EXISTING:-} " in *" $n "*) printf 'id-%s\n' "$n" ;; *) echo "Error: No such object: $n" >&2; exit 1 ;; esac ;;
    esac
    exit 0 ;;
esac
case "$(printf '|%s' "$@")" in
  *"|config|--format|json|"*|*"|config|--format|json") printf '%s' "${STUB_CONFIG_JSON:-}"; exit 0 ;;
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
# Docker-Fehler beim Nachsehen ist kein „fehlt“: weder anlegen (traefe ein vorhandenes, evtl. fremdes Volume) noch weiter.
: > "$STUB_LOG"
if ( STUB_VOL_LABEL=lifeagents STUB_FAIL='|lifeagents_pgdata' rt_volumes_ensure ) 2>/dev/null; then fail V.inspect-fehler-abbruch "kein Abbruch"; else pass V.inspect-fehler-abbruch; fi
if grep -q 'volume|create|.*lifeagents_pgdata' "$STUB_LOG"; then fail V.inspect-fehler-kein-create "angelegt"; else pass V.inspect-fehler-kein-create; fi
# Eine Warnung der CLI auf stderr gehoert nicht zum Label.
eq V.label-trotz-warnung lifeagents "$(STUB_WARN=1 STUB_VOL_LABEL=lifeagents rt_volume_label lifeagents_pgdata 2>/dev/null)"
eq V.label-fehlt-rc1 1 "$( (rt_volume_label lifeagents_gibtsnicht >/dev/null 2>&1); echo $?)"
eq V.label-fehler-rc2 2 "$( (STUB_VOL_LABEL=lifeagents STUB_FAIL='|lifeagents_x' rt_volume_label lifeagents_x >/dev/null 2>&1); echo $?)"
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
  # Paperless-Attrappe (Mocks im Pod): Adresse und Zugang kommen ueber die Antwort-Datei, das Manifest nimmt Loopback an.
  mkdir -p "$W/pk/paperless"; cp "$ROOT/packages/paperless/manifest.json" "$W/pk/paperless/manifest.json"
  PKG_SETTINGS_ANSWERS=''; rm -f "$W/la/paperless.env"
  r="$( ( CONFIG_GENERAL_PAPERLESS_URL=http://127.0.0.1:8092 _pkg_settings_from_env paperless; printf '%s' "$PKG_SETTINGS_ANSWERS" ) 2>/dev/null )"
  eq P.paperless-ziel-aus-antwort $'paperless\tgeneral\tpaperless_url\thttp://127.0.0.1:8092' "$r"
  ( PAPERLESS_API_TOKEN=mock-paperless-token _pkg_secrets_wizard paperless "$W/la/paperless.env" 0 ) >/dev/null 2>&1
  eq P.paperless-zugang-aus-antwort mock-paperless-token "$(read_env_value "$W/la/paperless.env" PAPERLESS_API_TOKEN)"
else
  fail P.jq "jq fehlt im Container (Pflicht fuer die Paket-Faelle)"
fi

# ---------------------------------------------------------------------------- L: Test-Weiche LIFEAGENTS_LLM_UPSTREAM (Gateway-Install)
# Inhalte gehen nur an api.anthropic.com (Privacy-Regel); die Weiche biegt das Ziel nur auf die KI-Attrappe im eigenen Netz-Namensraum
# (http://127.0.0.1:<port>), alles andere bricht ab, bevor etwas geschrieben wird. Ohne Weiche bleibt das Ziel unveraendert.
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/install_llm_gateway.sh"
# Dienst-Start und Port-Probe sind hier Attrappen (kein Docker, kein systemd); was die Weiche schreibt, laeuft echt.
# real-path-test: L.echter-weg schickt die geschriebene gateway.env durch den echten Gateway gegen die echte KI-Attrappe.
_wait_llm_gateway_health() { return 0; }
_llm_gateway_port_foreign() { return 1; }
LW="$W/lw"
# gwrun <Betriebsart> <Weiche|-> : install_llm_gateway in frischem Ordner; Ausgabe in $LW/out.
gwrun() {
  rm -rf "$LW"; mkdir -p "$LW"
  ( export LIFEAGENTS_RUNTIME="$1" LLM_GATEWAY_DIR="$LW/gw" STATE_DIRECTORY="$LW/st" INSTALL_ENV_FILE="$LW/core.env" \
      SCRIPT_DIR="$ROOT/provisioning" LLM_GATEWAY_SRC="$ROOT/provisioning/llm_gateway/server.js" LLM_GATEWAY_STICKER_SRC="$LW/keine" \
      LLM_GATEWAY_KEEPALIVE_HOURS=0
    unset LIFEAGENTS_LLM_UPSTREAM
    [ "$2" = - ] || export LIFEAGENTS_LLM_UPSTREAM="$2"
    install_llm_gateway ) >"$LW/out" 2>&1
}
gwenv() { read_env_value "$LW/gw/gateway.env" "$1" 2>/dev/null || true; }
gwrun compose http://127.0.0.1:8088;   eq L.weiche-schreibt-ziel http://127.0.0.1:8088 "$(gwenv LLM_GATEWAY_UPSTREAM)"
gwrun compose http://127.0.0.1:08088;  eq L.fuehrende-null-normalisiert http://127.0.0.1:8088 "$(gwenv LLM_GATEWAY_UPSTREAM)"
gwrun compose -
if [ -f "$LW/gw/gateway.env" ] && ! grep -q '^LLM_GATEWAY_UPSTREAM' "$LW/gw/gateway.env"; then pass L.ohne-weiche-keine-zeile; else fail L.ohne-weiche-keine-zeile "Zeile vorhanden oder gateway.env fehlt"; fi
for bad in https://api.anthropic.com http://example.org http://127.0.0.1.evil.test:80 http://localhost:8088 http://127.0.0.1:0 \
           http://127.0.0.1:99999 http://127.0.0.1:8088/x http://u@127.0.0.1:8088 http://127.0.0.1 http://127.0.0.1:8088/ 'http://[::1]:8088' 'http://127.0.0.1:8088 x'; do
  if gwrun compose "$bad"; then fail "L.fremdes-ziel-bricht-ab [$bad]" "kein Abbruch"
  elif [ -e "$LW/gw" ]; then fail "L.fremdes-ziel-bricht-ab [$bad]" "es wurde schon geschrieben"
  elif sed 's|http://127.0.0.1:<port>||g' "$LW/out" | grep -qF -- "$bad"; then fail "L.fremdes-ziel-bricht-ab [$bad]" "die Meldung nennt den Wert"
  else pass "L.fremdes-ziel-bricht-ab [$bad]"; fi
done
# systemd-Betrieb: die Unit-Vorlage bleibt unveraendert, die Weiche gibt es nur im Verbund.
if gwrun systemd http://127.0.0.1:8088; then fail L.systemd-lehnt-ab "kein Abbruch"
elif [ -e "$LW/gw" ]; then fail L.systemd-lehnt-ab "es wurde schon geschrieben"; else pass L.systemd-lehnt-ab; fi
# Antwort-Datei: die Weiche setzt nur die Umgebung des Aufrufers, nie eine Antwort (Sperrliste).
printf '%s\n' 'LIFEAGENTS_LLM_UPSTREAM=http://127.0.0.1:8088' > "$W/a"; ok_ans L.antwortdatei-sperrt '[ "${LIFEAGENTS_LLM_UPSTREAM:-}" != http://127.0.0.1:8088 ]'
# Echter Weg: gateway.env -> echter Gateway (provisioning/llm_gateway/server.js) -> echte KI-Attrappe (tests/mock_llm/server.js).
# hand-injected: die Ports 18188/18197 (zweiter Lauf 18189/18198) sind frei gewaehlt (der Standard 8090 koennte im Substrat belegt sein); gateway.env wird sonst unveraendert gelesen
LMOCK=18188; LGW=18197; LLOG="$W/mock_llm.jsonl"
lstart() {   # lstart <gateway.env> : KI-Attrappe + Gateway starten (Hintergrund), auf beide warten
  : > "$LLOG"
  MOCK_LLM_PORT=$LMOCK MOCK_LLM_LOG="$LLOG" MOCK_LLM_SCENARIOS="$ROOT/tests/mock_llm/scenarios.json" node "$ROOT/tests/mock_llm/server.js" >"$W/l_mock.log" 2>&1 & LPID1=$!
  # shellcheck disable=SC2046  # gateway.env: ein Paar je Zeile, Werte ohne Leerzeichen (Hex, Zahlen, Pfade)
  env -i PATH="$PATH" $(cat "$1") LLM_GATEWAY_PORT=$LGW STATE_DIRECTORY="$LW/st" node "$LW/gw/server.js" >"$W/l_gw.log" 2>&1 & LPID2=$!
  # Beide Prozesse muessen leben: sonst koennte ein fremder Listener auf dem Port die Gesundheitsprobe beantworten.
  local _; for _ in $(seq 1 100); do
    kill -0 "$LPID1" 2>/dev/null && kill -0 "$LPID2" 2>/dev/null || return 1
    curl -sf "http://127.0.0.1:$LGW/__health" >/dev/null 2>&1 && curl -sf "http://127.0.0.1:$LMOCK/__health" >/dev/null 2>&1 && return 0; sleep 0.3
  done
  return 1
}
# Grund eines gescheiterten Starts (Prozesse und Protokolle), eine Zeile.
lwhy() { printf 'mock=%s gateway=%s | %s | %s' "$(kill -0 "$LPID1" 2>/dev/null && echo lebt || echo tot)" "$(kill -0 "$LPID2" 2>/dev/null && echo lebt || echo tot)" \
  "$(tr '\n' ' ' < "$W/l_mock.log" | head -c 200)" "$(tr '\n' ' ' < "$W/l_gw.log" | head -c 200)"; }
lstop() { kill "${LPID1:-0}" "${LPID2:-0}" 2>/dev/null; wait "${LPID1:-0}" "${LPID2:-0}" 2>/dev/null; return 0; }
trap 'lstop; rm -rf "$W"' EXIT
if command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  gwrun compose "http://127.0.0.1:$LMOCK" && mkdir -p "$LW/st"
  if lstart "$LW/gw/gateway.env"; then
    lup="$(curl -sf "http://127.0.0.1:$LGW/__health" | jq -r .upstream)"
    eq L.echter-weg-ziel "http://127.0.0.1:$LMOCK" "$lup"
    # Nur mit der Attrappe als Ziel: Zeigt der Gateway woandershin (rot), ginge der Aufruf an den echten Dienst.
    if [ "$lup" = "http://127.0.0.1:$LMOCK" ]; then
      curl -s -o /dev/null -X POST "http://127.0.0.1:$LGW/v1/messages" -H 'x-api-key: erfunden' -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
        -d '{"model":"claude-haiku-latest","max_tokens":16,"messages":[{"role":"user","content":"hallo"}]}'
      if jq -e 'select(.url == "/v1/messages" and .dialect == "anthropic")' "$LLOG" >/dev/null 2>&1; then pass L.echter-weg; else fail L.echter-weg "kein Aufruf kam in der KI-Attrappe an"; fi
    else fail L.echter-weg "Ziel ist nicht die KI-Attrappe, kein Aufruf geschickt"; fi
  else fail L.echter-weg "Gateway oder KI-Attrappe starten nicht: $(lwhy)"; fi
  lstop
  # Ohne Weiche zeigt der Gateway auf api.anthropic.com; es wird hier bewusst kein Aufruf geschickt (er ginge an den echten Dienst).
  # Eigene Ports: der Standort des ersten Laufs ist erst nach dem Beenden der Prozesse frei.
  LMOCK=18189; LGW=18198
  gwrun compose - && mkdir -p "$LW/st"
  if lstart "$LW/gw/gateway.env"; then
    eq L.ohne-weiche-kein-loopback https://api.anthropic.com "$(curl -sf "http://127.0.0.1:$LGW/__health" | jq -r .upstream)"
  else fail L.ohne-weiche-kein-loopback "Gateway oder KI-Attrappe starten nicht: $(lwhy)"; fi
  lstop
else
  fail L.echter-weg "node oder curl fehlt im Container"
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
# Gegensperre: laeuft ein Kern (stack up/uninstall), beginnt kein Wechsel; nichts gestartet, keine Zustandsdatei.
: > "$STUB_LOG"
if ( STUB_RUNNING=lifeagents-core master_swap_begin v9.1.0 "$W/compose.new.src" "$NEW" ) >/dev/null 2>&1; then fail S.kern-sperrt "kein Abbruch"; else pass S.kern-sperrt; fi
if grep -q 'lifeagents-swap' "$STUB_LOG" || [ -e "$SWAP_STATE" ]; then fail S.kern-sperrt-nichts-geaendert "Helfer oder Zustand"; else pass S.kern-sperrt-nichts-geaendert; fi
# Ein nur lesender Kern (status/check/wizard-url) haelt kein Update auf.
if ( STUB_RUNNING=lifeagents-core STUB_ARGS_lifeagents_core='status --json' master_swap_begin v9.1.0 "$W/compose.new.src" "$NEW" ) >/dev/null 2>&1; then pass S.lesender-kern-sperrt-nicht; else fail S.lesender-kern-sperrt-nicht "Abbruch"; fi
master_swap_close; rm -f "$SWAP_STATE"
# Fenster: der Kern startet erst, waehrend das Update die Abbilder laedt (nach der ersten Pruefung). Der Wechsel prueft nach
# dem Schreiben der Zustandsdatei erneut und bricht vor dem Helfer ab; die Datei ist danach wieder weg.
: > "$STUB_LOG"; rm -f "$W/core.now"
if ( rt_core_changing() { [ -e "$W/core.now" ]; }; rt_target_precheck() { : > "$W/core.now"; }
     master_swap_begin v9.1.0 "$W/compose.new.src" "$NEW" ) >/dev/null 2>&1; then fail S.kern-im-fenster-sperrt "kein Abbruch"; else pass S.kern-im-fenster-sperrt; fi
if grep -q 'lifeagents-swap' "$STUB_LOG" || [ -e "$SWAP_STATE" ] || [ -e "$SWAP_DIR/stack.env" ]; then fail S.kern-im-fenster-nichts-geaendert "Helfer, Zustand oder Env-Datei"; else pass S.kern-im-fenster-nichts-geaendert; fi
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
: > "$STUB_LOG"; printf 'chiffrat' > "$W/hp.src"; rt_host_put /Users/erika/Sicherung lifeagents-backup-1.nla.enc "$W/hp.src"
case "$(last)" in
  "docker|run|--rm|-i|--label|io.lifeagents.install=lifeagents|--network|none|--mount|type=bind,src=/Users/erika/Sicherung,dst=/out|busybox:test|sh|-c|"*"|_|lifeagents-backup-1.nla.enc|"[0-9a-f]*"|stdin=") pass R.schreiben-nur-dieser-ordner ;;
  *) fail R.schreiben-nur-dieser-ordner "$(last)" ;;
esac
: > "$STUB_LOG"; rt_host_get /Users/erika/Sicherung x.nla.enc >/dev/null
case "$(last)" in *"type=bind,src=/Users/erika/Sicherung,dst=/in,readonly|"*) pass R.lesen-nur-lesend ;; *) fail R.lesen-nur-lesend "$(last)" ;; esac
if grep -qE '\|-v\||prune' "$STUB_LOG"; then fail R.kein-breiter-schalter "$(cat "$STUB_LOG")"; else pass R.kein-breiter-schalter; fi
# Mehr als 50 Tabellen: jsonb_build_object nimmt hoechstens 100 Argumente -> Bloecke zu 50 Paaren (Export brach sonst ab).
_pairs=(); for i in $(seq 1 120); do _pairs+=("'t$i', $i"); done
_obj="$( { _bkp_jsonb_obj "${_pairs[@]}"; } 2>/dev/null || true)"
eq R.json-bloecke-zu-50 '3 0 120' "$(printf '%s' "$_obj" | grep -o 'jsonb_build_object(' | wc -l) $(printf '%s' "$_obj" | grep -o "'t[0-9]*'" | sort | uniq -d | wc -l) $(printf '%s' "$_obj" | grep -o "'t[0-9]*'" | wc -l)"
eq R.json-leer "'{}'::jsonb" "$( { _bkp_jsonb_obj; } 2>/dev/null || true)"
# pg_dump -a meldet Fremdschluessel-Ringe als Warnung (harmlos mit --disable-triggers) -> nur genau dieser Block faellt weg,
# jede andere Warnung samt ihrem Hinweis und jeder Fehler bleiben sichtbar (Texte wie pg_dump 17, Tabellennamen erfunden).
_pgerr='pg_dump: warning: there are circular foreign-key constraints on this table:
pg_dump: detail: konten
pg_dump: hint: You might not be able to restore the dump without using --disable-triggers or temporarily dropping the constraints.
pg_dump: hint: Consider using a full dump instead of a --data-only dump to avoid this problem.
pg_dump: warning: there are circular foreign-key constraints among these tables:
pg_dump: detail: objekte
pg_dump: detail: buchungen
pg_dump: detail: kredite
pg_dump: hint: You might not be able to restore the dump without using --disable-triggers or temporarily dropping the constraints.
pg_dump: hint: Consider using a full dump instead of a --data-only dump to avoid this problem.
pg_dump: warning: could not find something else
pg_dump: hint: some other hint
pg_dump: error: query failed'
eq R.pgdump-ring-warnung-weg 'pg_dump: warning: could not find something else|pg_dump: hint: some other hint|pg_dump: error: query failed' \
  "$(printf '%s\n' "$_pgerr" | { _bkp_pgdump_stderr 2>/dev/null || true; } | paste -sd'|' -)"
eq R.pgdump-ohne-ring-unveraendert 'pg_dump: detail: x|pg_dump: warning: y' \
  "$(printf 'pg_dump: detail: x\npg_dump: warning: y\n' | { _bkp_pgdump_stderr 2>/dev/null || true; } | paste -sd'|' -)"

# ---------------------------------------------------------------------------- B: Sicherungs-Schluessel (Notfallblatt)
# Erfundene Schluessel, nie ein echter Wert (Repo oeffentlich).
K1="$(printf '0123456789abcdef%.0s' 1 2 3 4)"
K2="$(printf 'fedcba9876543210%.0s' 1 2 3 4)"
_paper="$(printf '%s' "$K1" | backup_key_paper)"
eq B.blatt-vier-zeilen 4 "$(printf '%s\n' "$_paper" | grep -cE '^[1-4]:  [0-9a-f]{4}(-[0-9a-f]{4}){3}  [0-9a-f]{2}$')"
eq B.blatt-rundweg "key:$K1" "$(printf '%s\n' "$_paper" | backup_key_parse)"
eq B.gross-und-ohne-praefix "key:$K1" "$(printf '%s\n' "$_paper" | sed -E 's/^[1-4]:  //' | tr 'a-f' 'A-F' | backup_key_parse)"
eq B.roh-ohne-pruefzeichen "key:$K1" "$(printf '  %s\n' "$K1" | backup_key_parse)"
eq B.zeile-ohne-pruefzeichen 0123456789abcdef "$(printf '1: 0123-4567-89AB-cdef' | backup_key_line 1)"
_bad="$(printf '%s\n' "$_paper" | sed -E '3s/^(3:  )./\1f/')"
[ "$_bad" != "$_paper" ] || _bad="$(printf '%s\n' "$_paper" | sed -E '3s/^(3:  )./\1e/')"
eq B.tippfehler-zeile3 err:line3 "$(printf '%s\n' "$_bad" | backup_key_parse)"
# Zeile 2 unter Zeile 1 abgetippt (ohne Nummern): die Pruefzeichen haengen an der Zeilennummer.
_swap="$(printf '%s\n' "$_paper" | sed -E 's/^[1-4]:  //' | awk 'NR==1{a=$0;next} NR==2{print; print a; next} {print}')"
eq B.vertauschte-zeilen err:line1 "$(printf '%s\n' "$_swap" | backup_key_parse)"
eq B.zu-kurz err:length "$(printf 'abc123' | backup_key_parse)"
eq B.fremde-zeichen err:chars "$(printf 'kein schluessel!' | backup_key_parse)"
eq B.fehlende-zeile err:line4 "$(printf '%s\n' "$_paper" | sed '4d' | backup_key_parse)"
# Die ganze Notfallblatt-Datei: aktueller + aelterer Schluessel, dazwischen Text und eine Schritt-Liste.
_kit="$(printf 'Notfallblatt\n%s\n\nFuer aeltere Sicherungen:\n%s\n- 1. Schritt\nDatum 12.11.2026\n' "$_paper" "$(printf '%s' "$K2" | backup_key_paper)")"
eq B.datei-zwei-schluessel "key:$K1 key:$K2" "$(printf '%s\n' "$_kit" | backup_key_parse | tr '\n' ' ' | sed 's/ $//')"
eq B.datei-tippfehler-im-ersten "err:line3 key:$K2" "$(printf '%s\n%s\n' "$_bad" "$(printf '%s' "$K2" | backup_key_paper)" | backup_key_parse | tr '\n' ' ' | sed 's/ $//')"
_id1="$(printf '%s' "$K1" | backup_key_id)"; _id2="$(printf '%s' "$K2" | backup_key_id)"
if [[ "$_id1" =~ ^k[0-9a-f]{8}$ ]] && [ "$_id1" != "$_id2" ]; then pass B.kennung-form; else fail B.kennung-form "$_id1/$_id2"; fi
# Entschluesseln mit allen gespeicherten Schluesseln (die DB-Abfrage ist hier eine Attrappe; gpg ist echt).
printf 'klartext' > "$W/plain"
gpg_sym_encrypt "$K1" "$W/c.gpg" "$W/plain" 2>/dev/null
if ( backup_key_candidates() { printf '%s\n' "$K2" "$K1"; }
     gpg_sym_decrypt_any "$W/c.gpg" "$W/out" && [ "$_BK_HIT_INDEX" = 1 ] && [ "$_BK_HIT_KEY" = "$K1" ] && [ "$(cat "$W/out")" = klartext ] ); then
  pass B.alle-schluessel-probieren; else fail B.alle-schluessel-probieren "kein Treffer mit dem zweiten"; fi
printf 'rest' > "$W/out"
if ( backup_key_candidates() { printf '%s\n' "$K2"; }; gpg_sym_decrypt_any "$W/c.gpg" "$W/out" ); then fail B.kein-treffer "Treffer"
elif [ -s "$W/out" ]; then fail B.kein-treffer "Ausgabe nicht geleert"; else pass B.kein-treffer; fi
# Aufraeumen im Rechner-Ordner: nur eigene Kennung, die neuesten 14 bleiben; fremde Kennung und alte Namen nie.
_names="$( for i in $(seq 10 25); do printf 'lifeagents-backup-202611%02d033000-%s-v0.44.0.nla.enc\n' "$i" "$_id1"; done
           for i in 1 2 3; do printf 'lifeagents-backup-2026100%d033000-k0000000%d-v0.43.0.nla.enc\n' "$i" "$i"; done
           printf 'lifeagents-backup-20261001033000.nla.enc\nlifeagents-backup-20261002033000.nla.enc\n' )"
eq B.aufraeumen-nur-eigene "lifeagents-backup-20261111033000-${_id1}-v0.44.0.nla.enc lifeagents-backup-20261110033000-${_id1}-v0.44.0.nla.enc" \
  "$(printf '%s\n' "$_names" | _bkp_rotate_victims 14 "$_id1" | tr '\n' ' ' | sed 's/ $//')"
eq B.aufraeumen-fremde-kennung '' "$(printf '%s\n' "$_names" | _bkp_rotate_victims 14 k00000001)"
: > "$STUB_LOG"
if rt_host_rm /Users/erika/Sicherung ok.nla.enc ../weg 2>/dev/null; then fail B.loeschen-nur-namen "Pfad angenommen"
elif [ -s "$STUB_LOG" ]; then fail B.loeschen-nur-namen "Container trotzdem gestartet"; else pass B.loeschen-nur-namen; fi
rt_host_rm /Users/erika/Sicherung a.nla.enc b.nla.enc
case "$(last)" in *"src=/Users/erika/Sicherung,dst=/out|"*"|_|a.nla.enc|b.nla.enc|stdin=") pass B.loeschen-genau-diese ;; *) fail B.loeschen-genau-diese "$(last)" ;; esac
eq B.dateiname "lifeagents-backup-20261112033000-${_id1}-v0.44.0.nla.enc" "$(_bkp_file_name 20261112033000 "$_id1" v0.44.0)"
eq B.dateiname-dev "lifeagents-backup-20261112033000-${_id1}-vdev.nla.enc" "$(_bkp_file_name 20261112033000 "$_id1" 'main-1a2b/x')"
eq B.kennung-aus-name "$_id1" "$(_bkp_file_key_id "/x/lifeagents-backup-20261112033000-${_id1}-v0.44.0.nla.enc")"
eq B.kennung-umbenannte-kopie "$_id1" "$(_bkp_file_key_id "Kopie von lifeagents-backup-20261112033000-${_id1}-v0.44.0 (1).nla.enc")"
eq B.aufraeumen-nie-umbenannte '' "$(printf 'Kopie von lifeagents-backup-20261112033000-%s-v0.44.0.nla.enc\n' "$_id1" | _bkp_rotate_victims 0 "$_id1")"
# Eigen/fremd an einer Stelle (_bkp_classify): Terminal-Auswahl, Fragebogen-Hinweis und App-Liste. Fremde und alte zuerst,
# darin neueste zuerst; fremde Dateien ohne .nla.enc fallen weg.
_cls_in="$(printf '%s\n' "lifeagents-backup-20261110033000-${_id1}-v0.44.0.nla.enc" "lifeagents-backup-20261112033000-${_id1}-v0.44.0.nla.enc" \
  "lifeagents-backup-20261101033000-k0000000a-v0.43.0.nla.enc" "lifeagents-backup-20261102033000-k0000000a-v0.43.0.nla.enc" \
  "lifeagents-backup-20261001033000.nla.enc" "notizen.txt")"
_cls="$( ( _bkp_key_ids() { printf '%s\n' "$_id1"; }; printf '%s\n' "$_cls_in" | _bkp_classify | _bkp_sorted | cut -f1,3 | tr '\t\n' ': ' ) )"
eq B.einteilung-reihenfolge "lifeagents-backup-20261102033000-k0000000a-v0.43.0.nla.enc:other lifeagents-backup-20261101033000-k0000000a-v0.43.0.nla.enc:other lifeagents-backup-20261001033000.nla.enc:legacy lifeagents-backup-20261112033000-${_id1}-v0.44.0.nla.enc:own lifeagents-backup-20261110033000-${_id1}-v0.44.0.nla.enc:own " "$_cls"
eq B.einteilung-version-zeit "20261102033000 v0.43.0" "$( ( _bkp_key_ids() { :; }; printf '%s\n' "$_cls_in" | _bkp_classify | grep 20261102 | cut -f4,5 | tr '\t' ' ' ) )"
eq B.fremde-ids "k0000000a" "$( ( _bkp_key_ids() { printf '%s\n' "$_id1"; }; rt_host_ls() { printf '%s\n' "$_cls_in"; }; _bkp_foreign_ids /x ) )"
eq B.auswahl-fremde-zuerst "lifeagents-backup-20261102033000-k0000000a-v0.43.0.nla.enc" \
  "$( ( _bkp_key_ids() { printf '%s\n' "$_id1"; }; printf '%s\n' "$_cls_in" | _bkp_pick_lines | head -n1 | cut -f2 ) )"
# Start-App: Sicherung + Blatt ueber stdin (erste Zeile "sheet <base64>", danach die Datei bytegenau, auch mit UTF-8-Blatt).
printf 'Blatt mit Umlaut äö und 한글\n1:  abcd\n' > "$W/blatt.in"; printf 'BINAER\001\002ende' > "$W/datei.in"
{ printf 'sheet %s\n' "$(base64 -w0 < "$W/blatt.in")"; base64 < "$W/datei.in"; } > "$W/rahmen.in"
( _bkp_read_in_stdin "$W/rahmen.out" < "$W/rahmen.in"; printf '%s' "$_BKP_SHEET" > "$W/blatt.out"; printf '%s' "$_BKP_SHEET_SET" > "$W/gesetzt.out" ) 2>/dev/null
if cmp -s "$W/datei.in" "$W/rahmen.out" && [ "$(cat "$W/blatt.out")" = "$(cat "$W/blatt.in")" ] && [ "$(cat "$W/gesetzt.out")" = 1 ]; then
  pass B.rahmen-blatt-und-datei; else fail B.rahmen-blatt-und-datei "Datei oder Blatt verändert"; fi
{ printf 'sheet\n'; base64 < "$W/datei.in"; } > "$W/rahmen2.in"
if ( _bkp_read_in_stdin "$W/rahmen2.out" < "$W/rahmen2.in"; [ -z "$_BKP_SHEET" ] && [ "$_BKP_SHEET_SET" = 1 ] && cmp -s "$W/datei.in" "$W/rahmen2.out" ) 2>/dev/null; then
  pass B.rahmen-ohne-blatt; else fail B.rahmen-ohne-blatt "leeres Blatt nicht erkannt"; fi
eq B.rahmen-falsche-form '{"ok":false,"code":"unreadable"}' "$( ( _BKP_JSON=1; printf 'kaputt\n' | _bkp_read_in_stdin "$W/x.out" ) 2>/dev/null )"
# Feste Codes: JSON-Modus = genau ein Objekt auf stdout, weitere Felder; Hintergrund-Lauf merkt den Grund in backup.state.
eq B.code-json '{"ok":false,"code":"key_line","line":3}' "$( ( _BKP_JSON=1; _bkp_rdie key_line 'Zeile 3' --argjson line 3 ) 2>/dev/null )"
_bst2="$W/rs.state"; rm -f "$_bst2"
( BACKUP_STATE_FILE="$_bst2"; _BKP_CHILD=1; _BKP_JSON=0; _bkp_rdie busy 'belegt' ) >/dev/null 2>&1
eq B.code-im-hintergrund busy "$(read_env_value "$_bst2" LAST_RESTORE_REASON)"
# Stand des Hintergrund-Laufs: ok/fail nach dem Start, running solange die Restore-Sperre gehalten wird, sonst unfinished.
_rs() { ( BACKUP_STATE_FILE="$_bst2"; BACKUP_RESTORE_LOCK="$W/restore.lock"; backup_cmd_restore_status --json ) 2>/dev/null | jq -r '.state + ":" + (.code // "")'; }
rm -f "$_bst2"; eq B.stand-leer 'idle:' "$(_rs)"
env_upsert "$_bst2" LAST_RESTORE_START 200; env_upsert "$_bst2" LAST_RESTORE_FAIL 150
eq B.stand-abgebrochen 'unfinished:' "$(_rs)"
_lauf="$( exec 8>>"$W/restore.lock"; flock -n 8; _rs )"; eq B.stand-laeuft 'running:' "$_lauf"
env_upsert "$_bst2" LAST_RESTORE_FAIL 210; env_upsert "$_bst2" LAST_RESTORE_REASON version_older
eq B.stand-fehler 'fail:version_older' "$(_rs)"
env_upsert "$_bst2" LAST_RESTORE_OK 220
eq B.stand-ok 'ok:' "$(_rs)"
# Rechner-Pfade: Windows-Schreibweise geht als Docker-Form an Docker (Docker Desktop/WSL2), Anzeige bleibt beim Nutzer.
eq B.windows-pfad-docker '/run/desktop/mnt/host/c/Daten/OneDrive/Life Agents Sicherungen' "$(_bkp_hd 'C:\Daten\OneDrive\Life Agents Sicherungen\')"
eq B.windows-schraegstrich '/run/desktop/mnt/host/d/Sicherung' "$(_bkp_hd 'D:/Sicherung')"
eq B.mac-pfad-unveraendert '/Users/erika/Library/Mobile Documents/com~apple~CloudDocs' "$(_bkp_hd '/Users/erika/Library/Mobile Documents/com~apple~CloudDocs/')"
eq B.join-windows 'C:\Daten\Life Agents Sicherungen' "$(_bkp_join 'C:\Daten' 'Life Agents Sicherungen')"
eq B.join-mac '/Users/erika/Life Agents Sicherungen' "$(_bkp_join '/Users/erika/' 'Life Agents Sicherungen')"
for d in 'C:\Daten' 'c:/Daten'; do if _bkp_host_dir_valid "$d"; then pass "B.windows-gueltig:$d"; else fail "B.windows-gueltig:$d" abgelehnt; fi; done
for d in 'C:relativ' 'C:\a,b' '\\server\freigabe'; do if _bkp_host_dir_valid "$d"; then fail "B.windows-ungueltig:$d" angenommen; else pass "B.windows-ungueltig:$d"; fi; done
: > "$STUB_LOG"
if rt_host_mkdir /Users/erika 'a/b'; then fail B.unterordner-nur-name "Pfad angenommen"; elif [ -s "$STUB_LOG" ]; then fail B.unterordner-nur-name "Container gestartet"; else pass B.unterordner-nur-name; fi
# Chat-Hinweis: erst nach 2 Tagen ohne gelungene Sicherung, dann hoechstens alle 20 h.
(
  BACKUP_STATE_FILE="$W/bstate"; : > "$BACKUP_STATE_FILE"; BACKUP_NOTIFY_HOURS=00-23
  notify_owner_telegram() { printf 'x\n' >> "$W/notified"; }
  : > "$W/notified"
  env_upsert "$BACKUP_STATE_FILE" LAST_OK "$(( $(date +%s) - 3600 ))"; _bkp_stale_notify
  a="$(wc -l < "$W/notified")"
  env_upsert "$BACKUP_STATE_FILE" LAST_OK "$(( $(date +%s) - 3 * 86400 ))"; env_upsert "$BACKUP_STATE_FILE" LAST_FAIL_REASON folder
  _bkp_stale_notify; b="$(wc -l < "$W/notified")"
  _bkp_stale_notify; c="$(wc -l < "$W/notified")"
  env_upsert "$BACKUP_STATE_FILE" LAST_NOTIFY "$(( $(date +%s) - 21 * 3600 ))"; _bkp_stale_notify; d="$(wc -l < "$W/notified")"
  printf '%s %s %s %s\n' "$a" "$b" "$c" "$d"
) > "$W/notify.out" 2>&1
eq B.hinweis-nach-2-tagen-alle-20h '0 1 1 2' "$(tail -n1 "$W/notify.out")"
# Nachts kein Hinweis (Takt 03:30), ohne Ordner nur woechentlich; Eingabe-Bereinigung; Grund-Code je Ordner-Problem.
(
  BACKUP_STATE_FILE="$W/bstate2"; : > "$BACKUP_STATE_FILE"
  notify_owner_telegram() { printf 'x\n' >> "$W/notified2"; }
  : > "$W/notified2"
  env_upsert "$BACKUP_STATE_FILE" LAST_OK "$(( $(date +%s) - 3 * 86400 ))"
  h="$(TZ=Europe/Berlin date +%H)"; nh="$(printf '%02d-%02d' $(( (10#$h + 1) % 24 )) $(( (10#$h + 1) % 24 )))"
  BACKUP_NOTIFY_HOURS="$nh" _bkp_stale_notify; a="$(wc -l < "$W/notified2")"
  env_upsert "$BACKUP_STATE_FILE" LAST_FAIL_REASON nofolder
  env_upsert "$BACKUP_STATE_FILE" LAST_NOTIFY "$(( $(date +%s) - 2 * 86400 ))"
  BACKUP_NOTIFY_HOURS=00-23 _bkp_stale_notify; b="$(wc -l < "$W/notified2")"
  env_upsert "$BACKUP_STATE_FILE" LAST_NOTIFY "$(( $(date +%s) - 8 * 86400 ))"
  BACKUP_NOTIFY_HOURS=00-23 _bkp_stale_notify; c="$(wc -l < "$W/notified2")"
  printf '%s %s %s\n' "$a" "$b" "$c"
) > "$W/notify2.out" 2>&1
eq B.hinweis-nur-tagsueber-ohne-ordner-woechentlich '0 0 1' "$(tail -n1 "$W/notify2.out")"
eq B.pfad-anfuehrungszeichen 'C:\Daten\OneDrive' "$(_bkp_path_clean '  "C:\Daten\OneDrive"  ')"
eq B.pfad-leerzeichen '/Users/erika/Meine Sicherung' "$(_bkp_path_clean ' /Users/erika/Meine Sicherung ')"
eq B.grund-je-problem 'folder folder write' "$(_bkp_reason_of missing) $(_bkp_reason_of access) $(_bkp_reason_of readonly)"
eq B.kennung-alter-name '' "$(_bkp_file_key_id lifeagents-backup-20261001033000.nla.enc)"

# ---------------------------------------------------------------------------- D: Entfernen (Pruefliste Nr. 17, stack.sh)
unset LIFEAGENTS_RUNTIME
# Der Kern laeuft als eigener Container (LA_CORE=1, eigenes Abbild aus <projekt>-core); Abbild-Namen liest er aus compose.yml.
SC_SELFIMG=reg.example/master@sha256:aaaa
SC_CFG="$(jq -cn --arg m "$SC_SELFIMG" '{services:{anchor:{image:"busybox:t",container_name:"lifeagents-anchor"},
  postgres:{image:"postgres:t",container_name:"lifeagents-postgres"},master:{image:$m,container_name:"lifeagents-master"},
  edge:{image:"caddy:t",container_name:"lifeagents-edge"},tailscale:{image:"ts:t",container_name:"lifeagents-tailscale"}}}')"
# real-path-test: genericity.yml compose-stack-cold/-ops fahren dieselben Verben im echten Docker (Kern per docker run).
core() {
  ( cd "$W" && env -u LA_EDGE_PORT -u LA_WIZARD_PORT -u LA_PG_SUPERPW -u LA_PROBE_IMAGE -u LIFEAGENTS_RUNTIME \
      LA_CORE="${SC_CORE-1}" LA_PROJECT=lifeagents STUB_IMG_lifeagents_core="$SC_SELFIMG" STUB_CONFIG_JSON="$SC_CFG" \
      RELEASE_TAG="${SC_REL:-v9.0.0}" bash "$ROOT/provisioning/compose/stack.sh" "$@" )
}
dst() { : > "$STUB_LOG"; core uninstall "$@" >/dev/null 2>&1; }
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
if _out="$(STUB_VOL_LABEL=lifeagents STUB_FAIL='|volume|rm|lifeagents_pgdata' core uninstall --delete-data 2>&1)"; then fail D.rm-fehler-abbruch "Exit 0"; else pass D.rm-fehler-abbruch; fi
case "$_out" in *Label*) fail D.rm-fehler-wahrer-grund "meldet Label: $_out" ;; *"Daemon-Fehler"*) pass D.rm-fehler-wahrer-grund ;; *) fail D.rm-fehler-wahrer-grund "Grund fehlt: $_out" ;; esac
if STUB_VOL_LABEL=fremd dst --delete-data; then fail D.fremdes-label-abbruch "Exit 0"; else pass D.fremdes-label-abbruch; fi
eq D.fremdes-label-unberuehrt 0 "$(grep -c '^docker|volume|rm|' "$STUB_LOG")"
if grep -qE 'prune|\|-v\||--volumes|--rmi|\|-a\||--all' "$STUB_LOG"; then fail D.nie-breit "$(grep -E 'prune|-v|--rmi' "$STUB_LOG" | head -1)"; else pass D.nie-breit; fi
if STUB_RUNNING=lifeagents-swap dst; then fail D.nicht-waehrend-wechsel "Exit 0"; else pass D.nicht-waehrend-wechsel; fi
if grep -q '|down|' "$STUB_LOG"; then fail D.waehrend-wechsel-unberuehrt "down lief"; else pass D.waehrend-wechsel-unberuehrt; fi

# ---------------------------------------------------------------------------- SC: Kern (lib/stack_core.sh, stack <verb> --json)
# Nur Logik, die der echte Weg schwer erzwingt (Werte-Quellen, Ports, Weitergabe, JSON-Vertrag); ob Docker dabei wirklich
# anlegt und startet, belegt erst genericity.yml.
SCO="$W/sc.out"; SCE="$W/sc.err"
scr() { : > "$STUB_LOG"; : > "${STUB_LOG}.put"; : > "${STUB_LOG}.vols"; rm -f "${STUB_LOG}.failn"; SC_RC=0; core "$@" >"$SCO" 2>"$SCE" || SC_RC=$?; }
res() { tail -n1 "$SCO" | jq -r "$1" 2>/dev/null; }
put_of() { awk -v f="== $1" '$0 == f {on=1; next} /^== /{on=0} on' "${STUB_LOG}.put"; }
_lp="lifeagents_"
SC_ALLVOLS="$(for v in $LA_STATE_VOLUMES; do printf '%s%s ' "$_lp" "$v"; done)"
SC_STORED=$'LA_EDGE_PORT=5890\nLA_WIZARD_PORT=5891\nLA_PG_SUPERPW=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nLA_TS_HOSTNAME=calm-otter'

# Gruende: jede Stelle im Kern nennt nur Gruende der geschlossenen Liste; ein fremder Grund wird internal.
_reasons="$(sed -n 's/^SC_REASONS="\(.*\)"$/\1/p' "$ROOT/provisioning/lib/stack_core.sh")"
_used="$(grep -oE '(sc_fail|_sc_chk [a-z]+) [a-z_]+' "$ROOT/provisioning/lib/stack_core.sh" | awk '{print $NF}' | grep -vxE 'sc_fail|r|reason' | sort -u)"
_bad=''; for r in $_used; do case " $_reasons " in *" $r "*) ;; *) _bad="$_bad $r" ;; esac; done
eq SC.gruende-geschlossen '' "${_bad# }"
[ "$(wc -w <<<"$_reasons")" -ge 20 ] && pass SC.gruende-liste-lesbar || fail SC.gruende-liste-lesbar "$_reasons"
_ub="$( ( . "$ROOT/provisioning/lib/stack_core.sh"; exec {SC_OUT}>&1; SC_VERB=up SC_JSON=1; sc_fail erfunden "x" ) 2>/dev/null | jq -r .reason)"
eq SC.fremder-grund-internal internal "$_ub"

# Erster Lauf auf leerem Docker: Werte neu, im Volume abgelegt; stdout nur JSON-Zeilen mit v 1, genau ein result am Ende.
STUB_VOLS='' STUB_RUNNING=lifeagents-master scr up --json
eq SC.up-leer-ok 'true|0' "$(res .ok)|$SC_RC"
_nj="$(grep -cv '^{' "$SCO")"; _nv="$(jq -s '[.[] | select(.v != 1)] | length' "$SCO")"; _nr="$(jq -s '[.[] | select(.type == "result")] | length' "$SCO")"
eq SC.nur-json-zeilen '0|0|1' "$_nj|$_nv|$_nr"
eq SC.schritte-up 'lock delegate check values volumes start done' "$(jq -r 'select(.type == "progress") | .step' "$SCO" | tr '\n' ' ' | sed 's/ $//')"
_pw="$(put_of /var_la/stack.env | sed -n 's/^LA_PG_SUPERPW=//p')"
[[ "$_pw" =~ ^[0-9a-f]{64}$ ]] && pass SC.passwort-neu-64-hex || fail SC.passwort-neu-64-hex "'$_pw'"
eq SC.ports-neu '5880|5881|5880|5881' "$(put_of /var_la/stack.env | sed -n 's/^LA_EDGE_PORT=//p')|$(put_of /var_la/stack.env | sed -n 's/^LA_WIZARD_PORT=//p')|$(res .ports.edge)|$(res .ports.wizard)"
[[ "$(put_of /var_la/stack.env | sed -n 's/^LA_TS_HOSTNAME=//p')" =~ ^[a-z]+-[a-z]+$ ]] && pass SC.ts-name-gezogen || fail SC.ts-name-gezogen "$(put_of /var_la/stack.env)"
if [ -n "$_pw" ] && ! grep -qF "$_pw" "$SCO" "$SCE"; then pass SC.passwort-nie-in-ausgabe; else fail SC.passwort-nie-in-ausgabe "Passwort in stdout/stderr"; fi
if [ -n "$_pw" ] && grep -qF "$_pw" "$STUB_LOG"; then fail SC.passwort-nie-im-argv "steht in einem docker-Aufruf"; else pass SC.passwort-nie-im-argv; fi
# Volumes vor dem ersten Schreiben: kein Lese-/Schreib-Container auf ein Volume, das noch nicht angelegt ist.
_first_put="$(grep -n '^docker|run|--rm|-i|.*lifeagents_var_la' "$STUB_LOG" | head -n1 | cut -d: -f1)"
_create="$(grep -n '^docker|volume|create|.*|lifeagents_var_la|' "$STUB_LOG" | head -n1 | cut -d: -f1)"
[ -n "$_first_put" ] && [ -n "$_create" ] && [ "$_create" -lt "$_first_put" ] && pass SC.volume-vor-werten || fail SC.volume-vor-werten "create=$_create put=$_first_put"
if put_of /var_la/core-foreign-images | grep -q .; then pass SC.merkliste-erster-lauf; else fail SC.merkliste-erster-lauf "keine Merkliste"; fi
grep -qF "|up|-d|--wait|--wait-timeout|180|anchor|postgres|master|edge|" "$STUB_LOG" && pass SC.up-wartet || fail SC.up-wartet "$(grep '|up|' "$STUB_LOG")"
grep -q "^docker|compose|.*|up|" "$STUB_LOG" && grep -q 'reg.example/master@sha256:aaaa' "${STUB_LOG}.env" && pass SC.master-eigenes-abbild || fail SC.master-eigenes-abbild "$(cat "${STUB_LOG}.env")"

# Gespeicherte Werte bleiben: kein Schreiben, Ports wie gespeichert.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_stack_env="$SC_STORED" STUB_RUNNING=lifeagents-master scr up --json
eq SC.werte-bleiben '5890|5891|' "$(res .ports.edge)|$(res .ports.wizard)|$(put_of /var_la/stack.env)"
if put_of /var_la/core-foreign-images | grep -q . || grep -q '^== /var_la/core-foreign-images' "${STUB_LOG}.put"; then fail SC.merkliste-nur-erster-lauf "neu geschrieben"; else pass SC.merkliste-nur-erster-lauf; fi

# Bestand der Start-App: keine Werte-Datei, aber ein master -> seine Umgebung wird uebernommen (kein neues Passwort).
STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING="lifeagents-master lifeagents-postgres" STUB_IMG_lifeagents_master="$SC_SELFIMG" STUB_RUNNING=lifeagents-master \
  STUB_MASTER_ENV=$'LA_EDGE_PORT=5884\nLA_WIZARD_PORT=5885\nLA_PG_SUPERPW=feedfacefeedfacefeedfacefeedface\nLA_TS_HOSTNAME=bot' scr up --json
eq SC.bestand-uebernommen 'LA_EDGE_PORT=5884 LA_WIZARD_PORT=5885 LA_PG_SUPERPW=feedfacefeedfacefeedfacefeedface LA_TS_HOSTNAME=bot' "$(put_of /var_la/stack.env | tr '\n' ' ' | sed 's/ $//')"
if grep -qF feedface "$SCO" "$SCE"; then fail SC.bestand-passwort-nie-in-ausgabe "steht in der Ausgabe"; else pass SC.bestand-passwort-nie-in-ausgabe; fi

# Datenbank da (initialisiert), Passwort nirgends -> values_lost, nichts angelegt.
STUB_VOLS="${_lp}pgdata" STUB_CAT__pgdata_PG_VERSION=17 scr up --json
eq SC.werte-verloren 'values_lost|1' "$(res .reason)|$SC_RC"
if grep -v 'lifeagents_probe' "$STUB_LOG" | grep -q '|volume|create|\||up|' || [ -s "${STUB_LOG}.put" ]; then fail SC.werte-verloren-nichts-geaendert "$(grep -E 'create|\|up\|' "$STUB_LOG" | head -1)"; else pass SC.werte-verloren-nichts-geaendert; fi
# Abbruch eines ersten Laufs nach dem Anlegen der Volumes: leeres pgdata ist keine Datenbank -> neue Werte, kein Abbruch.
STUB_VOLS="${_lp}pgdata" STUB_RUNNING=lifeagents-master scr up --json
eq SC.leeres-pgdata-neu 'true|64' "$(res .ok)|$(put_of /var_la/stack.env | sed -n 's/^LA_PG_SUPERPW=//p' | tr -d '\n' | wc -c | tr -d ' ')"
# Werte liegen ab, bevor pgdata entsteht (ein Abbruch dazwischen liesse sonst eine Datenbank ohne Passwort zurueck).
STUB_VOLS='' STUB_RUNNING=lifeagents-master scr up --json
_pg="$(grep -n '^docker|volume|create|.*|lifeagents_pgdata|' "$STUB_LOG" | head -n1 | cut -d: -f1)"
_vp="$(grep -n '^docker|run|--rm|-i|.*lifeagents_var_la' "$STUB_LOG" | head -n1 | cut -d: -f1)"
[ -n "$_pg" ] && [ -n "$_vp" ] && [ "$_vp" -lt "$_pg" ] && pass SC.werte-vor-pgdata || fail SC.werte-vor-pgdata "put=$_vp pgdata=$_pg"
# Tailscale-Knoten schon da -> sein Name bleibt (bot), nie neu gezogen.
STUB_VOLS="${_lp}ts_state" STUB_RUNNING=lifeagents-master scr up --json
eq SC.ts-bestand-bot bot "$(put_of /var_la/stack.env | sed -n 's/^LA_TS_HOSTNAME=//p')"

# Ports: belegt ohne Container -> neu gesucht; belegt mit Container -> bleibt; nichts frei -> port_none_free.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_stack_env="$SC_STORED" STUB_BUSY_PORTS='5890 5880' STUB_RUNNING=lifeagents-master scr up --json
eq SC.port-belegt-neu '5881|5891' "$(res .ports.edge)|$(res .ports.wizard)"
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_stack_env="$SC_STORED" STUB_BUSY_PORTS='5890' STUB_EXISTING=lifeagents-edge STUB_RUNNING=lifeagents-master scr up --json
eq SC.port-mit-container-bleibt '5890|' "$(res .ports.edge)|$(put_of /var_la/stack.env)"
STUB_VOLS='' STUB_BUSY_PORTS="$(seq -s ' ' 5880 5899)" scr up --json
eq SC.port-keiner-frei 'port_none_free|1' "$(res .reason)|$SC_RC"
# Test-Verbund neben einer echten Installation: eigene Spanne.
LA_CORE_PORTS=57200-57299 STUB_BUSY_PORTS=57200 STUB_VOLS='' STUB_RUNNING=lifeagents-master scr up --json
eq SC.port-spanne '57201|57202' "$(res .ports.edge)|$(res .ports.wizard)"

# Weitergabe: master mit anderem Abbild und Kern-Etikett -> genau ein Kurzlauf dieses Abbilds, selbst nichts angelegt.
OTHER=reg.example/master@sha256:bbbb
STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING=lifeagents-master STUB_IMG_lifeagents_master="$OTHER" STUB_CORE_IMAGES="$OTHER" scr up --json
_d="$(grep -c '^docker|run|--rm|-i|--name|lifeagents-core-next|' "$STUB_LOG")"
eq SC.weitergabe-ein-lauf "1|0" "$_d|$SC_RC"
grep '^docker|run|--rm|-i|--name|lifeagents-core-next|' "$STUB_LOG" | grep -qF "|LA_CORE_DELEGATED=$SC_SELFIMG|" \
  && grep '^docker|run|--rm|-i|--name|lifeagents-core-next|' "$STUB_LOG" | grep -qF "|$OTHER|stack|up|--json|" \
  && pass SC.weitergabe-aufruf || fail SC.weitergabe-aufruf "$(grep core-next "$STUB_LOG")"
if grep -qE '\|volume\|create\||\|up\|-d\|' "$STUB_LOG"; then fail SC.weitergabe-selbst-nichts "$(grep -E 'create|\|up\|' "$STUB_LOG" | head -1)"; else pass SC.weitergabe-selbst-nichts; fi
if grep -q '"type":"result"' "$SCO"; then fail SC.weitergabe-ein-ergebnis "der aeussere Kern schrieb ein eigenes result"; else pass SC.weitergabe-ein-ergebnis; fi
# Die Weitergabe nimmt die Test-Weichen mit (als Name); sonst liefe ein install im inneren Kern still gegen echte Dienste.
LIFEAGENTS_TELEGRAM_API=http://127.0.0.1:8089 LA_FREMD=1 STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING=lifeagents-master STUB_IMG_lifeagents_master="$OTHER" \
  STUB_CORE_IMAGES="$OTHER" scr install --json </dev/null
_cn="$(grep '^docker|run|--rm|-i|--name|lifeagents-core-next|' "$STUB_LOG")"
case "$_cn" in *'|--env|LIFEAGENTS_TELEGRAM_API|'*) case "$_cn" in *LA_FREMD*|*127.0.0.1:8089*) fail SC.weitergabe-weichen "$_cn" ;; *) pass SC.weitergabe-weichen ;; esac ;;
  *) fail SC.weitergabe-weichen "$_cn" ;; esac
STUB_DELEGATE_RC=1 STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING=lifeagents-master STUB_IMG_lifeagents_master="$OTHER" STUB_CORE_IMAGES="$OTHER" scr up --json
eq SC.weitergabe-exit-durchgereicht 1 "$SC_RC"
# Kein Kern-Etikett (Stand vor dem Kern) -> legacy_installation, keine Weitergabe; start/status gehen weiter.
STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING=lifeagents-master STUB_IMG_lifeagents_master="$OTHER" scr up --json
eq SC.legacy-up 'legacy_installation|0' "$(res .reason)|$(grep -c '^docker|run|.*core-next' "$STUB_LOG")"
STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING=lifeagents-master STUB_IMG_lifeagents_master="$OTHER" scr status --json
eq SC.legacy-status-geht 'true|0' "$(res .ok)|$(res .core)"
# Entfernen haengt nicht an den Pins: auch eine Installation von vor dem Kern laesst sich abbauen.
STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING=lifeagents-master STUB_IMG_lifeagents_master="$OTHER" scr uninstall --json
eq SC.legacy-uninstall-geht "true|1|0" "$(res .ok)|$(grep -c '|down|' "$STUB_LOG")|$(grep -c '^docker|run|.*core-next' "$STUB_LOG")"
# Schon weitergegeben -> keine zweite Weitergabe.
LA_CORE_DELEGATED="$SC_SELFIMG" STUB_IMG_lifeagents_core_next="$SC_SELFIMG" STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING=lifeagents-master \
  STUB_IMG_lifeagents_master="$OTHER" STUB_CORE_IMAGES="$OTHER" scr up --json
eq SC.keine-zweite-weitergabe 'internal|0' "$(res .reason)|$(grep -c '^docker|run|.*core-next' "$STUB_LOG")"
# Daten einer neueren Fassung ohne master -> newer_installation.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__rt_tree_VERSION=v9.5.0 scr up --json
eq SC.neuere-installation newer_installation "$(res .reason)"
# Daten einer aelteren Fassung ohne master -> older_installation (die eigenen Pins liefen sonst ohne Sicherung ueber alten Daten).
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__rt_tree_VERSION=v8.9.0 scr up --json
eq SC.aeltere-installation 'older_installation|0' "$(res .reason)|$(grep -c '|up|-d|' "$STUB_LOG")"

# Unerwarteter Abbruch (die in einem Helfer) -> trotzdem genau ein result mit internal und der letzten Meldung.
STUB_VOLS='' STUB_FAIL='|volume|create|--label|io.lifeagents.install=lifeagents|lifeagents_pgdata' scr up --json
eq SC.abbruch-internal "internal|1|1" "$(res .reason)|$(jq -s '[.[] | select(.type == "result")] | length' "$SCO")|$SC_RC"
case "$(res .detail)" in *anlegen*) pass SC.abbruch-detail ;; *) fail SC.abbruch-detail "$(res .detail)" ;; esac
# Nicht als Kern gestartet (z. B. docker exec im master) -> in_master, nichts angelegt.
SC_CORE='' STUB_VOLS='' scr up --json
eq SC.nicht-im-master "in_master|0" "$(res .reason)|$(grep -c 'volume|create' "$STUB_LOG")"
# Ohne --json: stdout leer.
STUB_VOLS='' STUB_RUNNING=lifeagents-master scr up
eq SC.ohne-json-stdout-leer "0|0" "$(wc -c < "$SCO" | tr -d ' ')|$SC_RC"
# Falscher Aufruf: Exit 2, kein JSON.
scr up --json --gibtsnicht
eq SC.aufruf-falsch "2|0" "$SC_RC|$(wc -c < "$SCO" | tr -d ' ')"

# check: je Pruefung ok/reason; Pruef-Volume danach weg; Arbeitsspeicher nur Warnung.
STUB_VOLS='' scr check --json
eq SC.check-gruen 'true|docker,linux,engine,subpath,socket,disk' "$(res .ok)|$(res '[.checks[].id] | join(",")')"
eq SC.check-pruef-volume-weg '1|1' "$(grep -c '^docker|volume|create|.*|lifeagents_probe|' "$STUB_LOG")|$(grep -c '^docker|volume|rm|lifeagents_probe|' "$STUB_LOG")"
STUB_VOLS='' STUB_SRV_VERSION=25.0.5 scr check --json
eq SC.check-engine-alt 'docker_too_old|false' "$(res .reason)|$(res '.checks[] | select(.id == "engine") | .ok')"
STUB_VOLS='' STUB_SRV_OS=windows scr check --json;  eq SC.check-windows docker_windows_mode "$(res .reason)"
STUB_VOLS='' STUB_DF_KB=1000 scr check --json;      eq SC.check-platz disk_low "$(res .reason)"
STUB_VOLS='' STUB_MEM=2000000000 scr check --json;  eq SC.check-speicher-warnung 'true|memory_low' "$(res .ok)|$(res '.warnings | join(",")')"
STUB_VOLS='' STUB_FAIL='|cat|/r/f' scr check --json; eq SC.check-unterpfad docker_capability "$(res .reason)"
STUB_FAIL='|version|' scr check --json;             eq SC.check-docker-aus 'docker_unreachable|false' "$(res .reason)|$(res '.checks[0].ok')"

# uninstall --delete-data: Abbilder laut compose.yml ausser der Merkliste; belegtes Abbild bleibt (kept).
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_core_foreign_images='postgres:t' STUB_RUNNING=lifeagents-master scr uninstall --delete-data --json
eq SC.abbau-abbilder "busybox:t caddy:t $SC_SELFIMG ts:t" "$(grep '^docker|image|rm|' "$STUB_LOG" | cut -d'|' -f4 | sort | tr '\n' ' ' | sed 's/ $//')"
grep -q '^docker|exec|lifeagents-master|lifeagents|telegram|release-webhook|' "$STUB_LOG" && pass SC.abbau-webhook-zuerst || fail SC.abbau-webhook-zuerst "kein release-webhook"
_wh="$(grep -n 'release-webhook' "$STUB_LOG" | head -n1 | cut -d: -f1)"; _dn="$(grep -n '|down|' "$STUB_LOG" | head -n1 | cut -d: -f1)"
[ -n "$_wh" ] && [ -n "$_dn" ] && [ "$_wh" -lt "$_dn" ] && pass SC.abbau-webhook-vor-down || fail SC.abbau-webhook-vor-down "webhook=$_wh down=$_dn"
eq SC.abbau-schritte 'lock webhook containers volumes images done' "$(jq -r 'select(.type == "progress") | .step' "$SCO" | tr '\n' ' ' | sed 's/ $//')"
# Ohne Merkliste (Bestand der Start-App, oder var_la schon geloescht) weiss der Kern nicht, was vorher da war: kein Abbild.
STUB_VOLS="${_lp}pgdata" scr uninstall --delete-data --json
eq SC.abbau-ohne-merkliste-keine-abbilder 'true|0' "$(res .ok)|$(grep -c '^docker|image|rm|' "$STUB_LOG")"
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_core_foreign_images='fremd:x' STUB_FAIL='|image|rm|caddy:t' scr uninstall --delete-data --json
eq SC.abbau-abbild-belegt 'true|image_in_use' "$(res .ok)|$(res '.kept[] | select(.what == "caddy:t") | .reason')"

# status (auch im master per docker exec, ohne LA_CORE): Felder.
SC_CORE='' LA_MASTER_IMAGE="$SC_SELFIMG" STUB_VOLS="${_lp}pgdata ${_lp}rt_tree" STUB_CAT__rt_tree_VERSION=v9.0.0 scr status --json
eq SC.status-felder 'true|false|v9.0.0|false' "$(res .installed)|$(res .running)|$(res .version)|$(res .update_running)"
STUB_RUNNING=lifeagents-swap STUB_VOLS='' scr status --json
eq SC.status-update-laeuft true "$(res .update_running)"
STUB_VOLS="${_lp}pgdata" STUB_FAIL='|ps|--format|' scr status --json
eq SC.status-ps-fehler-leere-liste 'true|0' "$(res .ok)|$(res '.services | length')"
# install: nur die Test-Weichen der Positivliste (SC_TEST_SWITCHES) gehen an provision.sh, als Name (-e NAME, Wert aus der
# Umgebung des Kerns, nie in einer Befehlszeile); andere Variablen, auch gesperrte LIFEAGENTS_*, kommen nie durch.
SC_TEST_SWITCHES_EXP='LIFEAGENTS_TELEGRAM_API LIFEAGENTS_LLM_UPSTREAM'
eq SC.weichen-liste "$SC_TEST_SWITCHES_EXP" "$(sed -n 's/^SC_TEST_SWITCHES="\(.*\)"$/\1/p' "$ROOT/provisioning/lib/stack_core.sh")"
LIFEAGENTS_TELEGRAM_API=http://127.0.0.1:8089 LIFEAGENTS_LLM_UPSTREAM=http://127.0.0.1:8088 LIFEAGENTS_DIR=/fremd \
  LIFEAGENTS_RESULT_FILE=/fremd/r LA_FREMD=1 FREMD_WEICHE=x STUB_VOLS="$SC_ALLVOLS" STUB_RUNNING=lifeagents-master \
  scr install --json -- --profile dev </dev/null
_px="$(grep '^docker|exec|.*provision\.sh' "$STUB_LOG")"
eq SC.install-ok 'true|0' "$(res .ok)|$SC_RC"
case "$_px" in *'|exec|-e|LIFEAGENTS_TELEGRAM_API|-e|LIFEAGENTS_LLM_UPSTREAM|lifeagents-master|bash|'*'|--profile|dev|'*) pass SC.install-weichen-durch ;;
  *) fail SC.install-weichen-durch "$_px" ;; esac
case "$_px" in *LIFEAGENTS_DIR*|*RESULT_FILE*|*LA_FREMD*|*FREMD_WEICHE*) fail SC.install-fremdes-nie "$_px" ;; *) pass SC.install-fremdes-nie ;; esac
if grep -qF '127.0.0.1:808' "$STUB_LOG"; then fail SC.install-wert-nie-im-argv "$(grep -F '127.0.0.1:808' "$STUB_LOG" | head -1)"; else pass SC.install-wert-nie-im-argv; fi
LIFEAGENTS_TELEGRAM_API='' STUB_VOLS="$SC_ALLVOLS" STUB_RUNNING=lifeagents-master scr install --json </dev/null
_px="$(grep '^docker|exec|.*provision\.sh' "$STUB_LOG")"
case "$_px" in *'|-e|'*|'') fail SC.install-ohne-weichen "ok=$(res .ok) provision: $_px" ;; *) pass SC.install-ohne-weichen ;; esac
# setup.sh ist oeffentlich: eine liegengebliebene Weiche mit fremdem Ziel darf nie Bot-Aufrufe umleiten. Nur
# http://127.0.0.1:<port> geht durch, alles andere faellt mit Warnung weg (Wert nie in der Meldung).
LIFEAGENTS_TELEGRAM_API=https://fremd.example LIFEAGENTS_LLM_UPSTREAM=http://127.0.0.1:8088 STUB_VOLS="$SC_ALLVOLS" STUB_RUNNING=lifeagents-master \
  scr install --json </dev/null
_px="$(grep '^docker|exec|.*provision\.sh' "$STUB_LOG")"
case "$_px" in *LIFEAGENTS_TELEGRAM_API*|'') fail SC.install-fremdes-ziel-faellt-weg "$_px" ;; *'|-e|LIFEAGENTS_LLM_UPSTREAM|'*) pass SC.install-fremdes-ziel-faellt-weg ;; *) fail SC.install-fremdes-ziel-faellt-weg "$_px" ;; esac
if grep -q 'LIFEAGENTS_TELEGRAM_API' "$SCE" && ! grep -qF 'fremd.example' "$SCE"; then pass SC.install-fremdes-ziel-warnung; else fail SC.install-fremdes-ziel-warnung "$(cat "$SCE")"; fi
# start: ohne Installation not_installed; nur vorhandene, stehende Container.
STUB_VOLS='' scr start --json;  eq SC.start-ohne-installation not_installed "$(res .reason)"
STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING='lifeagents-anchor lifeagents-edge' STUB_RUNNING=lifeagents-anchor scr start --json
grep -q '^docker|compose|.*|start|edge|stdin=$' "$STUB_LOG" && pass SC.start-nur-vorhandene || fail SC.start-nur-vorhandene "$(grep '|start|' "$STUB_LOG")"
if grep -q '|up|' "$STUB_LOG"; then fail SC.start-legt-nichts-an "up lief"; else pass SC.start-legt-nichts-an; fi
# Sperre: offener master-Wechsel bei laufendem master (sein Tick schliesst ihn ab) -> busy vor jeder Aenderung.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state='PHASE=handoff' STUB_RUNNING=lifeagents-master scr up --json
eq SC.wechsel-offen-busy 'busy|0' "$(res .reason)|$(grep -c 'volume|create' "$STUB_LOG")"
# Offene Datei ohne laufenden master (Wechsel endete in rollback_failed): kein Tick schliesst sie je -> kein busy,
# sonst liesse sich der Verbund weder starten noch entfernen.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state='PHASE=rollback_failed' scr uninstall --json
eq SC.wechsel-ohne-master-entfernbar 'true|1' "$(res .ok)|$(grep -c '|down|' "$STUB_LOG")"
# Laufender, aber kaputter master mit offener Datei (kein Tick schliesst sie): Entfernen geht trotzdem; nur ein laufender
# Helfer sperrt den Abbau. Anlegen/Starten bleibt gesperrt (der Tick koennte noch abschliessen).
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state='PHASE=rollback_failed' STUB_RUNNING=lifeagents-master scr uninstall --json
eq SC.wechsel-kaputter-master-entfernbar 'true|1' "$(res .ok)|$(grep -c '|down|' "$STUB_LOG")"
STUB_VOLS="$SC_ALLVOLS" STUB_RUNNING='lifeagents-master lifeagents-swap' scr uninstall --json
eq SC.helfer-laeuft-abbau-busy 'busy|0' "$(res .reason)|$(grep -c '|down|' "$STUB_LOG")"
# Frische Uebergabe (Helfer startet gleich): auch der Abbau wartet; eine alte, haengen gebliebene nicht.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state="PHASE=handoff
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)" STUB_RUNNING=lifeagents-master scr uninstall --json
eq SC.frische-uebergabe-abbau-busy 'busy|0' "$(res .reason)|$(grep -c '|down|' "$STUB_LOG")"
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state=$'PHASE=handoff\nSTARTED=2026-01-01T00:00:00Z' STUB_RUNNING=lifeagents-master scr uninstall --json
eq SC.alte-uebergabe-abbau-geht 'true|1' "$(res .ok)|$(grep -c '|down|' "$STUB_LOG")"
# Unbekanntes Alter zaehlt als frisch.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state='PHASE=handoff' STUB_RUNNING=lifeagents-master scr uninstall --json
eq SC.uebergabe-ohne-zeit-busy 'busy|0' "$(res .reason)|$(grep -c '|down|' "$STUB_LOG")"
# Der neue master richtet gerade ein (swapped/applying: Sicherung, Migration) -> Abbau wartet; ohne laufenden master nicht.
for _ph in swapping swapped applying; do
  STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state="PHASE=$_ph" STUB_RUNNING=lifeagents-master scr uninstall --json
  eq "SC.abbau-waehrend-$_ph-busy" 'busy|0' "$(res .reason)|$(grep -c '|down|' "$STUB_LOG")"
done
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state='PHASE=applying' scr uninstall --json
eq SC.abbau-applying-ohne-master-geht 'true|1' "$(res .ok)|$(grep -c '|down|' "$STUB_LOG")"
# Laufender master, dessen Tick seit ueber einer Stunde nicht abschliesst (kaputtes neues Abbild): der Abbau geht.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state=$'PHASE=applying\nSTARTED=2026-01-01T00:00:00Z' STUB_RUNNING=lifeagents-master scr uninstall --json
eq SC.abbau-applying-alt-geht 'true|1' "$(res .ok)|$(grep -c '|down|' "$STUB_LOG")"
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state="PHASE=applying
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)" STUB_RUNNING=lifeagents-master scr uninstall --json
eq SC.abbau-applying-frisch-busy 'busy|0' "$(res .reason)|$(grep -c '|down|' "$STUB_LOG")"
# Daten-Volume beim Abbau nicht pruefbar: nicht als entfernt zaehlen, sondern data_kept.
STUB_VOLS="$SC_ALLVOLS" STUB_FAIL='|volume|inspect|-f|{{index .Labels "io.lifeagents.install"}}|lifeagents_pgdata' scr uninstall --delete-data --json
eq SC.abbau-pgdata-unpruefbar 'data_kept|lifeagents_pgdata' "$(res .reason)|$(res '[.kept[] | select(.what == "lifeagents_pgdata") | .what] | first')"
# status/start: Docker-Fehler bei pgdata ist kein „nicht installiert“.
STUB_VOLS="$SC_ALLVOLS" STUB_FAIL='|volume|inspect|-f|{{index .Labels "io.lifeagents.install"}}|lifeagents_pgdata' scr status --json
eq SC.status-pgdata-unpruefbar 'true|true' "$(res .ok)|$(res .installed)"
STUB_VOLS="$SC_ALLVOLS" STUB_FAIL='|volume|inspect|-f|{{index .Labels "io.lifeagents.install"}}|lifeagents_pgdata' scr start --json
eq SC.start-pgdata-unpruefbar internal "$(res .reason)"
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_master_swap_state='PHASE=rolled_back' STUB_RUNNING=lifeagents-master scr uninstall --json
eq SC.abbau-rolled-back-geht 'true|1' "$(res .ok)|$(grep -c '|down|' "$STUB_LOG")"

# Lesefehler (Kurzlauf-Container scheitert) ist kein fehlender Wert: Abbruch, nie ein neues Passwort oder neue Ports.
# Der Fehler trifft genau das Lesen von stack.env (das Schreiben hat ein anderes Skript), nicht die Sperre davor.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_stack_env="$SC_STORED" STUB_FAIL='cat "$1"|_|/var_la/stack.env' STUB_RUNNING=lifeagents-master scr up --json
eq SC.lesefehler-werte-abbruch 'internal|values|0' "$(res .reason)|$(jq -r 'select(.type == "progress") | .step' "$SCO" | tail -n1)|$(grep -c '^== /var_la/stack.env' "${STUB_LOG}.put")"
STUB_VOLS="${_lp}pgdata" STUB_FAIL='cat "$1"|_|/pgdata/PG_VERSION' STUB_RUNNING=lifeagents-master scr up --json
eq SC.lesefehler-pgdata-abbruch 'internal|values|0' "$(res .reason)|$(jq -r 'select(.type == "progress") | .step' "$SCO" | tail -n1)|$(grep -c '^== /var_la/stack.env' "${STUB_LOG}.put")"
STUB_VOLS="$SC_ALLVOLS" STUB_FAIL='cat "$1"|_|/rt_tree/VERSION' scr up --json
eq SC.lesefehler-version-abbruch 'internal|0' "$(res .reason)|$(grep -c '|up|-d|' "$STUB_LOG")"
# Docker-Fehler schon beim Nachsehen, ob var_la da ist: die Sperre (erstes Lesen) wartet, keine neuen Werte. Den spaeteren
# Pfad (erster Lauf erkannt, Merkliste) erreicht eine feste Attrappe nicht; er hat dieselbe rc-2-Regel (sc_up).
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_stack_env="$SC_STORED" STUB_FAIL='|volume|inspect|-f|{{index .Labels "io.lifeagents.install"}}|lifeagents_var_la' STUB_RUNNING=lifeagents-master scr up --json
eq SC.volume-inspect-fehler-sperre 'busy|lock|0' "$(res .reason)|$(jq -r 'select(.type == "progress") | .step' "$SCO" | tail -n1)|$(grep -c '^== /var_la/stack.env' "${STUB_LOG}.put")"
# Zustand des Wechsels nicht lesbar, master laeuft: jedes aendernde Verb wartet (Sperre schliesst bei Unklarheit). Ohne
# master und ohne Helfer kann kein Wechsel weiterlaufen: dann geht es (sonst sperrte z. B. eine volle Platte den Abbau).
STUB_VOLS="$SC_ALLVOLS" STUB_FAIL='cat "$1"|_|/var_la/master-swap/state' STUB_RUNNING=lifeagents-master scr uninstall --json
eq SC.lesefehler-sperre-busy 'busy|0' "$(res .reason)|$(grep -c '|down|' "$STUB_LOG")"
STUB_VOLS="$SC_ALLVOLS" STUB_FAIL='cat "$1"|_|/var_la/master-swap/state' scr uninstall --json
eq SC.lesefehler-ohne-master-abbau-geht 'true|1' "$(res .ok)|$(grep -c '|down|' "$STUB_LOG")"
# Unlesbar und auch die Frage „laeuft der master?“ scheitert (Docker gestoert): das ist kein „kein master“ -> busy.
STUB_VOLS="$SC_ALLVOLS" STUB_FAIL='cat "$1"|_|/var_la/master-swap/state' STUB_FAIL2='|lifeagents-master' scr uninstall --json
eq SC.lesefehler-master-unklar-busy 'busy|0' "$(res .reason)|$(grep -c '|down|' "$STUB_LOG")"
# Erster Blick auf var_la gelingt, der zweite (Erkennung „erster Lauf“) scheitert: kein erster Lauf, keine neue Merkliste.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_stack_env="$SC_STORED" STUB_FAIL='|volume|inspect|-f|{{index .Labels "io.lifeagents.install"}}|lifeagents_var_la' STUB_FAIL_FROM=2 STUB_RUNNING=lifeagents-master scr up --json
eq SC.erster-lauf-inspect-fehler 'internal|delegate|0' "$(res .reason)|$(jq -r 'select(.type == "progress") | .step' "$SCO" | tail -n1)|$(wc -l < "${STUB_LOG}.put" | tr -d ' ')"
# Abgeleitetes Volume nicht pruefbar: Grund inspect_failed, nicht volume_busy.
STUB_VOLS="$SC_ALLVOLS ${_lp}n8n_patches" STUB_FAIL='|volume|inspect|-f|{{index .Labels "io.lifeagents.install"}}|lifeagents_n8n_patches' scr uninstall --json
eq SC.abbau-abgeleitet-unpruefbar inspect_failed "$(res '.kept[] | select(.what == "lifeagents_n8n_patches") | .reason')"
# status: Zustand nicht lesbar -> update_running true (die App startet dann nichts Aenderndes).
STUB_VOLS="$SC_ALLVOLS" STUB_FAIL='cat "$1"|_|/var_la/master-swap/state' scr status --json
eq SC.status-lesefehler-update-laeuft 'true|true' "$(res .ok)|$(res .update_running)"

# Weitergabe endet unerwartet (Signal, Exit 137): trotzdem genau ein result, Exit 1.
STUB_DELEGATE_RC=137 STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING=lifeagents-master STUB_IMG_lifeagents_master="$OTHER" STUB_CORE_IMAGES="$OTHER" scr up --json
eq SC.weitergabe-signal-result 'internal|1|1' "$(res .reason)|$(jq -s '[.[] | select(.type == "result")] | length' "$SCO")|$SC_RC"

# _procs <regex> — Anzahl laufender Prozesse, deren Aufruf passt (aus /proc: das Substrat hat kein procps, pgrep fehlt dort).
_procs() { local f c n=0; for f in /proc/[0-9]*/cmdline; do c="$(tr "\0" " " 2>/dev/null < "$f")" || continue; [[ "$c" =~ $1 ]] && n=$((n + 1)); done; printf '%s\n' "$n"; }
# docker stop schickt SIGTERM: der Kern endet mit einem result (internal), nicht stumm.
: > "$STUB_LOG"; : > "${STUB_LOG}.vols"
( cd "$W" && exec env -u LA_EDGE_PORT -u LA_WIZARD_PORT -u LA_PG_SUPERPW -u LA_PROBE_IMAGE -u LIFEAGENTS_RUNTIME \
    LA_CORE=1 LA_PROJECT=lifeagents STUB_IMG_lifeagents_core="$SC_SELFIMG" STUB_CONFIG_JSON="$SC_CFG" RELEASE_TAG=v9.0.0 \
    STUB_VOLS='' STUB_SLOW_UP=30 bash "$ROOT/provisioning/compose/stack.sh" up --json >"$SCO" 2>"$SCE" ) & _pid=$!
for _ in $(seq 1 50); do grep -q '"step":"start"' "$SCO" 2>/dev/null && break; sleep 0.1; done
sleep 0.5; kill -TERM "$_pid" 2>/dev/null
# Wie docker stop: nach der Frist (hier 5 s) waere SIGKILL faellig. Der Kern muss vorher enden, nicht erst nach dem Schritt.
_gone=0; for _ in $(seq 1 50); do kill -0 "$_pid" 2>/dev/null || { _gone=1; break; }; sleep 0.1; done
[ "$_gone" = 1 ] || kill -KILL "$_pid" 2>/dev/null; wait "$_pid" 2>/dev/null || true
eq SC.signal-result 'internal|1|1' "$(res .reason)|$(jq -s '[.[] | select(.type == "result")] | length' "$SCO")|$_gone"
# Der unterbrochene Schritt (hier der docker-Client fuer compose up) endet mit, statt weiterzulaufen.
sleep 0.3; eq SC.signal-kind-beendet 0 "$(_procs "$W/bin/docker compose .*up -d --wait")"
# sc_sig <verb-args…> — Kern im Hintergrund wie in einem Container starten, nach dem Schritt <step> TERM senden.
sc_sig() {
  local step="$1"; shift
  : > "$STUB_LOG"; : > "${STUB_LOG}.vols"; : > "$SCO"
  ( cd "$W" && exec env -u LA_EDGE_PORT -u LA_WIZARD_PORT -u LA_PG_SUPERPW -u LA_PROBE_IMAGE -u LIFEAGENTS_RUNTIME \
      LA_CORE=1 LA_PROJECT=lifeagents STUB_IMG_lifeagents_core="$SC_SELFIMG" STUB_CONFIG_JSON="$SC_CFG" RELEASE_TAG=v9.0.0 \
      bash "$ROOT/provisioning/compose/stack.sh" "$@" >"$SCO" 2>"$SCE" </dev/null ) & _pid=$!
  for _ in $(seq 1 50); do grep -q "\"step\":\"$step\"" "$SCO" 2>/dev/null && break; sleep 0.1; done
  sleep 0.5; kill -TERM "$_pid" 2>/dev/null
  _gone=0; for _ in $(seq 1 "${SC_SIG_WAIT:-50}"); do kill -0 "$_pid" 2>/dev/null || { _gone=1; break; }; sleep 0.1; done
  [ "$_gone" = 1 ] || kill -KILL "$_pid" 2>/dev/null; SC_RC=0; wait "$_pid" 2>/dev/null || SC_RC=$?
}
# Weitergabe: TERM geht an den inneren Kern weiter; sein result ist das eine result (kein zweites vom aeusseren).
STUB_DELEGATE_SLEEP=30 STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING=lifeagents-master STUB_IMG_lifeagents_master="$OTHER" STUB_CORE_IMAGES="$OTHER" sc_sig delegate up --json
eq SC.signal-weitergabe-ein-result 'innen|1|1|1' "$(res .detail)|$(jq -s '[.[] | select(.type == "result")] | length' "$SCO")|$SC_RC|$_gone"
# install: result nach dem Signal; die Antwort-Datei bleibt fuer das im master weiterlaufende provision.sh liegen (docker exec
# reicht kein Signal weiter; geloescht scheiterte es still, bevor es sie gelesen hat).
STUB_SLOW_EXEC=30 STUB_VOLS="$SC_ALLVOLS" STUB_RUNNING=lifeagents-master sc_sig provision install --json
eq SC.signal-install-result "internal|1|0" "$(res .reason)|$_gone|$(grep -c '^docker|exec|lifeagents-master|rm|-f|/run/lifeagents-wizard/answers.env|' "$STUB_LOG")"
# Innerer Kern ignoriert TERM (aelterer Stand): der aeussere wartet begrenzt und endet vor der SIGKILL-Frist mit einem result.
STUB_DELEGATE_SLEEP=30 STUB_DELEGATE_DEAF=1 STUB_VOLS="$SC_ALLVOLS" STUB_EXISTING=lifeagents-master STUB_IMG_lifeagents_master="$OTHER" STUB_CORE_IMAGES="$OTHER" SC_SIG_WAIT=120 sc_sig delegate up --json
eq SC.signal-weitergabe-taub-result 'internal|1|1' "$(res .reason)|$(jq -s '[.[] | select(.type == "result")] | length' "$SCO")|$_gone"
# Abbau: der compose-Client unter _sc_ro (Enkel des Hintergrund-Schritts) endet mit.
STUB_SLOW_DOWN=30 STUB_VOLS="$SC_ALLVOLS" sc_sig containers uninstall --json
sleep 0.3; eq SC.signal-enkel-beendet 'internal|0' "$(res .reason)|$(_procs "$W/bin/docker compose .*down --remove-orphans")"

# check laedt nichts: alle Pruef-Container laufen aus dem eigenen Abbild (ein von check geladenes busybox stuende sonst
# auf der Merkliste des ersten up und bliebe nach --delete-data liegen).
STUB_VOLS='' scr check --json
eq SC.check-nur-eigenes-abbild "0|$(grep -c '^docker|run|' "$STUB_LOG")" "$(grep '^docker|run|' "$STUB_LOG" | grep -vcF "|$SC_SELFIMG|")|$(grep '^docker|run|' "$STUB_LOG" | grep -cF "|$SC_SELFIMG|")"
# Auch die Helfer-Container von up (Volumes lesen/schreiben, Port-Probe) laufen aus dem eigenen Abbild: busybox laedt nur
# Compose fuer den anchor, und genau so zaehlt es als selbst geladen.
STUB_VOLS="$SC_ALLVOLS" STUB_CAT__var_la_stack_env="$SC_STORED" STUB_RUNNING=lifeagents-master scr up --json
eq SC.helfer-nur-eigenes-abbild 0 "$(grep '^docker|run|' "$STUB_LOG" | grep -vcF "|$SC_SELFIMG|")"

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
# Der Check wartet UPDATE_CHECK_LOCK_WAIT_S auf die Sperre (Minuten-Runner); der Halter hier haelt sie laenger = Update.
( unset LIFEAGENTS_UPDATE_LOCK_HELD; UPDATE_CHECK_LOCK_WAIT_S=1; _chk_case scheduled ) >/dev/null 2>&1
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
# CLI-Attrappe: der Tick ruft jeden Schritt als eigenen CLI-Prozess (Zeitgrenze, _ur_step); Auftraege/Check melden sich wie
# frueher die Funktions-Attrappen als "run"/"check" (Check-Argumente ohne "--", Ergebnis in UPDATE_CHECK_OUTCOME_FILE).
cat > "$W/bin/lifeagents" <<'STUB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "update --run-requested") echo run >> "$TICK_LOG" ;;
  "update --check")
    echo check >> "$TICK_LOG"; echo "${3#--}" >> "$CHECK_ARGS"
    if [ -n "${STUB_OUTCOME:-}" ] && [ -n "${UPDATE_CHECK_OUTCOME_FILE:-}" ]; then echo "$STUB_OUTCOME" > "$UPDATE_CHECK_OUTCOME_FILE"; fi ;;
  *) echo "cli $*" >> "$TICK_LOG" ;;
esac
STUB
chmod +x "$W/bin/lifeagents"; export TICK_LOG="$W/tick.log" CHECK_ARGS="$W/check.args"
lifeagents_version_marker() { printf '%s' "$W/VERSION_TICK"; }
lifeagents_env_file() { printf '%s' "$W/core.env"; }
printf 'HOUSEHOLD_TIMEZONE=UTC\n' > "$W/core.env"
UPDATE_TICK_STATE="$W/tick.state"; rm -f "$W/VERSION_TICK" "$W/tick.log" "$UPDATE_TICK_STATE"
( update_tick ); eq K.vor-installation-still '' "$(cat "$W/tick.log" 2>/dev/null)"
echo v9.0.0 > "$W/VERSION_TICK"
( BACKUP_AUTO_AT=0000 update_tick )
eq K.erster-tick-alles 'run check cli backup auto --scheduled' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
: > "$W/tick.log"; ( BACKUP_AUTO_AT=0000 update_tick )
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
# Stuendlicher Takt ab BACKUP_AUTO_AT; ob heute noch gesichert werden muss, entscheidet `backup auto --scheduled` (KB-Faelle).
_bst="$W/tickb.state"; rm -f "$_bst"
env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP "$(TZ=UTC date +%Y-%m-%d)"; env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP_TRY "$(( $(date -u +%s) - 3700 ))"
env_upsert "$_bst" LAST_OK 100; env_upsert "$_bst" LAST_FAIL 200
: > "$W/tick.log"; ( BACKUP_STATE_FILE="$_bst" BACKUP_AUTO_AT=0000 update_tick )
eq K.fehlschlag-neuer-versuch 'run cli backup auto --scheduled' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
: > "$W/tick.log"; ( BACKUP_STATE_FILE="$_bst" BACKUP_AUTO_AT=0000 update_tick )
eq K.neuer-versuch-erst-nach-einer-stunde 'run' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
env_upsert "$_bst" LAST_OK 300; env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP_TRY "$(( $(date -u +%s) - 3700 ))"
: > "$W/tick.log"; ( BACKUP_STATE_FILE="$_bst" BACKUP_AUTO_AT=0000 update_tick )
eq K.nach-erfolg-entscheidet-die-sicherung 'run cli backup auto --scheduled' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
# Ohne gewaehlten Ordner ebenfalls stuendlich: nur so erreicht der Hinweis das Meldefenster am Tag.
env_upsert "$_bst" LAST_FAIL 400; env_upsert "$_bst" LAST_FAIL_REASON nofolder
env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP_TRY "$(( $(date -u +%s) - 3700 ))"
: > "$W/tick.log"; ( BACKUP_STATE_FILE="$_bst" BACKUP_AUTO_AT=0000 update_tick )
eq K.ohne-ordner-stuendlich-fuer-den-hinweis 'run cli backup auto --scheduled' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
# Sperre belegt (Wiederherstellung oder Update lief): Grund busy, kein Alarm, der naechste Takt holt die Sicherung nach.
env_upsert "$_bst" LAST_FAIL 500; env_upsert "$_bst" LAST_FAIL_REASON busy
env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP_TRY "$(( $(date -u +%s) - 3700 ))"
: > "$W/tick.log"; ( BACKUP_STATE_FILE="$_bst" BACKUP_AUTO_AT=0000 update_tick )
eq K.belegt-holt-nach 'run cli backup auto --scheduled' "$(tr '\n' ' ' < "$W/tick.log" | sed 's/ $//')"
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
# Das 2-h-Fenster gilt nur nach einem Check, der entschieden hat; sonst Neuversuch nach UPDATE_CHECK_RETRY_S (15 min).
# gap = Sekunden, die nach dem Tick bis zum naechsten Check bleiben (Intervall - seit dem Check vergangen).
_gap() { local l now; l="$(read_env_value "$UPDATE_TICK_STATE" LAST_CHECK)"; now="$(date -u +%s)"; echo $(( UPDATE_CHECK_EVERY_S - (now - l) )); }
_rng() { if [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; then echo ok; else echo "gap=$1"; fi; }
for _o in decided undecided; do
  env_upsert "$UPDATE_TICK_STATE" LAST_CHECK 0; : > "$W/tick.log"
  ( STUB_OUTCOME=$_o BACKUP_AUTO_AT=2400 update_tick )
  _g="$(_gap)"
  if [ "$_o" = decided ]; then
    eq K.entschieden-volles-fenster ok "$(_rng "$_g" 7190 7200)"
  else
    eq K.nicht-entschieden-15-minuten ok "$(_rng "$_g" 890 900)"
  fi
done
# Ein Check ohne Meldung (alte Attrappe/Absturz) zaehlt wie bisher als entschieden.
env_upsert "$UPDATE_TICK_STATE" LAST_CHECK 0; ( BACKUP_AUTO_AT=2400 update_tick )
_g="$(_gap)"; eq K.ohne-meldung-volles-fenster ok "$(_rng "$_g" 7190 7200)"
unset LIFEAGENTS_RUNTIME

# ---------------------------------------------------------------------------- E: Ort fuer n8n-Eingabe-Dateien
# n8n liest `import:*` im n8n-Container und sieht vom master nur das Volume /shared; ein Kindprozess ohne TMPDIR in der Umgebung
# (Wizard-Abschluss nach dem Pairing) darf nie nach /tmp ausweichen.
eq E.verbund-ohne-tmpdir '/shared' "$(unset TMPDIR; LIFEAGENTS_RUNTIME=compose n8n_input_dir)"
eq E.verbund-mit-fremdem-tmpdir '/shared' "$(TMPDIR=/var/tmp LIFEAGENTS_RUNTIME=compose n8n_input_dir)"
eq E.klassisch-ohne-tmpdir '/tmp' "$(unset TMPDIR; LIFEAGENTS_RUNTIME=systemd n8n_input_dir)"
eq E.klassisch-mit-tmpdir '/var/tmp' "$(TMPDIR=/var/tmp LIFEAGENTS_RUNTIME=systemd n8n_input_dir)"

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

# ---------------------------------------------------------------------------- N: Node-Unterversion im Update (install_n8n.sh)
# Gleiche Hauptversion, neuere NodeSource-Unterversion: ensure_node hebt an, upgrade_detect zaehlt es als Tausch.
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/install_n8n.sh"
node_minor_newer "24.22.2-1nodesource1" "24.22.3-1nodesource1"; eq N.node-neueres-angebot 0 $?
node_minor_newer "24.22.3-1nodesource1" "24.22.3-1nodesource1"; eq N.node-gleich-kein-tausch 1 $?
node_minor_newer "24.22.3-1nodesource1" "24.22.2-1nodesource1"; eq N.node-aelteres-angebot-kein-downgrade 1 $?
node_minor_newer "" "24.22.3-1nodesource1"; eq N.node-nicht-per-dpkg-kein-tausch 1 $?
node_minor_newer "24.22.2-1nodesource1" ""; eq N.node-kein-kandidat-kein-tausch 1 $?
# node_stub_env <installiert> <angebotene-version> — Attrappen fuer Node-Pakete (madison-Zeilen wie apt-cache sie liefert)
node_stub_env() {
  NODE_MAJOR=24; INST="$1"; CAND="$2"; NODE_MINOR_CHANGED=0
  node() { echo "v${INST%%-*}"; }
  dpkg-query() { [ -n "$INST" ] && printf '%s' "$INST"; return 0; }
  apt-cache() { printf '     nodejs | %s | https://deb.nodesource.com/node_24.x nodistro/main amd64 Packages\n     nodejs | 24.22.1-1nodesource1 | https://deb.nodesource.com/node_24.x nodistro/main amd64 Packages\n' "$CAND"; }
  apt_update_once() { :; }
  apt_install() { echo "$*" >> "$W/node_inst"; local a; for a in "$@"; do case "$a" in nodejs=*) INST="${a#nodejs=}";; esac; done; }
}
# node_n_run <installiert> <angebot> — ensure_node zweimal in einem SUBSHELL; gibt "<Installationen> <Neustart-Schalter>" aus
node_n_run() {
  : > "$W/node_inst"
  ( node_stub_env "$1" "$2"; ensure_node; ensure_node; echo "$(wc -l < "$W/node_inst" | tr -d ' ') ${NODE_MINOR_CHANGED:-0} ${INST%%-*}" ) 2>/dev/null | tail -n1
}
eq N.ensure_node-hebt-einmal-an "1 1 24.22.3" "$(node_n_run 24.22.2-1nodesource1 24.22.3-1nodesource1)"
eq N.ensure_node-aktuell-kein-eingriff "0 0 24.22.3" "$(node_n_run 24.22.3-1nodesource1 24.22.3-1nodesource1)"
eq N.ensure_node-andere-hauptversion-nie "0 0 24.22.2" "$(node_n_run 24.22.2-1nodesource1 25.1.0-1nodesource1)"
# _upg_changes_systemd: Node-Minor erscheint als Zeile, ohne neueres Angebot bleibt die Liste leer (kein Merkzettel/Stopp)
node_chg() { ( node_stub_env "$1" "$2"; N8N_VERSION=2.45.7; n8n() { echo 2.45.7; }; _upg_pg_versions() { :; }; _upg_changes_systemd ) 2>/dev/null; }
eq U.node-minor-zeile 'Node.js 24.22.2 -> 24.22.3' "$(node_chg 24.22.2-1nodesource1 24.22.3-1nodesource1)"
eq U.node-aktuell-leer '' "$(node_chg 24.22.3-1nodesource1 24.22.3-1nodesource1)"

# ---------------------------------------------------------------------------- I: Sicherungs-Timer (install_backup_timer.sh, klassisch)
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/install_backup_timer.sh"
unset LIFEAGENTS_RUNTIME
TEMPLATE_DIR="$ROOT/provisioning/templates"; SYSTEMD_UNIT_DIR="$W/units"; mkdir -p "$SYSTEMD_UNIT_DIR"
PROVISION_REPO_SLUG=o/r; UPDATE_CLI_BIN=/usr/local/bin/lifeagents
rm -f "$W/log"; : > "$STUB_LOG"
( TIMEZONE=Europe/Berlin BACKUP_AUTO_AT=0330 install_backup_timer ) >/dev/null 2>&1
bt="$SYSTEMD_UNIT_DIR/lifeagents-backup.timer"; bs="$SYSTEMD_UNIT_DIR/lifeagents-backup.service"
if [ -s "$bt" ] && [ -s "$bs" ]; then pass I.units-angelegt; else fail I.units-angelegt "Unit-Dateien fehlen"; fi
if grep -qFx 'OnCalendar=*-*-* 03..23:30:00 Europe/Berlin' "$bt"; then pass I.timer-kalender-haushalts-zeitzone; else fail I.timer-kalender-haushalts-zeitzone "$(grep OnCalendar "$bt")"; fi
if grep -qFx 'Persistent=true' "$bt"; then pass I.timer-persistent; else fail I.timer-persistent "Persistent=true fehlt"; fi
if grep -qFx 'ExecStart=/usr/local/bin/lifeagents backup auto --scheduled' "$bs"; then pass I.service-ruft-backup-auto; else fail I.service-ruft-backup-auto "$(grep ExecStart "$bs")"; fi
if grep -qE '^(Requires|PartOf|BindsTo)=' "$bs"; then fail I.service-ohne-n8n-bindung "Bindung gefunden"; else pass I.service-ohne-n8n-bindung; fi
if grep -q '@@' "$bt" "$bs"; then fail I.keine-platzhalter-uebrig "$(grep -h '@@' "$bt" "$bs")"; else pass I.keine-platzhalter-uebrig; fi
if grep -q 'daemon-reload' "$STUB_LOG" && grep -q 'enable|lifeagents-backup.timer' "$STUB_LOG" && grep -q 'restart|lifeagents-backup.timer' "$STUB_LOG"; then pass I.timer-wird-aktiviert; else fail I.timer-wird-aktiviert "$(tr '\n' ' ' < "$STUB_LOG")"; fi
if grep -q 'restart|lifeagents-backup.service\|start|lifeagents-backup.service' "$STUB_LOG"; then fail I.service-nie-gestartet "Service angefasst"; else pass I.service-nie-gestartet; fi
: > "$STUB_LOG"; ( TIMEZONE=Europe/Berlin BACKUP_AUTO_AT=0330 install_backup_timer ) >/dev/null 2>&1
if grep -qE 'daemon-reload|restart' "$STUB_LOG"; then fail I.zweitlauf-noop "$(tr '\n' ' ' < "$STUB_LOG")"; else pass I.zweitlauf-noop; fi
( TIMEZONE=UTC BACKUP_AUTO_AT=0415 install_backup_timer ) >/dev/null 2>&1
if grep -qFx 'OnCalendar=*-*-* 04..23:15:00 UTC' "$bt"; then pass I.uhrzeit-aus-backup-auto-at; else fail I.uhrzeit-aus-backup-auto-at "$(grep OnCalendar "$bt")"; fi
( TIMEZONE=UTC BACKUP_AUTO_AT=2460 install_backup_timer ) >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then pass I.ungueltige-uhrzeit-bricht-ab; else fail I.ungueltige-uhrzeit-bricht-ab "rc=$rc"; fi
rm -f "$bt" "$bs"; : > "$STUB_LOG"
( LIFEAGENTS_RUNTIME=compose install_backup_timer; LIFEAGENTS_RUNTIME=compose uninstall_backup_timer ) >/dev/null 2>&1
if [ ! -e "$bt" ] && [ ! -s "$STUB_LOG" ]; then pass I.verbund-no-op; else fail I.verbund-no-op "Datei oder Aufruf im Verbund"; fi
_u_stop_unit() { echo "stop $*" >> "$W/ustop"; }
: > "$W/ustop"; ( uninstall_backup_timer ) >/dev/null 2>&1
eq I.abbau-timer-und-service 'stop lifeagents-backup.timer 1 stop lifeagents-backup.service 1' "$(tr '\n' ' ' < "$W/ustop" | sed 's/ $//')"

# alte crontab-Zeile: genau diese Zeile geht, alles andere bleibt (Attrappe: der Speicher ist eine Datei)
cat > "$W/bin/crontab" <<'STUB'
#!/usr/bin/env bash
store="$CRON_STORE"
case "$*" in
  "-l -u root") [ -f "$store" ] || exit 1; cat "$store" ;;
  "-u root "*) cp "$3" "$store"; echo x >> "$store.writes" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$W/bin/crontab"; export CRON_STORE="$W/crontab.store"
LEGACY='30 3 * * * cd /root && lifeagents backup export --notify-telegram >> /var/log/lifeagents-backup.log 2>&1'
printf 'MAILTO=owner@example.test\n%s\n0 5 * * * /usr/local/bin/other-job\n' "$LEGACY" > "$CRON_STORE"; rm -f "$CRON_STORE.writes"
out="$( remove_legacy_backup_cron 2>&1 )"
eq I.cron-nur-diese-zeile-weg $'MAILTO=owner@example.test\n0 5 * * * /usr/local/bin/other-job' "$(cat "$CRON_STORE")"
case "$out" in *"Alte Sicherungs-Zeile aus der root-crontab entfernt"*) pass I.cron-protokoll-vermerk ;; *) fail I.cron-protokoll-vermerk "$out" ;; esac
rm -f "$CRON_STORE.writes"; out="$( remove_legacy_backup_cron 2>&1 )"
if [ -z "$out" ] && [ ! -e "$CRON_STORE.writes" ]; then pass I.cron-zweitlauf-still-ohne-schreiben; else fail I.cron-zweitlauf-still-ohne-schreiben "Ausgabe '$out'"; fi
printf '45 3 * * * cd /root && lifeagents backup export --notify-telegram >> /var/log/lifeagents-backup.log 2>&1\n# %s\n' "$LEGACY" > "$CRON_STORE"; cp "$CRON_STORE" "$W/cron.before"
out="$( remove_legacy_backup_cron 2>&1 )"
if cmp -s "$CRON_STORE" "$W/cron.before" && [ -z "$out" ]; then pass I.cron-abgewandelte-zeile-bleibt; else fail I.cron-abgewandelte-zeile-bleibt "veraendert"; fi
rm -f "$CRON_STORE"; out="$( remove_legacy_backup_cron 2>&1 )"
if [ -z "$out" ] && [ ! -e "$CRON_STORE" ]; then pass I.cron-ohne-crontab-still; else fail I.cron-ohne-crontab-still "$out"; fi
printf '%s\n' "$LEGACY" > "$CRON_STORE"; out="$( LIFEAGENTS_RUNTIME=compose remove_legacy_backup_cron 2>&1 )"
if [ "$(cat "$CRON_STORE")" = "$LEGACY" ]; then pass I.cron-verbund-no-op; else fail I.cron-verbund-no-op "Zeile im Verbund entfernt"; fi
out="$( svc_is_active() { return 1; }; remove_legacy_backup_cron 2>&1 )"
if [ "$(cat "$CRON_STORE")" = "$LEGACY" ] && [ -z "$out" ]; then pass I.cron-bleibt-ohne-laufenden-timer; else fail I.cron-bleibt-ohne-laufenden-timer "Zeile trotz inaktivem Timer entfernt"; fi
eq I.standard-ordner-getrennt-von-vorab-sicherungen '/var/backups/lifeagents/daily' "$BACKUP_LOCAL_DIR"
( backup_cli help 2>&1 ) > "$W/help.out" 2>&1 || true
if grep -q 'crontab' "$W/help.out"; then fail I.hilfe-ohne-crontab-empfehlung "$(grep crontab "$W/help.out")"; else pass I.hilfe-ohne-crontab-empfehlung; fi

# _bkp_auto_due: seit dem letzten BACKUP_AUTO_AT (Haushalts-Zeitzone) keine Sicherung gelungen?
printf 'HOUSEHOLD_TIMEZONE=UTC\n' > "$W/core.env"; lifeagents_env_file() { printf '%s' "$W/core.env"; }
_bs="$W/due.state"; rm -f "$_bs"
due() { ( BACKUP_STATE_FILE="$_bs" BACKUP_AUTO_AT="$1"; _bkp_auto_due ) && printf due || printf none; }
eq I.faellig-nie-gesichert due "$(due 0000)"
env_upsert "$_bs" LAST_OK "$(date +%s)"
eq I.heute-gesichert-nicht-faellig none "$(due 0000)"
env_upsert "$_bs" LAST_OK "$(( $(date +%s) - 3 * 86400 ))"
eq I.vor-3-tagen-faellig due "$(due 0000)"
_two="$(date -u -d '2 hours ago' +%H%M)"
env_upsert "$_bs" LAST_OK "$(( $(date +%s) - 3600 ))"
eq I.nach-letzter-uhrzeit-gesichert-nicht-faellig none "$(due "$_two")"
env_upsert "$_bs" LAST_OK "$(( $(date +%s) - 3 * 3600 ))"
eq I.vor-letzter-uhrzeit-gesichert-faellig due "$(due "$_two")"

# Chat-Hinweis im klassischen Betrieb: derselbe Rahmen (2 Tage, nur tagsueber, 20 h Sperre), aber LXC-Texte ohne Start-App.
lxc_note() {   # lxc_note <grund> [<sprache>] -> Text der Telegram-Nachricht
  ( _pkg_dir() { printf "%s" "$ROOT/packages"; }; BACKUP_STATE_FILE="$W/lxc.state"; : > "$BACKUP_STATE_FILE"; BACKUP_NOTIFY_HOURS=00-23; BACKUP_LOCAL_DIR=/srv/sicherung; _BACKUP_LANG="${2:-de}"
    notify_owner_telegram() { printf '%s' "$1" > "$W/lxc.note"; }
    env_upsert "$BACKUP_STATE_FILE" LAST_OK "$(( $(date +%s) - 3 * 86400 ))"; env_upsert "$BACKUP_STATE_FILE" LAST_FAIL_REASON "$1"
    rm -f "$W/lxc.note"; _bkp_stale_notify; cat "$W/lxc.note" 2>/dev/null )
}
for g in write key dump encrypt busy; do
  t="$(lxc_note "$g")"
  case "$t" in *"Start-App"*|*"Sicherungsordner ändern"*) fail "I.hinweis-lxc-ohne-start-app:$g" "$t" ;; *"auf dem Server"*|*"Auf dem Server"*) pass "I.hinweis-lxc-ohne-start-app:$g" ;; *) fail "I.hinweis-lxc-ohne-start-app:$g" "kein LXC-Text: $t" ;; esac
done
case "$(lxc_note write)" in *"/srv/sicherung"*"voll oder schreibgeschützt"*) pass I.hinweis-lxc-schreibfehler-nennt-ordner ;; *) fail I.hinweis-lxc-schreibfehler-nennt-ordner "$(lxc_note write)" ;; esac
case "$(lxc_note dump)" in *"journalctl -u lifeagents-backup"*"Anleitung:"*) pass I.hinweis-lxc-verweist-auf-protokoll ;; *) fail I.hinweis-lxc-verweist-auf-protokoll "$(lxc_note dump)" ;; esac
case "$(lxc_note key en)" in *"backup key is missing"*"journalctl"*) pass I.hinweis-lxc-englisch ;; *) fail I.hinweis-lxc-englisch "$(lxc_note key en)" ;; esac
# Verbund bleibt bei den Start-App-Texten.
case "$( LIFEAGENTS_RUNTIME=compose lxc_note key )" in *"Start-App"*) pass I.hinweis-verbund-unveraendert ;; *) fail I.hinweis-verbund-unveraendert "$( LIFEAGENTS_RUNTIME=compose lxc_note key )" ;; esac
# backup auto (klassisch) ruft den Hinweis nach jedem Versuch: Ordner nicht anlegbar, Export gescheitert, Erfolg.
na() {   # na <ordner> <export-rc> -> "<Hinweis-Pruefungen>/<Rotationen>"
  ( BACKUP_LOCAL_DIR="$1"; rm -f "$W/na.n" "$W/na.r"; : > "$W/na.n"; : > "$W/na.r"
    _rc="$2"; _bkp_stale_notify() { echo x >> "$W/na.n"; }; backup_cmd_export() { return "$_rc"; }; _bkp_key() { printf k; }
    _bkp_local_rotate() { echo r >> "$W/na.r"; }
    BACKUP_STATE_FILE="$W/na.state"; : > "$BACKUP_STATE_FILE"
    _bkp_auto_local 0 >/dev/null 2>&1; printf '%s/%s' "$(wc -l < "$W/na.n" | tr -d ' ')" "$(wc -l < "$W/na.r" | tr -d ' ')" )
}
eq I.auto-ordner-nicht-anlegbar-hinweis-ohne-rotation 1/0 "$(na /proc/nirgends/x 0)"
eq I.auto-export-gescheitert-hinweis-ohne-rotation 1/0 "$(na "$W/na.dir" 1)"
eq I.auto-erfolg-rotiert-und-hinweis 1/1 "$(na "$W/na.dir2" 0)"
eq I.auto-hinweis-nicht-faellig-kein-aufruf 0 "$( ( BACKUP_LOCAL_DIR="$W/na.dir3"; rm -f "$W/na.n"; _bkp_stale_notify() { echo x >> "$W/na.n"; }; _bkp_auto_due() { return 1; }; _bkp_auto_local 1 >/dev/null 2>&1; cat "$W/na.n" 2>/dev/null | wc -l | tr -d ' ' ) )"

# R  Netz-Wiederholung: rt_stack_up versucht es bis zu dreimal (Registry-Limit, Aussetzer); add_apt_key laedt erst in eine Datei
#    und schaltet curl-Wiederholung auch fuer curl 18 ein (kein halber Schluessel in gpg).
rt_try() {   # rt_try <fehlschlaege-vor-erfolg> -> "<rc>/<aufrufe>"
  ( : > "$W/rt.n"; RT_UP_RETRY_DELAY=0; _fails="$1"
    _rt_compose() { echo x >> "$W/rt.n"; [ "$(wc -l < "$W/rt.n" | tr -d ' ')" -gt "$_fails" ]; }
    warn() { :; }; sleep() { :; }
    rt_stack_up master >/dev/null 2>&1; printf '%s/%s' "$?" "$(wc -l < "$W/rt.n" | tr -d ' ')" )
}
eq R.up-gelingt-sofort 0/1 "$(rt_try 0)"
eq R.up-zweiter-versuch 0/2 "$(rt_try 1)"
eq R.up-dritter-versuch 0/3 "$(rt_try 2)"
eq R.up-gibt-nach-drei-versuchen-auf 1/3 "$(rt_try 9)"
mkdir -p "$W/akbin"
printf '#!/usr/bin/env bash\nprintf "%%s " "$@" > "%s/curl.args"\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && { printf KEY > "$2"; }; shift; done\n' "$W" > "$W/akbin/curl"
printf '#!/usr/bin/env bash\ncat > "$4"\n' > "$W/akbin/gpg"
chmod +x "$W/akbin/curl" "$W/akbin/gpg"
( PATH="$W/akbin:$PATH"; add_apt_key https://example.invalid/k.asc "$W/ak/key.gpg" ) >/dev/null 2>&1
eq R.apt-key-curl-wiederholt-auch-curl18 1 "$(grep -c -e '--retry-all-errors' "$W/curl.args" 2>/dev/null)"
eq R.apt-key-landet-vollstaendig-im-schluesselbund KEY "$(cat "$W/ak/key.gpg" 2>/dev/null)"

# D  doctor im Docker-Verbund: Alter von Release-Check und Sicherungs-Versuch (Tick-Zustand), Tunnel (Tailscale).
#    Echter Code von doctor.sh in einer Teilschale; nur Docker-Wrapper und Zeit-Dateien sind Attrappen.
dd_state() {   # dd_state <check-alter-s|-> <backup-datum|-> <VERSION-Alter-Min> -> Zustands-Datei + VERSION-Marker
  rm -f "$W/dd.state"; : > "$W/dd.VERSION"; touch -d "$3 minutes ago" "$W/dd.VERSION"
  [ "$1" = - ] || env_upsert "$W/dd.state" LAST_CHECK "$(( $(date -u +%s) - $1 ))"
  [ "$2" = - ] || env_upsert "$W/dd.state" LAST_BACKUP "$2"
}
dd_run() {   # dd_run <funktion> -> Ausgabe + fail=<n>
  ( . "$ROOT/provisioning/doctor.sh" >/dev/null 2>&1
    _fail=0; LIFEAGENTS_RUNTIME=compose; LA_PROJECT=t; UPDATE_TICK_STATE="$W/dd.state"; HOUSEHOLD_TIMEZONE=Europe/Berlin
    id() { echo 0; }; lifeagents_version_marker() { printf '%s' "$W/dd.VERSION"; }
    "$1"; echo "fail=$_fail" )
}
dd_today="$(TZ=Europe/Berlin date +%Y-%m-%d)"; dd_yday="$(TZ=Europe/Berlin date -d yesterday +%Y-%m-%d)"; dd_old="$(TZ=Europe/Berlin date -d '3 days ago' +%Y-%m-%d)"
dd_state 600 - 600; out="$(dd_run _doctor_compose_check)"
eq D.check-frisch-gruen '  [ OK ] Release-Check läuft (letzter Versuch vor 10 min)
fail=0' "$out"
dd_state 7300 - 600; out="$(dd_run _doctor_compose_check)"
eq D.check-ueber-fenster-noch-gruen 'fail=0' "$(printf '%s' "$out" | tail -n1)"
dd_state 20000 - 600; out="$(dd_run _doctor_compose_check)"
eq D.check-steht-rot '  [FAIL] Release-Check lief seit 5 h nicht mehr — Update-Hinweise im Chat kommen nicht an (docker logs t-master)
fail=1' "$out"
dd_state - - 600; out="$(dd_run _doctor_compose_check)"
eq D.check-nie-gelaufen-rot 'fail=1' "$(printf '%s' "$out" | tail -n1)"
dd_state - - 3; out="$(dd_run _doctor_compose_check)"
eq D.check-frische-installation-warn '  [WARN] Release-Check startet mit dem nächsten Durchlauf (höchstens 1 min)
fail=0' "$out"
# Sicherungs-Versuch: den Zustand schreibt der echte Tick (update_tick, Marker LAST_BACKUP_TRY), kein von Hand gesetzter Schluessel.
dd_tick() {   # dd_tick <BACKUP_AUTO_AT des Ticks> <VERSION-Alter-Min>
  rm -f "$W/dd.state" "$W/dd.bst"; : > "$W/dd.VERSION"; touch -d "$2 minutes ago" "$W/dd.VERSION"
  ( export LIFEAGENTS_RUNTIME=compose; UPDATE_TICK_STATE="$W/dd.state"; BACKUP_STATE_FILE="$W/dd.bst"; BACKUP_AUTO_AT="$1"; UPDATE_CHECK_EVERY_S=99999999
    lifeagents_version_marker() { printf '%s' "$W/VERSION_TICK"; }; update_tick ) >/dev/null 2>&1
}
dd_tick 0000 600; out="$(dd_run _doctor_compose_backup_tick)"
printf '%s' "$out" | grep -q '^  \[ OK \] Tägliche Sicherung wird angestoßen (letzter Versuch vor [01] min)$' && eq D.sicherung-vom-echten-tick-gruen 'fail=0' "$(printf '%s' "$out" | tail -n1)" || fail D.sicherung-vom-echten-tick-gruen "$out"
env_upsert "$W/dd.state" LAST_BACKUP_TRY "$(( $(date -u +%s) - 3 * 86400 ))"; out="$(dd_run _doctor_compose_backup_tick)"
eq D.sicherung-alter-versuch-warn '  [WARN] Tägliche Sicherung wurde seit 72 h nicht mehr angestoßen — Verlauf: docker logs t-master
fail=0' "$out"
dd_tick 2400 600; out="$(BACKUP_AUTO_AT=0000 dd_run _doctor_compose_backup_tick)"
eq D.sicherung-nie-angestossen-warn '  [WARN] Tägliche Sicherung wurde noch nie angestoßen — Verlauf: docker logs t-master
fail=0' "$out"
dd_tick 2400 3; out="$(BACKUP_AUTO_AT=0000 dd_run _doctor_compose_backup_tick)"
eq D.sicherung-frische-installation-still 'fail=0' "$out"
# Tunnel: nur im Tunnel-Weg; tailscale-Container und Status laut Attrappe.
dd_fun='{"AllowFunnel":{"bot.tail-fantasy.ts.net:443":true},"Web":{"bot.tail-fantasy.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8088"}}}}}'
dd_ts() {   # dd_ts <REACH_MODE> <laeuft:0|1> <status-json> [funnel-json] -> Ausgabe
  ( . "$ROOT/provisioning/doctor.sh" >/dev/null 2>&1
    _fail=0; LIFEAGENTS_RUNTIME=compose; LA_PROJECT=t; REACH_MODE="$1"; _up="$2"; _js="$3"; _fn="${4-$dd_fun}"; DOMAIN="${5-}"
    rt_edge_active() { [ "$_up" = 0 ]; }; _reach_ts_status() { printf "%s" "$_js"; }; rt_edge_exec() { printf "%s" "$_fn"; }
    _doctor_compose_tunnel; echo "fail=$_fail" )
}
dd_ok='{"BackendState":"Running","Self":{"DNSName":"bot.tail-fantasy.ts.net.","Expired":false,"CapMap":{"https":[],"funnel":[]}}}'
eq D.tunnel-anderer-weg-still 'fail=0' "$(dd_ts fritzbox 0 "$dd_ok")"
eq D.tunnel-container-aus-rot '  [FAIL] Tunnel: der Container tailscale läuft nicht — Telegram erreicht den Bot nicht (Start-App: Neu starten; docker logs --tail 100 t-tailscale)
fail=1' "$(dd_ts tunnel 1 "$dd_ok")"
eq D.tunnel-steht-gruen '  [ OK ] Tunnel steht (Tailscale angemeldet, bot.tail-fantasy.ts.net)
fail=0' "$(dd_ts tunnel 0 "$dd_ok")"
dd_exp="$(date -u -d '+5 days' +%Y-%m-%dT%H:%M:%SZ)"
dd_soon="${dd_ok/\"Expired\"/\"KeyExpiry\":\"$dd_exp\",\"Expired\"}"
out="$(dd_ts tunnel 0 "$dd_soon")"
printf '%s' "$out" | grep -q '^  \[WARN\] Tailscale-Anmeldung läuft in [45] Tag(en) ab' && eq D.tunnel-schluessel-laeuft-ab-zaehlt-nicht 'fail=0' "$(printf '%s' "$out" | tail -n1)" || fail D.tunnel-schluessel-laeuft-ab "$out"
dd_login='{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/abc","Self":{"DNSName":"bot.tail-fantasy.ts.net."}}'
# Noch nie eingerichtet (kein Tunnel-Name als DOMAIN in core.env): Einrichtung steht aus = Hinweis. Lief der Tunnel schon
# (DOMAIN gesetzt) und ist jetzt abgemeldet oder abgelaufen: der Bot ist nicht erreichbar = ROT.
out="$(dd_ts tunnel 0 "$dd_login" "$dd_fun" bot.tail-fantasy.ts.net)"
printf "%s" "$out" | grep -qF "  [FAIL] Tunnel: bei Tailscale anmelden" && eq D.tunnel-abgemeldet-nach-betrieb-rot fail=1 "$(printf "%s" "$out" | tail -n1)" || fail D.tunnel-abgemeldet-nach-betrieb-rot "$out"
eq D.tunnel-nie-angemeldet-nur-hinweis '  [WARN] Tunnel: Einrichtung steht noch aus — bei Tailscale anmelden: docker exec -i t-master lifeagents reconfigure core → „Unverändert neu anwenden“
fail=0' "$(dd_ts tunnel 0 "$dd_login")"
eq D.tunnel-startet-ohne-betrieb-nur-hinweis "  [WARN] Tunnel: Einrichtung steht noch aus — startet …
fail=0" "$(dd_ts tunnel 0 "{\"BackendState\":\"NoState\"}")"
dd_expired="${dd_ok/\"Expired\":false/\"Expired\":true}"
eq D.tunnel-abgelaufen-rot "  [FAIL] Tunnel: Tailscale-Anmeldung abgelaufen — neu anmelden: docker exec -i t-master lifeagents reconfigure core
fail=1" "$(dd_ts tunnel 0 "$dd_expired")"
# Nach einem Update legt der Installer tailscale neu an; die Abschlusspruefung kann die ersten Sekunden "startet" sehen. Mit
# Tunnel-Adresse (lief schon) wartet doctor kurz (DOCTOR_TS_TRIES x 2 s), erst danach ist "startet" ein Ausfall.
dd_tsw() {   # dd_tsw <Zahl "startet"-Antworten vor der echten> <Versuche> -> Ausgabe
  rm -f "$W/ts.n"
  ( . "$ROOT/provisioning/doctor.sh" >/dev/null 2>&1
    _fail=0; LIFEAGENTS_RUNTIME=compose; LA_PROJECT=t; REACH_MODE=tunnel; DOMAIN=bot.tail-fantasy.ts.net; DOCTOR_TS_TRIES="$2"; _k="$1"
    rt_edge_active() { return 0; }; rt_edge_exec() { printf '%s' "$dd_fun"; }; sleep() { :; }
    _reach_ts_status() { local c; c="$(cat "$W/ts.n" 2>/dev/null || echo 0)"; echo $((c + 1)) > "$W/ts.n"; if [ "$c" -lt "$_k" ]; then printf '{"BackendState":"NoState"}'; else printf '%s' "$dd_ok"; fi; }
    _doctor_compose_tunnel; echo "fail=$_fail" )
}
eq D.tunnel-startet-kurz-dann-gruen '  [ OK ] Tunnel steht (Tailscale angemeldet, bot.tail-fantasy.ts.net)
fail=0' "$(dd_tsw 2 5)"
eq D.tunnel-startet-dauerhaft-rot '  [FAIL] Tunnel: startet …
fail=1' "$(dd_tsw 99 3)"

# G  Fingerabdruck des Workflow-Deploys (deploy_workflows.sh): die n8n-Version kommt im Docker-Verbund aus dem Image des
#    laufenden n8n-Containers, nicht aus dem Pin von provision.sh. Sonst ergaebe dieselbe Instanz je Einstieg (Installer
#    mit Pin, CLI ohne) zwei Fingerabdruecke und jeder CLI-Lauf spielte alle Workflows neu ein.
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/deploy_workflows.sh"
gx() {   # gx <N8N_VERSION|-> <Image des n8n-Containers|-> -> Kontext-Zeile
  ( export LIFEAGENTS_RUNTIME=compose LA_PROJECT=t LA_N8N_CONTAINER=t-n8n; N8N_ENV_FILE="$W/gx.env"; : > "$N8N_ENV_FILE"
    owner_tg_token() { printf 'tok'; }
    if [ "$1" = - ]; then unset N8N_VERSION; else N8N_VERSION="$1"; fi
    if [ "$2" = - ]; then unset STUB_IMG_t_n8n; else export STUB_IMG_t_n8n="$2"; fi
    _wf_deploy_context )
}
gx_img='n8nio/n8n:2.45.7@sha256:9a8d8dcea75667496695d7810d7e1fe018a65efb36cc499d347f3931b3957b5d'
eq G.cli-und-installer-gleicher-fingerabdruck "$(gx 2.45.7 "$gx_img")" "$(gx - "$gx_img")"
eq G.version-kommt-aus-dem-container 'n8n=2.45.7|' "$(gx - "$gx_img" | cut -d'|' -f1-1 | sed 's/$/|/')"
eq G.versionswechsel-aendert-den-fingerabdruck 1 "$([ "$(gx - "$gx_img")" != "$(gx - 'n8nio/n8n:2.46.0@sha256:aa')" ] && echo 1 || echo 0)"
eq G.ohne-container-gilt-der-pin 'n8n=2.45.7' "$(gx 2.45.7 - | cut -d'|' -f1)"
mkdir -p "$W/gxb/bin"; printf '#!/bin/sh\n' > "$W/gxb/bin/n8n"; chmod +x "$W/gxb/bin/n8n"; printf '{"version":"9.9.9"}' > "$W/gxb/package.json"
eq G.verbund-ignoriert-ein-lokales-n8n-binary 'n8n=2.45.7' "$( PATH="$W/gxb/bin:$PATH"; gx - "$gx_img" | cut -d'|' -f1 )"
# Review-Funde: Funnel-Eintrag weg = Tunnel steht nicht; leerer Sicherungs-Zustand vor BACKUP_AUTO_AT ist noch kein Fehlalarm.
eq D.tunnel-funnel-fehlt-rot '  [FAIL] Tunnel: Funnel-Einträge fehlen oder weichen ab — Telegram erreicht den Bot nicht (docker exec -i t-master lifeagents reconfigure core → „Unverändert neu anwenden“)
fail=1' "$(dd_ts tunnel 0 "$dd_ok" '{}')"
dd_tick 2400 600; out="$(BACKUP_AUTO_AT=2359 dd_run _doctor_compose_backup_tick)"
eq D.sicherung-vor-der-backup-uhrzeit-still 'fail=0' "$out"

# Laufender Tick-Schritt: LAST_TICK wird nur am Tick-Anfang geschrieben, ein Schritt darf lange laufen (Update 2 h,
# Sicherung 30 min, Check 5 min). Solange er innerhalb seiner Zeitgrenze laeuft, ist das ein Hinweis, kein ROT.
dt_run() {   # dt_run <tick-alter-s> <lock:frei|belegt> -> Ausgabe von _doctor_compose_tick + fail=<n>
  rm -f "$W/dd.state"; : > "$W/dd.VERSION"; touch -d "600 minutes ago" "$W/dd.VERSION"
  env_upsert "$W/dd.state" LAST_TICK "$(( $(date -u +%s) - $1 ))"
  ( . "$ROOT/provisioning/doctor.sh" >/dev/null 2>&1
    _fail=0; LIFEAGENTS_RUNTIME=compose; LA_PROJECT=t; UPDATE_TICK_STATE="$W/dd.state"; DOCTOR_PROC_ROOT="$W/dtproc"
    id() { echo 0; }; lifeagents_version_marker() { printf '%s' "$W/dd.VERSION"; }
    _lk="$2"; update_lock_free() { [ "$_lk" = frei ]; }
    _doctor_compose_tick; echo "fail=$_fail" )
}
dts() {   # dts <pid> <minuten-seit-start> <cmdline> -> Attrappen-Prozess; mtime von /proc/<pid> bleibt "jetzt" (wie im echten /proc), die Startzeit steht in stat Feld 22
  local parts; read -ra parts <<<"$3"; mkdir -p "$W/dtproc/$1"; printf '%s\0' "${parts[@]}" > "$W/dtproc/$1/cmdline"
  printf '100000.00 0.00\n' > "$W/dtproc/uptime"
  printf '%s (lifeagents) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$1" "$(( (100000 - $2 * 60) * 100 ))" > "$W/dtproc/$1/stat"
}
rm -rf "$W/dtproc"; mkdir -p "$W/dtproc"
dts 7 20 'bash /usr/local/bin/lifeagents update --run-requested'
eq D.tick-update-laeuft-hinweis '  [WARN] Update-Schleife im master: läuft gerade: Update, seit 20 min (Zeitgrenze 120 min)
fail=0' "$(dt_run 1200 belegt)"
rm -rf "$W/dtproc"; mkdir -p "$W/dtproc"; dts 8 20 'bash /usr/local/bin/lifeagents backup auto --scheduled'
eq D.tick-sicherung-laeuft-hinweis '  [WARN] Update-Schleife im master: läuft gerade: Sicherung, seit 20 min (Zeitgrenze 30 min)
fail=0' "$(dt_run 1200 frei)"
rm -rf "$W/dtproc"; mkdir -p "$W/dtproc"; dts 9 10 'bash /usr/local/bin/lifeagents update --check --scheduled'
eq D.tick-check-ueber-zeitgrenze-rot '  [FAIL] Update-Schleife im master steht seit 10 min — Updates aus dem Chat kommen nicht an (docker logs t-master)
fail=1' "$(dt_run 600 frei)"
rm -rf "$W/dtproc"; mkdir -p "$W/dtproc"
rm -rf "$W/dtproc"; mkdir -p "$W/dtproc"; dts 10 200 'bash /usr/local/bin/lifeagents update --run-requested'
eq D.tick-haengender-update-schritt-rot '  [FAIL] Update-Schleife im master steht seit 15 min — Updates aus dem Chat kommen nicht an (docker logs t-master)
fail=1' "$(dt_run 900 belegt)"
rm -rf "$W/dtproc"; mkdir -p "$W/dtproc"
eq D.tick-ohne-schritt-rot 'fail=1' "$(dt_run 900 frei | tail -n1)"
eq D.tick-sperre-belegt-ohne-prozess-hinweis '  [WARN] Update-Schleife im master: läuft gerade: Update (Sperre belegt), seit 15 min (Zeitgrenze 120 min)
fail=0' "$(dt_run 900 belegt)"
eq D.tick-sperre-belegt-ueber-zeitgrenze-rot 'fail=1' "$(dt_run 8000 belegt | tail -n1)"


# H  doctor: ein Dienst laeuft noch mit dem alten Node (apt hat die Datei ersetzt, der Neustart blieb aus). Erkennung ueber
#    /proc/<pid>/exe = "…/node (deleted)"; die Probe-Wurzel ist ersetzbar, sonst echter Code von doctor.sh.
hp() {   # hp <pid> <exe-ziel> <cmdline> -> Eintrag im Attrappen-/proc
  local parts; read -ra parts <<<"$3"
  mkdir -p "$W/hproc/$1"; ln -sfn "$2" "$W/hproc/$1/exe"; printf '%s\0' "${parts[@]}" > "$W/hproc/$1/cmdline"
}
hd() {   # hd <compose:0|1> -> Ausgabe von _doctor_node_stale + fail=<n>
  ( . "$ROOT/provisioning/doctor.sh" >/dev/null 2>&1
    _fail=0; DOCTOR_PROC_ROOT="$W/hproc"; id() { echo 0; }
    if [ "$1" = 1 ]; then LIFEAGENTS_RUNTIME=compose; else unset LIFEAGENTS_RUNTIME; fi
    _doctor_node_stale; echo "fail=$_fail" )
}
rm -rf "$W/hproc"; hp 101 /usr/bin/node 'node /usr/lib/node_modules/n8n/bin/n8n start'; hp 102 /usr/bin/node 'node /opt/lifeagents/llm_gateway/server.js'; hp 103 /usr/bin/bash 'bash'
eq H.alles-aktuell-still 'fail=0' "$(hd 0)"
hp 101 '/usr/bin/node (deleted)' 'node /usr/lib/node_modules/n8n/bin/n8n start'
eq H.n8n-alter-node-warnt '  [WARN] Node.js: n8n läuft noch mit der alten Version — ein Neustart steht aus (Abhilfe: '"'lifeagents update'"' oder '"'systemctl restart n8n'"')
fail=0' "$(hd 0)"
hp 102 '/usr/bin/node (deleted)' 'node /opt/lifeagents/llm_gateway/server.js'
eq H.beide-alt-nennt-beide '  [WARN] Node.js: n8n, LLM-Gateway laufen noch mit der alten Version — ein Neustart steht aus (Abhilfe: '"'lifeagents update'"' oder '"'systemctl restart n8n lifeagents-llm-gateway'"')
fail=0' "$(hd 0)"
eq H.verbund-still 'fail=0' "$(hd 1)"

# ---------------------------------------------------------------------------- KZ: Zeitgrenzen im Tick (wie die drei Units)
# Ein haengender Schritt (Auftraege, Check, Sicherung) wird nach seiner Grenze beendet, samt Kindprozessen; die anderen
# Schritte laufen weiter. Attrappen auf beiden Ebenen (Shell-Funktion und CLI), damit der Fall vom Aufrufweg unabhaengig ist.
# real-path-test: none (Zeitgrenze im echten Verbund: Runde 8 im Bericht ob)
mkdir -p "$W/kzbin"
{ printf '#!/usr/bin/env bash\nd=%q\n' "$W/kz"
  cat <<'STUB'
w=''
case "$1 ${2:-}" in
  "update --run-requested") w=run ;; "update --check") w=check ;; "backup auto") w=backup ;;
esac
if [ -n "$w" ] && [ "$(cat "$d/hang" 2>/dev/null)" = "$w" ]; then sleep 30 & echo $! > "$d/child.pid"; wait; fi
echo "$w" >> "$d/log"
STUB
} > "$W/kzbin/lifeagents"
chmod +x "$W/kzbin/lifeagents"
kz_case() (   # kz_case <haengender-schritt> -> "<sekunden>|<log>|<kind-lebt?>"
  local KZ_DIR="$W/kz" KZ_HANG="$1"; rt_is_compose() { return 0; }; _ur_cli() { printf "%s" "$W/kzbin/lifeagents"; }
  rm -rf "$KZ_DIR"; mkdir -p "$KZ_DIR"; printf "%s" "$KZ_HANG" > "$KZ_DIR/hang"
  _kz() { if [ "$KZ_HANG" = "$1" ]; then sleep 30 & echo $! > "$KZ_DIR/child.pid"; wait; fi; echo "$1" >> "$KZ_DIR/log"; }
  update_run_requested() { _kz run; }; update_check() { _kz check; }
  require_root() { :; }; _ur_alert() { :; }
  lifeagents_version_marker() { printf '%s' "$KZ_DIR/V"; }; echo v9.0.0 > "$KZ_DIR/V"
  lifeagents_env_file() { printf '%s' "$KZ_DIR/core.env"; }; printf 'HOUSEHOLD_TIMEZONE=UTC\n' > "$KZ_DIR/core.env"
  UPDATE_TICK_STATE="$KZ_DIR/tick.state"; BACKUP_STATE_FILE="$KZ_DIR/b.state"; BACKUP_AUTO_AT=0000
  UPDATE_RUN_TIMEOUT_S=2 UPDATE_CHECK_TIMEOUT_S=2 BACKUP_TIMEOUT_S=2 UPDATE_STEP_KILL_S=1
  local t0 alive=nein; t0="$(date +%s)"
  update_tick >/dev/null 2>&1
  if [ -s "$KZ_DIR/child.pid" ] && kill -0 "$(cat "$KZ_DIR/child.pid")" 2>/dev/null; then alive=ja; kill "$(cat "$KZ_DIR/child.pid")"; fi
  printf '%s|%s|%s' "$(( $(date +%s) - t0 < 15 ))" "$(tr '\n' ' ' < "$KZ_DIR/log" 2>/dev/null | sed 's/ $//')" "$alive"
)
eq KZ.auftrag-haengt-tick-geht-weiter '1|check backup|nein' "$(kz_case run)"
eq KZ.check-haengt-tick-geht-weiter '1|run backup|nein' "$(kz_case check)"
eq KZ.sicherung-haengt-tick-endet '1|run check|nein' "$(kz_case backup)"
# SIGTERM (docker stop, Neuanlage durch den Helfer) erreicht den laufenden Schritt, nicht erst SIGKILL nach 10 s.
kz_term() (
  local KZ_DIR="$W/kz"; rt_is_compose() { return 0; }; _ur_cli() { printf "%s" "$W/kzbin/lifeagents"; }
  rm -rf "$KZ_DIR"; mkdir -p "$KZ_DIR"; printf run > "$KZ_DIR/hang"
  update_run_requested() { sleep 30 & echo $! > "$KZ_DIR/child.pid"; wait; }
  require_root() { :; }; _ur_alert() { :; }
  lifeagents_version_marker() { printf '%s' "$KZ_DIR/V"; }; echo v9.0.0 > "$KZ_DIR/V"
  lifeagents_env_file() { printf '%s' "$KZ_DIR/core.env"; }; : > "$KZ_DIR/core.env"
  UPDATE_TICK_STATE="$KZ_DIR/tick.state"; UPDATE_RUN_TIMEOUT_S=60
  update_tick >/dev/null 2>&1 & local tp=$! i alive=nein
  for i in $(seq 1 50); do [ -s "$KZ_DIR/child.pid" ] && break; sleep 0.1; done
  kill -TERM "$tp"
  for i in $(seq 1 50); do kill -0 "$tp" 2>/dev/null || break; sleep 0.1; done
  sleep 0.3
  if [ -s "$KZ_DIR/child.pid" ] && kill -0 "$(cat "$KZ_DIR/child.pid")" 2>/dev/null; then alive=ja; kill "$(cat "$KZ_DIR/child.pid")"; fi
  kill -9 "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
  printf '%s' "$alive"
)
eq KZ.term-erreicht-den-schritt nein "$(kz_term)"
# Ein abgebrochener Wechsel (Zeitgrenze mitten in provision.sh, n8n war fuer die Sicherung gestoppt) laesst den Bot nicht aus.
kz_intr() (   # kz_intr <mode> -> gestartete Dienste
  master_swap_resolve() { printf interrupted; }; master_swap_close() { :; }; _ur_alert() { :; }
  _swap_get() { case "$1" in MODE) printf '%s' "$KZ_MODE" ;; TAG) printf v9.1.0 ;; *) : ;; esac; }
  svc_start() { echo "$*" >> "$W/kzi.log"; }
  rm -f "$W/kzi.log"; KZ_MODE="$1" _ur_swap_continue >/dev/null 2>&1; cat "$W/kzi.log" 2>/dev/null
)
eq KZ.unterbrochen-update-n8n-wieder-an n8n "$(kz_intr update)"
eq KZ.unterbrochen-rueckweg-n8n-wieder-an n8n "$(kz_intr rollback)"

# ---------------------------------------------------------------------------- KR: Hilfs-Container mit jedem Lauf erneuern
# Rand, Gateway und laufende Profil-Dienste kommen auf den Stand der compose.yml dieses Laufs (neuer Pin = Neuanlage durch
# Compose); anchor nie. Wird edge neu angelegt, muss tailscale (in seinem Namensraum) mit. Attrappe: docker (STUB_LOG).
# real-path-test: none (Neuanlage im echten Verbund: Runde 8 im Bericht ob)
kr_case() (   # kr_case <laufend> <edge-id-vorher> <edge-id-nachher> -> Compose-up-Aufrufe
  rt_is_compose() { return 0; }; export STUB_RUNNING="$1"
  rt_container_id() { if [ -s "$W/kr.after" ]; then cat "$W/kr.after"; else printf '%s' "$KR_BEFORE"; fi; }
  KR_BEFORE="$2"; rm -f "$W/kr.after"; : > "$STUB_LOG"
  _rt_compose() { echo "$*" >> "$W/kr.calls"; printf '%s' "$KR_AFTER" > "$W/kr.after"; }
  KR_AFTER="$3"; rm -f "$W/kr.calls"
  rt_stack_refresh >/dev/null 2>&1; tr '\n' ';' < "$W/kr.calls"
)
eq KR.rand-und-gateway 'up -d --no-deps edge gateway;' "$(kr_case '' e1 e1)"
eq KR.wan-laeuft-mit 'up -d --no-deps edge gateway wan;' "$(kr_case 'lifeagents-wan' e1 e1)"
eq KR.tailscale-neuer-pin 'up -d --no-deps edge gateway;up -d --no-deps tailscale;' "$(kr_case 'lifeagents-tailscale' e1 e1)"
eq KR.edge-neu-tailscale-neu 'up -d --no-deps edge gateway;up -d --no-deps --force-recreate tailscale;' "$(kr_case 'lifeagents-tailscale' e1 e2)"
eq KR.ohne-tailscale-kein-tailscale 'up -d --no-deps edge gateway;' "$(kr_case '' e1 e2)"
# Der spaete Installer-Haken ruft die Erneuerung bei jedem Weg nach aussen (auch ohne FritzBox).
kr_conv() ( rt_stack_refresh() { echo refresh; }; reach_edge_public_write() { return 1; }; reach_mode() { printf tunnel; }; reach_converge 2>/dev/null )
eq KR.converge-erneuert refresh "$(kr_conv)"
# Nach einer Neuanlage des Gateways wartet der Lauf auf dessen Antwort; antwortet es nicht, steht es als Warnung im Lauf.
kr_gw() ( rt_stack_refresh() { :; }; reach_edge_public_write() { return 1; }; reach_mode() { printf tunnel; }
          _wait_llm_gateway_health() { return "$KR_GW"; }; warn() { echo "warn $*"; }; KR_GW="$1"; reach_converge 2>/dev/null | cut -c1-25 )
eq KR.gateway-antwortet-still '' "$(kr_gw 0)"
eq KR.gateway-stumm-warnung 'warn KI-Gateway antwortet' "$(kr_gw 1)"

# ---------------------------------------------------------------------------- KL: Update-Protokolle aufraeumen
# Die neuesten 10 bleiben immer, aelter als 30 Tage und darueber hinaus gehen; fremde Dateien im Ordner nie.
kl_case() (
  local d="$W/kl" i; rm -rf "$d"; mkdir -p "$d"; UPDATE_LOG_DIR="$d"
  for i in $(seq -w 1 14); do : > "$d/update-202610${i}T030000Z.log"; touch -d "-$((60 - 10#$i)) days" "$d/update-202610${i}T030000Z.log"; done
  : > "$d/update-20261115T030000Z.log"; : > "$d/fremd.txt"; touch -d '-90 days' "$d/fremd.txt"
  _ur_logs_prune >/dev/null 2>&1
  find "$d" -mindepth 1 -printf '%f\n' | sort | tr '\n' ' '
)
eq KL.neueste-zehn-und-fremde-bleiben 'fremd.txt update-20261006T030000Z.log update-20261007T030000Z.log update-20261008T030000Z.log update-20261009T030000Z.log update-20261010T030000Z.log update-20261011T030000Z.log update-20261012T030000Z.log update-20261013T030000Z.log update-20261014T030000Z.log update-20261115T030000Z.log ' "$(kl_case)"
kl_young() (
  local d="$W/kl" i; rm -rf "$d"; mkdir -p "$d"; UPDATE_LOG_DIR="$d"
  for i in $(seq -w 1 14); do : > "$d/update-202611${i}T030000Z.log"; done
  _ur_logs_prune >/dev/null 2>&1; find "$d" -mindepth 1 | wc -l | tr -d " "
)
eq KL.junge-bleiben-alle 14 "$(kl_young)"

# ---------------------------------------------------------------------------- SV: Abbruch-Pruefungen VOR dem master-Wechsel
# Was ein Update abbrechen kann (PostgreSQL-Hauptversion des neuen Pins passt nicht zu den Daten, Abbilder des neuen Stands
# nicht ladbar), muss im alten master scheitern: kein Helfer, kein Zustand, der alte Stand laeuft unveraendert.
# real-path-test: none (Wechsel im echten Verbund: Runde 8 im Bericht ob)
sv_case() (   # sv_case <pg-major-der-daten> <stub-fail> -> "<rc>|<zustand?>|<helfer?>|<grund>"
  rt_is_compose() { return 0; }; export STUB_PG_MAJOR="$1" STUB_FAIL="$2" STUB_IMAGE_PRESENT=0
  # hand-injected: Antwort der docker-Attrappe auf 'compose config' (PostgreSQL-Pin des neuen Stands), kein Wert des geprueften Codes
  export STUB_CONFIG_JSON='{"services":{"postgres":{"image":"postgres:17@sha256:cccc"}}}'
  rt_image_ensure() { return 0; }; unset LIFEAGENTS_UPDATE_LOCK_HELD
  result_set() { [ "$1" = reason_code ] && printf '%s' "$2" > "$W/sv.reason"; return 0; }
  die_because() { printf '%s' "$1" > "$W/sv.reason"; exit 1; }
  rm -rf "$SWAP_DIR" "$W/sv.reason"; : > "$STUB_LOG"; local rc=0
  ( master_swap_begin v9.1.0 "$W/compose.new.src" "$NEW" ) >/dev/null 2>&1 || rc=$?
  printf '%s|%s|%s|%s' "$rc" "$([ -e "$SWAP_STATE" ] && echo ja || echo nein)" \
    "$(grep -q '^docker|run|--rm|-d|' "$STUB_LOG" && echo ja || echo nein)" "$(cat "$W/sv.reason" 2>/dev/null)"
)
eq SV.pg-hauptversion-bricht-vorher-ab '1|nein|nein|pg_major' "$(sv_case 16 '')"
eq SV.abbilder-nicht-ladbar-bricht-vorher-ab '1|nein|nein|net' "$(sv_case 17 '|pull|')"
case "$(sv_case 17 '')" in 0\|ja\|ja\|*) pass SV.alles-da-wechsel-startet ;; *) fail SV.alles-da-wechsel-startet "$(sv_case 17 '')" ;; esac
rm -rf "$SWAP_DIR"

# ---------------------------------------------------------------------------- KB: Sicherung im Tick wie lifeagents-backup.timer
# Ab BACKUP_AUTO_AT stuendlich `backup auto --scheduled`; ob heute schon gesichert ist, entscheidet backup.state (LAST_OK).
# Ohne gewaehlten Ordner kommt so tagsueber der Hinweis an (der 03:30-Lauf liegt ausserhalb von 09-20 Uhr), und ein Lauf, der
# ohne Fehler-Vermerk endete (Zeitgrenze, Neustart des master), wird nachgeholt statt erst morgen.
kb_tick() (   # kb_tick <LAST_OK> <LAST_FAIL> <LAST_FAIL_REASON> -> CLI-Aufrufe der Sicherung
  rt_is_compose() { return 0; }; _ur_cli() { printf '%s' "$W/bin/lifeagents"; }; require_root() { :; }
  local d="$W/kb"; rm -rf "$d"; mkdir -p "$d"
  lifeagents_version_marker() { printf '%s' "$W/kb/V"; }; echo v9.0.0 > "$d/V"
  lifeagents_env_file() { printf '%s' "$W/kb/core.env"; }; printf 'HOUSEHOLD_TIMEZONE=UTC\n' > "$d/core.env"
  UPDATE_TICK_STATE="$d/tick.state"; BACKUP_STATE_FILE="$d/b.state"; BACKUP_AUTO_AT=0000
  env_upsert "$UPDATE_TICK_STATE" LAST_CHECK "$(date -u +%s)"
  env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP "$(TZ=UTC date +%Y-%m-%d)"
  env_upsert "$UPDATE_TICK_STATE" LAST_BACKUP_TRY "$(( $(date -u +%s) - 3700 ))"
  env_upsert "$BACKUP_STATE_FILE" LAST_OK "$1"; [ -z "$2" ] || env_upsert "$BACKUP_STATE_FILE" LAST_FAIL "$2"
  [ -z "$3" ] || env_upsert "$BACKUP_STATE_FILE" LAST_FAIL_REASON "$3"
  : > "$TICK_LOG"; update_tick >/dev/null 2>&1; grep '^cli backup' "$TICK_LOG" | tr '\n' ';'
)
eq KB.ohne-ordner-stuendlich-mit-hinweis 'cli backup auto --scheduled;' "$(kb_tick 100 200 nofolder)"
eq KB.lauf-ohne-vermerk-wird-nachgeholt 'cli backup auto --scheduled;' "$(kb_tick 100 '' '')"
# Die Entscheidung "heute schon gesichert?" trifft --scheduled auch im Verbund; faellig ohne Ordner -> Vermerk + Hinweis-Pruefung.
kb_auto() (   # kb_auto <faellig 0|1> -> "<grund>|<hinweis-aufrufe>"
  rt_is_compose() { return 0; }; local d="$W/kba"; rm -rf "$d"; mkdir -p "$d"; BACKUP_STATE_FILE="$d/b.state"
  _bkp_auto_due() { [ "$KB_DUE" = 1 ]; }; _bkp_host_dir() { :; }; _bkp_resolve_db() { :; }
  _bkp_stale_notify() { echo n >> "$d/n"; }; KB_DUE="$1"
  backup_cmd_auto --scheduled >/dev/null 2>&1
  printf '%s|%s' "$(read_env_value "$BACKUP_STATE_FILE" LAST_FAIL_REASON 2>/dev/null)" "$(cat "$d/n" 2>/dev/null | wc -l | tr -d ' ')"
)
eq KB.geplant-nicht-faellig-tut-nichts '|0' "$(kb_auto 0)"
eq KB.geplant-faellig-ohne-ordner 'nofolder|1' "$(kb_auto 1)"

# ---------------------------------------------------------------------------- RB: Rueckweg im Verbund aus einem Stand ohne Release-Tag
# Im Verbund ist der vorherige Stand das vorherige master-Image samt compose.yml (Merkzettel), kein Download: ein Bestand mit
# VERSION 'dev' (Image ohne -Version gebaut) kommt so zurueck. Klassisch bleibt ein Tag Pflicht (install.sh des Vorgaengers).
rb_case() (   # rb_case <compose 0|1> <from_release> -> erreicht | abbruch:<meldung>
  local d="$W/rb"; rm -rf "$d"; mkdir -p "$d"
  if [ "$1" = 1 ]; then rt_is_compose() { return 0; }; else rt_is_compose() { return 1; }; fi
  require_root() { :; }; lifeagents_db_name() { :; }; N8N_DB_NAME=n8n
  UPGRADE_MARKER="$d/upgrade.pending"; printf 'x' > "$d/b.dump.gpg"; printf 'services: {}\n' > "$d/b.compose.yml"
  printf 'FROM_RELEASE=%s\nBACKUP=%s\nKEY_TABLE=core.backup_key\nFROM_MASTER_IMAGE=reg.example/master@sha256:dddd\nFROM_COMPOSE=%s\n' \
    "$2" "$d/b.dump.gpg" "$d/b.compose.yml" > "$UPGRADE_MARKER"
  update_lock_acquire() { echo erreicht > "$d/out"; return 1; }
  die() { [ -s "$d/out" ] || printf 'abbruch:%s' "$*" > "$d/out"; exit 1; }; die_because() { shift; die "$@"; }
  ( upgrade_rollback --yes ) >/dev/null 2>&1
  [ "$1" = 1 ] || ( upgrade_rollback ) >/dev/null 2>&1 </dev/null
  head -c 60 "$d/out"
)
eq RB.verbund-dev-kommt-zurueck erreicht "$(rb_case 1 dev)"
case "$(rb_case 0 dev)" in abbruch:*) pass RB.klassisch-dev-ohne-rueckweg ;; *) fail RB.klassisch-dev-ohne-rueckweg "$(rb_case 0 dev)" ;; esac
case "$(rb_case 1 '')" in abbruch:*) pass RB.verbund-ohne-version-abbruch ;; *) fail RB.verbund-ohne-version-abbruch "$(rb_case 1 '')" ;; esac

# ---------------------------------------------------------------------------- KU: unterbrochenes Update ohne master-Wechsel
# Starb der Lauf (Zeitgrenze, Neustart) nach upgrade_prepare, steht n8n; der naechste Runner schliesst den Auftrag als
# interrupted und startet n8n wieder (der Merkzettel bleibt, das naechste Update setzt fort).
ku_case() (   # ku_case <merkzettel 0|1> <recovered-json> -> gestartete Dienste
  local d="$W/ku"; rm -rf "$d"; mkdir -p "$d"; UPGRADE_MARKER="$d/upgrade.pending"; [ "$1" = 1 ] && : > "$UPGRADE_MARKER"
  require_root() { :; }; lifeagents_db_name() { :; }; update_lock_acquire() { return 0; }; rt_is_compose() { return 1; }
  _ur_installed() { printf v9.0.0; }; _ur_reports_flush() { :; }; _ur_menu_refresh() { :; }; _ur_alert() { :; }
  _ur_sql() { printf '{"recovered":%s,"claimed":null}' "$KU_REC"; }; KU_REC="$2"
  svc_start() { echo "$*" >> "$d/s"; }
  update_run_requested >/dev/null 2>&1; cat "$d/s" 2>/dev/null
)
eq KU.unterbrochen-mit-merkzettel-n8n-an n8n "$(ku_case 1 '[{"id":3,"tag":"v9.1.0","kind":"update","outcome":"interrupted"}]')"
eq KU.ohne-merkzettel-nichts '' "$(ku_case 0 '[{"id":3,"tag":"v9.1.0","kind":"update","outcome":"interrupted"}]')"
eq KU.nichts-erholt-nichts '' "$(ku_case 1 '[]')"

# ---------------------------------------------------------------------------- SH: Frist fuer den Wechsel-Helfer
# Haengt der Helfer (laeuft, schreibt aber 30 min nichts mehr; Frist wie doctor), haelt er sonst jeden Tick auf "wait" und
# jeden neuen Auftrag dahinter. Nach der Frist: Helfer anhalten, nach dem eigenen Image entscheiden (wie bei einem
# gestorbenen Helfer): Ausgang -> zurueckgerollt (Meldung, n8n an), Ziel -> fortsetzen.
# real-path-test: none (haengender Helfer im echten Verbund nicht nachgestellt; Bericht ob)
sh_case() (   # sh_case <minuten-seit-letztem-schritt> <eigenes-image> -> "<resolve>|<angehalten>"
  rm -rf "$SWAP_DIR"; mkdir -p "$SWAP_DIR"
  printf 'PHASE=swapping\nFROM=%s\nTO=%s\n' "$LA_MASTER_IMAGE" "$NEW" > "$SWAP_STATE"
  if [ "$1" -gt 0 ]; then touch -d "-$1 minutes" "$SWAP_STATE"; fi
  : > "$STUB_LOG"
  local r; r="$(STUB_RUNNING=lifeagents-swap LA_MASTER_IMAGE="$2" master_swap_resolve)"
  printf '%s|%s' "$r" "$(grep -c '^docker|stop|lifeagents-swap' "$STUB_LOG")"
)
eq SH.helfer-frisch-wartet 'wait|0' "$(sh_case 0 "$LA_MASTER_IMAGE")"
eq SH.helfer-haengt-alter-master 'rolled_back|1' "$(sh_case 31 "$LA_MASTER_IMAGE")"
eq SH.helfer-haengt-neuer-master 'apply|1' "$(sh_case 31 "$NEW")"
rm -rf "$SWAP_DIR"

# ---------------------------------------------------------------------------- UO: Optionen von `lifeagents update`/`rollback`
# --help zeigt die Hilfe und aendert nichts; eine unbekannte Option bricht ab, bevor geladen, gesperrt oder gewechselt wird
# (im Verbund startete `update --help` sonst den master-Wechsel, provision.sh sah die Option nie). Weitergereicht werden nur
# Optionen, die provision.sh parse_args fuer einen normalen Lauf kennt.
uo_case() (   # uo_case <args…> -> "<rc>|<fetch-aufruf>"
  fetch_and_run_release() { printf '%s' "$*" > "$W/uo.fetch"; exit 0; }
  die() { exit 1; }; rm -f "$W/uo.fetch"; local rc=0
  ( update_cli "$@" ) >/dev/null 2>&1 || rc=$?
  printf '%s|%s' "$rc" "$(cat "$W/uo.fetch" 2>/dev/null)"
)
eq UO.help-laedt-nichts '0|' "$(uo_case --help)"
eq UO.h-laedt-nichts '0|' "$(uo_case -h)"
eq UO.unbekannt-bricht-vorher-ab '1|' "$(uo_case --bogus)"
eq UO.deinstallieren-nicht-ueber-update '1|' "$(uo_case --uninstall)"
eq UO.ohne-optionen 0\|latest "$(uo_case)"
eq UO.version-und-weitergabe '0|v9.1.0 --profile release --verbose' "$(uo_case --version v9.1.0 --profile release --verbose)"
eq UO.weitergabe-mit-wert '0|latest --packages=finance' "$(uo_case --packages=finance)"
eq UO.weitergabe-wert-fehlt '1|' "$(uo_case --domain)"
uo_rb() (   # uo_rb <args…> -> "<rc>|<weiter?>"
  require_root() { :; }; lifeagents_db_name() { printf weiter > "$W/uo.rb"; exit 7; }
  die() { exit 1; }; rt_is_compose() { return 0; }; rm -f "$W/uo.rb"; local rc=0
  ( upgrade_rollback "$@" ) >/dev/null 2>&1 || rc=$?
  printf '%s|%s' "$rc" "$(cat "$W/uo.rb" 2>/dev/null)"
)
eq UO.rollback-help-aendert-nichts '0|' "$(uo_rb --help)"
eq UO.rollback-unbekannt-bricht-ab '1|' "$(uo_rb --jes)"
eq UO.rollback-yes-laeuft-weiter '7|weiter' "$(uo_rb --yes)"

# ---------------------------------------------------------------------------- HP: Datei in den Rechner-Ordner, nur vollstaendig
# Bricht der docker-Client mitten im Hochladen ab (Zeitgrenze, Neuanlage des master), endet `cat` im Helfer mit EOF und die
# halbe Datei bekam bisher den endgueltigen Namen (am echten Docker belegt: Bericht ob Runde 12). Der Helfer benennt nur um,
# wenn die Pruefsumme stimmt; sonst verschwindet .part. Die Attrappe ersetzt nur Docker: das Helfer-Skript laeuft echt.
hp_case() (   # hp_case <bytes-die-ankommen> <bytes-der-datei> -> "<rc>|<endgueltig>|<part>"
  local d="$W/hp" rc=0; rm -rf "$d"; mkdir -p "$d/out"
  _rt_host_run() {
    [ "$1" = -i ] && shift
    local src="${1#type=bind,src=}"; src="${src%%,*}"; shift
    local a=("$@"); a[2]="${a[2]//\/out/$src}"
    head -c "$HP_CUT" | "${a[@]}"
  }
  head -c "$2" /dev/urandom > "$d/full"; HP_CUT="$1"
  rt_host_put "$d/out" b.nla.enc "$d/full" >/dev/null 2>&1 || rc=$?
  printf '%s|%s|%s' "$([ "$rc" -eq 0 ] && echo 0 || echo fehler)" \
    "$(if [ -e "$d/out/b.nla.enc" ]; then cmp -s "$d/out/b.nla.enc" "$d/full" && echo ganz || echo halb; else echo fehlt; fi)" \
    "$([ -e "$d/out/.b.nla.enc.part" ] && echo ja || echo nein)"
)
eq HP.abgebrochen-kein-gueltiger-name 'fehler|fehlt|nein' "$(hp_case 1000 4000)"
eq HP.vollstaendig-wie-bisher '0|ganz|nein' "$(hp_case 4000 4000)"
eq HP.leere-datei-vollstaendig '0|ganz|nein' "$(hp_case 0 0)"

# ---------------------------------------------------------------------------- VH: Versionsnummer als Gesetz (Release-Profil)
# Echter Code (common.sh, runtime.sh, update_runner.sh update_cli, doctor.sh); Attrappe ist nur docker (Umgebung und Etikett
# des master-Containers). Der echte Weg mit Abbild, Tick und Release-Check: genericity.yml compose-stack-ops, Schritt
# "Update aus dev".
vh_env() {   # vh_env <profil|-> <VERSION|-fehlt|-leer> -> core.env + VERSION unter $W/vh
  rm -rf "$W/vh"; mkdir -p "$W/vh/etc" "$W/vh/lib"
  [ "$1" = - ] || printf 'INSTALL_PROFILE=%s\n' "$1" > "$W/vh/etc/core.env"
  case "$2" in -fehlt) ;; -leer) : > "$W/vh/lib/VERSION" ;; *) printf '%s\n' "$2" > "$W/vh/lib/VERSION" ;; esac
}
vh_ver() { if [ -e "$W/vh/lib/VERSION" ]; then head -n1 "$W/vh/lib/VERSION"; else echo fehlt; fi; }
vh_case() (   # vh_case <profil> <VERSION> <env-tag> <etikett> [systemd] -> "<rc>|<VERSION danach>|<docker-aufrufe>"
  vh_env "$1" "$2"; : > "$STUB_LOG"
  # hand-injected: Umgebung und Etikett des master-Abbilds sind die Eingabe des Falls (echter Weg: genericity.yml Schritt "Update aus dev")
  export LIFEAGENTS_DIR="$W/vh/etc" LIFEAGENTS_RUNTIME="${5:-compose}" STUB_REL_ENV="$3" STUB_REL_LABEL="$4"
  lifeagents_version_marker() { printf '%s' "$W/vh/lib/VERSION"; }; lifeagents_env_file() { printf '%s/%s.env' "$W/vh/etc" "$1"; }
  local rc=0; lifeagents_version_heal >/dev/null 2>&1 || rc=$?
  printf '%s|%s|%s' "$rc" "$(vh_ver)" "$(grep -c '^docker' "$STUB_LOG")"
)
eq VH.dev-aus-umgebung-des-abbilds '0|v9.0.0|1' "$(vh_case release dev v9.0.0 '')"
eq VH.dev-aus-etikett-altes-abbild '0|v0.43.1|1' "$(vh_case release dev '' v0.43.1)"
eq VH.umgebung-dev-etikett-gilt '0|v0.43.1|1' "$(vh_case release dev dev v0.43.1)"
eq VH.leer-wird-nachgetragen '0|v9.0.0|1' "$(vh_case release -leer v9.0.0 '')"
eq VH.keine-quelle-nichts-geschrieben '1|dev|1' "$(vh_case release dev dev '')"
eq VH.etikett-kein-release-nicht-uebernommen '1|dev|1' "$(vh_case release dev '' latest)"
eq VH.entwickler-stand-bleibt '0|dev-0123abc|0' "$(vh_case release dev-0123abc v9.0.0 '')"
eq VH.release-bleibt '0|v1.2.3|0' "$(vh_case release v1.2.3 v9.0.0 '')"
eq VH.dev-profil-unberuehrt '0|dev|0' "$(vh_case dev dev v9.0.0 '')"
eq VH.ohne-installation-nichts '0|fehlt|0' "$(vh_case release -fehlt v9.0.0 '')"
eq VH.klassisch-keine-quelle '1|dev|0' "$(vh_case release dev v9.0.0 '' systemd)"
# Kein Nachtragen mitten in einem Umbau: dann liefe womoeglich schon das Ziel-Abbild (Release-Wechsel ginge verloren).
vh_busy() (   # vh_busy <sperre|wechsel|merkzettel> -> VERSION danach
  vh_env release dev; export LIFEAGENTS_DIR="$W/vh/etc" LIFEAGENTS_RUNTIME=compose STUB_REL_ENV=v9.0.0 STUB_REL_LABEL=''
  lifeagents_version_marker() { printf '%s' "$W/vh/lib/VERSION"; }; lifeagents_env_file() { printf '%s/%s.env' "$W/vh/etc" "$1"; }
  LIFEAGENTS_UPDATE_LOCK="$W/vh/lock"; UPGRADE_MARKER="$W/vh/upgrade.pending"; SWAP_STATE="$W/vh/swap.state"
  case "$1" in
    sperre) flock "$LIFEAGENTS_UPDATE_LOCK" sleep 8 & sleep 0.5 ;;   # laenger als die 5 s, die die Heilung wartet
    wechsel) : > "$SWAP_STATE" ;;
    merkzettel) : > "$UPGRADE_MARKER" ;;
  esac
  lifeagents_version_heal >/dev/null 2>&1; vh_ver; wait
)
eq VH.sperre-belegt-nichts-nachgetragen dev "$(vh_busy sperre)"
eq VH.master-wechsel-nichts-nachgetragen dev "$(vh_busy wechsel)"
eq VH.unvollendetes-update-nichts-nachgetragen dev "$(vh_busy merkzettel)"

# Einstieg: jeder Timer-Modus von `lifeagents update` heilt zuerst (Tick, Release-Check, Auftrag); die Hilfe aendert nichts.
vh_cli() (   # vh_cli <args...> -> "<VERSION danach>|<aufgerufen>"
  vh_env release dev; : > "$STUB_LOG"
  # hand-injected: Umgebung und Etikett des master-Abbilds sind die Eingabe des Falls (echter Weg: genericity.yml Schritt "Update aus dev")
  export LIFEAGENTS_DIR="$W/vh/etc" LIFEAGENTS_RUNTIME=compose STUB_REL_ENV=v9.0.0 STUB_REL_LABEL=''
  lifeagents_version_marker() { printf '%s' "$W/vh/lib/VERSION"; }; lifeagents_env_file() { printf '%s/%s.env' "$W/vh/etc" "$1"; }
  update_check() { echo check >> "$W/vh/called"; }; update_run_requested() { echo run >> "$W/vh/called"; }
  update_tick() { echo tick >> "$W/vh/called"; }
  update_cli "$@" >/dev/null 2>&1 || true
  printf '%s|%s' "$(vh_ver)" "$(tr '\n' ' ' < "$W/vh/called" 2>/dev/null)"
)
eq VH.cli-release-check-heilt-vorher 'v9.0.0|check ' "$(vh_cli --check --scheduled)"
eq VH.cli-tick-heilt-vorher 'v9.0.0|tick ' "$(vh_cli --tick)"
eq VH.cli-auftrag-heilt-vorher 'v9.0.0|run ' "$(vh_cli --run-requested)"
eq VH.cli-hilfe-aendert-nichts 'dev|' "$(vh_cli --help)"

# provision.sh: ein Release-Lauf ohne Versionsnummer nimmt die des Abbilds oder bricht vor jeder Aenderung ab.
vh_resolve() (   # vh_resolve <profil> <RELEASE_TAG|-> <env-tag> [systemd] -> "<rc>|<RELEASE_TAG>|<reason_code>"
  # Eigener bash-Prozess: die_because schreibt den Grund nur in der Haupt-Shell (wie in provision.sh main).
  # hand-injected: Umgebung und Etikett des master-Abbilds sind die Eingabe des Falls (echter Weg: genericity.yml Schritt "Update aus dev")
  export LIFEAGENTS_RUNTIME="${4:-compose}" STUB_REL_ENV="$3" STUB_REL_LABEL='' LIFEAGENTS_RESULT_FILE="$W/vh.result"
  rm -f "$W/vh.result"; if [ "$2" = - ]; then unset RELEASE_TAG; else export RELEASE_TAG="$2"; fi
  local rc=0 tag
  tag="$(bash -c '. "$1/provisioning/lib/common.sh"; release_tag_resolve "$2" 2>/dev/null; printf "%s" "${RELEASE_TAG:-}"' _ "$ROOT" "$1")" || rc=$?
  printf '%s|%s|%s' "$rc" "$tag" "$(read_env_value "$W/vh.result" reason_code 2>/dev/null)"
)
eq VH.lauf-dev-nimmt-abbild-tag '0|v9.0.0|' "$(vh_resolve release dev v9.0.0)"
eq VH.lauf-ohne-tag-nimmt-abbild-tag '0|v9.0.0|' "$(vh_resolve release - v9.0.0)"
eq VH.lauf-ohne-quelle-bricht-ab '1||no_version' "$(vh_resolve release dev dev)"
eq VH.lauf-klassisch-ohne-tag-bricht-ab '1||no_version' "$(vh_resolve release dev v9.0.0 systemd)"
eq VH.lauf-entwickler-stand-bleibt '0|dev-0123abc|' "$(vh_resolve release dev-0123abc v9.0.0)"
eq VH.lauf-dev-profil-unberuehrt '0|dev|' "$(vh_resolve dev dev v9.0.0)"

# doctor: im Release-Profil ist eine fehlende Versionsnummer ROT, mit dem Weg, wie sie wiederkommt; dev-<rev> ist in Ordnung.
vh_doc() (   # vh_doc <profil> <VERSION> <env-tag> [systemd] -> Ausgabe + fail=<n>
  vh_env "$1" "$2"
  ( . "$ROOT/provisioning/doctor.sh" >/dev/null 2>&1
    _fail=0; export LIFEAGENTS_DIR="$W/vh/etc" LIFEAGENTS_RUNTIME="${4:-compose}" STUB_REL_ENV="$3" STUB_REL_LABEL=''; LA_PROJECT=t
    lifeagents_runtime_dir() { printf '%s' "$W/vh/lib"; }
    _doctor_release_version; echo "fail=$_fail" )
)
eq VH.doctor-release-gruen '  [ OK ] Installierte Version: v1.2.3
fail=0' "$(vh_doc release v1.2.3 v9.0.0)"
eq VH.doctor-dev-rot-heilt-selbst '  [FAIL] Keine Versionsnummer eingetragen (VERSION: dev) — Update-Hinweise im Chat kommen so nicht an. Behebt sich selbst: der nächste Durchlauf (höchstens 1 min) trägt v9.0.0 aus dem laufenden Programm-Paket ein.
fail=1' "$(vh_doc release dev v9.0.0)"
eq VH.doctor-dev-rot-ohne-quelle "  [FAIL] Keine Versionsnummer eingetragen (VERSION: dev) — Update-Hinweise im Chat kommen so nicht an. Abhilfe: einmal '$(LA_PROJECT=t rt_master_cli_hint) update'
fail=1" "$(vh_doc release dev dev)"
eq VH.doctor-klassisch-rot "  [FAIL] Keine Versionsnummer eingetragen (VERSION: leer) — Update-Hinweise im Chat kommen so nicht an. Abhilfe: einmal '$(LIFEAGENTS_RUNTIME=systemd rt_cli_hint) update'
fail=1" "$(vh_doc release -leer v9.0.0 systemd)"
eq VH.doctor-entwickler-stand '  [ OK ] Installierte Version: dev-0123abc (Entwickler-Stand)
fail=0' "$(vh_doc release dev-0123abc v9.0.0)"
eq VH.doctor-dev-profil-still 'fail=0' "$(vh_doc dev dev v9.0.0)"
eq VH.doctor-ohne-installation-still 'fail=0' "$(vh_doc release -fehlt v9.0.0)"

# Rueckweg im Verbund auf einen Stand mit FROM_RELEASE=dev: die Nummer kommt aus dem Ziel-Abbild, bevor Daten angefasst werden;
# fehlt sie auch dort, Abbruch vorher (sonst braeche release_tag_resolve erst nach dem Zuruecksetzen ab).
vh_rb() (   # vh_rb <FROM_RELEASE> <env-tag des Ziel-Abbilds> -> "daten:<ziel>" | "<grund>|abbruch:<meldung>"
  local d="$W/vhrb"; rm -rf "$d"; mkdir -p "$d/etc"
  # hand-injected: Umgebung und Etikett des master-Abbilds sind die Eingabe des Falls (echter Weg: genericity.yml Schritt "Update aus dev")
  export LIFEAGENTS_RUNTIME=compose STUB_REL_ENV="$2" STUB_REL_LABEL='' STUB_IMAGE_PRESENT=1
  printf 'INSTALL_PROFILE=release\n' > "$d/etc/core.env"; lifeagents_env_file() { printf '%s/%s.env' "$d/etc" "$1"; }
  require_root() { :; }; N8N_DB_NAME=n8n
  UPGRADE_MARKER="$d/upgrade.pending"; printf 'x' > "$d/b.dump.gpg"; printf 'services: {}\n' > "$d/b.compose.yml"
  printf 'FROM_RELEASE=%s\nBACKUP=%s\nKEY_TABLE=core.backup_key\nFROM_MASTER_IMAGE=reg.example/master@sha256:dddd\nFROM_COMPOSE=%s\n' \
    "$1" "$d/b.dump.gpg" "$d/b.compose.yml" > "$UPGRADE_MARKER"
  update_lock_acquire() { return 0; }; backup_key_read() { echo k; }; gpg_sym_decrypt_any() { _BK_HIT_KEY=k; return 0; }
  # shellcheck disable=SC2154  # from_rel ist eine lokale Variable von upgrade_rollback (dynamischer Geltungsbereich)
  pg_su_exec() { [ -s "$d/out" ] || printf 'daten:%s' "$from_rel" > "$d/out"; exit 0; }
  pg_su_psql() { pg_su_exec "$@"; }
  die() { [ -s "$d/out" ] || printf 'abbruch:%s' "$*" > "$d/out"; exit 1; }; die_because() { printf '%s|' "$1" > "$d/why"; shift; die "$@"; }
  ( upgrade_rollback --yes ) >/dev/null 2>&1
  printf '%s%s' "$(cat "$d/why" 2>/dev/null)" "$(head -c 40 "$d/out")"
)
eq VH.rueckweg-dev-nimmt-nummer-des-ziels 'daten:v0.43.1' "$(vh_rb dev v0.43.1)"
eq VH.rueckweg-mit-nummer-unveraendert 'daten:v1.2.3' "$(vh_rb v1.2.3 v0.43.1)"
case "$(vh_rb dev '')" in 'no_version|abbruch:'*) pass VH.rueckweg-ohne-nummer-vor-den-daten ;; *) fail VH.rueckweg-ohne-nummer-vor-den-daten "$(vh_rb dev '')" ;; esac

# ---------------------------------------------------------------------------- IK: lifeagents images keep (Liste "wird noch gebraucht")
# Echter Code (images_cli.sh) gegen erfundene Dateien in der Form, die upgrade_guard.sh und master_swap.sh schreiben. Der echte
# Weg (Update ueber zwei Staende, jedes gelistete Abbild vorhanden, Rueckweg nur mit diesen): Bericht ob Runde 15.
[ -f "$ROOT/provisioning/lib/images_cli.sh" ] && . "$ROOT/provisioning/lib/images_cli.sh"
ik_compose() {   # ik_compose <datei> <master-zeile> <postgres-digest>
  printf '%s\n' 'name: lifeagents' '' 'x-images:' \
    '  busybox: &img_busybox busybox:1.37@sha256:b1' "  postgres: &img_postgres postgres:17@sha256:$3" \
    '  n8n: &img_n8n n8nio/n8n:2.45.7@sha256:n1' '  # Kommentarzeile im Block' "  master: &img_master $2" '' 'services:' '  anchor:' '    image: *img_busybox' > "$1"
}
ik_case() (   # ik_case [--plain] -> Ausgabe von images keep
  local d="$W/ik"; rm -rf "$d"; mkdir -p "$d/bk" "$d/swap" "$d/state"
  # hand-injected: im master setzt compose.yml LA_MASTER_IMAGE (laufendes Abbild); der Fall gibt es wie dort vor
  export LIFEAGENTS_RUNTIME=compose LA_MASTER_IMAGE='reg.example/master@sha256:cccc'
  require_root() { :; }
  LA_COMPOSE_FILE="$d/compose.yml"; UPGRADE_BACKUP_DIR="$d/bk"; UPGRADE_STATE_DIR="$d/state"; UPGRADE_MARKER="$d/state/upgrade.pending"
  SWAP_DIR="$d/swap"; SWAP_STATE="$d/swap/state"
  ik_compose "$LA_COMPOSE_FILE" '${LA_MASTER_IMAGE:-reg.example/master@sha256:cccc}' p3
  # Zwei aufbewahrte Sicherungen (Stand a -> b, Stand b -> c) samt Merkzettel-Kopie.
  ik_compose "$d/bk/pre-upgrade-1.dump.gpg.compose.yml" '${LA_MASTER_IMAGE:-reg.example/master@sha256:aaaa}' p1
  printf 'FROM_RELEASE=v9.0.0\nFROM_MASTER_IMAGE=reg.example/master@sha256:aaaa\n' > "$d/bk/pre-upgrade-1.dump.gpg.meta"
  ik_compose "$d/bk/pre-upgrade-2.dump.gpg.compose.yml" '${LA_MASTER_IMAGE:?neutral}' p2
  printf 'FROM_RELEASE=v9.1.0\nFROM_MASTER_IMAGE=ci-ops-master:b\n' > "$d/bk/pre-upgrade-2.dump.gpg.meta"
  : > "$d/bk/pre-upgrade-1.dump.gpg"; : > "$d/bk/pre-upgrade-2.dump.gpg"
  ik_compose "$d/swap/compose.prev.yml" '${LA_MASTER_IMAGE:-reg.example/master@sha256:bbbb}' p2
  images_cli keep "$@" 2>/dev/null
)
ik_out="$(ik_case)"
eq IK.json-ok true "$(printf '%s' "$ik_out" | jq -r .ok 2>/dev/null)"
eq IK.alle-abbilder 'busybox:1.37@sha256:b1 ci-ops-master:b n8nio/n8n:2.45.7@sha256:n1 postgres:17@sha256:p1 postgres:17@sha256:p2 postgres:17@sha256:p3 reg.example/master@sha256:aaaa reg.example/master@sha256:bbbb reg.example/master@sha256:cccc' \
  "$(printf '%s' "$ik_out" | jq -r '[.images[].ref] | join(" ")' 2>/dev/null)"
eq IK.laufender-master-ist-helfer-abbild 'current running swap_helper' \
  "$(printf '%s' "$ik_out" | jq -r '.images[] | select(.ref == "reg.example/master@sha256:cccc") | .sources | join(" ")' 2>/dev/null)"
eq IK.rueckweg-ziel-aus-merkzettel 'backup:pre-upgrade-2.dump.gpg' \
  "$(printf '%s' "$ik_out" | jq -r '.images[] | select(.ref == "ci-ops-master:b") | .sources | join(" ")' 2>/dev/null)"
eq IK.neutrale-zeile-keine-referenz 0 "$(printf '%s' "$ik_out" | jq '[.images[].ref | select(test("LA_MASTER"))] | length' 2>/dev/null)"
eq IK.plain-eine-je-zeile 9 "$(ik_case --plain | grep -c .)"
eq IK.klassisch-abgelehnt '{"ok":false,"reason":"not_compose"}|1' \
  "$( ( LIFEAGENTS_RUNTIME=systemd; rc=0; out="$(images_cli keep 2>/dev/null)" || rc=$?; printf '%s|%s' "$out" "$rc" ) )"
# Offener Wechsel und unvollendetes Update ohne Sicherung: Ziel und vorheriger Stand bleiben gelistet.
ik_open() (
  local d="$W/ik2"; rm -rf "$d"; mkdir -p "$d/bk" "$d/swap" "$d/state"
  # hand-injected: im master setzt compose.yml LA_MASTER_IMAGE (laufendes Abbild); der Fall gibt es wie dort vor
  export LIFEAGENTS_RUNTIME=compose LA_MASTER_IMAGE='m:old'; require_root() { :; }
  LA_COMPOSE_FILE="$d/compose.yml"; UPGRADE_BACKUP_DIR="$d/bk"; UPGRADE_STATE_DIR="$d/state"; UPGRADE_MARKER="$d/state/upgrade.pending"
  SWAP_DIR="$d/swap"; SWAP_STATE="$d/swap/state"
  ik_compose "$LA_COMPOSE_FILE" '${LA_MASTER_IMAGE:-m:old}' p3
  ik_compose "$d/swap/compose.new.yml" '${LA_MASTER_IMAGE:-m:new}' p4
  printf 'PHASE=handoff\nFROM=m:old\nTO=m:new\n' > "$SWAP_STATE"
  ik_compose "$d/state/upgrade.pending.compose.yml" '${LA_MASTER_IMAGE:-m:older}' p5
  printf 'FROM_MASTER_IMAGE=m:older\nFROM_COMPOSE=%s\n' "$d/state/upgrade.pending.compose.yml" > "$UPGRADE_MARKER"
  images_cli keep --plain 2>/dev/null | tr '\n' ' '
)
eq IK.offener-wechsel-und-merkzettel 'busybox:1.37@sha256:b1 m:new m:old m:older n8nio/n8n:2.45.7@sha256:n1 postgres:17@sha256:p3 postgres:17@sha256:p4 postgres:17@sha256:p5 ' "$(ik_open)"
# ---------------------------------------------------------------------------- CL: Befehl in Meldungen je Betriebsart
# Eine Adresse (rt_cli_hint): klassisch `sudo lifeagents`, Verbund `docker exec -i <projekt>-master lifeagents`; -it fuer Befehle
# mit Rueckfrage (rollback/reconfigure brechen mit nur -i ab). Der Runner gibt beide Formen an core.fn_update_report mit.
cl_hint() ( if [ "$1" = 1 ]; then rt_is_compose() { return 0; }; else rt_is_compose() { return 1; }; fi; LA_PROJECT=la-x; rt_cli_hint "${2:-}" )
eq CL.klassisch 'sudo lifeagents' "$(cl_hint 0)"
eq CL.klassisch-tty 'sudo lifeagents' "$(cl_hint 0 tty)"
eq CL.verbund 'docker exec -i la-x-master lifeagents' "$(cl_hint 1)"
eq CL.verbund-tty 'docker exec -it la-x-master lifeagents' "$(cl_hint 1 tty)"
eq CL.master-hint-unveraendert 'docker exec -i la-x-master lifeagents' "$(LA_PROJECT=la-x rt_master_cli_hint)"
cl_report() (   # cl_report <compose 0|1> -> das p, das _ur_report an die DB gibt (cli|cli_tty)
  if [ "$1" = 1 ]; then rt_is_compose() { return 0; }; else rt_is_compose() { return 1; }; fi; LA_PROJECT=la-x
  _ur_sql() { case "$2" in *'fn_update_report('*) printf '%s' "$1" > "$W/cl.p"; printf '{}' ;; esac; }
  _ur_send() { return 1; }; _up_close() { :; }; rm -f "$W/cl.p"
  _ur_report 7 result bot_up=false >/dev/null 2>&1
  jq -r '"\(.cli)|\(.cli_tty)"' "$W/cl.p" 2>/dev/null
)
eq CL.runner-klassisch 'sudo lifeagents|sudo lifeagents' "$(cl_report 0)"
eq CL.runner-verbund 'docker exec -i la-x-master lifeagents|docker exec -it la-x-master lifeagents' "$(cl_report 1)"
# ---------------------------------------------------------------------------- HL: Halt-Nachricht, wenn eine Pflichtangabe fehlt
# Unbeaufsichtigtes Update haelt an: Telegram-Text aus dem Katalog in der Owner-Sprache, Befehl je Betriebsart aus rt_cli_hint
# (reconfigure fragt nach -> -it), "an deinen Daten", kein "Server" im Verbund.
hl_case() (   # hl_case <compose 0|1> <lang> -> der Telegram-Text
  if [ "$1" = 1 ]; then rt_is_compose() { return 0; }; else rt_is_compose() { return 1; }; fi; LA_PROJECT=la-x
  _pkg_dir() { printf '%s' "$ROOT/packages"; }
  backup_kit_lang() { printf '%s' "$HL_LANG"; }; HL_LANG="$2"   # Owner-Sprache aus der DB: eigene Faelle in tests/backup
  LIFEAGENTS_DIR="$W/hl"; rm -rf "$LIFEAGENTS_DIR"; mkdir -p "$LIFEAGENTS_DIR"; LIFEAGENTS_UPDATE_REQUESTED=0
  notify_owner_telegram() { printf '%s' "$1" > "$W/hl.msg"; return 0; }; rm -f "$W/hl.msg"
  ( _hold_update_for_missing_keys ANTHROPIC_API_KEY 'Anthropic-Schlüssel' ) >/dev/null 2>&1
  cat "$W/hl.msg" 2>/dev/null
)
hl_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "fehlt '$3' in: $2" ;; esac; }
hl_not() { case "$2" in *"$3"*) fail "$1" "unerwartet '$3' in: $2" ;; *) pass "$1" ;; esac; }
HLC="$(hl_case 0 de)"; HLD="$(hl_case 1 de)"; HLE="$(hl_case 1 en)"
hl_has HL.klassisch-befehl "$HLC" $'\nsudo lifeagents reconfigure\n'
hl_has HL.klassisch-server "$HLC" 'Server'
hl_has HL.klassisch-daten "$HLC" 'An deinen Daten wurde nichts geändert'
hl_has HL.klassisch-angabe "$HLC" 'Anthropic-Schlüssel'
hl_has HL.verbund-befehl "$HLD" $'\ndocker exec -it la-x-master lifeagents reconfigure\n'
hl_not HL.verbund-kein-server "$HLD" 'Server'
hl_not HL.verbund-kein-sudo "$HLD" 'sudo'
hl_has HL.verbund-ort "$HLD" 'PowerShell'
hl_has HL.verbund-englisch "$HLE" 'docker exec -it la-x-master lifeagents reconfigure'
hl_not HL.verbund-englisch-kein-deutsch "$HLE" 'wartet'

# ---------------------------------------------------------------------------- RH: Rueckweg-Hinweis im Verbund
# Scheitert n8n nach einem Versionswechsel, druckt upgrade_rollback_hint den Rueckweg. Im Verbund gibt es kein systemctl,
# runuser, dropdb oder install.sh: dort nur der Befehl, der hier laeuft (rollback mit -it, fragt nach), und wo das Protokoll
# steht. Geht `lifeagents rollback` nicht (kein vorheriges Programm-Paket im Merkzettel), wird er nicht versprochen.
rh_case() (   # rh_case <compose 0|1> <from_release> <master-image|-> -> Ausgabe des Hinweises
  local d="$W/rh"; rm -rf "$d"; mkdir -p "$d"
  if [ "$1" = 1 ]; then rt_is_compose() { return 0; }; else rt_is_compose() { return 1; }; fi; LA_PROJECT=la-x
  UPGRADE_MARKER="$d/upgrade.pending"; printf 'x' > "$d/b.dump.gpg"
  { printf 'FROM_RELEASE=%s\nBACKUP=%s\nKEY_TABLE=core.backup_key\n' "$2" "$d/b.dump.gpg"
    [ "$3" = - ] || printf 'FROM_MASTER_IMAGE=%s\nFROM_COMPOSE=%s\n' "$3" "$d/b.compose.yml"; } > "$UPGRADE_MARKER"
  ui_fd() { echo 2; }; RELEASE_TAG=v9.9.9; N8N_DB_NAME=n8n
  upgrade_rollback_hint 2>&1
)
rh_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "fehlt '$3' in: $2" ;; esac; }
rh_not() { case "$2" in *"$3"*) fail "$1" "unerwartet '$3' in: $2" ;; *) pass "$1" ;; esac; }
RHV="$(rh_case 1 v0.40.0 reg.example/master@sha256:dddd)"
rh_has RH.verbund-befehl "$RHV" 'docker exec -it la-x-master lifeagents rollback'
rh_has RH.verbund-ort "$RHV" 'PowerShell'
rh_has RH.verbund-protokoll "$RHV" 'docker logs'
for w in systemctl runuser dropdb install.sh journalctl; do rh_not "RH.verbund-ohne-$w" "$RHV" "$w"; done
RHD="$(rh_case 1 dev reg.example/master@sha256:dddd)"
rh_has RH.verbund-dev-befehl "$RHD" 'lifeagents rollback'
RHN="$(rh_case 1 v0.40.0 -)"
rh_not RH.verbund-ohne-merkzettel-kein-befehl "$RHN" 'lifeagents rollback'
rh_has RH.verbund-ohne-merkzettel-sicherung "$RHN" "$W/rh/b.dump.gpg"
for w in systemctl dropdb install.sh; do rh_not "RH.verbund-ohne-merkzettel-ohne-$w" "$RHN" "$w"; done
RHG="$(rh_case 1 v0.9.0 reg.example/master@sha256:dddd)"
rh_not RH.verbund-alt-ohne-journalctl "$RHG" 'journalctl'
rh_has RH.verbund-alt-kein-rueckweg "$RHG" 'KEIN RÜCKWEG'
RHK="$(rh_case 0 v0.40.0 -)"
rh_has RH.klassisch-unveraendert "$RHK" 'dropdb'

# ---------------------------------------------------------------------------- SU: Linux-Einrichter (setup.sh)
. "$(dirname "${BASH_SOURCE[0]}")/setup_cases.sh"

exit "$fails"
