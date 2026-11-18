-- ============================================================
-- fn_statements_due (READ, STABLE) -- welcher Kontoauszug faellig ist (die eine Regel fuer Erinnerung und Bot)
--   Stichtag = letzter Tag des Vormonats. Kandidaten = aktive cash-Konten mit Kontonummer, Bank oder schon einem
--   Auszug (Bargeld ohne Bank faellt raus). Gedruckter Auszug eines Kontos ohne Export-Profil: die Bank gibt den Takt
--   vor (Monat, eigener Zyklus, Quartal) -> faellig, wenn letztes Auszugs-Ende + gerundete Laenge in Monaten (mind. 1)
--   den Stichtag erreicht und kein spaeterer Chat-Abgleich den Stichtag schon abdeckt. Sonst (Datei-Export, Konto mit
--   Export-Profil, kein Auszug): faellig, wenn fn_account_confirmed_until vor dem Stichtag liegt oder NULL ist. Beim
--   Datei-Export endet der Zeitraum am Importtag-1, seine Laenge sagt nichts ueber den Takt.
--   Leser: cron.reconcile_accounts (finance_ro) und der Finance-Agent per postgres_select (Beschreibung
--   tool_reconcile_bank_statement). Test: tests/db/finance/test_fn_statements_due.sql.
--   Eingabe: p_today (NULL = core.fn_today()).
--   Rueckgabe: {cut_date, accounts:[{account_id, name, label, covered_until|null, file_export, never}]} -- nur faellige
--   Konten, never zuerst, dann covered_until, dann Name.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_statements_due(p_today date DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH cut AS (
        SELECT (date_trunc('month', COALESCE(p_today, core.fn_today())) - interval '1 day')::date AS d
    ), acc AS (
        SELECT a.id, a.name, finance.fn_account_label(a.emoji, a.account_type, a.name) AS label,
               a.last_reconciled_at, s.period_start, s.period_end, s.balance_source,
               finance.fn_bank_export_account_profile(a.id) IS NOT NULL AS file_export,
               finance.fn_account_confirmed_until(a.id) AS covered_until
        FROM finance.accounts a
        LEFT JOIN LATERAL (SELECT b.period_start, b.period_end, b.balance_source FROM finance.bank_statements b
                           WHERE b.account_id = a.id ORDER BY b.period_end DESC LIMIT 1) s ON true
        WHERE a.status = 'active'
          AND a.account_type = 'cash'
          AND (a.account_number IS NOT NULL OR NULLIF(trim(a.bank), '') IS NOT NULL OR s.period_end IS NOT NULL)
    ), due AS (
        SELECT acc.* FROM acc, cut
        WHERE CASE WHEN acc.balance_source = 'printed' AND NOT acc.file_export
                   THEN (acc.period_end + make_interval(months => GREATEST(round((acc.period_end - acc.period_start + 1) / 30.0)::int, 1)))::date <= cut.d
                        AND (acc.last_reconciled_at IS NULL OR acc.last_reconciled_at < cut.d)
                   ELSE acc.covered_until IS NULL OR acc.covered_until < cut.d END
    )
    SELECT jsonb_build_object(
        'cut_date', (SELECT d FROM cut),
        'accounts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                         'account_id', id, 'name', name, 'label', label, 'covered_until', covered_until,
                         'file_export', file_export, 'never', covered_until IS NULL)
                         ORDER BY covered_until NULLS FIRST, name) FROM due), '[]'::jsonb));
$$;
