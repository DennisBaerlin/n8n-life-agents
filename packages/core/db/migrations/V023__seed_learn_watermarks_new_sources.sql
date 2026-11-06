-- ============================================================
-- V023 — Lern-Loop: Startmarke fuer die mit Phase B NEU hinzugekommenen Lern-Quellen (einmalig)
--   Phase B macht ALLE agent.*_chat_memory (ausser orchestrator) zu Quellen von core.fn_collect_chat_since
--   (vorher fest finance|finance_advisor|guide). Laeuft der opt-in Lern-Loop auf dieser Instanz schon (es gibt
--   Watermark-Zeilen), duerfen die bereits gefuellten Tabellen der neuen Quellen (z. B. career-/estate-
--   Gespraeche, Trauerfall-Begleitung) NICHT rueckwirkend ans Lern-Modell -> fuer jede Quelle ohne Watermark
--   wird sie EINMALIG auf die aktuelle max(id) gesetzt. Gelernt wird ab jetzt.
--   Bewusst hier (Flyway V, einmalig) und NICHT in der Lauf-fn: dort verschluckte eine "neue Quelle ->
--   max(id)"-Regel jedes kuenftige erste Gespraech (n8n legt die Memory-Tabelle erst beim ersten Turn an)
--   und die Nachrichten einer Quelle ohne bisherige Owner-Treffer. Die Lauf-fn behandelt eine fehlende
--   Watermark wieder schlicht als 0.
--   Loop nie gelaufen (keine Watermark-Zeile) -> nichts zu tun (der erste Lauf sammelt ab 0 wie vor Phase B).
--   Tabellen dynamisch aus pg_tables (kein Agent-/Paketname im Core).
-- ============================================================
DO $$
DECLARE
    v_tbl text;
    v_max bigint;
BEGIN
    IF to_regclass('agent.guide_learn_watermark') IS NULL
       OR NOT EXISTS (SELECT 1 FROM agent.guide_learn_watermark) THEN
        RETURN;
    END IF;
    FOR v_tbl IN
        SELECT t.tablename FROM pg_catalog.pg_tables t
         WHERE t.schemaname = 'agent' AND t.tablename LIKE '%\_chat\_memory' ESCAPE '\'
           AND t.tablename <> 'orchestrator_chat_memory'
    LOOP
        EXECUTE format('SELECT COALESCE(max(id), 0) FROM agent.%I', v_tbl) INTO v_max;
        INSERT INTO agent.guide_learn_watermark (agent_name, last_seen_id)
        VALUES (left(v_tbl, length(v_tbl) - length('_chat_memory')), v_max)
        ON CONFLICT ON CONSTRAINT guide_learn_watermark_pkey DO NOTHING;
    END LOOP;
END $$;
