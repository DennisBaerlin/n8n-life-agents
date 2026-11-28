# install_backup_timer.sh — systemd-Timer fuer die taegliche Sicherung (klassischer Betrieb). Gesourct von provision.sh.
#
#   lifeagents-backup.{service,timer}   ab BACKUP_AUTO_AT stuendlich bis 23 Uhr (Haushalts-Zeitzone, Persistent=true):
#                                       `lifeagents backup auto --scheduled` (backup_cli.sh: nur wenn heute noch nichts gelang)
# Im Docker-Verbund ersetzt der Tick im master den Timer (update_runner.sh update_tick) — dort ist alles hier ein no-op.
# Idempotent, Zweitlauf = no-op. Den Service nie (neu) starten, nur den Timer (wie install_update_timers.sh).
#
# Reads globals: TEMPLATE_DIR, TIMEZONE (provision.sh resolve_household_timezone), PROVISION_REPO_SLUG, BACKUP_AUTO_AT (common.sh).

BACKUP_TIMER_UNIT=lifeagents-backup
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"   # Test-Haken: die Units in einen Wegwerf-Ordner legen

# Die Zeile, die `lifeagents backup help` frueher fuer die root-crontab empfahl (woertlich, Zeichen fuer Zeichen). Nur sie raeumt
# remove_legacy_backup_cron weg: eine abgewandelte Zeile ist eine Eigenentscheidung des Besitzers und bleibt.
BACKUP_LEGACY_CRON_LINE='30 3 * * * cd /root && lifeagents backup export --notify-telegram >> /var/log/lifeagents-backup.log 2>&1'

install_backup_timer() {
  rt_is_compose && return 0
  local at="${BACKUP_AUTO_AT:-0330}" hh mm svc_changed=1 tchanged=1
  [[ $at =~ ^([01][0-9]|2[0-3])([0-5][0-9])$ ]] || die "BACKUP_AUTO_AT='${at}' ist keine Uhrzeit (HHMM, 0000–2359)."
  hh="${BASH_REMATCH[1]}"; mm="${BASH_REMATCH[2]}"
  if render_template "$TEMPLATE_DIR/${BACKUP_TIMER_UNIT}.service.tpl" CLI_BIN="${UPDATE_CLI_BIN:-/usr/local/bin/lifeagents}" REPO_SLUG="$PROVISION_REPO_SLUG" \
      | write_if_changed "${SYSTEMD_UNIT_DIR}/${BACKUP_TIMER_UNIT}.service" 0644; then
    svc_changed=0
  fi
  [ "$svc_changed" -eq 0 ] && svc_daemon_reload
  if render_template "$TEMPLATE_DIR/${BACKUP_TIMER_UNIT}.timer.tpl" TIMEZONE="${TIMEZONE:-Europe/Berlin}" HOUR="$hh" MINUTE="$mm" \
      | write_if_changed "${SYSTEMD_UNIT_DIR}/${BACKUP_TIMER_UNIT}.timer" 0644; then
    tchanged=0
  fi
  enable_start_unit "${BACKUP_TIMER_UNIT}.timer" "$tchanged"
  ok "Tägliche Sicherung aktiv (ab ${hh}:${mm}, die letzten ${BACKUP_HOST_KEEP:-14} bleiben in ${BACKUP_LOCAL_DIR})."
}

# remove_legacy_backup_cron — die alte, im Hilfetext empfohlene crontab-Zeile aus der root-crontab nehmen (sonst sicherten Zeile
#   und Timer doppelt). Nur genau diese Zeile; alles andere bleibt unberuehrt. Ohne crontab oder ohne die Zeile: still. Nur bei
#   laufendem Timer: enable_start_unit verschluckt einen gescheiterten `systemctl enable`, ohne Timer waere die Zeile die letzte Sicherung.
remove_legacy_backup_cron() {
  rt_is_compose && return 0
  command -v crontab >/dev/null 2>&1 || return 0
  svc_is_active "${BACKUP_TIMER_UNIT}.timer" || return 0
  local cur tmp
  cur="$(crontab -l -u root 2>/dev/null || true)"
  printf '%s\n' "$cur" | grep -qxF -- "$BACKUP_LEGACY_CRON_LINE" || return 0
  tmp="$(mktemp)"
  printf '%s\n' "$cur" | grep -vxF -- "$BACKUP_LEGACY_CRON_LINE" > "$tmp" || true
  if crontab -u root "$tmp"; then
    ok "Alte Sicherungs-Zeile aus der root-crontab entfernt — die tägliche Sicherung läuft jetzt über den Timer ${BACKUP_TIMER_UNIT}; andere Einträge blieben unberührt."
  else
    warn "Die alte Sicherungs-Zeile in der root-crontab ließ sich nicht entfernen — bitte per 'crontab -e' löschen, sonst läuft die Sicherung doppelt."
  fi
  rm -f "$tmp"
}

# uninstall_backup_timer — Timer + Service stoppen, deaktivieren, Unit-Dateien loeschen (idempotent; uninstall.sh). Sicherungs-Dateien
#   und backup.state bleiben (Nutzerdaten).
uninstall_backup_timer() {
  rt_is_compose && return 0
  _u_stop_unit "${BACKUP_TIMER_UNIT}.timer" 1
  _u_stop_unit "${BACKUP_TIMER_UNIT}.service" 1
}
