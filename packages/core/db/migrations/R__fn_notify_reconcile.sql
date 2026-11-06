-- ============================================================
-- core.fn_notify_reconcile (Bulk-Re-Arm fuer level-triggered Producer, Phase Notify WS-1)
--   Loescht alle Latch-Zeilen einer source, deren key NICHT im aktuell uebergebenen Schluessel-Set
--   liegt -> sie gelten als "wieder im Band" (re-armed). Das ist die Reconcile-GC-Semantik der
--   Advisor-Drift-Engine: der Review-Lauf re-evaluiert jede Runde das VOLLE Alert-Set; jede Metrik,
--   die NICHT mehr breached (also nicht im aktuellen Set), wird geloescht -> der naechste Breach
--   derselben Metrik feuert wieder (k8s-Desired-State-Muster). Deckt zugleich umbenannte/geloeschte
--   Entitaeten (stale keys) ab -> kein Leak.
--
--   p_keys leer/NULL -> alle Zeilen der source werden geloescht (keine aktuelle Breach -> alles re-armed).
--   AUSSCHLIESSLICH fuer level-triggered Producer (Advisor). Event-getriebene Producer (Folds/knock)
--   re-armen ueber fn_notify_resolve (per key) bzw. den TTL -- NICHT hierueber.
--
--   SECURITY DEFINER (search_path-Pin + REVOKE PUBLIC): D10-Schreibfenster auf core.notification_state.
--   Anwenden via: db_apply.ps1 -File packages\core\db\migrations\R__fn_notify_reconcile.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_notify_reconcile(p_source text, p_keys text[])
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    DELETE FROM core.notification_state
    WHERE source = p_source
      AND key <> ALL (COALESCE(p_keys, ARRAY[]::text[]));
$$;

REVOKE ALL ON FUNCTION core.fn_notify_reconcile(text, text[]) FROM public;
