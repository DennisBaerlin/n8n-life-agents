# runtime.sh — Betriebsart des Installers: systemd (LXC/Debian, Standard) oder compose (Verbund aus Containern).
# GESOURCT von common.sh (kein Shebang, kein set -e). Diese Datei ist die EINZIGE Stelle, die weiss, WIE Postgres, n8n und
# die Dienste erreicht werden: rohe `runuser`/`systemctl`- und JEDE `docker`-Zeile stehen nur hier (contract_lint 32). Im
# systemd-Betrieb tun die Wrapper exakt das, was vorher inline stand; keine vorgetaeuschten Programme (kein Fake-systemctl).
#
# LIFEAGENTS_RUNTIME=compose (gesetzt im master-Container, provisioning/compose/compose.yml): Postgres, n8n und LLM-Gateway
# laufen als eigene Container in EINEM Netz-Namensraum (network_mode: service:anchor, Pod-Muster), der Installer im master.
# Alle 127.0.0.1-Annahmen (5432, 5678, 8090) bleiben wahr.
#
# DOCKER-POSITIVLISTE (contract_lint 32, gilt auch fuer die Start-App): erlaubt sind nur
#   docker exec · docker inspect · docker image inspect · docker version · docker volume inspect · docker volume create ·
#   docker run --rm · docker compose -p "$LA_PROJECT" <up|start|stop|restart|ps|config|pull|version>.
# Verboten sind breite Befehle (prune, --all/-a, ps -q, rm $(…), down -v/--volumes, --rmi, system …): unser master hat
# Zugriff auf GANZ Docker, ein Fehler hier traefe fremde Container (z. B. Paperless) — die wichtigste Regel des Verbunds.
# Alles, was wir anlegen, traegt den Projektnamen als Vorsatz und das Label io.lifeagents.install=<projekt>. Nur der
# Deinstaller (Start-App bzw. Paket 2, nach ausdruecklicher Rueckfrage, Pruefliste Nr. 17) darf zusaetzlich `compose down`
# (ohne -v), `volume rm <eigenes, gelabeltes Volume>` und `image rm <laut Journal selbst geladen>`.

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
# Rueckfrage). EINE Liste fuer rt_volumes_ensure und den Deinstaller (Paket 2).
LA_STATE_VOLUMES="pgdata n8n_home etc_n8n etc_la var_la rt_tree gw_state ts_state wizard_state"

# _rt_compose <args…> — docker compose mit FESTEM Projekt und fester Datei (nie das Projekt aus der Umgebung raten).
_rt_compose() { docker compose -p "$LA_PROJECT" -f "$LA_COMPOSE_FILE" "$@"; }

# --- Postgres als Superuser ---------------------------------------------------------------------------------------------
# pg_su_exec <programm> [args…] — ein Programm als Postgres-Superuser (systemd: runuser/Peer-Auth, compose: docker exec).
# compose: OHNE -i, stdin wird NICHT weitergereicht. `docker exec -i` liest stdin bis EOF — in einer
# `while read … done <<<"$liste"`-Schleife (provision.sh Paket-Loop) frass es den Rest der Liste (Probelauf-Fund 2).
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
# n8n_cli_env <env-datei> <n8n-args…> — n8n-CLI (import:workflow/credentials) mit geladener n8n.env, als n8n-Nutzer.
# compose: im n8n-Container; Eingabe-Dateien muessen dort unter demselben Pfad liegen (Volume `shared` = TMPDIR des
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
# n8n_image_tar <verzeichnis> — tar-Strom eines Verzeichnisses aus dem UNVERAENDERTEN n8n-Image (nur compose: die
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
  if rt_is_compose; then _rt_compose up -d --no-deps "$(svc_service "$1")" >&2
  else systemctl enable --now "$1" >/dev/null 2>&1 || systemctl enable --now "$1"; fi
}
# svc_start / svc_stop <unit…> — compose: nur die Units, die ein Dienst des Verbunds sind (Timer gibt es dort nicht).
svc_start() { if rt_is_compose; then _svc_compose_each start "$@"; else systemctl start "$@"; fi; }
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
# mit unserem Namen OHNE unser Label gehoert jemand anderem -> Abbruch, nie uebernehmen (Einwand 29). rc 0 = alle da.
rt_volumes_ensure() {
  local v name lbl
  for v in $LA_STATE_VOLUMES; do
    name="${LA_PROJECT}_${v}"
    if lbl="$(docker volume inspect -f "{{index .Labels \"${LA_LABEL}\"}}" "$name" 2>/dev/null)"; then
      [ "$lbl" = "$LA_PROJECT" ] || die "Volume ${name} existiert, gehört aber nicht zu dieser Installation (Label ${LA_LABEL} fehlt) — nichts geändert."
    else
      docker volume create --label "${LA_LABEL}=${LA_PROJECT}" "$name" >/dev/null || die "Volume ${name} ließ sich nicht anlegen."
    fi
  done
}
# rt_stack_config_check — Prueft die Compose-Datei samt Interpolation (Pruefliste Nr. 13), OHNE sie auszugeben: die
# aufgeloeste Fassung enthaelt das Superuser-Passwort (`config --quiet` = nur Fehlermeldungen).
rt_stack_config_check() { _rt_compose config --quiet; }
# rt_stack_dry_run <dienste…> — `up --dry-run`: zeigt, welche Container angelegt/geaendert wuerden (Pruefliste Nr. 13).
rt_stack_dry_run() { _rt_compose up --dry-run -d --no-deps "$@" 2>&1; }
# rt_host_port_free <port> — ist der Port auf dem Rechner frei (FritzBox-Weg: 80/443)? Probe mit einem Kurzlauf-Container,
# der nur den Port belegt und sofort endet: Docker Desktop bindet den Host-Port beim Start und scheitert, wenn ein anderes
# Programm (auch ausserhalb von Docker) ihn haelt. Ein Port-Scan aus dem Container saehe den Rechner nicht.
rt_host_port_free() {
  docker run --rm --name "${LA_PROJECT}-portprobe-$1" --label "${LA_LABEL}=${LA_PROJECT}" -p "$1:9" \
    "${LA_PROBE_IMAGE:?LA_PROBE_IMAGE nicht gesetzt}" true >/dev/null 2>&1
}
# rt_stack_up <dienste…> — Dienste des Verbunds starten (Abhaengigkeiten laut compose.yml, z. B. master -> gesunde DB).
rt_stack_up() { _rt_compose up -d "$@"; }
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

# --- Rand (Paket 3, lib/reach.sh): edge, tailscale, wan -----------------------------------------------------------------
# Feste Dienstliste ausserhalb des Pods, Container <projekt>-<dienst>; jeder andere Name = rc 2 (nie ein fremder Container).
_rt_edge_container() { case "$1" in edge|tailscale|wan) printf '%s-%s' "$LA_PROJECT" "$1" ;; *) return 2 ;; esac; }
# rt_edge_active <dienst> — 0 = Container laeuft.
rt_edge_active() {
  local c; c="$(_rt_edge_container "$1")" || return 2
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]
}
# rt_edge_restart <dienst> — Container neu starten (wan liest seine Adresse beim Start; Tailscale stellt neu einen Link aus).
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
# rt_edge_logs_hint <dienst> -> Diagnose-Befehl als Text (wird nicht ausgefuehrt).
rt_edge_logs_hint() { printf 'docker logs --tail 100 %s-%s' "$LA_PROJECT" "$1"; }
