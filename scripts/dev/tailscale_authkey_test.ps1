#Requires -Version 5.1
# tailscale_authkey_test.ps1 — echter Weg des Tailscale-Anmeldeschluessels (gratis, braucht ein Test-Tailnet):
#   1. Schluessel je Lauf per OAuth-Client erzeugen (scripts/ci/install_test_answers.sh, echte Tailscale-API);
#   2. offizielles Tailscale-Image (Digest aus provisioning/compose/compose.yml) wie im Verbund starten (tailscaled direkt,
#      Userspace, ohne Schluessel) und mit dem echten Docker-Weg anmelden (lib/reach.sh _reach_key_login:
#      `tailscale up --auth-key=file:/dev/stdin` per `docker exec -i`);
#   3. pruefen: laeuft, Tag tag:install-test, kein Neustart des Containers, Schluessel weder in docker inspect noch in den
#      Logs noch im Zustand; Funnel fuer das Tag erlaubt (HTTPS-Abruf von aussen ueber <name>.<tailnet>.ts.net, bis 10 min DNS);
#   4. abmelden (fluechtiges Geraet sofort weg) und Container entfernen.
# Gegenstueck der Attrappen-Faelle K in tests/mock_reach/{cli,compose}_cases.sh und A in answers_cases.sh.
#
# Voraussetzungen: Docker; ein lokales master-Abbild (bash, jq, curl, docker-CLI; das neueste ghcr.io/.../master wird
#   genommen, sonst -Image); .env mit TEST_TS_OAUTH_CLIENT_ID + TEST_TS_OAUTH_CLIENT_SECRET (OAuth-Client des getrennten
#   Test-Tailnets, Scope auth_keys, Tag tag:install-test). Fehlen sie: "uebersprungen", Exit 0.
#   Container-Namen: <$env:N8NTEST_CONTAINER oder s4ts>-authkey-*, z. B. s4ts-authkey-tailscale; am Ende abgebaut.
# Usage:  .\scripts\dev\tailscale_authkey_test.ps1 [-Image <master-abbild>] [-EnvFile <pfad>] [-Verbose]
#   -EnvFile: Datei mit den OAuth-Werten statt <Repo>\.env.
# Exit-Code = Anzahl Fehler.
param([string]$Image, [string]$EnvFile, [switch]$Verbose)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
. "$PSScriptRoot\..\lib\dotenv.ps1"
. "$PSScriptRoot\..\lib\test_common.ps1"

$envFile = if ($EnvFile) { $EnvFile } else { Join-Path $RepoRoot '.env' }
$vals = if (Test-Path $envFile) { Read-DotEnvValues $envFile } else { @{} }
if (-not $vals['TEST_TS_OAUTH_CLIENT_ID'] -or -not $vals['TEST_TS_OAUTH_CLIENT_SECRET']) {
    Write-Host 'tailscale_authkey_test: uebersprungen (TEST_TS_OAUTH_CLIENT_ID/SECRET nicht in .env)' -ForegroundColor Yellow
    exit 0
}
# Werte nur als Prozess-Umgebung; docker run -e NAME liest sie von dort (nie im argv).
$env:TEST_TS_OAUTH_CLIENT_ID = $vals['TEST_TS_OAUTH_CLIENT_ID']
$env:TEST_TS_OAUTH_CLIENT_SECRET = $vals['TEST_TS_OAUTH_CLIENT_SECRET']

$compose = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'provisioning\compose\compose.yml'), (New-Object System.Text.UTF8Encoding($false)))
$tsImage = [regex]::Match($compose, 'tailscale:\s*&img_tailscale\s+(\S+)').Groups[1].Value
if (-not $tsImage) { throw 'Tailscale-Abbild in compose.yml nicht gefunden (Anker img_tailscale).' }
if (-not $Image) {
    # Neuestes master-Abbild (Release aus ghcr oder lokal gebaut <projekt>-master); es bringt bash, jq, curl, docker-CLI mit.
    $Image = @(docker images --format '{{.CreatedAt}}|{{.Repository}}:{{.Tag}}' | Where-Object { $_ -match '\|[^|]*[/-]master:' } | Sort-Object -Descending | Select-Object -First 1) -replace '^[^|]*\|', ''
    if (-not $Image) { throw 'Kein lokales master-Abbild gefunden; -Image <abbild> angeben.' }
}
# Eigener Zusatz -authkey: der Verbund-Test eines Worktrees heisst $env:N8NTEST_CONTAINER-tailscale, der bliebe sonst nicht verschont.
$prefix = ($(if ($env:N8NTEST_CONTAINER) { $env:N8NTEST_CONTAINER } else { 's4ts' })) + '-authkey'
$host_ = "$prefix-" + (-join ((1..6) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] }))

# Innerer Lauf (bash im master-Abbild, Docker-Socket des Rechners). Den Schluessel gibt nie ein Befehl aus; Suchen danach
# bekommen ihn per stdin oder Prozess-Substitution (grep -f), nie im argv.
$inner = @'
set -uo pipefail
P="$1"; TSIMG="$2"; HOST="$3"; C="$P-tailscale"
export LA_PROJECT="$P" LIFEAGENTS_RUNTIME=compose LIFEAGENTS_DIR=/tmp/la REACH_RUN_DIR=/tmp/la/run REACH_CONF_DIR=/tmp/la/reach
export REACH_KEY_WAIT_SECS=60 REACH_KEY_SETTLE_SECS=120
mkdir -p /tmp/la
. /repo/provisioning/lib/common.sh
. /repo/provisioning/lib/release_inputs.sh
fails=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "erwartet '$2', bekommen '$3'"; fi; }
cleanup() { docker exec "$C" tailscale logout >/dev/null 2>&1; docker rm -fv "$C" >/dev/null 2>&1; rm -rf /tmp/la; }
trap cleanup EXIT
docker rm -fv "$C" >/dev/null 2>&1
docker run -d --name "$C" --entrypoint tailscaled "$TSIMG" --tun=userspace-networking --statedir=/var/lib/tailscale >/dev/null \
  || { fail R_start "Tailscale-Container startet nicht"; exit 1; }
# hand-injected: Bot-Token und Anthropic-Schluessel braucht nur die Antwort-Datei, nicht dieser Test (Tailscale-Teil allein).
TEST_TELEGRAM_BOT_TOKEN=unused TEST_ANTHROPIC_API_KEY=unused bash /repo/scripts/ci/install_test_answers.sh /tmp/la/answers.env \
  || { fail R_mint "kein Schluessel per OAuth (Ausgabe oben)"; exit 1; }
pass R_mint
install_answers_load /tmp/la/answers.env
KEY="${_reach_authkey:-}"
eq R_key_not_exported 0 "$(env | grep -c '^TS_AUTHKEY=')"
_reach_key_login _reach_ts_status _reach_ts_up_key "$HOST"; eq R_login 0 "$?"
_reach_key_wait _reach_ts_key_ready; eq R_ready 0 "$?"
reach_ts_eval "$(_reach_ts_status)"
eq R_running running "$REACH_TS_STATE"
eq R_tag tag:install-test "$(docker exec "$C" tailscale status --json --peers=false | jq -r '(.Self.Tags // []) | join(",")')"
eq R_no_restart 0 "$(docker inspect -f '{{.RestartCount}}' "$C")"
eq R_inspect_no_key 0 "$(docker inspect "$C" | grep -cF -f <(printf '%s\n' "$KEY"))"
eq R_logs_no_key 0 "$(docker logs "$C" 2>&1 | grep -cF -f <(printf '%s\n' "$KEY"))"
eq R_state_no_key 0 "$(printf '%s\n' "$KEY" | docker exec -i "$C" sh -c 'grep -rlF -f - /var/lib/tailscale /tmp 2>/dev/null | wc -l')"
docker exec "$C" timeout 20 tailscale funnel --bg --yes text:install-test-ok >/dev/null 2>&1; eq R_funnel_cmd 0 "$?"
body=''
for _ in $(seq 1 60); do body="$(curl -fsS --max-time 10 "https://$REACH_TS_DNS/" 2>/dev/null)" && break; sleep 10; done
eq R_funnel_from_outside install-test-ok "$body"
printf 'tailscale_authkey_test: %s Fehler\n' "$fails" >&2
exit "$fails"
'@

Write-Host ""
Write-Host "Tailscale-Anmeldeschluessel, echter Weg — Container $prefix-tailscale, Abbild $Image"
Write-Host ("-" * 64)
$sock = '/var/run/docker.sock'
# Als Datei statt per Pipe: PS 5.1 stellt nativen Programmen beim Pipen ein BOM voran (bash: "\xEF\xBB\xBFset: command not found").
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "$prefix-run.sh"
[System.IO.File]::WriteAllText($tmp, $inner.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
$args_ = @('run', '--rm', '--name', "$prefix-run", '-v', "${sock}:${sock}", '-v', "$((Resolve-Path $RepoRoot).Path):/repo:ro",
    '-v', "${tmp}:/t.sh:ro", '-e', 'TEST_TS_OAUTH_CLIENT_ID', '-e', 'TEST_TS_OAUTH_CLIENT_SECRET', '--entrypoint', 'bash', $Image, '/t.sh', $prefix, $tsImage, $host_)
try { $r = Invoke-Native docker $args_; $lines = @($r.Output | ForEach-Object { "$_" }); $code = $r.Code }
finally { Remove-Item $tmp -ErrorAction SilentlyContinue; [void](Invoke-Native docker @('rm', '-fv', "$prefix-tailscale")) }
foreach ($l in $lines) {
    if ($l -match '^PASS ') { if ($Verbose) { Write-Host "    [OK]   $($l.Substring(5))" -ForegroundColor DarkGray } }
    elseif ($l -match '^FAIL ') { Write-Host "    [FAIL] $($l.Substring(5))" -ForegroundColor Red }
    else { Write-Host "    $l" -ForegroundColor DarkGray }
}
$failed = @($lines | Where-Object { $_ -match '^FAIL ' }).Count
if ($code -ne 0 -and $failed -eq 0) { $failed = 1; Write-Host "    [FAIL] Lauf brach ab (exit $code)" -ForegroundColor Red }
Write-Host ("-" * 64)
if ($failed -eq 0) { Write-Host 'tailscale_authkey_test: OK' -ForegroundColor Green } else { Write-Host "tailscale_authkey_test: $failed Fehler" -ForegroundColor Red }
exit $failed
