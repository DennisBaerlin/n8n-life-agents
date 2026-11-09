#!/usr/bin/env bash
# Korrektur hitl-chat-no-link-fallback am installierten n8n: Fingerabdruck, Status-Erkennung, Verhalten (hitl_chat_approval_cases.js).
# Aufruf: bash cases.sh <wurzel mit provisioning/ und mock_n8n_patch/>. Ausgabe PASS/FAIL je Fall.
set -uo pipefail
ROOT="$1"
ID=hitl-chat-no-link-fallback
rt_is_compose() { return 1; }
n8n_live_cat() { cat "${LIVE_OVERRIDE:-$1}"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
ok() { :; }
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/n8n_patches.sh"

check() { if [ "$2" = "$3" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s: bekam %s, erwartet %s\n' "$1" "$2" "$3"; fi; }

FILE="$(n8n_patch_file "$ID")"
check status_installiert "$(n8n_patch_status "$ID")" patched
check original_gesichert "$([ -f "$FILE.orig" ] && sha256sum < "$FILE.orig" | cut -d' ' -f1)" "$(_n8n_patch_field "$ID" 3)"

TMP="$(mktemp)"
if [ -f "$FILE.orig" ] && _n8n_patch_render "$ID" "$FILE.orig" "$TMP"; then
  check ersatz_ergibt_zielfassung "$(sha256sum < "$TMP" | cut -d' ' -f1)" "$(_n8n_patch_field "$ID" 4)"
else
  printf 'FAIL ersatz_ergibt_zielfassung: Ersatz nicht moeglich\n'
fi

# Ein n8n-Update ersetzt die Datei: jede fremde Fassung darf nie als aktiv gelten.
cp "$FILE.orig" "$TMP"; printf '\n// andere Fassung\n' >> "$TMP"
LIVE_OVERRIDE="$TMP"; check update_unbekannte_fassung "$(n8n_patch_status "$ID")" unknown
printf 'module.exports = {};\n' > "$TMP"
check update_stelle_entfernt "$(n8n_patch_status "$ID")" changed
LIVE_OVERRIDE="$FILE.orig"; check original_erkannt "$(n8n_patch_status "$ID")" original
unset LIVE_OVERRIDE
rm -f "$TMP"
n8n_patch_must_stay "$ID"; check entfernt_ist_doctor_rot "$?" 0
n8n_patch_must_stay memory-all-tool-rounds; check andere_korrektur_nur_hinweis "$?" 1

# Handkorrektur an der Datei: das Update stellt aus dem npm-Paket (Attrappe) das Original her und patcht; passt es nicht, bleibt alles.
N8N_PATCH_FILE_BACKUP="$(mktemp)"; cp -p "$FILE" "$N8N_PATCH_FILE_BACKUP"
PACK_ORIG="$FILE.orig"
npm() {
  if [ "$1" = pack ]; then
    local d; d="$(mktemp -d)"; mkdir -p "$d/package/dist/nodes/Telegram/hitl"
    cp "$PACK_ORIG" "$d/package/dist/nodes/Telegram/hitl/setup.js"
    tar -czf ./fake.tgz -C "$d" package; rm -rf "$d"; return "${PACK_RC:-0}"
  fi
  command npm "$@"
}
only_this_patch() { N8N_PATCHES=("$(printf '%s\n' "${N8N_PATCHES[@]}" | grep "^$ID|")"); }
only_this_patch
printf '\n// von Hand geaendert\n' >> "$FILE"
apply_n8n_patches
check hand_geaendert_wird_gepatcht "$(n8n_patch_status "$ID")" patched
check hand_geaendert_neustart_angefordert "$N8N_PATCH_CHANGED" 1

printf '\n// von Hand geaendert\n' >> "$FILE"; HAND_SHA="$(sha256sum < "$FILE")"
PACK_RC=1 apply_n8n_patches
check npm_fehlt_datei_unberuehrt "$(sha256sum < "$FILE")" "$HAND_SHA"
check npm_fehlt_status_nicht_aktiv "$(n8n_patch_status "$ID")" changed
cp -p "$N8N_PATCH_FILE_BACKUP" "$FILE"; rm -f "$N8N_PATCH_FILE_BACKUP"

N8N_USER_FOLDER="$(mktemp -d)" node "$ROOT/mock_n8n_patch/hitl_chat_approval_cases.js" "$FILE" 2>/dev/null
