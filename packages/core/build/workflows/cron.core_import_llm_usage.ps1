#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.cron_import_llm_usage --------------------------------------------------------------------------------------
# Nachts (schedule.llm_usage_import, Standard 03:40) ruft der Cron core.sub_import_llm_usage. Ohne ihn landen die KI-Kosten nur
# in core.llm_usage, wenn jemand /costs schickt, und der Gateway hebt die Mitschrift nur 62 Tage auf. Ungegatet (Core-Crons
# haben keinen cron_enable-Schalter), sendet nie eine Nachricht; scheitert der Abruf, meldet der Fehler-Workflow es.
function Build-CoreCronImportLlmUsage {
    $trig = Build-ScheduleTrigger @(-620, 0) -ScheduleKey 'llm_usage_import'

    $idImport = Get-RequiredWorkflowId 'core.sub_import_llm_usage' -Caller 'Build-CoreCronImportLlmUsage'
    $call = Build-CallWorkflow 'Import LLM usage' @(-400, 0) $idImport 'core.sub_import_llm_usage' ([ordered]@{ chat_id = '' })

    $ifOk = Build-If 'Import ok?' @(-180, 0) '={{ $json.ok === true }}' 'true' 'equals' 'boolean'
    $fail = Build-Err 'Gateway unreachable' @(40, 160) 'LLM usage import failed: gateway unreachable (127.0.0.1:8090/__usage)'

    $sticky = Build-Sticky 'Überblick' @(-640, -320) -Header 'Ablauf' `
        'core.cron_import_llm_usage — nächtlicher Import der KI-Kosten' `
        'Schedule (schedule.llm_usage_import aus core.config, Standard täglich 03:40 in der Haushalts-Zeitzone) -> Import LLM usage (ruft core.sub_import_llm_usage: holt die neuen Zeilen vom lokalen LLM-Gateway und spielt sie idempotent in core.llm_usage ein, derselbe Weg wie /costs) -> Import ok? (der Sub scheitert nie selbst, sondern meldet ok:false; sonst gäbe es zwei Alarme) -> false: Gateway unreachable (Stop and Error, der Lauf scheitert und core.sub_error_notify meldet es genau einmal; kein eigener Telegram-Versand). Ungegatet, weil Core-Crons keinen cron_enable-Schalter haben; abschalten nur über den Zeitplan.' 380 400

    $nodes = @($trig, $call, $ifOk, $fail, $sticky)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Import LLM usage' ) ) }
        'Import LLM usage'            = @{ main = @( ,@( E 'Import ok?' ) ) }
        'Import ok?'                  = @{ main = @( @(), @( E 'Gateway unreachable' ) ) }
    }
    return Build-Workflow 'core.cron_import_llm_usage' $nodes $conns
}
