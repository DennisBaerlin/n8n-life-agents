-- tests/db/career/pending_recalc2_findings.sql
-- PENDING: Abweichungen der Zweitrechnung Runde 2 (career), bewusst ROT und ausserhalb des Gates (db_test sammelt nur
-- test_*.sql). Lauf von Hand: .\scripts\db_test.ps1 -Filter 'pending_recalc2_*'
-- Nach Fix bzw. Owner-Entscheid den Fall in tests/db/career/test_recalc2_career.sql verschieben.
--   (C1) Auslegung: Skill-Luecken-Zahl im Berater-Satz zaehlt je Ziel-Rolle, nicht je Faehigkeit.
--        career.fn_skill_gap.gap_count summiert missing + weak ueber alle Rollen; career.fn_advisor_review sagt damit
--        "Du hast {count} Skill-Luecke(n) fuer deine Ziel-Rolle(n)". Fehlt Python in zwei Ziel-Rollen, nennt der Satz 2,
--        obwohl eine Faehigkeit fehlt. Ein Laie liest die Zahl als Anzahl fehlender Faehigkeiten.
--        Beispiel: Rolle A braucht Python + Spark, Rolle B braucht Python + dbt, Profil leer.
--          Erwartung (je Faehigkeit): Python, Spark, dbt = 3. DB: 2 + 2 = 4.
--        Fix-Vorschlag: zusaetzliches Feld distinct_gap_count (lower(trim(name)) ueber missing + weak aller Rollen) und
--        der Hauptsatz nutzt es; gap_count je Rolle bleibt fuer die Zeilen "Ziel X: ..." und "Dazu kommen n Luecken".
--        Der Zusatz "Dazu kommen {n}" sollte dann nur Faehigkeiten nennen, die in der primaeren Rolle nicht vorkommen.
BEGIN;

DO $$
DECLARE
  g jsonb;
BEGIN
  g := career.fn_skill_gap(
    '{"target_roles":[{"title":"A","required_skills":[{"name":"Python"},{"name":"Spark"}]},
                      {"title":"B","required_skills":[{"name":"python"},{"name":"dbt"}]}]}',
    '{"skills":[]}');
  IF COALESCE((g->>'distinct_gap_count')::int, (g->>'gap_count')::int) IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'FAIL [C1] Skill-Luecken je Faehigkeit: erwartet 3 (Python, Spark, dbt), got gap_count % / distinct %',
      g->>'gap_count', g->>'distinct_gap_count'; END IF;
END $$;

ROLLBACK;
