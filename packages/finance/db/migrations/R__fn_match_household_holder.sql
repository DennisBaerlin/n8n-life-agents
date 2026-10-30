-- ============================================================
-- fn_match_household_holder (READ, STABLE) -- gehoert ein gedruckter Name (Gegenpart einer Buchung, Kontoinhaber eines
--   Auszugs) zu Haushaltsmitgliedern? ("Import zuerst": IBAN-Lernen, Inhaber aus dem PDF, Dauerauftrags-Erkennung)
--   Die EINE Adresse fuer Bank-Drucke ("ZWEISTEIN, MAXIMILIAN", "Max und Erika Zweistein", "MUELLER"/"MULLER"). Anders als
--   core.fn_resolve_person (ein vom Nutzer genannter Bezug: Vorname/Alias/Selbstbezug, exakt) wird token-weise verglichen:
--   fn_holder_tokens je Variante (1 = ae/oe/ue, 2 = a/o/u; die erste eindeutige gewinnt) gegen
--   core.fn_household_persons().full_name (publiziertes Fenster, Grant an finance_rw/_ro; kein DEFINER noetig).
--   Regeln (konservativ, Plan-Review 2026-10-30):
--     * eine Person trifft, wenn ALLE ihre Tokens im Namen stehen; Personen mit weniger als 2 Tokens (nur Vorname) nie;
--     * eine getroffene Person, deren Tokens echte Teilmenge einer anderen getroffenen sind, faellt weg ("Ida Quell" in
--       "Greta Ida Quell");
--     * zwei getroffene Personen mit gleichen Tokens -> kein Treffer (mehrdeutig);
--     * bleibt ein Token des Namens, das zu keiner getroffenen Person gehoert ("GmbH", ein fremder Name) -> kein Treffer.
--   RUECKGABE: {matched, person_ids[] (sortiert), owner_person_id (genau eine Person, sonst NULL), joint (>= 2 Personen)}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_match_household_holder(p_name text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_variant INT;
    v_ids     JSONB;
    v_amb     BOOLEAN;
    v_left    BOOLEAN;
BEGIN
    FOR v_variant IN 1..2 LOOP
        WITH name AS (SELECT finance.fn_holder_tokens(p_name, v_variant) AS t),
        hit AS (
            SELECT hp.person_id, finance.fn_holder_tokens(hp.full_name, v_variant) AS t
            FROM core.fn_household_persons() hp, name n
            WHERE cardinality(finance.fn_holder_tokens(hp.full_name, v_variant)) >= 2
              AND finance.fn_holder_tokens(hp.full_name, v_variant) <@ n.t
        ),
        top AS (
            SELECT h.* FROM hit h
            WHERE NOT EXISTS (SELECT 1 FROM hit o WHERE o.person_id <> h.person_id AND h.t <@ o.t AND NOT (o.t <@ h.t))
        )
        SELECT (SELECT jsonb_agg(person_id ORDER BY person_id) FROM top),
               EXISTS (SELECT 1 FROM top a JOIN top b ON a.person_id < b.person_id AND a.t <@ b.t AND b.t <@ a.t),
               EXISTS (SELECT 1 FROM name n, unnest(n.t) x WHERE NOT EXISTS (SELECT 1 FROM top WHERE x = ANY(top.t)))
        INTO v_ids, v_amb, v_left;
        IF v_ids IS NOT NULL AND NOT v_amb AND NOT v_left THEN
            RETURN jsonb_build_object('matched', true, 'person_ids', v_ids,
                'owner_person_id', CASE WHEN jsonb_array_length(v_ids) = 1 THEN v_ids->>0 END,
                'joint', jsonb_array_length(v_ids) >= 2);
        END IF;
    END LOOP;
    RETURN jsonb_build_object('matched', false, 'person_ids', '[]'::jsonb, 'owner_person_id', NULL, 'joint', false);
END;
$$;
