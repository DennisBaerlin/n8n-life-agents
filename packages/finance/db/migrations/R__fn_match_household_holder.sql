-- ============================================================
-- fn_match_household_holder (READ, STABLE) -- gehoert ein gedruckter Name (Gegenpart einer Buchung, Kontoinhaber eines
--   Auszugs) zu Haushaltsmitgliedern? ("Import zuerst": IBAN-Lernen, Inhaber aus dem PDF, Dauerauftrags-Erkennung)
--   Die EINE Adresse fuer Bank-Drucke ("ZWEISTEIN, MAXIMILIAN", "Max und Erika Zweistein", "MUELLER"/"MULLER"). Anders als
--   core.fn_resolve_person (ein vom Nutzer genannter Bezug: Vorname/Alias/Selbstbezug, exakt) wird token-weise verglichen:
--   fn_holder_tokens je Variante (1 = ae/oe/ue, 2 = a/o/u; die erste eindeutige gewinnt) gegen
--   core.fn_household_persons().full_name (publiziertes Fenster, Grant an finance_rw/_ro; kein DEFINER noetig).
--   Regeln (konservativ, Plan-Review 2026-10-30):
--     * eine Person trifft, wenn ALLE ihre Tokens im Namen stehen; Personen mit weniger als 2 Tokens (nur Vorname) nie;
--     * zwei getroffene Personen, deren Tokens gleich sind oder ineinander stecken ("Ida Quell" in "Greta Ida Quell") ->
--       kein Treffer (mehrdeutig: "Greta Ida Quell" allein und "Greta Ida Quell und Ida Quell" sind token-gleich;
--       Code-Review 2026-10-30);
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
        ppl AS MATERIALIZED (   -- Tokens je Person EINMAL (das Fenster ist DEFINER und nicht inline-bar)
            SELECT hp.person_id, finance.fn_holder_tokens(hp.full_name, v_variant) AS t FROM core.fn_household_persons() hp
        ),
        hit AS (
            SELECT p.person_id, p.t FROM ppl p, name n WHERE cardinality(p.t) >= 2 AND p.t <@ n.t
        )
        SELECT (SELECT jsonb_agg(person_id ORDER BY person_id) FROM hit),
               -- zwei Getroffene, von denen einer ganz im anderen steckt (gleich oder Teilmenge): "Greta Ida Quell" allein
               -- und "Greta Ida Quell und Ida Quell" ergeben dieselben Tokens -> nicht unterscheidbar
               EXISTS (SELECT 1 FROM hit a JOIN hit b ON a.person_id <> b.person_id AND a.t <@ b.t),
               EXISTS (SELECT 1 FROM name n, unnest(n.t) x WHERE NOT EXISTS (SELECT 1 FROM hit WHERE x = ANY(hit.t)))
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
