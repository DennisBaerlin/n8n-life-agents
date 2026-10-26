-- ============================================================
-- fn_account_interest_defaults (READ, STABLE) -- die vorgeschlagenen Zins-Werte eines NEUEN Kontos
--   EINE Quelle fuer die HITL-Karte (tool_create_account 'Resolve interest defaults', Import-Karte ueber
--   fn_import_card_rows) UND fn_create_account (Karte = Write; Praezedenz fn_interest_rate_preview).
--   Regeln: unit = interest_credit_unit, sonst NULL -- KEIN erfundener Rhythmus (Live-Befund 2026-10-24: vorher 'year';
--   fn_create_account lehnt einen Satz ohne Rhythmus ueber fn_interest_schedule_reason ab); interval =
--   interest_credit_interval > 1; dom / pdom = interest_credit_day_of_month / interest_posting_day_of_month;
--   conv = interest_day_count_convention > fn_interest_default_convention (Kontotyp); auto_post = interest_auto_post >
--   fn_interest_auto_post_default(unit); conv_reason = manual | default_cash | default_fixed | default (Begruendung auf
--   der Karte); valid_from = interest_valid_from > heute.
--   first_period_end / first_credit_date = erstes Periodenende bzw. Gutschrift-Datum ab valid_from aus DEMSELBEN Raster
--   wie die Faelligkeit (fn_interest_next_period_end / fn_interest_value_date) -- die Karte zeigt "Erste Gutschrift"
--   und macht so das Kalender-Raster sichtbar; NULL ohne Rhythmus.
--   Leere Strings = nicht genannt (Einzel-Tool). Eingabe jsonb wie fn_create_account.
--   RUECKGABE {unit, interval, dom, pdom, conv, conv_reason, auto_post, valid_from, first_period_end, first_credit_date}.
--   STABLE (core.fn_today(): Karte und Write lesen "heute" je zu ihrem Zeitpunkt — eine Karte vor Mitternacht,
--   bestaetigt danach, bekommt den neuen Tag; bewusst, Wartegrenze 10 Min).
--   Tests: tests/db/finance/test_fn_account_interest_defaults.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_interest_defaults(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_type finance.account_type  := NULLIF(p->>'account_type', '')::finance.account_type;
    v_unit finance.schedule_unit := NULLIF(p->>'interest_credit_unit', '')::finance.schedule_unit;
    -- Einlesen ueber fn_parse_small_int (EINE Adresse mit dem Check in fn_create_account): 'Resolve interest defaults'
    -- laeuft bei JEDEM create_account, auch ohne Zinssatz; ein unlesbarer Wert (z. B. "last") wirft hier nicht --
    -- fn_create_account lehnt ihn bei gesetztem Satz ab.
    v_n    INT      := COALESCE(finance.fn_parse_small_int(p->>'interest_credit_interval'), 1);
    v_dom  INT      := finance.fn_parse_small_int(p->>'interest_credit_day_of_month');
    v_pdom SMALLINT := finance.fn_parse_small_int(p->>'interest_posting_day_of_month');
    v_conv TEXT     := NULLIF(p->>'interest_day_count_convention', '');
    -- relative Angabe ("in 2 weeks") -> core.fn_resolve_date; unlesbar -> heute: dieser Vorschlags-Lookup wirft nie,
    -- fn_create_account (Probelauf vor der Karte) lehnt dasselbe interest_valid_from mit {ok:false} ab.
    v_from DATE     := COALESCE(core.fn_resolve_date(NULLIF(p->>'interest_valid_from', '')), core.fn_today());
    v_pe   DATE;
BEGIN
    IF v_unit IS NOT NULL THEN
        v_pe := finance.fn_interest_next_period_end(v_from, v_from, v_n, v_unit, v_dom);
    END IF;
    RETURN jsonb_build_object(
        'unit', v_unit,
        'interval', v_n,
        'dom', v_dom,
        'pdom', v_pdom,
        'conv', COALESCE(v_conv, finance.fn_interest_default_convention(v_type)),
        'conv_reason', CASE WHEN v_conv IS NOT NULL THEN 'manual'
                            WHEN v_type = 'cash' THEN 'default_cash'
                            WHEN v_type = 'fixed_deposit' THEN 'default_fixed'
                            ELSE 'default' END,
        'auto_post', COALESCE(NULLIF(p->>'interest_auto_post', '')::boolean,
                              finance.fn_interest_auto_post_default(v_unit), false),
        'valid_from', to_char(v_from, 'YYYY-MM-DD'),
        'first_period_end', to_char(v_pe, 'YYYY-MM-DD'),
        'first_credit_date', to_char(finance.fn_interest_value_date(v_pe, v_pdom), 'YYYY-MM-DD'));
END;
$$;
