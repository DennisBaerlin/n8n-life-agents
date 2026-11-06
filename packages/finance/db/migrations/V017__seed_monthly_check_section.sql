-- V017: Onboarding-Sektion 'monthly_check' (Monats-Check, WP-F) fuer BESTANDS-Nutzer als erledigt anlegen.
-- Die Sektion ist ein Ausblick (keine Erfassung). Ein Nutzer, der alle bisherigen Sektionen schon beantwortet hat,
-- soll durch das Update nicht wieder "Onboarding ausstehend" sehen. Laeuft VOR dem Host-Seeder (seed_data.sh
-- _seed_onboarding_sections, ON CONFLICT DO NOTHING -> die Zeile hier bleibt, nur label/ord werden nachgezogen).
-- Frische Installation: onboarding_state ist hier noch leer -> nichts eingefuegt -> der Seeder legt 'unknown' an.
INSERT INTO finance.onboarding_state (section_key, ord, label, status)
SELECT 'monthly_check', 6, 'Monats-Check (Kontoauszug)', 'completed'
WHERE EXISTS (SELECT 1 FROM finance.onboarding_state)
  AND NOT EXISTS (SELECT 1 FROM finance.onboarding_state WHERE status = 'unknown')
ON CONFLICT (section_key) DO NOTHING;
