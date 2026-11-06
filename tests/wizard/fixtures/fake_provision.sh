#!/usr/bin/env bash
# Attrappe von provision.sh für den Durchlauf: prüft den Aufruf und liest die Antwort-Datei so, wie es der Leser in
# Paket 1 tun muss (Vertrag di4-wizard-antwort-format: Kopfzeile, KEY=wert roh, nie ausführen), legt das Gelesene als JSON
# ab und meldet die Stufen über LIFEAGENTS_RESULT_FILE wie result_set. Fehler auf Wunsch: Datei $WIZARD_FAKE_DIR/fail_stage,
# Anhalten in einer Stufe (Vorschau-Bilder): $WIZARD_FAKE_DIR/hold_stage.
set -euo pipefail
D="${WIZARD_FAKE_DIR:?}"
[ "$#" -eq 4 ] && [ "$1 $2 $3" = "--profile release --unattended" ] || exit 64
f="$4"
[ "$(stat -c %a "$f")" = 600 ] || exit 65
[ -n "${LIFEAGENTS_RESULT_FILE:-}" ] || exit 66
first=1; json='{}'
while IFS= read -r l || [ -n "$l" ]; do
  if [ "$first" = 1 ]; then [ "$l" = '# lifeagents-answers v1' ] || exit 67; first=0; continue; fi
  case "$l" in *=*) : ;; *) exit 68 ;; esac
  k="${l%%=*}"; v="${l#*=}"
  [[ "$k" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || exit 69
  [ "$(jq -r --arg k "$k" 'has($k)' <<<"$json")" = false ] || exit 70
  json="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$json")"
done < "$f"
printf '%s' "$json" > "$D/parsed.json"
n="$(cat "$D/runs" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$D/runs"
for s in preflight base postgres n8n gateway schema access workflows packages cli final; do
  printf 'status=running\nstage=%s\n' "$s" > "$LIFEAGENTS_RESULT_FILE"
  while [ "$(cat "$D/hold_stage" 2>/dev/null || true)" = "$s" ]; do sleep 0.05; done   # Vorschau: Stufe anhalten
  fail="$(cat "$D/fail_stage" 2>/dev/null || true)"
  if [ "$fail" = "$s" ]; then printf 'status=failed\nstage=%s\nreason_code=fake_failure\n' "$s" > "$LIFEAGENTS_RESULT_FILE"; exit 1; fi
  sleep 0.02
done
printf 'status=ok\nstage=final\nchanged=true\n' > "$LIFEAGENTS_RESULT_FILE"
