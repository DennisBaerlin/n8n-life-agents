# =====================================================================================================
# agent_routing.ps1 — DIE eine Lese- + Pruef-Stelle fuer provides.agents[] aller Paket-Manifeste (Phase C)
#
# Das Routing-Wissen eines Pakets lebt in seinen provides.agents-Objekten {name, router_description, order,
# fallback_for?} — der Core-Prompt kennt kein Paket. Diese Funktion liefert die nach order sortierte Routing-
# Liste (ohne 'orchestrator' = der Router routet nicht zu sich selbst) UND die Verstoesse gegen den Vertrag:
#   (a) jeder Agent ausser 'orchestrator' hat eine nicht-leere router_description (die frueher leere
#       finance-Sonderlocke kann nicht zurueckkehren);
#   (b) jedes agent.<x> in einer router_description ist ein deklarierter Agent irgendeines Manifests.
#       Gehoert <x> per Namens-Konvention (x == <pkg> oder <pkg>_…) zu einem VORHANDENEN Paket, ist ein
#       unbekannter Name ein Tippfehler -> Fehler; ebenso, wenn er einem deklarierten Agenten- oder vorhandenen
#       Paketnamen bis auf <= 2 Zeichen gleicht (Levenshtein; faengt agent.monitr / agent.finnce_advisor). Sonst verweist der Text auf
#       ein abwesendes (optionales, docs/package-contract.md §4.2) Paket -> nur Warnung (Phase D, Owner-Entscheid:
#       ein Repo ohne beliebiges Domaenen-Paket bleibt baubar; zur Laufzeit meldet der Verteiler "nicht installiert");
#   (c) fallback_for ist eine LISTE aus $AgentFallbackKinds, nicht am 'orchestrator', und jede Art
#       beansprucht hoechstens EIN Agent ueber alle Pakete (Dialogflow-/Rasa-"fallback", arch-challenge Phase C).
# Konsumenten: build.ps1 ($AgentRoutingList -> throw bei Verstoss = tiefste Durchsetzung, die Daten entstehen
# build-time), contract_lint.ps1 Check 19 (fruehere, freundliche Meldung + synthetische Negativ-Asserts) und
# (Phase E) die Test-Treiber ueber scripts/dev/test_n8n_state.ps1 Get-TestRouteAgent (kein Paket im Treiber).
# Bewusst abhaengigkeitsfrei (nur Manifest-JSON rein, Objekte raus), damit der Lint sie dot-sourcen kann.
# =====================================================================================================

# Erlaubte fallback_for-Arten (geschlossene Liste; eine neue Art = bewusster Diff hier + Satz in
# Get-AgentFallbackSentence + Core-Prompt-Regel).
$AgentFallbackKinds = @('attachment')

# Levenshtein-Abstand (klein, abhaengigkeitsfrei) — trennt Tippfehler von Verweisen auf abwesende Pakete.
function Get-EditDistance([string]$A, [string]$B) {
    $prev = 0..$B.Length
    for ($i = 1; $i -le $A.Length; $i++) {
        $cur = @($i) + @(0) * $B.Length
        for ($j = 1; $j -le $B.Length; $j++) {
            $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
            $cur[$j] = [Math]::Min([Math]::Min($cur[$j - 1] + 1, $prev[$j] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    return $prev[$B.Length]
}

# Der feste englische Satz (Schicht 1), den der Orchestrator-Build an die Tool-Beschreibung des
# Fallback-Agenten haengt — EINE Formulierung, Core-generisch.
function Get-AgentFallbackSentence([string]$Kind) {
    switch ($Kind) {
        'attachment' { return 'Default recipient for an attachment marker whose document type stays unclear from caption and conversation.' }
        default      { throw "agent_routing: keine Satz-Vorlage fuer fallback_for-Art '$Kind'." }
    }
}

# Die Eingabe von Get-AgentRouting: alle packages/*/manifest.json als @{ Path; Json }, nach Pfad sortiert.
# Encoding lokal (UTF-8 ohne BOM) — die Funktion darf sich nicht auf ein $Utf8NoBom des Aufrufers verlassen
# (Umlaute in router_description). contract_lint liest bewusst ueber sein eigenes Read-Manifest (sammelt ein
# unlesbares Manifest als Lint-Fehler, statt zu werfen).
function Get-PackageManifest([string]$RepoRoot) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    return @(Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json') | Sort-Object FullName | ForEach-Object {
        @{ Path = "packages/$($_.Directory.Name)/manifest.json"; Json = ([System.IO.File]::ReadAllText($_.FullName, $enc) | ConvertFrom-Json) }
    })
}

# Onboarding-Reihenfolge der Pakete (Menue + Dispatch) — ABGELEITET, nie deklariert: Pakete mit
# onboarding/sections.json; wer Daten/Dienste eines anderen Onboarding-Pakets konsumiert (consumes.reads
# '<schema>.<fn>', consumes.services '<pkg>:<dienst>'), kommt danach (dessen Daten liegen dann schon vor).
# Gleichstand: haushaltsweite Pakete vor persoenlichen (ein context_scopes-Eintrag mit scope per_user), dann Name.
# Zyklus -> throw. Core-Haushalt ist nicht dabei (Host-Sonderfall, steht immer vorn).
# Rueckgabe: @( [pscustomobject]@{ Package; Agent } ) in Onboarding-Reihenfolge (Agent = bare
# provides.onboarding.agent; contract_lint 11 erzwingt provides.onboarding <-> sections.json).
# Get-OnboardingPackageOrder liest das Repo; Get-OnboardingOrderFromManifests ist die reine Sortierung (Eingabe
# @{ Path; Json } NUR der Pakete mit sections.json) — contract_lint 21 fuettert sie mit synthetischen Faellen.
# Get-OnboardingSectionKeys — die Sektions-Keys EINES Pakets in Reihenfolge (ord) aus packages/<pkg>/onboarding/
# sections.json, fuer Tool-Beschreibungen (tool_set_onboarding_section): die Liste wird abgeleitet, nie abgetippt
# (die estate-Beschreibung nannte 6 von 7 Keys -> system_profile war nicht markierbar). Fehlt die Datei -> throw.
# -NonGatingOnly: nur die Sektionen mit "gates_advisor": false (offen sperren sie den Berater-Eingang nicht, z. B.
# der Monats-Check; fehlt das Feld = sperrt) -> build-fixe Ausnahmeliste des Onboarding-Gates im Berater.
function Get-OnboardingSectionKeys([string]$RepoRoot, [string]$Package, [switch]$NonGatingOnly) {
    $f = Join-Path $RepoRoot "packages\$Package\onboarding\sections.json"
    if (-not (Test-Path $f)) { throw "Get-OnboardingSectionKeys: $f fehlt" }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $secs = @(([System.IO.File]::ReadAllText($f, $enc) | ConvertFrom-Json) | Sort-Object ord)
    if ($NonGatingOnly) { $secs = @($secs | Where-Object { $_.PSObject.Properties.Name -contains 'gates_advisor' -and $_.gates_advisor -eq $false }) }
    return @($secs | ForEach-Object { [string]$_.key })
}

function Get-OnboardingPackageOrder([string]$RepoRoot) {
    $withSections = @(Get-PackageManifest $RepoRoot | Where-Object {
        Test-Path (Join-Path $RepoRoot "packages\$(($_.Path -split '/')[1])\onboarding\sections.json") })
    return @(Get-OnboardingOrderFromManifests $withSections)
}

function Get-OnboardingOrderFromManifests([array]$Manifests) {
    $pk = @{}
    foreach ($m in $Manifests) {
        $dir = ($m.Path -split '/')[1]
        $perUser = $false
        if ($null -ne $m.Json.context_scopes) {
            foreach ($p in $m.Json.context_scopes.PSObject.Properties) {
                if ($p.Value -is [pscustomobject] -and [string]$p.Value.scope -eq 'per_user') { $perUser = $true }
            }
        }
        $pk[$dir] = @{ Json = $m.Json; PerUser = $perUser; Deps = @() }
    }
    foreach ($name in @($pk.Keys)) {
        $c = $pk[$name].Json.consumes
        $refs = @()
        if ($null -ne $c) {
            $refs += @($c.reads | Where-Object { $_ -match '^([a-z][a-z0-9_]*)\.' } | ForEach-Object { ($_ -split '\.')[0] })
            $refs += @($c.services | Where-Object { $_ -match '^([a-z][a-z0-9_]*):' } | ForEach-Object { ($_ -split ':')[0] })
        }
        $pk[$name].Deps = @($refs | Where-Object { $_ -ne $name -and $pk.ContainsKey($_) } | Sort-Object -Unique)
    }
    $order = @()
    while ($order.Count -lt $pk.Count) {
        $ready = @($pk.Keys | Where-Object { $order -notcontains $_ } | Where-Object {
            $deps = $pk[$_].Deps; @($deps | Where-Object { $order -notcontains $_ }).Count -eq 0 })
        if ($ready.Count -eq 0) {
            $rest = @($pk.Keys | Where-Object { $order -notcontains $_ } | Sort-Object)
            throw ("Onboarding-Reihenfolge: zyklische consumes-Abhaengigkeit zwischen " + ($rest -join ', '))
        }
        $order += @($ready | Sort-Object @{ Expression = { $pk[$_].PerUser } }, @{ Expression = { $_ } })[0]
    }
    return @($order | ForEach-Object {
        $onb = $pk[$_].Json.provides.onboarding
        [pscustomobject]@{ Package = $_; Agent = $(if ($null -ne $onb) { [string]$onb.agent } else { '' }) }
    })
}

# Name des Route-Tool-Nodes, den der Orchestrator-Build je Agent erzeugt (n8n zeigt ihn im runData unter
# metadata.subNodeExecutionData.actions[].nodeName) — EINE Adresse fuer Orchestrator-Def und Test-Treiber.
function Get-AgentCallNodeName([string]$AgentName) { return "Call 'agent.$AgentName'" }

# $Manifests = Liste von @{ Path = <Anzeige-Pfad>; Json = <ConvertFrom-Json-Objekt> }.
# Rueckgabe: @{ List = <sortierte Routing-Eintraege>; Errors = <string[]>; Warnings = <string[]> }.
function Get-AgentRouting($Manifests) {
    $errors   = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $present  = @($Manifests | ForEach-Object { [string]$_.Json.name } | Where-Object { $_ })
    $entries  = @()
    $declared = @{}
    foreach ($m in $Manifests) {
        foreach ($a in @($m.Json.provides.agents)) {
            if ($null -eq $a) { continue }
            $n = if ($a -is [string]) { $a } else { [string]$a.name }
            if (-not [string]::IsNullOrEmpty($n)) { $declared[$n] = $true }
        }
    }
    $claimed = @{}
    foreach ($m in $Manifests) {
        $pkg = [string]$m.Json.name
        foreach ($a in @($m.Json.provides.agents)) {
            if ($null -eq $a) { continue }
            if ($a -is [string]) {
                $errors.Add("$($m.Path): provides.agents-Eintrag '$a' ist ein String - erwartet ein Objekt {name, router_description, order}.")
                continue
            }
            $name = [string]$a.name
            if ([string]::IsNullOrEmpty($name)) { $errors.Add("$($m.Path): provides.agents-Eintrag ohne name."); continue }
            $desc = [string]$a.router_description
            $isRouter = ($name -eq 'orchestrator')

            # (c) fallback_for: fehlend/null = keine; sonst MUSS es eine JSON-Liste sein (ein nackter String
            # wuerde in PowerShell sonst still zeichenweise bzw. als Ein-Element-Wert durchgehen).
            $kinds = @()
            $hasFb = $a.PSObject.Properties.Name -contains 'fallback_for'
            if ($hasFb -and $null -ne $a.fallback_for) {
                if ($a.fallback_for -isnot [System.Array]) {
                    $errors.Add("$($m.Path): agent '$name' fallback_for muss eine Liste sein (z. B. [""attachment""]), ist '$($a.fallback_for)'.")
                } else {
                    foreach ($k in $a.fallback_for) {
                        $ks = [string]$k
                        if ($AgentFallbackKinds -notcontains $ks) {
                            $errors.Add("$($m.Path): agent '$name' fallback_for-Art '$ks' unbekannt (erlaubt: $($AgentFallbackKinds -join ', ')).")
                        } elseif ($kinds -contains $ks) {
                            $errors.Add("$($m.Path): agent '$name' nennt fallback_for-Art '$ks' doppelt.")
                        } else {
                            $kinds += $ks
                        }
                    }
                }
            }
            if ($isRouter) {
                if ($kinds.Count -gt 0) { $errors.Add("$($m.Path): 'orchestrator' darf kein fallback_for tragen (der Router routet nicht zu sich selbst).") }
                continue
            }
            foreach ($k in $kinds) {
                if ($claimed.ContainsKey($k)) {
                    $errors.Add("$($m.Path): fallback_for-Art '$k' wird von '$name' UND '$($claimed[$k])' beansprucht - hoechstens ein Agent je Art.")
                } else { $claimed[$k] = $name }
            }

            # (a) Pflicht-Beschreibung
            if ([string]::IsNullOrWhiteSpace($desc)) {
                $errors.Add("$($m.Path): agent '$name' hat keine router_description - das Routing-Wissen eines Agenten lebt dort (Core-Prompt kennt kein Paket).")
            }
            # (b) Referenz-Integritaet: agent.<x> (greedy; ein satzschliessender Punkt gehoert nicht zum Namen)
            foreach ($rm in [regex]::Matches($desc, 'agent\.([a-z_]+)')) {
                $ref = $rm.Groups[1].Value
                if (-not $declared.ContainsKey($ref)) {
                    $ownPkg = @($present | Where-Object { $ref -eq $_ -or $ref -like "${_}_*" })
                    $near   = @(@($declared.Keys) + @($present) | Where-Object { (Get-EditDistance $ref $_) -le 2 })
                    $refPkg = ($ref -split '_')[0]
                    $nearP  = @($present | Where-Object { (Get-EditDistance $refPkg $_) -le 2 })
                    if ($ownPkg.Count -gt 0 -or $near.Count -gt 0 -or $nearP.Count -gt 0) {
                        $hint = @($ownPkg + $near + $nearP | Select-Object -Unique) -join ', '
                        $errors.Add("$($m.Path): router_description von '$name' verweist auf agent.$ref - kein deklarierter Agent (aehnlich/vorhanden: $hint -> Tippfehler?).")
                    } else {
                        $warnings.Add("$($m.Path): router_description von '$name' verweist auf agent.$ref - kein Paket dafuer im Repo (optionale Abhaengigkeit; Text ggf. anpassen).")
                    }
                }
            }

            $entries += [pscustomobject]@{
                Name = $name; Description = $desc; Order = [int]$a.order
                Package = $pkg; FallbackFor = $kinds
            }
        }
    }
    return @{ List = @($entries | Sort-Object Order, Name); Errors = @($errors); Warnings = @($warnings | Select-Object -Unique) }
}
