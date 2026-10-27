#Requires -Version 5.1
# Gemeinsame Builder-Helper fuer die agent.finance.tool_*-Generatoren.
# Wird von build.ps1 dot-gesourct (NICHT &/Import-Module),
# damit Build-Pg/Build-* die Script-Scope-Creds ($CRED_POSTGRES/$CRED_TELEGRAM) sehen.

# ============================================================
# COMMON BUILDERS
# ============================================================

# Platzhalter-ID fuer Knoten/webhookId/innere ids: Save-WorkflowFile (Set-StableNodeIds) ersetzt GENAU die hier
# ausgegebenen Werte deterministisch (UUID-v5 aus Workflow- + Knoten-Name). Eine feste GUID im Builder bricht den Build.
$script:NewIdIssued = New-Object 'System.Collections.Generic.HashSet[string]'
function New-Id { $g = [guid]::NewGuid().ToString(); [void]$script:NewIdIssued.Add($g); $g }

# Start trigger with typed inputs (n8n 2.x format, executeWorkflowTrigger 1.1; geprueft bis 2.44.4)
function Build-Trigger {
    param([string[]]$InputNames, [int[]]$Pos = @(0, 0))
    # chat_id wird IMMER mitgefuehrt (Agent -> Tool -> Gate): das Gate braucht es als Telegram-
    # Empfaenger fuer den sendAndWait-Send. Jeder Aufrufer reicht chat_id durch.
    if ($InputNames -notcontains 'chat_id') { $InputNames = @($InputNames) + 'chat_id' }
    [ordered]@{
        parameters = [ordered]@{
            workflowInputs = [ordered]@{
                values = @($InputNames | ForEach-Object { [ordered]@{ name = $_ } })
            }
        }
        type = 'n8n-nodes-base.executeWorkflowTrigger'
        typeVersion = 1.1
        position = $Pos
        id = (New-Id)
        name = 'Start'
    }
}

# Phase B: DER EINE Schutz fuer JSON aus Modell-Eingaben (Tool-Felder kommen vom Agenten als JSON-STRING).
# Get-GuardedJsonExpr '<JS-Ausdruck, der werfen kann (JSON.parse ...)>' -> IIFE, die den Ausdruck auswertet und bei
# ungueltigem JSON den Nicht-Objekt-/Nicht-Array-Sentinel '__invalid_json__' liefert. Die Ziel-fn prueft den Typ
# (jsonb_typeof IS DISTINCT FROM 'object'/'array') und lehnt mit {ok:false} ab -> Tool-Fehler als DATEN statt
# Execution-Abbruch + Owner-Alert (Regel *Tool-Fehler & Retry-Stuerme*). Vorher: rohes JSON.parse in den finance-
# Import-/Reconcile-Tools (Absturz bei kaputtem JSON); Muster aus agent.tool_set_context_facts (Phase A) — jetzt geteilt.
# Fuer Build-Pg-Param-Ausdruecke (roher JS-Ausdruck, ohne '={{'); die IIFE ist n8n-Expression-tauglich (s. Fmt-MoneyJs).
$script:InvalidJsonSentinel = '__invalid_json__'
function Get-GuardedJsonExpr([string]$Body) {
    return "(() => { try { return $Body; } catch (e) { return '$($script:InvalidJsonSentinel)'; } })()"
}

# Postgres node with parameterized query.
# $Params is an array of n8n expression strings (e.g. "={{ $('Start').item.json.foo }}");
# they bind to $1, $2, ... in $Query in order.
function Build-Pg {
    # STANDARD fuer ALLE Postgres-Nodes: EIN jsonb-Parameter ($1). $Params ist eine benannte
    # [ordered]@{ feld = '<roher n8n/JS-Ausdruck>' }; Build-Pg baut daraus queryReplacement =
    # '={{ JSON.stringify({ feld: <expr>, ... }) }}'. Die Query referenziert ($1::jsonb)->>'feld'
    # (mit Cast: (($1::jsonb)->>'feld')::numeric) bzw. fn(... $1::jsonb).
    # Begruendung: ein JSON-Objekt ist nie leer und splittet nie -> kein $1-Drop / Parameter-Shift
    # (siehe CLAUDE.md Build-Gotchas). Loest Sentinel + positionale Komma-Parameter komplett ab.
    param([string]$Name, [int[]]$Pos, [string]$Query, $Params = $null)
    $opts = @{}
    if ($null -ne $Params -and $Params.Count -gt 0) {
        $pairs = foreach ($k in $Params.Keys) { "${k}: " + $Params[$k] }
        $opts = [ordered]@{ queryReplacement = '={{ JSON.stringify({ ' + ($pairs -join ', ') + ' }) }}' }
    }
    [ordered]@{
        parameters = [ordered]@{
            operation = 'executeQuery'
            query = $Query
            options = $opts
        }
        type = 'n8n-nodes-base.postgres'
        typeVersion = 2.6
        position = $Pos
        id = (New-Id)
        name = $Name
        credentials = @{ postgres = $CRED_POSTGRES }
    }
}

# Personen-Feld eines Write-Tools aufloesen (Name/Vorname/Alias -> person_id-Slug) — der EINE Baustein aller
# 'Resolve Person'-Knoten (Finanz + Nachlass). chat_id des Absenders geht immer mit: ein Selbstbezug ("ich", "mein",
# "me", "나") meint die Person, die gerade chattet (core.fn_resolve_person, core:V033). Ausgang wie bisher
# {person_id, full_name, hit_count, candidates}; leeres Feld = kein Name (Haushalt/unveraendert).
function Build-ResolvePerson {
    param([string]$Name, [int[]]$Pos, [string]$Field, [string]$StartNode = 'Start')
    Build-Pg $Name $Pos `
        "=SELECT person_id, full_name, hit_count, candidates FROM core.fn_resolve_person(NULLIF((`$1::jsonb)->>'$Field', ''), (`$1::jsonb)->>'chat_id');" `
        ([ordered]@{ $Field = "`$('$StartNode').item.json.$Field"; chat_id = "String(`$('$StartNode').item.json.chat_id || '')" })
}

# IF node — comparison with strict typing.
# rightValue MUST be emitted with the operator's real type: under strict typeValidation n8n rejects a
# string '1'/'true' against a number/boolean leftValue ("Wrong type: 'true' is a string ...").
function Build-If {
    param([string]$Name, [int[]]$Pos, [string]$Left, [string]$Right,
          [string]$Op = 'equals', [string]$Type = 'number')
    # n8n IF v2.2 (Filter-Komponente) erwartet KANONISCHE Operation-Werte: gt/gte/lt/lte.
    # Lesbare Aliase werden hier uebersetzt — sonst akzeptiert n8n den Wert beim Publish, routet aber
    # zur LAUFZEIT still auf FALSE (z. B. 'largerEqual' tat genau das -> stille no-op-Gates).
    $opAliases = @{ largerEqual = 'gte'; smallerEqual = 'lte'; larger = 'gt'; smaller = 'lt' }
    if ($opAliases.ContainsKey($Op)) { $Op = $opAliases[$Op] }
    # WHITELIST statt Vertrauen: n8n validiert Operation-Strings beim Publish NICHT (unbekannter
    # Wert = stilles FALSE zur Laufzeit). Ein Tippfehler bricht deshalb den BUILD, nicht den Prod-Pfad.
    $validOps = @{
        string  = @('equals','notEquals','contains','notContains','startsWith','notStartsWith',
                    'endsWith','notEndsWith','regex','notRegex','exists','notExists','empty','notEmpty')
        number  = @('equals','notEquals','gt','gte','lt','lte','exists','notExists')
        boolean = @('true','false','equals','notEquals','exists','notExists')
    }
    if (-not $validOps.ContainsKey($Type)) {
        throw "Build-If '$Name': unbekannter Condition-Typ '$Type' (erlaubt: $($validOps.Keys -join ', ')). Neuen Typ bewusst in die Whitelist aufnehmen."
    }
    if ($validOps[$Type] -notcontains $Op) {
        throw "Build-If '$Name': Operation '$Op' ist kein kanonischer n8n-Wert fuer Typ '$Type' (erlaubt: $($validOps[$Type] -join ', ')). n8n wuerde das beim Publish schlucken und zur Laufzeit still auf FALSE routen."
    }
    # typeValidation:strict + string-Operator: ein nicht-String-leftValue (z. B. numerische Telegram-
    # chat_id) wirft zur LAUFZEIT NodeOperationError ("Wrong type: ... is a number"). Builder-Gesetz:
    # string-typisierte Expressions werden automatisch String(<expr> || '')-gewrappt — null/undefined
    # wird '' (NICHT 'null'/'undefined'), damit "leer = nicht gefunden"-Vergleiche intakt bleiben.
    # (|| statt ??: repo-weit erprobte n8n-Expression-Syntax; 0/'' sind hier nie gueltige Werte.)
    if ($Type -eq 'string' -and $Left -match '^=\{\{\s*(.+?)\s*\}\}$' -and $Left -notmatch 'String\(') {
        $Left = '={{ String((' + $Matches[1] + ") || '') }}"
    }
    $rightTyped = switch ($Type) {
        'boolean' { ($Right -eq 'true') }
        'number'  { if ($Right -match '^-?\d+$') { [int]$Right } else { [double]$Right } }
        default   { $Right }
    }
    [ordered]@{
        parameters = [ordered]@{
            conditions = [ordered]@{
                options = [ordered]@{ caseSensitive = $true; typeValidation = 'strict'; version = 2 }
                conditions = @(
                    [ordered]@{
                        id = (New-Id)
                        leftValue = $Left
                        rightValue = $rightTyped
                        operator = [ordered]@{ type = $Type; operation = $Op }
                    }
                )
                combinator = 'and'
            }
            options = @{}
        }
        type = 'n8n-nodes-base.if'
        typeVersion = 2.2
        position = $Pos
        id = (New-Id)
        name = $Name
    }
}

# Switch node (v3.4) — N benannte Regeln + Fallback-Output 'extra'. Jede Regel ist eine Hashtable
# @{ Left=<n8n-Expr>; Type='string'|'boolean'|'number'; Right=<Wert>; OutputKey=<Name>; Op='equals' }.
# Op default 'equals'; 'exists'/'notExists' = Feld-Vorhandensein (singleValue, rightValue ''). rightValue
# wird wie in Build-If typgerecht emittiert (boolean -> echtes $true, number -> Zahl) — ein als String
# emittiertes $true crasht den strict-Switch ZUR LAUFZEIT still auf FALSE (Build-Gotcha, real getroffen).
# leftValue bleibt VERBATIM (kein String()-Wrap: 'exists' braucht das rohe Feld; die deployten Switches
# wrappen nicht). rules.values MUSS Array-Form behalten (Publish-Gate-Gotcha) -> hier via @(...) erzwungen;
# die N+1 Output-Connections (Regeln in Reihenfolge + 'extra'-Fallback als Index N) baut der Aufrufer mit
# dem Komma-Operator (siehe packages/CLAUDE.md *Filter-/Selector-conditions ... Array-Form*).
function Build-Switch {
    param([string]$Name, [int[]]$Pos, [array]$Rules)
    $vals = @($Rules | ForEach-Object {
        $r  = $_
        $op = if ($r.Op) { $r.Op } else { 'equals' }
        $cond = [ordered]@{ id = (New-Id); leftValue = $r.Left }
        if ($op -in @('exists', 'notExists')) {
            $cond['operator']   = [ordered]@{ operation = $op; singleValue = $true; type = $r.Type }
            $cond['rightValue'] = ''
        } else {
            $cond['operator']   = [ordered]@{ operation = $op; type = $r.Type }
            $cond['rightValue'] = switch ($r.Type) {
                'boolean' { if ($r.Right -is [bool]) { $r.Right } else { ("$($r.Right)" -eq 'true') } }
                'number'  { if ("$($r.Right)" -match '^-?\d+$') { [int]$r.Right } else { [double]$r.Right } }
                default   { [string]$r.Right }
            }
        }
        [ordered]@{
            conditions = [ordered]@{
                combinator = 'and'
                conditions = @( $cond )
                options    = [ordered]@{ caseSensitive = $true; leftValue = ''; typeValidation = 'strict'; version = 3 }
            }
            outputKey    = $r.OutputKey
            renameOutput = $true
        }
    })
    [ordered]@{
        parameters = [ordered]@{
            options = [ordered]@{ fallbackOutput = 'extra' }
            rules   = [ordered]@{ values = @($vals) }
        }
        type = 'n8n-nodes-base.switch'
        typeVersion = 3.4
        position = $Pos
        id = (New-Id)
        name = $Name
    }
}

# Structured tool error (Set node) — returns { ok:false, error } as DATA, not a thrown error.
# Best practice: the agent reads the message and asks the user / reports, WITHOUT a retry storm.
# Use this for user-correctable / validation conditions. Reserve Build-Err (Stop and Error) for
# genuine exceptions (e.g. a DB write failing after approval).
function Build-ToolError {
    param([string]$Name, [int[]]$Pos, [string]$MessageExpr)
    Build-Set $Name $Pos @(
        ,@('ok','false','boolean')
        ,@('error', $MessageExpr, 'string')
    )
}

# Pflicht-Zeile eines Lese-Knotens (Build-Gotcha "SELECT ohne Treffer = kein Item"): ein Tool, dessen erster Read den
# Ziel-Datensatz per id/Name holt, endete bei 0 Treffern still ("The workflow did not return a response", Mock-Tier
# 2026-10-24: tool_void_transaction mit unbekannter id). Setzt alwaysOutputData am Read (n8n liefert dann ein leeres
# Item) und baut 'Found?' (Spalte $KeyField vorhanden) + ToolError mit $NotFoundExpr. Verdrahtung beim Aufrufer:
# Read -> $g.If; $g.If [0] -> weiter, [1] -> $g.Err. Liefert @{ If; Err }.
function New-RequiredRowGate {
    param([Parameter(Mandatory)]$Read, [Parameter(Mandatory)][string]$KeyField, [Parameter(Mandatory)][string]$NotFoundExpr,
          [int[]]$IfPos, [int[]]$ErrPos, [string]$IfName = 'Found?', [string]$ErrName = 'Not found')
    $Read['alwaysOutputData'] = $true
    @{
        If  = Build-If $IfName $IfPos "={{ `$json.$KeyField !== undefined && `$json.$KeyField !== null }}" 'true' 'equals' 'boolean'
        Err = Build-ToolError $ErrName $ErrPos $NotFoundExpr
    }
}

# Abbruch-Ergebnis eines Write-Tools nach "Abbrechen" am HITL-Gate: {ok:false, cancelled:true, message}. Die Meldung
# liest NUR das aufrufende LLM (Tool-Ergebnis = Modell-Schicht -> englisch laut Sprachpolitik; die Antwort an den
# Nutzer formuliert der Agent in dessen Sprache). $Action = englische Nominalphrase ("the account creation").
# Das Retry-Verbot steht bewusst IM Ergebnis, nicht nur im Prompt: live (2026-10-22) rief der Finanz-Agent nach
# "Abbrechen" create_account im selben Lauf mit identischen Werten erneut auf -> neue Karte je Abbruch.
function Build-ToolCancelled {
    param([string]$Name, [int[]]$Pos, [Parameter(Mandatory)][string]$Action)
    if ($Action -match "['""]" -or $Action -match '[^\x20-\x7E]') { throw "Build-ToolCancelled '$Name': -Action nur ASCII ohne Anfuehrungszeichen (englische Modell-Meldung)" }
    Build-Set $Name $Pos @(
        ,@('ok','false','boolean')
        ,@('cancelled','true','boolean')
        ,@('message', "The user cancelled $Action. Do NOT call this tool again in this turn. Tell the user it was cancelled and ask what they want to change.", 'string')
    )
}

# Datums-Hinweis fuer $fromAI-Parameter (Modell-Schicht -> englisch): das LLM gibt eine relative Angabe ROH weiter,
#   die Write-fn rechnet sie (core.fn_resolve_input_dates -> core.fn_resolve_date). Nennt genau deren Grammatik
#   (Ziffern, kein "a week"/"next month"); was nicht passt, fragt der Agent nach (Prompt-Regel des Agenten). Die
#   Ablehnung der fn ({ok:false, code:'invalid_date'}) verweist nur hierher, wiederholt die Grammatik nicht.
#   Die EINE Adresse fuer den Text: Aufrufer setzen ihn per ('<Feld> (' + (Get-DateParamHint) + '), …') zusammen.
function Get-DateParamHint {
    'YYYY-MM-DD or relative to today exactly as: today, yesterday, tomorrow, in 2 weeks, -3 days, 2 months ago, next friday, last monday (counts as digits: in 1 week, not in a week) - never compute a date yourself'
}

# Ausdruck fuer eine Karten-Zeile mit einem Datum, das die Write-fn aufgeloest hat: r.effective.<Key> aus dem Probelauf
#   (New-FnWriteGate), sonst der Roh-Wert aus Start (fn ohne effective fuer diesen Key, z. B. leeres Feld).
#   Karte = Write: der Gate-Write bekommt dasselbe effective (Post-State-Vertrag).
function Get-DryEffectiveExpr {
    param([Parameter(Mandatory)][string]$Key, [string]$DryName = 'Dry run', [string]$StartName = 'Start')
    if ($Key -notmatch '^[a-z_]+$') { throw "Get-DryEffectiveExpr: -Key '$Key' muss snake_case sein" }
    "((`$('$DryName').item.json.r.effective || {}).$Key || `$('$StartName').item.json.$Key)"
}

# Das Feld-Objekt einer Karte = genau der Payload des Gate-Writes: Start-Felder || r.effective des Probelaufs
#   (New-FnWriteGate mischt dasselbe in den echten Write). Fuer geteilte Kartenzeilen (-S in Get-FinanceHitlLines),
#   damit jedes Datum/jeder Default so erscheint, wie er gespeichert wird.
function Get-WritePayloadExpr {
    param([string]$DryName = 'Dry run', [string]$StartName = 'Start')
    "(Object.assign({}, `$('$StartName').item.json, `$('$DryName').item.json.r.effective || {}))"
}

# New-FnWriteGate — "DB ist das Gesetz": Probelauf der Write-fn VOR der HITL-Karte + der echte Write, aus EINER
#   Param-Map (Build-Pg-Form). Liefert vier Knoten + Namen fuer die Verdrahtung:
#     Dry    'Dry run'          SELECT core.fn_dry_run('<Fn>(jsonb)'::regprocedure, $1) AS r   (immer zurueckgerollt)
#     DryOk  'Dry run ok?'      IF r.ok -> true: weiter zur Karte | false: Reject
#     Reject 'Dry run rejected' {ok:false, card_sent:false, error, code, candidates} an den Agenten — KEINE Karte
#     Write  <WriteName>        SELECT <WriteSelect> FROM <Fn>(params || r.effective) AS r      (nach dem Gate)
#   r.effective = Werte, die die fn selbst gesetzt hat (Default-Datum, Gebuehr 0, abgeleitete Konten): sie gehen FEST
#   in den echten Write, damit Karte und Buchung dasselbe zeigen (auch bei einem Tipp nach Mitternacht).
#   CardLinesExpr = r.card_lines (Hinweis-Zeilen {kind:'note'} der fn) fuer New-HitlSummary -LinesExpr.
#   Eine echte Exception der fn bricht schon den Probelauf ab (errorWorkflow alarmiert), wie vorher den Write.
#   Der echte Write prueft erneut (Bestand kann sich zwischen Karte und Tipp aendern) -> 'Write ok?' bleibt im Tool.
function New-FnWriteGate {
    param(
        [Parameter(Mandatory)][string]$Fn,
        [Parameter(Mandatory)]$Params,
        [Parameter(Mandatory)][string]$WriteName,
        [Parameter(Mandatory)][string]$WriteSelect,
        [Parameter(Mandatory)][int[]]$DryPos,
        [Parameter(Mandatory)][int[]]$WritePos,
        [string]$DryName = 'Dry run',
        [string]$DryOkName = 'Dry run ok?',
        [string]$RejectName = 'Dry run rejected'
    )
    if ($Fn -notmatch '^[a-z_]+\.fn_[a-z0-9_]+$') { throw "New-FnWriteGate: -Fn '$Fn' muss <schema>.fn_<name> sein (Build-Konstante)" }
    if ($Params.Contains('_effective')) { throw "New-FnWriteGate '$Fn': '_effective' ist reserviert" }
    $dry = Build-Pg $DryName $DryPos "=SELECT core.fn_dry_run('$Fn(jsonb)'::regprocedure, `$1::jsonb) AS r;" $Params
    $D = "`$('$DryName').item.json.r"
    $dryOk = Build-If $DryOkName @(($DryPos[0] + 220), $DryPos[1]) "={{ $D.ok }}" 'true' 'equals' 'boolean'
    $reject = Build-Set $RejectName @(($DryPos[0] + 440), ($DryPos[1] + 200)) @(
        ,@('ok', 'false', 'boolean')
        ,@('card_sent', 'false', 'boolean')
        ,@('error', "={{ $D.reason || $D.error || 'The database rejected this entry.' }}", 'string')
        ,@('code', "={{ $D.code || '' }}", 'string')
        ,@('candidates', "={{ $D.candidates || [] }}", 'array')
    )
    $wp = [ordered]@{}
    foreach ($k in $Params.Keys) { $wp[$k] = $Params[$k] }
    $wp['_effective'] = "($D.effective || null)"
    $write = Build-Pg $WriteName $WritePos `
        "=SELECT $WriteSelect FROM $Fn((`$1::jsonb - '_effective') || COALESCE(NULLIF((`$1::jsonb)->'_effective', 'null'::jsonb), '{}'::jsonb)) AS r;" $wp
    @{
        Dry = $dry; DryOk = $dryOk; Reject = $reject; Write = $write
        DryName = $DryName; DryOkName = $DryOkName; RejectName = $RejectName; WriteName = $WriteName
        CardLinesExpr = "($D.card_lines || [])"
        Nodes = @($dry, $dryOk, $reject, $write)
    }
}

# Stop and Error node — bubbles error up to the calling Finance Agent (ONLY for true exceptions)
function Build-Err {
    param([string]$Name, [int[]]$Pos, [string]$Message)
    [ordered]@{
        parameters = [ordered]@{
            errorMessage = $Message
        }
        type = 'n8n-nodes-base.stopAndError'
        typeVersion = 1
        position = $Pos
        id = (New-Id)
        name = $Name
    }
}

# Return node (Set) — builds the success-JSON
# $Assignments is an array of @(name, value, type) tuples; -Name fuer einen zweiten Erfolgs-Ausgang im selben Workflow
function Build-Return {
    param([int[]]$Pos, [array]$Assignments, [string]$Name = 'Return')
    $list = @($Assignments | ForEach-Object {
        [ordered]@{ id = (New-Id); name = $_[0]; value = $_[1]; type = $_[2] }
    })
    [ordered]@{
        parameters = [ordered]@{
            assignments = @{ assignments = $list }
            options = @{}
        }
        type = 'n8n-nodes-base.set'
        typeVersion = 3.4
        position = $Pos
        id = (New-Id)
        name = $Name
    }
}

# Connection edge helper
function E {
    param([string]$Node, [string]$Type = 'main', [int]$Index = 0)
    @{ node = $Node; type = $Type; index = $Index }
}

# Sticky note — makes DB-side automatic effects (trigger / GENERATED / CHECK) visible on the canvas.
# This is the rendered "effect spec": every place the DB does work this workflow does NOT do gets a note,
# so the n8n workflow stays the complete, single source of truth for a tool incl. its DB-side steps.
# Content is German (Sprachpolitik Layer 3 = dev docs); ASCII-safe (no umlauts/EUR sign) like the rest
# of this script. Color 4 default; $Header defaults to "DB-Automatik" (Tool-Stickys, die DB-Effekte
# erklaeren). Flow-/Ablauf-Stickys (z. B. die deterministischen Subs) uebergeben einen eigenen Header
# (z. B. 'Ablauf'), damit das Canvas-Label nicht faelschlich "DB-Automatik" behauptet (Review L10).
function Build-Sticky {
    param([string]$Name, [int[]]$Pos, [string]$Title, [string]$Body, [int]$Height = 160, [int]$Width = 320, [string]$Header = 'DB-Automatik')
    [ordered]@{
        parameters = [ordered]@{
            content = "## $Header`n**$Title**`n`n$Body"
            height  = $Height
            width   = $Width
            color   = 4
        }
        type = 'n8n-nodes-base.stickyNote'
        typeVersion = 1
        position = $Pos
        id = (New-Id)
        name = $Name
    }
}

# executeWorkflow call node. $Inputs is an ordered hashtable name->expression.
function Build-CallWorkflow {
    param([string]$Name, [int[]]$Pos, [string]$WorkflowId, [string]$CachedName, $Inputs)
    [ordered]@{
        parameters = [ordered]@{
            workflowId = [ordered]@{
                __rl = $true
                value = $WorkflowId
                mode = 'list'
                cachedResultUrl = "/workflow/$WorkflowId"
                cachedResultName = $CachedName
            }
            workflowInputs = [ordered]@{
                mappingMode = 'defineBelow'
                value = $Inputs
                matchingColumns = @()
                schema = @()
                attemptToConvertTypes = $false
                convertFieldsToString = $true
            }
            options = @{}
        }
        type = 'n8n-nodes-base.executeWorkflow'
        typeVersion = 1.2
        position = $Pos
        id = (New-Id)
        name = $Name
    }
}

# New-WebhookNode — produktiver HTTP-Eingang (Webhook v2, n8n 2.45.4). -Path ist PFLICHT ein Deploy-Platzhalter
#   (__<NAME>_PATH__, deploy_workflows.sh setzt die Adresse je Instanz aus INGRESS_ID_KEY ein; workflow_lint prueft es),
#   nie ein Literal: das Repo ist oeffentlich. -Methods > 1 -> multipleMethods, ein Ausgang je Methode in dieser
#   Reihenfolge. Antwort immer ueber einen New-RespondNode (responseMode responseNode). Ein text/plain-Body kommt als
#   String in $json.body an (n8n body-parser), JSON als Objekt.
function New-WebhookNode {
    param([string]$Name, [int[]]$Pos, [Parameter(Mandatory)][string]$Path, [string[]]$Methods = @('POST'))
    if ($Path -notmatch '^__[A-Z][A-Z0-9_]*_PATH__$') { throw "New-WebhookNode '$Name': -Path muss ein Deploy-Platzhalter __<NAME>_PATH__ sein, kein Literal ('$Path')." }
    $p = [ordered]@{}
    if ($Methods.Count -gt 1) { $p['multipleMethods'] = $true; $p['httpMethod'] = @($Methods) }
    else { $p['httpMethod'] = $Methods[0] }
    $p['path'] = $Path; $p['responseMode'] = 'responseNode'; $p['options'] = [ordered]@{}
    [ordered]@{
        parameters  = $p
        type        = 'n8n-nodes-base.webhook'
        typeVersion = 2
        position    = $Pos
        id          = (New-Id)
        name        = $Name
        webhookId   = (New-Id)
    }
}

# New-RespondNode — Antwort eines New-WebhookNode (Respond to Webhook 1.5). -Kind text: -Body ist ein STATISCHER
#   String (kein '='-Ausdruck -> n8n wertet ihn nie aus, '{{' darin ist harmlos); -Kind json: -Body ist ein n8n-Ausdruck,
#   der ein Objekt liefert. -Headers = geordnete Name->Wert-Map (Content-Type immer explizit, die Node-Doku verlangt es).
function New-RespondNode {
    param([string]$Name, [int[]]$Pos, [ValidateSet('text', 'json')][string]$Kind, [Parameter(Mandatory)][string]$Body,
          [System.Collections.IDictionary]$Headers = [ordered]@{})
    if ($Kind -eq 'text' -and $Body.StartsWith('=')) { throw "New-RespondNode '$Name': -Kind text braucht einen statischen Body (beginnt mit '=')." }
    if ($Kind -eq 'json' -and -not $Body.StartsWith('={{')) { throw "New-RespondNode '$Name': -Kind json braucht einen Ausdruck '={{ ... }}'." }
    $entries = @($Headers.Keys | ForEach-Object { [ordered]@{ name = [string]$_; value = [string]$Headers[$_] } })
    [ordered]@{
        parameters  = [ordered]@{
            respondWith  = $Kind
            responseBody = $Body
            options      = [ordered]@{ responseHeaders = [ordered]@{ entries = $entries } }
        }
        type        = 'n8n-nodes-base.respondToWebhook'
        typeVersion = 1.5
        position    = $Pos
        id          = (New-Id)
        name        = $Name
    }
}

# Set node helper (named) — assignments is array of @(name, value, type)
function Build-Set {
    param([string]$Name, [int[]]$Pos, [array]$Assignments)
    $list = @($Assignments | ForEach-Object {
        [ordered]@{ id = (New-Id); name = $_[0]; value = $_[1]; type = $_[2] }
    })
    [ordered]@{
        parameters = [ordered]@{ assignments = @{ assignments = $list }; options = @{} }
        type = 'n8n-nodes-base.set'
        typeVersion = 3.4
        position = $Pos
        id = (New-Id)
        name = $Name
    }
}

# Wait node (v1.1) "After Time Interval" in Sekunden — NUR kurze Pausen im laufenden Prozess. n8n 2.44.4 schlaeft
# unter MAX_IN_PROCESS_WAIT_MS (65 000 ms, packages/workflow/src/constants.ts) direkt im Prozess
# (base-execute-context.ts putExecutionToWait); darueber lagert es die Execution in die DB aus und der WaitTracker
# weckt sie erst bei seinem 60-s-Poll -> eine "kurze" Pause koennte still bis zu einer Minute dauern. Daher bricht
# der Build ab 60 s ab (laengere Pausen sind ein eigener, bewusster Bau).
function Build-WaitSeconds {
    param([string]$Name, [int[]]$Pos, [double]$Seconds)
    if ($Seconds -le 0 -or $Seconds -ge 60) {
        throw "Build-WaitSeconds '$Name': $Seconds s liegt nicht in (0, 60) — nur kurze In-Prozess-Pausen (n8n schlaeft unter 65 s im Prozess)."
    }
    [ordered]@{
        parameters = [ordered]@{ amount = $Seconds; unit = 'seconds' }
        type = 'n8n-nodes-base.wait'
        typeVersion = 1.1
        position = $Pos
        id = (New-Id)
        name = $Name
        webhookId = (New-Id)   # wie im n8n-Editor; build-stabil (Set-StableNodeIds), fuer timeInterval ungenutzt
    }
}

# ============================================================
# ADVISOR/PAKET-AGENT-EINGANGSNAHT (extrahiert aus agent.finance_advisor, WS-1 career)
# ============================================================
# WS-3 Core-first Hard-Gate (immer-an Onboarding-Invariante, VOR Load Config): kein Paket vor dem Core-Onboarding
# (Haushalt). EINE Quelle fuer New-AdvisorGateChain UND agent.finance (vorher eine Hand-Kopie). Liest unter der
# Paket-RO-Cred (publizierte DEFINER-Fenster core.fn_onboarding_status + core.fn_ui_texts_for) im SELBEN Read den
# Status und den Umleitungs-Text in der Sprache des Absenders (chat_id; unbekannt/kaputt -> Owner-Sprache, nie ein
# RAISE). onError=continue + IF '=== false' -> fail-open bei Lesefehler (dann fehlt auch kein Text). Redirect =
# relaybares {ok:false, output} (der Orchestrator reicht ihn wortgleich oder ueber das Router-LLM weiter).
# Liefert @{ Read; Gate; Redirect } mit festen Node-Namen (Verdrahtung beim Aufrufer).
function New-CoreOnboardingGate {
    param(
        [Parameter(Mandatory)][string]$StartNode,
        [Parameter(Mandatory)]$CredPgRo,
        [int[]]$ReadPos = @(-1240, 360), [int[]]$GatePos = @(-1120, 360), [int[]]$RedirectPos = @(-1120, 540)
    )
    # Roter Faden: ein MITGLIED kann den Haushalt nicht einrichten -> statt "schick /onboarding" der ehrliche Hinweis
    # "wird noch eingerichtet, ich sage Bescheid" (core.sub_onboarding_progress schickt "Es kann losgehen", sobald der
    # Owner fertig ist). viewer_is_member kommt aus demselben DEFINER-Fenster (Rolle aus chat_id, nie LLM).
    $keys = Get-UiKeysSql @('core.gate.core_onboarding_required', 'core.gate.core_onboarding_wait_owner')
    $read = Build-Pg 'Core onboarding read' $ReadPos `
        ("=WITH s AS (SELECT core.fn_onboarding_status('core', (`$1::jsonb)->>'chat_id') AS r) " +
         "SELECT (s.r->>'complete')::boolean AS core_complete, COALESCE((s.r->>'viewer_is_member')::boolean, false) AS viewer_is_member, " +
         "core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb($keys)))->'t' AS t FROM s;") `
        ([ordered]@{ chat_id = "String(`$('$StartNode').item.json.chat_id || '')" })
    $read.credentials = @{ postgres = $CredPgRo }
    $read.onError = 'continueRegularOutput'
    $gate = Build-If 'Core onboarding gate' $GatePos `
        "={{ `$('Core onboarding read').item.json.core_complete === false }}" 'true' 'equals' 'boolean'
    $redirect = Build-Set 'Core onboarding required' $RedirectPos @(
        ,@('ok', 'false', 'boolean')
        ,@('output', ("={{ (`$('Core onboarding read').item.json.viewer_is_member === true) ? " +
                      (Get-UiTextJs "`$('Core onboarding read').item.json.t" 'core.gate.core_onboarding_wait_owner') + " : " +
                      (Get-UiTextJs "`$('Core onboarding read').item.json.t" 'core.gate.core_onboarding_required') + " }}"), 'string')
    )
    @{ Read = $read; Gate = $gate; Redirect = $redirect }
}

# Roter Faden: der EINE Aufruf-Knoten, den jedes tool_set_onboarding_section (core/finance/career/estate) nach einem
# erfolgreichen Set traegt -> Core-Dienst core:onboarding_progress (core.sub_onboarding_progress: Weiter-Karte, Lern-
# Angebot, "Es kann losgehen"). Fire-and-forget + onError=continue (eine Karte darf den Onboarding-Schritt nie stoeren,
# Muster New-ShowThinkingCallNode). $Package = build-time-Konstante (nie LLM); chat_id + die Kipp-Flags aus den festen
# Knoten 'Start' / 'Set section' des Tools (Set section muss area_completed_now + area_all_skipped selektieren).
function New-OnboardingProgressCallNode {
    param([Parameter(Mandatory)][string]$Package, [int[]]$Pos, [string]$Name = 'Onboarding progress')
    $wf = Resolve-CoreServiceAlias 'core:onboarding_progress' $CoreServiceMap
    $id = Get-RequiredWorkflowId $wf -Caller "New-OnboardingProgressCallNode '$Package'"
    $n = Build-CallWorkflow $Name $Pos $id $wf ([ordered]@{
        chat_id            = "={{ String(`$('Start').item.json.chat_id || '') }}"
        package            = $Package
        area_completed_now = "={{ `$('Set section').item.json.area_completed_now === true }}"
        area_all_skipped   = "={{ `$('Set section').item.json.area_all_skipped === true }}"
    })
    $n.parameters.options = [ordered]@{ waitForSubWorkflow = $false }
    $n['onError'] = 'continueRegularOutput'
    $n
}

# Die deterministische Eingangs-Naht, die JEDER Paket-Agent VOR dem LLM teilt (build-CLAUDE.md
# *Neuer AGENT-Workflow* + *Paket-Agent ... Routing-Status-/Core-first-Gate*): Anti-Loop-Depth-Gate
# -> Routing-Status-Gate (WS-B8, package active) -> Core-first-Onboarding-Gate (WS-3). Strukturell
# ueber finance/career/jede kuenftige Domaene IDENTISCH; das echte Delta (Tool-Liste, Modell, Memory-
# Tabelle, domain-Expression, der finance-SPEZIFISCHE feature.onboarding_gate-Zweig NACH Load Config)
# bleibt im jeweiligen Build-Def (Clone-and-Trim; arch-challenge D1: duenne geteilte Naht, KEINE
# volle Factory; Rule of Three = finance + finance_advisor + career = 3 Aufrufer dieser Gate-Kette).
# Parametrisiert ueber StartNode (chat_id/task-Quelle + erste Kante), Package (fn_package_active),
# die Paket-RO-Credential (beide Read-Nodes) und NextNode (False-Zweig des Core-Gates, i. d. R.
# 'Load Config'). Liefert @{ Nodes; Connections } mit Connections IN ORIGINAL-REIHENFOLGE (StartNode
# -> Depth -> Package -> Core), damit der Aufrufer sie ZUERST in sein $conns mergt (Schluessel-
# Reihenfolge = JSON-Reihenfolge des connections-Objekts).
function New-AdvisorGateChain {
    param(
        [Parameter(Mandatory)][string]$StartNode,
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)]$CredPgRo,
        [string]$NextNode = 'Load Config',
        [int[]]$DepthGatePos    = @(-1480, 0),
        [int[]]$DepthDenyPos    = @(-1300, 200),
        [int[]]$PkgReadPos      = @(-1480, 360),
        [int[]]$PkgGatePos      = @(-1360, 360),
        [int[]]$PkgDenyPos      = @(-1360, 540),
        [int[]]$CoreReadPos     = @(-1240, 360),
        [int[]]$CoreGatePos     = @(-1120, 360),
        [int[]]$CoreRedirectPos = @(-1120, 540)
    )
    # Anti-Loop-Backstop (Pflicht fuer jeden AGENT-Workflow)
    $nDepthGate = Build-If 'Depth gate' $DepthGatePos `
        "={{ Number(`$json.call_depth) || 0 }}" '2' 'largerEqual' 'number'
    $nDepthDeny = Build-ToolError 'Max call depth' $DepthDenyPos 'max_call_depth'

    # WS-B8 Routing-Status-Gate (vor Load Config): bricht VOR dem LLM ab, wenn das Paket nicht 'active'
    # ist. core.fn_package_active('<pkg>') unter der Paket-RO-Cred (publiziertes SECURITY-DEFINER-Window,
    # D10). Build-Pg-Default = WRITE-Cred -> post-construction auf die RO-Cred. onError=continue + IF
    # '=== false' => DB-Lesefehler faellt fail-open durch (Normalfall active), nur expliziter Nicht-
    # active-Status (installing/installed/inactive) sperrt.
    $nPkgRead = Build-Pg 'Package active read' $PkgReadPos `
        "SELECT core.fn_package_active('$Package') AS active;"
    $nPkgRead.credentials = @{ postgres = $CredPgRo }
    $nPkgRead.onError = 'continueRegularOutput'
    $nPkgGate = Build-If 'Package active gate' $PkgGatePos `
        "={{ `$('Package active read').item.json.active === false }}" 'true' 'equals' 'boolean'
    $nPkgDeny = Build-ToolError 'Package inactive' $PkgDenyPos 'package_inactive'

    # WS-3 Core-first Hard-Gate (geteilt mit agent.finance: New-CoreOnboardingGate).
    $core = New-CoreOnboardingGate -StartNode $StartNode -CredPgRo $CredPgRo `
        -ReadPos $CoreReadPos -GatePos $CoreGatePos -RedirectPos $CoreRedirectPos
    $nCoreRead = $core.Read; $nCoreGate = $core.Gate; $nCoreRedirect = $core.Redirect

    # Connections in Original-Reihenfolge ($StartNode -> Depth -> Package -> Core); der Aufrufer mergt
    # sie ZUERST, dann seine eigenen Keys (Load Config ff.) -> JSON-Schluessel-Reihenfolge bleibt stabil.
    $conns = [ordered]@{}
    $conns[$StartNode]              = @{ main = @( ,@( E 'Depth gate' ) ) }
    $conns['Depth gate']           = @{ main = @(
        @( E 'Max call depth' ),
        @( E 'Package active read' )   # false: -> WS-B8 Routing-Status-Gate (vor Load Config)
    ) }
    $conns['Package active read']  = @{ main = @( ,@( E 'Package active gate' ) ) }
    $conns['Package active gate']  = @{ main = @(
        @( E 'Package inactive' ),       # true: status != active -> structured decline (no LLM)
        @( E 'Core onboarding read' )    # false: active OR read error (fail-open) -> WS-3 Core-first-Gate
    ) }
    $conns['Core onboarding read'] = @{ main = @( ,@( E 'Core onboarding gate' ) ) }
    $conns['Core onboarding gate'] = @{ main = @(
        @( E 'Core onboarding required' ),  # true: Core-Haushalt offen -> Redirect (kein LLM)
        @( E $NextNode )                    # false: Core fertig OR read error (fail-open) -> proceed
    ) }

    @{
        Nodes = @($nDepthGate, $nDepthDeny, $nPkgRead, $nPkgGate, $nPkgDeny, $nCoreRead, $nCoreGate, $nCoreRedirect)
        Connections = $conns
    }
}

# HTTP GET node — retries 3x, 2s apart. Used for external API calls (e.g. FX rates).
function Build-Http {
    param([string]$Name, [int[]]$Pos, [string]$Url)
    [ordered]@{
        parameters = [ordered]@{ url = $Url; options = @{} }
        type = 'n8n-nodes-base.httpRequest'; typeVersion = 4.2; position = $Pos
        id = (New-Id); name = $Name; retryOnFail = $true; maxTries = 3; waitBetweenTries = 2000
    }
}

# ============================================================
# TELEGRAM-SENDER (zentral) — die "can't parse entities"-Klasse strukturell geschlossen.
# Telegram parst legacy Markdown (sendAndWait: parse_mode HARTKODIERT 'Markdown'; sendMessage:
# wirksamer Default). Regeln, die diese Helper erzwingen (Build-Gotchas #12-14):
#   - appendAttribution=false IMMER (sendMessage: additionalFields, sendAndWait: options)
#   - retryOnFail IMMER (transiente Telegram-Timeouts)
#   - DYNAMISCHER Text (={{ ... }}) wird KOMPLETT escapt (die 4 Legacy-Entities _ * ` [ per
#     Bot-API-Backslash) — DB-Werte/Nutzerdaten koennen den Send nie mehr crashen.
#   - STATISCHER Text mit Entities bricht den BUILD (frueh statt live; Plain-Text-Konvention).
#   - -NoEscape NUR fuer bewusst un-escapte LLM-Texte (Allowlist in workflow_lint.ps1; Risiko
#     dokumentiert im BACKLOG "Markdown-Entity-Risiko bei LLM-Antworten").
# Direkt-konstruierte Telegram-Sends in Build-Defs sind Altlast — neue Sends NUR ueber diese Helper.

function Protect-TgMarkdown([string]$JsExpr) {
    '(' + $JsExpr + ').replace(/[_*`[]/g, ''\\$&'')'
}

function Resolve-TgTextExpr([string]$TextExpr, [bool]$NoEscape) {
    if ($TextExpr -match '(?s)^=\{\{(.+)\}\}\s*$') {
        if ($NoEscape) { return $TextExpr }
        return '={{ ' + (Protect-TgMarkdown $Matches[1].Trim()) + ' }}'
    }
    if ($TextExpr -match '[_*`\[]') {
        throw "Telegram-Text enthaelt rohe Legacy-Markdown-Entities (_ * `` [): '$TextExpr' — umformulieren (Plain-Text-Konvention) oder als ={{ ... }}-Expression uebergeben (wird dann escapt)."
    }
    return $TextExpr
}

# WP-5: waehrungs-korrekte Formatierung von Betraegen/Daten im Locale des Empfaengers in nutzer-sichtbaren
# Nachrichten (HITL-Summaries + Cron-Reminder, Renderer Get-UiRenderLibJs). DIE EINE Adresse (sonst re-implementiert jeder der ~40 Summary-Builder das Symbol/
# Zahlformat neu -> Drift, hart '€' auf USD-Konten). Beide emittieren ein PLAIN JS-METHODEN-/Ternaer-Fragment
# (KEIN Function-Closure -> kein n8n-#15900-Risiko, Beleg: set_household_facts faehrt laengst eine IIFE in einer
# Expression), das eine bestehende n8n-Expression einsetzt. Der workflow_lint erzwingt die Nutzung (Feld-Vokabular).
#   Fmt-MoneyJs(betragExpr, ccyExpr, localeExpr) -> Intl currency-style: EUR->'€', USD->'$' (currencyDisplay
#     narrowSymbol, sonst z. B. de-DE 'US$'), Gruppierung + Dezimalzeichen des Locales in EINEM Call. Shape-Guard /^[A-Za-z]{3}$/ statt ||'EUR'
#     (Intl.NumberFormat wirft RangeError bei form-ungueltigem NICHT-leerem Code, nicht nur bei falsy).
#     ccyExpr = die Zeilen-Waehrung (accounts.currency) wo verfuegbar, sonst das Literal "'EUR'" (EUR-Konvention).
#   Fmt-DateJs(datumExpr, localeExpr) -> ISO 'JJJJ-MM-TT' -> Datum im Locale.
#   -LocaleExpr (Textkatalog, PFLICHT seit Phase C): JS-Ausdruck des Intl-Locales des Empfaengers (z. B. 'loc' im
#     Renderer, Quelle core.ui_languages.locale ueber core.fn_ui_texts_for/fn_hitl_texts). Kein Default mehr: ein
#     Aufruf ohne Locale bricht den Build ab (sonst formatierte ein Send still deutsch fuer jeden Empfaenger).
#     Fmt-DateJs rendert per Intl (de 31.12.2026, en-GB 31/12/2026, ko 2026. 12. 31.), ein Nicht-ISO-Wert kommt roh
#     zurueck (nie werfen: ein LLM-Tippfehler darf das Gate nicht lahmlegen).
function Fmt-MoneyJs([string]$AmountExpr, [string]$CurrencyExpr, [string]$LocaleExpr) {
    if ([string]::IsNullOrWhiteSpace($LocaleExpr)) { throw "Fmt-MoneyJs: -LocaleExpr fehlt (Locale des Empfaengers, z. B. aus core.fn_ui_texts_for)" }
    'Number(' + $AmountExpr + ").toLocaleString(" + $LocaleExpr + ",{style:'currency',currency:(/^[A-Za-z]{3}$/.test(" +
        $CurrencyExpr + ')?' + $CurrencyExpr + ":'EUR'),currencyDisplay:'narrowSymbol'})"
}
function Fmt-DateJs([string]$DateExpr, [string]$LocaleExpr) {
    if ([string]::IsNullOrWhiteSpace($LocaleExpr)) { throw "Fmt-DateJs: -LocaleExpr fehlt (Locale des Empfaengers, z. B. aus core.fn_ui_texts_for)" }
    "((m) => m ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])).toLocaleDateString(" + $LocaleExpr +
        ", {timeZone:'UTC', year:'numeric', month:'2-digit', day:'2-digit'}) : String(" + $DateExpr +
        "))(/^(\d{4})-(\d{2})-(\d{2})/.exec(String(" + $DateExpr + ")))"
}

# ============================================================
# HITL-Zusammenfassung im Textkatalog (Feste Texte in der Sprache der Person)
#   Ein Write-Tool baut seine Bestaetigungs-Zusammenfassung NICHT mehr als deutschen String, sondern als
#   STRUKTUR (Keys + typisierte Rohwerte); das Gate (agent.tool_human_approval) rendert sie je Empfaenger in dessen
#   Sprache ('Render texts' = core.fn_hitl_texts, 'Compose messages' = Get-HitlComposeJs). Das LLM formuliert
#   nichts davon, Betraege/Daten formatiert Intl im Locale des Empfaengers.
#   Form: { title, title_params?, lines: [ { label, kind, value, currency?, enum?, params?, is_default? } ] }
#     kind text (Rohwert, leer -> '—') | money (+currency) | date (ISO) | enum (+enum = Key-Prefix; Wert-Key
#     <enum>.<wert lower, Nicht-[a-z0-9_] -> '_'>, fehlt er -> Rohwert) | bool (ja/nein) | language (Code ->
#     Eigenname) | key (value = Text-Key) | tpl (value = Text-Key, params = {name: Wert|typisierter Wert}) |
#     removed ('wird entfernt') | list (Array von Werten) | heading (Zwischenzeile ohne Bullet) | note (Absatz
#     unter den Zeilen, value = Text-Key, params) | raw (fertiger Zeilentext ohne Label, nur aus -LinesExpr).
#     Optional je Zeile: label_fallback (lesbarer Ersatz fuer ein Label ohne Key), bei key: fallback.
#   Keys: <pkg>.<bereich>.<name>, Quelle packages/<pkg>/locales/<lang>.json. Jeder statische Key (und jeder
#   key-foermige String-Literal in den Ausdruecken) wird ZUR BUILD-ZEIT gegen die de.json des Key-Pakets geprueft
#   (unbekannt -> throw). Wert-Ausdruecke sind rohe JS-Ausdruecke (ohne ={{ }}).
# ============================================================
$script:HitlLocaleCache = @{}
function Get-HitlLocaleKeys([string]$Pkg) {
    if (-not $script:HitlLocaleCache.ContainsKey($Pkg)) {
        $f = Join-Path $RepoRoot "packages\$Pkg\locales\de.json"
        $keys = @{}
        if (Test-Path $f) {
            $obj = [System.IO.File]::ReadAllText($f, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $keys[$p.Name] = [string]$p.Value }   # Text fuer Assert-HitlTplParams
        }
        $script:HitlLocaleCache[$Pkg] = $keys
    }
    $script:HitlLocaleCache[$Pkg]
}
function Assert-HitlKey([string]$Key, [string]$Ctx) {
    if ($Key -notmatch '^[a-z][a-z0-9_]*(\.[a-z0-9_]+){2,}$') { throw "${Ctx}: Text-Key '$Key' hat nicht die Form <pkg>.<bereich>.<name>" }
    $pkg = $Key.Split('.')[0]
    if (-not (Get-HitlLocaleKeys $pkg).ContainsKey($Key)) { throw "${Ctx}: unbekannter Text-Key '$Key' (fehlt in packages/$pkg/locales/de.json)" }
}
function Assert-HitlEnumPrefix([string]$Prefix, [string]$Ctx) {
    $pkg = $Prefix.Split('.')[0]
    $hit = @((Get-HitlLocaleKeys $pkg).Keys | Where-Object { $_.StartsWith("$Prefix.") })
    if ($hit.Count -eq 0) { throw "${Ctx}: Enum-Prefix '$Prefix' hat keinen einzigen Wert-Key in packages/$pkg/locales/de.json" }
}
# Assert-HitlTplParams — jeder {platzhalter} JEDES Text-Keys im Ausdruck braucht einen gleichnamigen Parameter. Der
# Renderer setzt fehlende Parameter leer (n8n verwirft undefined-Felder; Owner 2026-10-22: nie "{isin}" als Rohtext),
# ein vertippter Parameter-Name faellt deshalb HIER beim Build auf statt still leer auf der Karte.
function Assert-HitlTplParams([string]$Expr, [hashtable]$Params, [string]$Ctx) {
    $have = if ($Params) { @($Params.Keys) } else { @() }
    foreach ($m in [regex]::Matches($Expr, "'([a-z][a-z0-9_]*(?:\.[a-z0-9_]+){2,})'")) {
        $k = $m.Groups[1].Value
        $keys = Get-HitlLocaleKeys ($k.Split('.')[0])
        if (-not $keys.ContainsKey($k)) { continue }
        foreach ($ph in [regex]::Matches([string]$keys[$k], '\{(\w+)\}')) {
            if ($have -notcontains $ph.Groups[1].Value) {
                throw "${Ctx}: Text-Key '$k' braucht den Parameter '$($ph.Groups[1].Value)' (fehlt in -Params/-TitleParams)"
            }
        }
    }
}
# Prueft key-foermige String-Literale ('<pkg>.<bereich>.<name>') in einem JS-Ausdruck (bedingte Notes/Keys).
function Assert-HitlExprKeys([string]$Expr, [string]$Ctx) {
    $pkgs = @(Get-ChildItem (Join-Path $RepoRoot 'packages') -Directory | ForEach-Object { $_.Name })
    foreach ($m in [regex]::Matches($Expr, "'([a-z][a-z0-9_]*(?:\.[a-z0-9_]+){2,})'")) {
        $k = $m.Groups[1].Value
        $pkg = $k.Split('.')[0]
        if ($pkgs -notcontains $pkg) { continue }
        # ein Enum-Prefix (z. B. 'core.enum.role') ist selbst kein Key, aber Praefix seiner Wert-Keys
        if ((Get-HitlLocaleKeys $pkg).ContainsKey($k)) { continue }
        Assert-HitlEnumPrefix $k $Ctx
    }
}
# ============================================================
# Feste Nutzertexte in Workflows (Textkatalog Phase B, docs/package-contract.md §3.11): ein Postgres-Node laedt die
# benoetigten Keys EINMAL in der Sprache des Empfaengers (core.fn_ui_texts -> Objekt {key: text}, die "t-Map"); Telegram-
# Nodes lesen daraus per Ausdruck. Muster core.fn_hitl_texts -> Get-HitlComposeJs. Jeder Key wird zur Build-Zeit gegen
# die de.json seines Pakets geprueft (Assert-HitlKey).
#   Get-UiKeysSql @('core.orch.x', ...)        -> "ARRAY['core.orch.x', ...]::text[]" (SQL-Literal, Keys geprueft)
#   Get-UiTextJs  <MapJs> <Key> [@{p='<js>'}]   -> JS-Ausdruck: Text aus der Map, Platzhalter {p} ersetzt; fehlt der
#                                                  Key in der Map (DB-Fehler), steht der Key selbst da (sichtbar, kein Crash)
#   Get-UiTextExpr <MapJs> <Key> [@{...}]       -> dasselbe als n8n-Ausdruck '={{ ... }}'
# ============================================================
function Get-UiKeysSql([string[]]$Keys) {
    foreach ($k in $Keys) { Assert-HitlKey $k 'Get-UiKeysSql' }
    'ARRAY[' + (($Keys | ForEach-Object { "'" + $_ + "'" }) -join ',') + ']::text[]'
}
function Get-UiTextJs([string]$MapJs, [string]$Key, [hashtable]$Params = @{}) {
    Assert-HitlKey $Key 'Get-UiTextJs'
    $js = "String(((" + $MapJs + ") || {})['" + $Key + "'] || '" + $Key + "')"
    if ($Params.Count -eq 0) { return $js }
    # EIN Durchlauf ueber die Vorlage (wie fill() in Get-UiRenderLibJs): ein eingesetzter Wert (Konto-/Zahlungsname
    # mit '{reason}') wird nie erneut nach Platzhaltern durchsucht. Callback statt Ersatz-String -> kein '$&'-Effekt.
    # Object.keys statt hasOwnProperty: n8n-Ausdruecke sperren das Wort "prototype" ("security concerns").
    $pairs = foreach ($p in ($Params.Keys | Sort-Object)) { "'" + $p + "': (" + $Params[$p] + ")" }
    $js + ".replace(/\{(\w+)\}/g, (m, k) => { const P = { " + ($pairs -join ', ') + " }; return Object.keys(P).includes(k) ? String(P[k]) : m; })"
}
function Get-UiTextExpr([string]$MapJs, [string]$Key, [hashtable]$Params = @{}) {
    '={{ ' + (Get-UiTextJs $MapJs $Key $Params) + ' }}'
}

function ConvertTo-HitlParams([hashtable]$Params) {
    if (-not $Params -or $Params.Count -eq 0) { return '' }
    foreach ($v in $Params.Values) { Assert-HitlExprKeys ([string]$v) 'HITL-Parameter' }   # Keys auch in Parametern pruefen
    $pairs = foreach ($k in ($Params.Keys | Sort-Object)) { "${k}: (" + $Params[$k] + ')' }
    ', params: { ' + ($pairs -join ', ') + ' }'
}
# New-HitlValue — typisierter Wert ohne Label (fuer tpl-Parameter / list-Elemente), JS-Objekt-Literal.
# Assert-HitlCurrency — Geld zeigt die Waehrung SEINER Zeile (Konto/Holding). Ein festes 'EUR' ist nur dort erlaubt, wo das
# Datenmodell den Wert in EUR fuehrt (Versicherung, Kredit, Rente, Immobilie, Sparziel) — und muss dann per -EurByModel
# bewusst markiert sein (vorher zeigten ~20 Karten Fremdwaehrungs-Betraege still als Euro).
function Assert-HitlCurrency([string]$Currency, [bool]$EurByModel, [string]$Ctx) {
    if ([string]::IsNullOrWhiteSpace($Currency)) { throw "${Ctx}: kind money braucht -Currency <Zeilen-Waehrung>" }
    if ($Currency.Trim() -eq "'EUR'" -and -not $EurByModel) {
        throw "${Ctx}: festes 'EUR' — Waehrung aus der Zeile (-Currency <expr>) oder, wenn das Datenmodell EUR fuehrt, -EurByModel"
    }
}
function New-HitlValue {
    param([Parameter(Mandatory)][ValidateSet('text','money','date','number','enum','bool','language','key')][string]$Kind,
          [Parameter(Mandatory)][string]$Value, [string]$Currency, [switch]$EurByModel, [string]$Enum, [int]$Digits = 0)
    $o = "{ kind: '$Kind', value: ($Value)"
    if ($Kind -eq 'money') {
        if ($EurByModel -and -not $Currency) { $Currency = "'EUR'" }
        Assert-HitlCurrency $Currency $EurByModel.IsPresent 'New-HitlValue'
        $o += ", currency: ($Currency)"
    }
    if ($Kind -eq 'number') { $o += ", digits: $Digits" }
    if ($Kind -eq 'enum')  { Assert-HitlEnumPrefix $Enum 'New-HitlValue'; $o += ", enum: '$Enum'" }
    if ($Kind -eq 'key')   { Assert-HitlExprKeys $Value 'New-HitlValue' }
    $o + ' }'
}
# New-HitlLine — eine Zeile (• Label: Wert). -If = JS-Bedingung (falsy -> Zeile entfaellt), -IsDefault = JS-
# Bedingung fuer den Zusatz '(Standard)'. Liefert ein JS-Objekt-Literal fuer New-HitlSummary -Lines.
# -OmitEmpty = optionale Info-Zeile entfaellt, wenn ihr Wert leer ist (null/''/[]; bei tpl: Key null ODER alle
#   Parameter leer) statt als '—' zu erscheinen (Owner 2026-10-25: leere Zusatzzeilen ueberfordern). Nie fuer
#   removed/heading (dort IST leer die Aussage) und nie fuer Felder, deren Leer-Bedeutung zaehlt (dafuer eigener
#   Text wie finance.value.no_instalment).
function New-HitlLine {
    param([Parameter(Mandatory)][string]$Label, [string]$Value = 'null',
          [ValidateSet('text','money','date','number','enum','bool','language','key','tpl','removed','list','heading')][string]$Kind = 'text',
          [string]$Currency, [switch]$EurByModel, [string]$Enum, [hashtable]$Params, [string]$If, [string]$IsDefault, [int]$Digits = 0,
          [switch]$OmitEmpty)
    $ctx = "New-HitlLine '$Label'"
    Assert-HitlKey $Label $ctx
    if ($OmitEmpty) {
        if ($Kind -in @('removed', 'heading')) { throw "${ctx}: -OmitEmpty ist bei kind '$Kind' nicht erlaubt (leer ist dort die Aussage)" }
        $emp = '((x) => x === null || x === undefined || x === "" || (Array.isArray(x) && x.length === 0))'
        $filled = if ($Kind -eq 'tpl') {
            $pv = @(if ($Params) { $Params.Keys | Sort-Object | ForEach-Object { "($($Params[$_]))" } })
            $keyOk = "!$emp($Value)"
            if ($pv.Count) { "($keyOk && ![" + ($pv -join ', ') + "].every($emp))" } else { "($keyOk)" }
        } else { "(!$emp($Value))" }
        $If = if ($If) { "($If) && $filled" } else { $filled }
    }
    $o = "{ label: '$Label', kind: '$Kind', value: ($Value)"
    switch ($Kind) {
        'money' {
            if ($EurByModel -and -not $Currency) { $Currency = "'EUR'" }
            Assert-HitlCurrency $Currency $EurByModel.IsPresent $ctx
            $o += ", currency: ($Currency)"
        }
        'number' { $o += ", digits: $Digits" }
        'enum'  { if (-not $Enum) { throw "${ctx}: kind enum braucht -Enum <prefix>" }; Assert-HitlEnumPrefix $Enum $ctx; $o += ", enum: '$Enum'" }
        'key'   { Assert-HitlExprKeys $Value $ctx }
        'tpl'   { Assert-HitlExprKeys $Value $ctx; Assert-HitlTplParams $Value $Params $ctx; $o += (ConvertTo-HitlParams $Params) }
    }
    if ($IsDefault) { $o += ", is_default: !!($IsDefault)" }
    $o += ' }'
    if ($If) { $o = "(($If) ? $o : null)" }
    $o
}
# New-HitlNote — Absatz unter den Zeilen (Hinweis/ACHTUNG). -Key = fester Key ODER -KeyExpr = JS-Ausdruck, der
# einen Key liefert (bedingte Varianten; jedes Key-Literal darin wird geprueft). -If wie New-HitlLine.
function New-HitlNote {
    param([string]$Key, [string]$KeyExpr, [hashtable]$Params, [string]$If)
    if ($Key) { Assert-HitlKey $Key "New-HitlNote '$Key'"; $v = "'$Key'" }
    elseif ($KeyExpr) { Assert-HitlExprKeys $KeyExpr 'New-HitlNote'; $v = "($KeyExpr)" }
    else { throw 'New-HitlNote: -Key oder -KeyExpr angeben' }
    Assert-HitlTplParams $v $Params 'New-HitlNote'
    $o = "{ kind: 'note', value: $v" + (ConvertTo-HitlParams $Params) + ' }'
    if ($If) { $o = "(($If) ? $o : null)" }
    $o
}
# New-HitlSummary — der Set-Knoten 'Build Approval Summary' mit summary als OBJEKT (statt deutschem String).
#   -Lines = Ergebnisse von New-HitlLine/New-HitlNote; -LinesExpr = JS-Ausdruck, der ein Array solcher Objekte
#   liefert (dynamische Listen, z. B. je Person); -TitleParams = Platzhalter des Titels.
function New-HitlSummary {
    param([string]$Name = 'Build Approval Summary', [int[]]$Pos, [Parameter(Mandatory)][string]$Title,
          [hashtable]$TitleParams, [string[]]$Lines = @(), [string]$LinesExpr)
    Assert-HitlKey $Title "New-HitlSummary '$Title'"
    Assert-HitlTplParams "'$Title'" $TitleParams "New-HitlSummary '$Title'"
    $tp =if ($TitleParams -and $TitleParams.Count) { ', title_params: { ' + ((($TitleParams.Keys | Sort-Object) | ForEach-Object { "${_}: (" + $TitleParams[$_] + ')' }) -join ', ') + ' }' } else { '' }
    $arr = '[ ' + ($Lines -join ', ') + ' ]'
    if ($LinesExpr) { Assert-HitlExprKeys $LinesExpr "New-HitlSummary '$Title'"; $arr = "$arr.concat($LinesExpr)" }
    $inner = "{ title: '$Title'$tp, lines: $arr.filter(Boolean) }"
    if ($inner -match '\}\}') { throw "New-HitlSummary '$Title': '}}' im Ausdruck (n8n beendet die Expression) — Leerzeichen setzen" }
    Build-Set $Name $Pos @( ,@('summary', "={{ ($inner) }}", 'object') )
}

# Get-HitlComposeJs — der EINE Renderer des HITL-Gates (Code-Knoten 'Compose messages', runOnceForEachItem).
#   Liest 'Render texts' (core.fn_hitl_texts: Sprache/Locale/Texte je Empfaenger) + das Summary aus 'Start' und
#   liefert je Empfaenger die fertigen Texte: owner {text, pre, stage2, stage2_pre, info, info_pre, approve, cancel,
#   unauthorized}, member {text, pre, approve, cancel, unauthorized} (fehlt das Member-Buendel -> Owner-Texte, nie ein
#   Absturz). *_pre = die vorderen Teile einer Karte ueber dem Telegram-Limit ("Teil n/N"), sonst []; text = der letzte.
#   Ein String-Summary (Test-Harness) geht unveraendert durch. Wirft nie bei kaputten Werten (Rohwert).
#   ENTSCHEIDET NIE UEBER EMPFAENGER: chatId/approverIds bleiben im Gate an Resolve sender/$OWNER_CHAT_ID gebunden.
# Get-UiRenderLibJs — der EINE Renderer typisierter Text-Strukturen (Textkatalog, docs/package-contract.md §3.11):
#   liefert JS-Quelltext einer Funktion uiRender(B, LANGS) fuer Code-Knoten. B = Text-Buendel EINES Empfaengers
#   ({lang, locale, t} aus core.fn_ui_texts_for bzw. owner/member aus core.fn_hitl_texts), LANGS = Code -> Eigenname.
#   Rueckgabe { t, has, fill, val, msg, lines, money, date, num, empty, isEmpty, loc }:
#     val(x)    — ein typisierter Wert {kind: text|money|date|number|enum|bool|language|key|tpl|removed|list}
#     msg(arr)  — Saetze (Alert-msg einer fn_advisor_review): null-Elemente (entfallene Teilsaetze) raus, mit ' ' verbunden
#     lines(arr)— Zeilen (Digest): null = Leerzeile, ein Array = eine Zeile aus Teilen (msg)
#   Betraege/Daten/Zahlen per Intl im Locale des Empfaengers (Fmt-MoneyJs/Fmt-DateJs, number: feste digits, sign;
#   digits -1 = alle Stellen des Werts, fuer Stueckzahlen).
#   Wirft nie bei kaputten Werten (Rohwert). Genutzt vom HITL-Gate (Get-HitlComposeJs) und den Cron-Berichten.
#   Die Format-Woerter (core.fmt.*) gehoeren in jede t-Map, die den Renderer nutzt: $script:UiRenderKeys.
$script:UiRenderKeys = @('core.fmt.empty', 'core.fmt.default_suffix', 'core.fmt.yes', 'core.fmt.no', 'core.fmt.removed')
function Get-UiRenderLibJs {
    $money = Fmt-MoneyJs 'n' 'cur' -LocaleExpr 'loc'
    $date  = Fmt-DateJs 'v' -LocaleExpr 'loc'
    $js = @'
function uiRender(B, LANGS) {
  B = B || {};
  LANGS = LANGS || {};
  const T = B.t || {};
  const loc = B.locale || 'en-GB';
  // fn_ui_texts liefert fuer einen fehlenden Key den Key selbst -> das zaehlt hier als "nicht vorhanden".
  const has = (k) => Object.prototype.hasOwnProperty.call(T, k) && T[k] !== k;
  const t = (k) => (has(k) ? T[k] : String(k));
  const empty = has('core.fmt.empty') ? T['core.fmt.empty'] : '—';
  const isEmpty = (v) => v === null || v === undefined || v === '';
  // Platzhalter in EINEM Durchlauf: einfache Werte unveraendert (auch '' fuer optionale Zusaetze wie die Einheit),
  // nur typisierte Werte ({kind: money|date|enum|...}) laufen durch val(); null/undefined -> ''. Ein FEHLENDER
  // Parameter zaehlt wie undefined: n8n verwirft undefined-Felder beim Speichern des Summary-Objekts, sonst stuende
  // Rohtext wie "{isin}" auf der Karte (Owner 2026-10-22). Vertippte Parameter-Namen faengt der Build
  // (Assert-HitlTplParams in New-HitlLine/New-HitlNote/New-HitlSummary).
  function fill(txt, params) {
    return String(txt).replace(/\{(\w+)\}/g, (m, n) => {
      if (!params || !Object.prototype.hasOwnProperty.call(params, n)) return '';
      const p = params[n];
      if (p === null || p === undefined) return '';
      return (typeof p === 'object') ? val(p) : String(p);
    });
  }
  function money(v, c) {
    if (isEmpty(v)) return empty;
    const n = Number(v);
    if (!isFinite(n)) return String(v);
    // Ohne gueltigen Waehrungscode KEIN stilles EUR (ein USD-Betrag sahe sonst wie Euro aus): Zahl + Rohcode.
    if (!(typeof c === 'string' && /^[A-Za-z]{3}$/.test(c))) return num(v, 2) + (isEmpty(c) ? '' : ' ' + String(c));
    const cur = c.toUpperCase();
    try { return __MONEY__; } catch (e) { return String(v) + ' ' + cur; }
  }
  function date(v) {
    if (isEmpty(v)) return empty;
    try { return __DATE__; } catch (e) { return String(v); }
  }
  // Nachkommastellen, die der Wert selbst traegt (ohne Null-Schwanz der DB, z. B. numeric(18,8) "10.00000000" -> 0).
  function decimals(v) {
    const s = String(v).trim();
    const e = s.match(/^-?\d+(?:\.(\d+))?e-(\d+)$/i);
    if (e) return Math.min(20, (e[1] || '').length + Number(e[2]));
    const m = s.match(/\.(\d+)$/);
    return m ? Math.min(20, m[1].replace(/0+$/, '').length) : 0;
  }
  // digits < 0 = so viele Stellen wie der Wert hat (Stueckzahlen: Krypto bis 8 Stellen, nie gerundet).
  function num(v, digits, sign) {
    if (isEmpty(v)) return empty;
    const n = Number(v);
    if (!isFinite(n)) return String(v);
    const d = (Number(digits) < 0) ? decimals(v) : Math.max(0, Math.min(6, Number(digits) || 0));
    try { return n.toLocaleString(loc, { minimumFractionDigits: d, maximumFractionDigits: d, signDisplay: sign ? 'exceptZero' : 'auto' }); }
    catch (e) { return String(v); }
  }
  function val(x) {
    if (isEmpty(x)) return empty;
    if (typeof x !== 'object') return String(x);
    if (Array.isArray(x)) return x.length ? x.map(val).join(', ') : empty;
    const v = x.value;
    switch (x.kind) {
      case 'money': return money(v, x.currency);
      case 'date': return date(v);
      case 'number': return num(v, x.digits, x.sign);
      case 'enum': {
        if (isEmpty(v)) return empty;
        const k = String(x.enum) + '.' + String(v).toLowerCase().replace(/[^a-z0-9_]+/g, '_');
        return has(k) ? T[k] : String(v);
      }
      case 'bool': return (v === true || v === 'true') ? t('core.fmt.yes')
        : ((v === false || v === 'false') ? t('core.fmt.no') : empty);
      case 'language': return isEmpty(v) ? empty : (LANGS[v] || String(v));
      case 'key': return isEmpty(v) ? empty : (has(v) ? T[v] : (x.fallback || String(v)));
      case 'tpl': return isEmpty(v) ? empty : fill(t(v), x.params);
      case 'removed': return t('core.fmt.removed');
      case 'list': return (Array.isArray(v) && v.length) ? v.map(val).join(', ') : empty;
      default: return isEmpty(v) ? empty : (Array.isArray(v) ? v.join(', ') : String(v));
    }
  }
  function msg(parts) {
    return (Array.isArray(parts) ? parts : [parts]).filter((p) => !isEmpty(p)).map(val).join(' ');
  }
  function lines(ls) {
    return (Array.isArray(ls) ? ls : []).map((l) => (l === null || l === undefined) ? ''
      : (Array.isArray(l) ? msg(l) : val(l))).join('\n');
  }
  return { T, loc, has, t, empty, isEmpty, fill, money, date, num, val, msg, lines };
}
'@
    $js.Replace('__MONEY__', $money).Replace('__DATE__', $date)
}

function Get-HitlComposeJs {
    $js = (Get-UiRenderLibJs) + @'
// Compose messages (Get-HitlComposeJs): Summary + Gate-Texte je Empfaenger in dessen Sprache.
const R = $('Render texts').first().json.r || {};
const S = $('Start').first().json.summary;
const LANGS = R.languages || {};
// Telegram-Limit 4096 Zeichen je Nachricht: ist eine Karte laenger, wird sie in Teile <= PART_MAX gepackt (inkl.
// "Teil n/N"-Zeile, Reserve PART_TAG). Kopf (Stufe-2-/Info-Praefix + Titel) steht in Teil 1, der Schwanz (Hinweise +
// Knopf-Hinweis) komplett im LETZTEN Teil (der mit den Knoepfen); getrennt wird an Block-Grenzen (heading = neuer
// Block), notfalls an Zeilen; eine Einzelzeile ueber dem Limit wird hart gekuerzt. pre = Teile 1..N-1 (das Gate
// sendet sie vor der Karte), text = letzter Teil. Kurze Karten: pre = [] und text exakt wie bisher.
const PART_MAX = 4000;
const PART_TAG = 40;
function make(B) {
  if (!B) return null;
  const U = uiRender(B, LANGS);
  const { T, has, t, isEmpty, fill, val } = U;
  function summary() {
    if (typeof S === 'string') return { head: '', blocks: [S.split('\n')], notes: [] };
    if (!S || typeof S !== 'object') return { head: '', blocks: [], notes: [] };
    const blocks = [];
    const notes = [];
    const push = (line) => { if (!blocks.length) blocks.push([]); blocks[blocks.length - 1].push(line); };
    for (const l of (Array.isArray(S.lines) ? S.lines : []).filter(Boolean)) {
      if (l.kind === 'note') { notes.push(fill(t(l.value), l.params)); continue; }
      // raw: fertige Zeile ohne Label (z. B. die Bestaetigungszeile einer Paket-validate_fn) — ein String oder ein
      // typisierter Wert (tpl der validate_fn, Textkatalog Phase C), dann in der Sprache des Empfaengers gerendert
      if (l.kind === 'raw') {
        if (!isEmpty(l.value)) push('• ' + (typeof l.value === 'object' ? val(l.value) : String(l.value)));
        continue;
      }
      // label_fallback: lesbarer Ersatz fuer offene Felder ohne Katalog-Key (z. B. neue Roh-Fakten-Keys)
      const lab = has(l.label) ? T[l.label] : (l.label_fallback || String(l.label));
      if (l.kind === 'heading') {
        blocks.push([lab + (isEmpty(l.value) ? ':' : ': ' + String(l.value))]);
        continue;
      }
      push('• ' + lab + ': ' + val(l) + (l.is_default ? ' ' + t('core.fmt.default_suffix') : ''));
    }
    return { head: S.title ? fill(t(S.title), S.title_params) : '', blocks, notes };
  }
  const SM = summary();
  // Text wie bisher: Kopf, Leerzeile, Zeilen (vor jeder Ueberschrift eine Leerzeile), Leerzeile, Hinweise.
  function joinBlocks(bs) { return bs.map((b) => b.join('\n')).join('\n\n'); }
  function parts(prefix, suffix) {
    const head = [prefix, SM.head].filter((x) => !isEmpty(x)).join('\n\n');
    const tail = [SM.notes.join('\n\n'), suffix].filter((x) => !isEmpty(x)).join('\n\n');
    const whole = [head, joinBlocks(SM.blocks), tail].filter((x) => !isEmpty(x)).join('\n\n');
    if (whole.length <= PART_MAX) return Array.of(whole);
    const max = PART_MAX - PART_TAG;
    const cut = (s) => (s.length > max ? s.slice(0, max - 1) + '…' : s);
    const out = [];
    let cur = cut(head);
    const add = (piece, sep) => {
      if (isEmpty(piece)) return;
      const cand = isEmpty(cur) ? piece : cur + sep + piece;
      if (cand.length <= max) { cur = cand; return; }
      if (!isEmpty(cur)) out.push(cur);
      cur = piece;
    };
    for (const b of SM.blocks) {
      const txt = b.join('\n');
      if (txt.length <= max) { add(txt, '\n\n'); continue; }
      add(cut(b[0]), '\n\n');
      for (const line of b.slice(1)) add(cut(line), '\n');
    }
    const tl = cut(tail);
    if (!isEmpty(tl)) {
      if (!isEmpty(cur) && (cur + '\n\n' + tl).length > max) { out.push(cur); cur = tl; }
      else cur = isEmpty(cur) ? tl : cur + '\n\n' + tl;
    }
    if (!isEmpty(cur)) out.push(cur);
    return out.map((p, i) => fill(t('core.hitl.part'), { n: i + 1, total: out.length }) + '\n' + p);
  }
  function msg(prefix, suffix) { const p = parts(prefix, suffix); return { text: p[p.length - 1], pre: p.slice(0, -1) }; }
  return { lang: B.lang, msg, t, fill };
}
const O = make(R.owner) || make({ lang: 'en', locale: 'en-GB', t: {} });
const M = make(R.member) || O;
const mname = (R.member && R.member.name) || '';
const chrome = (X) => ({ approve: X.t('core.hitl.approve'), cancel: X.t('core.hitl.cancel'),
  unauthorized: X.t('core.hitl.unauthorized') });
const oText = O.msg('', O.t('core.hitl.hint'));
const oStage2 = O.msg(O.fill(O.t('core.hitl.member_requests'), { name: mname }), O.t('core.hitl.hint'));
const oInfo = O.msg(O.fill(O.t('core.hitl.member_confirmed'), { name: mname }), '');
const mText = M.msg('', M.t('core.hitl.hint'));
return { json: {
  owner: Object.assign({ lang: O.lang, text: oText.text, pre: oText.pre,
    stage2: oStage2.text, stage2_pre: oStage2.pre, info: oInfo.text, info_pre: oInfo.pre }, chrome(O)),
  member: Object.assign({ lang: M.lang, text: mText.text, pre: mText.pre }, chrome(M)),
} };
'@
    $js
}

# New-AdvisorPhrasingTail — der geteilte Umformulier-Schwanz der Advisor-Review-Crons (Rule of Three: die zwei
# Core-Crons via New-AdvisorCron + der estate-Jahres-Review; vorher eine Hand-Kopie). Liefert:
#   'Load model config' (New-ModelConfigNode, -ConfigPackage/-ConfigKey) — der AUFRUFER haengt ihn VOR den
#     Latch-schreibenden Evaluate-Knoten (ein Ladefehler darf nie einen Hinweis als gemeldet markieren, der nie
#     verschickt wurde); die Evaluate-SQL hat keine Eingangs-Bezuege;
#   'Phrase message' (Basic LLM Chain, onError continue -> deterministischer Fallback) mit -PromptLead + $json.det_text;
#   Umschalter (New-ModelSelectorBundle, .first() — zwischen Config-Knoten und Kette liegen Code-Knoten);
#   'Choose text' (LLM-Text oder der deterministische Text aus 'Build message').
# Gate/Schedule/Evaluate/Build message/Send bleiben je Cron (belegte estate-Abweichung: eigenes Gate, kein cron_off).
# Rueckgabe @{ LoadNode; Nodes; Connections } — Connections: Phrase -> Choose text + Umschalter-Kanten.
function New-AdvisorPhrasingTail {
    param(
        [Parameter(Mandatory)][string]$PromptLead,      # EN-Anweisung, an die der deterministische Text angehaengt wird
        [Parameter(Mandatory)][string]$ConfigPackage,   # Besitzer des Modell-Keys (heute 'core')
        [Parameter(Mandatory)][string]$ConfigKey,       # Modell-Key (heute 'advisor_review')
        [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high')][string]$Effort,
        [int[]]$LoadPos = @(-550, -180)
    )
    if ($PromptLead.Contains("'")) { throw "New-AdvisorPhrasingTail: -PromptLead darf kein ' enthalten (JS-String im Ausdruck)" }
    # Textkatalog Phase C: die Ausgabesprache = die des Empfaengers. -PromptLead traegt GENAU EINEN Platzhalter
    # {language}; 'Build message' liefert $json.language_label (z. B. "ko (한국어)") und det_text schon in dieser Sprache.
    $parts = $PromptLead -split '\{language\}'
    if ($parts.Count -ne 2) { throw "New-AdvisorPhrasingTail: -PromptLead braucht genau einen Platzhalter {language} (Empfaenger-Sprache)" }
    $load = New-ModelConfigNode -Position $LoadPos -Keys @( ,@($ConfigPackage, $ConfigKey) )
    $phrase = [ordered]@{
        parameters = [ordered]@{
            promptType = 'define'
            text = "={{ '$($parts[0])' + `$json.language_label + '$($parts[1])' + `$json.det_text }}"
        }
        type = '@n8n/n8n-nodes-langchain.chainLlm'; typeVersion = 1.7; position = @(180, 0)
        id = (New-Id); name = 'Phrase message'
        onError = 'continueRegularOutput'
        retryOnFail = $true; maxTries = 2; waitBetweenTries = 2000
    }
    $selector = New-ModelSelectorBundle -ConfigField "model.$ConfigKey" -ConfigNodeName 'Load model config' `
        -AgentNodeName 'Phrase message' -SelectorPos @(180, 220) -ModelRowPos @(40, 400) -Effort $Effort -FirstConfigItem
    $choose = [ordered]@{
        parameters = [ordered]@{ jsCode = @'
const llm = ($input.first().json && $input.first().json.text) || '';
const det = $('Build message').first().json.det_text;
return [{ json: { message: llm.trim() ? llm.trim() : det } }];
'@ }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(400, 0)
        id = (New-Id); name = 'Choose text'
    }
    $conns = [ordered]@{ 'Phrase message' = @{ main = @( ,@( E 'Choose text' ) ) } }
    foreach ($k in $selector.Connections.Keys) { $conns[$k] = $selector.Connections[$k] }
    return @{ LoadNode = $load; Nodes = @($phrase) + @($selector.Nodes) + @($choose); Connections = $conns }
}

# Assert-FromAiSpec — Pflicht/optional eines $fromAI-Felds muss zu seiner Beschreibung passen (BUILDER-Gotcha):
#   (a) Beschreibung sagt optional / leave empty, die Spec hat aber keinen Default -> das LLM MUSS einen Wert liefern und
#       erfindet ihn oder fragt nach (create_loan/create_real_estate trugen 7 solche Felder).
#   (b) Zahlenfeld mit Default '' -> ergaebe $fromAI(..., 'number', ) = kaputte Expression.
# Genutzt von New-AdvisorToolNode UND dem finance-lokalen New-ToolWorkflowNode (beide bauen $fromAI aus derselben Spec-Form).
function Assert-FromAiSpec([array]$InputSpec, [string]$Ctx) {
    foreach ($spec in $InputSpec) {
        $name = $spec[0]; $desc = [string]$spec[1]; $type = $spec[2]
        if ($spec.Count -lt 4 -and $desc -match '(?i)\boptional\b|\bleave (it )?empty\b') {
            throw "${Ctx}: Feld '$name' ist laut Beschreibung optional, hat aber keinen Default (4. Element) -> das LLM muesste es erfinden"
        }
        if ($spec.Count -ge 4 -and $type -eq 'number' -and [string]$spec[3] -eq '') {
            throw "${Ctx}: Zahlenfeld '$name' mit Default '' ergaebe eine kaputte `$fromAI-Expression -> Default-Zahl oder Typ 'string'"
        }
    }
}

# Frei-SQL-Lesewerkzeug `postgres_select` (postgresTool executeQuery) der Agenten -- die EINE Quelle (vorher
# Hand-Kopien je Agent-Def). Read-Fehler sind NICHT
# fatal (onError continue: der DB-Fehler geht als Tool-Ergebnis an den Agenten, er korrigiert die Query selbst).
# Live-Befund 2026-10-24 (Execution 732): ein Aufruf OHNE query-Argument liess n8n intern werfen ("Cannot read
# properties of undefined (reading 'match')", executeQuery.operation) -> leere/fehlende query wird zu einem SELECT, das
# {ok:false, error} als Zeile liefert. Bewusst KEIN Default (4. $fromAI-Argument): der machte query im Schema optional.
# workflow_lint prueft den Guard an jedem postgresTool mit $fromAI-query. $Cred = die Paket-RO-Credential.
function New-PostgresSelectToolNode {
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)]$Cred, [int[]]$Pos = @(-336, 208))
    [ordered]@{
        parameters = [ordered]@{
            descriptionType = 'manual'
            toolDescription = $Description
            operation = 'executeQuery'
            query = "={{ (`$fromAI('query', 'A read-only PostgreSQL SELECT statement', 'string') || '').trim() || `"SELECT false AS ok, 'The query argument is missing - call postgres_select again with one read-only SELECT statement in query.' AS error`" }}"
            options = @{}
        }
        type = 'n8n-nodes-base.postgresTool'
        typeVersion = 2.6
        position = $Pos
        id = (New-Id)
        name = 'postgres_select'
        onError = 'continueRegularOutput'
        credentials = @{ postgres = $Cred }
    }
}

# toolWorkflow-Node fuer CROSS-AGENT-Tools (agent.tool_*): voller Workflow-Name + $fromAI-InputSpec +
# optionale FIXE (nicht-$fromAI) Inputs + chat_id-Durchreichung. Phase 0 WS-0c AT: die EINE geteilte
# Quelle (loest die byte-identischen Duplikate New-AdvisorToolNode/New-CareerAdvisorToolNode/New-GuideToolNode
# in den 4 Agent-Build-Defs ab; monitor nutzte schon den finance-lokalen). Genutzt von agent.finance_advisor,
# agent.career_advisor, agent.monitor, agent.guide. -StartNode ist PFLICHT (kein finance-biased Default ->
# ein anderer Konsument kann nicht still die falsche chat_id-Quelle erben). Guide bindet keine FixedInputs
# (uebergibt $null). Liegt in lib = Engine (kein Cross-Paket-Import, ein Name -> Scope-Kollision geloest).
function New-AdvisorToolNode {
    param(
        [Parameter(Mandatory)][string]$ToolKey,        # Node-/Tool-Name fuer das LLM, z. B. 'web_search'
        [Parameter(Mandatory)][string]$WorkflowName,   # voller n8n-Name, z. B. 'agent.tool_web_search'
        [string]$Description,
        [array] $InputSpec,                            # @( @(name, desc, type[, default]) ... )
        $FixedInputs,                                  # [ordered]@{ name = '<n8n expression>' } — nicht-$fromAI; $null = keine
        [Parameter(Mandatory)][int[]]$Position,
        [Parameter(Mandatory)][string]$StartNode       # chat_id-Quelle (je Agent dessen Start-Node) — PFLICHT
    )
    $id = Get-RequiredWorkflowId $WorkflowName 'New-AdvisorToolNode'
    Assert-FromAiSpec $InputSpec "New-AdvisorToolNode '$ToolKey'"
    $valueMap = [ordered]@{}
    $schema   = @()
    foreach ($spec in $InputSpec) {
        $name = $spec[0]; $desc = $spec[1]; $type = $spec[2]
        if ($spec.Count -ge 4) {
            $def = $spec[3]
            if ($type -eq 'number') { $valueMap[$name] = "={{ `$fromAI('$name', '$desc', '$type', $def) }}" }
            else                    { $valueMap[$name] = "={{ `$fromAI('$name', '$desc', '$type', '$def') }}" }
        } else {
            $valueMap[$name] = "={{ `$fromAI('$name', '$desc', '$type') }}"
        }
        $schema += [ordered]@{
            id = $name; displayName = $name; required = $false; defaultMatch = $false
            display = $true; canBeUsedToMatch = $true; type = $type; removed = $false
        }
    }
    if ($null -ne $FixedInputs) {
        foreach ($k in $FixedInputs.Keys) {
            $valueMap[$k] = $FixedInputs[$k]
            $schema += [ordered]@{
                id = $k; displayName = $k; required = $false; defaultMatch = $false
                display = $true; canBeUsedToMatch = $true; type = 'string'; removed = $false
            }
        }
    }
    # chat_id immer durchreichen (Gate-Empfaenger + e2e-Domain-Switch fuer den Sentinel)
    $valueMap['chat_id'] = "={{ `$('$StartNode').item.json.chat_id }}"
    $schema += [ordered]@{
        id = 'chat_id'; displayName = 'chat_id'; required = $false; defaultMatch = $false
        display = $true; canBeUsedToMatch = $true; type = 'string'; removed = $false
    }
    [ordered]@{
        parameters = [ordered]@{
            name = $ToolKey
            description = $Description
            workflowId = [ordered]@{
                __rl = $true; value = $id; mode = 'list'
                cachedResultUrl = "/workflow/$id"; cachedResultName = $WorkflowName
            }
            workflowInputs = [ordered]@{
                mappingMode = 'defineBelow'; value = $valueMap; matchingColumns = @()
                schema = @($schema); attemptToConvertTypes = $false; convertFieldsToString = $false
            }
        }
        type = '@n8n/n8n-nodes-langchain.toolWorkflow'
        typeVersion = 2.2
        position = $Position
        id = (New-Id)
        name = $ToolKey
    }
}

# Paket-Tool-Services an einen Agenten binden (docs/package-contract.md §5 Cross-package tool services; paperless
# Phase 2). Je Service EIN toolWorkflow-Node 'tool_<alias>' — Ziel ist IMMER der Core-Vermittler
# agent.sub_dispatch_tool (Core-ID literal; die Paket-Workflow-ID steht NIE im Konsumenten -> workflow_lint-Naht),
# mit FESTEM service='<pkg>:<alias>' + args = JSON.stringify der $fromAI-Felder aus dem PROVIDER-Manifest
# (provides.services.<alias>.inputs: Pflicht = 3-arg, optional = 4-arg mit Default bzw. '') + chat_id vom StartNode.
# Tool-Description verbatim aus dem Provider-Manifest (EINE Quelle fuer Modell-Schema, Eingabe-Pruefung im Werkzeug
# und /help). Default: die Nicht-Core-Eintraege aus consumes.services des Konsumenten (core:-Dienste bindet jede Def
# selbst); -Own: die EIGENEN provides.services (Dokumenten-Assistent) — ebenfalls ueber den Vermittler, weil der die
# EINE Berechtigungs-Pruefstelle ist (literal waere ein Bypass von core.fn_resolve_service).
# Fail-closed: unbekannter Provider/Alias, String-Form beim Provider, ' oder Backtick in einer Beschreibung
# ($fromAI-Literal), Namens-Kollision mit -ExistingNodes, Selbst-Konsum ohne -Own -> throw.
# Rueckgabe @{ Nodes; Connections } (ai_tool-Kanten zu -AgentNode) — der Aufrufer haengt beides an.
function Add-ServiceTools {
    param(
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$AgentNode,
        [Parameter(Mandatory)][string]$StartNode,
        [Parameter(Mandatory)][int[]]$Position,       # Position des ersten Nodes; jeder weitere +160 in x
        [array]$ExistingNodes = @(),
        [string[]]$Exclude = @(),                      # Aliase, die DIESER Agent nicht bekommt (z. B. Finance-DEFER)
        [switch]$Own
    )
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $readManifest = { param($pkg)
        $p = Join-Path $RepoRoot "packages\$pkg\manifest.json"
        if (-not (Test-Path $p)) { throw "Add-ServiceTools: Paket '$pkg' hat kein manifest.json." }
        [System.IO.File]::ReadAllText($p, $u8) | ConvertFrom-Json
    }
    $consumer = & $readManifest $Package
    $refs = if ($Own) {
        @($consumer.provides.services.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { "${Package}:$($_.Name)" })
    } else {
        @(@($consumer.consumes.services) | Where-Object { $_ -and $_ -notlike 'core:*' })
    }
    $existing = @($ExistingNodes | ForEach-Object { [string]$_.name })
    $nodes = @(); $conns = [ordered]@{}; $x = $Position[0]; $lines = @()
    foreach ($ref in $refs) {
        if ($ref -notmatch '^([a-z][a-z0-9_]*):([a-z][a-z0-9_]*)$') { throw "Add-ServiceTools: '$ref' ist kein '<pkg>:<alias>'." }
        $prov = $Matches[1]; $alias = $Matches[2]
        if ($Exclude -contains $alias) { continue }
        if ($prov -eq $Package -and -not $Own) { throw "Add-ServiceTools: $Package konsumiert sich selbst ('$ref') — eigene Werkzeuge bindet -Own." }
        $svc = (& $readManifest $prov).provides.services.$alias
        if ($null -eq $svc -or $svc -is [string]) { throw "Add-ServiceTools: '$ref' ist kein Objekt-Form-Service in packages/$prov/manifest.json." }
        $fields = @()
        foreach ($in in $svc.inputs.PSObject.Properties) {
            $d = [string]$in.Value.description; $t = [string]$in.Value.type
            if ($d -match "['``]") { throw "Add-ServiceTools: '$ref' input '$($in.Name)': ' oder Backtick in der Beschreibung bricht das `$fromAI-Literal." }
            $call = if ($in.Value.required) { "`$fromAI('$($in.Name)', '$d', '$t')" }
                    elseif ($null -ne $in.Value.default -and $t -eq 'number') { "`$fromAI('$($in.Name)', '$d', '$t', $($in.Value.default))" }
                    elseif ($null -ne $in.Value.default) { "`$fromAI('$($in.Name)', '$d', '$t', '$($in.Value.default)')" }
                    else { "`$fromAI('$($in.Name)', '$d', '$t', '')" }
            $fields += "$($in.Name): $call"
        }
        $toolKey = "tool_$alias"
        if ($existing -contains $toolKey) { throw "Add-ServiceTools: Node-Name '$toolKey' existiert im Agenten schon." }
        $existing += $toolKey
        $fixed = [ordered]@{
            service = "${prov}:$alias"
            args    = '={{ JSON.stringify({ ' + ($fields -join ', ') + ' }) }}'
        }
        $nodes += New-AdvisorToolNode $toolKey 'agent.sub_dispatch_tool' ([string]$svc.description) @() $fixed @($x, $Position[1]) -StartNode $StartNode
        $conns[$toolKey] = @{ ai_tool = @( ,@( E $AgentNode 'ai_tool' ) ) }
        $lines += "- $toolKey -> ${prov}:$alias (darf: $($svc.permission))"
        $x += 160
    }
    # Sticky-Pflicht (Workflows sind die Doku): die gebundenen Paket-Werkzeuge + ihr Weg ueber den Vermittler.
    if ($nodes.Count -gt 0) {
        $nodes += Build-Sticky 'Doc: Paket-Werkzeuge' @($Position[0], ($Position[1] - 260)) -Header 'Ablauf' `
            'Paket-Werkzeuge (optional, ueber den Core-Vermittler)' `
            ("Diese Werkzeuge gehoeren einem ANDEREN Paket bzw. sind Paket-Services. Jeder Aufruf geht an agent.sub_dispatch_tool (fester service + args aus den Modell-Feldern + chat_id). Dort entscheidet core.fn_resolve_service: Paket installiert+aktiv? Absender darf? Sonst {ok:false, error, hint} als Daten - der Agent laeuft auch ohne das Paket.`n" + ($lines -join "`n")) 200 ([Math]::Max(320, 160 * $refs.Count))
    }
    @{ Nodes = $nodes; Connections = $conns }
}

# Regulaerer Telegram-Send (sendMessage, keine Buttons) — Form 1:1 aus core.sub_error_notify.
#   -ParseMode: 'Markdown' | 'HTML' setzt additionalFields.parse_mode explizit. Nicht gesetzt = n8n-Default (Markdown).
#     Es gibt KEIN Plain: n8n (GenericFunctions.addAdditionalFields) macht aus einem leeren parse_mode still
#     'Markdown' (Live-Befund 2026-10-22, Exec 297) -> echtes Plain = 'HTML' + HTML-escapter Text (Fallback unten).
#   -OnError 'continueErrorOutput' schaltet den Fehler-Ausgang frei (fuer den Markdown->Plain-Fallback, WP-2).
function New-TelegramSendNode {
    param([string]$Name, [int[]]$Pos, [string]$TextExpr,
          [string]$ChatIdExpr = '__OWNER_CHAT_ID__',
          [switch]$NoEscape, [int]$MaxTries = 3, [int]$WaitBetweenTries = 2000,
          [string]$ParseMode, [string]$OnError)
    $addl = [ordered]@{ appendAttribution = $false }
    if ($PSBoundParameters.ContainsKey('ParseMode')) { $addl['parse_mode'] = $ParseMode }
    $node = [ordered]@{
        parameters = [ordered]@{
            additionalFields = $addl
            chatId = $ChatIdExpr
            text   = (Resolve-TgTextExpr $TextExpr $NoEscape.IsPresent)
        }
        type = 'n8n-nodes-base.telegram'; typeVersion = 1.2; position = $Pos
        id = (New-Id); name = $Name
        retryOnFail = $true; maxTries = $MaxTries; waitBetweenTries = $WaitBetweenTries
        credentials = @{ telegramApi = $CRED_TELEGRAM }
    }
    if ($OnError) { $node['onError'] = $OnError }
    $node
}

# WP-2 Markdown-Robustheit: EIN LLM-Relay-Send, der bei einem Markdown-PARSE-Fehler (ungepaartes _*[` in freier
# LLM-Antwort -> Telegram HTTP 400 "can't parse entities") NICHT crasht, sondern denselben Text PLAIN nachsendet.
# Gibt zwei Nodes zurueck: Primary (parse_mode='Markdown', onError=continueErrorOutput, maxTries=1 — Retry ist bei
# einem deterministischen Parse-Fehler nutzlos + interagiert defekt mit onError=Continue, GH #10763) und
# PlainFallback (parse_mode='HTML' + Text mit & < > als Entities, voller retryOnFail — transiente Fehler des
# Fallbacks bleiben UNGEFANGEN -> regulaerer errorWorkflow -> ein echter Zustellausfall wird NICHT maskiert).
# Warum HTML statt parse_mode='': n8n setzt leeres parse_mode still auf 'Markdown' (der Fallback crashte 2026-10-22
# an derselben Entity wie der Primary); im HTML-Modus sind laut Bot-API nur < > & Steuerzeichen -> escapt kommt
# der Text 1:1 an. Der Aufrufer verdrahtet: <input> -> Primary; Primary[main,0] (Erfolg) terminiert;
# Primary[error] -> PlainFallback. -TextExpr = genau EIN ={{ ... }}-Ausdruck (wird fuer den Fallback umhuellt).
function New-TelegramSendWithPlainFallback {
    param([string]$Name, [int[]]$Pos, [string]$TextExpr, [string]$ChatIdExpr = '__OWNER_CHAT_ID__')
    if ($TextExpr -notmatch '(?s)^=\{\{(.+)\}\}\s*$') { throw "New-TelegramSendWithPlainFallback '$Name': -TextExpr muss genau ein ={{ ... }}-Ausdruck sein" }
    $plainExpr = '={{ String(' + $Matches[1].Trim() + ").replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;') }}"
    $primary = New-TelegramSendNode $Name $Pos $TextExpr -ChatIdExpr $ChatIdExpr -NoEscape `
                   -ParseMode 'Markdown' -OnError 'continueErrorOutput' -MaxTries 1
    $fallback = New-TelegramSendNode "$Name (plain fallback)" @(($Pos[0] + 220), ($Pos[1] + 200)) $plainExpr `
                   -ChatIdExpr $ChatIdExpr -NoEscape -ParseMode 'HTML'
    @{ Primary = $primary; Fallback = $fallback }
}

# New-TelegramRelayChain — EIN Weg fuer jede Agent-Antwort an den Chat (Orchestrator-Relay, Paket-Befehle, Onboarding-
# Knoepfe; Owner 2026-10-25 "Zahlen richtig + lesbar"): '<Name> split' (Code) teilt den Text an Absatzgrenzen in Teile
# <= 3500 Zeichen (vor dem Escapen; Telegram-Limit 4096) und escapt & < > -> '<Name> loop' (splitInBatches, 1 Teil je
# Runde) -> '<Name>' (Telegram, parse_mode=HTML = echtes Plain; alle Agenten schreiben Plain-Text; leeres parse_mode
# macht n8n still zu Markdown) -> zurueck zur Loop. Ein Retry wiederholt so nur den aktuellen Teil (keine Duplikate).
# -TextJs = JS-Ausdruck im Code-Node-Kontext (nur .first(), kein .item), -FallbackJs = Text, wenn er leer ist.
# Rueckgabe: @{ Nodes; Conns; Entry = '<Name> split'; Loop = '<Name> loop' } — der Aufrufer verdrahtet zur Entry und
# den Done-Ausgang (Loop main[0]) zu seinem Folge-Node (AddDone).
function New-TelegramRelayChain {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][int[]]$Pos, [Parameter(Mandatory)][string]$TextJs,
          [Parameter(Mandatory)][string]$ChatIdExpr, [string]$FallbackJs = "''", [string]$DoneTo)
    $js = @"
const body = String(($TextJs) || ($FallbackJs) || '');
const LIMIT = 3500;
const chunks = [];
let cur = '';
const push = (s) => { if (s.trim()) chunks.push(s); };
for (const para of body.split('\n\n')) {
  const add = cur ? cur + '\n\n' + para : para;
  if (add.length <= LIMIT) { cur = add; continue; }
  push(cur); cur = '';
  let rest = para;
  while (rest.length > LIMIT) {
    let cut = rest.lastIndexOf('\n', LIMIT);
    if (cut < LIMIT / 2) cut = rest.lastIndexOf(' ', LIMIT);
    if (cut < LIMIT / 2) cut = LIMIT;
    push(rest.slice(0, cut)); rest = rest.slice(cut).replace(/^\s+/, '');
  }
  cur = rest;
}
push(cur);
const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
return chunks.map((c, i) => ({ json: { text: esc(c), part: i + 1, parts: chunks.length } }));
"@
    $split = [ordered]@{ parameters = [ordered]@{ jsCode = $js }; type = 'n8n-nodes-base.code'; typeVersion = 2
        position = $Pos; id = (New-Id); name = "$Name split" }
    $loop = Build-Loop "$Name loop" @(($Pos[0] + 200), $Pos[1])
    $send = New-TelegramSendNode $Name @(($Pos[0] + 400), ($Pos[1] + 120)) "={{ `$json.text }}" -ChatIdExpr $ChatIdExpr -NoEscape -ParseMode 'HTML'
    # main[0] = done, main[1] = loop — beide MUESSEN Arrays bleiben (ein Ein-Element-Array entpackt PowerShell sonst
    # zu einem Objekt -> n8n-Import "connections.<loop>.main[0] Expected array, received object").
    $doneArr = @(if ($DoneTo) { E $DoneTo })
    $conns = [ordered]@{
        "$Name split" = @{ main = @( ,@( E "$Name loop" ) ) }
        "$Name loop"  = @{ main = @( ,$doneArr ) + @( ,@( E $Name ) ) }
        $Name         = @{ main = @( ,@( E "$Name loop" ) ) }
    }
    @{ Nodes = @($split, $loop, $send); Conns = $conns; Entry = "$Name split"; Loop = "$Name loop" }
}

# Telegram Send-and-Wait (Buttons; approvalType 'double' = Approve+Disapprove); eigener webhookId je Node.
# CHAT-BESTAETIGUNG (n8n >= 2.35, Telegram-Node-Parameter chatApproval): die Knoepfe tragen callback_data statt
# eines Links -> der Tipp laeuft ueber Telegram -> Orchestrator-Trigger -> POST <WEBHOOK_URL-Origin>/webhook-
# waiting-telegram (HMAC-gebunden an die Execution), kein Browser. Ob das AN ist, entscheidet erst der Deploy:
# chatApproval traegt den Platzhalter __HITL_CHAT_APPROVAL__, den deploy_workflows.sh durch true/false ersetzt
# (true nur, wenn der Server seinen eigenen /webhook-waiting-telegram ueber die Domain erreicht; sonst Link-
# Knoepfe ueber /webhook-waiting/* wie bisher). approverIds = WER tippen darf (leer hiesse: jeder!) -> Default
# die Ziel-chat_id (privater Chat: chat_id == user_id); ein Ausdruck muss im Webhook-Kontext ohne Item-Index
# tragen (.first(), nie .item) und darf nie leer werden. n8n bindet den Tipp an die Execution, nicht an die
# Nachricht -> mehrere Warte-Nodes nacheinander in EINER Execution brauchen den Stale-Tap-Schutz (Aufrufer).
function New-TelegramSendAndWaitNode {
    param([string]$Name, [int[]]$Pos, [string]$MessageExpr,
          [string]$ChatIdExpr = '__OWNER_CHAT_ID__', [string]$ApprovalType = 'double',
          [string]$ApproverIdsExpr,
          # Textkatalog Phase C: KEINE Default-Texte mehr — jeder Aufrufer gibt Knopf-Texte und Popup in der Sprache
          # des Empfaengers mit (={{ }}-Ausdruck aus seiner t-Map, nur .first()). -DisapproveLabel nur bei 'double'.
          [string]$ApproveLabel, [string]$DisapproveLabel,
          [switch]$NoEscape, [int]$MaxTries = 3, [int]$WaitBetweenTries = 2000,
          # -LimitWaitMinutes > 0 setzt das n8n-sendAndWait-`limitWaitTime` UNTER options (Telegram ruft
          # configureWaitTillDate(this) mit Default 'options' -> liest nur options.limitWaitTime.values; top-level wird
          # still ignoriert = unbegrenzt, Live-Befund 2026-10-22, n8n 2.44.4): nach N Minuten ohne Button-Antwort resumed n8n den
          # Workflow OHNE Approval -> data.approved bleibt leer -> der downstream `approved?`-Check faellt
          # auf FALSE (fail-closed, kein Write). Begrenzt das verdoppelte Telegram-Socket-Hang-Fenster auf
          # dem zweistufigen Member->Owner-Pfad (WS-5b arch-challenge #6). 0 = unbegrenzt (Default-Verhalten).
          [int]$LimitWaitMinutes = 0,
          # Textkatalog: Popup fuer einen fremden Tipper (={{ }}-Ausdruck mit .first() aus der t-Map des Empfaengers).
          [string]$UnauthorizedReply)
    # Nach dem Tipp (n8n Telegram hitl/webhook.ts): postDecisionBehavior FEST removeButtons — showOutcome haengte die
    # fest ENGLISCHE Zeile "✅ Approved by <Name>" an (nicht konfigurierbar, nicht uebersetzbar). Was passiert ist,
    # bestaetigt der Aufrufer selbst in der Sprache des Empfaengers (Agent-Antwort bzw. Ergebnis-Zeile der Cron-Dialoge).
    foreach ($req in @(@('ApproveLabel', $ApproveLabel), @('UnauthorizedReply', $UnauthorizedReply))) {
        if ([string]::IsNullOrWhiteSpace($req[1])) { throw "New-TelegramSendAndWaitNode '$Name': -$($req[0]) fehlt (Text in der Sprache des Empfaengers aus der t-Map)" }
    }
    if ($ApprovalType -eq 'double' -and [string]::IsNullOrWhiteSpace($DisapproveLabel)) {
        throw "New-TelegramSendAndWaitNode '$Name': -DisapproveLabel fehlt (approvalType double)"
    }
    # Default nur fuer ein LITERALES Ziel (__OWNER_CHAT_ID__); ein Ziel-AUSDRUCK braucht ein ausdrueckliches ApproverIds mit
    # .first() + Fallback ('-1'), weil $json/.item beim Tipp (Webhook-Kontext) nicht mehr das Original-Item ist.
    if (-not $ApproverIdsExpr) {
        if ($ChatIdExpr -like '=*') { throw "New-TelegramSendAndWaitNode '$Name': Ziel ist ein Ausdruck -> -ApproverIdsExpr ausdruecklich setzen (.first(), Fallback '-1')" }
        $ApproverIdsExpr = $ChatIdExpr
    }
    if ([string]::IsNullOrWhiteSpace($ApproverIdsExpr)) { throw "New-TelegramSendAndWaitNode '$Name': ApproverIds leer (hiesse: jeder darf bestaetigen)" }
    if ($ApproverIdsExpr -match '\.item\b') { throw "New-TelegramSendAndWaitNode '$Name': ApproverIds-Ausdruck mit .item traegt im Webhook-Kontext nicht -> .first()" }
    # Texte (Labels, Popup) werden teils im Webhook-Kontext neu ausgewertet (n8n liest unauthorizedReplyText beim
    # Tipp) -> nur .first(). Und Text-Knoten entscheiden NIE ueber Empfaenger/Tipp-Berechtigung (Sicherheits-
    # Invariante des Gates): chatId/approverIds duerfen 'Render texts'/'Compose messages' nicht referenzieren.
    foreach ($tx in @($ApproveLabel, $DisapproveLabel, $UnauthorizedReply)) {
        if ($tx -match '\.item\b') { throw "New-TelegramSendAndWaitNode '$Name': Text-Ausdruck mit .item traegt im Webhook-Kontext nicht -> .first()" }
    }
    foreach ($tx in @($ChatIdExpr, $ApproverIdsExpr)) {
        if ($tx -match "Render texts|Compose messages") { throw "New-TelegramSendAndWaitNode '$Name': chatId/approverIds duerfen nie aus den Text-Knoten kommen (Sicherheits-Invariante)" }
    }
    $approval = [ordered]@{ approvalType = $ApprovalType; approveLabel = $ApproveLabel }
    if ($ApprovalType -eq 'double') { $approval['disapproveLabel'] = $DisapproveLabel }
    $params = [ordered]@{
        resource = 'message'; operation = 'sendAndWait'
        chatId = $ChatIdExpr
        message = (Resolve-TgTextExpr $MessageExpr $NoEscape.IsPresent)
        approvalOptions = [ordered]@{ values = $approval }
        chatApproval = '__HITL_CHAT_APPROVAL__'
        approverIds = $ApproverIdsExpr
        unauthorizedReplyText = $UnauthorizedReply
        postDecisionBehavior = 'removeButtons'
        options = [ordered]@{ appendAttribution = $false }
    }
    if ($LimitWaitMinutes -gt 0) {
        $params.options['limitWaitTime'] = [ordered]@{ values = [ordered]@{
            limitType = 'afterTimeInterval'; resumeAmount = $LimitWaitMinutes; resumeUnit = 'minutes' } }
    }
    [ordered]@{
        parameters = $params
        type = 'n8n-nodes-base.telegram'; typeVersion = 1.2; position = $Pos
        id = (New-Id); name = $Name
        retryOnFail = $true; maxTries = $MaxTries; waitBetweenTries = $WaitBetweenTries
        credentials = @{ telegramApi = $CRED_TELEGRAM }; webhookId = (New-Id)
    }
}

# Stale-Tap-Schutz fuer MEHRERE Bestaetigungs-Fragen nacheinander in EINER Execution (Cron-Dialoge, Schleifen).
# Grund: n8n bindet einen Chat-Bestaetigungs-Tipp an die Execution, nicht an die Nachricht (Telegram hitl/webhook.js
# vergleicht message_id nicht). Ein Doppel-Tipp auf Frage 1 koennte so die schon wartende Frage 2 beantworten
# (z. B. "ueberspringen" ungesehen). Der Guard merkt sich je Execution die beantworteten message_ids
# ($execution.customData, Wert max. 255 Zeichen -> die letzten 20) und schickt einen Tipp auf eine schon
# beantwortete Nachricht zurueck an die Frage (sie wird neu gestellt). Link-Knoepfe (chatApproval aus) liefern keine
# messageId -> nie "stale" (deren Resume-URL ist ohnehin an den Node gebunden).
# Rueckgabe: @{ Nodes; Connections } — komplette Verdrahtung Frage -> Guard -> (frisch) $Next | (stale) Frage; der
# Aufrufer merged beides und verdrahtet die Frage NICHT mehr selbst.
function New-StaleTapGuard {
    param([Parameter(Mandatory)][string]$AskName, [Parameter(Mandatory)][string]$Next, [int[]]$Pos)
    $code = [ordered]@{
        parameters = [ordered]@{
            mode   = 'runOnceForEachItem'   # haelt die Item-Paarung -> nachgelagerte $('Loop Over Items').item tragen
            jsCode = @'
// Stale-Tap-Schutz (New-StaleTapGuard): Tipp auf eine schon beantwortete Nachricht?
const d = ($input.item.json || {}).data || {};
const id = (d.messageId === undefined || d.messageId === null) ? '' : String(d.messageId);
const seen = String($execution.customData.get('hitl_seen') || '').split(',').filter(Boolean);
const stale = id !== '' && seen.includes(id);
if (!stale && id !== '') $execution.customData.set('hitl_seen', seen.concat(id).slice(-20).join(','));
return { json: Object.assign({}, $input.item.json, { stale_tap: stale }) };
'@
        }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = $Pos
        id = (New-Id); name = "$AskName (tap check)"
    }
    $if = Build-If "$AskName (fresh tap?)" @(($Pos[0] + 180), $Pos[1]) "={{ `$json.stale_tap }}" 'false' 'equals' 'boolean'   # true = frisch
    $conns = [ordered]@{
        $AskName       = @{ main = @( ,@( E $code.name ) ) }
        ($code.name)   = @{ main = @( ,@( E $if.name ) ) }
        ($if.name)     = @{ main = @(
            @( E $Next ),      # [0] frischer Tipp -> Antwort auswerten
            @( E $AskName )    # [1] Tipp auf eine schon beantwortete Nachricht -> Frage neu stellen
        ) }
    }
    @{ Nodes = @($code, $if); Connections = $conns }
}

# Telegram-Send (sendMessage) MIT Inline-Keyboard (Antipp-Buttons -> callback_query). Wie
# New-TelegramSendNode (Attribution/Retry/Markdown-Escape des dynamischen Texts), zusaetzlich
# replyMarkup='inlineKeyboard' + EINE Button-Reihe. $Buttons = Array @{ Text=<sichtbar>; Data=<callback_data> };
# -Rows statt -Buttons = mehrere Reihen (Array von Button-Arrays, z. B. ein Knopf je Reihe).
# Data ist KEIN Nutzer-Text (kein parse_mode) -> nicht escapt, darf eine n8n-Expression sein
# (z. B. "={{ 'confirm:' + ... }}"). n8n baut daraus reply_markup.inline_keyboard (GenericFunctions
# addAdditionalFields: rows[].row.buttons[].{text, additionalFields.callback_data}); verifiziert n8n 2.21.7, auf 2.44.4 bestaetigt (hitl_gate_test).
function New-TelegramInlineKeyboardSendNode {
    param([string]$Name, [int[]]$Pos, [string]$TextExpr, [array]$Buttons, [array]$Rows,
          [string]$ChatIdExpr = '__OWNER_CHAT_ID__',
          [switch]$NoEscape, [int]$MaxTries = 3, [int]$WaitBetweenTries = 2000)
    $toBtn = { param($b) [ordered]@{ text = $b.Text; additionalFields = [ordered]@{ callback_data = $b.Data } } }
    if (-not $Rows) { $Rows = @( ,@($Buttons) ) }
    $rowNodes = @($Rows | ForEach-Object { [ordered]@{ row = [ordered]@{ buttons = @($_ | ForEach-Object { & $toBtn $_ }) } } })
    [ordered]@{
        parameters = [ordered]@{
            additionalFields = [ordered]@{ appendAttribution = $false }
            chatId      = $ChatIdExpr
            text        = (Resolve-TgTextExpr $TextExpr $NoEscape.IsPresent)
            replyMarkup = 'inlineKeyboard'
            inlineKeyboard = [ordered]@{ rows = $rowNodes }
        }
        type = 'n8n-nodes-base.telegram'; typeVersion = 1.2; position = $Pos
        id = (New-Id); name = $Name
        retryOnFail = $true; maxTries = $MaxTries; waitBetweenTries = $WaitBetweenTries
        credentials = @{ telegramApi = $CRED_TELEGRAM }
    }
}

# Telegram sendMessageDraft ("Bot denkt nach ..."): leerer Text = Platzhalter "Thinking..." (Bot API 9.5+, nur private
# Chats, max. 30 s, verschwindet mit der naechsten Bot-Nachricht). Rein kosmetisch -> KEIN Retry und onError=continue
# (ein Fehlschlag darf nie eine Antwort verzoegern oder einen Alarm ausloesen); keine Nachricht -> kein
# appendAttribution/Markdown (workflow_lint nimmt operation='sendMessageDraft' aus). draftId fest 1 = je Chat
# eine Blase, ein erneuter Aufruf aktualisiert sie (statt eine zweite zu zeigen).
function New-TelegramDraftNode {
    param([string]$Name, [int[]]$Pos, [string]$ChatIdExpr = '__OWNER_CHAT_ID__', [string]$Text = '')
    [ordered]@{
        parameters = [ordered]@{
            resource = 'message'; operation = 'sendMessageDraft'
            chatId = $ChatIdExpr; draftId = 1; text = $Text
            additionalFields = [ordered]@{}
        }
        type = 'n8n-nodes-base.telegram'; typeVersion = 1.2; position = $Pos
        id = (New-Id); name = $Name; onError = 'continueRegularOutput'
        credentials = @{ telegramApi = $CRED_TELEGRAM }
    }
}

# Fire-and-forget-Aufruf von core.sub_show_thinking (Build-CallWorkflow + wartet NICHT + Fehler werden geschluckt) —
# die "Bot denkt nach ..."-Anzeige darf die eigentliche Antwort nie aufhalten. $ChatIdExpr = Ziel-Chat (Ausdruck).
# Davor gehoert ein 'nur private Chats'-IF des Aufrufers (sendMessageDraft gibt es nur dort).
# $ExecutionIdExpr = Lauf mit Schalter agent.thinking_lease -> Erneuerungs-Schleife bis zum Loeschen; den Schalter
# MUSS der Aufrufer vorher synchron anlegen (fn_create_thinking_lease) und VOR seiner Antwort loeschen.
function New-ShowThinkingCallNode {
    param([string]$Name, [int[]]$Pos, [Parameter(Mandatory)][string]$ChatIdExpr, [Parameter(Mandatory)][string]$ExecutionIdExpr)
    $id = Get-RequiredWorkflowId 'core.sub_show_thinking' -Caller "New-ShowThinkingCallNode '$Name'"
    $n = Build-CallWorkflow $Name $Pos $id 'core.sub_show_thinking' ([ordered]@{ chat_id = $ChatIdExpr; execution_id = $ExecutionIdExpr })
    $n.parameters.options = [ordered]@{ waitForSubWorkflow = $false }
    $n['onError'] = 'continueRegularOutput'
    $n
}

# Telegram answerCallbackQuery (resource 'callback'/operation 'answerQuery'): quittiert den Antipp-Button
# (entfernt den Lade-Spinner am Owner-Client; optionaler kurzer Toast $Text <=200 Zeichen, plain, KEIN
# parse_mode -> kein Escape noetig). $QueryIdExpr = ={{ ...callback_query.id }}. Eigene Telegram-Methode,
# KEIN sendMessage -> kein appendAttribution/Markdown (workflow_lint nimmt resource='callback' bewusst aus).
function New-TelegramAnswerCallbackNode {
    param([string]$Name, [int[]]$Pos, [string]$QueryIdExpr, [string]$Text = '',
          [int]$MaxTries = 3, [int]$WaitBetweenTries = 2000)
    $add = [ordered]@{}
    if ($Text) { $add['text'] = $Text }
    [ordered]@{
        parameters = [ordered]@{
            resource = 'callback'; operation = 'answerQuery'
            queryId = $QueryIdExpr
            additionalFields = $add
        }
        type = 'n8n-nodes-base.telegram'; typeVersion = 1.2; position = $Pos
        id = (New-Id); name = $Name
        retryOnFail = $true; maxTries = $MaxTries; waitBetweenTries = $WaitBetweenTries
        credentials = @{ telegramApi = $CRED_TELEGRAM }
    }
}

# Telegram sendDocument (resource 'message'/operation 'sendDocument'): schickt eine Datei aus dem BINARY
# eines Vorgaenger-Nodes (binaryData=true, binaryPropertyName = das Binary-Feld, Default 'data' — muss zum
# Convert-to-File-Output passen). Caption = Legacy-Markdown wie jeder andere Send: n8n setzt parse_mode nur
# bei sendMessage selbst (GenericFunctions addAdditionalFields), hier also explizit — sonst zeigte Telegram die
# Escape-Backslashes der zentral escapten Caption (Katalog-Text, ein Uebersetzer darf _ oder [ schreiben).
# workflow_lint PRUEFT die caption (eigener sendDocument-Zweig liest additionalFields.caption statt .text). WS-5:
# der Notfallmappe-Egress (fn_render_emergency_binder -> Convert to File -> hier). typeVersion 1.2 +
# appendAttribution:false + retryOnFail wie die uebrige New-Telegram*-Familie. Bot-API-Caption-Limit 1024.
function New-TelegramSendDocumentNode {
    param([string]$Name, [int[]]$Pos, [string]$ChatIdExpr = '__OWNER_CHAT_ID__',
          [string]$BinaryProperty = 'data', [string]$Caption = '',
          [int]$MaxTries = 3, [int]$WaitBetweenTries = 2000)
    $addl = [ordered]@{ appendAttribution = $false }
    if ($Caption) {
        $addl['caption'] = (Resolve-TgTextExpr $Caption $false)   # Ausdruck (Katalog-Text) -> zentral escapt
        $addl['parse_mode'] = 'Markdown'
    }
    [ordered]@{
        parameters = [ordered]@{
            resource           = 'message'
            operation          = 'sendDocument'
            chatId             = $ChatIdExpr
            binaryData         = $true
            binaryPropertyName = $BinaryProperty
            additionalFields   = $addl
        }
        type = 'n8n-nodes-base.telegram'; typeVersion = 1.2; position = $Pos
        id = (New-Id); name = $Name
        retryOnFail = $true; maxTries = $MaxTries; waitBetweenTries = $WaitBetweenTries
        credentials = @{ telegramApi = $CRED_TELEGRAM }
    }
}

# ============================================================
# WEITERE GEMEINSAME NODE-BUILDER (vorher in mehreren cron.*-Defs dupliziert)

# Schedule-Trigger; die Cron-Expression ist ein PLATZHALTER `__CFG_SCHEDULE_<KEY>__`, den der Installer beim
# Einspielen aus core.config (category 'schedule', key = $ScheduleKey) einsetzt (deploy_workflows.sh) — so wirkt
# `lifeagents config set schedule <key> …` ohne Neubau. Der scheduleTrigger liest seinen Plan nur beim Aktivieren
# (packages/CLAUDE.md *Scheduled Workflows*). Die Zeile .config.schedule.<key> deklariert das Manifest des Pakets,
# dem der Workflow gehoert (config_test.ps1 (3) prueft beide Richtungen). Key-Form ^[a-z][a-z0-9_]*$ -> die
# Grossschreibung im Platzhalter ist eindeutig (kein Key kann mit einem anderen kollidieren).
function Build-ScheduleTrigger {
    param([int[]]$Pos, [Parameter(Mandatory)][string]$ScheduleKey)
    if ($ScheduleKey -cnotmatch '^[a-z][a-z0-9_]*$') { throw "Build-ScheduleTrigger: ScheduleKey '$ScheduleKey' muss ^[a-z][a-z0-9_]*`$ sein" }
    [ordered]@{
        parameters = [ordered]@{ rule = [ordered]@{ interval = @(
            [ordered]@{ field = 'cronExpression'; expression = "__CFG_SCHEDULE_$($ScheduleKey.ToUpperInvariant())__" }
        ) } }
        type = 'n8n-nodes-base.scheduleTrigger'; typeVersion = 1.3; position = $Pos
        id = (New-Id); name = 'Schedule (cron from config)'
    }
}

function Build-NoOp {
    param([string]$Name, [int[]]$Pos)
    [ordered]@{ parameters = @{}; type = 'n8n-nodes-base.noOp'; typeVersion = 1; position = $Pos
        id = (New-Id); name = $Name }
}

# splitInBatches-Loop: Ausgaenge main[0]=done, main[1]=loop; alle Zweige zurueck zur Loop-Node.
function Build-Loop {
    param([string]$Name, [int[]]$Pos)
    [ordered]@{ parameters = [ordered]@{ options = @{} }; type = 'n8n-nodes-base.splitInBatches'
        typeVersion = 3; position = $Pos; id = (New-Id); name = $Name }
}

# Wrap a workflow definition into the n8n API payload.
# $Manifest (optional, Phase 4 Discoverability): per-Tool-Capability-Hashtable
#   @{ Category='<id>' } (id einer catalog.categories[] des eigenen Pakets) bzw. @{ Internal = $true } —
#   co-located in der Build-Funktion, damit ein neues Tool seine Capability NICHT vergessen kann. Wird als
#   '_manifest' angehaengt; Build-/'_*'-Keys werden von Save-WorkflowFile NIE serialisiert (reine Build-Zeit-
#   Metadaten). Der Katalog-Renderer (lib/catalog.ps1) zeigt nur Kategorien, die ein Tool nutzt; Titel, Beschreibung
#   und Beispiele stehen im Textkatalog (<pkg>.help.<id>.*, Textkatalog Phase B).
function Build-Workflow {
    param([string]$Name, [array]$Nodes, $Connections, $Manifest = $null)
    # NOTE: 'active' is intentionally omitted — n8n API treats it as read-only on POST/PUT.
    # errorWorkflow = die id von core.sub_error_notify, in build.ps1 per Name aus dem State aufgeloest
    # ($ErrorNotifyId) — KEIN ID-Literal mehr. core.sub_error_notify selbst ueberschreibt settings (kein
    # Self-Verweis -> keine Endlos-Alert-Schleife).
    # TEST-STARTPUNKT JE CRON (2026-10-26, schnellere freie Gates): ein Workflow mit dem Zeitplan-Trigger bekommt
    # GENERISCH einen zweiten Einstieg 'Test run' (Build-Trigger, Eingaben leer bis auf chat_id) mit denselben Kanten. Der
    # Test-Eingang core.cron_run.test_harness (nur Test-Instanzen) startet den Cron darueber sofort, statt den Zeitplan
    # auf jede Minute zu stellen und zu warten (cron_text_test). Nur aus n8n selbst erreichbar; kein Cron liest seinen
    # Trigger-Knoten, der Lauf ist mit jedem Start-Item identisch.
    $sched = @($Nodes | Where-Object { $_.name -eq 'Schedule (cron from config)' })
    if ($sched.Count -eq 1 -and -not ($Nodes | Where-Object { $_.name -eq 'Test run' })) {
        $testRun = Build-Trigger @() -Pos @([int]$sched[0].position[0], ([int]$sched[0].position[1] + 180))
        $testRun.name = 'Test run'
        $Nodes = @($Nodes) + $testRun
        $Nodes = @($Nodes) + (Build-Sticky 'Test run (Doc)' @(([int]$sched[0].position[0] - 40), ([int]$sched[0].position[1] + 300)) `
            'Test-Startpunkt (nur Tests)' `
            'Zweiter Einstieg mit denselben Kanten wie der Zeitplan: der Test-Eingang core.cron_run.test_harness (nur auf Test-Instanzen) startet diesen Cron damit sofort (cron_text_test). Im Betrieb ungenutzt; nur aus n8n selbst erreichbar. Gebaut von Build-Workflow (build_helpers.ps1).' 220 300 'Test')
        $Connections['Test run'] = $Connections['Schedule (cron from config)']
    }
    $wf = [ordered]@{
        name        = $Name
        nodes       = $Nodes
        connections = $Connections
        settings    = [ordered]@{ executionOrder = 'v1'; errorWorkflow = $ErrorNotifyId }
    }
    if ($null -ne $Manifest) { $wf['_manifest'] = $Manifest }
    return $wf
}

# ============================================================
# MODELL ZUR LAUFZEIT (Festwert-Phase 2) — kein Config-Wert wird mehr beim Bauen eingebacken.
# Jeder Workflow, der ein konfigurierbares Modell nutzt, liest den model_key bei JEDEM Lauf aus core.config
# (Pg-Knoten 'Load model config'); `lifeagents config set model <key> <wert>` wirkt damit ab dem naechsten Lauf.
# Die Zuordnung model_key -> n8n_model_id backt der Bau aus packages/core/seed/ai_models.json ein (dieselbe Quelle
# und Semantik wie der Umschalter, der sie seit jeher in seine Modell-Knoten schreibt; das Register aendert sich nur
# per Release, Seed und Bau lesen dieselbe Datei). config_test (4) prueft die Bezuege statisch.

# New-ModelConfigNode — DER Pg-Knoten 'Load model config': liest je (Paket, Key) den model_key per
# core.fn_config_get (publiziertes Fenster, an alle Paket-Rollen gegrantet) -> Item { model: { <key>: <model_key> } }.
# Credential = das dynamische $CRED_POSTGRES des Aufrufers (Build-Pg; z. B. finance_rw im Belege-Tool).
# Jeder (Paket, Key) muss als .config.model.<key> im Manifest des Pakets stehen (Build-Fehler statt stillem NULL).
# json (nicht jsonb) wie der learn-Cron — das Ergebnis kommt als Objekt am Item an.
function New-ModelConfigNode {
    param(
        [Parameter(Mandatory)][int[]]$Position,
        [Parameter(Mandatory)][object[]]$Keys,          # @( @('core','panel_a'), @('core','panel_b') )
        [string]$Name = 'Load model config'
    )
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $items = @()
    foreach ($pair in $Keys) {
        $pkg = [string]$pair[0]; $key = [string]$pair[1]
        if ($pkg -cnotmatch '^[a-z][a-z0-9_]*$' -or $key -cnotmatch '^[a-z][a-z0-9_]*$') { throw "New-ModelConfigNode: ungueltiges Paket/Key '$pkg'/'$key'" }
        $mf = "$RepoRoot\packages\$pkg\manifest.json"
        if (-not (Test-Path $mf)) { throw "New-ModelConfigNode: Paket '$pkg' hat kein manifest.json" }
        $entry = ([System.IO.File]::ReadAllText($mf, $u8) | ConvertFrom-Json).config.model.$key
        if ($null -eq $entry) { throw "New-ModelConfigNode: '$pkg' deklariert config.model.$key nicht in $mf" }
        $items += [ordered]@{ pkg = $pkg; key = $key }
    }
    Build-Pg $Name $Position `
        "=SELECT json_object_agg(e->>'key', core.fn_config_get(e->>'pkg', 'model', e->>'key')) AS model FROM jsonb_array_elements((`$1::jsonb)->'items') AS e" `
        ([ordered]@{ items = (ConvertTo-JsLiteral -Value @($items)) })
}

# Get-ModelIdMapJs — JS-Objekt-Literal { model_key: n8n_model_id } aller Claude-Chat-Modelle des Registers
# (provider Anthropic, mode chat). EINE Quelle fuer den HTTP-Body (New-AnthropicMessagesNode) und das
# Modell-Etikett im expert_panel. Ein model_key ausserhalb der Zuordnung ergibt zur Laufzeit undefined.
function Get-ModelIdMapJs {
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $map = [ordered]@{}
    $models = ([System.IO.File]::ReadAllText("$RepoRoot\packages\core\seed\ai_models.json", $u8) | ConvertFrom-Json) |
        Where-Object { $_.provider -eq 'Anthropic' -and $_.mode -eq 'chat' } | Sort-Object selector_index
    foreach ($m in $models) { $map[[string]$m.model_key] = [string]$m.n8n_model_id }
    if ($map.Count -eq 0) { throw 'Get-ModelIdMapJs: keine Claude-Chat-Modelle in packages/core/seed/ai_models.json' }
    return (ConvertTo-JsLiteral -Value $map)
}

# ============================================================
# New-LmChatNode — die EINE Quelle fuer EINEN Modell-Node aus einem model_key.
# Liest packages/core/seed/ai_models.json, loest n8n_model_id auf und emittiert
#   @n8n/n8n-nodes-langchain.lmChatAnthropic (typeVersion 1.5), options.thinkingMode='adaptive',
#   KEINE Sampling-Parameter (die 5.5-Generation lehnt temperature mit 400 ab).
# Chat-Modelle sind seit Modell-Phase 2 nur noch Claude (Owner-Entscheid 2026-10-19); ein Register-Eintrag eines
# anderen Anbieters oder ein Embedding-Modell am Chat-Node bricht den BAU ab (statt still einen fremden Node zu bauen).
# Seit Festwert-Phase 2 nur noch der interne Knoten-Bauer des Model-Selector-Bundles (ein Node je Chat-Modell des
# Registers) -> Node-Konventionen leben an EINER Stelle; Einzel-Modell-Verbraucher gibt es nicht mehr (jedes Modell
# ist zur Laufzeit umschaltbar).
#
# DENK-TIEFE + ANTWORTLAENGE (Anthropic, Node v1.5 — Node-Source 2.21.7 + 2.44.4 verifiziert): adaptive -> invocationKwargs
# thinking:{type:'adaptive'} + output_config:{effort}. Ohne Wert gilt effort 'medium' und max_tokens 4096 —
# Denken zaehlt zu max_tokens (5.5-Generation denkt immer mit) -> 4096 schneidet Antworten STILL ab.
# Daher setzt jeder Verbraucher -Effort bewusst (low|medium|high; xhigh/max zeigt der Node nur fuer Opus)
# und max_tokens ist grosszuegig 16000 (maxTokensToSample).
#
# PROMPT-CACHING: setzt NICHT dieser Node, sondern der lokale LLM-Gateway (provisioning/llm_gateway), auf den
# die Anthropic-Credential (url) zeigt — Haltepunkte am letzten Werkzeug + System-Ende (1h) + oben (5 Min).
# Node v1.5 (unser Pin) hat keine Caching-Option (Node-Source 2.44.4 geprueft); die eingebaute Option ab n8n 2.37 (Node v1.6) setzt nur den oberen
# Haltepunkt (kein Treffer ueber Gespraeche/Testfaelle) -> auch nach einem n8n-Update NICHT einschalten (der
# Gateway erkennt einen vorhandenen oberen Marker und laesst ihn stehen; brachte nichts zusaetzlich).
function New-LmChatNode {
    param(
        [Parameter(Mandatory)][string]$ModelKey,   # model_key aus der Registry
        [string]$Name = $null,                       # Node-Name; Default = ModelKey
        [int[]]$Position = @(0, 0),
        $Models = $null,                             # vorgeladene Registry (optional, sonst lesen)
        [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high')][string]$Effort,   # Denk-Tiefe (Anthropic), bewusst je Verbraucher
        [int]$MaxTokens = 16000,                     # Antwortlaenge inkl. Denken (Anthropic)
        $AnthropicCred = $null
    )
    if ($null -eq $AnthropicCred) { $AnthropicCred = $CRED_ANTHROPIC }
    if ($null -eq $Models) {
        $u8 = New-Object System.Text.UTF8Encoding($false)
        $Models = [System.IO.File]::ReadAllText("$RepoRoot\packages\core\seed\ai_models.json", $u8) | ConvertFrom-Json
    }
    $m = $Models | Where-Object { $_.model_key -eq $ModelKey }
    if (-not $m) { throw "New-LmChatNode: model_key '$ModelKey' nicht in packages/core/seed/ai_models.json" }
    if ($m.provider -ne 'Anthropic' -or $m.mode -ne 'chat') {
        throw "New-LmChatNode: model_key '$ModelKey' ist kein Claude-Chat-Modell (provider '$($m.provider)', mode '$($m.mode)') — Chat-Nodes bauen nur Anthropic"
    }
    if ([string]::IsNullOrEmpty($Name)) { $Name = $ModelKey }

    $cachedName = @{
        'claude-haiku-5-5'  = 'Claude Haiku 5.5'
        'claude-sonnet-5-5' = 'Claude Sonnet 5.5'
        'claude-opus-5-5'   = 'Claude Opus 5.5'
    }
    $model = [ordered]@{ '__rl' = $true; mode = 'list'; value = $m.n8n_model_id }
    if ($cachedName.ContainsKey($m.n8n_model_id)) { $model['cachedResultName'] = $cachedName[$m.n8n_model_id] }
    return [ordered]@{
        # Bewusst KEIN Caching-Key in 'options' — Prompt-Caching macht der LLM-Gateway (Kommentar oben).
        parameters  = [ordered]@{ model = $model; options = [ordered]@{ maxTokensToSample = $MaxTokens; thinkingMode = 'adaptive'; effort = $Effort } }
        type        = '@n8n/n8n-nodes-langchain.lmChatAnthropic'
        typeVersion = 1.5
        position    = @([int]$Position[0], [int]$Position[1])
        id          = (New-Id)
        name        = $Name
        credentials = @{ anthropicApi = $AnthropicCred }
    }
}

# ============================================================
# MODEL SELECTOR BUNDLE — die EINE Quelle fuer den Modell-Selektor (ueberall identisch).
# Je Selector-Zeile der Registry (selector_index NOT NULL) ein Modell-Node (Name = model_key aus
# packages/core/seed/ai_models.json) + Model Selector mit einer Regel je Zeile. -Effort = Denk-Tiefe des
# Verbrauchers (gilt fuer alle seine Anthropic-Nodes). Pro Use-Case waehlt NUR der Config-Wert (model.<consumer>) das
# aktive Modell — kein Tier-Schema mehr ([LIGHT]/[STANDARD]/[ADVANCED] sind obsolet).
# Anzahl Nodes/Regeln = Anzahl Chat-Zeilen der Registry (heute 3: Haiku/Sonnet/Opus), nie hart verdrahtet.
# Anthropic-Nodes: adaptives Thinking an, KEINE Sampling-Parameter (New-LmChatNode). Modell-IDs + selector_index
# kommen aus der Registry -> ein selector_index-Drift wie der alte "alle auf Sonnet"-Bug ist ausgeschlossen.
# Rueckgabe: @{ Nodes = <je Chat-Modell ein Node + Selector>; Connections = <ordered: je Modell -> Selector, Selector -> Agent> }.
# -NamePrefix: zwei Umschalter in EINEM Workflow (expert_panel: Lane A + Lane B) — n8n verlangt eindeutige Knoten-Namen,
#   und die Verbindungen sind ueber den Namen verdrahtet -> der Praefix gilt fuer Modell-Knoten, Selector-Name,
#   Verbindungs-Schluessel UND -Ziel. Default '' = Bestands-Ausgabe unveraendert.
# -FirstConfigItem: die Regeln lesen $('<ConfigNode>').first() statt .item — fuer Verbraucher, bei denen zwischen dem
#   Config-Knoten (genau 1 Zeile) und der Kette Code-Knoten liegen, deren Item-Zuordnung n8n nicht garantiert
#   (Advisor-Crons, Panel). Bestand (Agenten, learn-Cron) bleibt bei .item.
function New-ModelSelectorBundle {
    param(
        [Parameter(Mandatory)][string]$ConfigField,     # z. B. 'model.finance' / 'model.finance_advisor' / 'model.orchestrator'
        [Parameter(Mandatory)][string]$ConfigNodeName,  # Node, der die Config liefert: Agenten 'Load Config', Orchestrator 'Load core.config'
        [Parameter(Mandatory)][string]$AgentNodeName,   # AI-Agent-Node, an den der Selector haengt
        [int[]]$SelectorPos = @(-688, 208),
        [int[]]$ModelRowPos = @(-848, 416),             # Basis-Position der ersten Modell-Node; weitere rechts daneben
        [int]$ModelDx = 176,
        [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high')][string]$Effort,
        [string]$NamePrefix = '',
        [switch]$FirstConfigItem,
        $AnthropicCred = $null
    )
    if ($null -eq $AnthropicCred) { $AnthropicCred = $CRED_ANTHROPIC }
    $selectorName = "${NamePrefix}Model Selector"
    $accessor = if ($FirstConfigItem) { 'first()' } else { 'item' }
    $u8 = New-Object System.Text.UTF8Encoding($false)
    # Nur Chat-Zeilen (mode='chat' <=> selector_index gesetzt, DB-CHECK + config_test 5): Embeddings (z. B.
    # gemini-embedding-001) VOR Sort/Node-Bau UND Regel-Bau filtern — [int]$null waere 0 -> index -1 = ungueltige
    # Connection fuer JEDEN Selector-Konsumenten. Die Chat-Nummern sind lueckenlos 1..n (config_test 5), weil der
    # Selector Eingang selector_index-1 bei numberInputs = n verdrahtet.
    # Klammerung PFLICHT (PS-5.1-Quirk): ConvertFrom-Json reicht das Array als EIN Pipeline-Objekt
    # weiter — ein direkt angehaengtes Where-Object filtert sonst NIE.
    $models = ([System.IO.File]::ReadAllText("$RepoRoot\packages\core\seed\ai_models.json", $u8) | ConvertFrom-Json) |
        Where-Object { $_.mode -eq 'chat' } | Sort-Object selector_index

    $nodes = @()
    $conns = [ordered]@{}
    $i = 0
    foreach ($m in $models) {
        $px = [int]$ModelRowPos[0] + ([int]$i * [int]$ModelDx)
        # Jeder Modell-Node aus der EINEN Quelle New-LmChatNode (Thinking, Denk-Tiefe, Caching-Wiring).
        $nodes += (New-LmChatNode -ModelKey $m.model_key -Name "$NamePrefix$($m.model_key)" -Position @($px, [int]$ModelRowPos[1]) `
                       -Models $models -Effort $Effort -AnthropicCred $AnthropicCred)
        # Modell-Node -> Model Selector am Eingang selector_index-1 (Array-Form via Komma-Operator).
        $conns["$NamePrefix$($m.model_key)"] = @{ ai_languageModel = @( ,@( @{ node = $selectorName; type = 'ai_languageModel'; index = ([int]$m.selector_index - 1) } ) ) }
        $i++
    }

    # Je Chat-Modell eine Regel: model_key (Config-Wert) -> selector_index. leftValue referenziert den Config-Node.
    $rules = @()
    foreach ($m in $models) {
        $rules += [ordered]@{
            modelIndex = [int]$m.selector_index
            conditions = [ordered]@{
                options    = [ordered]@{ caseSensitive = $true; leftValue = ''; typeValidation = 'strict'; version = 2 }
                conditions = @(
                    [ordered]@{
                        id         = (New-Id)
                        leftValue  = "={{ `$('$ConfigNodeName').$accessor.json.$ConfigField }}"
                        rightValue = $m.model_key
                        operator   = [ordered]@{ type = 'string'; operation = 'equals'; name = 'filter.operator.equals' }
                    }
                )
                combinator = 'and'
            }
        }
    }
    $selector = [ordered]@{
        # numberInputs aus der GEFILTERTEN Chat-Modell-Anzahl abgeleitet (nie hart verdrahtet) — eine
        # neue/entfernte Selector-Zeile in ai_models.json kann so nie still vom Node-Input-Satz driften.
        parameters  = [ordered]@{ numberInputs = [int](@($models).Count); rules = [ordered]@{ rule = $rules } }
        type        = '@n8n/n8n-nodes-langchain.modelSelector'
        typeVersion = 1
        position    = $SelectorPos
        id          = (New-Id)
        name        = $selectorName
    }
    $nodes += $selector
    $conns[$selectorName] = @{ ai_languageModel = @( ,@( @{ node = $AgentNodeName; type = 'ai_languageModel'; index = 0 } ) ) }

    return @{ Nodes = $nodes; Connections = $conns }
}

# ============================================================
# ANTHROPIC MESSAGES (HTTP) — die EINE Quelle fuer direkte Claude-Aufrufe ohne Agent/Chain.
# Fuer Pfade, die der lmChatAnthropic-Node nicht kann: Bild/PDF-Bloecke, Structured Output
# (output_config.format), Server-Tool web_search. Konsumenten: tool_web_search, Monitor-Wert-
# beschaffung (monitor_helpers.ps1), Belege-/Lebenslauf-Extraktion, Job-Scorer.
# Warum HTTP statt nativem n8n-Anthropic-Node: scripts/build/CLAUDE.md *Modell-Node-Builder* (arch-challenge 2026-10-19).
# Bewusst kein -AnthropicCred-Override (kein Konsument braucht ihn; anders als New-LmChatNode).
# Denken: kein thinking-Parameter -> die 5.5-Generation denkt adaptiv; effort steuert die Tiefe.
# max_tokens grosszuegig (Denken zaehlt mit). Auswertung IMMER ueber Get-AnthropicResultJs (stop_reason!).
# URL = der lokale LLM-Gateway (provisioning/llm_gateway, 127.0.0.1:8090) statt api.anthropic.com: er misst die
# Nutzung (Kosten-Report, Header x-lifeagents-workflow = Workflow) und reicht unveraendert weiter — gecacht wird hier NICHT (Einmal-Aufruf ohne eigene
# Werkzeuge; ein Cache-Eintrag wuerde 1,25x/2x kosten und nie gelesen). Im Mock-Tier landet der Aufruf so beim
# Mock statt kostenpflichtig bei Anthropic.

# ConvertTo-JsLiteral — PS-Wert als JS-Literal fuer einen n8n-Ausdruck. n8n trennt Ausdruecke an
# '{{'/'}}' -> Struktur-Klammern werden auseinandergezogen; ein String MIT '{{'/'}}' wirft (Build-Fehler
# statt still kaputtem Ausdruck). ConvertTo-Json escaped ' < > & als \u00xx -> sicher im Ausdruck.
function ConvertTo-JsLiteral {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [string]) {
        if ($Value.Contains('{{') -or $Value.Contains('}}')) { throw "ConvertTo-JsLiteral: Text enthaelt '{{' oder '}}' (bricht den n8n-Ausdruck)" }
        return (ConvertTo-Json -InputObject $Value -Compress)
    }
    $j = ConvertTo-Json -InputObject $Value -Depth 30 -Compress
    while ($j.Contains('}}')) { $j = $j.Replace('}}', '} }') }
    while ($j.Contains('{{')) { $j = $j.Replace('{{', '{ {') }
    return $j
}

# New-AnthropicMessagesNode — HTTP-Request-Node auf /v1/messages (laeuft per Item).
#   -ConfigModelKey  Modell-Key in core.config (z. B. 'web_search'); das Modell kommt zur LAUFZEIT aus dem
#               Pg-Knoten -ConfigNodeName (New-ModelConfigNode, MUSS vorher im Pfad liegen) und wird ueber die
#               eingebackene Zuordnung (Get-ModelIdMapJs) zur n8n_model_id. .first(): der Config-Knoten hat genau
#               EINE Zeile, auch wenn der HTTP-Knoten viele Items abarbeitet (Monitor-Cron). Unbekannter/leerer
#               Key -> model null -> Anthropic 400 -> anthropicText {ok:false} (nie still ein anderes Modell).
#   -System     statischer System-Text (EN, Layer 1)
#   -ContentJs  roher JS-Ausdruck fuer den user-content (String ODER Block-Array, z. B. Bild/PDF + Text)
#   -JsonSchema optional: Antwort als JSON nach Schema (output_config.format, Wurzel = object)
#   -WebSearchMaxUses >0: Server-Tool web_search_20260209 (live verifiziert auf Haiku/Sonnet 5.5, auch zusammen mit
#               -JsonSchema; laut Anthropic-Doku auf allen Modellen ab Claude 4.6 verfuegbar -> keine Modell-Weiche)
function New-AnthropicMessagesNode {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int[]]$Position,
        [Parameter(Mandatory)][string]$ConfigModelKey,
        [string]$ConfigNodeName = 'Load model config',
        [Parameter(Mandatory)][string]$System,
        [Parameter(Mandatory)][string]$ContentJs,
        [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high')][string]$Effort,
        [int]$MaxTokens = 16000,
        $JsonSchema = $null,
        [int]$WebSearchMaxUses = 0,
        [int]$TimeoutMs = 120000
    )
    if ($ContentJs.Contains('{{') -or $ContentJs.Contains('}}')) { throw "New-AnthropicMessagesNode '$Name': -ContentJs enthaelt '{{' oder '}}' (bricht den n8n-Ausdruck) — Klammern mit Leerzeichen trennen" }
    if ($ConfigModelKey -cnotmatch '^[a-z][a-z0-9_]*$') { throw "New-AnthropicMessagesNode '$Name': -ConfigModelKey '$ConfigModelKey' muss ^[a-z][a-z0-9_]*`$ sein" }
    $outCfg = "output_config: { effort: '$Effort'"
    if ($null -ne $JsonSchema) { $outCfg += ", format: { type: 'json_schema', schema: $(ConvertTo-JsLiteral $JsonSchema) }" }
    $outCfg += ' }'
    $modelExpr = '(' + (Get-ModelIdMapJs) + "[`$('$ConfigNodeName').first().json.model.$ConfigModelKey] || null)"
    $fields = @(
        " model: $modelExpr",
        " max_tokens: $MaxTokens",
        " system: $(ConvertTo-JsLiteral $System)",
        " messages: [{ role: 'user', content: ($ContentJs) }]",
        " $outCfg"
    )
    if ($WebSearchMaxUses -gt 0) { $fields += " tools: [{ type: 'web_search_20260209', name: 'web_search', max_uses: $WebSearchMaxUses }]" }
    $jsonBody = '={{ JSON.stringify({' + ($fields -join ',') + ' }) }}'
    [ordered]@{
        parameters = [ordered]@{
            method = 'POST'
            url = 'http://127.0.0.1:8090/v1/messages'   # lokaler LLM-Gateway (Messung; Einmal-Aufruf -> kein Caching)
            authentication = 'predefinedCredentialType'
            nodeCredentialType = 'anthropicApi'
            sendHeaders = $true
            # x-lifeagents-workflow: Workflow-Kennung fuer den Kosten-Report (/kosten); der Gateway misst sie und reicht sie
            # nie an Anthropic weiter (provisioning/llm_gateway/server.js). Agenten/Ketten tragen sie als Kennzeile
            # (Add-LlmWorkflowTag in workflow_lifecycle.ps1), weil lmChatAnthropic keinen Header je Knoten kann.
            headerParameters = @{ parameters = @(
                [ordered]@{ name = 'anthropic-version'; value = '2023-06-01' },
                [ordered]@{ name = 'x-lifeagents-workflow'; value = '={{ $workflow.name }}' }
            ) }
            sendBody = $true
            specifyBody = 'json'
            jsonBody = $jsonBody
            options = [ordered]@{ timeout = $TimeoutMs }
        }
        type = 'n8n-nodes-base.httpRequest'
        typeVersion = 4.4
        position = @([int]$Position[0], [int]$Position[1])
        id = (New-Id)
        name = $Name
        retryOnFail = $true; maxTries = 2; waitBetweenTries = 3000
        onError = 'continueRegularOutput'
        credentials = @{ anthropicApi = $CRED_ANTHROPIC }
    }
}

# Get-AnthropicFileBlockJs — JS-Ausdruck fuer EINEN Datei-Block aus base64 + MIME (Telegram-Download via
# agent.tool_fetch_telegram_file): PDF -> document-Block, sonst image-Block (jpeg/png/gif/webp — die
# Allow-List erzwingt der Download-Baustein). Liefert ein Block-OBJEKT (der Aufrufer baut das Array).
function Get-AnthropicFileBlockJs {
    param([Parameter(Mandatory)][string]$B64Expr, [Parameter(Mandatory)][string]$MimeExpr)
    "(($MimeExpr) === 'application/pdf' ? { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: ($B64Expr) } } : { type: 'image', source: { type: 'base64', media_type: ($MimeExpr), data: ($B64Expr) } })"
}

# Get-AnthropicResultJs — JS-Prelude fuer den auswertenden Code-Node: definiert
#   anthropicText(r) -> { ok:true, text } | { ok:false, error }   (alle text-Bloecke OHNE Trenner zusammengefuegt —
#     Zitate splitten EINEN Text an Quellen-Grenzen in mehrere Bloecke, ein '\n' braeche JSON-Strings;
#     HTTP-Fehler/onError-Objekt, stop_reason max_tokens|refusal|pause_turn und leere Antwort -> ok:false,
#     nie eine still abgeschnittene Antwort)
#   stripFences(t) -> t ohne ```json-Zaun
function Get-AnthropicResultJs {
    @'
const anthropicText = (r) => {
  if (!r || !Array.isArray(r.content)) {
    const m = (r && r.error && (r.error.message || r.error.type || r.error.description)) || 'no response';
    return { ok: false, error: String(m).slice(0, 200) };
  }
  if (r.stop_reason === 'max_tokens') return { ok: false, error: 'answer truncated (max_tokens)' };
  if (r.stop_reason === 'refusal') return { ok: false, error: 'model declined the request' };
  if (r.stop_reason === 'pause_turn') return { ok: false, error: 'web search did not finish (pause_turn)' };
  const text = r.content.filter(b => b && b.type === 'text' && b.text).map(b => b.text).join('').trim();
  if (!text) return { ok: false, error: 'empty answer' };
  return { ok: true, text };
};
const stripFences = (t) => String(t).replace(/^\s*```[a-z]*\s*/i, '').replace(/\s*```\s*$/, '');
'@
}
