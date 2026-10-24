-- ============================================================
-- V026 (core) — den ausgelieferten Standard von Config-Zeilen aus der Zeit vor default_value nachtragen.
--
--   WARUM: Releases bis v0.2.0 kannten core.config.default_value noch nicht. Bestandszeilen haben es darum NULL,
--   und core.fn_config_seed behandelt sie als "vom Owner gesetzt" (dpkg-conffile-Regel) — ein nie angefasster
--   Wert folgt dann einem spaeter geaenderten Standard NIE. Gefunden im Upgrade-Test v0.2.0 -> heute (2026-10-20):
--   model/panel_b (v0.2.0: claude-sonnet-latest, heute claude-opus-latest) blieb still auf Sonnet -> beide
--   Panel-Lanes liefen auf demselben Modell.
--
--   Regel: nur die Vor-default-Aera (default_value IS NULL) und nur, wenn der Wert GLEICH dem damals ausgelieferten
--   Standard ist (= nie geaendert) -> default_value := damaliger Standard. Der Seed danach erkennt "nie geaendert"
--   und zieht den heutigen Standard nach; ein abweichender Owner-Wert bleibt. Die Liste = ALLE Config-Standards der
--   v0.2.0-Manifeste (nicht nur panel_b), damit auch ein spaeter noch geaenderter Standard greift. Modell-Werte
--   stehen schon nach der core:V024-Owner-Regel umgeschrieben da (gemini-2.5-flash -> claude-haiku-latest, jedes
--   andere Gemini -> claude-sonnet-latest), weil V024 die Bestandswerte genauso umgestellt hat. Nicht in der Liste:
--   cron_enable (Laufzeit-Schalter, der Seed ueberschreibt ihn nie), api.* (System-Werte, immer ueberschrieben),
--   feature.prompt_caching (core:V025 entfernt).
--
--   IDEMPOTENT: V laeuft genau einmal (ledger-gegated); ein zweiter Lauf findet keine passende NULL-Zeile mehr.
--   Frische DB = no-op (die Zeilen entstehen erst im Seed, mit default_value).
-- APPLY-ORDER: Inits -> V (hier, nach V024/V025) -> R -> Seed.
-- ============================================================

-- Ein Statement: nachtragen + je getroffene Zeile eine NOTICE ins Update-Protokoll (Muster core:V024).
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        WITH shipped (category, key, value) AS (VALUES
            ('advisor', 'career_plan_stale_days', '365'),
            ('advisor', 'cashflow_buffer_nudge', 'true'),
            ('advisor', 'cashflow_buffer_pct', '0.10'),
            ('advisor', 'drift_pace_pp', '10'),
            ('advisor', 'estate_review_days', '365'),
            ('advisor', 'plan_stale_days', '365'),
            ('advisor', 'price_stale_days', '7'),
            ('advisor', 'risk_profile_stale_days', '365'),
            ('advisor', 'savings_squeeze_nudge', 'true'),
            ('advisor', 'tax_year_nudge', 'true'),
            ('career', 'job_max_per_run', '7'),
            ('career', 'job_score_threshold', '3'),
            ('career', 'job_source_adzuna', 'true'),
            ('career', 'job_source_bundesagentur', 'true'),
            ('career', 'job_source_jsearch', 'true'),
            ('feature', 'career_onboarding_gate', 'true'),
            ('feature', 'monitor_triggers', 'true'),
            ('feature', 'onboarding_gate', 'true'),
            ('finance', 'reconcile_overdue_days', '30'),
            ('general', 'bundesland', ''),
            ('learn_context', 'daily_cap', '3'),
            ('learn_context', 'expiry_days', '7'),
            ('model', 'advisor_review', 'claude-haiku-latest'),
            ('model', 'career_advisor', 'claude-opus-latest'),
            ('model', 'cv_extract', 'claude-sonnet-latest'),
            ('model', 'estate_advisor', 'claude-opus-latest'),
            ('model', 'finance', 'claude-sonnet-latest'),
            ('model', 'finance_advisor', 'claude-opus-latest'),
            ('model', 'guide', 'claude-sonnet-latest'),
            ('model', 'job_scorer', 'claude-sonnet-latest'),
            ('model', 'learn_context', 'claude-sonnet-latest'),
            ('model', 'monitor', 'claude-sonnet-latest'),
            ('model', 'monitor_acquisition', 'claude-sonnet-latest'),
            ('model', 'orchestrator', 'claude-haiku-latest'),
            ('model', 'panel_a', 'claude-sonnet-latest'),
            ('model', 'panel_b', 'claude-sonnet-latest'),
            ('model', 'vision_extract', 'claude-sonnet-latest'),
            ('model', 'web_search', 'claude-sonnet-latest'),
            ('monitor', 'fail_alert_streak', '3'),
            ('monitor', 'fx_stale_days', '5'),
            ('schedule', 'drift_check', '0 8 * * *'),
            ('schedule', 'learn_context', '0 6 * * *'),
            ('schedule', 'monitor_triggers', '10 * * * *'),
            ('schedule', 'plan_review', '0 9 1 1,4,7,10 *'),
            ('schedule', 'reconcile_accounts', '0 8 1 * *'),
            ('schedule', 'refresh_fx_rates', '0 6 * * *'),
            ('schedule', 'refresh_market_prices', '0 7 * * *'),
            ('schedule', 'refresh_market_signals', '0 6 * * 1'),
            ('schedule', 'remind_case_tasks', '0 8 * * *'),
            ('schedule', 'remind_interest', '30 9 * * *'),
            ('schedule', 'remind_recurring', '0 9 * * *'),
            ('schedule', 'review_register', '0 9 1 * *'),
            ('schedule', 'score_jobs', '0 7 * * 1-5'),
            ('telegram', 'bot_username', 'your_bot'),
            ('transcription', 'provider', 'google')
        )
        UPDATE core.config c
           SET default_value = s.value
          FROM shipped s
         WHERE s.category = c.category AND s.key = c.key
           AND c.default_value IS NULL
           AND c.value IS NOT DISTINCT FROM s.value
        RETURNING c.category, c.key, c.value
    LOOP
        RAISE NOTICE 'core:V026 %/%: nie geaendert ("%") -> folgt ab jetzt dem ausgelieferten Standard', r.category, r.key, r.value;
    END LOOP;
END $$;
