-- ============================================================
-- V002 (core) — WS-B2b: Löschschutz von metadata.protected-Flag + Name-Hardcode auf die
--   host-eigene Registry core.protected_contexts umgestellt (Kubernetes-Finalizer-Muster).
--
-- Der Baseline-Init (agent.core_init.sql, Phase 1) installiert bereits den NEUEN registry-basierten
--   trg_core_contexts_protect und erstellt den Auto-Protect-Trigger nicht mehr. Diese versioned
--   Migration räumt den ALTBESTAND (einmalig, ledger-gegated):
--   (a) Auto-Protect-Trigger + fn entfernen (Bestands-DB hat sie noch; Fresh-DB: DROP IF EXISTS no-op);
--   (b) das tote metadata.protected-Flag strippen (nichts liest es mehr — der Lösch-Trigger liest die Registry);
--   (c) jobscout_agent_instructions löschen (Owner: gehört nicht in core; nur Paper-Validierungs-Platzhalter);
--   (d) financial_planning dem finance-Paket zuordnen (Owner; V001 ließ die Laufzeit-Zeile auf 'core').
--
-- APPLY-ORDER / FENSTER: Phase 1 (Init) hat den registry-basierten Lösch-Trigger schon live; die Registry
--   ist HIER (vor seed_data) noch LEER -> der jobscout-DELETE (c) ist nicht geblockt. Benignes Fenster
--   (Single-User offline): zwischen V002 und seed_data ist kurz nichts geschützt; ein seed_data-Fehlschlag
--   ließe den Schutz persistent leer (graceful: leere Registry = kein Fehler, nur kein Schutz). Fresh-DB:
--   core_contexts noch leer -> (b)/(c)/(d) treffen 0 Zeilen; seed_data füllt danach core.protected_contexts.
-- Re-run-sicher (DROP IF EXISTS, idempotente UPDATE/DELETE) — aber ledger-gegated = läuft genau einmal.
-- ============================================================

-- (a) Auto-Protect (Namensmuster-Stempel) retired
DROP TRIGGER IF EXISTS trg_core_contexts_autoprotect ON agent.core_contexts;
DROP FUNCTION IF EXISTS agent.trg_core_contexts_autoprotect_fn();

-- (b) totes metadata.protected-Flag entfernen (Schutz lebt jetzt in core.protected_contexts)
UPDATE agent.core_contexts SET metadata = metadata - 'protected' WHERE metadata ? 'protected';

-- (c) jobscout_agent_instructions löschen (Owner: nicht core; Paper-Platzhalter)
DELETE FROM agent.core_contexts WHERE name = 'jobscout_agent_instructions';

-- (d) financial_planning -> finance-Paket (Owner; package-Spalte, V001 ließ es 'core')
UPDATE agent.core_contexts SET package = 'finance' WHERE name = 'financial_planning';
