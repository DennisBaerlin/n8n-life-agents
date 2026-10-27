#Requires -Version 5.1
# Definition agent.finance.cron_remind_missing_prices -> Build-CronRemindMissingPrices. Dot-gesourct von build.ps1.
# Kurs-Luecken-Erinnerung (Owner 2026-10-27: "ein Kurs, der nicht gefunden wird, darf nie unentdeckt bleiben").
# Deterministisch bis auf EINE optionale Websuche je Luecke und Latch-Fenster. Ablauf: Schedule (im Erinnerungs-
# fenster) -> finance.fn_price_gaps() (Luecken missing|stale, Feed-Ausfall, Re-Arm behobener Luecken) ->
#   Feed-Ausfall -> EINE Meldung (Latch 'feed_down', 7 Tage);
#   sonst je Luecke: fn_price_gap_claim (Latch je Position, 7 Tage; DIREKT vor dem eigenen Versand) -> Yahoo-ISIN-Suche
#   (sub_resolve_yahoo_symbol, Plausi-Pflicht) -> kein Kandidat: Websuche (core:web_search) nach Boersen-Tickern ->
#   dieselbe Sub prueft sie (try_symbols) -> Karte [Uebernehmen]/[Nicht jetzt] ODER Text-Hinweis.
#   Uebernehmen -> fn_apply_price_symbol (Guard already_resolved) -> Kurs (+FX) sofort holen -> Ergebnis-Zeile.
# Warum Cron statt Monitor-Trigger: Dialog + Schreibzugriff auf eine Domaenen-Tabelle (packages/core/CLAUDE.md
# Cron-vs-Trigger-Gesetz). Warum kein Callback-Knopf: der DB-Handler kann den Kurs nicht sofort holen.
function Build-CronRemindMissingPrices {
    # Schreibt via fn_apply_price_symbol/fn_price_gap_claim -> enge Paket-Schreibrolle finance_rw (D10).
    $CRED_POSTGRES = $CRED_FINANCE_RW
    $ResolveYahooSymbolId = Get-RequiredWorkflowId 'agent.finance.sub_resolve_yahoo_symbol' 'Build-CronRemindMissingPrices' -Soft
    $MarketPricesCronId   = Get-RequiredWorkflowId 'agent.finance.cron_refresh_market_prices' 'Build-CronRemindMissingPrices' -Soft
    $FxCronId             = Get-RequiredWorkflowId 'agent.finance.cron_refresh_fx_rates' 'Build-CronRemindMissingPrices'
    $webSearchName        = Resolve-CoreServiceAlias 'core:web_search' $CoreServiceMap
    $WebSearchId          = Get-RequiredWorkflowId $webSearchName 'Build-CronRemindMissingPrices'

    $trig = Build-ScheduleTrigger @(-1100, 0) -ScheduleKey 'remind_missing_prices'

    $gate = Build-Pg 'Cron enabled?' @(-920, 0) `
        "SELECT core.fn_package_active('finance') AND COALESCE(core.fn_config_get('finance','cron_enable','remind_missing_prices') = 'true', false) AS enabled"
    $gateIf = Build-If 'Cron on?' @(-760, -40) "={{ `$json.enabled }}" 'true' 'equals' 'boolean'
    $gateOff = Build-NoOp 'Disabled' @(-760, 200)

    # EINE Zeile: Luecken-Dokument (Seiteneffekt: Re-Arm behobener Luecken) + Texte in Owner-Sprache.
    $keys = Get-UiKeysSql (@(
        'finance.dialog.price_gap_missing', 'finance.dialog.price_gap_stale', 'finance.dialog.price_gap_found',
        'finance.dialog.price_gap_none', 'finance.dialog.price_gap_maybe', 'finance.dialog.price_gap_btn_apply',
        'finance.dialog.price_gap_btn_later', 'finance.dialog.price_gap_applied', 'finance.dialog.price_gap_applied_noprice',
        'finance.dialog.price_gap_already', 'finance.dialog.price_gap_failed', 'finance.dialog.price_gap_later',
        'finance.dialog.price_feed_down', 'core.reminders.card_footer', 'core.hitl.unauthorized') + $script:UiRenderKeys)
    $find = Build-Pg 'Find gaps' @(-560, 0) @"
=SELECT x.r AS doc, core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb($keys))) AS ui
FROM (SELECT finance.fn_price_gaps() AS r) x;
"@ $null
    $T   = "`$('Find gaps').first().json.ui.t"
    $lib = Get-UiRenderLibJs

    # Feed-Ausfall -> EIN Item; sonst ein Item je Luecke (0 Luecken -> 0 Items -> Ende).
    $planJs = $lib + @'
const m = $('Find gaps').first().json;
const doc = m.doc || {};
const U = uiRender(m.ui || {});
if (doc.feed_down) {
  return [{ json: { mode: 'feed_down', text: U.fill(U.t('finance.dialog.price_feed_down'), { date: { kind: 'date', value: doc.stale_since } })
                                          + '\n\n' + U.t('core.reminders.card_footer') } }];
}
const fx = JSON.stringify(doc.fx || {});
return (Array.isArray(doc.gaps) ? doc.gaps : []).map((g) => ({ json: Object.assign({ mode: 'gap', fx_json: fx }, g) }));
'@
    $plan = [ordered]@{ parameters = [ordered]@{ jsCode = $planJs }; type = 'n8n-nodes-base.code'; typeVersion = 2
        position = @(-340, 0); id = (New-Id); name = 'Plan items' }
    $ifFeed = Build-If 'Feed down?' @(-140, 0) "={{ `$json.mode === 'feed_down' }}" 'true' 'equals' 'boolean'
    $claimFeed = Build-Pg 'Claim feed down' @(60, -260) "SELECT finance.fn_price_gap_claim('feed_down') AS due;"
    $ifFeedDue = Build-If 'Feed due?' @(260, -260) "={{ `$json.due }}" 'true' 'equals' 'boolean'
    $nFeed = New-TelegramSendNode 'Notify feed down' @(460, -320) "={{ `$('Plan items').first().json.text }}"

    $loop = Build-Loop 'Loop Over Items' @(60, 100)
    $done = Build-NoOp 'Done' @(260, -60)
    # .first() = juengster Lauf der Schleife = die aktuelle Luecke. Bewusst nicht .item: hinter den Code-Knoten (neue Items
    # ohne Paarung) und dem Websuche-Aufruf traegt die Item-Paarung nicht verlaesslich.
    $it   = "`$('Loop Over Items').first().json"

    # Latch je Position DIREKT vor dem eigenen Versand (nie fuer alle vorab).
    $claim = Build-Pg 'Claim gap' @(260, 160) "=SELECT finance.fn_price_gap_claim((`$1::jsonb)->>'key') AS due;" `
        ([ordered]@{ key = "String($it.holding_id)" })
    $ifDue = Build-If 'Gap due?' @(460, 160) "={{ `$json.due }}" 'true' 'equals' 'boolean'

    # Yahoo-Suche: immer ISIN-Suche (provider_symbol leer, auch ein kaputtes Override wird neu gesucht); gewuenschte
    # Waehrung = die der Position; Plausi-Referenzen = letzter Kurs (enges Band) UND Einstand (grobes Band), je in ihrer
    # Waehrung, FX-Karte aus fn_price_gaps (ein veralteter oder falscher letzter Kurs sperrt so keinen richtigen Treffer).
    $resolveInputs = {
        param([string]$Try)
        [ordered]@{
            isin            = "={{ $it.isin || '' }}"
            raw_symbol      = "={{ $it.symbol || '' }}"
            price_currency  = "={{ $it.currency || '' }}"
            price_per_share = "={{ '' }}"
            provider_symbol = "={{ '' }}"
            ref_price       = "={{ $it.price != null ? String($it.price) : '' }}"
            ref_currency    = "={{ $it.price_currency || '' }}"
            cost_price      = "={{ $it.avg_price != null ? String($it.avg_price) : '' }}"
            cost_currency   = "={{ $it.currency || '' }}"
            fx_rates        = "={{ $it.fx_json || '{}' }}"
            try_symbols     = $Try
        }
    }
    $resolve = Build-CallWorkflow 'Resolve Yahoo symbol' @(660, 100) $ResolveYahooSymbolId 'agent.finance.sub_resolve_yahoo_symbol' `
        (& $resolveInputs "={{ '' }}")

    # Kandidat bewerten + Texte bauen (EINE Regel fuer Yahoo- und Websuche-Kandidaten): uebernehmbar nur mit ISIN,
    # anderem Symbol als dem heutigen Feed-Symbol und adoptable (Sub: verifiziert inkl. Plausi-Pflicht, oder plausible
    # Fremdwaehrungs-Notierung derselben ISIN; Websuche-Ticker nie Fremdwaehrung).
    $pickJs = {
        param([bool]$Web)
        $lib + @'
const m = $('Find gaps').first().json;
const U = uiRender(m.ui || {});
const g = $('Loop Over Items').first().json;
const y = $input.first().json || {};
const WEB = __WEB__;
const cur = String(g.feed_symbol || '').toUpperCase();
const sym = String(y.provider_symbol || '').toUpperCase();
const hasQuote = !!g.isin && !!sym && sym !== cur && Number(y.market_price) > 0;
const accept = hasQuote && y.adoptable === true;
const head = g.status === 'stale'
  ? U.fill(U.t('finance.dialog.price_gap_stale'), { name: g.name, account: g.account_name, feed: g.feed_symbol, date: { kind: 'date', value: g.price_as_of } })
  : U.fill(U.t('finance.dialog.price_gap_missing'), { name: g.name, account: g.account_name, feed: g.feed_symbol });
const price = { kind: 'money', value: y.market_price, currency: y.currency };
const footer = U.t('core.reminders.card_footer');
const card = head + '\n\n' + U.fill(U.t('finance.dialog.price_gap_found'), { symbol: sym, listing: y.name || sym, exchange: y.exchange || '', price: price })
           + '\n\n' + footer;
const maybe = (!accept && hasQuote) ? U.fill(U.t('finance.dialog.price_gap_maybe'), { symbol: sym, listing: y.name || y.exchange || sym, price: price }) + '\n\n' : '';
const none = head + '\n\n' + maybe + U.fill(U.t('finance.dialog.price_gap_none'), { name: g.name }) + '\n\n' + footer;
return [{ json: { accept: accept, try_web: !accept && !WEB && !!g.isin, cand_symbol: sym, cand_currency: String(y.currency || ''),
                  text_card: card, text_none: none } }];
'@ -replace '__WEB__', ($(if ($Web) { 'true' } else { 'false' }))
    }
    $pick = [ordered]@{ parameters = [ordered]@{ jsCode = (& $pickJs $false) }; type = 'n8n-nodes-base.code'; typeVersion = 2
        position = @(860, 100); id = (New-Id); name = 'Pick candidate' }
    $ifAccept = Build-If 'Accept?' @(1060, 100) "={{ `$json.accept }}" 'true' 'equals' 'boolean'
    $ifTryWeb = Build-If 'Try web?' @(1260, 300) "={{ `$json.try_web }}" 'true' 'equals' 'boolean'

    # Websuche (bezahlte Anthropic-API ueber den Core-Dienst; nur ISIN + Name, keine Bestaende). Fehler -> weiter ohne.
    $web = Build-CallWorkflow 'Web search' @(1460, 220) $WebSearchId $webSearchName ([ordered]@{
        query = "={{ 'Yahoo Finance ticker symbols with exchange suffix (for example .DE Xetra, .F Frankfurt, .L London, .AS Amsterdam, .MI Milan) for the security with ISIN ' + $it.isin + ' (' + $it.name + '). List the symbols.' }}"
    })
    $web['onError'] = 'continueRegularOutput'
    $web['alwaysOutputData'] = $true
    $parseJs = @'
const w = $input.first().json || {};
const g = $('Loop Over Items').first().json;
const cur = String(g.feed_symbol || '').toUpperCase();
// Nur der Antwort-Teil, ohne Quellenliste und ohne URLs/Domains: sonst zaehlten boerse-frankfurt.de, onvista.de & Co.
// als ".DE"-Ticker und verbrauchten das 3er-Budget (Code-Review 2026-10-27).
const answer = String(w.ok === false ? '' : (w.results || '')).split('=== SOURCES ===')[0];
const txt = answer.replace(/https?:\/\/\S+/gi, ' ').replace(/\bwww\.\S+/gi, ' ').replace(/\b[\w-]+\.(?:com|net|org|io|eu|info)\b/gi, ' ');
// Yahoo-Format mit Boersen-Suffix; erfundene Ticker scheitern danach am Chart-Abruf bzw. an der Plausi-Pruefung.
const RX = /\b([A-Z0-9]{1,12}\.(?:DE|F|SG|MU|BE|DU|HM|HA|L|AS|PA|MI|SW|VI|BR|MC|LS|IR|CO|ST|OL|HE|TO|AX|HK|T))\b/g;
const out = [];
let mm;
while ((mm = RX.exec(txt)) !== null && out.length < 3) {
  const s = mm[1];
  if (s !== cur && !out.includes(s)) out.push(s);
}
return [{ json: Object.assign({}, $('Pick candidate').first().json, { tickers: out.join(','), ticker_count: out.length }) }];
'@
    $parse = [ordered]@{ parameters = [ordered]@{ jsCode = $parseJs }; type = 'n8n-nodes-base.code'; typeVersion = 2
        position = @(1660, 220); id = (New-Id); name = 'Parse tickers' }
    $ifTickers = Build-If 'Any ticker?' @(1860, 220) "={{ `$json.ticker_count }}" '0' 'larger' 'number'
    $resolveWeb = Build-CallWorkflow 'Resolve web tickers' @(2060, 140) $ResolveYahooSymbolId 'agent.finance.sub_resolve_yahoo_symbol' `
        (& $resolveInputs "={{ `$('Parse tickers').first().json.tickers }}")
    $pickWeb = [ordered]@{ parameters = [ordered]@{ jsCode = (& $pickJs $true) }; type = 'n8n-nodes-base.code'; typeVersion = 2
        position = @(2260, 140); id = (New-Id); name = 'Pick web candidate' }

    $nNone = New-TelegramSendNode 'Notify no source' @(2060, 420) "={{ `$json.text_none }}" -OnError 'continueRegularOutput'

    # Karte: zwei Knoepfe (sendAndWait); ohne Tipp nach 8 h weiter wie "Nicht jetzt" (kein Write, keine haengende Execution).
    $ask = New-TelegramSendAndWaitNode 'Ask price symbol' @(1260, -40) '={{ $json.text_card }}' `
        -ApproveLabel (Get-UiTextExpr $T 'finance.dialog.price_gap_btn_apply') `
        -DisapproveLabel (Get-UiTextExpr $T 'finance.dialog.price_gap_btn_later') `
        -UnauthorizedReply (Get-UiTextExpr $T 'core.hitl.unauthorized') -LimitWaitMinutes 480
    $gAsk = New-StaleTapGuard -AskName 'Ask price symbol' -Next 'Apply?' -Pos @(1460, -160)
    $ifApply = Build-If 'Apply?' @(1820, -160) "={{ `$json.data && `$json.data.approved === true }}" 'true' 'equals' 'boolean'

    # Kandidat aus dem LETZTEN Lauf von Accept? (.first() = juengster Lauf, Hauptausgang true): Accept? laeuft je Runde
    # bis zu zweimal (Yahoo-, dann Websuche-Kandidat); nur der true-Lauf fuehrt zur Karte. Muster wie 'Loop Over Items'.
    $A = "`$('Accept?').first().json"
    $apply = Build-Pg 'Apply symbol' @(2020, -260) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'code' AS code FROM finance.fn_apply_price_symbol(`$1::jsonb) AS r;" `
        ([ordered]@{
            holding_id           = "$it.holding_id"
            expected_feed_symbol = "$it.feed_symbol"
            provider_symbol      = "$A.cand_symbol"
            quote_currency       = "$A.cand_currency"
        })
    $ifApplied = Build-If 'Applied?' @(2220, -260) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $callPrices = Build-CallWorkflow 'Refresh market prices' @(2420, -380) $MarketPricesCronId 'agent.finance.cron_refresh_market_prices' `
        ([ordered]@{ chat_id = "={{ '' }}" })
    $callPrices['alwaysOutputData'] = $true
    $ifFx = Build-If 'Foreign quote?' @(2620, -380) "={{ $A.cand_currency !== 'EUR' }}" 'true' 'equals' 'boolean'
    $callFx = Build-CallWorkflow 'Refresh FX rates' @(2820, -460) $FxCronId 'agent.finance.cron_refresh_fx_rates' `
        ([ordered]@{ chat_id = "={{ '' }}" })
    $callFx['alwaysOutputData'] = $true
    $readNew = Build-Pg 'Read new price' @(3020, -380) `
        "=SELECT (SELECT to_jsonb(s) FROM finance.fn_holding_price_status(ARRAY[((`$1::jsonb)->>'holding_id')::int]) s) AS st;" `
        ([ordered]@{ holding_id = "$it.holding_id" })

    # Ergebnis-Zeilen (je Ausgang ein eigener Compose-Knoten: in der Schleife darf kein Knoten einen evtl. nicht
    # gelaufenen Vorgaenger lesen). Den Fehlgrund liefert die fn als code (der englische reason geht nie in die Nachricht).
    $composeApplied = [ordered]@{ parameters = [ordered]@{ jsCode = ($lib + @'
const m = $('Find gaps').first().json;
const U = uiRender(m.ui || {});
const g = $('Loop Over Items').first().json;
const a = $('Accept?').first().json;
const st = ($input.first().json || {}).st || {};
const text = (st.price !== null && st.price !== undefined && st.status === 'ok')
  ? U.fill(U.t('finance.dialog.price_gap_applied'), { name: g.name, symbol: a.cand_symbol,
      price: { kind: 'money', value: st.price, currency: st.price_currency }, date: { kind: 'date', value: st.price_as_of } })
  : U.fill(U.t('finance.dialog.price_gap_applied_noprice'), { name: g.name, symbol: a.cand_symbol });
return [{ json: { text: text } }];
'@) }; type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(3220, -380); id = (New-Id); name = 'Compose applied' }
    $composeRejected = [ordered]@{ parameters = [ordered]@{ jsCode = ($lib + @'
const m = $('Find gaps').first().json;
const U = uiRender(m.ui || {});
const g = $('Loop Over Items').first().json;
const r = $input.first().json || {};
const key = (r.code === 'already_resolved' || r.code === 'not_found') ? 'finance.dialog.price_gap_already' : 'finance.dialog.price_gap_failed';
return [{ json: { text: U.fill(U.t(key), { name: g.name }) } }];
'@) }; type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(2420, -160); id = (New-Id); name = 'Compose not applied' }
    $composeLater = [ordered]@{ parameters = [ordered]@{ jsCode = ($lib + @'
const m = $('Find gaps').first().json;
const U = uiRender(m.ui || {});
const g = $('Loop Over Items').first().json;
return [{ json: { text: U.fill(U.t('finance.dialog.price_gap_later'), { name: g.name }) } }];
'@) }; type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(2020, -40); id = (New-Id); name = 'Compose later' }
    $nResult = New-TelegramSendNode 'Notify result' @(3420, -160) "={{ `$json.text }}" -OnError 'continueRegularOutput'

    $stickyOverview = Build-Sticky 'Überblick' @(-920, -460) `
        'Kurs-Lücken-Erinnerung (Owner 2026-10-27: nie unentdeckt)' `
        'Schedule (core.config schedule.remind_missing_prices, Standard 25 10 * * * = im Erinnerungsfenster). Find gaps = finance.fn_price_gaps(): gehaltene Positionen ohne gültigen Kurs (missing = nie einer, stale = älter als advisor.price_stale_days; EINE Regel fn_price_status wie Depot-Übersicht und Berater), Referenzkurs für die Plausi-Prüfung, FX-Sätze; Seiteneffekt: behobene Lücken re-armen (core.fn_notify_resolve, source finance_prices). Plan items: Feed-Ausfall (keine Position ok, >= 2 stale) -> EINE Meldung (Latch feed_down, 7 Tage), sonst ein Item je Lücke. Ohne Lücke: Ende. Meldet unabhängig vom Finanzplan (der Berater-Drift-Check ist opt-in und war der Grund, dass eine Lücke unbemerkt blieb).' 340 620
    $stickyLatch = Build-Sticky 'Latch je Karte' @(260, 340) `
        'fn_price_gap_claim direkt vor dem Versand' `
        'Claim gap = core.fn_should_notify(finance_prices, holding_id, 7 Tage): erste Meldung sofort, dann höchstens alle 7 Tage, solange die Lücke besteht. Gesetzt wird er je Position erst in ihrer Schleifen-Runde: eine nicht angetippte Karte verschluckt so keine spätere (die Karte wartet höchstens 8 h, dann weiter wie "Nicht jetzt"). Bewusst kein fn_notify_reconcile (advisor-only, kein Paket-Grant).' 300 400
    $stickySearch = Build-Sticky 'Symbol-Suche mit Plausi-Pflicht' @(660, -320) `
        'Yahoo-ISIN-Suche, dann Websuche, beides geprüft' `
        'Resolve Yahoo symbol = derselbe Sub wie Kauf/Korrektur/Import (provider_symbol leer -> immer ISIN-Suche; Plausi gegen letzten Kurs, Band 0,8-1,25, ODER Einstand, Band 0,2-5, je in ihrer Währung, sonst in EUR verglichen). Pick candidate: übernehmbar nur mit ISIN, anderem Symbol als dem heutigen Feed-Symbol und adoptable (Sub). Sonst (nur mit ISIN) Websuche über core:web_search (bezahlte Anthropic-API, Anfrage = ISIN + Name, keine Bestände) -> Parse tickers (bis 3 Ticker mit Börsen-Suffix, nur aus dem Antwort-Teil, URLs/Domains entfernt; Websuche-Ticker nur in Positions-Währung) -> dieselbe Sub mit try_symbols prüft sie per Chart-Abruf + Plausi -> Pick web candidate. Ein erfundener Ticker scheitert dort; den Rest prüft der Owner auf der Karte (Name, Börse, Kurs). Krypto (ohne ISIN) -> nur Text-Hinweis.' 340 620
    $stickyApply = Build-Sticky 'Übernehmen' @(2020, -660) `
        'fn_apply_price_symbol + Sofort-Kurs' `
        'Der Tipp ist das HITL. Apply symbol = finance.fn_apply_price_symbol: Guard zuerst (Lücke noch offen, Feed-Symbol noch das der Karte, sonst code already_resolved -> "nichts überschrieben"), dann fn_set_holding mit provider_symbol + quote_currency (immer, auch EUR). Danach Refresh market prices (+ Refresh FX rates bei Fremdwährung, beide alwaysOutputData) -> Read new price (fn_holding_price_status, aggregiert -> immer ein Item) -> Ergebnis-Zeile mit Kurs und Datum. Nicht jetzt / kein Tipp in 8 h -> nur Hinweis "in 7 Tagen wieder".' 340 440
    $stickyStale = Build-Sticky 'Doppel-Tipp-Schutz' @(1460, -480) `
        'Mehrere Karten in einer Execution' `
        'n8n bindet einen Tipp an die Execution, nicht an die Nachricht. Hinter der Karte merkt sich "(tap check)" die beantworteten Nachrichten; ein Tipp auf eine schon beantwortete Karte stellt die aktuelle neu (New-StaleTapGuard, Muster cron_remind_interest).' 300 260
    $stickyGate = Build-Sticky 'F9 Cron-Gate' @(-1100, -260) `
        'Paket aktiv UND cron_enable.remind_missing_prices' `
        'core.fn_package_active(''finance'') AND core.fn_config_get(''finance'',''cron_enable'',''remind_missing_prices'')=''true'' (DB entscheidet, fail-closed). Läuft unter finance_rw (Latch + fn_apply_price_symbol). Toggle: /reminders oder lifeagents config set cron_enable remind_missing_prices false.' 300 300

    $nodes = @($trig, $gate, $gateIf, $gateOff, $find, $plan, $ifFeed, $claimFeed, $ifFeedDue, $nFeed,
               $loop, $done, $claim, $ifDue, $resolve, $pick, $ifAccept, $ifTryWeb, $web, $parse, $ifTickers,
               $resolveWeb, $pickWeb, $nNone, $ask, $ifApply, $apply, $ifApplied, $callPrices, $ifFx, $callFx, $readNew,
               $composeApplied, $composeRejected, $composeLater, $nResult,
               $stickyOverview, $stickyLatch, $stickySearch, $stickyApply, $stickyStale, $stickyGate) + $gAsk.Nodes

    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Find gaps' ),
            @( E 'Disabled' )
        ) }
        'Find gaps'                   = @{ main = @( ,@( E 'Plan items' ) ) }
        'Plan items'                  = @{ main = @( ,@( E 'Feed down?' ) ) }
        'Feed down?'                  = @{ main = @(
            @( E 'Claim feed down' ),    # true: Feed-Ausfall -> EINE Meldung
            @( E 'Loop Over Items' )     # false: je Luecke
        ) }
        'Claim feed down'             = @{ main = @( ,@( E 'Feed due?' ) ) }
        'Feed due?'                   = @{ main = @(
            @( E 'Notify feed down' ),
            @()
        ) }
        'Loop Over Items'             = @{ main = @(
            @( E 'Done' ),
            @( E 'Claim gap' )
        ) }
        'Claim gap'                   = @{ main = @( ,@( E 'Gap due?' ) ) }
        'Gap due?'                    = @{ main = @(
            @( E 'Resolve Yahoo symbol' ),   # true: jetzt melden
            @( E 'Loop Over Items' )         # false: im Latch-Fenster still
        ) }
        'Resolve Yahoo symbol'        = @{ main = @( ,@( E 'Pick candidate' ) ) }
        'Pick candidate'              = @{ main = @( ,@( E 'Accept?' ) ) }
        'Accept?'                     = @{ main = @(
            @( E 'Ask price symbol' ),       # true: Karte mit [Uebernehmen]
            @( E 'Try web?' )                # false: Websuche oder Text-Hinweis
        ) }
        'Try web?'                    = @{ main = @(
            @( E 'Web search' ),
            @( E 'Notify no source' )
        ) }
        'Web search'                  = @{ main = @( ,@( E 'Parse tickers' ) ) }
        'Parse tickers'               = @{ main = @( ,@( E 'Any ticker?' ) ) }
        'Any ticker?'                 = @{ main = @(
            @( E 'Resolve web tickers' ),
            @( E 'Notify no source' )
        ) }
        'Resolve web tickers'         = @{ main = @( ,@( E 'Pick web candidate' ) ) }
        'Pick web candidate'          = @{ main = @( ,@( E 'Accept?' ) ) }
        'Notify no source'            = @{ main = @( ,@( E 'Loop Over Items' ) ) }
        'Apply?'                      = @{ main = @(
            @( E 'Apply symbol' ),
            @( E 'Compose later' )
        ) }
        'Apply symbol'                = @{ main = @( ,@( E 'Applied?' ) ) }
        'Applied?'                    = @{ main = @(
            @( E 'Refresh market prices' ),
            @( E 'Compose not applied' )
        ) }
        'Refresh market prices'       = @{ main = @( ,@( E 'Foreign quote?' ) ) }
        'Foreign quote?'              = @{ main = @(
            @( E 'Refresh FX rates' ),
            @( E 'Read new price' )
        ) }
        'Refresh FX rates'            = @{ main = @( ,@( E 'Read new price' ) ) }
        'Read new price'              = @{ main = @( ,@( E 'Compose applied' ) ) }
        'Compose applied'             = @{ main = @( ,@( E 'Notify result' ) ) }
        'Compose not applied'         = @{ main = @( ,@( E 'Notify result' ) ) }
        'Compose later'               = @{ main = @( ,@( E 'Notify result' ) ) }
        'Notify result'               = @{ main = @( ,@( E 'Loop Over Items' ) ) }
    }
    foreach ($k in $gAsk.Connections.Keys) { $conns[$k] = $gAsk.Connections[$k] }
    return (Build-Workflow 'agent.finance.cron_remind_missing_prices' $nodes $conns)
}
