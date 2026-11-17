-- tests/db/core/test_fn_name_report.sql
-- core.fn_name_key (Normalform) und core.fn_name_report (vergebene/aehnliche Namen, Vorschlag mit Personen-Zusatz).
BEGIN;

DO $$
DECLARE
  v JSONB;
  v_ex JSONB := '[{"name":"Gesetzliche Rente Erika Mustermann","person":"Erika Mustermann"},
                  {"name":"Riester Erika","person":"Erika Mustermann"},
                  {"name":"Haftpflicht","person":null}]';
BEGIN
  -- Normalform: Gross/Klein, Leerraum innen, Satzzeichen; Umlaute und Hangul bleiben
  IF core.fn_name_key('  Gesetzliche   RENTE – Erika ') IS DISTINCT FROM 'gesetzliche rente erika' THEN
    RAISE EXCEPTION 'FAIL name_key [Normalform]: %', core.fn_name_key('  Gesetzliche   RENTE – Erika '); END IF;
  IF core.fn_name_key('Bausparvertrag Müller') IS DISTINCT FROM 'bausparvertrag müller'
     OR core.fn_name_key('비상금 지민') IS DISTINCT FROM '비상금 지민' THEN
    RAISE EXCEPTION 'FAIL name_key [Umlaut/Hangul bleiben]: % / %', core.fn_name_key('Bausparvertrag Müller'), core.fn_name_key('비상금 지민'); END IF;
  IF core.fn_name_key(NULL) <> '' THEN RAISE EXCEPTION 'FAIL name_key [NULL]'; END IF;
  RAISE NOTICE 'PASS name_key [Normalform]';

  -- taken: gleiche Normalform; Vorschlag = + Vorname der Person
  v := core.fn_name_report('haftpflicht', v_ex, 'Max Mustermann');
  IF v->'taken' <> '["Haftpflicht"]' OR v->>'suggested_name' IS DISTINCT FROM 'haftpflicht Max'
     OR (v->>'needs_person')::boolean OR jsonb_array_length(v->'existing_names') <> 3 THEN
    RAISE EXCEPTION 'FAIL name_report [taken]: %', v; END IF;
  RAISE NOTICE 'PASS name_report [taken + Vorschlag Vorname]';

  -- taken ohne Person: kein Vorschlag
  v := core.fn_name_report('Haftpflicht', v_ex, NULL);
  IF v->>'suggested_name' IS NOT NULL THEN RAISE EXCEPTION 'FAIL name_report [ohne Person kein Vorschlag]: %', v; END IF;
  RAISE NOTICE 'PASS name_report [ohne Person kein Vorschlag]';

  -- Geschwister einer anderen Person mit vollem Namen -> needs_person, Vorschlag in derselben Form
  v := core.fn_name_report('Gesetzliche Rente', v_ex, 'Max Mustermann');
  IF NOT (v->>'needs_person')::boolean OR v->>'suggested_name' IS DISTINCT FROM 'Gesetzliche Rente Max Mustermann'
     OR v->'similar' <> '["Gesetzliche Rente Erika Mustermann"]' OR jsonb_array_length(v->'taken') <> 0
     OR v->>'sibling' IS DISTINCT FROM 'Gesetzliche Rente Erika Mustermann' THEN
    RAISE EXCEPTION 'FAIL name_report [Geschwister voller Name]: %', v; END IF;
  RAISE NOTICE 'PASS name_report [Geschwister voller Name]';

  -- Geschwister mit Vornamen -> Vorschlag mit Vornamen
  v := core.fn_name_report('Riester', v_ex, 'Max Mustermann');
  IF NOT (v->>'needs_person')::boolean OR v->>'suggested_name' IS DISTINCT FROM 'Riester Max' THEN
    RAISE EXCEPTION 'FAIL name_report [Geschwister Vorname]: %', v; END IF;
  RAISE NOTICE 'PASS name_report [Geschwister Vorname]';

  -- dieselbe Person bzw. Haushalt: nur aehnlich, kein Vorschlag
  v := core.fn_name_report('Riester', v_ex, 'Erika Mustermann');
  IF (v->>'needs_person')::boolean OR v->>'suggested_name' IS NOT NULL OR v->'similar' <> '["Riester Erika"]' THEN
    RAISE EXCEPTION 'FAIL name_report [gleiche Person]: %', v; END IF;
  v := core.fn_name_report('Riester', v_ex, NULL);
  IF (v->>'needs_person')::boolean OR v->'similar' <> '["Riester Erika"]' THEN
    RAISE EXCEPTION 'FAIL name_report [Haushalt]: %', v; END IF;
  RAISE NOTICE 'PASS name_report [gleiche Person / Haushalt: nur aehnlich]';

  -- Wortgrenze: "Riest" ist nicht aehnlich zu "Riester Erika"
  v := core.fn_name_report('Riest', v_ex, NULL);
  IF jsonb_array_length(v->'similar') <> 0 THEN RAISE EXCEPTION 'FAIL name_report [Wortgrenze]: %', v; END IF;
  RAISE NOTICE 'PASS name_report [Wortgrenze]';

  -- Vorschlag, der selbst vergeben ist, entfaellt
  v := core.fn_name_report('Haftpflicht', v_ex || '[{"name":"Haftpflicht Max","person":"Max Mustermann"}]', 'Max Mustermann');
  IF v->>'suggested_name' IS NOT NULL THEN RAISE EXCEPTION 'FAIL name_report [Vorschlag vergeben]: %', v; END IF;
  RAISE NOTICE 'PASS name_report [vergebener Vorschlag entfaellt]';

  -- leerer Bestand
  v := core.fn_name_report('Neu', '[]', 'Max Mustermann');
  IF v <> '{"taken":[],"similar":[],"needs_person":false,"existing_names":[],"suggested_name":null,"sibling":null}'::jsonb THEN
    RAISE EXCEPTION 'FAIL name_report [leer]: %', v; END IF;
  RAISE NOTICE 'PASS name_report [leerer Bestand]';
END $$;

ROLLBACK;
