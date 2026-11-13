-- tests/db/core/test_fn_release_card.sql
-- Update-Hinweis: Release-Karte fuer den Owner.
--   core.fn_semver_cmp(a,b)      = die eine SemVer-Logik (nur stabile vX.Y.Z, sonst NULL).
--   core.fn_release_intro(body)  = Kurzfassung = Einleitungsabsatz der Tag-Nachricht (bis Leerzeile/##/---),
--                                  Markdown-Zeichen raus, <= 300 Zeichen.
--   core.fn_release_card(p)      = faellig? + Text + Knoepfe in Owner-Sprache; merkt nichts.
--   core.fn_release_card_sent(t) = Latch erst nach erfolgreichem Senden (core.fn_should_notify).
-- db_test hat kein seed_data -> family + Config self-seeden; Texte fallen auf den Key zurueck (Assertions auf Keys).
BEGIN;
SET LOCAL TimeZone = 'Europe/Berlin';

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'release_card fixture', NULL, 'lazy', E'## fam',
        jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
          jsonb_build_object('person_id','rc_owner','first_name','RC','last_name','Owner',
                             'role','owner','birth_date','1980-01-01','telegram_user_id',8101,'language','de','as_of','2026-10-24')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;

INSERT INTO core.config (package, category, key, value) VALUES ('core', 'feature', 'update_check', 'true')
ON CONFLICT (category, key) DO UPDATE SET value = excluded.value;

DO $$
DECLARE
  r     jsonb;
  v_rel jsonb;
  v_txt text;
  v_long text := repeat('Wort ', 100);
  v_body text;
  v_night text;
  v_noon  text;
BEGIN
  -- ---------- 1) SemVer ----------
  IF core.fn_semver_cmp('v0.10.0', 'v0.9.2') IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [1a 0.10 > 0.9]'; END IF;
  IF core.fn_semver_cmp('v0.9.9', 'v0.10.0') IS DISTINCT FROM -1 THEN RAISE EXCEPTION 'FAIL [1b 0.9.9 < 0.10.0]'; END IF;
  IF core.fn_semver_cmp('v1.2.3', 'v1.2.3') IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [1c gleich]'; END IF;
  IF core.fn_semver_cmp('v2.0.0', 'v1.99.99') IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [1d major]'; END IF;
  IF core.fn_semver_cmp('dev', 'v0.1.0') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1e dev -> NULL]'; END IF;
  IF core.fn_semver_cmp('v1.0.0-rc1', 'v1.0.0') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1f Prerelease -> NULL]'; END IF;
  IF core.fn_semver_cmp(NULL, 'v1.0.0') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1g NULL]'; END IF;

  -- ---------- 2) Kurzfassung ----------
  IF core.fn_release_intro(E'Kurz **fett** und `code`.\n\n## Details\n- x') IS DISTINCT FROM 'Kurz fett und code.' THEN
    RAISE EXCEPTION 'FAIL [2a Markdown raus, bis Leerzeile]: %', core.fn_release_intro(E'Kurz **fett** und `code`.\n\n## Details\n- x'); END IF;
  IF core.fn_release_intro(E'Zeile eins\r\nZeile zwei\n---\nInstallation …') IS DISTINCT FROM 'Zeile eins Zeile zwei' THEN
    RAISE EXCEPTION 'FAIL [2b bis --- + Zeilen verbunden]: %', core.fn_release_intro(E'Zeile eins\r\nZeile zwei\n---\nInstallation …'); END IF;
  IF core.fn_release_intro(E'Text\n## Abschnitt') IS DISTINCT FROM 'Text' THEN RAISE EXCEPTION 'FAIL [2c bis ##]'; END IF;
  IF core.fn_release_intro(E'## Nur Überschrift\n- a') IS DISTINCT FROM '' THEN RAISE EXCEPTION 'FAIL [2d beginnt mit ## -> leer]'; END IF;
  IF length(core.fn_release_intro(v_long)) > 300 OR right(core.fn_release_intro(v_long), 1) <> '…' THEN
    RAISE EXCEPTION 'FAIL [2e gekuerzt auf 300 mit …]'; END IF;
  IF core.fn_release_intro(NULL) IS DISTINCT FROM '' THEN RAISE EXCEPTION 'FAIL [2f NULL -> leer]'; END IF;

  -- ---------- 3) Karte: Filter, Reihenfolge, Knoepfe ----------
  v_rel := '[
    {"tag":"v0.15.0","draft":false,"prerelease":false,"body":"Neu B.","html_url":"https://example.org/r/v0.15.0","assets":["SHA256SUMS","SHA256SUMS.sig"]},
    {"tag":"v0.14.1","draft":false,"prerelease":false,"body":"Neu A.","html_url":"https://example.org/r/v0.14.1","assets":["SHA256SUMS","SHA256SUMS.sig"]},
    {"tag":"v0.16.0-rc1","draft":false,"prerelease":true,"body":"RCX","html_url":"https://example.org/r/rc","assets":[]},
    {"tag":"v0.17.0","draft":true,"prerelease":false,"body":"DRAFTX","html_url":"https://example.org/r/d","assets":[]},
    {"tag":"nightly","draft":false,"prerelease":false,"body":"NIGHTX","html_url":"https://example.org/r/n","assets":[]},
    {"tag":"v0.14.0","draft":false,"prerelease":false,"body":"ALTX","html_url":"https://example.org/r/v0.14.0","assets":[]},
    {"tag":"v0.13.0","draft":false,"prerelease":false,"body":"AELTERX","html_url":"https://example.org/r/v0.13.0","assets":[]}
  ]'::jsonb;
  r := core.fn_release_card(jsonb_build_object('installed', 'v0.14.0', 'releases', v_rel));
  IF (r->>'due')::boolean IS NOT TRUE OR r->>'tag' IS DISTINCT FROM 'v0.15.0' THEN
    RAISE EXCEPTION 'FAIL [3a faellig, neuester Tag]: %', r; END IF;
  v_txt := r->>'text';
  IF position('Neu B.' IN v_txt) = 0 OR position('Neu A.' IN v_txt) = 0 THEN RAISE EXCEPTION 'FAIL [3b beide Kurzfassungen]: %', v_txt; END IF;
  IF position('Neu B.' IN v_txt) > position('Neu A.' IN v_txt) THEN RAISE EXCEPTION 'FAIL [3c neueste zuerst]: %', v_txt; END IF;
  IF v_txt ~ '(RCX|DRAFTX|NIGHTX|ALTX|AELTERX)' THEN RAISE EXCEPTION 'FAIL [3d Filter Prerelease/Draft/Nicht-SemVer/alt]: %', v_txt; END IF;
  IF position('core.update.card.title' IN v_txt) = 0 THEN RAISE EXCEPTION 'FAIL [3e Titel-Key]: %', v_txt; END IF;
  IF r#>>'{keyboard,0,0,callback_data}' IS DISTINCT FROM 'upd:now:v0.15.0' THEN RAISE EXCEPTION 'FAIL [3f Knopf]: %', r->'keyboard'; END IF;
  IF r#>>'{keyboard,1,0,url}' IS DISTINCT FROM 'https://example.org/r/v0.15.0' THEN RAISE EXCEPTION 'FAIL [3g Link]: %', r->'keyboard'; END IF;

  -- ---------- 4) Karte merkt nichts; erst _sent latcht ----------
  r := core.fn_release_card(jsonb_build_object('installed', 'v0.14.0', 'releases', v_rel));
  IF (r->>'due')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [4a ohne _sent weiter faellig]: %', r; END IF;
  IF core.fn_release_card_sent('v0.15.0') IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [4b _sent -> true]'; END IF;
  r := core.fn_release_card(jsonb_build_object('installed', 'v0.14.0', 'releases', v_rel));
  IF (r->>'due')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'notified' THEN RAISE EXCEPTION 'FAIL [4c gemerkt]: %', r; END IF;
  IF core.fn_release_card_sent('v0.15.0') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [4d zweites _sent -> false]'; END IF;
  IF core.fn_release_card_sent('nightly') IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [4e kaputter Tag -> false]'; END IF;

  -- ---------- 5) Nicht faellig: dev / aktuell / kaputte Eingaben ----------
  r := core.fn_release_card(jsonb_build_object('installed', 'dev', 'releases', v_rel));
  IF (r->>'due')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'not_release' THEN RAISE EXCEPTION 'FAIL [5a dev]: %', r; END IF;
  r := core.fn_release_card(jsonb_build_object('installed', 'v0.15.0', 'releases', v_rel));
  IF (r->>'due')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'up_to_date' THEN RAISE EXCEPTION 'FAIL [5b aktuell]: %', r; END IF;
  r := core.fn_release_card('{"installed":"v0.14.0","releases":"kaputt"}'::jsonb);
  IF (r->>'due')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5c releases kein Array]: %', r; END IF;
  r := core.fn_release_card(NULL);
  IF (r->>'due')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5d NULL]: %', r; END IF;

  -- ---------- 6) Signatur-Pflicht: Release ohne SHA256SUMS.sig zaehlt nicht ----------
  r := core.fn_release_card(jsonb_build_object('installed', 'v0.14.0', 'require_signature', true, 'releases',
         '[{"tag":"v0.18.0","draft":false,"prerelease":false,"body":"Ohne Sig.","html_url":"https://example.org/r/v0.18.0","assets":["SHA256SUMS"]},
           {"tag":"v0.14.1","draft":false,"prerelease":false,"body":"Mit Sig.","html_url":"https://example.org/r/v0.14.1","assets":["SHA256SUMS","SHA256SUMS.sig"]}]'::jsonb));
  IF r->>'tag' IS DISTINCT FROM 'v0.14.1' OR position('Ohne Sig.' IN r->>'text') > 0 THEN
    RAISE EXCEPTION 'FAIL [6 unsigniert ignoriert]: %', r; END IF;

  -- ---------- 7) hoechstens 3 Kurzfassungen (die neuesten) ----------
  r := core.fn_release_card(jsonb_build_object('installed', 'v1.0.0', 'releases',
         '[{"tag":"v1.0.1","draft":false,"prerelease":false,"body":"K1X","html_url":"u1","assets":[]},
           {"tag":"v1.0.2","draft":false,"prerelease":false,"body":"K2X","html_url":"u2","assets":[]},
           {"tag":"v1.0.3","draft":false,"prerelease":false,"body":"K3X","html_url":"u3","assets":[]},
           {"tag":"v1.0.4","draft":false,"prerelease":false,"body":"K4X","html_url":"u4","assets":[]}]'::jsonb));
  IF r->>'tag' IS DISTINCT FROM 'v1.0.4' OR position('K1X' IN r->>'text') > 0 OR position('K2X' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL [7 drei neueste]: %', r; END IF;

  -- ---------- 8) Schalter aus -> nicht faellig (fail-closed auch ohne Zeile) ----------
  UPDATE core.config SET value = 'false' WHERE package = 'core' AND category = 'feature' AND key = 'update_check';
  r := core.fn_release_card(jsonb_build_object('installed', 'v1.0.0', 'releases', '[{"tag":"v1.0.9","draft":false,"prerelease":false,"body":"x","html_url":"u","assets":[]}]'::jsonb));
  IF (r->>'due')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'disabled' THEN RAISE EXCEPTION 'FAIL [8a aus]: %', r; END IF;
  DELETE FROM core.config WHERE package = 'core' AND category = 'feature' AND key = 'update_check';
  r := core.fn_release_card(jsonb_build_object('installed', 'v1.0.0', 'releases', '[{"tag":"v1.0.9","draft":false,"prerelease":false,"body":"x","html_url":"u","assets":[]}]'::jsonb));
  IF (r->>'due')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'disabled' THEN RAISE EXCEPTION 'FAIL [8b ohne Zeile]: %', r; END IF;

  -- ---------- 9) Sprache: summary:<lang>-Marker (HTML-Kommentar nach dem Einleitungsabsatz) ----------
  -- Dieselben Faelle liegen als Dateien in tests/fixtures/release_notes/ (Pruefskript-Test); db_test kann keine
  -- Repo-Dateien lesen -> hier inline. Aenderungen an beiden Stellen.
  v_body := E'English intro.\n\n<!-- summary:de\nDeutsche **Kurzfassung**,\nzweite Zeile mit [Link](https://example.org/x).\n-->\n\n'
         || E'<!-- summary:ko\n한국어 요약입니다.\n-->\n\n## Changes\n- x';
  IF core.fn_release_intro(v_body, 'de') IS DISTINCT FROM 'Deutsche Kurzfassung, zweite Zeile mit Link.' THEN
    RAISE EXCEPTION 'FAIL [9a de-Marker, Markdown raus, Zeilen verbunden]: %', core.fn_release_intro(v_body, 'de'); END IF;
  IF core.fn_release_intro(v_body, 'ko') IS DISTINCT FROM '한국어 요약입니다.' THEN
    RAISE EXCEPTION 'FAIL [9b zwei Marker: lazy, jeder fuer sich]: %', core.fn_release_intro(v_body, 'ko'); END IF;
  IF core.fn_release_intro(v_body, 'en') IS DISTINCT FROM 'English intro.' THEN
    RAISE EXCEPTION 'FAIL [9c en = Einleitungsabsatz, Marker nicht im Intro]: %', core.fn_release_intro(v_body, 'en'); END IF;
  IF core.fn_release_intro(v_body) IS DISTINCT FROM 'English intro.' THEN
    RAISE EXCEPTION 'FAIL [9d 1-Argument-Aufruf = Intro]'; END IF;
  IF core.fn_release_intro(E'English only.\n\n## Changes', 'ko') IS DISTINCT FROM 'English only.' THEN
    RAISE EXCEPTION 'FAIL [9e Marker fehlt -> englischer Absatz]'; END IF;
  IF core.fn_release_intro(E'English intro.\n\n<!-- summary:de\n   \n-->\n\n## Changes', 'de') IS DISTINCT FROM 'English intro.' THEN
    RAISE EXCEPTION 'FAIL [9f leerer Marker -> Fallback]'; END IF;
  IF core.fn_release_intro(E'English intro.

<!-- summary:de
**
-->

## Changes', 'de') IS DISTINCT FROM 'English intro.' THEN
    RAISE EXCEPTION 'FAIL [9f2 Marker nach Bereinigung leer -> Rueckfall]'; END IF;
  IF core.fn_release_intro(v_body, NULL) IS DISTINCT FROM 'English intro.'
     OR core.fn_release_intro(v_body, 'de|.*') IS DISTINCT FROM 'English intro.'
     OR core.fn_release_intro(v_body, '') IS DISTINCT FROM 'English intro.' THEN
    RAISE EXCEPTION 'FAIL [9g lang NULL/Muell -> Fallback, keine Regex-Injektion]'; END IF;
  v_txt := core.fn_release_intro(E'Intro.\n\n<!-- summary:de\n' || v_long || E'\n-->', 'de');
  IF length(v_txt) > 300 OR right(v_txt, 1) <> '…' THEN RAISE EXCEPTION 'FAIL [9h Marker auf 300 gekuerzt]: %', length(v_txt); END IF;
  IF core.fn_release_intro(E'Intro.\r\n\r\n<!--  summary:de\r\nMit CRLF.\r\n-->\r\n', 'de') IS DISTINCT FROM 'Mit CRLF.' THEN
    RAISE EXCEPTION 'FAIL [9i CRLF + doppeltes Leerzeichen]'; END IF;

  -- Karte in Owner-Sprache (Fixture: Owner de)
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'feature', 'update_check', 'true')
    ON CONFLICT (category, key) DO UPDATE SET value = excluded.value;
  v_rel := jsonb_build_array(jsonb_build_object('tag', 'v2.0.1', 'draft', false, 'prerelease', false,
             'body', E'English card text.\n\n<!-- summary:de\nDeutscher Kartentext.\n-->\n\n## Changes',
             'html_url', 'https://example.org/r/v2.0.1', 'assets', jsonb_build_array()));
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel));
  IF position('Deutscher Kartentext.' IN r->>'text') = 0 OR position('English card text.' IN r->>'text') > 0 THEN
    RAISE EXCEPTION 'FAIL [9j Karte zeigt deutschen Text]: %', r->>'text'; END IF;
  UPDATE agent.core_contexts
     SET metadata = jsonb_set(metadata, '{facts,persons,0,language}', '"en"')
   WHERE name = 'family';
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel));
  IF position('English card text.' IN r->>'text') = 0 OR position('Deutscher Kartentext.' IN r->>'text') > 0 THEN
    RAISE EXCEPTION 'FAIL [9k Owner en -> englisch]: %', r->>'text'; END IF;
  UPDATE agent.core_contexts
     SET metadata = jsonb_set(metadata, '{facts,persons,0,language}', '"ko"')
   WHERE name = 'family';
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel));
  IF position('English card text.' IN r->>'text') = 0 THEN
    RAISE EXCEPTION 'FAIL [9l Owner ko ohne ko-Marker -> englischer Fallback]: %', r->>'text'; END IF;
  UPDATE agent.core_contexts
     SET metadata = jsonb_set(metadata, '{facts,persons,0,language}', '"de"')
   WHERE name = 'family';

  -- ---------- 10) Fenster: scheduled-Check nur im Erinnerungs-Fenster ----------
  DELETE FROM core.config WHERE category = 'general' AND key IN ('reminders_from', 'reminders_until');
  v_night := ((timestamp '2026-11-07 03:00') AT TIME ZONE current_setting('TimeZone'))::text;
  v_noon  := ((timestamp '2026-11-07 12:00') AT TIME ZONE current_setting('TimeZone'))::text;
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel, 'scheduled', true, 'at', v_night));
  IF (r->>'due')::boolean IS NOT FALSE OR r->>'reason' IS DISTINCT FROM 'outside_window' THEN
    RAISE EXCEPTION 'FAIL [10a nachts + scheduled -> outside_window]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state n WHERE n.source = 'release_update' AND n.key = 'v2.0.1') THEN
    RAISE EXCEPTION 'FAIL [10b outside_window latcht nicht]'; END IF;
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel, 'scheduled', true, 'at', v_noon));
  IF (r->>'due')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [10c mittags + scheduled -> faellig]: %', r; END IF;
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel, 'at', v_night));
  IF (r->>'due')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [10d nachts ohne scheduled (Handaufruf) -> faellig]: %', r; END IF;
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel, 'scheduled', false, 'at', v_night));
  IF (r->>'due')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [10e scheduled=false -> faellig]: %', r; END IF;
  INSERT INTO core.config (package, category, key, value) VALUES
    ('core', 'general', 'reminders_from', '2'), ('core', 'general', 'reminders_until', '22');
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel, 'scheduled', true, 'at', v_night));
  IF (r->>'due')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [10f Fenster 2-22 per Config folgt]: %', r; END IF;
  DELETE FROM core.config WHERE category = 'general' AND key IN ('reminders_from', 'reminders_until');
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel, 'scheduled', true, 'at', 'kein-datum'));
  IF r->>'due' IS NULL THEN RAISE EXCEPTION 'FAIL [10g at Muell -> kein RAISE, Antwort]: %', r; END IF;
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel, 'scheduled', true, 'at', v_night));
  PERFORM core.fn_release_card_sent('v2.0.1');
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.1', 'releases', v_rel, 'scheduled', true, 'at', v_night));
  IF r->>'reason' IS DISTINCT FROM 'up_to_date' THEN RAISE EXCEPTION 'FAIL [10h nachts + nichts Neues -> up_to_date]: %', r; END IF;
  r := core.fn_release_card(jsonb_build_object('installed', 'v2.0.0', 'releases', v_rel, 'scheduled', true, 'at', v_night));
  IF r->>'reason' IS DISTINCT FROM 'notified' THEN RAISE EXCEPTION 'FAIL [10i nachts + gemerkt -> notified vor outside_window]: %', r; END IF;

  RAISE NOTICE 'test_fn_release_card: alle Faelle gruen';
END $$;

ROLLBACK;
