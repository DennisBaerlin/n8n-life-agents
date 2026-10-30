-- ============================================================
-- fn_bank_export_load (READ, STABLE) -- Bank-Export-Datei laden: Leser + Konto-Waechter + Sub-Konto-Waechter
--   Die EINE Lade-Sequenz fuer Export-Dateien (Bank-Import-Modul): fn_bank_export_normalize (Profil + kanonische
--   Zeilen) -> fn_bank_export_resolve_account (Konto nach Datei-Profil, Waehrungen der Datei) -> mehrere Sub-Konten in
--   einer Datei (N26-Spaces, account_types) -> multiple_sub_accounts. Konsumenten: fn_get_recurring_suggestions,
--   fn_replace_takeover_with_lots, fn_statement_prepare (Datei-Zweig).
--   plpgsql (late-bound): fn_bank_export_normalize/_resolve_account liegen alphabetisch spaeter.
--   Eingabe jsonb: {account_name (optional), table:{rows}}.
--   RUECKGABE: Leser-Rueckgabe (rows, unknown_rows, account_types, currencies, profile, printed_balance, statement?)
--   || {account_id, account_name} | {ok:false, code, reason, ...} (Codes des Lesers bzw. des Konto-Waechters,
--   multiple_sub_accounts + account_types).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_load(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_norm JSONB;
    v_m    JSONB;
BEGIN
    v_norm := finance.fn_bank_export_normalize(COALESCE(p->'table', '{}'::jsonb));
    IF (v_norm->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_norm;
    END IF;
    v_m := finance.fn_bank_export_resolve_account(p->>'account_name', v_norm->>'profile', v_norm->'currencies');
    IF (v_m->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_m;
    END IF;
    IF jsonb_array_length(COALESCE(v_norm->'account_types', '[]'::jsonb)) > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'multiple_sub_accounts', 'account_types', v_norm->'account_types',
            'reason', 'The export mixes several sub-accounts (' || (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(v_norm->'account_types') x)
                   || ') - ask the user to export each account on its own.');
    END IF;
    RETURN v_norm || jsonb_build_object('account_id', (v_m->>'account_id')::int, 'account_name', v_m->>'account_name');
END;
$$;
