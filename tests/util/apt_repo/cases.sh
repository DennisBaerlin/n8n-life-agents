#!/usr/bin/env bash
# cases.sh — Fall-Runner von scripts/dev/apt_repo_test.ps1: apt-Quellen (add_apt_key/add_apt_source in provisioning/lib/common.sh)
# im frischen debian:12-Container mit echtem apt und echtem pkgs.tailscale.com, nur curl vorhanden, kein gnupg:
#   K  Schluessel + Quelle auf einem Rechner ohne gpg; danach muss ein `apt-get update` laufen.
#   B  Schluessel nicht beschaffbar: keine Quelle ohne Schluessel, ein altes Ueberbleibsel verschwindet, apt-get update laeuft.
#   T  Tunnel-Schritt (reach_cli_ts_install) mit unbekanntem gpg bis zu einem folgenden apt-get update.
#
# Usage: bash cases.sh <root>   (root = Verzeichnis mit provisioning/). Ausgabe "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
# shellcheck disable=SC2015,SC2034,SC2181,SC2329  # "a && pass || fail" gewollt (pass = rc 0); REACH_CORE_ENV liest reach_cli.sh
set -uo pipefail
ROOT="$1"
# hand-injected: apt laeuft im Wegwerf-Container ohne Rueckfragen (gleiche Einstellung wie install.sh/provision.sh)
export LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
rc_is() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "rc erwartet $2, bekommen $3"; fi; }
rc_ok() { if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1" "rc $2: $3"; fi; }
absent() { if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "$2 liegt noch da"; fi; }

# Ausgangslage wie bei der Installation: curl da (der Launcher hat es gebraucht), gnupg nicht.
apt-get update -qq >/dev/null && apt-get install -y -qq curl ca-certificates >/dev/null || { echo "FAIL setup: curl nicht installierbar"; exit 1; }
command -v gpg >/dev/null 2>&1 && { echo "FAIL setup: gpg schon da"; exit 1; }

# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/reach_cli.sh"
# hand-injected: kein systemd und kein TUN im Container; unattended, damit kein QR-Code/Dialog vorausgesetzt wird
export REACH_CLI_TS_DEFAULTS="/tmp/tailscaled.default" REACH_CLI_TUN_DEV=/nonexistent UNATTENDED=1
REACH_CORE_ENV=/tmp/core.env

KR=/usr/share/keyrings/tailscale-archive-keyring.gpg
LIST=/etc/apt/sources.list.d/tailscale.list
TS_KEY="https://pkgs.tailscale.com/stable/debian/bookworm.gpg"
TS_LINE="deb [signed-by=${KR}] https://pkgs.tailscale.com/stable/debian bookworm main"
reset() { rm -f "$KR" "$LIST"; _APT_UPDATED=0; }

# --- K: Schluessel ohne gpg -------------------------------------------------------------------------------------------
reset
( add_apt_key "$TS_KEY" "$KR" ) >/tmp/k.out 2>&1; rc_ok K_key_without_gpg $? "$(tail -n3 /tmp/k.out)"
[ -s "$KR" ] && pass K_keyring_written || fail K_keyring_written "Schluesselbund fehlt/leer"
( add_apt_source "$LIST" "$TS_LINE" ) >/tmp/k.out 2>&1; rc_ok K_source_written $? "$(tail -n3 /tmp/k.out)"
out="$(apt-get update -qq 2>&1)"; rc_ok K_apt_update_after $? "$out"

# --- B: Schluessel nicht beschaffbar ----------------------------------------------------------------------------------
reset
( add_apt_key "https://127.0.0.1:9/kein-schluessel.gpg" "$KR" ) >/tmp/b.out 2>&1; [ $? -ne 0 ] && pass B_key_fails || fail B_key_fails "rc 0 trotz fehlendem Schluessel"
( add_apt_source "$LIST" "$TS_LINE" ) >/tmp/b.out 2>&1; [ $? -ne 0 ] && pass B_source_refused || fail B_source_refused "Quelle ohne Schluesselbund angenommen"
absent B_no_list "$LIST"
printf '%s\n' "$TS_LINE" > "$LIST"
( add_apt_source "$LIST" "$TS_LINE" ) >/tmp/b.out 2>&1
absent B_stale_list_removed "$LIST"
out="$(apt-get update -qq 2>&1)"; rc_ok B_apt_update_after $? "$out"

# --- T: Tunnel-Schritt bis zum folgenden apt-get update ---------------------------------------------------------------
reset
( reach_cli_ts_install ) >/tmp/t.out 2>&1
command -v tailscale >/dev/null 2>&1 && pass T_tailscale_installed || fail T_tailscale_installed "tailscale fehlt: $(tail -n5 /tmp/t.out)"
out="$(apt-get update -qq 2>&1)"; rc_ok T_apt_update_after $? "$out"

printf '# %s Fehler\n' "$fails"
exit "$fails"
