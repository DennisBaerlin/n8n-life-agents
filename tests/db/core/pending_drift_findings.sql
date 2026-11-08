-- tests/db/core/pending_drift_findings.sql
-- PENDING: Drift-Funde (Tool-Description <-> fn-Vertrag) im Core, bewusst ROT und ausserhalb des Gates

-- (S2.11) Plan-Abschnitt mit Tippfehler im section_key ("risk_profil"): fn_advisor_save_section prueft nur "nicht
--   leer" und legt einen Phantom-Abschnitt an. Korrekt: {ok:false} mit den gueltigen Keys der Domaene.
BEGIN;
DO $$
DECLARE v jsonb;
BEGIN
  v := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','plan_name','__drift_s211_plan__',
         'section_key','risk_profil','section_content','Beispiel: mittlere Risikobereitschaft.'));
  IF (v->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [S2.11] unbekannter section_key "risk_profil" gespeichert, erwartet ok:false mit gueltigen Keys, got %', v;
  END IF;
  RAISE NOTICE 'PASS [S2.11]';
END $$;
ROLLBACK;
