-- ============================================================
-- fn_set_cron_enable (ATOMIC WRITE) — Cron an/aus per Chat-Button
--   Owner-Aktion (Inline-Button am Nudge / am Publish-Aktivierungs-Angebot / an der Lern-Karte, callback_query):
--   schaltet das Enable-Flag eines Crons in core.config (category 'cron_enable'). Die Owner-Auth liegt am
--   Orchestrator-Callback (from.id==Owner via 'Callback owner?').
--
--   Schaltbar = Mitgliedschaft in core.cron_labels: ein Key ist genau dann aus dem Chat schaltbar, wenn er dort eine
--   Zeile hat. Always-on Crons (Default value='true') stehen nicht in der Registry -> strukturell nicht
--   chat-togglable. Ein neues Paket macht seinen opt-in-Cron schaltbar, indem es nur eine
--   cron_labels-Zeile deklariert (Manifest-Block), kein fn-Edit. Eine Quelle (Registry-Membership) speist
--   Togglability + Button-Existenz (cron_toggle_lint) + fn-Akzeptanz -> kein Drift zwischen drei Listen.
--
--   UPDATE-only: die cron_enable-Config-Zeile muss existieren (vom Installer geseedet, ON CONFLICT DO NOTHING)
--   -> kein INSERT-Pfad; package der Zeile bleibt unberuehrt (nie 'core' hartkodieren).
--   Die fn bleibt rein: Rueckgabe {ok,key,enabled} ohne Labels (Presentation macht der Orchestrator, der die
--   deutschen Toasts selbst aus core.cron_labels liest, docs/package-contract.md §8).
--
--   p: { key, enabled }  (key ∈ Mitglieder von core.cron_labels; enabled bool bzw. 'true'/'false')
--   scope=person-Keys (agent.reminder_prefs je Person) -> {ok:false} (ihr cron_enable ist Konsolen-Notschalter).
--   mandatory-Keys (Pflicht-Erinnerung, nur Anzeige in /reminders) -> {ok:false} (nur Konsole).
--   Rueckgabe: {ok:true, key, enabled} | {ok:false, reason}  (kein RAISE -> kein Owner-Alert).
--   INVOKER: der Orchestrator ruft sie unter dem Haupt-RW/Host-Credential (besitzt core.config + core.cron_labels)
--   -> kein DEFINER-Eskalationsfenster (wie fn_block_knocker / fn_advisor_review_evaluate). search_path-Pin
--   + REVOKE von PUBLIC + den Leserollen.
--   Tests: tests/db/core/test_fn_set_cron_enable.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_set_cron_enable(p jsonb)
RETURNS jsonb LANGUAGE plpgsql
SET search_path = pg_catalog, core
AS $$
DECLARE
    v_key     TEXT := COALESCE(p->>'key', '');
    v_enabled BOOLEAN;
BEGIN
    -- Togglability = Registry-Membership: nur opt-in Crons mit cron_labels-Zeile.
    IF NOT EXISTS (SELECT 1 FROM core.cron_labels WHERE cron_key = v_key) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('unknown or non-toggleable cron key "%s" (not in core.cron_labels)', v_key));
    END IF;
    -- Person-Reminder schaltet jede Person selbst (core.fn_set_reminder_pref, rem:-Knoepfe); ihr
    -- cron_enable ist der Konsolen-Notschalter fuer alle -> nie per Chat-Knopf (ein alter Knopf an einer Karte
    -- schaltete sonst die Zustellung fuer den ganzen Haushalt ab).
    IF EXISTS (SELECT 1 FROM core.cron_labels WHERE cron_key = v_key AND scope = 'person') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('cron key "%s" is person-scoped (each person switches it via rem:on|off)', v_key));
    END IF;
    -- Pflicht-Erinnerungen (gesetzliche Fristen) sind nur Anzeige, nie per Chat schaltbar.
    IF EXISTS (SELECT 1 FROM core.cron_labels WHERE cron_key = v_key AND mandatory) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('cron key "%s" is mandatory (console only)', v_key));
    END IF;
    BEGIN
        v_enabled := (p->>'enabled')::boolean;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'enabled must be a boolean (true|false)');
    END;

    -- UPDATE-only: die Config-Zeile existiert (Installer-Seed); package bleibt unberuehrt.
    UPDATE core.config
       SET value = CASE WHEN v_enabled THEN 'true' ELSE 'false' END
     WHERE category = 'cron_enable' AND key = v_key;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('cron_enable config row for "%s" missing (seed inconsistency)', v_key));
    END IF;

    RETURN jsonb_build_object('ok', true, 'key', v_key, 'enabled', v_enabled);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_set_cron_enable(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION core.fn_set_cron_enable(JSONB) FROM context_ro;
    END IF;
END $$;
