-- packages/finance/db/migrations/R__fn_ensure_currency.sql
-- Auto-registers an ISO-4217 currency code in finance_currencies if absent.
-- Guards: ^[A-Z]{3}$ regex; zero-decimal list (minor_unit=0); all others default to 2.
-- Idempotent: ON CONFLICT (code) DO NOTHING. Returns {ok:bool, reason?, code, minor_unit}.
CREATE OR REPLACE FUNCTION finance.fn_ensure_currency(p_code text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_minor_unit SMALLINT;
BEGIN
  IF p_code !~ '^[A-Z]{3}$' THEN
    RETURN jsonb_build_object('ok', false,
      'reason', format('invalid currency code %L: must match ^[A-Z]{3}$', p_code));
  END IF;

  -- ISO 4217 zero-decimal currencies (minor_unit = 0)
  v_minor_unit := CASE p_code
    WHEN 'BIF' THEN 0 WHEN 'CLP' THEN 0 WHEN 'DJF' THEN 0 WHEN 'GNF' THEN 0
    WHEN 'ISK' THEN 0 WHEN 'JPY' THEN 0 WHEN 'KMF' THEN 0 WHEN 'KRW' THEN 0
    WHEN 'PYG' THEN 0 WHEN 'RWF' THEN 0 WHEN 'UGX' THEN 0 WHEN 'VND' THEN 0
    WHEN 'VUV' THEN 0 WHEN 'XAF' THEN 0 WHEN 'XOF' THEN 0 WHEN 'XPF' THEN 0
    ELSE 2
  END;

  INSERT INTO finance.currencies (code, minor_unit)
  VALUES (p_code, v_minor_unit)
  ON CONFLICT (code) DO NOTHING;

  RETURN jsonb_build_object('ok', true, 'code', p_code, 'minor_unit', v_minor_unit);
END;
$$;
