-- ============================================================
-- V018 — family-Platzhaltertext an die Fakten angleichen (Install-UX-Phase 6)
--   Das Owner-Skelett (util_seed_owner_skeleton.sql) traegt seit der Installation den Owner mit Namen +
--   Geburtsdatum in metadata.facts, die Prosa sagte aber "(noch keine Haushaltsdaten erfasst - Onboarding
--   ausstehend)" — ein Widerspruch, der den Guide verleitete, Bekanntes neu zu erfragen. Neue Installationen
--   bekommen den neuen Text direkt; diese Migration ersetzt NUR den exakt unveraenderten alten Platzhalter
--   (vom Owner/Agent geschriebene Prosa bleibt unberuehrt). Idempotent (Exakt-Match), kein BEGIN/COMMIT.
-- ============================================================
UPDATE agent.core_contexts
SET content = '(Inhaber bei der Installation angelegt; weitere Personen folgen im Onboarding)'
WHERE name = 'family'
  AND content = '(noch keine Haushaltsdaten erfasst - Onboarding ausstehend)';
