#!/usr/bin/env bash
# debian_vm.sh -- Schritte des Debian-Laufs (.github/workflows/linux-setup-debian.yml): ein frisches Debian 12 als KVM-VM auf dem
# GitHub-Runner, darin der echte Linux-Einstieg provisioning/setup.sh wie bei einem Nutzer (Docker holen, Kern starten), dann der
# Fragebogen im Browser (tests/install/wizard_klick.cjs), Kopplung, Pruefung am Ende, Zweitlauf, Abbau.
# Aufruf (nur auf einem ubuntu-24.04-Runner, im Checkout):  bash tests/install/debian_vm.sh <schritt> [arg]
#   kvm | registry | image | boot | setup | mocks | answers | setup_answers | reach | answers_cleanup | link | tunnel | browser | klick | pair | verify | second | uninstall | summary | diag | stop
# Zustand liegt in $RUNNER_TEMP (Marken, Schluessel, VM-Ordner) und in $GITHUB_ENV (SETUP_IMAGE, VM_DIR).
#
# Grenzen (ohne echtes Telegram und echtes Anthropic gehen diese Stellen nur mit Ersatz, alles andere ist der echte Weg):
#  - Telegram: der Bot ist die Attrappe tests/mock_telegram im Netz-Namensraum des Verbunds. Der Fragebogen-Prozess im master
#    kennt die Test-Weiche LIFEAGENTS_TELEGRAM_API nicht (compose.yml setzt sie nicht), darum wird er mit ihr neu gestartet.
#  - Telegram-Token und Anthropic-Schluessel: der Fragebogen prueft sie live gegen api.telegram.org und api.anthropic.com und lehnt erfundene ab. Die VM sperrt
#    die Adressen, der Fragebogen nimmt die Werte dann mit Hinweis "nicht online pruefbar" (wie ohne Netz) an; der Bot-Aufruf tg-check geht an die Attrappe.
#  - Tunnel: der Klicker prueft die Tailscale-Seite (kommt vor der Installation, Anmelde-Link, neues Fenster, QR, Zurueck), kommt dort
#    ohne Tailscale-Konto aber nicht weiter. Er wechselt ueber Zurueck und die Uebersicht auf die FritzBox-Adresse (erfundener Name)
#    und installiert damit; der echte Tunnel laeuft im Antwort-Datei-Weg (unten). Kopplung und
#    Abschluss fahren danach wie im Verbund-Lauf von genericity.yml (pair_and_finalize.sh, Webhook-Update statt Telegram).
#  - Paperless: die Adresse wird uebersprungen (optional); ein echtes Paperless im LAN fehlt dem Lauf.
#  - Antwort-Datei-Weg (Schritte answers/setup_answers/reach): mit den Test-Zugaengen (nur Environment install-test auf main) echt - Tunnel,
#    Test-Bot, Anthropic-Schluessel. Ohne sie (ANSWERS_STANDIN=1, Lauf auf Entwicklungs-Branches) erfundene Werte ohne Tailnet:
#    Telegram-Attrappe und gesperrte Dienste wie im Klickweg, der Tunnel-Teil entfaellt. Gekoppelt wird dort nie: ein Bot kann sich kein
#    /start schicken, und die Begruessung ginge an einen Chat, den es nicht gibt (Hand-Test des Owners).
# shellcheck disable=SC2016,SC2029  # die vm()-Befehle sind Text fuer die Shell in der VM: Variablen gehoeren dort aufgeloest, nicht hier
set -euo pipefail

: "${RUNNER_TEMP:?nur im Runner}"
W="$RUNNER_TEMP/vm"
mkdir -p "$W"
CRANE_VERSION="${CRANE_VERSION:-v0.22.1}"
CRANE_SHA256="${CRANE_SHA256:-0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0}"
VM_DISK_GB="${VM_DISK_GB:-30}"
VM_MEM="${VM_MEM:-10G}"
VM_CPUS="${VM_CPUS:-4}"

mark() { printf '%s %s\n' "$(date +%s)" "$1" >> "$RUNNER_TEMP/marks.txt"; }
# -F /dev/null: sonst reicht der Client LANG=C.UTF-8 des Runners per SendEnv durch und ueberschreibt LANG=C der Vorlage.
SSH_O=(-F /dev/null -i "$W/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=15 -p 2222)
vm() { ssh "${SSH_O[@]}" debian@127.0.0.1 "$@"; }
vm_scp() { scp -F /dev/null -i "$W/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -P 2222 "$@"; }
# setup.sh wie ein Nutzer als root, mit der Sprache einer Proxmox-Vorlage (LANG=C).
vm_setup() {
  # hand-injected: im Lauf mit Telegram-Attrappe (ANSWERS_STANDIN=1, nach den Attrappen) geht jeder setup.sh-Aufruf an die Attrappe, auch Zweitlauf und Abbau
  local e=''
  { [ "${ANSWERS_STANDIN:-}" = 1 ] && [ -e "$RUNNER_TEMP/tgmock.up" ]; } && e='LIFEAGENTS_TELEGRAM_API=http://127.0.0.1:8089'
  vm "sudo env -u LC_ALL LANG=C $e bash setup.sh --yes --image '$SETUP_IMAGE' $*"
}

# Secrets: GitHub maskiert sie ohnehin; zusaetzlich hier, damit auch abgeleitete Zeilen nie im Log stehen. Nie ausgeben.
mask_secrets() {
  local v
  for v in TEST_TELEGRAM_BOT_TOKEN TEST_ANTHROPIC_API_KEY TEST_TS_OAUTH_CLIENT_ID TEST_TS_OAUTH_CLIENT_SECRET; do [ -z "${!v:-}" ] || echo "::add-mask::${!v}"; done
}

step_kvm() {
  mark start
  echo "--- CPU / RAM / Platte"
  lscpu | grep -E 'Model name|Virtualization|Hypervisor|^CPU\(s\)' || true
  free -m | head -2
  df -h / /mnt 2>/dev/null || true
  echo "--- /dev/kvm"
  ls -l /dev/kvm || true
  # Empfohlene udev-Regel (GitHub Changelog 2024-04-02): /dev/kvm fuer den Runner-Nutzer nutzbar machen.
  echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
  sudo udevadm control --reload-rules
  sudo udevadm trigger --name-match=kvm || true
  # Die Regel greift mit Verzug (A0: zwei Laeufe ok, ein Lauf zu frueh geprueft): kurz warten, sonst die Rechte direkt setzen.
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -w /dev/kvm ] && break; sleep 1; done
  [ -w /dev/kvm ] || { [ ! -c /dev/kvm ] || sudo chmod a+rw /dev/kvm; }
  if ! { [ -c /dev/kvm ] && [ -w /dev/kvm ]; }; then
    echo "::error::Kein nutzbares /dev/kvm auf diesem Runner: Runner-Ausfall, nicht der Produktcode. Lauf wiederholen."
    exit 1
  fi
  echo "KVM da und beschreibbar."
  mark kvm_ok
}

# Master-Abbild aus dem Baum bauen und aus einer Registry ohne Docker (crane) bereitstellen: die VM holt es ueber einen
# umgekehrten SSH-Tunnel als 127.0.0.1:5001 (nur Loopback ist fuer Docker ohne TLS erlaubt).
step_registry() {
  git archive --format=tar HEAD provisioning packages .gitattributes \
    | docker build -q -f provisioning/compose/master.Dockerfile --build-arg RELEASE_TAG=v9.0.0 -t ci/master:ci -
  docker save -o "$RUNNER_TEMP/master.tar" ci/master:ci
  mkdir -p "$RUNNER_TEMP/crane" "$RUNNER_TEMP/registry"
  curl -fsSL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" -o "$RUNNER_TEMP/crane.tgz"
  echo "${CRANE_SHA256}  $RUNNER_TEMP/crane.tgz" | sha256sum -c -
  tar -xzf "$RUNNER_TEMP/crane.tgz" -C "$RUNNER_TEMP/crane" crane
  nohup "$RUNNER_TEMP/crane/crane" registry serve --address 127.0.0.1:5001 --disk "$RUNNER_TEMP/registry" > "$RUNNER_TEMP/crane.log" 2>&1 &
  local _
  for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:5001/v2/ >/dev/null 2>&1 && break; sleep 1; done
  "$RUNNER_TEMP/crane/crane" push --insecure "$RUNNER_TEMP/master.tar" 127.0.0.1:5001/ci/master:ci
  local digest
  digest="$("$RUNNER_TEMP/crane/crane" digest --insecure 127.0.0.1:5001/ci/master:ci)"
  echo "SETUP_IMAGE=127.0.0.1:5001/ci/master@$digest" >> "$GITHUB_ENV"
  # Platz fuer die VM-Platte: Abbilder und Tar werden nicht mehr gebraucht (die Registry haelt eine Kopie).
  docker system prune -af >/dev/null
  rm -f "$RUNNER_TEMP/master.tar"
  df -h / /mnt 2>/dev/null || true
  mark master_ready
}

# Neuestes Debian-12-Cloud-Image (frisch ist der Zweck des woechentlichen Laufs); die Pruefsumme steht auf demselben HTTPS-Server
# und schuetzt vor einem kaputten Download, nicht vor einem manipulierten Server.
step_image() {
  sudo apt-get update -qq
  sudo apt-get install -y -qq qemu-system-x86 qemu-utils genisoimage >/dev/null
  # Die groessere freie Platte nehmen: die VM-Platte waechst beim Docker-Verbund um mehrere GB.
  local free_root free_mnt V
  free_root="$(df --output=avail -k "$RUNNER_TEMP" | tail -1)"
  free_mnt="$(df --output=avail -k /mnt 2>/dev/null | tail -1 || echo 0)"
  if [ "${free_mnt:-0}" -gt "$free_root" ]; then sudo mkdir -p /mnt/vm && sudo chown "$USER" /mnt/vm; V=/mnt/vm; else V="$RUNNER_TEMP/vmdisk"; mkdir -p "$V"; fi
  echo "VM_DIR=$V" >> "$GITHUB_ENV"
  local base=debian-12-generic-amd64.qcow2 url=https://cloud.debian.org/images/cloud/bookworm/latest
  curl -fsSL "$url/$base" -o "$V/base.qcow2"
  curl -fsSL "$url/SHA512SUMS" -o "$V/SHA512SUMS"
  (cd "$V" && grep " $base\$" SHA512SUMS | sed "s| $base\$| base.qcow2|" | sha512sum -c -)
  echo "Debian-Build: $(curl -fsSL "$url/" | grep -o 'debian-12-generic-amd64-[0-9-]*\.qcow2' | head -1)"
  mark image_downloaded
  # Overlay auf dem unveraenderten Abbild; cloud-init (growpart) vergroessert in der VM das Dateisystem.
  qemu-img create -q -f qcow2 -b base.qcow2 -F qcow2 "$V/disk.qcow2" "${VM_DISK_GB}G"
  ssh-keygen -q -t ed25519 -N '' -f "$W/key"
  # LANG=C wie eine Proxmox-Vorlage: das cloud-init-Modul locale schreibt den Vorgabewert der Distribution nach
  # /etc/default/locale, darum setzt runcmd (laeuft spaeter) die Datei erst danach auf LANG=C. Weder curl noch gnupg werden
  # vorinstalliert oder nachgereicht: was das Image nicht mitbringt, muss setup.sh selbst holen.
  cat > "$W/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$W/key.pub")
runcmd:
  - [sh, -c, "echo LANG=C > /etc/default/locale"]
EOF
  printf 'instance-id: debian-l2-1\nlocal-hostname: debian-l2\n' > "$W/meta-data"
  genisoimage -quiet -output "$V/seed.iso" -volid cidata -joliet -rock "$W/user-data" "$W/meta-data"
}

step_boot() {
  # VM_DIR kommt aus $GITHUB_ENV des Schritts "image".
  qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp "$VM_CPUS" -m "$VM_MEM" \
    -drive "file=$VM_DIR/disk.qcow2,if=virtio,format=qcow2" \
    -drive "driver=raw,file=$VM_DIR/seed.iso,if=virtio,readonly=on" \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
    -display none -serial "file:$W/console.log" -pidfile "$W/qemu.pid" -daemonize
  mark vm_started
  local _ up=""
  for _ in $(seq 1 120); do
    if vm true 2>/dev/null; then up=1; break; fi
    sleep 3
  done
  [ -n "$up" ] || { echo "::error::Kein SSH in 6 Minuten"; tail -40 "$W/console.log"; exit 1; }
  mark ssh_up
  vm 'cloud-init status --wait' || { vm 'sudo tail -60 /var/log/cloud-init.log' || true; exit 1; }
  mark cloud_init_done
  vm 'bash -s' <<'VM'
echo "--- Debian";                 grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
echo "--- /etc/default/locale";    cat /etc/default/locale
grep -qx 'LANG=C' /etc/default/locale
echo "--- Docker vorab?";          if command -v docker >/dev/null 2>&1; then echo "JA (unerwartet)"; exit 1; else echo "nein (kalter Rechner)"; fi
echo "--- curl/gnupg vorab?";      for c in curl gpg; do if command -v "$c" >/dev/null 2>&1; then echo "$c: ja"; else echo "$c: nein"; fi; done
systemd-detect-virt; nproc; free -m | head -2; df -h /
VM
}

# setup.sh wie ein Nutzer: Datei in die VM, als root ausfuehren, Docker kommt aus Dockers Paketquelle, der Kern startet.
step_setup() {
  vm_scp provisioning/setup.sh debian@127.0.0.1:setup.sh
  # Das Abbild kommt ueber -R aus der crane-Registry am Runner; ohne den Tunnel scheitert der Pull in der VM.
  ssh -f -N -R 127.0.0.1:5001:127.0.0.1:5001 -o ExitOnForwardFailure=yes "${SSH_O[@]}" debian@127.0.0.1
  mark setup_start
  local rc=0
  vm_setup > "$RUNNER_TEMP/setup1.out" 2> "$RUNNER_TEMP/setup1.err" || rc=$?
  mark setup_done
  # Der Einmal-Link gehoert in kein oeffentliches Log: Wert maskieren, bevor die Ausgabe erscheint.
  local tok
  tok="$(cat "$RUNNER_TEMP/setup1.out" "$RUNNER_TEMP/setup1.err" | grep -o 'start?t=[^[:space:]]*' | head -1 | sed 's/^start?t=//' || true)"
  [ -z "$tok" ] || echo "::add-mask::$tok"
  cat "$RUNNER_TEMP/setup1.err" >&2
  cat "$RUNNER_TEMP/setup1.out"
  [ "$rc" = 0 ] || { echo "::error::setup.sh Exit $rc"; exit 1; }
  grep -q 'ssh -L 5881:127.0.0.1:5881 debian@' "$RUNNER_TEMP/setup1.out" || { echo "::error::Ausgabe ohne SSH-Befehl fuer den Fragebogen"; exit 1; }
  [ -n "$tok" ] || { echo "::error::Ausgabe ohne Fragebogen-Link"; exit 1; }
  vm 'dpkg -s docker-ce | grep -E "^(Status|Version):"; grep -h Suites /etc/apt/sources.list.d/docker.sources'
  vm 'test "$(systemctl is-enabled lifeagents-stack.service)" = enabled && systemctl is-active lifeagents-stack.service'
  # Passwort des Verbunds nie in der Ausgabe von setup.sh.
  local pw
  pw="$(vm 'sudo docker exec lifeagents-master printenv LA_PG_SUPERPW')"
  [ -n "$pw" ] || { echo "::error::Kein Passwort des Verbunds im master (LA_PG_SUPERPW leer)"; exit 1; }
  echo "::add-mask::$pw"
  if grep -qF "$pw" "$RUNNER_TEMP/setup1.out" "$RUNNER_TEMP/setup1.err"; then echo "::error::Passwort in der Ausgabe von setup.sh"; exit 1; fi
  printf '%s' "$pw" | sha256sum | cut -c1-16 > "$RUNNER_TEMP/pw.hash"
}

# Ersatz nur dort, wo es die echte Gegenstelle im Lauf nicht gibt (Grenzen im Kopf): Telegram-Attrappe, erfundene Werte.
mock_telegram_up() {
  vm 'mkdir -p ~/mocks/log'
  vm_scp tests/mock_telegram/server.js debian@127.0.0.1:mocks/server.js
  vm_scp -r tests/mock_telegram/docs debian@127.0.0.1:mocks/docs
  local img _
  img="$(vm 'sudo docker inspect -f "{{.Config.Image}}" lifeagents-master')"
  # Das Etikett io.lifeagents.install=lifeagents laesst den Abbau (setup.sh --uninstall) die Attrappe mitnehmen.
  vm "sudo docker run -d --name lifeagents-tgmock --network container:lifeagents-anchor --label io.lifeagents.install=lifeagents \
    --entrypoint node -e N8NTEST_MOCK_TG_PORT=8089 -e N8NTEST_MOCK_TG_LOG=/log/mock_telegram.jsonl \
    -v \$HOME/mocks/server.js:/m/server.js:ro -v \$HOME/mocks/docs:/m/docs:ro -v \$HOME/mocks/log:/log '$img' /m/server.js >/dev/null"
  for _ in $(seq 1 25); do vm 'sudo docker exec lifeagents-master curl -sf http://127.0.0.1:8089/__health >/dev/null' 2>/dev/null && break; sleep 1; done
  vm 'sudo docker exec lifeagents-master curl -sf http://127.0.0.1:8089/__health >/dev/null' || { echo "::error::Telegram-Attrappe antwortet nicht"; exit 1; }
  # Fragebogen-Prozess mit der Weiche neu starten: erst nur den node-Prozess des Fragebogens beenden (nicht die Schleife des master).
  vm 'sudo docker exec lifeagents-master sh -c '"'"'for d in /proc/[0-9]*; do
      if tr "\0" " " < $d/cmdline 2>/dev/null | grep -q "^node /opt/lifeagents/provisioning/wizard/server.js $"; then kill "${d#/proc/}"; fi
    done'"'"
  sleep 2
  # hand-injected: LIFEAGENTS_TELEGRAM_API zeigt die Bot-Aufrufe auf die Attrappe; compose.yml gibt die Weiche dem Fragebogen nicht mit (Test-Weiche SC_TEST_SWITCHES, lib/stack_core.sh)
  vm 'sudo docker exec -d -e LIFEAGENTS_TELEGRAM_API=http://127.0.0.1:8089 lifeagents-master sh -c "exec node /opt/lifeagents/provisioning/wizard/server.js >>/tmp/wizard.log 2>&1"'
  for _ in $(seq 1 30); do vm 'sudo docker exec lifeagents-master node /opt/lifeagents/provisioning/wizard/ctl.js status >/dev/null' 2>/dev/null && break; sleep 1; done
}
# Dienst sperren (v4 und v6): der Fragebogen prueft Telegram-Token und Anthropic-Schluessel live gegen die festen Adressen (nur der
# Bot-Aufruf der Brueckenfunktion tg-check folgt der Test-Weiche) und lehnt erfundene Werte ab; "nicht erreichbar" nimmt er mit
# Hinweis an (wie ohne Netz).
block_host() {
  local h="$1"
  vm "bash -s '$h'" <<'VM'
h="$1"
for ip in $(getent ahostsv4 "$h" | awk '{print $1}' | sort -u); do sudo ip route replace blackhole "$ip/32"; done
for ip in $(getent ahostsv6 "$h" 2>/dev/null | awk '{print $1}' | sort -u); do sudo ip -6 route replace blackhole "$ip/128" || true; done
code="$(sudo docker exec lifeagents-master curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://$h/" || true)"
echo "$h aus dem master: HTTP $code"
[ "$code" = 000 ]
VM
}
step_mocks() {
  vm 'sudo mkdir -p /srv/lifeagents-backup && sudo chmod 777 /srv/lifeagents-backup'
  mock_telegram_up
  touch "$RUNNER_TEMP/tgmock.up"
  block_host api.telegram.org
  block_host api.anthropic.com
  mark mocks_ready
}
# Frischer Link wie `lifeagents wizard-url` (der von setup.sh ist nach dem Neustart des Fragebogens nicht mehr gueltig), Tunnel wie am Laptop.
step_link() {
  local url tok
  url="$(vm 'sudo lifeagents wizard-url' | grep -o 'http://127.0.0.1:5881/start?t=[^[:space:]]*' | head -1)"
  [ -n "$url" ] || { echo "::error::lifeagents wizard-url gab keinen Link"; exit 1; }
  tok="${url#*t=}"
  [ -z "$tok" ] || echo "::add-mask::$tok"
  (umask 077; printf '%s' "$url" > "$RUNNER_TEMP/klick.url")
}
step_tunnel() {
  ssh -f -N -L 5881:127.0.0.1:5881 -o ExitOnForwardFailure=yes "${SSH_O[@]}" debian@127.0.0.1
}

# Browser wie am Laptop des Nutzers: frischer Link, Tunnel (ssh -L), Playwright aus dem Lockfile.
step_browser() {
  step_link
  step_tunnel
  node --version
  npm ci --no-audit --no-fund --prefix tests/install
  npx --prefix tests/install playwright install --with-deps chromium
}
# Den Fragebogen durchklicken (erfundene Werte).
step_klick() {
  KLICK_URL="$(cat "$RUNNER_TEMP/klick.url")" KLICK_OUT="${KLICK_OUT:-$RUNNER_TEMP/klick-out}" node tests/install/wizard_klick.cjs
}

# Kopplung und Abschluss ohne echtes Telegram: dasselbe Skript wie in genericity.yml (Verbund-Lauf). Es armiert die Kopplung ueber
# `lifeagents household pair-owner --machine`, schickt /start <Code> an den echten Webhook des Orchestrators und prueft Abschluss,
# Begruessung (kommt bei der Attrappe an), chat_id in den Workflows und doctor. Der Fragebogen steht dabei auf der Seite "Verbinden"; sein eigenes Koppeln ist nicht Teil des Laufs.
step_pair() {
  vm_scp tests/mock_telegram/pair_and_finalize.sh debian@127.0.0.1:mocks/pair_and_finalize.sh
  vm 'sudo bash /home/debian/mocks/pair_and_finalize.sh lifeagents /home/debian/mocks/log'
  mark paired
}

# Ende-Kontrolle nach Fragebogen und Kopplung: n8n antwortet, Verbund gesund, doctor gruen, Workflows da und veroeffentlicht.
step_verify() {
  mark questionnaire_done
  local _
  for _ in $(seq 1 60); do vm 'curl -fsS --max-time 2 -o /dev/null http://127.0.0.1:5880/healthz/readiness' 2>/dev/null && break; sleep 2; done
  vm 'curl -fsS --max-time 5 -o /dev/null -w "n8n readiness: HTTP %{http_code}\n" http://127.0.0.1:5880/healthz/readiness'
  vm 'sudo docker exec lifeagents-master stack status --json | tail -n1 | jq -e ".running and ([.services[] | select(.name == \"postgres\") | .health] == [\"healthy\"])" >/dev/null && echo "stack status: running, postgres healthy"'
  vm 'sudo docker exec lifeagents-master bash /opt/lifeagents/provisioning/doctor.sh'
  local total
  total="$(vm "sudo docker exec lifeagents-postgres psql -U postgres -d n8n -tAc 'SELECT count(*) FROM public.workflow_entity' | tr -d '[:space:]'")"
  echo "Workflows: $total"
  local min="${MIN_WORKFLOWS:-100}"
  [ "$total" -ge "$min" ] || { echo "::error::Workflows: $total (erwartet >= $min)"; exit 1; }
  vm "sudo docker exec lifeagents-postgres psql -U postgres -d n8n -tAc 'SELECT count(*) FROM public.workflow_entity WHERE \"activeVersionId\" IS NULL' | tr -d '[:space:]'" | grep -qx 0 \
    || { echo "::error::Unveroeffentlichte Workflows"; exit 1; }
  vm 'sudo docker ps -a --filter "label=io.lifeagents.install=lifeagents" --format "{{.Names}} {{.ID}}" | sort' > "$RUNNER_TEMP/ids.1"
  vm 'sha256sum /usr/local/bin/lifeagents /etc/systemd/system/lifeagents-stack.service' > "$RUNNER_TEMP/files.1"
  cat "$RUNNER_TEMP/ids.1"
  mark verified
}

# Zweitlauf von setup.sh: nichts aendert sich (gleiche Container, gleiche Dateien).
step_second() {
  vm_setup > "$RUNNER_TEMP/setup2.out" 2> "$RUNNER_TEMP/setup2.err" || { cat "$RUNNER_TEMP/setup2.err" >&2; exit 1; }
  cat "$RUNNER_TEMP/setup2.err" >&2
  grep -q 'Nichts zu tun' "$RUNNER_TEMP/setup2.err" || { echo "::error::Zweitlauf meldet nicht 'Nichts zu tun'"; exit 1; }
  vm 'sudo docker ps -a --filter "label=io.lifeagents.install=lifeagents" --format "{{.Names}} {{.ID}}" | sort' > "$RUNNER_TEMP/ids.2"
  diff "$RUNNER_TEMP/ids.1" "$RUNNER_TEMP/ids.2"
  vm 'sha256sum -c -' < "$RUNNER_TEMP/files.1"
  mark second_run
}

# Abbau mit Daten: nichts bleibt zurueck (keine Container, Volumes, Abbilder), Docker selbst bleibt.
step_uninstall() {
  # Die Attrappe gehoert nicht zum Verbund: der Abbau haelt ein Abbild zurueck, das noch ein Container nutzt.
  vm 'sudo docker rm -fv lifeagents-tgmock >/dev/null 2>&1 || true'
  # Tunnel-Geraet abmelden, bevor sein Container verschwindet: es faellt sofort aus dem Tailnet statt erst nach der Frist.
  vm 'sudo docker exec lifeagents-tailscale tailscale logout >/dev/null 2>&1 || true'
  vm_setup --uninstall --delete-data
  vm 'bash -s' <<'VM'
# shellcheck disable=SC2016,SC2029  # die vm()-Befehle sind Text fuer die Shell in der VM: Variablen gehoeren dort aufgeloest, nicht hier
set -euo pipefail
test -z "$(sudo docker ps -aq)" || { echo "Container uebrig:"; sudo docker ps -a; exit 1; }
if sudo docker volume ls -q | grep -q .; then echo "Volumes uebrig:"; sudo docker volume ls -q; exit 1; fi
if sudo docker images -q | grep -q .; then echo "Abbilder uebrig:"; sudo docker images; exit 1; fi
if test -e /usr/local/bin/lifeagents || test -e /etc/systemd/system/lifeagents-stack.service; then echo "Befehl oder Einheit noch da"; exit 1; fi
sudo docker version >/dev/null
echo "Abbau sauber, Docker bleibt."
VM
  mark uninstalled
}

step_summary() {
  [ -s "$RUNNER_TEMP/marks.txt" ] || return 0
  {
    echo "## Debian-VM-Lauf"
    echo "| Phase | Sekunden seit der vorigen Marke |"
    echo "|---|---|"
    local prev='' t name first
    first="$(head -1 "$RUNNER_TEMP/marks.txt" | cut -d' ' -f1)"
    while read -r t name; do [ -z "$prev" ] || echo "| $name | $((t - prev)) |"; prev="$t"; done < "$RUNNER_TEMP/marks.txt"
    echo "| **gesamt** | $((prev - first)) |"
  } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

step_diag() {
  mask_secrets
  echo "=== console.log (Ende)"; tail -40 "$W/console.log" 2>/dev/null || true
  echo "=== crane.log"; tail -20 "$RUNNER_TEMP/crane.log" 2>/dev/null || true
  vm 'sudo docker ps -a --format "{{.Names}} {{.Status}}"; sudo journalctl -u docker -n 30 --no-pager; df -h /' 2>/dev/null || true
  vm 'sudo docker exec lifeagents-master tail -40 /tmp/wizard.log' 2>/dev/null || true
  vm 'tail -20 $HOME/mocks/log/mock_telegram.jsonl' 2>/dev/null || true
  vm 'sudo journalctl -u lifeagents-stack.service -n 30 --no-pager' 2>/dev/null || true
}

step_stop() {
  [ ! -s "$W/qemu.pid" ] || sudo kill "$(cat "$W/qemu.pid")" || true
  pkill -f 'ssh -f -N' || true
}

# --- Antwort-Datei-Weg (unbeaufsichtigt, ohne Fragebogen): setup.sh --answers mit dem Helfer der Test-Zugaenge ----------------------
# Der Helfer scripts/ci/install_test_answers.sh macht aus den Secrets (nur im env: des Schritts "answers") die Antwort-Datei samt
# frischem Tailscale-Schluessel (1 h, einmalig). ANSWERS_STANDIN=1 (nur der Lauf ohne Secrets, erfundene Werte, kein Tailnet): wie im
# Klickweg Telegram-Attrappe und gesperrte Dienste; setup.sh laeuft dann zweimal (erst der Kern, dann --answers), weil die Attrappe den
# Namensraum des laufenden Verbunds braucht.
step_answers() {
  mask_secrets
  (umask 077; bash scripts/ci/install_test_answers.sh "$RUNNER_TEMP/answers.env")
  vm_scp "$RUNNER_TEMP/answers.env" debian@127.0.0.1:answers.env
  vm 'chmod 600 ~/answers.env'
  mark answers_ready
}
step_setup_answers() {
  vm_scp provisioning/setup.sh debian@127.0.0.1:setup.sh
  ssh -f -N -R 127.0.0.1:5001:127.0.0.1:5001 -o ExitOnForwardFailure=yes "${SSH_O[@]}" debian@127.0.0.1
  if [ "${ANSWERS_STANDIN:-}" = 1 ]; then
    vm_setup >/dev/null
    step_mocks
  fi
  mark setup_start
  local rc=0
  vm_setup --answers /home/debian/answers.env > "$RUNNER_TEMP/setup1.out" 2> "$RUNNER_TEMP/setup1.err" || rc=$?
  mark setup_done
  [ "$rc" = 0 ] || { cat "$RUNNER_TEMP/setup1.err" >&2; cat "$RUNNER_TEMP/setup1.out"; echo "::error::setup.sh --answers Exit $rc"; exit 1; }
  # Der Schluessel der Antwort-Datei darf nirgends in der Ausgabe stehen.
  local k v
  for k in TS_AUTHKEY TELEGRAM_BOT_TOKEN ANTHROPIC_API_KEY N8N_OWNER_PASSWORD; do
    v="$(sed -n "s/^$k='\(.*\)'\$/\1/p" "$RUNNER_TEMP/answers.env" | head -1)"
    [ -z "$v" ] || { ! grep -qF -- "$v" "$RUNNER_TEMP/setup1.out" "$RUNNER_TEMP/setup1.err" || { echo "::error::$k steht in der Ausgabe von setup.sh"; exit 1; }; }
  done
  cat "$RUNNER_TEMP/setup1.err" >&2
  cat "$RUNNER_TEMP/setup1.out"
}

# Nach der Installation mit Tunnel: Tunnel steht (ready = Adresse da und Telegram zeigt darauf), Adresse *.ts.net, getWebhookInfo ohne
# Fehler, oeffentlicher Pfad ueber Funnel antwortet von n8n (404 von n8n, nicht von Tailscale; DNS neuer Funnel-Namen braucht bis 10 Min),
# Kosten 0 (usage.jsonl leer). Ohne Tailnet im Lauf (kein REACH_MODE in der Antwort-Datei): nur der Hinweis.
step_reach() {
  mask_secrets
  if ! grep -q "^REACH_MODE='tunnel'" "$RUNNER_TEMP/answers.env"; then
    echo "::notice::Tunnel-Teil uebersprungen: kein Tailscale-Zugang in diesem Lauf."
    return 0
  fi
  local _ st='' dom='' code=''
  for _ in $(seq 1 90); do
    st="$(vm 'sudo docker exec lifeagents-master bash /opt/lifeagents/provisioning/compose/reach_ctl.sh status' 2>/dev/null | tail -n1 | jq -r '.state // empty' 2>/dev/null || true)"
    [ "$st" = ready ] && break
    sleep 10
  done
  [ "$st" = ready ] || { echo "::error::Tunnel nicht ready nach 15 Minuten (Zustand: ${st:-?})"; vm 'sudo docker exec lifeagents-master bash /opt/lifeagents/provisioning/compose/reach_ctl.sh status' || true; exit 1; }
  dom="$(vm "sudo docker exec lifeagents-master sh -c 'grep ^DOMAIN= /etc/lifeagents/core.env | cut -d= -f2-'" | tr -d "\r'\"")"
  case "$dom" in *.ts.net) echo "Adresse: $dom" ;; *) echo "::error::DOMAIN ist keine ts.net-Adresse"; exit 1 ;; esac
  local tok info
  tok="$(sed -n "s/^TELEGRAM_BOT_TOKEN='\(.*\)'\$/\1/p" "$RUNNER_TEMP/answers.env" | head -1)"
  info="$(printf 'url = "https://api.telegram.org/bot%s/getWebhookInfo"\n' "$tok" | curl -sS --max-time 20 -K -)"
  jq -e --arg p "https://$dom/webhook/" '.result.url | startswith($p)' <<<"$info" >/dev/null || { echo "::error::Telegram zeigt nicht auf die Adresse des Rechners"; exit 1; }
  jq -e '(.result.last_error_message // "") == ""' <<<"$info" >/dev/null || { echo "::error::getWebhookInfo meldet einen Zustellfehler"; exit 1; }
  echo "getWebhookInfo: Adresse stimmt, kein Zustellfehler"
  local body="$RUNNER_TEMP/probe.body"
  for _ in $(seq 1 60); do
    code="$(curl -s -o "$body" -w '%{http_code}' --max-time 10 "https://$dom/webhook/lifeagents-probe-ci" || true)"
    # 404 von n8n nennt den Webhook; ein 404 von Tailscale oder einem Proxy davor tut das nicht.
    [ "$code" = 404 ] && grep -qi 'webhook' "$body" && break
    code=''
    sleep 10
  done
  [ -n "$code" ] || { echo "::error::Oeffentlicher Pfad ueber $dom antwortet nicht von n8n (kein 404 mit n8n-Meldung)"; head -c 300 "$body" 2>/dev/null || true; exit 1; }
  echo "Oeffentlicher Pfad ueber den Funnel: n8n antwortet (404 fuer unbekannten Webhook)"
  vm 'sudo docker exec lifeagents-gateway true' || { echo "::error::Gateway-Container nicht erreichbar, Kosten nicht pruefbar"; exit 1; }
  local n
  n="$(vm "sudo docker exec lifeagents-gateway sh -c 'wc -l < /var/lib/lifeagents-llm-gateway/usage.jsonl 2>/dev/null || echo 0'" | tr -d '[:space:]')"
  [ "${n:-0}" = 0 ] || { echo "::error::Das Gateway hat $n Anfragen mitgeschrieben (erwartet 0)"; exit 1; }
  echo "Kosten: 0 Anfragen an Anthropic"
  mark reach_ok
}

# Aufraeumen (auch nach Fehlern): Tailscale-Geraet abmelden, Webhook des Test-Bots loeschen (nie drop_pending_updates), Antwort-Dateien weg.
# Der Token kommt aus der Antwort-Datei, damit kein weiterer Schritt Secrets braucht.
step_answers_cleanup() {
  vm 'sudo docker exec lifeagents-tailscale tailscale logout' >/dev/null 2>&1 || true
  if [ -s "$RUNNER_TEMP/answers.env" ]; then
    local tok
    tok="$(sed -n "s/^TELEGRAM_BOT_TOKEN='\(.*\)'\$/\1/p" "$RUNNER_TEMP/answers.env" | head -1)"
    [ -z "$tok" ] || echo "::add-mask::$tok"
    if [ "${ANSWERS_STANDIN:-}" != 1 ] && [ -n "$tok" ]; then
      printf 'url = "https://api.telegram.org/bot%s/deleteWebhook"\n' "$tok" | curl -sS -o /dev/null -w 'deleteWebhook: HTTP %{http_code}\n' --max-time 20 -K - || true
    fi
  fi
  vm 'rm -f ~/answers.env' >/dev/null 2>&1 || true
  rm -f "$RUNNER_TEMP/answers.env"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  kvm) step_kvm ;; registry) step_registry ;; image) step_image ;; boot) step_boot ;; setup) step_setup ;;
  mocks) step_mocks ;; answers) step_answers ;; setup_answers) step_setup_answers ;; reach) step_reach ;; answers_cleanup) step_answers_cleanup ;; link) step_link ;; tunnel) step_tunnel ;; browser) step_browser ;; klick) step_klick ;; pair) step_pair "$@" ;; verify) step_verify ;;
  second) step_second ;; uninstall) step_uninstall ;; summary) step_summary ;; diag) step_diag ;; stop) step_stop ;;
  *) echo "Aufruf: bash tests/install/debian_vm.sh kvm|registry|image|boot|setup|mocks|answers|setup_answers|reach|answers_cleanup|link|tunnel|browser|klick|pair|verify|second|uninstall|summary|diag|stop" >&2; exit 64 ;;
esac
