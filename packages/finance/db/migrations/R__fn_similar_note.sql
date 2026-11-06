-- ============================================================
-- fn_similar_note (KARTEN-HINWEIS "AEHNLICHER EINTRAG", Paket DB-ist-das-Gesetz S6)
--   Die EINE Form des weichen Dubletten-Hinweises der create-fns fuer Versicherung, Kredit, Immobilie, Sparziel und
--   Sparplan (Konto: eigene Note similar_account). Jede create-fn stellt ihre Regel mit hoher Schwelle (z. B.
--   Versicherung: gleiche Gesellschaft + gleicher Jahresbeitrag) und reicht den Namen des Treffers hierher.
--   NULL -> [] (kein Hinweis), sonst [{kind:'note', value:'finance.note.similar_entry', params:{name}}].
--   Ersetzt die Prompt-Regel "aehnliche Eintraege selbst suchen und nachfragen" (Karte statt Chat-Rueckfrage).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_similar_note(p_existing_name text)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE WHEN p_existing_name IS NULL THEN '[]'::jsonb
                ELSE jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'finance.note.similar_entry',
                                                          'params', jsonb_build_object('name', p_existing_name))) END;
$$;
