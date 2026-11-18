-- ============================================================
-- fn_bank_export_facts (READ, STABLE) -- was eine Tabellen-Datei ist, bevor das Modell sie sieht
--   Vorab-Ergebnis fuer agent.finance (tool_get_bank_export_facts): nur die Fakten, die das Modell sonst raten wuerde.
--   Datei-Fakten aus fn_bank_export_normalize, Konto bzw. Kandidaten aus fn_bank_export_load ohne Kontoname (die Wahl
--   der DB; nennt der Nutzer ein Konto, entscheidet der Import), bestaetigt bis aus fn_account_confirmed_until.
--   Nie Zeilen-Inhalte (Gegenpart, Zweck, Einzelbetrag) und nie N26-Space-Namen: das Ergebnis geht in den System-Prompt.
--   plpgsql (late-bound): fn_bank_export_load/_normalize/_profiles liegen alphabetisch spaeter.
--   Eingabe jsonb: {table:{rows}}.
--   Rueckgabe: {ok:true, recognised:false, code} (kein Profil, unlesbar)
--   | {ok:true, recognised:true, profile, bank, account_name|null, account_code|null (account_unknown|
--   account_ambiguous|multiple_sub_accounts|...), candidates[Namen], covered_until|null, date_from, date_to, row_count}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_facts(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_norm JSONB;
    v_load JSONB;
    v_ok   BOOLEAN;
BEGIN
    v_norm := finance.fn_bank_export_normalize(COALESCE(p->'table', '{}'::jsonb));
    IF (v_norm->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN jsonb_build_object('ok', true, 'recognised', false, 'code', v_norm->>'code');
    END IF;
    v_load := finance.fn_bank_export_load(jsonb_build_object('table', p->'table'));
    v_ok := (v_load->>'ok')::boolean IS DISTINCT FROM false;
    RETURN jsonb_build_object(
        'ok', true, 'recognised', true,
        'profile', v_norm->>'profile',
        'bank', (SELECT pr->>'bank' FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr
                 WHERE pr->>'key' = v_norm->>'profile'),
        'account_name', CASE WHEN v_ok THEN v_load->>'account_name' END,
        'account_code', CASE WHEN v_ok THEN NULL ELSE v_load->>'code' END,
        'candidates', CASE WHEN v_ok THEN '[]'::jsonb
                           ELSE COALESCE((SELECT jsonb_agg(c->>'name' ORDER BY c->>'name')
                                          FROM jsonb_array_elements(COALESCE(v_load->'candidates', '[]'::jsonb)) c), '[]'::jsonb) END,
        'covered_until', CASE WHEN v_ok THEN finance.fn_account_confirmed_until((v_load->>'account_id')::int) END,
        'date_from', (SELECT min((r->>'date')::date) FROM jsonb_array_elements(v_norm->'rows') r),
        'date_to', (SELECT max((r->>'date')::date) FROM jsonb_array_elements(v_norm->'rows') r),
        'row_count', jsonb_array_length(COALESCE(v_norm->'rows', '[]'::jsonb)));
END;
$$;
