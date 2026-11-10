-- ============================================================
-- fn_statement_lines_merge (IMMUTABLE) -- Auszugszeilen fuer die Dauerauftrags-Erkennung bereinigen
--   (1) Doppelte (gleiches Datum, Betrag, Gegenpart, IBAN, Mandat UND Verwendungszweck, z. B. zwei sich ueberlappende
--   Auszuege) zaehlen einmal; zwei echte Zahlungen am selben Tag unterscheiden sich im Zweck und bleiben (die
--   Kandidaten-fn summiert sie zu einem Termin). (2) Storno/Ruecklastschrift: entgegengesetzter Betrag, gleicher
--   Gegenpart (ohne Gross-/Kleinschreibung, nicht leer), hoechstens 14 Tage auseinander -> beide Zeilen raus, jede Zeile
--   hoechstens in einem Paar (fruehestes Gegenstueck zuerst). Nur fuer die Erkennung; der Monats-Check sieht alle Zeilen.
--   Eingabe: jsonb-Array der Zeilen (date, amount, counterparty, counterparty_iban, mandate_ref, purpose, ...).
--   RUECKGABE: jsonb-Array (Reihenfolge nach Datum).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_statement_lines_merge(p_lines jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_rows JSONB;
    v_drop INT[] := '{}';
    v_a    RECORD;
    v_b    INT;
BEGIN
    IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN
        RETURN '[]'::jsonb;
    END IF;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('i', y.i, 'l', y.l) ORDER BY y.i), '[]'::jsonb)
    INTO v_rows
    FROM (SELECT x.l, (row_number() OVER (ORDER BY x.d, x.o))::int AS i
    FROM (SELECT DISTINCT ON ((l->>'date'), round((l->>'amount')::numeric, 2), lower(COALESCE(l->>'counterparty', '')),
                              COALESCE(l->>'counterparty_iban', ''), COALESCE(l->>'mandate_ref', ''), COALESCE(l->>'purpose', ''))
                 l, (l->>'date')::date AS d, o
          FROM jsonb_array_elements(p_lines) WITH ORDINALITY e(l, o)
          WHERE NULLIF(l->>'date', '') IS NOT NULL AND NULLIF(l->>'amount', '') IS NOT NULL
          ORDER BY (l->>'date'), round((l->>'amount')::numeric, 2), lower(COALESCE(l->>'counterparty', '')),
                   COALESCE(l->>'counterparty_iban', ''), COALESCE(l->>'mandate_ref', ''), COALESCE(l->>'purpose', ''), o) x) y;

    FOR v_a IN SELECT (r->>'i')::int AS i, (r->'l'->>'date')::date AS d, round((r->'l'->>'amount')::numeric, 2) AS amt,
                      lower(btrim(COALESCE(r->'l'->>'counterparty', ''))) AS cp
               FROM jsonb_array_elements(v_rows) r ORDER BY (r->>'i')::int LOOP
        CONTINUE WHEN v_a.i = ANY(v_drop) OR v_a.cp = '' OR v_a.amt = 0;
        SELECT (r->>'i')::int INTO v_b
        FROM jsonb_array_elements(v_rows) r
        WHERE (r->>'i')::int > v_a.i AND NOT ((r->>'i')::int = ANY(v_drop))
          AND round((r->'l'->>'amount')::numeric, 2) = -v_a.amt
          AND lower(btrim(COALESCE(r->'l'->>'counterparty', ''))) = v_a.cp
          AND abs((r->'l'->>'date')::date - v_a.d) <= 14
        ORDER BY (r->>'i')::int LIMIT 1;
        IF v_b IS NOT NULL THEN
            v_drop := v_drop || v_a.i || v_b;
        END IF;
    END LOOP;
    RETURN COALESCE((SELECT jsonb_agg(r->'l' ORDER BY (r->>'i')::int) FROM jsonb_array_elements(v_rows) r
                     WHERE NOT ((r->>'i')::int = ANY(v_drop))), '[]'::jsonb);
END;
$$;
