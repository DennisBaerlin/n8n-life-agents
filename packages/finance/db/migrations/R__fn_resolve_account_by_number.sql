-- ============================================================
-- fn_resolve_account_by_number (READ) -- Konto-Zuordnung eines Kontoauszugs (Monats-Check WP-B)
--   Loest eine gedruckte Kontonummer/IBAN in ein AKTIVES Konto auf (Spiegel zu fn_resolve_account fuer Namen).
--   1. exakt in der Normalform fn_normalize_account_number (Leerzeichen/Gross-Klein egal),
--   2. sonst Fallback LETZTE 4 STELLEN (Kreditkarten-Auszuege drucken nur eine maskierte Nummer "XXXX ... 4711"),
--      nur fuer cash-Konten, nur bei genau einem Treffer und NUR wenn die gedruckte Nummer maskiert ist (Folge von
--      X/*/Punkten oder hoechstens 6 Ziffern) — eine vollstaendige fremde IBAN mit zufaellig gleichen Endziffern ist
--      ein neues Konto (account_unknown), nie ein Treffer.
--   RUECKGABE: TABLE(id, hit_count, candidates) — id nur bei genau einem Treffer; candidates = [{id,name,bank,
--   account_type}] der Treffer (bei 0 Treffern: aktive cash-Konten OHNE Kontonummer = die Kandidaten, denen der
--   Nutzer die Nummer zuordnen kann).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_resolve_account_by_number(p_number text)
RETURNS TABLE (id int, hit_count int, candidates jsonb)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_norm  TEXT := finance.fn_normalize_account_number(p_number);
    v_last4 TEXT := right(regexp_replace(COALESCE(p_number, ''), '\D', '', 'g'), 4);
    v_ids   INT[];
    v_masked BOOLEAN := COALESCE(p_number, '') ~ '([*xX•.]\s*){2,}|…'
                        OR length(regexp_replace(COALESCE(p_number, ''), '\D', '', 'g')) <= 6;
BEGIN
    SELECT array_agg(a.id ORDER BY a.id) INTO v_ids
    FROM finance.accounts a
    WHERE a.status = 'active' AND a.account_number = v_norm;

    IF v_ids IS NULL AND v_masked AND length(v_last4) = 4 THEN
        SELECT array_agg(a.id ORDER BY a.id) INTO v_ids
        FROM finance.accounts a
        WHERE a.status = 'active' AND a.account_type = 'cash'
          AND right(a.account_number, 4) = v_last4;
        IF cardinality(v_ids) > 1 THEN
            RETURN QUERY SELECT NULL::int, cardinality(v_ids),
                (SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'bank', a.bank,
                                                     'account_type', a.account_type) ORDER BY a.id)
                 FROM finance.accounts a WHERE a.id = ANY(v_ids));
            RETURN;
        END IF;
    END IF;

    IF v_ids IS NULL THEN
        RETURN QUERY SELECT NULL::int, 0,
            COALESCE((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'bank', a.bank,
                                                          'account_type', a.account_type) ORDER BY a.id)
                      FROM finance.accounts a
                      WHERE a.status = 'active' AND a.account_type = 'cash' AND a.account_number IS NULL), '[]'::jsonb);
        RETURN;
    END IF;

    RETURN QUERY SELECT CASE WHEN cardinality(v_ids) = 1 THEN v_ids[1] END, cardinality(v_ids),
        (SELECT jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'bank', a.bank,
                                             'account_type', a.account_type) ORDER BY a.id)
         FROM finance.accounts a WHERE a.id = ANY(v_ids));
END;
$$;
