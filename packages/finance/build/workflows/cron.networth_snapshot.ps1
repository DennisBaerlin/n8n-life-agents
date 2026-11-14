#Requires -Version 5.1
# Definition agent.finance.cron_networth_snapshot -> Build-CronNetworthSnapshot. Dot-gesourct von build.ps1.
# Vermoegens-Tagesstand festhalten: deterministisch, kein LLM, kein externer Abruf, keine Nachricht.
# Zeitplan schedule.networth_snapshot (Standard stuendlich) -> Gate (Paket aktiv AND cron_enable) -> finance.fn_record_networth_snapshot().
# Warum stuendlich mit Ueberschreiben statt Tagesplan + Nachhol-Gate wie die Kurs-Crons: gemeint ist der Stand am Ende
# des Tages; ein Nachholen am Folgetag haette den heutigen Stand unter einem falschen Tag gespeichert. Der letzte Lauf des
# Tages bleibt, ein Tag ohne Lauf bleibt leer.
function Build-CronNetworthSnapshot {
    # Schreibt finance.networth_snapshots -> enge Paket-Schreibrolle finance_rw (Dynamic Scope fuer Build-Pg).
    $CRED_POSTGRES = $CRED_FINANCE_RW

    $trig = Build-ScheduleTrigger @(-700, 0) -ScheduleKey 'networth_snapshot'

    $gate = Build-Pg 'Cron enabled?' @(-480, 0) `
        "SELECT core.fn_package_active('finance') AND COALESCE(core.fn_config_get('finance','cron_enable','networth_snapshot') = 'true', false) AS enabled"
    $gateIf = Build-If 'Cron on?' @(-260, 0) "={{ `$json.enabled }}" 'true' 'equals' 'boolean'
    $gateOff = Build-NoOp 'Disabled' @(-40, 200)

    $record = Build-Pg 'Record snapshot' @(-40, 0) `
        "SELECT finance.fn_record_networth_snapshot() AS r"

    $stickyOverview = Build-Sticky 'Überblick' @(-760, -320) `
        'Vermögens-Tagesstand (kein LLM, keine Nachricht)' `
        'Jeder Lauf (Zeitplan aus core.config schedule.networth_snapshot, Standard stündlich) ersetzt finance.fn_record_networth_snapshot den Stand des heutigen Tages in finance.networth_snapshots: je Konto, Depot, Immobilie und Vorsorge mit Anlageklasse und Person, Kredite negativ, aus der View networth_items. So bleibt der letzte Lauf des Tages stehen. Frühere Tage schreibt der Lauf nie: ist das Gerät einen ganzen Tag aus, bleibt der Tag leer, nichts wird nachgetragen. Die Anzeige füllt Lücken erst beim Lesen und markiert sie. Gate: Paket aktiv und cron_enable networth_snapshot = true (fail-closed); aus: lifeagents config set cron_enable networth_snapshot false.' 380 360

    $nodes = @($trig, $gate, $gateIf, $gateOff, $record, $stickyOverview)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Record snapshot' ),
            @( E 'Disabled' )
        ) }
    }
    return (Build-Workflow 'agent.finance.cron_networth_snapshot' $nodes $conns)
}