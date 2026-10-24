#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_commit_import ------------------------------------
# BULK-IMPORT Schritt 3/3: EIN HITL-Gate fuer den ganzen Batch -> EIN atomarer Write
# (fn_import_bundle loopt die BESTEHENDEN fn_create_*/fn_book_* in EINER Transaktion).
# 40 Einzel-Approvals waeren Approval-Fatigue (= Sicherheitsloch, Review-Konsens) —
# Praezedenz: tool_reconcile_accounts_batch. Read summary -> Gate -> atomic Write.
function Build-CommitImport {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $FxCronId = Get-RequiredWorkflowId 'agent.finance.cron_refresh_fx_rates' 'Build-CommitImport'   # Sofort-FX-Fetch (Dual-Trigger), paket-intern
    # Monats-Check WP-G: Yahoo-Sub + Kurs-Cron SOFT (2-Pass-Bootstrap, Muster set_holding).
    $ResolveYahooSymbolId = Get-RequiredWorkflowId 'agent.finance.sub_resolve_yahoo_symbol' 'Build-CommitImport' -Soft
    $MarketPricesCronId   = Get-RequiredWorkflowId 'agent.finance.cron_refresh_market_prices' 'Build-CommitImport' -Soft
    $trig = Build-Trigger @((Get-ImportToolSpec 'tool_commit_import') | ForEach-Object { $_[0] })   # Feldliste aus ../import_tool_specs.ps1 (EINE Quelle, Review A5)

    # Monats-Check WP-G: Kurs-Symbol VOR der Karte. Je Depot-Position mit ISIN und ohne Feed-Symbol die ISIN bei Yahoo
    # aufloesen (derselbe Sub wie tool_book_stock_buy/set_holding); nur ein VERIFIZIERTER Treffer (Boersen-Waehrung =
    # Depot-Waehrung) wandert ins Staging -> die Karte zeigt ihn, der Owner bestaetigt ihn mit. Kein Treffer -> bleibt
    # leer, nach dem Import fragt der Agent nach (positions_without_price). alwaysOutputData: 0 Positionen -> EIN leeres
    # Item, der Loop laeuft einmal leer durch (Sub ohne ISIN = sofort roh, kein HTTP).
    $loadPos = Build-Pg 'Load positions' @(220, -420) `
        "=SELECT s.row_no, s.payload->>'isin' AS isin, s.payload->>'symbol' AS symbol, s.payload->>'price_per_share' AS price, COALESCE(NULLIF(s.payload->>'quote_currency',''), finance.fn_import_depot_currency(s.batch_id, s.payload->>'depot')) AS ccy FROM finance.import_staging s WHERE s.batch_id = ((`$1::jsonb)->>'batch_id')::uuid AND s.entity_type = 'stock_buy' AND s.status <> 'committed' AND NULLIF(s.payload->>'isin','') IS NOT NULL AND NULLIF(s.payload->>'provider_symbol','') IS NULL ORDER BY s.row_no;" `
        ([ordered]@{ batch_id = '$(''Start'').first().json.batch_id' })
    $loadPos['alwaysOutputData'] = $true
    $eachPos = Build-Loop 'Each position' @(440, -420)
    $resolvePos = Build-CallWorkflow 'Resolve Yahoo symbol' @(660, -540) $ResolveYahooSymbolId 'agent.finance.sub_resolve_yahoo_symbol' `
        ([ordered]@{
            isin            = "={{ `$('Each position').item.json.isin || '' }}"
            raw_symbol      = "={{ `$('Each position').item.json.symbol || '' }}"
            price_currency  = "={{ `$('Each position').item.json.ccy || '' }}"
            price_per_share = "={{ `$('Each position').item.json.price || '' }}"
            provider_symbol = "={{ '' }}"
        })
    # Uebernommen wird ein verifizierter Treffer ODER (2026-10-23) eine plausible Notierung in Fremdwaehrung, wenn es
    # keine in der Wunschwaehrung gibt (SPCX/USD fuer eine EUR-Position) -> provider_currency steht dann mit auf der
    # Karte ("wird in EUR umgerechnet"); fn_import_bundle reicht sie als quote_currency an die Position weiter.
    $ifVerified = Build-If 'Symbol verified?' @(880, -540) "={{ (`$json.verified === true || (`$json.foreign_listing === true && `$json.plausible === true)) && !!`$('Each position').item.json.row_no }}" 'true' 'equals' 'boolean'
    $storeSym = Build-Pg 'Store symbol' @(1100, -620) `
        "=SELECT (finance.fn_import_update_row(`$1::jsonb)->>'ok')::boolean AS ok;" `
        ([ordered]@{
            batch_id      = '$(''Start'').first().json.batch_id'
            row_no        = '$(''Each position'').item.json.row_no'
            payload_merge = '({ provider_symbol: $(''Resolve Yahoo symbol'').item.json.provider_symbol, provider_currency: $(''Resolve Yahoo symbol'').item.json.foreign_listing ? $(''Resolve Yahoo symbol'').item.json.currency : null })'
        })

    # Read-only Batch-Summary fuer das Gate: Counts + die Kartenzeilen aus finance.fn_import_card_rows (je valider Zeile
    # roher Payload + abgeleitete Werte aus DENSELBEN fn wie der Write: Person, Zeilen-Waehrung, Zins-Vorschlag, Rate,
    # Sparplan, Verrechnungskonto, Bundle-Defaults). Formatiert wird erst im Gate je Empfaenger. EIN Statement.
    $load = Build-Pg 'Load batch summary' @(220, 0) `
        "=SELECT (SELECT COUNT(*) FROM finance.import_staging s WHERE s.batch_id = ((`$1::jsonb)->>'batch_id')::uuid AND s.status = 'invalid')::int AS invalid_count, (SELECT COUNT(*) FROM finance.import_staging s WHERE s.batch_id = ((`$1::jsonb)->>'batch_id')::uuid AND s.status = 'valid')::int AS valid_count, (SELECT COUNT(*) FROM finance.import_staging s WHERE s.batch_id = ((`$1::jsonb)->>'batch_id')::uuid AND s.status = 'committed')::int AS committed_count, finance.fn_import_card_rows(((`$1::jsonb)->>'batch_id')::uuid) AS rows;" `
        ([ordered]@{ batch_id = '$(''Start'').first().json.batch_id' })
    # Nach dem Positions-Loop kommen N Items an ('done' gibt alle durchlaufenen aus) -> EINE Summary, EINE Karte.
    $load['executeOnce'] = $true

    $ifReady = Build-If 'Batch ready?' @(440, 0) "={{ `$json.invalid_count === 0 && `$json.committed_count === 0 && `$json.valid_count > 0 }}" 'true' 'equals' 'boolean'

    # card_sent:false -> tool_extract_finance_document meldet ehrlich "keine Karte" (approval_card_sent).
    $errNotReady = Build-Set 'Batch not ready' @(660, 200) @(
        ,@('ok','false','boolean')
        ,@('card_sent','false','boolean')
        ,@('error', "={{ `$('Load batch summary').item.json.committed_count > 0 ? 'This batch is already committed.' : (`$('Load batch summary').item.json.valid_count === 0 ? 'Nothing to commit — stage rows first.' : `$('Load batch summary').item.json.invalid_count + ' row(s) are still invalid — fix them with tool_update_staging_row first (the user corrects in chat, e.g. row 7: balance 5230).') }}", 'string')
    )

    # Import-Haertung 2026-10-22: Probelauf VOR der Karte = derselbe fn_import_bundle-Lauf, immer zurueckgerollt.
    # Fehler -> keine Karte, die Fehlerzeilen gehen an den Agenten (Owner-Befund: Karte sah gut aus, Abbruch erst
    # nach dem Bestaetigen). executeOnce: hinter dem Positions-Loop kann mehr als ein Item ankommen.
    $dryRun = Build-Pg 'Dry run import' @(660, -120) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'error_summary' AS error_summary, COALESCE(r->'errors', '[]'::jsonb) AS errors FROM finance.fn_import_bundle(`$1::jsonb) AS r;" `
        ([ordered]@{ batch_id = '$(''Start'').first().json.batch_id'; dry_run = 'true' })
    $dryRun['executeOnce'] = $true
    $ifDryOk = Build-If 'Dry run ok?' @(880, -120) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errDry = Build-Set 'Dry run failed' @(1100, -240) @(
        ,@('ok','false','boolean')
        ,@('card_sent','false','boolean')
        ,@('error', "={{ `$('Dry run import').first().json.reason + (`$('Dry run import').first().json.error_summary ? ' — ' + `$('Dry run import').first().json.error_summary : '') }}", 'string')
        ,@('errors', "={{ `$('Dry run import').first().json.errors || [] }}", 'array')
        ,@('error_summary', "={{ `$('Dry run import').first().json.error_summary || '' }}", 'string')
    )

    # EINE Approval-Summary (Textkatalog): Anzahl + je Staging-Zeile ein Block "Art: #Nr Name" mit denselben Feldzeilen
    # wie die Einzel-Karte der Art (../hitl_lines.ps1, Get-FinanceImportCardLinesExpr). Keine Kuerzung mehr: ist die
    # Karte laenger als eine Telegram-Nachricht, teilt das Gate sie in "Teil n/N" (nichts wird blind mit-bestaetigt).
    $linesExpr = Get-FinanceImportCardLinesExpr "`$('Load batch summary').item.json.rows"
    $summary = New-HitlSummary -Pos @(660, 0) -Title 'finance.hitl.commit_import' -Lines @(
        (New-HitlLine 'finance.label.entries' "`$('Load batch summary').item.json.rows.length")
        (New-HitlNote -Key 'finance.note.import_all_or_nothing')
    ) -LinesExpr $linesExpr

    $reqApproval = Build-CallWorkflow 'Request Approval' @(880, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').first().json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1100, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1320, 200) 'the commit_import action (the staged import stays; it can be corrected and committed again)'

    $bundle = Build-Pg 'Import bundle (atomic)' @(1320, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'error_summary' AS error_summary, (r->>'committed')::int AS committed, r->'created' AS created, COALESCE(r->'positions', '[]'::jsonb) AS positions FROM finance.fn_import_bundle(`$1::jsonb) AS r;" `
        ([ordered]@{ batch_id = '$(''Start'').first().json.batch_id' })

    $ifWritten = Build-If 'Write ok?' @(1540, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'

    # A11: error_summary ist bereits zu "Zeile N: reason; …" formatiert (kein roher JSON-Blob)
    $errWrite = Build-ToolError 'Import rolled back' @(1760, 200) `
        "={{ `$('Import bundle (atomic)').item.json.reason + ' — ' + `$('Import bundle (atomic)').item.json.error_summary }}"

    # Sofort-FX-Fetch wie tool_create_account: legt der Batch ein Nicht-EUR-Konto an ODER bekommt eine Position eine
    # Kurswaehrung ausser EUR (quote_currency, z. B. USD-Notierung), den FX-Cron als Sub rufen (sonst bleiben die
    # *_eur-Werte bis zum naechsten Schedule-Lauf NULL). Laeuft NACH dem Kurs-Abruf (Plan-Review 2026-10-23: vorher
    # kannte fn_active_currencies die Kurswaehrung noch nicht).
    $ifForeign = Build-If 'FX refresh needed?' @(2640, -120) `
        "={{ (`$('Import bundle (atomic)').first().json.created || []).some(c => c.entity_type === 'account' && c.currency && c.currency !== 'EUR') || (`$('Import bundle (atomic)').first().json.positions || []).some(p => p.quote_currency && p.quote_currency !== 'EUR') }}" 'true' 'equals' 'boolean'
    $ifForeign['executeOnce'] = $true   # der Kurs-Abruf kann mehrere Items liefern -> EIN FX-Abruf
    $callFx = Build-CallWorkflow 'Refresh FX rates' @(2860, -240) $FxCronId 'agent.finance.cron_refresh_fx_rates' `
        ([ordered]@{ chat_id = "={{ `$('Start').first().json.chat_id }}" })

    # Monats-Check WP-G: nach dem Write Kurse der neuen Positionen sofort holen (Sub, Muster set_holding) und melden,
    # welche Position noch keinen Kurs bzw. keine Anlageklasse hat -> der Agent klaert es mit dem Owner (Kurs-Symbol per
    # tool_verify_price_symbol + tool_set_holding; Anlageklasse nur bei Finanzplan per tool_set_asset_classes, eine Karte).
    $ifPos = Build-If 'Positions imported?' @(1760, -120) `
        "={{ (`$('Import bundle (atomic)').first().json.positions || []).length > 0 }}" 'true' 'equals' 'boolean'
    $callPrices = Build-CallWorkflow 'Refresh market prices' @(1980, -240) $MarketPricesCronId 'agent.finance.cron_refresh_market_prices' `
        ([ordered]@{ chat_id = "={{ `$('Start').first().json.chat_id }}" })
    $checkPos = Build-Pg 'Check positions' @(3080, -120) `
        "=WITH ids AS (SELECT (x->>'holding_id')::int AS id FROM jsonb_array_elements(COALESCE((`$1::jsonb)->'positions', '[]'::jsonb)) x) SELECT COALESCE(jsonb_agg(jsonb_build_object('holding_id', h.id, 'name', h.name, 'isin', h.isin, 'symbol', h.symbol)) FILTER (WHERE NOT EXISTS (SELECT 1 FROM finance.market_prices mp WHERE mp.symbol = h.symbol)), '[]'::jsonb) AS positions_without_price, COALESCE(jsonb_agg(jsonb_build_object('holding_id', h.id, 'name', h.name)) FILTER (WHERE h.asset_class IS NULL), '[]'::jsonb) AS positions_without_asset_class FROM finance.depot_holdings h JOIN ids ON ids.id = h.id;" `
        ([ordered]@{ positions = '$(''Import bundle (atomic)'').first().json.positions || []' })

    $checkPos['executeOnce'] = $true   # beide Zweige (mit/ohne FX) muenden hier -> EIN Check
    $ret = Build-Return @(3300, 0) @(
        ,@('ok','true','boolean')
        ,@('committed', "={{ `$('Import bundle (atomic)').first().json.committed }}", 'number')
        ,@('created',   "={{ `$('Import bundle (atomic)').first().json.created }}", 'array')
        ,@('positions_without_price',       "={{ `$('Check positions').first().json.positions_without_price || [] }}", 'array')
        ,@('positions_without_asset_class', "={{ `$('Check positions').first().json.positions_without_asset_class || [] }}", 'array')
    )
    $stickyPos = Build-Sticky 'Kurs-Symbol und Anlageklasse' @(220, -760) `
        'Depot-Positionen: Kurs-Symbol vor der Karte, Lücken nach dem Write melden' `
        'Monats-Check WP-G (Owner 2026-10-22: ETF "P500" ohne Kurs, "Anlageklasse: —"). VOR der Karte: Load positions -> je Position mit ISIN und ohne Feed-Symbol Resolve Yahoo symbol (derselbe Sub wie Einzelkauf/set_holding) -> ein verifizierter Treffer (Börsen-Währung = Depot-Währung) ODER, wenn es keine solche Notierung gibt, eine plausible Notierung in Fremdwährung (2026-10-23, z. B. SPCX/USD; provider_currency kommt mit, die Karte sagt "wird in € umgerechnet", fn_import_bundle setzt sie als quote_currency der Position) wird per fn_import_update_row ins Staging geschrieben und steht damit auf der Karte (Owner bestätigt ihn mit). Kein Treffer -> leer. NACH dem Write: Refresh market prices (Sub) -> FX refresh needed? (Fremdwährungs-Konto oder -Kurs -> FX-Sofort-Fetch, erst NACH den Kursen) -> Check positions liefert positions_without_price / positions_without_asset_class; der Agent fragt dann nach Börse/Ticker (tool_verify_price_symbol -> tool_set_holding) bzw. ordnet bei bestehendem Finanzplan die Anlageklassen mit EINER Karte zu (tool_set_asset_classes). Load positions hat alwaysOutputData: ohne Positionen läuft der Loop einmal leer durch.' 360 640

    $stickyFn = Build-Sticky 'fn_import_bundle: der atomare Commit' @(1320, -300) `
        'Loop über BESTEHENDE fn_* in EINER Transaktion' `
        'fn_import_bundle: (1) Guards (Batch existiert, alle Rows valid, nicht committed), (2) atomarer Block: Reihenfolge account -> real_estate -> loan -> Rest -> pension_statement; je Row Namen->ID-Auflösung (In-Batch-Konten zuerst, sonst fn_resolve_account) und Aufruf der bestehenden fn_create_*/fn_book_* (keine Duplikation der Validierung); Personen-Felder je Zeile per fn_import_resolve_persons (wie die Einzel-Tools); account delegiert opening_balance an fn_create_account (Eröffnungsbuchung category=other, kein Reconcile-Stempel); stock_buy = Bestandsübernahme (existing_position, Verrechnungskonto unverändert). (3) JEDES {ok:false}/jede Exception -> gesammelt -> Rollback per Flag (kein SQLERRM-Stringmatch) -> {ok:false, errors[row_no], error_summary} als DATEN (kein Owner-Alert); Staging bleibt intakt -> korrigieren + erneut tool_commit_import (Probelauf, dann Karte). Erfolg: Rows -> committed; Trigger pflegen Salden/shares/avg.' 260 620

    $stickyGate = Build-Sticky 'EIN Gate für den ganzen Batch' @(880, -200) `
        'Batch-Approval statt 40 Einzel-Gates' `
        'Review-Konsens: Einzel-Approvals je Entität trainieren Approval-Fatigue (Sicherheitsloch). Onboarding-Writes in leere Namespaces sind billig reversibel (delete-Tools existieren) -> EIN Sammel-Gate je Batch (Präzedenz tool_reconcile_accounts_batch). Operative Writes (Transfer/Sell/Void) behalten Einzel-Gates. Invalid-Rows blocken das Gate (erst korrigieren). Die Karte zeigt je Zeile ALLE Felder ihrer Art wie die Einzel-Karte (geteilte Felddefinition hitl_lines.ps1, abgeleitete Werte aus fn_import_card_rows); importierbar sind nur diese Felder (fn_import_allowed_keys). Zu lang für eine Nachricht -> das Gate teilt in Teil n/N, die Knöpfe hängen an der letzten.' 240 520

    $stickyDry = Build-Sticky 'Probelauf vor der Karte' @(660, -420) `
        'Probelauf: Karte nur, wenn der Write klappen wird' `
        'Import-Härtung 2026-10-22: fn_import_bundle(dry_run:true) läuft denselben Write-Loop über dieselben fn_create_*/fn_book_* und rollt IMMER zurück (Staging-Status bleibt). Fehler (unbekannter Typ, Zins auf Depot, doppelte Position, zu langer Wert …) -> Dry run failed: KEINE Karte, card_sent:false, errors[row_no] + error_summary an den Agenten -> tool_update_staging_row -> erneut tool_commit_import. Keine zweite Regel-Liste neben den Write-fns, die driften könnte. Zwischen Karte und Tipp kann sich der Bestand noch ändern -> der echte Commit prüft erneut (Import rolled back).' 320 360

    $nodes = @($trig, $loadPos, $eachPos, $resolvePos, $ifVerified, $storeSym,
               $load, $ifReady, $errNotReady, $dryRun, $ifDryOk, $errDry, $stickyDry, $summary, $reqApproval,
               $ifApproved, $retCancelled, $bundle, $ifWritten, $errWrite, $ifForeign, $callFx,
               $ifPos, $callPrices, $checkPos, $ret,
               $stickyFn, $stickyGate, $stickyPos)

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Load positions' ) ) }
        'Load positions'         = @{ main = @( ,@( E 'Each position' ) ) }
        'Each position'          = @{ main = @(
            @( E 'Load batch summary' ),     # done -> Karte
            @( E 'Resolve Yahoo symbol' )    # je Position
        ) }
        'Resolve Yahoo symbol'   = @{ main = @( ,@( E 'Symbol verified?' ) ) }
        'Symbol verified?'       = @{ main = @(
            @( E 'Store symbol' ),
            @( E 'Each position' )
        ) }
        'Store symbol'           = @{ main = @( ,@( E 'Each position' ) ) }
        'Load batch summary'     = @{ main = @( ,@( E 'Batch ready?' ) ) }
        'Batch ready?'           = @{ main = @(
            @( E 'Dry run import' ),
            @( E 'Batch not ready' )
        ) }
        'Dry run import'         = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run failed' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Import bundle (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Import bundle (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Positions imported?' ),
            @( E 'Import rolled back' )
        ) }
        'Positions imported?'    = @{ main = @(
            @( E 'Refresh market prices' ),
            @( E 'FX refresh needed?' )
        ) }
        'Refresh market prices'  = @{ main = @( ,@( E 'FX refresh needed?' ) ) }
        'FX refresh needed?'     = @{ main = @(
            @( E 'Refresh FX rates' ),    # true: Fremdwaehrungs-Konto oder -Kurs im Batch -> FX-Sofort-Fetch
            @( E 'Check positions' )
        ) }
        'Refresh FX rates'       = @{ main = @( ,@( E 'Check positions' ) ) }
        'Check positions'        = @{ main = @( ,@( E 'Return' ) ) }
    }

    return Build-Workflow 'agent.finance.tool_commit_import' $nodes $conns `
        @{ Category = 'import' }
}
