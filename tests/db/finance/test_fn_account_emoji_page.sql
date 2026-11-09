-- tests/db/finance/test_fn_account_emoji_page.sql
-- Knopf-Liste: je Kontoart und Seite genau sechs, ueber vier Seiten jedes Zeichen genau einmal, Blaettern im Kreis.
BEGIN;
DO $$
DECLARE t finance.account_type; v_id int; v_s int; p int; c jsonb; v_all text[]; v_first text; o jsonb; v_e text;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__pg_settle__','cash','EUR','active') RETURNING id INTO v_s;
  FOREACH t IN ARRAY enum_range(NULL::finance.account_type) LOOP
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, fixed_deposit_maturity_date)
      VALUES ('__pg_' || t || '__', t, 'EUR', 'active', CASE WHEN t IN ('stocks_depot','crypto_depot') THEN v_s END, CASE WHEN t = 'fixed_deposit' THEN core.fn_today() + 90 END)
      RETURNING id INTO v_id;
    v_all := ARRAY[]::text[];
    FOR p IN 0..3 LOOP
      c := finance.fn_account_emoji_page(v_id, p, 'de');
      IF jsonb_array_length(c->'options') <> 6 THEN RAISE EXCEPTION 'FAIL [sechs %/%]: %', t, p, c; END IF;
      FOR o IN SELECT * FROM jsonb_array_elements(c->'options') LOOP
        v_e := split_part(o->>'data', ':', 3);
        IF o->>'data' <> 'acem:' || v_id || ':' || v_e OR char_length(v_e) <> 1 OR left(o->>'text', 2) <> v_e || ' ' OR octet_length(o->>'data') > 64 THEN RAISE EXCEPTION 'FAIL [data %]: %', t, o; END IF;
        v_all := v_all || v_e;
      END LOOP;
      IF c->'more'->>'data' <> 'acem:' || v_id || ':more:' || ((p + 1) % 4) THEN RAISE EXCEPTION 'FAIL [more %/%]: %', t, p, c->'more'; END IF;
      IF NULLIF(c->>'text', '') IS NULL OR NULLIF(c->'more'->>'text', '') IS NULL THEN RAISE EXCEPTION 'FAIL [Texte]: %', c; END IF;
      IF p = 0 THEN v_first := split_part(c->'options'->0->>'data', ':', 3); END IF;
    END LOOP;
    IF v_first <> finance.fn_account_emoji(NULL, t) THEN RAISE EXCEPTION 'FAIL [erstes = Ersatz %]: %', t, v_first; END IF;
    IF (SELECT count(DISTINCT x) FROM unnest(v_all) x) <> 24 OR cardinality(v_all) <> 24
       OR EXISTS (SELECT 1 FROM unnest(v_all) x WHERE NOT x = ANY(finance.fn_account_emoji_choices())) THEN RAISE EXCEPTION 'FAIL [jedes genau einmal %]: %', t, v_all; END IF;
  END LOOP;
  IF finance.fn_account_emoji_page(-1, 0, 'de') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [unbekanntes Konto]'; END IF;
  IF finance.fn_account_emoji_page(v_s, 4, 'de') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [Seite ausserhalb]'; END IF;
END $$;

-- Erste Seite der Kontoart wie abgenommen
DO $$
DECLARE v int; v_got text;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__pg_c__','cash','EUR','active') RETURNING id INTO v;
  SELECT string_agg(split_part(o->>'data', ':', 3), ' ') INTO v_got FROM jsonb_array_elements(finance.fn_account_emoji_page(v, 0, 'de')->'options') o;
  IF v_got <> '🏦 💳 👛 🐷 💰 🏠' THEN RAISE EXCEPTION 'FAIL [Seite 0 cash]: %', v_got; END IF;
END $$;
ROLLBACK;
