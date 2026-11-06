-- privacy_terms.sql -- liest die Werte, die nie ins oeffentliche Repo duerfen, als (art, wert) aus einer Instanz.
-- Nur lesend: scripts/refresh_privacy_denylist.ps1 faehrt die Datei mit default_transaction_read_only = on und schreibt das
-- Ergebnis allein nach .local/ im Haupt-Checkout. Spalten-Drift faengt tests/db/cross/test_privacy_terms_source.sql.
-- Bewusst NICHT: Namen von Konten, Vertraegen und Zielen (Alltagswoerter wie "Miete"), Banken, Betraege einzelner Buchungen,
-- glatte Raten (eine ganze Zahl traefe zu oft; die findet nur die Modell-Pruefung).
-- Arten: name, date, id, text, amount.

SELECT kind, value
FROM (
    SELECT 'name' AS kind, v AS value
    FROM agent.core_contexts c
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(c.metadata -> 'facts' -> 'persons') = 'array'
             THEN c.metadata -> 'facts' -> 'persons' ELSE '[]'::jsonb END) p
    CROSS JOIN LATERAL (VALUES (p ->> 'first_name'), (p ->> 'last_name'),
                               (concat_ws(' ', p ->> 'first_name', p ->> 'last_name'))) x (v)
    WHERE c.name = 'family'
    UNION ALL
    SELECT 'date', p ->> 'birth_date'
    FROM agent.core_contexts c
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(c.metadata -> 'facts' -> 'persons') = 'array'
             THEN c.metadata -> 'facts' -> 'persons' ELSE '[]'::jsonb END) p
    WHERE c.name = 'family'
    UNION ALL
    SELECT 'text', v
    FROM agent.core_contexts c
    CROSS JOIN LATERAL (VALUES (c.metadata -> 'facts' ->> 'current_title'),
                               (c.metadata -> 'facts' ->> 'industry')) x (v)
    WHERE c.name LIKE 'career\_profile\_\_%'
    UNION ALL
    SELECT 'text', r ->> 'title'
    FROM agent.core_contexts c
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(c.metadata -> 'facts' -> 'target_roles') = 'array'
             THEN c.metadata -> 'facts' -> 'target_roles' ELSE '[]'::jsonb END) r
    WHERE c.name LIKE 'career\_planning\_\_%'
    UNION ALL
    SELECT 'text', l #>> '{}'
    FROM agent.core_contexts c
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(c.metadata -> 'facts' -> 'target_locations') = 'array'
             THEN c.metadata -> 'facts' -> 'target_locations' ELSE '[]'::jsonb END) l
    WHERE c.name LIKE 'career\_planning\_\_%'
) core_terms
WHERE value IS NOT NULL AND trim(value) <> '';

SELECT to_regclass('finance.accounts') IS NOT NULL AS has_finance \gset
\if :has_finance
SELECT kind, value
FROM (
    SELECT 'id' AS kind, account_number::text AS value FROM finance.accounts
    UNION ALL SELECT 'id', policy_number::text FROM finance.insurances
    UNION ALL SELECT 'id', contract_number::text FROM finance.pension
    UNION ALL SELECT 'amount', abs(balance)::text FROM finance.account_balances
        WHERE abs(balance) >= 100 AND balance <> trunc(balance)
    UNION ALL SELECT 'amount', shares::text FROM finance.depot_holdings
        WHERE shares > 0 AND shares <> round(shares, 2)
    UNION ALL SELECT 'amount', average_purchase_price::text FROM finance.depot_holdings
        WHERE average_purchase_price >= 1 AND average_purchase_price <> trunc(average_purchase_price)
    UNION ALL SELECT 'amount', current_value::text FROM finance.pension
        WHERE current_value <> trunc(current_value)
    UNION ALL SELECT 'amount', abs(amount)::text FROM finance.recurring_payments
        WHERE abs(amount) >= 100 AND amount <> trunc(amount)
    UNION ALL SELECT 'amount', original_amount::text FROM finance.loans
        WHERE original_amount <> trunc(original_amount) OR original_amount % 1000 <> 0
    UNION ALL SELECT 'date', interest_rate_fixed_until::text FROM finance.loans
    UNION ALL SELECT 'date', term_end_date::text FROM finance.loans
    UNION ALL SELECT 'date', disbursement_date::text FROM finance.loans
) finance_terms
WHERE value IS NOT NULL AND trim(value) <> '';
\endif

SELECT to_regclass('estate.contacts') IS NOT NULL AS has_estate \gset
\if :has_estate
SELECT kind, value
FROM (
    SELECT 'name' AS kind, name AS value FROM estate.contacts
    UNION ALL SELECT 'id', phone FROM estate.contacts
    UNION ALL SELECT 'text', email FROM estate.contacts
    UNION ALL SELECT 'text', address FROM estate.contacts
    UNION ALL SELECT 'id', customer_no FROM estate.provider_contracts
    UNION ALL SELECT 'id', contract_no FROM estate.provider_contracts
    UNION ALL SELECT 'text', username FROM estate.digital_accounts
    UNION ALL SELECT 'id', tax_id FROM estate.person_records
    UNION ALL SELECT 'id', pension_insurance_no FROM estate.person_records
    UNION ALL SELECT 'id', health_insurance_no FROM estate.person_records
    UNION ALL SELECT 'text', employer FROM estate.person_records
) estate_terms
WHERE value IS NOT NULL AND trim(value) <> '';
\endif
