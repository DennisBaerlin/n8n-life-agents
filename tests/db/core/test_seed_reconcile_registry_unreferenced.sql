-- tests/db/core/test_seed_reconcile_registry_unreferenced.sql
-- Der Seed (provisioning/lib/seed_data.sh, _seed_reconcile) loescht je Registry-Tabelle die Zeilen, die ein Manifest nicht mehr
-- nennt, in derselben Transaktion wie alle anderen Seed-Anweisungen. Das ist nur sicher, solange nichts den Tabellen den DELETE
-- verbietet: ein Fremdschluessel auf eine dieser Tabellen oder ein DELETE-Trigger liesse die Anweisung scheitern und kippte den
-- ganzen Seed (Update und Restore bleiben halb abgeglichen). core.monitor_acquisition_methods hat einen solchen FK und steht darum
-- bewusst nicht in der Liste des Seeders. Fuer jede Tabelle der Liste:
--   (1) kein Fremdschluessel zeigt auf sie
--   (2) kein benutzerdefinierter DELETE-Trigger haengt an ihr
-- Kommt ein FK oder Trigger dazu, entfaellt die Tabelle aus _seed_reconcile (Muster: monitor_acquisition_methods) oder der Test
-- wird bewusst angepasst. Nur Katalog-Abfragen, keine Daten.
BEGIN;

DO $$
DECLARE
  v_tabs   REGCLASS[] := ARRAY['core.context_validators', 'core.context_scopes', 'core.context_renderers',
                               'core.advisors', 'core.cron_labels', 'core.callback_handlers']::regclass[];
  v_bad    TEXT;
BEGIN
  SELECT string_agg(conrelid::regclass::text || ' -> ' || confrelid::regclass::text, ', ')
    INTO v_bad
    FROM pg_constraint
   WHERE contype = 'f' AND confrelid = ANY (v_tabs);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [FK]: Fremdschluessel auf eine abgeglichene Registry-Tabelle (%): der DELETE in _seed_reconcile kann den Seed kippen', v_bad;
  END IF;
  RAISE NOTICE 'PASS [kein FK auf die sechs abgeglichenen Registry-Tabellen]';

  SELECT string_agg(tgrelid::regclass::text || '.' || tgname, ', ')
    INTO v_bad
    FROM pg_trigger
   WHERE NOT tgisinternal AND (tgtype & 8) <> 0 AND tgrelid = ANY (v_tabs);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [Trigger]: DELETE-Trigger auf einer abgeglichenen Registry-Tabelle (%): _seed_reconcile kann scheitern', v_bad;
  END IF;
  RAISE NOTICE 'PASS [kein DELETE-Trigger auf den abgeglichenen Registry-Tabellen]';
END $$;

ROLLBACK;
