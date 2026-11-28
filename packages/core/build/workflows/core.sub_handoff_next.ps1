#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_handoff_next (vereinbarte Eintraege: der naechste kommt von selbst) ------------------------------------
# Der Buchhalter erledigt je Lauf genau einen vereinbarten Eintrag (eigene Karte) und endet. Der Orchestrator ruft diesen Sub
# nach dem ersten Lauf ([Jetzt eintragen]); er startet die naechsten Laeufe ohne Nutzer-Nachricht, bis nichts mehr offen ist
# oder eine Antwort mit einer Frage endet. Eigener Sub statt Kreis im Orchestrator: der groesste Workflow waechst nicht.
# Eingaben (JSON-Text bzw. Text): chat_id, task_ids, tasks (Liste des ersten Laufs), last_output (dessen Antwort),
# task_prefix/task_suffix (fester Auftrag des Orchestrators um die Liste), workflow_id/package/thinking/audience/empty_ok
# (Eingaben des Vermittlers agent.sub_dispatch_agent). Ausgang { output } = die zuletzt gesendete Antwort.
function Build-CoreSubHandoffNext {
    $trig = Build-Trigger @('task_ids', 'tasks', 'last_output', 'task_prefix', 'task_suffix', 'workflow_id', 'package', 'thinking', 'audience', 'empty_ok') @(-1100, 0)
    $S = "`$('Start').first().json"

    $state = Build-Pg 'Handoff state' @(-880, 0) `
        "=SELECT core.fn_handoff_tasks_read(ARRAY(SELECT jsonb_array_elements_text(COALESCE((`$1::jsonb)->'ids', '[]'::jsonb))::int)) AS r;" `
        ([ordered]@{ ids = "(() => { try { return JSON.parse($S.task_ids || '[]'); } catch (e) { return []; } })()" }) -ContinueOnError
    $state['alwaysOutputData'] = $true

    # Rest = Liste des letzten Laufs ohne ihren ersten Eintrag (der war dran, auch wenn seine Karte abgebrochen wurde), davon nur
    # die noch working sind. Kreis-Ausdruecke lesen den juengsten Lauf eines Knotens; beim ersten Durchlauf gibt es Run next
    # noch nicht, darum die Liste und Antwort aus Start.
    $nextJs = @"
const parse = (s, d) => { try { return typeof s === 'string' ? JSON.parse(s || 'null') ?? d : (s ?? d); } catch (e) { return d; } };
const rows = parse(`$('Handoff state').first().json.r, []);
const status = new Map((Array.isArray(rows) ? rows : []).map((t) => [Number(t.id), String(t.status || '')]));
const looped = `$('Run next').isExecuted;
const prev = looped ? (`$('Handoff next').first().json.tasks || []) : parse($S.tasks, []);
// Frage-Test auf dem Text ohne Markerzeilen (wie Reply text), sonst versteckte eine angehaengte Markerzeile die Frage.
const out = String((looped ? `$('Run next').first().json.output : $S.last_output) || '').split('\n').filter((l) => !/$($script:NextStepMarkerPattern)/.test(l) && !/$($script:ChoicesMarkerPattern)/.test(l) && !/^\s*HANDOVER\s*`$/i.test(l)).join('\n').trim();
const question = /[?？]\s*`$/.test(out);
const list = Array.isArray(prev) ? prev : [];
const tasks = list.slice(1).filter((t) => status.get(Number(t && t.id)) === 'working');
// Freigabe am Ende: alles noch working; nach einer Frage bleibt nur der fragende Eintrag (der erste der Liste) beansprucht.
const current = list.length ? Number(list[0] && list[0].id) : null;
const release_ids = Array.from(status).filter(([, st]) => st === 'working').map(([id]) => id).filter((id) => !(question && id === current));
return [{ json: { more: tasks.length > 0 && out !== '' && !question, tasks, release_ids } }];
"@
    $next = [ordered]@{ parameters = [ordered]@{ jsCode = $nextJs }; type = 'n8n-nodes-base.code'; typeVersion = 2
                        position = @(-660, 0); id = (New-Id); name = 'Handoff next' }
    $more = Build-If 'More?' @(-440, 0) "={{ `$json.more === true }}" 'true' 'equals' 'boolean'

    $run = Build-CallWorkflow 'Run next' @(-220, -160) (Get-RequiredWorkflowId 'agent.sub_dispatch_agent' -Caller 'Build-CoreSubHandoffNext') 'agent.sub_dispatch_agent' ([ordered]@{
        task        = "={{ String($S.task_prefix || '') + JSON.stringify(`$('Handoff next').first().json.tasks || []) + String($S.task_suffix || '') }}"
        chat_id     = "={{ String($S.chat_id || '') }}"
        call_depth  = '1'
        workflow_id = "={{ String($S.workflow_id || '') }}"
        package     = "={{ String($S.package || '') }}"
        thinking    = "={{ String($S.thinking || '') }}"
        audience    = "={{ String($S.audience || '') }}"
        empty_ok    = "={{ String($S.empty_ok || '') }}"
    })
    $run['onError'] = 'continueErrorOutput'   # main[1] = Fehler -> Claims freigeben
    # Ein eigener Sende-Knoten statt New-TelegramRelayChain: deren splitInBatches startet im Kreis nicht neu. Die Regeln halten
    # die Antworten in diesem Modus kurz (eine Nachricht); Markerzeilen werden wie in der Relay-Kette entfernt.
    $text = [ordered]@{ parameters = [ordered]@{ jsCode = "return [{ json: { text: String(`$('Run next').first().json.output || '').split('\n').filter((l) => !/$($script:NextStepMarkerPattern)/.test(l) && !/$($script:ChoicesMarkerPattern)/.test(l) && !/^\s*HANDOVER\s*`$/i.test(l)).join('\n').trim() } }];" }
                        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(0, -160); id = (New-Id); name = 'Reply text' }
    $send = New-TelegramSendNode 'Send reply' @(220, -160) "={{ `$json.text }}" -ChatIdExpr "={{ String($S.chat_id || '') }}" -OnError 'continueRegularOutput'

    # Ende: was noch working ist (abgebrochene Karte), wird wieder offen und steht auf der Liste; niemand arbeitet mehr daran.
    # Nach einer Frage bleibt nur der fragende Eintrag beansprucht (die Antwort geht ueber die Folge-Bindung an den Buchhalter).
    # Lauf-Fehler (Fehler-Ausgang von Run next) -> alle beanspruchten frei.
    $release = Build-Pg 'Release open' @(0, 160) 'SELECT core.fn_release_handoff_tasks($1::jsonb) AS r;' `
        ([ordered]@{ task_ids = "((`$('Run next').isExecuted && (`$('Run next').first().json || {}).error) ? (() => { try { return JSON.parse($S.task_ids || '[]'); } catch (e) { return []; } })() : (`$('Handoff next').first().json.release_ids || []))" }) -ContinueOnError
    $release['executeOnce'] = $true
    # output wie ein Agent-Lauf: der Orchestrator bindet die Folge-Antwort an die zuletzt gesehene Antwort (Add-FollowupSet).
    $result = Build-Set 'Result' @(440, 160) @( ,@('output', "={{ `$('Run next').isExecuted ? String(`$('Run next').first().json.output || '') : String($S.last_output || '') }}", 'string') )
    $result['executeOnce'] = $true

    $sticky = Build-Sticky 'Überblick' @(-1140, -440) -Header 'Ablauf' 'Vereinbarte Einträge: der nächste kommt von selbst' `
        ('Gerufen vom Orchestrator nach dem ersten Buchhalter-Lauf von [Jetzt eintragen] (Run handoff chain <domain>). Der Buchhalter erledigt je Lauf genau einen Eintrag mit eigener Karte und endet. ' +
         'Handoff state (core.fn_handoff_tasks_read der beanspruchten ids) -> Handoff next: Rest = Liste des letzten Laufs ohne ihren ersten Eintrag, nur noch working; endet die Antwort mit einer Frage (der Buchhalter braucht einen Rohwert), ist Schluss. ' +
         'More? -> Run next (agent.sub_dispatch_agent, derselbe feste Auftrag mit dem Rest) -> Reply text -> Send reply -> zurück zu Handoff state. Die Liste schrumpft je Runde, eine Endlosschleife gibt es nicht. ' +
         'Send reply statt der Relay-Kette: deren Schleifen-Knoten (splitInBatches) startet im Kreis nicht neu. ' +
         'Ende -> Release open (core.fn_release_handoff_tasks): was noch working ist (abgebrochene Karte), ist wieder offen und steht auf der Liste; nach einer Frage bleibt nur der fragende Eintrag beansprucht, nach einem Lauf-Fehler wird alles frei; eingetragene bleiben done. Result.output = zuletzt gesendete Antwort (Folge-Bindung im Orchestrator).') 420 520

    $nodes = @($trig, $state, $next, $more, $run, $text, $send, $release, $result, $sticky)
    $conns = [ordered]@{
        'Start'         = @{ main = @( ,@( E 'Handoff state' ) ) }
        'Handoff state' = @{ main = @( ,@( E 'Handoff next' ) ) }
        'Handoff next'  = @{ main = @( ,@( E 'More?' ) ) }
        'More?'         = @{ main = @( @( E 'Run next' ), @( E 'Release open' ) ) }
        'Run next'      = @{ main = @( @( E 'Reply text' ), @( E 'Release open' ) ) }
        'Reply text'    = @{ main = @( ,@( E 'Send reply' ) ) }
        'Send reply'    = @{ main = @( ,@( E 'Handoff state' ) ) }
        'Release open'  = @{ main = @( ,@( E 'Result' ) ) }
    }
    return Build-Workflow 'core.sub_handoff_next' $nodes $conns
}
