#!/usr/bin/env bash
# Korrektur hitl-chat-no-link-fallback im Docker-Verbund: das Original kommt aus dem unveraenderten n8n-Image, die gepatchte Datei liegt
# im Volume n8n_patches und ist ueber compose.yml in den n8n-Container eingehaengt (n8n_patches.sh _apply_n8n_patches_compose).
# Aufruf: bash compose_cases.sh <wurzel mit provisioning/ und mock_n8n_patch/>, im master des laufenden Verbunds (cases.sh ruft es dort
# selbst). Ausgabe PASS/FAIL je Fall. Das Volume des Verbunds bleibt unberuehrt: die Anwendung laeuft gegen einen Temp-Ordner.
set -uo pipefail
ROOT="$1"
ID=hitl-chat-no-link-fallback
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/n8n_patches.sh"
rt_is_compose || { printf 'FAIL setup: LIFEAGENTS_RUNTIME=compose fehlt (nur im master des Verbunds)\n'; exit 1; }
# Die echte n8n_live_cat (docker exec in den n8n-Container) bleibt; LIVE_OVERRIDE stellt eine fremde Fassung vor, wie in cases.sh.
eval "_live_cat_real$(declare -f n8n_live_cat | sed '1s/^n8n_live_cat//')"
# shellcheck disable=SC2329  # wird indirekt ueber n8n_patch_status gerufen
n8n_live_cat() { if [ -n "${LIVE_OVERRIDE:-}" ]; then cat "$LIVE_OVERRIDE"; else _live_cat_real "$@"; fi; }

check() { if [ "$2" = "$3" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s: bekam %s, erwartet %s\n' "$1" "$2" "$3"; fi; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }

FILE="$(n8n_patch_file "$ID")"; NAME="$(basename "$FILE")"
STAGE="$(mktemp -d)"; OUT="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$OUT"' EXIT

# Was n8n gerade sieht: die gepatchte Datei aus dem Volume (Mount ueber das Image-Verzeichnis).
check status_im_laufenden_n8n "$(n8n_patch_status "$ID")" patched

# Das Original aus dem Image (nie aus dem laufenden Container: dort liegt der Mount).
if n8n_image_tar "$(dirname "$FILE")" 2>/dev/null | tar -xf - -C "$STAGE" 2>/dev/null && [ -f "$STAGE/$NAME" ]; then
  ORIG="$STAGE/$NAME"
  check original_aus_image "$(sha "$ORIG")" "$(_n8n_patch_field "$ID" 3)"
else
  printf 'FAIL original_aus_image: Datei nicht aus dem n8n-Image zu holen (%s)\n' "$FILE"
  exit 1
fi

TMP="$STAGE/.render"
if _n8n_patch_render "$ID" "$ORIG" "$TMP"; then
  check ersatz_ergibt_zielfassung "$(sha "$TMP")" "$(_n8n_patch_field "$ID" 4)"
else
  printf 'FAIL ersatz_ergibt_zielfassung: Ersatz nicht moeglich\n'
fi

# Ein n8n-Update ersetzt die Datei: jede fremde Fassung darf nie als aktiv gelten.
cp "$ORIG" "$STAGE/.variant"; printf '\n// andere Fassung\n' >> "$STAGE/.variant"
LIVE_OVERRIDE="$STAGE/.variant"; check update_unbekannte_fassung "$(n8n_patch_status "$ID")" unknown
printf 'module.exports = {};\n' > "$STAGE/.variant"
check update_stelle_entfernt "$(n8n_patch_status "$ID")" changed
LIVE_OVERRIDE="$ORIG"; check original_erkannt "$(n8n_patch_status "$ID")" original
unset LIVE_OVERRIDE
n8n_patch_must_stay "$ID"; check entfernt_ist_doctor_rot "$?" 0
n8n_patch_must_stay memory-all-tool-rounds; check andere_korrektur_nur_hinweis "$?" 1

# Anwenden gegen einen Temp-Ordner statt des Volumes: erzeugt <id>/<datei> in der Zielfassung, meldet die Aenderung (n8n-Neustart),
# und ein Zweitlauf aendert nichts.
N8N_PATCHES=("$(printf '%s\n' "${N8N_PATCHES[@]}" | grep "^$ID|")")
N8N_PATCH_DIR="$OUT" apply_n8n_patches >/dev/null 2>&1
check anwenden_erzeugt_zielfassung "$([ -f "$OUT/$ID/$NAME" ] && sha "$OUT/$ID/$NAME")" "$(_n8n_patch_field "$ID" 4)"
check anwenden_fordert_neustart "$N8N_PATCH_CHANGED" 1
N8N_PATCH_DIR="$OUT" apply_n8n_patches >/dev/null 2>&1
check zweitlauf_aendert_nichts "$N8N_PATCH_CHANGED" 0

# Verhalten der gepatchten Datei, gleiche Probe wie klassisch. Sie laedt n8n-workflow und n8n-core ueber den Pfad der Datei: das geht nur
# im n8n-Container, und dort gegen die eingehaengte Datei am Originalpfad (so sieht n8n sie).
docker cp "$ROOT/mock_n8n_patch/hitl_chat_approval_cases.js" "$LA_N8N_CONTAINER:/tmp/hitl_chat_approval_cases.js" >/dev/null 2>&1 \
  || { printf 'FAIL verhalten_probe: Probe nicht in den n8n-Container kopierbar\n'; exit 1; }
# hand-injected: N8N_USER_FOLDER ist nur der Arbeitsordner der Probe (n8n-core legt dort beim Laden seine Konfiguration an), kein Wert des geprueften Patches
probe_out="$(docker exec -e N8N_USER_FOLDER=/tmp/hitl-probe "$LA_N8N_CONTAINER" node /tmp/hitl_chat_approval_cases.js "$FILE" 2>&1)"; probe_rc=$?
docker exec "$LA_N8N_CONTAINER" rm -rf /tmp/hitl_chat_approval_cases.js /tmp/hitl-probe >/dev/null 2>&1
printf '%s\n' "$probe_out"
# Eine Probe, die gar nichts ausgibt (Absturz beim Laden), darf nicht wie ein gruener Lauf aussehen.
printf '%s\n' "$probe_out" | grep -q '^PASS ' || { printf 'FAIL verhalten_probe: keine PASS-Zeile von der Probe: %s\n' "$(printf '%s' "$probe_out" | head -c 300 | tr '\n' ' ')"; exit 1; }
exit "$probe_rc"
