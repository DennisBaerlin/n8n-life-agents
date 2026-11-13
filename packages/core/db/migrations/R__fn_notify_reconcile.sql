-- ============================================================
-- fn_notify_reconcile (WRITE)
--   Bulk-Re-Arm fuer level-triggered Producer. Eingabe: p_source, p_keys (text[]). Rueckgabe: void.
--   Loescht alle Latch-Zeilen einer source, deren key nicht im aktuell uebergebenen Schluessel-Set
--   liegt -> sie gelten als "wieder im Band" (re-armed). Das ist die Reconcile-GC-Semantik der
--   Advisor-Drift-Engine: der Review-Lauf re-evaluiert jede Runde das volle Alert-Set; jede Metrik,
--   die nicht mehr breached (also nicht im aktuellen Set), wird geloescht -> der naechste Breach
--   derselben Metrik feuert wieder (k8s-Desired-State-Muster). Deckt zugleich umbenannte/geloeschte
--   Entitaeten (stale keys) ab -> kein Leak.
--
--   p_keys leer/NULL -> alle Zeilen der source werden geloescht (keine aktuelle Breach -> alles re-armed).
--   Ausschliesslich fuer level-triggered Producer (Advisor). Event-getriebene Producer (Folds/knock)
--   re-armen ueber fn_notify_resolve (per key) bzw. den TTL, nicht hierueber.
--
--   SECURITY DEFINER (search_path-Pin + REVOKE PUBLIC): D10-Schreibfenster auf core.notification_state.
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
