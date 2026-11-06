-- ============================================================
-- estate.fn_render_estate_overview (WS-1 — Render des EINEN estate-Lese-Kontexts estate_overview)
--   DUENNER WRAPPER (WS-5 Rule-of-Three-Extraktion): der vollstaendige Register-Ueberblick lebt seit
--   WS-5 in estate.fn_render_register_body(p_mask, p_lang) — der EINEN Register-Rendering-Logik, die sich
--   Overview UND Notfallmappe teilen (kein Sektions-Duplikat -> strukturell drift-frei). Der Overview
--   ruft sie UNMASKIERT (p_mask=false): der Haushalts-Lese-Kontext zeigt die vollen Kennnummern. Sprache fest
--   'de' (Textkatalog Phase C): der Text ist Modell-Kontext, kein Nutzertext -> das Agent-Verhalten bleibt gleich.
--   UNIFORME Renderer-Signatur fn(text)->text (core.context_renderers-Registry, Engine core.fn_fetch_context
--   wrappt Banner + Header + '---' + Prosa); p_name wird nicht gebraucht (estate_overview ist household,
--   KEINE context_scopes-Zeile -> nie suffigiert). estate_overview darf NIE Publish-Ziel werden
--   (arch-challenge P5) — die Register-Tabellen sind die Wahrheit.
--   LANGUAGE plpgsql (NICHT sql): die Body-Referenz auf fn_render_register_body ist damit LATE-BOUND
--   (kein Bau-Reihenfolge-Zwang zwischen den beiden R__-Dateien; check_function_bodies-sicher).
--   RAISE-FREI + STABLE; schema-qualifiziert (laeuft im fn_fetch_context-DEFINER, Pfad ohne estate).
--   RUECKGABE: mehrzeiliger Register-Text (nie NULL — fn_render_register_body garantiert es).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_render_estate_overview.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_render_estate_overview(p_name text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN estate.fn_render_register_body(false, 'de');   -- Modell-Kontext: feste Sprache (Agent-Verhalten unveraendert)
END;
$$;
