#Requires -Version 5.1
# Definition agent.finance.cron_reconcile_accounts -> Build-CronReconcileAccounts. Dot-gesourct von build.ps1.
# Deterministisch, KEIN LLM, KEIN Write: Monats-Check-Erinnerung (WP-D). Schedule -> Konten mit Kontoauszug, deren
# bestaetigter Stand den letzten Monat noch nicht abdeckt -> IF count>0 -> EINE Telegram-Nachricht mit Anleitung.
# Zeitplan = Platzhalter __CFG_SCHEDULE_RECONCILE_ACCOUNTS__, den der Installer beim Einspielen aus core.config
# (schedule.reconcile_accounts) einsetzt. Nutzt aus dem Orchestrator-Scope: $RepoRoot, $Utf8NoBom, $CRED_POSTGRES,
# $CRED_TELEGRAM + build_helpers (Build-Pg/Build-If/Build-Sticky/E/Build-Workflow/New-Id).
#
# Design: KEIN sendAndWait-Dialog. Die Antwort ist eine Datei (Kontoauszug-PDF), und Datei/Freitext loesen ein offenes
# sendAndWait-Gate NICHT auf (HITL-Constraint, Root-CLAUDE.md). Darum nur eine informierende Nachricht; der Nutzer
# schickt das PDF an den Bot -> agent.finance -> tool_reconcile_bank_statement (eine Karte je Auszug).
function Build-CronReconcileAccounts {
    # Read-only (nur SELECT + Telegram-Reminder, kein Write) -> enge Leserolle finance_ro (D10);
    # funktions-lokaler Override (inkl. Gate-Read; fn_package_active/fn_config_get sind an finance_ro gegrantet).
    $CRED_POSTGRES = $CRED_FINANCE_RO

    # lokale Node-Builder (cron-spezifisch)
    # Node-Builder (Build-ScheduleTrigger/New-TelegramSendNode/Build-NoOp) kommen zentral aus
    # lib/build_helpers.ps1 — der Telegram-Helper escapt dynamischen Text automatisch.
    $trig = Build-ScheduleTrigger @(-680, 0) -ScheduleKey 'reconcile_accounts'

    # F9 Cron-Gating (WS4a): laeuft nur, wenn Paket aktiv UND cron_enable -> sonst No-op (DB entscheidet, fail-closed).
    $gate = Build-Pg 'Cron enabled?' @(-500, 0) `
        "SELECT core.fn_package_active('finance') AND COALESCE(core.fn_config_get('finance','cron_enable','reconcile_accounts') = 'true', false) AS enabled"
    $gateIf = Build-If 'Cron on?' @(-340, -40) "={{ `$json.enabled }}" 'true' 'equals' 'boolean'
    $gateOff = Build-NoOp 'Disabled' @(-340, 160)
    $stickyGate = Build-Sticky 'F9 Cron-Gate (WS4a)' @(-680, -240) `
        'Paket aktiv UND cron_enable.reconcile_accounts' `
        'Erster Schritt: core.fn_package_active(''finance'') AND core.fn_config_get(''finance'',''cron_enable'',''reconcile_accounts'')=''true'' (DB entscheidet, fail-closed). Aus -> No-op. Läuft unter finance_ro (read-only). Toggle: lifeagents config set cron_enable reconcile_accounts false.' 280 400

    # Eine Zeile: Stichtag (letzter Tag des Vormonats) + die faelligen Konten (Name, bestaetigt bis) + die Texte in
    # Owner-Sprache (core.fn_ui_texts_for, an finance_ro gegrantet). Die Anzeige (Datum per Intl im Owner-Locale) baut
    # 'Build message' — nie to_char (Format hinge an lc_numeric).
    # Monats-Check (WP-D): Kandidaten = aktive cash-Konten mit Kontoauszug — Kontonummer bekannt, eine Bank angegeben
    # (Bargeld hat keine) oder schon ein eingespielter Auszug. Faellig, wenn der bestaetigte Stand den Stichtag noch nicht
    # erreicht: naechstes erwartetes Auszugs-Ende = letztes Auszugs-Ende + Laenge des letzten Auszugs in Monaten (ein
    # Quartalsauszug fragt nur jedes Quartal), sonst COALESCE(last_reconciled_at, created_at) < Stichtag. Bei 0 Treffern
    # unterdrueckt das IF die Nachricht (am 17. erscheinen nur noch die fehlenden Konten).
    $keys = Get-UiKeysSql (@('finance.dialog.monthly_check_intro', 'finance.dialog.monthly_check_line', 'finance.dialog.monthly_check_line_csv',
        'finance.dialog.monthly_check_never', 'finance.dialog.monthly_check_howto', 'core.reminders.btn_off') + $script:UiRenderKeys)
    $find = Build-Pg 'Find overdue accounts' @(-240, 0) @"
=WITH cut AS (
    SELECT (date_trunc('month', CURRENT_DATE) - interval '1 day')::date AS d
), acc AS (
    SELECT a.name, a.last_reconciled_at::date AS last_reconciled,
           finance.fn_broker_csv_account_profile(a.id) IS NOT NULL AS csv,
           CASE WHEN s.period_end IS NOT NULL
                THEN (s.period_end + make_interval(months => GREATEST(round((s.period_end - s.period_start + 1) / 30.0)::int, 1)))::date
                ELSE COALESCE(a.last_reconciled_at, a.created_at::date) + 1 END AS next_due
    FROM finance.accounts a
    LEFT JOIN LATERAL (SELECT b.period_start, b.period_end FROM finance.bank_statements b
                       WHERE b.account_id = a.id ORDER BY b.period_end DESC LIMIT 1) s ON true
    WHERE a.status = 'active'
      AND a.account_type = 'cash'
      AND (a.account_number IS NOT NULL OR NULLIF(trim(a.bank), '') IS NOT NULL OR s.period_end IS NOT NULL)
)
SELECT
    (SELECT d FROM cut) AS cut_date,
    (SELECT count(*)::int FROM acc WHERE next_due <= (SELECT d FROM cut)) AS overdue_count,
    COALESCE((SELECT jsonb_agg(jsonb_build_object('name', name, 'last_reconciled', last_reconciled, 'csv', csv)
                               ORDER BY last_reconciled NULLS FIRST, name)
              FROM acc WHERE next_due <= (SELECT d FROM cut)), '[]'::jsonb) AS accounts,
    core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb($keys))) AS ui;
"@ $null

    $ifAny = Build-If 'Any overdue?' @(0, 0) "={{ `$json.overdue_count }}" '0' 'larger' 'number'

    # Text im Owner-Locale (geteilter Renderer, Datum per Intl); Kontonamen = Daten (escapt der Send-Helper).
    $buildJs = (Get-UiRenderLibJs) + @'
const m = $('Find overdue accounts').first().json;
const U = uiRender(m.ui || {});
const rows = Array.isArray(m.accounts) ? m.accounts : [];
const lines = rows.map((r) => U.fill(U.t(r.csv ? 'finance.dialog.monthly_check_line_csv' : 'finance.dialog.monthly_check_line'), {
  name: r.name, date: r.last_reconciled ? { kind: 'date', value: r.last_reconciled } : U.t('finance.dialog.monthly_check_never') }));
const intro = U.fill(U.t('finance.dialog.monthly_check_intro'), { date: { kind: 'date', value: m.cut_date } });
// CSV-Bank (finance.fn_broker_csv_account_profile): der Schritt steht in der Kontozeile, die PDF-Anleitung nur bei PDF-Konten
const howto = rows.some((r) => !r.csv) ? '\n\n' + U.t('finance.dialog.monthly_check_howto') : '';
return [{ json: { message: intro + '\n\n' + lines.join('\n') + howto,
                  btn_off: U.t('core.reminders.btn_off') } }];
'@
    $build = [ordered]@{
        parameters = [ordered]@{ jsCode = $buildJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(220, -100)
        id = (New-Id); name = 'Build message'
    }
    # Roter Faden Paket B: Abmelden an der Nachricht selbst (RFC-8058-Prinzip) -> [Erinnerung abschalten] =
    # cron_off:reconcile_accounts (Owner-Callback -> core.fn_set_cron_enable); wieder an in /reminders.
    $notify = New-TelegramInlineKeyboardSendNode 'Notify overdue' @(440, -100) '={{ $json.message }}' `
        @( @{ Text = '={{ $json.btn_off }}'; Data = 'cron_off:reconcile_accounts' } )

    $none = Build-NoOp 'Nothing due' @(220, 120)

    $stickyOverview = Build-Sticky 'Überblick' @(-460, -300) `
        'Monats-Check-Erinnerung (3. und 17. des Monats, kein LLM, kein Write)' `
        'Schedule (Cron aus core.config schedule.reconcile_accounts, Standard 5 10 3,17 * * im Erinnerungs-Fenster: am 3. haben die meisten Banken den Monatsauszug bereitgestellt, am 17. nur noch die fehlenden Konten). Kandidaten: aktive cash-Konten mit Kontoauszug (Kontonummer bekannt, Bank angegeben oder schon ein Auszug eingespielt; Bargeld ohne Bank fällt raus). Fällig, wenn der bestätigte Stand den Stichtag (letzter Tag des Vormonats) nicht erreicht: nächstes erwartetes Auszugs-Ende = letztes Auszugs-Ende + dessen Länge in Monaten (ein Quartalsauszug fragt nur jedes Quartal). Aggregiert zu EINER Zeile (Stichtag + Konten + Texte in Owner-Sprache, core.fn_ui_texts_for). IF count>0 -> Build message (Datum per Intl im Owner-Locale, Schritt-für-Schritt-Anleitung aus dem Katalog; ein Konto einer CSV-Bank laut finance.fn_broker_csv_account_profile bekommt den CSV-Schritt in seiner Zeile, die PDF-Anleitung kommt nur, wenn ein PDF-Konto dabei ist) -> EINE Nachricht mit Knopf [Erinnerung abschalten] (cron_off:reconcile_accounts, Owner; wieder an in /reminders — Roter Faden Paket B); sonst No-Op.' 280 600

    $stickyDesign = Build-Sticky 'Workflow danach' @(0, 160) `
        'Ein PDF -> eine Karte -> ein atomarer Write' `
        'Kein sendAndWait hier: die Antwort ist eine Datei, und Dateien/Freitext lösen ein offenes sendAndWait-Gate NICHT auf (HITL-Constraint). Der Nutzer schickt je Konto den Kontoauszug -> agent.finance ruft tool_reconcile_bank_statement -> EINE Karte (abgehakte Zahlungen, Rest als Alltagsausgaben) -> fn_apply_bank_statement bucht atomar und gleicht auf den Endstand ab. Ein CSV-Export einer Bank mit CSV-Profil -> tool_import_broker_csv (fester Leser, App-Kontostand Pflicht). Wer keinen Auszug hat, kann weiterhin Stände per Chat nennen (tool_reconcile_accounts_batch).' 260 580

    $nodes = @($trig, $gate, $gateIf, $gateOff, $find, $ifAny, $build, $notify, $none, $stickyOverview, $stickyDesign, $stickyGate)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Find overdue accounts' ),   # true: Paket aktiv UND Cron an
            @( E 'Disabled' )                  # false: aus -> No-op
        ) }
        'Find overdue accounts'       = @{ main = @( ,@( E 'Any overdue?' ) ) }
        'Any overdue?'                = @{ main = @(
            @( E 'Build message' ),    # true:  count > 0
            @( E 'Nothing due' )       # false: nichts faellig
        ) }
        'Build message'               = @{ main = @( ,@( E 'Notify overdue' ) ) }
    }
    return (Build-Workflow 'agent.finance.cron_reconcile_accounts' $nodes $conns)
}
