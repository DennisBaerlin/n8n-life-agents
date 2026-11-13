-- ============================================================
-- fn_account_register (READ, STABLE) -- Provider-Lesefenster fuers Nachlass-Register
--   Publizierte, provider-eigene Lese-fn (docs/package-contract.md "Cross-package reads / provides.reads"):
--   liefert die aktiven Konten (ohne Loan-Konten — die deckt fn_liability_register) mit den
--   nachlass-relevanten Zugriffs-Attributen (ownership, has_transmortal_poa), aus denen der estate-Agent
--   ableitet, welche Konten die Erben erreichen muessen und wo ein Oder-Konto/eine transmortale
--   Vollmacht den Zugriff beschleunigt. finance besitzt die Daten, estate referenziert nur. Keine Eingabe.
--
--   Plain STABLE, kein SECURITY DEFINER, kein Grant: gelesen render-at-fetch im core.fn_fetch_context-
--   DEFINER (Owner=Superuser) -> kein neuer Grant. Call-Site doppel-guardet (fn_package_active('finance')
--   + to_regprocedure) -> finance absent = graceful NULL.
--
--   RAISE-frei + COALESCE'd (laeuft im Render-Fetch). Leere/keine aktiven Konten -> '[]'::jsonb (nie NULL).
--   account_type='loan' bewusst ausgeschlossen (Verbindlichkeit, nicht zugriffs-relevantes Guthaben-Konto).
--
--   Rueckgabe jsonb-Array je aktivem Nicht-Loan-Konto: { id, name, account_type, bank, account_number,
--   owner_person_id, ownership, has_transmortal_poa, currency, status }.
--   Tests: tests/db/finance/test_fn_account_register.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_register()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',                  id,
        'name',                name,
        'account_type',        account_type::text,
        'bank',                bank,
        'account_number',      account_number,
        'owner_person_id',     owner_person_id,
        'ownership',           ownership,
        'has_transmortal_poa', has_transmortal_poa,
        'currency',            currency,
        'status',              status::text
    ) ORDER BY name), '[]'::jsonb)
    FROM finance.accounts
    WHERE status = 'active' AND account_type <> 'loan';
$$;
