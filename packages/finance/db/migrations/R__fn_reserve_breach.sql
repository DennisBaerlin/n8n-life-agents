-- ============================================================
-- fn_reserve_breach (READ-ONLY Helfer, WS-C2/WS-B Phase S — proaktiver Reserve-Waechter)
--   Liest fuer GENAU EIN CASH-Konto den Deckungs-Waechter (finance.account_reserve_status: SALDO vs. getaggte
--   Reserve, NATIVE-Waehrung) und liefert bei Breach ein kompaktes jsonb-Objekt, sonst NULL.
--   Aufgerufen von fn_book_transaction/fn_book_transfer NACH dem Post-State-Saldo-Read; die Buch-fn FALTET das
--   Ergebnis als Kategorie-3-Post-State-Wert (`reserve_breach`) in ihren {ok:true,...}-Rueckgabevertrag. Der
--   Finance-Agent spricht den Owner dann proaktiv an + bietet auffuellen/Rate-erhoehen.
--   ADVISORY: kein Block, kein RAISE — der Spend ist legitim. Etablierter Standard YNAB „turn yellow".
--   RUECKGABE bei Breach: {account_id, account_name, balance, reserved, shortfall, note} — alle Zahlen
--     DB-berechnet; `note` deutsch-gerendert (NATIVE-Waehrung des Kontos). Kein Breach -> keine Zeile -> NULL.
--   WP-5a: der fruehere Depot-Zweig (depot_reserve_status) ist ENTFERNT — er war write-time UNERREICHBARER
--     toter Code: die einzigen Aufrufer fn_book_transaction/fn_book_transfer uebergeben IMMER ein Cash-Quellkonto
--     (ein Depot-Trade laeuft ueber fn_book_stock_buy/sell, die fn_reserve_breach nicht rufen), und der Depot-
--     Deckungs-Read laeuft direkt ueber depot_reserve_status in fn_advisor_review (Deckungs-Dialog).
--   LANGUAGE sql STABLE, SECURITY INVOKER (Default): laeuft unter finance_rw, das die View ueber den schema-
--     weiten GRANT liest. Kein DEFINER -> kein search_path-Pin/REVOKE-Gate (Catalog matcht nur DEFINER).
--   Anwenden via: db_apply.ps1 -File packages\finance\db\migrations\R__fn_reserve_breach.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_reserve_breach(p_account_id int)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    -- Cash/Festgeld-Zweig: Saldo-basiert, NATIVE-Waehrung. (Einziger Zweig — s. Kopf WP-5a.)
    SELECT jsonb_build_object(
               'account_id',   s.account_id,
               'account_name', s.account_name,
               'balance',      s.balance,
               'reserved',     s.reserved,
               'shortfall',    s.shortfall,
               'note', 'Warning: "' || s.account_name || '" has '
                       || round(s.reserved, 2) || ' ' || s.currency
                       || ' reserved for savings goals, but the balance is only '
                       || round(s.balance, 2) || ' ' || s.currency
                       || ' (' || round(s.shortfall, 2) || ' ' || s.currency || ' short).')
    FROM finance.account_reserve_status s
    WHERE s.account_id = p_account_id AND s.breach
    LIMIT 1;
$$;
