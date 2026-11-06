-- tests/db/core/test_fn_smalltalk_kind.sql
-- core.fn_smalltalk_kind(text): 'thanks' | 'greeting' | NULL — EXAKTER Abgleich nach Normalisierung.
--   * reiner Dank (de/en/ko, Herz allein, Dank + Deko-Emoji/Satzzeichen) -> 'thanks'
--   * jedes weitere Wort -> NULL (nein danke / ja danke / gerne danke sind Antworten, kein Dank)
--   * 👍 / ok allein sind nie Dank (moegliches Ja auf eine Rueckfrage)
--   * reiner Gruss -> 'greeting'; Gruss + Inhalt -> NULL
BEGIN;

DO $$
DECLARE
  r RECORD;
  v TEXT;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('Danke', 'thanks'), ('danke!', 'thanks'), ('  Danke dir :) ', 'thanks'), ('Danke dir!', 'thanks'),
      ('Vielen Dank!!', 'thanks'), ('Dankeschön', 'thanks'), ('danke schön', 'thanks'), ('Danke sehr.', 'thanks'),
      ('Danke ❤️', 'thanks'), ('Danke 🙏', 'thanks'), ('danke 👍', 'thanks'), ('❤️', 'thanks'), ('❤', 'thanks'),
      ('❤️❤️', 'thanks'), ('🥰', 'thanks'), ('Thanks', 'thanks'), ('thank you!', 'thanks'), ('thx', 'thanks'),
      ('Merci', 'thanks'), ('고마워요', 'thanks'), ('감사합니다!', 'thanks'), ('고맙습니다', 'thanks'),
      ('nein danke', NULL), ('ja danke', NULL), ('danke nein', NULL), ('gerne danke', NULL), ('ja, danke', NULL),
      ('네 감사합니다', NULL), ('no thanks', NULL), ('Danke, und buch noch 5 € Kaffee', NULL),
      ('👍', NULL), ('ok', NULL), ('Okay danke', NULL), ('🙏', NULL), ('', NULL), (NULL, NULL),
      ('Hallo', 'greeting'), ('hallo!', 'greeting'), ('Hi 👋', 'greeting'), ('Guten Morgen', 'greeting'),
      ('Moin', 'greeting'), ('hey', 'greeting'), ('Hello', 'greeting'), ('Good morning!', 'greeting'),
      ('안녕하세요', 'greeting'), ('안녕', 'greeting'),
      ('Hallo, mein Vater ist gestorben', NULL), ('Hi, buch 5 € Kaffee', NULL), ('hallo danke', NULL)
    ) AS t(input, expected)
  LOOP
    v := core.fn_smalltalk_kind(r.input);
    IF v IS DISTINCT FROM r.expected THEN
      RAISE EXCEPTION 'FAIL fn_smalltalk_kind [% -> % (erwartet %)]', quote_nullable(r.input), quote_nullable(v), quote_nullable(r.expected);
    END IF;
  END LOOP;

  RAISE NOTICE 'PASS fn_smalltalk_kind [Dank exakt, Antworten mit Dank kein Dank, 👍/ok nie, Gruss exakt]';
END $$;

ROLLBACK;
