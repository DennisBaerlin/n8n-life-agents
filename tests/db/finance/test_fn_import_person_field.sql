-- ============================================================
-- test_fn_import_person_field -- das eine Personen-Feld je entity_type (NULL = Typ ohne Person)
--   Die Namen muessen den create_*-Tool-Feldern entsprechen (hitl_lines.ps1 liest die WHEN-Zeilen der fn).
-- ============================================================
BEGIN;
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('account',      'owner_person'),
        ('real_estate',  'owner_person'),
        ('pension',      'owner_person'),
        ('insurance',    'policyholder_person'),
        ('loan',         'borrower_person'),
        ('savings_goal', 'beneficiary_person')
    ) v(t, f) LOOP
        IF finance.fn_import_person_field(r.t) IS DISTINCT FROM r.f THEN
            RAISE EXCEPTION 'FAIL [Person-Feld] %: got %, expected %', r.t, finance.fn_import_person_field(r.t), r.f;
        END IF;
    END LOOP;
    RAISE NOTICE 'PASS [Person-Feld]: 6 Typen mit Person -> richtiges Feld';

    -- Typen ohne Person und Unbekanntes -> NULL (nie ein geratenes Feld)
    FOR r IN SELECT * FROM (VALUES ('stock_buy'), ('recurring_payment'), ('pension_statement'), ('unbekannt'), (''), (NULL)) v(t) LOOP
        IF finance.fn_import_person_field(r.t) IS NOT NULL THEN
            RAISE EXCEPTION 'FAIL [ohne Person] %: got %, expected NULL', COALESCE(r.t, '<NULL>'), finance.fn_import_person_field(r.t);
        END IF;
    END LOOP;
    RAISE NOTICE 'PASS [ohne Person]: stock_buy/recurring_payment/pension_statement/unbekannt/NULL -> NULL';

    -- Konsistenz mit der Staging-Typliste: jeder erlaubte entity_type ist entweder Person-Typ oder bewusst NULL
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['account','real_estate','pension','insurance','loan','savings_goal']) t
               WHERE finance.fn_import_person_field(t) IS NULL) THEN
        RAISE EXCEPTION 'FAIL [Konsistenz]: ein Person-Typ liefert NULL';
    END IF;
END $$;
ROLLBACK;
