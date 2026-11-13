# update_progress.sh — Fortschritts-Nachricht eines Updates im Chat. Gesourct von update_runner.sh.
#
# Ein Hintergrund-Helfer liest den Schritt aus der Ergebnis-Datei (wie der Wizard) und bearbeitet genau eine Telegram-Nachricht.
# Das Update weiss nichts von ihm: keine Zeile in provision.sh, kein Warten, kein Exit-Status, der irgendwo ausgewertet wird.
# Texte und Prozente baut die DB vor dem Update fertig (core.fn_update_report, Phase progress_plan), denn waehrend des Updates
# ist sie zeitweise weg. Der Helfer rechnet nichts. Mitsterben mit der Unit oder dem master-Container ist gewollt.
#
# Zustandsdatei auf dem Volume, das auch den master-Wechsel ueberlebt: der Helfer des neuen master macht bei derselben Nachricht
# weiter. Sie gehoert genau einem Auftrag (.id), eine fremde wird ersetzt. Kein Token darin.

UP_STATE="${UP_STATE:-/var/lib/lifeagents/update-progress.state}"
UP_MIN_GAP_S="${UP_MIN_GAP_S:-10}"   # Abstand zwischen zwei Sendungen; Telegram nennt etwa 1/s je Chat als Grenze

# _up_api <token> <methode> [curl-args] -> Antwort-JSON auf stdout, auch bei 4xx (ohne -f, die Fehlerklasse steht im Koerper).
#   Leer = keine Antwort. Immer rc 0.
_up_api() {
  local token="$1" method="$2"; shift 2
  tg_api_curl "$token" "$method" -sS --connect-timeout 4 --max-time 8 "$@" 2>/dev/null || true
  return 0
}

_up_state_read() { cat "$UP_STATE" 2>/dev/null || true; return 0; }

_up_state_write() {
  local tmp
  mkdir -p "$(dirname "$UP_STATE")" 2>/dev/null || return 0
  tmp="$(mktemp "${UP_STATE}.XXXXXX" 2>/dev/null)" || return 0
  if ! { printf '%s' "$1" > "$tmp" && mv -f "$tmp" "$UP_STATE"; } 2>/dev/null; then rm -f "$tmp" 2>/dev/null; fi
  return 0
}

# _up_handle <antwort> <state> <text> <pct> <stage> — Antwort auswerten; setzt _UP_NEXT, _UP_BACKOFF, _UP_GONE.
_up_handle() {
  local resp="$1" state="$2" text="$3" pct="$4" stage="$5" now desc code retry mid ok
  now="$(date +%s)"
  ok="$(jq -r '.ok // false' <<<"$resp" 2>/dev/null || echo false)"
  desc="$(jq -r '.description // ""' <<<"$resp" 2>/dev/null || true)"
  code="$(jq -r '.error_code // 0' <<<"$resp" 2>/dev/null || echo 0)"
  # Die Bot-API hat keine festen Fehlercodes, nur Texte.
  case "$desc" in *'message is not modified'*) ok=true ;; esac
  if [ "$ok" = true ]; then
    mid="$(jq -r 'if (.result | type) == "object" then (.result.message_id // empty) else empty end' <<<"$resp" 2>/dev/null || true)"
    # Ohne bekannte Nachricht wuerde der naechste Takt eine zweite senden.
    if [ -z "$mid" ] && [ -z "$(jq -r '.message_id // empty' <<<"$state" 2>/dev/null || true)" ]; then _UP_GONE=1; return 0; fi
    _up_state_write "$(jq -c --arg m "$mid" --argjson p "$pct" --arg s "$stage" --arg t "$text" \
      '.pct=$p | .stage=$s | .text=$t | (if $m != "" then .message_id=($m|tonumber) else . end)' <<<"$state" 2>/dev/null || printf '%s' "$state")"
    _UP_NEXT=$((now + UP_MIN_GAP_S)); _UP_BACKOFF=15
    return 0
  fi
  case "$code" in
    429)
      retry="$(jq -r '.parameters.retry_after // 30' <<<"$resp" 2>/dev/null || echo 30)"
      case "$retry" in ''|*[!0-9]*) retry=30 ;; esac
      [ "$retry" -le 120 ] || retry=120
      _UP_NEXT=$((now + retry)); return 0 ;;
    403) _UP_GONE=1; return 0 ;;
    400)
      # Vom Nutzer geloescht: nicht wieder aufdraengen, die Ergebnis-Meldung kommt unabhaengig davon.
      case "$desc" in *'not found'*|*'MESSAGE_ID_INVALID'*|*"can't be edited"*) _UP_GONE=1; return 0 ;; esac ;;
  esac
  _UP_NEXT=$((now + _UP_BACKOFF))
  _UP_BACKOFF=$((_UP_BACKOFF * 2)); [ "$_UP_BACKOFF" -le 60 ] || _UP_BACKOFF=60
  return 0
}

# _up_tick <ergebnis-datei> <token> <chat> — ein Sendeversuch, wenn etwas zu sagen ist.
_up_tick() {
  local rf="$1" token="$2" chat="$3" state stage want text pct st mid resp
  [ "$(date +%s)" -ge "$_UP_NEXT" ] || return 0
  state="$(_up_state_read)"
  stage="$(read_env_value "$rf" stage 2>/dev/null || true)"
  want="$(jq -c --arg s "$stage" '
      (.plan.stages[$s] // null) as $st
      | if .message_id == null then
          {text:($st.text // .plan.start.text), pct:($st.pct // .plan.start.pct), stage:(if $st then $s else "" end)}
        elif $st != null and $st.pct > .pct and $st.text != .text then
          {text:$st.text, pct:$st.pct, stage:$s}
        else empty end' <<<"$state" 2>/dev/null || true)"
  [ -n "$want" ] || return 0
  text="$(jq -r '.text' <<<"$want")"; pct="$(jq -r '.pct' <<<"$want")"; st="$(jq -r '.stage' <<<"$want")"
  mid="$(jq -r '.message_id // empty' <<<"$state")"
  if [ -z "$mid" ]; then
    resp="$(_up_api "$token" sendMessage --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}")"
  else
    resp="$(_up_api "$token" editMessageText --data-urlencode "chat_id=${chat}" --data-urlencode "message_id=${mid}" --data-urlencode "text=${text}")"
  fi
  _up_handle "$resp" "$state" "$text" "$pct" "$st"
  return 0
}

# _up_loop <ergebnis-datei> <token> <chat> — der erste Sendeversuch liegt vor der Stop-Pruefung, damit auch ein sehr kurzer
#   Lauf seine Start-Nachricht zeigt.
_up_loop() {
  local rf="$1" token="$2" chat="$3" parent="$$" started gone
  _UP_NEXT=0; _UP_BACKOFF=15; _UP_GONE=0
  started="$(date +%s)"
  while [ "$(( $(date +%s) - started ))" -lt 7200 ] && kill -0 "$parent" 2>/dev/null; do
    _up_tick "$rf" "$token" "$chat"
    if [ "$_UP_GONE" = 1 ]; then
      gone="$(jq -c '.gone=true' <<<"$(_up_state_read)" 2>/dev/null || true)"
      [ -z "$gone" ] || _up_state_write "$gone"
      break
    fi
    [ ! -e "${UP_STATE}.stop" ] || break
    sleep 1
  done
}

# _up_start <id> <ergebnis-datei> — Helfer starten. Scheitert etwas, laeuft das Update ohne Anzeige. Immer rc 0.
_up_start() {
  local id="$1" rf="$2" state plan token chat
  _UP_PID=''
  need_cmd curl && need_cmd jq || return 0
  token="$(owner_tg_token)"; chat="$(owner_tg_chat_id)"
  [ -n "$token" ] && [ -n "$chat" ] || return 0
  state="$(_up_state_read)"
  if [ "$(jq -r '.id // empty' <<<"$state" 2>/dev/null || true)" != "$id" ]; then
    plan="$(_ur_sql "$(jq -nc --argjson id "$id" '{request_id:$id, phase:"progress_plan"}')" "SELECT core.fn_update_report(:'p'::jsonb);" 2>/dev/null)" || return 0
    [ "$(jq -r 'has("stages")' <<<"$plan" 2>/dev/null || echo false)" = true ] || return 0
    state="$(jq -c --argjson id "$id" '{id:$id, message_id:null, pct:-1, stage:"", text:"", plan:.}' <<<"$plan" 2>/dev/null)" || return 0
    _up_state_write "$state"
  fi
  rm -f "${UP_STATE}.stop" 2>/dev/null || true
  # fd 9 zu: Sonst hielte der Helfer die Update-Sperre (flock haengt an der offenen Dateibeschreibung).
  ( exec 9>&- ; set +eu +o pipefail ; _up_loop "$rf" "$token" "$chat" ) </dev/null >/dev/null 2>&1 &
  _UP_PID=$!
  return 0
}

# _up_stop — Helfer beenden. Die Frist liegt ueber --max-time: er bringt ein laufendes Senden selbst zu Ende. Ein KILL traefe nur
#   die Teilschale, ein weiterlaufendes curl koennte dann einen alten Stand ueber 100 % schreiben. Immer rc 0.
_up_stop() {
  local pid="${_UP_PID:-}"
  [ -n "$pid" ] || return 0
  : > "${UP_STATE}.stop" 2>/dev/null || true
  for _ in $(seq 1 60); do
    # `jobs -r` statt kill -0: ein beendetes, noch nicht abgeholtes Kind waere fuer kill -0 weiter da.
    jobs -rp 2>/dev/null | grep -qx "$pid" || break
    sleep 0.2
  done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "${UP_STATE}.stop" 2>/dev/null || true
  _UP_PID=''
  return 0
}

# _up_close <id> <klasse> — Fortschritts-Nachricht auf den Endstand bringen: 100 % nur bei geprueftem Erfolg (done). Ein Versuch,
#   die neue Ergebnis-Meldung folgt ohnehin. Immer rc 0.
_up_close() {
  local id="$1" class="$2" state mid text token chat
  state="$(_up_state_read)"
  [ "$(jq -r '.id // empty' <<<"$state" 2>/dev/null || true)" = "$id" ] || return 0
  [ "$(jq -r '.gone // false' <<<"$state" 2>/dev/null || echo false)" != true ] || return 0
  mid="$(jq -r '.message_id // empty' <<<"$state" 2>/dev/null || true)"
  [ -n "$mid" ] || return 0
  text="$(jq -r --arg c "$class" 'if $c == "done" then .plan.done.text else (.plan.stages[.stage].stopped // .plan.start.stopped) end' <<<"$state" 2>/dev/null || true)"
  [ -n "$text" ] && [ "$text" != null ] || return 0
  token="$(owner_tg_token)"; chat="$(owner_tg_chat_id)"
  [ -n "$token" ] && [ -n "$chat" ] || return 0
  _up_api "$token" editMessageText --data-urlencode "chat_id=${chat}" --data-urlencode "message_id=${mid}" --data-urlencode "text=${text}" >/dev/null
  return 0
}

# _up_forget <id> — Zustand erst nach zugestellter Ergebnis-Meldung loeschen, sonst fehlte dem Nachholen die message_id. Immer rc 0.
_up_forget() {
  [ "$(jq -r '.id // empty' <<<"$(_up_state_read)" 2>/dev/null || true)" = "$1" ] || return 0
  rm -f "$UP_STATE" 2>/dev/null || true
  return 0
}
