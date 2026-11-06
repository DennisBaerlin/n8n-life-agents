#!/usr/bin/env bash
# profile_photo_cases.sh — Fall-Runner von scripts/dev/bot_profile_photo_test.ps1, laeuft IM Container (bash/curl/jq/node).
#
# Faehrt den ECHTEN Installer-Schritt (provisioning/lib/bootstrap_owner.sh _ensure_bot_profile_photo + _wire_telegram)
# gegen den Mock tests/mock_telegram/server.js. Wichtigste Eigenschaft zuerst: ein vorhandenes Bild wird nie ersetzt, eine
# unklare Antwort aendert nichts, ein Fehler ist nur eine Warnung. Belegt NICHT, wie sich das echte Telegram verhaelt.
#
# Usage: bash profile_photo_cases.sh <root> <port>     Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>" / "SKIP <fall>: <grund>";
#                                                      Exit = Anzahl FAIL. <root> enthaelt provisioning/, mock_telegram/ und optional bot_profile/.
# shellcheck disable=SC2034,SC2329  # Werte und Stubs in den Subshells gelten fuer die gesourcten Funktionen, die sie lesen bzw. rufen
set -uo pipefail
ROOT="$1"; PORT="$2"
W=/tmp/profile_photo_test
INSTALLED=/usr/local/lib/lifeagents
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
skip() { printf 'SKIP %s: %s\n' "$1" "$2"; }
# eq <fall> <erwartet> <ist>
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }
# has <fall> <muster> — die Ausgabe des letzten Laufs enthaelt <muster>
has() { if printf '%s' "$OUT" | grep -qF "$2"; then pass "$1"; else fail "$1" "'$2' fehlt in: $OUT"; fi; }

# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/provisioning/lib/bootstrap_owner.sh"

# --- Sandbox + Mock -------------------------------------------------------------------------------------------
rm -rf "$W"; mkdir -p "$W/etc" "$W/tree/packages/core/build/bot_profile"
for d in /proc/[0-9]*; do
  if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q "^node .*profile_photo_mock/server\.js"; then kill "${d#/proc/}" 2>/dev/null || true; fi
done
sleep 0.2
MOCK_DIR="$W/profile_photo_mock"; mkdir -p "$MOCK_DIR"; cp "$ROOT/mock_telegram/server.js" "$MOCK_DIR/server.js"
LOG="$W/requests.jsonl"
N8NTEST_MOCK_TG_PORT="$PORT" N8NTEST_MOCK_TG_LOG="$LOG" node "$MOCK_DIR/server.js" >/dev/null 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 25); do curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 && break; sleep 0.2; done
curl -sf "http://127.0.0.1:$PORT/__health" >/dev/null 2>&1 || { fail setup 'Mock antwortet nicht'; exit 1; }

# Test-Bild: kleinste Datei mit JPEG-Anfang. Das echte Bild prueft Fall bild-* unten.
IMG="$W/tree/packages/core/build/bot_profile/bot_profile.jpg"
printf '\377\330\377\340\000\020JFIF\000\001\377\331' > "$IMG"

TOKEN='1000001:MARKERTOKENzz9'
STATE="$W/etc/bot-profile-photo"
export LIFEAGENTS_DIR="$W/etc" LIFEAGENTS_LIB="$W/tree" N8N_OWNER_ENV_FILE="$W/etc/core.env"
export LIFEAGENTS_TELEGRAM_API="http://127.0.0.1:$PORT"
unset BOT_PROFILE_PHOTO TELEGRAM_BOT_TOKEN REPO_ROOT

reset_case() {
  : > "$LOG"; rm -f "$STATE" "$W/etc/core.env"
  curl -sf "http://127.0.0.1:$PORT/__profile?count=${1:-0}&odd=&stuck=0&bot_id=7000000001" >/dev/null
  for m in getMe getUserProfilePhotos setMyProfilePhoto; do curl -sf "http://127.0.0.1:$PORT/__fail?method=$m&off=1" >/dev/null; done
}
ctl() { curl -sf "http://127.0.0.1:$PORT/$1" >/dev/null; }
calls() { local n; n="$(grep -c "\"method\":\"$1\"" "$LOG" 2>/dev/null)"; printf '%s' "${n:-0}"; }
calls_all() { wc -l < "$LOG" | tr -d ' '; }
# run: der Schritt unter set -e wie in provision.sh, OHNE `||` -> ein interner Abbruch wuerde als RC sichtbar.
run() { OUT="$( ( set -euo pipefail; _ensure_bot_profile_photo "$TOKEN"; echo RC_REACHED ) 2>&1 )"; RC=$?; }
marked() { if grep -qxF "${1:-7000000001}" "$STATE" 2>/dev/null; then echo ja; else echo nein; fi; }

# --- 1) Wichtigste Eigenschaft: vorhandenes Bild bleibt ---------------------------------------------------------
reset_case 1
run
eq 'mit-bild: kein Upload' 0 "$(calls setMyProfilePhoto)"
eq 'mit-bild: Rueckgabe 0' 0 "$RC"
eq 'mit-bild: fragt mit der eigenen Kennung' 1 "$(calls getUserProfilePhotos)"
eq 'mit-bild: gemerkt' ja "$(marked)"

# --- 2) Ohne Bild: genau ein gueltiger Upload --------------------------------------------------------------------
reset_case 0
run
eq 'ohne-bild: genau ein Upload' 1 "$(calls setMyProfilePhoto)"
eq 'ohne-bild: Rueckgabe 0' 0 "$RC"
eq 'ohne-bild: gemerkt' ja "$(marked)"
LINE="$(grep '"method":"setMyProfilePhoto"' "$LOG" | tail -n 1)"
eq 'ohne-bild: Form static + attach' 'static|attach://profile|profile|true' \
  "$(printf '%s' "$LINE" | jq -r '[.body.photo.type, .body.photo.photo, .body.file_field, (.body.file_is_jpeg|tostring)] | join("|")')"
eq 'ohne-bild: Protokoll ohne Bytes' 'null' "$(printf '%s' "$LINE" | jq -c '.body.data // null')"
# Sofort-Kontrolle: nach dem Setzen wird nochmal gelesen
eq 'ohne-bild: danach kontrolliert' 2 "$(calls getUserProfilePhotos)"

# --- 3) Zweiter Lauf: keine Aenderung, auch nach selbst geloeschtem Bild ------------------------------------------
: > "$LOG"
run
eq 'zweitlauf: kein Upload' 0 "$(calls setMyProfilePhoto)"
eq 'zweitlauf: keine Bild-Abfrage' 0 "$(calls getUserProfilePhotos)"
ctl '__profile?count=0'
: > "$LOG"
run
eq 'selbst-geloescht: kein neuer Upload' 0 "$(calls setMyProfilePhoto)"
eq 'merkdatei: nur eine Zeile' 1 "$(wc -l < "$STATE" | tr -d ' ')"

# --- 4) Unklare Antworten: nichts tun, nichts merken, warnen --------------------------------------------------------
reset_case 0; ctl '__fail?method=getMe'
run
eq 'getMe-fehler: kein Upload' 0 "$(calls setMyProfilePhoto)"; eq 'getMe-fehler: Rueckgabe 0' 0 "$RC"; has 'getMe-fehler: Warnung' 'Profilbild'
eq 'getMe-fehler: keine Merkzeile' nein "$(marked)"

reset_case 0; ctl '__fail?method=getUserProfilePhotos'
run
eq 'abfrage-fehler: kein Upload' 0 "$(calls setMyProfilePhoto)"; eq 'abfrage-fehler: Rueckgabe 0' 0 "$RC"; has 'abfrage-fehler: Warnung' 'Profilbild'
eq 'abfrage-fehler: keine Merkzeile' nein "$(marked)"

# Schiefe Antworten bei sonst 0 Bildern: fehlendes Feld, Text statt Zahl, Bruch, negativ, ok:false. Nie als 0 lesen.
for art in nofield string float negative notok; do
  reset_case 0; ctl "__profile?odd=$art"
  run
  eq "schief-$art: kein Upload" 0 "$(calls setMyProfilePhoto)"; eq "schief-$art: Rueckgabe 0" 0 "$RC"
  has "schief-$art: Warnung" 'Profilbild'; eq "schief-$art: keine Merkzeile" nein "$(marked)"
done

# Telegram nicht erreichbar (geschlossener Port): auch dann nur eine Warnung
reset_case 0
OUT="$( ( set -euo pipefail; LIFEAGENTS_TELEGRAM_API=http://127.0.0.1:9; _ensure_bot_profile_photo "$TOKEN"; echo RC_REACHED ) 2>&1 )"; RC=$?
eq 'kein-netz: Rueckgabe 0' 0 "$RC"; has 'kein-netz: Warnung' 'Profilbild'; eq 'kein-netz: keine Merkzeile' nein "$(marked)"
LEAK_NET="$OUT"

# --- 5) Upload scheitert: Warnung, nichts gemerkt, naechster Lauf versucht es neu -------------------------------------
reset_case 0; ctl '__fail?method=setMyProfilePhoto'
run
eq 'upload-fehler: Rueckgabe 0' 0 "$RC"; has 'upload-fehler: Lauf geht weiter' RC_REACHED; has 'upload-fehler: Warnung' 'Profilbild'
eq 'upload-fehler: keine Merkzeile' nein "$(marked)"
LEAK_FAIL="$OUT"
ctl '__fail?method=setMyProfilePhoto&off=1'; : > "$LOG"
run
eq 'upload-fehler: naechster Lauf setzt' 1 "$(calls setMyProfilePhoto)"
eq 'upload-fehler: danach gemerkt' ja "$(marked)"

# Telegram meldet nach dem Upload weiter 0 Bilder: Warnung, aber gemerkt -> kein zweiter Upload
reset_case 0; ctl '__profile?stuck=1'
run
has 'kontrolle-weicht-ab: Warnung' 'Profilbild'; eq 'kontrolle-weicht-ab: gemerkt' ja "$(marked)"
: > "$LOG"; run
eq 'kontrolle-weicht-ab: kein zweiter Upload' 0 "$(calls setMyProfilePhoto)"

# --- 6) Neuer Bot: neue Kennung wird wieder geprueft -----------------------------------------------------------------
reset_case 1; run
eq 'neuer-bot: erster gemerkt' ja "$(marked 7000000001)"
: > "$LOG"; ctl '__profile?count=0&bot_id=7000000002'
run
eq 'neuer-bot: Upload fuer den neuen Bot' 1 "$(calls setMyProfilePhoto)"; eq 'neuer-bot: gemerkt' ja "$(marked 7000000002)"

# --- 7) Aus-Schalter: kein einziger Telegram-Aufruf -------------------------------------------------------------------
reset_case 0
OUT="$( ( set -euo pipefail; BOT_PROFILE_PHOTO=0; _ensure_bot_profile_photo "$TOKEN"; echo RC_REACHED ) 2>&1 )"; RC=$?
eq 'schalter-env: kein Aufruf' 0 "$(calls_all)"; eq 'schalter-env: Rueckgabe 0' 0 "$RC"
reset_case 0; printf 'BOT_PROFILE_PHOTO=0\n' > "$W/etc/core.env"
run
eq 'schalter-core.env: kein Aufruf' 0 "$(calls_all)"; eq 'schalter-core.env: Rueckgabe 0' 0 "$RC"
# Andere Absagen zaehlen auch; nur leer oder 1 heisst an.
for v in off false no; do
  reset_case 0; printf 'BOT_PROFILE_PHOTO=%s\n' "$v" > "$W/etc/core.env"
  run
  eq "schalter-$v: kein Aufruf" 0 "$(calls_all)"
done
reset_case 0; printf 'BOT_PROFILE_PHOTO=1\n' > "$W/etc/core.env"
run
eq 'schalter-1: Upload' 1 "$(calls setMyProfilePhoto)"

# --- 8) Bilddatei fehlt: Warnung, kein Upload ---------------------------------------------------------------------------
reset_case 0; mv "$IMG" "$IMG.weg"
run
eq 'ohne-datei: kein Upload' 0 "$(calls setMyProfilePhoto)"; eq 'ohne-datei: Rueckgabe 0' 0 "$RC"; has 'ohne-datei: Warnung' 'Profilbild'
mv "$IMG.weg" "$IMG"

# --- 9) Schluessel-Leck: weder Ausgabe noch Protokoll, auch nicht im Fehlerweg --------------------------------------------
reset_case 0; run; LEAK_OK="$OUT"
case "$LEAK_OK$LEAK_FAIL$LEAK_NET" in
  *MARKERTOKENzz9*) fail 'schluessel: Ausgabe' 'Bot-Schluessel steht in der Ausgabe' ;;
  *) pass 'schluessel: Ausgabe' ;;
esac
if grep -q MARKERTOKENzz9 "$LOG"; then fail 'schluessel: Protokoll' 'Bot-Schluessel im Mock-Protokoll'; else pass 'schluessel: Protokoll'; fi
# Argumentliste: /proc/<pid>/cmdline ist fuer jeden lesbar. Ein curl-Vorschalter schreibt mit, was der echte curl im argv bekaeme.
mkdir -p "$W/shim"
REAL_CURL="$(command -v curl)"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/argv.log\nexec %s "$@"\n' "$W" "$REAL_CURL" > "$W/shim/curl"
chmod +x "$W/shim/curl"
reset_case 0; : > "$W/argv.log"
OUT="$( ( set -euo pipefail; PATH="$W/shim:$PATH"; _ensure_bot_profile_photo "$TOKEN"; echo RC_REACHED ) 2>&1 )"
eq 'schluessel: Vorschalter hat mitgeschrieben' 1 "$(grep -c 'setMyProfilePhoto\|photo=' "$W/argv.log")"
if grep -q MARKERTOKENzz9 "$W/argv.log"; then fail 'schluessel: Argumentliste' 'Bot-Schluessel im argv von curl'; else pass 'schluessel: Argumentliste'; fi

# --- 10) Eingehaengt: _wire_telegram ruft den Schritt wirklich auf (auch ohne Menue-Erfolg) -------------------------------
reset_case 0
OUT="$( ( set -euo pipefail
          _ensure_app_secret() { :; }
          _set_bot_command_menus() { :; }
          TELEGRAM_BOT_TOKEN="$TOKEN"
          _wire_telegram; echo RC_REACHED ) 2>&1 )"; RC=$?
eq 'wire-telegram: Upload' 1 "$(calls setMyProfilePhoto)"; eq 'wire-telegram: Rueckgabe 0' 0 "$RC"

# --- 11) Das committete Bild + der installierte Baum ------------------------------------------------------------------------
# jpeg_info <datei> -> "<breite>x<hoehe> <bytes>" aus dem SOF-Marker, leer = kein JPEG.
jpeg_info() {
  node -e '
    const b = require("fs").readFileSync(process.argv[1]);
    if (b[0] !== 0xFF || b[1] !== 0xD8) process.exit(0);
    for (let i = 2; i < b.length - 9;) {
      if (b[i] !== 0xFF) { i++; continue; }
      const m = b[i + 1];
      if (m >= 0xC0 && m <= 0xCF && m !== 0xC4 && m !== 0xC8 && m !== 0xCC) {
        console.log(b.readUInt16BE(i + 7) + "x" + b.readUInt16BE(i + 5) + " " + b.length); process.exit(0);
      }
      i += 2 + b.readUInt16BE(i + 2);
    }' "$1" 2>/dev/null
}
REPO_IMG="$ROOT/bot_profile/bot_profile.jpg"
if [ -r "$REPO_IMG" ]; then
  INFO="$(jpeg_info "$REPO_IMG")"
  eq 'bild: JPEG mit 640x640' 640x640 "${INFO%% *}"
  if [ "${INFO##* }" -lt 10485760 ] 2>/dev/null; then pass 'bild: unter 10 MB'; else fail 'bild: unter 10 MB' "Groesse '${INFO##* }'"; fi
  reset_case 0; cp "$REPO_IMG" "$IMG"; run
  eq 'bild: Mock nimmt die echte Datei an' 1 "$(calls setMyProfilePhoto)"
else
  skip 'bild' 'packages/core/build/bot_profile/bot_profile.jpg fehlt noch'
fi
if [ -d "$INSTALLED/packages" ]; then
  # Der Install-Lauf des Substrats hatte den echten Test-Bot-Schluessel: der Schalter muss ihn vom Bild ferngehalten haben.
  if [ -e /etc/lifeagents/bot-profile-photo ]; then fail 'substrat: Test-Bot unberuehrt' 'Merkdatei im Substrat -> der Schritt lief'; else pass 'substrat: Test-Bot unberuehrt'; fi
  if [ -r "$INSTALLED/packages/core/build/bot_profile/bot_profile.jpg" ]; then
    reset_case 0
    OUT="$( ( set -euo pipefail; LIFEAGENTS_LIB="$INSTALLED"; _ensure_bot_profile_photo "$TOKEN"; echo RC_REACHED ) 2>&1 )"; RC=$?
    eq 'installierter-baum: Upload der mitgelieferten Datei' 1 "$(calls setMyProfilePhoto)"
  else
    fail 'installierter-baum' 'Bild fehlt im installierten Baum'
  fi
else
  skip 'installierter-baum' 'kein installierter Baum (Container ohne Provisioning)'
fi

exit "$fails"
