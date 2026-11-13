-- ============================================================
-- estate.fn_render_estate_overview (READ — Render des einen estate-Lese-Kontexts estate_overview)
--   Duenner Wrapper: der vollstaendige Register-Ueberblick lebt in
--   estate.fn_render_register_body(p_mask, p_lang) — der einen Register-Rendering-Logik, die sich
--   Overview und Notfallmappe teilen (kein Sektions-Duplikat -> strukturell drift-frei). Der Overview
--   ruft sie unmaskiert (p_mask=false): der Haushalts-Lese-Kontext zeigt die vollen Kennnummern. Sprache fest
--   'de': der Text ist Modell-Kontext, kein Nutzertext.
--   Uniforme Renderer-Signatur fn(text)->text (core.context_renderers-Registry, Engine core.fn_fetch_context
--   wrappt Banner + Header + '---' + Prosa); p_name wird nicht gebraucht (estate_overview ist household,
--   keine context_scopes-Zeile -> nie suffigiert). estate_overview darf nie Publish-Ziel werden
--   — die Register-Tabellen sind die Wahrheit.
--   LANGUAGE plpgsql (nicht sql): die Body-Referenz auf fn_render_register_body ist damit late-bound
--   (kein Bau-Reihenfolge-Zwang zwischen den beiden R__-Dateien; check_function_bodies-sicher).
--   RAISE-frei + STABLE; schema-qualifiziert (laeuft im fn_fetch_context-DEFINER, Pfad ohne estate).
--   Rueckgabe: mehrzeiliger Register-Text (nie NULL — fn_render_register_body garantiert es).
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_render_estate_overview(p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN estate.fn_render_register_body(false, 'de');   -- Modell-Kontext: feste Sprache
END;
$$;
