-- ============================================================
-- estate.fn_render_emergency_binder (READ — die druckbare Notfallmappe, der groesste PII-Egress)
--   Rendert die ganze Nachlass-Registratur als einen weiterleitbaren Text (das Tool packt ihn als
--   Telegram-Dokument) — damit der ueberlebende Partner alles hat, selbst wenn das System aus ist /
--   beide Partner betroffen sind. Baut auf dem geteilten Register-Body auf
--   (estate.fn_render_register_body, kein Sektions-Duplikat) + Druck-Header.
--   Maskierung: p.mask_sensitive=true maskiert Steuer-ID + RV-Nr. ('••••••') — fuer eine weitergabe-
--     taugliche Mappe an Dritte. Default false (die Mappe soll fuer den Partner vollstaendig sein).
--   SECURITY DEFINER (owned by der applizierenden DDL-Rolle): der Binder laeuft standalone (das Tool
--     ruft ihn unter estate_rw) und muss finance sehen -> als DEFINER (Owner=Superuser) sieht der Body
--     finance; ein INVOKER-Aufruf unter estate_rw saehe es nicht. DEFINER-Haertung:
--     SET search_path gepinnt (CVE-2018-1058) + REVOKE ALL FROM PUBLIC (EXECUTE erhaelt estate_rw ueber
--     den Blanket-Grant in fn_provision_package_roles, nach den R__) + Body schema-qualifiziert
--     + kein Caller-Input im dyn. EXECUTE (das einzige EXECUTE steckt im registry-/to_regprocedure-
--     geguardeten finance-Read von fn_render_register_body).
--   adults_only-Backstop in der fn: als DEFINER kann sie core.fn_check_write_permission direkt rufen ->
--     ein Kind erhaelt die Voll-PII-Mappe nie, auch bei Direkt-Aufruf. Klassifikation "echte Ausnahme"
--     (RAISE insufficient_privilege, nicht {ok:false}): das Tool-Gate (n8n-IF 'Adult?') haette schon greifen
--     muessen -> ein Erreichen als Kind ist eine Anomalie. Der n8n-Node bleibt der UX-Pre-Gate (blockt vor
--     dem HITL, spart den Tap); diese fn ist der Backstop + db_test-Hook.
--   Sprache: die der anfordernden Person (agent.fn_ui_texts_for, Kette Person -> Owner -> en); Datum per
--     core.fn_fmt_date; deutsche Rechtsbegriffe der Eintraege bleiben deutsch.
--   Eingabe jsonb: chat_id (Pflicht — Adult-Check + Sprache), mask_sensitive (boolean, default false).
--   Rueckgabe: mehrzeiliger Notfallmappe-Text in der Sprache des Anfragenden (nie NULL); Kind -> RAISE.
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_render_emergency_binder(p jsonb)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, estate, agent, core, pg_temp
AS $$
DECLARE
    v_perm TEXT;
    -- NULLIF: das Tool reicht mask_sensitive als '' durch, wenn das LLM es weglaesst (4-arg-$fromAI-Default) —
    -- ''::boolean wuerfe. NULLIF('','')=NULL -> COALESCE -> false (Default = vollstaendige Mappe).
    v_mask BOOLEAN := COALESCE(NULLIF(p->>'mask_sensitive','')::boolean, false);
    v_lang TEXT;
    v_t    JSONB;
BEGIN
    -- adults_only-Backstop zuerst (Kind -> RAISE, erreicht die Mappe nie).
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RAISE EXCEPTION 'emergency_binder rejected (%): only adult household members (owner/partner) may export the estate binder', v_perm
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Sprache der anfordernden Person (die Mappe ist fuer den Hinterbliebenen, der sie
    -- anfordert), Kette Person -> Owner -> en ueber denselben Pfad wie alle festen Texte.
    v_t := agent.fn_ui_texts_for(jsonb_build_object('chat_id', p->>'chat_id', 'keys', jsonb_build_array(
               'estate.binder.title', 'estate.binder.as_of', 'estate.binder.masked', 'estate.binder.full',
               'estate.binder.no_secrets')));
    v_lang := v_t->>'lang';

    RETURN '# ' || (v_t->'t'->>'estate.binder.title') || E'\n'
        || (v_t->'t'->>'estate.binder.as_of') || ': ' || core.fn_fmt_date(current_date, v_lang) || E'\n'
        || CASE WHEN v_mask THEN v_t->'t'->>'estate.binder.masked'
                ELSE v_t->'t'->>'estate.binder.full' END || E'\n'
        || (v_t->'t'->>'estate.binder.no_secrets') || E'\n\n'
        || estate.fn_render_register_body(v_mask, v_lang);
END;
$$;

REVOKE ALL ON FUNCTION estate.fn_render_emergency_binder(jsonb) FROM public;
