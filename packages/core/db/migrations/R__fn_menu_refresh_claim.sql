-- ============================================================
-- core.fn_menu_refresh_claim() — Menue-Auftrag der Mini-App uebernehmen (READ; Tabelle + Trigger:
--   packages/core/db/core.menu_refresh_init.sql). Aufrufer nur bash als Superuser (provisioning/lib/deploy_workflows.sh
--   _set_bot_menu_buttons, der root-Runner update --run-requested fragt damit „offen?“). Muster
--   core.fn_update_request_claim, aber ohne Sperr-Zustand: ein Menue-Lauf ist idempotent, die Generation sorgt dafuer,
--   dass ein waehrend des Laufs entstandener Auftrag offen bleibt (core.fn_menu_refresh_finish schliesst nur bis gen).
--   RUECKGABE: {open, gen} — gen = aktuelle requested_gen; open = Unerledigtes UND keine Wartezeit nach einem
--              Fehlschlag (retry_after).
--   Tests: tests/db/core/test_fn_menu_refresh.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_menu_refresh_claim()
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog
AS $$
    SELECT jsonb_build_object(
        'open', COALESCE(bool_or(r.requested_gen > r.done_gen AND (r.retry_after IS NULL OR r.retry_after <= now())), false),
        'gen',  COALESCE(max(r.requested_gen), 0))
    FROM core.menu_refresh r;
$$;

REVOKE ALL ON FUNCTION core.fn_menu_refresh_claim() FROM public;
