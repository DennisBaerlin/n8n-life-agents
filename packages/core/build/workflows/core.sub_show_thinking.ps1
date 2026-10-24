#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_show_thinking ("Bot denkt nach ..."-Anzeige) -----------------------------------------
# Zeigt im Chat waehrend einer laengeren Agenten-Antwort einen Platzhalter statt Stille: Telegram
# sendMessageDraft mit leerem Text = "Thinking..."-Blase (Bot API 9.5+, nur private Chats). Der Platzhalter
# verschwindet, sobald der Bot eine Nachricht schickt, sonst nach kurzer Zeit (Doku: 30 s; live am Client
# 2026-10-23 nur ~8 s) -> Schleife: alle 5 s agent.fn_claim_thinking_draft fragen (DIE eine Stelle der Logik) und
# erneuern, bis der Aufrufer den Schalter (agent.thinking_lease) vor seiner Antwort loescht ('stop'); offene
# Bestaetigungskarte = 'pause'. Den Schalter legt der Aufrufer VORHER an (Orchestrator, agent.sub_dispatch_agent).
# Aufrufer rufen diesen Sub NUR fire-and-forget (Execute Workflow, waitForSubWorkflow=false, onError=continue):
# die Anzeige darf die Antwort nie verzoegern (Telegram-Socket-Hang, GH #24007) und nie einen Fehler-Alarm
# ausloesen -> Claim und Draft fangen jeden Fehler selbst ab (onError=continueRegularOutput, kein Retry).
function Build-CoreSubShowThinking {
    $start = Build-Trigger @('execution_id') @(-600, 200)
    $claim = Build-Pg 'Claim draft' @(-380, 200) `
        "SELECT agent.fn_claim_thinking_draft(`$1::jsonb) AS r;" `
        ([ordered]@{ execution_id = "String(`$('Start').first().json.execution_id || '')" })
    $claim['onError'] = 'continueRegularOutput'
    # Massgeblich ist expires_at in der DB (eine Pause ueber offener Karte verlaengert ihn, begrenzt durch die Karte).
    # $runIndex zaehlt jeden Besuch (show UND pause) -> nur Notnetz gegen eine endlose Schleife bei einem Fehler in der
    # fn: 2000 Runden = ~2,8 h, weit ueber jedem echten Lauf. DB-Fehler (kein r) / 'stop' / unbekannt -> extra = Ende.
    $state = Build-Switch 'Draft state' @(-160, 200) @(
        @{ Left = "={{ (`$json.r || {}).state === 'show' && `$runIndex < 2000 }}"; Type = 'boolean'; Op = 'equals'; Right = 'true'; OutputKey = 'show' }
        @{ Left = "={{ (`$json.r || {}).state === 'pause' && `$runIndex < 2000 }}"; Type = 'boolean'; Op = 'equals'; Right = 'true'; OutputKey = 'pause' }
    )
    $draft = New-TelegramDraftNode 'Show thinking' @(80, 100) -ChatIdExpr "={{ String(`$('Start').first().json.chat_id || '') }}"
    $wait = Build-WaitSeconds 'Wait' @(300, 200) 5

    $sticky = Build-Sticky 'Doc: Überblick' @(-600, -260) -Header 'Ablauf' `
        'core.sub_show_thinking — "Bot denkt nach ..."' `
        'Telegram sendMessageDraft mit leerem Text = Platzhalter "Thinking..." im Chat (nur private Chats; laut Doku max. 30 s, am Client live nur ~8 s; verschwindet mit der nächsten Bot-Nachricht). Claim draft (agent.fn_claim_thinking_draft) entscheidet je Runde: show = Draft senden, 5 s warten, wieder fragen; pause = offene Bestätigungskarte im Chat, keine Punkte über der Karte, nur warten; stop = Schalter weg (Antwort kommt gleich) bzw. abgelaufen -> Ende. Den Schalter (agent.thinking_lease, je Chat einer) öffnet der Aufrufer (Orchestrator bzw. agent.sub_dispatch_agent) VOR diesem Aufruf und löscht ihn VOR seiner Antwort. IMMER fire-and-forget: die Anzeige verzögert nie die Antwort. Claim und Draft schlucken jeden Fehler (kein Retry, kein Alarm) — rein kosmetisch. Erfolgreiche Läufe werden nicht gespeichert (saveDataSuccessExecution none), Fehler schon.' 440 460
    $stickyRace = Build-Sticky 'Doc: Wettlauf' @(60, -260) -Header 'Achtung' `
        'Kein Draft nach Antwort oder Karte' `
        'Zwischen Claim draft und dem Draft-Send liegen ~100-300 ms. Käme dazwischen die Antwort oder eine Karte, landete der Draft danach ("Thinking..." unter der Antwort bzw. über der Karte). Daher sperrt der Claim seine Schalter-Zeile und setzt bei show ein 1-s-Fenster (drafting_until); das Löschen vor der Antwort (fn_delete_thinking_lease, wait_for_draft) und das Öffnen einer Karte (fn_create_hitl_pending) warten es ab. Restlücke: ein Telegram-Aufruf über 1 s. Eingaben in der Schleife immer über $(''Start'').first() lesen (Item-Pairing über die Rückkante ist fragil).' 440 300

    $nodes = @($start, $claim, $state, $draft, $wait, $sticky, $stickyRace)
    $conns = [ordered]@{
        'Start'         = @{ main = @( ,@( E 'Claim draft' ) ) }
        'Claim draft'   = @{ main = @( ,@( E 'Draft state' ) ) }
        'Draft state'   = @{ main = @(
            @( E 'Show thinking' ),   # [0] show  -> Draft, dann warten
            @( E 'Wait' ),            # [1] pause -> nur warten (offene Karte)
            @()                       # [2] extra -> stop / DB-Fehler / Notnetz -> Ende
        ) }
        'Show thinking' = @{ main = @( ,@( E 'Wait' ) ) }
        'Wait'          = @{ main = @( ,@( E 'Claim draft' ) ) }
    }
    $wf = Build-Workflow 'core.sub_show_thinking' $nodes $conns
    # Rein kosmetischer Dauerlaeufer (je Nachricht eine Execution, ~4 Node-Laeufe alle 5 s): erfolgreiche Laeufe nicht
    # speichern -> kein Wachstum der execution_data zwischen zwei Pruning-Laeufen. Fehler bleiben sichtbar.
    $wf.settings['saveDataSuccessExecution'] = 'none'
    return $wf
}
