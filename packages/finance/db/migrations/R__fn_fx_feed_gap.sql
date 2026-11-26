-- ============================================================
-- fn_fx_feed_gap (READ with side effect, VOLATILE) -- liefert der Wechselkurs-Dienst noch? ("Quelle frisch?")
--   Die eine Adresse fuer die Ausfall-Meldung der Wechselkurse (cron_remind_missing_prices, Zweig FX feed down?),
--   Muster fn_price_gaps. Gemessen am juengsten Quell-Datum as_of der Tages-Feed-Zeilen, nicht
--   an updated_at: so fallen auch "Feed antwortet mit altem Stand", result=error und leeres rates auf. Nur Zeilen der Quelle
--   fn_fx_feed_source(): EZB-Nachlauf-Zeilen (source ecb) verdecken keinen Ausfall. Bezug ist das UTC-Datum (as_of ist das
--   UTC-Datum der Veroeffentlichung), nicht der Haushalts-Tag: sonst meldete ein Haushalt oestlich von UTC einen Tag zu frueh.
--   feed_down = Abruf eingeschaltet (cron_enable refresh_fx_rates) UND UTC-heute - juengstes as_of >= finance.fx_feed_alert_days
--   (Default 2, unlesbar -> 2): ein Tag Aussetzer bleibt still. Ohne jede Feed-Zeile (never) ist der Anker die
--   Installation des Pakets (core.fn_package_installed_at); erst fx_feed_alert_days danach gilt der Feed als ausgefallen.
--   Re-Arm (Seiteneffekt, darum VOLATILE): ohne feed_down core.fn_notify_resolve('finance:fx', 'feed_down') -> ein
--   spaeterer Ausfall meldet sich neu; gemeldet (gelatcht) wird erst im Cron via fn_feed_down_claim('fx').
--   Eingabe: keine. Rueckgabe: jsonb {feed_down boolean, never boolean, stale_since date|null (juengstes Quell-Datum)}.
--   Tests: tests/db/finance/test_fn_fx_feed_gap.sql
-- ============================================================
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
    v_anchor  timestamptz;
    v_down    boolean;
BEGIN
    SELECT max(r.as_of) INTO v_last FROM finance.fx_rates r WHERE r.source = finance.fn_fx_feed_source();
    IF v_last IS NOT NULL THEN
        v_down := v_enabled AND v_today - v_last >= v_days;
    ELSE
        v_anchor := core.fn_package_installed_at('finance');
        v_down := v_enabled AND v_anchor IS NOT NULL AND v_today - (v_anchor AT TIME ZONE 'UTC')::date >= v_days;
    END IF;

    IF NOT v_down THEN
        PERFORM core.fn_notify_resolve('finance:fx', 'feed_down');
    END IF;

    RETURN jsonb_build_object('feed_down', v_down, 'never', v_last IS NULL, 'stale_since', v_last);
END;
$$;
