# setup_cases.sh — Abschnitt SU von cases.sh: der Linux-Einrichter provisioning/setup.sh gegen Attrappen.
# Eingebunden am Ende von cases.sh (dort: pass/fail/eq, $W, $ROOT); allein startbar: bash setup_cases.sh <root>.
# Nur Logik, die der echte Weg schwer erzwingt (Pruefungen vor jeder Aenderung, Grund-Texte, Idempotenz der Dateien,
# Abbau-Regeln). Ob Docker wirklich eingerichtet wird und der Verbund nach einem Docker-Neustart zurueckkommt, belegt erst
# der Job linux-setup in genericity.yml.
# real-path-test: .github/workflows/genericity.yml (Job linux-setup fuehrt setup.sh auf einem kalten Runner mit echtem Docker und echtem systemd aus)
# shellcheck disable=SC2016,SC2034,SC2329,SC2015  # Pruef-Ausdruecke in einfachen Quotes; Variablen der einbindenden Datei
if [ -z "${W:-}" ]; then
  set -uo pipefail
  ROOT="$1"; export LANG=C.UTF-8 LC_ALL=C.UTF-8
  fails=0
  pass() { printf 'PASS %s\n' "$1"; }
  fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
  eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }
  W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
  SU_STANDALONE=1
fi

SUS="$ROOT/provisioning/setup.sh"
SUD="$W/su"; SUB="$SUD/bin"; SUR="$SUD/root"; SUL="$SUD/log"
mkdir -p "$SUB"

# Attrappen: argv eine Zeile je Aufruf in $STUB_LOG (Felder mit |); gesteuert ueber STUB_*.
cat > "$SUB/docker" <<'STUB'
#!/usr/bin/env bash
{ printf 'docker'; printf '|%s' "$@"; echo; } >> "$STUB_LOG"
# STUB_NO_DOCKER: Docker fehlt, bis ein apt-get install docker-ce die Marke setzt.
if [ -n "${STUB_NO_DOCKER:-}" ] && [ ! -e "$STUB_LOG.docker" ]; then echo "docker: not found" >&2; exit 127; fi
a="|$(IFS='|'; echo "$*")|"
case "${1:-}" in
  version) exit "${STUB_DOCKER_RC:-0}" ;;
  inspect)
    case "$a" in
      *'-core|'*) [ -n "${STUB_CORE_EXISTS:-}" ] && exit 0; exit 1 ;;
      *Config.Image*) [ -n "${STUB_MASTER_IMAGE:-}" ] && { echo "$STUB_MASTER_IMAGE"; exit 0; }; exit 1 ;;
    esac
    exit 1 ;;
  image)
    case "${2:-}" in
      inspect) if [ -n "${STUB_IMG_ABSENT:-}" ] && [ ! -e "$STUB_LOG.pulled" ]; then exit 1; fi; exit 0 ;;
      rm) exit "${STUB_IMGRM_RC:-0}" ;;
    esac ;;
  run)
    verb=''; seen=0
    for x in "$@"; do if [ "$seen" = 1 ]; then verb="$x"; break; fi; [ "$x" = stack ] && seen=1; done
    : > "$STUB_LOG.pulled"
    if [ "$verb" = install ]; then { echo "== install"; cat; } >> "$STUB_LOG.put"; fi
    f="STUB_OUT_${verb//-/_}"; r="STUB_RC_${verb//-/_}"
    if [ -n "${!f:-}" ]; then cat "${!f}"; else
      case "$verb" in
        up) printf '%s\n' '{"v":1,"type":"progress","verb":"up","step":"check"}' '{"v":1,"type":"result","verb":"up","ok":true,"changed":true,"ports":{"edge":5880,"wizard":5881},"version":"v9.0.0"}' ;;
        install) printf '%s\n' '{"v":1,"type":"result","verb":"install","ok":true,"provision_exit":0}' ;;
        uninstall) printf '%s\n' '{"v":1,"type":"result","verb":"uninstall","ok":true,"removed":{"containers":4,"volumes":[],"images":[]},"kept":[]}' ;;
        start) printf '%s\n' '{"v":1,"type":"result","verb":"start","ok":true,"started":[]}' ;;
      esac
    fi
    exit "${!r:-0}" ;;
  exec)
    d='{"v":1,"type":"result","verb":"wizard-url","ok":true,"url":"http://127.0.0.1:5881/start?t=abc123"}'
    case "$a" in *'|wizard-url|'*) printf '%s\n' "${STUB_URL_JSON:-$d}"; exit "${STUB_URL_RC:-0}" ;; esac
    exit 0 ;;
esac
exit 0
STUB
cat > "$SUB/systemctl" <<'STUB'
#!/usr/bin/env bash
{ printf 'systemctl'; printf '|%s' "$@"; echo; } >> "$STUB_LOG"
case "${1:-}" in
  is-enabled) [ -n "${STUB_ENABLED:-}" ] && exit 0; exit 1 ;;
  is-active) [ -n "${STUB_ACTIVE:-}" ] && exit 0; exit 3 ;;
esac
exit 0
STUB
cat > "$SUB/apt-get" <<'STUB'
#!/usr/bin/env bash
{ printf 'apt-get'; printf '|%s' "$@"; echo; } >> "$STUB_LOG"
case "$*" in *docker-ce*) : > "$STUB_LOG.docker" ;; esac
exit 0
STUB
cat > "$SUB/curl" <<'STUB'
#!/usr/bin/env bash
{ printf 'curl'; printf '|%s' "$@"; echo; } >> "$STUB_LOG"
o=''; while [ "$#" -gt 0 ]; do [ "$1" = -o ] && o="$2"; shift; done
[ -z "$o" ] || echo 'KEY' > "$o"
exit 0
STUB
cat > "$SUB/id" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { echo "${STUB_UID:-0}"; exit 0; }
exec /usr/bin/id "$@"
STUB
cat > "$SUB/dpkg" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --print-architecture) echo "${STUB_ARCH:-amd64}" ;;
  -s) case " ${STUB_DPKG:-} " in *" ${2:-} "*) exit 0 ;; esac; exit 1 ;;
esac
STUB
cat > "$SUB/hostname" <<'STUB'
#!/usr/bin/env bash
echo "192.0.2.10 fd00::1"
STUB
cat > "$SUB/snap" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_SNAP:-}" ] && exit 0; exit 1
STUB
cat > "$SUB/systemd-detect-virt" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_VIRT:-}" ] && { echo "$STUB_VIRT"; exit 0; }; echo none; exit 1
STUB
chmod +x "$SUB"/*

# su_root <id> <version> <codename> [ubuntu_codename] — frischer Wurzel-Baum mit os-release und Systemd-Ordner.
su_root() {
  rm -rf "$SUR" "$SUL"*; mkdir -p "$SUR/etc" "$SUR/run/systemd/system" "$SUR/usr/local/bin" "$SUR/etc/systemd/system" "$SUR/etc/apt/sources.list.d"
  { printf 'ID=%s\nVERSION_ID="%s"\nVERSION_CODENAME=%s\n' "$1" "$2" "$3"; [ -z "${4:-}" ] || printf 'UBUNTU_CODENAME=%s\n' "$4"; } > "$SUR/etc/os-release"
  : > "$SUL"
}
# su_run [setup.sh-Argumente] — Ergebnis in SU_RC, Ausgabe in $SUD/out und $SUD/err.
su_run() {
  SU_RC=0
  env -u LA_PROJECT -u LA_CORE_PORTS PATH="$SUB:$PATH" STUB_LOG="$SUL" LA_SETUP_ROOT="$SUR" LA_SETUP_WAIT=0 SUDO_USER="${SU_USER-alice}" "$@" </dev/null >"$SUD/out" 2>"$SUD/err" || SU_RC=$?
}
sux() { su_run bash "$SUS" "$@"; }   # sux <optionen> ohne Umgebung; mit Umgebung: su_run env FOO=1 bash "$SUS" …
su_changed() { ( cd "$SUR" && find . -type f | sort | xargs -r sha256sum ) | sha256sum | cut -d' ' -f1; }
su_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "fehlt '$3' in: $2" ;; esac; }
su_not() { case "$2" in *"$3"*) fail "$1" "unerwartet '$3' in: $2" ;; *) pass "$1" ;; esac; }
su_log() { cat "$SUL" 2>/dev/null; }
IMG='reg.example/master@sha256:aaaa'

# --- Datei und Aufruf ---------------------------------------------------------------------------------------------------
[ -f "$SUS" ] && pass SU.datei-da || fail SU.datei-da "provisioning/setup.sh fehlt"
if [ -f "$SUS" ]; then bash -n "$SUS" 2>/dev/null && pass SU.syntax || fail SU.syntax "bash -n"; fi

su_root debian 12 bookworm
sux --hilfe
eq SU.unbekannte-option-exit-2 2 "$SU_RC"
sux --help
eq SU.hilfe-exit-0 0 "$SU_RC"
for o in --yes --image --answers --uninstall --delete-data; do su_has "SU.hilfe-nennt$o" "$(cat "$SUD/out" "$SUD/err")" "$o"; done
sux --delete-data --image "$IMG"
eq SU.delete-data-nur-mit-uninstall 2 "$SU_RC"
sux --image
eq SU.image-ohne-wert-exit-2 2 "$SU_RC"
sux --image '-evil'
eq SU.image-form-geprueft 2 "$SU_RC"
sux --answers /nicht/da --yes --image "$IMG"
eq SU.answers-datei-fehlt 1 "$SU_RC"
[ -z "$(su_log)" ] && pass SU.answers-fehlt-nichts-gestartet || fail SU.answers-fehlt-nichts-gestartet "$(su_log)"

# --- Pruefungen vor jeder Aenderung: Abbruch, kein docker/apt-Aufruf, keine Datei -----------------------------------------
su_abort() {   # su_abort <fall> <erwarteter-text> — nach su_root/Vorbereitung: Exit 1, nichts angefasst
  local before after; before="$(su_changed)"
  sux --yes --image "$IMG"
  after="$(su_changed)"
  eq "SU.$1-exit-1" 1 "$SU_RC"
  su_has "SU.$1-text" "$(cat "$SUD/err")" "$2"
  eq "SU.$1-nichts-geaendert" "$before" "$after"
  if grep -qE '^(docker\|run|apt-get|systemctl\|(enable|daemon-reload))' "$SUL"; then fail "SU.$1-kein-aufruf" "$(head -3 "$SUL")"; else pass "SU.$1-kein-aufruf"; fi
}
su_root debian 12 bookworm; SU_USER=alice
su_run env STUB_UID=1000 bash "$SUS" --yes --image "$IMG"
eq SU.nicht-root-exit-1 1 "$SU_RC"
su_has SU.nicht-root-text "$(cat "$SUD/err")" root
su_root debian 11 bullseye; su_abort debian-11 'Debian 12'
su_root ubuntu 20.04 focal; su_abort ubuntu-20 'Ubuntu 22.04'
su_root fedora 40 x; su_abort fedora 'Debian'
su_root debian 12 bookworm; STUB_ARCH=armhf su_abort fremde-architektur 'amd64'
su_root debian 12 bookworm; mkdir -p "$SUR/etc/lifeagents"; : > "$SUR/etc/lifeagents/core.env"; su_abort klassisch-core-env 'klassische'
su_root debian 12 bookworm; : > "$SUR/etc/systemd/system/n8n.service"; su_abort klassisch-n8n-unit 'klassische'
su_root debian 12 bookworm; STUB_SNAP=1 su_abort snap-docker 'Snap'
su_root debian 12 bookworm; STUB_DPKG='docker.io' STUB_NO_DOCKER=1 su_abort fremdes-docker-paket 'docker.io'
su_root debian 12 bookworm; STUB_CORE_EXISTS=1 su_abort kern-laeuft-schon 'lifeagents-core'
su_root debian 12 bookworm; sux --yes
eq SU.ohne-pin-ohne-image-exit-1 1 "$SU_RC"
su_has SU.ohne-pin-hinweis "$(cat "$SUD/err")" '--image'
# Eine klassische Installation bremst auch den Abbau.
su_root debian 12 bookworm; mkdir -p "$SUR/etc/lifeagents"; : > "$SUR/etc/lifeagents/core.env"; sux --uninstall --yes --image "$IMG"
eq SU.klassisch-bremst-abbau 1 "$SU_RC"

# --- Docker einrichten ------------------------------------------------------------------------------------------------
su_root debian 12 bookworm
su_run env STUB_NO_DOCKER=1 bash "$SUS" --image "$IMG"   # kein --yes und kein Terminal
eq SU.docker-fehlt-ohne-ja-exit-1 1 "$SU_RC"
su_has SU.docker-fehlt-ohne-ja-hinweis "$(cat "$SUD/err")" '--yes'
grep -q '^apt-get|install' "$SUL" && fail SU.docker-fehlt-ohne-ja-kein-apt "apt-get install gelaufen" || pass SU.docker-fehlt-ohne-ja-kein-apt
su_root debian 13 trixie
su_run env STUB_NO_DOCKER=1 bash "$SUS" --yes --image "$IMG"
eq SU.docker-debian-eingerichtet 0 "$SU_RC"
DS="$SUR/etc/apt/sources.list.d/docker.sources"
su_has SU.docker-quelle-debian "$(cat "$DS" 2>/dev/null)" 'URIs: https://download.docker.com/linux/debian'
su_has SU.docker-suite-debian "$(cat "$DS" 2>/dev/null)" 'Suites: trixie'
su_has SU.docker-arch "$(cat "$DS" 2>/dev/null)" 'Architectures: amd64'
su_has SU.docker-signed-by "$(cat "$DS" 2>/dev/null)" 'Signed-By: /etc/apt/keyrings/docker.asc'
su_has SU.docker-schluessel-datei "$(cat "$SUR/etc/apt/keyrings/docker.asc" 2>/dev/null)" KEY
su_has SU.docker-pakete "$(grep '^apt-get|install' "$SUL" | tail -1)" 'docker-ce|docker-ce-cli|containerd.io|docker-compose-plugin'
su_has SU.docker-dienst "$(su_log)" 'systemctl|enable|--now|docker'
curls="$(grep '^curl' "$SUL")"
su_has SU.docker-nur-paketquelle "$curls" 'https://download.docker.com/linux/debian/gpg'
su_not SU.docker-nie-get-docker-com "$(su_log)" 'get.docker.com'
su_root ubuntu 24.04 noble noble
su_run env STUB_NO_DOCKER=1 bash "$SUS" --yes --image "$IMG"
su_has SU.docker-quelle-ubuntu "$(cat "$DS" 2>/dev/null)" 'URIs: https://download.docker.com/linux/ubuntu'
su_has SU.docker-suite-ubuntu "$(cat "$DS" 2>/dev/null)" 'Suites: noble'
su_root ubuntu 22.04 jammy jammy; mkdir -p "$SUR/etc/apt"
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: jammy\nComponents: stable\nSigned-By: /etc/apt/keyrings/x.gpg\n' > "$SUR/etc/apt/sources.list.d/docker-alt.sources"
su_run env STUB_NO_DOCKER=1 bash "$SUS" --yes --image "$IMG"
[ ! -e "$DS" ] && pass SU.docker-quelle-schon-da-keine-zweite || fail SU.docker-quelle-schon-da-keine-zweite "zweite Quelle geschrieben (Signed-By-Konflikt in apt)"
# Docker installiert, Dienst aus: nur starten, nichts installieren.
su_root debian 12 bookworm
su_run env STUB_NO_DOCKER=1 STUB_DPKG=docker-ce bash "$SUS" --yes --image "$IMG"
grep -q '^apt-get|install' "$SUL" && fail SU.docker-installiert-nur-starten "apt-get install" || pass SU.docker-installiert-nur-starten
# Kein systemd -> Docker laesst sich nicht einrichten.
su_root debian 12 bookworm; rmdir "$SUR/run/systemd/system"
su_run env STUB_NO_DOCKER=1 bash "$SUS" --yes --image "$IMG"
eq SU.docker-ohne-systemd-exit-1 1 "$SU_RC"

# --- Kern-Aufruf ---------------------------------------------------------------------------------------------------------
su_root debian 12 bookworm
sux --yes --image "$IMG"
eq SU.erster-lauf-exit-0 0 "$SU_RC"
upl="$(grep '^docker|run' "$SUL" | head -1)"
eq SU.kern-aufruf-form "docker|run|--rm|-i|--name|lifeagents-core|--label|io.lifeagents.install=lifeagents|--env|LA_CORE=1|--mount|type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock|$IMG|stack|up|--json" "$upl"
: > "$SUL"
su_run env LA_PROJECT=s4x LA_CORE_PORTS=57300-57319 bash "$SUS" --yes --image "$IMG"
upl="$(grep '^docker|run' "$SUL" | head -1)"
su_has SU.kern-projekt-durchgereicht "$upl" '|--name|s4x-core|--label|io.lifeagents.install=s4x|--env|LA_CORE=1|--env|LA_PROJECT|--env|LA_CORE_PORTS|'
su_has SU.kern-fortschritt-sichtbar "$(cat "$SUD/err")" 'Docker prüfen'
# Kein Geheimnis im Aufruf.
su_not SU.kern-kein-geheimnis "$upl" 'PW'

# Ergebnis auswerten: jeder Grund der geschlossenen Liste hat einen Satz; ohne result (Docker-Fehler) core_failed.
reasons="$(sed -n 's/^SC_REASONS="\(.*\)"$/\1/p' "$ROOT/provisioning/lib/stack_core.sh")"
miss=''; for r in $reasons; do grep -qE "(^|[[:space:]|(])${r}[|)]" "$SUS" 2>/dev/null || miss="$miss $r"; done
eq SU.jeder-grund-hat-text '' "${miss# }"
su_fail_out() { printf '%s\n' "{\"v\":1,\"type\":\"result\",\"verb\":\"up\",\"ok\":false,\"reason\":\"$1\",\"detail\":\"Satz vom Kern\"}" > "$SUD/res.$1"; }
su_fail_out disk_low
su_root debian 12 bookworm
su_run env STUB_OUT_up="$SUD/res.disk_low" STUB_RC_up=1 bash "$SUS" --yes --image "$IMG"
eq SU.grund-exit-1 1 "$SU_RC"
su_has SU.grund-text "$(cat "$SUD/err")" 'Platz'
[ ! -e "$SUR/usr/local/bin/lifeagents" ] && pass SU.grund-kein-befehl-geschrieben || fail SU.grund-kein-befehl-geschrieben "Befehl trotz Fehler geschrieben"
su_fail_out docker_capability
su_run env STUB_OUT_up="$SUD/res.docker_capability" STUB_RC_up=1 STUB_VIRT=lxc bash "$SUS" --yes --image "$IMG"
su_has SU.lxc-hinweis-nesting "$(cat "$SUD/err")" 'nesting=1,keyctl=1'
su_has SU.lxc-hinweis-vm "$(cat "$SUD/err")" 'VM'
su_run env STUB_OUT_up="$SUD/res.docker_capability" STUB_RC_up=1 bash "$SUS" --yes --image "$IMG"
su_not SU.kein-lxc-kein-nesting "$(cat "$SUD/err")" 'nesting=1'
echo 'kein json' > "$SUD/res.none"
su_run env STUB_OUT_up="$SUD/res.none" STUB_RC_up=125 bash "$SUS" --yes --image "$IMG"
eq SU.ohne-result-exit-1 1 "$SU_RC"
su_has SU.ohne-result-text "$(cat "$SUD/err")" 'Docker'

# --- Rechner-Befehl und Einheit -------------------------------------------------------------------------------------------
su_root debian 12 bookworm
sux --yes --image "$IMG"
CMD="$SUR/usr/local/bin/lifeagents"; UNIT="$SUR/etc/systemd/system/lifeagents-stack.service"
FIRSTLOG="$(su_log)"
[ -x "$CMD" ] && pass SU.befehl-da || fail SU.befehl-da "nicht ausfuehrbar/fehlt"
head -3 "$CMD" 2>/dev/null | grep -q 'managed by lifeagents setup.sh' && pass SU.befehl-markierung || fail SU.befehl-markierung "ohne Markierung"
bash -n "$CMD" 2>/dev/null && pass SU.befehl-syntax || fail SU.befehl-syntax "bash -n"
: > "$SUL"; STUB_LOG="$SUL" PATH="$SUB:$PATH" "$CMD" doctor </dev/null >/dev/null 2>&1
eq SU.befehl-reicht-durch 'docker|exec|-i|lifeagents-master|lifeagents|doctor|' "$(grep '^docker|exec' "$SUL" | head -1)|"
: > "$SUL"; STUB_LOG="$SUL" PATH="$SUB:$PATH" "$CMD" wizard-url </dev/null 2>/dev/null
su_has SU.befehl-wizard-url "$(grep '^docker|exec' "$SUL" | head -1)" 'lifeagents-master|stack|wizard-url|--json'
out="$(STUB_LOG="$SUL" PATH="$SUB:$PATH" "$CMD" wizard-url </dev/null 2>/dev/null)"
eq SU.befehl-wizard-url-nur-url 'http://127.0.0.1:5881/start?t=abc123' "$out"
: > "$SUL"; STUB_LOG="$SUL" STUB_MASTER_IMAGE='reg.example/master@sha256:bbbb' PATH="$SUB:$PATH" "$CMD" boot-start </dev/null >/dev/null 2>&1
su_has SU.boot-start-abbild-des-master "$(grep '^docker|run' "$SUL" | head -1)" '|reg.example/master@sha256:bbbb|stack|start|--json'
: > "$SUL"; STUB_LOG="$SUL" PATH="$SUB:$PATH" "$CMD" boot-start </dev/null >/dev/null 2>&1
su_has SU.boot-start-ohne-master-eigener-pin "$(grep '^docker|run' "$SUL" | head -1)" "|--env|LA_CORE=1|"
su_has SU.einheit-abhaengigkeit "$(cat "$UNIT" 2>/dev/null)" 'After=docker.service'
su_has SU.einheit-requires "$(cat "$UNIT" 2>/dev/null)" 'Requires=docker.service'
su_has SU.einheit-partof "$(cat "$UNIT" 2>/dev/null)" 'PartOf=docker.service'
su_has SU.einheit-typ "$(cat "$UNIT" 2>/dev/null)" 'Type=oneshot'
su_has SU.einheit-bleibt-aktiv "$(cat "$UNIT" 2>/dev/null)" 'RemainAfterExit=yes'
su_has SU.einheit-start "$(cat "$UNIT" 2>/dev/null)" 'ExecStart=/usr/local/bin/lifeagents boot-start'
su_has SU.einheit-boot "$(cat "$UNIT" 2>/dev/null)" 'WantedBy=multi-user.target'
head -1 "$UNIT" 2>/dev/null | grep -q 'managed by lifeagents setup.sh' && pass SU.einheit-markierung || fail SU.einheit-markierung "ohne Markierung"
su_has SU.einheit-aktiviert "$FIRSTLOG" 'systemctl|enable|lifeagents-stack.service'
su_not SU.einheit-nicht-sofort "$(grep lifeagents-stack <<<"$FIRSTLOG")" '--now'

# Zweitlauf: nichts aendert sich (Dateien, daemon-reload, enable).
sum1="$(su_changed)"
: > "$SUL"
su_run env STUB_ENABLED=1 bash "$SUS" --yes --image "$IMG"
eq SU.zweitlauf-exit-0 0 "$SU_RC"
eq SU.zweitlauf-dateien-gleich "$sum1" "$(su_changed)"
grep -qE '^systemctl\|(daemon-reload|enable)' "$SUL" && fail SU.zweitlauf-kein-systemctl "$(grep systemctl "$SUL")" || pass SU.zweitlauf-kein-systemctl
# Ohne systemd: Befehl ja, Einheit nein, Warnung.
su_root debian 12 bookworm; rmdir "$SUR/run/systemd/system"
sux --yes --image "$IMG"
eq SU.ohne-systemd-exit-0 0 "$SU_RC"
[ ! -e "$SUR/etc/systemd/system/lifeagents-stack.service" ] && [ -x "$SUR/usr/local/bin/lifeagents" ] && pass SU.ohne-systemd-nur-befehl || fail SU.ohne-systemd-nur-befehl "Einheit geschrieben oder Befehl fehlt"
su_has SU.ohne-systemd-warnung "$(cat "$SUD/err")" 'systemd'
# Fremde Datei gleichen Namens wird nie ueberschrieben.
su_root debian 12 bookworm; printf '#!/bin/sh\necho fremd\n' > "$SUR/usr/local/bin/lifeagents"
sux --yes --image "$IMG"
eq SU.fremder-befehl-exit-1 1 "$SU_RC"
eq SU.fremder-befehl-unveraendert $'#!/bin/sh\necho fremd' "$(cat "$SUR/usr/local/bin/lifeagents")"
su_root debian 12 bookworm; printf '[Unit]\nDescription=fremd\n' > "$SUR/etc/systemd/system/lifeagents-stack.service"
sux --yes --image "$IMG"
eq SU.fremde-einheit-exit-1 1 "$SU_RC"

# --- Ausgabe fuer den Fragebogen -------------------------------------------------------------------------------------------
su_root debian 12 bookworm
SU_USER=alice sux --yes --image "$IMG"
su_has SU.ausgabe-ssh "$(cat "$SUD/out")" 'ssh -L 5881:127.0.0.1:5881 alice@192.0.2.10'
su_has SU.ausgabe-link "$(cat "$SUD/out")" 'http://127.0.0.1:5881/start?t=abc123'
su_has SU.ausgabe-zehn-minuten "$(cat "$SUD/out")" '10 Minuten'
su_has SU.ausgabe-neuer-link "$(cat "$SUD/out")" 'lifeagents wizard-url'
su_root debian 12 bookworm
SU_USER='' sux --yes --image "$IMG"
su_has SU.ausgabe-ohne-sudo-root "$(cat "$SUD/out")" 'root@192.0.2.10'
su_root debian 12 bookworm
su_run env STUB_URL_RC=1 STUB_URL_JSON='{"v":1,"type":"result","verb":"wizard-url","ok":false,"reason":"master_not_running","detail":"x"}' bash "$SUS" --yes --image "$IMG"
eq SU.link-fehlt-exit-1 1 "$SU_RC"
su_has SU.link-fehlt-hinweis "$(cat "$SUD/err")" 'lifeagents wizard-url'

# --- --answers --------------------------------------------------------------------------------------------------------------
su_root debian 12 bookworm
printf "# lifeagents-answers v1\nTELEGRAM_BOT_TOKEN='x'\n" > "$SUD/answers.env"
rm -f "$SUL.put"
sux --yes --image "$IMG" --answers "$SUD/answers.env"
eq SU.answers-exit-0 0 "$SU_RC"
instl="$(grep '|stack|install|' "$SUL")"
su_has SU.answers-installiert "$instl" '|stack|install|--json|--|--profile|release'
su_has SU.answers-stdin "$(cat "$SUL.put" 2>/dev/null)" "TELEGRAM_BOT_TOKEN='x'"
su_not SU.answers-kein-ssh "$(cat "$SUD/out")" 'ssh -L'
su_root debian 12 bookworm
sux --yes --image "$IMG" --answers "$SUD/answers.env" -- --profile dev --packages finance
su_has SU.answers-eigene-optionen "$(grep '|stack|install|' "$SUL")" '|--|--profile|dev|--packages|finance'
su_not SU.answers-profil-nicht-doppelt "$(grep '|stack|install|' "$SUL")" '--profile|release'
printf '%s\n' '{"v":1,"type":"result","verb":"install","ok":false,"reason":"install_failed","detail":"x","provision_exit":1}' > "$SUD/res.inst"
su_root debian 12 bookworm
su_run env STUB_OUT_install="$SUD/res.inst" STUB_RC_install=1 bash "$SUS" --yes --image "$IMG" --answers "$SUD/answers.env"
eq SU.answers-install-failed-exit-1 1 "$SU_RC"
su_has SU.answers-install-failed-text "$(cat "$SUD/err")" 'Einrichtung'

# --- Abbau ----------------------------------------------------------------------------------------------------------------
su_root debian 12 bookworm
sux --yes --image "$IMG"
: > "$SUL"
sux --uninstall --yes --image "$IMG"
eq SU.abbau-exit-0 0 "$SU_RC"
su_has SU.abbau-ruft-kern "$(grep '^docker|run' "$SUL" | head -1)" "|stack|uninstall|--json"
su_not SU.abbau-ohne-daten-loeschen "$(grep '^docker|run' "$SUL" | head -1)" '--delete-data'
[ ! -e "$SUR/usr/local/bin/lifeagents" ] && [ ! -e "$SUR/etc/systemd/system/lifeagents-stack.service" ] && pass SU.abbau-entfernt-befehl-und-einheit || fail SU.abbau-entfernt-befehl-und-einheit "Dateien noch da"
su_has SU.abbau-einheit-deaktiviert "$(su_log)" 'systemctl|disable|lifeagents-stack.service'
grep -q '^docker|image|rm' "$SUL" && fail SU.abbau-ohne-daten-abbild-bleibt "image rm" || pass SU.abbau-ohne-daten-abbild-bleibt
# Fremde Dateien bleiben beim Abbau stehen.
su_root debian 12 bookworm; printf '#!/bin/sh\necho fremd\n' > "$SUR/usr/local/bin/lifeagents"
sux --uninstall --yes --image "$IMG"
eq SU.abbau-fremder-befehl-bleibt $'#!/bin/sh\necho fremd' "$(cat "$SUR/usr/local/bin/lifeagents")"
# --delete-data: ohne Terminal und ohne --yes Abbruch VOR dem Kern.
su_root debian 12 bookworm
sux --uninstall --delete-data --image "$IMG"
eq SU.delete-data-fragt-exit-1 1 "$SU_RC"
grep -q '^docker|run' "$SUL" && fail SU.delete-data-fragt-vor-dem-kern "Kern lief" || pass SU.delete-data-fragt-vor-dem-kern
su_has SU.delete-data-fragt-hinweis "$(cat "$SUD/err")" '--yes'
# --delete-data --yes: Option geht an den Kern; selbst geladenes Abbild (Marke) wird danach entfernt.
su_root debian 12 bookworm
su_run env STUB_IMG_ABSENT=1 bash "$SUS" --yes --image "$IMG"
[ "$(cat "$SUR/var/lib/lifeagents-setup/pulled-image" 2>/dev/null)" = "$IMG" ] && pass SU.marke-selbst-geladen || fail SU.marke-selbst-geladen "$(cat "$SUR/var/lib/lifeagents-setup/pulled-image" 2>/dev/null)"
: > "$SUL"
su_run env STUB_MASTER_IMAGE='reg.example/master@sha256:bbbb' bash "$SUS" --uninstall --delete-data --yes --image "$IMG"
eq SU.delete-data-exit-0 0 "$SU_RC"
su_has SU.delete-data-an-kern "$(grep '^docker|run' "$SUL" | head -1)" '|stack|uninstall|--json|--delete-data'
su_has SU.delete-data-eigenes-abbild-weg "$(su_log)" "docker|image|rm|$IMG"
su_has SU.delete-data-aktuelles-master-abbild-weg "$(su_log)" 'docker|image|rm|reg.example/master@sha256:bbbb'
[ ! -e "$SUR/var/lib/lifeagents-setup/pulled-image" ] && pass SU.marke-danach-weg || fail SU.marke-danach-weg "Marke bleibt"
# Abbild lag vorher schon da: nie entfernen.
su_root debian 12 bookworm
sux --yes --image "$IMG"
[ ! -e "$SUR/var/lib/lifeagents-setup/pulled-image" ] && pass SU.marke-nur-bei-selbst-geladen || fail SU.marke-nur-bei-selbst-geladen "Marke gesetzt"
: > "$SUL"
sux --uninstall --delete-data --yes --image "$IMG"
grep -q '^docker|image|rm' "$SUL" && fail SU.delete-data-fremdes-abbild-bleibt "image rm" || pass SU.delete-data-fremdes-abbild-bleibt
# Abbild wird noch gebraucht: nur Warnung, Abbau gilt trotzdem als gelungen.
su_root debian 12 bookworm
su_run env STUB_IMG_ABSENT=1 bash "$SUS" --yes --image "$IMG"
su_run env STUB_IMGRM_RC=1 bash "$SUS" --uninstall --delete-data --yes --image "$IMG"
eq SU.abbild-in-benutzung-nur-warnung 0 "$SU_RC"
# Kern meldet einen Grund -> Exit 1, Befehl und Einheit bleiben (der Verbund steht ja noch).
su_root debian 12 bookworm
sux --yes --image "$IMG"
printf '%s\n' '{"v":1,"type":"result","verb":"uninstall","ok":false,"reason":"busy","detail":"x"}' > "$SUD/res.ubusy"
su_run env STUB_OUT_uninstall="$SUD/res.ubusy" STUB_RC_uninstall=1 bash "$SUS" --uninstall --yes --image "$IMG"
eq SU.abbau-busy-exit-1 1 "$SU_RC"
[ -x "$SUR/usr/local/bin/lifeagents" ] && pass SU.abbau-busy-befehl-bleibt || fail SU.abbau-busy-befehl-bleibt "Befehl weg"
# Abbau braucht kein Abbild-Pin, wenn ein master da ist (Abbild aus dem laufenden Verbund).
su_root debian 12 bookworm
su_run env STUB_MASTER_IMAGE='reg.example/master@sha256:cccc' bash "$SUS" --uninstall --yes
eq SU.abbau-abbild-aus-master 0 "$SU_RC"
su_has SU.abbau-abbild-aus-master-aufruf "$(grep '^docker|run' "$SUL" | head -1)" '|reg.example/master@sha256:cccc|stack|uninstall|'

if [ -n "${SU_STANDALONE:-}" ]; then exit "$fails"; fi
