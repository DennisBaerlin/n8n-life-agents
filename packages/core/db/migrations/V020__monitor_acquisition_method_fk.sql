-- ============================================================
-- V020 — agent.monitor_triggers.acquisition_method -> FK auf core.monitor_acquisition_methods (Phase B)
--   Ersetzt die fruehere CHECK-IN-Liste (mit dem finance-Literal 'fx_rate'; die Init haelt nur noch die
--   Namens-Form) durch die Registry-Mitgliedschaft als DB-Gesetz. Versioned, weil (a) Daten: Bestands-Trigger
--   koennen eine Paket-Methode benutzen, deren Paket-Seed erst NACH der Schema-Phase laeuft -> fuer jede in
--   Benutzung befindliche, unregistrierte Methode wird GENERISCH (kein Methoden-Literal) eine Platzhalter-Zeile
--   angelegt (package/fns NULL; der Paket-Seed fuellt sie, sonst bleibt der Trigger geparkt). So muss die
--   Migration NIE Owner-Trigger loeschen. (b) die FK-Anlage ist nicht idempotent ausdrueckbar ohne Guard.
--   NO ACTION (nicht CASCADE): Trigger sind Owner-Daten, keine Bestandteile der Methode — der Paket-Purge
--   loescht seine Methoden-Trigger explizit + gezaehlt (fn_pkg_purge_data Schritt 3c); ein CASCADE feuerte
--   zudem trg_monitor_triggers_protect und braeche die ganze Purge-Transaktion ab.
--   Frische DB: nur Core-Trigger (sql) -> keine Platzhalter, FK sofort gueltig.
-- ============================================================
INSERT INTO core.monitor_acquisition_methods (method)
SELECT DISTINCT t.acquisition_method
  FROM agent.monitor_triggers t
 WHERE NOT EXISTS (SELECT 1 FROM core.monitor_acquisition_methods m WHERE m.method = t.acquisition_method)
ON CONFLICT (method) DO NOTHING;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'agent.monitor_triggers'::regclass
                      AND conname  = 'monitor_triggers_acquisition_method_fk') THEN
        ALTER TABLE agent.monitor_triggers
            ADD CONSTRAINT monitor_triggers_acquisition_method_fk
            FOREIGN KEY (acquisition_method) REFERENCES core.monitor_acquisition_methods (method);
    END IF;
END $$;
