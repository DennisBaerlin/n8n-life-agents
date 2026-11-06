-- ============================================================
-- core.fn_app_verify_init_data (READ) — prueft die Telegram-initData der Mini-App (docs/package-contract.md §3.12)
--   Verfahren laut core.telegram.org/bots/webapps („Validating data received via the Mini App“):
--   Query-String an '&' teilen, jeden Teil an '=' teilen und per core.fn_url_decode dekodieren (doppelter Key oder
--   ein Teil ohne '=' -> malformed); data_check_string = alle Felder ausser hash (signature zaehlt mit), sortiert
--   nach Key (Byte-Ordnung), 'key=value' mit '\n' verbunden; hex(HMAC_SHA256(data_check_string, Schluessel)) muss
--   hash sein. Schluessel = core.app_secret (= HMAC("WebAppData", Bot-Token), vom Host je Deploy geschrieben).
--   Danach auth_date: nicht aelter als core.config app.init_data_max_age_s (Standard 3600 s), hoechstens 60 s in der
--   Zukunft (Uhren-Toleranz), sonst expired. user.id kommt aus DERSELBEN geparsten Map wie die Pruefung.
--   NIE EIN RAISE (Muell aus dem Internet darf keinen Owner-Alert ausloesen). p_now nur fuer Tests.
--   INVOKER unter der Host-Credential (liest core.app_secret, das keine Leserolle sieht); pgcrypto liegt in public.
--   p_init_data: Telegram.WebApp.initData (roh, URL-kodiert)
--   RUECKGABE: {ok:true, telegram_user_id, language_code, auth_date} |
--              {ok:false, code: malformed|bad_signature|expired|no_secret}
--   Tests: tests/db/core/test_fn_app_verify_init_data.sql (extern berechneter Vektor)
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_app_verify_init_data(p_init_data text, p_now timestamptz DEFAULT now())
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_keys text[] := '{}';
    v_vals text[] := '{}';
    v_pair text;
    v_pos  int;
    v_k    text;
    v_hash text;
    v_auth bigint;
    v_user jsonb;
    v_key  bytea;
    v_dcs  text;
    v_max  int;
    v_age  bigint;
BEGIN
    IF p_init_data IS NULL OR p_init_data = '' OR length(p_init_data) > 8192 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'malformed');
    END IF;

    BEGIN
        FOREACH v_pair IN ARRAY string_to_array(p_init_data, '&') LOOP
            v_pos := strpos(v_pair, '=');
            IF v_pos < 2 THEN
                RETURN jsonb_build_object('ok', false, 'code', 'malformed');
            END IF;
            v_k := core.fn_url_decode(left(v_pair, v_pos - 1));
            IF v_k = ANY (v_keys) THEN
                RETURN jsonb_build_object('ok', false, 'code', 'malformed');
            END IF;
            v_keys := v_keys || v_k;
            v_vals := v_vals || core.fn_url_decode(substr(v_pair, v_pos + 1));
        END LOOP;

        v_hash := lower(v_vals[array_position(v_keys, 'hash')]);
        v_k    := v_vals[array_position(v_keys, 'auth_date')];
        IF v_hash IS NULL OR v_hash !~ '^[0-9a-f]{64}$' OR v_k IS NULL OR v_k !~ '^[0-9]{1,12}$' THEN
            RETURN jsonb_build_object('ok', false, 'code', 'malformed');
        END IF;
        v_auth := v_k::bigint;
        v_user := (v_vals[array_position(v_keys, 'user')])::jsonb;
        IF jsonb_typeof(v_user) IS DISTINCT FROM 'object' OR COALESCE(v_user->>'id', '') !~ '^[0-9]{1,18}$' THEN
            RETURN jsonb_build_object('ok', false, 'code', 'malformed');
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'code', 'malformed');
    END;

    SELECT s.webapp_key INTO v_key FROM core.app_secret s WHERE s.id;
    IF v_key IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'no_secret');
    END IF;

    SELECT string_agg(u.k || '=' || u.v, E'\n' ORDER BY u.k COLLATE "C")
      INTO v_dcs
      FROM unnest(v_keys, v_vals) AS u(k, v)
     WHERE u.k <> 'hash';
    -- Vergleich ohne Zeit-Seitenkanal: beide Seiten noch einmal mit dem Schluessel hashen (Double-HMAC), dann
    -- haengt die Vergleichsdauer nicht am Praefix des angreifer-gewaehlten hash.
    IF public.hmac(public.hmac(convert_to(v_dcs, 'UTF8'), v_key, 'sha256'), v_key, 'sha256')
       IS DISTINCT FROM public.hmac(decode(v_hash, 'hex'), v_key, 'sha256') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'bad_signature');
    END IF;

    BEGIN
        v_max := NULLIF(core.fn_config_get('core', 'app', 'init_data_max_age_s'), '')::int;
    EXCEPTION WHEN OTHERS THEN
        v_max := NULL;
    END;
    v_age := extract(epoch FROM p_now)::bigint - v_auth;
    IF v_age > COALESCE(v_max, 3600) OR v_age < -60 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'expired');
    END IF;

    RETURN jsonb_build_object('ok', true,
                              'telegram_user_id', (v_user->>'id')::bigint,
                              'language_code', v_user->>'language_code',
                              'auth_date', v_auth);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_app_verify_init_data(text, timestamptz) FROM public;
