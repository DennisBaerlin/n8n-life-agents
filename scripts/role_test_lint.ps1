#Requires -Version 5.1
# role_test_lint.ps1 -- hartes Commit-Gate (Vorbild approval_lint/core_literal_lint): jede publizierte
# SECURITY-DEFINER-Bruecken-fn, die unter einer RESTRIKTIVEN Lese-Rolle laeuft (EXECUTE-Grant an eine
# *_ro-Rolle), MUSS in tests/db/cross/test_role_permissions.sql einen SET-LOCAL-ROLE-Perspektiv-Test
# haben (Rollen-Perspektiv-Pflicht -> tests/CLAUDE.md *DB-Tests: Pattern*). Grund: der db_test laeuft als
# Superuser und umgeht ALLE Rechtepruefungen -> ein fehlender Grant / kein Zugriff unter der engen Rolle
# ist im Superuser-Test UNSICHTBAR (so brach core.fn_fetch_context/load_context monatelang, WS3).
#
# STRENGE = "mind. EINE Rolle" (nicht "unter jeder"): die fn ist in mind. einem SET-LOCAL-ROLE-Segment
# aufgerufen (der echte Prod-Pfad ist damit gedeckt; estate_ro-Paritaet ist billige optionale Zugabe,
# kein Muss -> s. Plan-Notiz).
#
# SCOPE (Union zweier Zweige):
#  (A) provides.reads[] je packages/*/manifest.json -- NUR wenn die owning-fn SECURITY DEFINER ist.
#      Die Oberflaeche-A-Provider-fns (finance.fn_liquidity_snapshot/_insurance_register/_account_register/
#      _liability_register) sind PLAIN STABLE + kein Grant -> laufen NIE unter *_ro -> skip. Ohne diesen
#      DEFINER-Filter wuerde der Lint auf allen 4 false-failen. Modus = R__fn_<name>.sql auf /SECURITY DEFINER/i.
#  (B) expliziter GRANT EXECUTE an eine Lese-Rolle: static util_create_*_ro.sql (TO <role>_ro) + dynamisch
#      R__fn_provision_package_roles.sql (TO %I, %I == (v_rw, v_ro)). Single %I == v_rw -> KEIN Read-Role-
#      Grant -> exclude (fn_set_onboarding_section/fn_check_write_permission/fn_should_notify/fn_notify_resolve).
#      MUST-IGNORE: (i) Blanket GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA; (ii) jeder GRANT SELECT/USAGE.
#
# MATCH: schema-qualifizierter NAME (core.fn_x) in mind. einem SET-LOCAL-ROLE...RESET-ROLE-Segment (NUR
# der Name, NIE die Signatur -- der Grant traegt arg-TYPEN, der Test arg-WERTE). No-arg-fns per Name
# identisch. Ein Vorkommen ausserhalb eines Rollen-Segments (Kommentar/Fixture) zaehlt NICHT.
#
# ALLOWLIST: scripts/build/role_test_lint_allowlist.json {fn, reason} (Ratchet-Spirit wie core_literal).
# Mit dem DEFINER-Filter bleibt sie LEER (alle 12 heutigen Fenster getestet). Orphan = FAIL.
#
# GEGENRICHTUNG (C, 2026-10-23): jeder core./agent.-Aufruf eines gebauten Workflow-Knotens unter einer engen Rolle
# muss fuer diese Rolle ausfuehrbar sein (PUBLIC-Default oder Grant) -- Details am Block unten.
#
# Kein LLM, kein Netz, kein Substrat. Exit-Code = Anzahl Fehler.
param([switch]$Verbose)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
$RepoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
$u8 = New-Object System.Text.UTF8Encoding($false)
$fails = 0
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fails++ }

# --- SQL-Kommentar quote-aware strippen (-- am Code-Level; -- innerhalb '...' bleibt) -----------------
function Get-SqlCode {
    param([string]$Line)
    $inS = $false; $inD = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($inS) { if ($c -eq "'") { $inS = $false }; continue }
        if ($inD) { if ($c -eq '"') { $inD = $false }; continue }
        if ($c -eq "'") { $inS = $true; continue }
        if ($c -eq '"') { $inD = $true; continue }
        if ($c -eq '-' -and $i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '-') { return $Line.Substring(0, $i) }
    }
    return $Line
}

# --- SECURITY DEFINER als echten fn-Modifier erkennen (NICHT im Kommentar) ----------------------------
# Die Oberflaeche-A-Header erwaehnen "SECURITY DEFINER" in der Prosa ("... als SECURITY DEFINER exponieren
# -> dann ...") als die VERWORFENE Alternative -> ein roher Text-Match false-positived alle 4 PLAIN-STABLE-
# fns. Darum zuerst die --Kommentare quote-aware strippen, dann matchen (der Modifier steht im fn-Header,
# nie im $$-Body -> Comment-Stripping ist hier sicher).
function Test-FileHasDefiner {
    param([string]$Path)
    $code = ([System.IO.File]::ReadAllLines($Path, $u8) | ForEach-Object { Get-SqlCode $_ }) -join "`n"
    return ($code -match '(?i)SECURITY\s+DEFINER')
}

# --- Branch B: GRANT-EXECUTE-Zeilen einer Datei -> Liste der an eine Lese-Rolle gegranteten schema.fn ---
$grantRx = [regex]"GRANT\s+EXECUTE\s+ON\s+FUNCTION\s+([a-z0-9_]+\.[a-z0-9_]+)\s*\(([^)]*)\)\s+TO\s+([^';]+)"
function Get-ReadRoleGrants {
    param([string]$Path)
    $out = @()
    if (-not (Test-Path $Path)) { return $out }
    foreach ($line in [System.IO.File]::ReadAllLines($Path, $u8)) {
        $code = Get-SqlCode $line
        $m = $grantRx.Match($code)
        if (-not $m.Success) {
            # Self-Assert (Cold-Eyes A2): eine per-fn GRANT-EXECUTE-Zeile, die $grantRx NICHT parst, ist ein
            # STILLER Deckungs-Verlust (mehrzeiliges GRANT ODER verschachtelte Argument-Klammer wie
            # numeric(10,2) -> [^)]* stoppt an der inneren `)`). Fail-closed statt still uebergehen.
            # (Die Blanket-Form GRANT EXECUTE ON ALL FUNCTIONS matcht `ON FUNCTION ` bewusst nicht -> kein Fehlalarm.)
            # SUPPRESSION (zweistufig wie layout_lint L4): ein in-line `lint-ignore: role-test-lint` auf der
            # ROHEN Zeile (Kommentar-Teil) markiert eine bewusst dynamische Grant-Form ausserhalb des Scopes —
            # heute genau der INVOKER-only-Bulk-Grant in fn_provision_package_roles (NOT prosecdef gefiltert,
            # kein DEFINER-Fenster). Unmarkierte dynamische Grants failen weiter fail-closed.
            if ([regex]::IsMatch($code, 'GRANT\s+EXECUTE\s+ON\s+FUNCTION\s')) {
                if ($line -match 'lint-ignore:\s*role-test-lint') {
                    if ($Verbose) { Write-Host "  [skip] markierter dynamischer Grant: $($code.Trim())" -ForegroundColor DarkGray }
                } else {
                    Fail "GRANT-EXECUTE-Parse-Miss in $([System.IO.Path]::GetFileName($Path)): '$($code.Trim())' -- der Grant-Parser greift nicht (mehrzeilig? verschachtelte Argument-Klammer?). Parser haerten ODER bewusst-dynamische Form mit `lint-ignore: role-test-lint` markieren, sonst stiller Deckungs-Verlust."
            }
            }
            continue
        }
        $fn = $m.Groups[1].Value
        $target = $m.Groups[3].Value.Trim()
        $isRead = $false
        if ($target -match '%I') {
            # 2x %I == (v_rw, v_ro) -> Read-Rolle dabei; 1x %I == v_rw -> nein.
            if (([regex]::Matches($target, '%I')).Count -ge 2) { $isRead = $true }
        } else {
            foreach ($r in ($target -split ',')) { if ($r.Trim() -match '_ro$') { $isRead = $true } }
        }
        if ($isRead) { $out += $fn }
    }
    return $out
}

# --- Scope aufbauen: $required[schema.fn] = <Quelle> --------------------------------------------------
$required = @{}

# (B) Grant-Quellen: die zwei Core-RO-Util + jedes R__fn_provision_package_roles (heute nur core).
$grantSources = @()
$grantSources += @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Recurse -Filter 'util_create_*_ro.sql' -ErrorAction SilentlyContinue | ForEach-Object FullName)
$grantSources += @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Recurse -Filter 'R__fn_provision_package_roles.sql' -ErrorAction SilentlyContinue | ForEach-Object FullName)
foreach ($src in ($grantSources | Sort-Object -Unique)) {
    foreach ($fn in (Get-ReadRoleGrants $src)) {
        if (-not $required.ContainsKey($fn)) { $required[$fn] = "grant:$([System.IO.Path]::GetFileName($src))" }
    }
}

# (A) provides.reads DEFINER-fns je Manifest (PLAIN STABLE -> skip).
foreach ($pkgDir in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | ForEach-Object FullName)) {
    $mf = Join-Path $pkgDir 'manifest.json'
    if (-not (Test-Path $mf)) { continue }
    $json = $null
    try { $json = [System.IO.File]::ReadAllText($mf, $u8) | ConvertFrom-Json } catch { Fail "manifest unparsbar: $mf -- $_"; continue }
    if (-not ($json.provides -and $json.provides.reads)) { continue }
    foreach ($r in @($json.provides.reads)) {
        if ($r -notmatch '^([a-z0-9_]+)\.([a-z0-9_]+)\s*\(') { continue }
        $schema = $Matches[1]; $fnName = $Matches[2]
        $sq = "$schema.$fnName"
        $owningFile = Join-Path $pkgDir "db\migrations\R__$fnName.sql"
        if (-not (Test-Path $owningFile)) {
            Write-Host "  [WARN] provides.reads $sq : owning-Datei R__$fnName.sql nicht gefunden (DEFINER-Modus unbestimmbar -> nicht gefordert)" -ForegroundColor DarkYellow
            continue
        }
        if (Test-FileHasDefiner $owningFile) {
            if (-not $required.ContainsKey($sq)) { $required[$sq] = "provides.reads(DEFINER):$fnName" }
        }
        # PLAIN STABLE -> skip (laeuft nie unter einer *_ro-Rolle).
    }
}

# Self-Assert: Scope-Enumeration darf nicht still leer sein (Parser-Bruch -> False-Green).
if ($required.Count -lt 1) { Fail "Scope-Enumeration lieferte 0 fns -- Grant-Parser kaputt? (erwartet >=1)" }

# --- Rollen-Perspektiv-Testdatei: SET-LOCAL-ROLE...RESET-ROLE-Segmente extrahieren --------------------
$testFile = Join-Path $RepoRoot 'tests\db\cross\test_role_permissions.sql'
$segments = @()
if (-not (Test-Path $testFile)) {
    Fail "Rollen-Perspektiv-Testdatei fehlt: tests/db/cross/test_role_permissions.sql"
} else {
    # Kommentare zuerst strippen (wie Test-FileHasDefiner): ein fn-Name in einem --Kommentar INNERHALB
    # eines Rollen-Segments darf NICHT als Deckung zaehlen (Cold-Eyes A1) -- nur ein echter Aufruf zaehlt.
    $testCode = ([System.IO.File]::ReadAllLines($testFile, $u8) | ForEach-Object { Get-SqlCode $_ }) -join "`n"
    $segRx = [regex]'(?is)SET\s+LOCAL\s+ROLE\s+\w+\s*;(.*?)RESET\s+ROLE'
    $segments = @($segRx.Matches($testCode) | ForEach-Object { $_.Groups[1].Value })
    # Self-Assert: der Segment-Parser muss etwas finden (sonst zaehlte alles als ungetestet).
    if ($segments.Count -lt 1) { Fail "keine SET-LOCAL-ROLE-Segmente in test_role_permissions.sql gefunden -- Segment-Parser kaputt?" }
}

# --- Allowlist laden + selbst-konsistent pruefen -----------------------------------------------------
$alPath = Join-Path $RepoRoot 'scripts\build\role_test_lint_allowlist.json'
$allow = @{}
if (-not (Test-Path $alPath)) {
    Fail "Allowlist fehlt: scripts/build/role_test_lint_allowlist.json (leer {allow:[]} anlegen)"
} else {
    $al = [System.IO.File]::ReadAllText($alPath, $u8) | ConvertFrom-Json
    foreach ($e in @($al.allow)) {
        $k = [string]$e.fn
        if ([string]::IsNullOrWhiteSpace($k)) { Fail "allowlist: Eintrag ohne fn"; continue }
        if ([string]::IsNullOrWhiteSpace([string]$e.reason)) { Fail "allowlist: Eintrag '$k' ohne reason (jede Ausnahme braucht eine Begruendung)" }
        if ($allow.ContainsKey($k)) { Fail "allowlist: doppelter Eintrag '$k'"; continue }
        $allow[$k] = [string]$e.reason
    }
}

# --- Abgleich: jede in-scope fn hat mind. ein Rollen-Segment mit ihrem Namen --------------------------
$usedAllow = @{}
foreach ($fn in ($required.Keys | Sort-Object)) {
    $nameRx = [regex]("(?i)" + [regex]::Escape($fn) + "\b")   # NUR der Name, nie die Signatur
    $covered = $false
    foreach ($seg in $segments) { if ($nameRx.IsMatch($seg)) { $covered = $true; break } }
    if ($covered) {
        if ($Verbose) { Write-Host "  [ok] $fn  ($($required[$fn]))" -ForegroundColor DarkGray }
        continue
    }
    if ($allow.ContainsKey($fn)) {
        $usedAllow[$fn] = $true
        Write-Host "  [ALLOW] $fn -- $($allow[$fn])" -ForegroundColor DarkYellow
        continue
    }
    Fail "$fn ist unter einer Lese-Rolle EXECUTE-gegrantet ($($required[$fn])), hat aber KEINEN SET-LOCAL-ROLE-Perspektiv-Test in tests/db/cross/test_role_permissions.sql -- Rollen-Test ergaenzen (SET LOCAL ROLE <rolle>; ... $fn(...); RESET ROLE;) ODER mit Begruendung in scripts/build/role_test_lint_allowlist.json allowlisten."
}

# --- Orphan-Allowlist: Eintrag (a) nicht in scope ODER (b) in scope + ohnehin getestet ----------------
foreach ($k in ($allow.Keys | Sort-Object)) {
    if (-not $usedAllow.ContainsKey($k)) {
        Fail "allowlist-ORPHAN '$k' -- die fn braucht keine Ausnahme (nicht in scope ODER hat bereits einen Rollen-Test); Eintrag entfernen (Ratchet schrumpft)."
    }
}

# --- (C) Gegenrichtung: jeder Workflow-Aufruf unter einer ENGEN Rolle braucht ein Ausfuehrungsrecht ----------------
# Anlass 2026-10-23 (/reminders-Menue): ein Postgres-Knoten unter core_ro rief core.fn_ui_texts_for (REVOKE PUBLIC,
# Grant nur an die Paket-Rollen) -> zur Laufzeit permission denied; db_test (Superuser) und (A)/(B) oben (Grant ->
# Test) sahen es nicht. Statisch je gebautem Knoten: Rolle aus dem Platzhalter __CRED_POSTGRES_<ROLLE>_RO|RW__
# (WRITE = Owner-Cred -> skip), Aufrufe core.fn_x( / agent.fn_x( aus der Query. Erlaubt, wenn das Schema fuer die
# Rolle sichtbar ist (Paket-Rollen: nur core) UND entweder die fn ihren PUBLIC-Default behaelt (kein REVOKE ... FROM
# public in packages/*/db; context_ro bekommt nie etwas ueber PUBLIC) ODER ein Grant die Rolle deckt
# (util_create_<rolle>.sql literal; fn_provision_package_roles 'TO %I, %I' = rw+ro, 'TO %I' = nur rw).
$grantMap = @{}   # schema.fn -> @{ <rolle> | '%rw' | '%ro' = $true }
foreach ($src in ($grantSources | Sort-Object -Unique)) {
    foreach ($line in [System.IO.File]::ReadAllLines($src, $u8)) {
        $m = $grantRx.Match((Get-SqlCode $line))
        if (-not $m.Success) { continue }
        $fn = $m.Groups[1].Value; $target = $m.Groups[3].Value.Trim()
        if (-not $grantMap.ContainsKey($fn)) { $grantMap[$fn] = @{} }
        if ($target -match '%I') {
            $grantMap[$fn]['%rw'] = $true
            if (([regex]::Matches($target, '%I')).Count -ge 2) { $grantMap[$fn]['%ro'] = $true }
        } else {
            foreach ($r in ($target -split ',')) { $grantMap[$fn][$r.Trim()] = $true }
        }
    }
}
$revoked = @{}
$revokeRx = [regex]'(?is)REVOKE\s+(?:ALL|EXECUTE)\s+ON\s+FUNCTION\s+([a-z0-9_]+\.[a-z0-9_]+)\s*\([^;]*?FROM\s+public'
foreach ($f in (Get-ChildItem (Join-Path $RepoRoot 'packages') -Recurse -Filter '*.sql' | Where-Object { $_.FullName -match '\\db\\' })) {
    $code = ([System.IO.File]::ReadAllLines($f.FullName, $u8) | ForEach-Object { Get-SqlCode $_ }) -join "`n"
    foreach ($m in $revokeRx.Matches($code)) { $revoked[$m.Groups[1].Value] = $true }
}
if ($revoked.Count -lt 1) { Fail "(C) keine REVOKE-FROM-public-fn gefunden -- REVOKE-Parser kaputt? (erwartet >=1)" }
$callRx = [regex]'\b(core|agent)\.(fn_[a-z0-9_]+)\s*\('
$nCalls = 0
foreach ($wfFile in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\workflows\*.json'))) {
    $wf = [System.IO.File]::ReadAllText($wfFile.FullName, $u8) | ConvertFrom-Json
    foreach ($n in @($wf.nodes)) {
        if (-not $n.credentials -or -not $n.credentials.postgres) { continue }
        if ([string]$n.credentials.postgres.id -notmatch '^__CRED_POSTGRES_([A-Z0-9_]+)_(RO|RW)__$') { continue }
        $role = ($Matches[1] + '_' + $Matches[2]).ToLower()
        $isPkg = $role -notin @('core_ro', 'context_ro')
        foreach ($m in $callRx.Matches([string]$n.parameters.query)) {
            $fn = "$($m.Groups[1].Value).$($m.Groups[2].Value)"; $nCalls++
            $where = "$($wf.name) / '$($n.name)' (Rolle $role)"
            if ($isPkg -and $m.Groups[1].Value -eq 'agent') {
                Fail "(C) $where ruft $fn -- Schema agent ist fuer Paket-Rollen unsichtbar; ueber ein publiziertes core-Fenster lesen."
                continue
            }
            $g = $grantMap[$fn]
            $granted = $g -and ($g.ContainsKey($role) -or ($isPkg -and $g.ContainsKey('%' + $role.Substring($role.Length - 2))))
            if (-not $granted -and ($role -eq 'context_ro' -or $revoked.ContainsKey($fn))) {
                Fail "(C) $where ruft $fn ohne Ausfuehrungsrecht (REVOKE PUBLIC, kein Grant an $role) -> zur Laufzeit permission denied. Grant am Rollen-Ort ergaenzen (+ Rollen-Test) ODER eine fuer $role freigegebene fn nutzen."
            }
        }
    }
}
if ($nCalls -lt 1) { Fail "(C) keine core./agent.-Aufrufe unter engen Rollen gefunden -- Workflow-Parser kaputt? (erwartet >=1)" }
if ($Verbose) { Write-Host "  (C) $nCalls Aufruf(e) unter engen Rollen geprueft" -ForegroundColor DarkGray }

if ($fails -eq 0) {
    Write-Host "role_test_lint: OK ($($required.Count) DEFINER/_ro-Bruecken-fn(s) rollen-getestet, 0 Luecken; Workflow-Aufrufe unter engen Rollen freigegeben)" -ForegroundColor Green
} else {
    Write-Host "role_test_lint: $fails Fehler" -ForegroundColor Red
}
exit $fails
