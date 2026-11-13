#Requires -Version 5.1
# Definition agent.finance.cron_refresh_fx_rates -> Build-CronRefreshFxRates. Dot-gesourct von build.ps1.
# Deterministisch, kein LLM. Vier Eingaenge: (a) Schedule (taeglich; Platzhalter, den der Installer beim Einspielen aus
# core.config schedule.refresh_fx_rates einsetzt — scheduleTrigger liest seinen Plan nur beim Aktivieren) und (b)
# executeWorkflowTrigger fuer den Sofort-Fetch aus tool_create_account/tool_set_holding nach einem
# Fremdwaehrungs-Write, (c) n8nTrigger beim Start von n8n und (d) stuendlicher Schedule; (a), (c), (d) laufen durch
# New-CatchUpEntry (fn_feed_refresh_due: ein Abruf je Kalendertag). Alle muenden in denselben Pfad: Check fn_active_currencies ->
# HTTP GET open.er-api.com/v6/latest/EUR -> finance.fn_upsert_fx_rates. Nutzt aus dem Orchestrator-Scope:
# $RepoRoot, $Utf8NoBom, $CRED_POSTGRES + build_helpers (Build-Pg/Build-Http/Build-Sticky/E/Build-Workflow/New-Id).
function Build-CronRefreshFxRates {
    # Schreibt finance.fx_rates -> laeuft unter der engen Paket-Schreibrolle finance_rw;
    # funktions-lokaler Override (Dynamic-Scope -> Build-Pg sieht es), inkl. der Gate-Reads (fn_package_active/
    # fn_config_get sind an finance_rw EXECUTE-gegrantet).
    $CRED_POSTGRES = $CRED_FINANCE_RW

    # Node-Builder kommen zentral aus lib/build_helpers.ps1 (Build-ScheduleTrigger/Build-Http).
    $trig = Build-ScheduleTrigger @(-820, 0) -ScheduleKey 'refresh_fx_rates'

    # Zweiter Eingang: executeWorkflowTrigger ('Start') — tool_create_account/tool_set_holding rufen
    # den Workflow nach einem Fremdwaehrungs-Write als Sub auf (Sofort-Fetch, kein Warten auf 06:00).
    $subTrig = Build-Trigger @() @(-820, 200)

    # F9 Cron-Gating — Dual-Trigger: Tagesplan, n8n-Start und stuendlicher Check laufen durch ein Gate (New-CatchUpEntry:
    # Paket aktiv AND cron_enable AND fn_feed_refresh_due('fx'); die DB entscheidet, ein Abruf je Kalendertag, wer zuerst
    # kommt). Der Sofort-Fetch ('Start') ist Folge eines bereits erlaubten/HITL-approvten Fremdwaehrungs-Writes und prueft
    # nur Paket aktiv (cron_enable aus blockt ihn nicht). Aus -> 'Disabled' (No-op).
    $gateStart = Build-Pg 'Package active?' @(-600, 200) `
        "SELECT core.fn_package_active('finance') AS active"
    $ifStart = Build-If 'Package on?' @(-400, 240) "={{ `$json.active }}" 'true' 'equals' 'boolean'

    $disabled = Build-NoOp 'Disabled' @(-400, 420)

    # Nachholen: n8n-Start (nach 30 s fuer Netz/DNS) und stuendlicher Check (Ruhezustand startet n8n nicht neu) ueber den
    # gemeinsamen Eingang; der Tagesplan haengt unten am selben Gate 'Catch-up needed?'.
    $catchUp = New-CatchUpEntry -Package 'finance' -Feed 'fx' -CronKey 'refresh_fx_rates' `
        -OnDue @('Check active currencies') -Origin @(-1040, -220)

    # Das Aufraeumen haengt nicht an der Faelligkeit: ohne Fremdwaehrung ist der Abruf nie faellig, der Tagesplan soll
    # trotzdem taeglich aufraeumen. Eigenes Gate (Paket aktiv AND cron_enable), nur vom Tagesplan.
    $gateSweep = Build-Pg 'Cron enabled?' @(-600, -100) `
        "SELECT core.fn_package_active('finance') AND COALESCE(core.fn_config_get('finance','cron_enable','refresh_fx_rates') = 'true', false) AS enabled"
    $ifSweep = Build-If 'Cron on?' @(-400, -100) "={{ `$json.enabled }}" 'true' 'equals' 'boolean'

    # Early-Exit: fn_active_currencies() zaehlt Fremdwaehrungs-Objekte. Bei cnt=0 kein HTTP-Call.
    $checkCurr = Build-Pg 'Check active currencies' @(-180, 0) `
        'SELECT count(*)::int AS cnt FROM finance.fn_active_currencies()'

    $ifCurr = Build-If 'Any foreign currencies?' @(60, 0) `
        "={{ `$json.cnt }}" '0' 'larger' 'number'

    $fetch = Build-Http 'Fetch EUR rates' @(300, 0) 'https://open.er-api.com/v6/latest/EUR'
    # Ausfall des Feeds bleibt stumm (wie 'Fetch prices'): sonst loeste der stuendliche Nachhol-Lauf bei jeder Wiederholung
    # einen Fehler-Alert aus. Gemeldet wird die Luecke einmal ueber die bestehende Latch-Mechanik (Berater-Hinweis
    # fx_rate_stale nach finance.fx_stale_days, core.fn_should_notify); der Upsert schreibt ohne rates nichts.
    $fetch['onError'] = 'continueRegularOutput'

    # Upsert via finance.fn_upsert_fx_rates: Upsert-Invarianten deterministisch testbar in der fn.
    $upsert = Build-Pg 'Upsert fx_rates' @(540, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'upserted')::int AS upserted FROM finance.fn_upsert_fx_rates(`$1::jsonb) AS r;" `
        ([ordered]@{ rates = '$json.rates' })

    # Huckepack: der taegliche Lauf raeumt auch verfallene Import- und Vorschlags-Stapel auf (finance.fn_import_sweep, 7 Tage);
    # nicht fatal, damit ein Aufraeum-Fehler nie den Kurs-Abruf aufhaelt.
    $sweep = Build-Pg 'Sweep import staging' @(-180, -160) 'SELECT finance.fn_import_sweep(7) AS deleted'
    $sweep['onError'] = 'continueRegularOutput'
    $stickySweep = Build-Sticky 'Aufräumen' @(-180, -360) 'Import-Stapel aufräumen (täglich)' 'Nur im Tagesplan-Pfad hinter eigenem Gate Cron enabled? (Paket aktiv, cron_enable), unabhängig davon, ob der Kurs-Abruf fällig ist (ohne Fremdwährung ist er nie fällig): finance.fn_import_sweep(7) löscht nicht übernommene Import-Zeilen nach 7 Tagen und Dauerauftrags-Vorschlags-Stapel 7 Tage nach ihrem letzten Ergänzen. Läuft hier, weil dieser Cron täglich und unter finance_rw läuft; ein Fehler hält den Kurs-Abruf nicht auf.' 260 200

    $stickyOverview = Build-Sticky 'Überblick' @(-460, -260) `
        'FX-Kurs-Refresh (Dual-Trigger, kein LLM)' `
        'VIER Eingänge, EIN Pfad: (a) Schedule täglich (Cron aus core.config schedule.refresh_fx_rates, beim Einspielen eingesetzt; läuft durch dieselbe Fälligkeits-Prüfung wie das Nachholen); (b) executeWorkflowTrigger Start — Tools rufen den Workflow nach einem Write sofort auf (eliminiert das NULL-Fenster in Roll-up-Views bis zum nächsten Schedule-Lauf); (c) n8n-Start und (d) stündlicher Check holen einen verpassten Lauf nach (Sticky Nachholen). Pfad: prüfe aktive Fremdwährungs-Menge via fn_active_currencies() -> IF leer: Abbruch ohne HTTP-Call. Sonst: HTTP GET open.er-api.com/v6/latest/EUR (kostenlos, KEIN Key, Basis EUR, 7 Tage/Woche) -> Upsert in finance.fx_rates: eine Zeile je Fremdwährung aus aktiven Konten/Holdings — keine manuelle Pflege von finance.currencies nötig. Die Roll-up-Views konvertieren via finance.fn_to_eur (As-of-Lookup).' 280 640

    $stickyEarlyExit = Build-Sticky 'Early-Exit' @(60, 200) `
        'fn_active_currencies() leer -> kein HTTP-Call' `
        'Wenn kein Konto und keine Holding eine Nicht-EUR-Währung trägt, liefert fn_active_currencies() 0 Zeilen (cnt=0). Der IF-Zweig false beendet den Workflow hier — kein sinnloser Kurs-Fetch.' 220 240

    $stickyUpsert = Build-Sticky 'Upsert-Logik (via fn)' @(540, 200) `
        'finance.fn_upsert_fx_rates(p jsonb)' `
        'Atomarer Upsert in der fn (deterministisch getestet: test_fn_upsert_fx_rates.sql). fn-Schritte: je getrackter Währung aus fn_active_currencies() eine Zeile, rate aus p->rates->CCY; Guards: Key existiert (?), numerisch UND >0 (fängt 0/n-a-Kurse ab); ON CONFLICT (base,quote,as_of) -> idempotenter Tages-Upsert. rate-Richtung: 1 EUR = <rate> <CCY>; Umrechnung: betrag/rate (fn_to_eur).' 280 480

    $stickyGate = Build-Sticky 'F9 Cron-Gate (WS4a)' @(-600, -240) `
        'Paket-aktiv (beide) + cron_enable und fällig (Tagesplan/Nachholen)' `
        'Läuft unter finance_ro? Nein: WRITE-Cron -> finance_rw. Das Gate Catch-up needed? liest core.fn_package_active(''finance'') AND core.fn_config_get(''finance'',''cron_enable'',''refresh_fx_rates'')=''true'' AND finance.fn_feed_refresh_due(''fx'') (DB entscheidet, fail-closed: fehlende/false-Zeile -> aus). Toggle zur Laufzeit: lifeagents config set cron_enable refresh_fx_rates false. DUAL-TRIGGER: der Start-Pfad (Sofort-Fetch nach erlaubtem Write) prüft NUR Paket-aktiv (kein cron_enable, keine Fälligkeit) -> ein abgeschalteter Schedule blockt den approvten Sofort-Fetch nicht.' 300 440

    $stickyInit = Build-Sticky 'Nachholen (Start + stündlich)' @(-1040, -520) `
        'Verpassten Tageslauf nachholen (n8n-Start und jede Stunde)' `
        'Die Planzeit verfällt, wenn das Gerät aus ist oder schläft; der scheduleTrigger holt nicht nach. Drei Eingänge fragen deshalb dieselbe Prüfung: der Tagesplan, der n8n Trigger (Instance started, nach 30 s für Netz und DNS) und ein stündlicher Check (schedule.refresh_catchup, deckt auch das Aufwachen aus dem Ruhezustand, bei dem n8n nicht neu startet). Catch-up needed?: Paket aktiv, cron_enable an, und finance.fn_feed_refresh_due(''fx'') meldet, dass heute noch kein Kurs geholt wurde (jüngster Stand vor Beginn des heutigen Kalendertags der Haushalts-Zeitzone; ohne jeden Kurs ebenfalls). Sonst Ende ohne Abruf: ein Abruf je Kalendertag, wer zuerst kommt, Wochenende kostet nichts extra. Der Stunden-Check startet erst ab 03:15 (Manifest-Default), weil open.er-api.com seine Tageskurse um ca. 00:02 bis 00:26 UTC veröffentlicht. Fällt der Feed aus, bleibt der Lauf stumm (Fetch EUR rates: onError weiter) und wiederholt stündlich; die Lücke meldet einmal der Berater (fx_rate_stale, finance.fx_stale_days). Unabhängig von fx_stale_days entscheidet nur die Kalendertag-Regel.' 340 340

    $nodes = @($trig, $subTrig, $gateStart, $ifStart, $disabled, $gateSweep, $ifSweep) + @($catchUp.Nodes) +
             @($checkCurr, $ifCurr, $fetch, $upsert,
               $sweep, $stickySweep,
               $stickyOverview, $stickyEarlyExit, $stickyUpsert, $stickyGate, $stickyInit)
    $conns = [ordered]@{}
    foreach ($k in $catchUp.Connections.Keys) { $conns[$k] = $catchUp.Connections[$k] }
    $conns['Schedule (cron from config)'] = @{ main = @( ,@( (E 'Catch-up needed?'), (E 'Cron enabled?') ) ) }   # Tagesplan: Abruf-Gate + Aufraeum-Gate
    $conns2 = [ordered]@{
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Sweep import staging' ),   # true: Paket aktiv UND Cron an
            @( E 'Disabled' )
        ) }
        'Start'                      = @{ main = @( ,@( E 'Package active?' ) ) }
        'Package active?'             = @{ main = @( ,@( E 'Package on?' ) ) }
        'Package on?'                 = @{ main = @(
            @( E 'Check active currencies' ),   # true: Paket aktiv -> Sofort-Fetch
            @( E 'Disabled' )                    # false: Paket aus -> No-op
        ) }
        'Check active currencies'     = @{ main = @( ,@( E 'Any foreign currencies?' ) ) }
        'Any foreign currencies?'     = @{ main = @(
            @( E 'Fetch EUR rates' ),    # true: currencies present -> fetch
            @()                           # false: no foreign objects -> terminate
        ) }
        'Fetch EUR rates'             = @{ main = @( ,@( E 'Upsert fx_rates' ) ) }
    }
    foreach ($k in $conns2.Keys) { $conns[$k] = $conns2[$k] }
    return (Build-Workflow 'agent.finance.cron_refresh_fx_rates' $nodes $conns)
}
