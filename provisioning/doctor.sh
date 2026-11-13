#!/usr/bin/env bash
# doctor.sh — read-only Diagnose des provisionierten Stacks (Ampel + Exit-Code).
#
# Aufruf: `bash doctor.sh` bzw. `lifeagents doctor`; am Ende von provision.sh laeuft es automatisch.
# Standalone (eigenes `set -euo pipefail`); als Quelle gesourct (BASH_SOURCE != $0) startet main nicht.
# Voraussetzungen: laeuft auch ohne root; Pruefungen, die root brauchen (Peer-Auth als postgres, 640-Env-Dateien,
# nft-Tabelle), melden dann SKIP statt Fehl-ROT. Die Doktor-Pruefungen aendern nichts (Ausnahme: der
# FritzBox-Weg `wan` im Docker-Verbund wird bei ausbleibender Antwort einmal neu gestartet).
# Ausgabe je Pruefung: [ OK ], [FAIL] (ROT), [WARN] und [SKIP] zaehlen nicht als Fehler.
# Exit-Code = Anzahl ROT (0 = alles gruen, CI-/Gate-tauglich).
#
# Infra-Pruefungen: PG / n8n / Env / Paket-Secrets / Host-Keys (Telegram/Anthropic, Google optional) /
# Ingress. Der HTTPS-Reverse-Proxy ist bring-your-own: doctor prueft nicht, welcher Terminierer laeuft,
# sondern das Outcome (Orchestrator-Trigger aktiv + oeffentliches HTTPS erreichbar), proxy-agnostisch.
set -euo pipefail
# UTF-8 unabhaengig von der System-Locale, auch bei direktem Aufruf auf einem LANG="C"-System.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/firewall.sh
. "$SCRIPT_DIR/lib/firewall.sh"   # TRUSTED_PROXIES-Normalisierung + Set-Vergleich
# shellcheck source=lib/n8n_patches.sh
. "$SCRIPT_DIR/lib/n8n_patches.sh"   # n8n_patch_status (read-only): sind die n8n-Korrekturen aktiv?

N8N_ENV_FILE="${N8N_ENV_FILE:-/etc/n8n/n8n.env}"
N8N_PORT="$(read_env_value "$N8N_ENV_FILE" N8N_PORT || true)"
[ -n "$N8N_PORT" ] || N8N_PORT=5678
N8N_DB_NAME="$(read_env_value "$N8N_ENV_FILE" DB_POSTGRESDB_DATABASE 2>/dev/null || true)"
[ -n "$N8N_DB_NAME" ] || N8N_DB_NAME=n8n
# DOMAIN aus der Env oder dem Merge-Store core.env (Env gewinnt, Muster wie _apikey unten) — sonst saehe ein
# standalone `lifeagents doctor` die Domain nie und der Ingress-Check skippte immer.
DOMAIN="${DOMAIN:-$(read_env_value /etc/lifeagents/core.env DOMAIN 2>/dev/null || true)}"
DOMAIN="$(normalize_domain "$DOMAIN")"   # nur im Speicher (doctor ist read-only): eine von Hand eingefuegte URL zaehlt schon jetzt

_fail=0
_pass() { printf '  [ OK ] %s\n' "$*"; }
_red()  { printf '  [FAIL] %s\n' "$*"; _fail=$((_fail+1)); }
_skip() { printf '  [SKIP] %s\n' "$*"; }
_warn() { printf '  [WARN] %s\n' "$*"; }   # Hinweis, zaehlt nicht als Fehler (optionale Funktion fehlt)

svc_active() {
  local unit="$1" label="$2"
  if svc_is_active "$unit"; then _pass "$label aktiv ($unit)"; else _red "$label NICHT aktiv ($unit)"; fi
}

# _doctor_app_check <webhook-base> <app-path> [telegram_ok] — die Seite je Adressfamilie ueber die Domain abrufen und
#   mit dem lokalen n8n vergleichen (common.sh reach_family/reach_assess, dieselbe Pruefung wie der Installer; Body statt
#   Statuscode: FritzBox/Home Assistant antworten auch 200). Typischer Befund: die MyFRITZ!-Adresse hat per IPv6 die
#   FritzBox selbst (aus dem Heimnetz ihre Oberflaeche, von unterwegs der Fernzugang). Nur WARN/SKIP, nie ROT.
_doctor_app_check() {
  local base="$1" app="$2" tg="${3:-0}" host ref r4 r6 kind text fams=''
  host="${base#https://}"; host="${host%%/*}"; host="${host%%:*}"
  ref="$(http_fp "http://127.0.0.1:${N8N_PORT}/webhook/${app}")"
  case "$ref" in
    200\|*) ;;
    *) _warn "Übersicht (Mini-App): n8n liefert die Seite nicht aus (HTTP ${ref%%|*}) — 'lifeagents update' ausführen; der Chat ist davon nicht betroffen"; return 0 ;;
  esac
  if ! need_cmd node; then _skip "Übersicht-Check über die Domain (node fehlt für die DNS-Abfrage)"; return 0; fi
  r4="$(N8N_URL="http://127.0.0.1:${N8N_PORT}" reach_family "$base" "/webhook/${app}" 4)"
  r6="$(N8N_URL="http://127.0.0.1:${N8N_PORT}" reach_family "$base" "/webhook/${app}" 6)"
  if [ "$r4" = noaddr ] && [ "$r6" = noaddr ]; then _warn "Übersicht: die Domain ${host} hat im DNS keine Adresse"; return 0; fi
  reach_assess "$r4" "$r6" "$tg" "$host"
  [ "$r4" = ok ] && fams='IPv4'
  [ "$r6" = ok ] && fams="${fams:+$fams + }IPv6"
  [ "$r6" = noaddr ] && fams="${fams:+$fams; }kein IPv6-Eintrag"
  while IFS=$'\t' read -r kind text; do
    case "$kind" in
      bad)  _warn "Übersicht: ${text}" ;;
      info) _skip "Übersicht: ${text}" ;;
    esac
  done <<<"$REACH_LINES"
  if [ "$REACH_BAD" = 1 ]; then _warn "Übersicht — Abhilfe: ${REACH_HINT}"
  elif [ "$r4" = ok ] || [ "$r6" = ok ]; then _pass "Übersicht (Mini-App) lädt über ${base}/webhook/… (${fams})"; fi
}

# _doctor_compose_tick — Docker-Verbund: lebt die Tick-Schleife des master (Ersatz der Update-Timer)? Ein offener
#   master-Wechsel ohne laufenden Helfer, der aelter als 30 Minuten ist, haengt (lib/master_swap.sh).
_doctor_compose_tick() {
  local st=/var/lib/lifeagents/update-tick.state last age swap=/var/lib/lifeagents/master-swap/state
  if [ "$(id -u)" -ne 0 ]; then _skip "Update-Schleife im master (braucht root)"; return 0; fi
  last="$(read_env_value "$st" LAST_TICK 2>/dev/null || true)"
  case "$last" in
    ''|*[!0-9]*)
      # Direkt nach der Installation (Abschlusspruefung) laeuft die Schleife erst mit dem naechsten Durchlauf an.
      if [ -n "$(find "$(lifeagents_version_marker)" -mmin -10 2>/dev/null)" ]; then
        _warn "Update-Schleife im master startet mit dem nächsten Durchlauf (höchstens 1 min)"
      else _red "Update-Schleife im master lief noch nie — Updates aus dem Chat kommen nicht an (docker logs ${LA_PROJECT}-master)"; fi ;;
    *) age=$(( $(date -u +%s) - last ))
       if [ "$age" -le 300 ]; then _pass "Update-Schleife im master läuft (letzter Durchlauf vor ${age} s)"
       else _red "Update-Schleife im master steht seit $((age / 60)) min — Updates aus dem Chat kommen nicht an (docker logs ${LA_PROJECT}-master)"; fi ;;
  esac
  if [ -f "$swap" ] && ! rt_swap_helper_running && [ -n "$(find "$swap" -mmin +30 2>/dev/null)" ]; then
    _red "Ein master-Wechsel (Update) ist seit über 30 min offen — Verlauf: docker logs ${LA_PROJECT}-master"
  fi
}

# _doctor_backup — Alter der letzten gelungenen Sicherung (backup.state). Verbund: ROT ab BACKUP_STALE_S (dort gibt es nur
#   die taegliche Sicherung in den Rechner-Ordner, fehlt sie, merkt es sonst niemand); LXC: WARN (Sicherung per export/crontab
#   ist dort Sache des Owners). Eine frische Installation (VERSION juenger als die Frist) ist noch nicht veraltet.
_doctor_backup() {
  local ok_at age days reason folder fix
  if [ "$(id -u)" -ne 0 ]; then _skip "Letzte Sicherung (braucht root)"; return 0; fi
  ok_at="$(read_env_value "$BACKUP_STATE_FILE" LAST_OK 2>/dev/null || true)"; case "$ok_at" in ''|*[!0-9]*) ok_at=0 ;; esac
  reason="$(read_env_value "$BACKUP_STATE_FILE" LAST_FAIL_REASON 2>/dev/null || true)"
  folder="$(read_env_value "$(lifeagents_env_file core)" BACKUP_HOST_DIR 2>/dev/null || true)"
  age=$(( $(date +%s) - ok_at )); days=$(( age / 86400 ))
  if [ "$ok_at" -gt 0 ] && [ "$age" -le "$BACKUP_STALE_S" ]; then
    if [ "$days" -eq 0 ]; then _pass "Letzte Sicherung: heute${folder:+ (Ordner auf dem Rechner)}"; else _pass "Letzte Sicherung: vor ${days} Tag(en)"; fi
    return 0
  fi
  # Frische Installation (VERSION juenger als die Frist): noch nicht veraltet. Im Verbund ohne Ordner (nur ueber eine
  # unbeaufsichtigte Installation ohne Fragebogen erreichbar, z. B. CI) nur WARN — ROT erst nach der Frist.
  if [ "$ok_at" -eq 0 ] && [ -n "$(find "$(lifeagents_version_marker)" -mmin -"$(( BACKUP_STALE_S / 60 ))" 2>/dev/null)" ]; then
    if rt_is_compose && [ -z "$folder" ]; then _warn "Letzte Sicherung: noch keine — kein Sicherungsordner gewählt: Start-App › Sicherungsordner ändern … (oder lifeagents backup host-dir <ordner> --create)"
    else _pass "Letzte Sicherung: noch keine erfasst (Installation oder Update ist frisch)"; fi
    return 0
  fi
  local when; if [ "$ok_at" -gt 0 ]; then when="vor ${days} Tagen"; else when="noch keine"; fi
  if rt_is_compose; then
    case "$reason" in
      nofolder|'') [ -n "$folder" ] || { _red "Letzte Sicherung: ${when} — kein Sicherungsordner gewählt: Start-App › Sicherungsordner ändern … (oder lifeagents backup host-dir <ordner> --create; Anleitung: ${BACKUP_GUIDE_URL})"; return 0; } ;;
    esac
    case "$reason" in
      folder) fix="der Ordner ist nicht erreichbar — prüfen oder neu wählen: Start-App › Sicherungsordner ändern …" ;;
      write)  fix="in den Ordner lässt sich nicht schreiben (voll oder schreibgeschützt)" ;;
      *)      fix="Verlauf: docker logs ${LA_PROJECT}-master" ;;
    esac
    _red "Letzte Sicherung: ${when} — ${fix}"
  else
    _warn "Letzte Sicherung: ${when} — lifeagents backup export (Anleitung: ${BACKUP_GUIDE_URL})"
  fi
}

# _doctor_compose_pod <bind> — Docker-Verbund: (1) alle Pod-Container im Netz-Namensraum des anchor (nach einem
#   `docker restart` des anchor haengen sie sonst an einem toten Namensraum, Einwand 17), (2) Netz-Grenze von aussen.
_doctor_compose_pod() {
  local anchor ns c n bad='' p
  anchor="$(rt_netns "${LA_PROJECT}-anchor" || true)"
  if [ -z "$anchor" ]; then
    _red "anchor-Container läuft nicht — der ganze Verbund ist ohne Netz (Start-App: Neu starten)"
  else
    for c in postgres n8n gateway master; do
      rt_container_running "${LA_PROJECT}-${c}" || continue   # laeuft nicht: melden die Dienst-Pruefungen
      ns="$(rt_netns "${LA_PROJECT}-${c}" || true)"
      [ "$ns" = "$anchor" ] || bad="${bad:+${bad}, }${c}"
    done
    if [ -n "$bad" ]; then
      _red "Netz-Namensraum getrennt (${bad}) — der anchor wurde einzeln neu gestartet. Abhilfe: in der Start-App Neu starten (docker compose -p ${LA_PROJECT} restart anchor — startet die Pod-Container danach mit)"
    else
      _pass "Pod teilt einen Netz-Namensraum (anchor, postgres, n8n, gateway, master)"
    fi
  fi
  # Rand: tailscale haengt per network_mode am Namensraum von edge — wird edge neu angelegt (z. B. anderer Port), bleibt
  # tailscale sonst an einem toten Namensraum haengen (derselbe Einwand 17).
  if rt_container_running "${LA_PROJECT}-tailscale"; then
    if [ "$(rt_netns "${LA_PROJECT}-tailscale" || true)" = "$(rt_netns "${LA_PROJECT}-edge" || echo x)" ]; then
      _pass "tailscale teilt den Netz-Namensraum des Rands"
    else
      _red "tailscale hängt nicht mehr am Rand (edge wurde neu angelegt) — Abhilfe: docker compose -p ${LA_PROJECT} restart tailscale (hängt sich beim Start an den aktuellen Rand)"
    fi
  fi
  if rt_probe_internal "$N8N_PORT"; then _pass "Rand erreicht n8n (gemessen aus dem internen Netz, n8n bindet $1 im Verbund)"
  else _red "Rand erreicht n8n nicht — Telegram und Mini-App kommen nicht an (gemessen aus dem internen Netz)"; fi
  local open=0
  for p in 5432 8090; do
    if rt_probe_internal "$p"; then
      open=1; n="PostgreSQL"; [ "$p" = 8090 ] && n="LLM-Gateway"
      _red "${n} (Port ${p}) ist aus dem internen Netz erreichbar — muss nur im Verbund lauschen (127.0.0.1)"
    fi
  done
  [ "$open" -eq 1 ] || _pass "PostgreSQL und LLM-Gateway von außen nicht erreichbar (gemessen)"
  # FritzBox-Weg: Antwort über die Adresse des Rechners; bei Ausbleiben startet reach_lan_doctor wan einmal neu.
  local lvl txt
  while IFS=$'\t' read -r lvl txt; do
    case "$lvl" in pass) _pass "$txt" ;; warn) _warn "$txt" ;; red) _red "$txt" ;; esac
  done <<<"$(reach_lan_doctor)"
}

main() {
  printf 'Diagnose — n8n-life-agents Provisioning\n'

  # --- disk ---
  local avail_mb
  avail_mb="$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -n "$avail_mb" ] && [ "$avail_mb" -ge 500 ]; then _pass "Freier Speicher /: ${avail_mb} MB"
  else _red "Wenig/kein freier Speicher /: ${avail_mb:-?} MB"; fi

  # --- PostgreSQL ---
  svc_active postgresql "PostgreSQL"
  if pg_ready 2>/dev/null; then _pass "PostgreSQL nimmt Verbindungen an"
  else _red "PostgreSQL pg_isready negativ"; fi
  # Laufende Minor != installierte Minor: der alte Server haelt noch die alte Bibliothek, das Paket brachte die neue
  # (Neustart blieb aus, install_pg.sh pg_restart_if_stale). Nur LXC + root (Peer-Auth); sonst still.
  if [ "$(id -u)" -eq 0 ]; then
    local _pgv _pgrun="" _pginst=""; _pgv="$(pg_server_versions)"; read -r _pgrun _pginst <<<"$_pgv"
    if pg_minor_stale "$_pgrun" "$_pginst"; then
      _warn "PostgreSQL läuft noch in Version ${_pgrun}, installiert ist ${_pginst} — ein Neustart steht aus (Abhilfe: 'lifeagents update' oder 'systemctl restart postgresql')"
    fi
  fi
  # UTF-8 ist Gesetz (provisioning/CLAUDE.md): in einer SQL_ASCII-DB sind Umlaute nur Bytes (Proxmox-Vorlage
  # LANG="C"). Lesen braucht root (Peer-Auth als postgres) -> sonst SKIP statt Fehl-ROT.
  if [ "$(id -u)" -eq 0 ]; then
    local _enc
    _enc="$(pg_db_encoding "$N8N_DB_NAME")"
    if [ "$_enc" = "UTF8" ]; then _pass "Datenbank '${N8N_DB_NAME}' in UTF-8"
    elif [ -n "$_enc" ]; then _red "Datenbank '${N8N_DB_NAME}' ist ${_enc} statt UTF-8 — Umlaute werden falsch gespeichert (Abhilfe: Meldung von 'lifeagents update')"
    else _skip "Datenbank-Kodierung: '${N8N_DB_NAME}' nicht lesbar"; fi
  else _skip "Datenbank-Kodierung: nur als root prüfbar"; fi

  # --- n8n ---
  svc_active n8n "n8n"
  # readiness = DB verbunden und migriert (nach einem Versionssprung erst nach den Migrationen gruen).
  if curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${N8N_PORT}/healthz/readiness" 2>/dev/null; then
    _pass "n8n bereit (http://127.0.0.1:${N8N_PORT}/healthz/readiness)"
  else _red "n8n meldet sich nicht bereit (Port ${N8N_PORT}) — $(svc_logs_hint n8n)"; fi
  # Installierte Version gegen den Pin des installierten Baums (eine Adresse: provision.sh) + Node.
  local _pin _have
  # shellcheck disable=SC2016  # $ ist hier ein Literal im sed-Muster (die Default-Zeile von provision.sh)
  _pin="$(sed -n 's/^N8N_VERSION="\${N8N_VERSION:-\(.*\)}"$/\1/p' "$SCRIPT_DIR/provision.sh" 2>/dev/null || true)"
  _have="$(n8n_exec n8n --version 2>/dev/null || true)"
  if [ -n "$_pin" ] && [ -n "$_have" ] && [ "$_pin" != "$_have" ]; then
    _red "n8n ${_have} installiert, erwartet ${_pin} — 'lifeagents update' erneut starten"
  elif [ -n "$_have" ]; then
    _pass "n8n ${_have} · Node.js $(n8n_exec node -v 2>/dev/null || printf '?')"
  fi
  # n8n-Korrekturen (lib/n8n_patches.sh): aktiv = gruen; Zeile von n8n geaendert = Hinweis (vermutlich behoben,
  # Patch pruefen); Original noch da oder unbekannte Fassung = ROT (der Fehler wirkt im Betrieb).
  if n8n_present; then
    local _pid _pst
    while IFS= read -r _pid; do
      [ -n "$_pid" ] || continue
      _pst="$(n8n_patch_status "$_pid")"
      case "$_pst" in
        patched)  _pass "n8n-Korrektur '${_pid}' aktiv" ;;
        changed)  if n8n_patch_must_stay "$_pid"; then _red "n8n-Korrektur '${_pid}': n8n hat die Stelle geändert, die Korrektur fehlt — Patch an die n8n-Version anpassen"
                  else _warn "n8n-Korrektur '${_pid}': n8n hat die Stelle geändert (vermutlich behoben) — Patch prüfen/entfernen"; fi ;;
        original) _red "n8n-Korrektur '${_pid}' fehlt — 'lifeagents update' erneut starten" ;;
        *)        _red "n8n-Korrektur '${_pid}': ${_pst} (Datei unbekannt/fehlt) — nicht gepatcht, Patch an die n8n-Version anpassen" ;;
      esac
    done < <(n8n_patch_ids)
  fi
  # Ein unvollendetes Update (upgrade_guard.sh-Merkzettel) — der naechste 'lifeagents update' setzt es fort.
  if [ -f /var/lib/lifeagents/upgrade.pending ]; then
    _red "Ein Update wurde nicht abgeschlossen — 'lifeagents update' erneut starten (setzt mit der vorhandenen Sicherung fort)"
  fi

  # --- Update im Chat (lib/install_update_timers.sh + lib/update_runner.sh) ---
  if rt_is_compose; then
    # Verbund: statt der Timer laeuft die Tick-Schleife im master (compose.yml, update_runner.sh update_tick).
    _doctor_compose_tick
  else
    svc_active lifeagents-update-check.timer "Release-Check alle 2 Stunden"
    svc_active lifeagents-update-run.timer "Update-Aufträge aus dem Chat"
  fi
  _doctor_backup
  if [ "$(id -u)" -eq 0 ] && need_su_tools; then
    local _stuck _lastfail _help _runner_log="journalctl -u lifeagents-update-run -n 50"
    if rt_is_compose; then _runner_log="docker logs ${LA_PROJECT}-master"; fi
    # Haengender Auftrag: offen seit > 60 min und die Update-Sperre ist frei (sonst laeuft er gerade wirklich).
    _stuck="$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c \
      "SELECT id FROM core.update_requests WHERE finished_at IS NULL AND requested_at < now() - interval '60 minutes' LIMIT 1" 2>/dev/null || true)"
    if [ -n "$_stuck" ] && update_lock_free; then
      _red "Update-Auftrag ${_stuck} hängt seit über einer Stunde — der Runner läuft nicht (${_runner_log})"
    fi
    # Das letzte Update der letzten 7 Tage ist gescheitert -> dieselbe Hilfe wie im Chat (core.fn_update_report).
    _lastfail="$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c \
      "SELECT id FROM (SELECT id, outcome FROM core.update_requests WHERE finished_at > now() - interval '7 days'
                        ORDER BY finished_at DESC, id DESC LIMIT 1) l
        WHERE outcome IN ('partial','held','failed','interrupted')" 2>/dev/null || true)"
    if [ -n "$_lastfail" ]; then
      _help="$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c \
        "SELECT core.fn_update_report(jsonb_build_object('request_id', ${_lastfail}::bigint, 'phase', 'result', 'bot_up', true))->>'text'" 2>/dev/null || true)"
      _warn "Das letzte Update hat nicht vollständig geklappt:"
      printf '%s\n' "$_help" | sed 's/^/         /'
    fi
    # Menue-Auftrag der Uebersicht (core.menu_refresh): derselbe Runner setzt die Knoepfe nach Kopplung/Sprachwechsel;
    # offen seit > 30 min = der Runner laeuft nicht; aufgegeben (3 Fehlschlaege in Folge) = Telegram lehnt einen Chat ab.
    if [ -n "$(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c \
          "SELECT 1 FROM core.menu_refresh WHERE (requested_gen > done_gen AND requested_at < now() - interval '30 minutes')
              OR gave_up_at > now() - interval '7 days'" 2>/dev/null || true)" ]; then
      _warn "Übersicht-Knöpfe nicht vollständig nachgezogen (Kopplung/Sprache geändert, Telegram lehnte ab) — ${_runner_log}"
    fi
  fi

  # --- LLM-Gateway (lib/install_llm_gateway.sh): alle Claude-Aufrufe laufen darueber -> Ausfall = ROT ---
  svc_active lifeagents-llm-gateway "LLM-Gateway"
  if curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:8090/__health" 2>/dev/null; then   # Port fest (install_llm_gateway.sh)
    _pass "LLM-Gateway Health OK (Prompt-Caching aktiv)"
  else _red "LLM-Gateway antwortet nicht — kein Agent erreicht Claude. Diagnose: $(svc_logs_hint lifeagents-llm-gateway 50)"; fi
  # fallback = Anthropic lehnte die Cache-Haltepunkte ab, Anfrage lief ohne Caching (teurer, aber funktionsfaehig).
  if [ "$(id -u)" -eq 0 ]; then
    local _fb
    _fb="$(svc_journal_since lifeagents-llm-gateway '-24h' | grep -c '"fallback":true' || true)"
    if [ "${_fb:-0}" -gt 0 ]; then
      _warn "LLM-Gateway: ${_fb} Anfrage(n) in 24 h ohne Caching wiederholt (Anthropic lehnte die Haltepunkte ab) — journalctl -u lifeagents-llm-gateway"
    fi
  fi

  # --- Netzwerk: Bind + Firewall passen zu TRUSTED_PROXIES ---
  # Gefaehrlich ist nur ein Zustand: n8n lauscht im Heimnetz (0.0.0.0) ohne die Freigabe-Tabelle (z. B. nach
  # einem manuellen `nft -f` mit flush ruleset) -> ROT. Proxy auf anderem Rechner eingetragen, aber n8n nur lokal
  # -> ROT (der Proxy bekommt 502). Ohne root ist die Tabelle nicht lesbar -> SKIP.
  local _tp _tp_list _tp_nonloop _bind _tp_show
  _tp="${TRUSTED_PROXIES:-$(read_env_value /etc/lifeagents/core.env TRUSTED_PROXIES 2>/dev/null || true)}"
  _bind="$(read_env_value "$N8N_ENV_FILE" N8N_LISTEN_ADDRESS 2>/dev/null || true)"
  if rt_is_compose; then
    # Verbund: ein Netz-Namensraum fuer den ganzen Pod, und die Grenze von aussen gemessen — ein
    # Kurzlauf-Container im internen Netz sieht, was der Rand sieht: n8n ja, Postgres und Gateway nein.
    _doctor_compose_pod "${_bind:-0.0.0.0}"
  elif ! _tp_list="$(normalize_trusted_proxies "$_tp" 2>/dev/null)"; then
    _red "TRUSTED_PROXIES ungültig ('${_tp}') — korrigieren: lifeagents proxy set <IP des Proxy-Rechners>"
  else
    _tp_nonloop="$(_proxy_nonloop "$_tp_list")"
    _tp_show="$(printf '%s' "$_tp_nonloop" | paste -sd, - | sed 's/,/, /g')"
    if [ -z "$_tp_nonloop" ]; then
      if [ "${_bind:-127.0.0.1}" = "127.0.0.1" ]; then _pass "n8n nur lokal erreichbar (Reverse Proxy auf diesem Rechner)"
      else _red "n8n lauscht auf ${_bind}, obwohl kein Proxy auf einem anderen Rechner eingetragen ist — lifeagents proxy set 127.0.0.1"; fi
    else
      if [ "$_bind" != "0.0.0.0" ]; then
        _red "Proxy auf anderem Rechner (${_tp_show}) eingetragen, aber n8n lauscht nur lokal — der Proxy bekommt 502 (Firewall ließ sich nicht einrichten?). Erneut: lifeagents proxy set ${_tp_list}"
      elif [ "$(id -u)" -ne 0 ]; then
        _skip "Firewall-Prüfung (braucht root: sudo lifeagents doctor)"
      elif svc_is_active "$LA_FW_UNIT_NAME" && firewall_set_matches "$_tp_list"; then
        _pass "Firewall aktiv: n8n (Port ${N8N_PORT}) nur für ${_tp_show}"
      else
        _red "Firewall fehlt oder weicht ab — n8n lauscht im Heimnetz ohne passende Freigabe. Sofort: lifeagents proxy set ${_tp_list}"
      fi
    fi
  fi

  # --- Credential-Dubletten (read-only; id-Churn-Symptom / Versions-Pin-Backstop) ---
  # Je (name,type) genau eine Credential erwartet. >1 = ein n8n-Bump, der den import:credentials-Upsert
  # auf id-Match bricht (dann akkumulieren Dubletten).
  # API-Key aus core.env; fehlt er / n8n nicht erreichbar -> SKIP (nicht ROT).
  local _apikey _dups
  _apikey="$(read_env_value /etc/lifeagents/core.env N8N_API_KEY 2>/dev/null || true)"
  if [ -n "$_apikey" ] && need_cmd jq; then
    _dups="$(n8n_api_curl "$_apikey" "http://127.0.0.1:${N8N_PORT}/api/v1/credentials?limit=250" -fsS --max-time 5 \
              2>/dev/null \
              | jq -r '[.data[]? | [.name,.type]] | group_by(.) | map(select(length>1)) | length' 2>/dev/null || true)"
    if [ -z "$_dups" ]; then _skip "Credential-Dubletten-Check (n8n-API nicht erreichbar)"
    elif [ "$_dups" = "0" ]; then _pass "Keine Credential-Dubletten (id-stabil)"
    else _red "${_dups} Credential-Name/Typ mehrfach vorhanden (id-Churn? je Name genau EINE erwartet)"; fi
  else
    _skip "Credential-Dubletten-Check (kein N8N_API_KEY in core.env / kein jq)"
  fi

  # --- deklarierte Paket-Secrets (manifest `credentials`-Block, docs/package-contract.md §3.8) ---
  # Je installiertem Paket die deklarierten env-Keys gegen den Store pruefen: required fehlt/leer -> ROT mit
  # woertlichem Abhilfe-Kommando; optional fehlt/leer -> Hinweis (kein FAIL — Quelle degradiert graceful).
  # Ohne root sind die 640-env-Files nicht lesbar -> SKIP statt Fehl-ROT (doctor braucht kein root).
  local _pkgroot="${LIFEAGENTS_LIB:-/usr/local/lib/lifeagents}/packages"
  # "Installiert" = Zeile in core.package_registry (eine Wahrheit, wie `lifeagents update`/package list; die
  # Datei /etc/lifeagents/<pkg>.env allein meldete nach `uninstall --keep-data` ROT fuer ein nicht installiertes
  # Paket). Ohne root (kein DB-Zugriff) faellt der Check auf die Datei-Heuristik zurueck.
  local _installed=''
  if [ "$(id -u)" -eq 0 ] && need_su_tools; then
    _installed=" $(pg_su_psql -X -tA -d "$N8N_DB_NAME" -c "SELECT package FROM core.package_registry" 2>/dev/null | tr '\n' ' ' || true)"
  fi
  if need_cmd jq && [ -d "$_pkgroot" ]; then
    local _mf _pkg _envf _entry _cname _req _keys _k _v _miss _ncred _nok
    for _mf in "$_pkgroot"/*/manifest.json; do
      [ -r "$_mf" ] || continue
      _pkg="$(jq -r '.name // empty' "$_mf" 2>/dev/null || true)"
      [ -n "$_pkg" ] || continue
      jq -e '(.credentials // {}) | [to_entries[] | select(.key != "_comment")] | length > 0' "$_mf" >/dev/null 2>&1 || continue
      _envf="/etc/lifeagents/${_pkg}.env"
      if [ "${#_installed}" -gt 1 ]; then
        case "$_installed" in *" $_pkg "*) : ;; *) _skip "Paket-Secrets ($_pkg): Paket nicht installiert"; continue ;; esac
        [ -e "$_envf" ] || { _red "Paket-Secrets ($_pkg): $_envf fehlt, obwohl das Paket installiert ist — Abhilfe: lifeagents package reconfigure $_pkg"; continue; }
      else
        [ -e "$_envf" ] || { _skip "Paket-Secrets ($_pkg): Paket nicht installiert ($_envf fehlt)"; continue; }
      fi
      if [ ! -r "$_envf" ]; then _skip "Paket-Secrets ($_pkg): $_envf nicht lesbar (doctor ohne root)"; continue; fi
      _ncred=0; _nok=0
      while IFS= read -r _entry; do
        [ -n "$_entry" ] || continue
        _ncred=$((_ncred+1))
        _cname="$(jq -r '.value.name' <<<"$_entry")"
        _req="$(jq -r '.value.required // false' <<<"$_entry")"
        _keys="$(jq -r '.value.env | keys[]' <<<"$_entry")"
        _miss=''
        while IFS= read -r _k; do
          [ -n "$_k" ] || continue
          _v="$(read_env_value "$_envf" "$_k" || true)"
          [ -n "$_v" ] || _miss="${_miss}${_miss:+/}$_k"
        done <<<"$_keys"
        if [ -z "$_miss" ]; then
          _nok=$((_nok+1))
        elif [ "$_req" = "true" ]; then
          _red "Pflicht-Secret fuer '$_cname' ($_pkg) fehlt/leer: $_miss — Abhilfe: lifeagents package reconfigure $_pkg"
        else
          _skip "Optionales Credential '$_cname' ($_pkg) ohne $_miss — Quelle inaktiv (nachtragen: lifeagents package reconfigure $_pkg)"
        fi
      done <<<"$(jq -c '(.credentials // {}) | to_entries[] | select(.key != "_comment")' "$_mf" 2>/dev/null)"
      # if-Form statt &&-Kette: eine falsche &&-Bedingung als letzte Loop-Anweisung wuerde unter set -e das
      # ganze doctor.sh still beenden (dieselbe Falle wie provision.sh::parse_args).
      if [ "$_nok" -gt 0 ]; then _pass "Paket-Secrets ($_pkg): ${_nok}/${_ncred} Credential(s) konfiguriert"; fi
    done
  fi

  # --- Grund-Zugaenge (Paritaet zum Paket-Pflicht-Secret-Check oben) ---
  # Laufzeit-Teilmenge der Pflicht-Host-Keys (release_inputs.sh _REQUIRED_HOST_KEYS; Name/Geburtsdatum braucht nur das
  # Pairing): ohne Telegram-Token kein Chat, ohne Anthropic-Schluessel denkt kein Agent (ROT); ohne Google-Schluessel nur
  # keine Sprachnachrichten (WARN, optional). Nur Release-Instanzen (dev/CI laufen bewusst ohne); ohne root ist
  # core.env nicht lesbar -> SKIP. Gate auf das Verzeichnis: /etc/lifeagents ist 0750 root:n8n, ohne Gruppenrecht
  # scheitert schon `-e` auf die Datei (die SKIP-Zeile fiele sonst still weg).
  local _ce=/etc/lifeagents/core.env _gmiss=''
  if [ -d /etc/lifeagents ] && [ "$(id -u)" -ne 0 ] && [ ! -r "$_ce" ]; then
    _skip "Grund-Zugänge (braucht root: sudo lifeagents doctor)"
  elif [ -r "$_ce" ] && [ "$(read_env_value "$_ce" INSTALL_PROFILE 2>/dev/null || true)" = "release" ]; then
    [ -n "$(read_env_value "$_ce" TELEGRAM_BOT_TOKEN 2>/dev/null || true)" ] || _gmiss="Telegram-Bot-Token"
    [ -n "$(read_env_value "$_ce" ANTHROPIC_API_KEY 2>/dev/null || true)" ] || _gmiss="${_gmiss:+$_gmiss, }Anthropic-API-Schlüssel"
    if [ -z "$_gmiss" ]; then _pass "Grund-Zugänge gesetzt (Telegram-Bot-Token, Anthropic-API-Schlüssel)"
    else _red "Grund-Zugang fehlt: ${_gmiss} — ohne ihn bleibt der Bot stumm. Abhilfe: lifeagents reconfigure"; fi
    if [ -z "$(read_env_value "$_ce" GOOGLE_API_KEY 2>/dev/null || true)" ]; then
      _warn "Kein Google-API-Schlüssel — Sprachnachrichten sind aus (optional). Einrichten: lifeagents reconfigure"
    fi
  fi

  # --- env file integrity (encryption key present + tight perms) ---
  if [ -f "$N8N_ENV_FILE" ]; then
    if read_env_value "$N8N_ENV_FILE" N8N_ENCRYPTION_KEY >/dev/null; then _pass "Encryption-Key in $N8N_ENV_FILE gesetzt"
    else _red "N8N_ENCRYPTION_KEY fehlt in $N8N_ENV_FILE"; fi
    local perms; perms="$(stat -c '%a' "$N8N_ENV_FILE" 2>/dev/null || echo '?')"
    case "$perms" in 600|640|660) _pass "Env-Datei-Rechte ${perms}" ;; *) _red "Env-Datei-Rechte zu offen: ${perms} (erwartet 640)" ;; esac
  else _red "Env-Datei fehlt: $N8N_ENV_FILE"; fi

  # --- Ingress-Gesundheit (proxy-agnostisch) ---
  # Der HTTPS-Reverse-Proxy ist bring-your-own -> doctor prueft nicht, welcher Terminierer laeuft, sondern das
  # Outcome. Beide Checks nur bei gesetzter Domain (= Public-Ingress erwartet, Release): ohne Domain gibt es
  # keinen oeffentlichen Eingang (dev/Substrat — die Tiers feuern ueber die Harness-Webhooks, nicht ueber
  # Telegram), ein inaktiver Orchestrator ist dort der Normalfall -> SKIP statt Fehl-ROT.
  # CLI-Tunnel (lib/reach_cli.sh): steht der Tailscale-Weg selbst? Auch ohne Domain (die kommt erst mit der Anmeldung).
  if ! rt_is_compose && [ "$(reach_cli_mode)" = tunnel ]; then
    local _lvl _txt
    while IFS=$'\t' read -r _lvl _txt; do
      case "$_lvl" in pass) _pass "$_txt" ;; warn) _warn "$_txt" ;; red) _red "$_txt" ;; esac
    done <<<"$(reach_cli_doctor "$N8N_PORT")"
  fi
  # Gleiche Pruefung wie der Pairing-Abschluss: ein verbundener Owner, dessen Workflows noch chat_id 0 tragen, bekommt keine Karten.
  if [ -n "$_apikey" ] && need_cmd jq; then
    local _owner_chat _ph_left
    _owner_chat="$(_owner_chat_id_db)"
    if [ -z "$_owner_chat" ]; then _skip "Owner-chat_id in den Workflows (Owner noch nicht verbunden)"
    elif ! _ph_left="$(N8N_API_KEY="$_apikey" N8N_URL="http://127.0.0.1:${N8N_PORT}" owner_chat_placeholder_count)"; then _skip "Owner-chat_id in den Workflows (n8n-API nicht erreichbar)"
    elif [ "$_ph_left" -eq 0 ]; then _pass "Owner-chat_id in allen Workflows eingetragen"
    else _red "${_ph_left} Telegram-Schritt(e) tragen noch die Platzhalter-chat_id 0 — Bestätigungen scheitern mit 'chat not found'. Abhilfe: lifeagents household pair-owner"; fi
  else
    _skip "Owner-chat_id in den Workflows (kein N8N_API_KEY in core.env / kein jq)"
  fi

  if [ -n "$DOMAIN" ]; then
    # (1) Kern-Check: ist der Orchestrator-Trigger aktiv? Nur dann hat n8n den Telegram-Webhook registriert
    # -> nur dann erreicht Telegram den Bot. `_apikey` wurde oben gelesen (function-local). SKIP ohne
    # Key/jq/API (Muster wie Dubletten).
    if [ -n "$_apikey" ] && need_cmd jq; then
      local _orch_state _orch_active
      # Geteilter Helfer (common.sh, auch vom gefuehrten Ende owner_connect.sh genutzt): "<id>\t<active>".
      _orch_state="$(n8n_orchestrator_state "$_apikey" "http://127.0.0.1:${N8N_PORT}")"
      _orch_active="${_orch_state#*$'\t'}"
      if [ -z "$_orch_state" ]; then _skip "Orchestrator-Aktiv-Check (n8n-API nicht erreichbar / Workflow fehlt)"
      elif [ "$_orch_active" = "true" ]; then _pass "Orchestrator-Trigger aktiv (Telegram-Webhook registriert)"
      else _red "Orchestrator-Trigger INAKTIV — Telegram erreicht den Bot nicht (Reverse Proxy live? dann: lifeagents reconfigure → Grundsystem → Unverändert neu anwenden; noch nie mit Telegram verbunden: lifeagents household pair-owner)"; fi
    else
      _skip "Orchestrator-Aktiv-Check (kein N8N_API_KEY in core.env / kein jq)"
    fi

    # (2) Public-HTTPS-Reachability: jede HTTP-Antwort (auch 404 = unser gesunder webhook-only /-Zustand)
    # heisst "TLS-Endpunkt + Reverse Proxy erreichbar". Nur 000 (kein TLS/keine Verbindung) -> SKIP
    # (DNS/Cert/Proxy/Port-Weiterleitung; transient -> nicht ROT, der Orchestrator-Check oben ist ROT-faehig).
    local _code
    _code="$(https_code "$DOMAIN")"
    if [ "$_code" != "000" ]; then _pass "HTTPS-Ingress erreichbar (${DOMAIN}, HTTP ${_code})"
    else _skip "HTTPS ${DOMAIN} nicht erreichbar — DNS/Cert/Reverse-Proxy/Port-Weiterleitung prüfen"; fi

    # (3) Telegrams Sicht (getWebhookInfo) — der lokale HTTPS-Test besteht auch bei Hairpin-NAT/Split-DNS,
    # waehrend Telegram von aussen nicht durchkommt. ROT nur, wenn Telegram Updates staut (pending > 0) und
    # der letzte Zustellfehler frisch ist (< 15 Min) — dann ist der Bot taub.
    local _tg_token _wh _wh_url _wh_pending _wh_err_date _wh_err _tg_ok=0
    _tg_token="$(read_env_value /etc/lifeagents/core.env TELEGRAM_BOT_TOKEN 2>/dev/null || true)"
    if [ -n "$_tg_token" ] && need_cmd jq; then
      _wh="$(tg_api_curl "$_tg_token" getWebhookInfo -fsS --max-time 10 2>/dev/null || true)"
      _wh_url="$(printf '%s' "$_wh" | jq -r '.result.url // ""' 2>/dev/null || true)"
      _wh_pending="$(printf '%s' "$_wh" | jq -r '.result.pending_update_count // 0' 2>/dev/null || echo 0)"
      _wh_err_date="$(printf '%s' "$_wh" | jq -r '.result.last_error_date // 0' 2>/dev/null || echo 0)"
      _wh_err="$(printf '%s' "$_wh" | jq -r '.result.last_error_message // ""' 2>/dev/null || true)"
      if [ -z "$_wh" ]; then _skip "Telegram-Webhook-Check (Telegram-API nicht erreichbar)"
      elif [ -z "$_wh_url" ]; then _red "Telegram kennt keine Webhook-Adresse — der Bot empfängt nichts (Reparatur: lifeagents reconfigure → Grundsystem → Unverändert neu anwenden; noch nie mit Telegram verbunden: lifeagents household pair-owner)"
      elif [ "${_wh_pending:-0}" -gt 0 ] 2>/dev/null && [ $(( $(date +%s) - ${_wh_err_date:-0} )) -lt 900 ] 2>/dev/null; then
        _red "Telegram kann den Bot nicht erreichen (${_wh_pending} Nachricht(en) warten): ${_wh_err:-unbekannter Fehler}"
      else _pass "Telegram stellt an ${_wh_url%%/webhook/*}/… zu"; fi
      # Nur wenn Telegram an genau diese Domain zustellt, gilt ein IPv4-Fehlschlag in (5) als Hairpin (neutral).
      if tg_webhook_delivers "$_wh" "$DOMAIN"; then _tg_ok=1; fi
    else
      _skip "Telegram-Webhook-Check (kein TELEGRAM_BOT_TOKEN in core.env / kein jq)"
    fi

    # (4) Bestaetigen im Chat: der Orchestrator-Trigger reicht jeden Knopf-Tipp an <WEBHOOK_URL>/webhook-waiting-
    # telegram weiter — vom Server selbst ueber die Domain (common.sh hitl_route_probe; read-only, pinnt nichts).
    # ROT nur, wenn die Chat-Knoepfe deployt sind (dann gingen Tipps still verloren); sonst WARN mit dem Weg dorthin.
    # Deploy-Modus = core.env HITL_CHAT_APPROVAL (deploy_workflows.sh haelt ihn fuer alle Workflows fest, ohne API).
    local _whurl _chat
    _whurl="$(read_env_value "$N8N_ENV_FILE" WEBHOOK_URL 2>/dev/null || true)"
    _chat="$(hitl_chat_state)"
    if [ -z "$_whurl" ]; then _skip "Bestätigen-im-Chat-Check (keine WEBHOOK_URL in ${N8N_ENV_FILE})"
    elif N8N_URL="http://127.0.0.1:${N8N_PORT}" hitl_route_probe "$_whurl"; then
      if [ "$_chat" = "true" ]; then _pass "Bestätigungs-Knöpfe im Chat erreichen n8n (${_whurl%/}${HITL_ROUTE_SUFFIX})"
      else _warn "Bestätigungs-Route erreichbar, Knöpfe aber noch als Webseiten-Link — 'lifeagents update' schaltet Bestätigen im Chat ein"; fi
    elif [ "$_chat" = "true" ]; then
      _red "Bestätigungs-Tipps erreichen n8n NICHT (${_whurl%/}${HITL_ROUTE_SUFFIX}) — jede Bestätigung läuft ins Leere. Reverse Proxy: ${HITL_ROUTE_SUFFIX} wie /webhook-waiting/* an n8n weiterleiten, dann 'lifeagents update'"
    else
      _warn "Bestätigen im Chat ist aus (Knöpfe öffnen eine Webseite): ${_whurl%/}${HITL_ROUTE_SUFFIX} erreicht n8n nicht — im Reverse Proxy ergänzen, dann 'lifeagents update'"
    fi

    # (5) Mini-App „Übersicht“ (docs/package-contract.md §3.12): Handy und Laptop oeffnen die Seite DIREKT ueber die
    # Domain, je Adressfamilie (Happy Eyeballs) — Telegram-Webhooks laufen nur ueber IPv4, ein falscher IPv6-Weg faellt
    # im Chat also nie auf. Darum je Familie getrennt pruefen (_doctor_app_check). Nur WARN: die App ist optional,
    # der Chat laeuft auch ohne sie. Nichts aendern, nur lesen (GET liefert eine statische Seite ohne Daten).
    local _app
    _app="$(_app_path)"
    if [ -z "$_whurl" ] || [ -z "$_app" ]; then _skip "Übersicht-Check (keine WEBHOOK_URL bzw. kein INGRESS_ID_KEY)"
    else _doctor_app_check "${_whurl%/}" "$_app" "$_tg_ok"; fi
  elif [ "$(reach_cli_mode)" = tunnel ]; then
    _skip "Noch keine Internet-Adresse — sie kommt mit der Tailscale-Anmeldung (Orchestrator-/HTTPS-Checks übersprungen)"
  else
    _skip "Kein Public-Ingress (keine Domain) — Orchestrator-/HTTPS-Checks übersprungen (dev/Substrat)"
  fi

  echo
  if [ "$_fail" -eq 0 ]; then ok "Diagnose: alle Checks grün."; else err "Diagnose: ${_fail} Check(s) ROT."; fi
  return "$_fail"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
