-- ============================================================
-- fn_default_beneficiary (READ — Begünstigte Person eines Sparplans/Sparziels)
--   Eingabe: p_named (Personen-Slug, im Tool aufgeloest; leer/NULL = nicht genannt), p_account_id (tragendes Konto:
--   Sparplan = Depot, Sparziel = Spartopf reserve_account_id).
--   Rueckgabe: p_named, sonst owner_person_id des Kontos; gemeinsames Konto (owner_person_id NULL) -> NULL = Haushalt.
--   Genutzt von fn_create_savings_plan, fn_create_savings_goal (auch im Import-Pfad) und der Import-Karte.
--   Grenzfall (wie fn_set_account): ein explizites "Haushalt" auf einem Personen-Konto ist nicht waehlbar.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_default_beneficiary(p_named text, p_account_id int)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT COALESCE(NULLIF(p_named, ''),
                    (SELECT a.owner_person_id FROM finance.accounts a WHERE a.id = p_account_id));
$$;
