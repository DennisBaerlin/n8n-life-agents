-- ============================================================
-- fn_default_beneficiary (READ — Begünstigte Person eines Sparplans/Sparziels; DB leitet ab, nie das LLM)
--   Genannte Person (Slug, im Tool aufgeloest) gewinnt; ohne Nennung der Inhaber des tragenden Kontos
--   (Sparplan: Depot, Sparziel: Spartopf = reserve_account_id). Gemeinsames Konto (owner_person_id NULL) -> NULL
--   = Haushalt. Live-Befund 2026-10-24: ein Plan im Depot einer Person landete still als "Haushalt".
--   Genutzt von fn_create_savings_plan, fn_create_savings_goal (auch im Import-Pfad) und der Import-Karte.
--   Bekannte Luecke (wie fn_set_account): ein explizites "Haushalt" auf einem Personen-Konto ist nicht waehlbar.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_default_beneficiary(p_named text, p_account_id int)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT COALESCE(NULLIF(p_named, ''),
                    (SELECT a.owner_person_id FROM finance.accounts a WHERE a.id = p_account_id));
$$;
