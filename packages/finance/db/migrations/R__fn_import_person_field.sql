-- ============================================================
-- fn_import_person_field (READ, IMMUTABLE) -- das EINE Personen-Feld je entity_type (NULL = Typ ohne Person):
--   account/real_estate/pension -> owner_person, insurance -> policyholder_person, loan -> borrower_person,
--   savings_goal -> beneficiary_person (gleiche Namen wie die create_*-Tools). Genutzt von fn_import_resolve_persons
--   (Aufloesung zum Slug), fn_import_card_rows (Personenname auf der Karte) und dem Build-Abgleich der Kartenfelder
--   (packages/finance/build/workflows/hitl_lines.ps1 liest die WHEN-Zeilen dieser Datei).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_person_field(p_type text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_type IN ('account', 'real_estate', 'pension') THEN 'owner_person'
        WHEN p_type = 'insurance'    THEN 'policyholder_person'
        WHEN p_type = 'loan'         THEN 'borrower_person'
        WHEN p_type = 'savings_goal' THEN 'beneficiary_person'
    END;
$$;
