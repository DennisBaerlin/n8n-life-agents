# config_cli.sh — Runtime-CLI fuer den zentralen Config-Store (core.config).
# SOURCED (kein Shebang, kein `set -e` — der Top-Aufrufer `lifeagents` traegt den Error-Mode).
#
# Aufruf: `lifeagents config <verb> [args]` (die CLI sourct diese Datei + common.sh).
# DB-Zugriff: postgres-Superuser via runuser/Peer-Auth am lokalen Socket (host-vermittelt, wie
# pkg_lifecycle.sh/apply_schema.sh).
#
# Zugriffsmodell (Owner-Direktive, Plan §2/§WP5): Config ist EIN flacher zentraler Store mit global
# eindeutigem (category,key); die `package`-Spalte ist Vor-Installations-Deklaration (Manifest) und
# reine INFO — per CLI NIE aenderbar (write-own: die CLI setzt nur Werte, nie die Paket-Zuordnung).
# `set` ist UPDATE-only (kein INSERT) -> ein unbekannter Key ist ein Fehler, kein stiller Drift; die
# Defaults deklariert das Manifest (.config-Block), der Installer-Seeder (_seed_package_config) legt
# die Zeilen an. Die DB prueft jeden neuen Wert (category='model': bekanntes Modell derselben Art wie der Standard,
# core.fn_model_value_eligible + Fremdschluessel; value_type/Grenzen,
# z. B. Zeitplan oder ganze Zahl, trg_config_check_value_type) und meldet bei Ablehnung, was erwartet wird.
#
# Jede Zeile, die `list` zeigt, wirkt: Systemwerte (managed_by='system', z. B. api.core_version) sind ausgeblendet
# und nicht aenderbar; ein Zeitplan (category='schedule') steckt im Workflow (n8n liest ihn nur beim Aktivieren)
# -> nach `set`/`reset` spielt die CLI die Workflows des besitzenden Pakets neu ein (_cfg_apply_schedule).

DB_SUPERUSER="${DB_SUPERUSER:-postgres}"

# N8N_DB_NAME aus der n8n.env ableiten (Runtime-CLI laeuft ausserhalb von provision.sh) — eine Adresse: common.sh.
_cfg_resolve_db() { lifeagents_db_name >/dev/null; }

# _cfg_psql <psql-args...>  -> psql als postgres-Superuser am lokalen Socket (ON_ERROR_STOP).
# -q (quiet) unterdrueckt den Command-Status-Tag ("UPDATE 0/1") -> bei `set` liefert RETURNING auf
# eine nicht-existente Zeile WIRKLICH leeren stdout (sonst maskiert "UPDATE 0" die 0-Treffer-Erkennung);
# Ergebniszeilen von SELECT bleiben unberuehrt.
# VERBOSITY=terse: eine abgelehnte Eingabe zeigt nur die DB-Meldung ("Ungültiger Wert … — erwartet: …"), ohne die
# technische CONTEXT-Zeile der PL/pgSQL-Funktion.
_cfg_psql() {
  _cfg_resolve_db
  runuser -u "$DB_SUPERUSER" -- psql -v ON_ERROR_STOP=1 -v VERBOSITY=terse -X -q -d "$N8N_DB_NAME" "$@"
}

# _cfg_ident_ok <s>  -> 0 wenn ^[a-z][a-z0-9_]*$ (category/key-Vertrag; Injection-Schutz VOR Interpolation).
_cfg_ident_ok() { printf '%s' "$1" | grep -qE '^[a-z][a-z0-9_]*$'; }

# _cfg_managed_by <category> <key>  -> 'owner' | 'system' | '' (Zeile fehlt). Argumente vorher ident-geprueft.
_cfg_managed_by() {
  _cfg_psql -tA -c "SELECT managed_by FROM core.config WHERE category = '$1' AND key = '$2'" 2>/dev/null || true
}

# _cfg_apply_schedule <category> <key>  — nach set/reset: ist es ein Zeitplan, die Workflows des besitzenden Pakets
#   neu einspielen. deploy_workflows setzt den Wert aus core.config ein und meldet den alten Zeitplan vorher ab ->
#   der neue gilt sofort, ohne n8n-Neustart. Nicht installiertes Paket -> nichts zu tun (der Wert gilt ab der
#   Installation). Laeuft in einer Subshell (deploy_workflows kann `die`n); Fehlschlag = Warnung, der Wert ist
#   trotzdem gespeichert und wirkt beim naechsten `lifeagents update`.
_cfg_apply_schedule() {
  [ "$1" = "schedule" ] || return 0
  local pkg status
  pkg="$(_cfg_psql -tA -c "SELECT package FROM core.config WHERE category = 'schedule' AND key = '$2'" 2>/dev/null || true)"
  _cfg_ident_ok "$pkg" || { warn "Besitzendes Paket von schedule/$2 unbekannt — Zeitplan wirkt nach 'lifeagents update'."; return 0; }
  status="$(_cfg_psql -tA -c "SELECT status FROM core.package_registry WHERE package = '${pkg}'" 2>/dev/null || true)"
  case "$status" in
    active|inactive) ;;
    *) log "Paket '$pkg' ist nicht installiert — der Zeitplan gilt ab der Installation."; return 0 ;;
  esac
  log "Zeitplan geändert -> Workflows von '$pkg' neu einspielen ..."
  _pkg_resolve_env
  # DEPLOY_STRICT_ACTIVATE=1: lief ein deaktivierter Workflow danach NICHT wieder an, ist das ein Fehler (sonst
  # meldete die CLI "aktiv", waehrend der Zeitplan-Workflow stillsteht).
  if ( DEPLOY_STRICT_ACTIVATE=1 deploy_workflows "$pkg" ); then
    ok "Neuer Zeitplan für ${2} ist aktiv."
  else
    warn "Workflows von '$pkg' konnten nicht (vollständig) neu eingespielt bzw. aktiviert werden — der Wert ist gespeichert; 'lifeagents doctor' prüft, 'lifeagents update' spielt erneut ein."
  fi
}

# --- list: alle Config-Zeilen, je Paket eine Ueberschrift, je Eintrag zwei Zeilen -------------------
# Reine ANZEIGE (zweizeilig, auch ohne Terminal; kein --plain/--json — Skripte lesen core.config direkt, nie diese
# Ausgabe): `category/key = value [*]` + darunter eingerueckt der deutsche Einzeiler `summary` (Manifest-Feld
# `.config.<c>.<k>.summary`; `description` bleibt englischer Entwickler-Text und wird hier bewusst NICHT gezeigt).
# Grundsystem (core) zuerst, dann die Pakete alphabetisch; Ueberschrift im ui_section-Plain-Stil.
config_cmd_list() {
  local rows out='' c_head='' c_dim='' c_rst='' wrap=0 width=0 cols
  local pkg label category key mark sum val cur='' wrapped line shown
  # Farbe + Breite EINMAL vorab: danach geht stdout ggf. in die Pipe zum Pager (ui_page) und waere kein TTY mehr.
  # Eigene Codes statt _C_CYAN/_C_RST (common.sh): die richten sich nach stderr (fd 2), die Liste geht auf stdout;
  # Ueberschrift im Plain-Stil von ui_section, das selbst auf stderr schreibt.
  if ui_color_enabled 1; then c_head=$'\033[0;36m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'; fi
  if [ -t 1 ]; then
    cols="$(tput cols 2>/dev/null || true)"      # ohne TERM scheitert tput -> Fallback 80
    case "$cols" in '' | *[!0-9]*) cols=80 ;; esac
    width=$((cols - 6))
    if [ "$width" -lt 40 ]; then width=40; fi
    wrap=1
  fi
  # Trenner \x1f statt \t: summary/value koennen leer sein, und bash `read` kollabiert konsekutive Tabs (Tab ist
  # IFS-whitespace, gleiche Begruendung wie seed_data.sh _seed_package_config). value als LETZTE Spalte -> `read`
  # haengt den Rest dort an. mark = '*' wenn der Wert vom ausgelieferten Default abweicht (conffile,
  # core.fn_config_seed) — solche Werte ueberleben Updates; `lifeagents config reset` holt den Default zurueck.
  rows="$(_cfg_psql -tA -F $'\x1f' -c \
    "SELECT c.package, COALESCE(NULLIF(r.display_name, ''), c.package), c.category, c.key,
            CASE WHEN c.default_value IS NULL OR c.value IS DISTINCT FROM c.default_value THEN '*' ELSE ' ' END,
            c.summary, c.value
       FROM core.config c LEFT JOIN core.package_registry r USING (package)
      WHERE c.managed_by = 'owner'
      ORDER BY (c.package <> 'core'), c.package, c.category, c.key")" || \
    die "Config-Abfrage fehlgeschlagen (Schema angewandt?)."
  if [ -z "$rows" ]; then log "core.config ist leer."; return 0; fi
  while IFS=$'\x1f' read -r pkg label category key mark sum val; do
    [ -n "$pkg" ] || continue
    if [ "$pkg" != "$cur" ]; then
      if [ -n "$cur" ]; then out+=$'\n'; fi
      out+="${c_head}--- ${label} (${pkg}) ---${c_rst}"$'\n'
      cur="$pkg"
    fi
    shown="$val"
    if [ -z "$shown" ]; then shown="${c_dim}(leer)${c_rst}"; fi
    out+="  ${category}/${key} = ${shown}"
    if [ "$mark" = "*" ]; then out+=" *"; fi
    out+=$'\n'
    # leer = Zeile noch nicht neu geseedet (Update vor diesem Release) -> sichtbar statt still.
    if [ -z "$sum" ]; then sum='(keine Beschreibung — lifeagents update)'; fi
    # Erst den reinen Text umbrechen, DANN je Zeile einfaerben (Farbcodes zaehlten sonst als Breite). fold zaehlt
    # Bytes -> Umlaute brechen minimal frueher um, nie ueber den Rand. Ohne Terminal: eine Zeile.
    if [ "$wrap" = 1 ]; then wrapped="$(printf '%s\n' "$sum" | fold -s -w "$width")"; else wrapped="$sum"; fi
    while IFS= read -r line; do
      out+="      ${c_dim}${line% }${c_rst}"$'\n'
    done <<<"$wrapped"
  done <<<"$rows"
  out+=$'\n''* = von dir angepasst (bleibt bei Updates erhalten; Standard zurück: lifeagents config reset <category> <key>)'
  printf '%s\n' "$out" | ui_page
}

# --- reset: Wert EINER Zeile auf den ausgelieferten Standard zuruecksetzen (core.fn_config_reset) -----
config_cmd_reset() {
  if [ "$#" -eq 0 ] && ui_interactive; then
    ensure_gum
    local pick
    pick="$(_cfg_psql -tA -F $'\t' -c \
      "SELECT category || '/' || key || ' = ' || value || '   (Standard: ' || COALESCE(default_value,'?') || ')', category || ' ' || key
         FROM core.config WHERE managed_by = 'owner' AND default_value IS NOT NULL AND value IS DISTINCT FROM default_value
        ORDER BY package, category, key" 2>/dev/null \
      | ui_choose 'Angepassten Wert auf den Standard zurücksetzen:' 0 || true)"
    [ -n "$pick" ] && set -- "${pick%% *}" "${pick##* }"
  fi
  if [ "$#" -lt 2 ]; then die "Usage: lifeagents config reset <category> <key>"; fi
  local category="$1" key="$2" res ok_flag val
  _cfg_ident_ok "$category" || die "Ungueltige category (erwarte ^[a-z][a-z0-9_]*\$): $category"
  _cfg_ident_ok "$key"      || die "Ungueltiger key (erwarte ^[a-z][a-z0-9_]*\$): $key"
  [ "$(_cfg_managed_by "$category" "$key")" != "system" ] || \
    die "${category}.${key} ist ein Systemwert (setzt jedes Update selbst) und nicht änderbar."
  res="$(_cfg_psql -tA -c "SELECT core.fn_config_reset(jsonb_build_object('category','${category}','key','${key}'))")" || \
    die "Config-Reset fehlgeschlagen (Schema angewandt?)."
  ok_flag="$(printf '%s' "$res" | jq -r '.ok // false' 2>/dev/null || echo false)"
  [ "$ok_flag" = "true" ] || die "Unbekannter Config-Key '${category}.${key}' oder kein Standard hinterlegt."
  val="$(printf '%s' "$res" | jq -r '.value // ""' 2>/dev/null || true)"
  ok "core.config: ${category}.${key} auf den Standard zurückgesetzt ('${val}')."
  _cfg_apply_schedule "$category" "$key"
}

# --- set: Wert EINER bestehenden Zeile setzen (UPDATE-only, kein INSERT, package-Ownership fix) ----
config_cmd_set() {
  # Missing-Arg-Picker (E3, NUR beim voll-leeren Aufruf — Teil-Aufrufe behalten die heutige Usage,
  # KISS): Key-Auswahl aus core.config; der Picker-VALUE traegt "category key" (beide Tokens
  # ident-gepinnt ^[a-z][a-z0-9_]*$ -> space-safe splitbar, Plan-Kritik C5). Wert danach: bei
  # category='model' ein zweiter Picker ueber die passenden agent.ai_models (der DB-Trigger validiert ohnehin),
  # sonst ui_input. Abbruch an jeder Stelle -> unveraenderte Usage (E5a). `|| true` je Pipeline:
  # eine fehlende Registry/Schema darf unter set -e nicht crashen, sondern leer -> Usage.
  if [ "$#" -eq 0 ] && ui_interactive; then
    ensure_gum
    local pick
    pick="$(_cfg_psql -tA -F $'\t' -c \
      "SELECT category || '/' || key || ' = ' || value || '   [' || package || ']', category || ' ' || key FROM core.config WHERE managed_by = 'owner' ORDER BY package, category, key" 2>/dev/null \
      | ui_choose 'Config-Eintrag aendern:' 0 || true)"
    if [ -n "$pick" ]; then
      local p_category="${pick%% *}" p_key="${pick##* }" p_value="" p_info p_sum p_cur p_def
      # Erklaer-Kasten VOR der Eingabe (Muster _prompt_validated: printf help | ui_box >&2): der deutsche
      # Einzeiler `summary` + aktueller Wert + Standard. Erst ident-pruefen (Interpolation), Fehlschlag -> kein
      # Kasten (die Pruefung unten bricht dann ohnehin ab).
      if _cfg_ident_ok "$p_category" && _cfg_ident_ok "$p_key"; then
        p_info="$(_cfg_psql -tA -F $'\x1f' -c \
          "SELECT COALESCE(NULLIF(summary, ''), '(keine Beschreibung — lifeagents update)'),
                  CASE WHEN value = '' THEN '(leer)' ELSE value END,
                  CASE WHEN default_value IS NULL THEN '—' WHEN default_value = '' THEN '(leer)' ELSE default_value END,
                  CASE WHEN value_type = 'string' THEN '' ELSE core.fn_config_value_expectation(value_type, minimum, maximum) END
             FROM core.config WHERE category = '${p_category}' AND key = '${p_key}'" 2>/dev/null || true)"
        if [ -n "$p_info" ]; then
          IFS=$'\x1f' read -r p_sum p_cur p_def p_exp <<<"$p_info" || true
          { printf '%s\n\nAktuell: %s   Standard: %s\n' "$p_sum" "$p_cur" "$p_def"
            if [ -n "$p_exp" ]; then printf 'Erwartet: %s\n' "$p_exp"; fi
          } | ui_box "${p_category}/${p_key}" >&2
        fi
      fi
      if [ "$p_category" = "model" ] && _cfg_ident_ok "$p_key"; then
        # Nur Modelle, die der Eintrag annimmt (core.fn_model_value_eligible: gleiche Modell-Art wie sein Standard —
        # dieselbe Regel wie der DB-Trigger), in Umschalter-Reihenfolge, mit der gepinnten Version dahinter.
        p_value="$(_cfg_psql -tA -F $'\t' -c \
          "SELECT m.model_key || '   (' || m.n8n_model_id || ')', m.model_key FROM agent.ai_models m
            WHERE core.fn_model_value_eligible(m.model_key,
                    (SELECT c.default_value FROM core.config c WHERE c.category = 'model' AND c.key = '${p_key}'))
            ORDER BY m.selector_index NULLS LAST, m.model_key" 2>/dev/null \
          | ui_choose "Neues Modell für ${p_key}:" 0 || true)"
      else
        p_value="$(ui_input "Neuer Wert für ${p_category}.${p_key}: ")"
      fi
      [ -n "$p_value" ] && set -- "$p_category" "$p_key" "$p_value"
    fi
  fi
  if [ "$#" -lt 3 ]; then die "Usage: lifeagents config set <category> <key> <value>"; fi
  local category="$1" key="$2" value="$3"
  _cfg_ident_ok "$category" || die "Ungueltige category (erwarte ^[a-z][a-z0-9_]*\$): $category"
  _cfg_ident_ok "$key"      || die "Ungueltiger key (erwarte ^[a-z][a-z0-9_]*\$): $key"
  [ "$(_cfg_managed_by "$category" "$key")" != "system" ] || \
    die "${category}.${key} ist ein Systemwert (setzt jedes Update selbst) und nicht änderbar."

  # category/key sind ident-validiert; der Wert wird als SQL-Literal interpoliert -> Quotes verdoppeln.
  # UPDATE-only + RETURNING: matcht die (category,key)-Zeile NICHT -> leere Rueckgabe -> Fehler (kein
  # stiller INSERT); lehnt die DB den Wert ab (Modell unbekannt, falscher Typ/ausserhalb der Grenzen) -> psql zeigt
  # ihre Meldung (was erwartet wird) auf stderr, ON_ERROR_STOP -> nonzero -> Fehler. managed_by='owner' im WHERE =
  # Gurt zum Hosentraeger oben (ein Systemwert wird nie per CLI geschrieben).
  local v_esc="${value//\'/\'\'}" updated
  updated="$(_cfg_psql -tA -c \
    "UPDATE core.config SET value = '${v_esc}' WHERE category = '${category}' AND key = '${key}' AND managed_by = 'owner' RETURNING key")" || \
    die "Wert für ${category}.${key} abgelehnt (Grund siehe Meldung oben) — nichts geändert."
  if [ -z "$updated" ]; then
    die "Unbekannter Config-Key '${category}.${key}' — in core.config nicht vorhanden. Config-Keys werden in den Paket-Manifesten (.config) deklariert + vom Seeder angelegt; die CLI legt keine neuen Zeilen an."
  fi
  ok "core.config: ${category}.${key} = '${value}' gesetzt (package-Ownership unveraendert)."
  _cfg_apply_schedule "$category" "$key"
}

# --- Dispatcher: `lifeagents config <verb> [args]` ------------------------------------------------
config_cli() {
  # Verb-Picker: nacktes `lifeagents config` auf TTY -> Menue statt Hilfetext; ESC/non-TTY ->
  # Hilfetext wie bisher (Exit 0, E5b).
  if [ "$#" -eq 0 ] && ui_interactive; then
    ensure_gum
    local _menu_verb
    _menu_verb="$(ui_choose 'lifeagents config — was tun?' 0 <<'MENU'
list — Alle Config-Zeilen anzeigen	list
set — Einen Wert ändern (Auswahl-Liste)	set
reset — Angepassten Wert auf den Standard zurücksetzen	reset
help — Hilfe anzeigen	help
MENU
)"
    [ -n "$_menu_verb" ] && set -- "$_menu_verb"
  fi
  local verb="${1:-help}"; shift || true
  case "$verb" in
    list)   config_cmd_list "$@" ;;
    set)    config_cmd_set "$@" ;;
    reset)  config_cmd_reset "$@" ;;
    help|--help|-h)
      cat >&2 <<'EOF'
lifeagents config <verb> — zentralen Config-Store (core.config) ansehen/ändern.

  list                          Alle Config-Zeilen je Paket, mit einem Satz, was die Einstellung bewirkt.
                                Read-only. '*' markiert Werte, die du angepasst hast.
  set <category> <key> <value>  Wert einer BESTEHENDEN Zeile setzen (UPDATE-only, kein INSERT).
                                Die package-Ownership bleibt unangetastet (Manifest-Deklaration).
                                Angepasste Werte bleiben bei Updates erhalten.
                                Cron abschalten z. B.: lifeagents config set cron_enable refresh_fx_rates false
                                Zeitplan ändern z. B.: lifeagents config set schedule score_jobs '0 7 * * 1-5'
                                (gilt sofort — die Workflows des Pakets werden neu eingespielt).
  reset <category> <key>        Einen angepassten Wert auf den ausgelieferten Standard zurücksetzen.

Hinweis: neue Keys legt die CLI NICHT an — sie kommen aus den Paket-Manifesten (.config-Block) über
den Installer-Seeder. Die Datenbank prüft jeden Wert (Modell bekannt, Zeitplan/Zahl/true-false gültig)
und sagt bei Ablehnung, was erwartet wird.
EOF
      ;;
    *) err "lifeagents config: unbekannter Verb: $verb"; config_cli help; return 1 ;;
  esac
}
