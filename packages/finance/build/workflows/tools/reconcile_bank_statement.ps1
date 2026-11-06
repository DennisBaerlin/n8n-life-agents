#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_reconcile_bank_statement (Monats-Check WP-C) ---
# Kontoauszug (Foto/PDF) -> Claude-Vision liest die gedruckten Rohwerte (Konto, Zeitraum, Salden, ALLE Zeilen) ->
# finance.fn_statement_prepare (Konto per IBAN, Saldo-Probe, Zuordnung zu den erwarteten Zahlungen, Rest, Kartenzeilen)
# -> EINE Karte -> finance.fn_apply_bank_statement (unter Lock neu gerechnet, fingerprint muss passen). Einzelumsaetze
# werden nicht gespeichert (Owner-Vorgabe); was keiner erwarteten Zahlung entspricht, wird EINE Abgleichsbuchung.
function Build-ReconcileBankStatement {
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $idFetch = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:fetch_telegram_file' $CoreServiceMap) 'Build-ReconcileBankStatement'
    $trig = Build-Trigger @('file_id', 'more_file_ids', 'doc_hint', 'account_name', 'transfer_account')

    # Extraktions-Vertrag (EN, Modell-Instruktion): nur gedruckte Rohwerte. KEINE Apostrophe (JS-String im jsonBody).
    $sysText = 'You read a German bank account statement (Kontoauszug) of ONE account and output only its printed raw values - never compute, never guess. is_statement = true only for a real account statement with an opening and a closing balance (Kontoauszug, Rechnungsabschluss, credit card statement); false for anything else (depot statement, insurance or pension letter, a plain transaction list without balances, pending transactions / vorgemerkte Umsaetze). account_number = the IBAN of this account exactly as printed (for a credit card statement the printed card number, masked digits allowed). account_holder = the printed account holder name(s) (Kontoinhaber) exactly as printed, empty if none is printed. currency = ISO code (EUR for Euro). period_start and period_end = the statement period as YYYY-MM-DD (Zeitraum / von ... bis; if only a statement date is printed, use the first booking date and the statement date). opening_balance = Kontostand alt / Saldo alt at the start; closing_balance = Kontostand neu / Saldo neu at the end; negative when overdrawn (S, Soll or minus). lines = EVERY booking in order: date = booking date (Buchungstag) as YYYY-MM-DD; amount = signed number, negative for debits (S, Soll, minus, Lastschrift, Abbuchung, Kartenzahlung), positive for credits (H, Haben, Gutschrift, Eingang); counterparty = name of the payee or payer; counterparty_iban = the IBAN of the other side if printed; creditor_id = Glaeubiger-ID (CI) if printed; mandate_ref = Mandatsreferenz (MREF) if printed; purpose = Verwendungszweck, shortened to the essential words. Carry-over lines (Uebertrag), page subtotals, the Saldo alt / Saldo neu lines and summary boxes are NOT lines; a booked interest, fee or Rechnungsabschluss posting IS a line. If the document holds several consecutive statements of the same account, merge them only when each opening balance equals the previous closing balance. German number format 1.234,56 means 1234.56. Use an empty string for any text field that is not printed. Several files may come together, labelled File 1 of N and so on (pages or overlapping photos of one statement, or different documents). groups = the file numbers that belong together, one inner array per statement of one account: pages of one statement and consecutive statements of the same account whose opening balance equals the previous closing balance are one group; another account, or a file that is not an account statement, is its own group. A booking visible on two overlapping photos counts once. For a single file groups = [[1]]. With more than one group leave lines empty.'
    $schema = [ordered]@{
        type = 'object'
        properties = [ordered]@{
            groups          = [ordered]@{ type = 'array'; items = [ordered]@{ type = 'array'; items = [ordered]@{ type = 'integer' } } }
            is_statement    = [ordered]@{ type = 'boolean' }
            account_number  = [ordered]@{ type = 'string' }
            account_holder  = [ordered]@{ type = 'string' }
            currency        = [ordered]@{ type = 'string' }
            period_start    = [ordered]@{ type = 'string' }
            period_end      = [ordered]@{ type = 'string' }
            opening_balance = [ordered]@{ type = 'number' }
            closing_balance = [ordered]@{ type = 'number' }
            lines = [ordered]@{
                type = 'array'
                items = [ordered]@{
                    type = 'object'
                    properties = [ordered]@{
                        date              = [ordered]@{ type = 'string' }
                        amount            = [ordered]@{ type = 'number' }
                        counterparty      = [ordered]@{ type = 'string' }
                        counterparty_iban = [ordered]@{ type = 'string' }
                        creditor_id       = [ordered]@{ type = 'string' }
                        mandate_ref       = [ordered]@{ type = 'string' }
                        purpose           = [ordered]@{ type = 'string' }
                    }
                    required = @('date', 'amount', 'counterparty', 'counterparty_iban', 'creditor_id', 'mandate_ref', 'purpose')
                    additionalProperties = $false
                }
            }
        }
        required = @('groups', 'is_statement', 'account_number', 'account_holder', 'currency', 'period_start', 'period_end', 'opening_balance', 'closing_balance', 'lines')
        additionalProperties = $false
    }

    $reader = New-TelegramFilesReader -FetchId $idFetch -OnFiles 'Load model config' -OnError 'File unusable' -X 220
    $errFile = Build-ToolError 'File unusable' @(1100, 200) (Get-FinanceFileErrorExpr)

    $contentJs = "$(Get-AnthropicFileBlocksJs).concat([{ type: 'text', text: 'Context from the user: ' + (`$('Start').item.json.doc_hint || 'none') + '. Read the statement now.' }])"
    $loadModel = New-ModelConfigNode -Position @(1100, -160) -Keys @( ,@('finance', 'vision_extract') )
    $vision = New-AnthropicMessagesNode -Name 'Read statement' -Position @(1320, 0) -ConfigModelKey 'vision_extract' -System $sysText `
        -ContentJs $contentJs -Effort medium -MaxTokens 32000 -JsonSchema $schema -TimeoutMs 240000

    $jsShape = (Get-AnthropicResultJs) + @'
const r = $input.first().json;
const fail = (code, m) => [{ json: { ok: false, code, error: m } }];
const res = anthropicText(r);
if (!res.ok) return fail('unreadable', 'The statement could not be read (' + res.error + ') - ask the user for the PDF from online banking or a sharper photo.');
let s;
try { s = JSON.parse(stripFences(res.text)); } catch (e) { return fail('unreadable', 'The statement could not be read - ask the user for the PDF from online banking.'); }
// Mehrere Dateien, die nicht EIN Auszug sind -> Gruppen an den Agenten (Datei ohne Gruppe = eigene Gruppe), keine Karte.
const ids = $('Collect files').first().json.file_ids;
if (ids.length > 1) {
  const seen = new Set();
  const groups = (s && Array.isArray(s.groups) ? s.groups : []).map((g) => (Array.isArray(g) ? g : []).filter((n) => Number.isInteger(n) && n >= 1 && n <= ids.length && !seen.has(n) && seen.add(n)).map((n) => ids[n - 1])).filter((g) => g.length);
  ids.forEach((id, i) => { if (!seen.has(i + 1)) groups.push([id]); });
  if (groups.length > 1) return [{ json: { ok: false, code: 'several_documents', groups, error: 'These files are not one statement of one account - nothing was booked. Call this tool once per entry of groups, one after the other: file_id = the first id of the group, more_file_ids = its other ids.' } }];
}
if (!s || s.is_statement !== true) return fail('not_a_statement', 'This is not an account statement with opening and closing balance. A depot statement, insurance or pension letter goes to tool_extract_finance_document; a plain transaction list cannot be checked against balances - ask for the monthly statement PDF.');
const txt = (v) => (typeof v === 'string' && v.trim() !== '') ? v.trim() : null;
const lines = (Array.isArray(s.lines) ? s.lines : []).map((l) => ({
  date: txt(l.date), amount: Number(l.amount), counterparty: txt(l.counterparty), counterparty_iban: txt(l.counterparty_iban),
  creditor_id: txt(l.creditor_id), mandate_ref: txt(l.mandate_ref), purpose: txt(l.purpose) }));
return [{ json: { ok: true, account_number: txt(s.account_number), account_holder: txt(s.account_holder), currency: txt(s.currency), period_start: txt(s.period_start),
  period_end: txt(s.period_end), opening_balance: Number(s.opening_balance), closing_balance: Number(s.closing_balance),
  lines, line_count: lines.length } }];
'@
    $shape = [ordered]@{ parameters = [ordered]@{ jsCode = $jsShape }; type = 'n8n-nodes-base.code'; typeVersion = 2
        position = @(1540, 0); id = (New-Id); name = 'Shape statement' }
    $ifShaped = Build-If 'Statement read?' @(1760, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errShape = Build-Set 'Not readable' @(1980, 200) @(
        ,@('ok', 'false', 'boolean')
        ,@('code', "={{ `$('Shape statement').item.json.code }}", 'string')
        ,@('error', "={{ `$('Shape statement').item.json.error }}", 'string')
        ,@('groups', "={{ `$('Shape statement').item.json.groups || [] }}", 'array')
    )

    $S = "`$('Shape statement').item.json"
    $stmtParams = [ordered]@{
        account_number  = "$S.account_number"
        account_holder  = "$S.account_holder"   # Import zuerst: Inhaber-Vorschlag fuer ein neues Konto (account_unknown)
        account_name    ="`$('Start').item.json.account_name || null"
        transfer_account = "`$('Start').item.json.transfer_account || null"   # Pool-Regel: Wahl des Nutzers nach transfer_choice_required
        currency        = "$S.currency"
        period_start    = "$S.period_start"
        period_end      = "$S.period_end"
        opening_balance = "$S.opening_balance"
        closing_balance = "$S.closing_balance"
        lines           = "$S.lines"
    }
    $chain = New-StatementGateChain -X 1980 -StmtParams $stmtParams -Title 'finance.hitl.reconcile_bank_statement' `
        -CancelAction 'the monthly statement import (nothing was booked)'

    $sticky = Build-Sticky 'Überblick' @(220, -460) `
        'Monats-Check: Kontoauszug -> eine Karte -> Buchung (Einzelumsätze werden nicht gespeichert)' `
        'List files -> Fetch telegram file je Datei (Core-Baustein) -> Collect files -> Claude-Vision (model.vision_extract, Denk-Tiefe mittel, JSON-Schema) liest alle Dateien gemeinsam, NUR gedruckte Rohwerte: Konto-IBAN, Kontoinhaber, Zeitraum, Anfangs-/Endstand, alle Zeilen. Mehrere Dateien, die nicht EIN Auszug sind (Feld groups): several_documents mit den Gruppen, keine Karte, der Agent ruft je Gruppe neu auf. Doppelt fotografierte Buchungen fängt die Saldo-Probe. Shape statement prüft is_statement (Depotauszug/Police -> tool_extract_finance_document; ein Bank-Export (CSV/Excel) geht an tool_import_bank_export). Ab Prepare statement die geteilte Monats-Check-Kette (statement_chain.ps1, gleich in tool_import_bank_export) = finance.fn_statement_prepare: Konto per IBAN (unbekannt -> account_unknown + Kandidaten + gedruckte IBAN, bei stimmender Saldo-Probe auch Endsaldo + Stichtag, bei passendem Kontoinhaber der Inhaber-Vorschlag owner_person/owner_joint; bestehendes Konto -> der Agent ruft mit account_name erneut; neues Konto -> tool_create_account mit dieser IBAN und dem Endsaldo zum Stichtag, der Auszug wird danach nicht mehr eingespielt), Saldo-Probe Anfang + Zeilen = Ende (sonst balance_check_failed, nichts wird geschrieben), Zuordnung zu den erwarteten Zahlungen (Stufe 0/A/B), Rest, Kartenzeilen, fingerprint. Ein Transfer, der schon im Rest des Gegenkontos steckt, wird dort verrechnet; ist das unklar, wird keiner gebucht (fn_statement_partner_lump, kein Raten). Karte (Zeilen kommen fertig strukturiert aus der DB) -> Gate -> Apply statement = finance.fn_apply_bank_statement. Rückgabe: Rest als Saldo plus getrennte offene Ein- und Ausgänge, Buchungen mit gleichem Betrag wie eine Abweichung (difference_candidates), bei already_covered das Datum, ab dem ein Auszug weiterhilft. PRIVACY: Kontoauszüge nur über die bezahlte Anthropic-API.' 360 560
    $stickyFp = Build-Sticky 'Vorschau = Buchung' @(1980, -420) `
        'Prepare läuft zweimal: für die Karte und unter Lock in der Buchung' `
        'fn_apply_bank_statement sperrt die Salden der beteiligten Konten, rechnet fn_statement_prepare mit denselben Rohwerten neu und bucht nur, wenn der fingerprint der Karte gleich ist (Plan/Apply-Muster). Hat sich zwischen Karte und Tipp etwas geändert (manuelle Buchung, Gegenbein aus dem Auszug des Partnerkontos, Dauerauftrag geändert) -> stale_preview, nichts gebucht, der Agent schickt den Auszug neu. Eine innere Buch-Ablehnung -> booking_failed, alles zurückgerollt.' 320 360

    $nodes = @($trig) + $reader.Nodes + @($errFile, $loadModel, $vision, $shape, $ifShaped, $errShape) + $chain.Nodes + @($sticky, $stickyFp)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E $reader.Entry ) ) }
        'Load model config'      = @{ main = @( ,@( E 'Read statement' ) ) }
        'Read statement'         = @{ main = @( ,@( E 'Shape statement' ) ) }
        'Shape statement'        = @{ main = @( ,@( E 'Statement read?' ) ) }
        'Statement read?'        = @{ main = @( @( E $chain.Entry ), @( E 'Not readable' ) ) }
    }
    foreach ($k in $chain.Conns.Keys) { $conns[$k] = $chain.Conns[$k] }
    foreach ($k in $reader.Conns.Keys) { $conns[$k] = $reader.Conns[$k] }
    return Build-Workflow 'agent.finance.tool_reconcile_bank_statement' $nodes $conns @{ Category = 'import' }
}
