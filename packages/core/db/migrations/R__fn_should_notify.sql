-- ============================================================
-- fn_should_notify (ATOMIC WRITE — geteilte Notify-Dedup-Entscheidung)
--   Das eine Entscheidungs-Fenster aller Owner-Benachrichtigungs-Producer. Liefert true genau dann,
--   wenn der Latch (source, key) jetzt von 'ok' -> 'fired' kippt, d.h. die Notiz ist neu (Erst-Breach
--   oder nach Re-Arm) und soll raus. Stempelt in derselben Operation state='fired', last_fired_at, und
--   (bei TTL) expires_at = now()+ttl. Bereits 'fired' ohne abgelaufenen TTL -> false (still).
--   Eingabe: p_source text, p_key text, p_ttl interval (optional). Rueckgabe: boolean.
--
--   Vertrag: nur aufrufen, wenn die zu meldende Bedingung bereits wahr ist — die fn gatet eine schon-
--     wahre Notiz (Dedup), sie evaluiert die Bedingung nicht selbst. (Reserve breached? monthly_net<0?
--     unbekannter Knock? -> erst pruefen, dann fn_should_notify.)
--
--   Strategien ueber einen Parameter:
--     * p_ttl = NULL  -> reiner Edge-Latch: feuert einmal, bleibt 'fired' bis ein expliziter Re-Arm
--                        (fn_notify_resolve / fn_notify_reconcile) kommt. Fuer reserve_breach (Re-Arm
--                        im Saldo-Trigger) + advisor (Re-Arm via Reconcile-GC).
--     * p_ttl = intvl -> Cooldown/TTL-Backstop: feuert, ist im Fenster still, re-armt nach Ablauf
--                        automatisch. Fuer knock (1h) + cashflow_coverage-Backstop (48h) + savings_squeeze (24h).
--
--   Race-safe (Muster core.fn_advisor_review_evaluate): INSERT ... ON CONFLICT DO NOTHING (schliesst die
--     PK-Luecke beim Erst-Breach; ein SELECT ... FOR UPDATE auf eine nicht-existente Zeile sperrte keine
--     Luecke) -> dann FOR UPDATE auf die nun existente Zeile (serialisiert gleichzeitige Producer).
--
--   SECURITY DEFINER + gepinnter search_path + REVOKE PUBLIC: enge Paket-Rollen (finance_rw)
--     erreichen core.notification_state nur ueber dieses Fenster. EXECUTE-Grant in fn_provision_package_roles.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_should_notify(p_source text, p_key text, p_ttl interval DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_state TEXT;
    v_exp   TIMESTAMPTZ;
BEGIN
    -- Zeile idempotent anlegen (Default 'ok'), dann sperren + Vorzustand lesen (Race-Muster).
    INSERT INTO core.notification_state (source, key, state)
    VALUES (p_source, p_key, 'ok')
    ON CONFLICT (source, key) DO NOTHING;

    SELECT state, expires_at INTO v_state, v_exp
    FROM core.notification_state
    WHERE source = p_source AND key = p_key
    FOR UPDATE;

    -- Kippen, wenn 'ok' (frisch/re-armed) oder ein TTL-Latch abgelaufen ist (auto Re-Arm).
    -- NULL-TTL-'fired' re-armt nie automatisch -> bleibt still bis explizitem Re-Arm.
    IF v_state = 'ok' OR (v_state = 'fired' AND v_exp IS NOT NULL AND v_exp <= now()) THEN
        UPDATE core.notification_state
        SET state         = 'fired',
            last_fired_at = now(),
            expires_at    = CASE WHEN p_ttl IS NULL THEN NULL ELSE now() + p_ttl END,
            updated_at    = now()
        WHERE source = p_source AND key = p_key;
        RETURN true;
    END IF;

    RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_should_notify(text, text, interval) FROM public;
