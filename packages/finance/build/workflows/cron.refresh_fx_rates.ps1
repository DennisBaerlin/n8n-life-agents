#Requires -Version 5.1
# Definition agent.finance.cron_refresh_fx_rates -> Build-CronRefreshFxRates. Dot-gesourct von build.ps1.
# Deterministisch, kein LLM. Drei Eingaenge: (a) Schedule (taeglich; Platzhalter, den der Installer beim Einspielen aus
# core.config schedule.refresh_fx_rates einsetzt — scheduleTrigger liest seinen Plan nur beim Aktivieren), (b) n8nTrigger
# beim Start von n8n und (c) stuendlicher Schedule; alle laufen durch New-CatchUpEntry (fn_feed_refresh_due: ein Abruf je
# Kalendertag). Pfad: HTTP GET open.er-api.com/v6/latest/EUR -> finance.fn_upsert_fx_rates (jede gelieferte Waehrung,
# as_of = Quell-Datum) -> einmaliger EZB-Nachlauf der letzten 5 Jahre, solange er aussteht (finance.fn_fx_history_due). Nutzt aus dem Orchestrator-Scope: $RepoRoot, $Utf8NoBom, $CRED_POSTGRES + build_helpers
# (Build-Pg/Build-Http/Build-Sticky/E/Build-Workflow/New-Id).
function Build-CronRefreshFxRates {
    # Schreibt finance.fx_rates -> laeuft unter der engen Paket-Schreibrolle finance_rw;
    # funktions-lokaler Override (Dynamic-Scope -> Build-Pg sieht es), inkl. der Gate-Reads (fn_package_active/
    # fn_config_get sind an finance_rw EXECUTE-gegrantet).
    $CRED_POSTGRES = $CRED_FINANCE_RW

    # Node-Builder kommen zentral aus lib/build_helpers.ps1 (Build-ScheduleTrigger/Build-Http).
    $trig = Build-ScheduleTrigger @(-820, 0) -ScheduleKey 'refresh_fx_rates'

    $disabled = Build-NoOp 'Disabled' @(-400, 420)

    # Nachholen: n8n-Start (nach 30 s fuer Netz/DNS) und stuendlicher Check (Ruhezustand startet n8n nicht neu) ueber den
    # gemeinsamen Eingang; der Tagesplan haengt unten am selben Gate 'Catch-up needed?'.
    $catchUp = New-CatchUpEntry -Package 'finance' -Feed 'fx' -CronKey 'refresh_fx_rates' `
        -OnDue @('Fetch EUR rates') -Origin @(-1040, -220)

    # Das Aufraeumen haengt nicht an der Faelligkeit: der Tagesplan soll auch dann taeglich aufraeumen, wenn ein
    # Nachhol-Lauf den Abruf heute schon erledigt hat. Eigenes Gate (Paket aktiv AND cron_enable), nur vom Tagesplan.
    $gateSweep = Build-Pg 'Cron enabled?' @(-600, -100) `
        "SELECT core.fn_package_active('finance') AND COALESCE(core.fn_config_get('finance','cron_enable','refresh_fx_rates') = 'true', false) AS enabled"
    $ifSweep = Build-If 'Cron on?' @(-400, -100) "={{ `$json.enabled }}" 'true' 'equals' 'boolean'

    $fetch = Build-Http 'Fetch EUR rates' @(300, 0) 'https://open.er-api.com/v6/latest/EUR'
    # Ausfall des Feeds bleibt hier stumm (wie 'Fetch prices'): sonst loeste der stuendliche Nachhol-Lauf bei jeder
    # Wiederholung einen Fehler-Alert aus. Gemeldet wird der Ausfall von cron_remind_missing_prices (erstmals nach finance.fx_feed_alert_days, dann alle 7 Tage)
    # (finance.fn_fx_feed_gap, am Quell-Datum as_of); der Upsert schreibt ohne rates nichts.
    $fetch['onError'] = 'continueRegularOutput'

    # Upsert via finance.fn_upsert_fx_rates: Upsert-Invarianten deterministisch testbar in der fn. as_of = UTC-Datum von
    # time_last_update_unix (Stand der Quelle, nicht "heute"): liefert die Quelle tagelang denselben Stand, entsteht keine
    # falsch datierte Zeile, und fn_fx_feed_gap erkennt den Ausfall. Fehlt das Feld, setzt die fn heute.
    $upsert = Build-Pg 'Upsert fx_rates' @(540, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'upserted')::int AS upserted FROM finance.fn_upsert_fx_rates(`$1::jsonb) AS r;" `
        ([ordered]@{
            rates = '$json.rates'
            as_of = "(Number(`$json.time_last_update_unix) > 0 ? new Date(Number(`$json.time_last_update_unix) * 1000).toISOString().slice(0, 10) : '')"
        })

    # Einmaliger Nachlauf der Kurs-Geschichte (5 Jahre EZB-Referenzkurse ueber Frankfurter v2, nur Provider ecb): der
    # Tages-Feed liefert keine Vergangenheit. Faellig, solange keine EZB-Zeile existiert (finance.fn_fx_history_due, die
    # auch den Zeitraum rechnet); ein gescheiterter Abruf wird am naechsten Tag wiederholt.
    $histDue = Build-Pg 'History due?' @(760, 0) 'SELECT finance.fn_fx_history_due() AS h'
    $histDue['onError'] = 'continueRegularOutput'
    $ifHist = Build-If 'History missing?' @(980, 0) "={{ !!(`$json.h && `$json.h.due) }}" 'true' 'equals' 'boolean'
    $H = "`$('History due?').first().json.h"
    $fetchHist = Build-Http 'Fetch ECB history' @(1200, -80) `
        "=https://api.frankfurter.dev/v2/rates?from={{ $H.from }}&to={{ $H.to }}&base=EUR&providers=ecb"
    # Antwort als Text: eine JSON-Liste wuerde n8n in ein Item je Zeile (rund 35 000) zerlegen. Fehler -> leer, kein Alert.
    # Kein retryOnFail: zusammen mit onError continue wiederholt n8n nicht (GH #10763); der naechste Tageslauf versucht es.
    $fetchHist['parameters']['options'] = [ordered]@{ timeout = 60000; response = [ordered]@{ response = [ordered]@{ responseFormat = 'text' } } }
    $fetchHist['onError'] = 'continueRegularOutput'
    $fetchHist.Remove('retryOnFail'); $fetchHist.Remove('maxTries'); $fetchHist.Remove('waitBetweenTries')
    $importHist = Build-Pg 'Import ECB history' @(1420, -80) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'upserted')::int AS upserted FROM finance.fn_upsert_fx_rates(`$1::jsonb) AS r;" `
        ([ordered]@{
            rows = "(() => { try { const a = JSON.parse(`$json.data || '[]'); return Array.isArray(a) ? a : []; } catch (e) { return []; } })()"
        })
    $importHist['onError'] = 'continueRegularOutput'

    # Huckepack: der taegliche Lauf raeumt auch verfallene Import- und Vorschlags-Stapel auf (finance.fn_import_sweep, 7 Tage);
    # nicht fatal, damit ein Aufraeum-Fehler nie den Kurs-Abruf aufhaelt.
    $sweep = Build-Pg 'Sweep import staging' @(-180, -160) 'SELECT finance.fn_import_sweep(7) AS deleted'
    $sweep['onError'] = 'continueRegularOutput'
    $stickySweep = Build-Sticky 'Aufräumen' @(-180, -360) 'Import-Stapel aufräumen (täglich)' 'Nur im Tagesplan-Pfad hinter eigenem Gate Cron enabled? (Paket aktiv, cron_enable), unabhängig davon, ob der Kurs-Abruf heute noch fällig ist (ein Nachhol-Lauf kann ihn schon erledigt haben): finance.fn_import_sweep(7) löscht nicht übernommene Import-Zeilen nach 7 Tagen und Dauerauftrags-Vorschlags-Stapel 7 Tage nach ihrem letzten Ergänzen. Läuft hier, weil dieser Cron täglich und unter finance_rw läuft; ein Fehler hält den Kurs-Abruf nicht auf.' 260 200

    $stickyOverview = Build-Sticky 'Überblick' @(-460, -260) `
        'FX-Kurs-Refresh (kein LLM, alle Währungen)' `
        'DREI Eingänge, EIN Pfad: (a) Schedule täglich (Cron aus core.config schedule.refresh_fx_rates, beim Einspielen eingesetzt; läuft durch dieselbe Fälligkeits-Prüfung wie das Nachholen); (b) n8n-Start und (c) stündlicher Check holen einen verpassten Lauf nach (Sticky Nachholen). Pfad: HTTP GET open.er-api.com/v6/latest/EUR (kostenlos, KEIN Key, Basis EUR, alle rund 160 Währungen in einer Antwort, 7 Tage/Woche) -> Upsert in finance.fx_rates: eine Zeile je gelieferter Währung, unabhängig davon, ob ein Konto oder eine Position sie nutzt (Wächter, Berater und Kürzel-Prüfung brauchen Kurse vorher). Darum kein Sofort-Abruf nach einem Write: der Kurs liegt schon da. Danach einmalig der EZB-Nachlauf (Sticky EZB-Nachlauf). Gelesen wird über finance.fn_to_eur / finance.fn_fx_rate. Abruf aus (cron_enable) heißt: gar keine neuen Kurse.' 280 640

    $stickyUpsert = Build-Sticky 'Upsert-Logik (via fn)' @(540, 200) `
        'finance.fn_upsert_fx_rates(p jsonb)' `
        'Atomarer Upsert in der fn (deterministisch getestet: test_fn_upsert_fx_rates.sql). fn-Schritte: jeder Key ^[A-Z]{3}$ außer EUR mit numerischem Wert > 0 wird eine Zeile (kaputte Einzelwerte zählen still in skipped); neue Codes legt die fn in finance.currencies an (ISO-Nachkommastellen). as_of = Datum aus time_last_update_unix der Antwort (Quell-Stand). ON CONFLICT (base,quote,as_of) -> idempotenter Tages-Upsert. rate-Richtung: 1 EUR = <rate> <CCY>; Umrechnung: betrag/rate (fn_to_eur).' 280 480

    $stickyHist = Build-Sticky 'EZB-Nachlauf (einmalig)' @(1200, 160) `
        'Kurs-Geschichte der letzten 5 Jahre einmal nachladen' `
        'Nach jedem Tages-Upsert fragt History due? finance.fn_fx_history_due(): fällig, solange keine Zeile mit source ecb existiert; die fn liefert auch from/to (heute minus 5 Jahre bis heute). Fetch ECB history = Frankfurter v2 /v2/rates mit providers=ecb (eine einheitliche Reihe, kostenlos, ohne Schlüssel; nur Arbeitstage, rund 30 Währungen; Wochenenden schließt die Kurs-Suche fn_fx_eur_row). Antwort als Text, Import ECB history parst sie im Ausdruck und schreibt per fn_upsert_fx_rates im Zeilen-Modus (source ecb, ON CONFLICT DO NOTHING: ein vorhandener Tageskurs gewinnt). Fehler oder leere Antwort -> nichts geschrieben, der nächste Tageslauf versucht es erneut; kein Alert.' 300 380

    $stickyGate = Build-Sticky 'Cron-Gate' @(-600, -240) `
        'Paket aktiv + cron_enable und fällig' `
        'WRITE-Cron -> finance_rw. Das Gate Catch-up needed? liest core.fn_package_active(''finance'') AND core.fn_config_get(''finance'',''cron_enable'',''refresh_fx_rates'')=''true'' AND finance.fn_feed_refresh_due(''fx'') (DB entscheidet, fail-closed: fehlende/false-Zeile -> aus). Toggle zur Laufzeit: lifeagents config set cron_enable refresh_fx_rates false — dann kommt kein neuer Kurs, und fn_fx_feed_gap meldet bewusst keinen Ausfall.' 300 360

    $stickyInit = Build-Sticky 'Nachholen (Start + stündlich)' @(-1040, -520) `
        'Verpassten Tageslauf nachholen (n8n-Start und jede Stunde)' `
        'Die Planzeit verfällt, wenn das Gerät aus ist oder schläft; der scheduleTrigger holt nicht nach. Drei Eingänge fragen deshalb dieselbe Prüfung: der Tagesplan, der n8n Trigger (Instance started, nach 30 s für Netz und DNS) und ein stündlicher Check (schedule.refresh_catchup, deckt auch das Aufwachen aus dem Ruhezustand, bei dem n8n nicht neu startet, und ein erst später aktiviertes Paket). Catch-up needed?: Paket aktiv, cron_enable an, und finance.fn_feed_refresh_due(''fx'') meldet, dass heute noch kein Tages-Feed geholt wurde (jüngster Abruf vor Beginn des heutigen Kalendertags der Haushalts-Zeitzone; ohne jede Zeile ebenfalls) oder der geholte Stand (as_of, UTC-Datum der Veröffentlichung) älter ist als das UTC-Datum von vor einer Stunde (Haushalt östlich von UTC holte vor der Veröffentlichung noch den Vortag; ein veralteter Feed wird so stündlich neu versucht). Sonst Ende ohne Abruf: normal ein Abruf je Kalendertag, wer zuerst kommt. Der Stunden-Check startet erst ab 03:15 (Manifest-Default), weil open.er-api.com seine Tageskurse um ca. 00:02 bis 00:26 UTC veröffentlicht. Fällt der Feed aus, bleibt der Lauf stumm (Fetch EUR rates: onError weiter) und wiederholt stündlich; den Ausfall meldet cron_remind_missing_prices nach finance.fx_feed_alert_days Tagen ohne neues Quell-Datum.' 340 340

    $nodes = @($trig, $disabled, $gateSweep, $ifSweep) + @($catchUp.Nodes) +
             @($fetch, $upsert, $histDue, $ifHist, $fetchHist, $importHist, $sweep, $stickySweep,
               $stickyOverview, $stickyUpsert, $stickyHist, $stickyGate, $stickyInit)
    $conns = [ordered]@{}
    foreach ($k in $catchUp.Connections.Keys) { $conns[$k] = $catchUp.Connections[$k] }
    $conns['Schedule (cron from config)'] = @{ main = @( ,@( (E 'Catch-up needed?'), (E 'Cron enabled?') ) ) }   # Tagesplan: Abruf-Gate + Aufraeum-Gate
    $conns2 = [ordered]@{
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Sweep import staging' ),   # true: Paket aktiv UND Cron an
            @( E 'Disabled' )
        ) }
        'Fetch EUR rates'             = @{ main = @( ,@( E 'Upsert fx_rates' ) ) }
        'Upsert fx_rates'             = @{ main = @( ,@( E 'History due?' ) ) }
        'History due?'                = @{ main = @( ,@( E 'History missing?' ) ) }
        'History missing?'            = @{ main = @(
            @( E 'Fetch ECB history' ),      # true: noch keine EZB-Zeile -> einmal nachladen
            @()
        ) }
        'Fetch ECB history'           = @{ main = @( ,@( E 'Import ECB history' ) ) }
    }
    foreach ($k in $conns2.Keys) { $conns[$k] = $conns2[$k] }
    return (Build-Workflow 'agent.finance.cron_refresh_fx_rates' $nodes $conns)
}
