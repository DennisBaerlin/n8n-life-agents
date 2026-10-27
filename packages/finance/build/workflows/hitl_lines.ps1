#Requires -Version 5.1
# Die Feldzeilen der finance-Bestaetigungskarten je Art (Owner 2026-10-22: alle fuer die Art relevanten Felder, ein
# Feld pro Zeile, einheitlich). EINE Definition fuer die Einzel-Karte (tool_create_* / tool_book_stock_buy) UND die
# Import-Karte (tool_commit_import, je Staging-Zeile ein Block). Helper-Datei ohne Build-* (die Builder-Discovery
# liefert hier 0 Builder); gelesen nur in Funktionskoerpern -> Ladereihenfolge egal.
#
# Regeln (packages/CLAUDE.md *HITL-Bestaetigungs-Format*):
#   - Jede Art hat eine feste Zeilenliste; ein leeres Feld zeigt '—' (Renderer). -If NUR fuer (a) die Relevanz je
#     Unterart (Depot vs. Konto, Festgeld, Einnahme vs. Ausgabe) und (b) Folgegruppen eines gesetzten Hauptfelds
#     (Zins, Kreditrate, Rentenbeitrag) — dann vollstaendig. Zahl-Bedingungen ueber Get-FinanceNumSetJs (numerisch:
#     '0' aus dem Einzel-Tool und 0 aus dem Import gelten gleich als "nicht gesetzt").
#   - -S = JS-Ausdruck des Feld-Objekts mit den Feldnamen der EINZEL-Tools (Build-Trigger); der Import mappt seine
#     Staging-Namen ueber $script:FIN_IMPORT_CARD.Alias darauf. -D = abgeleitete Werte als JS-Ausdruecke (Einzel-Tool:
#     Pre-Gate-Knoten; Import: X.* aus finance.fn_import_card_rows) — beide aus DENSELBEN fn_* wie der Write.
#   - Was die Import-Zeile tragen darf (finance.fn_import_allowed_keys) muss eine Kartenzeile haben:
#     Test-FinanceImportKeysCovered bricht den Build sonst (Owner: was nicht auf der Karte steht, wird nicht gespeichert).

# JS: ist ein Zahl-Feld gesetzt (nicht leer, nicht 0)? Deutsches Komma toleriert; unlesbar zaehlt als gesetzt
# (lieber eine Zeile zu viel zeigen als einen geschriebenen Wert verstecken).
function Get-FinanceNumSetJs([string]$Expr) {
    "((v) => v !== undefined && v !== null && v !== '' && Number(String(v).replace(',', '.')) !== 0)($Expr)"
}

# Abbuchungstag (schedule_day_of_month) in Klartext — EINE Definition fuer alle Karten (vorher Kopien je Tool; Sparziel
# und Sparplan zeigten -1 als "-1."): -1 -> letzter, -2 -> vorletzter Tag des Monats, fester Tag -> Template -DayTpl
# (Param {day}), leer -> -Empty (JS-Ausdruck; 'null' = '—'). Liefert den Template-Key-Ausdruck fuer New-HitlLine -Kind tpl.
function Get-FinanceDomTpl {
    param([Parameter(Mandatory)][string]$Dom, [string]$DayTpl = 'finance.tpl.day_of_month', [string]$Empty = 'null')
    "(String($Dom ?? '') === '-1' ? 'finance.value.last_day_of_month' : (String($Dom ?? '') === '-2' ? 'finance.value.second_to_last_day_of_month' : ($Dom ? '$DayTpl' : $Empty)))"
}
# Monatsende-Tag (-1/-2) als Key-Wert fuer Templates mit eigenem Platzhalter (z. B. Sparplan-Zyklus {end}).
function Get-FinanceMonthEndKey([string]$Dom) {
    "(String($Dom ?? '') === '-2' ? 'finance.value.second_to_last_day_of_month' : 'finance.value.last_day_of_month')"
}

# Zins-Kadenz in Klartext (Live-Befund 2026-10-24: keine Codes wie "ACT/365" oder "-1" auf der Karte) — EINE Definition
# fuer die Konto-Karte (Einzel-Tool + Import) und die Karte von tool_set_account_interest. Werte als JS-Ausdruecke:
# Unit/Interval/Dom/Pdom = die Kadenz, die der Write schreibt (Konto: Eingabe, von fn_create_account unveraendert
# uebernommen; Satzwechsel: wirksame Werte aus fn_interest_rate_preview); FirstCredit = erste Gutschrift aus derselben
# fn (fn_interest_next_period_end, Kalender-Raster) — die Karte rechnet nichts, sie waehlt nur den Text:
#   Rhythmus  taeglich/woechentlich/monatlich/vierteljaehrlich/halbjaehrlich/jaehrlich, sonst "alle n <Einheit>"
#   Gutschrift  dom -1 -> zum Monats-/Quartals-/Halbjahres-/Jahresende | fester Tag -> am n. | leer: year -> am
#               Jahrestag, month (Altzeile) -> am Tag des Starts, day/week -> laufend
#   Methode   Katalog-Enum finance.enum.day_count.<code> (der Renderer macht aus ACT/365 den Key act_365)
function Get-FinanceInterestScheduleLines {
    param([Parameter(Mandatory)][string]$Unit, [Parameter(Mandatory)][string]$Interval, [Parameter(Mandatory)][string]$Dom,
          [Parameter(Mandatory)][string]$Pdom, [Parameter(Mandatory)][string]$FirstCredit,
          [Parameter(Mandatory)][string]$Conv, [Parameter(Mandatory)][string]$ConvReason, [string]$If)
    $u  = "String($Unit || '')"
    $n  = "Number($Interval || 1)"
    $d  = "String($Dom ?? '')"
    $rhythm = "($n === 1 ? $u : ($u === 'month' && $n === 3 ? 'quarter' : ($u === 'month' && $n === 6 ? 'half_year' : ($u === 'month' && $n === 12 ? 'year' : $u))))"
    $simple = "($n === 1 || ($u === 'month' && [3, 6, 12].includes($n)))"
    $endOf  = "($u === 'year' ? 'year' : ($u !== 'month' ? 'period' : ({ 1: 'month', 3: 'quarter', 6: 'half_year', 12: 'year' })[$n] || 'period'))"
    $creditTpl = "($d === '-1' ? 'finance.tpl.credit_end' : ($d !== '' ? 'finance.tpl.credit_on_day' : ($u === 'year' ? 'finance.tpl.credit_anniversary' : ($u === 'month' ? 'finance.tpl.credit_start_day' : 'finance.tpl.credit_continuous'))))"
    @(
        (New-HitlLine 'finance.label.credit_rhythm' "($simple ? 'finance.tpl.plain' : 'finance.tpl.every_unit')" -Kind tpl -If $If -Params @{
            value    = (New-HitlValue -Kind enum -Value $rhythm -Enum 'finance.enum.credit_rhythm')
            interval = $n
            unit     = (New-HitlValue -Kind enum -Value $u -Enum 'finance.enum.schedule_unit') })
        (New-HitlLine 'finance.label.credit_day' $creditTpl -Kind tpl -If $If -Params @{
            value = (New-HitlValue -Kind enum -Value $endOf -Enum 'finance.enum.credit_end')
            day   = $d })
        (New-HitlLine 'finance.label.credit_day_next_month' "(String($Pdom ?? '') !== '' ? 'finance.tpl.credit_on_day' : null)" -Kind tpl -If $If -Params @{
            value = (New-HitlValue -Kind enum -Value "'period'" -Enum 'finance.enum.credit_end')
            day   = "String($Pdom ?? '')" })
        (New-HitlLine 'finance.label.first_credit' $FirstCredit -Kind date -If $If)
        (New-HitlLine 'finance.label.interest_method' "'finance.tpl.interest_method'" -Kind tpl -If $If -Params @{
            method = (New-HitlValue -Kind enum -Value $Conv -Enum 'finance.enum.day_count')
            reason = (New-HitlValue -Kind enum -Value $ConvReason -Enum 'finance.enum.interest_reason') })
    )
}

function Get-FinanceHitlLines {
    param(
        [Parameter(Mandatory)][ValidateSet('account','stock_buy','insurance','pension','pension_statement',
            'recurring_payment','real_estate','savings_goal','loan')][string]$Entity,
        [Parameter(Mandatory)][string]$S,
        [hashtable]$D = @{},
        [switch]$Import   # Import-Karte: Depot-Position = Bestandsuebernahme (kein Yahoo-Symbol, keine Abbuchung)
    )
    $need = { param($k) if (-not $D.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($D[$k])) { throw "Get-FinanceHitlLines ${Entity}: -D.$k fehlt" }; $D[$k] }
    $own  = { param($label, $expr) New-HitlLine $label "($expr ? 'finance.tpl.plain' : 'finance.value.household')" -Kind tpl -Params @{ value = $expr } }
    $dom  = Get-FinanceDomTpl "$S.schedule_day_of_month" -Empty "'finance.value.relative_to_start'"
    # Verrechnungskonto: im Import mit Herkunft (-D.SettlementRef = X.settlement_ref aus fn_import_ref_account:
    # 'db' besteht schon, 'batch' wird mit angelegt) -- der Owner las den nackten Namen als Neuanlage (2026-10-23).
    # Einzel-Tools loesen es immer gegen den Bestand auf -> dort nur der Name.
    $settle = { param($nameExpr, $if)
        if ($D.ContainsKey('SettlementRef')) {
            $r = $D['SettlementRef']
            New-HitlLine 'finance.label.settlement_account' "(!$nameExpr ? null : ($r === 'db' ? 'finance.tpl.account_existing' : ($r === 'batch' ? 'finance.tpl.account_created_with' : 'finance.tpl.plain')))" -Kind tpl -Params @{ value = $nameExpr } -If $if
        } else {
            New-HitlLine 'finance.label.settlement_account' $nameExpr -If $if
        }
    }

    switch ($Entity) {
        'account' {
            # Relevanz je Unterart, aber nie einen geschriebenen Wert verstecken: eine Zeile ausserhalb ihrer Unterart
            # erscheint, sobald der Wert genannt ist (fn_create_account schreibt ihn trotzdem bzw. lehnt ab).
            $isDepot = "['stocks_depot','crypto_depot'].includes($S.account_type)"
            $hasInt  = Get-FinanceNumSetJs "$S.interest_rate"
            $isFixed = "($S.account_type === 'fixed_deposit' || !!$S.fixed_deposit_maturity_date || ($S.fixed_deposit_auto_renew !== undefined && $S.fixed_deposit_auto_renew !== null && $S.fixed_deposit_auto_renew !== ''))"
            @(
                (New-HitlLine 'core.label.name'                  "$S.name")
                (New-HitlLine 'core.label.type'                  "$S.account_type" -Kind enum -Enum 'finance.enum.account_type')
                (New-HitlLine 'finance.label.bank'               "$S.bank" -OmitEmpty)
                (New-HitlLine 'finance.label.iban_number'        "$S.account_number" -OmitEmpty)
                (& $own 'finance.label.owner_person' (& $need 'Person'))
                (New-HitlLine 'finance.label.balance'            "($S.opening_balance || 0)" -Kind money -Currency (& $need 'Ccy') -If "!$isDepot")
                # Stichtag des Saldos (Konto aus Kontoauszug): Wert aus dem Probelauf der fn, nur im Einzel-Tool (-D.BalanceDate)
                if ($D.ContainsKey('BalanceDate')) { New-HitlLine 'finance.label.statement_date' $D['BalanceDate'] -Kind date -If "!!$S.opening_balance_date" }
                (& $settle "$S.settlement_account_name" "($isDepot || !!$S.settlement_account_name)")
                (New-HitlLine 'finance.label.interest'           "($hasInt ? 'finance.tpl.percent_pa' : 'finance.value.none')" -Kind tpl -Params @{ value = "$S.interest_rate" } -If "(!$isDepot || $hasInt)")
                (Get-FinanceInterestScheduleLines -If $hasInt -Unit "$S.interest_credit_unit" -Interval "$S.interest_credit_interval" `
                    -Dom "$S.interest_credit_day_of_month" -Pdom "$S.interest_posting_day_of_month" `
                    -FirstCredit (& $need 'FirstCredit') -Conv (& $need 'Conv') -ConvReason (& $need 'ConvReason'))
                (New-HitlLine 'finance.label.auto_post'          "($(& $need 'AutoPost') ? 'finance.value.auto_post_yes' : 'finance.value.auto_post_no')" -Kind key -If $hasInt)
                (New-HitlLine 'finance.label.interest_valid_from' (& $need 'ValidFrom') -Kind date -If $hasInt -IsDefault "!$S.interest_valid_from")
                (New-HitlLine 'finance.label.maturity'           "$S.fixed_deposit_maturity_date" -Kind date -If $isFixed)
                (New-HitlLine 'finance.label.auto_renew'         "$S.fixed_deposit_auto_renew" -Kind bool -If $isFixed)
                (New-HitlLine 'core.label.currency'              (& $need 'Ccy') -IsDefault "!$S.currency")
            )
        }
        'stock_buy' {
            $ccy = & $need 'Ccy'
            # Kennung wie fn_book_stock_buy (fn_holding_symbol: Ticker, sonst ISIN) -- Import-Karte aus X.symbol (derselbe
            # fn), Einzel-Tool spiegelt sie aus dem Input
            $sym = if ($D.ContainsKey('Symbol')) { $D['Symbol'] } else { "($S.symbol || $S.isin)" }
            $lines = @(
                # Krypto hat keine ISIN: ohne isin nur das Symbol (ein fehlender Parameter bliebe sonst als "{isin}" stehen);
                # ohne Ticker ist die Kennung die ISIN -> nur einmal zeigen statt "IE00... (IE00...)"
                (New-HitlLine 'finance.label.security'           "($S.isin && $sym !== $S.isin ? 'finance.tpl.symbol_isin' : 'finance.tpl.plain')" -Kind tpl -Params @{ symbol = $sym; isin = "$S.isin"; value = $sym })
                # Bezeichnung: derselbe Fallback wie fn_book_stock_buy (ohne Namen = Kennung)
                (New-HitlLine 'finance.label.designation'        "($S.name || $sym)")
                (New-HitlLine 'finance.label.depot'              "$S.depot_name")
                (& $settle (& $need 'Settlement') $null)
                (New-HitlLine 'finance.label.pieces'             "$S.shares" -Kind number -Digits -1)
                (New-HitlLine 'finance.label.price'              "$S.price_per_share" -Kind money -Currency $ccy)
                (New-HitlLine 'finance.label.order_fee'          "($S.order_fee || 0)" -Kind money -Currency $ccy)
            )
            if (-not $Import) {
                $lines += (New-HitlLine 'finance.label.total_cost' "(Number($S.shares) * Number($S.price_per_share) + Number($S.order_fee || 0))" -Kind money -Currency $ccy)
            }
            if ($Import) {
                # Import (Monats-Check WP-G): Anlageklasse nur zeigen, wenn der Auszug sie liefert (Owner las "Anlageklasse: —"
                # als Fehler); das Kurs-Symbol setzt tool_commit_import aus der Yahoo-Aufloesung der ISIN.
                $lines += (New-HitlLine 'finance.label.asset_class'  "$S.asset_class" -If "$S.asset_class")
                $lines += (New-HitlLine 'finance.label.quote_symbol' "$S.provider_symbol" -If "$S.provider_symbol")
                # Notierung nur in Fremdwaehrung (tool_commit_import, 2026-10-23): Kurs kommt z. B. in USD, Einstand bleibt EUR
                $lines += (New-HitlNote -Key 'finance.note.quote_symbol_foreign' -If "$S.provider_currency" -Params @{ currency = "$S.provider_currency" })
                # gedruckte Depotnummer (2026-10-23): ordnet das Depot zu; kennt das Depot seine Nummer noch nicht, speichert
                # der Commit sie mit (fn_import_depot_number_to_store) -> eigene Hinweiszeile mit Depot UND Nummer
                $lines += (New-HitlLine 'finance.label.depot_number' "$S.depot_number" -If "$S.depot_number")
                $lines += (New-HitlNote -Key 'finance.note.depot_number_stored' -If "!!$(& $need 'DepotNumberToStore')" -Params @{
                    number = (& $need 'DepotNumberToStore'); depot = "$S.depot_name" })
                $lines += (New-HitlLine 'finance.label.booking'  "'finance.value.position_takeover'" -Kind key)
            } else {
                $lines += (New-HitlLine 'finance.label.asset_class'  "$S.asset_class")
                $Y = & $need 'Quote'
                # Die Karte zeigt, was geschrieben wird: $S.provider_symbol IST der Write-Payload (nur ein adoptable Yahoo-
                # Vorschlag oder ein genanntes Symbol, Plausi-Pflicht 2026-10-27); Kurs/Boerse nur, wenn er zu genau
                # diesem Symbol gehoert.
                $quoteOk = "(!!$S.provider_symbol && $S.provider_symbol === $Y.provider_symbol && !!$Y.market_price)"
                $symKey = "($quoteOk ? ($Y.exchange ? 'finance.tpl.quote_symbol_price_exchange' : 'finance.tpl.quote_symbol_price') : 'finance.tpl.quote_symbol_plain')"
                $lines += (New-HitlLine 'finance.label.quote_symbol' $symKey -Kind tpl -Params @{
                    symbol   = "($S.provider_symbol || $sym)"
                    price    = (New-HitlValue -Kind money -Value "$Y.market_price" -Currency "($Y.currency || $ccy)")
                    exchange = "$Y.exchange" })
            }
            $lines += (New-HitlLine 'core.label.date'            (& $need 'Date') -Kind date)
            if (-not $Import) {
                # Fremdwaehrungs-Notierung (keine in Depot-Waehrung, plausibel; 2026-10-23) ist kein "nicht verifiziert"-Fall,
                # sondern ein Umrechnungs-Hinweis
                $lines += (New-HitlNote -Key 'finance.note.quote_symbol_unverified' -If "!$Y.adoptable")
                $lines += (New-HitlNote -Key 'finance.note.quote_symbol_foreign' -If "$Y.foreign_listing && $Y.plausible" -Params @{ currency = "$Y.currency" })
                $lines += (New-HitlNote -Key 'finance.note.existing_position' -If "($S.existing_position === true || $S.existing_position === 'true')")
            }
            $lines
        }
        'insurance' {
            @(
                (New-HitlLine 'core.label.name'                    "$S.name")
                (New-HitlLine 'finance.label.company'              "$S.insurance_company" -OmitEmpty)
                (New-HitlLine 'finance.label.policy_number'        "$S.policy_number" -OmitEmpty)
                (& $own 'finance.label.policyholder_person' (& $need 'Person'))
                # WP2: Beitrag je Abbuchung (genannt oder aus dem Jahresbeitrag) und Jahreswert kommen aus fn_insurance_fields
                # (Einzel-Tool: Vorschau-Knoten, Import: fn_import_card_rows) -- die Karte rechnet nichts.
                (New-HitlLine 'finance.label.rate_per_debit'       (& $need 'PeriodAmount') -Kind money -EurByModel)
                (New-HitlLine 'finance.label.payment_mode'         "'finance.tpl.every_unit'" -Kind tpl -Params @{
                    interval = "($S.schedule_interval || '1')"
                    unit     = (New-HitlValue -Kind enum -Value "($S.schedule_unit || 'year')" -Enum 'finance.enum.schedule_unit') })
                (New-HitlLine 'finance.label.annual_contribution'  (& $need 'Annual') -Kind money -EurByModel)
                (New-HitlLine 'finance.label.debit_day'            $dom -Kind tpl -Params @{ day = "$S.schedule_day_of_month" })
                (New-HitlLine 'finance.label.debit_account'        "$S.debit_account_name")
                (New-HitlLine 'finance.label.valid_from_contract'  "($S.valid_from || $S.first_payment_date)" -Kind date)
                (New-HitlLine 'finance.label.first_debit'          "$S.first_payment_date" -Kind date)
                (New-HitlLine 'finance.label.insurance_type'       "$S.insurance_type" -Kind enum -Enum 'finance.enum.insurance_type' -OmitEmpty)
                (New-HitlLine 'finance.label.coverage_amount'      "$S.coverage_amount" -Kind money -EurByModel -OmitEmpty)
                (New-HitlLine 'finance.label.beneficiary'          "$S.beneficiary" -OmitEmpty)
                (New-HitlLine 'finance.label.claim_deadline'       "($S.claim_deadline_hours ? 'finance.tpl.hours' : null)" -Kind tpl -Params @{ value = "$S.claim_deadline_hours" } -OmitEmpty)
            )
        }
        'pension' {
            $hasC = Get-FinanceNumSetJs "$S.contribution_amount"
            @(
                (New-HitlLine 'core.label.name'                          "$S.name")
                (New-HitlLine 'finance.label.kind'                       "$S.pension_type" -Kind enum -Enum 'finance.enum.pension_type')
                (New-HitlLine 'finance.label.provider'                   "$S.provider" -OmitEmpty)
                (New-HitlLine 'finance.label.contract_number'            "$S.contract_number" -OmitEmpty)
                (& $own 'finance.label.owner_person' (& $need 'Person'))
                (New-HitlLine 'finance.label.current_value'              "($S.current_value ? 'finance.tpl.plain' : 'finance.value.unknown')" -Kind tpl -Params @{
                    value = (New-HitlValue -Kind money -Value "$S.current_value" -EurByModel) })
                (New-HitlLine 'finance.label.valuation_date'             "$S.value_updated_at" -Kind date -OmitEmpty)
                (New-HitlLine 'finance.label.guaranteed_monthly_pension' "$S.guaranteed_monthly_pension" -Kind money -EurByModel -OmitEmpty)
                (New-HitlLine 'finance.label.retirement_start'           "$S.retirement_start_date" -Kind date -OmitEmpty)
                # WP2: Beitrag je Abbuchung + Rhythmus roh (Default monatlich); den Monatswert leitet pension_overview ab
                (New-HitlLine 'finance.label.rate_per_debit'            "($hasC ? 'finance.tpl.plain' : 'finance.value.none_parens')" -Kind tpl -Params @{
                    value = (New-HitlValue -Kind money -Value "$S.contribution_amount" -EurByModel) })
                (New-HitlLine 'finance.label.payment_mode'               "'finance.tpl.every_unit'" -Kind tpl -If $hasC -Params @{
                    interval = "($S.schedule_interval || '1')"
                    unit     = (New-HitlValue -Kind enum -Value "($S.schedule_unit || 'month')" -Enum 'finance.enum.schedule_unit') })
                (New-HitlLine 'finance.label.debit_account'              "$S.debit_account_name" -If $hasC)
                (New-HitlLine 'finance.label.first_debit'                "$S.first_payment_date" -Kind date -If $hasC)
                (New-HitlLine 'finance.label.debit_day'                  $dom -Kind tpl -Params @{ day = "$S.schedule_day_of_month" } -If $hasC)
                (New-HitlLine 'finance.label.notes'                      "$S.notes" -OmitEmpty)
            )
        }
        'pension_statement' {
            @(
                (New-HitlLine 'finance.label.pension'         "$S.pension")
                (New-HitlLine 'finance.label.statement_date'  "$S.statement_date" -Kind date)
                (New-HitlLine 'finance.label.reached_claim'   "$S.reached_claim" -Kind money -EurByModel -OmitEmpty)
                (New-HitlLine 'finance.label.projection'      "$S.projection" -Kind money -EurByModel -OmitEmpty)
                (New-HitlLine 'finance.label.scenario_1pct'   "$S.scenario_1pct" -Kind money -EurByModel -OmitEmpty)
                (New-HitlLine 'finance.label.scenario_2pct'   "$S.scenario_2pct" -Kind money -EurByModel -OmitEmpty)
                (New-HitlLine 'finance.label.em_monthly'      "$S.em_monthly" -Kind money -EurByModel -OmitEmpty)
                (New-HitlLine 'finance.label.earning_points'  "$S.earning_points" -Kind number -Digits -1 -OmitEmpty)
                (New-HitlLine 'finance.label.regular_retirement_date' "$S.regular_retirement_date" -Kind date -OmitEmpty)
                (New-HitlLine 'finance.label.notes'           "$S.notes" -OmitEmpty)
            )
        }
        'recurring_payment' {
            @(
                (New-HitlLine 'core.label.name'             "$S.name")
                (New-HitlLine 'finance.label.account'       "$S.account_name")
                (New-HitlLine 'finance.label.direction'     "($S.direction === 'expense' ? 'outflow' : 'inflow')" -Kind enum -Enum 'finance.enum.direction')
                (New-HitlLine 'core.label.amount'           "$S.amount" -Kind money -Currency (& $need 'Ccy'))
                (New-HitlLine 'finance.label.cycle'         "'finance.tpl.every_unit'" -Kind tpl -Params @{
                    interval = "($S.schedule_interval || '1')"
                    unit     = (New-HitlValue -Kind enum -Value "$S.schedule_unit" -Enum 'finance.enum.schedule_unit') })
                (New-HitlLine 'finance.label.debit_day'     $dom -Kind tpl -Params @{ day = "$S.schedule_day_of_month" } -If "$S.direction === 'expense'")
                (New-HitlLine 'finance.label.credit_day'    $dom -Kind tpl -Params @{ day = "$S.schedule_day_of_month" } -If "$S.direction !== 'expense'")
                (New-HitlLine 'finance.label.first_payment' "$S.first_payment_date" -Kind date)
                (New-HitlLine 'finance.label.valid_from'    "($S.valid_from || $S.first_payment_date)" -Kind date -IsDefault "!$S.valid_from")
                (New-HitlLine 'finance.label.valid_to'      "($S.valid_to ? 'finance.tpl.plain' : 'finance.value.unlimited')" -Kind tpl -Params @{
                    value = (New-HitlValue -Kind date -Value "$S.valid_to") })
                (New-HitlLine 'core.label.note'             "$S.notes" -OmitEmpty)
            )
        }
        'real_estate' {
            @(
                (New-HitlLine 'core.label.name'             "$S.name")
                (New-HitlLine 'finance.label.current_value' "($S.current_value || null)" -Kind money -EurByModel -OmitEmpty)
                (New-HitlLine 'finance.label.valuation_date' "$S.value_updated_at" -Kind date -OmitEmpty)
                (& $own 'finance.label.owner_person' (& $need 'Person'))
                (New-HitlLine 'core.label.status'           "($S.status || 'active')" -Kind enum -Enum 'finance.enum.status' -IsDefault "!$S.status")
                (New-HitlLine 'finance.label.notes'         "$S.notes" -OmitEmpty)
            )
        }
        'savings_goal' {
            # Sparziel-Zweckbindung 2026-10-27: eine eigene Rate gibt es nur fuer einen Rest > 0 ohne Sparplan; sonst
            # entfallen Rate-Details (Abbuchungskonto/-tag, erste Buchung) und die Zeile zeigt 0 (Hinweis kommt aus der fn).
            $rate = & $need 'MonthlyRate'
            $hasRate = "(Number($rate) > 0 && !$S.savings_plan_name)"
            @(
                (New-HitlLine 'core.label.name'                    "$S.goal_name")
                (New-HitlLine 'finance.label.goal_type'            "$S.goal_type" -OmitEmpty)
                (New-HitlLine 'finance.label.target_amount'        "$S.target_amount" -Kind money -EurByModel)
                (New-HitlLine 'finance.label.target_date'          (& $need 'TargetDate') -Kind date)
                (New-HitlLine 'finance.label.already_saved'        "($S.already_saved || null)" -Kind money -Currency "($S.reserve_currency || 'EUR')" -OmitEmpty)
                (New-HitlLine 'finance.label.monthly_savings_rate' "'finance.tpl.rate_computed'" -Kind tpl -If $hasRate -Params @{
                    value  = (New-HitlValue -Kind money -Value $rate -EurByModel)
                    months = (& $need 'Months') })
                (New-HitlLine 'finance.label.monthly_savings_rate' "0" -Kind money -EurByModel -If "!($hasRate) && !$S.savings_plan_name")
                (New-HitlLine 'finance.label.link_savings_plan'    "$S.savings_plan_name" -OmitEmpty)
                # 2026-10-27: Antwort auf existing_transfer (fortfuehren oder zusaetzlich); Konto/Tag kommen dann aus r.effective
                (New-HitlLine 'finance.label.standing_transfer'    "(String($S.replace_transfer) === 'true' ? 'finance.value.transfer_continued' : (String($S.replace_transfer) === 'false' ? 'finance.value.transfer_additional' : null))" -Kind key -OmitEmpty)
                (New-HitlLine 'finance.label.debit_account'        "$S.account_name" -If $hasRate)
                (New-HitlLine 'finance.label.reserve_pot'          "'finance.tpl.reserve_pot'" -Kind tpl -If $hasRate -Params @{ name = "$S.reserve_account_name" })
                (New-HitlLine 'finance.label.reserve_pot'          "$S.reserve_account_name" -If "!($hasRate)")
                (New-HitlLine 'finance.label.debit_day'            (Get-FinanceDomTpl "$S.schedule_day_of_month" -DayTpl 'finance.tpl.day_ordinal' -Empty "'finance.value.relative_to_start'") -Kind tpl -If $hasRate -Params @{ day = "$S.schedule_day_of_month" })
                # WP2: ohne genanntes Datum die erste Rate aus fn_savings_rate_schedule (naechster Termin ab heute); das
                # Einzel-Tool pinnt sie ueber r.effective und meldet first_payment_defaulted (Vorgabe-Markierung bleibt)
                (New-HitlLine 'finance.label.first_booking'        "($S.first_payment_date || $(& $need 'FirstPayment'))" -Kind date -If $hasRate -IsDefault "($S.first_payment_defaulted === true || !$S.first_payment_date)")
                (& $own 'finance.label.beneficiary_person' (& $need 'Person'))
                (New-HitlLine 'finance.label.priority'             "($S.priority ? 'finance.tpl.priority_hint' : null)" -Kind tpl -Params @{ value = "$S.priority" } -OmitEmpty)
                (New-HitlLine 'core.label.note'                    "$S.notes" -OmitEmpty)
            )
        }
        'loan' {
            $hasRate = Get-FinanceNumSetJs "$S.monthly_annuity"
            $ldom = Get-FinanceDomTpl "$S.schedule_day_of_month"
            # Aufteilung der 1. Rate aus der Restschuld: Einzel-Tool = Probelauf von fn_create_loan, Import =
            # fn_import_card_rows (beide fn_loan_monthly_interest) -- die Karte rechnet nichts (Live-Befund 2026-10-24).
            $rateInt = & $need 'RateInterest'
            $ratePri = & $need 'RatePrincipal'
            # laufend (Restschuld zum Stichtag heute) entscheidet die DB: Einzel-Tool = Probelauf opening_balance_date,
            # Import = X.running (dieselbe Regel wie fn_create_loan)
            $running = & $need 'Running'
            @(
                (New-HitlLine 'core.label.name'                      "$S.name")
                (New-HitlLine 'finance.label.lender'                 "$S.lender" -OmitEmpty)
                (& $own 'finance.label.borrower_person' (& $need 'Person'))
                (New-HitlLine 'finance.label.loan_amount_original'   "$S.original_amount" -Kind money -EurByModel -OmitEmpty)
                (New-HitlLine 'finance.label.remaining_debt_current' "($running ? 'finance.tpl.amount_running_loan' : 'finance.tpl.plain')" -Kind tpl -Params @{
                    value = (New-HitlValue -Kind money -Value "($S.current_balance || $S.original_amount)" -EurByModel) })
                (New-HitlLine 'finance.label.disbursement_date'      "$S.disbursement_date" -Kind date -OmitEmpty)
                (New-HitlLine 'finance.label.interest_rate'          "'finance.tpl.percent_pa'" -Kind tpl -Params @{ value = "$S.interest_rate" })
                (New-HitlLine 'finance.label.fixed_until'            "$S.interest_rate_fixed_until" -Kind date -OmitEmpty)
                (New-HitlLine 'finance.label.term_end'               "$S.term_end_date" -Kind date -OmitEmpty)
                # WP2: voraussichtliche Restschuld (bei gleichem Zins, ohne Sondertilgung) aus dem Probelauf von fn_create_loan
                # (loan_overview/fn_loan_projected_balance) -- nur die Einzel-Karte; leer (kein Datum, keine Rate) entfaellt
                if ($D.ContainsKey('BalFixed')) {
                    (New-HitlLine 'finance.label.balance_projected_fixed_until' $D['BalFixed'] -Kind money -EurByModel -OmitEmpty)
                    (New-HitlLine 'finance.label.balance_projected_term_end'    $D['BalTermEnd'] -Kind money -EurByModel -OmitEmpty)
                }
                (New-HitlLine 'finance.label.monthly_instalment'     "($hasRate ? 'finance.tpl.plain' : 'finance.value.no_instalment')" -Kind tpl -Params @{
                    value = (New-HitlValue -Kind money -Value "$S.monthly_annuity" -EurByModel) })
                (New-HitlLine 'finance.label.first_rate_split'       "'finance.tpl.rate_split'" -Kind tpl -If $hasRate -Params @{
                    interest  = (New-HitlValue -Kind money -Value $rateInt -EurByModel)
                    principal = (New-HitlValue -Kind money -Value $ratePri -EurByModel) })
                (New-HitlLine 'finance.label.first_instalment'       "$S.first_payment_date" -Kind date -If $hasRate)
                (New-HitlLine 'finance.label.debit_day'              $ldom -Kind tpl -Params @{ day = "$S.schedule_day_of_month" } -If $hasRate)
                (New-HitlLine 'finance.label.debit_account_instalment' "$S.debit_account_name")
                (New-HitlLine 'finance.label.disbursed_to_own'       "($S.disbursement_account_name ? 'finance.tpl.disbursed_to_account' : 'finance.value.disbursed_no')" -Kind tpl -Params @{ account = "$S.disbursement_account_name" })
                (New-HitlLine 'finance.label.real_estate'            (& $need 'RealEstate') -OmitEmpty)
                (New-HitlLine 'core.label.note'                      "$S.notes" -OmitEmpty)
            )
        }
    }
}

# Import-Karte: Feldnamen-Mapping Staging -> Einzel-Tool (Alias), Ueberschrift je Art (Heading) und die abgeleiteten
# Werte X.* aus finance.fn_import_card_rows (D). Covered = erlaubte Import-Felder, die die Karte ueber einen
# abgeleiteten Wert statt ueber S.<feld> zeigt (Test-FinanceImportKeysCovered).
$script:FIN_IMPORT_CARD = [ordered]@{
    account           = @{ Heading = 'finance.label.account'; Alias = @{ settlement_account = 'settlement_account_name' }
                           D = @{ Person = 'X.person'; Ccy = 'X.ccy'; SettlementRef = 'X.settlement_ref'; Conv = 'X.interest.conv'; ConvReason = 'X.interest.conv_reason'; AutoPost = 'X.interest.auto_post'; ValidFrom = 'X.interest.valid_from'; FirstCredit = 'X.interest.first_credit_date' }
                           Covered = @('interest_day_count_convention', 'interest_auto_post') }
    stock_buy         = @{ Heading = 'finance.label.holding_position'; Alias = @{ depot = 'depot_name' }
                           D = @{ Ccy = 'X.ccy'; Settlement = 'X.settlement'; SettlementRef = 'X.settlement_ref'; Date = 'X.transaction_date'; Symbol = 'X.symbol'; DepotNumberToStore = 'X.depot_number_to_store' }
                           # symbol: die Karte zeigt die Kennung X.symbol (fn_holding_symbol: genannter Ticker, sonst ISIN);
                           # depot_holder: nur Hinweis fuer die Depot-Zuordnung (fn_import_resolve_depot), wird nicht
                           # gespeichert -- die Karte zeigt das gewaehlte Depot
                           Covered = @('quote_currency', 'transaction_date', 'symbol', 'depot_holder') }
    insurance         = @{ Heading = 'finance.label.insurance'; Alias = @{ debit_account = 'debit_account_name' }
                           D = @{ Person = 'X.person'; PeriodAmount = 'X.period_amount'; Annual = 'X.annual_premium' }
                           # Beitrag: die Karte zeigt den Betrag je Abbuchung bzw. Jahreswert als abgeleiteten Wert (X.*)
                           Covered = @('premium_amount', 'annual_premium') }
    pension           = @{ Heading = 'finance.label.pension'; Alias = @{ debit_account = 'debit_account_name' }
                           D = @{ Person = 'X.person' }; Covered = @() }
    # pension_id = interner Griff von fn_import_stage (Folgebescheid an die vorhandene gesetzliche Rente); die Karte
    # zeigt dieselbe Rente ueber die Zeile finance.label.pension (S.pension).
    pension_statement = @{ Heading = 'finance.label.pension_statement'; Alias = @{}
                           D = @{}; Covered = @('pension_id') }
    recurring_payment = @{ Heading = 'finance.label.recurring_payment'; Alias = @{ account = 'account_name' }
                           D = @{ Ccy = 'X.ccy' }; Covered = @() }
    real_estate       = @{ Heading = 'finance.label.real_estate'; Alias = @{}
                           D = @{ Person = 'X.person' }; Covered = @() }
    savings_goal      = @{ Heading = 'finance.label.savings_goal'; Alias = @{ name = 'goal_name'; account = 'account_name'; reserve_account = 'reserve_account_name'; savings_plan = 'savings_plan_name' }
                           D = @{ Person = 'X.person'; TargetDate = '(X.schedule || {}).target_date'; MonthlyRate = '(X.schedule || {}).monthly_rate'; Months = '(X.schedule || {}).months'; FirstPayment = '(X.schedule || {}).first_payment_date' }
                           Covered = @('target_date', 'monthly_savings_rate') }
    loan              = @{ Heading = 'finance.label.loan'; Alias = @{ debit_account = 'debit_account_name'; disbursement_account = 'disbursement_account_name' }
                           D = @{ Person = 'X.person'; RealEstate = 'S.real_estate'; RateInterest = '(X.rate_split || {}).interest'; RatePrincipal = '(X.rate_split || {}).principal'; Running = 'X.running' }; Covered = @() }
}

# Die erlaubten Import-Felder je Art aus der EINEN SQL-Adresse (R__fn_import_allowed_keys.sql, Zeilenformat
# WHEN '<typ>' THEN ARRAY[...]) lesen.
function Get-FinanceImportAllowedKeys {
    $path = Join-Path $PSScriptRoot '..\..\db\migrations\R__fn_import_allowed_keys.sql'
    $sql = [System.IO.File]::ReadAllText((Resolve-Path $path), [System.Text.UTF8Encoding]::new($false))
    $map = [ordered]@{}
    foreach ($m in [regex]::Matches($sql, "WHEN '(\w+)' THEN ARRAY\[([^\]]*)\]")) {
        $map[$m.Groups[1].Value] = @([regex]::Matches($m.Groups[2].Value, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value })
    }
    if ($map.Count -ne $script:FIN_IMPORT_CARD.Count) { throw "Get-FinanceImportAllowedKeys: $($map.Count) Arten in R__fn_import_allowed_keys.sql, $($script:FIN_IMPORT_CARD.Count) in FIN_IMPORT_CARD" }
    $map
}

# Bricht den Build, wenn ein erlaubtes Import-Feld keine Kartenzeile hat (S.<einzel-tool-name> im Zeilen-JS, das
# Personen-Feld ueber X.person oder ein Covered-Eintrag).
function Test-FinanceImportKeysCovered([System.Collections.IDictionary]$LinesJs) {
    $allowed = Get-FinanceImportAllowedKeys
    # Personen-Feld je Art aus der EINEN SQL-Adresse (R__fn_import_person_field.sql, WHEN-Zeilen)
    $pfSql = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot '..\..\db\migrations\R__fn_import_person_field.sql')), [System.Text.UTF8Encoding]::new($false))
    $person = @{}
    foreach ($m in [regex]::Matches($pfSql, "WHEN p_type (?:IN \(([^)]*)\)|= ('\w+'))\s+THEN '(\w+)'")) {
        foreach ($tm in [regex]::Matches(($m.Groups[1].Value + $m.Groups[2].Value), "'(\w+)'")) { $person[$tm.Groups[1].Value] = $m.Groups[3].Value }
    }
    if ($person.Count -lt 1) { throw 'Test-FinanceImportKeysCovered: keine Personen-Felder aus R__fn_import_person_field.sql gelesen' }
    foreach ($t in $allowed.Keys) {
        $cfg = $script:FIN_IMPORT_CARD[$t]
        foreach ($k in $allowed[$t]) {
            $name = if ($cfg.Alias.ContainsKey($k)) { $cfg.Alias[$k] } else { $k }
            if ($cfg.Covered -contains $k -or $person[$t] -eq $k) { continue }
            if ($LinesJs[$t] -notmatch "\bS\.$([regex]::Escape($name))\b") {
                throw "Test-FinanceImportKeysCovered: Import-Feld '$k' ($t) hat keine Kartenzeile (S.$name) — Zeile in Get-FinanceHitlLines ergaenzen oder das Feld aus fn_import_allowed_keys nehmen"
            }
        }
    }
}

# JS-Ausdruck (LinesExpr) der Import-Karte: je Staging-Zeile eine Ueberschrift '<Art>: <Name>' + die Zeilen
# aus Get-FinanceHitlLines (S = Payload mit Einzel-Tool-Feldnamen, X = abgeleitete Werte der Zeile).
# Bewusst OHNE row_no: die Staging-Nummer ist ein interner Griff des Agenten (bleibt nach geloeschten Zeilen
# stabil, Luecken moeglich) — auf der Karte las der Owner '#4' als "4 Dinge angelegt" (2026-10-22).
function Get-FinanceImportCardLinesExpr([Parameter(Mandatory)][string]$RowsExpr) {
    $fns = [ordered]@{}
    foreach ($t in $script:FIN_IMPORT_CARD.Keys) {
        $cfg = $script:FIN_IMPORT_CARD[$t]
        $fns[$t] = '(S, X) => [ ' + ((Get-FinanceHitlLines -Entity $t -S 'S' -D $cfg.D -Import) -join ', ') + ' ]'
    }
    Test-FinanceImportKeysCovered $fns
    $L  = '{ ' + (($fns.Keys | ForEach-Object { "${_}: $($fns[$_])" }) -join ', ') + ' }'
    $AL = '{ ' + (($script:FIN_IMPORT_CARD.Keys | ForEach-Object {
            $a = $script:FIN_IMPORT_CARD[$_].Alias
            "${_}: { " + (($a.Keys | Sort-Object | ForEach-Object { "${_}: '$($a[$_])'" }) -join ', ') + ' }' }) -join ', ') + ' }'
    $H  = '{ ' + (($script:FIN_IMPORT_CARD.Keys | ForEach-Object { "${_}: '$($script:FIN_IMPORT_CARD[$_].Heading)'" }) -join ', ') + ' }'
    "(() => { const L = $L; const AL = $AL; const H = $H; const out = []; " +
    "for (const r of ($RowsExpr || [])) { const S = Object.assign({}, r.p || {}); const al = AL[r.entity_type] || {}; " +
    "for (const k of Object.keys(al)) { if (S[k] !== undefined) S[al[k]] = S[k]; } " +
    "out.push({ kind: 'heading', label: (H[r.entity_type] || 'core.label.type'), value: r.name });" +
    "for (const l of (L[r.entity_type] ? L[r.entity_type](S, r.x || {}) : [])) { if (l) out.push(l); } } " +
    "return out; })()"
}
