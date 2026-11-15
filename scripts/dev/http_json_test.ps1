#Requires -Version 5.1
# Selbsttest von scripts/lib/http_json.ps1: ein lokaler HTTP-Listener antwortet wie die Anthropic-API mit
# "application/json" ohne charset und einem Text mit Umlaut und Euro-Zeichen; Invoke-JsonPostUtf8 muss ihn unverfaelscht liefern.
# Dazu die Verdrahtung: judge_eval und monitor_probe rufen die API nur ueber den Helfer. Kein Substrat, kein API-Aufruf, keine Kosten.
# Usage:  .\scripts\dev\http_json_test.ps1
# Exit-Code = Anzahl Fehler.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$repo = git -C $PSScriptRoot rev-parse --show-toplevel
. (Join-Path $repo 'scripts\lib\http_json.ps1')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$fail = 0
function Check([bool]$Ok, [string]$Msg) {
    if ($Ok) { Write-Host "[PASS] $Msg" -ForegroundColor Green }
    else { Write-Host "[FAIL] $Msg" -ForegroundColor Red; $script:fail++ }
}

# Erwarteter Text aus Codepoints, damit die Skript-Kodierung den Test nicht verfaelschen kann: "Prüfung 5 €".
$expected = 'Pr' + [char]0x00FC + 'fung 5 ' + [char]0x20AC

# Freien Port holen, dann den Listener in einem eigenen Runspace genau eine Anfrage beantworten lassen.
$probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0); $probe.Start()
$port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port; $probe.Stop()
$prefix = "http://127.0.0.1:$port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()
$ps = [powershell]::Create()
[void]$ps.AddScript({
    param($l, $text)
    $ctx = $l.GetContext()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"reason":"' + $text + '"}')
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}).AddArgument($listener).AddArgument($expected)
$async = $ps.BeginInvoke()
try {
    $r = Invoke-JsonPostUtf8 -Uri $prefix -Body '{"q":"x"}' -TimeoutSec 10
    Check ($r.reason -ceq $expected) "Antwort ohne charset kommt als UTF-8 an (bekommen: '$($r.reason)')"
} finally {
    [void]$async.AsyncWaitHandle.WaitOne(5000)
    $listener.Stop(); $listener.Close(); $ps.Dispose()
}

# Verdrahtung: kein direkter Invoke-RestMethod mehr gegen die Anthropic-API.
foreach ($f in @('scripts\judge_eval.ps1', 'scripts\monitor_probe.ps1')) {
    $src = [System.IO.File]::ReadAllText((Join-Path $repo $f), $Utf8NoBom)
    Check ($src -match 'lib\\http_json\.ps1' -and $src -match 'Invoke-JsonPostUtf8' -and $src -notmatch 'Invoke-RestMethod[^\r\n]*(\$Endpoint|api\.anthropic\.com)') "$f liest die API-Antwort ueber Invoke-JsonPostUtf8"
}

if ($fail -eq 0) { Write-Host 'http_json_test: alle Pruefungen bestanden.' -ForegroundColor Green }
else { Write-Host "http_json_test: $fail Pruefung(en) fehlgeschlagen." -ForegroundColor Red }
exit $fail
