-- ============================================================
-- career.fn_record_job_match (ATOMIC UPSERT eines Job-Treffers)
--   Die eine UPSERT-fn der career.job_matches-Tabelle, genutzt von zwei Aufrufern:
--     * cron.score_jobs  -> source='bundesagentur'|'adzuna'|'jsearch' + score (1..4 aus dem Per-Posting-Scorer),
--                           + external_id (Per-Provider-Schluessel) + optional board (nur jsearch: job_publisher);
--     * tool_record_job_match -> source='forwarded' (manuell vorgemerkt, kein score, board NULL).
--   Eingabe p: title (Pflicht), source (Default 'forwarded'), external_id, board, employer, location, url,
--     score (nur als JSON-Zahl 1..4 beachtet, Nicht-Zahl-Strings werden ignoriert), score_reasoning,
--     is_serendipity, raw; Person: person_id (nur trusted Cron, nie als $fromAI exponieren), sonst Sender aus
--     chat_id (Tool-Pfad), sonst Owner-Fallback.
--   Idempotenz (source-skopiert): ON CONFLICT auf den partial-UNIQUE-Index uq_job_matches_external_id
--     (source, external_id, person_id) WHERE external_id IS NOT NULL -> ein Re-Scan desselben Postings derselben
--     Quelle+Person UPDATEt (kein Dup); zwei Quellen (BA-refnr / Adzuna-id / JSearch-job_id = verschiedene
--     Schluesselraeume) mit gleicher external_id kollidieren nicht (2 Zeilen); forwarded ohne external_id = INSERT.
--   board: COALESCE-Merge im UPDATE (Re-Record ohne board bewahrt den bestehenden Wert; jsearch liefert
--     board=job_publisher immer, adzuna/bundesagentur/forwarded -> NULL by design). board nimmt nie am Key teil.
--   score/is_serendipity/board sind Roh-Werte des Aufrufers; abgeleitete Spalten (updated_at) traegt der Trigger.
--   Rueckgabe: Erfolg -> {ok:true, job_match_id, created, score} (score entfaellt bei NULL);
--     ok:false ohne Write und ohne RAISE (kein Owner-Alert): 'invalid source "<s>" (…)', 'title is required
--     (non-empty)', 'score <n> out of range (1..4)', 'no person resolved (no person_id, chat_id or owner)'.
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_record_job_match(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_source      text     := COALESCE(NULLIF(trim(p->>'source'), ''), 'forwarded');
    v_external_id text     := NULLIF(trim(p->>'external_id'), '');   -- generischer Per-Provider-Schluessel (BA: refnr)
    v_board       text     := NULLIF(trim(p->>'board'), '');         -- Original-Board (nur jsearch; sonst NULL)
    v_title       text     := COALESCE(NULLIF(trim(p->>'title'), ''), '');
    v_score       smallint;   -- nur aus einer expliziten JSON-Zahl gesetzt (kein Cast auf Nicht-Zahl -> kein RAISE)
    v_seren       boolean  := COALESCE((p->>'is_serendipity')::boolean, false);
    v_chat        bigint;     -- Sender-chat_id (RAISE-frei gecastet); nur der Tool-Pfad liefert sie
    v_person      text;       -- aufgeloeste Eigentuemer-Person (wholly-per-person)
    v_id          bigint;
    v_existing    bigint;
    v_final_score smallint;
BEGIN
    -- Korrigierbare Validierung vor dem Write (kein RAISE -> kein Owner-Alert):
    IF v_source NOT IN ('bundesagentur', 'adzuna', 'jsearch', 'forwarded') THEN
        RETURN jsonb_build_object('ok', false, 'reason', format('invalid source "%s" (bundesagentur|adzuna|jsearch|forwarded)', v_source));
    END IF;
    IF v_title = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'title is required (non-empty)');
    END IF;
    -- score nur, wenn explizit als JSON-Zahl geliefert (ein Nicht-Zahl-String wird ignoriert, nicht gecastet
    -- -> kein RAISE; ein Cast im DECLARE koennte vor der Validierung werfen):
    IF p ? 'score' AND jsonb_typeof(p->'score') = 'number' THEN
        IF (p->>'score')::numeric < 1 OR (p->>'score')::numeric > 4 THEN
            RETURN jsonb_build_object('ok', false, 'reason', format('score %s out of range (1..4)', p->>'score'));
        END IF;
        v_score := (p->>'score')::smallint;
    END IF;

    -- Person-Aufloesung (wholly-per-person; Identitaet nie vom LLM gerechnet). Praezedenz:
    --   (1) explizite person_id  -- trusted Cron only: nie als $fromAI exponieren (Tool-Schema-Lint erzwingt das)
    --   (2) Sender aus chat_id (Tool-Pfad)  (3) Owner-Fallback (Cron/Tool ohne Person).
    -- chat_id RAISE-frei casten (nicht-numerisch -> NULL -> Owner-Fallback greift; kein Owner-Alert).
    BEGIN
        v_chat := NULLIF(p->>'chat_id', '')::bigint;
    EXCEPTION WHEN OTHERS THEN
        v_chat := NULL;
    END;
    v_person := COALESCE(
        NULLIF(p->>'person_id', ''),
        NULLIF(agent.fn_resolve_sender(v_chat)->>'person_id', ''),
        agent.fn_owner_person_id());
    IF v_person IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'no person resolved (no person_id, chat_id or owner)');
    END IF;

    -- created-Flag: existiert die (source, external_id)-Zeile dieser Person schon? (source gehoert dazu: ein neuer
    -- Provider mit gleicher external_id meldet korrekt created=true; NULL external_id = forwarded = immer neu.)
    SELECT id INTO v_existing FROM career.job_matches
        WHERE v_external_id IS NOT NULL AND external_id = v_external_id AND source = v_source AND person_id = v_person;

    INSERT INTO career.job_matches (person_id, source, external_id, board, title, employer, location, url, score, score_reasoning, is_serendipity, raw)
    VALUES (
        v_person, v_source, v_external_id, v_board, v_title,
        NULLIF(trim(p->>'employer'), ''),
        NULLIF(trim(p->>'location'), ''),
        NULLIF(trim(p->>'url'), ''),
        v_score,
        NULLIF(trim(p->>'score_reasoning'), ''),
        v_seren,
        COALESCE(p->'raw', '{}'::jsonb)
    )
    ON CONFLICT (source, external_id, person_id) WHERE external_id IS NOT NULL DO UPDATE SET
        title           = EXCLUDED.title,
        board           = COALESCE(EXCLUDED.board, career.job_matches.board),
        employer        = COALESCE(EXCLUDED.employer, career.job_matches.employer),
        location        = COALESCE(EXCLUDED.location, career.job_matches.location),
        url             = COALESCE(EXCLUDED.url, career.job_matches.url),
        score           = COALESCE(EXCLUDED.score, career.job_matches.score),
        score_reasoning = COALESCE(EXCLUDED.score_reasoning, career.job_matches.score_reasoning),
        is_serendipity  = EXCLUDED.is_serendipity OR career.job_matches.is_serendipity,
        raw             = CASE WHEN EXCLUDED.raw = '{}'::jsonb THEN career.job_matches.raw ELSE EXCLUDED.raw END
    RETURNING id, score INTO v_id, v_final_score;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'ok', true,
        'job_match_id', v_id,
        'created', (v_existing IS NULL),
        'score', v_final_score
    ));
END;
$$;
