-- ============================================================
-- V030 (finance) — Renteninformation-Gesetze scharf schalten (Plan 2026-10-26).
--
--   WARUM eine V-Migration: das Init legt die neuen CHECKs nur NOT VALID an (ein Altbestand liesse sie sonst schon im
--   Init scheitern, vor jeder V-Phase); den UNIQUE-Index "eine aktive gesetzliche Rente je Person" kann man nicht NOT
--   VALID anlegen. Hier wird der Altbestand EINMALIG bereinigt, dann validiert/angelegt:
--   (1) gesetzliche Rente mit eigener Monatsrente/Wert (frueher per Chat erlaubt): die Betraege wandern in die Notiz
--       (Fakt bleibt sichtbar), die Spalten werden leer -> die Werte gehoeren kuenftig zur Renteninformation.
--   (2) mehrere AKTIVE gesetzliche Renten desselben Eigentuemers (NULL = Haushalt): die aelteste bleibt aktiv, die
--       weiteren werden pausiert (mit Hinweis in der Notiz; ihre Renteninformationen bleiben erhalten).
--   (3) PRE-FLIGHT fail-loud: eine Renteninformation mit negativem Betrag bzw. fallenden Szenarien wird nicht still
--       geaendert -> Abbruch mit ids (die neuen Szenario-Spalten sind im Bestand leer, betroffen waeren nur Altwerte).
--   (4) VALIDATE der drei CHECKs, CREATE UNIQUE INDEX.
--   FRISCHE DB: kein Bestand -> (1)-(3) No-op, (4) validiert/legt an. Re-run-sicher.
-- ============================================================

-- (1) Betraege einer gesetzlichen Rente -> Notiz
UPDATE finance.pension
   SET notes = concat_ws(E'\n', notes,
           CASE WHEN guaranteed_monthly_pension IS NOT NULL
                THEN 'Monatsrente laut frueherer Erfassung: ' || to_char(guaranteed_monthly_pension, 'FM999999990.00') END,
           CASE WHEN current_value IS NOT NULL
                THEN 'Wert laut frueherer Erfassung: ' || to_char(current_value, 'FM999999990.00') END),
       guaranteed_monthly_pension = NULL,
       current_value = NULL
 WHERE pension_type = 'statutory' AND (guaranteed_monthly_pension IS NOT NULL OR current_value IS NOT NULL);

-- (2) weitere aktive gesetzliche Renten desselben Eigentuemers pausieren (die aelteste bleibt)
UPDATE finance.pension p
   SET status = 'paused',
       notes  = concat_ws(E'\n', p.notes, 'Pausiert (V030): eine weitere aktive gesetzliche Rente derselben Person - '
                                         || 'bitte zusammenfuehren oder loeschen.')
 WHERE p.pension_type = 'statutory' AND p.status = 'active'
   AND EXISTS (SELECT 1 FROM finance.pension o
                WHERE o.pension_type = 'statutory' AND o.status = 'active' AND o.id < p.id
                  AND o.owner_person_id IS NOT DISTINCT FROM p.owner_person_id);

-- (3) Pre-flight Renteninformationen
DO $$
DECLARE v_bad TEXT;
BEGIN
    SELECT string_agg(id::text, ', ' ORDER BY id) INTO v_bad FROM finance.pension_statements
     WHERE COALESCE(reached_claim, 0) < 0 OR COALESCE(projection, 0) < 0 OR COALESCE(em_monthly, 0) < 0
        OR COALESCE(scenario_1pct, 0) < 0 OR COALESCE(scenario_2pct, 0) < 0 OR COALESCE(earning_points, 0) < 0
        OR scenario_1pct < projection OR scenario_2pct < scenario_1pct OR scenario_2pct < projection;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'V030 pre-flight: Renteninformation(en) mit negativem Betrag oder fallenden Szenarien, id %. '
            'Werte korrigieren (oder die Zeile loeschen), dann erneut migrieren.', v_bad;
    END IF;
END $$;

-- (4) Gesetze scharf
ALTER TABLE finance.pension            VALIDATE CONSTRAINT finance_pension_statutory_no_amounts;
ALTER TABLE finance.pension_statements VALIDATE CONSTRAINT finance_pension_statements_nonneg;
ALTER TABLE finance.pension_statements VALIDATE CONSTRAINT finance_pension_statements_scenarios_rise;
CREATE UNIQUE INDEX IF NOT EXISTS finance_pension_statutory_uq
    ON finance.pension (owner_person_id) NULLS NOT DISTINCT WHERE pension_type = 'statutory' AND status = 'active';
