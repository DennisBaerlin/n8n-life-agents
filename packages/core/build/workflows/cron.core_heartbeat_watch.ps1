#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.cron_heartbeat_watch ------------------------------------------------------------------------------------------
# Waechter ueber den Hintergrund-Teil (Update-Pruefung, Auftraege aus dem Chat, Sicherung): alle 10 Minuten zaehlt
# core.fn_heartbeat_claim die beobachtete Zeit seit dem letzten Lebenszeichen und liefert die faelligen Owner-Texte fertig;
# je Text ein Telegram-Versuch, danach core.fn_heartbeat_finish mit dem Ergebnis. Schwellen, Fenster, Sprache und Takt
# der Wiederholungen entscheidet allein die DB. Ungegatet ausser core aktiv (Core-Crons haben keinen cron_enable-Schalter);
# kein Sprachmodell. Bei uns anders als ein Monitor-Trigger (agent.monitor_triggers): der kann weder Entwarnung noch
# Erinnerungs-Takt und waere vom Monitor-Agenten abschaltbar (docs/reference/core.md *Waechter*).
function Build-CoreCronHeartbeatWatch {
    $trig = Build-ScheduleTrigger @(-1100, 0) -ScheduleKey 'heartbeat_watch'

    $gate = Build-Pg 'Core active?' @(-880, 0) "=SELECT core.fn_package_active('core') AS enabled" $null
    $ifOn = Build-If 'Active?' @(-660, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $off = Build-NoOp 'Inactive' @(-660, 200)

    $claim = Build-Pg 'Find messages' @(-440, 0) `
        "=WITH c AS MATERIALIZED (SELECT core.fn_heartbeat_claim('{}'::jsonb) AS r) SELECT c.r::text AS r FROM c;" $null

    $splitJs = @'
let r = {};
try { r = JSON.parse($input.first().json.r || '{}'); } catch (e) { r = {}; }
const list = Array.isArray(r.messages) ? r.messages : [];
return list.map(m => ({ json: { key: String(m.key), chat_id: String(m.chat_id), text: String(m.text || '') } }));
'@
    $split = [ordered]@{
        parameters = [ordered]@{ jsCode = $splitJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-220, 0)
        id = (New-Id); name = 'Split messages'
    }

    # MaxTries 1 + continueErrorOutput: Retry x onError=Continue ist in n8n defekt (GH #10763); die Wiederholung macht der
    # naechste Lauf nach dem Sende-Abstand aus fn_heartbeat_finish.
    $send = New-TelegramSendNode 'Send' @(0, 0) "={{ `$json.text }}" -ChatIdExpr "={{ String(`$json.chat_id) }}" `
        -OnError 'continueErrorOutput' -MaxTries 1
    $finishParam = { param($sent) [ordered]@{ key = "`$('Split messages').item.json.key"; sent = $sent } }
    $ok = Build-Pg 'Finish sent' @(220, -120) '=SELECT core.fn_heartbeat_finish($1::jsonb) AS r;' (& $finishParam 'true')
    $failed = Build-Pg 'Finish failed' @(220, 120) '=SELECT core.fn_heartbeat_finish($1::jsonb) AS r;' (& $finishParam 'false')

    $sticky = Build-Sticky 'Überblick' @(-1140, -440) -Header 'Ablauf' `
        'core.cron_heartbeat_watch — Wächter über den Hintergrund-Teil (deterministisch, kein LLM)' `
        'Rund um die Uhr (schedule.heartbeat_watch, Standard alle 10 Minuten); ob gerade gesendet werden darf (Erinnerungs-Fenster), entscheidet die DB, damit das Zählen nachts weiterläuft. Core active? (Paket core aus -> Inactive, nichts passiert; Core-Crons haben keinen cron_enable-Schalter). Lebenszeichen schreibt der root-Teil selbst (core.fn_heartbeat_record: Minuten-Schleife bzw. Timer, Release-Check, Sicherung). Find messages = core.fn_heartbeat_claim (MATERIALIZED, ein Aufruf): zählt nur Zeit, in der dieser Wächter selbst lief (zugeklappter Rechner löst nichts aus), Schwellen watch.* aus core.config, nur an den Owner, Docker-Verbund: Ursache vor Folge. Split messages -> Send (je Text ein Versuch) -> Finish sent / Finish failed = core.fn_heartbeat_finish. Gemerkt wird erst nach dem Telegram-Erfolg; scheitert das Senden (Netz weg, Bot blockiert), wächst der Abstand bis zum nächsten Versuch (30 Minuten, verdoppelt, höchstens 24 Stunden). Kein Stop and Error beim Sendefehler: der Fehler-Alarm ginge über denselben kaputten Weg.' 420 520

    $nodes = @($trig, $gate, $ifOn, $off, $claim, $split, $send, $ok, $failed, $sticky)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Core active?' ) ) }
        'Core active?'                = @{ main = @( ,@( E 'Active?' ) ) }
        'Active?'                     = @{ main = @( @( E 'Find messages' ), @( E 'Inactive' ) ) }
        'Find messages'               = @{ main = @( ,@( E 'Split messages' ) ) }
        'Split messages'              = @{ main = @( ,@( E 'Send' ) ) }
        # main[0] = Erfolg, main[1] = Fehler-Ausgang von continueErrorOutput
        'Send'                        = @{ main = @( @( E 'Finish sent' ), @( E 'Finish failed' ) ) }
    }
    return Build-Workflow 'core.cron_heartbeat_watch' $nodes $conns
}
