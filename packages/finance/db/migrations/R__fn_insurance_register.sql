-- ============================================================
-- finance.fn_insurance_register (WS-0b estate — Provider-Lesefenster fuers Nachlass-Register)
--   Publizierte, provider-eigene Lese-fn (docs/package-contract.md "Cross-package reads / provides.reads",
--   Oberflaeche A): liefert die AKTIVEN Policen mit den nachlass-relevanten Feldern, aus denen der estate-
--   Renderer/die estate-Gap-Analyse (WS-1/2) ableitet, welche Policen eine Klasse/Bezugsberechtigten/
--   Versicherungssumme/AVB-Meldefrist tragen und welche im Todesfall auszahlen. finance BESITZT die
--   Daten (Produkt-Attribute), estate referenziert nur.
--
--   PLAIN STABLE, KEIN SECURITY DEFINER, KEIN Grant: estate liest sie NICHT unter estate_ro, sondern der
--   estate-Renderer ruft sie render-at-fetch IM core.fn_fetch_context-DEFINER-Kontext (Owner=Superuser)
--   auf -> Schema-Read OHNE neuen Grant. Die Call-Site doppel-guardet (fn_package_active('finance') +
--   to_regprocedure) -> finance absent = graceful NULL (optionale Dependency, requires bleibt leer).
--
--   RAISE-FREI + COALESCE'd: laeuft IM Render-Fetch -> ein RAISE braeche den ganzen load_context-Abruf ab.
--   Leere/keine aktive Police -> '[]'::jsonb (nie NULL). status::text (ENUM -> Text, stabile Anzeige).
--
--   RUECKGABE jsonb-ARRAY je aktiver Police: { id, name, insurance_company, insurance_type, policy_number,
--   beneficiary, coverage_amount, claim_deadline_hours, policyholder_person_id, status }.
--   Anwenden via: db_apply.ps1 -File packages\finance\db\migrations\R__fn_insurance_register.sql
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
