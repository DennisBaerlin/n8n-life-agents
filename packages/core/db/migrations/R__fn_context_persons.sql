-- ============================================================
-- fn_context_persons (READ, Identity-Helper — Suffix-Enumerations-Primitiv)
--   Liefert die person_ids, die einen per_user-Kontext '<base>__<person_id>' in agent.core_contexts
--   tragen (managed_by='agent' = echte Laufzeit-PII, nicht geseedete Base-/Instruktions-Zeilen).
--   Schwester von agent.fn_owner_person_id / fn_person_chat_id / fn_resolve_sender (Familie der
--   family-/core_contexts-Identitaets-Primitive, hier die "welche Personen haben Kontext <base>"-Richtung).
--   Eingabe: p_base_name (Basis-Name des per_user-Kontexts). Rueckgabe: Tabelle person_id, leer bei 0 Treffern.
--
--   Die eine Quelle der per-Person-Faecherung. Drei Konsumenten teilen dieses Primitiv:
--     * cron.score_jobs            -> fn_context_persons('career_planning')  (je Person scoren + Karte senden)
--     * cron.refresh_market_signals-> fn_context_persons('career_planning')  (Union der (Rolle,Ort) refreshen)
--     * cron.advisor_* (Engine)    -> per_user-Domains ueber fn_context_persons(plan_context) faechern
--       (household-Domains weiter mit person_id=NULL; die Scope-CASE lebt im Advisor-Cron, wo beide koexistieren)
--   Die per_user-ness/Scope kennt dieses Primitiv bewusst nicht; der Aufrufer nennt seinen base direkt.
--
--   Literal-Prefix-Match (kein Regex, kein LIKE) -> injektions- und wildcard-sicher: ein LIKE 'career_planning__%'
--   wuerde die internen '_' von 'career_planning' als Single-Char-Wildcards lesen (false-positive z. B.
--   'careerXplanning__bar'); ein Regex-Anker '^'||base||'__' interpolierte Metazeichen aus base ungeschuetzt.
--   left(name, length(base)+2) = base||'__' ist eine reine Gleichheit; substring(name FROM length(base)+3)
--   extrahiert den pid (1-basiert; +3 = direkt hinter '<base>__'). DISTINCT + Non-Empty-Suffix-Guard.
--
--   Deterministisch und RAISE-frei (Set-Returning, leere Menge bei 0 Treffern -> die Crons degradieren graceful).
--   search_path nicht gepinnt (Paritaet fn_owner_person_id/fn_person_chat_id; alle Refs schema-qualifiziert).
--   Kein REVOKE-Tail (Identity-Helper, kein DEFINER-Fenster; nur die Haupt-RW-Crons lesen es).
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_context_persons(p_base_name text)
RETURNS TABLE(person_id text) LANGUAGE sql STABLE AS $$
    SELECT DISTINCT substring(c.name FROM length(p_base_name) + 3)
    FROM agent.core_contexts c
    WHERE c.managed_by = 'agent'
      AND left(c.name, length(p_base_name) + 2) = p_base_name || '__'
      AND length(c.name) > length(p_base_name) + 2;
$$;
