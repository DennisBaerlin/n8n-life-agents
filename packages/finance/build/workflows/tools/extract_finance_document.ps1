#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_extract_finance_document -------------------------
# BULK-IMPORT Vision-Pfad (Phase 2): Telegram-file_id -> agent.tool_fetch_telegram_file (INLINE,
# generischer Download-/base64-Baustein, WS-4) -> Claude-Vision aufs BILD/PDF (bezahlte API, trainiert
# nicht — Kontoauszuege NIE ueber einen Free-Tier-Zugang) -> rohe Rows ->
# fn_import_stage (source=vision). Kein eigenes HITL (Staging ist Arbeitskopie); jede Zahl laeuft durch
# Validate + das EINE Commit-Gate — sind alle Zeilen gueltig, ruft dieses Tool tool_commit_import selbst (Karte sicher). Modell via config model.vision_extract, bei JEDEM Lauf gelesen (Load model config).
# Das Plumbing (Download/Validierung/base64) lebt seit WS-4 im Core-Baustein; die FINANZ-Vision bleibt
# HIER (volle Bild-Genauigkeit + Privacy-Hard-Rule), der Claude-Aufruf ueber den geteilten Baustein
# New-AnthropicMessagesNode (lib/build_helpers.ps1).
function Build-ExtractFinanceDocument {
    # WS-B0: enge Paket-Schreibrolle (finance_rw, Least-Privilege D10) statt Owner-Cred.
    # Dynamic-Scope: Build-Pg liest dieses $CRED_POSTGRES. Core-Tools nutzen die Owner-Cred.
    $CRED_POSTGRES = $CRED_FINANCE_RW

    # WS-4: generischen Download-/base64-Baustein inline rufen (D9-Core-Service-Alias). Liefert { ok, b64, mime, error }.
    $idFetch = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:fetch_telegram_file' $CoreServiceMap) 'Build-ExtractFinanceDocument'

    # Extraktions-Vertrag (EN, Layer 1): NUR Rohwerte, JSON-Array, Felder des Staging-Vertrags.
    # KEINE Apostrophe verwenden (JS-Single-Quote-String im jsonBody).
    $sysText = 'You extract structured finance data from a photographed or scanned German finance document (Depotauszug, insurance policy, Renteninformation, Rentenauskunft, Standmitteilung, a document listing accounts). Output ONLY a JSON array, no prose. If the document is a bank account statement with individual booking lines and an opening and closing balance (Kontoauszug, credit card statement), return exactly [{"entity_type":"bank_statement"}] and nothing else - it belongs to the monthly check, not to this import. Each element has entity_type plus RAW printed values - never compute, never estimate; omit fields that are not printed or unreadable. German number format 1.234,56 means 1234.56; output plain numbers. Dates as YYYY-MM-DD. Supported entity_type and fields: account {name, account_type one of cash|p2p|stocks_depot|crypto_depot|fixed_deposit, bank, opening_balance = the printed CURRENT or closing balance, account_number, currency}; stock_buy {depot = depot account name if known, depot_number = the printed depot or account number of the depot (Depot, Depotnummer), depot_holder = the printed depot holder (first and last name), symbol = the ticker ONLY if a ticker is printed (an ISIN is not a ticker; never derive a ticker from the name), isin, name, shares, price_per_share = printed purchase price PER UNIT (labels: Einstandskurs, durchschnittlicher Einstandskurs, Ø Einstand, Kaufkurs, Einstandspreis), cost_basis_total = printed TOTAL purchase value of the position (labels: Einstandswert, Einstand gesamt, Kaufwert) - give whichever is printed (both if both), NEVER the current market price or market value (Kurswert, Marktwert, aktueller Kurs); omit both only if neither is printed} one element PER POSITION of a Depotauszug; insurance {name, annual_premium, insurance_company, policy_number}; pension {name, pension_type one of statutory|occupational|riester|ruerup|private, provider, current_value (never for statutory), contract_number, owner_person = the printed first and last name of the insured person}; recurring_payment {name, direction one of income|expense, amount, schedule_unit one of day|week|month|year}; real_estate {name, current_value}; pension_statement {pension = name of the pension this statement belongs to, statement_date = the date of the letter, reached_claim = monthly pension from the claim reached so far (bislang erreichte Rentenanwartschaft), projection = monthly pension if contributions continue, without pension adjustments (Hochrechnung), scenario_1pct and scenario_2pct = the printed monthly pension at a yearly adjustment rate of 1 percent and 2 percent, em_monthly = Rente wegen voller Erwerbsminderung, earning_points = Entgeltpunkte, regular_retirement_date = the printed start date of the Regelaltersrente} for a Renteninformation, Rentenauskunft or Standmitteilung - for a statutory pension also emit the pension row (pension_type statutory, provider, owner_person); settlement_balance {depot = depot account name if known, depot_number, depot_holder, balance = the printed cash balance, balance_date = the printed as-of date of that balance (labels: zum, Stand, Datum)} for the cash or settlement line of a depot overview (labels: Cash, Cashkonto, Verrechnungskonto, Guthaben) - NEVER output that cash line as an account. If the document is not a finance document, return [].'

    $trig = Build-Trigger @((Get-ImportToolSpec 'tool_extract_finance_document') | ForEach-Object { $_[0] })   # Feldliste aus ../import_tool_specs.ps1 (EINE Quelle, Review A5)

    # WS-4: generischer Download-/base64-Baustein inline -> { ok, b64, mime, error } (leere/unbrauchbare file_id -> ok:false).
    $fetch = Build-CallWorkflow 'Fetch telegram file' @(420, 60) $idFetch 'agent.tool_fetch_telegram_file' `
        ([ordered]@{ file_id = "={{ `$('Start').item.json.file_id }}" })
    $ifB64 = Build-If 'File ok?' @(860, 60) "={{ `$('Fetch telegram file').item.json.ok }}" 'true' 'equals' 'boolean'
    $errB64 = Build-ToolError 'File unusable' @(1080, 240) (Get-FinanceFileErrorExpr)

    # Claude-Vision: Bild als image-Block, PDF als document-Block + Kontext-Text. JSON-Array per Prompt-Vertrag
    # (heterogene Rows je entity_type -> kein festes Structured-Output-Schema); der Parse toleriert Zaeune.
    $fileBlock = Get-AnthropicFileBlockJs -B64Expr "`$('Fetch telegram file').item.json.b64" -MimeExpr "`$('Fetch telegram file').item.json.mime"
    $contentJs = "[ $fileBlock, { type: 'text', text: 'Document context from the user: ' + (`$('Start').item.json.doc_hint || 'none') + '. Extract the finance data now.' } ]"
    # Modell zur Laufzeit (model.vision_extract via core.fn_config_get, unter finance_rw — das Fenster ist gegrantet).
    $loadModel = New-ModelConfigNode -Position @(1080, -100) -Keys @( ,@('finance', 'vision_extract') )
    $http = New-AnthropicMessagesNode -Name 'Vision extract' -Position @(1080, 60) -ConfigModelKey 'vision_extract' -System $sysText `
        -ContentJs $contentJs -Effort medium -TimeoutMs 180000

    $jsShape = (Get-AnthropicResultJs) + @'
const r = $input.first().json;
const fail = (m) => [{ json: { ok: false, error: 'Extraction failed (' + m + ') - ask the user for a sharper photo or to dictate the data instead.' } }];
const res = anthropicText(r);
if (!res.ok) return fail(res.error);
const txt = stripFences(res.text);
const a = txt.indexOf('['), z = txt.lastIndexOf(']');
let rows;
try { rows = JSON.parse(a >= 0 && z > a ? txt.slice(a, z + 1) : txt); }
catch (e) { return fail('unparseable model output'); }
if (!Array.isArray(rows)) return fail('model did not return an array');
if (Array.isArray(rows) && rows.some(x => x && x.entity_type === 'bank_statement')) return [{ json: { ok: false, code: 'use_reconcile_bank_statement', error: 'This is a bank account statement with booking lines - call tool_reconcile_bank_statement with the same file_id instead (nothing was staged).' } }];
if (rows.length === 0) return [{ json: { ok: false, error: 'No finance data recognized - is this really a statement? Ask the user, then enter via chat if needed.' } }];
rows = rows.slice(0, 60).filter(x => x && typeof x === 'object' && x.entity_type);
// Cash-/Verrechnungs-Stand einer Depot-Uebersicht wird NICHT gestaged (2026-10-23): fn_import_balance_targets ordnet
// ihn dem Verrechnungskonto zu, der Agent bietet danach tool_reconcile_account an (eigene Karte).
const balances = rows.filter(x => x.entity_type === 'settlement_balance').map(({ entity_type, ...b }) => b);
rows = rows.filter(x => x.entity_type !== 'settlement_balance');
if (rows.length === 0 && balances.length === 0) return fail('rows without entity_type');
return [{ json: { ok: true, rows: JSON.stringify(rows), row_count: rows.length, balances: JSON.stringify(balances) } }];
'@
    $shape = [ordered]@{
        parameters = [ordered]@{ jsCode = $jsShape }
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(1300, 60)
        id = (New-Id)
        name = 'Shape rows'
    }
    $ifShaped = Build-If 'Rows ok?' @(1520, 60) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    # W9-Backstop (DB-ist-das-Gesetz S9): ein Kontoauszug mit Buchungszeilen kommt als code=use_reconcile_bank_statement
    # zurueck (nichts gestaged) -> der Agent ruft tool_reconcile_bank_statement mit derselben file_id.
    $errShape = Build-Set 'Extraction failed' @(1740, 240) @(
        ,@('ok', 'false', 'boolean')
        ,@('error', "={{ `$('Shape rows').item.json.error }}", 'string')
        ,@('code', "={{ `$('Shape rows').item.json.code || '' }}", 'string')
    )

    # Rohe Rows -> Staging (source=vision) inkl. sofortiger Validierung
    $stage = Build-Pg 'Stage extracted rows' @(1740, 60) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'batch_id' AS batch_id, (r->>'staged')::int AS staged, (r->>'valid')::int AS valid, (r->>'invalid')::int AS invalid, r->'errors' AS errors FROM finance.fn_import_stage(`$1::jsonb) AS r;" `
        ([ordered]@{
            rows     = 'JSON.parse($(''Shape rows'').item.json.rows)'
            batch_id = '$(''Start'').item.json.batch_id || null'
            source   = '''vision'''
            chat_id  = 'String($(''Start'').item.json.chat_id || '''')'   # Selbstbezug "ich" -> wer chattet (fn_import_stage)
        })
    $ifStaged = Build-If 'Stage ok?' @(1960, 60) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errStage = Build-ToolError 'Stage failed' @(2180, 240) "={{ `$('Stage extracted rows').item.json.reason }}"

    # Cash-/Verrechnungs-Salden (settlement_balance, 2026-10-23): read-only Zuordnung zum Verrechnungskonto des Depots
    # (fn_import_balance_targets: Depotnummer/Inhaber, nur Bestandskonten, Druckdatum Pflicht, Blocker wie der Abgleich)
    # -> balances[] im Return; der Agent ruft danach je Abweichung tool_reconcile_account (eigene Karte).
    $ifAnyRows = Build-If 'Any rows to stage?' @(1630, -60) "={{ `$('Shape rows').item.json.row_count > 0 }}" 'true' 'equals' 'boolean'
    $resolveBal = Build-Pg 'Resolve balances' @(2070, -60) `
        "=SELECT finance.fn_import_balance_targets(NULLIF((`$1::jsonb)->>'batch_id', '')::uuid, (`$1::jsonb)->'rows') AS balances;" `
        ([ordered]@{
            batch_id = '$(''Stage extracted rows'').item.json.batch_id'
            rows     = 'JSON.parse($(''Shape rows'').item.json.balances || ''[]'')'
        })
    $resolveBalOnly = Build-Pg 'Resolve balances only' @(1850, -260) `
        "=SELECT finance.fn_import_balance_targets(NULL, (`$1::jsonb)->'rows') AS balances;" `
        ([ordered]@{ rows = 'JSON.parse($(''Shape rows'').item.json.balances || ''[]'')' })
    $retBalOnly = Build-Set 'Return balances only' @(2070, -260) @(
        ,@('ok', 'true', 'boolean')
        ,@('extracted_rows', '0', 'number')
        ,@('valid', '0', 'number')
        ,@('invalid', '0', 'number')
        ,@('errors', '={{ [] }}', 'array')
        ,@('balances', "={{ `$json.balances || [] }}", 'array')
    )

    # Owner 2026-10-22 (arch-challenge: fester Ablauf statt LLM-Entscheid): sind ALLE Zeilen des Batches gueltig, schickt
    # dieses Tool die Sammelkarte SELBST (tool_commit_import inline: Karte mit Knoepfen + atomarer Write nach dem Tipp)
    # und liefert deren Ergebnis — die Karte kommt garantiert, statt dass das Modell im Text "Soll ich uebernehmen?"
    # fragt. Ungueltige Zeilen -> keine Karte, der Agent klaert sie (tool_update_staging_row -> tool_commit_import).
    # Doppel-Commit ist ausgeschlossen: commit_import lehnt einen schon committeten Batch ab ('already committed').
    $idCommit = Get-RequiredWorkflowId 'agent.finance.tool_commit_import' 'Build-ExtractFinanceDocument'
    $ifAllValid = Build-If 'All rows valid?' @(2180, -140) "={{ `$('Stage extracted rows').item.json.invalid === 0 && `$('Stage extracted rows').item.json.valid > 0 }}" 'true' 'equals' 'boolean'
    $commit = Build-CallWorkflow 'Send approval card' @(2400, -140) $idCommit 'agent.finance.tool_commit_import' `
        ([ordered]@{ batch_id = "={{ `$('Stage extracted rows').item.json.batch_id }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $retCommitted = Build-Set 'Return card result' @(2620, -140) @(
        ,@('ok', "={{ `$json.ok === true }}", 'boolean')
        ,@('approval_card_sent', "={{ `$json.card_sent !== false }}", 'boolean')   # Probelauf-Fehler/Batch nicht bereit -> keine Karte
        ,@('batch_id', "={{ `$('Stage extracted rows').item.json.batch_id }}", 'string')
        ,@('extracted_rows', "={{ `$('Shape rows').item.json.row_count }}", 'number')
        ,@('committed', "={{ `$json.committed || 0 }}", 'number')
        ,@('created', "={{ `$json.created || [] }}", 'array')
        ,@('cancelled', "={{ `$json.cancelled === true }}", 'boolean')
        ,@('message', "={{ `$json.message || `$json.error || '' }}", 'string')
        ,@('errors', "={{ `$json.errors || [] }}", 'array')
        ,@('error_summary', "={{ `$json.error_summary || '' }}", 'string')
        ,@('positions_without_price',       "={{ `$json.positions_without_price || [] }}", 'array')
        ,@('positions_without_asset_class', "={{ `$json.positions_without_asset_class || [] }}", 'array')
        ,@('balances', "={{ `$('Resolve balances').item.json.balances || [] }}", 'array')
    )

    $ret = Build-Return @(2400, 60) @(
        ,@('ok', 'true', 'boolean')
        ,@('batch_id', "={{ `$('Stage extracted rows').item.json.batch_id }}", 'string')
        ,@('extracted_rows', "={{ `$('Shape rows').item.json.row_count }}", 'number')
        ,@('valid',   "={{ `$('Stage extracted rows').item.json.valid }}", 'number')
        ,@('invalid', "={{ `$('Stage extracted rows').item.json.invalid }}", 'number')
        ,@('errors',  "={{ `$('Stage extracted rows').item.json.errors }}", 'array')
        ,@('balances', "={{ `$('Resolve balances').item.json.balances || [] }}", 'array')
    )

    $sticky = Build-Sticky 'Vision-Extraktion (paid-key Pflicht)' @(420, -420) `
        'Fetch telegram file (Core-Baustein: Download/base64) -> Load model config -> Claude-Vision aufs Bild/PDF (model.vision_extract, Denk-Tiefe mittel: Depotauszüge mit Stück-/Gesamt-Einstand brauchen sorgfältiges Lesen, Owner-Befund 2026-10-22) -> Staging -> alle gültig: Sammelkarte (tool_commit_import)' `
        'PRIVACY: Kontoauszüge gehen NUR über die bezahlte Anthropic-API (anthropicApi-Credential; die API trainiert laut Commercial Terms nicht auf Kundeninhalten) — nie über einen Free-Tier-Zugang. Der Download/die base64-Wandlung kommt seit WS-4 aus dem generischen Baustein agent.tool_fetch_telegram_file (kein Key dort; Allow-List jpeg/png/gif/webp/pdf, Bild <= 5 MB); die FINANZ-Vision aufs BILD (volle Genauigkeit: Layout/Spalten/Einstandskurs/ISIN) bleibt HIER, der Aufruf über den geteilten Baustein New-AnthropicMessagesNode (Bild = image-Block, PDF = document-Block). Extraktion liefert NUR Rohwerte (Bestände, keine Historie, nichts Abgeleitetes — System-Prompt + Staging-Denylist) als JSON-Array (Prompt-Vertrag, Parse toleriert Zäune; abgeschnittene Antwort/Ablehnung -> ok:false). Depot-Positionen: Ticker nur, wenn gedruckt (sonst ist die ISIN die Kennung, fn_holding_symbol); gedruckte Depotnummer/Inhaber (depot_number/depot_holder) -> fn_import_stage wählt das Depot deterministisch (fn_import_resolve_depot) statt des geratenen Namens, Widersprüche werden Zeilenfehler (Owner-Befund 2026-10-23). Jede Zahl läuft durch fn_import_validate und das EINE Commit-Gate (tool_commit_import) — dieses Tool selbst schreibt nichts in die Bücher; sind alle Zeilen gültig, ruft es tool_commit_import auf (Karte, Write erst nach dem Tipp; Sticky Karte kommt sicher). Modell: Load model config liest bei JEDEM Lauf core.config model.vision_extract (Wechsel: lifeagents config set model vision_extract <key>, wirkt sofort; nur Claude = bezahlte API).' 320 680

    $stickyCard = Build-Sticky 'Karte kommt sicher' @(2180, -420) `
        'Alle Zeilen gültig -> Sammelkarte direkt (tool_commit_import inline)' `
        'Owner 2026-10-22: nach dem Auslesen fragte der Agent im Text nach ("Soll ich es so übernehmen?") statt die Karte zu schicken - keine Knöpfe. Fester Ablauf statt Modell-Entscheid (arch-challenge: Anthropic "Building effective agents" - feste Reihenfolgen gehören in den Code; erzwungene Tool-Aufrufe lehnen die aktuellen Claude-Modelle ab). Alle Zeilen gültig -> Send approval card ruft tool_commit_import (Karte mit Knöpfen, atomarer Write nach dem Tipp) und gibt dessen Ergebnis zurück (approval_card_sent, committed bzw. cancelled). Ungültige Zeilen -> Return wie bisher, der Agent klärt sie und ruft danach tool_commit_import. Ein zweiter Commit desselben Batches wird abgelehnt (already committed).' 300 400
    $stickyBal = Build-Sticky 'Cash-Stand einer Depot-Übersicht' @(1630, -560) `
        'settlement_balance -> zweite Karte über tool_reconcile_account (nie als Konto-Zeile)' `
        'Owner-Fall 2026-10-23: die Vermögensübersicht druckt "Cash 3.054,97"; als account-Zeile wurde sie als Dublette eines FREMDEN Kontos abgelehnt und verworfen. Jetzt trennt Shape rows settlement_balance ab (nicht gestaged). Resolve balances (fn_import_balance_targets, read-only) ordnet über Depotnummer/Inhaber/Name dem Verrechnungskonto des Depots zu (nur Bestandskonten; Depot neu im Batch -> Saldo als opening_balance der Konto-Zeile), Druckdatum Pflicht, Blocker wie der Abgleich, liefert Saldo zum Datum + Differenz + skip_count. balances[] geht an den Agenten; er ruft danach je Abweichung tool_reconcile_account (eigene Karte, Owner-Entscheid "zweite Karte statt neuer Import-Art"). Nur ein Cash-Stand im Dokument -> Any rows to stage? false -> Resolve balances only.' 320 520

    $nodes = @($trig, $fetch, $ifB64, $errB64,
               $loadModel, $http, $shape, $ifShaped, $errShape, $stage, $ifStaged, $errStage, $ifAllValid, $commit, $retCommitted, $ret, $sticky, $stickyCard,
               $ifAnyRows, $resolveBal, $resolveBalOnly, $retBalOnly, $stickyBal)

    $conns = [ordered]@{
        'Start'              = @{ main = @( ,@( E 'Fetch telegram file' ) ) }
        'Fetch telegram file' = @{ main = @( ,@( E 'File ok?' ) ) }
        'File ok?'           = @{ main = @(
            @( E 'Load model config' ),
            @( E 'File unusable' )
        ) }
        'Load model config' = @{ main = @( ,@( E 'Vision extract' ) ) }
        'Vision extract' = @{ main = @( ,@( E 'Shape rows' ) ) }
        'Shape rows'     = @{ main = @( ,@( E 'Rows ok?' ) ) }
        'Rows ok?'       = @{ main = @(
            @( E 'Any rows to stage?' ),
            @( E 'Extraction failed' )
        ) }
        'Any rows to stage?' = @{ main = @(
            @( E 'Stage extracted rows' ),
            @( E 'Resolve balances only' )   # nur ein Cash-Stand im Dokument -> nichts zu stagen
        ) }
        'Resolve balances only' = @{ main = @( ,@( E 'Return balances only' ) ) }
        'Stage extracted rows' = @{ main = @( ,@( E 'Stage ok?' ) ) }
        'Stage ok?'      = @{ main = @(
            @( E 'Resolve balances' ),
            @( E 'Stage failed' )
        ) }
        'Resolve balances' = @{ main = @( ,@( E 'All rows valid?' ) ) }
        'All rows valid?' = @{ main = @(
            @( E 'Send approval card' ),   # alle gueltig -> Karte kommt sicher
            @( E 'Return' )                # ungueltige Zeilen -> der Agent klaert sie
        ) }
        'Send approval card' = @{ main = @( ,@( E 'Return card result' ) ) }
    }

    return Build-Workflow 'agent.finance.tool_extract_finance_document' $nodes $conns `
        @{ Category = 'import' }
}
