# images_cli.sh — `lifeagents images keep`: welche Abbilder der Docker-Verbund fuer Betrieb und Rueckweg noch braucht.
# Nur lesen: Loeschen gehoert der Start-App (sie fuehrt das Journal der selbst geladenen Abbilder; Regel im Kopf von
# runtime.sh). Kein docker-Aufruf: die Quelle sind allein die Dateien, aus denen Betrieb, master-Wechsel und Rueckweg ihre
# Abbilder nehmen.
#   current     aktuelle compose.yml (alle Pins des x-images-Blocks)
#   running     laufender master (LA_MASTER_IMAGE); zugleich swap_helper: der Helfer eines Wechsels startet aus ihm
#   backup:<s>  je aufbewahrte Sicherung <s>: ihre compose-Kopie und FROM_MASTER_IMAGE der .meta (Ziel von `rollback`)
#   pending     Merkzettel eines unvollendeten Updates samt compose-Kopie (auch ohne Sicherung)
#   swap_new / swap_old / swap_prev   Dateien des master-Wechsels (offen: Ziel und Ausgang; danach compose.prev.yml)
# Gesourct von lifeagents.tpl nach common.sh, fetch_release.sh (master_swap.sh) und upgrade_guard.sh (Pfade).

# _img_compose_refs <compose-datei> — Abbild-Referenzen des x-images-Blocks, eine je Zeile. Die master-Zeile traegt den Pin
#   als Vorgabe `${LA_MASTER_IMAGE:-<ref>}`; die neutrale Form `${LA_MASTER_IMAGE:?…}` (Branch-Bau) nennt keinen.
_img_compose_refs() {
  [ -r "$1" ] || return 0
  awk '
    /^x-images:/ { inb = 1; next }
    inb && /^[^ #]/ { inb = 0 }
    inb && /^  [a-z_]+: &img_[a-z_]+ / {
      v = $0; sub(/^  [a-z_]+: &img_[a-z_]+ +/, "", v); sub(/ +#.*$/, "", v)
      if (v ~ /^\$\{LA_MASTER_IMAGE:-/) { sub(/^\$\{LA_MASTER_IMAGE:-/, "", v); sub(/\}$/, "", v) }
      else if (v ~ /^\$\{/) next
      if (v != "") print v
    }' "$1"
}

# _img_pairs — "<ref>\t<quelle>" je Fund auf stdout.
_img_pairs() {
  local f b v
  _img_emit() { [ -n "$1" ] && printf '%s\t%s\n' "$1" "$2"; return 0; }
  _img_compose_refs "$LA_COMPOSE_FILE" | while IFS= read -r v; do _img_emit "$v" current; done
  _img_emit "${LA_MASTER_IMAGE:-}" running; _img_emit "${LA_MASTER_IMAGE:-}" swap_helper
  for f in "$UPGRADE_BACKUP_DIR"/pre-upgrade-*.dump.gpg; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    _img_compose_refs "${f}.compose.yml" | while IFS= read -r v; do _img_emit "$v" "backup:$b"; done
    _img_emit "$(read_env_value "${f}.meta" FROM_MASTER_IMAGE 2>/dev/null || true)" "backup:$b"
  done
  if [ -f "$UPGRADE_MARKER" ]; then
    _img_emit "$(read_env_value "$UPGRADE_MARKER" FROM_MASTER_IMAGE 2>/dev/null || true)" pending
    _img_compose_refs "$(read_env_value "$UPGRADE_MARKER" FROM_COMPOSE 2>/dev/null || true)" | while IFS= read -r v; do _img_emit "$v" pending; done
  fi
  _img_compose_refs "$SWAP_DIR/compose.new.yml" | while IFS= read -r v; do _img_emit "$v" swap_new; done
  _img_compose_refs "$SWAP_DIR/compose.old.yml" | while IFS= read -r v; do _img_emit "$v" swap_old; done
  _img_compose_refs "$SWAP_DIR/compose.prev.yml" | while IFS= read -r v; do _img_emit "$v" swap_prev; done
  if [ -f "$SWAP_STATE" ]; then
    _img_emit "$(read_env_value "$SWAP_STATE" TO 2>/dev/null || true)" swap_new
    _img_emit "$(read_env_value "$SWAP_STATE" FROM 2>/dev/null || true)" swap_old
  fi
}

# images_keep [--plain] — JSON {"ok":true,"images":[{"ref","sources":[…]}]} (nach ref sortiert, jede ref einmal) bzw. mit
#   --plain eine ref je Zeile. Klassisch {"ok":false,"reason":"not_compose"}, rc 1 (dort gibt es keine Abbilder).
images_keep() {
  local plain=0
  case "${1:-}" in --plain) plain=1 ;; '') ;; *) die "Unbekannte Angabe '${1}' — erlaubt: --plain." ;; esac
  if ! rt_is_compose; then printf '{"ok":false,"reason":"not_compose"}\n'; return 1; fi
  require_root
  if [ "$plain" = 1 ]; then _img_pairs | cut -f1 | LC_ALL=C sort -u; return 0; fi
  _img_pairs | jq -R -s -c '
    [split("\n")[] | select(length > 0) | split("\t") | {ref: .[0], src: .[1]}]
    | group_by(.ref) | map({ref: .[0].ref, sources: (map(.src) | unique)})
    | {ok: true, images: .}'
}

images_usage() {
  cat >&2 <<'EOF'
lifeagents images — Abbilder des Docker-Verbunds (nur lesen).

  keep [--plain]   Abbilder, die Betrieb, master-Wechsel und Rückweg noch brauchen: JSON für die Start-App
                   ({"ok":true,"images":[{"ref":…,"sources":[…]}]}), mit --plain eine Referenz je Zeile.
                   Gelöscht wird nichts. Braucht root.
EOF
}

images_cli() {
  case "${1:-help}" in
    keep) shift; images_keep "$@" ;;
    help|--help|-h) images_usage ;;
    *) images_usage; die "lifeagents images: unbekannter Befehl '${1}'." ;;
  esac
}
