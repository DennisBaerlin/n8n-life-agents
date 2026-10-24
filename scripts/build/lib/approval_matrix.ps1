#Requires -Version 5.1
# =====================================================================================================
# approval_matrix.ps1 — DIE eine Lese- + Pruef-Stelle der Maker-Checker-Stufen (WS-5b; Phase D je Paket)
#
# Jedes Paket deklariert seine Gate-Aufrufer (Workflows, die agent.tool_human_approval rufen) im eigenen
# manifest.json-Block `approval_matrix` = { "_comment": …, "<workflow-name>": { "tier": …, "reason": … } }
# (docs/package-contract.md §3.10). Diese Funktion vereint die Bloecke ALLER Manifeste und prueft den Vertrag:
#   (a) tier ∈ self | owner_info | owner_approval | owner_only, reason nicht leer (self: s. $ApprovalTierRank);
#   (b) kein Workflow in zwei Bloecken;
#   (c) Verb-Praefix-Strenge: der tier ist mindestens so streng wie das Verb im Tool-Namen verlangt
#       (strenger erlaubt; ein neues Verb muss hier bewusst klassifiziert werden).
# Besitz (deklarierendes Paket == Paket des Workflows) pruefen die Konsumenten: build.ps1 gegen das Paket
# des erzeugenden Build-Defs, approval_lint gegen den Ablageort der gebauten Datei.
# Konsumenten: build.ps1 (Set-ApprovalTier, throw bei Verstoss) + scripts/approval_lint.ps1.
# Abhaengigkeitsfrei (nur Manifest-JSON rein, Objekte raus), damit der Lint sie dot-sourcen kann.
# =====================================================================================================

# self = die eigene Person bestaetigt, kein Owner beteiligt/informiert. NUR fuer Schreibwege, deren DB-fn die
# Selbst-Beschraenkung strukturell erzwingt (heute: agent.fn_set_own_context_facts, per_user fest) -> vom Verb-Floor
# ausgenommen; approval_lint prueft am GEBAUTEN Workflow, dass er ausschliesslich diese fn ruft und keinen scope-Eingang hat.
$ApprovalTierRank = @{ self = -1; owner_info = 0; owner_approval = 1; owner_only = 2 }
$ApprovalSelfFn   = 'agent.fn_set_own_context_facts'
# Verb -> Mindest-Rang. save/publish/invite = Plan-/Identitaets-Writes (owner_only); set/close/delete/… =
# Aenderung/Lebenszyklus (owner_approval); create/book/record/cancel/export = Anlegen/Buchen/Break-Glass (owner_info).
$ApprovalVerbFloor = @{ save = 2; publish = 2; invite = 2
                        set = 1; close = 1; delete = 1; void = 1; settle = 1; sell = 1; reconcile = 1; commit = 1
                        create = 0; book = 0; record = 0; cancel = 0; export = 0 }

function Get-ApprovalMatrix {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $entries = @{}; $errors = @()
    foreach ($mf in (Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json') | Sort-Object FullName)) {
        $m   = [System.IO.File]::ReadAllText($mf.FullName, $u8) | ConvertFrom-Json
        $pkg = [string]$m.name
        if ($null -eq $m.approval_matrix) { continue }
        foreach ($p in $m.approval_matrix.PSObject.Properties) {
            if ($p.Name -eq '_comment') { continue }
            $wf = $p.Name; $tier = [string]$p.Value.tier
            if (-not $ApprovalTierRank.ContainsKey($tier)) { $errors += "${pkg}: ungueltiger tier '$tier' fuer '$wf' (owner_only|owner_approval|owner_info|self)."; continue }
            if ([string]::IsNullOrWhiteSpace([string]$p.Value.reason)) { $errors += "${pkg}: '$wf' ohne reason."; continue }
            if ($entries.ContainsKey($wf)) { $errors += "'$wf' doppelt deklariert ($($entries[$wf].Package) und $pkg)."; continue }
            $verb = if ($wf -match 'tool_([a-z]+?)_') { $Matches[1] } elseif ($wf -match 'tool_([a-z]+)$') { $Matches[1] } else { $null }
            if (-not $verb -or -not $ApprovalVerbFloor.ContainsKey($verb)) {
                $errors += "${pkg}: unbekanntes Verb-Praefix in '$wf' (erlaubt: $(($ApprovalVerbFloor.Keys | Sort-Object) -join ', ')) — neues Verb bewusst klassifizieren."; continue
            }
            if ($tier -ne 'self' -and $ApprovalTierRank[$tier] -lt $ApprovalVerbFloor[$verb]) {
                $errors += "${pkg}: '$wf' ist als '$tier' SCHWAECHER getiert als der Verb-Praefix '$verb' verlangt — Schwaechen verboten, strenger waere ok."; continue
            }
            $entries[$wf] = [pscustomobject]@{ Tier = $tier; Package = $pkg }
        }
    }
    return [pscustomobject]@{ Entries = $entries; Errors = $errors }
}
