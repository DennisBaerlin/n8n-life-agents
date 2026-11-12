#Requires -Version 5.1
# Definition agent.finance.cron_refresh_fx_rates -> Build-CronRefreshFxRates. Dot-gesourct von build.ps1.
# Deterministisch, KEIN LLM. DREI EINGAENGE: (a) Schedule (taeglich; Platzhalter, den der Installer beim Einspielen aus
# core.config schedule.refresh_fx_rates einsetzt — scheduleTrigger liest seinen Plan nur beim Aktivieren) und (b)
# executeWorkflowTrigger fuer den Sofort-Fetch aus tool_create_account/tool_set_holding nach einem
# Fremdwaehrungs-Write, (c) n8nTrigger beim Start von n8n und (d) stuendlicher Schedule (beide Nachholen ueber
# fn_feed_refresh_due). Alle muenden in denselben Pfad: Check fn_active_currencies ->
# HTTP GET open.er-api.com/v6/latest/EUR -> finance.fn_upsert_fx_rates. Nutzt aus dem Orchestrator-Scope:
# $RepoRoot, $Utf8NoBom, $CRED_POSTGRES + build_helpers (Build-Pg/Build-Http/Build-Sticky/E/Build-Workflow/New-Id).
function Build-CronRefreshFxRates {
    # Schreibt finance.fx_rates -> laeuft unter der engen Paket-Schreibrolle finance_rw (Least-Privilege, D10);
    # funktions-lokaler Override (Dynamic-Scope -> Build-Pg sieht es), inkl. der Gate-Reads (fn_package_active/
    # fn_config_get sind an finance_rw EXECUTE-gegrantet).
    $CRED_POSTGRES = $CRED_FINANCE_RW

    # Node-Builder kommen zentral aus lib/build_helpers.ps1 (Build-ScheduleTrigger/Build-Http).
    $trig = Build-ScheduleTrigger @(-820, 0) -ScheduleKey 'refresh_fx_rates'

    # Zweiter Eingang: executeWorkflowTrigger ('Start') — tool_create_account/tool_set_holding rufen
    # den Workflow nach einem Fremdwaehrungs-Write als Sub auf (Sofort-Fetch, kein Warten auf 06:00).
    $subTrig = Build-Trigger @() @(-820, 200)

    # F9 Cron-Gating (WS4a) — Dual-Trigger: fn_package_active gated BEIDE Eingaenge (Paket aus = nichts);
    # der cron_enable-Flag gated NUR den Schedule-Pfad (der Start-Sofort-Fetch ist Folge eines bereits
    # erlaubten/HITL-approvten Fremdwaehrungs-Writes -> laeuft auch bei abgeschaltetem Schedule). Beide
    # muenden bei OK in 'Check active currencies', sonst in 'Disabled' (No-op). Vergleich entscheidet die DB.
    $gateSched = Build-Pg 'Cron enabled?' @(-600, 0) `
        "SELECT core.fn_package_active('finance') AND COALESCE(core.fn_config_get('finance','cron_enable','refresh_fx_rates') = 'true', false) AS enabled"
    $ifSched = Build-If 'Cron on?' @(-400, -40) "={{ `$json.enabled }}" 'true' 'equals' 'boolean'

    $gateStart = Build-Pg 'Package active?' @(-600, 200) `
        "SELECT core.fn_package_active('finance') AS active"
    $ifStart = Build-If 'Package on?' @(-400, 240) "={{ `$json.active }}" 'true' 'equals' 'boolean'

    $disabled = Build-NoOp 'Disabled' @(-400, 420)

    # Dritter Eingang: n8n-Start holt den verpassten Tageslauf nach (Geraet war um die Planzeit aus). Gleiches Gate wie der
    # Schedule, zusaetzlich nur bei Luecke. Die Pause gibt Netz und DNS nach dem Hochfahren Zeit (sonst Fehlalarm).
    $trigInit = Build-InstanceStartTrigger @(-1040, -220)
    $waitInit = Build-WaitSeconds 'Wait for network' @(-820, -220) 30
    # Vierter Eingang: stuendlicher Check faengt auch den Ruhezustand ab (n8n startet dabei nicht neu); fn_feed_refresh_due
    # entscheidet je Kalendertag, nicht der Workflow. Der Schedule-Knoten traegt einen eigenen Namen, weil 'Schedule (cron
    # from config)' der Tagesplan bleibt (workflow_lint, Test run).
    $trigHour = Build-ScheduleTrigger @(-1040, -80) -ScheduleKey 'refresh_catchup'
    $trigHour['name'] = 'Schedule (hourly catch-up)'
    $gateInit = Build-Pg 'Catch-up needed?' @(-600, -220) `
        "SELECT core.fn_package_active('finance') AND COALESCE(core.fn_config_get('finance','cron_enable','refresh_fx_rates') = 'true', false) AND finance.fn_feed_refresh_due('fx') AS due"
    $ifInit = Build-If 'Catch up?' @(-400, -220) "={{ `$json.due }}" 'true' 'equals' 'boolean'

    # Early-Exit: fn_active_currencies() zaehlt Fremdwaehrungs-Objekte. Bei cnt=0 kein HTTP-Call.
    $checkCurr = Build-Pg 'Check active currencies' @(-180, 0) `
        'SELECT count(*)::int AS cnt FROM finance.fn_active_currencies()'

    $ifCurr = Build-If 'Any foreign currencies?' @(60, 0) `
        "={{ `$json.cnt }}" '0' 'larger' 'number'

    $fetch = Build-Http 'Fetch EUR rates' @(300, 0) 'https://open.er-api.com/v6/latest/EUR'

    # Upsert via finance.fn_upsert_fx_rates (A4b): Upsert-Invarianten deterministisch testbar in der fn.
    $upsert = Build-Pg 'Upsert fx_rates' @(540, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, (r->>'upserted')::int AS upserted FROM finance.fn_upsert_fx_rates(`$1::jsonb) AS r;" `
        ([ordered]@{ rates = '$json.rates' })

    # Huckepack: der taegliche Lauf raeumt auch verfallene Import- und Vorschlags-Stapel auf (finance.fn_import_sweep, 7 Tage);
    # nicht fatal, damit ein Aufraeum-Fehler nie den Kurs-Abruf aufhaelt.
    $sweep = Build-Pg 'Sweep import staging' @(-180, -160) 'SELECT finance.fn_import_sweep(7) AS deleted'
    $sweep['onError'] = 'continueRegularOutput'
    $stickySweep = Build-Sticky 'Aufräumen' @(-180, -360) 'Import-Stapel aufräumen (täglich)' 'Nur im Zeitplan-Pfad: finance.fn_import_sweep(7) löscht nicht übernommene Import-Zeilen nach 7 Tagen und Dauerauftrags-Vorschlags-Stapel 7 Tage nach ihrem letzten Ergänzen. Läuft hier, weil dieser Cron täglich und unter finance_rw läuft; ein Fehler hält den Kurs-Abruf nicht auf.' 260 200

    $stickyOverview = Build-Sticky 'Überblick' @(-460, -260) `
        'FX-Kurs-Refresh (Dual-Trigger, kein LLM)' `
        'VIER Eingänge, EIN Pfad: (a) Schedule täglich (Cron aus core.config schedule.refresh_fx_rates, beim Einspielen eingesetzt); (b) executeWorkflowTrigger Start — Tools rufen den Workflow nach einem Write sofort auf (eliminiert das NULL-Fenster in Roll-up-Views bis zum nächsten Schedule-Lauf); (c) n8n-Start und (d) stündlicher Check holen einen verpassten Lauf nach (Sticky Nachholen). Pfad: prüfe aktive Fremdwährungs-Menge via fn_active_currencies() -> IF leer: Abbruch ohne HTTP-Call. Sonst: HTTP GET open.er-api.com/v6/latest/EUR (kostenlos, KEIN Key, Basis EUR, 7 Tage/Woche) -> Upsert in finance.fx_rates: eine Zeile je Fremdwährung aus aktiven Konten/Holdings — keine manuelle Pflege von finance.currencies nötig. Die Roll-up-Views konvertieren via finance.fn_to_eur (As-of-Lookup).' 280 640

    $stickyEarlyExit = Build-Sticky 'Early-Exit' @(60, 200) `
        'fn_active_currencies() leer -> kein HTTP-Call' `
        'Wenn kein Konto und keine Holding eine Nicht-EUR-Währung trägt, liefert fn_active_currencies() 0 Zeilen (cnt=0). Der IF-Zweig false beendet den Workflow hier — kein sinnloser Kurs-Fetch.' 220 240

    $stickyUpsert = Build-Sticky 'Upsert-Logik (via fn)' @(540, 200) `
        'finance.fn_upsert_fx_rates(p jsonb)' `
        'Atomarer Upsert in der fn (deterministisch getestet: test_fn_upsert_fx_rates.sql). fn-Schritte: je getrackter Währung aus fn_active_currencies() eine Zeile, rate aus p->rates->CCY; Guards: Key existiert (?), numerisch UND >0 (fängt 0/n-a-Kurse ab); ON CONFLICT (base,quote,as_of) -> idempotenter Tages-Upsert. rate-Richtung: 1 EUR = <rate> <CCY>; Umrechnung: betrag/rate (fn_to_eur).' 280 480

    $stickyGate = Build-Sticky 'F9 Cron-Gate (WS4a)' @(-600, -240) `
        'Paket-aktiv (beide) + cron_enable (nur Schedule)' `
        'Läuft unter finance_ro? Nein: WRITE-Cron -> finance_rw. Gate liest core.fn_package_active(''finance'') AND core.fn_config_get(''finance'',''cron_enable'',''refresh_fx_rates'')=''true'' (DB entscheidet, fail-closed: fehlende/false-Zeile -> aus). Toggle zur Laufzeit: lifeagents config set cron_enable refresh_fx_rates false. DUAL-TRIGGER: der Start-Pfad (Sofort-Fetch nach erlaubtem Write) prüft NUR Paket-aktiv (kein cron_enable) -> ein abgeschalteter Schedule blockt den approvten Sofort-Fetch nicht.' 300 440

    $stickyInit = Build-Sticky 'Nachholen (Start + stündlich)' @(-1040, -520) `
        'Verpassten Tageslauf nachholen (n8n-Start und jede Stunde)' `
        'Die Planzeit verfällt, wenn das Gerät aus ist oder schläft; der scheduleTrigger holt nicht nach. Zwei Eingänge fragen deshalb dieselbe Prüfung: der n8n Trigger (Instance started, nach 30 s für Netz und DNS) und ein stündlicher Check (schedule.refresh_catchup, deckt auch das Aufwachen aus dem Ruhezustand, bei dem n8n nicht neu startet). Catch-up needed?: Paket aktiv, cron_enable an, und finance.fn_feed_refresh_due(''fx'') meldet, dass heute noch kein Kurs geholt wurde (jüngster Stand vor Beginn des heutigen Kalendertags der Haushalts-Zeitzone; ohne jeden Kurs ebenfalls). Sonst Ende ohne Abruf: ein Abruf je Kalendertag, Wochenende kostet nichts extra. Unabhängig von finance.fx_stale_days (Anzeige/Berater).' 340 340

    $nodes = @($trig, $subTrig, $gateSched, $ifSched, $gateStart, $ifStart, $disabled,
               $trigInit, $waitInit, $trigHour, $gateInit, $ifInit,
               $checkCurr, $ifCurr, $fetch, $upsert,
               $sweep, $stickySweep,
               $stickyOverview, $stickyEarlyExit, $stickyUpsert, $stickyGate, $stickyInit)
    $conns = [ordered]@{
        'Instance started'            = @{ main = @( ,@( E 'Wait for network' ) ) }
        'Wait for network'            = @{ main = @( ,@( E 'Catch-up needed?' ) ) }
        'Schedule (hourly catch-up)'  = @{ main = @( ,@( E 'Catch-up needed?' ) ) }
        'Catch-up needed?'            = @{ main = @( ,@( E 'Catch up?' ) ) }
        'Catch up?'                   = @{ main = @(
            @( E 'Check active currencies' ),   # true: Luecke -> nachholen
            @( E 'Disabled' )
        ) }
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( (E 'Check active currencies'), (E 'Sweep import staging') ),   # true: Paket aktiv UND Cron an
            @( E 'Disabled' )                    # false: aus -> No-op
        ) }
        'Start'                       = @{ main = @( ,@( E 'Package active?' ) ) }
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
    return (Build-Workflow 'agent.finance.cron_refresh_fx_rates' $nodes $conns)
}
