-- ============================================================
-- fn_book_stock_buy (ATOMIC WRITE)
--   Holding suchen ODER anlegen + EINE Kauf-Transaktion, in EINER Transaktion. Order-Gebuehr
--   wird in amount gefaltet (Anschaffungskosten) UND separat in order_fee gespeichert; shares
--   und average_purchase_price pflegt die DB per Trigger (avg nur aus buy-Zeilen). Eingabe jsonb:
--   depot_id, settlement_id (im n8n aufgeloest), isin, symbol (opt bei ISIN -- fn_holding_symbol: ohne Ticker ist die
--   ISIN die Kennung), name (opt, Default = Kennung), shares, price_per_share,
--   order_fee, transaction_date (ISO oder relativ, leer = heute), asset_class (opt -- Allokations-Block-key, lowercase snake; Auto-Tag,
--   nur beim ANLEGEN der Holding gesetzt, Format-Verstoss -> {ok:false}),
--   provider_symbol (opt -- Phase M: Markt-Daten-Feed-Symbol-Override, z. B. VWCE.DE; nur beim ANLEGEN),
--   quote_currency (opt -- Phase M: native Quote-Waehrung; via fn_ensure_currency validiert -> {ok:false}; nur beim ANLEGEN),
--   recurring_payment_id (opt -- verknuepft den Kauf mit einem Sparplan), due_date (opt, nur mit
--   recurring_payment_id -- Monats-Check WP-A: die Faelligkeit, die der Kauf erledigt = recurring_due_date;
--   Default transaction_date; Abgleich-Sperre auf dem Verrechnungskonto -> {ok:false, code:'reconciled'}),
--   existing_position (opt bool, Default false -- BESTANDSUEBERNAHME einer bereits gehaltenen Position,
--   z. B. beim Onboarding/Depotauszug-Import): der Kauf wird wie gewohnt gebucht (shares/avg korrekt aus
--   der 'buy'-Zeile), dazu EINE Gegenbuchung category='position_takeover' (+Betrag, gleiches Datum, gleiche
--   group_id) auf dem Verrechnungskonto -> dessen Saldo bleibt unveraendert (der genannte Kontostand ist
--   schon der heutige). Ein Void entfernt beide Zeilen. Korrigierbar {ok:false}: zusammen mit
--   recurring_payment_id (Sparplan-Ausfuehrung ist echter Geldfluss); Holding hat bereits Stueck > 0 (ein
--   erneuter Depotauszug wuerde die Position verdoppeln -> Korrektur ueber set_holding).
--   CHECK finance_transactions_position_takeover_shape ist der Backstop der Gegenbuchungs-Form. Das Paar schreibt allein
--   fn_book_takeover_pair (eine Adresse mit den Import-Tranchen). cost_basis_total (opt, NUR mit existing_position und ohne
--   price_per_share): Gesamt-Einstand -> Stueckpreis rechnet fn_unit_price_from_total (das LLM teilt nie selbst).
--   WS-B Stufe 2 (Phase S) — AUTO-JOURNAL: ist dieser Kauf die Ausfuehrung eines GOAL-VERKNUEPFTEN Sparplans
--   (recurring_payment_id -> savings_plans.savings_goal_id IS NOT NULL), dann ATOMAR in derselben Tx append-only
--   savings_goal_reserve_entries-Zeilen kind='sparplan_buy', value_date = transaction_date, source_tx_id = Kauf-Tx:
--     * Depot +X (X = shares*price + fee, volle Cash-Abfluss-Magnitude inkl. Gebuehr, Depot-Waehrung),
--     * Verrechnungskonto -c, c = min(Ziel-Anteil auf dem Verrechnungskonto, X), nur wenn c > 0.
--   KONSERVIERUNG NUR FUER ZIEL-GELD (Sparziel-Zweckbindung 2026-10-27): Geld, das dem Ziel schon gehoerte, wird nur
--   umgeschichtet (Fortschritt unveraendert); der Rest (X - c) ist frisches Geld und zaehlt als neu gespart. Vorher
--   wurde das Cash-Bein selbst mit -X getaggt -> ein Sparplan, der nicht aus Ziel-Geld bezahlt wurde, brachte NIE
--   Fortschritt. Der Kauf traegt kein Ziel-Tag mehr. WP-3b Guard: Settlement-Waehrung != Depot-Waehrung bei goal-Kauf
--   -> {ok:false} (Cross-Currency-Settlement out-of-scope; beide Zeilen tragen dieselbe Waehrung).
--   Manueller Kauf (recurring_payment_id NULL) ODER nicht-goal-Sparplan -> KEINE Wirkung (kein Journal).
--   Idempotenz erbt vom Buy (die Journal-Zeilen teilen die Buy-Tx -> re-run kein Doppel-Insert).
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, holding_id, buy_tx_id, settlement_balance, settlement_change,
--   total_shares, avg_purchase_price} (Post-State aus der fn: Trigger-gepflegte shares/avg +
--   neuer Verrechnungskonto-Saldo, in derselben Transaktion gelesen; group_id = Handle der Uebernahme-Gruppe (sonst NULL); settlement_change = Saldo nachher - vorher, DB-Delta:
--   Bestandsuebernahme 0, normaler Kauf -Kaufbetrag -- Live-Befund 2026-10-28: ohne die Zahl erfand das Modell
--   eine Kontobewegung). Korrigierbar
--   (Depot-Typ-Mismatch, negative order_fee, > 8 Stueck-Nachkommastellen oder Betrag < 1 Cent via
--   fn_trade_amount_reason) -> {ok:false, reason, depot_type} OHNE Write (kein RAISE -> kein
--   Owner-Alert; das Tool reicht reason an den Agenten).
--   Phase L WS-6: ist die RESULTIERENDE Holding ungetaggt (asset_class IS NULL — neu ohne Tag ODER bestehend
--   untagged), faltet die fn eine null_tag-Fallback-Note in den {ok:true}-Envelope (0 Extra-SQL, der Post-State-
--   SELECT liest asset_class mit). Nur der interaktive Agent surfaced sie (Sparplan-Ausfuehrung/Import bauen
--   ihren eigenen Return, reichen die Note NICHT durch); ein getaggter (manuell ODER per Sparplan vererbter)
--   Kauf -> keine Note.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_book_stock_buy(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_depot      INT               := (p->>'depot_id')::int;
    v_settle     INT               := (p->>'settlement_id')::int;
    v_isin       TEXT              := NULLIF(p->>'isin', '');  -- NULL for crypto (no ISIN)
    v_symbol     TEXT              := finance.fn_holding_symbol(p->>'symbol', p->>'isin');  -- ohne Ticker = ISIN (Depotauszug druckt oft nur die ISIN)
    v_name       TEXT              := COALESCE(NULLIF(btrim(p->>'name'), ''), v_symbol);  -- ohne Bezeichnung (Krypto-Import) = Kennung; name ist NOT NULL
    v_shares     NUMERIC           := (p->>'shares')::numeric;
    -- freie Tool-Eingabe ("540,20"); unlesbar -> NULL -> {ok:false}. 0 = nicht genannt (Tool-Default bei cost_basis_total;
    -- ein Kurs 0 ist ohnehin ungueltig und wird unten als "nicht positiv" abgelehnt).
    v_price      NUMERIC           := NULLIF(finance.fn_parse_numeric_or_null(p->>'price_per_share', false), 0);
    v_fee        NUMERIC           := COALESCE(NULLIF(p->>'order_fee', '')::numeric, 0);
    v_date       DATE;
    v_due        DATE;
    v_reason     TEXT;
    v_asset_cls  TEXT              := NULLIF(p->>'asset_class', '');  -- WS2b: Allokations-Block-key (Auto-Tag, optional)
    v_provider_sym TEXT            := NULLIF(p->>'provider_symbol', '');  -- Phase M: optionaler Feed-Symbol-Override (nur beim Anlegen)
    v_quote_ccy  TEXT              := finance.fn_normalize_currency(NULLIF(p->>'quote_currency', ''));   -- Phase M: optionale native Quote-Waehrung (roh normalisiert 'usd'->'USD'; nur beim Anlegen)
    v_ccy_result JSONB;
    v_depot_type finance.account_type;
    v_depot_ccy  CHAR(3);
    v_settle_ccy CHAR(3);          -- WP-3b: Settlement-Konto-Waehrung (Konservierungs-Guard bei goal-Kauf)
    v_rp_id      INT               := NULLIF(p->>'recurring_payment_id', '')::int;
    v_goal       INT;              -- WS-B Stufe 2: Ziel des goal-verknuepften Sparplans (NULL = manueller/freier Kauf)
    v_goal_cash  NUMERIC;          -- 2026-10-27: Ziel-Geld auf dem Verrechnungskonto, das der Kauf umschichtet (c)
    v_holding    INT;
    v_buy        INT;
    v_bal        NUMERIC;
    v_shares_tot NUMERIC;
    v_avg        NUMERIC;
    v_holding_cls TEXT;            -- Phase L WS-6: asset_class der resultierenden Holding (NULL = ungetaggt -> Fallback-Note)
    v_existing   BOOLEAN           := COALESCE(NULLIF(p->>'existing_position', '')::boolean, false);
    v_held       NUMERIC;
    v_dates      JSONB;
    v_bal_before NUMERIC;
    v_pair       JSONB;
    v_total      NUMERIC;          -- cost_basis_total (Gesamt-Einstand einer Uebernahme), geparst
    v_group      UUID;             -- Handle der Uebernahme-Gruppe (Import haengt weitere Tranchen an)
BEGIN
    -- relative Datumsangaben ("yesterday", "-3 days") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['transaction_date', 'due_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    v_date := COALESCE(NULLIF(p->>'transaction_date', '')::date, core.fn_today());   -- leer = heute (DB-Default)
    v_due  := COALESCE(NULLIF(p->>'due_date', '')::date, v_date);
    -- Korrigierbare Input-Pruefungen -> {ok:false} (analog fn_book_stock_sell).
    -- Kennung: Ticker ODER ISIN (fn_holding_symbol); ohne beides -> {ok:false} statt NOT-NULL-RAISE (Backstop bleibt).
    IF v_symbol IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'A position needs a ticker symbol or an ISIN (crypto: the coin symbol, e.g. BTC).');
    END IF;
    IF v_shares IS NULL OR v_shares <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Share count must be a positive number, got ' || COALESCE(v_shares::text, 'null') || '.');
    END IF;
    -- Uebernahme mit Gesamtbetrag ("10 Stueck fuer insgesamt 1.000 EUR"): Stueckpreis rechnet die DB.
    -- Der Probelauf gibt den Stueckpreis als effective.price_per_share an Karte UND echten Write weiter; der Write
    -- traegt dann beide Felder -> gleich = ok (Karte = Buchung), abweichend = {ok:false}.
    IF NULLIF(p->>'cost_basis_total', '') IS NOT NULL THEN
        -- freie Tool-Eingabe: "1.000,50" / "1000 EUR" -> fn_parse_de_numeric; nicht lesbar = korrigierbar, kein Cast-RAISE
        v_total := finance.fn_parse_numeric_or_null(p->>'cost_basis_total', true);
        IF v_total IS NULL OR v_total <= 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'cost_basis_total (total amount paid) must be a positive number, got ' || (p->>'cost_basis_total') || '.');
        END IF;
        IF NOT v_existing
           OR (v_price IS NOT NULL AND round(v_price, 8) IS DISTINCT FROM finance.fn_unit_price_from_total(v_total, v_shares)) THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'cost_basis_total is only for taking over an existing position without a price per share - '
                       || 'give either price_per_share or cost_basis_total.');
        END IF;
        v_price := finance.fn_unit_price_from_total(v_total, v_shares);
    END IF;
    -- Rundungs-Paket 2026-10-23: Kurs auf die Spaltenpraezision (8 Stellen), Gebuehr auf Cent (order_fee numeric(12,2)) —
    -- VOR den Pruefungen, damit Betrag, order_fee und unit_price aus denselben Werten entstehen (CHECK
    -- finance_transactions_unit_price_chk) und ein Kurs < 5e-9 nicht als 0 durchrutscht.
    v_price := round(v_price, 8);
    v_fee   := round(v_fee, 2);
    IF v_price IS NULL OR v_price <= 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Price per share must be a positive number (at most 8 decimal places), got '
                   || COALESCE(NULLIF(p->>'price_per_share', ''), v_price::text, 'null')
                   || CASE WHEN v_total IS NOT NULL THEN ' (derived from cost_basis_total ' || v_total || ')' ELSE '' END || '.');
    END IF;
    -- Korrigierbar: negative Gebuehr senkte die Anschaffungskosten still (Spiegel: CHECK finance_transactions_order_fee_chk).
    IF v_fee < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'Order fee must not be negative, got ' || v_fee || '.');
    END IF;
    -- > 8 Stueck-Stellen / Betrag < 1 Cent -> {ok:false} (EINE Adresse mit fn_book_stock_sell).
    v_reason := finance.fn_trade_amount_reason(v_shares, v_shares * v_price + v_fee);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_reason);
    END IF;
    -- Korrigierbar: das Anlageklasse-Etikett muss das Block-key-Format treffen (lowercase snake) -> {ok:false}
    -- statt hartem CHECK-RAISE/Owner-Alert (das LLM nennt das Label, es ist nutzer-korrigierbar).
    IF v_asset_cls IS NOT NULL AND v_asset_cls !~ '^[a-z0-9_]+$' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'asset_class tag must be lowercase letters/digits/underscore (e.g. sp500), got: ' || v_asset_cls);
    END IF;
    -- Bestandsuebernahme ist nie eine Sparplan-Ausfuehrung (die ist echter Geldfluss + Reserve-Journal).
    IF v_existing AND v_rp_id IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'An existing position cannot be a savings-plan execution - book the execution as a normal buy.');
    END IF;
    -- Phase M: optionale Quote-Waehrung (falls gesetzt) registrieren/validieren -> {ok:false} bei ungueltigem
    -- ISO-Code (kein FK-RAISE/Owner-Alert; mirror des currency-Pfads in fn_set_holding). Wird nur beim ANLEGEN
    -- der Holding geschrieben (s. u.) -> der FK auf depot_holdings.quote_currency kann dann nicht feuern.
    IF v_quote_ccy IS NOT NULL THEN
        v_ccy_result := finance.fn_ensure_currency(v_quote_ccy);
        IF NOT (v_ccy_result->>'ok')::boolean THEN
            RETURN v_ccy_result;
        END IF;
    END IF;

    -- Korrigierbar: Depot-Typ muss zur ISIN-Praesenz passen -> {ok:false} (kein RAISE).
    SELECT account_type, currency INTO v_depot_type, v_depot_ccy
    FROM finance.accounts WHERE id = v_depot;
    IF v_isin IS NOT NULL AND v_depot_type <> 'stocks_depot' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Depot type mismatch: an ISIN-based buy requires a stocks_depot, but this depot is '
                   || v_depot_type || '. Ask the user for a stocks depot (or to create one).',
            'depot_type', v_depot_type);
    END IF;
    IF v_isin IS NULL AND v_depot_type <> 'crypto_depot' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Depot type mismatch: a crypto buy (no ISIN) requires a crypto_depot, but this depot is '
                   || v_depot_type || '. Ask the user for a crypto depot (or to create one).',
            'depot_type', v_depot_type);
    END IF;

    -- WS-B Stufe 2: Ableitungs-Kette — ist dieser Kauf die Ausfuehrung eines GOAL-verknuepften Sparplans?
    -- recurring_payment_id -> savings_plans.savings_goal_id (nur wenn die rp einer goal-verknuepften
    -- Sparplan-Zeile gehoert). Manueller Kauf (v_rp_id NULL) -> v_goal bleibt NULL -> keine Reserve-Wirkung.
    -- VOR den Writes bestimmt (der Konservierungs-Guard darf keinen partiellen Holding-Insert hinterlassen).
    -- Audit Paket 2: der Sparplan zeigt auf den KOPF der Vorgaenger-Kette; eine Ausfuehrung zu alten Konditionen
    -- stempelt die alte rp -> ueber den Kopf aufloesen, sonst fiele die Reserve-Gutschrift still weg.
    IF v_rp_id IS NOT NULL THEN
        SELECT savings_goal_id INTO v_goal
        FROM finance.savings_plans
        WHERE recurring_payment_id = finance.fn_recurring_lineage_head(v_rp_id) AND savings_goal_id IS NOT NULL;
    END IF;

    -- WP-3b Konservierungs-Guard: bei einem goal-verknuepften Kauf muss das Cash-Soll-Bein (Settlement-Konto,
    -- native) und die Depot-Reserve-Zeile (Depot-Waehrung, native) DIESELBE Waehrung tragen, sonst kuerzen sie
    -- sich nach der EUR-Umrechnung in savings_goal_progress NICHT weg -> current_amount driftet still. Der
    -- Cross-Currency-Settlement-Fall (z. B. EUR-Konto finanziert KRW-Depot) ist bewusst OUT-of-scope -> {ok:false}
    -- (korrigierbar, kein RAISE) statt still falsch. VOR jedem Write.
    IF v_goal IS NOT NULL THEN
        SELECT currency INTO v_settle_ccy FROM finance.accounts WHERE id = v_settle;
        IF v_settle_ccy IS DISTINCT FROM v_depot_ccy THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Cross-currency goal-linked buy not supported: the settlement account is ' || v_settle_ccy
                       || ' but the depot is ' || COALESCE(v_depot_ccy, 'EUR') || '. Use a settlement account in the '
                       || 'depot currency, or unlink the savings plan from the goal.');
        END IF;
    END IF;

    -- WP-1: ein Sparplan-Kauf ist ein wiederkehrendes Vorkommen (recurring_payment_id gesetzt) -> Idempotenz-Guard
    -- je (rp, Datum, Settlement-Konto) VOR dem Holding-Upsert (freundliche Schnellbahn; manueller Kauf v_rp_id NULL
    -- unberuehrt). Der ON CONFLICT auf der Kauf-Tx unten ist der Race-Backstop (partieller UNIQUE-Index).
    IF v_rp_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM finance.transactions
        WHERE recurring_payment_id = v_rp_id AND recurring_due_date = v_due AND account_id = v_settle) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'This savings-plan execution (payment ' || v_rp_id || ' due ' || v_due || ') is already booked.');
    END IF;
    -- Abgleich-Sperre (Monats-Check WP-A): eine Sparplan-Ausfuehrung ist ein wiederkehrender Geldfluss vom
    -- Verrechnungskonto; dessen Saldo-Abgleich enthaelt sie schon.
    IF v_rp_id IS NOT NULL THEN
        v_reason := finance.fn_reconciled_reason(v_settle, v_date);
        IF v_reason IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'reconciled', 'reason', v_reason);
        END IF;
    END IF;

    -- ISIN-based lookup for stocks/ETFs; symbol-based for crypto (v_isin IS NULL).
    SELECT id INTO v_holding
    FROM finance.depot_holdings
    WHERE account_id = v_depot
      AND (
          (v_isin IS NOT NULL AND isin = v_isin)
          OR (v_isin IS NULL AND isin IS NULL AND symbol = v_symbol)
      )
    LIMIT 1;

    -- Bestandsuebernahme auf eine schon gehaltene Position verdoppelt sie (erneuter Depotauszug) -> {ok:false}.
    IF v_existing AND v_holding IS NOT NULL THEN
        SELECT shares INTO v_held FROM finance.depot_holdings WHERE id = v_holding;
        IF COALESCE(v_held, 0) > 0 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'This depot already holds ' || v_held || ' units of ' || v_symbol || '. A takeover records the '
                       || 'position once and never moves the settlement account; taking it over again would double it. To change '
                       || 'units or purchase price use set_holding. Several purchases of a position the depot does not hold yet '
                       || 'can be taken over together in ONE import batch (one stock_buy row per purchase).',
                'held_shares', v_held);
        END IF;
    END IF;

    IF v_holding IS NULL THEN
        -- Holding-Waehrung = Depot-Waehrung (KRW-Depot -> KRW-Holding), nicht hartkodiert EUR.
        -- asset_class/provider_symbol/quote_currency werden beim ANLEGEN gesetzt; eine bestehende Position
        -- behaelt ihre Werte (Korrektur via set_holding) -> ein wiederholter Kauf ueberschreibt sie nie.
        INSERT INTO finance.depot_holdings
            (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class,
             provider_symbol, quote_currency)
        VALUES (v_depot, v_isin, v_symbol, v_name, 0, NULL, COALESCE(v_depot_ccy, 'EUR'), v_asset_cls,
                v_provider_sym, v_quote_ccy)
        RETURNING id INTO v_holding;
    END IF;

    SELECT balance INTO v_bal_before FROM finance.account_balances WHERE account_id = v_settle;

    -- Bestandsuebernahme: Kauf + Gegenbuchung (Verrechnungskonto-Saldo unveraendert) ueber den EINEN Paar-Baustein.
    IF v_existing THEN
        v_group := gen_random_uuid();
        v_pair := finance.fn_book_takeover_pair(v_holding, v_settle, v_shares, v_price, v_fee, v_date, v_group, v_symbol);
        -- Dieselben Eingaben sind oben schon geprueft -> ein ok:false hier ist ein echter Defekt; RAISE rollt auch eine
        -- eben angelegte Holding zurueck (kein 0-Stueck-Waisen-Eintrag).
        IF NOT (v_pair->>'ok')::boolean THEN
            RAISE EXCEPTION 'fn_book_takeover_pair rejected pre-validated input: %', v_pair->>'reason';
        END IF;
        v_buy := (v_pair->>'buy_tx_id')::int;
    ELSE
    -- EINE Kauf-Transaktion (Gebuehr in amount gefaltet + separat in order_fee). Kein Ziel-Tag (2026-10-27): die
    -- Ziel-Wirkung eines goal-verknuepften Kaufs laeuft komplett ueber das Journal (unten).
    INSERT INTO finance.transactions
        (account_id, amount, transaction_date, category, holding_id, shares, order_fee, unit_price,
         recurring_payment_id, recurring_due_date, savings_goal_id, description, group_id)
    -- unit_price bleibt NULL: ein normaler Kauf rechnet aus |amount| (abgebuchter Cent-Betrag, Broker-Konvention).
    VALUES (v_settle, -(v_shares * v_price + v_fee), v_date, 'buy', v_holding, v_shares, v_fee, NULL,
            v_rp_id, CASE WHEN v_rp_id IS NOT NULL THEN v_due END, NULL,
            'Kauf ' || (p->>'shares') || ' ' || v_symbol || ' @ ' || (p->>'price_per_share')
                   || ' (Gebühr ' || COALESCE(p->>'order_fee', '0') || ')',
            NULL)
    ON CONFLICT (recurring_payment_id, recurring_due_date, account_id) WHERE recurring_payment_id IS NOT NULL
    DO NOTHING
    RETURNING id INTO v_buy;
    END IF;

    -- WP-1 Race-Backstop (nur der Sparplan-Pfad wird vom Index gedeckt; manueller Kauf traegt rp NULL -> kein
    -- Konflikt): leeres RETURNING = Doppel-Ausfuehrung verlor das Race -> {ok:false} VOR dem Reserve-Journal.
    -- Ein Konflikt impliziert einen frueheren Buy dieser rp -> die Holding existierte schon (Lookup fand sie,
    -- kein Neu-Insert) -> kein Orphan-Holding.
    IF v_buy IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'already_booked',
            'reason', 'This savings-plan execution (payment ' || v_rp_id || ' due ' || v_due || ') is already booked.');
    END IF;

    -- WS-B Stufe 2: Ziel-Reserve fortschreiben — append-only Journal-Zeilen (source_tx_id = Kauf, Idempotenz erbt vom
    -- Buy). Depot +X; soweit Ziel-Geld auf dem Verrechnungskonto lag, dort -c (Umschichten, konserviert), der Rest ist
    -- frisch. WP-3b: delta_native = roher Nativ-Betrag in der Depot- (= per Guard Settlement-)Waehrung, value_date =
    -- transaction_date -> die VIEW konvertiert beide Zeilen mit demselben Kurs/Datum nach EUR (kein fn_to_eur am Insert).
    IF v_goal IS NOT NULL THEN
        SELECT LEAST(GREATEST(COALESCE(s.share_native, 0), 0), v_shares * v_price + v_fee) INTO v_goal_cash
        FROM finance.savings_goal_account_share s
        WHERE s.goal_id = v_goal AND s.account_id = v_settle;
        INSERT INTO finance.savings_goal_reserve_entries
            (savings_goal_id, account_id, delta_native, currency, value_date, source_tx_id, kind)
        VALUES (v_goal, v_depot, v_shares * v_price + v_fee, COALESCE(v_depot_ccy, 'EUR'), v_date, v_buy, 'sparplan_buy');
        IF COALESCE(v_goal_cash, 0) > 0 THEN
            INSERT INTO finance.savings_goal_reserve_entries
                (savings_goal_id, account_id, delta_native, currency, value_date, source_tx_id, kind)
            VALUES (v_goal, v_settle, -v_goal_cash, COALESCE(v_depot_ccy, 'EUR'), v_date, v_buy, 'sparplan_buy');
        END IF;
    END IF;

    -- Post-State (Trigger haben gefeuert): Verrechnungskonto-Saldo + Holding shares/avg + Anlageklasse (WS-6).
    SELECT balance INTO v_bal
    FROM finance.account_balances WHERE account_id = v_settle;
    SELECT shares, average_purchase_price, asset_class INTO v_shares_tot, v_avg, v_holding_cls
    FROM finance.depot_holdings WHERE id = v_holding;

    -- Phase L WS-6: Fallback-Note, wenn die RESULTIERENDE Holding ungetaggt ist (asset_class IS NULL — am ENDE,
    -- nicht v_asset_cls IS NULL: ein Re-Buy einer bereits getaggten Position uebergibt asset_class NULL, soll aber
    -- NICHT nagen). Nicht-blockierend (advisory); der Bookkeeper relayed die Note (nur interaktiv).
    RETURN jsonb_build_object('ok', true, 'holding_id', v_holding, 'buy_tx_id', v_buy,
        'settlement_balance', v_bal, 'settlement_change', v_bal - COALESCE(v_bal_before, 0), 'group_id', v_group,
        'total_shares', v_shares_tot, 'avg_purchase_price', v_avg,
        'effective', (v_dates->'resolved') || jsonb_build_object('transaction_date', v_date, 'order_fee', v_fee)
                      || CASE WHEN NULLIF(p->>'cost_basis_total', '') IS NOT NULL
                              THEN jsonb_build_object('price_per_share', v_price) ELSE '{}'::jsonb END)
        || CASE WHEN v_holding_cls IS NULL
                THEN jsonb_build_object('null_tag', jsonb_build_object(
                    'symbol', v_symbol,
                    'note', 'Position "' || v_symbol || '" saved without an asset class. For allocation drift and '
                            || 'rebalancing to work, assign an asset class later with tool_set_holding (e.g. sp500).'))
                ELSE '{}'::jsonb END;
END;
$$;
