-- ============================================================
-- estate.v_register_gaps (Gap-View, WS-2 — offene Feld-/Zeilen-Luecken der estate-Register)
--   Eine Zeile = ein konkreter, handlungsfaehiger Gap:
--     * provider_contract: death_action NULL (Todesfall-Aktion nicht entschieden)
--     * digital_account:   desired_action NULL (Todesfall-Aktion nicht entschieden)
--     * digital_account:   SCHLUESSELKONTO ohne access_path (im Ereignisfall gatet das
--                          E-Mail-Konto alle Resets — ohne Zugangs-Fundort kritisch)
--     * person_record:     Erwachsener ganz OHNE Stammdaten-Zeile
--     * funeral_preferences: Erwachsener ganz OHNE Bestattungswuensche-Zeile
--   gap_code (Textkatalog Phase C) = stabiler Code; die Anzeige rendert estate.gap.<code> in der Sprache des Lesers
--   (fn_render_register_body). gap = englischer Modelltext (Sprachpolitik: der estate_ro-Frei-SQL-Leser ist das LLM).
--   Personen-Zeilen-Gaps nur fuer Erwachsene (owner|partner — wie v_directive_gaps).
--   Personen-Quelle = core.fn_household_persons() (View laeuft mit Owner-Rechten).
--   Konsumiert von estate.fn_gap_report + estate_ro (Frei-SQL).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__v_register_gaps.sql
-- ============================================================
DROP VIEW IF EXISTS estate.v_register_gaps CASCADE;
CREATE VIEW estate.v_register_gaps AS
SELECT 'provider_contract'::text AS area,
       c.id                      AS ref_id,
       c.owner_person_id         AS person_id,
       c.provider                AS item,
       'Death action OPEN (cancel/transfer/keep not decided)'::text AS gap,
       'death_action_open'::text AS gap_code
FROM estate.provider_contracts c
WHERE c.death_action IS NULL
UNION ALL
SELECT 'digital_account', a.id, a.owner_person_id, a.provider,
       'Death action OPEN (delete/memorialize/transfer/keep not decided)', 'digital_action_open'
FROM estate.digital_accounts a
WHERE a.desired_action IS NULL
UNION ALL
SELECT 'digital_account', a.id, a.owner_person_id, a.provider,
       'KEY ACCOUNT without access location (access_path) - in an event it gates every reset', 'key_account_no_access'
FROM estate.digital_accounts a
WHERE a.is_key_account AND a.access_path IS NULL
UNION ALL
SELECT 'person_record', NULL::bigint, hp.person_id, hp.full_name,
       'Official records missing entirely (tax ID, pension insurance no., health insurer, certificates location)',
       'person_record_missing'
FROM core.fn_household_persons() hp
WHERE hp.role IN ('owner', 'partner')
  AND NOT EXISTS (SELECT 1 FROM estate.person_records pr WHERE pr.person_id = hp.person_id)
UNION ALL
SELECT 'funeral_preferences', NULL::bigint, hp.person_id, hp.full_name,
       'Funeral wishes not recorded (prepaid funeral contract unclear)', 'funeral_missing'
FROM core.fn_household_persons() hp
WHERE hp.role IN ('owner', 'partner')
  AND NOT EXISTS (SELECT 1 FROM estate.funeral_preferences f WHERE f.person_id = hp.person_id);
