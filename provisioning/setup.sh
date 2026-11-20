#!/usr/bin/env bash
# setup.sh — Einrichter fuer einen Linux-Server (Docker-Verbund). Kein Sourcing, ein Release-Asset (stabiler Einstieg:
# .../releases/latest/download/setup.sh). Er prueft den Rechner, richtet fehlendes Docker aus Dockers apt-Paketquelle ein,
# ruft den Kern des Verbunds (`stack up`, Aufruf-Form im Kopf von compose/stack.sh) und gibt den SSH-Befehl fuer den Fragebogen aus.
#
# Aufruf als root auf Debian 12/13 oder Ubuntu 22.04/24.04 (amd64, arm64), nie `| bash` (ein abgebrochener Download liefe halb):
#   curl -fsSL https://github.com/<slug>/releases/latest/download/setup.sh -o setup.sh && bash setup.sh
#   bash setup.sh --yes                       # Docker ohne Rueckfrage einrichten
#   bash setup.sh --answers antworten.env     # statt Fragebogen: Antwort-Datei (nach `--` Optionen fuer provision.sh)
#   bash setup.sh --uninstall [--delete-data] # Verbund entfernen; Docker bleibt
# Optionen: --yes, --image <ref> (Entwickler/CI; Releases tragen den Pin), --answers <datei>, --uninstall, --delete-data, --help.
# Test-Naehte (nicht in der Hilfe): LA_PROJECT, LA_CORE_PORTS (an den Kern), LA_SETUP_ROOT (Pfad-Praefix), LA_SETUP_WAIT,
# dazu die Test-Weichen TEST_SWITCHES (nur als Name an den Kern, der sie an provision.sh reicht).
# Exit: 0 gelungen, 1 gescheitert (nichts oder nur Vollendetes geaendert), 2 Aufruf falsch.
#
# Neben dem Verbund legt er zwei Dateien an, beide mit Markierung (fremde Dateien gleichen Namens fasst er nie an):
# /usr/local/bin/lifeagents (reicht Befehle in den master durch) und die Systemd-Einheit lifeagents-stack.service, die nach
# jedem Start von Docker einmal `stack start` fuehrt: Startet Docker einen Container des Pods vor dem anchor, scheitert er
# beim Wiederanlauf (Exit 128) und wird nicht wiederholt.
set -euo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive
trap 'rc=$?; printf "\n[x] setup.sh: unerwarteter Abbruch bei Zeile %s (Exit %s).\n" "$LINENO" "$rc" >&2' ERR

# Das Release setzt hier den Abbild-Pin ein (scripts/lib/release_images.ps1 Set-SetupPin); im Baum bleibt er leer, weil das
# master-Abbild immer die neutrale Form dieser Datei traegt.
MASTER_IMAGE_PIN=''

# Kopie von SC_TEST_SWITCHES (lib/stack_core.sh; setup.sh sourct nichts), Gleichheit prueft tests/mock_runtime/setup_cases.sh.
TEST_SWITCHES="LIFEAGENTS_TELEGRAM_API LIFEAGENTS_LLM_UPSTREAM"
R="${LA_SETUP_ROOT:-}"
P="${LA_PROJECT:-lifeagents}"
MARK='managed by lifeagents setup.sh'
CMD_FILE="$R/usr/local/bin/lifeagents"
UNIT_NAME=lifeagents-stack.service
UNIT_FILE="$R/etc/systemd/system/$UNIT_NAME"
STATE_DIR="$R/var/lib/lifeagents-setup"
PULLED_FILE="$STATE_DIR/pulled-image"

if [ -t 2 ]; then _G=$'\033[0;32m'; _Y=$'\033[0;33m'; _RD=$'\033[0;31m'; _C=$'\033[0;36m'; _N=$'\033[0m'; else _G='' _Y='' _RD='' _C='' _N=''; fi
log()  { printf '%s[*]%s %s\n' "$_C" "$_N" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$_G" "$_N" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$_Y" "$_N" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$_RD" "$_N" "$*" >&2; exit 1; }

usage() {
  cat <<'TXT'
Aufruf: bash setup.sh [--yes] [--image <abbild>] [--answers <datei> [-- <optionen fuer provision.sh>]]
        bash setup.sh --uninstall [--delete-data] [--yes]

  --yes             Rueckfragen mit Ja beantworten (Docker einrichten, Daten loeschen)
  --image <abbild>  master-Abbild statt des eingebauten (nur Entwickler/CI)
  --answers <datei> Antwort-Datei statt Fragebogen; Vorgabe fuer provision.sh ist --profile release
  --uninstall       Verbund entfernen (Daten bleiben); Docker selbst bleibt
  --delete-data     mit --uninstall: auch alle Daten loeschen (unwiderruflich)
  --help            diese Hilfe
TXT
}
usage_err() { printf '%s[x]%s %s\n\n' "$_RD" "$_N" "$1" >&2; usage >&2; exit 2; }

YES=0 IMAGE_ARG='' ANSWERS='' UNINSTALL=0 DELETE_DATA=0 PROV=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --image) [ "$#" -ge 2 ] || usage_err "--image braucht ein Abbild."; IMAGE_ARG="$2"; shift ;;
    --answers) [ "$#" -ge 2 ] || usage_err "--answers braucht eine Datei."; ANSWERS="$2"; shift ;;
    --uninstall) UNINSTALL=1 ;;
    --delete-data) DELETE_DATA=1 ;;
    --help|-h) usage; exit 0 ;;
    --) shift; PROV=("$@"); break ;;
    *) usage_err "Unbekannte Option: $1" ;;
  esac
  shift
done
[ "$DELETE_DATA" = 0 ] || [ "$UNINSTALL" = 1 ] || usage_err "--delete-data gibt es nur mit --uninstall."
[ -z "$ANSWERS" ] || [ "$UNINSTALL" = 0 ] || usage_err "--answers und --uninstall schliessen sich aus."
[ "${#PROV[@]}" -eq 0 ] || [ -n "$ANSWERS" ] || usage_err "Optionen nach -- gibt es nur zusammen mit --answers."
# Eine Referenz, die mit - beginnt, wuerde Docker als Option lesen.
[ -z "$IMAGE_ARG" ] || [[ "$IMAGE_ARG" =~ ^[a-z0-9][A-Za-z0-9._:/@-]*$ ]] || usage_err "--image: ungueltige Abbild-Referenz."
[ -z "$ANSWERS" ] || [ -r "$ANSWERS" ] || die "Antwort-Datei nicht lesbar: $ANSWERS"

# ask <frage> <hinweis-ohne-terminal> — ja = 0. Ohne --yes und ohne Terminal nie raten.
ask() {
  local a=''
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || die "$1 Ohne Terminal nur mit --yes."
  printf '%s [j/N] ' "$1" >&2
  read -r a || true
  case "$a" in j|J|ja|Ja|JA|y|Y|yes) return 0 ;; esac
  return 1
}

reason_text() {
  case "$1" in
    docker_unreachable) echo "Docker antwortet nicht. Läuft der Dienst? Prüfen mit: systemctl status docker" ;;
    docker_windows_mode) echo "Docker läuft im Windows-Modus; hier werden Linux-Container gebraucht." ;;
    docker_too_old) echo "Docker ist zu alt (mindestens Version 26). Bitte Docker aus Dockers Paketquelle aktualisieren." ;;
    docker_capability) echo "Docker kann hier keine Unterpfade eines Speichers einhängen (zu alte Engine oder ein zu streng eingestellter Container)." ;;
    docker_socket) echo "Der Docker-Anschluss (Socket) ist in einem Hilfs-Container nicht erreichbar." ;;
    disk_low) echo "Zu wenig freier Platz: mindestens 10 GB werden gebraucht." ;;
    foreign_objects) echo "Ein Speicher mit dem Namen des Verbunds gehört nicht zu uns und bleibt unangetastet. Bitte umbenennen oder entfernen." ;;
    values_lost) echo "Die Datenbank ist da, aber das gemerkte Passwort fehlt. Es wird nie ein neues erzeugt, sonst wären die Daten unlesbar. Aus einer Sicherung wiederherstellen oder mit --uninstall --delete-data neu beginnen." ;;
    port_none_free) echo "Von den Ports 5880 bis 5899 sind nicht zwei frei." ;;
    busy) echo "Ein anderer Lauf (Einrichtung oder Update) arbeitet gerade. Später noch einmal versuchen." ;;
    legacy_installation) echo "Es läuft eine Installation aus der Zeit vor diesem Einrichter. Sie wird per Update im Chat aktualisiert; setup.sh legt sie nicht neu an." ;;
    newer_installation) echo "Auf diesem Rechner steht eine neuere Fassung als die dieses Einrichters. Bitte die aktuelle setup.sh laden." ;;
    older_installation) echo "Auf diesem Rechner liegen Daten einer älteren Fassung ohne laufende Installation. Das setzt setup.sh nicht fort." ;;
    pull_failed) echo "Ein Abbild ließ sich nicht laden. Netzwerk prüfen und noch einmal starten." ;;
    start_failed) echo "Die Dienste ließen sich nicht starten." ;;
    db_unhealthy) echo "Die Datenbank wurde nicht gesund." ;;
    not_installed) echo "Hier ist noch nichts installiert." ;;
    master_not_running) echo "Das Steuer-Programm (master) läuft nicht." ;;
    install_failed) echo "Die Einrichtung im master endete mit einem Fehler (Ausgabe oben)." ;;
    in_master) echo "Dieser Befehl darf nicht im master laufen." ;;
    data_kept) echo "Mindestens ein Daten-Speicher blieb stehen (Grund oben)." ;;
    internal) echo "Unerwarteter Fehler im Kern." ;;
    *) echo "Der Kern meldete den Grund '$1'." ;;
  esac
}

# --- Rechner pruefen (vor jeder Aenderung) --------------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "setup.sh muss als root laufen (sudo bash setup.sh …)."

OS_ID='' OS_VER='' OS_CODE=''
if [ -r "$R/etc/os-release" ]; then
  # shellcheck source=/dev/null  # os-release liegt im Test unter LA_SETUP_ROOT
  OS_ID="$(. "$R/etc/os-release"; echo "${ID:-}")"
  # shellcheck source=/dev/null
  OS_VER="$(. "$R/etc/os-release"; echo "${VERSION_ID:-}")"
  # shellcheck source=/dev/null
  OS_CODE="$(. "$R/etc/os-release"; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
fi
case "$OS_ID:$OS_VER" in
  debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
  *) die "Unterstützt sind Debian 12/13 und Ubuntu 22.04/24.04 (amd64, arm64). Hier: ${OS_ID:-unbekannt} ${OS_VER}." ;;
esac
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64|arm64) ;; *) die "Unterstützt sind amd64 und arm64, hier ist es $ARCH." ;; esac
if [ -e "$R/etc/lifeagents/core.env" ] || [ -e "$R/etc/systemd/system/n8n.service" ]; then
  die "Auf diesem Rechner läuft eine klassische Installation (n8n als Systemdienst). setup.sh richtet sie nicht neu ein und ändert nichts; der Umzug ist ein eigener Schritt."
fi
# Fremde Dateien gleichen Namens nie ueberschreiben oder entfernen: erst pruefen, dann arbeiten.
foreign_check() { [ ! -e "$1" ] || grep -q "$MARK" "$1" || die "$1 gehört nicht zu setup.sh und wird nicht überschrieben."; }
if [ "$UNINSTALL" = 0 ]; then foreign_check "$CMD_FILE"; foreign_check "$UNIT_FILE"; fi

if command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1; then
  die "Docker ist als Snap installiert. Das wird nicht unterstützt (anderer Socket, eingeschränkte Rechte). Bitte das Snap entfernen und Docker aus Dockers Paketquelle nehmen."
fi

# Docker braucht curl und jq (JSON des Kerns lesen).
apt_updated=0
for t in curl jq; do
  "$t" --version >/dev/null 2>&1 && continue
  command -v apt-get >/dev/null 2>&1 || die "$t fehlt und apt-get ist nicht da."
  # Frische Cloud-Abbilder haben keine Paketlisten: ohne update fände apt kein Paket.
  if [ "$apt_updated" = 0 ]; then apt-get update -qq >&2; apt_updated=1; fi
  log "Installiere $t …"; apt-get install -y -qq "$t" >&2
done

# --- Docker ---------------------------------------------------------------------------------------------------------------
install_docker() {
  local pkg src
  [ -d "$R/run/systemd/system" ] || die "Docker lässt sich hier nicht einrichten: systemd läuft nicht."
  # Dockers Anleitung nennt diese Pakete als Konflikt; apt -y entfernte sie ohne Nachfrage (auch containerd und runc anderer Programme).
  for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    ! dpkg -s "$pkg" >/dev/null 2>&1 || die "Das Paket $pkg steht im Weg (widerspricht Dockers Paketen). Bitte entfernen: apt-get remove $pkg"
  done
  ask "Docker ist nicht eingerichtet. Jetzt aus Dockers offizieller Paketquelle (download.docker.com) einrichten?" || die "Ohne Docker geht es nicht weiter."
  log "Richte Docker aus der offiziellen Paketquelle ein …"
  apt-get update -qq >&2
  apt-get install -y -qq ca-certificates curl >&2
  # Eine zweite Quelle fuer dieselbe Adresse mit anderem Signed-By laesst apt abbrechen.
  if ! grep -rqs 'download.docker.com' "$R/etc/apt/sources.list" "$R/etc/apt/sources.list.d" 2>/dev/null; then
    install -m 0755 -d "$R/etc/apt/keyrings"
    curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o "$R/etc/apt/keyrings/docker.asc"
    chmod a+r "$R/etc/apt/keyrings/docker.asc"
    src="$R/etc/apt/sources.list.d/docker.sources"
    printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
      "$OS_ID" "$OS_CODE" "$ARCH" > "$src"
    apt-get update -qq >&2
  fi
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >&2
  systemctl enable --now docker >&2
}
docker_ready() {
  docker version >/dev/null 2>&1 && return 0
  if dpkg -s docker-ce >/dev/null 2>&1; then
    [ -d "$R/run/systemd/system" ] && systemctl enable --now docker >&2 || true
  else
    [ "$UNINSTALL" = 0 ] || die "Docker ist nicht da, also gibt es auch nichts zu entfernen."
    install_docker
  fi
  docker version >/dev/null 2>&1 || die "Docker antwortet nicht. Prüfen mit: systemctl status docker"
}
docker_ready

# --- Abbild und Kern ------------------------------------------------------------------------------------------------------
master_image() { docker inspect -f '{{.Config.Image}}' "$P-master" 2>/dev/null || true; }
IMAGE="${IMAGE_ARG:-$MASTER_IMAGE_PIN}"
if [ -z "$IMAGE" ] && [ "$UNINSTALL" = 1 ]; then IMAGE="$(master_image)"; fi
[ -n "$IMAGE" ] || die "Dieses setup.sh trägt keinen Abbild-Pin (Entwicklungsstand). Mit --image <abbild> starten oder das Release-Asset laden."
if docker inspect "$P-core" >/dev/null 2>&1; then
  die "Ein anderer Lauf ist aktiv oder hat einen Rest hinterlassen (Container $P-core). Warten oder: docker rm -f $P-core"
fi

OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
STEPS='{"lock":"Sperre prüfen","delegate":"Installierte Fassung prüfen","check":"Docker prüfen","values":"Werte anlegen","volumes":"Speicher","start":"Dienste starten","answers":"Antworten übergeben","provision":"Einrichten","webhook":"Telegram lösen","containers":"Container entfernen","images":"Abbilder entfernen"}'
# core <stdin-datei> <verb> [optionen] — der Kern in der einen Aufruf-Form; Ergebnis in $OUT, Fortschritt auf stderr.
core() {
  local in="$1" rc k a=(run --rm -i --name "$P-core" --label "io.lifeagents.install=$P" --env LA_CORE=1)
  shift
  [ -z "${LA_PROJECT:-}" ] || a+=(--env LA_PROJECT)
  [ -z "${LA_CORE_PORTS:-}" ] || a+=(--env LA_CORE_PORTS)
  for k in $TEST_SWITCHES; do [ -z "${!k:-}" ] || a+=(--env "$k"); done
  a+=(--mount "type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock" "$IMAGE" stack "$@")
  set +e
  docker "${a[@]}" < "$in" | tee "$OUT" | jq -Rr --unbuffered --argjson s "$STEPS" 'fromjson? | select(type == "object" and .type == "progress") | (.step // "" | tostring) as $k | "    · " + ($s[$k] // $k)' >&2
  rc="${PIPESTATUS[0]}"
  set -e
  return "$rc"
}
# core_verdict <exit> — wertet das eine result aus; 0 = ok, sonst Meldung und 1. RES = result-Zeile.
RES=''
core_verdict() {
  local rc="$1" reason
  RES="$(jq -Rc 'fromjson? | select(type == "object" and .type == "result")' "$OUT" | tail -n1)"
  if [ -z "$RES" ]; then
    err_core "Docker meldete einen Fehler (Exit $rc), bevor der Kern ein Ergebnis lieferte. Meist ist es das Laden des Abbilds ($IMAGE) oder der Docker-Dienst selbst."
    return 1
  fi
  [ "$(jq -r '.ok' <<<"$RES")" = true ] && return 0
  reason="$(jq -r '.reason // "internal"' <<<"$RES")"
  err_core "$(reason_text "$reason")"
  case "$reason" in docker_capability|docker_socket)
    if [ "$(systemd-detect-virt -c 2>/dev/null || true)" = lxc ]; then
      warn "Das ist ein LXC-Container. Docker braucht dort nesting=1,keyctl=1; Proxmox empfiehlt für Docker eine VM."
    fi ;;
  esac
  return 1
}
err_core() { printf '%s[x]%s %s\n' "$_RD" "$_N" "$1" >&2; }
# mark_pulled — merkt sich, dass dieser Lauf das Abbild selbst geladen hat (nur dann raeumt --uninstall --delete-data es weg).
mark_pulled() {
  [ ! -e "$PULLED_FILE" ] || return 0
  docker image inspect "$IMAGE" >/dev/null 2>&1 || return 0   # Pull gescheitert: nichts geladen, nichts zu merken
  install -m 0755 -d "$STATE_DIR"
  printf '%s\n' "$IMAGE" > "$PULLED_FILE"
}
# put_managed <datei> <modus> — Inhalt von stdin; 0 = geschrieben, 1 = war schon gleich.
put_managed() {
  local tmp rc=1
  tmp="$(mktemp)"; cat > "$tmp"
  if [ ! -e "$1" ] || ! cmp -s "$tmp" "$1"; then install -m "$2" "$tmp" "$1"; rc=0; fi
  rm -f "$tmp"
  return "$rc"
}

# --- Abbau ----------------------------------------------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  if [ "$DELETE_DATA" = 1 ]; then
    ask "Alle Daten (Datenbank, Dokumente, Schlüssel) werden unwiderruflich gelöscht. Wirklich löschen?" || die "Abgebrochen, nichts gelöscht."
  fi
  cur_master="$(master_image)"
  log "Entferne den Verbund …"
  uargs=(uninstall --json); [ "$DELETE_DATA" = 0 ] || uargs+=(--delete-data)
  rc=0; core /dev/null "${uargs[@]}" || rc=$?
  # Nur eigene Dateien (mit Markierung) entfernen.
  remove_own_files() {
    if [ -e "$UNIT_FILE" ] && grep -q "$MARK" "$UNIT_FILE"; then
      if [ -d "$R/run/systemd/system" ]; then systemctl disable "$UNIT_NAME" >&2 || true; fi
      rm -f "$UNIT_FILE"
      if [ -d "$R/run/systemd/system" ]; then systemctl daemon-reload >&2 || true; fi
    fi
    if [ -e "$CMD_FILE" ] && grep -q "$MARK" "$CMD_FILE"; then rm -f "$CMD_FILE"; fi
  }
  if ! core_verdict "$rc"; then
    # Der Verbund ist weg (oder war es schon), nur etwas blieb stehen: die eigenen Dateien gehen trotzdem, sonst startet die Einheit
    # nach jedem Docker-Neustart einen Verbund, den es nicht mehr gibt. Bei busy, internal u. a. steht der Verbund noch: nichts anfassen.
    [ -n "$RES" ] || RES='{}'
    case "$(jq -r '.reason // ""' <<<"$RES")" in data_kept|foreign_objects|not_installed) remove_own_files ;; esac
    exit 1
  fi
  remove_own_files
  if [ "$DELETE_DATA" = 1 ] && [ -e "$PULLED_FILE" ]; then
    for img in "$(cat "$PULLED_FILE")" "$cur_master"; do
      [ -n "$img" ] || continue
      docker image rm "$img" >/dev/null 2>&1 || warn "Abbild $img blieb liegen (wird noch gebraucht)."
    done
    rm -f "$PULLED_FILE"
  fi
  ok "Verbund entfernt.$([ "$DELETE_DATA" = 1 ] && echo ' Daten gelöscht.' || echo ' Die Daten bleiben; setup.sh startet sie wieder.') Docker bleibt installiert."
  exit 0
fi

# --- Einrichten -----------------------------------------------------------------------------------------------------------
had_image=1; docker image inspect "$IMAGE" >/dev/null 2>&1 || had_image=0
log "Starte den Verbund (Abbild $IMAGE) …"
rc=0; core /dev/null up --json || rc=$?
[ "$had_image" = 1 ] || mark_pulled
core_verdict "$rc" || exit 1
changed="$(jq -r '.changed' <<<"$RES")"
version="$(jq -r '.version // "?"' <<<"$RES")"

# Rechner-Befehl: wizard-url und boot-start sind eigene Verben, alles andere geht in den master. boot-start nimmt das Abbild
# des vorhandenen master (nach Updates der aktuelle Stand, auch wenn er gestoppt ist), sonst das von diesem Lauf.
sed -e "s|@P@|$P|g" -e "s|@IMG@|$IMAGE|g" -e "s|@MARK@|$MARK|g" <<'TXT' | { put_managed "$CMD_FILE" 0755 || true; }
#!/usr/bin/env bash
# @MARK@ — Befehl lifeagents auf dem Rechner (Verbund in Docker). Entfernen: setup.sh --uninstall.
set -euo pipefail
P='@P@'
case "${1:-}" in
  wizard-url)
    r="$(docker exec "$P-master" stack wizard-url --json 2>/dev/null | jq -Rc 'fromjson? | select(type == "object" and .type == "result")' | tail -n1 || true)"
    [ -n "$r" ] || r='{}'
    if [ "$(jq -r '.ok // false' <<<"$r")" = true ]; then jq -r '.url' <<<"$r"; else
      printf 'Kein Link: %s\n' "$(jq -r '.detail // "der Verbund läuft nicht?"' <<<"$r")" >&2; exit 1
    fi ;;
  boot-start)
    img="$(docker inspect -f '{{.Config.Image}}' "$P-master" 2>/dev/null || true)"
    a=(--env LA_CORE=1); [ "$P" = lifeagents ] || a+=(--env "LA_PROJECT=$P")
    exec docker run --rm --name "$P-core" --label "io.lifeagents.install=$P" "${a[@]}" \
      --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock "${img:-@IMG@}" stack start --json ;;
  *)
    t=-i; if [ -t 0 ] && [ -t 1 ]; then t=-it; fi
    exec docker exec "$t" "$P-master" lifeagents "$@" ;;
esac
TXT

if [ -d "$R/run/systemd/system" ]; then
  unit_new=0
  put_managed "$UNIT_FILE" 0644 <<TXT && unit_new=1
# $MARK
[Unit]
Description=Life Agents: start the stack once after Docker is up
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=300
ExecStart=/usr/local/bin/lifeagents boot-start

[Install]
WantedBy=multi-user.target
TXT
  [ "$unit_new" = 0 ] || systemctl daemon-reload >&2
  # Sofort starten (--now): Nur eine aktive Einheit (RemainAfterExit) startet mit, wenn Docker allein neu startet (PartOf);
  # eine inaktive bliebe nach `systemctl restart docker` aus.
  if [ "$unit_new" = 1 ] || ! systemctl is-enabled --quiet "$UNIT_NAME" 2>/dev/null; then
    systemctl enable --now "$UNIT_NAME" >&2 || warn "Die Einheit $UNIT_NAME ließ sich nicht starten (journalctl -u $UNIT_NAME)."
  elif ! systemctl is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    systemctl start "$UNIT_NAME" >&2 || warn "Die Einheit $UNIT_NAME ließ sich nicht starten (journalctl -u $UNIT_NAME)."
  fi
else
  warn "systemd läuft hier nicht: Nach einem Neustart von Docker startet der Verbund nicht von selbst (lifeagents boot-start von Hand)."
fi

if [ -n "$ANSWERS" ]; then
  [ "${#PROV[@]}" -gt 0 ] || PROV=(--profile release)
  case " ${PROV[*]} " in *" --profile "*|*" --profile="*) ;; *) PROV=(--profile release "${PROV[@]}") ;; esac
  log "Richte mit der Antwort-Datei ein …"
  rc=0; core "$ANSWERS" install --json -- "${PROV[@]}" || rc=$?
  core_verdict "$rc" || exit 1
  ok "Eingerichtet ($version). Zustand prüfen: lifeagents doctor"
  exit 0
fi

url=''
# Ein laufender Verbund ohne Wizard (Einrichtung abgeschlossen, Zweitlauf) hat keinen Link: dann nicht lange warten.
tries=15; [ "$changed" = true ] || tries=3
for _ in $(seq 1 "$tries"); do
  url="$(docker exec "$P-master" stack wizard-url --json 2>/dev/null | jq -Rr 'fromjson? | select(type == "object" and .type == "result" and .ok == true) | .url // empty' | tail -n1 || true)"
  [ -z "$url" ] || break
  sleep "${LA_SETUP_WAIT:-2}"
done
if [ -z "$url" ]; then
  if [ "$changed" = true ]; then ok "Der Verbund läuft ($version)."; else ok "Nichts zu tun: der Verbund läuft bereits ($version)."; fi
  warn "Es gibt keinen Link zum Fragebogen. Ist die Einrichtung schon abgeschlossen, ist das normal. Sonst in einer Minute: lifeagents wizard-url"
  exit 0
fi
port="$(sed -nE 's#^http://127\.0\.0\.1:([0-9]+)/.*#\1#p' <<<"$url")"
[ -n "$port" ] || die "Der Link zum Fragebogen hat eine unerwartete Form ($url). Neuer Versuch: lifeagents wizard-url"
addr="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
if [ "$changed" = true ]; then ok "Der Verbund läuft ($version)."; else ok "Nichts zu tun: der Verbund läuft bereits ($version)."; fi
cat <<TXT

So öffnest du den Fragebogen (am eigenen Laptop):
  1. Verbindung aufbauen und das Terminal offen lassen:
       ssh -L ${port}:127.0.0.1:${port} ${SUDO_USER:-root}@${addr:-<adresse-dieses-servers>}
  2. Im Browser am Laptop öffnen:
       ${url}
Der Link gilt 10 Minuten. Einen neuen Link gibt es mit: lifeagents wizard-url
TXT
