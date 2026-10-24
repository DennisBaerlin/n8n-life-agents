-- ============================================================
-- core.fn_split_learned_block(p_content text, OUT body text, OUT block text)   (Phase A — "## Gelernt" verwaltet)
--   Trennt den system-verwalteten Lern-Notiz-Block eines Prosa-Kontexts vom Rest (Ansible-blockinfile-Muster):
--   block = ab der ERSTEN Zeile '^## Gelernt\s*$' bis VOR die naechste '^## '-Ueberschrift (eine '### '-Unter-
--   ueberschrift gehoert dazu) oder Textende, rechts getrimmt; body = der Text ohne diesen Block, rechts
--   getrimmt. Kein Block -> body = Eingabe, block = NULL. Der Block darf Leerzeilen enthalten
--   (core.fn_append_context_note fuegt neueste zuerst direkt nach der Ueberschrift ein).
--   EINE Definition des Ankers fuer: core.fn_append_context_note (Ziel-Ueberschrift) und
--   agent.fn_advisor_publish_plan (Block beim Re-Publish erhalten, im neuen plan_md mitgeschickten verwerfen —
--   sonst loeschte jeder Publish still alle bestaetigten Notizen).
--   IMMUTABLE, rein textuell, kein Tabellenzugriff.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_split_learned_block(p_content text, OUT body text, OUT block text)
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_lines text[] := string_to_array(COALESCE(p_content, ''), E'\n');
    v_n     int;
    v_start int;
    v_end   int;
    v_i     int;
BEGIN
    v_n := COALESCE(array_length(v_lines, 1), 0);
    FOR v_i IN 1 .. v_n LOOP
        IF v_lines[v_i] ~ '^## Gelernt\s*$' THEN v_start := v_i; EXIT; END IF;
    END LOOP;
    IF v_start IS NULL THEN
        body  := p_content;
        block := NULL;
        RETURN;
    END IF;
    v_end := v_n;
    FOR v_i IN v_start + 1 .. v_n LOOP
        IF v_lines[v_i] ~ '^## ' THEN v_end := v_i - 1; EXIT; END IF;
    END LOOP;
    block := rtrim(array_to_string(v_lines[v_start:v_end], E'\n'), E'\n ');
    body  := rtrim(array_to_string(v_lines[1:v_start - 1] || v_lines[v_end + 1:v_n], E'\n'), E'\n ');
END;
$$;
