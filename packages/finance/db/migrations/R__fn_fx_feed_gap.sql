-- ============================================================
-- fn_fx_feed_gap (READ with side effect, VOLATILE) -- kommen noch Wechselkurse an? ("Quelle frisch?")
--   Die eine Adresse fuer die Ausfall-Meldung der Wechselkurse (cron_remind_missing_prices, Zweig FX feed down?),
--   Muster fn_price_gaps. Gemessen am juengsten Quell-Datum as_of, nicht an updated_at: so fallen auch "Feed antwortet
--   mit altem Stand", result=error und leeres rates auf. Bezug ist das UTC-Datum (as_of ist das UTC-Datum der
--   Veroeffentlichung), nicht der Haushalts-Tag: sonst meldete ein Haushalt oestlich von UTC einen Tag zu frueh.
--   Zwei Quellen, gemeldet wird erst, wenn beide ausfallen:
--     Tages-Feed (fn_fx_feed_source) aus = UTC-heute - juengstes as_of >= finance.fx_feed_alert_days (Default 2,
--       unlesbar -> 2; ein Tag Aussetzer bleibt still); ohne jede Feed-Zeile ist der Anker die Installation des Pakets
--       (core.fn_package_installed_at).
--     Ersatzquelle EZB (fn_fx_history_source, Nachlauf und Ersatz-Abruf des FX-Crons) aus = keine Zeile, oder
--       mindestens fx_feed_alert_days Arbeitstage (Mo-Fr) zwischen juengstem as_of und UTC-heute: die EZB veroeffentlicht
--       nur werktags, ein Wochenende ist kein Ausfall. TARGET-Feiertage zaehlt das bewusst mit (seltene Fruehmeldung nur,
--       wenn zugleich der Tages-Feed aus ist).
--   feed_down = Abruf eingeschaltet (cron_enable refresh_fx_rates) UND beide Quellen aus.
--   Re-Arm (Seiteneffekt, darum VOLATILE): ohne feed_down core.fn_notify_resolve('finance:fx', 'feed_down') -> ein
--   spaeterer Ausfall meldet sich neu; gemeldet (gelatcht) wird erst im Cron via fn_feed_down_claim('fx').
--   Eingabe: keine. Rueckgabe: jsonb {feed_down boolean, never boolean (keine Zeile aus beiden Quellen),
--   stale_since date|null (juengstes Quell-Datum beider Quellen)}.
--   Tests: tests/db/finance/test_fn_fx_feed_gap.sql
-- fn_weekdays_between (READ, IMMUTABLE) -- Anzahl der Tage Mo-Fr echt zwischen p_from und p_to (beide exklusiv;
--   p_to <= p_from + 1 -> 0). Fuer die Werktags-Frische der EZB-Kurse.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_weekdays_between(p_from date, p_to date)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT count(*)::int
    FROM generate_series(p_from + 1, p_to - 1, interval '1 day') d
    WHERE extract(isodow FROM d) < 6;
$$;

CREATE OR REPLACE FUNCTION finance.fn_fx_feed_gap()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    v_today   date := (now() AT TIME ZONE 'UTC')::date;
    v_cfg     text := core.fn_config_get('finance', 'finance', 'fx_feed_alert_days');
    v_days    int  := CASE WHEN v_cfg ~ '^[0-9]{1,3}$' THEN v_cfg::int ELSE 2 END;
    v_enabled boolean := COALESCE(core.fn_config_get('finance', 'cron_enable', 'refresh_fx_rates') = 'true', false);
    v_last    date;
    v_ecb     date;
    v_anchor  timestamptz;
    v_feed_down boolean;
    v_down    boolean;
BEGIN
    SELECT max(r.as_of) INTO v_last FROM finance.fx_rates r WHERE r.source = finance.fn_fx_feed_source();
    SELECT max(r.as_of) INTO v_ecb  FROM finance.fx_rates r WHERE r.source = finance.fn_fx_history_source();
    IF v_last IS NOT NULL THEN
        v_feed_down := v_today - v_last >= v_days;
    ELSE
        v_anchor := core.fn_package_installed_at('finance');
        v_feed_down := v_anchor IS NOT NULL AND v_today - (v_anchor AT TIME ZONE 'UTC')::date >= v_days;
    END IF;
    v_down := v_enabled AND v_feed_down
              AND (v_ecb IS NULL OR finance.fn_weekdays_between(v_ecb, v_today) >= v_days);

    IF NOT v_down THEN
        PERFORM core.fn_notify_resolve('finance:fx', 'feed_down');
    END IF;

    RETURN jsonb_build_object('feed_down', v_down, 'never', v_last IS NULL AND v_ecb IS NULL,
                              'stale_since', GREATEST(v_last, v_ecb));
END;
$$;
