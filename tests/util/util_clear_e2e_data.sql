-- Wrapper (Test/E2E): ruft die geguardete agent.fn_clear_e2e_data() auf -> loescht ALLE
-- E2E-Sentinel-Entitaeten ('__E2E__'-Marker im Namen) FK-sicher + atomar. Die Pre-/Post-
-- Assertions in der Function schuetzen vor versehentlicher Produktivdaten-Loeschung.
-- Paket-Teile raeumen die Konventions-Hooks <pkg>.fn_clear_e2e_data(text) (Phase B), aufgerufen vom Core-Dispatcher.
-- Anwenden (manuell): scripts\db_apply.ps1 -File "tests\util\util_clear_e2e_data.sql"
--   (scripts\e2e_test.ps1 ruft die fn direkt per psql -c auf, Pre-Flight je Case UND Post-Flight).
SELECT agent.fn_clear_e2e_data();
