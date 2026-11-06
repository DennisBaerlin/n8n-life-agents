-- ============================================================
-- V031 (core) — Basis-Codes der Bot-Persona vorab anlegen (core.ui_personas, Init core.ui_texts_init.sql).
--
--   WARUM: der Validator agent.fn_validate_household_facts laesst family.persons[].persona nur aus
--   core.ui_personas zu. Der Seed (_seed_ui_personas, SoT Core-Manifest "personas.list") laeuft erst nach
--   Init -> V -> R; die ungeseedete Test-DB und jeder Write vor dem Seed saehen sonst eine leere Liste.
--   Muster V027 (ui_languages). locale_lint prueft: diese Liste ⊆ Manifest.
--
--   IDEMPOTENT: V laeuft genau einmal (ledger-gegated); ON CONFLICT DO NOTHING laesst Seed-Werte stehen.
-- APPLY-ORDER: Inits -> V (hier) -> R -> Seed.
-- ============================================================

INSERT INTO core.ui_personas (code, ord) VALUES
    ('neutral', 1),
    ('butler', 2),
    ('sportscaster', 3),
    ('sage', 4)
ON CONFLICT (code) DO NOTHING;
