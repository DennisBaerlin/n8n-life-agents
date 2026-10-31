-- ============================================================
-- core.fn_smalltalk_kind (Klassifikator fuer reinen Dank / reinen Gruss, Bot mit Gesicht 2026-10-30)
--   Deterministisch statt LLM: der Orchestrator setzt bei 'thanks' nur ein Herz (kein Agent-Lauf), bei
--   'greeting' darf fn_claim_persona_sticker einen Hallo-Sticker waehlen. Darum EXAKTER Abgleich nach
--   Normalisierung (Kleinschreibung, Emoji-Varianten/Hautton/ZWJ, Satzzeichen, Leerraum): jedes weitere Wort
--   -> NULL. "nein danke", "ja danke", "gerne danke", "네 감사합니다" sind Antworten auf eine Rueckfrage, kein
--   Dank; 👍 und "ok" allein koennen ein Ja sein und zaehlen nie. Deko-Emoji (Herzen, 🙏, 🙂, 👍 ...) fallen nur
--   NEBEN einem Wort weg; allein zaehlen nur Herzen als Dank.
--   Die Listen sind bewusst kurz und exakt (de/en/ko = core.ui_languages); fehlt ein Ausdruck, laeuft die
--   Nachricht ganz normal ueber den Router (fail-safe).
--   RUECKGABE: 'thanks' | 'greeting' | NULL
--   Tests: tests/db/core/test_fn_smalltalk_kind.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_smalltalk_kind(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    -- Herzen (allein = Dank) und weitere Deko-Emoji (nur neben einem Wort erlaubt)
    c_hearts constant text := '\u2764\u2665\U0001F9E1\U0001F49B\U0001F49A\U0001F499\U0001F49C\U0001F5A4\U0001F90D\U0001F90E'
                              '\U0001F495\U0001F496\U0001F497\U0001F493\U0001F49E\U0001F970\U0001F60D\U0001F618\U0001FA77';
    c_deco   constant text := '\U0001F64F\U0001F60A\U0001F642\U0001F600\U0001F603\U0001F604\U0001F601\U0001F917\U0001F44D'
                              '\U0001F44C\U0001F389\u263A\U0001F44B';
    c_thanks constant text[] := ARRAY[
        'danke', 'danke dir', 'danke euch', 'danke sehr', 'danke schön', 'dankeschön',
        'vielen dank', 'vielen lieben dank', 'tausend dank', 'herzlichen dank', 'merci',
        'thx', 'thanks', 'thank you', 'thank you so much', 'thanks a lot', 'many thanks', 'ty',
        '고마워', '고마워요', '고맙습니다', '감사합니다', '감사해요'];
    c_greet  constant text[] := ARRAY[
        'hallo', 'hallöchen', 'hi', 'hey', 'moin', 'moin moin', 'servus', 'guten morgen', 'guten tag', 'guten abend',
        'hello', 'good morning', 'good afternoon', 'good evening',
        '안녕', '안녕하세요', '좋은 아침', '좋은 아침이에요'];
    v text;
BEGIN
    v := lower(btrim(COALESCE(p_text, '')));
    -- Varianten-Selektor, ZWJ, Hautton-Modifikatoren weg (\u2764\uFE0F = U+2764 U+FE0F)
    v := regexp_replace(v, '[\uFE0F\u200D\U0001F3FB-\U0001F3FF]', '', 'g');
    IF v = '' THEN
        RETURN NULL;
    END IF;
    IF regexp_replace(v, '\s+', '', 'g') ~ ('^[' || c_hearts || ']+$') THEN
        RETURN 'thanks';
    END IF;
    v := regexp_replace(v, '[' || c_hearts || c_deco || ']', ' ', 'g');
    v := regexp_replace(v, '[!"#$%&''()*+,./:;<=>?@\[\\\]^_`{|}~…¡¿“”„‘’«»。、！？-]', ' ', 'g');
    v := btrim(regexp_replace(v, '\s+', ' ', 'g'));
    IF v = '' THEN
        RETURN NULL;
    END IF;
    IF v = ANY (c_thanks) THEN
        RETURN 'thanks';
    END IF;
    IF v = ANY (c_greet) THEN
        RETURN 'greeting';
    END IF;
    RETURN NULL;
END;
$$;
