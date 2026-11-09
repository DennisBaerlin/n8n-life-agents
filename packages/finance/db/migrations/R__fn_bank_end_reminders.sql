-- ============================================================
-- fn_bank_end_due (READ, STABLE) -- welche beendeten Bank-Auftraege heute eine Erinnerung ausloesen
--   Das System notiert Dauerauftraege und Sparplaene nur; ohne eingetragenes Ende bucht die Bank weiter.
--   Faellig: Kopf aktiv (pausiert hat schon die Karte bank_stop gesagt), letzter Termin L (fn_recurring_last_due) mit
--   L + 3 <= p_on <= L + 60, Ausfuehrung bei Bank/Broker (fn_bank_setup_kind mit p_existing; Handueberweisung,
--   Lastschrift, Eingang, Kredit-Rate nie). 3 Tage: ein Termin am Wochenende bucht erst am naechsten Bankarbeitstag,
--   frueheres Loeschen kostete die letzte gewollte Ausfuehrung. 60 Tage: keine Rueckwirkung auf laengst Beendetes.
--   Eingabe: p_on (Stichtag, default heute).
--   Rueckgabe: jsonb-Array nach last_due, name: {head, last_due, kind standing_order|savings_plan, execution bank|unknown,
--   name, amount (positiv), currency, bank|null, to_name, goal|null, holder_person_id|null, holder_name|null (Vorname),
--   holder_role|null}. Inhaber = owner_person_id des Quell-Kontos, beim Sparplan des Depots.
--   plpgsql: fn_recurring_last_due und fn_transfer_executed_by sortieren als R__ spaeter.
--   Tests: tests/db/finance/test_fn_bank_end_reminders.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_end_due(p_on date DEFAULT core.fn_today())
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_out jsonb;
BEGIN
    WITH heads AS (
        SELECT DISTINCT finance.fn_recurring_lineage_head(id) AS head FROM finance.recurring_payments
    ), c AS (
        SELECT r.*, h.head, finance.fn_recurring_last_due(h.head) AS last_due,
               finance.fn_bank_setup_kind(h.head, true) AS kind
          FROM heads h JOIN finance.recurring_payments r ON r.id = h.head
         WHERE r.status = 'active' AND r.valid_to IS NOT NULL
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'head', c.head, 'last_due', c.last_due, 'kind', c.kind,
               'execution', CASE WHEN c.kind = 'savings_plan' THEN 'bank' ELSE finance.fn_transfer_executed_by(c.head) END,
               'name', COALESCE(sp.name, c.name), 'amount', abs(c.amount), 'currency', src.currency,
               'bank', NULLIF(btrim(CASE WHEN c.kind = 'savings_plan' THEN dep.bank ELSE src.bank END), ''),
               'to_name', CASE WHEN c.kind = 'savings_plan' THEN dep.name ELSE tgt.name END,
               'goal', g.name,
               'holder_person_id', p.person_id,
               'holder_name', split_part(p.full_name, ' ', 1),
               'holder_role', p.role)
             ORDER BY c.last_due, COALESCE(sp.name, c.name)), '[]'::jsonb)
      INTO v_out
      FROM c
      JOIN finance.accounts src ON src.id = c.account_id
      LEFT JOIN finance.accounts tgt ON tgt.id = c.target_account_id
      LEFT JOIN LATERAL (SELECT s.name, s.depot_id FROM finance.savings_plans s
                          WHERE s.recurring_payment_id = c.head ORDER BY s.id LIMIT 1) sp ON true
      LEFT JOIN finance.accounts dep ON dep.id = sp.depot_id
      LEFT JOIN finance.savings_goals g ON g.recurring_payment_id = c.head
      LEFT JOIN core.fn_household_persons() p
             ON p.person_id = CASE WHEN c.kind = 'savings_plan' THEN dep.owner_person_id ELSE src.owner_person_id END
     WHERE c.kind IS NOT NULL
       AND p_on BETWEEN c.last_due + 3 AND c.last_due + 60;
    RETURN v_out;
END $$;

-- ============================================================
-- fn_bank_end_claim (WRITE, Latch) -- die heutigen Bank-Ende-Nachrichten je Empfaenger, jede genau einmal
--   Owner: Sammel-Nachricht mit allen faelligen Auftraegen (cron_enable.remind_bank_end). Inhaber mit Rolle partner,
--   Telegram-Kopplung und core.fn_reminder_allowed('remind_bank_end_person'): eigene Nachricht. Kinder nie (ein
--   Kinderdepot fuehren die Eltern), der Owner als Inhaber bekommt nur die Sammel-Nachricht.
--   Latch core.notification_state, Quelle 'finance:bank_end' (Reset raeumt <pkg>:<sub>), Key <head>:<L>:owner|<person_id>,
--   ohne TTL. Wer heute nicht darf, latcht nicht: Koppeln oder Wieder-Einschalten im Fenster holt die Erinnerung nach.
--   Budget: je Empfaenger Slot 'bank_end' normal, nur wenn etwas noch nicht gemeldet ist; ohne Platz kein Merker (Folgetag).
--   Merker aelter als 400 Tage werden geloescht; ihr L liegt laengst ausserhalb des Fensters.
--   Eingabe: p_on (Stichtag, default heute).
--   Rueckgabe: jsonb-Array, Owner zuerst: [{recipient 'owner'|<person_id>, chat_id (null beim Owner = Default-Chat), items:
--   Zeilen aus fn_bank_end_due}]; holder_name beim eigenen Auftrag des Owners null.
--   Tests: tests/db/finance/test_fn_bank_end_reminders.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_end_claim(p_on date DEFAULT core.fn_today())
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    c_src    CONSTANT text := 'finance:bank_end';
    v_ok     boolean := core.fn_reminder_allowed('remind_bank_end', NULL);
    v_owner  jsonb := '[]'::jsonb;
    v_people jsonb := '{}'::jsonb;
    v_item   jsonb;
    v_base   text;
    v_pid    text;
    v_chat   bigint;
    v_out    jsonb;
    v_oroom  boolean;              -- Budget des Owners, einmal je Lauf
    v_proom  jsonb := '{}'::jsonb; -- Budget je Mitglied, einmal je Lauf
BEGIN
    PERFORM core.fn_notify_forget_before(c_src, (p_on - 400)::timestamptz);
    FOR v_item IN SELECT e FROM jsonb_array_elements(finance.fn_bank_end_due(p_on)) e LOOP
        v_base := (v_item->>'head') || ':' || (v_item->>'last_due');
        v_pid  := v_item->>'holder_person_id';
        IF v_ok AND v_oroom IS NULL AND NOT core.fn_notify_told(c_src, v_base || ':owner') THEN
            v_oroom := core.fn_proactive_claim(NULL, 'bank_end', 'normal');
        END IF;
        IF v_ok AND v_oroom AND core.fn_should_notify(c_src, v_base || ':owner', NULL) THEN
            v_owner := v_owner || CASE WHEN v_item->>'holder_role' = 'owner'
                                       THEN jsonb_set(v_item, '{holder_name}', 'null') ELSE v_item END;
        END IF;
        CONTINUE WHEN v_item->>'holder_role' IS DISTINCT FROM 'partner';
        v_chat := core.fn_person_chat_id(v_pid);
        IF v_chat IS NOT NULL AND core.fn_reminder_allowed('remind_bank_end_person', v_pid)
           AND NOT v_proom ? v_pid AND NOT core.fn_notify_told(c_src, v_base || ':' || v_pid) THEN
            v_proom := v_proom || jsonb_build_object(v_pid, core.fn_proactive_claim(v_pid, 'bank_end', 'normal'));
        END IF;
        IF COALESCE((v_proom->>v_pid)::boolean, false) AND v_chat IS NOT NULL
           AND core.fn_reminder_allowed('remind_bank_end_person', v_pid)
           AND core.fn_should_notify(c_src, v_base || ':' || v_pid, NULL) THEN
            v_people := jsonb_set(v_people, ARRAY[v_pid], jsonb_build_object(
                'recipient', v_pid, 'chat_id', v_chat,
                'items', COALESCE(v_people->v_pid->'items', '[]'::jsonb) || v_item), true);
        END IF;
    END LOOP;
    SELECT CASE WHEN jsonb_array_length(v_owner) > 0
                THEN jsonb_build_array(jsonb_build_object('recipient', 'owner', 'chat_id', NULL, 'items', v_owner))
                ELSE '[]'::jsonb END
           || COALESCE((SELECT jsonb_agg(value ORDER BY key) FROM jsonb_each(v_people)), '[]'::jsonb)
      INTO v_out;
    RETURN v_out;
END $$;

-- ============================================================
-- fn_bank_stop_note_told (WRITE, Latch) -- Karten-Notiz bank_stop; was die Karte sagt, erinnert der Cron nicht noch einmal
--   = fn_bank_setup_note(p_rp_id, 'bank_stop', p_params); ist die Notiz nicht leer und L <= heute, setzt sie den Owner-Key
--   von fn_bank_end_claim im selben Commit (der Probelauf rollt ihn mit zurueck). Nur der Owner-Key: der Owner sieht die
--   Karte immer (Schreiber oder Freigeber), der Inhaber nicht, und die Write-fns kennen den Absender nicht.
--   Kein Trigger: test_dry_run_finance verbietet aufgeschobene Trigger, und Import oder Restore haben keine Karte gezeigt.
--   Eingabe: p_rp_id (beliebiges Glied), p_params (wie fn_bank_setup_note). Rueckgabe: die Notiz.
--   Tests: tests/db/finance/test_fn_bank_end_reminders.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_bank_stop_note_told(p_rp_id int, p_params jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_note jsonb := finance.fn_bank_note_recorded(p_rp_id, 'bank_stop', p_params);
    v_last date  := finance.fn_recurring_last_due(p_rp_id);
BEGIN
    IF v_note <> '[]'::jsonb AND v_last <= core.fn_today() THEN
        PERFORM core.fn_should_notify('finance:bank_end',
            finance.fn_recurring_lineage_head(p_rp_id) || ':' || v_last || ':owner', NULL);
    END IF;
    RETURN v_note;
END $$;
