-- ============================================================
-- fn_set_account (ATOMIC WRITE)
--   Aendert Konto-STAMMDATEN (partielles Update: nur uebergebene, nicht-leere Felder;
--   "nicht gesendet = unveraendert" via COALESCE(NULLIF(...), spalte)).
--   BEWUSST NICHT aenderbar: account_type (haengt an depot-needs-settlement-CHECK,
--   loan=negativ, depot=keine Tx), currency (Betraege sind nativ gespeichert -> retroaktiv
--   Korruption), status (-> fn_close_account), last_reconciled_* (-> fn_reconcile_account).
--   Eingabe jsonb: account_id (im n8n via fn_resolve_account aufgeloest), name, bank,
--   account_number, owner_person_id (Slug, im Tool aufgeloest; leer=unveraendert), notes,
--   fixed_deposit_maturity_date, fixed_deposit_auto_renew, ownership/has_transmortal_poa (WS-0b estate:
--   Nachlass-Attribute, geschlossene ownership-Liste per CHECK; leer=unveraendert).
--   Kontonummer (Monats-Check WP-B) in der Normalform fn_normalize_account_number; schon bei einem ANDEREN aktiven
--   Konto vergeben -> {ok:false, reason} ohne Write (UNIQUE-Index = Backstop). remove_account_number = true entfernt die
--   Nummer ("Import zuerst": Korrekturweg fuer eine falsch zugeordnete bzw. gelernte IBAN, die sonst beim richtigen Konto
--   als Dublette abgelehnt wuerde); zusammen mit account_number -> {ok:false, code:'conflicting_input'}.
--   settlement_id (im Tool aufgeloest; leer=unveraendert): Verrechnungskonto, Pruefung fn_settlement_account_reason
--   (nur Depot/P2P; P2P = das Girokonto, auf das der Anbieter auszahlt, Bank-Import-Modul) -> sonst {ok:false, reason}.
--   Bankwechsel setzt den Depot-Kalender accounts.plan_execution_days zurueck (NULL = unbekannt): er beschreibt die
--   Ausfuehrungstage der ALTEN Bank (fn_resolve_plan_schedule belegt neu vor bzw. fragt einmal nach).
--   RUECKGABE: {ok:true, account_id}. RAISE nur bei not-found (Resolve haette greifen muessen).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_set_account(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id     INT  := (p->>'account_id')::int;
    v_number TEXT := finance.fn_normalize_account_number(p->>'account_number');
    v_taken  TEXT;
    v_dates  JSONB;
    v_settle INT;
    v_remove BOOLEAN := COALESCE(NULLIF(p->>'remove_account_number', '')::boolean, false);
BEGIN
    -- relative Datumsangabe ("in 2 years") -> ISO; nicht aufloesbar -> {ok:false, code:'invalid_date'}
    v_dates := core.fn_resolve_input_dates(p, ARRAY['fixed_deposit_maturity_date']);
    IF NOT (v_dates->>'ok')::boolean THEN RETURN v_dates; END IF;
    p := v_dates->'p';
    IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_id) THEN
        RAISE EXCEPTION 'Account % not found.', v_id;
    END IF;

    IF v_remove AND v_number IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'conflicting_input',
            'reason', 'Either set a new account number or remove it - not both in one call.');
    END IF;

    -- S7: eine IBAN-foermige Nummer muss ihre Pruefziffer bestehen (Spiegel-CHECK finance_accounts_iban_chk)
    IF NOT finance.fn_iban_valid(v_number) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_iban',
            'reason', 'The IBAN ' || v_number || ' has wrong check digits - a digit is probably mistyped; ask the user to check it.');
    END IF;

    SELECT name INTO v_taken FROM finance.accounts
    WHERE account_number = v_number AND status = 'active' AND id <> v_id;
    IF v_taken IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'The account number ' || v_number || ' already belongs to the account "' || v_taken || '".');
    END IF;

    -- Verrechnungskonto (Bank-Import-Modul): nur Depot/P2P, dieselbe Pruefung wie fn_create_account
    v_settle := NULLIF(p->>'settlement_id', '')::int;
    SELECT finance.fn_settlement_account_reason(a.account_type::text, a.currency, v_settle, a.id) INTO v_taken
    FROM finance.accounts a WHERE a.id = v_id;
    IF v_taken IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', v_taken);
    END IF;

    UPDATE finance.accounts SET
        name                        = COALESCE(NULLIF(p->>'name', ''), name),
        bank                        = COALESCE(NULLIF(p->>'bank', ''), bank),
        -- Depot-Kalender gehoert zur Bank: neue Bank -> vergessen (neu vorbelegt bzw. beim naechsten Sparplan erfragt)
        plan_execution_days         = CASE WHEN NULLIF(p->>'bank', '') IS NOT NULL
                                                AND p->>'bank' IS DISTINCT FROM bank
                                           THEN NULL ELSE plan_execution_days END,
        account_number              = CASE WHEN v_remove THEN NULL ELSE COALESCE(v_number, account_number) END,
        settlement_account_id       = COALESCE(v_settle, settlement_account_id),
        owner_person_id             = COALESCE(NULLIF(p->>'owner_person_id', ''), owner_person_id),  -- WS-4: typisierter Eigentuemer (Slug); leer=unveraendert (Un-Tag->BACKLOG)
        notes                       = COALESCE(NULLIF(p->>'notes', ''), notes),
        fixed_deposit_maturity_date = COALESCE(NULLIF(p->>'fixed_deposit_maturity_date', '')::date, fixed_deposit_maturity_date),
        fixed_deposit_auto_renew    = COALESCE(NULLIF(p->>'fixed_deposit_auto_renew', '')::boolean, fixed_deposit_auto_renew),
        -- WS-0b (estate): Nachlass-Attribute (leer=unveraendert; ownership-CHECK = geschlossene-Liste-Backstop).
        ownership                   = COALESCE(NULLIF(p->>'ownership', ''), ownership),
        has_transmortal_poa         = COALESCE(NULLIF(p->>'has_transmortal_poa', '')::boolean, has_transmortal_poa)
    WHERE id = v_id;

    RETURN jsonb_build_object('ok', true, 'account_id', v_id, 'effective', v_dates->'resolved');
END;
$$;
