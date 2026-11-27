-- ============================================================
-- estate.v_task_templates (Vorlagen-Katalog mit Texten — die eine Render-Adresse der Aufgaben-Texte)
--   Eine Zeile je Vorlage aus estate.task_templates plus title/detail aus dem Textkatalog
--   (estate.task.<template_key>.title|.detail) in der Haushalts-Sprache (core.fn_ui_texts_for ohne chat_id = Owner).
--   Fallback-Kette des Katalogs endet beim Key selbst: fehlt der .title-Key, ist title der Key-String; fehlt der
--   .detail-Key, ist detail NULL (Vorlage ohne Erklaerung).
--   Konsumiert von estate.fn_case_template_rows (Soll-Satz eines Falls) + estate_ro (Frei-SQL des Beraters im
--   Vorsorge-Modus: was nach einem Ereignis zu tun ist, ohne Fall).
-- ============================================================
DROP VIEW IF EXISTS estate.v_task_templates CASCADE;
CREATE VIEW estate.v_task_templates AS
WITH tx AS (
    SELECT t.template_key,
           core.fn_ui_texts_for(jsonb_build_object('keys', jsonb_build_array(
               'estate.task.' || t.template_key || '.title', 'estate.task.' || t.template_key || '.detail')))->'t' AS t
    FROM estate.task_templates t
)
SELECT t.template_key, t.case_type, t.phase, t.ord,
       coalesce(x.t->>('estate.task.' || t.template_key || '.title'), 'estate.task.' || t.template_key || '.title') AS title,
       nullif(x.t->>('estate.task.' || t.template_key || '.detail'), 'estate.task.' || t.template_key || '.detail') AS detail,
       t.deadline_anchor, t.offset_count, t.offset_unit, t.condition_key, t.fan_out, t.legal_source, t.hardness, t.retired
FROM estate.task_templates t
JOIN tx x ON x.template_key = t.template_key;
