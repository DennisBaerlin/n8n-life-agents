#Requires -Version 5.1
# Definition agent.finance.cron_refresh_market_prices -> Build-CronRefreshMarketPrices. Dot-gesourct von build.ps1.
# Deterministisch, KEIN LLM. VIER EINGAENGE (Muster cron_refresh_fx_rates): (a) Schedule (taeglich, Cron
# aus core.config schedule.refresh_market_prices, beim Einspielen eingesetzt),
# (b) executeWorkflowTrigger 'Start' fuer den Sofort-Fetch aus tool_book_stock_buy/tool_set_holding nach
# einem Depot-Write (kein NULL-Preis-Fenster bis zum naechsten Schedule), (c) n8n-Start und (d) stuendlicher
# Schedule als Nachholen (fn_feed_refresh_due). Alle muenden in denselben Pfad:
# gehaltene Symbole holen -> EIN Code-Node fetcht ALLE Kurse via Yahoo Finance v8/chart PER Symbol (WP-4:
# Aktien/ETF UND Krypto als TICKER-FIAT; kollisionsfrei, CoinGecko retired) -> finance.fn_upsert_market_prices. Laeuft unter finance_rw (schreibt
# finance.market_prices). Nutzt aus dem Orchestrator-Scope: $RepoRoot, $CRED_FINANCE_RW + build_helpers.
function Build-CronRefreshMarketPrices {
    # Schreibt finance.market_prices -> enge Paket-Schreibrolle finance_rw (Least-Privilege, D10);
    # funktions-lokaler Override (Dynamic-Scope -> Build-Pg sieht es), inkl. der Gate-Reads.
    $CRED_POSTGRES = $CRED_FINANCE_RW

    $trig    = Build-ScheduleTrigger @(-900, 0) -ScheduleKey 'refresh_market_prices'
    # Zweiter Eingang: executeWorkflowTrigger ('Start') — tool_book_stock_buy/tool_set_holding rufen den
    # Workflow nach einem Depot-Write als Sub auf (Sofort-Fetch). Keine Inputs deklariert (chat_id wird
    # vom Aufrufer mitgegeben, hier ignoriert — der Cron beschafft nur Kurse).
    $subTrig = Build-Trigger @() @(-900, 200)

    # F9 Cron-Gating: Tagesplan, n8n-Start und stuendlicher Check laufen durch EIN Gate (New-CatchUpEntry: Paket aktiv AND
    # cron_enable AND fn_feed_refresh_due('prices'); die DB entscheidet, ein Abruf je Kalendertag, wer zuerst kommt). Der Start-
    # Sofort-Fetch ist Folge eines bereits erlaubten/HITL-approvten Depot-Writes und prueft NUR Paket aktiv.
    $gateStart = Build-Pg 'Package active?' @(-680, 200) `
        "SELECT core.fn_package_active('finance') AS active"
    $ifStart = Build-If 'Package on?' @(-460, 240) "={{ `$json.active }}" 'true' 'equals' 'boolean'

    $disabled = Build-NoOp 'Disabled' @(-460, 440)

    # Nachholen: n8n-Start (nach 30 s fuer Netz/DNS) und stuendlicher Check (Ruhezustand startet n8n nicht neu); der Tagesplan
    # haengt unten am selben Gate 'Catch-up needed?'.
    $catchUp = New-CatchUpEntry -Package 'finance' -Feed 'prices' -CronKey 'refresh_market_prices' `
        -OnDue @('Get held symbols') -Origin @(-1120, -240)

    # Gehaltene Symbole (WP-4: EIN Feed = Yahoo Finance fuer ALLES). cnt > 0 = Early-Exit-Gate (kein Fetch ohne
    # Holdings). Je Holding ein PAAR { q, s }: s = symbol = der fn_upsert-Join-Key; q = das anzufragende Yahoo-
    # Feed-Symbol. Aktie/ETF (ISIN vorhanden): q = COALESCE(provider_symbol, symbol) = Yahoo-Ticker mit Boersen-
    # Suffix (VWCE.DE). Krypto (ISIN NULL): q = COALESCE(provider_symbol, symbol || '-EUR') = Yahoos Krypto-
    # Konvention TICKER-FIAT (BTC-EUR liefert direkt EUR; ein mehrdeutiges Ticker wie UNI setzt der Owner explizit
    # via provider_symbol = UNI7083-USD). CoinGecko entfaellt (Symbol-Batch war kollisionsanfaellig -> Rate-
    # Roulette); Yahoo-Per-Symbol ist kollisionsfrei wie der Aktien-Zweig. Yahoo fehlt ein Coin -> null_price.
    # Die q-Regel lebt in finance.fn_feed_symbol (Init-Helfer, EINE Adresse mit der Kurs-Status-Anzeige 2026-10-27).
    $getSyms = Build-Pg 'Get held symbols' @(-240, 0) @'
WITH held AS (
  SELECT DISTINCT symbol AS s, finance.fn_feed_symbol(isin, symbol, provider_symbol) AS q
  FROM finance.depot_holdings WHERE shares > 0
)
SELECT count(*)::int AS cnt,
       COALESCE(json_agg(json_build_object('q', q, 's', s)), '[]') AS symbols
FROM held
'@

    $ifHold = Build-If 'Any holdings?' @(-20, 0) "={{ `$json.cnt }}" '0' 'larger' 'number'

    # EIN Code-Node (kein LLM, deterministisch): Yahoo-Finance v8/finance/chart PER Symbol fuer ALLES — Aktien/
    # ETF UND Krypto (WP-4: CoinGecko entfaellt, sein Symbol-Batch war kollisionsanfaellig). key-/auth-frei.
    # try/catch je Symbol -> ein Ausfall killt die anderen nicht; fehlt ein Kurs, faellt das Symbol hier raus und
    # agent.finance.cron_remind_missing_prices meldet die Luecke (Owner 2026-10-27: nie unentdeckt). Rueckgabe { prices: { SYM: kurs } }, GESCHLUESSELT auf das
    # Holding-symbol (s). q->s ist direkt bekannt (Per-Symbol-Call, kollisionsfrei -> KEIN Rate-Roulette wie beim
    # frueheren CoinGecko-Symbol-Batch). Yahoo liefert in meta.currency die echte Quote-Waehrung (EUR bei
    # BTC-EUR, USD bei UNI7083-USD) -> je Symbol durchgereicht (currencies{}), fn_upsert setzt sie autoritativ
    # (GBp/Pence HIER normalisiert: GBp = GBP/100). (Stooq + CoinGecko retired — nicht erneut einbauen.)
    $fetchJs = @'
const symbols = ($('Get held symbols').first().json.symbols || []);
const prices = {};
const currencies = {};   // symbol -> Yahoo-meta.currency (autoritativ; fn_upsert nimmt sie, ^[A-Z]{3}$-Backstop)

// Yahoo Finance v8/finance/chart je Symbol (Aktien/ETF wie Portfolio Performance UND Krypto als TICKER-FIAT).
// q = Yahoo-Feed-Symbol: Aktie/ETF mit Boersen-Suffix (VWCE.DE Xetra, VWRL.L London); Krypto als BTC-EUR /
// UNI7083-USD. PER-Symbol-Call -> q->s direkt bekannt, keine Rueckwaerts-Map, keine Symbol-Kollision. Kurs =
// chart.result[0].meta.regularMarketPrice (in meta.currency). PENCE: Londoner Pence currency='GBp' (= GBP/100).
for (const h of symbols) {
  try {
    const url = 'https://query1.finance.yahoo.com/v8/finance/chart/' + encodeURIComponent(h.q)
              + '?range=1d&interval=1d&lang=en-US&region=US&corsDomain=finance.yahoo.com';
    const res = await this.helpers.httpRequest({ url, json: true, timeout: 15000 });
    const r = res && res.chart && res.chart.result && res.chart.result[0];
    const m = r && r.meta ? r.meta : null;
    let px = m ? Number(m.regularMarketPrice) : NaN;
    let ccy = m && m.currency ? String(m.currency) : '';
    if (ccy === 'GBp') { px = px / 100; ccy = 'GBP'; }   // Pence -> GBP
    if (px > 0 && !Number.isNaN(px)) {
      prices[h.s] = px;
      if (/^[A-Z]{3}$/.test(ccy)) currencies[h.s] = ccy;
    }
  } catch (e) { /* Symbol-Ausfall -> ohne Kurs; cron_remind_missing_prices meldet die Luecke */ }
}

return [{ json: { prices, currencies, source: 'yahoo' } }];
'@
    $fetch = [ordered]@{
        parameters = [ordered]@{ jsCode = $fetchJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(200, 0)
        id = (New-Id); name = 'Fetch prices'
        onError = 'continueRegularOutput'
        retryOnFail = $true; maxTries = 2; waitBetweenTries = 2000
    }

    # Upsert via finance.fn_upsert_market_prices (Invarianten deterministisch getestet). Nur gehaltene
    # Symbole + numerisch>0 werden geschrieben; ON CONFLICT (symbol,as_of) idempotenter Tages-Upsert.
    $upsert = Build-Pg 'Upsert market_prices' @(420, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'upserted')::int AS upserted FROM finance.fn_upsert_market_prices(`$1::jsonb) AS r;" `
        ([ordered]@{ prices = '$json.prices'; currencies = '$json.currencies'; source = '$json.source' })

    $stickyOverview = Build-Sticky 'Überblick' @(-540, -300) `
        'Markt-Preis-Refresh (Dual-Trigger, kein LLM)' `
        'VIER Eingänge, EIN Pfad: (a) Schedule täglich (Cron aus core.config schedule.refresh_market_prices, beim Einspielen eingesetzt; läuft durch dieselbe Fälligkeits-Prüfung wie das Nachholen); (b) executeWorkflowTrigger Start — tool_book_stock_buy/tool_set_holding rufen den Workflow nach einem Depot-Write sofort auf (eliminiert das NULL-Preis-Fenster bis zum nächsten Schedule); (c) n8n-Start und (d) stündlicher Check holen einen verpassten Lauf nach (Sticky Nachholen). Pfad: gehaltene Symbole holen (depot_holdings shares>0) -> IF cnt=0: Abbruch ohne Fetch. Sonst: EIN Code-Node holt ALLE Kurse über Yahoo Finance v8/chart PER Symbol (WP-4: Aktien/ETF UND Krypto als TICKER-FIAT wie BTC-EUR; key-frei, kollisionsfrei; CoinGecko retired) -> finance.fn_upsert_market_prices. Die Allokations-Drift (fn_advisor_review) liest den jüngsten Kurs via finance.networth_by_asset_class.' 300 700

    $stickyEarlyExit = Build-Sticky 'Early-Exit' @(-20, 200) `
        'cnt=0 -> kein Fetch' `
        'Hält keine Depot-Position eine shares>0-Zeile, liefert Get held symbols cnt=0. Der IF-Zweig false beendet den Workflow hier — kein sinnloser Quote-Fetch.' 220 220

    $stickyFetch = Build-Sticky 'Kurs-Fetch (kein LLM)' @(200, 200) `
        'Yahoo Finance PER Symbol — Aktien/ETF UND Krypto (WP-4)' `
        'EIN Code-Node, deterministisch: ALLE Symbole -> Yahoo Finance v8/finance/chart PER Symbol (key-/auth-frei; meta.regularMarketPrice). try/catch je Symbol (ein Ausfall killt die anderen nicht). Fehlt ein Kurs -> Symbol fällt hier raus, agent.finance.cron_remind_missing_prices meldet die Lücke (Karte mit geprüftem Vorschlag, auch ohne Finanzplan). Angefragt wird q = finance.fn_feed_symbol: Aktie/ETF (ISIN vorhanden) = COALESCE(provider_symbol, symbol) = Yahoo-Ticker mit Börsen-Suffix (VWCE.DE Xetra, VWRL.L London); Krypto (ISIN NULL) = COALESCE(provider_symbol, symbol||''-EUR'') = Yahoos Krypto-Konvention TICKER-FIAT (BTC-EUR liefert direkt EUR; mehrdeutiges Ticker wie UNI -> Owner setzt provider_symbol=UNI7083-USD). PER-Symbol = kollisionsfrei (KEIN Rate-Roulette wie beim früheren CoinGecko-Symbol-Batch). q->s direkt bekannt, keine Rückwärts-Map. Die Kurs-WÄHRUNG kommt je Symbol aus Yahoos meta.currency (currencies{} im Payload; GBp/Pence -> GBP/100 HIER normalisiert), fn_upsert setzt sie autoritativ (Backstop ^[A-Z]{3}$ -> sonst Fallback COALESCE(quote_currency,currency)) -> EUR-Roll-up via fn_to_eur. (Stooq + CoinGecko retired — nicht erneut einbauen.)' 340 640

    $stickyGate = Build-Sticky 'F9 Cron-Gate' @(-680, -280) `
        'Paket-aktiv (beide) + cron_enable und fällig (Tagesplan/Nachholen)' `
        'WRITE-Cron -> finance_rw. Das Gate Catch-up needed? liest core.fn_package_active(''finance'') AND core.fn_config_get(''finance'',''cron_enable'',''refresh_market_prices'')=''true'' AND finance.fn_feed_refresh_due(''prices'') (DB entscheidet, fail-closed). Toggle: lifeagents config set cron_enable refresh_market_prices false. DUAL-TRIGGER: der Start-Pfad (Sofort-Fetch nach erlaubtem Depot-Write) prüft NUR Paket-aktiv (kein cron_enable, keine Fälligkeit).' 300 440

    $stickyInit = Build-Sticky 'Nachholen (Start + stündlich)' @(-1120, -540) `
        'Verpassten Tageslauf nachholen (n8n-Start und jede Stunde)' `
        'Die Planzeit verfällt, wenn das Gerät aus ist oder schläft; der scheduleTrigger holt nicht nach. Drei Eingänge fragen deshalb dieselbe Prüfung: der Tagesplan, der n8n Trigger (Instance started, nach 30 s für Netz und DNS) und ein stündlicher Check (schedule.refresh_catchup, deckt auch das Aufwachen aus dem Ruhezustand, bei dem n8n nicht neu startet). Catch-up needed?: Paket aktiv, cron_enable an, und finance.fn_feed_refresh_due(''prices'') meldet, dass heute noch kein Kurs einer gehaltenen Position geholt wurde (jüngster Stand vor Beginn des heutigen Kalendertags der Haushalts-Zeitzone). Sonst Ende ohne Abruf: ein Abruf je Kalendertag, Wochenende und Feiertag kosten nichts extra, die Yahoo-Last bleibt klein. Der Stunden-Check startet erst ab 03:15 (Manifest-Default). Ist keine gehaltene Position je bepreist worden, gilt der Lauf als fällig und wiederholt stündlich (wenige Symbole, Yahoo-Last klein); fehlen nur einzelne Symbole, löst das keinen Abruf aus, die Lücke meldet cron_remind_missing_prices. Fällt der Feed ganz aus, bleibt der Lauf stumm (Fetch prices: onError weiter).' 340 320

    $nodes = @($trig, $subTrig, $gateStart, $ifStart, $disabled) + @($catchUp.Nodes) +
             @($getSyms, $ifHold, $fetch, $upsert,
               $stickyOverview, $stickyEarlyExit, $stickyFetch, $stickyGate, $stickyInit)
    $conns = [ordered]@{}
    foreach ($k in $catchUp.Connections.Keys) { $conns[$k] = $catchUp.Connections[$k] }
    $conns['Schedule (cron from config)'] = @{ main = @( ,@( E 'Catch-up needed?' ) ) }   # Tagesplan: dasselbe Gate
    $conns2 = [ordered]@{
        'Start'                       = @{ main = @( ,@( E 'Package active?' ) ) }
        'Package active?'             = @{ main = @( ,@( E 'Package on?' ) ) }
        'Package on?'                 = @{ main = @(
            @( E 'Get held symbols' ),
            @( E 'Disabled' )
        ) }
        'Get held symbols'            = @{ main = @( ,@( E 'Any holdings?' ) ) }
        'Any holdings?'               = @{ main = @(
            @( E 'Fetch prices' ),   # true: Holdings vorhanden -> fetch
            @()                       # false: keine -> terminate
        ) }
        'Fetch prices'                = @{ main = @( ,@( E 'Upsert market_prices' ) ) }
    }
    foreach ($k in $conns2.Keys) { $conns[$k] = $conns2[$k] }
    return (Build-Workflow 'agent.finance.cron_refresh_market_prices' $nodes $conns)
}
