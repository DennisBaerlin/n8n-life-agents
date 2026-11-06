# master_swap.sh — Update im Docker-Verbund = Wechsel des master-Images ueber einen kurzlebigen Helfer (Plan-Pruefung Fund 6).
# GESOURCT (kein Shebang, kein set -e) von fetch_release.sh, update_runner.sh, upgrade_guard.sh und compose/swap_helper.sh.
#
# WARUM: Im Verbund bringt ein Release ein neues master-Image (Werkzeuge + Installer-Baum + compose.yml mit den Pins von n8n,
# Postgres & Co.). Der master kann sich nicht selbst ersetzen: `compose up master` aus ihm heraus beendet genau den Prozess,
# der es ausfuehrt. Darum drei Rollen mit EINER Zustandsdatei (Volume var_la, ueberlebt jeden Container):
#   1. alter master (`lifeagents update`): Release laden + Unterschrift pruefen (fetch_release.sh, unveraendert), aus der
#      GEPRUEFTEN compose.yml des Release das Ziel-Image lesen, Image bereitlegen, Zustand + beide compose-Dateien + Env-Datei
#      ablegen, Helfer starten. Bis hierher ist am laufenden System nichts geaendert (jeder Fehler = Abbruch davor).
#   2. Helfer (compose/swap_helper.sh, aus dem ALTEN Image): neuen master anlegen, Selbsttest; scheitert er, den alten
#      wieder anlegen. Schreibt PHASE=swapped bzw. rolled_back.
#   3. neuer (bzw. alter) master, naechster Tick (`lifeagents update --tick`, update_runner.sh): setzt fort — provision.sh aus
#      dem Image-Baum (upgrade_guard sichert davor) bzw. meldet den Rueckweg — und schliesst den Chat-Auftrag ab.
# Stirbt der Helfer mittendrin, entscheidet das eigene Image des master: = Ziel -> weiter, = Ausgang -> zurueckgerollt.
# Nennt die compose.yml des Releases keinen Pin (neutrale Zeile `${LA_MASTER_IMAGE:?…}`) -> ein Update bricht vor jeder Aenderung ab.

SWAP_DIR="${SWAP_DIR:-/var/lib/lifeagents/master-swap}"
SWAP_STATE="${SWAP_DIR}/state"
MASTER_IMAGE_TREE="${MASTER_IMAGE_TREE:-/opt/lifeagents}"   # Installer-Baum IM master-Image (master.Dockerfile)
# Variablen, die compose.yml interpoliert (EINE Liste fuer die Env-Datei des Helfers; contract_lint 33 haelt sie gleich).
SWAP_STACK_VARS="LA_PROJECT LA_EDGE_PORT LA_WIZARD_PORT LA_PG_SUPERPW LA_MASTER_IMAGE LA_TS_HOSTNAME"

_swap_get() { read_env_value "$SWAP_STATE" "$1" 2>/dev/null || true; }
_swap_set() { env_upsert "$SWAP_STATE" "$1" "$2"; }

# _swap_write_stack_env <ziel-datei> <master-image> — die Interpolations-Werte dieses master (Umgebung) fuer den Helfer,
#   LA_MASTER_IMAGE auf das Ziel. docker-Env-Datei = KEY=wert roh; ein Zeilenumbruch im Wert waere nicht darstellbar.
_swap_write_stack_env() {
  local out="$1" img="$2" v val
  ( umask 077; : > "$out" )
  for v in $SWAP_STACK_VARS; do
    if [ "$v" = LA_MASTER_IMAGE ]; then val="$img"; else val="${!v:-}"; fi
    case "$val" in *$'\n'*|*$'\r'*) die "Wert von ${v} enthält einen Zeilenumbruch — master-Wechsel abgebrochen, nichts geändert." ;; esac
    [ -n "$val" ] && printf '%s=%s\n' "$v" "$val" >> "$out"
  done
  chmod 0600 "$out"
}

# master_swap_begin <tag> <compose-datei> <ziel-image> [update|rollback] — <compose-datei> = die (gepruefte) compose.yml des
#   Ziel-Stands (Update: aus dem Release; Rueckweg: die vorherige aus dem Merkzettel). — Rolle 1 (siehe Kopf). Kehrt mit rc 0 zurueck, sobald der
#   Helfer laeuft; der Aufrufer endet dann (der master wird gleich ersetzt). Jeder Fehler davor = die, nichts geaendert.
master_swap_begin() {
  local tag="$1" cf="$2" target="$3" mode="${4:-update}" from="${LA_MASTER_IMAGE:-}" phase
  [ -n "$from" ] || die "LA_MASTER_IMAGE fehlt im master — Wechsel abgebrochen, nichts geändert."
  # Dieselbe Sperre wie jedes Update (der Chat-Runner haelt sie schon): kein Tick schaut dazwischen.
  update_lock_acquire 30 || die_because locked "Gerade läuft ein Update oder eine Einrichtung — danach erneut versuchen. Nichts geändert."
  if [ -f "$SWAP_STATE" ]; then
    phase="$(_swap_get PHASE)"
    die_because locked "Ein früherer master-Wechsel ist noch offen (Phase ${phase:-?}) — er wird beim nächsten Tick abgeschlossen; danach erneut versuchen."
  fi
  result_set stage download   # Schritt-Code wie das Laden des Release (core.fn_update_report kennt ihn)
  log "Neues Programm-Paket für ${tag} bereitlegen (${target}) ..."
  rt_image_ensure "$cf" "$target" \
    || die_because net "Das Programm-Paket ${target} ließ sich nicht laden — Update abgebrochen, es wurde nichts geändert."
  mkdir -p "$SWAP_DIR"; chmod 0700 "$SWAP_DIR"
  rm -f "$SWAP_DIR"/compose.new.yml "$SWAP_DIR"/stack.env
  install -m 0600 "$cf" "$SWAP_DIR/compose.new.yml"
  install -m 0600 "$LA_COMPOSE_FILE" "$SWAP_DIR/compose.old.yml"
  _swap_write_stack_env "$SWAP_DIR/stack.env" "$target"
  # SWAP_DROP_DB_AFTER/SWAP_NOTIFY (nur der Rueckweg) stehen VOR dem Helfer-Start in der Datei: danach schreibt der Helfer
  # sie, ein zweiter Schreiber koennte eine Zeile verlieren.
  printf 'PHASE=handoff\nMODE=%s\nTAG=%s\nFROM=%s\nTO=%s\nREQUEST_ID=%s\nALLOW_DOWNGRADE=%s\nDROP_DB_AFTER=%s\nNOTIFY=%s\nSTARTED=%s\n' \
    "$mode" "$tag" "$from" "$target" "${LIFEAGENTS_UPDATE_REQUEST_ID:-}" "${LIFEAGENTS_ALLOW_DOWNGRADE:-0}" \
    "${SWAP_DROP_DB_AFTER:-}" "${SWAP_NOTIFY:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | write_file "$SWAP_STATE" 0600
  if ! rt_swap_helper_start "$from" "$SWAP_DIR"; then
    rm -f "$SWAP_STATE" "$SWAP_DIR/stack.env"
    die "Der Helfer für den master-Wechsel ließ sich nicht starten — Update abgebrochen, es wurde nichts geändert."
  fi
  result_set status handoff
  ok "Übergabe an den Helfer: der master wird auf ${tag} gewechselt; das Update läuft danach im neuen master weiter (docker logs $(rt_master_container))."
}

# swap_helper_main <arbeitsordner> — Rolle 2 (im Helfer-Container, compose/swap_helper.sh). rc 0 = Zustand geschrieben.
swap_helper_main() {
  SWAP_DIR="$1"; SWAP_STATE="$1/state"
  local from to
  from="$(_swap_get FROM)"; to="$(_swap_get TO)"
  [ -n "$from" ] && [ -n "$to" ] || { warn "Zustandsdatei unvollständig — Helfer endet ohne Änderung."; return 1; }
  sleep "${SWAP_GRACE_SECS:-3}"   # der alte master beendet seinen Schritt (Ergebnis-Datei, Log)
  _swap_set PHASE swapping
  log "master wechseln: ${from} -> ${to}"
  if rt_master_recreate "$SWAP_DIR/compose.new.yml" "$to" && rt_master_selfcheck "${SWAP_CHECK_SECS:-120}"; then
    _swap_set PHASE swapped
    ok "master läuft mit ${to}."
  else
    warn "Neuer master besteht den Selbsttest nicht — zurück auf ${from}."
    rt_master_recreate "$SWAP_DIR/compose.old.yml" "$from" || true
    if rt_master_selfcheck "${SWAP_CHECK_SECS:-120}"; then _swap_set PHASE rolled_back
    else _swap_set PHASE rollback_failed; fi
  fi
  rm -f "$SWAP_DIR/stack.env"
  return 0
}

# master_swap_pending — 0, wenn ein Wechsel offen ist (Zustandsdatei vorhanden).
master_swap_pending() { [ -f "$SWAP_STATE" ]; }

# master_swap_resolve -> was der Tick tun soll: wait | apply | rolled_back | interrupted | none. Rolle 3, entscheidet
#   nach dem eigenen Image, wenn der Helfer nicht mehr laeuft (er kann mitten im Wechsel gestorben sein).
master_swap_resolve() {
  master_swap_pending || { printf 'none'; return 0; }
  local phase from to me
  phase="$(_swap_get PHASE)"; from="$(_swap_get FROM)"; to="$(_swap_get TO)"; me="${LA_MASTER_IMAGE:-}"
  if rt_swap_helper_running; then printf 'wait'; return 0; fi
  case "$phase" in
    applying)   printf 'interrupted' ;;   # der neue master starb waehrend provision.sh -> nicht still wiederholen
    handoff)
      # Helfer noch nicht gestartet oder vor seinem ersten Schritt gestorben: kurz abwarten, danach nach eigenem Image.
      if [ -n "$(find "$SWAP_STATE" -mmin -5 2>/dev/null)" ]; then printf 'wait'
      elif [ "$me" = "$from" ]; then printf 'rolled_back'
      else printf 'interrupted'; fi ;;
    rolled_back|rollback_failed) printf 'rolled_back' ;;
    *)
      if [ -n "$to" ] && [ "$me" = "$to" ]; then printf 'apply'
      elif [ -n "$from" ] && [ "$me" = "$from" ]; then printf 'rolled_back'
      else printf 'interrupted'; fi ;;
  esac
}

# master_swap_close — Zustand abschliessen: Zustandsdatei weg, compose.old.yml bleibt als compose.prev.yml (Rueckweg).
master_swap_close() {
  [ -f "$SWAP_DIR/compose.old.yml" ] && mv -f "$SWAP_DIR/compose.old.yml" "$SWAP_DIR/compose.prev.yml"
  rm -f "$SWAP_STATE" "$SWAP_DIR/compose.new.yml" "$SWAP_DIR/stack.env"
}
