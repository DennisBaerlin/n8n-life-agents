#Requires -Version 5.1
# Definition agent.finance.cron_remind_interest -> Build-CronRemindInterest. Dot-gesourct von build.ps1.
# Deterministisch, kein LLM: Schedule -> fn_interest_due_open -> Loop -> auto-buchen ODER HITL "Zinsgutschrift buchen?".
# Eigener Cron: Zins ist eine 2. Due-Quelle (account_interest_rates), eigene
# Cadence/Toggle. Der Betrag wird von der DB berechnet (fn_interest_amount_due, NIE das LLM); auto_post-Konten
# (taeglich/woechentlich) werden ohne Gate gebucht, sonst HITL. Idempotenz je (Konto, period_end) macht
# Mehrfach-/Backfill-Laeufe doppel-sicher. Schedule (Cron) aus core.config, beim Einspielen eingesetzt.
# Nutzt aus dem Build-Scope: $RepoRoot, $Utf8NoBom, $CRED_FINANCE_RW, $CRED_TELEGRAM + build_helpers.
function Build-CronRemindInterest {
    # Bucht via finance.fn_book_interest_occurrence/fn_skip_interest_occurrence -> enge Schreibrolle finance_rw.
    $CRED_POSTGRES = $CRED_FINANCE_RW

    $trig = Build-ScheduleTrigger @(-680, 0) -ScheduleKey 'remind_interest'

    # F9 Cron-Gating: laeuft nur, wenn Paket aktiv UND cron_enable -> sonst No-op (DB entscheidet, fail-closed).
    $gate = Build-Pg 'Cron enabled?' @(-500, 0) `
        "SELECT core.fn_package_active('finance') AND COALESCE(core.fn_config_get('finance','cron_enable','remind_interest') = 'true', false) AS enabled"
    $gateIf = Build-If 'Cron on?' @(-340, -40) "={{ `$json.enabled }}" 'true' 'equals' 'boolean'
    $gateOff = Build-NoOp 'Disabled' @(-340, 200)
    $stickyGate = Build-Sticky 'F9 Cron-Gate' @(-680, -240) `
        'Paket aktiv UND cron_enable.remind_interest' `
        'Erster Schritt: core.fn_package_active(''finance'') AND core.fn_config_get(''finance'',''cron_enable'',''remind_interest'')=''true'' (DB entscheidet, fail-closed). Aus -> No-op. Läuft unter finance_rw (bucht via fn_book_interest_occurrence). Toggle: lifeagents config set cron_enable remind_interest false.' 280 400

    # Offene Zins-Faelligkeiten + DB-berechneter Betrag + auto_post-Flag; nur Vorschlaege > 0 (Nullsaldo/ohne Satz
    # raus). ORDER BY period_end ASC -> die Zinseszins-Kette wird in der richtigen Reihenfolge gebucht.
    # Monats-Check (WP-D): Konten mit eingespieltem Kontoauszug fragt die Erinnerung NICHT — dort hakt der Auszug die
    # Zinsgutschrift ab (fn_statement_match), oder der Abgleich schliesst sie (keine taegliche Rueckfrage mehr).
    # auto_post-Konten (taeglich/woechentlich) bucht der Cron weiter still: dort fragt niemand, und ohne sie fehlte der
    # Zins zwischen zwei Auszuegen im Saldo. Kein Doppel: der Auszug-Rest ist die DB-Differenz zum Endsaldo, die schon
    # gebuchten Gutschriften stecken im Systemstand.
    $getOpen = Build-Pg 'Get open interest' @(-240, 0) @"
=SELECT q.account_id, q.value_date, q.period_end, q.account_name, q.amount, q.auto_post, q.currency
FROM (
  SELECT o.account_id, o.value_date::text AS value_date, o.period_end::text AS period_end,
         a.name AS account_name, a.currency AS currency,   -- WP-5: Konto-Waehrung fuer die Betrag-Formatierung
         finance.fn_interest_amount_due(o.account_id, o.period_end) AS amount,
         o.auto_post
  FROM finance.fn_interest_due_open(CURRENT_DATE) o
  JOIN finance.accounts a ON a.id = o.account_id
  WHERE o.auto_post OR NOT EXISTS (SELECT 1 FROM finance.bank_statements b WHERE b.account_id = o.account_id)
) q
WHERE q.amount > 0
ORDER BY q.period_end, q.account_name;
"@ $null

    $loop = Build-Loop 'Loop Over Items' @(0, 0)
    $done = Build-NoOp 'Done' @(220, -260)

    # M3 Auto-Post-Branch: auto_post=true (Default day/week) -> direkt buchen (kein Gate); sonst HITL-Loop.
    $autoIf = Build-If 'Auto-post?' @(220, 0) "={{ `$json.auto_post }}" 'true' 'equals' 'boolean'

    # Textkatalog Phase C: Texte EINMAL in Owner-Sprache (read-only VOR jedem Write).
    $loadTexts = Build-Pg 'Load texts' @(-240, -200) `
        ("SELECT core.fn_ui_texts_for(jsonb_build_object('keys', to_jsonb(" + (Get-UiKeysSql @(
            'finance.dialog.interest_ask', 'finance.dialog.interest_defer', 'finance.dialog.btn_book',
            'finance.dialog.btn_other', 'finance.dialog.btn_tomorrow', 'finance.dialog.btn_skip',
            'finance.dialog.interest_booked', 'finance.dialog.book_failed', 'finance.dialog.already_booked', 'finance.dialog.skipped',
            'finance.dialog.remind_tomorrow', 'core.hitl.unauthorized', 'core.reminders.card_footer')) + "))) AS r;")
    $T   = "`$('Load texts').first().json.r.t"
    $LOC = "(`$('Load texts').first().json.r.locale || 'en-GB')"
    $it  = "`$('Loop Over Items').item.json"
    $popup = Get-UiTextExpr $T 'core.hitl.unauthorized'

    # WP-5: Betrag waehrungs-korrekt (Fmt-MoneyJs mit der Konto-Waehrung), Daten im Owner-Locale (Fmt-DateJs).
    $intAmt = Fmt-MoneyJs "$it.amount" "$it.currency" $LOC
    $intPe  = Fmt-DateJs  "$it.period_end" $LOC
    $intVd  = Fmt-DateJs  "$it.value_date" $LOC
    # Roter Faden Paket B: die Bestaetigungs-Frage hat genau zwei Knoepfe (sendAndWait) -> statt eines Abschalten-Knopfs
    # die Fusszeile core.reminders.card_footer ("Erinnerungen verwalten: /reminders"); cron_toggle_lint verlangt eins von beiden.
    $askInterest = New-TelegramSendAndWaitNode 'Ask interest booked' @(440, 60) `
        ('={{ ' + (Get-UiTextJs $T 'finance.dialog.interest_ask' @{ amount = $intAmt; account = "$it.account_name"; period_end = $intPe; value_date = $intVd }) +
         " + '\n\n' + " + (Get-UiTextJs $T 'core.reminders.card_footer') + ' }}') `
        -ApproveLabel (Get-UiTextExpr $T 'finance.dialog.btn_book') -DisapproveLabel (Get-UiTextExpr $T 'finance.dialog.btn_other') `
        -UnauthorizedReply $popup
    $ifBooked = Build-If 'Book interest?' @(660, 60) "={{ `$json.data.approved }}" 'true' 'equals' 'boolean'

    # Berechneten Zins buchen (kein amount -> DB rechnet selbst, eine Quelle). value_date=Gutschrift-Datum,
    # period_end=abgedeckte Vorperiode (Idempotenz-Key). Ein Book-Knoten fuer beide Wege; danach entscheidet
    # 'Auto-posted?': der Auto-Branch bleibt still (Verifikation spaeter gegen den Auszug), der bestaetigte
    # HITL-Pfad bekommt seine Ergebnis-Zeile.
    $book = Build-Pg 'Book interest' @(880, -120) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'code' AS code FROM finance.fn_book_interest_occurrence(`$1::jsonb) AS r;" `
        ([ordered]@{
            account_id = "$it.account_id"
            value_date = "$it.value_date"
            period_end = "$it.period_end"
        })
    $ifAuto = Build-If 'Auto-posted?' @(1100, -120) "={{ $it.auto_post }}" 'true' 'equals' 'boolean'

    $askDefer = New-TelegramSendAndWaitNode 'Ask defer' @(880, 120) `
        (Get-UiTextExpr $T 'finance.dialog.interest_defer' @{ account = "$it.account_name" }) `
        -ApproveLabel (Get-UiTextExpr $T 'finance.dialog.btn_tomorrow') -DisapproveLabel (Get-UiTextExpr $T 'finance.dialog.btn_skip') `
        -UnauthorizedReply $popup
    $ifTomorrow = Build-If 'Tomorrow?' @(1100, 120) "={{ `$json.data.approved }}" 'true' 'equals' 'boolean'

    # Ergebnis-Zeilen nach jedem Tipp (removeButtons entfernt nur die Knoepfe); onError continue. Den Fehlgrund
    # liefert die fn als code (der englische reason ist Modell-Text und kommt nie in die Nachricht).
    $nBooked = New-TelegramSendNode 'Notify booked' @(1320, -280) `
        ("={{ `$('Book interest').item.json.ok ? " + (Get-UiTextJs $T 'finance.dialog.interest_booked' @{ account = "$it.account_name" }) +
         " : `$('Book interest').item.json.code === 'already_booked' ? " + (Get-UiTextJs $T 'finance.dialog.already_booked' @{ name = "$it.account_name" }) +
         ' : ' + (Get-UiTextJs $T 'finance.dialog.book_failed' @{ name = "$it.account_name" }) + ' }}') `
        -OnError 'continueRegularOutput'
    $nSkipped = New-TelegramSendNode 'Notify skipped' @(1540, 260) `
        (Get-UiTextExpr $T 'finance.dialog.skipped' @{ name = "$it.account_name" }) -OnError 'continueRegularOutput'
    $nTomorrow = New-TelegramSendNode 'Notify tomorrow' @(1320, 60) `
        (Get-UiTextExpr $T 'finance.dialog.remind_tomorrow' @{ name = "$it.account_name" }) -OnError 'continueRegularOutput'

    $skip = Build-Pg 'Skip occurrence' @(1320, 260) `
        "=SELECT (r->>'ok')::boolean AS ok FROM finance.fn_skip_interest_occurrence(`$1::jsonb) AS r;" `
        ([ordered]@{
            account_id = '$(''Loop Over Items'').item.json.account_id'
            period_end = '$(''Loop Over Items'').item.json.period_end'
        })

    $stickyOverview = Build-Sticky 'Überblick' @(-460, -320) `
        'Zins-Fälligkeits-Scheduler (kein LLM, DB rechnet den Betrag)' `
        'Schedule (Cron aus core.config schedule.remind_interest, beim Einspielen eingesetzt) -> fn_interest_due_open(CURRENT_DATE) liefert offene Zins-Vorkommen (account_id, value_date, period_end, auto_post) je zins-fähigem Einlagen-Konto (cash/fixed_deposit/p2p, fn_interest_eligible_account_type); fn_interest_amount_due rechnet je Vorkommen den Betrag (basis zum period_end x Satz JE SEGMENT (taggenaue Mischung bei unterjährigem Satzwechsel) x day-count-Anteil, EINMAL gerundet). Nur Vorschläge > 0. "gebucht" wird aus finance.transactions (category=interest, interest_period_end=period_end) abgeleitet; nur Skips materialisiert (interest_skips.period_end). ORDER BY period_end ASC = korrekte Zinseszins-Reihenfolge.' 240 600
    $stickyAuto = Build-Sticky 'Auto vs HITL' @(220, 220) `
        'Auto-post? -> auto buchen ODER HITL' `
        'Auto-post? (auto_post=true, Default täglich/wöchentlich) -> direkt Book interest ohne Gate (deterministisch, cron-vs-trigger-konform; der Owner verifiziert später gegen den Auszug, Idempotenz je period_end schützt vor Doppel). Sonst (monatlich/jährlich, false) -> HITL "Ask interest booked": Bestätigen -> Book interest (berechnet, KEIN Override). Ablehnen -> Ask defer (morgen erneut = kein Write, taucht morgen wieder auf / überspringen = fn_skip_interest_occurrence -> interest_skips). Anderer Betrag: der Nutzer nennt dem Agenten den Ist-Betrag -> tool_book_interest bucht den Override. TEXTKATALOG: Texte + Aktions-Knöpfe in Owner-Sprache aus Load texts (core.fn_ui_texts_for, read-only VOR jedem Write), Beträge/Daten per Intl. Nach jedem Tipp eine Ergebnis-Zeile (Notify booked / skipped / tomorrow, onError continue; Fehlgrund als code aus der fn, nie der englische reason). Beide Wege buchen über denselben Knoten Book interest; Auto-posted? lässt den Auto-Branch still zurück in die Schleife, nur der bestätigte Pfad bekommt Notify booked.' 340 720

    # Stale-Tap-Schutz hinter JEDER Frage (mehrere Fragen nacheinander in einer Execution; New-StaleTapGuard).
    $gInterest = New-StaleTapGuard -AskName 'Ask interest booked' -Next 'Book interest?' -Pos @(500, 260)
    $gDefer    = New-StaleTapGuard -AskName 'Ask defer'           -Next 'Tomorrow?'      -Pos @(940, 300)
    $stickyStale = Build-Sticky 'Doppel-Tipp-Schutz' @(1300, -320) `
        'Tipp auf eine schon beantwortete Frage' `
        'Bestätigen im Chat: n8n bindet einen Tipp an diese Execution, nicht an die Nachricht. Ohne Schutz könnte ein Doppel-Tipp auf "buchen?" die danach wartende Frage "morgen erneut?" gleich mit beantworten. Hinter jeder Frage merkt sich "(tap check)" die beantworteten Nachrichten ($execution.customData); ein Tipp auf eine schon beantwortete Nachricht stellt die aktuelle Frage neu (New-StaleTapGuard).' 320 280

    $nodes = @($trig, $gate, $gateIf, $gateOff, $loadTexts, $getOpen, $loop, $done, $autoIf,
               $ifAuto, $nBooked, $nSkipped, $nTomorrow,
               $askInterest, $ifBooked, $book, $askDefer, $ifTomorrow, $skip,
               $stickyOverview, $stickyAuto, $stickyGate, $stickyStale) + $gInterest.Nodes + $gDefer.Nodes

    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Load texts' ),
            @( E 'Disabled' )
        ) }
        'Load texts'                  = @{ main = @( ,@( E 'Get open interest' ) ) }
        'Get open interest'           = @{ main = @( ,@( E 'Loop Over Items' ) ) }
        'Loop Over Items'             = @{ main = @(
            @( E 'Done' ),
            @( E 'Auto-post?' )
        ) }
        'Auto-post?'                  = @{ main = @(
            @( E 'Book interest' ),
            @( E 'Ask interest booked' )
        ) }
        'Book interest?'              = @{ main = @(
            @( E 'Book interest' ),
            @( E 'Ask defer' )
        ) }
        'Book interest'               = @{ main = @( ,@( E 'Auto-posted?' ) ) }
        'Auto-posted?'                = @{ main = @(
            @( E 'Loop Over Items' ),
            @( E 'Notify booked' )
        ) }
        'Notify booked'               = @{ main = @( ,@( E 'Loop Over Items' ) ) }
        'Tomorrow?'                   = @{ main = @(
            @( E 'Notify tomorrow' ),
            @( E 'Skip occurrence' )
        ) }
        'Skip occurrence'             = @{ main = @( ,@( E 'Notify skipped' ) ) }
        'Notify skipped'              = @{ main = @( ,@( E 'Loop Over Items' ) ) }
        'Notify tomorrow'             = @{ main = @( ,@( E 'Loop Over Items' ) ) }
    }
    foreach ($g in @($gInterest, $gDefer)) { foreach ($k in $g.Connections.Keys) { $conns[$k] = $g.Connections[$k] } }
    return (Build-Workflow 'agent.finance.cron_remind_interest' $nodes $conns)
}
