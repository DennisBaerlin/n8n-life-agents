#!/usr/bin/env bash
# cases.sh — Fall-Runner von scripts/dev/release_fetch_test.ps1, laeuft IM Substrat-Container (root, bash/curl/jq/node).
#
# Faehrt den ECHTEN Download-Code des Worktrees (<root>/provisioning/install.sh = Bootstrap, lib/fetch_release.sh =
# `lifeagents update`) gegen den Mock tests/mock_github/server.js: immer anonym (auch mit altem GH_TOKEN in der Env nie
# ein Auth-Header), Repo nicht oeffentlich / kein Release / falsches Tag ohne Frage, Abfragelimit, Netzfehler,
# abgebrochener Download, Unterschrift + SHA256 (Fake-Releases mit Test-Schluessel signiert; ohne Bund das Sidecar; der
# echte Projekt-Schluessel lehnt die Test-Unterschrift ab), Redirect, Aufraeumen des Arbeitsverzeichnisses, drop_legacy_repo_token. Das
# Fake-Release enthaelt einen Stub-provision.sh, der RELEASE_TAG + Args in eine Marker-Datei schreibt (= "Applier
# gestartet").
#
# Usage: bash cases.sh <root> <port>      Ausgabe je Fall "PASS <fall>" / "FAIL <fall>: <grund>"; Exit = Anzahl FAIL.
set -uo pipefail
ROOT="$1"; PORT="$2"
API="http://127.0.0.1:${PORT}"; SLUG="owner/repo"; TAG="v9.9.9"; BADSHA_TAG="v9.9.8"
OLDTOK="tok-legacy-5f3a"
W=/tmp/mock_github; REL="$W/releases"; MARK="$W/applied"
export LANG=C.UTF-8 LC_ALL=C.UTF-8 GUM_DISABLE=1 ROOT
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

# --- Fake-Releases: TAG (gueltig) + BADSHA_TAG (Pruefsumme passt nicht zum Tarball) -----------------------------
# Das Projekt signiert (provisioning/keys/release-signing.gpg, eingebettet in install.sh): die Fake-Releases tragen
# wie echte SHA256SUMS + SHA256SUMS.sig, unterschrieben mit einem kurzlebigen TEST-Schluessel; jeder Lauf zeigt per
# LIFEAGENTS_RELEASE_KEYRING auf dessen Bund (install.sh nimmt ein gesetztes Bund vor dem eingebetteten Schluessel).
# Das .sha256-Sidecar bleibt fuer den Fall ohne Bund (update_no_keyring_sidecar).
rm -rf "$W"; mkdir -p "$REL/$TAG" "$REL/$BADSHA_TAG" "$W/gnupg"; chmod 700 "$W/gnupg"
export GNUPGHOME="$W/gnupg"
gpg --batch --passphrase '' --quick-generate-key 'release-fetch-test signer' ed25519 sign never >/dev/null 2>&1
gpg --batch --export 'release-fetch-test signer' > "$W/kr.gpg"
for t in "$TAG" "$BADSHA_TAG"; do
  src="$W/src/$t/n8n-life-agents-$t/provisioning"; mkdir -p "$src"
  printf '%s\n' "printf '%s|%s\n' \"\${RELEASE_TAG:-}\" \"\$*\" > $MARK" > "$src/provision.sh"
  tar -czf "$REL/$t/n8n-life-agents-$t.tar.gz" -C "$W/src/$t" "n8n-life-agents-$t"
  printf 'echo fake-install\n' > "$REL/$t/install.sh"
  ( cd "$REL/$t" && sha256sum "n8n-life-agents-$t.tar.gz" > "n8n-life-agents-$t.tar.gz.sha256" \
      && sha256sum "n8n-life-agents-$t.tar.gz" install.sh > SHA256SUMS )
  gpg --batch --yes --pinentry-mode loopback --passphrase '' --detach-sign -o "$REL/$t/SHA256SUMS.sig" "$REL/$t/SHA256SUMS"
done
printf 'deadbeef' >> "$REL/$BADSHA_TAG/n8n-life-agents-$BADSHA_TAG.tar.gz"   # nach der (signierten) Pruefsumme veraendert

# --- Mock starten (im Hintergrund, beim Ende weg) ---------------------------------------------------------------
# Liegengebliebene Mocks eines abgebrochenen Laufs (gleicher Pfad) zuerst beenden — ps/pkill fehlen im Substrat.
for d in /proc/[0-9]*; do
  if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q "^node .*mock_github/server\.js"; then kill "${d#/proc/}" 2>/dev/null || true; fi
done
sleep 0.2
MOCK_GH_PORT="$PORT" MOCK_GH_SLUG="$SLUG" MOCK_GH_RELEASE_DIR="$REL" MOCK_GH_LATEST="$TAG" \
  node "$ROOT/mock_github/server.js" > "$W/mock.log" 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true' EXIT
# Bereit = GENAU der eben gestartete Mock antwortet (/__pid = seine PID) — nicht ein liegengebliebener Mock eines
# abgebrochenen Laufs oder ein anderer Dienst auf dem Port.
mock_ready() { kill -0 "$MOCK_PID" 2>/dev/null && [ "$(curl -s "$API/__pid" | jq -r '.pid // empty' 2>/dev/null)" = "$MOCK_PID" ]; }
for _ in $(seq 1 50); do mock_ready && break; sleep 0.1; done
mock_ready || { echo "FAIL setup: Mock nicht bereit (Port ${PORT}/$((PORT + 1)) belegt?) $(cat "$W/mock.log")"; exit 1; }

# cfg <json> — Fall-Zustand = Defaults + <json> (kein Rest aus dem Vorfall); leert das Log.
cfg() {
  curl -s -X POST -d "$(jq -cn --argjson o "$1" '{mode:"public", rate_limited:false, secondary_limit:false, no_latest:false, truncate_asset:false} + $o')" \
    "$API/__config" > /dev/null
}
reqs() { curl -s "$API/__requests"; }
# no_auth — kein einziger Request (API + S3) trug einen Authorization-Header.
no_auth() { [ "$(reqs | jq '[.[] | select(.auth != null)] | length')" = 0 ]; }
# s3_used — mind. ein Asset kam ueber den Redirect-Host (sonst pruefte no_auth den Redirect gar nicht).
s3_used() { [ "$(reqs | jq --argjson p "$((PORT + 1))" '[.[] | select(.port == $p)] | length')" -ge 1 ]; }
# no_api_assets — Assets ueber browser_download_url, nie ueber den API-Asset-Endpunkt (der zaehlt gegen das Limit).
no_api_assets() { [ "$(reqs | jq '[.[] | select(.path | test("/releases/assets/"))] | length')" = 0 ]; }

# Gemeinsame Test-Env: Mock-API + Fake-Slug; ein alter Token aus der Container-Env bleibt draussen (die Faelle mit
# Token setzen ihn ausdruecklich). SHELL=bash, weil `script -c` das Kommando ueber $SHELL startet.
BASE_ENV=(-u GH_TOKEN -u GITHUB_TOKEN SHELL=/bin/bash PROVISION_GH_API="$API" PROVISION_REPO_SLUG="$SLUG"
          LIFEAGENTS_RELEASE_KEYRING="$W/kr.gpg")
# shellcheck disable=SC2016  # bewusst einfach gequotet: $ROOT/$TEST_TAG expandiert erst im inneren bash -c
UPDATE_SH='set -euo pipefail
. "$ROOT/provisioning/lib/common.sh"; . "$ROOT/provisioning/lib/fetch_release.sh"
fetch_and_run_release "${TEST_TAG:-latest}"'

# run <install|update> <tty:0|1> [env-zuweisungen...] [-- install-args...] → setzt OUT + RC.
run() {
  local kind="$1" tty="$2"; shift 2
  local envs=() args=() seen=0 cmd
  for a in "$@"; do if [ "$seen" = 1 ]; then args+=("$a"); elif [ "$a" = "--" ]; then seen=1; else envs+=("$a"); fi; done
  rm -f "$MARK"
  if [ "$kind" = install ]; then
    cmd="$(printf '%q ' bash "$ROOT/provisioning/install.sh" --profile dev "${args[@]}")"
  else
    cmd="$(printf '%q ' bash -c "$UPDATE_SH")"
  fi
  if [ "$tty" = 1 ]; then
    OUT="$(env "${BASE_ENV[@]}" "${envs[@]}" script -qec "$cmd" /dev/null 2>&1 < /dev/null)"; RC=$?
  else
    OUT="$(env "${BASE_ENV[@]}" "${envs[@]}" bash -c "$cmd" 2>&1 < /dev/null)"; RC=$?
  fi
}
applied() { [ -f "$MARK" ] && grep -q "^$1|" "$MARK"; }
has() { printf '%s' "$OUT" | grep -qF "$1"; }
show() { printf '%s' "$OUT" | tr '\r\n' '  ' | cut -c1-300; }
ndirs() { find /tmp -maxdepth 1 -name "$1" | wc -l; }

# 1/2/3 oeffentlich: install latest + --version, update latest -> ok, nie ein Auth-Header, Asset ueber den Redirect
cfg '{}'; run install 0
if [ "$RC" = 0 ] && applied "$TAG" && no_auth && s3_used && no_api_assets; then pass install_latest; else fail install_latest "rc=$RC $(show)"; fi
cfg '{}'; run install 0 -- --version "$TAG"
if [ "$RC" = 0 ] && applied "$TAG" && no_auth; then pass install_version; else fail install_version "rc=$RC $(show)"; fi
cfg '{}'; run update 0
if [ "$RC" = 0 ] && applied "$TAG" && no_auth && s3_used && no_api_assets; then pass update_latest; else fail update_latest "rc=$RC $(show)"; fi
cfg '{}'; run update 0 TEST_TAG="$TAG"
if [ "$RC" = 0 ] && applied "$TAG" && no_auth; then pass update_version; else fail update_version "rc=$RC $(show)"; fi

# 4/5 alter Token in der Env (GH_TOKEN/GITHUB_TOKEN) -> wird ignoriert: kein Header, nicht in der Ausgabe
cfg '{}'; run install 0 GH_TOKEN="$OLDTOK" GITHUB_TOKEN="$OLDTOK"
if [ "$RC" = 0 ] && applied "$TAG" && no_auth && ! has "$OLDTOK"; then pass install_ignores_token; else fail install_ignores_token "rc=$RC $(show)"; fi
cfg '{}'; run update 0 GH_TOKEN="$OLDTOK" GITHUB_TOKEN="$OLDTOK"
if [ "$RC" = 0 ] && applied "$TAG" && no_auth && ! has "$OLDTOK"; then pass update_ignores_token; else fail update_ignores_token "rc=$RC $(show)"; fi

# 6 Repo nicht oeffentlich (alles 404), MIT TTY -> klare Meldung, KEINE Frage, Applier nicht gestartet, tmp aufgeraeumt
before="$(ndirs 'n8n_bootstrap.*')"
cfg '{"mode":"private"}'; run install 1
if [ "$RC" != 0 ] && ! applied "$TAG" && has 'Kein veroeffentlichtes stabiles Release' && ! has 'Token' && [ "$(ndirs 'n8n_bootstrap.*')" = "$before" ]; then
  pass private_repo_no_prompt; else fail private_repo_no_prompt "rc=$RC tmp=$before->$(ndirs 'n8n_bootstrap.*') $(show)"; fi

# 7 falsches Tag -> "Tag existiert nicht"
cfg '{}'; run install 0 -- --version v0.0.1
if [ "$RC" != 0 ] && has 'dieses Tag existiert nicht'; then pass wrong_tag; else fail wrong_tag "rc=$RC $(show)"; fi

# 8 noch kein stabiles Release (update) -> eigene Meldung, Arbeitsverzeichnis aufgeraeumt
before="$(ndirs 'n8n_release.*')"
cfg '{"no_latest":true}'; run update 0
if [ "$RC" != 0 ] && has 'Kein veroeffentlichtes stabiles Release' && [ "$(ndirs 'n8n_release.*')" = "$before" ]; then
  pass no_release_update; else fail no_release_update "rc=$RC tmp=$before->$(ndirs 'n8n_release.*') $(show)"; fi

# 9 Abfragelimit (403 + x-ratelimit-remaining: 0) -> eigene Meldung
cfg '{"rate_limited":true}'; run install 0
if [ "$RC" != 0 ] && has 'Abfragelimit'; then pass rate_limited; else fail rate_limited "rc=$RC $(show)"; fi
cfg '{"secondary_limit":true}'; run update 0
if [ "$RC" != 0 ] && has 'Abfragelimit'; then pass secondary_limit; else fail secondary_limit "rc=$RC $(show)"; fi

# 10 Netzfehler (geschlossener Port) -> Netzwerk-Meldung
run install 0 PROVISION_GH_API=http://127.0.0.1:1
if [ "$RC" != 0 ] && has 'nicht erreichbar'; then pass network_error; else fail network_error "rc=$RC $(show)"; fi

# 11 Download bricht nach den Headern ab (200 + curl-Exit 18) -> Abbruch-Meldung, NICHT "manipuliert", nichts entpackt
for kind in install update; do
  cfg '{"truncate_asset":true}'; run "$kind" 0
  if [ "$RC" != 0 ] && ! applied "$TAG" && has 'Antwort abgebrochen' && ! has 'SHA256-Verifikation'; then
    pass "truncated_download_$kind"; else fail "truncated_download_$kind" "rc=$RC $(show)"; fi
done

# 12 manipuliertes Asset -> Abbruch VOR dem Entpacken (install + update)
cfg '{}'; run install 0 -- --version "$BADSHA_TAG"
if [ "$RC" != 0 ] && ! applied "$BADSHA_TAG" && has 'passt nicht zur unterschriebenen'; then pass bad_sha_install; else fail bad_sha_install "rc=$RC $(show)"; fi
cfg '{}'; run update 0 TEST_TAG="$BADSHA_TAG"
if [ "$RC" != 0 ] && ! applied "$BADSHA_TAG" && has 'passt nicht zur unterschriebenen'; then pass bad_sha_update; else fail bad_sha_update "rc=$RC $(show)"; fi

# 12b Bestand ohne Schluesselbund (Update von vor der ersten signierenden Version) -> das SHA256-Sidecar reicht
cfg '{}'; run update 0 LIFEAGENTS_RELEASE_KEYRING=/nonexistent/release-signing.gpg
if [ "$RC" = 0 ] && applied "$TAG" && has 'SHA256 verifiziert' && ! has 'Unterschrift'; then pass update_no_keyring_sidecar
else fail update_no_keyring_sidecar "rc=$RC $(show)"; fi
cfg '{}'; run update 0 LIFEAGENTS_RELEASE_KEYRING=/nonexistent/release-signing.gpg TEST_TAG="$BADSHA_TAG"
if [ "$RC" != 0 ] && ! applied "$BADSHA_TAG" && has 'SHA256-Verifikation fehlgeschlagen'; then pass bad_sha_no_keyring
else fail bad_sha_no_keyring "rc=$RC $(show)"; fi
# 12c der ECHTE Projekt-Schluessel (installiertes /etc-Bund bzw. der in install.sh eingebettete) lehnt die
#     Test-Unterschrift ab — leer = kein Override, install.sh faellt auf /etc bzw. den eingebetteten Schluessel zurueck.
cfg '{}'; run install 0 LIFEAGENTS_RELEASE_KEYRING=
if [ "$RC" != 0 ] && ! applied "$TAG" && has 'ist ungültig'; then pass install_project_key_rejects_foreign
else fail install_project_key_rejects_foreign "rc=$RC $(show)"; fi

# 13 drop_legacy_repo_token: entfernt GH_TOKEN (nur die Zeile), warnt einmal, zweiter Lauf still; fehlende Datei egal
envf="$W/core.env"; printf 'INSTALL_PROFILE=release\nGH_TOKEN=%s\nHOUSEHOLD_TIMEZONE=Europe/Berlin\n' "$OLDTOK" > "$envf"
# shellcheck disable=SC2016  # $ROOT/$1 expandieren erst im inneren bash -c
out1="$(bash -c '. "$ROOT/provisioning/lib/common.sh"; drop_legacy_repo_token "$1" /nonexistent/install.env' _ "$envf" 2>&1)"
# shellcheck disable=SC2016
out2="$(bash -c '. "$ROOT/provisioning/lib/common.sh"; drop_legacy_repo_token "$1"' _ "$envf" 2>&1)"
if ! grep -q '^GH_TOKEN=' "$envf" && grep -q '^INSTALL_PROFILE=release$' "$envf" && grep -q '^HOUSEHOLD_TIMEZONE=Europe/Berlin$' "$envf" \
   && printf '%s' "$out1" | grep -q 'widerrufen' && [ -z "$out2" ] && ! printf '%s' "$out1" | grep -qF "$OLDTOK"; then
  pass drop_legacy_token; else fail drop_legacy_token "out1=[$out1] out2=[$out2] file=[$(tr '\n' ' ' < "$envf")]"; fi

exit "$fails"
