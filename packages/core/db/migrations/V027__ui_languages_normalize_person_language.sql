-- ============================================================
-- V027 (core) — unterstuetzte Sprachen anlegen + family.persons[].language auf deren Codes normieren.
--
--   WARUM: bis v0.5.0 war language ein Freitext-Fakt ohne Wertevorrat ("Deutsch", "Korean", "de", ...). Seit dem
--   Textkatalog bestimmt er die Sprache fester Texte, und der Validator agent.fn_validate_household_facts laesst nur
--   noch Codes aus core.ui_languages zu (Init). Ohne diese Migration haette ein Update zwei Brueche:
--   (1) core.ui_languages ist beim V-Lauf noch leer (Seed laeuft erst nach Init -> V -> R), der Backfill-UPDATE
--       feuerte den Validator und lehnte sogar 'de' ab -> darum legt (1) die Basis-Codes VORAB an. Der Manifest-
--       Block "languages" (core) bleibt die SoT fuer Name/Locale/Reihenfolge/Aliase: _seed_ui_languages upsertet
--       spaeter darueber (contract_lint prueft: diese Liste ⊆ Manifest).
--   (2) jeder spaetere family-Write scheiterte an einem Alt-Freitext -> (2) normiert den Bestand.
--
--   Normierung (dieselbe Regel wie agent.fn_normalize_language, hier inline, weil V vor den R__-fns laeuft):
--   lower(trim()) -> Region abschneiden (ko-KR -> ko) -> Code ODER Alias aus core.ui_languages. Nicht abbildbar:
--   Owner -> 'de' (bisherige Sprache aller Texte), Mitglied -> Key entfernt (Fallback Owner-Sprache zur Laufzeit).
--   Offene Lern-Kandidaten mit field='language' brauchen nichts: ihre Freigabe laeuft ueber fn_set_context_facts,
--   das seit diesem Release normalisiert.
--
--   IDEMPOTENT: V laeuft genau einmal (ledger-gegated); frische DB = Codes anlegen, family fehlt noch (no-op).
-- APPLY-ORDER: Inits -> V (hier) -> R -> Seed.
-- ============================================================

INSERT INTO core.ui_languages (code, name, locale, ord, aliases) VALUES
    ('de', 'Deutsch', 'de-DE', 1, ARRAY['deutsch', 'german', 'allemand']),
    ('en', 'English', 'en-GB', 2, ARRAY['english', 'englisch']),
    ('ko', '한국어',  'ko-KR', 3, ARRAY['korean', 'koreanisch', '한국어', '한국말'])
ON CONFLICT (code) DO NOTHING;

UPDATE agent.core_contexts c
   SET metadata = jsonb_set(c.metadata, '{facts,persons}', (
       SELECT jsonb_agg(
                CASE
                  WHEN n.code IS NOT NULL      THEN e.pp || jsonb_build_object('language', n.code)
                  WHEN e.pp->>'role' = 'owner' THEN e.pp || jsonb_build_object('language', 'de')
                  ELSE e.pp - 'language'
                END ORDER BY e.ord)
         FROM jsonb_array_elements(c.metadata->'facts'->'persons') WITH ORDINALITY AS e(pp, ord)
         LEFT JOIN LATERAL (
              SELECT l.code
                FROM core.ui_languages l
               WHERE l.code = regexp_replace(lower(trim(e.pp->>'language')), '^([a-z]{2})[-_][a-z0-9]+$', '\1')
                  OR lower(trim(e.pp->>'language')) = any (l.aliases)
               ORDER BY l.ord
               LIMIT 1) n ON TRUE))
 WHERE c.name = 'family'
   AND jsonb_typeof(c.metadata->'facts'->'persons') = 'array'
   AND jsonb_array_length(c.metadata->'facts'->'persons') > 0;
