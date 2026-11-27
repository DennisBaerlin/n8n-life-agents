#Requires -Version 5.1
# Test von scripts/config_fallback_lint.ps1: je Fall ein Wegwerf-Baum (Manifest, eine SQL-Datei, ein Workflow, Allowlist).
# Gruen: Rueckfall gleich dem Manifest in allen Lese-Formen. Rot: abweichender Rueckfall in SQL, Workflow-SQL und Ausdruck, Key
# ohne Manifest-Zeile, falsches Paket, neue Lese-Stelle ohne Rueckfall, veralteter oder unbegruendeter Allowlist-Eintrag.
# Aufruf: .\scripts\dev\config_fallback_lint_test.ps1     Exit-Code = Anzahl roter Faelle. Kein Docker, kein Netz.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$lint = (Resolve-Path (Join-Path $PSScriptRoot '..\config_fallback_lint.ps1')).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$ps = (Get-Process -Id $PID).Path
$fails = 0

$manifest = @'
{ "name": "finance", "config": {
  "advisor": { "window": { "value": "60" }, "buffer": { "value": "0.10" } },
  "feature": { "gate": { "value": "true" } },
  "cron_enable": { "remind": { "value": "true" } },
  "finance": { "fee_eur": { "value": "500" }, "days": { "value": "7,21" } } } }
'@
$goodSql = @'
-- core.fn_config_get('finance','advisor','window') mit Rueckfall 99 steht hier nur im Kommentar
v := COALESCE(NULLIF(core.fn_config_get('finance', 'advisor', 'window'), '')::int, 60);
w := COALESCE(core.fn_config_get('finance','advisor','buffer')::numeric, 0.1);
x := finance.fn_config_eur_in_currency('fee_eur', 500, v_cur, v_day);
SELECT COALESCE(core.fn_config_get('finance','cron_enable','remind') = 'true', false);
'@
$goodQuery = "SELECT COALESCE((SELECT value FROM core.config WHERE category='feature' AND key='gate'),'true') AS gate_on"
$goodExpr = "={{ `$('Load Config').item.json.advisor.window || 60 }}"

# Run-Case <name> <erwartete Fehler> <SQL> <Query> <Ausdruck> <Allowlist-Eintraege> <Teil der Meldung>
function Run-Case([string]$Name, [int]$Want, [string]$Sql = $goodSql, [string]$Query = $goodQuery, [string]$Expr = $goodExpr, [string]$Allow = '', [string]$Says = '') {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('cfl_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        foreach ($d in @('packages\finance\db\migrations', 'packages\finance\workflows', 'scripts\build')) { New-Item -ItemType Directory -Force (Join-Path $dir $d) | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $dir 'packages\finance\manifest.json'), $manifest, $u8)
        [System.IO.File]::WriteAllText((Join-Path $dir 'packages\finance\db\migrations\R__fn_x.sql'), $Sql, $u8)
        # Eingefrorene Migrationen zaehlen nicht, auch mit abweichendem Rueckfall.
        [System.IO.File]::WriteAllText((Join-Path $dir 'packages\finance\db\migrations\V001__old.sql'), "SELECT COALESCE(core.fn_config_get('finance','advisor','window'), '1');", $u8)
        $wf = [ordered]@{ name = 'agent.finance.x'; nodes = @(
                [ordered]@{ name = 'Read'; type = 'n8n-nodes-base.postgres'; parameters = [ordered]@{ query = $Query; options = [ordered]@{ v = $Expr } } }
                [ordered]@{ name = 'Doc'; type = 'n8n-nodes-base.stickyNote'; parameters = [ordered]@{ content = "core.fn_config_get(finance,x,y)" } }) }
        [System.IO.File]::WriteAllText((Join-Path $dir 'packages\finance\workflows\a-agent.finance.x.json'), (ConvertTo-Json -InputObject $wf -Depth 10), $u8)
        [System.IO.File]::WriteAllText((Join-Path $dir 'scripts\build\config_fallback_allowlist.json'), "{ `"allow`": [ $Allow ] }", $u8)
        $out = (& $ps -NoProfile -ExecutionPolicy Bypass -File $lint -Root $dir | Out-String)
        $code = $LASTEXITCODE
        if ($code -eq $Want -and (-not $Says -or $out.Contains($Says))) { Write-Host "  [PASS] $Name" }
        else { Write-Host "  [FAIL] $Name (erwartet $Want Fehler '$Says', war $code): $out" -ForegroundColor Red; $script:fails++ }
    } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
}

Run-Case 'alle Formen gleich dem Manifest' 0
Run-Case 'SQL-Rueckfall weicht ab' 1 -Sql ($goodSql -replace '::int, 60\)', '::int, 36)') -Says "Rueckfall '36' != Manifest-Standard '60'"
Run-Case 'Vergleichs-Form: aus dem Rueckfall wird der Config-Wert' 1 -Sql ($goodSql + "`nSELECT COALESCE(core.fn_config_get('finance','feature','gate') = 'true', false);") -Says "feature.gate Rueckfall 'false'"
Run-Case 'cron_enable fail-closed bleibt erlaubt' 0 -Sql ($goodSql + "`nSELECT COALESCE(core.fn_config_get('finance','cron_enable','remind'), 'false');")
Run-Case 'Helfer-Rueckfall weicht ab' 1 -Sql ($goodSql -replace "'fee_eur', 500", "'fee_eur', 250") -Says "finance.fee_eur Rueckfall '250'"
Run-Case 'Rueckfall ueber Variable weicht ab' 1 -Sql ($goodSql + "`nv_w := core.fn_config_get('finance','advisor','window')::int;`nRETURN COALESCE(v_w, 12);") -Says "advisor.window Rueckfall '12'"
Run-Case 'Workflow-SQL weicht ab' 1 -Query ($goodQuery -replace "'true'\) AS", "'false') AS") -Says "agent.finance.x / Read: feature.gate Rueckfall 'false'"
Run-Case 'Ausdrucks-Rueckfall weicht ab' 1 -Expr ($goodExpr -replace '\|\| 60', "?? '90'") -Says "advisor.window Rueckfall '90'"
Run-Case 'Rueckfall eines spaeteren Befehls zaehlt nicht' 1 -Sql ($goodSql + "`nIF core.fn_config_get('finance','advisor','window')::int > 5 THEN x := 1; END IF;`nSELECT 1 INTO v_cnt;`nRETURN COALESCE(v_cnt, 60);") -Says 'ohne erkannten Rueckfall'
Run-Case 'SELECT mit Alias wird gelesen' 1 -Sql ($goodSql + "`nSELECT COALESCE((SELECT NULLIF(c.value,'')::int FROM core.config c WHERE c.category='advisor' AND c.key='window'), 12);") -Says "advisor.window Rueckfall '12'"
Run-Case 'nicht lesbarer Schluessel wird gemeldet' 1 -Sql ($goodSql + "`nSELECT value INTO v FROM core.config WHERE category = v_cat;") -Says 'core.config.*.*'
Run-Case 'Zahlenliste ist keine Zahl' 1 -Sql ($goodSql + "`nSELECT COALESCE(core.fn_config_get('finance','finance','days'), '72,1');") -Says "Rueckfall '72,1' != Manifest-Standard '7,21'"
Run-Case 'Key ohne Manifest-Zeile' 1 -Sql ($goodSql + "`nSELECT COALESCE(core.fn_config_get('finance','advisor','windwo'), '60');") -Says 'steht in keinem Manifest'
Run-Case 'falsches Paket' 1 -Sql ($goodSql + "`nSELECT COALESCE(core.fn_config_get('core','advisor','window'), '60');") -Says "liest Paket 'core'"
$noFallback = $goodSql + "`nIF core.fn_config_get('finance','feature','gate') IS DISTINCT FROM 'true' THEN"
Run-Case 'neue Lese-Stelle ohne Rueckfall' 1 -Sql $noFallback -Says 'ohne erkannten Rueckfall'
$entry = '{ "where": "packages/finance/db/migrations/R__fn_x.sql", "read": "feature.gate", "fallback": "-", "count": 1, "reason": "none: fail-closed" }'
Run-Case 'begruendete Ausnahme' 0 -Sql $noFallback -Allow $entry
Run-Case 'Ausnahme ohne Grund' 1 -Sql $noFallback -Allow ($entry -replace 'none: fail-closed', 'TODO') -Says 'braucht reason'
Run-Case 'veraltete Ausnahme' 1 -Allow $entry -Says 'allowlist-ORPHAN'
Run-Case 'zweite Stelle mit gleichem Schluessel' 1 -Sql ($noFallback + "`nIF core.fn_config_get('finance','feature','gate') IS DISTINCT FROM 'true' THEN") -Allow $entry -Says '2x gefunden'

if ($fails -eq 0) { Write-Host 'PASS config_fallback_lint_test' -ForegroundColor Green } else { Write-Host "config_fallback_lint_test: $fails rot" -ForegroundColor Red }
exit $fails
