-- ============================================================
-- estate.v_directive_gaps (Gap-View, WS-2 — Vorsorge-Dokumente: Soll vs. Register)
--   ERWARTUNGSMENGE (Plan/Owner-Entscheid): directive_types mit recommendation
--   essential|recommended je ERWACHSENEM Haushaltsmitglied (owner|partner) — Minderjaehrigen-
--   Gap-Nudges waeren rechtlich unsinnig; 'situational' wird NIE genudgt.
--   Eine Zeile = ein offener Dokument-Gap: status 'missing' (kein Registereintrag) |
--   'does_not_exist' (bewusst erfasst: gibt es nicht — ehrlicher Gap) | 'planned' (in Arbeit).
--   'exists'-Eintraege erscheinen NICHT. Eine HAUSHALTS-Urkunde (owner_person_id NULL,
--   z. B. Berliner Testament) deckt den Typ fuer JEDEN Erwachsenen (LATERAL waehlt den besten
--   Treffer: exists > planned > does_not_exist; Person-Zeile vor Haushalts-Zeile).
--   Personen-Quelle = core.fn_household_persons() (publiziertes DEFINER-Fenster — die View
--   selbst laeuft mit Owner-Rechten, estate_ro liest sie ueber den View-Owner; Muster
--   finance-*_overview-Views). Konsumiert von estate.fn_gap_report + estate_ro (Frei-SQL).
--   Eigenstaendige Einzel-View -> eigene Datei (career-Muster R__v_<name>.sql).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__v_directive_gaps.sql
-- ============================================================
DROP VIEW IF EXISTS estate.v_directive_gaps CASCADE;
CREATE VIEW estate.v_directive_gaps AS
SELECT hp.person_id,
       hp.full_name,
       dt.doc_type,
       dt.label,
       dt.recommendation,
       coalesce(best.doc_status, 'missing') AS status
FROM core.fn_household_persons() hp
CROSS JOIN estate.directive_types dt
LEFT JOIN LATERAL (
    SELECT d.doc_status
    FROM estate.directives d
    WHERE d.doc_type = dt.doc_type
      AND (d.owner_person_id = hp.person_id OR d.owner_person_id IS NULL)
    ORDER BY CASE d.doc_status WHEN 'exists' THEN 0 WHEN 'planned' THEN 1 ELSE 2 END,
             (d.owner_person_id IS NOT NULL) DESC
    LIMIT 1
) best ON TRUE
WHERE hp.role IN ('owner', 'partner')
  AND dt.recommendation IN ('essential', 'recommended')
  AND coalesce(best.doc_status, 'missing') <> 'exists';
