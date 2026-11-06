-- packages/finance/db/migrations/R__fn_normalize_currency.sql
-- Normalisiert einen roh vom LLM/Owner gelieferten Waehrungs-Code auf die kanonische
-- ISO-4217-Schreibweise: upper(trim(...)). EINE Quelle fuer ALLE Waehrungs-Schreibwege
-- (fn_create_account, fn_book_stock_buy.quote_currency, fn_set_holding.currency+quote_currency)
-- -- Rule of Three: drei reale Konsumenten -> vereinheitlicht statt drei inline-upper(trim()).
--
-- WARUM: der Waehrungs-Input ist ein Roh-Wert ("DB rechnet, LLM-Input roh"). Das LLM nennt
-- currency mal klein ('usd'); ohne Normalisierung verwarf fn_create_account still den {ok:false}
-- von fn_ensure_currency und lief in einen harten FK-RAISE (finance_accounts_currency_fk) + Owner-Alert.
-- Die Formatpruefung bleibt bei fn_ensure_currency (^[A-Z]{3}$); ein echt-ungueltiger Code
-- (z. B. 'US', 'DOLLAR') liefert danach weiterhin {ok:false}, NUR die Gross-/Kleinschreibung
-- wird hier vorab geglaettet.
--
-- STRICT: NULL-Input -> NULL (die Aufrufer COALESCEn danach, z. B. auf 'EUR' bei create_account).
CREATE OR REPLACE FUNCTION finance.fn_normalize_currency(p_code text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT upper(trim(p_code));
$$;
