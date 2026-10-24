# shellcheck disable=SC2034,SC1111  # SC1111: deutsche Anfuehrungszeichen in Nutzertexten gewollt; SC2034: OWNER_CONNECT_*/_INGRESS_HELP_SHOWN liest der Aufrufer (provision.sh, household_cli.sh)
# owner_connect.sh — Gefuehrtes Ende der Installation: Erreichbarkeit (bring-your-own Reverse Proxy) +
# Telegram-Owner-Pairing (Install-UX-Phase 3). SOURCED (kein Shebang, kein set -e).
#
# EIN Code-Pfad, zwei Aufrufer: owner_connect_guided am Ende von provision.sh main() UND
# `lifeagents household pair-owner` (Muster pkg_cmd_install: provision.sh + CLI teilen den Pfad).
# Ablauf (interaktiv):
#   1. schon gepairt? -> fertig.  Voraussetzungen fehlen / kein TTY -> "spaeter" (Recap nennt den Befehl).
#   2. Erreichbarkeit: https://<domain> antwortet + Orchestrator aktiv + Telegram-Webhook gesetzt
#      (getWebhookInfo ist das Pruefstor — ein lokaler HTTPS-Test besteht auch bei Hairpin-NAT/Split-DNS,
#      wo Telegram trotzdem nicht durchkommt). Nicht erreichbar -> Caddyfile + Anforderungen + Auswahl
#      "Erneut pruefen / Spaeter". Webhook fehlt -> Orchestrator neu aktivieren (Telegram lehnt setWebhook
#      ab, solange die Domain nicht aufloest — deshalb hiess es frueher "danach lifeagents update").
#   3. Pairing im Geraete-Code-Muster (RFC 8628 / `gh auth login`): Code armieren, Deep-Link
#      t.me/<bot>?start=<code> zeigen (Telegram-Standard fuer Bot-Pairing), auf /start WARTEN (DB-Poll).
#      Ablauf (10 Min) -> nachfragen "Neuer Code / Spaeter" (RFC 8628 §3.5: kein Endlos-Re-Arm).
#   4. Fertig einrichten: Workflows mit der echten chat_id neu deployen (core + registry-aktive Pakete; der
#      Deploy meldet laufende Ausloeser vorher ab, kein n8n-Neustart noetig), Owner-Befehlsmenue setzen. Nicht-fatal.
#
# Reads globals: N8N_DB_NAME, N8N_URL, N8N_API_KEY, N8N_PORT, DOMAIN, TELEGRAM_BOT_TOKEN, REPO_ROOT.
# Ergebnis in OWNER_CONNECT_RESULT: connected | later | unavailable (+ OWNER_CONNECT_REASON; OWNER_CONNECT_FIX = der
# passende Nachtrag-Satz fuer den Recap, Install-UX-Phase 7: fehlende Angabe -> `lifeagents reconfigure`).
# Reuses (sourced siblings): _arm_owner_challenge/_set_bot_command_menus/_owner_psql (bootstrap_owner.sh),
#   _owner_chat_id_db/deploy_workflows (deploy_workflows.sh), common.sh-Helfer.

OWNER_CONNECT_RESULT=''
OWNER_CONNECT_REASON=''
OWNER_CONNECT_FIX=''
_INGRESS_HELP_SHOWN=0
_OC_PROBLEM=''
_OC_ACT_ERR=''

# emit_ingress_help <template-dir> <domain> <n8n-port> <webhook-url> — fertiges Caddyfile + Anforderungen
#   fuer einen bestehenden Proxy (bring your own, Install-UX-Phase 2). Explizite Parameter (statt
#   provision.sh-Globals) -> auch aus der CLI (`household pair-owner`) nutzbar. Schreibt das Caddyfile
#   zusaetzlich nach /etc/lifeagents/reverse-proxy.caddyfile (write_if_changed: Zweitlauf no-op).
#   Zwei Faelle aus TRUSTED_PROXIES (lib/firewall.sh, Install-UX-Phase 5) — EIN Baustein (Caddyfile.tpl,
#   Block zwischen den lifeagents-webhooks-Markern):
#   * Proxy auf diesem Rechner: komplettes Caddyfile, Upstream 127.0.0.1:<port>.
#   * Proxy auf einem anderen Rechner: nur der Einfuege-Baustein fuer dessen bestehenden Domain-Block, Upstream
#     <LAN-IP dieses Rechners>:<port> (ip route get Richtung Proxy), plus Angaben fuer NPM/Traefik.
emit_ingress_help() {
  local tpl_dir="$1" domain="$2" port="$3" webhook_url="$4" caddyfile list nonloop upstream proxies bind
  [ -n "$domain" ] || return 0
  list="$(normalize_trusted_proxies "${TRUSTED_PROXIES:-}" 2>/dev/null || printf '127.0.0.1')"
  nonloop="$(_proxy_nonloop "$list")"
  if [ -z "$nonloop" ]; then
    caddyfile="$(render_template "$tpl_dir/Caddyfile.tpl" SITE_ADDRESS="$domain" N8N_UPSTREAM="127.0.0.1:${port}")"
    printf '%s\n' "$caddyfile" | write_if_changed "${LIFEAGENTS_DIR:-/etc/lifeagents}/reverse-proxy.caddyfile" 0644 "root:${N8N_USER:-n8n}" || true
    ui_box "Fertige Caddy-Konfiguration für ${domain} (auch gespeichert in ${LIFEAGENTS_DIR:-/etc/lifeagents}/reverse-proxy.caddyfile)" <<EOF
${caddyfile}
EOF
    ui_box 'Reverse Proxy auf diesem Rechner — was er können muss (auch für NPM, Traefik, nginx …)' <<EOF
n8n ist nur auf diesem Rechner erreichbar (127.0.0.1:${port}). Der Reverse Proxy nimmt die
HTTPS-Verbindungen aus dem Internet an (Zertifikat z. B. von Let's Encrypt) und reicht weiter:

  NUR diese Pfade (alles andere gesperrt lassen):
    /webhook/*   /webhook-test/*   /webhook-waiting/*   /webhook-waiting-telegram
    →   http://127.0.0.1:${port}
  /webhook-waiting/* ist für die Bestätigungs-Knöpfe nötig (ohne bleiben Bestätigungen hängen);
  mit /webhook-waiting-telegram antworten sie direkt im Chat statt über eine Webseite.
Diese Kopfzeilen an n8n durchreichen: X-Forwarded-For, X-Forwarded-Host, X-Forwarded-Proto
(Caddy macht das automatisch).
Im Router: Port 443 auf diesen Rechner weiterleiten (Telegram nutzt nur 443, 80, 88 oder 8443).
n8n erwartet die Adresse ${webhook_url} — das ist bereits eingestellt.
Läuft dein Proxy stattdessen auf einem anderen Rechner: lifeagents proxy set <IP des Proxy-Rechners>
Schritt-für-Schritt (inkl. FRITZ!Box-Portfreigabe): Doku-Seite „Installation".
EOF
  else
    upstream="$(this_host_lan_ip "$(printf '%s' "$nonloop" | head -n1)")"
    [ -n "$upstream" ] || upstream="<IP dieses Rechners>"
    proxies="$(printf '%s' "$nonloop" | paste -sd, - | sed 's/,/, /g')"
    bind="$(read_env_value "${N8N_ENV_FILE:-/etc/n8n/n8n.env}" N8N_LISTEN_ADDRESS 2>/dev/null || true)"
    caddyfile="$(render_template "$tpl_dir/Caddyfile.tpl" SITE_ADDRESS="$domain" N8N_UPSTREAM="${upstream}:${port}" \
      | sed -n '/>>> lifeagents-webhooks/,/<<< lifeagents-webhooks/p' | sed '1d;$d' | sed 's/^\t//')"
    printf '%s\n' "$caddyfile" | write_if_changed "${LIFEAGENTS_DIR:-/etc/lifeagents}/reverse-proxy.caddyfile" 0644 "root:${N8N_USER:-n8n}" || true
    ui_box "Baustein für deinen bestehenden Caddy (Proxy-Rechner ${proxies}) — in den Block „${domain} { … }“ einfügen" <<EOF
${caddyfile}
EOF
    ui_box 'Reverse Proxy auf einem anderen Rechner — so gehört es zusammen' <<EOF
1. Der Baustein oben kommt in den bestehenden Block deiner Domain ${domain}, und zwar VOR einen
   eventuellen Sammel-Block „handle { … }“ ohne Pfad (z. B. für Home Assistant) — Caddy prüft die
   Pfad-Regel zuerst, alles andere geht weiter an den Sammel-Block. Danach: systemctl reload caddy.
   Gespeichert auch in ${LIFEAGENTS_DIR:-/etc/lifeagents}/reverse-proxy.caddyfile.
   Nginx Proxy Manager / Traefik: genau diese Pfade an http://${upstream}:${port}
     /webhook/*   /webhook-test/*   /webhook-waiting/*   /webhook-waiting-telegram
     (alles andere NICHT weiterleiten)
   X-Forwarded-For/-Host/-Proto durchreichen (Caddy macht das automatisch).
2. Dieser Rechner lässt n8n (Port ${port}) NUR von ${proxies} zu (Firewall);
   alle anderen Geräte im Heimnetz werden abgewiesen.
3. Ändert sich eine der beiden IP-Adressen, findet der Proxy n8n nicht mehr (Fehler 502).
   Darum im Router für BEIDE Rechner eine feste IP vergeben (FRITZ!Box: „Diesem Netzwerkgerät
   immer die gleiche IPv4-Adresse zuweisen“). Proxy-Adresse ändern: lifeagents proxy set <IP>
n8n erwartet die Adresse ${webhook_url} — das ist bereits eingestellt.
EOF
    if [ -n "$bind" ] && [ "$bind" = "127.0.0.1" ]; then
      warn "Achtung: n8n lauscht noch nur lokal (die Firewall ließ sich nicht einrichten, siehe oben) — der Proxy erreicht n8n so nicht."
    fi
  fi
  _INGRESS_HELP_SHOWN=1
}

# _oc_owner_person_exists -> 0 wenn das Owner-Person-Skelett existiert (ohne kann fn_consume nichts mergen).
_oc_owner_person_exists() {
  local n
  n="$(_owner_psql -tA -c "SELECT count(*) FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons','[]'::jsonb)) p WHERE c.name='family' AND p->>'role'='owner';" 2>/dev/null | head -n1 || true)"
  [ -n "$n" ] && [ "$n" != "0" ]
}

_oc_is_chat_id() { printf '%s' "$1" | grep -qE '^[0-9]+$' && [ "$1" != "0" ]; }

# _oc_webhook_info -> getWebhookInfo-JSON (leer bei Fehler). Token nur ueber den Config-Kanal.
_oc_webhook_info() {
  tg_api_curl "$TELEGRAM_BOT_TOKEN" getWebhookInfo -fsS --max-time 10 2>/dev/null || true
}

# _oc_webhook_known <getWebhookInfo-JSON> -> 0 nur bei einer gueltigen Telegram-Antwort (.ok == true). Ein curl-Fehler/
#   Netz-Wackler liefert "" = „unbekannt", NICHT „keine/falsche Adresse" (Install-UX-Phase 7; controller-runtime-Muster:
#   bei Fehler nicht handeln) — sonst de-/reaktivierte jeder Wackler den Bot bzw. meldete eine falsche Diagnose.
_OC_TG_UNKNOWN='Telegram ist gerade nicht erreichbar (Webhook-Stand unbekannt) — bitte gleich erneut prüfen'
_oc_webhook_known() {
  [ "$(printf '%s' "$1" | jq -r '.ok // false' 2>/dev/null || echo false)" = "true" ]
}

# _oc_activate_orchestrator <workflow-id> — de- + reaktivieren (zwingt n8n zu einem frischen setWebhook).
#   0 = ok; sonst steht n8ns/Telegrams Fehlermeldung in _OC_ACT_ERR.
_oc_activate_orchestrator() {
  local id="$1" resp code
  _OC_ACT_ERR=''
  n8n_set_published unpublish "$id" -sS -o /dev/null 2>/dev/null || true
  resp="$(n8n_set_published publish "$id" -sS -o - -w '\n%{http_code}' 2>/dev/null || true)"
  code="$(printf '%s' "$resp" | tail -n1)"
  case "$code" in 2*) return 0 ;; esac
  _OC_ACT_ERR="$(printf '%s' "$resp" | sed '$d' | jq -r '.message // empty' 2>/dev/null || true)"
  [ -n "$_OC_ACT_ERR" ] || _OC_ACT_ERR="HTTP ${code:-?}"
  return 1
}

# _oc_gateway_hint <http-code> — Klartext fuer "Proxy erreicht, n8n nicht" (502/503/504), je nach Proxy-Ort.
_oc_gateway_hint() {
  local list nonloop up
  list="$(normalize_trusted_proxies "${TRUSTED_PROXIES:-}" 2>/dev/null || printf '127.0.0.1')"
  nonloop="$(_proxy_nonloop "$list")"
  if [ -z "$nonloop" ]; then
    printf 'Dein Reverse Proxy antwortet (Fehler %s), kommt aber nicht bis zu n8n durch. Läuft er auf diesem Rechner, muss er an http://127.0.0.1:%s weiterleiten. Läuft er auf einem ANDEREN Rechner: lifeagents proxy set <IP des Proxy-Rechners>' "$1" "${N8N_PORT:-5678}"
  else
    up="$(this_host_lan_ip "$(printf '%s' "$nonloop" | head -n1)")"
    printf 'Dein Reverse Proxy antwortet (Fehler %s), kommt aber nicht bis zu n8n durch. Prüfe: leitet er an http://%s:%s weiter, und hat der Proxy-Rechner wirklich die IP %s? (Anzeige: lifeagents proxy show)' \
      "$1" "${up:-<IP dieses Rechners>}" "${N8N_PORT:-5678}" "$(printf '%s' "$nonloop" | paste -sd, -)"
  fi
}

# _oc_reachable — ist der Bot von aussen erreichbar? 0 = ja; sonst Grund (Klartext) in _OC_PROBLEM.
_oc_reachable() {
  _OC_PROBLEM=''
  local code st id active info url
  code="$(https_code "$DOMAIN")"
  if [ "$code" = "000" ]; then
    _OC_PROBLEM="https://${DOMAIN} antwortet nicht (DNS, Zertifikat, Reverse Proxy oder Port-Weiterleitung)"
    return 1
  fi
  # Aktive Probe der ganzen Kette (Install-UX-Phase 5): ein unbekannter Webhook-Pfad muss bis zu n8n durchgehen
  # (n8n antwortet 404). 502/503/504 = der Proxy ist erreichbar, kommt aber nicht bis zu n8n durch — sofort
  # erkannt, ohne erst auf ein /start und Telegrams Fehlermeldung zu warten.
  code="$(https_code "${DOMAIN}/webhook/lifeagents-probe-$(rand_hex 4)")"
  case "$code" in
    502|503|504) _OC_PROBLEM="$(_oc_gateway_hint "$code")"; return 1 ;;
  esac
  st="$(n8n_orchestrator_state "$N8N_API_KEY" "$N8N_URL")"
  if [ -z "$st" ]; then
    _OC_PROBLEM="n8n antwortet nicht oder der Bot-Workflow fehlt ('lifeagents doctor' zeigt Details)"
    return 1
  fi
  id="${st%%$'\t'*}"; active="${st#*$'\t'}"
  info="$(_oc_webhook_info)"
  url="$(printf '%s' "$info" | jq -r '.result.url // ""' 2>/dev/null || true)"
  # Webhook-Zustand (Install-UX-Phase 7, _oc_webhook_known): Reaktivieren, wenn der Orchestrator inaktiv ist ODER (bekannt
  # ∧ URL zeigt nicht auf die Domain). Aktiv ∧ unbekannt -> nichts anfassen, „erneut prüfen" anbieten.
  if [ "$active" = "true" ] && ! _oc_webhook_known "$info"; then
    _OC_PROBLEM="$_OC_TG_UNKNOWN"
    return 1
  fi
  if [ "$active" != "true" ] || [ "${url#"https://${DOMAIN}/"}" = "$url" ]; then
    if ! _oc_activate_orchestrator "$id"; then
      _OC_PROBLEM="Telegram nimmt die Adresse noch nicht an: ${_OC_ACT_ERR}"
      return 1
    fi
    info="$(_oc_webhook_info)"
    if ! _oc_webhook_known "$info"; then _OC_PROBLEM="$_OC_TG_UNKNOWN"; return 1; fi   # Wackler ≠ „keine Adresse"
    url="$(printf '%s' "$info" | jq -r '.result.url // ""' 2>/dev/null || true)"
    if [ "${url#"https://${DOMAIN}/"}" = "$url" ]; then
      _OC_PROBLEM="Telegram hat keine Webhook-Adresse für ${DOMAIN} gespeichert (aktuell: ${url:-leer})"
      return 1
    fi
  fi
  return 0
}

# _oc_wait_reachable — Erreichbarkeit pruefen; bei Problem Caddyfile + Auswahl. 0 = erreichbar.
_oc_wait_reachable() {
  local choice
  while :; do
    ui_step "Erreichbarkeit von https://${DOMAIN} prüfen"
    if _oc_reachable; then ui_step_done; return 0; fi
    ui_step_bad "$_OC_PROBLEM"
    if [ "$_INGRESS_HELP_SHOWN" -eq 0 ]; then
      emit_ingress_help "${OC_TEMPLATE_DIR:-$REPO_ROOT/provisioning/templates}" "$DOMAIN" "$N8N_PORT" "https://${DOMAIN}/"
    fi
    choice="$(printf '%s\n' "Erneut prüfen (Reverse Proxy ist eingerichtet)	retry" "Später einrichten	later" \
                | ui_choose 'Damit Telegram deinen Bot erreicht, muss der Reverse Proxy stehen:' 0)"
    [ "$choice" = "retry" ] || return 1
  done
}

# _oc_pair — Code armieren, Deep-Link zeigen, auf /start warten. 0 = verbunden, 1 = spaeter/Fehler.
_oc_pair() {
  local bot code result exp fd frames i n key shown_at err_seen info err_date err_msg choice chat rc
  fd="$(ui_fd)"
  bot="$(tg_api_curl "$TELEGRAM_BOT_TOKEN" getMe -fsS --max-time 10 2>/dev/null | jq -r '.result.username // empty' 2>/dev/null || true)"
  frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  while :; do
    code="$(rand_hex 8)"   # 16 Hex = 64 bit (OWASP-Entropie-Boden); gueltiger Deep-Link-Payload [A-Za-z0-9_-]
    result="$(_arm_owner_challenge "$code")"
    if [ "$(printf '%s' "$result" | jq -r '.ok // false' 2>/dev/null || echo false)" != "true" ]; then
      OWNER_CONNECT_REASON="Pairing-Code nicht erzeugt: $(printf '%s' "$result" | jq -r '.reason // "unbekannt"' 2>/dev/null || echo unbekannt)"
      warn "$OWNER_CONNECT_REASON"
      return 1
    fi
    exp="$(printf '%s' "$result" | jq -r '.expires_at // ""' 2>/dev/null || true)"
    if [ -n "$bot" ]; then
      ui_box 'Verbinde dich mit deinem Bot' <<EOF
Öffne diesen Link auf deinem Handy — Telegram startet den Chat mit deinem Bot:

    https://t.me/${bot}?start=${code}

Oder schreibe deinem Bot @${bot} diese Nachricht:   /start ${code}

Der Code gilt 10 Minuten und nur für dich — bitte nicht weitergeben.
EOF
    else
      ui_box 'Verbinde dich mit deinem Bot' <<EOF
Schreibe deinem Bot in Telegram diese Nachricht:   /start ${code}

Der Code gilt 10 Minuten und nur für dich — bitte nicht weitergeben.
EOF
    fi
    shown_at="$(date +%s)"; err_seen=0; i=0
    while :; do
      # Alle ~3 s: verbunden? (DB-only — kein Env-Fallback, B12)
      if [ $((i % 15)) -eq 0 ]; then
        chat="$(_owner_chat_id_db)"
        if _oc_is_chat_id "$chat"; then
          { printf '\r\033[2K' >&"$fd"; } 2>/dev/null || true
          ui_step 'Telegram-Verbindung'; ui_step_done 'verbunden'
          return 0
        fi
      fi
      # Alle ~6 s: meldet Telegram einen Zustellfehler seit der Code-Anzeige? (einmal anzeigen)
      if [ "$err_seen" -eq 0 ] && [ $((i % 30)) -eq 29 ]; then
        info="$(_oc_webhook_info)"
        err_date="$(printf '%s' "$info" | jq -r '.result.last_error_date // 0' 2>/dev/null || echo 0)"
        if [ "${err_date:-0}" -ge "$shown_at" ] 2>/dev/null; then
          err_msg="$(printf '%s' "$info" | jq -r '.result.last_error_message // ""' 2>/dev/null || true)"
          { printf '\r\033[2K' >&"$fd"; } 2>/dev/null || true
          case "$err_msg" in
            *502*|*503*|*504*|*"Bad Gateway"*)
              warn "Telegram meldet: ${err_msg}. $(_oc_gateway_hint "$(printf '%s' "$err_msg" | grep -oE '50[234]' | head -n1)") — ich warte weiter." ;;
            *) warn "Telegram kann deinen Server gerade nicht erreichen: ${err_msg:-unbekannter Fehler} — Reverse Proxy prüfen; ich warte weiter." ;;
          esac
          err_seen=1
        fi
      fi
      # Ablauf des Codes (10 Min, fn_arm_pairing_challenge)
      n=$(( $(date +%s) - shown_at ))
      if [ "$n" -ge 600 ]; then
        { printf '\r\033[2K' >&"$fd"; } 2>/dev/null || true
        choice="$(printf '%s\n' "Neuen Code erzeugen	new" "Später verbinden	later" | ui_choose "Der Code${exp:+ (gültig bis $exp)} ist abgelaufen." 0)"
        [ "$choice" = "new" ] && continue 2
        return 1
      fi
      { printf '\r\033[2K  %s Warte auf deine Nachricht an den Bot …  (s = später)' "${frames[$((i % 10))]}" >&"$fd"; } 2>/dev/null || true
      rc=0; ui_wait_key 0.2 || rc=$?
      key="$UI_KEY"
      if [ "$rc" -eq 2 ] || { [ "$rc" -eq 0 ] && { [ "$key" = "s" ] || [ "$key" = "S" ]; }; }; then
        { printf '\r\033[2K' >&"$fd"; } 2>/dev/null || true
        return 1
      fi
      i=$((i + 1))
    done
  done
}

# _oc_finalize — nach erfolgreichem Pairing: Workflows mit echter chat_id neu einspielen + Owner-Menue.
#   Laeuft in einer Subshell des Aufrufers (deploy_workflows kann `die`n) -> nie fatal fuer den Lauf.
#   KEIN n8n-Neustart mehr (frueher Pflicht, sonst liefen die alten Zeitplaene mit chat_id 0 weiter):
#   deploy_workflows deaktiviert jeden laufenden Ausloeser VOR dem Import (_deactivate_live_triggers) und
#   aktiviert danach den neuen Stand. Damit entfaellt auch das Warten auf laufende Ausfuehrungen — das
#   Deaktivieren bricht keine laufende Ausfuehrung ab (die "verbunden"-Antwort des Orchestrators kommt an).
_oc_finalize() {
  local pkgs p
  deploy_workflows core
  pkgs="$(_owner_psql -tA -c "SELECT package FROM core.package_registry WHERE status='active' AND package <> 'core' ORDER BY package;" 2>/dev/null || true)"
  for p in $pkgs; do deploy_workflows "$p"; done
  _set_bot_command_menus "$TELEGRAM_BOT_TOKEN"
}

# _oc_send_welcome — Install-UX-Phase 6: die Owner-Begruessung NACH _oc_finalize schicken (erst dann sind die
#   Workflows mit der echten chat_id neu deployt — ein Knopf-Tipp VOR finalize liefe gegen
#   die alten Workflows mit Owner-chat_id 0, z. B. das Bestaetigungs-Gate). Text + Knoepfe kommen aus der EINEN
#   Quelle core.fn_render_welcome() (dieselbe, die der Orchestrator bei /start sendet; ohne Argument = in der Sprache des
#   Owners, Textkatalog Phase B). Plain text OHNE parse_mode
#   (die fn liefert kein Markdown), Knoepfe in einer Zeile wie New-TelegramInlineKeyboardSendNode. Body per
#   String-Konkatenation um die numerisch validierte chat_id (kein jq-Re-Parse -> keine Double-Precision, Muster
#   _push_bot_commands); Token ueber tg_api_curl (nie argv). Best-effort: 0 = gesendet, 1 = nicht.
_oc_send_welcome() {
  local chat w rest
  chat="$(_owner_chat_id_db)"
  _oc_is_chat_id "$chat" || return 1
  w="$(_owner_psql -tA -c "SELECT core.fn_render_welcome();" 2>/dev/null || true)"
  [ "$(printf '%s' "$w" | jq -r '.ok // false' 2>/dev/null || echo false)" = "true" ] || return 1
  rest="$(printf '%s' "$w" | jq -c '{text}
      + (if ((.buttons // []) | length) > 0
         then {reply_markup: {inline_keyboard: [[.buttons[] | {text, callback_data}]]}} else {} end)' 2>/dev/null)" || return 1
  [ -n "$rest" ] || return 1
  tg_api_curl "$TELEGRAM_BOT_TOKEN" sendMessage -fsS --max-time 10 -X POST -H 'content-type: application/json' \
    --data "{\"chat_id\":${chat},${rest#\{}" >/dev/null 2>&1
}

# owner_connect_guided — siehe Datei-Kopf. Setzt OWNER_CONNECT_RESULT (+ OWNER_CONNECT_REASON) und
# OWNER_WELCOME_SENT (1 = die Begruessung kam per Installer an; der Recap nennt sonst „/start").
owner_connect_guided() {
  OWNER_CONNECT_RESULT=''; OWNER_CONNECT_REASON=''; OWNER_CONNECT_FIX=''; OWNER_WELCOME_SENT=0
  local chat _reconf='nachtragen mit: lifeagents reconfigure (verbindet danach mit Telegram)'
  chat="$(_owner_chat_id_db)"
  if _oc_is_chat_id "$chat"; then
    OWNER_CONNECT_RESULT='connected'
    ui_step 'Telegram-Verbindung'; ui_step_done 'bereits verbunden'
    return 0
  fi
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then OWNER_CONNECT_RESULT='unavailable'; OWNER_CONNECT_REASON='kein Telegram-Bot-Token'; OWNER_CONNECT_FIX="$_reconf"; return 0; fi
  if [ -z "${DOMAIN:-}" ]; then OWNER_CONNECT_RESULT='unavailable'; OWNER_CONNECT_REASON='keine Internet-Adresse (ohne öffentliche Adresse erreicht Telegram den Bot nicht)'; OWNER_CONNECT_FIX="$_reconf"; return 0; fi
  if [ -z "${N8N_API_KEY:-}" ]; then OWNER_CONNECT_RESULT='unavailable'; OWNER_CONNECT_REASON='n8n-Zugang fehlt (Owner-Bootstrap unvollständig)'; OWNER_CONNECT_FIX='Abhilfe: lifeagents update (richtet den n8n-Zugang neu ein)'; return 0; fi
  if ! _oc_owner_person_exists; then OWNER_CONNECT_RESULT='unavailable'; OWNER_CONNECT_REASON='Name/Geburtsdatum des Owners fehlen'; OWNER_CONNECT_FIX="$_reconf"; return 0; fi
  if ! ui_interactive; then OWNER_CONNECT_RESULT='later'; return 0; fi
  need_cmd jq || { OWNER_CONNECT_RESULT='later'; OWNER_CONNECT_REASON='jq fehlt'; return 0; }

  ui_section 'Verbindung zu Telegram'
  if ! _oc_wait_reachable; then OWNER_CONNECT_RESULT='later'; OWNER_CONNECT_REASON='Reverse Proxy noch nicht erreichbar'; return 0; fi
  if ! _oc_pair; then OWNER_CONNECT_RESULT='later'; return 0; fi
  ui_step 'Bot auf dich einstellen'
  if ( _oc_finalize ); then
    ui_step_done
    ui_step 'Begrüßung in Telegram schicken'
    if _oc_send_welcome; then
      OWNER_WELCOME_SENT=1; ui_step_done
    else
      ui_step_bad "nicht angekommen — schreib deinem Bot einfach /start"
    fi
  else
    ui_step_bad "nicht vollständig — 'lifeagents update' holt es nach"
  fi
  OWNER_CONNECT_RESULT='connected'
  return 0
}
