# install_update_timers.sh — systemd-Timer fuer das Update im Chat (Update-Hinweis 2026-10-24).
#
#   lifeagents-update-check.{service,timer}  taeglich 10:20 (Haushalts-Zeitzone): `lifeagents update --check`
#   lifeagents-update-run.{service,timer}    minuetlich: `lifeagents update --run-requested`
# Logik der Laeufe -> lib/update_runner.sh. Hier nur Rendern/Installieren/Entfernen (idempotent, Zweitlauf = no-op).
#
# WICHTIG: der Runner-Service fuehrt genau das Update aus, das diese Funktion (im neuen provision.sh) aufruft ->
#   NIE einen Service (neu) starten, nur die Timer. Eine geaenderte Service-Unit greift per daemon-reload beim
#   naechsten Timer-Lauf; der laufende oneshot-Prozess bleibt unberuehrt.
#
# Reads globals: TEMPLATE_DIR, TIMEZONE (provision.sh resolve_timezone), PROVISION_REPO_SLUG (common.sh).

UPDATE_TIMER_UNITS=(lifeagents-update-check lifeagents-update-run)
UPDATE_CLI_BIN="${UPDATE_CLI_BIN:-/usr/local/bin/lifeagents}"

install_update_timers() {
  local u svc_changed=1 tchanged
  for u in "${UPDATE_TIMER_UNITS[@]}"; do
    if render_template "$TEMPLATE_DIR/${u}.service.tpl" CLI_BIN="$UPDATE_CLI_BIN" REPO_SLUG="$PROVISION_REPO_SLUG" \
        | write_if_changed "/etc/systemd/system/${u}.service" 0644; then
      svc_changed=0
    fi
  done
  [ "$svc_changed" -eq 0 ] && systemctl daemon-reload
  for u in "${UPDATE_TIMER_UNITS[@]}"; do
    tchanged=1
    if render_template "$TEMPLATE_DIR/${u}.timer.tpl" TIMEZONE="${TIMEZONE:-Europe/Berlin}" \
        | write_if_changed "/etc/systemd/system/${u}.timer" 0644; then
      tchanged=0
    fi
    enable_start_unit "${u}.timer" "$tchanged"
  done
  ok "Update-Timer aktiv (täglicher Release-Check, Update-Aufträge aus dem Chat)."
}

# uninstall_update_timers — Timer + Services stoppen, deaktivieren, Unit-Dateien loeschen (idempotent; uninstall.sh).
uninstall_update_timers() {
  local u
  for u in "${UPDATE_TIMER_UNITS[@]}"; do
    _u_stop_unit "${u}.timer" 1
    _u_stop_unit "${u}.service" 1
  done
}

# install_release_keyring — den oeffentlichen Release-Signierschluessel des Projekts EINMAL nach /etc/lifeagents legen
#   (Vertrauen beim ersten Kontakt: Erstinstallation bzw. das erste Update auf eine signierende Version). Danach prueft
#   jedes Update (lifeagents update, Chat-Runner, install.sh) die Unterschrift gegen GENAU dieses Bund (fetch_release.sh
#   _release_fetch_verify). Ein Update ueberschreibt es NIE — sonst koennte ein gekapertes Release seinen eigenen
#   Schluessel mitbringen. Liefert der Baum (noch) keinen Schluessel, bleibt alles beim SHA256-Sidecar.
#   Reads globals: SCRIPT_DIR (provisioning/), LIFEAGENTS_DIR.
install_release_keyring() {
  local src="$SCRIPT_DIR/keys/release-signing.gpg" dst="${LIFEAGENTS_DIR}/release-signing.gpg"
  [ -s "$src" ] || { log "Release-Signierschlüssel: das Projekt signiert noch nicht — Prüfung per SHA256."; return 0; }
  if [ -s "$dst" ]; then
    cmp -s "$src" "$dst" || warn "Release-Signierschlüssel im neuen Stand weicht vom installierten ab — der installierte bleibt (${dst}). Ein bewusster Schlüsselwechsel: docs/reference/provisioning.md *Release-Signatur*."
    return 0
  fi
  install -m 0644 -o root -g root "$src" "$dst"
  ok "Release-Signierschlüssel installiert (${dst}) — Updates werden ab jetzt nur mit gültiger Unterschrift eingespielt."
}
