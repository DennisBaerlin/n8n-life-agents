-- ============================================================
-- finance.fn_plan_gaps (Plan-Luecken, 2026-10-27 — DB rechnet, was am Haushalts-Finanzplan noch fehlt)
--   Live-Anlass: ein importierter Plan war veroeffentlicht, aber nur 3 von 9 Interview-Sektionen waren je im Gespraech
--   bestaetigt und das Notreserve-Ziel fehlte; der Berater erkannte das nur zufaellig aus der Prosa.
--   Gilt nur bei AKTIVEM Plan (ohne aktiven Plan laeuft das Fresh-/Resume-Interview, keine Meldung).
--
--   KATALOG = die Interview-Sektionen (Reihenfolge = DIN-77230-Prioritaet) und ihre Pflicht-Bloecke; der Prompt
--   (finance_advisor_instructions.md "Interview catalog") muss dieselben Keys/Pfeil-Bloecke nennen — contract_lint 28
--   prueft die Gleichheit. Umbenannte Alt-Keys frueherer Versionen werden ignoriert.
--   BESTAETIGT = die Sektion steht im interview_state IRGENDEINER veroeffentlichten Version (active/superseded) der
--   Haushalts-Domain 'finance' (person_id NULL): ein neuer Draft startet leer, ohne die Union verschwaenden fruehere
--   Bestaetigungen nach dem naechsten Publish. Der E2E-Sentinel '__e2e_finance__' zaehlt nicht. Eine Sektion, die den
--   Haushalt nicht betrifft, bestaetigt der Berater mit einem kurzen "trifft nicht zu"-Save (Prompt).
--   VERWERTBAR (Pflicht-Block in p_facts = Sidecar financial_planning.metadata.facts, vom Renderer uebergeben):
--   emergency_reserve erst mit numerischem target_months/target_eur (sonst verwerfen Renderer und Review ihn still);
--   die uebrigen Bloecke = Objekt vorhanden. interview_state ohne Objekt-Form (Altlast) zaehlt als leer (RAISE-frei:
--   die fn laeuft im Render-Pfad von core.fn_fetch_context, ein Fehler kostete den ganzen Plan).
--
--   RUECKGABE jsonb: { has_active_plan,
--     open_sections:       [key…]  -- weder veroeffentlicht bestaetigt noch im Draft (Katalog-Reihenfolge)
--     draft_only_sections: [key…]  -- im offenen Draft gespeichert, noch nicht veroeffentlicht (-> publizieren)
--     missing_blocks:      [{section, block}…] }  -- bestaetigte Sektion ohne verwertbaren Block (keine Doppelnennung)
--   STABLE/INVOKER, keine Paket-Rollen-Grants (Muster fn_render_plan_facts): einziger Aufrufer ist
--   finance.fn_render_plan_facts innerhalb von core.fn_fetch_context (SECURITY DEFINER) -> liest agent.advisor_plans
--   mit dessen Rechten.
--   Anwenden via: db_apply.ps1 -File packages\finance\db\migrations\R__fn_plan_gaps.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_plan_gaps(p_facts jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_catalog CONSTANT jsonb := '[
        {"key":"household_basics",   "blocks":[]},
        {"key":"risk_protection",    "blocks":[]},
        {"key":"emergency_reserve",  "blocks":["emergency_reserve"]},
        {"key":"debts_loans",        "blocks":[]},
        {"key":"retirement_pension", "blocks":[]},
        {"key":"risk_profile",       "blocks":["risk_profile"]},
        {"key":"wealth_building",    "blocks":["target_allocation","glidepath"]},
        {"key":"korea_crossborder",  "blocks":[]},
        {"key":"goals_triggers",     "blocks":["goal"]}
    ]';
    v_facts      jsonb := CASE WHEN jsonb_typeof(p_facts) = 'object' THEN p_facts ELSE '{}'::jsonb END;
    v_confirmed  text[];
    v_draft      text[];
    v_open       jsonb;
    v_missing    jsonb;
    v_draft_only jsonb;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM agent.advisor_plans ap
                   WHERE ap.domain = 'finance' AND ap.person_id IS NULL AND ap.status = 'active') THEN
        RETURN jsonb_build_object('has_active_plan', false, 'open_sections', '[]'::jsonb,
                                  'draft_only_sections', '[]'::jsonb, 'missing_blocks', '[]'::jsonb);
    END IF;

    SELECT COALESCE(array_agg(DISTINCT k), '{}') INTO v_confirmed
    FROM agent.advisor_plans ap, jsonb_object_keys(ap.interview_state) k
    WHERE ap.domain = 'finance' AND ap.person_id IS NULL AND ap.status IN ('active', 'superseded')
      AND jsonb_typeof(ap.interview_state) = 'object';

    SELECT COALESCE(array_agg(DISTINCT k), '{}') INTO v_draft
    FROM agent.advisor_plans ap, jsonb_object_keys(ap.interview_state) k
    WHERE ap.domain = 'finance' AND ap.person_id IS NULL AND ap.status = 'draft'
      AND jsonb_typeof(ap.interview_state) = 'object';

    SELECT COALESCE(jsonb_agg(s.e->>'key' ORDER BY s.ord) FILTER (WHERE NOT (s.e->>'key' = ANY (v_draft))), '[]'::jsonb),
           COALESCE(jsonb_agg(s.e->>'key' ORDER BY s.ord) FILTER (WHERE s.e->>'key' = ANY (v_draft)), '[]'::jsonb)
      INTO v_open, v_draft_only
    FROM jsonb_array_elements(v_catalog) WITH ORDINALITY s(e, ord)
    WHERE NOT (s.e->>'key' = ANY (v_confirmed));

    SELECT COALESCE(jsonb_agg(jsonb_build_object('section', s.e->>'key', 'block', b.blk) ORDER BY s.ord, b.bord), '[]'::jsonb)
      INTO v_missing
    FROM jsonb_array_elements(v_catalog) WITH ORDINALITY s(e, ord),
         jsonb_array_elements_text(s.e->'blocks') WITH ORDINALITY b(blk, bord)
    WHERE s.e->>'key' = ANY (v_confirmed)
      AND NOT CASE
            WHEN jsonb_typeof(v_facts->b.blk) IS DISTINCT FROM 'object' THEN false
            WHEN b.blk = 'emergency_reserve' THEN jsonb_typeof(v_facts->b.blk->'target_months') IS NOT DISTINCT FROM 'number'
                                               OR jsonb_typeof(v_facts->b.blk->'target_eur') IS NOT DISTINCT FROM 'number'
            ELSE true
          END;

    RETURN jsonb_build_object('has_active_plan', true, 'open_sections', v_open,
                              'draft_only_sections', v_draft_only, 'missing_blocks', v_missing);
END;
$$;
