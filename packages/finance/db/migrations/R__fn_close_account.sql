-- ============================================================
-- fn_close_account (ATOMIC WRITE)
--   Setzt Kontostatus auf 'closed'. Danach blockiert
--   trg_finance_reject_closed_account jeden neuen INSERT auf dieses Konto.
--   Eingabe jsonb: account_id, closure_date (leer = heute, core.fn_today), notes.
--   GUARD (Audit F6): fn_get_account_close_blockers (EINE Adresse, auch die HITL-Vorpruefung des Tools) --
--   Saldo <> 0, Verrechnungskonto aktiver Depots, Depotbestand, aktive Sparplaene, Kredite, laufende
--   Dauerauftraege (Quelle/Ziel). Vorher verschwand ein Guthaben still aus dem Vermoegen.
--   RUECKGABE-VERTRAG: Erfolg -> {ok:true, account_id, status, effective:{closure_date}} (Datum fuer die Karte). Korrigierbar (Blocker vorhanden) ->
--   {ok:false, reason, blockers, depot_count} OHNE Write (kein RAISE -> kein Owner-Alert). RAISE nur fuer
--   echte Ausnahmen (not-found / already-closed -> vom Tool-Resolve (active_only) schon abgefangen).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_close_account(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_account     finance.accounts%ROWTYPE;
    v_blk         JSONB;
    v_date        DATE := COALESCE(NULLIF(p->>'closure_date', '')::date, core.fn_today());
BEGIN
    SELECT * INTO v_account FROM finance.accounts WHERE id = (p->>'account_id')::int;

    IF v_account.id IS NULL THEN
        RAISE EXCEPTION 'Account % not found.', p->>'account_id';
    END IF;
    IF v_account.status = 'closed' THEN
        RAISE EXCEPTION 'Account % is already closed.', v_account.id;
    END IF;

    -- Korrigierbar: irgendein Blocker (Saldo, Depot, Sparplan, Kredit, Dauerauftrag) -> {ok:false} OHNE Write.
    v_blk := finance.fn_get_account_close_blockers(v_account.id);
    IF (v_blk->>'blocked')::boolean THEN
        RETURN jsonb_build_object('ok', false,
            'reason',      v_blk->>'reason',
            'blockers',    v_blk->'blockers',
            'depot_count', COALESCE((SELECT (e->>'depot_count')::int FROM jsonb_array_elements(v_blk->'blockers') e
                                     WHERE e->>'kind' = 'settlement_for_depot'), 0));
    END IF;

    UPDATE finance.accounts
    SET status = 'closed',
        notes  = CASE
            WHEN NULLIF(p->>'notes', '') IS NOT NULL
            THEN COALESCE(notes || E'\n', '') || '[Geschlossen ' || v_date::text || ': ' || (p->>'notes') || ']'
            ELSE COALESCE(notes || E'\n', '') || '[Geschlossen ' || v_date::text || ']'
        END
    WHERE id = v_account.id;

    RETURN jsonb_build_object('ok', true, 'account_id', v_account.id, 'status', 'closed',
        'effective', jsonb_build_object('closure_date', v_date));
END;
$$;
