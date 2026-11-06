# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) in den Nutzertexten sind gewollt, keine vertippten Shell-Quotes
# reconfigure_cli.sh — `lifeagents reconfigure [core|<paket>]` (Install-UX-Phase 7): Angaben NACH der Installation erneut
# erfragen und anwenden (dpkg-reconfigure / `openclaw configure` / `gitlab-ctl reconfigure`). SOURCED von
# templates/lifeagents.tpl (mit den household-Bibliotheken + fetch_release.sh) — kein Shebang, kein set -e.
#   ohne Argument  Auswahl „Grundsystem" + installierte Pakete mit Zugangsdaten (Esc = nichts tun).
#   core           _host_reconfigure: Internet-Adresse, Telegram-Bot, Anthropic, Google (+ Name/Geburtsdatum, solange noch
#                  kein Owner-Skelett existiert) einzeln aus einer Auswahl aendern (nur das Gewaehlte wird gefragt,
#                  Enter = behalten) ODER unverändert neu anwenden.
#                  Anwenden = voller Converge des installierten Baums (run_installed_release = `lifeagents update` ohne
#                  Download). Bei uns anders als `package reconfigure` (nur Credential-Upsert, kein Redeploy): Host-Keys
#                  tragen abgeleiteten Zustand (WEBHOOK_URL, Telegram-Webhook, Befehlsmenues, Owner-Skelett, Pairing)
#                  -> docs/reference/provisioning.md *Install-UX* (Phase 7).
#   <paket>        pkg_cmd_reconfigure (Paket-Zugangsdaten, id-stabiler Credential-Upsert, kein Redeploy).

_reconfigure_usage() {
  cat >&2 <<'EOF'
lifeagents reconfigure [core|<paket>] — Angaben nach der Installation ändern.

  (ohne Argument)  Auswahl-Liste: Grundsystem oder ein Paket mit Zugangsdaten.
  core             Grundsystem: Internet-Adresse, Telegram-Bot-Token, Anthropic- und Google-Schlüssel
                   (und Name/Geburtsdatum, solange du noch nie mit dem Bot verbunden warst) einzeln
                   ändern — du wählst aus einer Liste, gefragt wird nur das Gewählte — oder
                   unverändert neu anwenden (repariert z. B. den Telegram-Webhook oder das
                   Befehlsmenü). Danach richtet es alles neu ein — wie 'lifeagents update', nur
                   ohne Download (dauert einige Minuten).
  <paket>          Zugangsdaten eines Pakets erneut erfragen (= lifeagents package reconfigure <paket>).

Nicht hier: die n8n-Anmeldung (in n8n selbst), Name/Geburtsdatum nach dem Verbinden (pflegt der
Bot im Chat), der Ort des Reverse Proxys ('lifeagents proxy set'). Optionale Angaben lassen sich
hier nur ändern, nicht leeren.
EOF
}

reconfigure_cli() {
  local target="${1:-}"
  case "$target" in
    help|--help|-h) _reconfigure_usage; return 0 ;;
  esac
  # Strg-C mittendrin = nichts gespeichert (Grundsystem UND Pakete speichern erst nach der letzten Antwort).
  # shellcheck disable=SC2034  # gelesen von ui_abort (common.sh)
  UI_ABORT_MSG='Abgebrochen — nichts geändert.'
  if [ -z "$target" ]; then
    # Non-TTY/unattended: Hilfetext wie bei jedem nackten Nomen (Exit 0 — Skripte sehen nie einen Picker).
    if ! ui_interactive; then _reconfigure_usage; return 0; fi
    ensure_gum
    require_cmd jq
    target="$( { printf '%s\t%s\n' "Grundsystem — Internet-Adresse, Telegram-Bot, Anthropic, Google (+ Name, solange nicht verbunden)" core
                 _pkg_reconfigure_rows; } | ui_choose 'Was möchtest du ändern?' 0)"
    # Esc = klassische Hilfe (wie jedes nackte Nomen, docs/reference/provisioning.md *Entscheidungen* 1.1/1.4).
    if [ -z "$target" ]; then _reconfigure_usage; return 0; fi
  fi
  case "$target" in
    core) _host_reconfigure ;;
    *)    pkg_cmd_reconfigure "$target" ;;
  esac
}

# _host_status_box <KEY…> — „aktueller Stand"-Kasten des Grundsystems (derselbe Renderer wie die Uebersicht vor dem
#   Installieren; Secrets nie im Klartext). Der Proxy-Ort steht nur zur Info dabei (aendern: lifeagents proxy set).
_host_status_box() {
  local k items=''
  for k in "$@"; do items="${items}host"$'\t'"-"$'\t'"${k}"$'\t'"$(_host_key_label "$k")"$'\n'; done
  if [ -n "${DOMAIN:-}" ]; then items="${items}host"$'\t'"-"$'\t'"TRUSTED_PROXIES"$'\t'"$(_host_key_label TRUSTED_PROXIES)"$'\n'; fi
  _review_render "$items" | ui_box 'Grundsystem — aktueller Stand'
}

# _host_reconfigure_apply — den gespeicherten Stand anwenden: voller Converge des installierten Baums (exec, kehrt nie
#   zurueck). Ab hier gilt wieder der normale Strg-C-Text des Installers.
_host_reconfigure_apply() {
  ok "Wende an — wie 'lifeagents update', nur ohne Download (dauert einige Minuten) ..."
  # shellcheck disable=SC2034  # gelesen von ui_abort (common.sh); ab hier gilt wieder der Installer-Text
  UI_ABORT_MSG=''
  run_installed_release
}

# _host_reconfigure — Grund-Angaben aendern (core.env) und anwenden. Speichert erst nach der LETZTEN Antwort
#   (Strg-C mittendrin = nichts geaendert); ohne Aenderung kein Converge (ausser auf ausdruecklichen Wunsch).
_host_reconfigure() {
  local keys k v action changed='' labels=''
  if ! ui_interactive; then
    cat >&2 <<'EOF'
'lifeagents reconfigure core' braucht ein Terminal (die Angaben werden nacheinander abgefragt).
Ohne Terminal: den Wert in /etc/lifeagents/core.env eintragen (z. B. ANTHROPIC_API_KEY=…,
GOOGLE_API_KEY=…, DOMAIN=…) und danach 'lifeagents update' ausführen. Einen NEUEN Telegram-Bot
bitte im Terminal über 'lifeagents reconfigure core' eintragen — beim Eintragen von Hand bliebe
der alte Bot an diesen Server angebunden.
EOF
    exit 1
  fi
  [ -e "$(lifeagents_version_marker)" ] || die "Keine installierte Instanz gefunden ($(lifeagents_version_marker) fehlt) — erst installieren (install.sh) bzw. nach einem Deinstallieren wiederherstellen ('lifeagents update')."
  _pkg_resolve_env   # N8N_DB_NAME/N8N_API_KEY/… — die Owner-Skelett-Pruefung (_host_editable_keys) braucht die DB
  load_install_env   # die gespeicherten Antworten aus core.env (sonst saehe alles leer aus)
  ensure_gum

  keys="$(_host_editable_keys | tr '\n' ' ')"
  # shellcheck disable=SC2086  # Key-Namen sind [A-Z_] (kein Globbing/Leerzeichen)
  _host_status_box $keys
  action="$(printf '%s\t%s\n' "Angaben ändern …" edit \
              "Unverändert neu anwenden (repariert Telegram-Webhook, Befehlsmenü, Verbindung)" apply \
              "Abbrechen" abort | ui_choose 'Grundsystem — was möchtest du tun?' 0)"
  case "$action" in
    edit)  : ;;
    apply) _host_reconfigure_apply ;;            # exec — kehrt nicht zurueck
    *)     log "Abgebrochen — nichts geändert."; return 0 ;;
  esac

  # Vorher-Stand merken, dann eine Auswahl: nur die gewaehlte Angabe wird gefragt („Enter = behalten", _host_key_ask
  # reask speichert selbst nichts), danach zurueck zur Auswahl — Muster „Eine Angabe ändern" der Uebersicht, aber OHNE
  # _review_edit (das speichert sofort; hier gilt: erst nach „Fertig" speichern, Strg-C/Abbrechen = nichts geaendert).
  local -A before=()
  local pick missing proxy_asked=0
  for k in $keys TRUSTED_PROXIES; do eval "before[$k]=\${$k:-}"; done
  while :; do
    # shellcheck disable=SC2086  # Key-Namen sind [A-Z_] (kein Globbing/Leerzeichen)
    pick="$( { for k in $keys; do printf '%s: %s\t%s\n' "$(_host_key_label "$k")" "$(_review_status host - "$k")" "$k"; done
               printf '%s\t%s\n' "Fertig — speichern und anwenden" 'done' "Abbrechen — nichts ändern" abort; } \
             | ui_choose 'Welche Angabe ändern? (Esc = abbrechen, nichts geändert)' 0)"
    case "$pick" in
      done)
        missing=''
        for k in $keys; do
          _host_key_required "$k" || continue
          eval "v=\${$k:-}"
          [ -n "$v" ] || missing="${missing:+$missing, }$(_host_key_label "$k")"
        done
        if [ -n "$missing" ]; then warn "Pflichtangabe fehlt noch: ${missing} — bitte zuerst eintragen."; continue; fi
        break ;;
      ''|abort) log "Abgebrochen — nichts geändert."; return 0 ;;
      *)
        _host_key_ask "$pick" 1
        # Neu eine Adresse -> einmal im Lauf auch: wo laeuft der Reverse Proxy? (gibt es nur mit Adresse; setzt nur die Variable)
        if [ "$pick" = "DOMAIN" ] && [ -z "${before[DOMAIN]}" ] && [ -n "${DOMAIN:-}" ] && [ "$proxy_asked" = 0 ]; then
          _ask_trusted_proxies 1; proxy_asked=1
        fi ;;
    esac
  done

  for k in "${!before[@]}"; do
    eval "v=\${$k:-}"
    if [ "$v" != "${before[$k]}" ]; then changed="${changed:+$changed }$k"; fi
  done
  if [ -z "$changed" ]; then
    action="$(printf '%s\t%s\n' "Nein — nichts tun" no "Ja — unverändert neu anwenden" apply \
                | ui_choose 'Nichts geändert — trotzdem neu anwenden?' 0)"
    if [ "$action" = "apply" ]; then _host_reconfigure_apply; fi
    ok "Nichts geändert."
    return 0
  fi

  # Bot gewechselt: dem alten Bot den Webhook nehmen (gemeinsamer Baustein mit der Uebersicht, release_inputs.sh) — gegen
  # die ALTE Adresse geprueft, falls sich beides zugleich aendert.
  case " $changed " in
    *" TELEGRAM_BOT_TOKEN "*) _drop_old_bot_webhook "${before[TELEGRAM_BOT_TOKEN]}" "${TELEGRAM_BOT_TOKEN:-}" "${before[DOMAIN]}" ;;
  esac
  for k in $changed; do
    eval "v=\${$k:-}"
    _store_answer "${INSTALL_ENV_FILE:-/etc/lifeagents/core.env}" "$k" "$v"
    labels="${labels:+$labels, }$(_host_key_label "$k")"
  done
  ok "Gespeichert: ${labels}."
  case " $changed " in
    *" DOMAIN "*)
      if [ -n "${DOMAIN:-}" ]; then
        log "Neue Internet-Adresse ${DOMAIN}: bitte in deinem Reverse Proxy eintragen — Telegram erreicht den Bot erst danach."
        log "Steht der Proxy erst später: danach 'lifeagents reconfigure' → Grundsystem → „Unverändert neu anwenden“."
        emit_ingress_help "${LIFEAGENTS_PROV:-$(lifeagents_runtime_dir)/provisioning}/templates" "$DOMAIN" "${N8N_PORT:-5678}" "https://${DOMAIN}/"
      fi ;;
  esac
  _host_reconfigure_apply
}
