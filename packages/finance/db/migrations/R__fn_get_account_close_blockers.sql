-- ============================================================
-- fn_get_account_close_blockers (READ) -- was das Schliessen eines Kontos verhindert (Audit F6)
--   EINE Adresse fuer die HITL-Vorpruefung in tool_close_account (read-only, Tool-Cred finance_rw; auch unter
--   finance_ro lesbar; VOR der Bestaetigungskarte) UND den Guard in fn_close_account. Vorher liess sich ein Konto mit Guthaben schliessen
--   (das Geld verschwand aus dem Vermoegen: Views zaehlen nur aktive Konten) und laufende Dauerauftraege feuerten
--   danach taeglich den Closed-Konto-Trigger (Owner-Alarm).
--   Blocker-Arten (kind): balance (Saldo <> 0) · settlement_for_depot (Verrechnungskonto aktiver Depots) ·
--   depot_holdings (Depot mit Bestand; ein Depot-Saldo ist immer 0) · savings_plans (aktive/pausierte Sparplaene
--   auf dem Depot) · loans (aktiver/pausierter Kredit mit diesem Konto als Kredit- oder Belastungskonto) ·
--   recurring_payments (Dauerauftraege mit diesem Konto als Quelle/Ziel, die noch laufen koennen -- status
--   active/paused und valid_to offen oder in der Zukunft, auch kuenftige und pausierte -- ODER schon beendet
--   sind, aber noch eine offene Rate im Erinnerungsfenster haben; sonst greift spaeter der Closed-Konto-Trigger).
--   RUECKGABE: {blocked, blockers:[{kind, ...details}], reason (EN, fuer den Nutzer erklaerbar)}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_get_account_close_blockers(p_account_id int)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_bal      NUMERIC;
    v_ccy      TEXT;
    v_blockers JSONB := '[]'::jsonb;
    v_cnt      INT;
    v_names    JSONB;
BEGIN
    SELECT COALESCE(b.balance, 0), a.currency INTO v_bal, v_ccy
    FROM finance.accounts a
    LEFT JOIN finance.account_balances b ON b.account_id = a.id
    WHERE a.id = p_account_id;

    IF v_bal <> 0 THEN
        v_blockers := v_blockers || jsonb_build_object('kind', 'balance', 'balance', v_bal, 'currency', v_ccy);
    END IF;

    SELECT count(*) INTO v_cnt FROM finance.accounts
    WHERE settlement_account_id = p_account_id AND status = 'active';
    IF v_cnt > 0 THEN
        v_blockers := v_blockers || jsonb_build_object('kind', 'settlement_for_depot', 'depot_count', v_cnt);
    END IF;

    SELECT count(*) INTO v_cnt FROM finance.depot_holdings WHERE account_id = p_account_id AND shares > 0;
    IF v_cnt > 0 THEN
        v_blockers := v_blockers || jsonb_build_object('kind', 'depot_holdings', 'holding_count', v_cnt);
    END IF;

    SELECT jsonb_agg(name ORDER BY name) INTO v_names FROM finance.savings_plans
    WHERE depot_id = p_account_id AND status IN ('active', 'paused');   -- pausiert kann wieder anlaufen
    IF v_names IS NOT NULL THEN
        v_blockers := v_blockers || jsonb_build_object('kind', 'savings_plans', 'names', v_names);
    END IF;

    SELECT jsonb_agg(name ORDER BY name) INTO v_names FROM finance.loans
    WHERE (loan_account_id = p_account_id OR debit_account_id = p_account_id)
      AND status IN ('active', 'paused');
    IF v_names IS NOT NULL THEN
        v_blockers := v_blockers || jsonb_build_object('kind', 'loans', 'names', v_names);
    END IF;

    SELECT jsonb_agg(name ORDER BY name) INTO v_names FROM finance.recurring_payments r
    WHERE (r.account_id = p_account_id OR r.target_account_id = p_account_id)
      AND (   (r.status IN ('active', 'paused') AND (r.valid_to IS NULL OR r.valid_to > CURRENT_DATE))
           OR EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE) o   -- beendet, Rate aber noch offen
                      WHERE o.recurring_payment_id = r.id));
    IF v_names IS NOT NULL THEN
        v_blockers := v_blockers || jsonb_build_object('kind', 'recurring_payments', 'names', v_names);
    END IF;

    RETURN jsonb_build_object(
        'blocked',  jsonb_array_length(v_blockers) > 0,
        'blockers', v_blockers,
        'reason',   CASE WHEN jsonb_array_length(v_blockers) = 0 THEN NULL ELSE
            'This account cannot be closed yet: '
            || (SELECT string_agg(CASE e->>'kind'
                    WHEN 'balance'              THEN 'it still holds a balance of ' || (e->>'balance') || ' ' || (e->>'currency')
                                                     || ' (transfer it out first)'
                    WHEN 'settlement_for_depot' THEN 'it is the settlement account for ' || (e->>'depot_count')
                                                     || ' active depot(s) (close or re-link the depot first)'
                    WHEN 'depot_holdings'       THEN 'the depot still holds ' || (e->>'holding_count') || ' position(s) (sell or move them first)'
                    WHEN 'savings_plans'        THEN 'savings plan(s) still run on it (active or paused; close them first): ' || (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(e->'names') x)
                    WHEN 'loans'                THEN 'it is used by loan(s): ' || (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(e->'names') x)
                    WHEN 'recurring_payments'   THEN 'recurring payment(s) still use it: ' || (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(e->'names') x)
                                                     || ' (end or move them first)'
                END, '; ')
                FROM jsonb_array_elements(v_blockers) e)
            || '.' END);
END;
$$;
