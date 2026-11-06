-- ============================================================
-- V005 (career) — career.job_matches Multi-Source (LinkedIn/StepStone via Sammel-APIs Adzuna/JSearch).
--
--   WARUM eine V-Migration: (1) RENAME COLUMN refnr -> external_id, (2) source-CHECK von 2 auf 4 Werte weiten
--   und (3) den partial-UNIQUE von (refnr, person_id) auf (source, external_id, person_id) umbauen lassen sich
--   nicht idempotent ueber den Init/CREATE ausdruecken (Bestand muss EINMALIG umbenannt/umgebaut werden). Der
--   Init traegt den END-Zustand (fresh DB bekommt external_id/board/4-Wert-CHECK + den Index direkt); diese
--   Migration transformiert Bestands-DBs. Muster: V001 (guarded RENAME-DO-Block) + V003 (Index-Rebuild).
--
--   MULTI-SOURCE (arch-challenge D2/D3):
--     * source = INGESTION-PROVIDER, jetzt {bundesagentur, adzuna, jsearch, forwarded}. CHECK BLEIBT (kein
--       Open-Text) — "Constraint ist Gesetz"; Quellen sind build-time enumeriert, jede reitet auf einer
--       Cron/Cred-Migration. adzuna = lizenzierter DE-Feed (holt StepStone-Inhalte zuverlaessig), jsearch =
--       Google-for-Jobs (holt LinkedIn stark).
--     * board (nullable, KEIN CHECK) = ORIGINAL-Board eines Aggregator-Treffers. Herkunft je Provider:
--         jsearch -> board IMMER aus job_publisher (NULL auf jsearch-Zeile = Bug);
--         adzuna  -> board NULL BY DESIGN (Adzuna legt KEIN Board offen; NICHT aus redirect_url/company ableiten);
--         bundesagentur/forwarded -> NULL.
--       `board IS NULL` heisst EINHEITLICH "von diesem Weg nicht offengelegt", NIE "hatten wir und verworfen".
--       board nimmt NIE am Dedup-Key teil (rein deskriptiv).
--     * external_id (war refnr) = generischer Per-Provider-Posting-Schluessel. Idempotenz-Identitaet jetzt
--       SOURCE-SKOPIERT (source, external_id, person_id): zwei Quellen mit gleicher external_id-Zeichenkette
--       kollidieren NICHT (BA-refnr / Adzuna-id / JSearch-job_id sind verschiedene Schluesselraeume) — sonst
--       UPSERTete Quelle B still in Quelle As Zeile. Cross-Aggregator-Fuzzy-Dedup (dieselbe reale Stelle via 2
--       Quellen) ist BACKLOG -> source-skopiert ist die sichere Default (2 Zeilen statt stiller Merge).
--
--   IDEMPOTENT + re-run-sicher: RENAME nur wenn refnr EXISTS und external_id NOT EXISTS; ADD COLUMN IF NOT
--   EXISTS board; CHECK DROP IF EXISTS + ADD; Index DROP IF EXISTS + CREATE. Fresh DB: der Init legt external_id/
--   board/4-Wert-CHECK + uq_job_matches_external_id schon an -> RENAME no-op, ADD no-op, CHECK identisch neu,
--   Index drop+recreate identisch. Bestands-DB (refnr, 2-Wert-CHECK, uq_job_matches_refnr): voller Umbau.
--
-- APPLY-ORDER: career Inits (tables_init: external_id/board/4-Wert-CHECK + guarded Index nur wenn external_id da)
--   -> V (hier: Rename/CHECK/board + Index-Rebuild) -> R (R__fn_record_job_match liest external_id/board,
--   ON CONFLICT (source, external_id, person_id); R__v_job_matches selektiert external_id/board). Re-run-sicher.
-- ============================================================

DO $$
BEGIN
    -- (1) refnr -> external_id (guarded; V001-DO-Block-Muster). Der abhaengige Index folgt der Spalte automatisch
    --     (wird in Schritt 4 ohnehin neu gebaut). Fresh DB hat external_id schon aus dem Init -> RENAME no-op.
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'career' AND table_name = 'job_matches' AND column_name = 'refnr')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'career' AND table_name = 'job_matches' AND column_name = 'external_id') THEN
        ALTER TABLE career.job_matches RENAME COLUMN refnr TO external_id;
    END IF;

    -- (2) board-Spalte (nullable, kein Default, kein CHECK). Fresh DB hat sie aus dem Init.
    ALTER TABLE career.job_matches ADD COLUMN IF NOT EXISTS board text;

    -- (3) source-CHECK von {bundesagentur, forwarded} auf {bundesagentur, adzuna, jsearch, forwarded} weiten.
    --     Superset -> keine Bestandszeile verletzt ihn (Validierung trivial auf Single-User-Tabelle). Auto-Name
    --     der inline-Spalten-CHECK = job_matches_source_check.
    ALTER TABLE career.job_matches DROP CONSTRAINT IF EXISTS job_matches_source_check;
    ALTER TABLE career.job_matches
        ADD CONSTRAINT job_matches_source_check
        CHECK (source IN ('bundesagentur', 'adzuna', 'jsearch', 'forwarded'));
END $$;

-- (4) Partial-UNIQUE von (refnr, person_id) auf (source, external_id, person_id) umbauen + auf den ehrlichen
--     Namen umbenennen (uq_job_matches_refnr -> uq_job_matches_external_id). DROP beide moeglichen Namen (fresh:
--     der Init legte uq_job_matches_external_id an; Bestand: uq_job_matches_refnr), dann CREATE -> idempotent.
--     Muster V003 (DROP IF EXISTS + CREATE; require-concurrent-index-* in .squawk.toml ausgeschlossen).
DROP INDEX IF EXISTS career.uq_job_matches_external_id;
DROP INDEX IF EXISTS career.uq_job_matches_refnr;
CREATE UNIQUE INDEX uq_job_matches_external_id
    ON career.job_matches (source, external_id, person_id) WHERE external_id IS NOT NULL;
