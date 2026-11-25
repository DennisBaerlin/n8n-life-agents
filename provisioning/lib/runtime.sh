# runtime.sh — Betriebsart des Installers: systemd (LXC/Debian, Standard) oder compose (Verbund aus Containern).
# Gesourct von common.sh (kein Shebang, kein set -e). Diese Datei ist die einzige Stelle, die weiss, wie Postgres, n8n und
# die Dienste erreicht werden: rohe `runuser`/`systemctl`- und jede `docker`-Zeile stehen nur hier (contract_lint 32). Im
# systemd-Betrieb sind die Wrapper duenne Huellen um die direkten Aufrufe; keine vorgetaeuschten Programme (kein Fake-systemctl).
#
# LIFEAGENTS_RUNTIME=compose (gesetzt im master-Container, provisioning/compose/compose.yml): Postgres, n8n und LLM-Gateway
# laufen als eigene Container in einem Netz-Namensraum (network_mode: service:anchor, Pod-Muster), der Installer im master.
# Alle 127.0.0.1-Annahmen (5432, 5678, 8090) bleiben wahr.
#
# Docker-Positivliste (contract_lint 32, gilt auch fuer die Start-App): erlaubt sind nur
#   docker exec · docker inspect · docker image inspect · docker version · docker volume inspect · docker volume create ·
#   docker info --format '{{.MemTotal}}' (nur rt_docker_mem) · docker stop "${LA_PROJECT}-swap" (nur rt_swap_helper_stop) ·
#   docker run --rm · docker ps --format '{"image":…}' (nur in rt_published_ports_json: festes JSON-Objekt, keine
#   Kennungen) · docker compose -p "$LA_PROJECT" <up|start|stop|restart|ps|config|pull|version|down>.
# Dazu fuer den Deinstaller (Pruefliste Nr. 17, nur nach ausdruecklicher Rueckfrage): `docker volume rm <name>` nur in
# rt_volume_rm_own (prueft vorher unser Label an genau diesem einen Namen) und `compose down` nur in rt_stack_down (ohne
# -v/--rmi: externe Volumes und Images bleiben; entfernt nur Container + Netze DIESES Projekts) und `docker image rm "$1"`
# nur in rt_image_rm_own (ohne -f: nutzt ein Container das Abbild, lehnt Docker ab; welche Abbilder, waehlt der Kern
# lib/stack_core.sh aus compose.yml abzueglich der vorher schon vorhandenen).
# Verboten sind breite Befehle (prune, --all/-a, ps -q, rm $(…), down -v/--volumes, --rmi, system …): unser master hat
# Zugriff auf ganz Docker, ein Fehler hier traefe fremde Container (z. B. Paperless) — die wichtigste Regel des Verbunds.
# Bind-Mounts nur per `--mount` (der Schalter -v ist wegen `down -v` gesperrt). Alles, was wir anlegen, traegt den
# Projektnamen als Vorsatz und das Label io.lifeagents.install=<projekt>.

rt_is_compose() { [ "${LIFEAGENTS_RUNTIME:-systemd}" = compose ]; }

# --- Namen im Verbund (eine Adresse; compose.yml bildet dieselben Namen aus LA_PROJECT) ----------------------------------
LA_PROJECT="${LA_PROJECT:-lifeagents}"
LA_LABEL="io.lifeagents.install"
LA_COMPOSE_FILE="${LA_COMPOSE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/compose/compose.yml}"
LA_PG_CONTAINER="${LA_PG_CONTAINER:-${LA_PROJECT}-postgres}"
LA_N8N_CONTAINER="${LA_N8N_CONTAINER:-${LA_PROJECT}-n8n}"
LA_GW_CONTAINER="${LA_GW_CONTAINER:-${LA_PROJECT}-gateway}"
LA_N8N_EXEC_USER="${LA_N8N_EXEC_USER:-node}"   # Nutzer des n8n-Images (uid 1000); im systemd-Betrieb gilt $N8N_USER
# Zustandsfuehrende Volumes (compose.yml: alle `external`, `compose down` loescht sie nie; nur der Deinstaller nach
# Rueckfrage). Eine Liste fuer rt_volumes_ensure und den Deinstaller.
LA_STATE_VOLUMES="pgdata n8n_home etc_n8n etc_la var_la rt_tree gw_state ts_state wizard_state"
# Abgeleitete Volumes (compose.yml: von Compose verwaltet, jeder Installer-Lauf schreibt sie neu, keine Nutzerdaten):
# der Deinstaller entfernt sie immer. contract_lint 33 haelt die Liste gleich mit compose.yml.
# shellcheck disable=SC2034  # gelesen von lib/stack_core.sh
LA_DERIVED_VOLUMES="shared gw_code n8n_patches reach_conf caddy_data"
# Variablen, die compose.yml interpoliert: der Kern (lib/stack_core.sh) setzt sie, der Helfer des master-Wechsels
# (lib/master_swap.sh) schreibt sie in seine Env-Datei. contract_lint 33 haelt die Liste gleich mit compose.yml.
# shellcheck disable=SC2034  # gelesen von lib/master_swap.sh und lib/stack_core.sh
LA_STACK_VARS="LA_PROJECT LA_EDGE_PORT LA_WIZARD_PORT LA_PG_SUPERPW LA_MASTER_IMAGE LA_TS_HOSTNAME"

# _rt_compose <args…> — docker compose mit festem Projekt und fester Datei (nie das Projekt aus der Umgebung raten).
_rt_compose() { docker compose -p "$LA_PROJECT" -f "$LA_COMPOSE_FILE" "$@"; }

# --- Postgres als Superuser ---------------------------------------------------------------------------------------------
# pg_su_exec <programm> [args…] — ein Programm als Postgres-Superuser (systemd: runuser/Peer-Auth, compose: docker exec).
# compose: ohne -i, stdin wird nicht weitergereicht. `docker exec -i` liest stdin bis EOF — in einer
# `while read … done <<<"$liste"`-Schleife (provision.sh Paket-Loop) frisst es den Rest der Liste.
pg_su_exec() {
  if rt_is_compose; then docker exec -u postgres "$LA_PG_CONTAINER" "$@"
  else runuser -u "${DB_SUPERUSER:-postgres}" -- "$@"; fi
}
# pg_su_stdin <programm> [args…] — wie pg_su_exec, reicht aber stdin weiter (pg_restore -f -, psql < datei, Pipes).
pg_su_stdin() {
  if rt_is_compose; then docker exec -i -u postgres "$LA_PG_CONTAINER" "$@"
  else runuser -u "${DB_SUPERUSER:-postgres}" -- "$@"; fi
}
# pg_su_psql [psql-args…] — psql als Superuser. compose: stdin nur, wenn psql es liest (weder -c noch -f, oder `-f -`);
# `-f <datei>` wird zu `-f -` + Datei als stdin (die Datei liegt im master, nicht im Postgres-Container).
pg_su_psql() {
  if ! rt_is_compose; then pg_su_exec psql "$@"; return; fi
  local a=() f='' has_c=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f)       f="$2"; a+=(-f -); shift 2 ;;
      -f*)      f="${1#-f}"; a+=(-f -); shift ;;
      -c|-[A-Za-z]*c) has_c=1; a+=("$1"); shift ;;
      *)        a+=("$1"); shift ;;
    esac
  done
  if [ "$f" = - ]; then pg_su_stdin psql "${a[@]}"
  elif [ -n "$f" ]; then pg_su_stdin psql "${a[@]}" < "$f"
  elif [ "$has_c" -eq 1 ]; then pg_su_exec psql "${a[@]}"
  else pg_su_stdin psql "${a[@]}"; fi
}
# need_su_tools / require_su_tools — ist der Superuser-Zugang (runuser+psql bzw. docker) vorhanden?
need_su_tools()    { if rt_is_compose; then need_cmd docker; else need_cmd psql && need_cmd runuser; fi; }
require_su_tools() { if rt_is_compose; then require_cmd docker; else require_cmd runuser; fi; }
# pg_ready — nimmt PostgreSQL Verbindungen an? compose: ueber TCP (-h 127.0.0.1) wie der Healthcheck — der Init-Server
# eines frischen Volumes lauscht nur am Socket und startet danach neu; der Socket-Test waere dort zu frueh gruen.
pg_ready() {
  if rt_is_compose; then pg_su_exec pg_isready -q -h 127.0.0.1
  else need_cmd pg_isready && pg_isready -q; fi
}
# pg_wait_ready [versuche] — bis zu N Sekunden auf pg_ready warten (Erstinstallation, Neustart). 0 = bereit.
pg_wait_ready() {
  local n="${1:-30}" _
  for _ in $(seq 1 "$n"); do pg_ready 2>/dev/null && return 0; sleep 1; done
  return 1
}

# --- n8n ----------------------------------------------------------------------------------------------------------------
# n8n_bin_path — Pfad/Name des n8n-Programms (compose: Name im n8n-Container; im master nie installiert).
n8n_bin_path() { if rt_is_compose; then printf 'n8n'; else command -v n8n 2>/dev/null || true; fi; }
# n8n_input_dir -> Ordner fuer Dateien, die `n8n import:*` liest. compose: immer das Volume /shared (der n8n-Container sieht
#   vom master nur dieses); nicht aus $TMPDIR ableiten, denn Kindprozesse mit schmaler Umgebung (Wizard: childEnv) haben es nicht.
n8n_input_dir() { if rt_is_compose; then printf '/shared'; else printf '%s' "${TMPDIR:-/tmp}"; fi; }
# n8n_cli_env <env-datei> <n8n-args…> — n8n-CLI (import:workflow/credentials) mit geladener n8n.env, als n8n-Nutzer.
# compose: im n8n-Container; Eingabe-Dateien muessen dort unter demselben Pfad liegen (Volume `shared`, n8n_input_dir; TMPDIR des
# master). Lader wie im Container-Entrypoint: KEY=wert roh (systemd-EnvironmentFile-Semantik), kein Shell-Quoting.
n8n_cli_env() {
  local envf="$1"; shift
  if rt_is_compose; then
    # shellcheck disable=SC2016  # $1/$l werden erst in der Container-Shell ausgewertet
    docker exec -u "$LA_N8N_EXEC_USER" "$LA_N8N_CONTAINER" sh -c '
      while IFS= read -r l || [ -n "$l" ]; do case "$l" in ""|"#"*) ;; *=*) export "$l" ;; esac; done < "$1"
      shift; exec n8n "$@"' _ "$envf" "$@"
  else
    # shellcheck disable=SC2016
    runuser -u "$N8N_USER" -- bash -c 'set -a; . "$1"; set +a; shift; exec "$@"' _ "$envf" "$(n8n_bin_path)" "$@"
  fi
}
# n8n_exec <cmd…> — ein Programm dort ausfuehren, wo n8n liegt (compose: im n8n-Container; systemd: lokal).
n8n_exec() { if rt_is_compose; then docker exec -u "$LA_N8N_EXEC_USER" "$LA_N8N_CONTAINER" "$@"; else "$@"; fi; }
# n8n_present — gibt es ein n8n, das man fragen kann? (compose: der Container laeuft)
n8n_present() { if rt_is_compose; then svc_is_active n8n; else need_cmd n8n; fi; }
# n8n_image_tar <verzeichnis> — tar-Strom eines Verzeichnisses aus dem unveraenderten n8n-Image (nur compose: die
# n8n-Korrektur legt eine Kopie des Verzeichnisses samt korrigierter Datei ins Volume, s. n8n_patches.sh).
n8n_image_tar() {
  docker run --rm --name "${LA_PROJECT}-patchsrc" --label "${LA_LABEL}=${LA_PROJECT}" --network none \
    --entrypoint tar "${LA_N8N_IMAGE:?LA_N8N_IMAGE nicht gesetzt}" -C "$1" -cf - .
}
# n8n_live_cat <pfad> — die Datei, wie n8n sie gerade sieht (compose: im laufenden Container, inkl. Patch-Mount).
n8n_live_cat() { if rt_is_compose; then docker exec "$LA_N8N_CONTAINER" cat "$1"; else cat "$1"; fi; }

# --- Dienste: systemd-Unit oder Compose-Dienst --------------------------------------------------------------------------
# svc_service <unit> -> Compose-Dienstname; rc 1 = im Verbund nicht vorhanden (Timer, Firewall …).
svc_service() {
  case "$1" in
    n8n|n8n.service)                                       printf 'n8n' ;;
    lifeagents-llm-gateway|lifeagents-llm-gateway.service) printf 'gateway' ;;
    postgresql|postgresql.service)                         printf 'postgres' ;;
    *) return 1 ;;
  esac
}
# --- Stilllegung (lib/retire_cli.sh): nie zwei Bots -----------------------------------------------------------------------
# Solange die Datei liegt, startet nichts n8n: ein gestartetes n8n setzt beim Aktivieren den Telegram-Webhook neu und holt den
# Bot von der neuen Maschine zurueck. Die Sperre sitzt hier, weil jeder Start (Update, Paket, Einstellung, Kopplung) ueber
# diese Wrapper laeuft; der Boot-Start im Verbund prueft dieselbe Datei im Volume var_la (stack_core.sh sc_start).
# Nur `retire --undo` hebt sie fuer seinen Lauf auf (LIFEAGENTS_RETIRE_UNDO=1).
LA_RETIRED_NAME=retired
la_retired_file() { printf '%s/%s' "${LIFEAGENTS_STATE_DIR:-/var/lib/lifeagents}" "$LA_RETIRED_NAME"; }
la_is_retired() { [ -e "$(la_retired_file)" ] && [ "${LIFEAGENTS_RETIRE_UNDO:-0}" != 1 ]; }
# „Umzug offen“ (lib/move_cli.sh): auf der NEUEN Maschine ab `move apply` bis `move done`. Die Datei sperrt jeden Versionswechsel
# (update_runner.sh update_cli, upgrade_guard.sh upgrade_move_guard: rollback und provision.sh): der Rueckweg auf die alte Maschine nimmt
# die Sicherung der neuen und verlangt dieselbe Release.
LA_MOVE_NAME=move-open
la_move_file() { printf '%s/%s' "${LIFEAGENTS_STATE_DIR:-/var/lib/lifeagents}" "$LA_MOVE_NAME"; }
la_move_open() { [ -e "$(la_move_file)" ]; }
# la_move_text -> der eine Satz dieser Sperre (alle drei Wege).
la_move_text() { printf 'Updates sind gesperrt, solange der Umzug nicht abgenommen ist (der Rückweg auf die alte Maschine braucht dieselbe Version). Nach der Abnahme: lifeagents move done'; }
# _rt_n8n_blocked <unit…> — rc 0 (= blockiert, mit Meldung), wenn eine der Units n8n ist und die Installation stillgelegt.
_rt_n8n_blocked() {
  local u
  la_is_retired || return 1
  for u in "$@"; do
    if [ "$(svc_service "$u" 2>/dev/null || true)" = n8n ]; then
      printf '[x] n8n bleibt aus: diese Installation ist stillgelegt (Umzug). Zurück: lifeagents retire --undo\n' >&2
      return 0
    fi
  done
  return 1
}
_svc_container() {
  case "$(svc_service "$1")" in
    n8n) printf '%s' "$LA_N8N_CONTAINER" ;; gateway) printf '%s' "$LA_GW_CONTAINER" ;;
    postgres) printf '%s' "$LA_PG_CONTAINER" ;; *) return 1 ;;
  esac
}
# svc_is_active <unit> — 0 = laeuft (systemd: is-active, compose: Container-Status running).
svc_is_active() {
  if rt_is_compose; then
    local c; c="$(_svc_container "$1")" || return 1
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]
  else systemctl is-active --quiet "$1"; fi
}
# svc_up <unit> — compose: Container anlegen/starten (`up -d --no-deps`; aendert einen laufenden Container mit
# unveraenderter Definition nicht). systemd: enable --now.
svc_up() {
  if _rt_n8n_blocked "$1"; then return 1; fi
  if rt_is_compose; then _rt_compose up -d --no-deps "$(svc_service "$1")" >&2
  else systemctl enable --now "$1" >/dev/null 2>&1 || systemctl enable --now "$1"; fi
}
# svc_start / svc_stop <unit…> — compose: nur die Units, die ein Dienst des Verbunds sind (Timer gibt es dort nicht).
svc_start() {
  if _rt_n8n_blocked "$@"; then return 1; fi
  if rt_is_compose; then _svc_compose_each start "$@"; else systemctl start "$@"; fi
}
svc_stop()  { if rt_is_compose; then _svc_compose_each stop "$@"; else systemctl stop "$@"; fi; }
_svc_compose_each() {
  local verb="$1" u s svcs=(); shift
  for u in "$@"; do s="$(svc_service "$u")" && svcs+=("$s"); done
  [ "${#svcs[@]}" -gt 0 ] || return 0
  case "$verb" in   # feste Woerter statt "$verb": contract_lint 32 prueft jeden Compose-Unterbefehl gegen die Positivliste
    start) _rt_compose start "${svcs[@]}" >&2 ;;
    stop)  _rt_compose stop "${svcs[@]}" >&2 ;;
  esac
}
# svc_restart <unit> — compose: `docker restart` (Env/Code liest der Container bei jedem Start frisch).
svc_restart() {
  if _rt_n8n_blocked "$1"; then return 1; fi
  if rt_is_compose; then docker restart "$(_svc_container "$1")" >/dev/null
  else systemctl restart "$1"; fi
}
# svc_reload_or_restart <unit> — systemd: reload, sonst restart (Firewall-Unit).
svc_reload_or_restart() {
  if rt_is_compose; then svc_restart "$1"; else systemctl reload "$1" || systemctl restart "$1"; fi
}
# svc_enable <unit> / svc_disable <unit> / svc_daemon_reload — reine systemd-Verwaltung; compose: no-op (der Verbund
# kennt keine Units, Container-Start regelt `restart: unless-stopped`).
svc_enable()        { rt_is_compose && return 0; systemctl enable "$1" >/dev/null 2>&1 || true; }
svc_disable()       { rt_is_compose && return 0; systemctl disable "$1" >/dev/null 2>&1 || true; }
svc_daemon_reload() { rt_is_compose && return 0; systemctl daemon-reload; }
# svc_logs_hint <unit> [zeilen] -> der Diagnose-Befehl fuer Meldungen (Text, wird nicht ausgefuehrt; Standard 100 Zeilen).
svc_logs_hint() {
  if rt_is_compose; then printf 'docker logs --tail %s %s' "${2:-100}" "$(_svc_container "$1" || printf '%s' "$1")"
  else printf 'journalctl -u %s -n %s' "$1" "${2:-100}"; fi
}
# svc_journal_since <unit> <seit> — Log-Zeilen eines Dienstes seit <seit> (journalctl-Form '-24h'; doctor:
# Gateway-Fallback-Zaehler). compose: docker logs mit derselben Dauer ('-24h' -> '24h').
svc_journal_since() {
  if rt_is_compose; then docker logs --since "${2#-}" "$(_svc_container "$1")" 2>&1
  else need_cmd journalctl && journalctl -u "$1" --since "$2" -o cat 2>/dev/null; fi
}
# systemd_present — laeuft systemd als PID 1? (Preflight; compose: nie)
systemd_present() { ! rt_is_compose && need_cmd systemctl && [ -d /run/systemd/system ]; }

# enable_start_unit <unit> <changed?> — daemon-reload nur bei geaenderter Unit, dann enable + (re)start.
# <changed?> ist der Exit-Status des Schreibens (0 = geaendert). compose: Container statt Unit; Timer/Firewall gibt es im
# Verbund nicht (Aufrufer ueberspringen sie). Env/Code liest der Container bei jedem Start -> bei Aenderung genuegt ein
# Neustart; fehlt der Container oder steht er, legt `up -d --no-deps` ihn an.
enable_start_unit() {
  local unit="$1" changed="${2:-1}"
  if _rt_n8n_blocked "$unit"; then return 1; fi
  if rt_is_compose; then
    svc_service "$unit" >/dev/null || { log "Compose-Betrieb: ${unit} entfällt."; return 0; }
    if [ "$changed" -eq 0 ] && svc_is_active "$unit"; then svc_restart "$unit"; else svc_up "$unit"; fi
    return 0
  fi
  if [ "$changed" -eq 0 ]; then
    systemctl daemon-reload
  fi
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if [ "$changed" -eq 0 ] || ! systemctl is-active --quiet "$unit"; then
    systemctl restart "$unit"
  fi
}

# --- Verbund (nur compose) ----------------------------------------------------------------------------------------------
# rt_docker_ok — antwortet der Docker-Daemon ueber den Socket?
rt_docker_ok() { docker version --format '{{.Server.Version}}' >/dev/null 2>&1; }
# rt_wait_healthy <container> [sekunden] — bis der Healthcheck des Containers `healthy` meldet. 0 = gesund.
rt_wait_healthy() {
  local c="$1" n="${2:-120}" st='' _
  for _ in $(seq 1 "$n"); do
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || true)"
    [ "$st" = healthy ] && return 0
    sleep 1
  done
  return 1
}
# rt_volumes_ensure — die zustandsfuehrenden Volumes anlegen (external in compose.yml, also nicht von Compose). Ein Volume
# mit unserem Namen ohne unser Label gehoert jemand anderem -> Abbruch, nie uebernehmen. rc 0 = alle da.
rt_volumes_ensure() {
  local v name lbl rc
  for v in $LA_STATE_VOLUMES; do
    name="${LA_PROJECT}_${v}"
    rc=0; lbl="$(rt_volume_label "$name")" || rc=$?
    case "$rc" in
      0) [ "$lbl" = "$LA_PROJECT" ] || die "Volume ${name} existiert, gehört aber nicht zu dieser Installation (Label ${LA_LABEL} fehlt) — nichts geändert." ;;
      1) docker volume create --label "${LA_LABEL}=${LA_PROJECT}" "$name" >/dev/null || die "Volume ${name} ließ sich nicht anlegen." ;;
      # `volume create` auf einen vorhandenen Namen gaebe dieses Volume ungeprueft zurueck (auch ein fremdes).
      *) die "Volume ${name} ließ sich nicht prüfen (Docker-Fehler) — nichts angelegt." ;;
    esac
  done
}
# rt_stack_config_check — Prueft die Compose-Datei samt Interpolation (Pruefliste Nr. 13), ohne sie auszugeben: die
# aufgeloeste Fassung enthaelt das Superuser-Passwort (`config --quiet` = nur Fehlermeldungen).
rt_stack_config_check() { _rt_compose config --quiet; }
# rt_stack_pull <dienste…> — fehlende Images dieser Dienste vorab laden (per Digest festgelegt: ein lokaler Treffer
# genuegt, wie bei rt_image_ensure; so scheitert ein Update nicht an einer Registry-Stoerung fuer Vorhandenes). Vor dem Stopp
# von n8n gerufen, damit ein Netz- oder Platzfehler das Update abbricht, solange nichts steht; `up` laedt sonst erst danach.
# Die aufgeloeste Konfiguration traegt das Superuser-Passwort: sie geht nur in jq, nie in eine Ausgabe.
rt_stack_pull() {
  local s img missing=()
  for s in "$@"; do
    img="$(_rt_compose config --format json "$s" 2>/dev/null | jq -r --arg s "$s" '.services[$s].image // empty' 2>/dev/null || true)"
    if [ -z "$img" ] || ! docker image inspect "$img" >/dev/null 2>&1; then missing+=("$s"); fi
  done
  [ "${#missing[@]}" -gt 0 ] || return 0
  _rt_compose pull "${missing[@]}" >&2
}
# rt_host_port_free <port> — ist der Port auf dem Rechner frei (FritzBox-Weg: 80/443)? Probe mit einem Kurzlauf-Container,
# der nur den Port belegt und sofort endet: Docker Desktop bindet den Host-Port beim Start und scheitert, wenn ein anderes
# Programm (auch ausserhalb von Docker) ihn haelt. Ein Port-Scan aus dem Container saehe den Rechner nicht.
rt_host_port_free() {
  docker run --rm --name "${LA_PROJECT}-portprobe-$1" --label "${LA_LABEL}=${LA_PROJECT}" -p "$1:9" \
    "${LA_PROBE_IMAGE:?LA_PROBE_IMAGE nicht gesetzt}" true >/dev/null 2>&1
}
# rt_published_ports_json <image-teil> <container-port> -> eine JSON-Zeile [{"ip":"0.0.0.0","port":8010}, …]: veroeffentlichte
# Host-Ports laufender Container dieses Rechners (auch fremder, z. B. Paperless fuer den Adress-Vorschlag im Wizard), deren
# Image <image-teil> enthaelt, fuer <container-port>/tcp. ip wie Docker sie meldet ("::" ohne Klammern), Paare einmalig;
# Port-Bereiche (8010-8011->…) zaehlen nicht. Ohne Docker oder bei einem Fehler: keine Ausgabe und rc 1 (der Aufrufer setzt
# dann [] ein, wizard/bridge.sh; ein eigenes [] ergaebe dort zwei JSON-Werte). Nur lesend; `ps --format` mit festem
# JSON-Objekt liefert keine Kennungen, die ein zweiter Befehl weiterverarbeiten koennte (Positivliste).
rt_published_ports_json() {
  local rows
  rows="$(docker ps --format '{"image":{{json .Image}},"ports":{{json .Ports}}}' 2>/dev/null)" || return 1
  # shellcheck disable=SC2016  # $img/$cp sind jq-Variablen
  jq -sc --arg img "$1" --arg cp "$2" '[ .[] | select((.image // "") | contains($img)) | (.ports // "") | split(", ")[]
      | capture("^(?<ip>.*):(?<port>[0-9]+)->(?<cp>[0-9]+)/tcp$") | select(.cp == $cp)
      | {ip: (.ip | ltrimstr("[") | rtrimstr("]")), port: (.port | tonumber)} ] | unique' <<<"$rows" 2>/dev/null || return 1
}
# rt_stack_up <dienste…> — Dienste des Verbunds starten (Abhaengigkeiten laut compose.yml, z. B. master -> gesunde DB).
# Bis zu 3 Versuche: ein Netz-Aussetzer oder das Mengenlimit der Image-Registry beim Holen der Images (toomanyrequests)
# soll weder einen Installer-Lauf noch die CI kippen; `up -d` ist wiederholbar (macht dort weiter, wo es stand).
rt_stack_up() {
  local n=1
  until _rt_compose up -d "$@"; do
    [ "$n" -lt 3 ] || return 1
    warn "Verbund starten gescheitert (Versuch $n/3) - neuer Versuch in ${RT_UP_RETRY_DELAY:-10} s."
    sleep "${RT_UP_RETRY_DELAY:-10}"; n=$((n + 1))
  done
}
# rt_stack_up_wait <dienste…> — Dienste starten und erst zurueckkehren, wenn sie laufen bzw. gesund sind (`--wait`, Postgres
# hat einen Healthcheck). Ein Versuch: der Kern laedt die Abbilder vorher (rt_stack_pull), eine abgelaufene Wartezeit ist
# ein kranker Dienst, kein Netz-Aussetzer. Nur fuer die Start-Dienste des Kerns: tailscale/wan (reach.sh) enden ohne
# Anmeldung bzw. Adresse von selbst, ein --wait schluege dort fehl.
rt_stack_up_wait() { _rt_compose up -d --wait --wait-timeout "${RT_UP_WAIT_SECS:-180}" "$@"; }
# rt_stack_ps — Zustand der laufenden eigenen Container (nur dieses Projekt; Name, Dienst, Status).
rt_stack_ps() { _rt_compose ps --format '{{.Name}}\t{{.Service}}\t{{.State}}\t{{.Health}}'; }
# rt_master_container -> Name des master-Containers (Host-Seite: Start-App bzw. CI).
rt_master_container() { printf '%s-master' "$LA_PROJECT"; }
# rt_master_write <ziel> — stdin als Datei (0600, root) in den master schreiben (Antwort-Datei; nie ueber argv, nie in
# /shared — das sieht auch n8n).
rt_master_write() {
  # shellcheck disable=SC2016  # $1 wird erst in der Container-Shell ausgewertet
  docker exec -i "$(rt_master_container)" sh -c 'umask 077; mkdir -p "$(dirname "$1")"; cat > "$1"' _ "$1"
}
# rt_master_exec <befehl…> — im master ausfuehren (ohne stdin, s. pg_su_exec).
rt_master_exec() { docker exec "$(rt_master_container)" "$@"; }
# rt_master_exec_env <name…> -- <befehl…> — wie rt_master_exec, dazu je Name `-e NAME`: den Wert liest Docker selbst aus der
#   Umgebung dieses Prozesses, er steht also nie in einer Befehlszeile. Welche Namen, entscheidet der Aufrufer (Kern:
#   SC_TEST_SWITCHES in lib/stack_core.sh).
rt_master_exec_env() {
  local e=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do e+=(-e "$1"); shift; done
  [ "${1:-}" = -- ] && shift
  docker exec "${e[@]}" "$(rt_master_container)" "$@"
}

# --- Kern (lib/stack_core.sh): Kurzlauf aus dem master-Abbild, der den Verbund anlegt, prueft und entfernt -------------
# Fester Name = Sperre gegen einen zweiten Kern (Docker lehnt den Namen ab, bevor etwas geschieht); die Weitergabe an das
# Abbild der Installation laeuft als <projekt>-core-next.
rt_core_container() { printf '%s-core%s' "$LA_PROJECT" "${LA_CORE_DELEGATED:+-next}"; }
# rt_core_changing — laeuft ein Kern dieses Projekts (auch eine Weitergabe) mit einem aendernden Verb? Gegensperre des
#   master-Wechsels; ein nur lesender (status, check, wizard-url, den eine Start-App regelmaessig ruft) haelt kein Update auf.
rt_core_changing() {
  local c
  for c in "${LA_PROJECT}-core" "${LA_PROJECT}-core-next"; do
    rt_container_running "$c" || continue
    case " $(docker inspect -f '{{join .Args " "}}' "$c" 2>/dev/null) " in *" up "*|*" start "*|*" install "*|*" uninstall "*) return 0 ;; esac
  done
  return 1
}
# rt_self_image -> das Abbild, aus dem dieser Prozess laeuft, in der Schreibweise des Aufrufs (Release-Pin
#   <register>/master@sha256:…): im Kern aus dem eigenen Container, im master aus seiner Umgebung. Eine andere
#   Schreibweise als LA_MASTER_IMAGE liesse Compose den master neu anlegen.
rt_self_image() {
  if [ "${LA_CORE:-}" = 1 ]; then docker inspect -f '{{.Config.Image}}' "$(rt_core_container)" 2>/dev/null
  else [ -n "${LA_MASTER_IMAGE:-}" ] && printf '%s\n' "$LA_MASTER_IMAGE"; fi
}
# rt_image_has_core <abbild> — traegt das Abbild das Kern-Etikett (master.Dockerfile, Stand ab dem Kern)?
rt_image_has_core() { [ "$(docker image inspect -f '{{index .Config.Labels "io.lifeagents.core"}}' "$1" 2>/dev/null)" = 1 ]; }
# rt_image_present <abbild> — liegt das Abbild lokal vor?
rt_image_present() { docker image inspect "$1" >/dev/null 2>&1; }
# rt_core_delegate <abbild> <verb> [args…] — denselben Aufruf im Abbild der Installation fahren (stdin, stdout, stderr und
#   Exit durchgereicht). LA_CORE_DELEGATED verhindert eine zweite Weitergabe; Werte gehen nie ueber die Umgebung mit.
#   Gesetzte Test-Weichen (SC_TEST_SWITCHES, lib/stack_core.sh) gehen als Name mit; der innere Kern prueft sie selbst.
rt_core_delegate() {
  local img="$1" k sw=(); shift
  for k in ${SC_TEST_SWITCHES:-}; do [ -z "${!k:-}" ] || sw+=(--env "$k"); done
  docker run --rm -i --name "${LA_PROJECT}-core-next" --label "${LA_LABEL}=${LA_PROJECT}" \
    --env LA_CORE=1 --env "LA_PROJECT=${LA_PROJECT}" --env "LA_CORE_DELEGATED=${LA_CORE_SELF_IMAGE:?}" --env LA_CORE_PORTS "${sw[@]}" \
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock "$img" stack "$@"
}
# rt_docker_server <Version|Os> -> Feld des Docker-Daemons (nicht des Clients).
rt_docker_server() {
  case "$1" in
    Version) docker version --format '{{.Server.Version}}' 2>/dev/null ;;
    Os)      docker version --format '{{.Server.Os}}' 2>/dev/null ;;
    *) return 2 ;;
  esac
}
# rt_docker_mem -> Arbeitsspeicher, den Docker sieht, in Byte (Docker Desktop: der der VM).
rt_docker_mem() { docker info --format '{{.MemTotal}}' 2>/dev/null; }
# rt_container_env <container> -> Umgebung des Containers, eine KEY=wert-Zeile je Eintrag. Beim master steht darin das
#   Superuser-Passwort: die Ausgabe geht nur in die Werte-Datei des Kerns, nie in eine Meldung.
rt_container_env() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null; }
# rt_volume_label <name> -> unser Label am Volume (leer = fremd); rc 1 = es gibt das Volume nicht, rc 2 = Docker-Fehler
#   (nicht „fehlt“: der Kern legte sonst neue Werte ueber vorhandene Daten an).
#   Warnungen der CLI auf stderr gehoeren nicht zum Label; den Grund eines Fehlers liest erst ein zweiter Aufruf.
rt_volume_label() {
  local out err
  if out="$(docker volume inspect -f "{{index .Labels \"${LA_LABEL}\"}}" "$1" 2>/dev/null)"; then printf '%s\n' "$out"; return 0; fi
  err="$(docker volume inspect -f '{{.Name}}' "$1" 2>&1 >/dev/null || true)"
  case "$err" in *[Nn]o\ such\ volume*) return 1 ;; *) return 2 ;; esac
}
# rt_vol_own <kurzname> — gibt es <projekt>_<kurzname> mit unserem Label? Vorher pruefen: ein --mount auf ein fehlendes
#   Volume legte es still ohne Label an, und rt_volumes_ensure braeche danach ab. rc 1 = fehlt oder fremd, 2 = Docker-Fehler.
rt_vol_own() {
  local l rc=0
  l="$(rt_volume_label "${LA_PROJECT}_$1")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ "$l" = "$LA_PROJECT" ]
}
# rt_vol_get <kurzname> <datei> -> Inhalt einer Datei im eigenen Volume (Kurzlauf aus LA_PROBE_IMAGE, ohne Netz, nur lesend
#   gemountet; im Kern ist das das eigene Abbild, lib/stack_core.sh sc_init).
#   rc 1 = Volume oder Datei fehlt, rc 2 = Lesen gescheitert (Container lief nicht, Abbild fehlt ohne Netz, …). Der Kern
#   wertet rc 2 nie als „fehlt“: sonst erzeugte er ein neues Passwort ueber einer Datenbank mit altem.
# shellcheck disable=SC2016  # $1 wird erst in der Container-Shell ausgewertet
rt_vol_get() {
  local rc=0
  rt_vol_own "$1" || return "$?"
  _rt_host_run "type=volume,src=${LA_PROJECT}_$1,dst=/$1,readonly" sh -c '[ -e "$1" ] || exit 3; cat "$1"' _ "/$1/$2" 2>/dev/null || rc=$?
  case "$rc" in 0) return 0 ;; 3) return 1 ;; *) return 2 ;; esac
}
# rt_vol_put <kurzname> <datei> — stdin als Datei (0600 root) ins eigene Volume: erst .part, dann umbenannt.
# shellcheck disable=SC2016  # $1 wird erst in der Container-Shell ausgewertet
rt_vol_put() {
  rt_vol_own "$1" || return 1
  _rt_host_run -i "type=volume,src=${LA_PROJECT}_$1,dst=/$1" \
    sh -c 'umask 077; mkdir -p "$(dirname "$1")" && cat > "$1.part" && mv -f "$1.part" "$1"' _ "/$1/$2"
}
# rt_probe_run <mount-angabe> <befehl…> — Kurzlauf-Container der Faehigkeits-Pruefung (wie _rt_host_run).
rt_probe_run() { _rt_host_run "$@"; }
# rt_probe_df -> `df -Pk /` aus einem Kurzlauf-Container (die Platte, auf der Docker seine Abbilder und Volumes ablegt).
rt_probe_df() { docker run --rm --label "${LA_LABEL}=${LA_PROJECT}" --network none "${LA_PROBE_IMAGE:?LA_PROBE_IMAGE nicht gesetzt}" df -Pk /; }
# rt_probe_socket <abbild> — erreicht ein Container mit eingehaengtem Socket den Daemon (der master braucht genau das)?
rt_probe_socket() {
  docker run --rm --label "${LA_LABEL}=${LA_PROJECT}" --network none \
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock --entrypoint docker "$1" version >/dev/null 2>&1
}
# rt_volume_create_own <name> — ein Volume mit unserem Label anlegen (Pruef-Volume des Kerns).
rt_volume_create_own() { docker volume create --label "${LA_LABEL}=${LA_PROJECT}" "$1" >/dev/null; }
# _rt_all_profiles -> alle Profile der compose.yml, mit Komma (fuer COMPOSE_PROFILES: Profil-Dienste zaehlen sonst nicht).
_rt_all_profiles() { _rt_compose config --profiles | paste -sd, -; }
# rt_stack_images -> "<dienst> <abbild>" je Dienst aller Profile. Die aufgeloeste Fassung traegt das Superuser-Passwort:
#   sie geht nur in jq, nie in eine Ausgabe.
rt_stack_images() {
  local profiles
  profiles="$(_rt_all_profiles)" || return 1
  COMPOSE_PROFILES="$profiles" _rt_compose config --format json 2>/dev/null \
    | jq -r '.services // {} | to_entries[] | select(.value.image) | "\(.key) \(.value.image)"' 2>/dev/null
}
# rt_stack_services -> "<dienst> <container>" je Dienst aller Profile (Namen laut compose.yml, nur lesend).
rt_stack_services() {
  local profiles
  profiles="$(_rt_all_profiles)" || return 1
  COMPOSE_PROFILES="$profiles" _rt_compose config --format json 2>/dev/null \
    | jq -r '.services // {} | to_entries[] | "\(.key) \(.value.container_name // "")"' 2>/dev/null
}
# rt_stack_start <dienste…> — vorhandene Container dieser Dienste starten (legt nie etwas an; Profil-Dienste eingeschlossen).
rt_stack_start() {
  local profiles
  profiles="$(_rt_all_profiles)" || return 1
  COMPOSE_PROFILES="$profiles" _rt_compose start "$@" >&2
}
# rt_image_rm_own <abbild> — ein Abbild entfernen, das der Kern laut compose.yml selbst geladen hat (Auswahl: stack_core.sh).
#   Ohne -f: nutzt ein Container (auch ein fremder) das Abbild, lehnt Docker ab. rc 0 = entfernt oder nicht vorhanden.
rt_image_rm_own() {
  rt_image_present "$1" || return 0
  docker image rm "$1" >/dev/null 2>&1
}

# --- Laufzeit im Verbund: Image-Wechsel, Messung, Rechner-Ordner, Abbau -------------------------------------------------
# rt_container_image <container> -> das Image (Name@Digest wie in compose.yml), mit dem der Container angelegt wurde.
rt_container_image() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null; }
# rt_container_health <container> -> Zustand des Healthchecks (healthy|unhealthy|starting), leer ohne Healthcheck.
rt_container_health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null; }
# rt_container_running_known <container> — 0 = laeuft, 1 = laeuft nicht oder gibt es nicht, 2 = Docker-Fehler (unbekannt).
#   Fuer Sperren: ein gestoertes Docker darf nicht wie „kein master“ aussehen.
rt_container_running_known() {
  local out
  if out="$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)"; then [ "$out" = true ] && return 0; return 1; fi
  out="$(docker inspect -f '{{.Id}}' "$1" 2>&1 >/dev/null || true)"
  case "$out" in *[Nn]o\ such\ *) return 1 ;; *) return 2 ;; esac
}
# rt_container_running <container> — 0 = laeuft.
rt_container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
# rt_container_up <container> — 0 = laeuft und steckt nicht in einer Neustart-Schleife (dort meldet Docker Running=true).
rt_container_up() { [ "$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' "$1" 2>/dev/null)" = 'true false' ]; }
# rt_master_image_of <compose-datei> -> das master-Image, das diese Datei selbst nennt (Release-Pin:
#   x-images.master `${LA_MASTER_IMAGE:-<register>/master@sha256:…}`, scripts/lib/release_images.ps1), also OHNE die Vorgabe aus der Umgebung. Leer = die Datei nennt
#   keins (neutrale Form `:?`). Die aufgeloeste Fassung enthaelt das Superuser-Passwort: sie geht nur in jq, nie in eine Ausgabe.
rt_master_image_of() {
  ( unset LA_MASTER_IMAGE; LA_COMPOSE_FILE="$1"; _rt_compose config --format json master 2>/dev/null ) \
    | jq -r '.services.master.image // empty' 2>/dev/null || true
}
# rt_image_ensure <compose-datei> <master-image> — das Image liegt lokal vor (sonst per Compose laden; nie `docker pull`
#   mit freiem Namen). Ein per Digest festgelegtes Image ist mit dem Inhalt identisch, der lokale Treffer genuegt.
rt_image_ensure() {
  docker image inspect "$2" >/dev/null 2>&1 && return 0
  # shellcheck disable=SC2030  # bewusst nur in der Teilschale: Ziel-Image fuer genau diesen Compose-Aufruf
  ( export LA_MASTER_IMAGE="$2"; LA_COMPOSE_FILE="$1"; _rt_compose pull master ) >&2
}
# rt_master_recreate <compose-datei> <master-image> — den master aus genau dieser Datei mit genau diesem Image anlegen
#   (`up --no-deps`: kein anderer Dienst wird angefasst). Nur aus dem Helfer rufen, nie aus dem master selbst.
# shellcheck disable=SC2030,SC2031  # bewusst nur in der Teilschale (s. rt_image_ensure)
rt_master_recreate() { ( export LA_MASTER_IMAGE="$2"; LA_COMPOSE_FILE="$1"; _rt_compose up -d --no-deps master ); }
# rt_master_selfcheck [sekunden] — laeuft der master und hat er alles, was der Installer braucht? 0 = ja.
rt_master_selfcheck() {
  local n="${1:-120}" _
  for _ in $(seq 1 "$n"); do
    if rt_container_running "$(rt_master_container)" \
       && docker exec "$(rt_master_container)" bash -c 'type jq node gpg >/dev/null 2>&1 && docker version >/dev/null 2>&1 && test -r /opt/lifeagents/provisioning/provision.sh && test "$LIFEAGENTS_RUNTIME" = compose' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}
# rt_swap_helper_start <image> <arbeitsordner> — den kurzlebigen Helfer fuer den master-Wechsel starten (der master
#   kann sich nicht selbst ersetzen). Aus dem alten, bewaehrten Image; sieht nur den Docker-Socket und var_la (dort liegen
#   Zustandsdatei, beide compose-Dateien und die Env-Datei). Fester Name: ein zweiter Wechsel waehrend eines laufenden
#   scheitert am Namen, bevor er etwas aendert.
rt_swap_helper_start() {
  docker run --rm -d --name "${LA_PROJECT}-swap" --label "${LA_LABEL}=${LA_PROJECT}" --network none \
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
    --mount "type=volume,src=${LA_PROJECT}_var_la,dst=/var/lib/lifeagents" \
    --env-file "$2/stack.env" --env LIFEAGENTS_RUNTIME=compose \
    --entrypoint bash "$1" /opt/lifeagents/provisioning/compose/swap_helper.sh "$2" >/dev/null
}
# rt_swap_helper_running — 0 = der Helfer laeuft noch.
rt_swap_helper_running() { rt_container_running "${LA_PROJECT}-swap"; }
# rt_netns <container> -> Kennung des Netz-Namensraums im Container (net:[…]); doctor vergleicht den Pod. /proc/self statt
#   /proc/1: der exec-Prozess teilt den Namensraum, und PID 1 eines anderen Nutzers (postgres) waere ohne ptrace nicht lesbar.
rt_netns() { docker exec "$1" readlink /proc/self/ns/net 2>/dev/null; }
# rt_probe_internal <port> — erreicht ein Kurzlauf-Container im internen Netz (dort, wo der Rand steht) anchor:<port>?
#   Die Messung von aussen: was der Rand sieht, sieht hier auch die Probe. 0 = erreichbar.
rt_probe_internal() {
  docker run --rm --label "${LA_LABEL}=${LA_PROJECT}" --network "${LA_PROJECT}_internal" \
    "${LA_PROBE_IMAGE:?LA_PROBE_IMAGE nicht gesetzt}" nc -z -w 2 anchor "$1" >/dev/null 2>&1
}
# _rt_host_run [-i] <mount-angabe> <befehl…> — ein Kurzlauf-Container fuer einen Ordner auf dem Rechner (Sicherung:
#   nicht auf der Docker-Platte): LA_PROBE_IMAGE (im master busybox, im Kern das eigene Abbild: dort nur sh, cat, df,
#   mkdir, mv verwenden, kein nc), ohne Netz, genau dieser eine Bind-Mount, unser Label. Fehlt der Ordner, scheitert
#   der Mount (Docker legt ihn mit --mount nie still an). -i = stdin durchreichen.
_rt_host_run() {
  local i=()
  if [ "$1" = -i ]; then i=(-i); shift; fi
  docker run --rm "${i[@]}" --label "${LA_LABEL}=${LA_PROJECT}" --network none --mount "$1" \
    "${LA_PROBE_IMAGE:?LA_PROBE_IMAGE nicht gesetzt}" "${@:2}"
}
# rt_host_put <rechner-ordner> <dateiname> <lokale-datei> — die Datei dorthin schreiben: erst .part, umbenannt nur bei
#   gleicher SHA-256. Endet der docker-Client mitten im Hochladen (Zeitgrenze, Neuanlage des master), schliesst Docker die
#   Eingabe des Helfers und `cat` endet ohne Fehler -> ohne Pruefung bekaeme die halbe Datei den gueltigen Namen und zaehlte
#   beim Aufraeumen als Sicherung. rc 1 = nicht vollstaendig angekommen (.part ist dann weg).
# shellcheck disable=SC2016  # $1/$2 werden erst in der Container-Shell ausgewertet
rt_host_put() {
  local sum
  sum="$(sha256sum < "$3" | cut -d' ' -f1)" && [ -n "$sum" ] || return 1
  _rt_host_run -i "type=bind,src=$1,dst=/out" sh -c 'umask 077; p="/out/.$1.part"; if cat > "$p" && [ "$(sha256sum < "$p" | cut -d" " -f1)" = "$2" ]; then mv -f "$p" "/out/$1"; else rm -f "$p"; exit 1; fi' \
    _ "$2" "$sum" < "$3"
}
# rt_host_get <rechner-ordner> <dateiname> — eine Datei von dort nach stdout (nur lesend gemountet).
rt_host_get() { _rt_host_run "type=bind,src=$1,dst=/in,readonly" cat "/in/$2"; }
# rt_host_ls <rechner-ordner> -> Dateinamen der Sicherungen (*.nla.enc) im Ordner, eine je Zeile.
# shellcheck disable=SC2016
rt_host_ls() { _rt_host_run "type=bind,src=$1,dst=/in,readonly" sh -c 'cd /in && for f in *.nla.enc; do [ -f "$f" ] && echo "$f"; done; true'; }
# rt_host_check <rechner-ordner> — gibt es den Ordner und ist er beschreibbar? (Probe anlegen + loeschen)
# shellcheck disable=SC2016  # $$/$p werden erst in der Container-Shell ausgewertet
rt_host_check() { _rt_host_run "type=bind,src=$1,dst=/out" sh -c 'p=/out/.lifeagents-probe.$$; : > "$p" && rm -f "$p"' >/dev/null 2>&1; }
# rt_master_cli_hint [tty] -> Befehlsanfang, mit dem man auf dem Rechner die CLI im master aufruft (fuer Meldungen mit Beispiel).
#   tty = fuer Befehle mit Rueckfrage (rollback, reconfigure): mit nur -i bricht rollback ab ("braucht ein Terminal") und
#   reconfigure zeigt nur die Hilfe (im echten Verbund belegt); update/doctor/backup lesen hoechstens stdin -> -i.
rt_master_cli_hint() {
  local f=-i; [ "${1:-}" = tty ] && f=-it
  printf 'docker exec %s %s-master lifeagents' "$f" "${LA_PROJECT:-lifeagents}"
}
# rt_cli_hint [tty] -> derselbe Befehlsanfang fuer beide Betriebsarten: Verbund wie oben, klassisch `sudo lifeagents` (die CLI
#   verlangt root). Die eine Adresse fuer Befehle in Meldungen an den Owner (Chat-Hilfe core.fn_update_report, Halt-Nachricht).
rt_cli_hint() { if rt_is_compose; then rt_master_cli_hint "${1:-}"; else printf 'sudo lifeagents'; fi; }
# rt_host_exists <rechner-ordner> — laesst Docker den Ordner einbinden? (fehlt er oder darf Docker nicht hinein, scheitert der
#   Mount; Docker Desktop unterscheidet beides nicht verlaesslich). rt_host_readable: zusaetzlich auflistbar (macOS-
#   Datenschutz kann den Mount erlauben und das Lesen verbieten).
rt_host_exists()   { _rt_host_run "type=bind,src=$1,dst=/in,readonly" true >/dev/null 2>&1; }
rt_host_readable() { _rt_host_run "type=bind,src=$1,dst=/in,readonly" ls -A /in >/dev/null 2>&1; }
# rt_host_mkdir <rechner-ordner> <name> — Unterordner <name> darin anlegen (vorhanden = ok); nur ein Name ohne Schraegstrich.
# shellcheck disable=SC2016  # $1 wird erst in der Container-Shell ausgewertet
rt_host_mkdir() {
  case "$2" in */*|''|.|..) return 1 ;; esac
  _rt_host_run "type=bind,src=$1,dst=/out" sh -c 'mkdir -p "/out/$1"' _ "$2" >/dev/null 2>&1
}
# rt_host_rm <rechner-ordner> <dateiname…> — genau diese Dateien dort loeschen (Auswahl: backup_cli.sh _bkp_rotate_victims;
#   nur Namen ohne Schraegstrich, sonst Abbruch vor dem Container).
# shellcheck disable=SC2016  # "$@" wird erst in der Container-Shell ausgewertet
rt_host_rm() {
  local f
  for f in "${@:2}"; do case "$f" in */*|''|.|..) return 1 ;; esac; done
  _rt_host_run "type=bind,src=$1,dst=/out" sh -c 'cd /out && for f in "$@"; do rm -f -- "$f"; done' _ "${@:2}"
}
# rt_stack_down — Container + Netze dieses Projekts entfernen (Deinstaller, Rechner-Seite). Ohne -v/--rmi: die externen
#   Volumes (Daten) und alle Images bleiben. Dienste aus Profilen (tailscale, wan) sind fuer Compose keine Waisen: `down`
#   erfasst sie nur, wenn ihr Profil aktiv ist -> alle Profile aus compose.yml aktivieren. --remove-orphans erfasst nur
#   Container mit unserem Compose-Projekt, nie fremde.
rt_stack_down() {
  local profiles
  profiles="$(_rt_all_profiles)" || return 1
  COMPOSE_PROFILES="$profiles" _rt_compose down --remove-orphans
}
# rt_volume_rm_own <name> — ein Volume entfernen, aber nur, wenn es unser Label traegt (fremdes gleichen Namens: Abbruch).
#   rc 0 = entfernt oder nicht vorhanden, 1 = fremdes Label (unberuehrt), 2 = Docker lehnte ab (Meldung nennt den Grund,
#   z. B. noch von einem Container belegt), 3 = liess sich nicht pruefen (Docker-Fehler, bleibt stehen).
rt_volume_rm_own() {
  local lbl err rc=0
  lbl="$(rt_volume_label "$1")" || rc=$?
  case "$rc" in 0) ;; 1) return 0 ;; *) warn "Volume $1 ließ sich nicht prüfen (Docker-Fehler) — bleibt stehen."; return 3 ;; esac
  [ "$lbl" = "$LA_PROJECT" ] || { warn "Volume $1 trägt nicht unser Label — bleibt unangetastet."; return 1; }
  err="$(docker volume rm "$1" 2>&1 >/dev/null)" || { warn "Volume $1 ließ sich nicht entfernen: ${err:-Docker nannte keinen Grund}"; return 2; }
}
# --- Rand (lib/reach.sh): edge, tailscale, wan --------------------------------------------------------------------------
# Feste Dienstliste ausserhalb des Pods, Container <projekt>-<dienst>; jeder andere Name = rc 2 (nie ein fremder Container).
_rt_edge_container() { case "$1" in edge|tailscale|wan) printf '%s-%s' "$LA_PROJECT" "$1" ;; *) return 2 ;; esac; }
# rt_edge_active <dienst> — 0 = Container laeuft.
rt_edge_active() {
  local c; c="$(_rt_edge_container "$1")" || return 2
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]
}
# rt_edge_restart <dienst> — Container neu starten (wan liest seine Adresse beim Start; Tailscale verwirft einen wartenden Anmelde-Link, neu anstossen: reach_login_start).
#   `docker restart` statt `compose restart`: tailscale/wan haengen an Profilen, die der Aufruf sonst erst aktivieren muesste.
rt_edge_restart() {
  local c; c="$(_rt_edge_container "$1")" || return 2
  docker restart "$c" >/dev/null
}
# rt_edge_exec <dienst> <befehl…> — im Rand-Container ausfuehren (ohne stdin, s. pg_su_exec), z. B. `tailscale status`.
rt_edge_exec() {
  local c; c="$(_rt_edge_container "$1")" || return 2
  shift
  docker exec "$c" "$@"
}
# rt_edge_exec_in <dienst> <befehl…> — wie rt_edge_exec, aber mit stdin (`-i`): fuer Geheimnisse, die nie ins argv duerfen.
rt_edge_exec_in() {
  local c; c="$(_rt_edge_container "$1")" || return 2
  shift
  docker exec -i "$c" "$@"
}
# rt_edge_exec_detached <dienst> <befehl…> — losgeloest im Rand-Container starten (`-d`, kehrt sofort zurueck), fuer einen
#   Befehl, der dort weiterlaufen muss (reach_login_start: `tailscale up` wartet auf die Anmeldung).
rt_edge_exec_detached() {
  local c; c="$(_rt_edge_container "$1")" || return 2
  shift
  docker exec -d "$c" "$@"
}
# rt_edge_logs_hint <dienst> -> Diagnose-Befehl als Text (wird nicht ausgefuehrt).
rt_edge_logs_hint() { printf 'docker logs --tail 100 %s-%s' "$LA_PROJECT" "$1"; }
# rt_probe_host <adresse> <port> — antwortet <adresse>:<port> einem Kurzlauf-Container im Netz edge_public (dort haengt wan)?
#   Misst den Weg ueber den Rechner (veroeffentlichter Port), nicht den Namensraum des Rands.
#   rc 0 = erreichbar, 1 = Port antwortet nicht, 2 = die Probe selbst lief nicht (docker-Fehler 125-127: Image fehlt,
#   Daemon, Netz) — nie als "antwortet nicht" werten.
rt_probe_host() {
  local rc=0
  docker run --rm --label "${LA_LABEL}=${LA_PROJECT}" --network "${LA_PROJECT}_edge_public" \
    "${LA_PROBE_IMAGE:?LA_PROBE_IMAGE nicht gesetzt}" nc -z -w 3 "$1" "$2" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) return 0 ;; 125|126|127) return 2 ;; *) return 1 ;; esac
}
# rt_edge_settle <dienst> [sekunden] — der Rand-Container laeuft, startet nicht gerade neu und ist mindestens 2 s oben
#   (wan hat keinen Healthcheck; Caddy bindet den Port binnen einer Sekunde). 0 = ruhig, 1 = nicht innerhalb der Zeit.
rt_edge_settle() {
  local c n="${2:-10}" _ row up started now
  c="$(_rt_edge_container "$1")" || return 2
  for _ in $(seq 1 "$n"); do
    row="$(docker inspect -f '{{.State.Running}} {{.State.Restarting}} {{.State.StartedAt}}' "$c" 2>/dev/null || true)"
    if [ "${row%% *}" = true ]; then
      up="${row#* }"; started="${up#* }"; now="$(date +%s)"
      started="$(date -d "$started" +%s 2>/dev/null || echo 0)"
      [ "${up%% *}" = false ] && [ $((now - started)) -ge 2 ] && return 0
    fi
    sleep 1
  done
  return 1
}
# rt_host_gateway -> Adresse des Rechners aus Sicht von edge_public (Gateway des Netzes laut Container wan), leer wenn unbekannt.
#   Ueber `docker inspect` des Containers: `docker network` steht nicht auf der Positivliste (contract_lint 32).
rt_host_gateway() {
  docker inspect -f "{{(index .NetworkSettings.Networks \"${LA_PROJECT}_edge_public\").Gateway}}" "${LA_PROJECT}-wan" 2>/dev/null \
    | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1
}

# --- Erneuern der Dienste ausserhalb des Installer-Schritts (Rand, Gateway) --------------------------------------------
# rt_container_id <container> -> Kennung (leer = es gibt ihn nicht).
rt_container_id() { docker inspect -f '{{.Id}}' "$1" 2>/dev/null; }
# rt_stack_refresh — edge, gateway und die laufenden Profil-Dienste (wan, tailscale) auf den Stand dieser compose.yml bringen:
#   `up -d --no-deps` legt nur neu an, was sich geaendert hat (z. B. ein neuer Pin nach einem Update), sonst no-op. Das Gateway
#   startet der Installer nur per `docker restart` neu (enable_start_unit), ein neuer Pin kaeme so nie an. anchor nie: seine
#   Neuanlage risse den Pod ab. tailscale haengt im Namensraum von edge; die Compose-Pruefsumme sieht nur `service:edge`, nicht
#   die Kennung -> nach einer Neuanlage von edge tailscale gezielt neu anlegen. rc 1 = mindestens ein Aufruf scheiterte.
rt_stack_refresh() {
  local before after ts=0 rc=0 svcs=(edge gateway)
  before="$(rt_container_id "${LA_PROJECT}-edge")"
  rt_container_running "${LA_PROJECT}-tailscale" && ts=1
  rt_container_running "${LA_PROJECT}-wan" && svcs+=(wan)
  _rt_compose up -d --no-deps "${svcs[@]}" >&2 || rc=1
  if [ "$ts" -eq 1 ]; then
    after="$(rt_container_id "${LA_PROJECT}-edge")"
    if [ -n "$before" ] && [ "$before" != "$after" ]; then
      _rt_compose up -d --no-deps --force-recreate tailscale >&2 || rc=1
    else
      _rt_compose up -d --no-deps tailscale >&2 || rc=1
    fi
  fi
  return "$rc"
}

# rt_target_precheck <compose-datei> <master-image> — was ein Update abbrechen kann, gegen die Datei des Ziel-Stands pruefen,
#   bevor der master gewechselt wird (lib/master_swap.sh; danach stuende der neue master auf dem alten Verbund):
#   PostgreSQL-Hauptversion des neuen Pins = die der Daten, Abbilder der Dienste ladbar (tailscale/wan nur, wenn sie laufen).
#   Abbruch per die_because pg_major|net, nichts geaendert. Unlesbarer Pin oder Datenstand = keine Aussage (wie upgrade_detect).
# shellcheck disable=SC2030,SC2031  # bewusst nur in der Teilschale: Ziel-Datei + Ziel-Image fuer genau diese Aufrufe
rt_target_precheck() {
  local cf="$1" img="$2" pin data svcs=(postgres n8n gateway edge)
  pin="$( ( export LA_MASTER_IMAGE="$img"; LA_COMPOSE_FILE="$cf"; _rt_compose config --format json postgres 2>/dev/null ) \
          | jq -r '.services.postgres.image // empty' 2>/dev/null | sed -nE 's#^.*/##; s/^[^:@]+:([0-9]+).*/\1/p')"
  data="$(pg_su_exec cat /var/lib/postgresql/data/PG_VERSION 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -n "$pin" ] && [ -n "$data" ] && [ "$pin" != "$data" ]; then
    die_because pg_major "Die Datenbank ist PostgreSQL ${data}, dieser Stand erwartet ${pin} — ein Wechsel der Hauptversion braucht eine Umwandlung der Daten; Update abgebrochen, es wurde nichts geändert."
  fi
  rt_container_running "${LA_PROJECT}-tailscale" && svcs+=(tailscale)
  rt_container_running "${LA_PROJECT}-wan" && svcs+=(wan)
  ( export LA_MASTER_IMAGE="$img"; LA_COMPOSE_FILE="$cf"; rt_stack_pull "${svcs[@]}" ) \
    || die_because net "Die neuen Images ließen sich nicht laden (Netz oder Platz?) — Update abgebrochen, es wurde nichts angehalten oder getauscht."
}

# rt_swap_helper_stop — den Helfer des master-Wechsels anhalten (fester Name, `--rm`: Anhalten entfernt ihn); nur fuer einen
#   haengenden Helfer (lib/master_swap.sh master_swap_resolve).
rt_swap_helper_stop() { docker stop "${LA_PROJECT}-swap" >/dev/null 2>&1; }

# rt_master_release_tag / rt_image_release_tag <abbild> — Release-Tag des laufenden master bzw. eines master-Abbilds (Ziel
#   eines Rueckwegs) auf stdout; Quelle von lifeagents_version_heal und release_tag_resolve. Zuerst RELEASE_TAG aus der
#   Umgebung des Abbilds (ENV ab v0.48.0; die Prozess-Umgebung taugt nicht, Aufrufer ueberschreiben RELEASE_TAG mit 'dev'),
#   sonst das Etikett org.opencontainers.image.version (Release-Bau, build_master_image.ps1). Nur vX.Y.Z oder ein Vorab-Tag
#   vX.Y.Z-<suffix> (common.sh is_prerelease_tag), sonst rc 1.
#   Klassisch rc 1: dort gibt es kein Abbild und keine andere verlaessliche Quelle.
_RT_REL_FMT='{{range .Config.Env}}{{println .}}{{end}}{{index .Config.Labels "org.opencontainers.image.version"}}'
_rt_release_tag_pick() {   # stdin = Ausgabe von _RT_REL_FMT
  local out env lab
  out="$(cat)"
  env="$(printf '%s\n' "$out" | sed -n 's/^RELEASE_TAG=//p' | head -n1)"
  lab="$(printf '%s\n' "$out" | tail -n1)"
  if is_release_tag "$env" || is_prerelease_tag "$env"; then printf '%s\n' "$env"
  elif is_release_tag "$lab" || is_prerelease_tag "$lab"; then printf '%s\n' "$lab"; else return 1; fi
}
rt_master_release_tag() {
  rt_is_compose || return 1
  local out
  out="$(docker inspect -f "$_RT_REL_FMT" "$(rt_master_container)" 2>/dev/null)" || return 1
  _rt_release_tag_pick <<<"$out"
}
rt_image_release_tag() {
  rt_is_compose || return 1
  local out
  out="$(docker image inspect -f "$_RT_REL_FMT" "$1" 2>/dev/null)" || return 1
  _rt_release_tag_pick <<<"$out"
}
