# stack_core.sh — Kern des Docker-Verbunds: legt den Verbund an, prueft, startet und entfernt ihn. Laeuft als Kurzlauf aus
# dem master-Abbild (`docker run --rm … <master> stack <verb>`, Aufruf-Form: compose/stack.sh); jeder Einstieg (Start-App,
# setup.sh, CI) ruft nur das, keiner traegt eine eigene Start-Logik. Gesourct von compose/stack.sh (kein set -e hier).
# Docker nur ueber lib/runtime.sh (Positivliste).
# shellcheck disable=SC2031  # SV[LA_*] sind Schluessel der Werte-Liste; _sc_ro exportiert nur in seiner Subshell
#
# Vertrag (docs/reference/provisioning.md *Docker-Verbund*): mit --json nur JSON-Zeilen auf stdout, jede mit "v":1
# (Fortschritt {"type":"progress","step":…}, zuletzt genau ein {"type":"result","ok":…}); Text fuer Menschen auf stderr.
# Exit 0 = ok:true, 1 = ok:false, 2 = Aufruf falsch (dann kein JSON). Ein Feld umbenennen oder einen Grund aendern = "v":2.
#
# Geschlossene Liste der Gruende (die eine Adresse; Selbst-Assert in tests/mock_runtime/cases.sh Abschnitt SC):
SC_REASONS="docker_unreachable docker_windows_mode docker_too_old docker_capability docker_socket disk_low foreign_objects values_lost port_none_free busy legacy_installation newer_installation older_installation pull_failed start_failed db_unhealthy not_installed master_not_running install_failed in_master data_kept internal"
# Grenzen der Pruefung: Volume-Unterpfade gibt es ab Docker Engine 26.0 (Release Notes 26.0, moby/moby#45687); 10 GiB frei;
# unter 3,5 GiB Arbeitsspeicher nur eine Warnung. Ports: 5880–5899 auf 127.0.0.1; LA_CORE_PORTS=<von>-<bis> verschiebt die
# Spanne fuer Test-Verbuende neben einer echten Installation (eigener LA_PROJECT je Worktree, CI).
SC_DOCKER_MIN=26.0
SC_DISK_MIN_KB=10485760
SC_MEM_WARN=3758096384
SC_PORT_FIRST=5880
SC_PORT_LAST=5899
if [[ "${LA_CORE_PORTS:-}" =~ ^([0-9]{4,5})-([0-9]{4,5})$ ]] && [ "${BASH_REMATCH[1]}" -lt "${BASH_REMATCH[2]}" ]; then
  SC_PORT_FIRST="${BASH_REMATCH[1]}" SC_PORT_LAST="${BASH_REMATCH[2]}"
fi
# Gespeicherte Werte (Datei im Volume var_la, KEY=wert roh, 0600). LA_MASTER_IMAGE nie: das ist immer das eigene Abbild, ein
# gespeicherter Wert waere nach dem naechsten Update veraltet. LA_PROJECT kommt vom Aufrufer.
SC_VALUE_KEYS="LA_EDGE_PORT LA_WIZARD_PORT LA_PG_SUPERPW LA_TS_HOSTNAME"
SC_VALUES_FILE=stack.env
SC_FOREIGN_FILE='core-foreign-images'
SC_ANSWERS=/run/lifeagents-wizard/answers.env
SC_HINTS=/run/lifeagents-wizard/hints.env
SC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SC_JSON=0 SC_VERB='' SC_DONE=0 SC_SELF='' SC_LASTF=''
SC_ARGS=() SC_IMAGES=()
declare -A SV=()

# --- Ausgabe ------------------------------------------------------------------------------------------------------------
# err merkt sich zusaetzlich die letzte Meldung (auch aus Subshells und aus `die` bestehender Helfer): ohne Ergebnis wird
# sie zum detail des result mit reason internal (EXIT-Trap).
err() {
  printf '%s[x]%s %s\n' "${_C_RED:-}" "${_C_RST:-}" "$*" >&2
  [ -n "$SC_LASTF" ] && printf '%s\n' "$*" >> "$SC_LASTF" 2>/dev/null
  return 0
}
# JSON-Zeilen ueber SC_OUT = stdout beim Start (sc_main, eigener fd: 9 nutzt die Update-Sperre in common.sh): ein Trap
# laeuft mitten in einem Schritt mit `>&2`, dessen Umleitung dann noch gilt; ueber fd 1 landete das result auf stderr.
_sc_line() { if [ "$SC_JSON" = 1 ]; then printf '%s\n' "$1" >&"$SC_OUT"; fi; }
sc_step() {
  _sc_line "$(jq -cn --arg verb "$SC_VERB" --arg step "$1" '{v:1,type:"progress",verb:$verb,step:$step}')"
  log "stack ${SC_VERB}: ${1}"
}
_sc_result() {   # <ok true|false> <extra-json>
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  SC_DONE=1
  _sc_line "$(jq -cn --arg verb "$SC_VERB" --argjson ok "$1" --argjson x "$extra" --arg d "${LA_CORE_DELEGATED:-}" \
    '{v:1,type:"result",verb:$verb,ok:$ok} + $x + (if $d == "" then {} else {delegated_from:$d} end)')"
}
# sc_ok [extra-json] — Ergebnis ok:true, Exit 0.
sc_ok() { _sc_result true "${1:-}"; ok "stack ${SC_VERB}: fertig."; exit 0; }
# sc_fail <grund> <satz> [extra-json] — Ergebnis ok:false, Exit 1. Ein Grund ausserhalb der Liste wird internal.
sc_fail() {
  local r="$1" d="$2" x="${3:-}"
  case " $SC_REASONS " in *" $r "*) ;; *) d="Unbekannter Grund ${r}: ${d}"; r=internal ;; esac
  [ -n "$x" ] || x='{}'
  err "$d"
  _sc_result false "$(jq -cn --arg r "$r" --arg d "$d" --argjson x "$x" '$x + {reason:$r,detail:$d}')"
  exit 1
}
# _sc_fg <befehl…> — einen langen Schritt (compose up --wait, Weitergabe, provision.sh) so fahren, dass ein Signal ihn
#   unterbricht: bash fuehrt einen Trap erst nach dem laufenden Vordergrund-Befehl aus, `wait` dagegen kehrt sofort zurueck.
#   stdin ueber SC_IN: ein Hintergrund-Befehl bekaeme sonst /dev/null (Antwort-Datei, Weitergabe mit -i).
_sc_fg() {
  local rc=0
  "$@" <&"$SC_IN" &
  SC_CHILD=$!
  wait "$SC_CHILD" || rc=$?
  SC_CHILD=''
  return "$rc"
}
# _sc_kids <pid> — direkte Kinder, aus /proc gelesen statt mit pgrep: ohne procps (Test-Substrat) fand pgrep nichts, und das
#   Signal erreichte still keinen Nachfahren.
_sc_kids() {
  local f r
  for f in /proc/[0-9]*/stat; do
    read -r r 2>/dev/null < "$f" || continue
    r="${r##*) }"   # hinter dem Prozessnamen (der darf Leerzeichen und Klammern enthalten): "<zustand> <ppid> …"
    r="${r#* }"
    if [ "${r%% *}" = "$1" ]; then f="${f#/proc/}"; printf '%s\n' "${f%/stat}"; fi
  done
}
# _sc_kill_below <pid> — TERM an alle Nachfahren (der docker-Client kann Enkel sein, z. B. unter _sc_ro), nicht an <pid>.
_sc_kill_below() {
  local c
  for c in $(_sc_kids "$1"); do _sc_kill_below "$c"; kill -TERM "$c" 2>/dev/null || true; done
}
# _sc_on_signal <exit> <name> — TERM/INT. Der laufende lange Schritt ist eine Subshell (_sc_fg) mit dem docker-Client
#   darunter: das Signal geht an diesen Client. Was er ausserhalb dieses Containers angestossen hat, endet damit nicht von
#   selbst: `docker run` (Weitergabe) reicht TERM an den inneren Kern weiter, dessen result ist dann das eine result
#   (Wartezeit 8 s, unter der SIGKILL-Frist von docker stop: ein innerer Kern ohne Handler liefe sonst bis zum Ende);
#   `docker exec` (provision.sh im master) reicht nichts weiter, provision.sh laeuft dort zu Ende. Seine Antwort-Datei bleibt
#   darum liegen (tmpfs im master, 0700 root; dieselben Zugangsdaten legt die Installation in /etc/lifeagents ab).
_sc_on_signal() {
  local rc=0 _
  err "Abgebrochen (Signal ${2:-TERM})."
  if [ -n "${SC_CHILD:-}" ]; then
    _sc_kill_below "$SC_CHILD"
    if [ "${SC_DELEGATING:-0}" = 1 ]; then
      for _ in $(seq 1 80); do kill -0 "$SC_CHILD" 2>/dev/null || break; sleep 0.1; done
      if ! kill -0 "$SC_CHILD" 2>/dev/null; then
        wait "$SC_CHILD" || rc=$?
        SC_CHILD=''
        case "$rc" in 0|1) SC_DONE=1; exit "$rc" ;; esac
      fi
    fi
  fi
  exit "$1"
}
_sc_on_exit() {
  local rc=$? d=''
  if [ -n "${SC_CHILD:-}" ]; then _sc_kill_below "$SC_CHILD"; kill -TERM "$SC_CHILD" 2>/dev/null || true; fi
  if [ "$SC_DONE" != 1 ] && [ -n "$SC_VERB" ]; then
    d="$(tail -n1 "$SC_LASTF" 2>/dev/null || true)"
    [ -n "$d" ] || d="Abbruch ohne Meldung (Exit ${rc})."
    _sc_result false "$(jq -cn --arg d "$d" '{reason:"internal",detail:$d}')"
    rc=1
  fi
  rm -f "$SC_LASTF"
  exit "$rc"
}
_sc_usage() {
  printf 'Aufruf: stack check|up|start|status|wizard-url [--hints-stdin]|install [-- <provision.sh-Optionen>]|uninstall [--delete-data] [--json]\n' >&2
  exit 2
}

# --- Grundlagen ---------------------------------------------------------------------------------------------------------
# _sc_ro <befehl…> — nur lesender Compose-Aufruf (config/ps/down): fehlende Pflicht-Werte durch Platzhalter ersetzen, damit
# die Interpolation von compose.yml gelingt. Nie fuer `up`: der Platzhalter landete in der Container-Konfiguration.
# shellcheck disable=SC2030  # Platzhalter gelten bewusst nur in dieser Subshell
_sc_ro() {
  ( export LA_EDGE_PORT="${LA_EDGE_PORT:-1}" LA_WIZARD_PORT="${LA_WIZARD_PORT:-2}" LA_PG_SUPERPW="${LA_PG_SUPERPW:-unused}"
    "$@" )
}
_sc_ver_ge() {   # <version> <mindestens>: nur die Zahlen vor einem Suffix (26.1.0-rc1 -> 26.1.0)
  local v="${1%%[-+ ]*}"
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  [ "$(printf '%s\n%s\n' "$2" "$v" | sort -V | head -n1)" = "$2" ]
}
# sc_init — eigenes Abbild und die Abbild-Namen aus der eigenen compose.yml (nicht aus der Umgebung: die hat nur der master).
#   Alle Helfer-Container des Kerns (Volumes lesen/schreiben, Port-Probe, check) laufen aus dem eigenen Abbild, das schon
#   vorliegt: der Kern laedt so selbst nie etwas. busybox laedt nur Compose fuer den anchor und zaehlt damit als selbst
#   geladen (Merkliste); eine von einem Helfer geladene Kopie stuende sonst auf der Merkliste und bliebe nach --delete-data.
sc_init() {
  local svc img anchor=''
  SC_SELF="$(rt_self_image || true)"
  [ -n "$SC_SELF" ] || sc_fail internal "Eigenes Abbild unbekannt: der Kern laeuft nicht unter dem Namen $(rt_core_container)."
  export LA_CORE_SELF_IMAGE="$SC_SELF" LA_MASTER_IMAGE="$SC_SELF" LA_PROJECT
  SC_IMAGES=()
  LA_N8N_IMAGE=''
  while read -r svc img; do
    [ -n "$img" ] || continue
    case " ${SC_IMAGES[*]} " in *" $img "*) ;; *) SC_IMAGES+=("$img") ;; esac
    case "$svc" in anchor) anchor="$img" ;; n8n) LA_N8N_IMAGE="$img" ;; esac
  done <<<"$(_sc_ro rt_stack_images || true)"
  [ -n "$anchor" ] || sc_fail internal "compose.yml nennt kein Abbild fuer anchor."
  export LA_PROBE_IMAGE="$SC_SELF" LA_N8N_IMAGE
}
_sc_need_core() {
  [ "${LA_CORE:-}" = 1 ] || sc_fail in_master "stack ${SC_VERB} laeuft nur als eigener Kurzlauf-Container (docker run … stack ${SC_VERB}), nicht im master."
}
# _sc_vget <kurzname> <datei> — Datei aus einem eigenen Volume nach SC_VREAD. rc 0 = gelesen, 1 = fehlt. Ein Lesefehler
#   (rt_vol_get rc 2) bricht bei up/install ab, statt als „fehlt“ zu gelten (dort entstuenden neues Passwort, neue Ports,
#   eine ueberschriebene Werte-Datei); die anderen Verben schreiben keine Werte und werten ihn als leer.
_sc_vget() {
  local rc=0
  SC_VREAD="$(rt_vol_get "$1" "$2")" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) SC_VREAD=''; return 1 ;;
    *) SC_VREAD=''
       case "$SC_VERB" in up|install) ;; *) warn "Datei ${2} im Volume ${LA_PROJECT}_${1} nicht lesbar — gilt hier als leer."; return 1 ;; esac
       sc_fail internal "Die Datei ${2} im Volume ${LA_PROJECT}_${1} liess sich nicht lesen — nichts geaendert." ;;
  esac
}
# sc_lock — kein laufender master-Wechsel; sonst legte der Helfer den master gleich neu an. Gegenstueck: master_swap_begin
#   prueft den Kern nach dem Schreiben der Zustandsdatei ein zweites Mal (lib/master_swap.sh).
#   Ohne laufenden master (und ohne Helfer, oben) kann kein Wechsel weiterlaufen: eine offene oder unlesbare Zustandsdatei
#   zaehlt dann nicht (nur der Tick des master schliesst sie ab; sonst sperrte sie fuer immer, eine volle Platte auch den
#   Abbau). Laeuft der master: unlesbar = busy; Anlegen/Starten/Einrichten wartet immer; der Abbau nur, solange der Wechsel
#   arbeitet: handoff juenger als 5 Min (Frist von master_swap_resolve), swapping/swapped/applying (Sicherung, Migration im
#   neuen master) juenger als 60 Min; unbekanntes Alter oder unbekannte Phase = arbeitet. Danach, und nach rolled_back oder
#   rollback_failed, laesst sich ein kaputter master entfernen.
sc_lock() {
  local st rc=0 mr phase started t age=-1
  if rt_swap_helper_running; then sc_fail busy "Gerade laeuft ein Update (master-Wechsel) — danach erneut versuchen. Nichts geaendert."; fi
  st="$(rt_vol_get var_la master-swap/state)" || rc=$?
  [ "$rc" = 1 ] && return 0
  [ "$rc" = 0 ] && [ -z "$st" ] && return 0
  # „Kein master“ muss feststehen: ein gestoertes Docker (rc 2) zaehlt als „laeuft vielleicht“.
  mr=0; rt_container_running_known "$(rt_master_container)" || mr=$?
  if [ "$mr" = 1 ]; then
    warn "Ein master-Wechsel ist offen (oder sein Zustand unlesbar), aber kein master laeuft — der naechste master entscheidet nach seinem Abbild."
    return 0
  fi
  [ "$rc" = 0 ] || sc_fail busy "Der Zustand eines Updates liess sich nicht lesen — danach erneut versuchen. Nichts geaendert."
  [ -n "$st" ] || return 0
  if [ "$SC_VERB" = uninstall ]; then
    phase="$(sed -n 's/^PHASE=//p' <<<"$st" | head -n1)"
    started="$(sed -n 's/^STARTED=//p' <<<"$st" | head -n1)"
    if [ -n "$started" ] && t="$(date -d "$started" +%s 2>/dev/null)"; then age=$(( $(date +%s) - t )); fi
    case "$phase" in
      rolled_back|rollback_failed) warn "Ein master-Wechsel endete ${phase} — der Abbau geht trotzdem."; return 0 ;;
      handoff) if [ "$age" -ge 300 ]; then warn "Eine Uebergabe an den Helfer haengt seit ${age} s — der Abbau geht trotzdem."; return 0; fi ;;
      swapping|swapped|applying) if [ "$age" -ge 3600 ]; then warn "Ein master-Wechsel (${phase}) haengt seit ${age} s — der Abbau geht trotzdem."; return 0; fi ;;
    esac
  fi
  sc_fail busy "Ein master-Wechsel ist noch offen — er wird beim naechsten Tick abgeschlossen; danach erneut versuchen. Nichts geaendert."
}
# sc_delegate — laeuft die Installation mit einem anderen Abbild, macht deren eigener Kern die Arbeit (ein neuerer oder
#   aelterer Einstieg legt so nie einen Verbund mit fremden Pins an; Updates gehen nur ueber den signierten Weg im Chat).
#   Kehrt nur zurueck, wenn dieser Kern selbst weitermacht.
sc_delegate() {
  local m img rc=0 inst own="${RELEASE_TAG:-}"
  m="$(rt_master_container)"
  img="$(rt_container_image "$m" || true)"
  if [ -n "$img" ] && [ "$img" != "$SC_SELF" ]; then
    if rt_image_has_core "$img"; then
      [ -z "${LA_CORE_DELEGATED:-}" ] || sc_fail internal "Weitergabe: der master laeuft mit ${img}, nicht mit diesem Abbild."
      log "Die Installation laeuft mit ${img} — dessen Kern uebernimmt."
      SC_DELEGATING=1
      _sc_fg rt_core_delegate "$img" "${SC_ARGS[@]}" || rc=$?
      SC_DELEGATING=0
      # Der innere Kern endet nur mit 0/1 und hat dann sein result geschrieben; alles andere (Docker 125–127, Signal 137/143)
      # heisst: kein result -> dieser Kern schreibt eines.
      case "$rc" in
        0|1) SC_DONE=1; exit "$rc" ;;
        125|126|127) sc_fail internal "Weitergabe an ${img} lief nicht (Docker-Exit ${rc})." ;;
        *) sc_fail internal "Die Weitergabe an ${img} endete unerwartet (Exit ${rc})." ;;
      esac
    fi
    # Starten, Ansehen und Entfernen haengen nicht an den Pins dieses Abbilds; Anlegen und Einrichten schon.
    case "$SC_VERB" in
      start|status|wizard-url|uninstall) return 0 ;;
    esac
    sc_fail legacy_installation "Diese Installation stammt von vor dem Kern (${img}); zuerst im Chat aktualisieren. Nichts geaendert."
  fi
  if [ -z "$img" ]; then
    _sc_vget rt_tree VERSION || true
    inst="$(tr -d '[:space:]' <<<"$SC_VREAD")"
    # Ohne master liefen sonst die eigenen Pins ueber Daten einer anderen Fassung: neuere Daten verstuende dieses Programm
    # nicht, aeltere bekaemen neue Pins (z. B. eine neue Postgres-Hauptversion) ohne Sicherung vorher (upgrade_guard).
    if is_release_tag "$inst" && is_release_tag "$own" && [ "$inst" != "$own" ]; then
      case "$SC_VERB" in
        up|install)
          if [ "$(printf '%s\n%s\n' "$inst" "$own" | sort -V | tail -n1)" = "$inst" ]; then
            sc_fail newer_installation "Die Daten stammen von ${inst}, dieses Programm ist ${own} — ein neueres Programm verwenden. Nichts geaendert."
          fi
          sc_fail older_installation "Die Daten stammen von ${inst}, dieses Programm ist ${own} — zuerst mit ${inst} starten, dann im Chat aktualisieren. Nichts geaendert." ;;
      esac
    fi
  fi
  return 0
}

# --- Werte (Datei im Volume var_la) -------------------------------------------------------------------------------------
_sc_any_container() {
  local s
  for s in anchor postgres master edge; do [ -n "$(rt_container_id "${LA_PROJECT}-$s" || true)" ] && return 0; done
  return 1
}
# sc_values_read — gespeicherte Werte, fehlende aus der Umgebung eines vorhandenen master (Bestand der Start-App). Nur lesend.
sc_values_read() {
  local line k v m src
  SV=()
  _sc_vget var_la "$SC_VALUES_FILE" || true
  SC_VALUES_STORED="$SC_VREAD"
  m="$(rt_master_container)"
  src="$SC_VALUES_STORED"
  if [ -n "$(rt_container_id "$m" || true)" ]; then src="${src}"$'\n'"$(rt_container_env "$m" || true)"; fi
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    [ "$k" != "$line" ] && [ -n "$v" ] || continue
    case " $SC_VALUE_KEYS " in *" $k "*) [ -n "${SV[$k]:-}" ] || SV[$k]="$v" ;; esac
  done <<<"$src"
}
_sc_ts_draw() {
  jq -r --argjson a "$RANDOM" --argjson b "$RANDOM" '(.adjectives | .[$a % length]) + "-" + (.nouns | .[$b % length])' \
    "$SC_LIB_DIR/ts_names.json"
}
_sc_port_pick() {   # <anderer belegter Wert> -> freier Port der Spanne
  local p
  for p in $(seq "$SC_PORT_FIRST" "$SC_PORT_LAST"); do
    [ "$p" = "$1" ] && continue
    rt_host_port_free "$p" && { printf '%s' "$p"; return 0; }
  done
  return 1
}
# sc_values_complete — fehlende Werte bilden. Ein gespeicherter wird nie ueberschrieben; Ausnahme Ports (s. u.). Gibt es eine
#   Datenbank, aber nirgends ihr Passwort, bricht der Kern ab, statt sie mit einem neuen auszusperren.
sc_values_complete() {
  local k p
  if [ -z "${SV[LA_PG_SUPERPW]:-}" ]; then
    # Initialisiert = PG_VERSION liegt im Volume; ein leeres pgdata (erster Lauf vor dem Start abgebrochen) ist keine Datenbank.
    _sc_vget pgdata PG_VERSION || true
    if [ -n "$SC_VREAD" ]; then
      sc_fail values_lost "Die Datenbank ist da, ihr Passwort aber nirgends mehr gespeichert — ein neues Passwort sperrte die Daten aus. Nichts geaendert."
    fi
    SV[LA_PG_SUPERPW]="$(rand_hex 32)"
  fi
  if [ -z "${SV[LA_TS_HOSTNAME]:-}" ]; then
    # Gibt es den Tailscale-Knoten schon, traegt er seinen Namen; ein neu gezogener braeuchte eine neue Anmeldung.
    k=0; rt_volume_label "${LA_PROJECT}_ts_state" >/dev/null || k=$?
    case "$k" in
      0) SV[LA_TS_HOSTNAME]=bot ;;
      1) SV[LA_TS_HOSTNAME]="$(_sc_ts_draw)" ;;
      *) sc_fail internal "Volume ${LA_PROJECT}_ts_state liess sich nicht pruefen — nichts geaendert." ;;
    esac
  fi
  # Ports: gespeicherte bleiben. Ohne einen Container des Projekts wird ein inzwischen belegter neu gesucht; bei laufendem
  # Verbund nie (ein neuer Port legte edge und tailscale neu an, und belegt ist er dann von uns selbst).
  if ! _sc_any_container; then
    for k in LA_EDGE_PORT LA_WIZARD_PORT; do
      if [ -n "${SV[$k]:-}" ] && ! rt_host_port_free "${SV[$k]}"; then log "Port ${SV[$k]} ist belegt — suche einen anderen."; SV[$k]=''; fi
    done
  fi
  for k in LA_EDGE_PORT LA_WIZARD_PORT; do
    [ -n "${SV[$k]:-}" ] && continue
    if [ "$k" = LA_EDGE_PORT ]; then p="${SV[LA_WIZARD_PORT]:-}"; else p="${SV[LA_EDGE_PORT]:-}"; fi
    SV[$k]="$(_sc_port_pick "$p" || true)"
    [ -n "${SV[$k]}" ] || sc_fail port_none_free "Zwischen ${SC_PORT_FIRST} und ${SC_PORT_LAST} sind keine zwei Ports frei. Nichts geaendert."
  done
}
_sc_values_text() { local k; for k in $SC_VALUE_KEYS; do [ -n "${SV[$k]:-}" ] && printf '%s=%s\n' "$k" "${SV[$k]}"; done; return 0; }
sc_values_export() {
  local k
  for k in $SC_VALUE_KEYS; do [ -n "${SV[$k]:-}" ] && export "$k=${SV[$k]}"; done
  return 0
}
_sc_ports_json() {
  jq -cn --arg e "${SV[LA_EDGE_PORT]:-}" --arg w "${SV[LA_WIZARD_PORT]:-}" \
    '{edge: ($e | tonumber? // null), wizard: ($w | tonumber? // null)}'
}
_sc_present_images() { local i; for i in "${SC_IMAGES[@]}"; do [ "$i" != "$SC_SELF" ] && rt_image_present "$i" && printf '%s\n' "$i"; done; return 0; }

# --- Faehigkeits-Pruefung -----------------------------------------------------------------------------------------------
# _sc_probe_subpath — Verzeichnis-Unterpfad eines Volumes einhaengen (n8n-Korrekturen, compose.yml): Pruef-Volume mit unserem
#   Label, danach immer entfernt. rc 0 = geht, 1 = geht nicht, 2 = ein fremdes Volume traegt den Namen.
_sc_probe_subpath() {
  local vol="${LA_PROJECT}_probe" lbl rc=1
  if lbl="$(rt_volume_label "$vol")"; then
    [ "$lbl" = "$LA_PROJECT" ] || return 2
    rt_volume_rm_own "$vol" >/dev/null 2>&1 || true
  fi
  rt_volume_create_own "$vol" || return 1
  if rt_probe_run "type=volume,src=${vol},dst=/v" sh -c 'mkdir -p /v/sub && echo ok > /v/sub/f' >/dev/null 2>&1 \
     && [ "$(rt_probe_run "type=volume,src=${vol},dst=/r,volume-subpath=sub,readonly" cat /r/f 2>/dev/null)" = ok ]; then rc=0; fi
  rt_volume_rm_own "$vol" >/dev/null 2>&1 || true
  return "$rc"
}
# sc_checks — setzt SC_CHECKS (JSON-Liste), SC_WARNINGS (JSON-Liste) und SC_CHECK_REASON (erster rote Grund, leer = alles gut).
sc_checks() {
  local rows=() warns=() v avail mem sp=0
  SC_CHECK_REASON=''
  _sc_chk() {
    rows+=("$(jq -cn --arg id "$1" --arg r "${2:-}" 'if $r == "" then {id:$id,ok:true} else {id:$id,ok:false,reason:$r} end')")
    if [ -n "${2:-}" ] && [ -z "$SC_CHECK_REASON" ]; then SC_CHECK_REASON="$2"; fi
    return 0
  }
  if [ "$(rt_docker_server Os || true)" = linux ]; then _sc_chk linux; else _sc_chk linux docker_windows_mode; fi
  v="$(rt_docker_server Version || true)"
  if _sc_ver_ge "$v" "$SC_DOCKER_MIN"; then _sc_chk engine; else _sc_chk engine docker_too_old; fi
  _sc_probe_subpath || sp=$?
  case "$sp" in 0) _sc_chk subpath ;; 2) _sc_chk subpath foreign_objects ;; *) _sc_chk subpath docker_capability ;; esac
  if rt_probe_socket "$SC_SELF"; then _sc_chk socket; else _sc_chk socket docker_socket; fi
  avail="$(rt_probe_df 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  if [[ "$avail" =~ ^[0-9]+$ ]] && [ "$avail" -ge "$SC_DISK_MIN_KB" ]; then _sc_chk disk; else _sc_chk disk disk_low; fi
  mem="$(rt_docker_mem || true)"
  if [[ "$mem" =~ ^[0-9]+$ ]] && [ "$mem" -lt "$SC_MEM_WARN" ]; then warns+=(memory_low); fi
  SC_CHECKS="$(printf '%s\n' '{"id":"docker","ok":true}' "${rows[@]}" | jq -cs .)"
  SC_WARNINGS="$(printf '%s\n' "${warns[@]}" | jq -cR 'select(. != "")' | jq -cs .)"
}

# --- Verben -------------------------------------------------------------------------------------------------------------
sc_check() {
  if ! rt_docker_ok; then
    sc_fail docker_unreachable "Docker antwortet nicht." '{"checks":[{"id":"docker","ok":false,"reason":"docker_unreachable"}],"warnings":[]}'
  fi
  sc_init
  sc_checks
  local x; x="$(jq -cn --argjson c "$SC_CHECKS" --argjson w "$SC_WARNINGS" '{checks:$c,warnings:$w}')"
  [ -z "$SC_CHECK_REASON" ] || sc_fail "$SC_CHECK_REASON" "Docker auf diesem Rechner taugt nicht fuer den Assistenten (${SC_CHECK_REASON})." "$x"
  sc_ok "$x"
}

sc_up() {
  local first=0 foreign=() before=() pulled after_ids before_ids v lbl health x rc
  _sc_need_core
  rt_docker_ok || sc_fail docker_unreachable "Docker antwortet nicht."
  sc_init
  sc_step lock;     sc_lock
  sc_step delegate; sc_delegate
  # Merkliste fremder Abbilder nur beim allerersten Lauf (var_la fehlt noch): was schon lag, entfernt der Abbau nie.
  rc=0; rt_vol_own var_la || rc=$?
  case "$rc" in 0) ;; 1) first=1 ;; *) sc_fail internal "Volume ${LA_PROJECT}_var_la liess sich nicht pruefen — nichts geaendert." ;; esac
  mapfile -t before < <(_sc_present_images)
  if [ "$first" = 1 ]; then foreign=("${before[@]}"); fi
  sc_step check;    sc_checks
  [ -z "$SC_CHECK_REASON" ] || sc_fail "$SC_CHECK_REASON" "Docker auf diesem Rechner taugt nicht fuer den Assistenten (${SC_CHECK_REASON})." \
    "$(jq -cn --argjson c "$SC_CHECKS" '{checks:$c}')"
  sc_step values;   sc_values_read; sc_values_complete; sc_values_export
  sc_step volumes
  for v in $LA_STATE_VOLUMES; do
    rc=0; lbl="$(rt_volume_label "${LA_PROJECT}_${v}")" || rc=$?
    [ "$rc" -le 1 ] || sc_fail internal "Volume ${LA_PROJECT}_${v} liess sich nicht pruefen — nichts geaendert."
    if [ "$rc" = 0 ] && [ "$lbl" != "$LA_PROJECT" ]; then
      sc_fail foreign_objects "Volume ${LA_PROJECT}_${v} gehoert nicht zu dieser Installation. Nichts geaendert."
    fi
  done
  # var_la zuerst und die Werte hinein, erst danach die uebrigen (pgdata): bricht der Lauf dazwischen ab, fehlte sonst das
  # Passwort einer Datenbank, die es schon gibt.
  rt_vol_own var_la || rt_volume_create_own "${LA_PROJECT}_var_la" || sc_fail internal "Volume ${LA_PROJECT}_var_la liess sich nicht anlegen."
  if [ "$(_sc_values_text)" != "$SC_VALUES_STORED" ]; then
    _sc_values_text | rt_vol_put var_la "$SC_VALUES_FILE" || sc_fail internal "Die Werte liessen sich nicht im Volume ${LA_PROJECT}_var_la ablegen."
  fi
  if [ "$first" = 1 ]; then
    printf '%s\n' "${foreign[@]}" | rt_vol_put var_la "$SC_FOREIGN_FILE" || sc_fail internal "Die Merkliste vorhandener Abbilder liess sich nicht ablegen."
  fi
  rt_volumes_ensure
  rt_stack_config_check >&2 || sc_fail internal "compose.yml ungueltig oder ein Pflicht-Wert fehlt."
  sc_step start
  before_ids="$(for v in anchor postgres master edge; do rt_container_id "${LA_PROJECT}-$v" || true; done)"
  _sc_fg rt_stack_pull anchor postgres master edge >&2 || sc_fail pull_failed "Die Abbilder liessen sich nicht laden (Netz oder Platz?)."
  if ! _sc_fg rt_stack_up_wait anchor postgres master edge >&2; then
    health="$(rt_container_health "$LA_PG_CONTAINER" || true)"
    case "$health" in
      unhealthy|starting) sc_fail db_unhealthy "Die Datenbank wurde nicht gesund ($(svc_logs_hint postgresql))." ;;
    esac
    sc_fail start_failed "Der Verbund liess sich nicht starten (docker logs ${LA_PROJECT}-master)."
  fi
  rt_master_selfcheck 120 || sc_fail start_failed "Der master laeuft nicht oder ihm fehlt ein Werkzeug (docker logs ${LA_PROJECT}-master)."
  after_ids="$(for v in anchor postgres master edge; do rt_container_id "${LA_PROJECT}-$v" || true; done)"
  pulled="$(comm -13 <(printf '%s\n' "${before[@]}" | sort -u) <(_sc_present_images | sort -u) | jq -cR 'select(. != "")' | jq -cs .)"
  x="$(jq -cn --argjson ch "$([ "$before_ids" != "$after_ids" ] && echo true || echo false)" --argjson p "$pulled" \
    --argjson ports "$(_sc_ports_json)" --arg ver "${RELEASE_TAG:-}" '{changed:$ch,pulled:$p,ports:$ports,version:$ver}')"
  sc_step 'done'
  sc_ok "$x"
}

sc_start() {
  local svc c started=() todo=() rc
  _sc_need_core
  rt_docker_ok || sc_fail docker_unreachable "Docker antwortet nicht."
  sc_init
  sc_lock
  sc_delegate
  rc=0; rt_vol_own pgdata || rc=$?
  case "$rc" in 0) ;; 1) sc_fail not_installed "Auf diesem Rechner gibt es keine Installation." ;; *) sc_fail internal "Volume ${LA_PROJECT}_pgdata liess sich nicht pruefen." ;; esac
  sc_values_read; sc_values_export
  while read -r svc c; do
    [ -n "$c" ] || continue
    [ -n "$(rt_container_id "$c" || true)" ] || continue
    rt_container_running "$c" || todo+=("$svc")
  done <<<"$(_sc_ro rt_stack_services || true)"
  if [ "${#todo[@]}" -gt 0 ]; then
    _sc_ro rt_stack_start "${todo[@]}" || sc_fail start_failed "Die vorhandenen Container liessen sich nicht starten."
  fi
  for svc in "${todo[@]}"; do rt_container_running "${LA_PROJECT}-$svc" && started+=("$svc"); done
  sc_step 'done'
  sc_ok "$(printf '%s\n' "${started[@]}" | jq -cR 'select(. != "")' | jq -cs '{started:.}')"
}

sc_status() {
  local m installed=false running=false ver core=0 svcs phase='' upd=false x st rc
  rt_docker_ok || sc_fail docker_unreachable "Docker antwortet nicht."
  sc_init
  if [ "${LA_CORE:-}" = 1 ]; then sc_delegate; fi
  m="$(rt_master_container)"
  rc=0; rt_vol_own pgdata || rc=$?
  # Nicht pruefbar = installiert (sicherer Standard: die App bietet dann keine Neuinstallation an).
  case "$rc" in 0) installed=true ;; 1) ;; *) installed=true; warn "Volume ${LA_PROJECT}_pgdata liess sich nicht pruefen." ;; esac
  rt_container_running "$m" && running=true
  ver="$(rt_vol_get rt_tree VERSION | tr -d '[:space:]' || true)"
  if [ -n "$(rt_container_image "$m" || true)" ] && rt_image_has_core "$(rt_container_image "$m")"; then core=1; fi
  sc_values_read
  svcs="$(_sc_ro rt_stack_ps 2>/dev/null || true)"
  svcs="$(jq -cR 'split("\t") | select(length >= 3) | {name:.[1],state:.[2]} + (if (.[3] // "") == "" then {} else {health:.[3]} end)' <<<"$svcs" | jq -cs .)"
  if [ "$running" = true ]; then
    phase="$(rt_master_exec node /opt/lifeagents/provisioning/wizard/ctl.js status 2>/dev/null | jq -r '.phase // empty' 2>/dev/null || true)"
  fi
  # Zustand nicht lesbar = laeuft (die App startet dann nichts Aenderndes).
  st=''; rc=0; st="$(rt_vol_get var_la master-swap/state)" || rc=$?
  if rt_swap_helper_running || [ -n "$st" ] || [ "$rc" -ge 2 ]; then upd=true; fi
  x="$(jq -cn --argjson i "$installed" --argjson r "$running" --arg v "$ver" --argjson core "$core" \
    --argjson ports "$(_sc_ports_json)" --argjson s "$svcs" --arg ph "$phase" --argjson u "$upd" \
    '{installed:$i,running:$r,version:$v,core:$core,ports:$ports,services:$s,update_running:$u}
     + (if $ph == "" then {} else {wizard:{phase:$ph}} end)')"
  sc_step 'done'
  sc_ok "$x"
}

sc_wizard_url() {
  local out url
  rt_docker_ok || sc_fail docker_unreachable "Docker antwortet nicht."
  sc_init
  if [ "${LA_CORE:-}" = 1 ]; then sc_delegate; fi
  rt_container_running "$(rt_master_container)" || sc_fail master_not_running "Der Assistent laeuft gerade nicht."
  if [ "$SC_HINTS_STDIN" = 1 ]; then
    rt_master_write "$SC_HINTS" || sc_fail internal "Die Hinweise liessen sich nicht an den Fragebogen geben."
  fi
  out="$(rt_master_exec node /opt/lifeagents/provisioning/wizard/ctl.js url 2>/dev/null || true)"
  url="$(jq -r '.url // empty' <<<"$out" 2>/dev/null || true)"
  [[ "$url" =~ ^http://127\.0\.0\.1:[0-9]+/ ]] || sc_fail internal "Der Fragebogen gab keinen Link (laeuft der Wizard?)."
  sc_step 'done'
  sc_ok "$(jq -cn --arg u "$url" '{url:$u}')"
}

sc_install() {
  local rc=0
  _sc_need_core
  rt_docker_ok || sc_fail docker_unreachable "Docker antwortet nicht."
  sc_init
  sc_lock
  sc_delegate
  rt_container_running "$(rt_master_container)" || sc_fail master_not_running "Der master laeuft nicht — zuerst stack up."
  sc_step answers
  rt_master_write "$SC_ANSWERS" || sc_fail internal "Die Antwort-Datei liess sich nicht in den master legen."
  sc_step provision
  _sc_fg rt_master_exec bash /opt/lifeagents/provisioning/provision.sh --unattended "$SC_ANSWERS" "${SC_PROVISION_ARGS[@]}" >&2 || rc=$?
  rt_master_exec rm -f "$SC_ANSWERS" || true
  [ "$rc" -eq 0 ] || sc_fail install_failed "Die Einrichtung im master endete mit Exit ${rc}." "$(jq -cn --argjson n "$rc" '{provision_exit:$n}')"
  sc_step 'done'
  sc_ok '{"provision_exit":0}'
}

sc_uninstall() {
  local foreign_list='' have_list=0 v rc img n=0 fvol=0 dkept=0 kept=() rmv=() rmi=() imgs=()
  _sc_kept() { kept+=("$(jq -cn --arg w "$1" --arg r "$2" '{what:$w,reason:$r}')"); }
  _sc_need_core
  rt_docker_ok || sc_fail docker_unreachable "Docker antwortet nicht."
  sc_init
  sc_step lock; sc_lock
  sc_delegate
  sc_values_read; sc_values_export
  sc_step webhook
  if rt_container_running "$(rt_master_container)" && rt_master_exec test -x /usr/local/bin/lifeagents 2>/dev/null; then
    _sc_fg rt_master_exec lifeagents telegram release-webhook >&2 || _sc_kept telegram-webhook webhook_failed
  fi
  # Ohne Merkliste (Bestand der Start-App, var_la schon geloescht) ist unbekannt, was vorher auf dem Rechner lag: dann
  # entfernt der Abbau kein einziges Abbild — ein Nachbar koennte es nutzen, auch wenn gerade kein Container laeuft.
  if foreign_list="$(rt_vol_get var_la "$SC_FOREIGN_FILE")"; then have_list=1; fi
  sc_step containers
  for v in $(_sc_ro rt_stack_services | awk '{print $2}' || true); do
    if [ -n "$(rt_container_id "$v" || true)" ]; then n=$((n + 1)); fi
  done
  _sc_fg _sc_ro rt_stack_down >&2 || sc_fail internal "Container liessen sich nicht entfernen — Daten unberuehrt."
  sc_step volumes
  # Abgeleitete Volumes (keine Nutzerdaten) gehen immer; ein fremdes gleichen Namens bleibt unangetastet.
  for v in $LA_DERIVED_VOLUMES; do
    rc=0; rt_volume_rm_own "${LA_PROJECT}_${v}" || rc=$?
    case "$rc" in 2) _sc_kept "${LA_PROJECT}_${v}" volume_busy ;; 3) _sc_kept "${LA_PROJECT}_${v}" inspect_failed ;; esac
  done
  if [ "$SC_DELETE_DATA" = 1 ]; then
    for v in $LA_STATE_VOLUMES; do
      # Vorher nachsehen nur, um „gab es nicht“ (kein Eintrag) von „entfernt“ zu trennen; rt_volume_rm_own prueft selbst.
      rc=0; rt_volume_label "${LA_PROJECT}_${v}" >/dev/null || rc=$?
      [ "$rc" = 1 ] && continue
      rc=0; rt_volume_rm_own "${LA_PROJECT}_${v}" || rc=$?
      case "$rc" in
        0) rmv+=("${LA_PROJECT}_${v}") ;;
        1) fvol=1 ;;
        2) dkept=1; _sc_kept "${LA_PROJECT}_${v}" volume_busy ;;
        *) dkept=1; _sc_kept "${LA_PROJECT}_${v}" inspect_failed ;;
      esac
    done
    sc_step images
    # Alle Abbilder der compose.yml (auch die, die erst der master geladen hat), ausser denen, die vorher schon lagen. Das
    # eigene Abbild nutzt gerade dieser Kern: Docker lehnt es ab, es bleibt als image_in_use.
    imgs=()
    if [ "$have_list" = 1 ]; then imgs=("${SC_IMAGES[@]}"); else log "Keine Merkliste vorhandener Abbilder — alle Abbilder bleiben."; fi
    for img in "${imgs[@]}"; do
      grep -qxF -- "$img" <<<"$foreign_list" && continue
      rt_image_present "$img" || continue
      if rt_image_rm_own "$img"; then rmi+=("$img"); else _sc_kept "$img" image_in_use; fi
    done
  fi
  local x
  x="$(jq -cn --argjson n "$n" \
        --argjson v "$(printf '%s\n' "${rmv[@]}" | jq -cR 'select(. != "")' | jq -cs .)" \
        --argjson i "$(printf '%s\n' "${rmi[@]}" | jq -cR 'select(. != "")' | jq -cs .)" \
        --argjson k "$(printf '%s\n' "${kept[@]}" | jq -c 'select(. != null)' 2>/dev/null | jq -cs .)" \
        '{removed:{containers:$n,volumes:$v,images:$i},kept:$k}')"
  [ "$fvol" -eq 0 ] || sc_fail foreign_objects "Mindestens ein Daten-Volume traegt nicht unser Label und bleibt unangetastet." "$x"
  [ "$dkept" -eq 0 ] || sc_fail data_kept "Mindestens ein Daten-Volume blieb stehen (Grund je Volume oben)." "$x"
  sc_step 'done'
  sc_ok "$x"
}

# sc_main <verb> [optionen…] — Einstieg aus compose/stack.sh.
sc_main() {
  local a
  SC_ARGS=("$@")
  SC_DELETE_DATA=0 SC_HINTS_STDIN=0 SC_PROVISION_ARGS=()
  case "${1:-}" in check|up|start|status|wizard-url|install|uninstall) SC_VERB="$1" ;; *) _sc_usage ;; esac
  shift
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$SC_VERB:$a" in
      *:--json) SC_JSON=1 ;;
      uninstall:--delete-data) SC_DELETE_DATA=1 ;;
      wizard-url:--hints-stdin) SC_HINTS_STDIN=1 ;;
      install:--) SC_PROVISION_ARGS=("$@"); break ;;
      *) printf 'Unbekannte Option fuer %s: %s\n' "$SC_VERB" "$a" >&2; SC_VERB=''; _sc_usage ;;
    esac
  done
  SC_LASTF="$(mktemp)"
  exec {SC_OUT}>&1 {SC_IN}<&0
  trap _sc_on_exit EXIT
  # Als PID 1 des Kern-Containers ignoriert bash SIGTERM ohne eigenen Handler: `docker stop` toetete ihn erst nach 10 s per
  # SIGKILL, ohne result. Mit Handler endet er sofort nach dem laufenden Schritt, der EXIT-Trap schreibt das result.
  trap '_sc_on_signal 143 TERM' TERM
  trap '_sc_on_signal 130 INT' INT
  case "$SC_VERB" in
    check) sc_check ;; up) sc_up ;; start) sc_start ;; status) sc_status ;; wizard-url) sc_wizard_url ;;
    install) sc_install ;; uninstall) sc_uninstall ;;
  esac
}
