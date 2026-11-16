# role_call_pairs.ps1 -- Bausteine der Rollen-Luecken-Pruefung (Zweig D von scripts/role_test_lint.ps1, Test:
# scripts/dev/role_gap_lint_test.ps1). Per Dot-Sourcing laden.
#   Get-RoleCallPairs   (Rolle, schema.fn)-Paare: Postgres-Knoten gebauter Workflows unter __CRED_POSTGRES_<ROLLE>_(RO|RW)__
#                       (WRITE = Owner-Rolle, ausgenommen), jedes schema.fn_x( der Query ohne SQL-Kommentare.
#   Get-RoleTestedFns   schema.fn_x in einem SET-ROLE-Segment irgendeines tests/db/**/*.sql (Segment endet an RESET ROLE,
#                       dem naechsten SET ROLE, ROLLBACK, COMMIT oder Dateiende; ein SET LOCAL gilt bis dahin). Segmente mit
#                       insufficient_privilege sind Negativ-Tests (Aufruf muss scheitern) und zaehlen nicht; ein
#                       EXECUTE format('SET LOCAL ROLE %I') ist unsichtbar (die fn gilt dann als ungetestet).
#   Compare-RoleGap     jede aufgerufene fn hat einen Rollen-Test oder steht mit Grund in der Liste; Orphan = Fehler.
#   Get-RoleCatalogBlock  die Paare als SQL-VALUES-Zeilen fuer tests/db/cross/test_role_catalog_exec.sql.
# Grenze: nur Aufrufe in parameters.query der Postgres-Knoten; Aufrufe in Code-Knoten oder im Koerper anderer fns fehlen.

function Remove-SqlComments([string]$Sql) {
    $s = [regex]::Replace($Sql, '(?s)/\*.*?\*/', ' ')
    return [regex]::Replace($s, '--[^\r\n]*', '')
}

function Get-RoleCallPairs {
    param([Parameter(Mandatory)][string]$Root)
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $callRx = [regex]'\b([a-z][a-z0-9_]*)\.(fn_[a-z0-9_]+)\s*\('
    $seen = @{}
    $files = @(Get-ChildItem (Join-Path $Root 'packages') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $d = Join-Path $_.FullName 'workflows'
        if (Test-Path $d) { Get-ChildItem $d -Filter '*.json' -File }
    })
    foreach ($f in $files) {
        $wf = [System.IO.File]::ReadAllText($f.FullName, $u8) | ConvertFrom-Json
        foreach ($n in @($wf.nodes)) {
            if (-not $n.credentials -or -not $n.credentials.postgres) { continue }
            if ([string]$n.credentials.postgres.id -notmatch '^__CRED_POSTGRES_([A-Z0-9_]+)_(RO|RW)__$') { continue }
            $role = ($Matches[1] + '_' + $Matches[2]).ToLower()
            $q = Remove-SqlComments ([string]$n.parameters.query)
            foreach ($m in $callRx.Matches($q)) {
                $fn = "$($m.Groups[1].Value).$($m.Groups[2].Value)"
                $seen["$role|$fn"] = [pscustomobject]@{ Role = $role; Fn = $fn }
            }
        }
    }
    return @($seen.Values | Sort-Object Role, Fn)
}

function Get-RoleTestedFns {
    param([Parameter(Mandatory)][string]$Root)
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $segRx = [regex]'(?is)\bSET\s+(?:LOCAL\s+|SESSION\s+)?ROLE\s+\w+\s*;(.*?)(?:\bRESET\s+ROLE\b|\bSET\s+(?:LOCAL\s+|SESSION\s+)?ROLE\b|\bROLLBACK\b|\bCOMMIT\b|\z)'
    $fnRx = [regex]'\b([a-z][a-z0-9_]*)\.(fn_[a-z0-9_]+)\b'
    $dir = Join-Path $Root 'tests\db'
    $out = @{}
    if (-not (Test-Path $dir)) { return @() }
    foreach ($f in (Get-ChildItem $dir -Recurse -Filter '*.sql' -File)) {
        $code = Remove-SqlComments ([System.IO.File]::ReadAllText($f.FullName, $u8))
        foreach ($s in $segRx.Matches($code)) {
            if ($s.Groups[1].Value -match '(?i)insufficient_privilege') { continue }
            foreach ($m in $fnRx.Matches($s.Groups[1].Value)) { $out["$($m.Groups[1].Value).$($m.Groups[2].Value)"] = $true }
        }
    }
    return @($out.Keys | Sort-Object)
}

function Compare-RoleGap {
    param($Pairs, [string[]]$Tested, [hashtable]$Allow)
    $errors = New-Object System.Collections.Generic.List[string]
    $called = @($Pairs | ForEach-Object { $_.Fn } | Sort-Object -Unique)
    $roles = @{}
    foreach ($p in $Pairs) { if (-not $roles.ContainsKey($p.Fn)) { $roles[$p.Fn] = @() }; $roles[$p.Fn] += $p.Role }
    foreach ($fn in $called) {
        $isTested = $Tested -contains $fn
        if ($Allow.ContainsKey($fn)) {
            if (-not "$($Allow[$fn])".Trim()) { $errors.Add("role_test_gap_allowlist: Eintrag '$fn' ohne Grund (welcher Rollen-Test fehlt?)") }
            if ($isTested) { $errors.Add("role_test_gap_allowlist: '$fn' hat inzwischen einen SET-ROLE-Test -> Eintrag entfernen; die Liste darf nur schrumpfen") }
            continue
        }
        if (-not $isTested) {
            $errors.Add("$fn wird von einem Workflow unter $(($roles[$fn] | Sort-Object -Unique) -join '/') aufgerufen, hat aber keinen SET-ROLE-Perspektiv-Test (tests/db) und steht nicht in scripts/build/role_test_gap_allowlist.json -> Rollen-Test schreiben (Muster: tests/db/cross/test_role_permissions.sql)")
        }
    }
    foreach ($k in $Allow.Keys) {
        if ($called -notcontains $k) { $errors.Add("role_test_gap_allowlist: '$k' wird von keinem Workflow unter enger Rolle mehr aufgerufen -> Eintrag entfernen; die Liste darf nur schrumpfen") }
    }
    return [pscustomobject]@{ Errors = @($errors) }
}

function Get-RoleCatalogBlock {
    param($Pairs)
    $rows = @($Pairs | Sort-Object Role, Fn | ForEach-Object { "  ('$($_.Role)', '$($_.Fn)')" })
    return ($rows -join ",`n")
}
