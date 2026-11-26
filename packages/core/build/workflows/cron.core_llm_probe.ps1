#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.cron_llm_probe ------------------------------------------------------------------------------------------------
# Takt der Nachschau waehrend einer KI-Pause (schedule.llm_probe, Standard alle 2 Minuten): ruft core.sub_llm_probe. Ob und wann
# wirklich nachgeschaut wird, entscheidet core.fn_llm_probe_due (ohne offene Pause nur ein kurzer DB-Aufruf, keine Anfrage an Claude).
# Ungegatet ausser core aktiv (Core-Crons haben keinen cron_enable-Schalter).
function Build-CoreCronLlmProbe {
    $trig = Build-ScheduleTrigger @(-880, 0) -ScheduleKey 'llm_probe'

    $gate = Build-Pg 'Core active?' @(-660, 0) "=SELECT core.fn_package_active('core') AS enabled" $null
    $ifOn = Build-If 'Active?' @(-440, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $idProbe = Get-RequiredWorkflowId 'core.sub_llm_probe' -Caller 'Build-CoreCronLlmProbe'
    $call = Build-CallWorkflow 'Run probe' @(-220, 0) $idProbe 'core.sub_llm_probe' ([ordered]@{ trigger = 'cron'; chat_id = '' })

    $sticky = Build-Sticky 'Überblick' @(-900, -300) -Header 'Ablauf' `
        'core.cron_llm_probe — Takt der Nachschau während einer KI-Pause' `
        'Schedule (schedule.llm_probe, Standard alle 2 Minuten) -> Core active? -> Run probe (core.sub_llm_probe, trigger cron). Ohne offene Pause nur ein kurzer DB-Aufruf (Aufräumen alter gemerkter Nachrichten), keine Anfrage an Claude; Plan und Sperre der Nachschau hält core.fn_llm_probe_due. Erfolgreiche Läufe werden nicht gespeichert.' 380 300

    $nodes = @($trig, $gate, $ifOn, $call, $sticky)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Core active?' ) ) }
        'Core active?'                = @{ main = @( ,@( E 'Active?' ) ) }
        'Active?'                     = @{ main = @( @( E 'Run probe' ), @() ) }
    }
    $wf = Build-Workflow 'core.cron_llm_probe' $nodes $conns
    $wf.settings['saveDataSuccessExecution'] = 'none'
    return $wf
}
