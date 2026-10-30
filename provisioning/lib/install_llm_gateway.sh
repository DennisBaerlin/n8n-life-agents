# install_llm_gateway.sh — den lokalen LLM-Gateway (Prompt-Caching + Nutzungs-Messung) als systemd-Dienst
# einrichten. Sourced by provision.sh (+ uninstall.sh liest die Namen). Definiert install_llm_gateway.
#
# WAS: llm_gateway/server.js (dependency-frei, Node aus ensure_node) lauscht auf 127.0.0.1:LLM_GATEWAY_PORT;
# inject_credentials.sh zeigt die Anthropic-Credential (url) darauf. Mechanik/Begruendung → Kopf von server.js
# und provisioning/CLAUDE.md *LLM-Gateway*.
#
# REIHENFOLGE (fail-closed): laeuft NACH install_n8n (Node da) und VOR inject_credentials. Antwortet der Dienst
# nicht, bricht der Lauf HIER ab (die) — die Credential wird nie auf einen toten Gateway umgebogen (sonst
# scheiterten alle Agenten; die direkten HTTP-Knoten sogar still via onError=continueRegularOutput).
#
# CODE-ORT: der Code wird SELBST nach $LLM_GATEWAY_DIR kopiert (write_if_changed), nicht aus dem
# install_cli-Spiegel gestartet — der entsteht erst am Lauf-Ende, und bei `lifeagents update` ist REPO_ROOT
# ein temporaerer Entpack-Ordner. Neustart, wenn Unit ODER Code sich geaendert haben.

LLM_GATEWAY_UNIT_NAME="lifeagents-llm-gateway"
# Port FEST (kein Env-Override): die direkten HTTP-Knoten tragen http://127.0.0.1:8090 build-time eingebacken
# (New-AnthropicMessagesNode) — ein abweichender Port liesse sie still ins Leere laufen.
LLM_GATEWAY_PORT=8090
LLM_GATEWAY_DIR="${LLM_GATEWAY_DIR:-/usr/local/lib/lifeagents-llm-gateway}"
LLM_GATEWAY_UNIT="/etc/systemd/system/${LLM_GATEWAY_UNIT_NAME}.service"
LLM_GATEWAY_URL="http://127.0.0.1:${LLM_GATEWAY_PORT}"

# _llm_gateway_port_foreign — 0, wenn der Port von einem FREMDEN Prozess belegt ist (unser Dienst laeuft nicht).
_llm_gateway_port_foreign() {
  systemctl is-active --quiet "$LLM_GATEWAY_UNIT_NAME" && return 1
  need_cmd ss || return 1
  [ -n "$(ss -Hltn "sport = :${LLM_GATEWAY_PORT}" 2>/dev/null)" ]
}

_wait_llm_gateway_health() {
  local _
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 2 -o /dev/null "${LLM_GATEWAY_URL}/__health" 2>/dev/null; then
      ok "LLM-Gateway Health OK (${LLM_GATEWAY_URL}/__health)."
      return 0
    fi
    sleep 1
  done
  return 1
}

install_llm_gateway() {
  local node_bin src="${LLM_GATEWAY_SRC:-$SCRIPT_DIR/llm_gateway/server.js}"
  node_bin="$(command -v node || true)"
  [ -n "$node_bin" ] || die "Node.js nicht im PATH — der LLM-Gateway braucht es (kommt mit n8n)."
  [ -f "$src" ] || die "LLM-Gateway-Code fehlt: $src (unvollständiges Paket)."
  if _llm_gateway_port_foreign; then
    die "Port ${LLM_GATEWAY_PORT} ist von einem anderen Programm belegt — der LLM-Gateway kann nicht starten (ss -ltnp zeigt, welches)."
  fi

  # Cache-Keep-Alive (Kopf von server.js): Stunden 0-48, Standard 24, 0 = aus. Quelle: Install-Env (Test-Substrat
  # setzt 0, sonst stupst ein stundenlang laufendes Substrat den Cache auf dem Entwickler-Schluessel an), sonst die
  # persistierte core.env (Owner-Schalter: LLM_GATEWAY_KEEPALIVE_HOURS=0 dort eintragen + lifeagents update).
  local ka_hours="${LLM_GATEWAY_KEEPALIVE_HOURS:-}"
  [ -n "$ka_hours" ] || ka_hours="$(read_env_value "$INSTALL_ENV_FILE" LLM_GATEWAY_KEEPALIVE_HOURS 2>/dev/null || true)"
  [ -n "$ka_hours" ] || ka_hours=24
  if ! [[ "$ka_hours" =~ ^[0-9]{1,2}$ ]] || [ "$ka_hours" -gt 48 ]; then
    warn "LLM_GATEWAY_KEEPALIVE_HOURS='$ka_hours' ungueltig (0-48) — nehme 24."
    ka_hours=24
  fi

  local changed=1
  if write_if_changed "$LLM_GATEWAY_DIR/server.js" 0644 < "$src"; then changed=0; fi
  # Persona-Sticker fuer den Telegram-Relay (Kopf von server.js): wie der Code SELBST kopiert (REPO_ROOT ist beim
  # Update ein Entpack-Ordner, der install_cli-Spiegel entsteht erst am Lauf-Ende). Binaer -> cmp + install statt
  # write_if_changed (das liest per $(cat) als Text). Geaenderte Datei -> Neustart (file_id-Cache im RAM leeren).
  local sticker_src="${LLM_GATEWAY_STICKER_SRC:-$SCRIPT_DIR/../packages/core/build/stickers}" sticker_dir="$LLM_GATEWAY_DIR/stickers" f
  install -d -m 0755 "$sticker_dir"
  if [ -d "$sticker_src" ]; then
    for f in "$sticker_src"/*.webp; do
      [ -f "$f" ] || continue
      if ! cmp -s "$f" "$sticker_dir/$(basename "$f")"; then install -m 0644 "$f" "$sticker_dir/$(basename "$f")"; changed=0; fi
    done
  else
    warn "Sticker-Ordner fehlt ($sticker_src) — der Bot schickt keine Sticker (Antworten laufen normal)."
  fi
  if render_template "$TEMPLATE_DIR/lifeagents-llm-gateway.service.tpl" \
        GATEWAY_PORT="$LLM_GATEWAY_PORT" \
        KEEPALIVE_HOURS="$ka_hours" \
        NODE_BIN="$node_bin" \
        GATEWAY_JS="$LLM_GATEWAY_DIR/server.js" \
        STICKER_DIR="$sticker_dir" \
      | write_if_changed "$LLM_GATEWAY_UNIT" 0644; then
    changed=0
  fi
  # Versionswechsel (upgrade_guard.sh, auch ein fortgesetzter): nach einem Node-Tausch liefe sonst der alte
  # Node-Prozess weiter (Unit + Pfad /usr/bin/node bleiben gleich).
  [ "${UPGRADE_ACTIVE:-0}" -eq 1 ] && changed=0
  enable_start_unit "$LLM_GATEWAY_UNIT_NAME" "$changed"
  _wait_llm_gateway_health \
    || die "LLM-Gateway antwortet nicht (${LLM_GATEWAY_URL}/__health) — Abbruch, bevor die Anthropic-Credential umgestellt wird. Diagnose: journalctl -u ${LLM_GATEWAY_UNIT_NAME} -n 50"
}

# uninstall_llm_gateway — Dienst stoppen + Unit + Code + Mitschrift (StateDirectory, usage.jsonl) entfernen
# (idempotent; von uninstall.sh gerufen). Mit DynamicUser liegt der Ordner unter /var/lib/private, /var/lib traegt
# nur den Link.
uninstall_llm_gateway() {
  _u_stop_unit "${LLM_GATEWAY_UNIT_NAME}.service" 1
  rm -rf "$LLM_GATEWAY_DIR" "/var/lib/${LLM_GATEWAY_UNIT_NAME}" "/var/lib/private/${LLM_GATEWAY_UNIT_NAME}" 2>/dev/null || true
}
