#Requires -Version 5.1
# Die geteilte Monats-Check-Kette: Prepare statement
# (finance.fn_statement_prepare) -> Karte -> Gate -> Apply statement (finance.fn_apply_bank_statement, fingerprint aus der
# Karte) -> Return. Konsumenten: tool_reconcile_bank_statement (gedruckter Auszug per Vision) und tool_import_bank_export
# (Bank-Export-Datei per festem Leser). Die Rohwerte ($StmtParams) liefert der Konsument; alles Rechnen + die Kartenzeilen
# kommen aus der DB (eine Adresse). Helper-Datei ohne Build-* (Builder-Discovery liefert 0 Builder); gelesen nur in
# Funktionskoerpern -> Ladereihenfolge egal.
#
# New-StatementGateChain -X <Start-x> -StmtParams <[ordered] Rohwerte fuer Build-Pg> -Title <finance.hitl.*>
#   -CancelAction <ASCII, Build-ToolCancelled> [-ReturnExtra <@(,@(name, expr, type))> ] [-NotReadyExtra <gleiche Form, Felder auch fuer ok:false>]
#   [-RecurringParams <[ordered] chat_id, period_start, period_end, lines fuer finance.fn_import_stage_recurring> -CollectExpr <JS: Einrichtung>]
#   -> @{ Nodes; Conns; Entry = 'Prepare statement' }. Der Konsument verbindet seinen letzten Knoten mit Entry.
#   Mit -RecurringParams erkennt die Kette Dauerauftraege (nichts gebucht, Vorschlags-Stapel): bei already_covered/already_imported
#   statt der Sackgasse ('Stage recurring' -> 'Return covered', Konto und Saldo-Probe aus der Prepare) und nach der Buchung, wenn
#   CollectExpr wahr ist ('Stage after check'; die Vorschlaege folgen der Monats-Check-Karte). Der Export-Konsument nutzt das nicht.
function New-StatementGateChain {
    param([int]$X, [Parameter(Mandatory)]$StmtParams, [Parameter(Mandatory)][string]$Title,
          [Parameter(Mandatory)][string]$CancelAction, [array]$ReturnExtra = @(), [array]$NotReadyExtra = @(),
          $RecurringParams = $null, [string]$CollectExpr = 'false')
    $prepare = Build-Pg 'Prepare statement' @($X, 0) "=SELECT finance.fn_statement_prepare(`$1::jsonb) AS r;" $StmtParams
    $ifPrep = Build-If 'Statement ok?' @(($X + 220), 0) "={{ `$json.r.ok }}" 'true' 'equals' 'boolean'
    $P = "`$('Prepare statement').item.json.r"
    $notReadyFields = @(
        ,@('ok', 'false', 'boolean')
        ,@('code', "={{ $P.code }}", 'string')
        ,@('error', "={{ $P.reason }}", 'string')
        # export_invalid: die betroffene Zeile der Datei (aus der Leser-fn), damit der Agent sie dem Nutzer nennt
        ,@('row_no', "={{ $P.row_no === undefined || $P.row_no === null ? '' : String($P.row_no) }}", 'string')
        ,@('candidates', "={{ $P.candidates || [] }}", 'array')
        # Konto-Waechter (Bank-Export-Datei): erkannte Bank der Datei + das Konto, um das es geht (aus der DB, nie geraten)
        ,@('bank', "={{ $P.bank || '' }}", 'string')
        ,@('account_name', "={{ $P.account_name || '' }}", 'string')
        ,@('account_number', "={{ $P.account_number || '' }}", 'string')
        ,@('difference', "={{ $P.difference === undefined || $P.difference === null ? '' : String($P.difference) }}", 'string')
        ,@('balance_verified', "={{ $P.balance_verified === true }}", 'boolean')
        ,@('closing_balance', "={{ $P.closing_balance === undefined || $P.closing_balance === null ? '' : String($P.closing_balance) }}", 'string')
        ,@('balance_date', "={{ $P.balance_date || '' }}", 'string')
        ,@('currency', "={{ $P.currency || '' }}", 'string')
        # gedruckter Kontoinhaber eines unbekannten Kontos als Inhaber-Vorschlag (aus der DB)
        ,@('owner_person', "={{ $P.owner_person || '' }}", 'string')
        ,@('owner_joint', "={{ $P.owner_joint === true }}", 'boolean')
        # Pool-Regel (transfer_choice_required): die eine unklare Zahlung, damit der Agent sie beim Nachfragen nennt
        ,@('payment_amount', "={{ $P.amount === undefined || $P.amount === null ? '' : String($P.amount) }}", 'string')
        ,@('payment_date', "={{ $P.date || '' }}", 'string')
        # already_covered: bis wann bestaetigt, ab wann ein Auszug weiterhilft (sonst Sackgasse)
        ,@('covered_until', "={{ $P.covered_until || '' }}", 'string')
        ,@('useful_from', "={{ $P.useful_from || '' }}", 'string')
    ) + $NotReadyExtra
    $errPrep = Build-Set 'Statement not ready' @(($X + 440), 200) $notReadyFields

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
        # Uebertraege einzeln, Rest nach Richtung (alle Zahlen aus fn_apply_bank_statement)
        ,@('transfers', "={{ $A.transfers || [] }}", 'array')
        ,@('rest_outflow', "={{ $A.rest_outflow }}", 'number')
        ,@('rest_inflow', "={{ $A.rest_inflow }}", 'number')
        # Der Rest ist ein Saldo -> offene Ein-/Ausgaenge getrennt, dazu alles andere im Rest
        ,@('unmatched_in', "={{ $A.unmatched_in }}", 'number')
        ,@('unmatched_out', "={{ $A.unmatched_out }}", 'number')
        ,@('rest_other', "={{ $A.rest_other }}", 'number')
        ,@('rest_unexplained', "={{ $A.rest_unexplained }}", 'number')
        # Name des Rests auf der Karte (eine Adresse: fn_statement_prepare); Luecke App-Stand/Export
        ,@('rest_kind', "={{ $A.rest_kind }}", 'string')
        ,@('export_gap', "={{ $A.export_gap || 0 }}", 'number')
        # Buchungen mit gleichem Betrag wie eine Abweichung: erst nachsehen, dann vorschlagen
        ,@('difference_candidates', "={{ $A.difference_candidates || [] }}", 'array')
        # Transfer steckte im Rest des Gegenkontos: verrechnet bzw. unklar (nichts gebucht)
        ,@('lump_offsets', "={{ $A.lump_offsets || [] }}", 'array')
        ,@('transfers_unclear', "={{ $A.transfers_unclear || [] }}", 'array')
        # Vormerkungen des letzten Exports, die dessen Rest jetzt ausgleichen (nie Einnahme/Ausgabe)
        ,@('pending_settled', "={{ $A.pending_settled || 0 }}", 'number')
        # IBANs eigener Konten, die dieser Abgleich gespeichert hat bzw. die mehrdeutig blieben
        ,@('iban_learned', "={{ $A.learned_accounts || [] }}", 'array')
        ,@('iban_ambiguous', "={{ $P.iban_ambiguous || [] }}", 'array')
        ,@('difference_before_period', "={{ $A.drift_amount }}", 'number')
        ,@('skipped_payments', "={{ $A.skipped_occurrences }}", 'number')
        ,@('plan_adjusted', "={{ $A.plan_adjusted || [] }}", 'array')
        ,@('savings_plan_estimated', "={{ $A.savings_plan_estimated || [] }}", 'array')
        ,@('unknown_direct_debits', "={{ $A.unknown_mandates || [] }}", 'array')
        ,@('balance_after', "={{ $A.balance_after }}", 'number')
        ,@('outlook', "={{ $A.outlook || {} }}", 'object')
    ) + $ReturnExtra
    $recNodes = @()
    if ($RecurringParams) {
        # Erkennung, wenn der Monat schon bestaetigt ist (sonst Sackgasse: Zeilen weg, "kann nicht lesen")
        $ifCovered = Build-If 'Covered month?' @(($X + 440), 400) "={{ ['already_covered', 'already_imported'].includes($P.code) }}" 'true' 'equals' 'boolean'
        $stageParams = [ordered]@{ mode = "'statement'"; account_id = "$P.account_id"; balance_verified = "$P.balance_verified === true" }
        foreach ($k in $RecurringParams.Keys) { $stageParams[$k] = $RecurringParams[$k] }
        $stage = Build-Pg 'Stage recurring' @(($X + 660), 400) "=SELECT finance.fn_import_stage_recurring(`$1::jsonb) AS r;" $stageParams
        $stage['onError'] = 'continueRegularOutput'   # eine gescheiterte Erkennung darf die Antwort nie kippen
        $retCovered = Build-Set 'Return covered' @(($X + 880), 400) ($notReadyFields + @(
            ,@('recurring', "={{ `$('Stage recurring').item.json.r || {} }}", 'object')
        ))
        # Einrichtung: nach der Buchung (Monats-Check-Karte zuerst), Saldo-Probe bestanden
        $ifCollect = Build-If 'Collect recurring?' @(($X + 1540), -240) "={{ $CollectExpr }}" 'true' 'equals' 'boolean'
        $stageAfter = [ordered]@{ mode = "'statement'"; account_id = "$P.account_id"; balance_verified = 'true' }
        foreach ($k in $RecurringParams.Keys) { $stageAfter[$k] = $RecurringParams[$k] }
        $stage2 = Build-Pg 'Stage after check' @(($X + 1760), -240) "=SELECT finance.fn_import_stage_recurring(`$1::jsonb) AS r;" $stageAfter
        $stage2['onError'] = 'continueRegularOutput'   # nach der Buchung: ein Fehler hier meldet nie eine gescheiterte Buchung
        $retRec = Build-Return @(($X + 1980), -240) ($retList + @(,@('recurring', "={{ `$('Stage after check').item.json.r || {} }}", 'object'))) -Name 'Return with suggestions'
        $recNodes = @($ifCovered, $stage, $retCovered, $ifCollect, $stage2, $retRec)
    }
    $ret = Build-Return @(($X + 1540), 0) $retList

    $nodes = @($prepare, $ifPrep, $errPrep, $summary, $reqApproval, $ifApproved, $retCancelled, $apply, $ifApplied, $errApply, $ret) + $recNodes
    $conns = [ordered]@{
        'Prepare statement'      = @{ main = @( ,@( E 'Statement ok?' ) ) }
        'Statement ok?'          = @{ main = @( @( E 'Build Approval Summary' ), @( E 'Statement not ready' ) ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @( @( E 'Apply statement' ), @( E 'Return cancelled' ) ) }
        'Apply statement'        = @{ main = @( ,@( E 'Booked?' ) ) }
        'Booked?'                = @{ main = @( @( E 'Return' ), @( E 'Not booked' ) ) }
    }
    if ($RecurringParams) {
        $conns['Statement ok?']      = @{ main = @( @( E 'Build Approval Summary' ), @( E 'Covered month?' ) ) }
        $conns['Covered month?']     = @{ main = @( @( E 'Stage recurring' ), @( E 'Statement not ready' ) ) }
        $conns['Stage recurring']    = @{ main = @( ,@( E 'Return covered' ) ) }
        $conns['Booked?']            = @{ main = @( @( E 'Collect recurring?' ), @( E 'Not booked' ) ) }
        $conns['Collect recurring?'] = @{ main = @( @( E 'Stage after check' ), @( E 'Return' ) ) }
        $conns['Stage after check']  = @{ main = @( ,@( E 'Return with suggestions' ) ) }
    }
    return @{ Nodes = $nodes; Conns = $conns; Entry = 'Prepare statement' }
}

# Get-FinanceFileErrorExpr: Fehlertext der Vision-Konsumenten (tool_reconcile_bank_statement, tool_extract_finance_document),
# wenn tool_fetch_telegram_file die Datei ablehnt. Eine CSV- oder Excel-Datei (mime text/csv bzw. xlsx) ist ein
# Bank-Export -> Verweis auf tool_import_bank_export mit genau dieser file_id, statt der rohen Ablehnung (eine Adresse fuer beide Konsumenten).
function Get-FinanceFileErrorExpr {
    $F = "`$('Collect files').item.json"
    return "={{ ['text/csv', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'].includes($F.mime) ? 'File ' + $F.failed_file_id + ' is a bank export file (CSV or Excel), not a photo or PDF - call tool_import_bank_export with this file_id (unless the file prints its balance, it also needs the balance the bank app shows right now).' + ($F.file_count > 1 ? ' Nothing was read - call this tool again without it.' : '') : $F.error }}"
}
