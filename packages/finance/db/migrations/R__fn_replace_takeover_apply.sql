-- ============================================================
-- fn_replace_takeover_apply (INTERNER WRITE-BAUSTEIN, kein Tool) -- Uebernahme-Gruppen durch datierte Lots ersetzen
--   Die EINE Stelle, die "neue Lots buchen -> alte Uebernahme-Gruppe(n) voiden -> Audit stempeln" ausfuehrt.
--   Aufrufer: fn_replace_takeover_with_lots (CSV-/Export-Weg, eine alte Gruppe je Position) und fn_replace_holding_lots
--   (eingetippte Liste, alle Uebernahme-Gruppen einer Position). Plan, Fingerabdruck, Pruefungen und Karte bleiben beim
--   Aufrufer; dieser Baustein bekommt schon geprueft-berechnete Lots und schreibt nur.
--   Bewusst POSITIONALE Argumente, kein jsonb-Payload (kein LLM-/Staging-Zugang, wie fn_book_takeover_pair).
--   Eingabe: p_holding, p_settle (Verrechnungskonto des Depots), p_lots = jsonb-Array [{date, shares, price, fee, cash}]
--   (cash=true: echter Kauf OHNE Gegenbuchung = Cash-Abfluss, nur der Export-Weg fuer Kaeufe nach dem bestaetigten
--   Kontostand-Tag; false: cash-neutrales Uebernahme-Paar), p_old_group_ids = die alten Uebernahme-Gruppen, die vorher
--   ermittelt wurden (VOR dem ersten Write, sonst fiele die neue Gruppe mit hinein), p_label = Kennung fuer den Buchungstext.
--   Ablauf: alle Lots in EINER neuen group_id (ein Write = eine group_id = ein Void) ueber fn_book_takeover_pair; danach
--   je alte Gruppe fn_void_transaction (Audit, Oversell-/Reserve-Guards) und transaction_audit.reason = 'replaced_by_lots',
--   replaced_by_group = neue group_id. Ein Lot, das der Aufrufer nicht vorab geprueft hat, oder ein abgelehntes Void ist
--   ein echter Defekt -> RAISE (Rollback der ganzen Transaktion).
--   RUECKGABE: {group_id, cash_lots_count}
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_replace_takeover_apply(
    p_holding int, p_settle int, p_lots jsonb, p_old_group_ids uuid[], p_label text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_group  UUID := gen_random_uuid();
    v_lot    JSONB;
    v_r      JSONB;
    v_cash_n INT := 0;
    v_old    UUID;
    v_void   JSONB;
BEGIN
    FOR v_lot IN SELECT e FROM jsonb_array_elements(p_lots) e LOOP
        v_r := finance.fn_book_takeover_pair(p_holding, p_settle, (v_lot->>'shares')::numeric,
                   (v_lot->>'price')::numeric, (v_lot->>'fee')::numeric, (v_lot->>'date')::date, v_group,
                   p_label, NOT (v_lot->>'cash')::boolean);
        IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN   -- vorab geprueft: echte Ausnahme
            RAISE EXCEPTION 'fn_replace_takeover_apply: lot of % refused: %', p_label, v_r->>'reason';
        END IF;
        IF (v_lot->>'cash')::boolean THEN v_cash_n := v_cash_n + 1; END IF;
    END LOOP;

    FOREACH v_old IN ARRAY COALESCE(p_old_group_ids, ARRAY[]::uuid[]) LOOP
        v_void := finance.fn_void_transaction(jsonb_build_object('transaction_id',
                      (SELECT min(t.id) FROM finance.transactions t WHERE t.group_id = v_old)));
        IF (v_void->>'ok')::boolean IS DISTINCT FROM true THEN
            RAISE EXCEPTION 'fn_replace_takeover_apply: old takeover of % could not be removed: %', p_label, v_void->>'reason';
        END IF;
        UPDATE finance.transaction_audit a SET reason = 'replaced_by_lots', replaced_by_group = v_group
        WHERE a.transaction_id IN (SELECT (x)::int FROM jsonb_array_elements_text(v_void->'transaction_ids') x)
          AND a.reason IS NULL
          AND a.id IN (SELECT max(b.id) FROM finance.transaction_audit b
                       WHERE b.transaction_id IN (SELECT (x)::int FROM jsonb_array_elements_text(v_void->'transaction_ids') x)
                       GROUP BY b.transaction_id);
    END LOOP;

    RETURN jsonb_build_object('group_id', v_group, 'cash_lots_count', v_cash_n);
END;
$$;
