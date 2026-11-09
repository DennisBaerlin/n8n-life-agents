-- V036: entfernt thinking-/redacted_thinking-Bloecke aus dem Bestand aller agent.*_chat_memory; die Sperre fuer neue Zeilen
-- steht in agent.chat_memory_guard_init.sql. Laeuft die Funktion doppelt, findet sie nichts mehr.
SELECT agent.fn_chat_memory_cleanup();
