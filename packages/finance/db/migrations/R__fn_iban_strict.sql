-- ============================================================
-- fn_iban_strict (READ, IMMUTABLE) -- ist p eine echte, lernbare IBAN? ("Import zuerst", IBAN-Lernen)
--   TRUE nur bei IBAN-Form (^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$ nach Grossschrift ohne Leerraum), nicht mit X maskiert
--   und stimmender Pruefziffer (mod 97 = fn_iban_valid). NULL/leer -> FALSE.
--   Abgrenzung: fn_iban_valid (Init-Baseline) laesst Nicht-IBANs bewusst durch (Kopf-Nummer eines Auszugs darf eine
--   Kartennummer sein, eine Depot-/P2P-Nummer ist keine IBAN) und prueft nur die Pruefziffer IBAN-foermiger Werte.
--   Wer eine Gegen-IBAN lernt oder als Schluessel erkennt, braucht diese strenge Form (Plan-Review 2026-10-30).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_iban_strict(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(n ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$' AND n !~ 'XXX' AND finance.fn_iban_valid(n), false)
    FROM (SELECT upper(regexp_replace(p, '\s', '', 'g')) AS n) x;
$$;
