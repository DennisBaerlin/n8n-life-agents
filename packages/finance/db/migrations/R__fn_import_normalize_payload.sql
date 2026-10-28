-- ============================================================
-- fn_import_normalize_payload (rein, IMMUTABLE — Zahl-Felder einer Staging-Row kanonisieren)
--   Wendet fn_parse_de_numeric auf die bekannten ZAHL-Felder je entity_type an und schreibt
--   den Wert als JSON-ZAHL zurueck in den Payload. EINMAL beim Staging-Write angewandt (fn_import_stage
--   + fn_import_update_row) -> der gespeicherte Payload ist immer kanonisch, validate_row UND
--   fn_import_bundle (bzw. die inneren fn_create_*) sehen saubere Werte. Genau EINE Stelle der
--   Normalisierung (Review A4: keine Drift zwischen Validate- und Commit-Schicht).
--   * Nur STRING-Werte werden geparst; eine JSON-Zahl (LLM liefert 0.125) ist schon kanonisch und bleibt
--     unberuehrt -> idempotent (update_row normalisiert das ganze Payload erneut, Audit-Fund 2026-10-21).
--   * Tausenderpunkt-Heuristik nur fuer GELD-Felder; Stueckzahl/Kurs/Zinssatz parsen rein dezimal.
--   * Nicht-castbarer String bleibt String (validate_row meldet den freundlichen Row-Fehler).
--   Nicht-Zahl-Felder (Namen, Datum, Enums) bleiben unberuehrt.
--   DEPOT-POSITION (Monats-Check WP-G, Owner-Befund 2026-10-22: Trade-Republic-Auszug ohne Stueckpreis):
--   * average_purchase_price = gedruckter Durchschnitts-Einstandskurs -> Alias fuer price_per_share (Rohwert, nicht
--     abgeleitet; nur bei stock_buy umbenannt, sonst greift die Derived-Denylist in fn_import_validate_row).
--   * cost_basis_total = gedruckter GESAMT-Einstand -> die DB leitet price_per_share = Einstand / Stueck ab (8 NK = Spaltenpraezision;
--     das LLM rechnet nie), wenn kein Stueckpreis gedruckt ist. Beide Eingabe-Keys werden danach entfernt (die
--     Karte zeigt den Stueckpreis; fn_import_allowed_keys kennt sie nicht).
--   * provider_symbol (Kurs-Feed-Symbol) in Grossbuchstaben (VWCE.DE).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_normalize_payload(p_type text, p jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_money TEXT[];
    v_plain TEXT[];
    v_k     TEXT;
    v_txt   TEXT;
BEGIN
    v_money := CASE p_type
        WHEN 'account'           THEN ARRAY['opening_balance']
        WHEN 'stock_buy'         THEN ARRAY['order_fee','cost_basis_total']
        WHEN 'insurance'         THEN ARRAY['premium_amount','annual_premium','coverage_amount']
        WHEN 'pension'           THEN ARRAY['current_value','contribution_amount','guaranteed_monthly_pension']
        WHEN 'recurring_payment' THEN ARRAY['amount']
        WHEN 'real_estate'       THEN ARRAY['current_value']
        WHEN 'savings_goal'      THEN ARRAY['target_amount','monthly_savings_rate','already_saved']
        WHEN 'loan'              THEN ARRAY['original_amount','current_balance','monthly_annuity']
        WHEN 'pension_statement' THEN ARRAY['reached_claim','projection','scenario_1pct','scenario_2pct','em_monthly']
        ELSE ARRAY[]::TEXT[]
    END;
    v_plain := CASE p_type
        WHEN 'account'           THEN ARRAY['interest_rate']
        WHEN 'stock_buy'         THEN ARRAY['shares','price_per_share','average_purchase_price']
        WHEN 'loan'              THEN ARRAY['interest_rate']
        WHEN 'pension_statement' THEN ARRAY['earning_points']   -- Entgeltpunkte "9,1234": rein dezimal, kein Tausenderpunkt
        ELSE ARRAY[]::TEXT[]
    END;

    FOREACH v_k IN ARRAY v_money || v_plain LOOP
        CONTINUE WHEN jsonb_typeof(p->v_k) IS DISTINCT FROM 'string' OR NULLIF(p->>v_k, '') IS NULL;
        v_txt := finance.fn_parse_de_numeric(p->>v_k, v_k = ANY(v_money));
        BEGIN
            p := jsonb_set(p, ARRAY[v_k], to_jsonb(v_txt::numeric));
        EXCEPTION WHEN invalid_text_representation THEN
            p := jsonb_set(p, ARRAY[v_k], to_jsonb(v_txt));   -- nicht castbar -> validate_row meldet es
        END;
    END LOOP;

    IF p_type = 'stock_buy' THEN
        IF NULLIF(p->>'price_per_share', '') IS NULL AND jsonb_typeof(p->'average_purchase_price') = 'number' THEN
            p := jsonb_set(p, '{price_per_share}', p->'average_purchase_price');
        END IF;
        IF NULLIF(p->>'price_per_share', '') IS NULL
           AND jsonb_typeof(p->'cost_basis_total') = 'number' AND jsonb_typeof(p->'shares') = 'number'
           AND (p->>'shares')::numeric > 0 THEN
            p := jsonb_set(p, '{price_per_share}',
                           to_jsonb(finance.fn_unit_price_from_total((p->>'cost_basis_total')::numeric, (p->>'shares')::numeric)));
        ELSIF NULLIF(p->>'price_per_share', '') IS NULL AND jsonb_typeof(p->'cost_basis_total') = 'string' THEN
            -- nicht lesbarer/mehrdeutiger Gesamt-Einstand ("643,220") -> als Preis-Rohwert stehen lassen: validate_row meldet
            -- den Wert als "keine Zahl" (Rueckfrage) statt still "Preis fehlt" (Rundungs-Paket 2026-10-23)
            p := jsonb_set(p, '{price_per_share}', p->'cost_basis_total');
        END IF;
        -- Stueckzahl auf die Spaltenpraezision (numeric(18,8)) — SICHTBAR: die Karte zeigt den gerundeten Wert vor dem
        -- Bestaetigen (Boersen liefern bis 18 Stellen; das Einzel-Tool lehnt > 8 Stellen dagegen ab, fn_trade_amount_reason).
        IF jsonb_typeof(p->'shares') = 'number' THEN
            p := jsonb_set(p, '{shares}', to_jsonb(round((p->>'shares')::numeric, 8)));
        END IF;
        p := p - 'average_purchase_price' - 'cost_basis_total';
        IF NULLIF(p->>'provider_symbol', '') IS NOT NULL THEN
            p := jsonb_set(p, '{provider_symbol}', to_jsonb(upper(trim(p->>'provider_symbol'))));
        END IF;
        IF NULLIF(p->>'provider_currency', '') IS NOT NULL THEN   -- Kurs-Waehrung einer Fremd-Notierung (USD)
            p := jsonb_set(p, '{provider_currency}', to_jsonb(upper(trim(p->>'provider_currency'))));
        END IF;
    END IF;
    RETURN p;
END;
$$;
