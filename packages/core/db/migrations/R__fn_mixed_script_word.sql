-- ============================================================
-- core.fn_mixed_script_word(p_text) — erstes Wort aus lateinischen und anderen Schriftzeichen
--   Modelle setzen gelegentlich fremde Zeichen mitten in ein Wort ("Notgro세schen"). Fehler ist ein Wort (Folge ohne Leerraum),
--   in dem Buchstaben aus Hangul, CJK/Kana, Kyrillisch oder Griechisch zwischen lateinischen Buchstaben stehen. Erlaubt bleiben
--   getrennte Woerter verschiedener Schrift und angehaengte Endungen ("ETF는", "App에서": Koreanisch und Japanisch
--   haengen Partikel direkt an lateinische Namen).
--   Rueckgabe: das Wort (Satzzeichen am Rand abgeschnitten) oder NULL.
--   Tests: tests/db/core/test_fn_advisor_save_section_fields.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_mixed_script_word(p_text text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT btrim(m[1], '.,;:!?()[]"''«»„“”')
      FROM regexp_matches(COALESCE(p_text, ''), '(\S+)', 'g') AS m
     WHERE m[1] ~ '[A-Za-zÀ-ɏ][Ͱ-ϿЀ-ӿᄀ-ᇿ぀-ヿ㐀-鿿가-힯]+[A-Za-zÀ-ɏ]'
     LIMIT 1;
$$;
