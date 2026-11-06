# shellcheck disable=SC2034  # N8N_PATCH_CHANGED liest install_n8n_unit (install_n8n.sh, gesourct): Neustart nach angewendeter Korrektur
# n8n_patches.sh — gezielte Korrekturen an der npm-global installierten n8n, bis n8n sie selbst liefert.
# Sourced by provision.sh (apply_n8n_patches in install_n8n) + doctor.sh (n8n_patch_status, read-only).
#
# Warum ein eigener Mechanismus (arch-challenge 2026-10-23): n8n laeuft als `npm install -g` ohne eigenes
# Projekt-Manifest -> patch-package/pnpm patch/npm overrides greifen nicht ohne Umbau (Fork, anderer ExecStart).
# Etabliertes Muster stattdessen: idempotenter, verankerter Ersatz (Ansible `replace`) mit Fingerabdruck der GANZEN
# Datei vorher und nachher (strenger als ein Diff-Kontext, kein Zusatzpaket wie `patch`):
#   Datei = bekannte Original-Fassung  -> jede Anker-Stelle woertlich ersetzen (je genau EIN Vorkommen),
#                                         <datei>.orig behalten, Ergebnis-Hash pruefen
#   Datei = bekannte gepatchte Fassung -> nichts tun (Zweitlauf = no-op)
#   Leit-Anker fehlt                   -> nichts tun; n8n hat die Stelle geaendert (vermutlich behoben) -> pruefen
#   sonst (unbekannte Fassung)         -> nichts anfassen, warnen; doctor meldet ROT
# Ein npm-Reinstall/Update ersetzt die Datei -> install_n8n ruft apply_n8n_patches bei JEDEM Lauf nach
# ensure_n8n_package. n8n-Pin-Wechsel: Hashes je Patch neu pruefen bzw. den Patch loeschen (provisioning/CLAUDE.md).
#
# Tabelle: id|Pfad relativ zu `npm root -g`|sha256 Original|sha256 gepatcht|Grund (Issue)
# Ersatz-Paare je id in _n8n_patch_pairs (JSON [[anker, ersatz], ...], woertlich, kein Regex); der ERSTE Anker ist
# der Leit-Anker fuer die Status-Erkennung.
N8N_PATCHES=(
  "memory-all-tool-rounds|n8n/node_modules/@n8n/n8n-nodes-langchain/dist/utils/agent-execution/memoryManagement.js|265e5c43cf6474f882ef03a24bb120579022ac2da2d93a297db865635e7eff73|47358c76e32c0618b7dff6561ecc7285a79cabf20f489e7a5b4f4ccb0baae84c|AI Agent V3 speichert nur die letzte Tool-Runde einer Nachricht im Chat-Gedächtnis (https://github.com/n8n-io/n8n/issues/41554)"   # lint-ignore: npm-Paketpfad unter `npm root -g`, kein Repo-Ordner
)

# _n8n_patch_pairs <id> -> JSON-Array der Ersatz-Paare
#   memory-all-tool-rounds (n8n 2.44.4 / langchain 2.44.2; in n8n 2.45.4 / langchain 2.45.3 byte-gleiche Datei):
#   (1) saveToMemory schneidet die Tool-Runden einer Nachricht nicht mehr bis auf die letzte ab (= Upstream-PR #41577);
#   (2) buildMessagesFromSteps: fruehere Runden kommen ueber die Ausfuehrungs-Metadaten serialisiert zurueck
#       ({lc, kwargs} statt AIMessage) -> wieder zur AIMessage machen, sonst bricht die Postgres-Chat-Memory mit
#       "message.toDict is not a function" ab (im Substrat nachgewiesen 2026-10-23; PR #41577 allein reicht nicht).
_n8n_patch_pairs() {
  case "$1" in
    memory-all-tool-rounds) cat <<'JSON'
[
  ["const newSteps = previousStepsCount ? steps.slice(previousStepsCount) : steps;",
   "const newSteps = steps;"],
  ["        const existingAIMessage = step.action.messageLog?.[0];",
   "        let existingAIMessage = step.action.messageLog?.[0];\n        if (existingAIMessage && typeof existingAIMessage.toDict !== 'function') {\n            existingAIMessage = new messages_1.AIMessage(existingAIMessage.lc === 1 && existingAIMessage.kwargs ? existingAIMessage.kwargs : existingAIMessage);\n        }"]
]
JSON
      ;;
    *) return 1 ;;
  esac
}

# _n8n_patch_anchor <id> -> Leit-Anker (erste Ersatz-Stelle; ihr Fehlen = n8n hat die Stelle geaendert)
_n8n_patch_anchor() {
  case "$1" in
    memory-all-tool-rounds) printf '%s' 'const newSteps = previousStepsCount ? steps.slice(previousStepsCount) : steps;' ;;
    *) return 1 ;;
  esac
}

# _n8n_patch_field <id> <feldnr 1..5>
_n8n_patch_field() {
  local row
  for row in "${N8N_PATCHES[@]}"; do
    [ "${row%%|*}" = "$1" ] && { printf '%s' "$row" | cut -d'|' -f"$2"; return 0; }
  done
  return 1
}

# n8n_patch_ids -> alle Patch-ids, je Zeile eine
n8n_patch_ids() { local row; for row in "${N8N_PATCHES[@]}"; do printf '%s\n' "${row%%|*}"; done; }

# n8n_patch_file <id> -> absoluter Pfad (Fehler, wenn npm fehlt)
n8n_patch_file() {
  local root; root="$(npm root -g 2>/dev/null || true)"
  [ -n "$root" ] || return 1
  printf '%s/%s' "$root" "$(_n8n_patch_field "$1" 2)"
}

# n8n_patch_status <id> -> original | patched | changed | unknown | missing   (read-only)
n8n_patch_status() {
  local f sha
  f="$(n8n_patch_file "$1" 2>/dev/null || true)"
  if [ -z "$f" ] || [ ! -f "$f" ]; then printf 'missing'; return 0; fi
  sha="$(sha256sum "$f" | cut -d' ' -f1)"
  if [ "$sha" = "$(_n8n_patch_field "$1" 3)" ]; then printf 'original'
  elif [ "$sha" = "$(_n8n_patch_field "$1" 4)" ]; then printf 'patched'
  elif grep -qF -- "$(_n8n_patch_anchor "$1")" "$f"; then printf 'unknown'
  else printf 'changed'; fi
}

# apply_n8n_patches — alle Patches anwenden (root, nach ensure_n8n_package). Setzt N8N_PATCH_CHANGED=1, wenn eine
# Datei geaendert wurde (install_n8n_unit startet n8n dann neu). Bricht den Install nie ab (warn statt die).
apply_n8n_patches() {
  local id f tmp
  N8N_PATCH_CHANGED=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$(n8n_patch_status "$id")" in
      patched)  ok "n8n-Korrektur '${id}' ist aktiv." ;;
      missing)  warn "n8n-Korrektur '${id}': Datei nicht gefunden — n8n-Aufbau geändert? Patch prüfen ($(_n8n_patch_field "$id" 5))." ;;
      changed)  warn "n8n-Korrektur '${id}': die fehlerhafte Zeile ist nicht mehr da — vermutlich hat n8n sie behoben; Patch prüfen und ggf. entfernen ($(_n8n_patch_field "$id" 5))." ;;
      unknown)  warn "n8n-Korrektur '${id}': unbekannte Datei-Fassung, NICHT gepatcht ($(_n8n_patch_field "$id" 5))." ;;
      original)
        f="$(n8n_patch_file "$id")"
        tmp="${f}.lifeagents-tmp"
        # Woertlicher Ersatz je Paar, jeder Anker genau EINMAL (node ist da: n8n laeuft darauf); Paare ueber Env
        if PATCH_SRC="$f" PATCH_DST="$tmp" PATCH_PAIRS="$(_n8n_patch_pairs "$id")" node -e '
            const fs = require("fs"); let s = fs.readFileSync(process.env.PATCH_SRC, "utf8");
            for (const [a, b] of JSON.parse(process.env.PATCH_PAIRS)) {
              const parts = s.split(a);
              if (parts.length !== 2) process.exit(3);
              s = parts.join(b);
            }
            fs.writeFileSync(process.env.PATCH_DST, s);' \
           && [ "$(sha256sum "$tmp" | cut -d' ' -f1)" = "$(_n8n_patch_field "$id" 4)" ]; then
          cp -p "$f" "${f}.orig"
          chmod --reference="$f" "$tmp" && chown --reference="$f" "$tmp"
          mv -f "$tmp" "$f"
          N8N_PATCH_CHANGED=1
          ok "n8n-Korrektur '${id}' angewendet (Original: ${f}.orig)."
        else
          rm -f "$tmp"
          warn "n8n-Korrektur '${id}': Ersatz ergab nicht die erwartete Fassung — Datei unverändert gelassen."
        fi ;;
    esac
  done < <(n8n_patch_ids)
}
