#Requires -Version 5.1
# JSON-POST mit UTF-8-Antwort: Invoke-JsonPostUtf8 -Uri <url> -Headers @{...} -Body <json-string> [-TimeoutSec 120] -> geparstes Objekt.
# Dot-sourcen:  . "$PSScriptRoot\lib\http_json.ps1"
# Falle PowerShell 5.1: Invoke-RestMethod dekodiert eine Antwort ohne charset im Content-Type als ISO-8859-1. Die Anthropic-API
# sendet "application/json" ohne charset, jedes Nicht-ASCII-Zeichen kommt dann als Mojibake an (ein Umlaut als zwei falsche Zeichen).
# Darum hier die Roh-Bytes als UTF-8 lesen (JSON ist laut RFC 8259 immer UTF-8). Fehler (4xx/5xx) werfen wie bei Invoke-RestMethod,
# $_.ErrorDetails.Message traegt den Fehler-Body. Test: scripts/dev/http_json_test.ps1.

function Invoke-JsonPostUtf8 {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [Parameter(Mandatory)][string]$Body,
        [int]$TimeoutSec = 120
    )
    $resp = Invoke-WebRequest -Uri $Uri -Method Post -Headers $Headers -TimeoutSec $TimeoutSec -UseBasicParsing `
        -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($Body))
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString($resp.RawContentStream.ToArray())
    return ($text | ConvertFrom-Json)
}
