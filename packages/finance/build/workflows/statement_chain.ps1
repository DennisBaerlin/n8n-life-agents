#Requires -Version 5.1
# Die geteilte Monats-Check-Kette (Broker-CSV Paket B: 2. Konsument -> vereinheitlicht): Prepare statement
# (finance.fn_statement_prepare) -> Karte -> Gate -> Apply statement (finance.fn_apply_bank_statement, fingerprint aus der
# Karte) -> Return. Konsumenten: tool_reconcile_bank_statement (gedruckter Auszug per Vision) und tool_import_bank_export
# (Bank-Export-Datei per festem Leser). Die Rohwerte ($StmtParams) liefert der Konsument; alles Rechnen + die Kartenzeilen
# kommen aus der DB (eine Adresse). Helper-Datei ohne Build-* (Builder-Discovery liefert 0 Builder); gelesen nur in
# Funktionskoerpern -> Ladereihenfolge egal.
#
# New-StatementGateChain -X <Start-x> -StmtParams <[ordered] Rohwerte fuer Build-Pg> -Title <finance.hitl.*>
#   -CancelAction <ASCII, Build-ToolCancelled> [-ReturnExtra <@(,@(name, expr, type))> ]
#   -> @{ Nodes; Conns; Entry = 'Prepare statement' }. Der Konsument verbindet seinen letzten Knoten mit Entry.
function New-StatementGateChain {
    param([int]$X, [Parameter(Mandatory)]$StmtParams, [Parameter(Mandatory)][string]$Title,
          [Parameter(Mandatory)][string]$CancelAction, [array]$ReturnExtra = @())
    $prepare = Build-Pg 'Prepare statement' @($X, 0) "=SELECT finance.fn_statement_prepare(`$1::jsonb) AS r;" $StmtParams
    $ifPrep = Build-If 'Statement ok?' @(($X + 220), 0) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    $P = "`$('Prepare statement').item.json.r"
    $errPrep = Build-Set 'Statement not ready' @(($X + 440), 200) @(
        ,@('ok', 'false', 'boolean')
        ,@('code', "={{ $P.code }}", 'string')
        ,@('error', "={{ $P.reason }}", 'string')
        ,@('candidates', "={{ $P.candidates || [] }}", 'array')
        ,@('account_number', "={{ $P.account_number || '' }}", 'string')
        ,@('difference', "={{ $P.difference === undefined || $P.difference === null ? '' : String($P.difference) }}", 'string')
        ,@('balance_verified', "={{ $P.balance_verified === true }}", 'boolean')
        ,@('closing_balance', "={{ $P.closing_balance === undefined || $P.closing_balance === null ? '' : String($P.closing_balance) }}", 'string')
        ,@('balance_date', "={{ $P.balance_date || '' }}", 'string')
        ,@('currency', "={{ $P.currency || '' }}", 'string')
        # Pool-Regel (transfer_choice_required): die EINE unklare Zahlung, damit der Agent sie beim Nachfragen nennt
        ,@('payment_amount', "={{ $P.amount === undefined || $P.amount === null ? '' : String($P.amount) }}", 'string')
        ,@('payment_date', "={{ $P.date || '' }}", 'string')
    )

    $summary = New-HitlSummary -Pos @(($X + 440), 0) -Title $Title `
        -TitleParams @{ account = "$P.account_name" } -LinesExpr "($P.card_lines || [])"
    $reqApproval = Build-CallWorkflow 'Request Approval' @(($X + 660), 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').first().json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(($X + 880), 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(($X + 1100), 200) $CancelAction

    $applyParams = [ordered]@{}
    foreach ($k in $StmtParams.Keys) { $applyParams[$k] = $StmtParams[$k] }
    $applyParams['fingerprint'] = "$P.fingerprint"
    $apply = Build-Pg 'Apply statement' @(($X + 1100), 0) "=SELECT finance.fn_apply_bank_statement(`$1::jsonb) AS r;" $applyParams
    $ifApplied = Build-If 'Booked?' @(($X + 1320), 0) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    $A = "`$('Apply statement').item.json.r"
    $errApply = Build-Set 'Not booked' @(($X + 1540), 200) @(
        ,@('ok', 'false', 'boolean')
        ,@('code', "={{ $A.code || '' }}", 'string')
        ,@('error', "={{ $A.reason }}", 'string')
    )
    $retList = @(
        ,@('ok', 'true', 'boolean')
        ,@('account_name', "={{ $P.account_name }}", 'string')
        ,@('period_start', "={{ $P.period_start }}", 'string')
        ,@('period_end', "={{ $P.period_end }}", 'string')
        ,@('currency', "={{ $P.currency }}", 'string')
        ,@('booked_count', "={{ $A.booked_count }}", 'number')
        ,@('everyday_spending', "={{ $A.lump_amount }}", 'number')
        ,@('difference_before_period', "={{ $A.drift_amount }}", 'number')
        ,@('skipped_payments', "={{ $A.skipped_occurrences }}", 'number')
        ,@('plan_adjusted', "={{ $A.plan_adjusted || [] }}", 'array')
        ,@('savings_plan_estimated', "={{ $A.savings_plan_estimated || [] }}", 'array')
        ,@('unknown_direct_debits', "={{ $A.unknown_mandates || [] }}", 'array')
        ,@('balance_after', "={{ $A.balance_after }}", 'number')
        ,@('outlook', "={{ $A.outlook || {} }}", 'object')
    ) + $ReturnExtra
    $ret = Build-Return @(($X + 1540), 0) $retList

    $nodes = @($prepare, $ifPrep, $errPrep, $summary, $reqApproval, $ifApproved, $retCancelled, $apply, $ifApplied, $errApply, $ret)
    $conns = [ordered]@{
        'Prepare statement'      = @{ main = @( ,@( E 'Statement ok?' ) ) }
        'Statement ok?'          = @{ main = @( @( E 'Build Approval Summary' ), @( E 'Statement not ready' ) ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @( @( E 'Apply statement' ), @( E 'Return cancelled' ) ) }
        'Apply statement'        = @{ main = @( ,@( E 'Booked?' ) ) }
        'Booked?'                = @{ main = @( @( E 'Return' ), @( E 'Not booked' ) ) }
    }
    return @{ Nodes = $nodes; Conns = $conns; Entry = 'Prepare statement' }
}

# Get-FinanceFileErrorExpr: Fehlertext der Vision-Konsumenten (tool_reconcile_bank_statement, tool_extract_finance_document),
# wenn tool_fetch_telegram_file die Datei ablehnt. Eine CSV- oder Excel-Datei (mime text/csv bzw. xlsx) ist ein
# Bank-Export -> Verweis auf tool_import_bank_export mit derselben file_id, statt der rohen Ablehnung (eine Adresse fuer beide Konsumenten).
function Get-FinanceFileErrorExpr {
    $F = "`$('Fetch telegram file').item.json"
    return "={{ ['text/csv', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'].includes($F.mime) ? 'This is a bank export file (CSV or Excel), not a photo or PDF - call tool_import_bank_export with the same file_id (unless the file prints its balance, it also needs the balance the bank app shows right now).' : $F.error }}"
}
