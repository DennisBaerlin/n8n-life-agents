-- ============================================================
-- agent.fn_hitl_repeat_key (Wiederhol-Sperre des HITL-Gates: die eine Schluessel-Ableitung)
--   Schluessel einer Bestaetigungskarte: repeat_key des strukturierten Summary (New-HitlSummary -RepeatKey, z. B. die
--   Plan-Tools, deren Text das Modell neu formuliert), sonst der Hash des ganzen Summary. jsonb normalisiert die
--   Feld-Reihenfolge -> der Hash ist stabil. Ohne Summary (NULL, JSON null, leerer Text) gibt es keinen Schluessel:
--   md5(NULL) waere NULL und traefe nie, ein Hash von 'null' traefe jede andere Karte ohne Summary.
--   Eingabe: p_summary (jsonb). Rueckgabe: text | NULL
--   Tests: tests/db/core/test_fn_hitl_pending.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_hitl_repeat_key(p_summary jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_summary IS NULL OR jsonb_typeof(p_summary) = 'null' OR p_summary = '""'::jsonb THEN NULL
        ELSE COALESCE(NULLIF(btrim(p_summary->>'repeat_key'), ''), md5(p_summary::text))
    END;
$$;

REVOKE ALL ON FUNCTION agent.fn_hitl_repeat_key(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_hitl_repeat_key(JSONB) FROM context_ro;
    END IF;
END $$;
