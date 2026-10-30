-- ============================================================
-- fn_bank_export_resolve_account (READ, STABLE) -- Konto einer Bank-Export-Datei (Konto-Waechter)
--   Live-Befund 2026-10-30: der Agent riet zu einer Trade-Republic-Datei ein Bondora-Konto. Die EINE Konto-Aufloesung
--   fuer Bank-Export-Dateien (fn_statement_prepare source:'file', fn_replace_takeover_with_lots) - nie der Prompt.
--   Kandidaten = aktive, buchbare Konten (fn_bookable_account_reason NULL: nie Depot/Kredit) mit dem Datei-Profil
--   (fn_bank_export_account_profile = p_profile) in einer Waehrung des Exports (p_currencies leer = jede), nach id.
--   Ohne account_name: genau 1 Kandidat -> dieses Konto; mehrere -> account_ambiguous; keiner -> account_unknown.
--   Mit account_name: fn_resolve_account (account_unknown/account_ambiguous wie bisher), nicht buchbar -> not_bookable,
--   andere Waehrung als der Export -> currency_mismatch, anderes Profil -> export_account_mismatch. Ein Konto OHNE Profil gilt nur, wenn sein Bank-Feld leer ist UND kein
--   Kandidat existiert (sonst waere ein geratenes Konto wieder buchbar); eine eingetragene andere Bank weist immer ab.
--   Nur Datei-Wege: der gedruckte Auszug (IBAN/Name) laeuft nie hier durch.
--   plpgsql (late-bound): fn_bookable_account_reason / fn_resolve_account liegen alphabetisch spaeter.
--   RUECKGABE: {ok:true, account_id, account_name}
--   | {ok:false, code, reason, bank (Bank der Datei), account_name?, candidates[{id,name,bank,account_type,status}]}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_export_resolve_account(p_account_name text, p_profile text,
                                                                 p_currencies jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_bank   TEXT;
    v_cand   JSONB;
    v_names  TEXT;
    v_res    RECORD;
    v_acct   finance.accounts%ROWTYPE;
    v_prof   TEXT;
    v_reason TEXT;
BEGIN
    SELECT pr->>'bank' INTO v_bank FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr WHERE pr->>'key' = p_profile;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'bank', a.bank,
                                                 'account_type', a.account_type, 'status', a.status) ORDER BY a.id), '[]'::jsonb),
           string_agg('"' || a.name || '"', ', ' ORDER BY a.id)
    INTO v_cand, v_names
    FROM finance.accounts a
    WHERE a.status = 'active'
      AND finance.fn_bank_export_account_profile(a.id) = p_profile
      AND finance.fn_bookable_account_reason(a.id) IS NULL
      AND (jsonb_array_length(COALESCE(p_currencies, '[]'::jsonb)) = 0
           OR a.currency IN (SELECT jsonb_array_elements_text(p_currencies)));

    IF NULLIF(trim(p_account_name), '') IS NULL THEN
        IF jsonb_array_length(v_cand) = 1 THEN
            RETURN jsonb_build_object('ok', true, 'account_id', (v_cand->0->>'id')::int, 'account_name', v_cand->0->>'name');
        END IF;
        RETURN jsonb_build_object('ok', false,
            'code', CASE WHEN jsonb_array_length(v_cand) = 0 THEN 'account_unknown' ELSE 'account_ambiguous' END,
            'bank', v_bank, 'candidates', v_cand,
            'reason', CASE WHEN jsonb_array_length(v_cand) = 0
                THEN 'This is a ' || v_bank || ' export, but no active ' || v_bank || ' account is known - ask the user which '
                     || 'existing account it belongs to or whether to create one.'
                ELSE 'This is a ' || v_bank || ' export and several accounts fit (' || v_names || ') - ask the user which one, '
                     || 'then call again with account_name.' END);
    END IF;

    SELECT * INTO v_res FROM finance.fn_resolve_account(trim(p_account_name), NULL, TRUE);
    IF v_res.hit_count <> 1 THEN
        RETURN jsonb_build_object('ok', false,
            'code', CASE WHEN v_res.hit_count = 0 THEN 'account_unknown' ELSE 'account_ambiguous' END,
            'bank', v_bank, 'reason', 'No unique active account named "' || trim(p_account_name) || '".',
            'candidates', CASE WHEN v_res.hit_count = 0 THEN v_cand ELSE v_res.candidates END);
    END IF;
    SELECT * INTO v_acct FROM finance.accounts WHERE id = v_res.id;

    v_reason := finance.fn_bookable_account_reason(v_acct.id);
    IF v_reason IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_bookable', 'bank', v_bank, 'account_name', v_acct.name,
            'candidates', v_cand,
            'reason', v_reason || CASE WHEN v_names IS NOT NULL
                                       THEN ' This ' || v_bank || ' export belongs to ' || v_names || '.' ELSE '' END);
    END IF;

    -- Waehrung wie bei den Kandidaten (Review 2026-10-30): sonst ersetzte der Lots-Weg EUR-Kaeufe gegen ein USD-Konto,
    -- bevor die Prepare die Waehrung prueft
    IF jsonb_array_length(COALESCE(p_currencies, '[]'::jsonb)) > 0
       AND v_acct.currency NOT IN (SELECT jsonb_array_elements_text(p_currencies)) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'currency_mismatch', 'bank', v_bank, 'account_name', v_acct.name,
            'candidates', v_cand,
            'reason', 'The export contains amounts in another currency than the account "' || v_acct.name
                   || '" (' || v_acct.currency || ').' || CASE WHEN v_names IS NOT NULL
                                                             THEN ' It fits ' || v_names || '.' ELSE '' END);
    END IF;

    v_prof := finance.fn_bank_export_account_profile(v_acct.id);
    IF v_prof IS DISTINCT FROM p_profile
       AND (v_prof IS NOT NULL OR NULLIF(trim(v_acct.bank), '') IS NOT NULL OR jsonb_array_length(v_cand) > 0) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'export_account_mismatch', 'bank', v_bank,
            'account_name', v_acct.name, 'candidates', v_cand,
            'reason', 'This file is a ' || v_bank || ' export, but the account "' || v_acct.name || '" is '
                   || COALESCE('kept at ' || NULLIF(trim(v_acct.bank), ''), 'not a ' || v_bank || ' account') || '. '
                   || CASE WHEN v_names IS NOT NULL THEN 'It fits ' || v_names || ' - ask the user which account it belongs to. '
                           ELSE 'Ask the user which account it belongs to. ' END
                   || 'Never guess the account. If the bank of an account is entered wrongly, fix it with tool_set_account (bank).');
    END IF;
    RETURN jsonb_build_object('ok', true, 'account_id', v_acct.id, 'account_name', v_acct.name);
END;
$$;
