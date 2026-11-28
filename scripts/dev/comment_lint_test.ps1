#Requires -Version 5.1
# Test fuer scripts/comment_lint.ps1: je Regel und Sprache (PowerShell, SQL, bash, JS) ein Treffer und ein Nicht-Treffer,
# dazu Here-Strings, String-Literale, Here-Docs und Dollar-Quotes, die nie treffen duerfen; Pflicht-Koepfe neuer Dateien;
# der Diff-Modus in einem Wegwerf-Repo (nur neue Zeilen zaehlen, alte Funde bleiben stumm).
# Die Fall-Texte stehen in Here-Strings: fuer den Lint sind sie Strings, diese Datei trifft also selbst nicht.
# Aufruf: .\scripts\dev\comment_lint_test.ps1     Exit-Code = Anzahl roter Faelle. Kein Docker, kein Netz.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot '..\lib\git_sandbox.ps1')
$lint = (Resolve-Path (Join-Path $PSScriptRoot '..\comment_lint.ps1')).Path
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# want = erwartete Regeln der Datei, sortiert und mit Komma verbunden ('' = kein Fund).
$cases = @(
    # --- PowerShell ---
    @{ id = 'ps-verlauf';       ext = 'ps1'; want = 'verlauf'; src = @'
# Befund 2026-10-24: der Wert war leer
$a = 1
'@ }
    @{ id = 'ps-verlauf-nicht'; ext = 'ps1'; want = ''; src = @'
$a = 1
# Rate am 31.01.2027 faellig; Phase 1: Basis, Regel 7b, L6
'@ }
    @{ id = 'ps-herestring';    ext = 'ps1'; want = ''; src = @"
`$h = @'
# seit v0.3.0 neu, TODO, NIE
'@
`$j = "# KW45"
"@ }
    @{ id = 'ps-code';          ext = 'ps1'; want = 'code'; src = @'
$a = 1
# $b = Get-Thing
'@ }
    @{ id = 'ps-code-nicht';    ext = 'ps1'; want = ''; src = @'
$a = 1
# Beispiel:
#   foreach ($tc in $cases) {
#   }
# $Description = die router_description des Pakets
'@ }
    @{ id = 'ps-todo';          ext = 'ps1'; want = 'todo'; src = @'
# TODO aufraeumen
$a = 1
'@ }
    @{ id = 'ps-todo-nicht';    ext = 'ps1'; want = ''; src = @'
# TODO(n8n 3 stabil) umstellen
# TODO sobald der Mock steht
$r = 'TODO'  # reason:'TODO' im Geruest
'@ }
    @{ id = 'ps-caps';          ext = 'ps1'; want = 'caps'; src = @'
$a = 1  # das darf NIE passieren
'@ }
    @{ id = 'ps-caps-nicht';    ext = 'ps1'; want = ''; src = @'
# JSON ohne NULL, HITL-Karte, UTF-8 mit BOM
$a = 1
'@ }
    @{ id = 'ps-marker';        ext = 'ps1'; want = ''; src = @'
# Befund 2026-10-24 als Beispiel  comment-lint: ok Regeltext
$a = 1
'@ }
    @{ id = 'ps-marker-ohne-grund'; ext = 'ps1'; want = 'verlauf'; src = @'
# Befund 2026-10-24 comment-lint: ok
$a = 1
'@ }
    # --- SQL ---
    @{ id = 'sql-testdaten';    ext = 'sql'; want = ''; src = @'
-- Depot-Stand 31.12.2026: 1.210; Zins seit 01.01.2027; KW 53 gibt es nur in manchen Jahren
-- ALTER TABLE ONLY greift nicht auf Kind-Tabellen
SELECT 1;
'@ }
    @{ id = 'sql-top-dollar';   ext = 'sql'; want = ''; src = @'
COMMENT ON COLUMN t.c IS $c$ -- NIE leer, TODO $c$;
'@ }
    @{ id = 'sql-verlauf';      ext = 'sql'; want = 'verlauf'; src = @'
SELECT 1; -- Fund 2026-11-01: lief das anders
'@ }
    @{ id = 'sql-string';       ext = 'sql'; want = ''; src = @'
SELECT '-- seit v0.2.0', 'it''s -- NIE';
SELECT E'a\'b -- KW45';
SELECT "col -- TODO" FROM t;
'@ }
    @{ id = 'sql-fn-body';      ext = 'sql'; want = 'caps'; src = @'
CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$
BEGIN
    -- NIE ohne Sperre
    RETURN 1;
END $$;
'@ }
    @{ id = 'sql-dollar-string'; ext = 'sql'; want = ''; src = @'
CREATE FUNCTION f() RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
    RETURN format($q$ -- TODO Phase B $q$);
END $fn$;
'@ }
    @{ id = 'sql-code';         ext = 'sql'; want = 'code'; src = @'
SELECT 1;
-- DELETE FROM t WHERE x = 1;
'@ }
    @{ id = 'sql-code-nicht';   ext = 'sql'; want = ''; src = @'
SELECT 1;
-- INSERT + UPDATE auf t, danach der Abgleich;
-- Rate am 30.06.2025 (-2500), Wert 1210 am 30.06.2026
'@ }
    @{ id = 'sql-block';        ext = 'sql'; want = 'verlauf'; src = @'
/* Phase B: Text kam aus dem Katalog */
SELECT 1;
'@ }
    @{ id = 'sql-todo';         ext = 'sql'; want = 'todo'; src = @'
SELECT 1; -- FIXME
'@ }
    # --- bash ---
    @{ id = 'sh-verlauf';       ext = 'sh'; want = 'verlauf'; src = @'
#!/usr/bin/env bash
echo x # früher war das y
'@ }
    @{ id = 'sh-heredoc';       ext = 'sh'; want = ''; src = @'
#!/usr/bin/env bash
cat <<'EOF'
# NIE, TODO, seit v0.1.0
EOF
cat <<-END
	# KW45
	END
echo "a # NUR" 'b # ALLE' ${#arr[@]} $#
'@ }
    @{ id = 'sh-code';          ext = 'sh'; want = 'code'; src = @'
#!/usr/bin/env bash
echo x
# export FOO=bar
'@ }
    @{ id = 'sh-kopf-beispiel'; ext = 'sh'; want = ''; src = @'
#!/usr/bin/env bash
# Aufruf:
# FOO=bar ./x.sh
echo x
'@ }
    @{ id = 'sh-todo-caps';     ext = 'sh'; want = 'caps,todo'; src = @'
#!/usr/bin/env bash
echo x
# TODO weg
# MUSS vorher laufen
'@ }
    @{ id = 'sh-quote-heredoc'; ext = 'sh'; want = 'todo'; src = @'
#!/usr/bin/env bash
echo "Aufruf: cmd <<EOF"
echo x # TODO weg
'@ }
    # --- JS ---
    @{ id = 'js-template-nested'; ext = 'js'; want = 'caps'; src = @'
const s = `a ${ok ? `x` : 'y'} // kein Kommentar`;
foo(); // NUR einmal
'@ }
    @{ id = 'js-verlauf';       ext = 'js'; want = 'verlauf'; src = @'
const a = 1; // seit v0.4 neu
'@ }
    @{ id = 'js-string';        ext = 'js'; want = ''; src = @'
const u = 'http://x // KW45';
const t = `a
// NIE und TODO
`;
const r = /\/\/ TODO/;
'@ }
    @{ id = 'js-division';      ext = 'js'; want = 'caps'; src = @'
const d = a / b; // NUR so, sonst / falsch
'@ }
    @{ id = 'js-code';          ext = 'js'; want = 'code'; src = @'
foo();
// bar(1);
'@ }
    @{ id = 'js-block';         ext = 'js'; want = 'caps'; src = @'
foo();
/*
 * ACHTUNG: zweimal aufgerufen
 */
'@ }
    @{ id = 'js-nicht';         ext = 'js'; want = ''; src = @'
foo();
// Grenzfall: leerer Body liefert 400, Regel (k) im Lint
'@ }
)
# Arbeits-Marken und Plan-Verweise: je Zeile ein eigener Fall (jedes Muster muss allein treffen bzw. still bleiben).
$marks = @(
    'Karte nur einmal senden (Owner 2026-10-22)', 'Trenner wie im Datum (Abnahme 2026-10-31)', 'Owner-Entscheid 2026-10-24: Text bleibt',
    'so gewuenscht in der Owner-Runde', 'CR bricht bash ab (Probelauf-Fund)', 'Start-App bauen (Plan docker-freunde, Paket 6)',
    'Laufzeit im Verbund (Paket 2)', 'Paket 3/5 des Umbaus', 'siehe Einwand 4', 'Pruefliste Nr. 7 deckt das',
    'Rollen je Paket (P5)', 'leeres Konto entfaellt (B10)', 'Bug B4: doppelte Zeile',
    'Karten der offenen Frage, Plan s4-berater-ux', 'Regel aus Plan *Wenn Docker schon da ist*', 'Details in .claude/plans/umbau.md',
    'Brief unter .local/handover/brief.md'
)
$noMarks = @(
    'Zustandsdatei .local/n8ntest_state.<container>.json im Haupt-Checkout', 'je Paket 1 Datei, Paket 2 folgt dem Muster nicht',
    'Owner tippt einmal; Rate am 31.01.2027 faellig', 'Plan-Schritt des Beraters, Plan des Haushalts', '(B) von Hand mitgegebene Werte',
    'Migration core:V012 legt die Spalte an', 'Spalte fehlt seit core:V012, core:V017 droppt sie', 'Pruefung (P) und (B) im Lint',
    'Tests: tests/db/x/test_prop_a.sql (P5)', 'sonst der Knoten (Plan route?)', 'entscheidet die fn (Plan und Sperre in der DB)'
)
$i = 0
foreach ($line in $marks)   { $i++; $cases += @{ id = "marke-$i";       ext = 'ps1'; want = 'verlauf'; src = "`$a = 1`n# $line`n" } }
$i = 0
foreach ($line in $noMarks) { $i++; $cases += @{ id = "marke-nicht-$i"; ext = 'ps1'; want = '';        src = "`$a = 1`n# $line`n" } }

# --- Regel-Faelle: alle Dateien in einem Lint-Lauf ---------------------------------------------------------------
$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('cl_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $paths = @{}
    foreach ($c in $cases) {
        $f = Join-Path $dir "$($c.id).$($c.ext)"
        [System.IO.File]::WriteAllText($f, $c.src, $u8)
        $paths[$c.id] = $f.Replace('\', '/')
    }
    # Pflicht-Koepfe: neue Skripte unter scripts/ (ohne lib/) und neue R__fn_*-Dateien. Pfad zusammengesetzt, sonst haelt doc_lint
    # die erfundenen Dateinamen fuer tote Verweise.
    $sd = 'scripts'; $pk = 'packages'; $pv = 'provisioning'; $tt = 'tests'
    $heads = @(
        @{ id = 'kopf-skript';       rel = "$sd/neu.ps1";      want = 'kopf'; src = "# Macht X.`n`$a = 1`n" }
        @{ id = 'kopf-skript-ok';    rel = "$sd/gut.ps1";      want = '';     src = "# Macht X.`n# Aufruf: .\scripts\gut.ps1`n# Exit-Code 0 = ok.`n`$a = 1`n" }
        @{ id = 'kopf-lib';          rel = "$sd/lib/h.ps1";    want = '';     src = "function H { 1 }`n" }
        @{ id = 'kopf-fn';           rel = 'm/R__fn_neu.sql';      want = 'kopf'; src = "-- Liefert etwas.`nSELECT 1;`n" }
        @{ id = 'kopf-fn-ok';        rel = 'm/R__fn_gut.sql';      want = '';     src = "-- ====`n-- core.fn_gut (READ)`n--   Liefert etwas.`nSELECT 1;`n" }
        @{ id = 'kopf-fn-ohne-text'; rel = 'm/R__fn_kurz.sql';     want = 'kopf'; src = "-- fn_kurz (READ)`nSELECT 1;`n" }
        # fn-Kopf nennt jeden Eingabe-Key, den der Rumpf aus p liest (p->'a'->>'b' nennt nur a; p_facts ist ein anderes Objekt).
        @{ id = 'kopf-fn-keys';      rel = 'm/R__fn_keys.sql';     want = 'kopf'; src = "-- fn_keys (WRITE)`n--   Eingabe: amount (Pflicht).`nCREATE FUNCTION x.fn_keys(p jsonb) RETURNS jsonb LANGUAGE sql AS `$f`$ SELECT p->>'amount', p->>'note', p ? 'flag' `$f`$;`n" }
        @{ id = 'kopf-fn-keys-ok';   rel = 'm/R__fn_keysok.sql';   want = '';     src = "-- fn_keysok (WRITE)`n--   Eingabe: amount (Pflicht), note, flag, plan (Objekt).`nCREATE FUNCTION x.fn_keysok(p jsonb, p_facts jsonb) RETURNS jsonb LANGUAGE sql AS `$f`$ SELECT p->>'amount', p->>'note', p ? 'flag', p->'plan'->>'tief', p_facts->>'fremd', v.p->>'spalte' -- p->>'im_kommentar'`n `$f`$;`n" }
        @{ id = 'kopf-fn-keys-alias'; rel = 'm/R__fn_alias.sql';   want = '';     src = "-- fn_alias (READ)`n--   Liefert Namen.`nCREATE FUNCTION x.fn_alias(p_confirm text) RETURNS jsonb LANGUAGE sql AS `$f`$ SELECT jsonb_agg(p->>'first_name') FROM jsonb_array_elements('[]'::jsonb) p `$f`$;`n" }
        @{ id = 'kopf-fn-keys-marke'; rel = 'm/R__fn_marke.sql';   want = '';     src = "-- fn_marke (WRITE)`n--   Schreibt etwas.`nCREATE FUNCTION x.fn_marke(p_id int, p jsonb) RETURNS jsonb LANGUAGE sql AS `$f`$ SELECT p->>'intern' -- comment-lint: ok kein Eingabe-Key, Feld der Zwischenzeile`n `$f`$;`n" }
        # Nummern von Pruefschritten in Test-Dateien sind Adressen, keine Arbeits-Marken.
        @{ id = 'marke-test-datei';  rel = "$tt/db/x/test_iso.sql"; want = '';    src = "-- (B1) x darf lesen`nSELECT 1;`n" }
        # Build-Defs, Installer-Bibliotheken und Top-Skripte des Installers; "Dot-gesourct von" nur mit vorhandener Datei.
        @{ id = 'kopf-def';          rel = "$pk/x/build/workflows/neu.ps1";  want = 'kopf'; src = "# Baut X.`nfunction Build-X { 1 }`n" }
        @{ id = 'kopf-def-ok';       rel = "$pk/x/build/workflows/gut.ps1";  want = '';     src = "# Baut X: Ausloeser Y, Ausgang {ok}.`n# Dot-gesourct von build.ps1.`nfunction Build-X { 1 }`n" }
        @{ id = 'kopf-def-quelle';   rel = "$pk/x/build/workflows/tot.ps1";  want = 'kopf'; src = "# Baut X: Ausloeser Y, Ausgang {ok}.`n# Dot-gesourct von gibt_es_nicht_helfer.ps1.`nfunction Build-X { 1 }`n" }
        @{ id = 'kopf-lib-sh';       rel = "$pv/lib/neu.sh";     want = 'kopf'; src = "# Helfer fuer X.`nfoo() { :; }`n" }
        @{ id = 'kopf-lib-sh-ok';    rel = "$pv/lib/gut.sh";     want = '';     src = "# shellcheck disable=SC2034  # Grund`n# gut.sh $([char]0x2014) Helfer fuer X.`n# Gesourct von provision.sh.`nfoo() { :; }`n" }
        @{ id = 'kopf-top-sh';       rel = "$pv/neu_top.sh";     want = 'kopf'; src = "#!/usr/bin/env bash`n# Macht X.`necho x`n" }
        @{ id = 'kopf-top-sh-ok';    rel = "$pv/gut_top.sh";     want = '';     src = "#!/usr/bin/env bash`n# Macht X.`n# Aufruf: bash gut_top.sh`n# Exit 0 = ok.`necho x`n" }
    )
    foreach ($h in $heads) {
        $f = Join-Path $dir $h.rel
        New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
        [System.IO.File]::WriteAllText($f, $h.src, $u8)
        $paths[$h.id] = $f.Replace('\', '/')
    }
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $lint -Files (@($paths.Values) -join ',') -Json
    if ($LASTEXITCODE -ne 0) { Fail "Lint-Lauf -Files brach ab (Exit $LASTEXITCODE): $raw" }
    $found = @(($raw -join '') | ConvertFrom-Json | ForEach-Object { $_ })   # PS 5.1 liefert das JSON-Array als ein Objekt
    foreach ($c in @($cases + $heads)) {
        $got = (@($found | Where-Object { $_.File -eq $paths[$c.id] } | ForEach-Object { $_.Rule } | Sort-Object -Unique) -join ',')
        if ($got -ne $c.want) { Fail "$($c.id): erwartet [$($c.want)], gefunden [$got]" } else { Write-Host "  ok $($c.id)" -ForegroundColor DarkGray }
    }
} finally { Remove-Item -Recurse -Force $dir }

# --- Diff-Modus im Wegwerf-Repo: der alte Fund bleibt stumm, nur die neue Zeile zaehlt ----------------------------
$repo = Join-Path ([System.IO.Path]::GetTempPath()) ('clr_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $repo | Out-Null
$savedEnv = @{}; foreach ($e in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_*' })) { $savedEnv[$e.Name] = $e.Value }
try {
    Clear-GitEnvironment
    Initialize-GitSandbox $repo
    & git -C $repo config user.email 't@example.invalid'; & git -C $repo config user.name 't'; & git -C $repo config commit.gpgsign false; & git -C $repo config core.autocrlf false
    New-Item -ItemType Directory -Path (Join-Path $repo 'scripts') | Out-Null
    Copy-Item $lint (Join-Path $repo 'scripts\comment_lint.ps1')
    $old = Join-Path $repo 'a.sql'
    [System.IO.File]::WriteAllText($old, "SELECT 1; -- Befund 2026-10-24 alt`n", $u8)
    & git -C $repo add -A; & git -C $repo commit -q -m base
    $sandLint = Join-Path $repo 'scripts\comment_lint.ps1'

    $failsBefore = $fails
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sandLint -Base HEAD
    if ($LASTEXITCODE -ne 0) { Fail "Diff-Modus: unveraenderter Bestand mit altem Fund muss gruen sein (Exit $LASTEXITCODE)" }

    [System.IO.File]::AppendAllText($old, "SELECT 2; -- NIE ohne Sperre`n", $u8)
    & git -C $repo add a.sql
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sandLint -Staged
    if ($LASTEXITCODE -ne 1 -or ($out -join ' ') -notmatch 'a\.sql:2 \[caps\]') { Fail "Diff-Modus -Staged: genau ein Fund in a.sql:2 erwartet (Exit $LASTEXITCODE): $out" }

    [System.IO.File]::WriteAllText((Join-Path $repo 'b.js'), "foo(); // eingebaut (KW45)`n", $u8)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sandLint -Base HEAD
    if ($LASTEXITCODE -ne 2) { Fail "Diff-Modus -Base: neue Zeile in a.sql und unversionierte b.js erwartet, 2 Funde (Exit $LASTEXITCODE): $out" }
    if ($fails -eq $failsBefore) { Write-Host '  ok diff-modus' -ForegroundColor DarkGray }
} finally {
    foreach ($k in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
    Remove-Item -Recurse -Force $repo
}

if ($fails -eq 0) { Write-Host "PASS comment_lint_test ($($cases.Count) Regel-Faelle, Pflicht-Koepfe, Diff-Modus)" -ForegroundColor Green }
else { Write-Host "comment_lint_test: $fails rot" -ForegroundColor Red }
exit $fails
