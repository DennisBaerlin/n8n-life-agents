-- ============================================================
-- fn_insurance_register (READ — Provider-Lesefenster fuers Nachlass-Register)
--   Publizierte, provider-eigene Lese-fn (docs/package-contract.md "Cross-package reads / provides.reads"):
--   liefert die aktiven Policen mit den nachlass-relevanten Feldern, aus denen der estate-
--   Renderer/die estate-Gap-Analyse ableitet, welche Policen eine Klasse/Bezugsberechtigten/
--   Versicherungssumme/AVB-Meldefrist tragen und welche im Todesfall auszahlen. finance besitzt die
--   Daten (Produkt-Attribute), estate referenziert nur.
--
--   Plain STABLE, kein SECURITY DEFINER, kein Grant: estate liest sie nicht unter estate_ro, sondern der
--   estate-Renderer ruft sie render-at-fetch im core.fn_fetch_context-DEFINER-Kontext (Owner=Superuser)
--   auf -> Schema-Read ohne neuen Grant. Die Call-Site doppel-guardet (fn_package_active('finance') +
--   to_regprocedure) -> finance absent = graceful NULL (optionale Dependency, requires bleibt leer).
--
--   RAISE-frei + COALESCE'd: laeuft im Render-Fetch -> ein RAISE braeche den ganzen load_context-Abruf ab.
--   Leere/keine aktive Police -> '[]'::jsonb (nie NULL). status::text (ENUM -> Text, stabile Anzeige).
--
--   Eingabe: keine. Rueckgabe jsonb-Array je aktiver Police: { id, name, insurance_company, insurance_type, policy_number,
--   beneficiary, coverage_amount, claim_deadline_hours, policyholder_person_id, status }.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_insurance_register()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',                     id,
        'name',                   name,
        'insurance_company',      insurance_company,
        'insurance_type',         insurance_type,
        'policy_number',          policy_number,
        'beneficiary',            beneficiary,
        'coverage_amount',        coverage_amount,
        'claim_deadline_hours',   claim_deadline_hours,
        'policyholder_person_id', policyholder_person_id,
        'status',                 status::text
    ) ORDER BY name), '[]'::jsonb)
    FROM finance.insurances
    WHERE status = 'active';
$$;
