# move_cli.sh — `lifeagents move`: Annahme auf der NEUEN Maschine (Gegenstueck zu `lifeagents retire`, lib/retire_cli.sh).
# Gesourct von templates/lifeagents.tpl (mit retire_cli.sh, backup_cli.sh, config_cli.sh und den Install-Primitiven des household-Arms:
# owner_connect.sh liefert _oc_finalize_verified). Mechanik: docs/reference/provisioning.md *Umzug*.
#
#   apply <ordner>   Umzugs-Ordner einspielen (Ordner = Ergebnis von `retire`; Verbund: Pfad auf dem Rechner). Vorpruefungen aendern
#                    nichts; danach in Stufen started -> restored -> finalized -> applied. Die Sicherung bringt Gespraeche,
#                    geaenderte Einstellungen und Paket-Zugaenge selbst mit (backup_cli.sh _bkp_restore_parts).
#   check [<ordner>] Vergleich vorher.txt (alte Maschine) gegen nachher.txt (hier, move_snapshot = backup_fingerprint): generisch je
#                    Tabelle der Sicherung Zeilenzahl und md5, kein Paket-Code im Kern.
#   status           Stand (Exit 0 = kein Umzug offen, 10 = mitten drin, 11 = eingespielt, wartet auf die Abnahme).
#   done             Abnahme: hebt die Update-Sperre auf.
#   abort            Ausweg aus einem stehengebliebenen Umzug: hebt nur die Update-Sperre auf, Daten bleiben.
#
# Zustand: la_move_file (runtime.sh) = Merker „Umzug offen“ + Stufe; ab `started` sperrt er das Update (update_runner.sh), bis
# `done` oder `abort`. Ein neuer apply-Lauf mit demselben Umzug macht nach der letzten erledigten Stufe weiter und spielt die Sicherung nie
# noch einmal ein: Daten, die inzwischen entstanden sind, gingen sonst verloren.
# Exit: 0 ok; 1 Abbruch bzw. Vergleich mit Abweichung (Grund auf stderr); 2 Vergleich unmoeglich.

MOVE_FORMAT=1
MOVE_STAGES="started restored finalized applied"
MOVE_TUNNEL_WAIT_SECS="${MOVE_TUNNEL_WAIT_SECS:-600}"
MOVE_TUNNEL_POLL_SECS="${MOVE_TUNNEL_POLL_SECS:-5}"
# move.env = Klartext-Antworten aus einem Ordner vor der Verschluesselung (gleiche Rolle, darum mitgeloescht).
MOVE_SECRET_FILES="move.env.gpg move.env"

move_usage() {
  cat >&2 <<'USAGE'
lifeagents move — Daten von der alten Maschine auf diese (neue) Maschine übernehmen.

Usage: lifeagents move apply <ordner>
       lifeagents move check [<ordner>] | status | done [--yes] | abort [--yes]

  apply <ordner>  Einspielen: Vorprüfungen (ändern nichts), dann die Sicherung (mit Gesprächen, Einstellungen und Zugängen),
                  Bot fest auf dich einstellen, Übersicht-Knopf mit der neuen Adresse, Geheimnis-Dateien im Ordner löschen,
                  Vergleich. Bricht es ab, macht ein neuer Lauf dort weiter. <ordner> = der Umzugs-Ordner der alten Maschine
                  (Docker-Verbund: Pfad auf dem Rechner, z. B. /root/lifeagents-move).
  check           Vergleich mit den Werten der alten Maschine (vorher.txt): nur Namen und Kennzahlen.
  status          Wie weit ist der Umzug? Exit 0 = kein Umzug offen, 10 = mitten drin, 11 = eingespielt (Abnahme steht aus).
  done            Abnahme nach der Probezeit: hebt die Update-Sperre auf. Ohne Terminal nur mit --yes.
  abort           Ausweg aus einem stehengebliebenen Umzug: nimmt nur die Update-Sperre weg, Daten bleiben. Ohne Terminal nur mit --yes.

Solange der Umzug offen ist, gibt es keine Updates: der Rückweg auf die alte Maschine braucht dieselbe Version.
USAGE
}

# --- Zustand -------------------------------------------------------------------------------------------------------------
_mv_get() { read_env_value "$(la_move_file)" "$1" 2>/dev/null || true; }
_mv_set() {
  local f; f="$(la_move_file)"
  ( umask 077; env_upsert "$f" "$1" "$2" ) || die "Stand des Umzugs liess sich nicht schreiben ($f)."
}
_mv_stage() { la_move_open || return 0; _mv_get STAGE; }
# _mv_reached <stufe> — 0, wenn die gespeicherte Stufe <stufe> oder eine spaetere ist.
_mv_reached() { la_stage_reached "$MOVE_STAGES" "$(_mv_stage)" "$1"; }

# --- Vergleich -----------------------------------------------------------------------------------------------------------
# move_compare <vorher> <nachher> — nur die abweichenden Zeilen, "<art> <name>  vorher <wert|—>  nachher <wert|—>", sortiert; still,
#   wenn alles gleich ist. rc 0 gleich, 1 Abweichung, 2 eine Datei fehlt. Zeilenform: "<art> <name> <wert>" (move_snapshot); der
#   Schluessel ist "<art> <name>", der Wert Zeilenzahl, md5 oder Zaehler — nie ein Inhalt.
move_compare() {
  local out
  [ -r "$1" ] && [ -r "$2" ] || return 2
  # Zuordnung ueber den Dateinamen: NR==FNR hielte bei leerer erster Datei jede Zeile der zweiten fuer „vorher“. Der awk-Status
  # zaehlt allein (eine Pipe in sort ueberdeckte ihn).
  out="$(awk -v first="$1" '
    function split3(line,   a) { n = index(line, " "); rest = substr(line, n + 1); m = index(rest, " ")
      if (m == 0) { key = line; val = "" } else { key = substr(line, 1, n + m - 1); val = substr(rest, m + 1) } }
    $0 == "" { next }
    FILENAME == first { split3($0); va[key] = val; seen[key] = 1; next }
    { split3($0); vb[key] = val; seen[key] = 1 }
    END { for (k in seen) { x = (k in va) ? va[k] : "—"; y = (k in vb) ? vb[k] : "—"; if (x != y) printf "%s  vorher %s  nachher %s\n", k, x, y } }
  ' "$1" "$2")" || return 2
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | LC_ALL=C sort
  return 1
}

# _mv_check <ordner-wie-angegeben> <lokaler-ordner> — move_snapshot hier -> nachher.txt (Verbund: auch in den Rechner-Ordner), dann
#   Vergleich mit vorher.txt. rc wie move_compare.
_mv_check() {
  local dir="$1" d="$2" diff rc=0
  [ -r "$d/vorher.txt" ] || { err "In ${dir} fehlt vorher.txt — ohne die Werte der alten Maschine gibt es nichts zu vergleichen."; return 2; }
  ( umask 077; move_snapshot > "$d/nachher.txt.part" ) || { rm -f "$d/nachher.txt.part"; die "Vergleichswerte dieser Maschine ließen sich nicht lesen."; }
  mv -f "$d/nachher.txt.part" "$d/nachher.txt"
  if rt_is_compose; then
    rt_host_put "$(_bkp_hd "$dir")" nachher.txt "$d/nachher.txt" || warn "nachher.txt ließ sich nicht in '${dir}' ablegen (der Vergleich läuft trotzdem)."
  fi
  diff="$(move_compare "$d/vorher.txt" "$d/nachher.txt")" || rc=$?
  case "$rc" in
    0) ok "Vergleich: alle gesicherten Tabellen, Einstellungen und das Gedächtnis stimmen mit der alten Maschine überein." ;;
    1) warn "Vergleich: Abweichungen gegenüber der alten Maschine (Zeilenzahl bzw. Prüfsumme je Tabelle):"
       printf '%s\n' "$diff" | sed 's/^/    /' >&2
       warn "Ob das gewollt ist (z. B. etwas, das hier seit dem Einspielen entstand), entscheidest du; bei Zweifel nicht abnehmen." ;;
    *) err "Vergleich nicht möglich." ;;
  esac
  return "$rc"
}

# --- Vorpruefungen -------------------------------------------------------------------------------------------------------
# _mv_owner_paired -> 0, wenn die family-Fakten einen Owner mit Telegram-Kennung tragen. Eine gescheiterte Abfrage heisst „unbekannt“
#   und bricht ab, nie „nicht gekoppelt“ (_owner_chat_id_db verschluckt DB-Fehler): der Schutz davor, eine laufende Installation zu
#   ueberschreiben, darf nicht offen aufgehen.
_mv_owner_paired() {
  local n
  n="$(_ret_sql "SELECT count(*) FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp
                  WHERE c.name = 'family' AND pp->>'role' = 'owner' AND COALESCE(pp->>'telegram_user_id', '') <> ''")" \
    || die "Datenbank nicht erreichbar — ob diese Maschine schon in Gebrauch ist, lässt sich nicht prüfen. Es wurde nichts geändert."
  [[ $n =~ ^[0-9]+$ ]] || die "Datenbank antwortet unklar bei der Prüfung, ob diese Maschine schon in Gebrauch ist. Es wurde nichts geändert."
  [ "$n" -gt 0 ]
}

# _mv_key_file -> Ablage des Notfallblatt-Schluessels zwischen move_unlock (vor der Einrichtung) und dem Einspielen; 0600 auf dem
#   Volume var_la neben dem Merker. Weg mit den Geheimnis-Dateien (_mv_wipe_secrets), bei abort und done.
_mv_key_file() { printf '%s/move-sheet.key' "$(dirname "$(la_move_file)")"; }

# move_unlock <move.env.gpg> <ziel> — vor der Einrichtung im master (compose/move_unlock.sh, gerufen von setup.sh --answers): einmal den
#   Schluessel vom Notfallblatt am Terminal fragen (derselbe Leser wie beim Einspielen, _bkp_ask_key_tty), die Antworten damit nach
#   <ziel> entschluesseln (0600) und den Schluessel bis zum Einspielen ablegen (_mv_key_file): move apply fragt dann nicht noch einmal.
move_unlock() {
  local in="$1" out="$2" tries=0 k
  [ -r "$in" ] || die "Die Antwort-Datei ${in} fehlt."
  ui_interactive || die "Die Antwort-Datei ist verschlüsselt — dafür braucht setup.sh ein Terminal (Schlüssel vom Notfallblatt der alten Maschine). Es wurde nichts geändert."
  { printf '\n  %s\n\n' "$(backup_text ask.intro)" > /dev/tty; } 2>/dev/null || true
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    k="$(_bkp_ask_key_tty | sed -n 's/^key://p' | head -n1)"
    if [ -n "$k" ] && ( umask 077; gpg_sym_decrypt "$k" "$in" > "$out" ); then
      ( umask 077; mkdir -p "$(dirname "$(_mv_key_file)")" && printf '%s' "$k" > "$(_mv_key_file)" ) \
        || die "Der Schlüssel ließ sich für das Einspielen nicht ablegen ($(_mv_key_file)). Es wurde nichts geändert."
      ok "Antwort-Datei entschlüsselt — das Einspielen (lifeagents move apply) fragt den Schlüssel nicht noch einmal."
      return 0
    fi
    rm -f -- "$out"
    warn "Dieser Schlüssel öffnet die Antwort-Datei nicht — bitte das Notfallblatt der alten Maschine nehmen."
  done
  die "Der Schlüssel passte dreimal nicht. Es wurde nichts geändert."
}

# _mv_plan <sicherung> — Probelauf (aendert nichts). Kein gespeicherter Schluessel dieser Maschine oeffnet die Sicherung (sie hat
#   einen eigenen): dann EINMAL den Schluessel vom Notfallblatt am Terminal erfragen (_MV_SHEET) und an Probelauf UND Einspielen
#   reichen (--key-stdin), sonst fragte das Einspielen ein zweites Mal. Setzt _MV_PLAN. Direkt rufen, nie in $(…).
_MV_SHEET=''; _MV_PLAN=''
_mv_plan() {
  local f="$1" plan code detail tries=0 parsed errf
  # Schon beim Entsperren der Antworten eingegeben (move_unlock): derselbe Wert, keine zweite Frage.
  if [ -z "$_MV_SHEET" ] && [ -r "$(_mv_key_file)" ]; then _MV_SHEET="$(cat "$(_mv_key_file)")"; fi
  errf="$(mktemp)"
  while :; do
    plan="$( ( printf '%s' "$_MV_SHEET" | backup_cmd_restore "$f" --plan --json --key-stdin ) 2>"$errf" | tail -n1 || true)"
    if [ "$(printf '%s' "$plan" | jq -r '.ok // false' 2>/dev/null || true)" = true ]; then
      _MV_PLAN="$plan"; rm -f "$errf"; return 0
    fi
    code="$(printf '%s' "$plan" | jq -r '.code // empty' 2>/dev/null || true)"
    case "$code" in
      key_*) ;;
      *) detail="$(sed 's/\x1b\[[0-9;]*m//g' "$errf" | grep -v '^[[:space:]]*$' | tail -n1 | sed 's/^\[x\] *//' || true)"; rm -f "$errf"
         die "Die Sicherung lässt sich hier nicht einspielen (${detail:-${code:-Prüfung gescheitert}}). Es wurde nichts geändert." ;;
    esac
    rm -f "$errf"
    ui_interactive || die "Die Sicherung braucht den Schlüssel vom Notfallblatt (diese Maschine hat einen eigenen). Ohne Terminal geht das nicht: auf der alten Maschine lifeagents backup key, dann hier am Terminal erneut. Es wurde nichts geändert."
    tries=$((tries + 1))
    [ "$tries" -le 3 ] || die "Der Schlüssel vom Notfallblatt passte dreimal nicht. Es wurde nichts geändert."
    errf="$(mktemp)"
    parsed="$(_bkp_ask_key_tty)"
    _MV_SHEET="$(printf '%s\n' "$parsed" | sed -n 's/^key://p' | head -n1 || true)"
    [ -n "$_MV_SHEET" ] || warn "Das war kein gültiger Schlüssel — noch einmal."
  done
}

# _mv_reach_activate — Tunnel steht, Telegram zeigt noch nicht darauf: den Installer einmal nachfahren (Adresse uebernehmen, n8n setzt
#   den Webhook): compose/reach_ctl.sh activate, dessen einziger Nutzer der Umzug ist (der Wizard meldet vor der Installation an).
_mv_reach_activate() { bash "$(lifeagents_runtime_dir)/provisioning/compose/reach_ctl.sh" activate >&2; }

# _mv_tunnel_text <zustand> <link> [weg] — was der Owner jetzt tun muss.
_mv_tunnel_text() {
  case "${3:-tunnel}:$1" in
    proxy:ports_busy) printf 'Port %s ist auf dieser Maschine belegt — der Eingang für den eigenen Reverse Proxy startet nicht. Den Port freimachen, dann dasselbe Kommando noch einmal.\n' "$REACH_LAN_PORT"; return 0 ;;
    proxy:*) printf 'Der Eingang für den eigenen Reverse Proxy (Port %s) startet noch ...\n' "$REACH_LAN_PORT"; return 0 ;;
    fritzbox:ports_busy) printf 'Port 80 oder 443 ist auf dieser Maschine belegt — der FritzBox-Weg startet nicht.\n'; return 0 ;;
    fritzbox:*) printf 'Der FritzBox-Weg startet noch ...\n'; return 0 ;;
  esac
  case "$1" in
    needs_login|key_expired)
      printf 'Diese Maschine muss sich bei Tailscale anmelden. Link im Browser öffnen (Konto mit Google, Apple, Microsoft oder GitHub):\n  %s\n' "${2:-—}" ;;
    needs_funnel)
      printf 'Im Tailscale-Konto muss Funnel für diese Maschine erlaubt werden. Link im Browser öffnen:\n  %s\n' "${2:-—}" ;;
    needs_machine_auth) printf 'Im Tailscale-Konto die Maschine freigeben: https://login.tailscale.com/admin/machines\n' ;;
    *) printf 'Tailscale startet noch ...\n' ;;
  esac
}

# _mv_tunnel — nur Docker-Verbund (klassisch gibt es diese Wege nicht): wartet, bis der Weg nach aussen (Tunnel, FritzBox, eigener Proxy) steht; zeigt den
#   Anmelde- bzw. Freigabe-Link (der unbeaufsichtigte Installer zeigt ihn nicht). Bei Ablauf der Wartezeit Abbruch ohne Aenderung.
_mv_tunnel() {
  rt_is_compose || return 0
  local left="$MOVE_TUNNEL_WAIT_SECS" js state url mode last='' activated=0 txt
  while :; do
    js="$(reach_status_json 2>/dev/null || true)"
    state="$(printf '%s' "$js" | jq -r '.state // "unavailable"' 2>/dev/null || printf unavailable)"
    url="$(printf '%s' "$js" | jq -r '.url // ""' 2>/dev/null || true)"
    printf '%s' "$url" | grep -qE "$REACH_LOGIN_RE" || url=''
    # Die Antwort-Datei des Umzugs setzt den Weg (retire_cli.sh _ret_reach_mode: tunnel oder proxy). Ohne Weg wurde ohne sie
    # eingerichtet: kein Warten wert, die Ursache gleich nennen.
    mode="$(printf '%s' "$js" | jq -r '.mode // ""' 2>/dev/null || true)"
    case "${js:+x}:$mode" in
      :*|x:tunnel|x:fritzbox|x:proxy) : ;;
      *) die "Hier ist kein Weg nach außen eingerichtet (Modus ${mode:-keiner}) — die Antwort-Datei des Umzugs setzt ihn. Es wurde nichts geändert; mit der Datei aus dem Umzugs-Ordner neu einrichten: bash setup.sh --answers <ordner>/move.env.gpg" ;;
    esac
    case "$state" in
      ready) return 0 ;;
      pending_activation)
        if [ "$activated" = 0 ]; then
          activated=1; log "Der Weg nach außen steht — die Adresse wird übernommen und der Bot umgestellt ..."
          _mv_reach_activate || die "Die Adresse ließ sich nicht übernehmen (Ausgabe oben). Es wurde nichts eingespielt; noch einmal: lifeagents move apply"
          continue
        fi ;;
    esac
    txt="$(_mv_tunnel_text "$state" "$url" "$mode")"
    if [ "$state:$url" != "$last" ]; then warn "Der Weg nach außen ist noch nicht fertig:"; printf '%s\n' "$txt" >&2; last="$state:$url"; fi
    left=$((left - MOVE_TUNNEL_POLL_SECS))
    [ "$left" -gt 0 ] || die "Der Weg nach außen wurde in der Wartezeit nicht fertig. Es wurde nichts eingespielt — nach der Anmeldung dasselbe Kommando noch einmal."
    sleep "$MOVE_TUNNEL_POLL_SECS"
  done
}

# --- Stufen --------------------------------------------------------------------------------------------------------------
# _mv_wipe_secrets <ordner-wie-angegeben> <lokaler-ordner> — die Antwort-Datei (Schluessel) nach dem Einspielen loeschen;
#   die verschluesselte Sicherung bleibt (Sicherheitsnetz bis `done`). Verbund: ueber den Rechner-Ordner.
_mv_wipe_secrets() {
  local dir="$1" d="$2" f
  rm -f -- "$(_mv_key_file)" || return 1
  if rt_is_compose; then
    # shellcheck disable=SC2086  # feste Dateinamen ohne Leerzeichen
    rt_host_rm "$(_bkp_hd "$dir")" $MOVE_SECRET_FILES
  else
    for f in $MOVE_SECRET_FILES; do rm -f -- "${d:?}/$f" || return 1; done
  fi
}

# --- Verben --------------------------------------------------------------------------------------------------------------
move_cmd_apply() {
  local dir="${1:-}" d rel move f inst
  [ -n "$dir" ] || { move_usage; die "lifeagents move apply braucht den Umzugs-Ordner."; }
  [ "$#" -le 1 ] || die "lifeagents move apply: nur der Ordner als Angabe (lifeagents move help)."
  require_root
  _bkp_resolve_db
  update_lock_acquire 30 || die "Gerade läuft ein Update, eine Sicherung oder eine Wiederherstellung — danach erneut."
  _ret_fetch_dir "$dir"; d="$_RET_DIR"
  [ -r "$d/move.manifest" ] || die "In ${dir} liegt kein Umzugs-Ordner (move.manifest fehlt)."
  [ "$(read_env_value "$d/move.manifest" FORMAT 2>/dev/null || true)" = "$MOVE_FORMAT" ] \
    || die "Der Umzugs-Ordner hat ein anderes Format ($(read_env_value "$d/move.manifest" FORMAT 2>/dev/null || printf '?')) — mit derselben Version der alten und der neuen Maschine neu erzeugen."
  rel="$(read_env_value "$d/move.manifest" RELEASE 2>/dev/null || true)"
  inst="$(_bkp_release_tag)"
  [ -n "$rel" ] && [ "$rel" = "$inst" ] \
    || die "Der Umzugs-Ordner stammt von Version ${rel:-?}, hier ist ${inst:-keine Version} installiert — beide Maschinen müssen dieselbe Version haben. Es wurde nichts geändert."
  f="$(read_env_value "$d/move.manifest" BACKUP_FILE 2>/dev/null || true)"
  case "$f" in ''|.|..|*/*) die "move.manifest nennt keine Sicherung." ;; esac
  [ -r "$d/$f" ] || die "Die Sicherung ${f} fehlt im Umzugs-Ordner. Es wurde nichts geändert."
  move="$(read_env_value "$d/move.manifest" CREATED 2>/dev/null || true)"
  [ -n "$move" ] || die "move.manifest nennt keinen Zeitpunkt (CREATED)."

  if la_move_open; then
    [ "$(_mv_get MOVE)" = "$move" ] \
      || die "Ein anderer Umzug ist noch offen (Stand: $(_mv_stage)) — erst abnehmen (lifeagents move done) oder verwerfen (lifeagents move abort). Es wurde nichts geändert."
  else
    # Schutz gegen den teuersten Tippfehler: das Einspielen ersetzt alle Nutzerdaten. Auf einer frisch eingerichteten Maschine ist
    # noch kein Owner gekoppelt (die Antwort-Datei koppelt keinen).
    if _mv_owner_paired; then
      die "Diese Maschine ist schon in Gebrauch (ein Owner ist gekoppelt) — das Einspielen würde ihre Daten ersetzen. Es wurde nichts geändert. Ein Umzug geht nur auf eine frisch eingerichtete Maschine."
    fi
  fi

  # Der Probelauf nur vor dem Einspielen: danach hat diese Maschine Daten, und der Probelauf meldete im Verbund „kein Sicherungs-Ordner“.
  if ! _mv_reached restored; then
    _mv_plan "$d/$f"
    if [ "$(printf '%s' "$_MV_PLAN" | jq -r '.release // empty' 2>/dev/null || true)" != "$rel" ]; then
      die "Die Sicherung stammt aus Version $(printf '%s' "$_MV_PLAN" | jq -r '.release // "?"' 2>/dev/null), der Umzugs-Ordner nennt ${rel}. Es wurde nichts geändert."
    fi
  fi
  _mv_tunnel

  if ! la_move_open; then
    rm -f "$(la_move_file)"
    _mv_set MOVE "$move"; _mv_set AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; _mv_set RELEASE "$rel"; _mv_set DIR "$dir"; _mv_set STAGE started
  fi
  if ! _mv_reached restored; then
    log "Spiele die Sicherung ein ..."
    ( printf '%s' "$_MV_SHEET" | backup_cmd_restore "$d/$f" --yes --key-stdin ) \
      || die "Wiederherstellen gescheitert — die Daten sind unverändert (atomar). Noch einmal: lifeagents move apply ${dir}"
    _mv_set STAGE restored
  fi
  # Gespraeche, Einstellungen oder Zugaenge nicht angekommen (backup_cli.sh _bkp_restore_parts): einmal nachholen, ohne die Daten
  # erneut zu ersetzen; sonst hier anhalten, bevor die Antworten geloescht werden und der Umzug als eingespielt gilt.
  if [ -n "$(read_env_value "$BACKUP_STATE_FILE" LAST_RESTORE_PARTS 2>/dev/null || true)" ]; then
    log "Hole die nicht übernommenen Teile nach ..."
    ( printf '%s' "$_MV_SHEET" | backup_cmd_restore "$d/$f" --yes --key-stdin --parts ) || true
    [ -z "$(read_env_value "$BACKUP_STATE_FILE" LAST_RESTORE_PARTS 2>/dev/null || true)" ] \
      || die "Nicht übernommen: $(read_env_value "$BACKUP_STATE_FILE" LAST_RESTORE_PARTS) (Gründe oben) — die Daten sind eingespielt. Noch einmal: lifeagents move apply ${dir}"
  fi
  if ! _mv_reached finalized; then
    load_install_env
    _pkg_resolve_env
    _oc_finalize_verified \
      || die "Der Bot ließ sich nicht fest auf dich einstellen (${OC_FINALIZE_REASON:-?}); Details oben. Der Stand ist gespeichert — noch einmal: lifeagents move apply ${dir}"
    _set_bot_menu_buttons "$(owner_tg_token)"
    _mv_set STAGE finalized
  fi
  if ! _mv_reached applied; then
    # Erst nach gelungenem Loeschen „eingespielt“: sonst blieben Schluessel und Gespraeche im Ordner, und kein Lauf versuchte es noch einmal.
    _mv_wipe_secrets "$dir" "$d" \
      || die "Die Geheimnis-Dateien (${MOVE_SECRET_FILES}) ließen sich in '${dir}' nicht löschen — Ordner und Rechte prüfen oder von Hand entfernen, dann noch einmal: lifeagents move apply ${dir}"
    _mv_set STAGE applied
  fi
  ok "Eingespielt. Jetzt prüfen (nicht abnehmen, bevor das alles stimmt): lifeagents doctor; dem Bot schreiben, eine Karte bestätigen; ein Mitglied schreibt, die Übersicht öffnet mit der neuen Adresse."
  log "Gut läuft es zwei Wochen? Dann abnehmen: lifeagents move done (danach gibt es Updates wieder und keinen Rückweg mehr)."
  _mv_check "$dir" "$d"
}

move_cmd_check() {
  local dir="${1:-}" d
  require_root
  _bkp_resolve_db
  [ -n "$dir" ] || dir="$(_mv_get DIR)"
  [ -n "$dir" ] || die "Umzugs-Ordner nötig: lifeagents move check <ordner>"
  _ret_fetch_dir "$dir"; d="$_RET_DIR"
  _mv_check "$dir" "$d"
}

move_cmd_status() {
  local st; st="$(_mv_stage)"
  if ! la_move_open; then log "Kein Umzug offen."; return 0; fi
  if [ "$st" = applied ]; then
    ok "Umzug offen seit $(_mv_get AT) (Version $(_mv_get RELEASE)); Updates sind gesperrt. Prüfen: lifeagents move check — abnehmen: lifeagents move done"
    return 11
  fi
  warn "Umzug angefangen, Stand: ${st:-?} (seit $(_mv_get AT)). Weiter: lifeagents move apply $(_mv_get DIR)"
  return 10
}

# abort — Ausweg aus einem stehengebliebenen Umzug (falscher Ordner, ein Lauf, der nicht mehr gelingt, die alte Maschine hat neu
#   exportiert): nimmt nur den Merker „Umzug offen“ weg, also die Update-Sperre. Daten werden nie angefasst; was schon eingespielt ist,
#   bleibt. Der eigentliche Rueckweg ist `lifeagents retire` hier und `lifeagents retire --undo` auf der alten Maschine.
move_cmd_abort() {
  local yes=0 a choice
  for a in "$@"; do
    case "$a" in --yes|-y) yes=1 ;; *) die "lifeagents move abort: unbekannte Angabe: $a" ;; esac
  done
  require_root
  la_move_open || { log "Kein Umzug offen — nichts zu verwerfen."; return 0; }
  if [ "$yes" != 1 ]; then
    ui_interactive || die "Ohne Terminal nur mit --yes: lifeagents move abort --yes"
    choice="$(printf '%s\t%s\n' 'Ja, verwerfen (nur die Update-Sperre fällt weg, Daten bleiben)' yes 'Nein' no | ui_choose 'Umzug verwerfen? Eingespieltes bleibt, es gibt danach wieder Updates.' 0)"
    [ "$choice" = yes ] || die "Nicht verworfen — nichts geändert."
  fi
  rm -f "$(la_move_file)" "$(_mv_key_file)"
  ok "Umzug verworfen: die Update-Sperre ist weg. Eingespielte Daten bleiben, wie sie sind (zurück auf die alte Maschine: lifeagents retire hier, dann lifeagents retire --undo dort)."
}

move_cmd_done() {
  local yes=0 a choice
  for a in "$@"; do
    case "$a" in --yes|-y) yes=1 ;; *) die "lifeagents move done: unbekannte Angabe: $a" ;; esac
  done
  require_root
  la_move_open || { log "Kein Umzug offen — nichts abzunehmen."; return 0; }
  [ "$(_mv_stage)" = applied ] \
    || die "Der Umzug ist noch nicht eingespielt (Stand: $(_mv_stage)) — erst zu Ende führen: lifeagents move apply $(_mv_get DIR)"
  if [ "$yes" != 1 ]; then
    ui_interactive || die "Ohne Terminal nur mit --yes: lifeagents move done --yes"
    choice="$(printf '%s\t%s\n' 'Ja, abnehmen (kein Rückweg mehr, Updates wieder frei)' yes 'Noch nicht' no | ui_choose 'Läuft alles so, wie es soll? Der Umzug wird abgenommen.' 0)"
    [ "$choice" = yes ] || die "Nicht abgenommen — nichts geändert."
  fi
  rm -f "$(la_move_file)" "$(_mv_key_file)"
  ok "Umzug abgenommen: Updates sind wieder frei. Die alte Maschine, die Proxy-Regel im Heimnetz und die Weiterleitung in der FritzBox dürfen jetzt weg; einen Rückweg auf die alte Maschine gibt es nicht mehr."
}

move_cli() {
  local verb="${1:-help}"; shift || true
  case "$verb" in
    apply)  move_cmd_apply "$@" ;;
    check)  move_cmd_check "$@" ;;
    status) move_cmd_status "$@" ;;
    done)   move_cmd_done "$@" ;;
    abort)  move_cmd_abort "$@" ;;
    help|--help|-h) move_usage; return 0 ;;
    *) move_usage; die "lifeagents move: unbekanntes Verb: ${verb}" ;;
  esac
}
