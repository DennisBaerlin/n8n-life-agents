#Requires -Version 5.1
# Definition agent.finance.cron_refresh_fx_rates -> Build-CronRefreshFxRates. Dot-gesourct von build.ps1.
# Deterministisch, kein LLM. Drei Eingaenge: (a) Schedule (taeglich; Platzhalter, den der Installer beim Einspielen aus
# core.config schedule.refresh_fx_rates einsetzt — scheduleTrigger liest seinen Plan nur beim Aktivieren), (b) n8nTrigger
# beim Start von n8n und (c) stuendlicher Schedule; alle laufen durch New-CatchUpEntry (fn_feed_refresh_due: ein Abruf je
# Kalendertag). Pfad: HTTP GET open.er-api.com/v6/latest/EUR -> finance.fn_upsert_fx_rates (jede gelieferte Waehrung,
# as_of = Quell-Datum) -> fehlende EZB-Tage holen (finance.fn_fx_history_due: einmal 5 Jahre Nachlauf, danach Ersatzquelle,
# wenn der Tages-Feed fuer heute nichts geliefert hat) -> Edelmetall-Preise je Metall (finance.fn_fx_metal_due, Frankfurter-
# Mischkurs, einmal 5 Jahre, danach ab dem juengsten Tag). Nutzt aus dem Orchestrator-Scope: $RepoRoot, $Utf8NoBom, $CRED_POSTGRES + build_helpers
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
    # Wiederholung einen Fehler-Alert aus. Der Upsert schreibt ohne rates nichts, danach holt 'History due?' die EZB als
    # Ersatz; gemeldet wird erst, wenn auch die ausbleibt (cron_remind_missing_prices, finance.fn_fx_feed_gap).
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

    # EZB-Referenzkurse ueber Frankfurter v2 (nur Provider ecb): einmal 5 Jahre Nachlauf (der Tages-Feed liefert keine
    # Vergangenheit), danach Ersatzquelle, solange der Tages-Feed fuer heute fehlt. Ob und welcher Zeitraum faellig ist,
    # rechnet finance.fn_fx_history_due; ein gescheiterter Abruf wird beim naechsten Lauf wiederholt.
    $histDue = Build-Pg 'History due?' @(760, 0) 'SELECT finance.fn_fx_history_due() AS h'
    $histDue['onError'] = 'continueRegularOutput'
    $ifHist = Build-If 'History missing?' @(980, 0) "={{ !!(`$json.h && `$json.h.due) }}" 'true' 'equals' 'boolean'
    $H = "`$('History due?').first().json.h"
    $fetchHist = Build-Http 'Fetch ECB history' @(1200, -80) `
        "=https://api.frankfurter.dev/v2/rates?from={{ $H.from }}&to={{ $H.to }}&base=EUR&providers=ecb"
    # Antwort als Text: eine JSON-Liste wuerde n8n in ein Item je Zeile (rund 35 000) zerlegen. Fehler -> leer, kein Alert.
    # Kein retryOnFail: zusammen mit onError continue wiederholt n8n nicht (GH #10763); der naechste Lauf versucht es.
    $fetchHist['parameters']['options'] = [ordered]@{ timeout = 60000; response = [ordered]@{ response = [ordered]@{ responseFormat = 'text' } } }
    $fetchHist['onError'] = 'continueRegularOutput'
    $fetchHist.Remove('retryOnFail'); $fetchHist.Remove('maxTries'); $fetchHist.Remove('waitBetweenTries')
    $importHist = Build-Pg 'Import ECB history' @(1420, -80) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'upserted')::int AS upserted FROM finance.fn_upsert_fx_rates(`$1::jsonb) AS r;" `
        ([ordered]@{
            rows = "(() => { try { const a = JSON.parse(`$json.data || '[]'); return Array.isArray(a) ? a : []; } catch (e) { return []; } })()"
        })
    $importHist['onError'] = 'continueRegularOutput'

    # Edelmetalle (XAU/XAG) ueber Frankfurter v2 (Mischkurs vieler Zentralbanken, je Feinunze): ein Item je Metall aus
    # finance.fn_fx_metal_due (einmal 5 Jahre, danach ab dem juengsten Tag). Daten als Text: n8n zerlegte ein Postgres-date
    # in ein JS-Datum mit Zeitzone, eine JSON-Liste in ein Item je Tag. base=Metall, weil base=EUR nur 5 Stellen liefert;
    # die DB invertiert (fn_upsert_fx_rates). Fehler -> nichts geschrieben, kein Alert; den Ausfall meldet der Waechter.
    $metalsDue = Build-Pg 'Metals due?' @(1640, 0) `
        'SELECT m.metal, m.from_date::text AS from_date, m.to_date::text AS to_date FROM finance.fn_fx_metal_due() m'
    $metalsDue['onError'] = 'continueRegularOutput'
    $fetchMetal = Build-Http 'Fetch metal prices' @(1860, 0) `
        '=https://api.frankfurter.dev/v2/rates?base={{ $json.metal }}&quotes=EUR&from={{ $json.from_date }}&to={{ $json.to_date }}'
    $fetchMetal['parameters']['options'] = [ordered]@{ timeout = 60000; response = [ordered]@{ response = [ordered]@{ responseFormat = 'text' } } }
    $fetchMetal['onError'] = 'continueRegularOutput'
    $fetchMetal.Remove('retryOnFail'); $fetchMetal.Remove('maxTries'); $fetchMetal.Remove('waitBetweenTries')
    $importMetal = Build-Pg 'Import metal prices' @(2080, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'upserted')::int AS upserted FROM finance.fn_upsert_fx_rates(`$1::jsonb) AS r;" `
        ([ordered]@{
            rows = "(() => { try { const a = JSON.parse(`$json.data || '[]'); return Array.isArray(a) ? a : []; } catch (e) { return []; } })()"
        })
    $importMetal['onError'] = 'continueRegularOutput'

    # Huckepack: der taegliche Lauf raeumt auch verfallene Import- und Vorschlags-Stapel auf (finance.fn_import_sweep mit ihrer eigenen Frist);
    # nicht fatal, damit ein Aufraeum-Fehler nie den Kurs-Abruf aufhaelt.
    $sweep = Build-Pg 'Sweep import staging' @(-180, -160) 'SELECT finance.fn_import_sweep() AS deleted'
    $sweep['onError'] = 'continueRegularOutput'
    $stickySweep = Build-Sticky 'Aufräumen' @(-180, -360) 'Import-Stapel aufräumen (täglich)' 'Nur im Tagesplan-Pfad hinter eigenem Gate Cron enabled? (Paket aktiv, cron_enable), unabhängig davon, ob der Kurs-Abruf heute noch fällig ist (ein Nachhol-Lauf kann ihn schon erledigt haben): finance.fn_import_sweep() löscht nicht übernommene Import-Zeilen und Dauerauftrags-Vorschlags-Stapel nach der Frist der fn (Default des Parameters, gerechnet ab dem letzten Ergänzen). Läuft hier, weil dieser Cron täglich und unter finance_rw läuft; ein Fehler hält den Kurs-Abruf nicht auf.' 260 200

    $stickyOverview = Build-Sticky 'Überblick' @(-460, -260) `
        'FX-Kurs-Refresh (kein LLM, alle Währungen)' `
        'DREI Eingänge, EIN Pfad: (a) Schedule täglich (Cron aus core.config schedule.refresh_fx_rates, beim Einspielen eingesetzt; läuft durch dieselbe Fälligkeits-Prüfung wie das Nachholen); (b) n8n-Start und (c) stündlicher Check holen einen verpassten Lauf nach (Sticky Nachholen). Pfad: HTTP GET open.er-api.com/v6/latest/EUR (kostenlos, KEIN Key, Basis EUR, alle rund 160 Währungen in einer Antwort, 7 Tage/Woche) -> Upsert in finance.fx_rates: eine Zeile je gelieferter Währung, unabhängig davon, ob ein Konto oder eine Position sie nutzt (Wächter, Berater und Kürzel-Prüfung brauchen Kurse vorher). Darum kein Sofort-Abruf nach einem Write: der Kurs liegt schon da. Danach fehlende EZB-Tage (Sticky EZB-Kurse: einmal 5 Jahre Nachlauf, danach Ersatzquelle bei Feed-Ausfall) und die Edelmetall-Preise (Sticky Edelmetalle). Gelesen wird über finance.fn_to_eur / finance.fn_fx_rate. Abruf aus (cron_enable) heißt: gar keine neuen Kurse.' 280 640

    $stickyUpsert = Build-Sticky 'Upsert-Logik (via fn)' @(540, 200) `
        'finance.fn_upsert_fx_rates(p jsonb)' `
        'Atomarer Upsert in der fn (deterministisch getestet: test_fn_upsert_fx_rates.sql). fn-Schritte: jeder Key ^[A-Z]{3}$ außer EUR und außer Edelmetallen (die kommen nur über Sticky Edelmetalle) mit numerischem Wert > 0 wird eine Zeile (kaputte Einzelwerte zählen still in skipped); neue Codes legt die fn in finance.currencies an (ISO-Nachkommastellen). as_of = Datum aus time_last_update_unix der Antwort (Quell-Stand). ON CONFLICT (base,quote,as_of) -> idempotenter Tages-Upsert. rate-Richtung: 1 EUR = <rate> <CCY>; Umrechnung: betrag/rate (fn_to_eur).' 280 480

    $stickyHist = Build-Sticky 'EZB-Kurse (Nachlauf + Ersatz)' @(1200, 160) `
        'Fehlende EZB-Tage holen: einmal 5 Jahre, danach als Ersatzquelle' `
        'Nach jedem Tages-Upsert (auch einem gescheiterten) fragt History due? finance.fn_fx_history_due() und bekommt from/to: (1) Nachlauf, solange keine Zeile mit source ecb existiert: heute minus 5 Jahre bis heute; (2) Ersatzquelle, wenn der Tages-Feed für das UTC-Datum von heute nichts geliefert hat und auch sonst kein Kurs von heute liegt: ab dem Tag nach dem jüngsten Kurs bis heute. Weil ein ausgefallener Feed fällig bleibt, läuft (2) mit dem stündlichen Nachholen mit; die EZB veröffentlicht werktags gegen 16 Uhr MEZ, davor und am Wochenende kommt eine leere Antwort. Die Ausfall-Meldung (cron_remind_missing_prices) kommt erst, wenn auch die EZB ausbleibt. Fetch ECB history = Frankfurter v2 /v2/rates mit providers=ecb (eine einheitliche Reihe, kostenlos, ohne Schlüssel; nur Arbeitstage, rund 30 Währungen; Wochenenden schließt die Kurs-Suche fn_fx_eur_row). Antwort als Text, Import ECB history parst sie im Ausdruck und schreibt per fn_upsert_fx_rates im Zeilen-Modus (source ecb; ein vorhandener Kurs einer anderen Quelle gewinnt, eine EZB-Zeile desselben Tages wird überschrieben). Kommt der Tages-Feed später doch, überschreibt sein Kurs die EZB-Zeile desselben Tages. Fehler oder leere Antwort -> nichts geschrieben, der nächste Lauf versucht es erneut; kein Alert.' 300 380

    $stickyMetal = Build-Sticky 'Edelmetalle' @(1860, 160) `
        'Gold und Silber (XAU/XAG) je Feinunze' `
        'Läuft in jedem Abruf nach dem EZB-Schritt (auch wenn der nichts zu tun hatte). Metals due? = finance.fn_fx_metal_due(): ein Item je Metall aus finance.currencies (kind metal, vom Init geseedet), from = jüngster gespeicherter Tag des Metalls (wird beim nächsten Abruf erneut geholt, weil sich der Mischkurs eines Tages danach noch ändern kann), ohne Zeile 5 Jahre zurück; to = UTC-Datum. Fetch metal prices = Frankfurter v2 /v2/rates?base=<Metall>&quotes=EUR (Mischkurs vieler Zentralbanken mit Ausreißer-Filter, auch am Wochenende, kostenlos, ohne Schlüssel), Antwort als Text. Import metal prices schreibt per fn_upsert_fx_rates im Zeilen-Modus: die DB speichert EUR -> Metall mit dem Kehrwert (fx_rates bleibt EUR-quotiert), Quelle frankfurter, gleiche Quelle zieht nach, eine andere gewinnt. Damit gibt es den Metallpreis über fn_fx_rate in jeder Währung, die Einheit (Unze, Gramm, Kilo) rechnet die Wächter-Methode fx_rate. Metall-Zeilen zählen weder für die Fälligkeit des Tages-Feeds noch für Ausfall-Meldung oder EZB-Ersatz; fällt die Quelle aus, meldet der einzelne Wächter nach monitor.fx_stale_days den veralteten Kurs. Fehler -> nichts geschrieben, kein Alert.' 300 400

    $stickyGate = Build-Sticky 'Cron-Gate' @(-600, -240) `
        'Paket aktiv + cron_enable und fällig' `
        'WRITE-Cron -> finance_rw. Das Gate Catch-up needed? liest core.fn_package_active(''finance'') AND core.fn_config_get(''finance'',''cron_enable'',''refresh_fx_rates'')=''true'' AND finance.fn_feed_refresh_due(''fx'') (DB entscheidet, fail-closed: fehlende/false-Zeile -> aus). Toggle zur Laufzeit: lifeagents config set cron_enable refresh_fx_rates false — dann kommt kein neuer Kurs, und fn_fx_feed_gap meldet bewusst keinen Ausfall.' 300 360

    $stickyInit = Build-Sticky 'Nachholen (Start + stündlich)' @(-1040, -520) `
        'Verpassten Tageslauf nachholen (n8n-Start und jede Stunde)' `
        'Die Planzeit verfällt, wenn das Gerät aus ist oder schläft; der scheduleTrigger holt nicht nach. Drei Eingänge fragen deshalb dieselbe Prüfung: der Tagesplan, der n8n Trigger (Instance started, nach 30 s für Netz und DNS) und ein stündlicher Check (schedule.refresh_catchup, deckt auch das Aufwachen aus dem Ruhezustand, bei dem n8n nicht neu startet, und ein erst später aktiviertes Paket). Catch-up needed?: Paket aktiv, cron_enable an, und finance.fn_feed_refresh_due(''fx'') meldet, dass heute noch kein Tages-Feed geholt wurde (jüngster Abruf vor Beginn des heutigen Kalendertags der Haushalts-Zeitzone; ohne jede Zeile ebenfalls) oder der geholte Stand (as_of, UTC-Datum der Veröffentlichung) älter ist als das UTC-Datum von vor einer Stunde (Haushalt östlich von UTC holte vor der Veröffentlichung noch den Vortag; ein veralteter Feed wird so stündlich neu versucht). Sonst Ende ohne Abruf: normal ein Abruf je Kalendertag, wer zuerst kommt. Der Stunden-Check startet erst ab 03:15 (Manifest-Default), weil open.er-api.com seine Tageskurse um ca. 00:02 bis 00:26 UTC veröffentlicht. Fällt der Feed aus, bleibt der Lauf stumm (Fetch EUR rates: onError weiter) und wiederholt stündlich; bis dahin springt die EZB als Ersatzquelle ein (Sticky EZB-Kurse); den Ausfall meldet cron_remind_missing_prices erst, wenn auch die EZB finance.fx_feed_alert_days Werktage nichts liefert.' 340 340

    $nodes = @($trig, $disabled, $gateSweep, $ifSweep) + @($catchUp.Nodes) +
             @($fetch, $upsert, $histDue, $ifHist, $fetchHist, $importHist, $metalsDue, $fetchMetal, $importMetal,
               $sweep, $stickySweep, $stickyOverview, $stickyUpsert, $stickyHist, $stickyMetal, $stickyGate, $stickyInit)
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
            @( E 'Fetch ECB history' ),      # true: Nachlauf aussteht oder Tages-Feed fehlt heute
            @( E 'Metals due?' )             # false: weiter mit den Edelmetallen
        ) }
        'Fetch ECB history'           = @{ main = @( ,@( E 'Import ECB history' ) ) }
        'Import ECB history'          = @{ main = @( ,@( E 'Metals due?' ) ) }
        'Metals due?'                 = @{ main = @( ,@( E 'Fetch metal prices' ) ) }
        'Fetch metal prices'          = @{ main = @( ,@( E 'Import metal prices' ) ) }
    }
    foreach ($k in $conns2.Keys) { $conns[$k] = $conns2[$k] }
    return (Build-Workflow 'agent.finance.cron_refresh_fx_rates' $nodes $conns)
}
