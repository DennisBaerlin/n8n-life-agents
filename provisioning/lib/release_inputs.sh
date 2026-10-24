# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) in den Nutzertexten sind gewollt, keine vertippten Shell-Quotes
# release_inputs.sh — Release-Eingaben sammeln + idempotent persistieren (Phase 6).
# Sourced by provision.sh (und von der lifeagents-CLI fuer reconfigure/package/config/…). Definiert
# load_install_env() + collect_release_inputs().
#
# ZWEI Quellen, env-override-first (Plan Phase 6: `${VAR:-$(prompt_if_tty)}`):
#   1. Prozess-Env (Dev/Test injiziert den .env-Test-Block; ein Re-Run mit gepinnten Werten).
#   2. /etc/lifeagents/core.env (unser Merge-Store = INSTALL_ENV_FILE, dieselbe Datei wie die Host/
#      Core-Secrets, per-Key gemergt; Secret-Modell §3.0a) — ein zweiter Lauf laedt die Werte des
#      ersten zurueck => KEIN erneutes Prompten = idempotent (Coolify-.env-Merge-Muster).
#   3. Sonst (nur Release + TTY): interaktiv per /dev/tty fragen. Unter `curl … | bash` ist stdin
#      die Pipe -> read MUSS aus /dev/tty lesen (sonst verschluckt es das Skript selbst).
#
# SELBST generiert (kein Prompt, openssl rand): N8N_ENCRYPTION_KEY + N8N_DB_PASSWORD
# (prepare_n8n_env/install_pg) + Owner-Init-Passwort (_resolve_owner_creds) + core.backup_key-Backup-
# Key (bootstrap_owner._ensure_backup_secret) + der Eingangs-Schluessel INGRESS_ID_KEY (bootstrap_owner._ensure_ingress_id_key;
# daraus leitet deploy_workflows die Trigger-ids ab, aus denen n8n beim Activate den secret_token <workflowId>_<nodeId> bildet). EXTERN abgefragt (hier): Domain, Telegram-Bot-Token,
# Google-/Anthropic-API-Key, Owner-Identitaet. Der Repo-Token fuer --version kommt in der
# Release-Asset-Phase dazu (separate Action).
#
# Reads/sets globals (provision.sh): INSTALL_ENV_FILE, N8N_USER, PROFILE, UNATTENDED, DOMAIN,
#   N8N_OWNER_EMAIL, OWNER_FIRST_NAME, OWNER_LAST_NAME, OWNER_BIRTH_DATE, TELEGRAM_BOT_TOKEN,
#   GOOGLE_API_KEY, ANTHROPIC_API_KEY.
#
# SEEN-MODELL (debconf-treu, Install-UX-Phase Spec C): ein Key gilt als "seen", wenn er eine
# KEY=-Zeile in core.env hat (auch mit LEEREM Wert = interaktiv angeboten + bewusst uebersprungen).
# _prompt_validated skippt seen-optionale Keys (fragt NIE erneut nach); ein NEUER Key eines Releases
# hat keine Zeile -> wird beim naechsten interaktiven Release-Lauf (Install ODER Update via
# INSTALL_PROFILE) genau einmal nachgefragt. Seen-Zeilen entstehen NUR in interaktiven Laeufen
# (unattended markiert nichts als gestellt — eine spaetere interaktive Sitzung darf fragen).
# PFLICHT-Keys (_REQUIRED_HOST_KEYS, Install-UX-Phase 7) kennen kein Seen-Gate: leer = erneut fragen.

# Die in core.env (INSTALL_ENV_FILE) gemergten HOST-Schluessel (Reihenfolge = Prompt-Reihenfolge).
# N8N_OWNER_PASSWORD = n8n-Admin-Login (nicht generierbar -> abfragen; persistiert fuer idempotente
# Re-Runs / Login-Reuse). Postgres-Passwoerter sind NICHT hier — die generiert der Installer selbst.
# PAKET-Secrets (z. B. die career-Job-Quellen Adzuna/JSearch) leben NICHT mehr hier: sie sind im
# jeweiligen packages/<pkg>/manifest.json `credentials`-Block deklariert (docs/package-contract.md
# §3.8), werden vom Stage-4-Wizard in pkg_install_one bzw. vorab von collect_package_inputs erfragt und in /etc/lifeagents/<pkg>.env
# persistiert (Naht-Rueckbau der Install-UX-Phase; contract_lint Naht-Guard blockt Rueckfaelle).
# OWNER_LANGUAGE = Sprache der festen Bot-Texte des Owners (Textkatalog; eigener Auswahl-Dialog _ask_owner_language,
# Vorauswahl Deutsch; leer/unattended -> bootstrap_owner nimmt 'de').
# OWNER_PERSONA = Bot-Charakter des Owners (Core-Manifest personas.list; eigener Auswahl-Dialog _ask_owner_persona,
# Vorauswahl Neutral; leer/unattended/ungueltig -> util_seed_owner_skeleton laesst den Key weg = neutral).
_INSTALL_ENV_KEYS="DOMAIN TRUSTED_PROXIES N8N_OWNER_EMAIL N8N_OWNER_PASSWORD OWNER_FIRST_NAME OWNER_LAST_NAME OWNER_BIRTH_DATE OWNER_LANGUAGE OWNER_PERSONA TELEGRAM_BOT_TOKEN ANTHROPIC_API_KEY GOOGLE_API_KEY"

# Pflicht-Host-Keys (Install-UX-Phase 7): ohne sie ist die Instanz unbenutzbar — kein Chat (Telegram), kein Agent denkt
# (seit Modell-Phase 2 laufen ALLE Agenten auf Claude -> Anthropic Pflicht; Google ist optional und traegt nur noch die
# Sprachnachrichten), kein Owner-Skelett -> kein Telegram-Pairing (Name + Geburtsdatum). EINE Adresse: _host_key_ask,
# _missing_required_host_keys, _all_host_keys_answered und die Uebersicht lesen sie.
_REQUIRED_HOST_KEYS="OWNER_FIRST_NAME OWNER_LAST_NAME OWNER_BIRTH_DATE TELEGRAM_BOT_TOKEN ANTHROPIC_API_KEY"
_host_key_required() { case " $_REQUIRED_HOST_KEYS " in *" $1 "*) return 0 ;; esac; return 1; }

# _missing_required_host_keys -> die leeren Pflicht-Host-Keys (Leerzeichen-getrennt) auf stdout. Gibt IMMER 0 zurueck
#   (Aufruf in $(…) unter dem geerbten set -e).
_missing_required_host_keys() {
  local k v out=''
  for k in $_REQUIRED_HOST_KEYS; do
    eval "v=\${$k:-}"
    [ -n "$v" ] || out="${out:+$out }$k"
  done
  printf '%s' "$out"
  return 0
}

# load_install_env — Werte aus core.env (INSTALL_ENV_FILE) in die Env laden, NUR wenn nicht schon (per Prozess-Env)
# gesetzt (override-first). Laeuft fuer JEDES Profil (Dev-Re-Runs profitieren ebenso). Fehlt die
# Datei -> no-op.
load_install_env() {
  [ -f "${INSTALL_ENV_FILE:-}" ] || return 0
  local k v
  for k in $_INSTALL_ENV_KEYS; do
    eval "v=\${$k:-}"
    if [ -z "$v" ]; then
      v="$(read_env_value "$INSTALL_ENV_FILE" "$k" || true)"
      [ -n "$v" ] && eval "$k=\$v; export $k"
    fi
  done
  # Explizit 0: endet die Schleife mit einem LEEREN letzten Key, waere der Funktions-Status sonst 1
  # (&&-Liste) -> set -e killt provision.sh STILL (die &&-Exemption unterdrueckt sogar den ERR-Trap).
  # Latenter Zweitlauf-Crash seit die optionalen Keys am Listen-Ende stehen koennen (Install-UX-Phase).
  return 0
}

# _read_tty <prompt> <secret?>  → eingegebener Wert auf STDOUT (leer, wenn kein TTY/unattended).
# Seit der Install-UX-Phase ein duenner Delegat auf ui_input (common.sh): gum-Zweig + plain-Fallback,
# /dev/tty (curl|bash-sicher), UND das gehaertete Interaktivitaets-Gate ui_interactive
# (TTY ∧ ¬UNATTENDED — Befund 1: vorher gate nur die TTY-Praesenz). secret=1 -> maskiert.
_read_tty() { ui_input "$1" "${2:-0}"; }

# _prompt_if_empty <varname> <prompt> <secret?>  — fragt nur, wenn die Variable leer ist UND ein
# TTY da ist. Setzt + exportiert die Variable. Ohne TTY (unattended) bleibt sie leer (der jeweilige
# Schritt skippt dann sauber — gleiche Degradierung wie bei fehlendem .env-Wert in Dev/Test).
_prompt_if_empty() {
  local name="$1" prompt="$2" secret="${3:-0}" cur val
  eval "cur=\${$name:-}"
  [ -n "$cur" ] && return 0
  val="$(_read_tty "$prompt" "$secret")"
  [ -n "$val" ] && eval "$name=\$val; export $name"
}

# _persist_install_env — die gemanagten Werte in core.env (INSTALL_ENV_FILE) mergen (Coolify-Muster),
# einmal vorher ein Backup. 640 root:n8n (Owner-Identitaet = PII, API-Keys = Secret -> nie ins Repo,
# konsistent mit n8n.env). Beim allerersten Schreiben Datei + Header anlegen.
# SEEN-Persistenz (Spec C/E2.1): in einem INTERAKTIVEN Lauf wurde jeder Key angeboten -> auch LEERE
# Werte als `KEY=`-Zeile schreiben (= seen, fragt nie erneut). Nicht-interaktiv (unattended/kein TTY)
# werden nur non-empty Werte gemergt — nie Gestelltes bleibt fragbar (debconf: seen = wurde gestellt).
_persist_install_env() {
  local f="$INSTALL_ENV_FILE" k v interactive=0
  ui_interactive && interactive=1
  if [ -f "$f" ]; then
    cp -p "$f" "${f}.bak" 2>/dev/null || true
  else
    mkdir -p "$(dirname "$f")"
    # umask 077 im Subshell: die Datei nimmt gleich Secrets auf -> nie (auch nicht kurz) world-readable anlegen.
    ( umask 077
      {
        printf '# Managed by provisioning collect_release_inputs (Phase 6) — Release-Eingaben.\n'
        printf '# Idempotenz-Store (env-override-first reuse; leere KEY=-Zeile = bewusst uebersprungen/seen).\n'
        printf '# chmod 640 root:%s, NIE ins Repo.\n' "$N8N_USER"
      } > "$f" )
  fi
  for k in $_INSTALL_ENV_KEYS; do
    eval "v=\${$k:-}"
    if [ -n "$v" ]; then
      env_upsert "$f" "$k" "$v"
    elif [ "$interactive" -eq 1 ] && ! _key_not_offered "$k"; then
      env_upsert "$f" "$k" ""
    fi
  done
  chmod 0640 "$f" 2>/dev/null || true
  chown "root:${N8N_USER}" "$f" 2>/dev/null || true
}

# --- Lokale Validatoren (kein Netz) gegen die echten Downstream-Constraints --------------------
# Genau die Regeln, an denen es sonst SPAETER scheitert: n8ns zod-Email (FQDN, lehnt owner@localhost
# ab), die household-Facts-Validierung (Vor-/Nachname non-empty, birth_date DATE-castbar + nicht in
# der Zukunft -> sonst schlaegt der Skelett-Seed fehl = kein Pairing), WEBHOOK_URL (FQDN).
# Das n8n-Login-Passwort prueft `_owner_password_ok` (bootstrap_owner.sh: 8-64/Ziffer/Grossbuchstabe).
_validate_domain()    { printf '%s' "$1" | grep -qiE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }
_validate_email()     { printf '%s' "$1" | grep -qE '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'; }
_validate_name()      { printf '%s' "$1" | grep -qE '[^[:space:]]'; }   # mind. ein Nicht-Whitespace
_validate_any()       { return 0; }                                     # validator-Enum 'none' (Paket-Wizard)
_validate_url()       { printf '%s' "$1" | grep -qiE '^https?://[^[:space:]]+$'; }  # validator-Enum 'url'
_validate_birthdate() {
  printf '%s' "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || return 1   # striktes ISO-Format
  date -d "$1" +%F >/dev/null 2>&1 || return 1                            # echtes Datum (lehnt 02-30 ab)
  [ "$1" \> "$(date +%F)" ] && return 1                                    # nicht in der Zukunft
  return 0
}

# --- Prompt-Zeit-Validierung der eingegebenen Secrets gegen den echten Dienst ----------------------
# Schon BEIM EINTIPPEN gegen den echten Dienst pruefen -> der Owner korrigiert sofort im Terminal,
# nicht erst spaet (die zweite Schranke ist _cred_test in inject_credentials, beide Profile). Der
# Key/Token geht ueber eine 600-`curl -K`-Config (nie ins argv/Prozessliste — Projekt-Hard-Rule).
# Grenze: das prueft GUELTIGKEIT (authentifiziert), NICHT Free-vs-Paid-Tier (das zeigt sich erst an
# der Tagesquote unter Last) — fuer den Paid-Key bleibt die AI-Studio-Plan-Pruefung Owner-Sache.
_http_status_secret() {
  local cfg; cfg="$(mktemp)"; chmod 600 "$cfg"
  printf '%s\n' "$@" > "$cfg"
  # curl schreibt bei Verbindungsfehler SELBST '000' (-w) UND endet != 0 -> `|| echo 000` ergaebe '000000'.
  local code; code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 -K "$cfg" 2>/dev/null)" || true
  code="${code:-000}"
  rm -f "$cfg"; printf '%s' "$code"
}

# Live-Pruefer: 0 = gueltig, 1 = vom Dienst abgelehnt, 2 = Dienst nicht erreichbar (kein Netz/Timeout, HTTP 000).
# 2 ist KEIN Tippfehler -> _prompt_validated uebernimmt den Wert mit Hinweis (die zweite Schranke _cred_test
# prueft beim Credential-Inject erneut), statt den Owner bei einem Netz-Wackler festzuhalten.
_live_rc() { case "$1" in 200) return 0 ;; 000) return 2 ;; *) return 1 ;; esac; }
_validate_telegram()  { _live_rc "$(_http_status_secret "url = \"https://api.telegram.org/bot$1/getMe\"")"; }
_validate_google()    { _live_rc "$(_http_status_secret "url = \"https://generativelanguage.googleapis.com/v1beta/models\"" "header = \"x-goog-api-key: $1\"")"; }
_validate_anthropic() { _live_rc "$(_http_status_secret "url = \"https://api.anthropic.com/v1/models\"" "header = \"x-api-key: $1\"" "header = \"anthropic-version: 2023-06-01\"")"; }

# _is_live_validator <fn> — Live-Dienst-Checks (echte API-Calls) vs. lokale Regex-Checks (gratis).
# F2c (Opus-Review): VORHANDENE Werte (Env/Store — z. B. bei jedem Prod-Update via INSTALL_PROFILE)
# werden NICHT live re-validiert (sonst 3 API-Calls je Update); Live-Checks laufen nur fuer
# NEU eingegebene Werte. Die zweite Schranke bleibt _cred_test beim Inject (beide Profile).
_is_live_validator() {
  case "$1" in _validate_telegram|_validate_google|_validate_anthropic) return 0 ;; esac
  return 1
}

# _prompt_label <prompt> -> menschenlesbarer Name einer Frage fuer Hinweise (Prompt ohne Klammer-Zusatz/Doppelpunkt).
_prompt_label() {
  local l="${1%%(*}"; l="${l%%: }"; l="${l%:}"
  printf '%s' "$l" | sed -E 's/[[:space:]]+$//'
}

# _prompt_reask_text <prompt> -> derselbe Prompt ohne den „Enter = …"-Zusatz (beim erneuten Fragen heisst Enter
#   „behalten"): "Adresse (z. B. x; Enter = nur im Heimnetz): " -> "Adresse (z. B. x): ",
#   "Schlüssel (optional, Enter = überspringen): " -> "Schlüssel (optional): ", "Token (Enter = …): " -> "Token: ".
_prompt_reask_text() {
  printf '%s' "$1" | sed -E 's/[;,] *Enter = [^)]*//; s/ *\(Enter = [^)]*\)//'
}

# _store_answer <file> <key> <value> — eine Antwort SOFORT speichern (Install-UX-Phase 4, Runde 2): bricht der
# Owner spaeter ab (Strg-C), fragt ein erneuter Lauf nur noch den Rest. umask 077 (die Datei kann vor dem
# n8n-User entstehen); danach 640 root:n8n, sobald es den User gibt (wie _persist_install_env).
_store_answer() {
  local f="$1" k="$2" v="$3"
  [ -n "$f" ] || return 0
  ( umask 077; env_upsert "$f" "$k" "$v" )
  if chown "root:${N8N_USER:-n8n}" "$f" 2>/dev/null; then chmod 0640 "$f" 2>/dev/null || true; fi
  return 0
}

# _prompt_validated <varname> <prompt> <secret?> <validator-fn> [required] [seen_file] [help] [confirm] [reask]
#   DER eine Prompt-Wrapper fuer Host-Keys UND den Paket-Secrets-Wizard (parametrisiertes Ziel).
#   Reihenfolge der Gates (Erstfrage, reask=0):
#     1. Wert schon gesetzt (Prozess-Env/Store) -> kein Prompt, keine Ausgabe. Lokale Validatoren pruefen ihn
#        weiter (gratis; ungueltig -> Hinweis); LIVE-Checks werden uebersprungen (F2c, s. _is_live_validator).
#     2. SEEN-Gate (F1, debconf): optionaler Key mit KEY=-Zeile im seen_file (auch leer) wurde
#        schon einmal angeboten -> NIE erneut fragen (Zeilen-Praesenz via env_has_key, nie der Wert).
#        Pflicht-Keys (required=1) kennen kein Seen-Gate: leer = erneut fragen (ein gespeicherter Wert kommt ueber
#        den Env-Preload load_install_env bzw. den Aufrufer schon in Gate 1 an).
#     3. Interaktivitaets-Gate ui_interactive (TTY ∧ ¬UNATTENDED — Befund 1). Nicht interaktiv: still zurueck —
#        fehlende Pflicht-Host-Keys meldet collect_release_inputs GESAMMELT vorab (Erstinstallation = die, Bestand =
#        warn; Install-UX-Phase 7), fehlende Paket-Pflicht-Credentials failen im Inject (§3.8).
#     4. Erst JETZT (es wird wirklich gefragt) die Erklaer-Box <help> + Buchfuehrung UI_ASKED/UI_ASKED_KEYS. Bis 3x
#        fragen+pruefen; Live-Checks zeigen „prüfe …". Optional + Enter = sichtbar „übersprungen", Pflicht + Enter =
#        „nötig". 3x ungueltig -> NIE still uebernehmen: optional = uebersprungen, required = Abbruch.
#        confirm=1 (Passwoerter): zweite Eingabe muss gleich sein.
#     5. Jede Antwort (auch „übersprungen" = leere Seen-Zeile) sofort in <seen_file> (_store_answer).
#   reask=1 (Uebersicht „Eine Angabe ändern", `lifeagents reconfigure`, `package reconfigure`): Gate 1+2 entfallen;
#   aktueller Wert aus der Env, sonst aus <seen_file>; Hinweis „[<wert> — Enter = behalten]" nur bei secret=0, sonst
#   „[gesetzt — …]" (debconf: Text-Fragen zeigen den Vorgabewert, Passwoerter nie); Enter = behalten (Pflicht + leer ->
#   nochmal); 3x ungueltig -> der alte Wert bleibt (nie der die-/skip-Schwanz). Speichert SELBST NICHTS — der Aufrufer
#   schreibt nach der letzten Antwort (Mehr-Key-Credentials aendern sich atomar; Strg-C = nichts geaendert).
# shellcheck disable=SC2034  # UI_ASKED liest provision.sh (Uebersicht nur, wenn wirklich gefragt wurde)
_prompt_validated() {
  local name="$1" prompt="$2" secret="${3:-0}" vfn="$4" required="${5:-0}" seenf="${6:-${INSTALL_ENV_FILE:-}}"
  local help="${7:-}" confirm="${8:-0}" reask="${9:-0}"
  local cur val="" again i=0 rc label hint=''
  label="$(_prompt_label "$prompt")"
  eval "cur=\${$name:-}"
  if [ "$reask" = "1" ]; then
    ui_interactive || return 0
    if [ -z "$cur" ] && [ -n "$seenf" ]; then cur="$(read_env_value "$seenf" "$name" 2>/dev/null || true)"; fi
    prompt="$(_prompt_reask_text "$prompt")"
    if [ -n "$cur" ]; then
      if [ "$secret" = "1" ]; then hint='[gesetzt — Enter = behalten] '; else hint="[${cur} — Enter = behalten] "; fi
    fi
  else
    if [ -n "$cur" ]; then
      if ! _is_live_validator "$vfn" && ! "$vfn" "$cur"; then
        # Die Domain landet in n8n.env, das Shell-Schritte sourcen -> ein ungueltiger Wert ist ein Abbruch, kein Hinweis.
        [ "$name" = DOMAIN ] && die "Die vorgegebene Internet-Adresse „${cur}“ ist ungültig (erwartet z. B. bot.example.org). Bitte korrigieren und erneut starten."
        warn "Gespeicherter Wert für „${label}“ ist ungültig — bitte prüfen (Protokoll: $name)."
      fi
      return 0
    fi
    if [ "$required" -ne 1 ] && [ -n "$seenf" ] && env_has_key "$seenf" "$name"; then
      return 0   # bewusst uebersprungen (seen) — debconf: nie erneut nagen
    fi
    ui_interactive || return 0   # nicht interaktiv: Pflicht-Luecken meldet der Aufrufer gesammelt (s. Kopf)
  fi
  UI_ASKED=1
  case " $UI_ASKED_KEYS " in *" $name "*) : ;; *) UI_ASKED_KEYS="${UI_ASKED_KEYS:+$UI_ASKED_KEYS }$name" ;; esac
  [ -n "$help" ] && printf '%s\n' "$help" | ui_box "$label" >&2
  while [ "$i" -lt 3 ]; do
    val="$(ui_input "${prompt}${hint}" "$secret")"
    if [ -z "$val" ]; then
      if [ "$reask" = "1" ] && [ -n "$cur" ]; then
        eval "$name=\$cur; export $name"   # Enter = behalten
        return 0
      fi
      if [ "$required" -eq 1 ]; then
        warn "  Diese Angabe ist nötig — bitte einen Wert eingeben (Strg-C = abbrechen)."
        i=$((i+1)); continue
      fi
      [ "$reask" = "1" ] && return 0   # optional + leer bleibt leer (es gibt nichts zu behalten)
      note "  übersprungen."
      _store_answer "$seenf" "$name" ""
      return 0
    fi
    rc=0
    if _is_live_validator "$vfn"; then
      { printf '  prüfe …' > /dev/tty; } 2>/dev/null || true
      "$vfn" "$val" || rc=$?
      { printf '\r\033[2K' > /dev/tty; } 2>/dev/null || true
    else
      "$vfn" "$val" || rc=$?
    fi
    if [ "$rc" -eq 2 ]; then
      warn "  Konnte gerade nicht online prüfen (keine Verbindung) — übernommen, wird bei der Einrichtung erneut geprüft."
      rc=0
    fi
    if [ "$rc" -eq 0 ] && [ "$confirm" = "1" ]; then
      again="$(ui_input "Zur Bestätigung noch einmal: " "$secret")"
      if [ "$again" != "$val" ]; then
        warn "  Die beiden Eingaben stimmen nicht überein — bitte erneut."
        i=$((i+1)); continue
      fi
    fi
    if [ "$rc" -eq 0 ]; then
      eval "$name=\$val; export $name"
      ok "  übernommen."
      [ "$reask" = "1" ] || _store_answer "$seenf" "$name" "$val"
      return 0
    fi
    warn "  Das passt nicht (ungültig oder Tippfehler) — bitte erneut."
    i=$((i+1))
  done
  if [ "$reask" = "1" ]; then
    # NIE still den letzten Fehlversuch uebernehmen und nie abbrechen: der bisherige Wert bleibt (der Aufrufer prueft
    # danach selbst, ob eine Pflichtangabe leer geblieben ist).
    if [ -n "$cur" ]; then
      eval "$name=\$cur; export $name"
      warn "  Dreimal ungültig — der bisherige Wert bleibt unverändert."
    else
      warn "  Dreimal keine gültige Eingabe — „${label}“ bleibt leer."
    fi
    return 0
  fi
  if [ "$required" -eq 1 ]; then
    die "„${label}“ ist nötig — nach 3 Versuchen kein gültiger Wert. Abbruch; ein erneuter Lauf fragt hier weiter."
  fi
  warn "  Dreimal ungültig — „${label}“ wird übersprungen (später nachtragbar)."
  _store_answer "$seenf" "$name" ""
  return 0
}

# _host_key_def <KEY> — die EINE Definition je Host-Frage (Install-UX-Phase 7): setzt _HK_PROMPT/_HK_VFN/_HK_SECRET/
#   _HK_CONFIRM/_HK_HELP. Quelle fuer die Erstfrage, die Uebersicht (Beschriftung = _prompt_label des Prompts, Secret-
#   Anzeige) und `lifeagents reconfigure`. TRUSTED_PROXIES traegt nur eine Beschriftung (eigener Dialog
#   _ask_trusted_proxies). Pflicht kommt aus _REQUIRED_HOST_KEYS, nicht von hier.
_HK_PROMPT=''; _HK_VFN='_validate_any'; _HK_SECRET=0; _HK_CONFIRM=0; _HK_HELP=''
_host_key_def() {
  _HK_PROMPT="$1: "; _HK_VFN='_validate_any'; _HK_SECRET=0; _HK_CONFIRM=0; _HK_HELP=''
  case "$1" in
    DOMAIN)
      _HK_PROMPT="Internet-Adresse (z. B. bot.example.com; Enter = nur im Heimnetz): "; _HK_VFN=_validate_domain
      _HK_HELP="Damit Telegram deinen Bot erreicht, muss dein Server unter einer eigenen Adresse aus dem
Internet per HTTPS erreichbar sein (eigene Domain oder DynDNS, Weiterleitung von Port 443
im Router, ein Reverse Proxy wie Caddy, Nginx Proxy Manager oder Traefik).
Den Proxy richtest du selbst ein — am Ende bekommst du eine fertige Vorlage und die genauen
Anforderungen. Ohne Adresse (Enter) läuft alles nur im Heimnetz; Telegram funktioniert dann nicht.
Nachtragen geht später jederzeit: lifeagents reconfigure" ;;
    TRUSTED_PROXIES)
      _HK_PROMPT="Reverse Proxy: " ;;
    N8N_OWNER_EMAIL)
      _HK_PROMPT="E-Mail für die n8n-Anmeldung (Enter = Platzhalter-Adresse): "; _HK_VFN=_validate_email
      _HK_HELP="n8n ist die Plattform, auf der deine Agenten laufen. Mit dieser E-Mail und dem folgenden
Passwort meldest du dich an der n8n-Weboberfläche an (nur für Wartung nötig).
Es werden keine Mails verschickt — die Adresse ist nur dein Anmeldename." ;;
    N8N_OWNER_PASSWORD)
      _HK_PROMPT="Passwort für die n8n-Anmeldung (Enter = wird erzeugt): "; _HK_VFN=_owner_password_ok
      _HK_SECRET=1; _HK_CONFIRM=1
      _HK_HELP="8 bis 64 Zeichen, mindestens eine Ziffer und ein Großbuchstabe.
Enter = die Installation erzeugt ein sicheres Passwort und zeigt es am Ende einmal an." ;;
    OWNER_FIRST_NAME)
      _HK_PROMPT="Dein Vorname: "; _HK_VFN=_validate_name
      _HK_HELP="Damit der Bot dich beim ersten Kontakt erkennt, legt die Installation dich als Inhaber
deines Haushalts an. Vorname, Nachname und Geburtsdatum sind Pflicht — ohne sie kann sich
der Bot nicht mit dir verbinden. Weitere Personen (Partner, Kinder) fügst du später im Chat
hinzu. Das Geburtsdatum nutzen die Berater für altersabhängige Themen (z. B. Rente,
Versicherungen). Alles bleibt auf deinem Server." ;;
    OWNER_LAST_NAME)
      _HK_PROMPT="Dein Nachname: "; _HK_VFN=_validate_name ;;
    OWNER_BIRTH_DATE)
      _HK_PROMPT="Dein Geburtsdatum (JJJJ-MM-TT, z. B. 1985-04-23): "; _HK_VFN=_validate_birthdate ;;
    OWNER_LANGUAGE)
      _HK_PROMPT="Sprache der Bot-Nachrichten: " ;;
    OWNER_PERSONA)
      _HK_PROMPT="Charakter des Bots: " ;;
    TELEGRAM_BOT_TOKEN)
      _HK_PROMPT="Telegram-Bot-Token: "; _HK_VFN=_validate_telegram; _HK_SECRET=1
      _HK_HELP="Pflicht: Über einen eigenen Telegram-Bot schreibst du mit deinen Agenten. So bekommst du
das Token:
  1. In Telegram nach @BotFather suchen und den Chat öffnen.
  2. /newbot senden.
  3. Einen Anzeigenamen wählen (frei) und einen Benutzernamen, der auf „bot“ endet.
  4. BotFather antwortet mit dem Token (Form 123456:ABC-DEF…) — hier einfügen.
Das Token wird sofort bei Telegram geprüft." ;;
    ANTHROPIC_API_KEY)
      _HK_PROMPT="Anthropic-API-Schlüssel: "; _HK_VFN=_validate_anthropic; _HK_SECRET=1
      _HK_HELP="Pflicht: Alle Agenten denken mit Claude von Anthropic (Weiterleiten, Buchen, Hilfe,
Belege lesen, Websuche, Beratung). Ohne diesen Schlüssel antwortet der Bot nicht.
  1. console.anthropic.com öffnen und anmelden.
  2. Guthaben aufladen („Billing“), dann „API Keys“ → „Create Key“ → Schlüssel kopieren.
Anthropic nutzt Daten aus der API nicht zum Training. Abgerechnet wird nach Nutzung.
Der Schlüssel wird sofort bei Anthropic geprüft." ;;
    GOOGLE_API_KEY)
      _HK_PROMPT="Google-API-Schlüssel (optional, Enter = überspringen): "; _HK_VFN=_validate_google; _HK_SECRET=1
      _HK_HELP="Optional, nur für Sprachnachrichten: Claude versteht kein Audio, deshalb wandelt
Googles Gemini deine Sprachnachrichten in Text um. Ohne Schlüssel antwortet der Bot auf eine
Sprachnachricht mit der Bitte, als Text zu schreiben — alles andere läuft normal.
  1. aistudio.google.com öffnen und mit deinem Google-Konto anmelden.
  2. „Get API key“ → „Create API key“ → Schlüssel kopieren.
  3. WICHTIG: für das Projekt die Abrechnung aktivieren (bezahlter Tarif). Nur dann nutzt
     Google deine Daten nicht zum Training.
Später nachtragen: lifeagents reconfigure" ;;
  esac
  return 0
}

# _host_key_label <KEY> -> menschenlesbare Beschriftung einer Host-Frage (Uebersicht, Meldungen) auf stdout.
_host_key_label() { _host_key_def "$1"; _prompt_label "$_HK_PROMPT"; }

# _host_key_ask <KEY> [reask] — eine Host-Frage stellen (Definition aus _host_key_def, Pflicht aus
#   _REQUIRED_HOST_KEYS). reask=1 (Uebersicht, reconfigure): Enter = behalten, speichert NICHT (der Aufrufer
#   speichert). Nie in $(…) aufrufen: der exportierte Wert ginge mit der Subshell verloren.
_host_key_ask() {
  local key="$1" reask="${2:-0}" req=0
  _host_key_required "$key" && req=1
  _host_key_def "$key"
  _prompt_validated "$key" "$_HK_PROMPT" "$_HK_SECRET" "$_HK_VFN" "$req" "${INSTALL_ENV_FILE:-}" "$_HK_HELP" "$_HK_CONFIRM" "$reask"
}

# _host_editable_keys -> die NACH der Erstinstallation sinnvoll aenderbaren Host-Keys, eins je Zeile (Uebersicht auf
#   einer Bestandsinstanz + `lifeagents reconfigure`): Internet-Adresse + die drei Schluessel; Name/Geburtsdatum nur,
#   solange noch kein Owner-Skelett existiert (danach sind es Haushalts-Daten, die der Bot im Chat pflegt). Die
#   n8n-Anmeldung bleibt draussen (lebt in n8n; die core.env-Werte nutzt nur die Ersteinrichtung), der Proxy-Ort auch
#   (`lifeagents proxy set`). Gibt immer 0 zurueck.
_host_editable_keys() {
  printf '%s\n' DOMAIN TELEGRAM_BOT_TOKEN ANTHROPIC_API_KEY GOOGLE_API_KEY
  if ! declare -F _oc_owner_person_exists >/dev/null || ! _oc_owner_person_exists; then
    printf '%s\n' OWNER_FIRST_NAME OWNER_LAST_NAME OWNER_BIRTH_DATE OWNER_LANGUAGE OWNER_PERSONA
  fi
  return 0
}

# _update_held_marker -> Pfad der Merk-Datei "Owner wurde ueber dieses fehlende Pflicht-Key-Set schon informiert".
_update_held_marker() { printf '%s/.update_held' "$LIFEAGENTS_DIR"; }

# _hold_update_for_missing_keys <keys> <labels> — unbeaufsichtigtes Update einer BESTANDSINSTANZ, aber ein Pflicht-
#   Host-Key fehlt (Beispiel: ANTHROPIC_API_KEY, seit Modell-Phase 2 Pflicht). Statt die neue Version einzuspielen (der Bot
#   waere danach stumm) wird NICHTS geaendert: Log-Meldung, einmal je fehlendem Key-Satz eine Telegram-Nachricht an den
#   Owner, dann exit 0 (kein Fehler fuer cron). Zurueckhalten statt halb einspielen = das unattended-upgrades-Muster.
#   Dedup per Merk-Datei in /etc/lifeagents (core.notification_state ginge erst nach apply_schema); collect_release_inputs
#   loescht sie, sobald nichts mehr fehlt. Alles fail-open: ein gescheiterter Versand aendert nichts am Halt.
_hold_update_for_missing_keys() {
  local keys="$1" labels="$2" marker keyset prev=''
  marker="$(_update_held_marker)"
  # shellcheck disable=SC2086  # bewusst ungequotet: die Key-Liste (Bezeichner ohne Leerzeichen) je Zeile sortieren
  keyset="$(printf '%s\n' $keys | sort | tr '\n' ' ')"
  prev="$(cat "$marker" 2>/dev/null || true)"
  warn "Update wartet: Pflichtangaben fehlen (${labels}). Es wurde nichts geändert — die installierte Version läuft weiter. Nachtragen: sudo lifeagents reconfigure (danach läuft das nächste Update normal)."
  result_set missing_keys "$labels"
  result_set changed false
  result_set status held
  # Vom Chat-Runner gestartet (LIFEAGENTS_UPDATE_REQUESTED): der Owner hat getippt und bekommt GENAU EINE Antwort —
  # die des Runners (core.fn_update_report, mit Hilfe-Schritten), auch beim Wiederholungs-Halt mit gleichem Key-Satz.
  if [ "${LIFEAGENTS_UPDATE_REQUESTED:-0}" = 1 ]; then exit 0; fi
  if [ "$keyset" != "$prev" ]; then
    if notify_owner_telegram "Update wartet: Für die neue Version fehlt eine Pflichtangabe (${labels}). Es wurde nichts geändert, dein Bot läuft wie bisher. Bitte auf dem Server eintragen: sudo lifeagents reconfigure — danach läuft das nächste Update normal durch."; then
      { printf '%s' "$keyset" > "$marker"; chmod 600 "$marker"; } 2>/dev/null || true
      log "Owner per Telegram informiert."
    else
      note "Owner konnte nicht per Telegram informiert werden (kein Token, Owner nicht verbunden oder Netz)."
    fi
  fi
  exit 0
}

# collect_release_inputs — NUR Release: fehlende externe Eingaben interaktiv erfragen + persistieren.
# load_install_env() lief schon in main() (override-first reuse). Dev/Test ruft das NICHT (Werte
# kommen aus dem injizierten .env-Block). Der EINE Prompt-Besitzer der HOST-Keys (Spec C
# Prompt-Ownership) — laeuft auch auf Prod-Updates (INSTALL_PROFILE, Befund 3) und fragt dann
# seen-aware genau die NEUEN Keys eines Releases nach (und leere Pflicht-Keys erneut). Erklaer-Boxen erscheinen
# NUR vor einer Frage, die wirklich gestellt wird (_prompt_validated) — ein Update mit vollstaendigen Antworten
# bleibt still.
collect_release_inputs() {
  [ "$PROFILE" = "release" ] || return 0

  if ! tty_usable && [ "$UNATTENDED" -ne 1 ]; then
    warn "Release ohne TTY und ohne --unattended: fehlende Eingaben können nicht erfragt werden — optionale Schritte entfallen, Pflichtangaben müssen aus der Umgebung kommen."
  fi
  # Nicht interaktiv: Pflichtangaben VORAB gesammelt pruefen (Install-UX-Phase 7; Subiquity-/Proxmox-Autoinstall-
  # Muster: alles Fehlende in EINER Meldung, vor jedem Installationsschritt). Erstinstallation: Abbruch. Bestandsinstanz:
  # "Update wartet" (_hold_update_for_missing_keys) — nichts einspielen, die installierte Version laeuft weiter, der Owner
  # bekommt einmal Bescheid; kein Abbruch per `die` (die Abhilfe `lifeagents reconfigure` laeuft ueber die installierte
  # Version). Gehalten wird NUR fuer Keys, die reconfigure auch abfragt (_host_editable_keys) — sonst haelt eine Instanz
  # mit Owner-Skelett, deren Name nie in core.env stand, fuer immer an (Name/Geburtsdatum fragt reconfigure dann nicht
  # mehr); solche Luecken bleiben eine Warnung wie bisher.
  if ! ui_interactive; then
    local _miss _m _labels='' _hold='' _hlabels='' _editable
    _miss="$(_missing_required_host_keys)"
    if [ -n "$_miss" ]; then
      for _m in $_miss; do _labels="${_labels:+$_labels, }$(_host_key_label "$_m") ($_m)"; done
      if _is_first_install; then
        die "Pflichtangaben fehlen: ${_labels}. Ohne Terminal kann die Installation nicht nachfragen — die Werte in die --unattended-Datei (KEY='wert') bzw. als Umgebungsvariablen setzen und erneut starten."
      fi
      _editable=" $(_host_editable_keys | tr '\n' ' ')"
      for _m in $_miss; do
        case "$_editable" in *" $_m "*) _hold="${_hold:+$_hold }$_m"; _hlabels="${_hlabels:+$_hlabels, }$(_host_key_label "$_m") ($_m)" ;; esac
      done
      if [ -n "$_hold" ]; then _hold_update_for_missing_keys "$_hold" "$_hlabels"; fi
      warn "Pflichtangaben fehlen: ${_labels} — bitte in /etc/lifeagents/core.env nachtragen."
    fi
  fi
  rm -f "$(_update_held_marker)" 2>/dev/null || true   # nichts (mehr) offen -> naechster Halt meldet sich wieder

  log "Release-Eingaben sammeln (env-override-first; fehlende interaktiv) ..."

  # Intro (nur wenn ueberhaupt etwas zu fragen ist — ein Update mit vollstaendigen Antworten bleibt still).
  if ui_interactive && ! _all_host_keys_answered; then
    ensure_gum
    ui_box 'Installation — was gleich gefragt wird' >&2 <<'INTRO'
Der Reihe nach:
  1. Erreichbarkeit   deine Internet-Adresse (optional) + wo dein Reverse Proxy läuft
  2. n8n-Anmeldung    E-Mail + Passwort für die Verwaltungsoberfläche
  3. Über dich        Vor- und Nachname, Geburtsdatum (Pflicht)
  4. Schlüssel        Telegram-Bot + Anthropic (Pflicht), Google (optional, Sprachnachrichten)
  5. Funktionen       welche Zusatz-Funktionen (Finanzen, Karriere, …) gleich mitkommen

Zu jeder Frage gibt es vorher eine kurze Erklärung. Enter bei „optional“ =
überspringen. Am Ende siehst du alle Antworten noch einmal und kannst jede
einzeln ändern, bevor etwas installiert wird. Datenbank-Passwörter und interne
Schlüssel erzeugt die Installation selbst. Funktionen kannst du auch später
jederzeit dazunehmen: lifeagents package install

Abbrechen geht jederzeit mit Strg-C — beantwortete Fragen bleiben gespeichert,
ein erneuter Aufruf fragt nur den Rest.
INTRO
  fi
  _ensure_install_env_file

  # Die Fragen in der Reihenfolge von _INSTALL_ENV_KEYS (EINE Liste fuer Reihenfolge, Persistenz und Intro);
  # TRUSTED_PROXIES, OWNER_LANGUAGE und OWNER_PERSONA haben eigene Auswahl-Dialoge, alle anderen kommen aus der Host-Fragen-Tabelle.
  local _k
  for _k in $_INSTALL_ENV_KEYS; do
    case "$_k" in
      TRUSTED_PROXIES) _ask_trusted_proxies ;;
      OWNER_LANGUAGE)  _ask_owner_language ;;
      OWNER_PERSONA)   _ask_owner_persona ;;
      *)               _host_key_ask "$_k" ;;
    esac
  done

  _persist_install_env
  ok "Release-Eingaben gesammelt + in $INSTALL_ENV_FILE gemergt (640 root:${N8N_USER})."
}

# _is_first_install -> 0, solange auf dieser Maschine Core + Pakete noch NIE durchgelaufen sind: der Marker VERSION fehlt
# (install_cli schreibt ihn nach den Core- und Paket-Schritten jedes Laufs, lifeagents_version_marker; postgres-Entrypoint-
# Muster PG_VERSION). Install-UX-Phase 7: vorher eine DB-Probe, die JEDEN psql-Fehler als „frisch" las (fail-open) —
# ein DB-Schluckauf haette ein unbeaufsichtigtes Update an einer Pflichtangabe sterben lassen. Reversibles
# --uninstall entfernt den Marker (ein Neu-Install danach gilt wieder als Erstinstallation).
_is_first_install() { [ ! -e "$(lifeagents_version_marker)" ]; }

# _ask_initial_packages — Install-UX-Phase 6: welche Zusatz-Funktionen gleich mitinstallieren? (debconf/tasksel:
# ALLE Fragen vorab — danach laeuft die Installation ohne Rueckfrage, und wenn Telegram verbunden ist, sind die
# Funktionen schon da.) Setzt PACKAGES_SPEC (provision.sh-Global) fuer die bestehenden Pfade (Paket-Fragen +
# Install-Schleife). NUR Release, NUR Erstinstallation, NUR ohne --packages/--core-only:
#   - Bestandsinstanzen werden nie gefragt.
#   - Merkzeile PACKAGES_SELECTED in core.env = EINMAL-Verbrauch: solange sie existiert, gilt die Wahl (auch wenn
#     ein abgebrochener Erstlauf den Core schon aktiv gemacht hat — sonst ginge das gewaehlte Paket still verloren);
#     provision.sh loescht sie nach der Paket-Schleife. Danach kann sie nie ein deinstalliertes Paket zurueckholen
#     ("deinstalliert bleibt weg"). Bewusst NICHT in _INSTALL_ENV_KEYS (die Liste treibt Intro/Seen der Host-Keys —
#     ein Paket-Wunsch ist kein Host-Key und darf auf Bestandsinstanzen kein Intro ausloesen).
#   - Erste Option „Nur Grundsystem" explizit (kein Verlass auf die gum-Semantik eines leeren Enter).
#   - reask=1 (Uebersicht „Eine Angabe ändern", Install-UX-Phase 7): umgeht die Bestands-Guards, Vorauswahl = die bisherige
#     Wahl (gum matcht LABELS komma-getrennt -> hier nur die kommafreien Namen, die Summaries enthalten Kommas);
#     Esc/leer = unveraendert (nur „Nur Grundsystem" leert); speichert NICHT (der Aufrufer schreibt PACKAGES_SELECTED).
# shellcheck disable=SC2034  # UI_ASKED liest provision.sh (Uebersicht nur, wenn wirklich gefragt wurde)
_ask_initial_packages() {
  local reask="${1:-0}"
  [ "$PROFILE" = "release" ] || return 0
  local known stored p out='' picked pre=''
  known=" $(_bundled_packages | tr '\n' ' ') "
  if [ "$reask" != "1" ]; then
    [ -z "${PACKAGES_SPEC:-}" ] || return 0
    if env_has_key "${INSTALL_ENV_FILE:-}" PACKAGES_SELECTED; then
      stored="$(read_env_value "$INSTALL_ENV_FILE" PACKAGES_SELECTED || true)"
      for p in ${stored//,/ }; do case "$known" in *" $p "*) out="${out:+$out,}$p" ;; esac; done
      PACKAGES_SPEC="${out:-none}"
      return 0
    fi
  fi
  _is_first_install || return 0
  ui_interactive || return 0
  ensure_jq_quiet || return 0
  UI_ASKED=1
  if [ "$reask" = "1" ]; then
    for p in ${PACKAGES_SPEC//,/ }; do
      case "$known" in *" $p "*) pre="${pre:+$pre,}$(pkg_display_name "$p")" ;; esac
    done
    picked="$( {
        printf '%s\t%s\n' "Nur Grundsystem (Funktionen später nachinstallieren)" none
        for p in $known; do
          printf '%s\t%s\n' "$(pkg_display_name "$p")" "$p"
        done
      } | ui_choose 'Welche Funktionen? (Leertaste = markieren, Enter = übernehmen, Esc = unverändert)' 1 "$pre" )"
    if [ -z "$picked" ]; then log "  Funktionen unverändert."; return 0; fi
  else
    ui_box 'Funktionen — was soll gleich mitkommen?' >&2 <<'BOX'
Das Grundsystem (Haushalt, Erinnerungen, Hilfe) wird immer installiert. Dazu kannst du
Zusatz-Funktionen wählen — jede bringt eigene Fähigkeiten und ggf. eigene Fragen
(z. B. Zugangsdaten). Nichts davon ist endgültig: später dazunehmen geht jederzeit mit
  lifeagents package install
BOX
    picked="$( {
        printf '%s\t%s\n' "Nur Grundsystem (Funktionen später nachinstallieren)" none
        for p in $known; do
          printf '%s\t%s\n' "$(pkg_display_name "$p") — $(pkg_text "$p" package.summary)" "$p"
        done
      } | ui_choose 'Welche Funktionen gleich mitinstallieren? (Leertaste = markieren, Enter = weiter)' 1 )"
  fi
  out=''
  while IFS= read -r p; do
    [ -n "$p" ] && [ "$p" != none ] || continue
    case "$known" in *" $p "*) out="${out:+$out,}$p" ;; esac
  done <<<"$picked"
  PACKAGES_SPEC="${out:-none}"
  [ "$reask" = "1" ] || _store_answer "${INSTALL_ENV_FILE:-}" PACKAGES_SELECTED "$out"
  if [ -n "$out" ]; then ok "  übernommen: ${out//,/, }."; else ok "  übernommen: nur Grundsystem."; fi
  return 0
}

# _all_host_keys_answered -> 0, wenn kein Host-Key mehr gefragt wuerde (gesetzt oder seen) — dann kein Intro.
#   Ein leerer Pflicht-Key gilt nie als beantwortet (er wird erneut gefragt, Install-UX-Phase 7).
_all_host_keys_answered() {
  local k v
  for k in $_INSTALL_ENV_KEYS; do
    eval "v=\${$k:-}"
    [ -n "$v" ] && continue
    _host_key_required "$k" && return 1
    env_has_key "${INSTALL_ENV_FILE:-}" "$k" && continue
    _key_not_offered "$k" && continue
    return 1
  done
  return 0
}

# _key_not_offered <key> -> 0, wenn der Key in diesem Lauf gar nicht gefragt wird (dann weder Intro noch
# "gesehen"-Zeile): TRUSTED_PROXIES nur MIT Internet-Adresse (ohne Domain gibt es keinen Proxy; wird spaeter eine
# Domain eingetragen, muss die Proxy-Frage dann noch kommen).
_TP_SKIPPED=0   # Proxy-Frage in diesem Lauf abgebrochen/ohne gueltige Antwort -> nicht als gesehen markieren
_key_not_offered() {
  [ "$1" = "TRUSTED_PROXIES" ] && { [ -z "${DOMAIN:-}" ] || [ "$_TP_SKIPPED" = 1 ]; } && return 0
  # OWNER_PERSONA wirkt nur beim ERSTEN Anlegen des Owner-Skeletts: steht der Owner schon (Bestands-Installation, die
  # den Key noch nie hatte), waere die Frage wirkungslos -> nicht anbieten (dort waehlt man im Chat mit /persona).
  [ "$1" = "OWNER_PERSONA" ] && declare -F _oc_owner_person_exists >/dev/null && _oc_owner_person_exists
}

# _owner_language_options -> Picker-Zeilen "Eigenname<TAB>code" der unterstuetzten Sprachen (Core-Manifest languages.list,
#   die EINE Sprachliste); _owner_language_name <code> -> Eigenname (Uebersicht/Meldungen).
_owner_language_options() { _pkg_manifest_field core '(.languages.list // []) | sort_by(.ord) | map("\(.name)\t\(.code)") | join("\n")'; }
_owner_language_name() { _pkg_manifest_field core "(.languages.list // [])[] | select(.code == \"$1\") | .name"; }

# _ask_owner_language [reask] — Sprache, in der der Bot dem Owner FESTE Texte schickt (Bestaetigungskarten, Knoepfe,
#   Erinnerungen; Gespraechsantworten folgen immer der Sprache der Nachricht). Auswahl nur aus den unterstuetzten
#   Sprachen, Vorauswahl Deutsch. Esc bei der Erstfrage = Deutsch; reask (Uebersicht) speichert nicht selbst. Nicht
#   interaktiv: nichts fragen -> bootstrap_owner setzt 'de'. Wirkt nur beim Anlegen des Owner-Skeletts; danach aendert
#   der Owner seine Sprache im Chat.
_ask_owner_language() {
  local reask="${1:-0}" pick
  if [ "$reask" != "1" ]; then
    [ -n "${OWNER_LANGUAGE:-}" ] && return 0
    env_has_key "${INSTALL_ENV_FILE:-}" OWNER_LANGUAGE && return 0
  fi
  ui_interactive || return 0
  UI_ASKED=1
  case " $UI_ASKED_KEYS " in *" OWNER_LANGUAGE "*) : ;; *) UI_ASKED_KEYS="${UI_ASKED_KEYS:+$UI_ASKED_KEYS }OWNER_LANGUAGE" ;; esac
  pick="$(_owner_language_options | ui_choose 'In welcher Sprache soll der Bot dir feste Nachrichten schicken (Bestätigungen, Knöpfe, Erinnerungen)?' 0 'Deutsch')"
  if [ -z "$pick" ]; then
    if [ "$reask" = "1" ]; then log "  Sprache unverändert."; return 0; fi
    pick=de
  fi
  OWNER_LANGUAGE="$pick"; export OWNER_LANGUAGE
  [ "$reask" = "1" ] || _store_answer "${INSTALL_ENV_FILE:-}" OWNER_LANGUAGE "$pick"
  ok "  übernommen: $(_owner_language_name "$pick")."
  return 0
}

# _owner_persona_name <code> -> deutscher Anzeigename aus dem Core-Textkatalog (core.persona.name.<code>, ohne das
#   fuehrende Emoji: Emoji-Breiten verschieben die Installer-Auswahl je nach Terminal); unbekannt -> der Code selbst.
#   _owner_persona_options -> Picker-Zeilen "Name<TAB>code" in Manifest-Reihenfolge (personas.list, die EINE Liste).
_owner_persona_name() {
  local n; n="$(pkg_text core "persona.name.$1")"
  n="${n#* }"
  printf '%s' "${n:-$1}"
}
_owner_persona_options() {
  local c
  for c in $(_pkg_manifest_field core '(.personas.list // []) | sort_by(.ord) | map(.code) | join(" ")'); do
    printf '%s\t%s\n' "$(_owner_persona_name "$c")" "$c"
  done
}

# _ask_owner_persona [reask] — Bot-Charakter, mit dem der Orchestrator dem Owner antwortet (nur Rahmen: eigene
#   Saetze + hoechstens ein Satz um Fach-Antworten; Zahlen, Karten, Knoepfe bleiben neutral). Vorauswahl Neutral;
#   Esc bei der Erstfrage = Neutral; reask speichert nicht selbst. Nicht interaktiv: nichts fragen -> neutral. Ein
#   ungueltiger OWNER_PERSONA-Wert bricht nie ab: util_seed_owner_skeleton schreibt nur Codes aus core.ui_personas.
#   Wirkt nur beim Anlegen des Owner-Skeletts; danach waehlt der Owner im Chat mit /persona.
_ask_owner_persona() {
  local reask="${1:-0}" pick
  if [ "$reask" != "1" ]; then
    [ -n "${OWNER_PERSONA:-}" ] && return 0
    env_has_key "${INSTALL_ENV_FILE:-}" OWNER_PERSONA && return 0
    _key_not_offered OWNER_PERSONA && return 0
  fi
  ui_interactive || return 0
  UI_ASKED=1
  case " $UI_ASKED_KEYS " in *" OWNER_PERSONA "*) : ;; *) UI_ASKED_KEYS="${UI_ASKED_KEYS:+$UI_ASKED_KEYS }OWNER_PERSONA" ;; esac
  pick="$(_owner_persona_options | ui_choose 'Welchen Charakter soll der Bot im Chat mit dir haben? (Zahlen, Bestätigungen und Knöpfe bleiben immer neutral; im Chat änderbar mit /persona)' 0 "$(_owner_persona_name neutral)")"
  if [ -z "$pick" ]; then
    if [ "$reask" = "1" ]; then log "  Charakter unverändert."; return 0; fi
    pick=neutral
  fi
  OWNER_PERSONA="$pick"; export OWNER_PERSONA
  [ "$reask" = "1" ] || _store_answer "${INSTALL_ENV_FILE:-}" OWNER_PERSONA "$pick"
  ok "  übernommen: $(_owner_persona_name "$pick")."
  return 0
}

# _ask_trusted_proxies — Install-UX-Phase 5: wo laeuft der Reverse Proxy? (nur MIT Domain, interaktiv, nicht
# schon beantwortet). Speichert EINEN Fakt TRUSTED_PROXIES: "dieser Rechner" = 127.0.0.1 (explizit), "anderer
# Rechner" = dessen IPv4 (Hostname wird einmal aufgeloest und als IP gespeichert — die Firewall arbeitet mit IPs).
# ESC = nichts speichern (Default lokal; der naechste Lauf fragt erneut). Antwort sofort gespeichert.
# reask=1 (Uebersicht/reconfigure, Install-UX-Phase 7): fragt auch bei schon beantworteter Frage, setzt NUR die Variable
# (der Aufrufer speichert), Esc/leer = unveraendert.
# shellcheck disable=SC2034  # UI_ASKED liest provision.sh (Uebersicht nur, wenn wirklich gefragt wurde)
_ask_trusted_proxies() {
  local reask="${1:-0}" where val ip i=0 list confirm
  [ -n "${DOMAIN:-}" ] || return 0
  if [ "$reask" != "1" ]; then
    [ -n "${TRUSTED_PROXIES:-}" ] && return 0
    env_has_key "${INSTALL_ENV_FILE:-}" TRUSTED_PROXIES && return 0
  fi
  ui_interactive || return 0
  UI_ASKED=1
  case " $UI_ASKED_KEYS " in *" TRUSTED_PROXIES "*) : ;; *) UI_ASKED_KEYS="${UI_ASKED_KEYS:+$UI_ASKED_KEYS }TRUSTED_PROXIES" ;; esac
  ui_box 'Reverse Proxy — wofür, und wo läuft er?' >&2 <<'BOX'
Ein Reverse Proxy ist der „Türsteher“ zwischen Internet und deinem Server: Er nimmt die
verschlüsselten HTTPS-Verbindungen von Telegram an (dafür hat er das Zertifikat, z. B. von
Let's Encrypt) und reicht NUR die drei Telegram-Pfade an n8n weiter. Die n8n-Oberfläche selbst
bleibt so privat. Ohne Reverse Proxy kann Telegram deinen Bot nicht erreichen.

Zwei Möglichkeiten:
  • Auf diesem Rechner (oder du hast noch keinen):
    du bekommst am Ende ein komplettes, fertiges Caddyfile + die Schritte, um Caddy hier
    zu installieren. n8n bleibt nur auf diesem Rechner erreichbar.
  • Auf einem anderen Rechner in deinem Heimnetz (z. B. ein zentraler Caddy, Nginx Proxy
    Manager oder Traefik in einem eigenen Container, der schon andere Dienste wie Home
    Assistant bedient): du gibst dessen IP-Adresse an. n8n wird dann NUR für diesen Rechner
    geöffnet (eine Firewall-Regel weist alle anderen Geräte ab), und du bekommst einen
    Baustein zum Einfügen in deine bestehende Proxy-Konfiguration.
Später ändern: lifeagents proxy set <IP>
BOX
  where="$(printf '%s\n' "Auf diesem Rechner (oder ich habe noch keinen)	local" \
                         "Auf einem anderen Rechner in meinem Heimnetz	remote" \
             | ui_choose 'Wo läuft dein Reverse Proxy?' 0)"
  case "$where" in
    local)
      TRUSTED_PROXIES="127.0.0.1"; export TRUSTED_PROXIES
      [ "$reask" = "1" ] || _store_answer "${INSTALL_ENV_FILE:-}" TRUSTED_PROXIES "127.0.0.1"
      ok "  übernommen: Proxy auf diesem Rechner."
      return 0 ;;
    remote) : ;;
    *)
      if [ "$reask" = "1" ]; then log "  Reverse Proxy unverändert."; return 0; fi
      _TP_SKIPPED=1; note "  übersprungen — n8n bleibt vorerst nur auf diesem Rechner erreichbar."; return 0 ;;
  esac
  while [ "$i" -lt 3 ]; do
    val="$(ui_input "IP-Adresse oder Name des Proxy-Rechners (z. B. 192.168.178.10): " 0)"
    val="$(printf '%s' "$val" | tr -d ' \r\n\t')"
    if [ -z "$val" ]; then
      if [ "$reask" = "1" ]; then log "  Reverse Proxy unverändert."; return 0; fi
      _TP_SKIPPED=1; note "  übersprungen — n8n bleibt vorerst nur auf diesem Rechner erreichbar."; return 0
    fi
    if printf '%s' "$val" | grep -qE '[A-Za-z]'; then
      # Hostname -> einmal IPv4 aufloesen und die IP speichern (die Firewall arbeitet mit Adressen).
      ip="$( { getent ahostsv4 "$val" 2>/dev/null || true; } | awk 'NR==1 {print $1}')"
      if [ -z "$ip" ]; then warn "  „${val}“ lässt sich nicht auflösen — bitte die IP-Adresse eingeben."; i=$((i+1)); continue; fi
      log "  ${val} → ${ip}"
      val="$ip"
    fi
    if ! list="$(normalize_trusted_proxies "$val" 2>/dev/null)" || [ -z "$(_proxy_nonloop "$list")" ]; then
      warn "  Das ist keine passende IPv4-Adresse des Proxy-Rechners (Beispiel: 192.168.178.10) — bitte erneut."
      i=$((i+1)); continue
    fi
    if printf '%s' "$list" | grep -q '/'; then
      confirm="$(printf '%s\n' "Nein, ich gebe die einzelne IP des Proxy-Rechners ein	no" "Ja, das ganze Netz freigeben	yes" \
                   | ui_choose "„${list}“ ist ein ganzes Netz — jedes Gerät darin käme an die n8n-Anmeldeseite. Wirklich?" 0)"
      [ "$confirm" = "yes" ] || { i=$((i+1)); continue; }
    fi
    trusted_proxies_warnings "$list"
    TRUSTED_PROXIES="$list"; export TRUSTED_PROXIES
    [ "$reask" = "1" ] || _store_answer "${INSTALL_ENV_FILE:-}" TRUSTED_PROXIES "$list"
    ok "  übernommen: n8n wird nur für ${list} geöffnet."
    return 0
  done
  if [ "$reask" = "1" ]; then warn "  Dreimal keine passende Adresse — Reverse Proxy unverändert."; return 0; fi
  _TP_SKIPPED=1
  warn "  Dreimal keine passende Adresse — n8n bleibt vorerst nur auf diesem Rechner erreichbar (später: lifeagents proxy set <IP>)."
  return 0
}

# _ensure_install_env_file — core.env mit Kopf anlegen, bevor die erste Antwort sofort gespeichert wird.
_ensure_install_env_file() {
  local f="${INSTALL_ENV_FILE:-}"
  [ -n "$f" ] && [ ! -f "$f" ] || return 0
  ( umask 077; mkdir -p "$(dirname "$f")"
    {
      printf '# Managed by provisioning collect_release_inputs (Phase 6) — Release-Eingaben.\n'
      printf '# Idempotenz-Store (env-override-first reuse; leere KEY=-Zeile = bewusst uebersprungen/seen).\n'
      printf '# chmod 640 root:%s, NIE ins Repo.\n' "${N8N_USER:-n8n}"
    } > "$f" )
}

# --- Uebersicht vor dem Installieren (Install-UX-Phase 7) ------------------------------------------------------
# review_install_answers install|package [paket…] — nach der LETZTEN Frage alle Antworten in einem Kasten zeigen
#   (Geheimes nur „gesetzt"/„übersprungen") + „Stimmt so — Installation starten / Eine Angabe ändern … / Abbrechen".
#   Muster: Fedora-Anaconda-TUI-Hub (jeder Punkt einzeln aenderbar) + Proxmox-Summary. Leer/Esc = Abbrechen wie bei
#   rustup, npm init, Homebrew und gum confirm (es wird nichts installiert; Zugangsdaten + Angaben sind gespeichert,
#   gepufferte Paket-Einstellungen fragt der naechste Aufruf erneut). Setzt REVIEW_RESULT=go|abort und gibt IMMER 0
#   zurueck — der Aufrufer handelt (provision.sh: exit 1, package install: return 1); nie unter if!/|| aufrufen (das
#   schaltete set -e im Rumpf ab). Nur interaktiv (Aufrufer gatet zusaetzlich). Alle Prompts bleiben in dieser Datei
#   bzw. den Paket-Wizards (contract_lint 12d).
#   install: Grund-Angaben (Erstinstallation: alle; Bestand: _host_editable_keys ∪ in diesem Lauf gefragte) + ggf.
#            die Funktions-Wahl + die Paket-Fragen der Pakete dieses Laufs (_packages_to_process, je Runde neu —
#            die Funktions-Wahl kann sich in der Uebersicht aendern).
#   package: nur die Paket-Fragen der genannten Pakete (`lifeagents package install`).
# shellcheck disable=SC2034  # gelesen von provision.sh + pkg_cmd_install (der Aufrufer handelt)
REVIEW_RESULT=''
# shellcheck disable=SC2034  # s. o.
review_install_answers() {
  local mode="${1:-install}" items choice
  [ "$#" -gt 0 ] && shift
  REVIEW_RESULT=go
  ui_interactive || return 0
  ensure_gum
  ensure_jq_quiet || true
  while :; do
    items="$(_review_items "$mode" "$@")"
    _review_render "$items" | ui_box 'Übersicht — bitte prüfen' >&2
    choice="$(printf '%s\t%s\n' "Stimmt so — Installation starten" go "Eine Angabe ändern …" edit \
                "Abbrechen — nichts installieren" abort | ui_choose 'Alles richtig?' 0)"
    case "$choice" in
      go)   REVIEW_RESULT=go; return 0 ;;
      edit) _review_edit "$items" ;;
      *)    REVIEW_RESULT=abort; return 0 ;;   # Abbrechen, Esc, leere Eingabe
    esac
  done
}

# _review_items install|package [paket…] -> Zeilen "kind<TAB>pkg<TAB>id<TAB>label" (kind host|packages|cred|setting).
_review_items() {
  local mode="$1" k keys='' pkgs p
  shift
  if [ "$mode" = "install" ]; then
    if _is_first_install; then
      for k in $_INSTALL_ENV_KEYS; do
        if [ "$k" = "TRUSTED_PROXIES" ] && [ -z "${DOMAIN:-}" ]; then continue; fi
        keys="${keys:+$keys }$k"
      done
    else
      keys="$(_host_editable_keys | tr '\n' ' ')"
      for k in $UI_ASKED_KEYS; do   # in diesem Lauf gefragte Host-Keys (z. B. neu in einem Release) bleiben korrigierbar
        case " $_INSTALL_ENV_KEYS " in *" $k "*) case " $keys " in *" $k "*) : ;; *) keys="$keys $k" ;; esac ;; esac
      done
    fi
    for k in $keys; do printf 'host\t-\t%s\t%s\n' "$k" "$(_host_key_label "$k")"; done
    if _is_first_install && env_has_key "${INSTALL_ENV_FILE:-}" PACKAGES_SELECTED; then
      printf 'packages\t-\tPACKAGES\tFunktionen\n'
    fi
    pkgs="$(_packages_to_process "${PACKAGES_SPEC:-none}")"
  else
    pkgs="$(printf '%s\n' "$@")"
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _pkg_review_items "$p"
  done <<<"$pkgs"
  return 0
}

# _review_render <items> -> die Zeilen des Uebersichts-Kastens ("Beschriftung: Stand").
_review_render() {
  local kind pkg id label
  while IFS=$'\t' read -r kind pkg id label; do
    [ -n "$kind" ] || continue
    printf '%s: %s\n' "$label" "$(_review_status "$kind" "$pkg" "$id")"
  done <<<"$1"
  printf '\n(Geheime Werte werden nie angezeigt, nur ob sie gesetzt sind.)\n'
}

# _review_status <kind> <pkg> <id> -> der angezeigte Stand eines Punkts (Secrets nie im Klartext).
_review_status() {
  local kind="$1" pkg="$2" id="$3" v p names=''
  case "$kind" in
    host)
      eval "v=\${$id:-}"
      _host_key_def "$id"
      case "$id" in
        N8N_OWNER_PASSWORD) if [ -n "$v" ]; then printf 'selbst gewählt'; else printf 'wird erzeugt (am Ende einmal angezeigt)'; fi ;;
        DOMAIN)             printf '%s' "${v:-— nur Heimnetz (Telegram erreicht den Bot dann nicht)}" ;;
        TRUSTED_PROXIES)    if [ -z "$v" ] || [ "$v" = "127.0.0.1" ]; then printf 'auf diesem Rechner'; else printf 'auf %s' "$v"; fi ;;
        N8N_OWNER_EMAIL)    printf '%s' "${v:-— (Platzhalter-Adresse)}" ;;
        OWNER_LANGUAGE)     printf '%s' "$(_owner_language_name "${v:-de}")" ;;
        OWNER_PERSONA)      printf '%s' "$(_owner_persona_name "${v:-neutral}")" ;;
        *)
          if [ "$_HK_SECRET" = "1" ]; then
            if [ -n "$v" ]; then printf 'gesetzt'
            elif _host_key_required "$id"; then printf 'FEHLT (Pflicht)'
            else printf 'übersprungen'; fi
          else
            printf '%s' "${v:-—}"
          fi ;;
      esac ;;
    packages)
      for p in ${PACKAGES_SPEC//,/ }; do
        [ "$p" = "none" ] && continue
        names="${names:+$names, }$(pkg_display_name "$p")"
      done
      printf '%s' "${names:-nur Grundsystem}" ;;
    cred)    _pkg_review_cred_status "$pkg" "$id" ;;
    setting) _pkg_review_setting_status "$pkg" "$id" ;;
  esac
  return 0
}

# _drop_old_bot_webhook <alter-token> <neuer-token> <adresse> — Bot-Wechsel auf einer BESTANDSINSTANZ (Install-UX-Phase 7):
#   dem ALTEN Bot den Webhook nehmen — der Webhook-Geheimwert <wfId>_<nodeId> haengt nicht am Bot, der alte Bot lieferte
#   sonst weiter an diesen Server. Nur wenn sein Webhook nachweislich auf https://<adresse>/ zeigt (ein anderswo genutzter
#   Bot bleibt unangetastet); bei der Erstinstallation war der alte Token nie hier angebunden -> nichts tun. Token nur ueber
#   tg_api_curl (Config-Kanal, nie argv). Danach der /start-Hinweis fuer den neuen Bot. Best-effort, gibt immer 0 zurueck.
_drop_old_bot_webhook() {
  local old="$1" new="$2" dom="$3" url
  [ -n "$old" ] && [ "$old" != "$new" ] || return 0
  _is_first_install && return 0
  if [ -n "$dom" ]; then
    url="$(tg_api_curl "$old" getWebhookInfo -fsS --max-time 10 2>/dev/null | jq -r '.result.url // ""' 2>/dev/null || true)"
    if [ -n "$url" ] && [ "${url#"https://${dom}/"}" != "$url" ]; then
      if tg_api_curl "$old" deleteWebhook -fsS --max-time 10 -X POST \
           -H 'content-type: application/json' --data '{"drop_pending_updates":true}' >/dev/null 2>&1; then
        ok "Alter Bot: Webhook entfernt (er liefert nichts mehr an diesen Server)."
      else
        warn "Alter Bot: Webhook ließ sich nicht entfernen — unkritisch (alter Token schon ungültig?)."
      fi
    fi
  fi
  ui_box 'Neuer Telegram-Bot' <<'EOF'
Öffne deinen neuen Bot in Telegram und schreib ihm einmal /start — ein Bot darf dir erst
schreiben, wenn du ihn gestartet hast. Deine Verbindung bleibt bestehen (sie hängt an deinem
Telegram-Konto, nicht am Bot). Fehlt danach das Befehlsmenü:
lifeagents reconfigure → Grundsystem → „Unverändert neu anwenden“.
EOF
  return 0
}

# _review_edit <items> — EINEN Punkt erneut fragen (Enter = behalten) und speichern; Esc = zurueck zur Uebersicht.
#   Picker-Zeilen "label<TAB>kind:pkg:id" (ui_choose/gum trennen am ERSTEN TAB).
_review_edit() {
  local items="$1" pick kind rest pkg id v old_domain old_token
  pick="$(printf '%s\n' "$items" | awk -F '\t' 'NF >= 4 { printf "%s\t%s:%s:%s\n", $4, $1, $2, $3 }' \
            | ui_choose 'Welche Angabe ändern? (Esc = zurück zur Übersicht)' 0)"
  [ -n "$pick" ] || return 0
  kind="${pick%%:*}"; rest="${pick#*:}"; pkg="${rest%%:*}"; id="${rest#*:}"
  case "$kind" in
    host)
      if [ "$id" = "TRUSTED_PROXIES" ]; then
        _ask_trusted_proxies 1
        if [ -n "${TRUSTED_PROXIES:-}" ]; then _store_answer "${INSTALL_ENV_FILE:-}" TRUSTED_PROXIES "$TRUSTED_PROXIES"; fi
      elif [ "$id" = "OWNER_LANGUAGE" ]; then
        _ask_owner_language 1
        if [ -n "${OWNER_LANGUAGE:-}" ]; then _store_answer "${INSTALL_ENV_FILE:-}" OWNER_LANGUAGE "$OWNER_LANGUAGE"; fi
      elif [ "$id" = "OWNER_PERSONA" ]; then
        _ask_owner_persona 1
        if [ -n "${OWNER_PERSONA:-}" ]; then _store_answer "${INSTALL_ENV_FILE:-}" OWNER_PERSONA "$OWNER_PERSONA"; fi
      else
        old_domain="${DOMAIN:-}"; old_token="${TELEGRAM_BOT_TOKEN:-}"
        _host_key_ask "$id" 1
        eval "v=\${$id:-}"
        _store_answer "${INSTALL_ENV_FILE:-}" "$id" "$v"
        if [ "$id" = "TELEGRAM_BOT_TOKEN" ]; then _drop_old_bot_webhook "$old_token" "$v" "${DOMAIN:-}"; fi
        # Neu eine Adresse -> jetzt auch die Proxy-Frage (sie gibt es nur mit Adresse; speichert selbst).
        if [ "$id" = "DOMAIN" ] && [ -z "$old_domain" ] && [ -n "${DOMAIN:-}" ]; then _ask_trusted_proxies; fi
      fi ;;
    packages)
      _ask_initial_packages 1
      v=''; [ "${PACKAGES_SPEC:-none}" = "none" ] || v="$PACKAGES_SPEC"
      _store_answer "${INSTALL_ENV_FILE:-}" PACKAGES_SELECTED "$v"
      # Neu gewaehlte Pakete bringen ihre Fragen mit (schon beantwortete fragt das Seen-Gate nicht erneut).
      # shellcheck disable=SC2046  # Paketnamen sind ^[a-z][a-z0-9_]*$ (kein Globbing/Leerzeichen)
      collect_package_inputs $(_packages_to_process "${PACKAGES_SPEC:-none}") ;;
    cred)    _pkg_secrets_wizard "$pkg" "$(lifeagents_env_file "$pkg")" 1 "$id" ;;
    setting) _pkg_settings_wizard "$pkg" 1 "$id" ;;
  esac
  return 0
}
