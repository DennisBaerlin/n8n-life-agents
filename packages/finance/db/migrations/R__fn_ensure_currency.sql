-- packages/finance/db/migrations/R__fn_ensure_currency.sql
-- fn_currency_minor_unit (READ, IMMUTABLE)
--   Nachkommastellen eines Waehrungscodes nach ISO 4217 (SIX "List One", Stand 2026-09-17): 0, 3 und 4 Stellen als
--   Ausnahme-Liste, sonst 2 (auch Nicht-ISO-Codes des Kurs-Feeds und N.A.-Codes wie XDR). Die eine Regel fuer
--   fn_ensure_currency (Einzel-Code) und fn_upsert_fx_rates (alle Feed-Waehrungen auf einmal): der erste Voll-Abruf
--   legt jede Feed-Waehrung endgueltig an (ON CONFLICT DO NOTHING), minor_unit steuert die Rundung im Abgleich.
--   Eingabe: p_code. Rueckgabe: smallint.
-- fn_ensure_currency (WRITE HELPER)
--   Registriert einen ISO-4217-Code in finance.currencies, falls er fehlt (idempotent, ON CONFLICT DO NOTHING).
--   Eingabe: p_code (Pflicht, ^[A-Z]{3}$); minor_unit aus fn_currency_minor_unit.
--   Rueckgabe: {ok:true, code, minor_unit} | {ok:false, reason} (ungueltiger Code oder Edelmetall, kein RAISE): Metall-Codes
--   (fn_is_metal) sind nur Kurs-Codes; die FK-Sperre der Waehrungs-Spalten loeste sonst einen Owner-Alarm aus.
-- Tests: tests/db/finance/test_fn_ensure_currency.sql
CREATE OR REPLACE FUNCTION finance.fn_currency_minor_unit(p_code text)
RETURNS smallint LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_code IN ('BIF', 'CLP', 'DJF', 'GNF', 'ISK', 'JPY', 'KMF', 'KRW', 'PYG', 'RWF', 'UGX', 'UYI', 'VND',
                    'VUV', 'XAF', 'XOF', 'XPF') THEN 0
    WHEN p_code IN ('BHD', 'IQD', 'JOD', 'KWD', 'LYD', 'OMR', 'TND') THEN 3
    WHEN p_code IN ('CLF', 'UYW') THEN 4
    ELSE 2
  END::smallint
$$;

CREATE OR REPLACE FUNCTION finance.fn_ensure_currency(p_code text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_minor_unit SMALLINT;
BEGIN
  IF p_code !~ '^[A-Z]{3}$' THEN
    RETURN jsonb_build_object('ok', false,
      'reason', format('invalid currency code %L: must match ^[A-Z]{3}$', p_code));
  END IF;

  IF finance.fn_is_metal(p_code) THEN
    RETURN jsonb_build_object('ok', false,
      'reason', format('%s is a precious metal (a price code for exchange rates and watchers), not a currency for accounts, holdings or prices', p_code));
  END IF;

  v_minor_unit := finance.fn_currency_minor_unit(p_code);

  INSERT INTO finance.currencies (code, minor_unit)
  VALUES (p_code, v_minor_unit)
  ON CONFLICT (code) DO NOTHING;

  RETURN jsonb_build_object('ok', true, 'code', p_code, 'minor_unit', v_minor_unit);
END;
$$;
