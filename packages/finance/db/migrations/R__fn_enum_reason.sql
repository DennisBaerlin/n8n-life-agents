-- ============================================================
-- fn_enum_reason (READ HELPER) -- Enum-Guard fuer Write-fns
--   Die eine Adresse fuer "unbekannter ENUM-Wert": liefert NULL, wenn p_value leer ist oder ein gueltiges Label von
--   p_enum, sonst den korrigierbaren Grund (EN, fuers {ok:false}) mit Feldname p_field und erlaubten Werten. Ein
--   Cast wie 'owned'::finance.property_status wirft dagegen RAISE -> Owner-Alert (Einzel-Tool) bzw. Rohfehler nach
--   der Freigabe (Import). Aufrufer pruefen den rohen Text und casten erst danach (nie im DECLARE, der laeuft vor
--   jedem Guard). Kein Trim: der Cast trimmt auch nicht.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_enum_reason(p_enum regtype, p_value text, p_field text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN NULLIF(p_value, '') IS NULL THEN NULL
        WHEN EXISTS (SELECT 1 FROM pg_enum e WHERE e.enumtypid = p_enum AND e.enumlabel = p_value) THEN NULL
        ELSE format('Unknown %s "%s" - allowed values: %s.', p_field, p_value,
                    (SELECT string_agg(e.enumlabel, ', ' ORDER BY e.enumsortorder)
                     FROM pg_enum e WHERE e.enumtypid = p_enum))
    END;
$$;
