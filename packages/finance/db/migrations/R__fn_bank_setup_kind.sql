-- ============================================================
-- fn_bank_setup_kind (READ HELPER) -- muss der Nutzer diese Kette selbst bei Bank oder Broker einrichten?
--   Das System notiert Dauerauftraege und Sparplaene nur. Eine Adresse fuer "welcher Bank-Hinweis passt": Karten beim
--   Anlegen/Aendern, Monats-Check (erstes Fehlen) und Berater (recurring_never_started) lesen sie.
--   Eingabe: eine rp-id (beliebiges Glied; die Antwort gilt fuer den Ketten-Kopf, auf den Besitzer zeigen).
--   Rueckgabe: 'savings_plan' (ein Sparplan zeigt auf den Kopf) | 'standing_order' (Uebertrag mit Ziel-Konto, den
--   fn_transfer_executed_by als 'unknown' fuehrt: weder als bestehender Bank-Dauerauftrag noch als Handueberweisung
--   angegeben, Quelle ein Geld-Konto) | NULL (Lastschrift, Eingang, Kredit-Rate, Handueberweisung, schon bei der Bank,
--   unbekannte id). Kredit-Raten tragen kein Ziel-Konto, eine Kredit-Quelle ergibt 'manual'.
--   p_existing (default false): true = es geht um einen bestehenden Auftrag (aendern, aussetzen, beenden); dann zaehlt
--   auch 'bank' (laeuft bei der Bank, muss dort mitgeaendert werden), nur 'manual' bleibt NULL.
--   plpgsql statt sql: fn_transfer_executed_by sortiert als R__ spaeter (late binding).
--   Tests: tests/db/finance/test_fn_bank_setup_kind.sql
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_bank_setup_kind(int);
CREATE OR REPLACE FUNCTION finance.fn_bank_setup_kind(p_rp_id int, p_existing boolean DEFAULT FALSE)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_head int := finance.fn_recurring_lineage_head(p_rp_id);
BEGIN
    IF v_head IS NULL THEN RETURN NULL; END IF;
    IF EXISTS (SELECT 1 FROM finance.savings_plans sp WHERE sp.recurring_payment_id = v_head) THEN
        RETURN 'savings_plan';
    END IF;
    IF EXISTS (SELECT 1 FROM finance.recurring_payments r WHERE r.id = v_head AND r.target_account_id IS NOT NULL)
       AND finance.fn_transfer_executed_by(v_head) = ANY (CASE WHEN p_existing THEN ARRAY['unknown', 'bank']
                                                                ELSE ARRAY['unknown'] END) THEN
        RETURN 'standing_order';
    END IF;
    RETURN NULL;
END $$;

-- ============================================================
-- fn_bank_setup_note (READ HELPER) -- die Karten-Notiz zum Bank-Hinweis einer Kette, Institut beim Namen
--   Eingabe: p_rp_id (beliebiges Glied), p_event (Anlass: 'bank_setup' neu angelegt | 'bank_change' Betrag/Tag/Topf
--   geaendert oder fortgesetzt | 'bank_stop' ausgesetzt/beendet | 'statement_never_seen' | 'recurring_never_started'),
--   p_params (weitere tpl-Parameter, optional). bank_change/bank_stop fragen fn_bank_setup_kind mit p_existing.
--   Rueckgabe: [] wenn fn_bank_setup_kind NULL ist, sonst [{kind:'note', value:<key>, params}]; der Key je Anlass, Art
--   und Namens-Lage steht woertlich in der Tabelle unten (locale_lint prueft nur Literale), bei leerem Institutsnamen
--   die _generic-Variante (Text sagt "deine Bank"/"dein Broker", params ohne bank). Unbekannter Anlass -> RAISE
--   (Programmierfehler). Der Name kommt aus accounts.bank: Dauerauftrag = Quell-Konto des Kopfs
--   (dort richtet man ihn ein), Sparplan = Depot des Sparplans. Ohne Artikel im Text ("bei {bank}"): der Artikel ist
--   bei Bank-Namen nicht ableitbar. Hat die Kette ein Ende, nennen bank_setup und bank_stop (solange der Termin noch
--   kommt und die Kette nicht pausiert ist: Pausieren heisst jetzt stoppen) die letzte Ausfuehrung: _until-Variante mit
--   params.date (fn_recurring_last_due).
--   Tests: tests/db/finance/test_fn_bank_setup_kind.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_setup_note(p_rp_id int, p_event text, p_params jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_kind text := finance.fn_bank_setup_kind(p_rp_id, p_event IN ('bank_change', 'bank_stop'));
    v_head int;
    v_bank text;
    v_key  text;
    v_last date;
    v_ev   text := p_event;
BEGIN
    IF v_kind IS NULL THEN RETURN '[]'::jsonb; END IF;
    v_head := finance.fn_recurring_lineage_head(p_rp_id);
    IF v_kind = 'savings_plan' THEN
        SELECT a.bank INTO v_bank
          FROM finance.savings_plans sp JOIN finance.accounts a ON a.id = sp.depot_id
         WHERE sp.recurring_payment_id = v_head ORDER BY sp.id LIMIT 1;
    ELSE
        SELECT a.bank INTO v_bank
          FROM finance.recurring_payments r JOIN finance.accounts a ON a.id = r.account_id
         WHERE r.id = v_head;
    END IF;
    v_bank := NULLIF(btrim(v_bank), '');
    IF p_event IN ('bank_setup', 'bank_stop') THEN
        v_last := finance.fn_recurring_last_due(p_rp_id);
        IF v_last IS NOT NULL
           AND (p_event = 'bank_setup'
                OR (v_last > core.fn_today()
                    AND EXISTS (SELECT 1 FROM finance.recurring_payments r WHERE r.id = v_head AND r.status = 'active'))) THEN
            v_ev := p_event || '_until';
        END IF;
    END IF;
    SELECT m.k INTO v_key FROM (VALUES
        ('bank_setup',              'standing_order', false, 'finance.note.bank_setup_standing_order'),
        ('bank_setup',              'standing_order', true,  'finance.note.bank_setup_standing_order_generic'),
        ('bank_setup',              'savings_plan',   false, 'finance.note.bank_setup_savings_plan'),
        ('bank_setup',              'savings_plan',   true,  'finance.note.bank_setup_savings_plan_generic'),
        ('bank_setup_until',        'standing_order', false, 'finance.note.bank_setup_standing_order_until'),
        ('bank_setup_until',        'standing_order', true,  'finance.note.bank_setup_standing_order_until_generic'),
        ('bank_setup_until',        'savings_plan',   false, 'finance.note.bank_setup_savings_plan_until'),
        ('bank_setup_until',        'savings_plan',   true,  'finance.note.bank_setup_savings_plan_until_generic'),
        ('bank_stop_until',         'standing_order', false, 'finance.note.bank_stop_standing_order_until'),
        ('bank_stop_until',         'standing_order', true,  'finance.note.bank_stop_standing_order_until_generic'),
        ('bank_stop_until',         'savings_plan',   false, 'finance.note.bank_stop_savings_plan_until'),
        ('bank_stop_until',         'savings_plan',   true,  'finance.note.bank_stop_savings_plan_until_generic'),
        ('bank_change',             'standing_order', false, 'finance.note.bank_change_standing_order'),
        ('bank_change',             'standing_order', true,  'finance.note.bank_change_standing_order_generic'),
        ('bank_change',             'savings_plan',   false, 'finance.note.bank_change_savings_plan'),
        ('bank_change',             'savings_plan',   true,  'finance.note.bank_change_savings_plan_generic'),
        ('bank_stop',               'standing_order', false, 'finance.note.bank_stop_standing_order'),
        ('bank_stop',               'standing_order', true,  'finance.note.bank_stop_standing_order_generic'),
        ('bank_stop',               'savings_plan',   false, 'finance.note.bank_stop_savings_plan'),
        ('bank_stop',               'savings_plan',   true,  'finance.note.bank_stop_savings_plan_generic'),
        ('statement_never_seen',    'standing_order', false, 'finance.note.statement_never_seen_standing_order'),
        ('statement_never_seen',    'standing_order', true,  'finance.note.statement_never_seen_standing_order_generic'),
        ('statement_never_seen',    'savings_plan',   false, 'finance.note.statement_never_seen_savings_plan'),
        ('statement_never_seen',    'savings_plan',   true,  'finance.note.statement_never_seen_savings_plan_generic'),
        ('recurring_never_started', 'standing_order', false, 'finance.advisor.recurring_never_started_standing_order'),
        ('recurring_never_started', 'standing_order', true,  'finance.advisor.recurring_never_started_standing_order_generic'),
        ('recurring_never_started', 'savings_plan',   false, 'finance.advisor.recurring_never_started_savings_plan'),
        ('recurring_never_started', 'savings_plan',   true,  'finance.advisor.recurring_never_started_savings_plan_generic')
    ) m(ev, kind, generic, k)
    WHERE m.ev = v_ev AND m.kind = v_kind AND m.generic = (v_bank IS NULL);
    IF v_key IS NULL THEN RAISE EXCEPTION 'fn_bank_setup_note: unknown event %', p_event; END IF;
    RETURN jsonb_build_array(jsonb_build_object(
        'kind', 'note',
        'value', v_key,
        'params', COALESCE(p_params, '{}'::jsonb)
                  || CASE WHEN v_bank IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('bank', v_bank) END
                  || CASE WHEN v_ev LIKE '%\_until' THEN jsonb_build_object('date', core.fn_ui_date(v_last)) ELSE '{}'::jsonb END));
END $$;

-- ============================================================
-- fn_recurring_never_ran (READ HELPER) -- lief diese Kette noch nie?
--   TRUE, wenn kein Glied der Kette (fn_recurring_lineage) je eine gebuchte Transaktion hat UND bei einem Uebertrag
--   auch keine andere Kette derselben Strecke (gleiche Quelle, gleiches Ziel-Konto) je gebucht wurde: ein Ersatz-
--   Dauerauftrag (Sparziel replace_transfer) fuehrt einen bei der Bank laufenden Auftrag fort und ist nicht "neu".
--   Bewusst ohne Auszugs-Skips: der Berater (2d) meldet erst nach zwei Skips und braucht trotzdem "nie gelaufen";
--   das erste Fehlen im Monats-Check (fn_statement_prepare) prueft die Skips zusaetzlich selbst.
--   Unbekannte id -> TRUE (keine Buchung).
--   Tests: tests/db/finance/test_fn_bank_setup_kind.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_never_ran(p_rp_id int)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (SELECT 1 FROM finance.transactions t
                        WHERE t.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(p_rp_id)))
       AND NOT EXISTS (SELECT 1
                         FROM finance.recurring_payments h
                         JOIN finance.recurring_payments o
                           ON o.account_id = h.account_id AND o.target_account_id = h.target_account_id
                         JOIN finance.transactions t ON t.recurring_payment_id = o.id
                        WHERE h.id = finance.fn_recurring_lineage_head(p_rp_id) AND h.target_account_id IS NOT NULL);
$$;
