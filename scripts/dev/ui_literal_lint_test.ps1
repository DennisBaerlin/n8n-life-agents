#Requires -Version 5.1
# Test von Scan (c) in scripts/ui_literal_lint.ps1 (feste Telegram-Texte im Installer): je Fall eine Wegwerf-.sh, Aufruf mit
# -ShellFile, erwartete Trefferzahl. Rot muessen feste Woerter in text=/caption= und in Helfer-Argumenten werden (auch
# englisch, auch ueber Variable, printf oder ${x:-Text}); gruen bleiben Katalog-Lookups, Protokoll-Zeilen, Kommentare, Here-Docs.
# Aufruf: .\scripts\dev\ui_literal_lint_test.ps1     Exit-Code = Anzahl roter Faelle. Kein Docker, kein Netz.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = (Resolve-Path (Join-Path $PSScriptRoot '..\ui_literal_lint.ps1')).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

$notify = @'
notify_owner_telegram() {
  tg_api_curl "$token" sendMessage -fsS -o /dev/null \
    --data-urlencode "chat_id=${chat}" --data-urlencode "text=$1" >/dev/null 2>&1
}
'@
$cases = @(
    @{ id = 'caption-literal'; want = 1; sh = @'
send() {
  local cap; cap="n8n-life-agents Off-Site-Backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  curl -fsS -K "$cfg" -F "chat_id=${chat}" -F "document=@${file}" -F "caption=${cap}"
}
'@ }
    @{ id = 'caption-katalog'; want = 0; sh = @'
send() {
  local cap; cap="$(backup_text offsite.caption date "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  curl -fsS -K "$cfg" -F "chat_id=${chat}" -F "caption=${cap}"
}
'@ }
    @{ id = 'helfer-literal'; want = 1; sh = $notify + @'
done_msg() { notify_owner_telegram "Rückweg fertig: dein System läuft wieder auf ${rel}." || true; }
'@ }
    @{ id = 'helfer-pkg-text'; want = 0; sh = $notify + @'
done_msg() { notify_owner_telegram "$(pkg_text core update.rollback_done)" || true; }
'@ }
    @{ id = 'helfer-englisch'; want = 1; sh = $notify + @'
hold() { notify_owner_telegram "Update on hold: ${labels}"; }
'@ }
    @{ id = 'helfer-ueber-local'; want = 1; sh = @'
_send() {
  local text="$1" token chat
  tg_api_curl "$token" sendMessage --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}"
}
card() { _send "Neue Version bereit" "[]"; }
'@ }
    @{ id = 'printf-im-wert'; want = 1; sh = @'
x() { resp="$(_up_api "$t" sendMessage --data-urlencode "text=$(printf 'Schritt %s von %s' "$a" "$b")")"; }
'@ }
    @{ id = 'default-text'; want = 1; sh = @'
x() { curl --data-urlencode "text=${STEP_TEXT:-Installation läuft}"; }
'@ }
    @{ id = 'db-text-per-jq'; want = 0; sh = @'
_ur_send() {
  local text="$1"
  tg_api_curl "$token" sendMessage --data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}"
}
x() { _ur_send "$(jq -r '.text // empty' <<<"$out")" "$(jq -c '.keyboard // []' <<<"$out")"; }
'@ }
    @{ id = 'protokoll-zeilen'; want = 0; sh = $notify + @'
x() {
  log "Off-Site-Kopie an Telegram-Owner-Chat gesendet (${size} Byte)."
  warn "Off-Site-Versand (Telegram sendDocument) fehlgeschlagen -> Backup liegt lokal: $file"
  ok "Fertig."
  notify_owner_telegram "$txt" || return 0
}
'@ }
    @{ id = 'kommentar-heredoc'; want = 0; sh = @'
# Beispiel: curl -F "caption=Hallo Welt"
x() {
  cat <<'EOF'
curl --data-urlencode "text=Hallo aus dem Here-Doc"
EOF
}
'@ }
)
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('ull_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    foreach ($c in $cases) {
        $f = Join-Path $dir "$($c.id).sh"
        [System.IO.File]::WriteAllText($f, ($c.sh -replace "`r`n", "`n") + "`n", $u8)
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint -ShellFile $f
        if ($LASTEXITCODE -ne $c.want) { Fail "$($c.id): erwartet $($c.want) Treffer, war $LASTEXITCODE ($($out -join ' | '))" }
    }
} finally { Remove-Item -Recurse -Force $dir }

if ($fails -eq 0) { Write-Host "PASS ui_literal_lint_test ($($cases.Count) Shell-Faelle)" -ForegroundColor Green }
else { Write-Host "ui_literal_lint_test: $fails rot" -ForegroundColor Red }
exit $fails
