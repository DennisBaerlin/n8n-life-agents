# seed_data.sh — getrackte Daten-Seeds in eine frische Instanz laden (Phase 6).
# Sourced by provision.sh. Definiert seed_data().
#
# WARUM: apply_schema legt nur die LEEREN Tabellen an (CREATE … IF NOT EXISTS). Die
# ZEILEN — Modell-Registry, Zentral-Config UND die Agent-Instruktions-Contexts — leben in
# getrackten Artefakten: packages/core/seed/ai_models.json, die .config-Bloecke der
# packages/*/manifest.json und packages/*/contexts/*.md. Ein frisches Release ohne Seed
# haette leere core.config / agent.ai_models / core_contexts -> Agenten ohne Modell, ohne
# Config, OHNE System-Prompt = funktionslos. seed_data() ist DER Seeder (Dev/Test wie Prod;
# die fruehere Autoren-Werkzeugkette n8n_push ist retired).
#
# REIHENFOLGE (Pflicht): ai_models VOR config (der core.config-Modell-Trigger referenziert
# agent.ai_models.model_key). Danach die Contexts.
#
# SEED vs. ONBOARDING (Privacy-Trennlinie, Plan Phase 6):
#   - SEED (hier, getrackt, KEINE PII): die Agent-Instruktionen + global_instructions +
#     trigger_design (englische Modell-Instruktionen / System-Protokoll). managed_by='seed'.
#   - ONBOARDING (NICHT hier, PII): family/finance_profile/financial_planning (managed_by=
#     'agent') sowie die persoenlichen Lazy-Docs (vehicles/financial_planning/career_planning/
#     shared_memory) — die fuellt der Owner/Guide zur Laufzeit. Sie liegen im .local-Mirror
#     (gitignored) und kommen NIE in den Tarball.
# capabilities_catalog (GENERIERT von build.ps1, getrackt, keine PII) wird als managed_by='build'
# mitgeseedet — exakt wie n8n_push Sektion 1c.
#
# Laeuft als postgres-Superuser (runuser, peer-Auth) in EINER psql-Session, ON_ERROR_STOP=1.
# Der Treiber ist 0644 in /tmp — zulaessig, weil ALLE Inhalte hier PII-frei sind (genau das ist
# der Sinn der Seed/Onboarding-Trennung; PII laeuft ueber die 600-Treiber in bootstrap_owner.sh).
#
# Reads globals (provision.sh): REPO_ROOT, N8N_DB_NAME.

DB_SUPERUSER="${DB_SUPERUSER:-postgres}"

# _seed_psql … — psql als postgres-Superuser gegen die n8n-DB (peer-Auth, ON_ERROR_STOP, -X).
_seed_psql() {
  runuser -u "$DB_SUPERUSER" -- psql -v ON_ERROR_STOP=1 -X -d "$N8N_DB_NAME" "$@"
}

# _sql_str <value>  → in SQL-Single-Quotes gewrappter, escapeter String ('' fuer eingebettete ').
# Leerer Wert -> '' (leerer String), NICHT NULL (Aufrufer entscheidet NULL separat).
_sql_str() {
  local v="${1//\'/\'\'}"
  printf "'%s'" "$v"
}

# _seed_skip_pkg <pkg>  -> 0 (= skip) wenn SEED_PKG gesetzt ist UND != pkg; sonst 1 (nicht skippen).
# Phase 5: derselbe Seeder-Code dient dem Monolith (SEED_PKG leer = alle Pakete) UND dem per-Paket-
# Install (SEED_PKG=<pkg> = nur dieses Paket) — EIN Code-Pfad, kein Cross-Package-Side-Effect.
_seed_skip_pkg() { [ -n "${SEED_PKG:-}" ] && [ "${SEED_PKG}" != "$1" ]; }

# --- (1) agent.ai_models  ----------------------------------------------------
# jq liefert metadaten-flache TSV-Zeilen (Werte ohne Tabs/Newlines by construction); bash baut
# das UPSERT (identische Semantik zu n8n_push 1b).
_seed_ai_models() {
  _seed_skip_pkg core && return 0   # ai_models ist core-eigen
  local file="$REPO_ROOT/packages/core/seed/ai_models.json"
  [ -f "$file" ] || { warn "Seed fehlt: $file — ai_models uebersprungen."; return 0; }
  # mode (chat|embedding, core:V024) zusammen mit selector_index: der CHECK ai_models_mode_selector_check
  # koppelt beide, deshalb setzt das UPSERT sie in derselben Zeile. Je Modell eine Anweisung in JSON-Reihenfolge
  # -> das Umnummerieren (z. B. 2/4/6 -> 1/2/3 nach V024) kollidiert nie mit dem UNIQUE auf selector_index.
  # pricing_usd_per_mtok (Kosten-Report) als kompaktes JSON (enthaelt keine Tabs/Newlines); fehlt es -> SQL NULL.
  jq -r '.[] | [.model_key, .provider, .n8n_model_id, (.selector_index|tostring), .mode, (.pricing_usd_per_mtok // null | tojson)] | @tsv' "$file" |
  while IFS=$'\t' read -r mk pv mid si md pr; do
    [ -n "$mk" ] || continue
    local prsql='NULL'
    [ "$pr" = 'null' ] || prsql="$(_sql_str "$pr")::jsonb"
    printf 'INSERT INTO agent.ai_models (model_key, provider, n8n_model_id, selector_index, mode, pricing_usd_per_mtok)\n'
    printf 'VALUES (%s, %s, %s, %s, %s, %s)\n' "$(_sql_str "$mk")" "$(_sql_str "$pv")" "$(_sql_str "$mid")" "$si" "$(_sql_str "$md")" "$prsql"
    printf 'ON CONFLICT (model_key) DO UPDATE SET provider=EXCLUDED.provider, n8n_model_id=EXCLUDED.n8n_model_id, selector_index=EXCLUDED.selector_index, mode=EXCLUDED.mode, pricing_usd_per_mtok=EXCLUDED.pricing_usd_per_mtok;\n'
  done
}

# --- (2) core.config — generischer per-Paket-Config-Seeder (WS4a) ------------
# Jedes Paket DEKLARIERT seine Config im manifest.json (.config: {category:{key:{value,description,summary}}});
# der HOST laedt sie paket-skopiert (package=<pkg>) in core.config. Loest _seed_config (packages/core/
# seed/config.json, retired) ab — 'core' ist nur ein erweitertes privilegiertes Paket und deklariert
# seine Config genauso im Manifest. Upsert-Regel = core.fn_config_seed (Install-UX-Phase 4, dpkg-conffile):
#   der Manifest-Wert ist der DEFAULT (default_value wird immer nachgezogen); value folgt ihm nur, solange der
#   Owner ihn nie geaendert hat — `lifeagents config set`/Wizard-/Agent-Werte ueberleben jedes Update.
#   cron_enable = Laufzeit-Schalter (nie ueberschrieben; der Erst-Seed legt die Default-Zeile an = Garantie fuers
#   fail-closed Cron-Gate), api.* = System-Werte (immer ueberschrieben). Vorher: DO UPDATE value=EXCLUDED.value.
# description (EN Entwickler-Text) optional; summary = DE Owner-Einzeiler fuer `lifeagents config list`
# (contract_lint erzwingt ihn). UNIQUE(category,key) bleibt global -> die CLI adressiert eine Zeile ohne Paket.
_seed_package_config() {
  local mf pkg cat key val desc sum typ min max mby
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    _seed_skip_pkg "$(jq -r '.name // empty' "$mf")" && continue
    # Feld-Trenner = Unit-Separator (\x1f), NICHT \t: bash `read` mit IFS=$'\t' KOLLABIERT konsekutive Tabs
    # (Tab ist IFS-whitespace) -> ein LEERER value (z. B. estate.general.bundesland = fail-closed-Default '')
    # bekaeme sonst die description in val geschoben. \x1f ist Nicht-whitespace -> leere Felder bleiben leer.
    # type/minimum/maximum/managed_by (Wert-Pruefung + System-Werte, core.config_init.sql): fehlt ein Feld -> ''
    # -> core.fn_config_seed nimmt den Default (string / keine Grenze / owner). minimum/maximum sind JSON-Zahlen.
    jq -r '.name as $pkg | (.config // {}) | to_entries[] | select(.key != "_comment")
           | .key as $cat | .value | to_entries[] | select(.key != "_comment")
           | [$pkg, $cat, .key, (.value.value // ""), (.value.description // ""), (.value.summary // ""),
              (.value.type // ""), (.value.minimum // "" | tostring), (.value.maximum // "" | tostring),
              (.value.managed_by // "")] | join("")' "$mf" |
    while IFS=$'\x1f' read -r pkg cat key val desc sum typ min max mby; do
      [ -n "$pkg" ] && [ -n "$cat" ] || continue
      printf 'SELECT core.fn_config_seed(jsonb_build_object(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s));\n' \
        "'category'" "$(_sql_str "$cat")" "'key'" "$(_sql_str "$key")" "'value'" "$(_sql_str "$val")" \
        "'description'" "$(_sql_str "$desc")" "'summary'" "$(_sql_str "$sum")" "'package'" "$(_sql_str "$pkg")" \
        "'type'" "$(_sql_str "$typ")" "'minimum'" "$(_sql_str "$min")" "'maximum'" "$(_sql_str "$max")" \
        "'managed_by'" "$(_sql_str "$mby")"
    done
  done
}

# --- Markdown-Context-Seed (capabilities_catalog + packages/*/contexts/*.md) -----
# Frontmatter (--- … ---) + Body trennen; Body via Dollar-Quoting (beliebiger Inhalt, inkl.
# '---' im Body). managed_by wird vom Aufrufer gesetzt (build|seed).
#
# _seed_context_md <file> <managed_by> [package]
#   package = besitzendes Paket (Lifecycle-/Uninstall-Purge-Key) und managed_by = Sync-Provenienz
#   (seed|build|agent) sind seit D14/WS-B2 TYPISIERTE Spalten auf agent.core_contexts (vorher
#   metadata.package/.managed_by). metadata wird hier auf '{}' gesetzt; das Loeschschutz-Flag
#   (protected) stempelt util_protect_contexts danach additiv ein (s. _seed_contexts).
_seed_context_md() {
  local file="$1" managed="$2" pkg="${3:-core}"
  [ -f "$file" ] || return 0
  local name; name="$(basename "$file" .md)"
  # BOM (falls vorhanden) defensiv strippen, sonst matcht /^---/ nicht.
  local clean; clean="$(sed '1s/^\xEF\xBB\xBF//' "$file")"

  # Frontmatter = Zeilen zwischen dem 1. und 2. '---'. Body = ALLES nach dem 2. '---'
  # (die Body-awk druckt erst, DANN inkrementiert -> ein '---' im Body bleibt erhalten).
  local fm body desc agent strat
  fm="$(printf '%s\n' "$clean"  | awk '/^---[[:space:]]*$/{c++; next} c==1{print}')"
  body="$(printf '%s\n' "$clean" | awk 'c>=2{print} /^---[[:space:]]*$/{c++}')"

  desc="$(printf '%s\n' "$fm"  | grep -E '^description:'   | head -n1 | sed -E 's/^description:[[:space:]]*//')"
  agent="$(printf '%s\n' "$fm" | grep -E '^agent_name:'    | head -n1 | sed -E 's/^agent_name:[[:space:]]*//')"
  strat="$(printf '%s\n' "$fm" | grep -E '^load_strategy:' | head -n1 | sed -E 's/^load_strategy:[[:space:]]*//')"
  [ -n "$strat" ] || strat="lazy"

  local agent_sql='NULL'
  [ -n "$agent" ] && agent_sql="$(_sql_str "$agent")"

  # Eindeutiges Dollar-Quote-Tag (Kollision mit dem Body praktisch ausgeschlossen).
  local tag; tag="ctxbody$(rand_hex 6)"

  printf 'INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)\n'
  printf 'VALUES (%s, %s, %s, %s, $%s$%s$%s$, %s, %s, %s)\n' \
    "$(_sql_str "$name")" "$(_sql_str "$desc")" "$agent_sql" "$(_sql_str "$strat")" \
    "$tag" "$body" "$tag" "$(_sql_str "$managed")" "$(_sql_str "$pkg")" "'{}'::jsonb"
  # Conffile-Guard (WS-1, arch-challenge D1 — dpkg-conffile-Semantik): eine Zeile, die der Owner
  # uebernommen hat (managed_by='agent': Prompt-Import, WS-5-Feedback-Tool, Laufzeit-PII), wird vom
  # Re-Seed NIE ueberschrieben — der Paket-Default gilt nur, solange der Nutzer nicht angefasst hat.
  # protected_contexts (§3.4) schuetzt nur vor DELETE; DIESER Guard schuetzt vor UPDATE-Clobber.
  # GEGENSTUECK core.fn_reset_user_data: managed_by='agent' gilt dort als Laufzeit-Daten und wird beim
  # Werkszustand-Reset GELOESCHT -> ein kuenftiger Uebernahme-Pfad braucht eine eigene Provenienz
  # (z. B. 'owner'), nicht 'agent' (heute existiert keiner).
  printf 'ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, agent_name=EXCLUDED.agent_name, load_strategy=EXCLUDED.load_strategy, content=EXCLUDED.content, managed_by=EXCLUDED.managed_by, package=EXCLUDED.package, metadata=EXCLUDED.metadata WHERE core_contexts.managed_by <> %s;\n' "$(_sql_str 'agent')"
}

# --- Capabilities-Katalog (/help + Guide) aus den Fragmenten der INSTALLIERTEN Pakete, je Sprache -------------
# Install-UX-Phase 4 (Paket-Modularitaet) + Textkatalog Phase B: build.ps1 rendert je Paket UND Katalogsprache ein
# Fragment (packages/<pkg>/seed/capabilities_catalog/<lang>.fragment.md) und je Sprache die komponierte Uebersicht
# (packages/core/seed/capabilities_catalog/<lang>.md) aus ALLEN Paketen. Der Installer komponiert zur Laufzeit je
# Sprache: Kopf (bis zur ersten '## '-Kategorie) der komponierten Datei + die Fragmente von Core + jedem 'active'
# Paket in core.package_registry (dieselbe Regel wie Telegram-Menue + Onboarding) (+ dem gerade geseedeten SEED_PKG,
# das in Stufe 5 noch 'installing' ist), sortiert nach Manifest catalog.ord. Gleiche Reihenfolge-/Strip-Regel wie
# Build-ComposedCatalog (scripts/build/lib/catalog.ps1).
#
# Install-UX-Phase 6: Zusatz-Sektion „Weitere Funktionen" am Ende (gebuendelte, aber nicht aktive Pakete mit
# Einzeiler + dem richtigen Server-Befehl, Texte core.help.more_* + <pkg>.package.*) — gleiche Zustands-Regel wie
# installed_packages (_pkg_state_rows).
# _capabilities_catalog_md <lang>
_capabilities_catalog_md() {
  local lang="$1" composed="$REPO_ROOT/packages/core/seed/capabilities_catalog/$1.md" mf pkg ord frag keep rows=''
  [ -f "$composed" ] || return 1
  keep=" core ${SEED_PKG:-} $(_seed_psql -tA -c "SELECT package FROM core.package_registry WHERE status = 'active'" 2>/dev/null | tr '\n' ' ') "
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)"
    [ -n "$pkg" ] || continue
    case "$keep" in *" $pkg "*) : ;; *) continue ;; esac
    frag="$REPO_ROOT/packages/$pkg/seed/capabilities_catalog/$lang.fragment.md"
    [ -f "$frag" ] || continue
    ord="$(jq -r '.catalog.ord // 500' "$mf" 2>/dev/null)"
    rows="${rows}${ord}"$'\t'"${pkg}"$'\n'
  done
  # Kopf + je Fragment (GENERATED-Kommentar + fuehrende Leerzeilen weg, Ende getrimmt) + eine Leerzeile;
  # zum Schluss Trailing-Leerzeilen weg (= Build-ComposedCatalog: TrimEnd + genau ein '\n').
  {
    awk '/^## /{exit} {print}' "$composed"
    printf '%s' "$rows" | sort -t$'\t' -k1,1n -k2,2 | while IFS=$'\t' read -r _ pkg; do
      [ -n "$pkg" ] || continue
      tr -d '\r' < "$REPO_ROOT/packages/$pkg/seed/capabilities_catalog/$lang.fragment.md" \
        | sed '1{/^[[:space:]]*<!--.*-->[[:space:]]*$/d}' | sed '/[^[:space:]]/,$!d' \
        | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
      printf '\n'
    done
    _more_packages_md "$lang"
  } | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# _pkg_state_rows — TSV „<pkg>\t<state>" je GEBUENDELTEM Nicht-Core-Paket (Manifest-Glob, nach Name sortiert).
# state = active | inactive | absent — NUR aus der Registry (nicht aus SEED_PKG: ein abgebrochenes 'installing'
# zaehlt als nicht installiert). Install-UX-Phase 6, EINE Regel fuer installed_packages, den /help-Tail,
# Begruessung (core.fn_render_welcome liest dieselbe Registry) und den Recap. Anzeigenamen liefert der Aufrufer in
# seiner Sprache (pkg_display_name / pkg_text).
_pkg_state_rows() {
  local reg raw mf pkg st
  # Registry NICHT lesbar -> return 1 (der Aufrufer ueberspringt das Seeden, die alte Zeile bleibt) statt still
  # "alles nicht installiert" zu behaupten.
  raw="$(_seed_psql -tA -c "SELECT package || ':' || status FROM core.package_registry" 2>/dev/null)" || return 1
  reg=" $(printf '%s' "$raw" | tr '\n' ' ') "
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)"
    [ -n "$pkg" ] && [ "$pkg" != core ] || continue
    case "$reg" in
      *" $pkg:active "*)   st=active ;;
      *" $pkg:inactive "*) st=inactive ;;
      *)                   st=absent ;;
    esac
    printf '%s\t%s\n' "$pkg" "$st"
  done
}

# _more_packages_md <lang> — /help-Sektion „Weitere Funktionen" (Relay-Text in <lang>): ausgeschaltete + nicht
# installierte Pakete mit Einzeiler und Server-Befehl. Leer, wenn alles aktiv ist (keine leere Ueberschrift).
_more_packages_md() {
  local lang="$1" rows pkg st name sum line
  rows="$(_pkg_state_rows)" || return 0   # Registry unlesbar -> Abschnitt weglassen statt falsch befuellen
  rows="$(printf '%s\n' "$rows" | awk -F'\t' '$2 != "active"')"
  [ -n "$rows" ] || return 0
  printf '## %s\n' "$(pkg_text core help.more_title "$lang")"
  printf '%s\n' "$(pkg_text core help.more_intro "$lang")"
  while IFS=$'\t' read -r pkg st; do
    [ -n "$pkg" ] || continue
    name="$(pkg_display_name "$pkg" "$lang")"; sum="$(pkg_text "$pkg" package.summary "$lang")"
    if [ "$st" = inactive ]; then line="$(pkg_text core help.more_inactive "$lang")"; else line="$(pkg_text core help.more_absent "$lang")"; fi
    # Ersetzung gequotet: bash >= 5.2 (patsub_replacement) macht sonst aus jedem "&" im Namen den Treffer.
    line="${line//\{name\}/"$name"}"; line="${line//\{summary\}/"$sum"}"; line="${line//\{package\}/"$pkg"}"
    printf -- '- %s\n' "$line"
  done <<< "$rows"
  printf '\n'
}

# _installed_packages_md — der STATISCHE globale Context `installed_packages` (Install-UX-Phase 6): jedem Agenten
# (static, agent_name leer) sagen, welche Pakete aktiv / ausgeschaltet / nicht installiert sind — sonst bot z. B.
# der Guide den „Buchhalter" an, obwohl Finance fehlt. Modell-Schicht -> Englisch, bewusst WINZIG (steht in jedem
# Prompt); deutsche Anzeigenamen nur als Nutzer-Begriff. Materialisierte Projektion aus Manifest + Registry ueber
# denselben Refresh-Haken wie der Katalog (nicht installierte Pakete stehen nicht in der DB).
_installed_packages_md() {
  local rows act ina='' abs=''
  act="core (\"$(pkg_display_name core)\")"
  rows="$(_pkg_state_rows)" || return 1   # Registry unlesbar -> nicht seeden (alte Zeile bleibt), nie still "nichts installiert"
  local pkg st name
  while IFS=$'\t' read -r pkg st; do
    [ -n "$pkg" ] || continue
    name="$(pkg_display_name "$pkg")"   # deutscher Anzeigename = Nutzer-Begriff im (englischen) Modell-Text
    case "$st" in
      active)   act="${act}, ${pkg} (\"${name}\")" ;;
      inactive) ina="${ina}${ina:+, }${pkg} (\"${name}\")" ;;
      *)        abs="${abs}${abs:+, }${pkg} (\"${name}\")" ;;
    esac
  done <<< "$rows"
  printf -- '---\n'
  printf 'description: Which feature packages are active, deactivated or not installed on this instance. Authoritative - check before mentioning or offering any package capability. Composed by the installer - never hand-edit.\n'
  printf 'agent_name:\n'
  printf 'load_strategy: static\n'
  printf -- '---\n\n'
  printf '# Installed packages\n\n'
  printf -- '- Active: %s.\n' "$act"
  # shellcheck disable=SC2016  # die Backticks sind Markdown-Code-Spans im Prompt-Text, KEINE Shell-Expansion
  [ -n "$ina" ] && printf -- '- Deactivated (the owner re-enables one on the server: `lifeagents package activate <name>`): %s.\n' "$ina"
  # shellcheck disable=SC2016  # dito: Markdown-Code-Span
  [ -n "$abs" ] && printf -- '- Not installed (the owner adds one on the server: `lifeagents package install <name>`): %s.\n' "$abs"
  printf '\nOnly offer or mention capabilities of ACTIVE packages. For a deactivated or not-installed one, say so plainly and name the exact server command (it runs in the server terminal, not in this chat).\n'
}

# _seed_capabilities_catalog — SQL-Upsert des laufzeit-komponierten Katalogs + des Paket-Zustands-Contexts
# installed_packages (managed_by='build', package core; EIN Haken -> kein Drift zwischen /help und Prompt).
# Textkatalog Phase B: je Katalogsprache (Core-Manifest languages.list) eine Zeile in core.help_catalog (die liest
# der Orchestrator bei /help in der Sprache des Absenders); der Kontext capabilities_catalog (Guide-Agent, Modell-
# Wissen) bleibt die deutsche Fassung aus derselben Erzeugung — keine Prompt-Aenderung.
_seed_capabilities_catalog() {
  local tmpd lang; tmpd="$(mktemp -d)"
  for lang in $(jq -r '.languages.list | sort_by(.ord) | .[].code' "$REPO_ROOT/packages/core/manifest.json" 2>/dev/null); do
    printf '%s' "$lang" | grep -qE '^[a-z]{2}$' || continue
    if _capabilities_catalog_md "$lang" > "$tmpd/help_$lang.md" 2>/dev/null && [ -s "$tmpd/help_$lang.md" ]; then
      printf 'INSERT INTO core.help_catalog (lang, content, updated_at) VALUES (%s, %s, now())\n' \
        "$(_sql_str "$lang")" "$(_sql_str "$(cat "$tmpd/help_$lang.md")")"
      printf 'ON CONFLICT (lang) DO UPDATE SET content = EXCLUDED.content, updated_at = now();\n'
    else
      warn "Hilfe-Katalog (/help) fuer Sprache '$lang' nicht komponierbar — die bisherige Fassung bleibt stehen."
    fi
  done
  if [ -s "$tmpd/help_de.md" ]; then
    {
      printf -- '---\n'
      printf 'description: Generated capability overview of the multi-agent system (categories + example utterances, German). Lazy global context for the guide agent; /help itself reads core.help_catalog in the sender language. Composed by the installer - never hand-edit.\n'
      printf 'agent_name:\n'
      printf 'load_strategy: lazy\n'
      printf -- '---\n\n'
      cat "$tmpd/help_de.md"
    } > "$tmpd/capabilities_catalog.md"
    _seed_context_md "$tmpd/capabilities_catalog.md" build core
  fi
  if _installed_packages_md > "$tmpd/installed_packages.md" 2>/dev/null; then
    _seed_context_md "$tmpd/installed_packages.md" build core
  fi
  rm -rf "$tmpd"
}

# refresh_capabilities_catalog — den Katalog nach einem Status-Wechsel (install/activate/deactivate/uninstall)
# neu komponieren (eigene kurze Transaktion; nie fatal). Aufrufer: pkg_lifecycle.sh.
refresh_capabilities_catalog() {
  [ -n "${N8N_DB_NAME:-}" ] || return 0
  local driver; driver="$(mktemp /tmp/seed_catalog.XXXXXX.sql)"; chmod 0644 "$driver"
  { printf '\\set ON_ERROR_STOP on\nBEGIN;\n'; _seed_capabilities_catalog; printf 'COMMIT;\n'; } > "$driver"
  _seed_psql -q -f "$driver" >/dev/null 2>&1 || warn "Hilfe-Katalog (/help) konnte nicht aktualisiert werden — naechstes 'lifeagents update' holt es nach."
  rm -f "$driver"
  return 0
}

# --- (3) Contexts  -----------------------------------------------------------
_seed_contexts() {
  # (a) Capabilities-Katalog: IMMER (auch beim per-Paket-Seed) laufzeit-komponiert aus Core + installierten
  #     Paketen (s. _capabilities_catalog_md) — ein Host-Komposit, kein Paket-Artefakt.
  _seed_capabilities_catalog

  # (b) Per-Paket-Contexts: packages/<pkg>/contexts/*.md (package = <pkg>). Seit WS-B2 liegen
  #     ALLE Instruktions-Contexts paket-besessen hier (auch die Finance-Instruktionen) — der
  #     fruehere flache db/seed/contexts/-Pfad ist retired.
  local d pkg f seeded=0 seeded_names=''
  for d in "$REPO_ROOT"/packages/*/contexts; do
    [ -d "$d" ] || continue
    pkg="$(basename "$(dirname "$d")")"
    _seed_skip_pkg "$pkg" && continue
    for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      _seed_context_md "$f" seed "$pkg"; seeded=1
      seeded_names="${seeded_names}${seeded_names:+, }$(_sql_str "$(basename "$f" .md)")"
    done
  done
  # Signalisierung zum Conffile-Guard (arch-challenge D1 ADOPT): bewahrte Owner-Zeilen NICHT still
  # ueberspringen — eine NOTICE nennt die Anzahl (der ON-CONFLICT-Skip selbst ist nicht zaehlbar,
  # daher separater count). Voll-Signalisierung (.dpkg-dist-Aequivalent) = BACKLOG mit Trigger.
  if [ -n "$seeded_names" ]; then
    # shellcheck disable=SC2016  # $conffile$ ist ein SQL-Dollar-Quote-Tag, KEINE Shell-Expansion
    printf 'DO $conffile$ DECLARE n int; BEGIN\n'
    printf '  SELECT count(*) INTO n FROM agent.core_contexts WHERE managed_by = %s AND name IN (%s);\n' \
      "$(_sql_str 'agent')" "$seeded_names"
    printf '  IF n > 0 THEN RAISE NOTICE %s, n; END IF;\n' \
      "$(_sql_str '% owner-owned context rows preserved, not overwritten by seed (dpkg-conffile guard)')"
    # shellcheck disable=SC2016  # dito: SQL-Dollar-Quote-Tag
    printf 'END $conffile$;\n'
  fi
  # Warnung nur beim Voll-Seed (per-Paket-Seed eines context-losen Pakets ist legitim).
  [ "$seeded" = "1" ] || [ -n "${SEED_PKG:-}" ] || warn "Keine Instruktions-Contexts gefunden (packages/*/contexts leer — Agenten ohne System-Prompt!)."
  # Loeschschutz (WS-B2b): NICHT mehr per metadata.protected-Flag (util_protect_contexts retired) —
  # die geschuetzten Namen kommen aus den Paket-Manifesten in core.protected_contexts (_seed_protected_contexts).
}

# --- (4) core.context_validators — generische Validator-Registry (WS-B1 / D12) -----
# Jedes Paket DEKLARIERT im manifest.json einen "context_validators"-Block
# { "<context_name>": "<pkg>.<fn>" }; der HOST upsertet die Zeile in core.context_validators
# (Deklaration vs. Ausfuehrung, docs/package-contract.md §3.3 — das Paket schreibt die Registry NIE
# selbst). Der Core-Trigger dispatcht generisch ueber diese Tabelle (kein hartkodierter Paket-Name im Core).
# BOUNDARY (own-schema-scoping wie bei den Rollen-Grants): validate_fn MUSS ins eigene Paket-Schema
# zeigen — ein Paket darf keinen fremden/Core-Validator binden.
_seed_context_validators() {
  local mf pkg cname fn
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    _seed_skip_pkg "$(jq -r '.name // empty' "$mf")" && continue
    jq -r '.name as $pkg | (.context_validators // {}) | to_entries[]
           | select(.key != "_comment") | [.key, .value, $pkg] | @tsv' "$mf" |
    while IFS=$'\t' read -r cname fn pkg; do
      [ -n "$cname" ] || continue
      case "$fn" in
        "$pkg".*) : ;;
        *) warn "context_validator '$cname' -> '$fn' zeigt nicht ins Paket-Schema '$pkg' — uebersprungen (Boundary)."; continue ;;
      esac
      printf 'INSERT INTO core.context_validators (context_name, validate_fn, package)\n'
      printf 'VALUES (%s, %s, %s)\n' "$(_sql_str "$cname")" "$(_sql_str "$fn")" "$(_sql_str "$pkg")"
      printf 'ON CONFLICT (context_name) DO UPDATE SET validate_fn=EXCLUDED.validate_fn, package=EXCLUDED.package, updated_at=now();\n'
      # Install-Zeit-Sichtbarkeit (arch-challenge): fehlt die Ziel-fn (Manifest-Typo / Apply-Order),
      # WARNING statt stiller Laufzeit-Degradation. Non-fatal -> Zeile bleibt, Trigger-Guard skippt grazil.
      # shellcheck disable=SC2016  # $dv$ ist ein literales SQL-Dollar-Quote-Tag, KEINE Shell-Expansion (gewollt nicht expandieren).
      printf 'DO $dv$ BEGIN IF to_regprocedure(%s) IS NULL THEN RAISE WARNING %s; END IF; END $dv$;\n' \
        "$(_sql_str "$fn(jsonb)")" "$(_sql_str "context_validator $cname -> $fn(jsonb) nicht gefunden (Manifest-Typo/Apply-Order?)")"
    done
  done
}

# --- (4a) core.context_scopes — Scope-/Permission-Registry (P0a, deklaratives Fundament) -----
# Jedes Paket DEKLARIERT im manifest.json einen "context_scopes"-Block, VERSCHACHTELT (2 Werte je Context):
#   { "<context>": { "scope", "write_permission" } } ;
# der HOST upsertet die Zeile in core.context_scopes (Deklaration vs. Ausfuehrung, analog _seed_context_validators).
# agent.fn_check_write_permission setzt die write_permission generisch durch (kein hartkodierter Paket-Name im Core).
# KEIN own-schema-Boundary-Check (anders als validators/renderers/advisors, wie _seed_cron_labels): die Werte sind
# reine Daten-Enums, KEINE fn-Bezeichner — die Durchsetzung sind die Tabellen-CHECKs (scope/write_permission/Cross).
# package=<pkg> -> fn_pkg_purge_data raeumt die Zeile beim Uninstall. Definitions- = Aufrufreihenfolge (vor renderers).
_seed_context_scopes() {
  local mf pkg cname scope perm
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    _seed_skip_pkg "$(jq -r '.name // empty' "$mf")" && continue
    jq -r '.name as $pkg | (.context_scopes // {}) | to_entries[]
           | select(.key != "_comment")
           | .key as $cname | .value
           | [$pkg, $cname, (.scope // ""), (.write_permission // "")] | @tsv' "$mf" |
    while IFS=$'\t' read -r pkg cname scope perm; do
      [ -n "$cname" ] || continue
      [ -n "$scope" ] && [ -n "$perm" ] \
        || { warn "context_scope '$cname' ($pkg): scope/write_permission unvollstaendig — uebersprungen."; continue; }
      printf 'INSERT INTO core.context_scopes (context_name, scope, write_permission, package)\n'
      printf 'VALUES (%s, %s, %s, %s)\n' \
        "$(_sql_str "$cname")" "$(_sql_str "$scope")" "$(_sql_str "$perm")" "$(_sql_str "$pkg")"
      printf 'ON CONFLICT (context_name) DO UPDATE SET scope=EXCLUDED.scope, write_permission=EXCLUDED.write_permission, package=EXCLUDED.package, updated_at=now();\n'
    done
  done
}

# --- (4a2) Paket-Fakten-Skelette — leere facts-Kontexte, die das PAKET besitzt (Install-UX-Phase 6) -----
# Jedes Paket DEKLARIERT im manifest.json einen "context_skeletons"-Block, VERSCHACHTELT:
#   { "<context>": { "agent_name", "description", "content", "facts": {…} } } ;
# der HOST legt die Zeile INSERT-ONLY an (ON CONFLICT DO NOTHING — vorhandene PII-Fakten werden NIE angefasst;
# Debian-postinst-Muster: das Paket legt seinen Zustand bei jeder Installation selbst an). Loest die Core-Naht
# ab, dass util_seed_owner_skeleton.sql auch ohne Finance eine finance_profile-Zeile anlegte (und sie nach
# `--purge` + Neuinstallation fehlte). Laeuft auch mit --no-seed (Code-Seed; der Restore UPDATEt danach die
# Zeile aus dem Bundle). Nur wenn das Paket registriert ist (ein Voll-Seed auf einer Core-only-Instanz legt
# so keine Waise an). load_strategy lazy, managed_by='agent' (Seeder fasst sie danach nie wieder an), package=<pkg>.
# Der facts-Trigger validiert den Start-Sidecar (der Validator ist oben schon registriert).
_seed_context_skeletons() {
  local mf pkg cname agent desc content facts agent_sql
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    _seed_skip_pkg "$(jq -r '.name // empty' "$mf")" && continue
    # Unit-Separator (\x1f) statt Tab: leere Felder (agent_name) duerfen nicht kollabieren (s. _seed_package_config).
    jq -r '.name as $pkg | (.context_skeletons // {}) | to_entries[]
           | select(.key != "_comment")
           | [$pkg, .key, (.value.agent_name // ""), (.value.description // ""), (.value.content // ""),
              ((.value.facts // {}) | tojson)] | join("\u001f")' "$mf" |
    while IFS=$'\x1f' read -r pkg cname agent desc content facts; do
      [ -n "$cname" ] || continue
      # Paritaet _seed_context_scopes: unvollstaendige Deklaration laut melden + ueberspringen (kein stilles Leer-Skelett).
      [ -n "$desc" ] && [ -n "$content" ] \
        || { warn "context_skeleton '$cname' ($pkg): description/content fehlt — uebersprungen."; continue; }
      agent_sql='NULL'; [ -n "$agent" ] && agent_sql="$(_sql_str "$agent")"
      printf 'INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)\n'
      printf "SELECT %s, %s, %s, 'lazy', %s, 'agent', %s, jsonb_build_object('facts', %s::jsonb)\n" \
        "$(_sql_str "$cname")" "$(_sql_str "$desc")" "$agent_sql" "$(_sql_str "$content")" "$(_sql_str "$pkg")" "$(_sql_str "$facts")"
      printf 'WHERE EXISTS (SELECT 1 FROM core.package_registry WHERE package = %s)\n' "$(_sql_str "$pkg")"
      printf 'ON CONFLICT (name) DO NOTHING;\n'
    done
  done
}

# --- (4b) core.context_renderers — generische Render-Registry (WS1a, Core-Advisor-Engine) -----
# Jedes Paket DEKLARIERT im manifest.json einen "context_renderers"-Block
# { "<context_name>": "<pkg>.<fn>" }; der HOST upsertet die Zeile in core.context_renderers
# (Deklaration vs. Ausfuehrung, docs/package-contract.md §3.3 — analog _seed_context_validators).
# Die generische Engine core.fn_fetch_context dispatcht generisch (kein hartkodierter Context-Name im Core).
# BOUNDARY (own-schema-scoping wie die Rollen-Grants): render_fn MUSS ins eigene Paket-Schema zeigen.
# Signatur ist UNIFORM fn(text)->text (Context-Name als Argument) — anders als die Validatoren fn(jsonb).
_seed_context_renderers() {
  local mf pkg cname fn
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    _seed_skip_pkg "$(jq -r '.name // empty' "$mf")" && continue
    jq -r '.name as $pkg | (.context_renderers // {}) | to_entries[]
           | select(.key != "_comment") | [.key, .value, $pkg] | @tsv' "$mf" |
    while IFS=$'\t' read -r cname fn pkg; do
      [ -n "$cname" ] || continue
      # Own-schema-scoping: ein Paket bindet nur <pkg>.*; der CORE (privilegiert, besitzt core+agent)
      # darf auch agent.* binden (die Haushalts-Renderer leben im geteilten agent-Layer, WS1b).
      if [ "$pkg" = core ]; then
        case "$fn" in core.*|agent.*) : ;; *) warn "context_renderer '$cname' -> '$fn' zeigt nicht ins Core-Schema (core.*/agent.*) — uebersprungen (Boundary)."; continue ;; esac
      else
        case "$fn" in "$pkg".*) : ;; *) warn "context_renderer '$cname' -> '$fn' zeigt nicht ins Paket-Schema '$pkg' — uebersprungen (Boundary)."; continue ;; esac
      fi
      printf 'INSERT INTO core.context_renderers (context_name, render_fn, package)\n'
      printf 'VALUES (%s, %s, %s)\n' "$(_sql_str "$cname")" "$(_sql_str "$fn")" "$(_sql_str "$pkg")"
      printf 'ON CONFLICT (context_name) DO UPDATE SET render_fn=EXCLUDED.render_fn, package=EXCLUDED.package, updated_at=now();\n'
      # Install-Zeit-Sichtbarkeit: fehlt die Ziel-fn (Manifest-Typo / Apply-Order), WARNING statt stiller
      # Laufzeit-Degradation (Engine faellt grazil auf rohen content zurueck). Signatur (text)!
      # shellcheck disable=SC2016  # $dr$ ist ein literales SQL-Dollar-Quote-Tag, KEINE Shell-Expansion.
      printf 'DO $dr$ BEGIN IF to_regprocedure(%s) IS NULL THEN RAISE WARNING %s; END IF; END $dr$;\n' \
        "$(_sql_str "$fn(text)")" "$(_sql_str "context_renderer $cname -> $fn(text) nicht gefunden (Manifest-Typo/Apply-Order?)")"
    done
  done
}

# --- (4c) core.advisors — generische Advisor-Registry (WS2, Core-Advisor-Engine) -----
# Jedes Paket DEKLARIERT im manifest.json einen "advisors"-Block, VERSCHACHTELT:
#   { "<domain>": { "plan_context": "<context>", "review_fn": "<pkg>.<fn>", "advisor_agent": "agent.<a>",
#                   "learn_notes": true|false (optional, Default false) } } ;
# der HOST upsertet die Zeile own-schema-scoped in core.advisors (Deklaration vs. Ausfuehrung, analog
# _seed_context_renderers — das Paket schreibt die Registry NIE selbst). Der generische Core-Wrapper
# core.fn_advisor_review_evaluate(domain) dispatcht ueber die Tabelle (kein hartkodierter Paket-Name im Core).
# BOUNDARY (own-schema-scoping wie die Rollen-Grants): review_fn MUSS ins eigene Paket-Schema zeigen; der
# CORE (privilegiert) darf core.*/agent.* binden (kuenftiger Core-Advisor). Signatur UNIFORM fn(text,text,jsonb)->jsonb (domain, person_id, opts).
# package=<pkg> -> fn_pkg_purge_data raeumt die Zeile beim Uninstall (sonst Orphan-review_fn).
_seed_advisors() {
  local mf pkg domain plan_ctx fn agent agent_sql learn
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    _seed_skip_pkg "$(jq -r '.name // empty' "$mf")" && continue
    # learn_notes STRIKT boolean (Muster member_permeable der callback_handlers): nur ein echtes JSON-true
    # zaehlt, alles andere (fehlend/String/Zahl) -> false (fail-closed).
    jq -r '.name as $pkg | (.advisors // {}) | to_entries[]
           | select(.key != "_comment")
           | .key as $domain | .value
           | [$pkg, $domain, (.plan_context // ""), (.review_fn // ""), (.advisor_agent // ""),
              (if .learn_notes == true then "true" else "false" end),
              (if .own_review_cron == true then "true" else "false" end)] | @tsv' "$mf" |
    while IFS=$'\t' read -r pkg domain plan_ctx fn agent learn owncron; do
      [ -n "$domain" ] || continue
      [ -n "$plan_ctx" ] && [ -n "$fn" ] || { warn "advisor '$domain' ($pkg): plan_context/review_fn fehlt — uebersprungen."; continue; }
      if [ "$pkg" = core ]; then
        case "$fn" in core.*|agent.*) : ;; *) warn "advisor '$domain' -> review_fn '$fn' zeigt nicht ins Core-Schema (core.*/agent.*) — uebersprungen (Boundary)."; continue ;; esac
      else
        case "$fn" in "$pkg".*) : ;; *) warn "advisor '$domain' -> review_fn '$fn' zeigt nicht ins Paket-Schema '$pkg' — uebersprungen (Boundary)."; continue ;; esac
      fi
      # advisor_agent (Phase 0 WS-0c #1, Datenquelle Domaene->Router-Ziel): leer -> NULL (CHECK erlaubt NULL).
      agent_sql='NULL'; [ -n "$agent" ] && agent_sql="$(_sql_str "$agent")"
      [ "$learn" = true ] || learn=false
      [ "$owncron" = true ] || owncron=false   # Roter Faden: eigener Review-Cron -> geteilte Advisor-Crons lassen die Domaene aus
      printf 'INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, learn_notes, own_review_cron, package, updated_at)\n'
      printf 'VALUES (%s, %s, %s, %s, %s, %s, %s, now())\n' \
        "$(_sql_str "$domain")" "$(_sql_str "$plan_ctx")" "$(_sql_str "$fn")" "$agent_sql" "$learn" "$owncron" "$(_sql_str "$pkg")"
      printf 'ON CONFLICT (domain) DO UPDATE SET plan_context=EXCLUDED.plan_context, review_fn=EXCLUDED.review_fn, advisor_agent=EXCLUDED.advisor_agent, learn_notes=EXCLUDED.learn_notes, own_review_cron=EXCLUDED.own_review_cron, package=EXCLUDED.package, updated_at=now();\n'
      # Install-Zeit-Sichtbarkeit: fehlt die Ziel-fn (Manifest-Typo / Apply-Order), WARNING statt stiller
      # Laufzeit-Degradation (der Eval-Wrapper gibt {ok:false,review_fn_missing} zurueck). Signatur (text,text,jsonb)
      # = die Arity, die core.fn_advisor_review_evaluate dispatcht (P2b-2 person-skopiert; vorher pruefte diese
      # Warnung die alte (text,jsonb)-Arity und griff nie).
      # shellcheck disable=SC2016  # $da$ ist ein literales SQL-Dollar-Quote-Tag, KEINE Shell-Expansion.
      printf 'DO $da$ BEGIN IF to_regprocedure(%s) IS NULL THEN RAISE WARNING %s; END IF; END $da$;\n' \
        "$(_sql_str "$fn(text,text,jsonb)")" "$(_sql_str "advisor $domain -> $fn(text,text,jsonb) nicht gefunden (Manifest-Typo/Apply-Order?)")"
    done
  done
}

# --- (4d) core.cron_labels — Chat-Toggle-Registry der opt-in Crons (Phase 0 WS-0c #2/#3) -----
# Jedes Paket DEKLARIERT im manifest.json die Liste seiner schaltbaren opt-in Crons:
#   "cron_labels": { "_comment", "list": ["<cron_key>", ...] } ;
# der HOST upsertet die Zeile in core.cron_labels (Deklaration vs. Ausfuehrung, analog _seed_advisors —
# das Paket schreibt die Registry NIE selbst, D10). MITGLIEDSCHAFT = chat-togglability-SoT (core.fn_set_cron_enable
# lehnt jeden Key ab, der NICHT hier steht -> always-on Crons stehen nicht drin). Die Toast-/Meldungstexte stehen im
# Textkatalog des Pakets (<pkg>.cron.<key>.*, Textkatalog Phase B), nicht mehr in der Registry.
# package=<pkg> -> fn_pkg_purge_data raeumt die Zeile beim Uninstall. KEIN own-schema-Boundary-Check
# (anders als advisors/validators): die Werte sind reine Daten-Strings, keine fn-Bezeichner.
# Roter Faden: "cron_labels.person": { "<key>": { "default_enabled": bool } } = PERSON-Reminder (scope='person', jede
# Person schaltet ihre Zustellung selbst ueber agent.reminder_prefs); "list" = Haushalts-Schalter (scope='household').
# scope + default_enabled werden bei jedem Seed nachgezogen (ON CONFLICT DO UPDATE), damit ein Update den Wechsel traegt.
_seed_cron_labels() {
  local mf pkg key scope def
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    _seed_skip_pkg "$(jq -r '.name // empty' "$mf")" && continue
    # Paket B: "mandatory": ["<key>"] = Pflicht-Erinnerung (Haushalt, in /reminders nur Anzeige, nie schaltbar).
    # default_enabled per has() statt `// true`: jq-`//` ersetzt auch ein gesetztes false (sonst waere
    # score_jobs still fuer jede Person an; Substrat-Befund 2026-10-23).
    jq -r '.name as $pkg
           | ((.cron_labels.list // [])[] | [$pkg, ., "household", "true", "false"]),
             ((.cron_labels.person // {}) | to_entries[] | select(.key != "_comment")
               | [$pkg, .key, "person", ((if (.value | has("default_enabled")) then .value.default_enabled else true end) | tostring), "false"]),
             ((.cron_labels.mandatory // [])[] | [$pkg, ., "household", "true", "true"])
           | @tsv' "$mf" |
    while IFS=$'\t' read -r pkg key scope def mand; do
      [ -n "$key" ] || continue
      printf 'INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled, mandatory, updated_at)\n'
      printf 'VALUES (%s, %s, %s, %s, %s, now())\n' "$(_sql_str "$key")" "$(_sql_str "$pkg")" "$(_sql_str "$scope")" "$def" "$mand"
      printf 'ON CONFLICT (cron_key) DO UPDATE SET package=EXCLUDED.package, scope=EXCLUDED.scope, default_enabled=EXCLUDED.default_enabled, mandatory=EXCLUDED.mandatory, updated_at=now();\n'
    done
  done
}

# --- (4d2) core.ui_languages — die EINE Liste der unterstuetzten Sprachen fester Nutzertexte -----
# SoT = Core-Manifest-Block "languages.list" (docs/package-contract.md §3.11). Upsert von Name/Locale/Reihenfolge/
# Aliasen; NIE loeschen (eine Person kann den Code tragen — der Validator lehnte sonst jeden family-Write ab).
# core:V027 legt die Basis-Codes vorab an (Backfill + Validator laufen vor dem Seed). Code-Seed (auch --no-seed).
_seed_ui_languages() {
  _seed_skip_pkg core && return 0   # die Sprachliste ist core-eigen
  local mf="$REPO_ROOT/packages/core/manifest.json" code name locale ord aliases dpat
  # Unit-Separator (\x1f) statt Tab: leere aliases duerfen date_pattern nicht nach vorn ziehen (s. _seed_package_config).
  jq -r '(.languages.list // [])[] | [.code, .name, .locale, (.ord|tostring), ((.aliases // []) | join(",")), (.date_pattern // "")] | join("\u001f")' "$mf" |
  while IFS=$'\x1f' read -r code name locale ord aliases dpat; do
    [ -n "$code" ] || continue
    printf 'INSERT INTO core.ui_languages (code, name, locale, ord, aliases, date_pattern)\n'
    printf "VALUES (%s, %s, %s, %s, string_to_array(%s, ','), NULLIF(%s, ''))\n" \
      "$(_sql_str "$code")" "$(_sql_str "$name")" "$(_sql_str "$locale")" "$ord" "$(_sql_str "$aliases")" "$(_sql_str "$dpat")"
    printf 'ON CONFLICT (code) DO UPDATE SET name=EXCLUDED.name, locale=EXCLUDED.locale, ord=EXCLUDED.ord, aliases=EXCLUDED.aliases, date_pattern=EXCLUDED.date_pattern;\n'
  done
}

# --- (4d2b) core.ui_personas — die EINE Liste der Bot-Personas je Person -----
# SoT = Core-Manifest-Block "personas.list". Upsert der Reihenfolge; NIE loeschen (eine Person kann den Code tragen —
# der Validator lehnte sonst jeden family-Write ab). core:V031 legt die Basis-Codes vorab an. Code-Seed (auch --no-seed).
_seed_ui_personas() {
  _seed_skip_pkg core && return 0   # die Persona-Liste ist core-eigen
  local mf="$REPO_ROOT/packages/core/manifest.json" code ord
  jq -r '(.personas.list // [])[] | "\(.code)\t\(.ord)"' "$mf" |
  while IFS=$'\t' read -r code ord; do
    [ -n "$code" ] || continue
    printf 'INSERT INTO core.ui_personas (code, ord) VALUES (%s, %s)\n' "$(_sql_str "$code")" "$ord"
    printf 'ON CONFLICT (code) DO UPDATE SET ord=EXCLUDED.ord;\n'
  done
}

# --- (4d3) core.ui_texts — Textkatalog fester Nutzertexte (packages/<pkg>/locales/<lang>.json) -----
# Muster Rails/gettext: die getrackten Dateien sind die Wahrheit, die Tabelle ist build-verwaltet -> je Paket
# VOLLSTAENDIG ersetzen (DELETE + INSERT in der Seed-Transaktion; kein Owner-Edit, kein Conffile-Guard). Die
# Datei-Inhalte gehen per Dollar-Quote ($uitexts$) als EIN jsonb-Literal hinein (kein Zeilen-Escaping noetig);
# '_'-Keys (_comment) bleiben draussen. Eine Datei, deren Sprache nicht in core.ui_languages steht, scheitert am
# FK (locale_lint faengt das vorher). Pakete ohne locales/ werden uebersprungen. Code-Seed (auch --no-seed).
# Abbild ALLER gebuendelten Pakete, unabhaengig vom Installationsstand: Onboarding-Menue und Vermittler nennen auch
# nicht installierte Pakete beim Namen (<pkg>.package.name, <pkg>.onboarding.*) -> der Core-Lauf (SEED_PKG leer
# oder core) seedet jedes Paket im Baum und raeumt Pakete, die das Release verlassen haben; ein Paket-Lauf nur sich
# selbst. Die Purge (core.fn_pkg_purge_data) fasst die Tabelle deshalb nicht an.
_seed_ui_texts() {
  local mf pkg dir f lang bundled=''
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf")"
    [ -n "$pkg" ] || continue
    bundled="${bundled}${bundled:+,}$(_sql_str "$pkg")"
    [ "${SEED_PKG:-core}" = core ] || [ "$SEED_PKG" = "$pkg" ] || continue
    dir="$REPO_ROOT/packages/$pkg/locales"
    # Erst loeschen, dann (falls vorhanden) neu einfuegen: auch ein Paket, das seine locales/ abgibt, hinterlaesst
    # keine alten Texte (vollstaendig build-verwaltet).
    printf 'DELETE FROM core.ui_texts WHERE package = %s;\n' "$(_sql_str "$pkg")"
    [ -d "$dir" ] || continue
    for f in "$dir"/*.json; do
      [ -f "$f" ] || continue
      lang="$(basename "$f" .json)"
      jq -e 'type == "object"' "$f" >/dev/null 2>&1 || die "locales: $f ist kein JSON-Objekt."
      if grep -q 'uitexts\$' "$f"; then die "locales: $f enthaelt den reservierten Quote-Tag \$uitexts\$."; fi
      printf 'INSERT INTO core.ui_texts (key, lang, text, package)\n'
      printf "SELECT e.key, %s, e.value, %s FROM jsonb_each_text(\$uitexts\$%s\$uitexts\$::jsonb) e WHERE left(e.key, 1) <> '_';\n" \
        "$(_sql_str "$lang")" "$(_sql_str "$pkg")" "$(jq -c . "$f")"
    done
  done
  if [ "${SEED_PKG:-core}" = core ] && [ -n "$bundled" ]; then
    printf 'DELETE FROM core.ui_texts WHERE package NOT IN (%s);\n' "$bundled"
  fi
}

# --- (4e) core.callback_handlers — generische Callback-Dispatch-Registry (Phase 0 WS-0c CB) -----
# Jedes Paket DEKLARIERT im manifest.json einen "callback_handlers"-Block { "<prefix>": "<pkg>.<fn>" };
# der HOST upsertet die Zeile in core.callback_handlers (Deklaration vs. Ausfuehrung, analog
# _seed_context_validators). Der generische Core-Dispatcher core.fn_dispatch_callback schlaegt das
# callback_data-Prefix hier nach + fuehrt die handler_fn dynamisch aus (kein hartkodierter Paket-Name im Core).
# BOUNDARY (own-schema-scoping wie die Validatoren): handler_fn MUSS ins eigene Paket-Schema zeigen; der
# CORE (privilegiert) darf core.*/agent.* binden. Signatur UNIFORM fn(jsonb)->jsonb.
# package=<pkg> -> fn_pkg_purge_data raeumt die Zeile beim Uninstall (sonst Orphan-handler_fn).
_seed_callback_handlers() {
  local mf pkg prefix fn perm
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    _seed_skip_pkg "$(jq -r '.name // empty' "$mf")" && continue
    # Nested-Schema { "<prefix>": { "handler_fn": "<pkg>.<fn>", "member_permeable": <bool> } } (Muster
    # _seed_context_scopes). member_permeable STRIKT boolean-getypt: nur exakt jq-true -> "true", jeder
    # andere/fehlende/falsch getypte Wert -> "false" = FAIL-CLOSED (die Member-Route oeffnet nie versehentlich).
    jq -r '.name as $pkg | (.callback_handlers // {}) | to_entries[]
           | select(.key != "_comment")
           | [.key, .value.handler_fn, (if (.value.member_permeable // false) == true then "true" else "false" end), $pkg]
           | @tsv' "$mf" |
    while IFS=$'\t' read -r prefix fn perm pkg; do
      [ -n "$prefix" ] || continue
      [ -n "$fn" ] || { warn "callback_handler '$prefix' ($pkg): handler_fn fehlt (nested-Schema {handler_fn, member_permeable}?) — uebersprungen."; continue; }
      if [ "$pkg" = core ]; then
        case "$fn" in core.*|agent.*) : ;; *) warn "callback_handler '$prefix' -> '$fn' zeigt nicht ins Core-Schema (core.*/agent.*) — uebersprungen (Boundary)."; continue ;; esac
      else
        case "$fn" in "$pkg".*) : ;; *) warn "callback_handler '$prefix' -> '$fn' zeigt nicht ins Paket-Schema '$pkg' — uebersprungen (Boundary)."; continue ;; esac
      fi
      printf 'INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)\n'
      printf 'VALUES (%s, %s, %s, %s)\n' "$(_sql_str "$prefix")" "$(_sql_str "$fn")" "$(_sql_str "$pkg")" "$perm"
      printf 'ON CONFLICT (prefix) DO UPDATE SET handler_fn=EXCLUDED.handler_fn, package=EXCLUDED.package, member_permeable=EXCLUDED.member_permeable, updated_at=now();\n'
      # Install-Zeit-Sichtbarkeit (analog _seed_advisors): fehlt die Ziel-fn -> WARNING statt stiller
      # Laufzeit-Degradation (der Dispatcher gibt {ok:false,handler_fn_missing} zurueck). Signatur (jsonb)!
      # shellcheck disable=SC2016  # $cb$ ist ein literales SQL-Dollar-Quote-Tag, KEINE Shell-Expansion.
      printf 'DO $cb$ BEGIN IF to_regprocedure(%s) IS NULL THEN RAISE WARNING %s; END IF; END $cb$;\n' \
        "$(_sql_str "$fn(jsonb)")" "$(_sql_str "callback_handler $prefix -> $fn(jsonb) nicht gefunden (Manifest-Typo/Apply-Order?)")"
    done
  done
}

# --- (4e2) core.app_screens — Bildschirme der Mini-App „Übersicht“ (docs/package-contract.md §3.12) -----
# Jedes Paket DEKLARIERT im manifest.json einen "app_screens"-Block { "<screen>": { handler_fn, ord, icon } };
# der HOST ersetzt die Zeilen des Pakets (DELETE + INSERT in der Seed-Transaktion -> ein aus dem Manifest
# entfernter Bildschirm verschwindet, statt als tote Registry-Zeile zu bleiben). core.fn_app_screen dispatcht
# generisch. BOUNDARY wie _seed_callback_handlers (handler_fn im eigenen Schema; core darf core.*/agent.*),
# Signatur fn(jsonb)->jsonb. Bildschirm-Keys sind paket-uebergreifend eindeutig (contract_lint).
_seed_app_screens() {
  local mf pkg screen fn ord icon
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf")"
    _seed_skip_pkg "$pkg" && continue
    printf 'DELETE FROM core.app_screens WHERE package = %s;\n' "$(_sql_str "$pkg")"
    jq -r '.name as $pkg | (.app_screens // {}) | to_entries[]
           | select(.key != "_comment")
           | [.key, (.value.handler_fn // ""), ((.value.ord // 100) | tostring), (.value.icon // ""), $pkg]
           | @tsv' "$mf" |
    while IFS=$'\t' read -r screen fn ord icon pkg; do
      [ -n "$screen" ] || continue
      [ -n "$fn" ] || { warn "app_screen '$screen' ($pkg): handler_fn fehlt — uebersprungen."; continue; }
      if [ "$pkg" = core ]; then
        case "$fn" in core.*|agent.*) : ;; *) warn "app_screen '$screen' -> '$fn' zeigt nicht ins Core-Schema — uebersprungen (Boundary)."; continue ;; esac
      else
        case "$fn" in "$pkg".*) : ;; *) warn "app_screen '$screen' -> '$fn' zeigt nicht ins Paket-Schema '$pkg' — uebersprungen (Boundary)."; continue ;; esac
      fi
      printf '%s' "$ord" | grep -qE '^-?[0-9]{1,9}$' || { warn "app_screen '$screen' ($pkg): ord '$ord' ist keine ganze Zahl -> 100."; ord=100; }
      printf 'INSERT INTO core.app_screens (screen, package, handler_fn, ord, icon)\n'
      printf 'VALUES (%s, %s, %s, %s, %s)\n' "$(_sql_str "$screen")" "$(_sql_str "$pkg")" "$(_sql_str "$fn")" "$ord" "$(_sql_str "$icon")"
      printf 'ON CONFLICT (screen) DO UPDATE SET package=EXCLUDED.package, handler_fn=EXCLUDED.handler_fn, ord=EXCLUDED.ord, icon=EXCLUDED.icon, updated_at=now();\n'
      # shellcheck disable=SC2016  # $as$ ist ein literales SQL-Dollar-Quote-Tag, KEINE Shell-Expansion.
      printf 'DO $as$ BEGIN IF to_regprocedure(%s) IS NULL THEN RAISE WARNING %s; END IF; END $as$;\n' \
        "$(_sql_str "$fn(jsonb)")" "$(_sql_str "app_screen $screen -> $fn(jsonb) nicht gefunden (Manifest-Typo/Apply-Order?)")"
    done
  done
}

# --- (4f) core.monitor_acquisition_methods — Monitor-Beschaffungs-Methoden der Pakete (Phase B) -----
# Jedes Paket DEKLARIERT im manifest.json einen "monitor_acquisition_methods"-Block, VERSCHACHTELT:
#   { "<method>": { "acquire_fn": "<pkg>.<fn>", "validate_fn": "<pkg>.<fn>", "label": "...", "params_description": "..." } }
# der HOST upsertet method/acquire_fn/validate_fn/package (label/params_description sind BUILD-Daten fuer die
# Tool-Beschreibungen, nicht in der DB). Der Core dispatcht generisch (agent.fn_monitor_acquire /
# fn_monitor_validate_params) — kein Paket-Name im Core. BOUNDARY (own-schema, Muster _seed_callback_handlers):
# beide fns MUESSEN ins eigene Paket-Schema zeigen. Upsert fuellt auch einen V020-Platzhalter (package NULL),
# stiehlt aber nie die Methode eines ANDEREN Pakets (WHERE package IS NULL OR package = EXCLUDED.package).
# Signatur UNIFORM fn(jsonb)->jsonb. package=<pkg> -> fn_pkg_purge_data Schritt 3c raeumt Trigger + Zeile.
_seed_monitor_acquisition_methods() {
  local mf pkg method afn vfn
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    _seed_skip_pkg "$(jq -r '.name // empty' "$mf")" && continue
    jq -r '.name as $pkg | (.monitor_acquisition_methods // {}) | to_entries[]
           | select(.key != "_comment")
           | [$pkg, .key, (.value.acquire_fn // ""), (.value.validate_fn // "")] | @tsv' "$mf" |
    while IFS=$'\t' read -r pkg method afn vfn; do
      [ -n "$method" ] || continue
      [ -n "$afn" ] && [ -n "$vfn" ] || { warn "monitor_acquisition_method '$method' ($pkg): acquire_fn/validate_fn fehlt — uebersprungen."; continue; }
      case "$afn" in "$pkg".*) : ;; *) warn "monitor_acquisition_method '$method' -> acquire_fn '$afn' zeigt nicht ins Paket-Schema '$pkg' — uebersprungen (Boundary)."; continue ;; esac
      case "$vfn" in "$pkg".*) : ;; *) warn "monitor_acquisition_method '$method' -> validate_fn '$vfn' zeigt nicht ins Paket-Schema '$pkg' — uebersprungen (Boundary)."; continue ;; esac
      printf 'INSERT INTO core.monitor_acquisition_methods (method, acquire_fn, validate_fn, package, updated_at)\n'
      printf 'VALUES (%s, %s, %s, %s, now())\n' "$(_sql_str "$method")" "$(_sql_str "$afn")" "$(_sql_str "$vfn")" "$(_sql_str "$pkg")"
      printf 'ON CONFLICT (method) DO UPDATE SET acquire_fn=EXCLUDED.acquire_fn, validate_fn=EXCLUDED.validate_fn, package=EXCLUDED.package, updated_at=now()\n'
      printf '  WHERE core.monitor_acquisition_methods.package IS NULL OR core.monitor_acquisition_methods.package = EXCLUDED.package;\n'
      # Install-Zeit-Sichtbarkeit (analog _seed_callback_handlers): fehlt eine Ziel-fn -> WARNING. Signatur (jsonb)!
      # shellcheck disable=SC2016  # $ma$ ist ein literales SQL-Dollar-Quote-Tag, KEINE Shell-Expansion.
      printf 'DO $ma$ BEGIN IF to_regprocedure(%s) IS NULL OR to_regprocedure(%s) IS NULL THEN RAISE WARNING %s; END IF; END $ma$;\n' \
        "$(_sql_str "$afn(jsonb)")" "$(_sql_str "$vfn(jsonb)")" "$(_sql_str "monitor_acquisition_method $method -> $afn(jsonb)/$vfn(jsonb) nicht gefunden (Manifest-Typo/Apply-Order?)")"
    done
  done
}

# --- (5) core.protected_contexts — paket-deklarierter Loeschschutz-Registry (WS-B2b) -----
# Jedes Paket deklariert im manifest.json eine "protected_contexts"-Liste von core_contexts.name;
# der HOST upsertet sie in core.protected_contexts (Deklaration vs. Ausfuehrung, docs/package-contract.md
# §3.4 — analog _seed_context_validators). Der Core-Lösch-Trigger blockt DELETE fuer registrierte Namen
# (Finalizer-Muster). package = besitzendes Paket (Uninstall-Scope). Paket schreibt die Registry NIE selbst
# (D10 sperrt Paket-Rollen von core aus). Single-Trusted-Author -> kein harter own-package-Check (PK = first-writer).
_seed_protected_contexts() {
  local mf pkg name
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    _seed_skip_pkg "$(jq -r '.name // empty' "$mf")" && continue
    jq -r '.name as $pkg | (.protected_contexts // [])[] | [., $pkg] | @tsv' "$mf" |
    while IFS=$'\t' read -r name pkg; do
      [ -n "$name" ] || continue
      printf 'INSERT INTO core.protected_contexts (context_name, package)\n'
      printf 'VALUES (%s, %s)\n' "$(_sql_str "$name")" "$(_sql_str "$pkg")"
      printf 'ON CONFLICT (context_name) DO UPDATE SET package=EXCLUDED.package, updated_at=now();\n'
    done
  done
}

# --- (6) <pkg>.onboarding_state — paket-besessene Onboarding-Sektionen (WS-B3 DRY-Onboarding) -----
# Jedes Paket DEKLARIERT seine Onboarding-Sektionen in packages/<pkg>/onboarding/sections.json
# ([{key,ord,label}]); der HOST seedet sie in <schema>.onboarding_state (homogenes Muster; ON CONFLICT
# DO NOTHING -> vorhandene Status bleiben erhalten). Die Tabelle legt der Paket-Init an; gelesen/geschrieben
# wird ueber die Core-Schnittstelle core.fn_onboarding_status / core.fn_set_onboarding_section. Core-'household'
# bleibt in agent.guide_init.sql hardkodiert (Host-Konvenienz, kein packages/core/onboarding noetig).
#
# P2b-1 PER-USER (career): traegt ein Paket in seinem context_scopes-Block einen per_user-Context, ist
# <pkg>.onboarding_state PRO PERSON (person_id NOT NULL, composite-PK (section_key, person_id)). Dann wird die
# OWNER-Zeile geseedet (person_id aus family role=owner; der Owner existiert hier, weil bootstrap_owner VOR
# pkg_install_one laeuft) als Sektions-Katalog; weitere Personen materialisiert core.fn_ensure_onboarding_person
# lazy daraus. Kein Owner (sollte nicht vorkommen) -> 0 Zeilen statt NOT-NULL-Crash. Die per_user-Ableitung
# spiegelt die fn-Ableitung (context_scopes scope='per_user'), gelesen aus dem Manifest.
_seed_onboarding_sections() {
  # --no-seed (pkg_install_one im Restore-vor-Install-Pfad): NUR die nutzerdaten-foermige onboarding_state
  # ueberspringen (der Restore bringt sie); die Code-Seeds (config/ui_languages/ui_texts/contexts/validators/protected/services)
  # laufen IMMER (nie im Backup-Bundle). M4.
  [ "${SEED_SKIP_ONBOARDING:-0}" = "1" ] && { log "onboarding_state-Seed uebersprungen (--no-seed)."; return 0; }
  local mf pkg schema sf key ord label per_user
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    pkg="$(jq -r '.name' "$mf")"
    _seed_skip_pkg "$pkg" && continue
    schema="$(jq -r '.schema // .name' "$mf")"
    sf="$REPO_ROOT/packages/$pkg/onboarding/sections.json"
    [ -f "$sf" ] || continue
    # per_user gdw irgendein context_scopes-Eintrag scope='per_user' traegt (Objekt-Werte; _comment ignoriert).
    per_user="$(jq -r '[(.context_scopes // {}) | to_entries[] | select((.value|type=="object") and .value.scope=="per_user")] | length' "$mf")"
    # Label = deutscher Katalog-Text <pkg>.onboarding.<key> (Textkatalog Phase B): die Spalte ist die Modell-Projektion
    # (Onboarding-Agenten lesen sie); das Menue holt die Labels selbst in der Sprache des Betrachters.
    jq -r '.[] | [.key, (.ord|tostring)] | @tsv' "$sf" |
    while IFS=$'\t' read -r key ord; do
      [ -n "$key" ] || continue
      label="$(pkg_text "$pkg" "onboarding.$key")"; label="${label:-$key}"
      if [ "${per_user:-0}" -gt 0 ]; then
        # per_user: Owner-Zeile (person_id aus family role=owner via SQL-Subquery; kein Owner -> 0 Zeilen).
        printf 'INSERT INTO %s.onboarding_state (section_key, ord, label, person_id)\n' "$schema"
        printf "SELECT %s, %s, %s, o.pid FROM (SELECT pp->>'person_id' AS pid FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons', '[]'::jsonb)) pp WHERE c.name='family' AND pp->>'role'='owner' LIMIT 1) o WHERE o.pid IS NOT NULL\n" "$(_sql_str "$key")" "$ord" "$(_sql_str "$label")"
        printf 'ON CONFLICT (section_key, person_id) DO NOTHING;\n'
      else
        printf 'INSERT INTO %s.onboarding_state (section_key, ord, label)\n' "$schema"
        printf 'VALUES (%s, %s, %s)\n' "$(_sql_str "$key")" "$ord" "$(_sql_str "$label")"
        printf 'ON CONFLICT (section_key) DO NOTHING;\n'
      fi
      # Label + ord sind Code-Fakten aus sections.json -> bei jedem Seed auf ALLE Zeilen der Sektion nachziehen
      # (per_user: auch lazy materialisierte Personen-Zeilen). status = Nutzerdaten, bleibt unberuehrt.
      printf 'UPDATE %s.onboarding_state SET label = %s, ord = %s WHERE section_key = %s AND (label IS DISTINCT FROM %s OR ord IS DISTINCT FROM %s);\n' \
        "$schema" "$(_sql_str "$label")" "$ord" "$(_sql_str "$key")" "$(_sql_str "$label")" "$ord"
    done
  done
}

# _collect_workflow_name_ids — TSV (name<TAB>id) ALLER getrackten Workflow-JSONs
# (packages/*/workflows; Build-Artefakte _*.json uebersprungen — dieselbe Dir-Logik wie
# deploy_workflows.sh). REINE Datei-Lese (kein REST, keine Import-Abhaengigkeit) — dieselbe Art Artefakt-
# Lese wie die Manifest-/Context-Reads. Liefert die name->id-Quelle fuer _seed_services (artefakt-
# deklarierte id; n8n uebernimmt sie id-erhaltend beim Import).
_collect_workflow_name_ids() {
  local d f dirs=()
  for d in "$REPO_ROOT"/packages/*/workflows; do [ -d "$d" ] && dirs+=("$d"); done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  for d in "${dirs[@]}"; do
    for f in "$d"/*.json; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in _*) continue ;; esac
      jq -r 'select(.name and .id) | [.name, .id] | @tsv' "$f" 2>/dev/null || true
    done
  done
}

# --- (6) core.services — generischer Service-Alias-Seeder (WS-B6) -------------
# Jedes Paket DEKLARIERT seine Dienste im manifest.json (provides.services: { <alias>: <workflow-name> });
# der HOST materialisiert sie in core.services (alias -> workflow_id + package). Gleiche Deklaration-vs-
# Ausfuehrung-Mechanik wie _seed_context_validators (das Paket schreibt die Registry NIE selbst). Die
# Workflow-id kommt artefakt-deklariert aus den getrackten JSONs (n8n uebernimmt sie id-erhaltend beim
# Import) -> KEIN REST-Read-Back. DECLARED state: die Deploy-Existenz bestaetigt der Verify post-deploy.
# Per-Paket-Reconcile (ownership-scoped, k8s ownerReference): loescht NUR aus DIESEM Paket-Manifest
# verschwundene Aliase, nie fremde.
# Zwei Formen (docs/package-contract.md §5): Core = String-Form { <alias>: <workflow-name> }, Zeilenname
# unqualifiziert. Nicht-Core-Paket-Tool-Services = Objekt-Form { <alias>: { workflow, description, permission,
# inputs } }, Zeilenname QUALIFIZIERT '<pkg>:<alias>' (globaler PK -> keine Kollision zwischen Anbietern; der
# Praefix-CHECK in core.services erzwingt es) + permission/description fuer den Vermittler agent.sub_dispatch_tool.
_seed_services() {
  local nameids; nameids="$(_collect_workflow_name_ids)"
  if [ -z "$nameids" ]; then
    warn "Kein Workflow-Baum gefunden (name->id leer) — core.services-Seed uebersprungen (kein Reconcile)."
    return 0
  fi
  local mf pkg has alias wf_name perm desc row wid aliases
  for mf in "$REPO_ROOT"/packages/*/manifest.json; do
    [ -f "$mf" ] || continue
    pkg="$(jq -r '.name // empty' "$mf" 2>/dev/null)" || { warn "Manifest unlesbar: $mf — uebersprungen."; continue; }
    [ -n "$pkg" ] || { warn "Manifest ohne .name: $mf — uebersprungen."; continue; }
    _seed_skip_pkg "$pkg" && continue
    # Deklariert das Paket (noch) Dienste? Gezaehlt werden echte Aliase (Objekt-Keys ohne '_'-Kommentare; eine
    # leere Liste [] = keine). Keine -> ownership-scoped ALLES dieses Pakets entfernen: ein Paket, das seinen
    # letzten Dienst streicht, hinterlaesst sonst Leichen-Zeilen, die core.fn_resolve_service bei aktivem Paket
    # auf einen nicht mehr existierenden Workflow aufloesen wuerde (Cold-Eyes, Phase 2). Fuer Pakete ohne je
    # einen Dienst ist das DELETE ein No-op.
    has="$(jq -r '(.provides.services // {}) | if type == "object" then ([keys[] | select(startswith("_") | not)] | length) else 0 end > 0' "$mf" 2>/dev/null)"
    if [ "$has" = "false" ]; then
      printf 'DELETE FROM core.services WHERE package = %s;\n' "$(_sql_str "$pkg")"
      continue
    elif [ "$has" != "true" ]; then
      warn "core.services: provides.services von $pkg nicht auswertbar — uebersprungen (kein Reconcile)."; continue
    fi
    # Upsert je (alias, wf_name) mit Map-Treffer; ALLE deklarierten Aliase fuer den Reconcile sammeln (S1).
    aliases=""
    while IFS=$'\t' read -r alias wf_name perm desc; do
      [ -n "$alias" ] || continue
      if [ "$pkg" = "core" ]; then row="$alias"; else row="$pkg:$alias"; fi
      aliases="${aliases:+$aliases, }$(_sql_str "$row")"
      wid="$(printf '%s\n' "$nameids" | awk -F'\t' -v n="$wf_name" '$1==n {print $2; exit}')"
      if [ -z "$wid" ]; then
        warn "core.services: $pkg provides.services '$alias' -> Workflow '$wf_name' nicht im getrackten Baum — Zeile uebersprungen (Manifest-Typo/Build-Drift)."
        continue
      fi
      printf 'INSERT INTO core.services (name, workflow_id, package, permission, description)\n'
      printf 'VALUES (%s, %s, %s, %s, %s)\n' "$(_sql_str "$row")" "$(_sql_str "$wid")" "$(_sql_str "$pkg")" \
        "$(_sql_str "$perm")" "$(_sql_str "$desc")"
      printf 'ON CONFLICT (name) DO UPDATE SET workflow_id=EXCLUDED.workflow_id, package=EXCLUDED.package, permission=EXCLUDED.permission, description=EXCLUDED.description;\n'
    done < <(jq -r '.provides.services | to_entries[] | select(.key | startswith("_") | not)
                    | if (.value | type) == "object"
                      then [.key, .value.workflow, (.value.permission // "owner_only"), (.value.description // "")]
                      else [.key, .value, "owner_only", ""] end | @tsv' "$mf")
    # Per-Paket-Reconcile (ownership-scoped): nur Aliase DIESES Pakets, gegen die DEKLARIERTE Menge (S1:
    # nicht die Treffer-Teilmenge -> eine declared-but-not-yet-deployed-Zeile bleibt erhalten).
    [ -n "$aliases" ] && \
      printf 'DELETE FROM core.services WHERE package = %s AND name <> ALL (ARRAY[%s]::text[]);\n' \
        "$(_sql_str "$pkg")" "$aliases"
  done
}

seed_data() {
  [ -n "${REPO_ROOT:-}" ]   || die "REPO_ROOT nicht gesetzt."
  [ -n "${N8N_DB_NAME:-}" ] || die "N8N_DB_NAME nicht gesetzt."
  require_cmd runuser
  require_cmd jq

  log "Daten-Seeds laden (ai_models -> config -> capabilities + instruction contexts -> Manifest-Registries [validators/scopes/renderers/advisors/cron_labels/callbacks/monitor-methods] + protected + onboarding + services) ..."

  local driver; driver="$(mktemp /tmp/seed_data.XXXXXX.sql)"
  chmod 0644 "$driver"   # postgres-User liest den Treiber; alle Inhalte sind PII-frei (Seed-Trennung)
  {
    printf '\\set ON_ERROR_STOP on\n'
    printf 'BEGIN;\n'
    _seed_ai_models       # ZUERST (config-Trigger referenziert model_key)
    _seed_package_config  # core.config aus den .config-Bloecken ALLER Manifeste (WS4a; loest _seed_config ab)
    _seed_ui_languages    # core.ui_languages aus dem Core-Manifest "languages" (Textkatalog; vor den Texten, FK)
    _seed_ui_personas     # core.ui_personas aus dem Core-Manifest "personas" (Wertevorrat family.persons[].persona)
    _seed_ui_texts        # core.ui_texts aus packages/<pkg>/locales/<lang>.json (Textkatalog, je Paket ersetzt)
    _seed_contexts
    _seed_context_validators   # core.context_validators aus den Paket-Manifesten (WS-B1/D12)
    _seed_context_scopes       # core.context_scopes aus den Paket-Manifesten (P0a Scope-/Permission-Registry)
    _seed_context_skeletons       # leere Fakten-Skelette der Pakete (Install-UX-Phase 6, insert-only, nach den Validatoren)
    _seed_context_renderers    # core.context_renderers aus den Paket-Manifesten (WS1a Render-Engine)
    _seed_advisors             # core.advisors aus den Paket-Manifesten (WS2 Core-Advisor-Engine)
    _seed_cron_labels          # core.cron_labels aus den Paket-Manifesten (Phase 0 WS-0c #2/#3 Cron-Toggle-Registry)
    _seed_callback_handlers    # core.callback_handlers aus den Paket-Manifesten (Phase 0 WS-0c CB Callback-Dispatch-Registry)
    _seed_app_screens          # core.app_screens aus den Paket-Manifesten (Mini-App „Übersicht“, §3.12)
    _seed_monitor_acquisition_methods  # core.monitor_acquisition_methods aus den Paket-Manifesten (Phase B Monitor-Methoden)
    _seed_protected_contexts  # core.protected_contexts aus den Paket-Manifesten (WS-B2b Loeschschutz)
    _seed_onboarding_sections  # <pkg>.onboarding_state aus packages/<pkg>/onboarding/sections.json (WS-B3)
    _seed_services             # core.services aus provides.services ALLER Manifeste + getrackten Workflow-ids (WS-B6)
    printf 'COMMIT;\n'
  } > "$driver"

  if _seed_psql -f "$driver"; then
    rm -f "$driver"
    ok "Daten-Seeds geladen (Modelle, Config, Instruktions-Contexts)."
  else
    local rc=$?
    warn "Seed-Treiber zur Fehlersuche behalten: $driver"
    die "Daten-Seed fehlgeschlagen (psql exit $rc) — Fehlerstelle in der Ausgabe oben."
  fi
}

# register_package <pkg> [status]  — EIN Paket in core.package_registry registrieren (Upsert aus dem
# Manifest) und optional auf <status> setzen (leer = nur registrieren -> fn_pkg_register setzt bei der
# Erstanlage 'installing', laesst den Status bei Re-Register unangetastet). Phase 5: ersetzt das pauschale
# register_packages (INTERIM). provision.sh registriert den Core ('active') in der Core-Phase; jedes andere
# Paket registriert+aktiviert der per-Paket-Install (pkg_install_one Stage 1 'register' -> Stage 7 'active').
# EIN Mechanismus, kein "alles aktiv"-Pauschal-Seed mehr. Idempotent. Reads globals: REPO_ROOT, N8N_DB_NAME.
register_package() {
  local pkg="$1" status="${2:-}"
  [ -n "${REPO_ROOT:-}" ]   || die "REPO_ROOT nicht gesetzt."
  [ -n "${N8N_DB_NAME:-}" ] || die "N8N_DB_NAME nicht gesetzt."
  require_cmd jq; require_cmd md5sum
  printf '%s' "$pkg" | grep -qE '^[a-z][a-z0-9_]*$' || { warn "Ungueltiger Paketname '$pkg' — Registrierung uebersprungen."; return 1; }
  # $status wird unten in die SQL interpoliert -> gegen die CHECK-Enum-Werte validieren (heute nur 'active';
  # Backstop gegen einen kuenftigen Aufrufer, der einen freien String reinreicht -> sonst malformte SQL).
  [ -z "$status" ] || printf '%s' "$status" | grep -qE '^[a-z][a-z_]+$' || { warn "Ungueltiger Status '$status' — Registrierung '$pkg' uebersprungen."; return 1; }
  local mf="$REPO_ROOT/packages/$pkg/manifest.json"
  [ -f "$mf" ] || { warn "Manifest fehlt: $mf — Registrierung '$pkg' uebersprungen."; return 1; }
  local sum payload esc setstatus=""
  sum="$(md5sum "$mf" | awk '{print $1}')"
  # display_name = deutscher Katalog-Name (<pkg>.package.name, Textkatalog Phase B; Konsole/Modell-Projektion).
  payload="$(jq -c --arg sum "$sum" --arg dn "$(pkg_text "$pkg" package.name)" \
    '{package:.name, version:.version, description:.description, display_name:$dn, core_api:.core_api, requires:(.requires // []), manifest_checksum:$sum}' "$mf")"
  esc="${payload//\'/\'\'}"
  [ -n "$status" ] && setstatus="SELECT core.fn_pkg_set_status(jsonb_build_object('package','$pkg','status','$status'));"
  if _seed_psql -q -c "SELECT core.fn_pkg_register('$esc'::jsonb); $setstatus" >/dev/null; then
    ok "Paket '$pkg' registriert (core.package_registry${status:+, status=$status})."
  else
    warn "Paket-Registrierung '$pkg' fehlgeschlagen."
    return 1
  fi
}
