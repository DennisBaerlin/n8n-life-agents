#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_save_plan_section (CROSS-AGENT, HITL-Write) -----------------
# Speichert eine Interview-Sektion in den Draft-Plan der Domain (Upsert in
# interview_state; fn legt den Draft bei Bedarf an, den Versionszaehler rechnet die DB).
# domain ist beim aufrufenden Agenten ein fixer Binding-Input (nie $fromAI); jeder Berater
# bindet dasselbe Tool mit seiner domain.
# Playback != Gate: der Agent spielt die Sektion vor diesem Tool-Call als
# normale Chat-Nachricht zurueck und ruft erst nach verbalem OK. Die Karte zeigt den ganzen
# Text, der gespeichert wird (sonst bestaetigt der Nutzer eine andere Fassung als die gespeicherte).
function Build-SavePlanSection {
    $trig = Build-Trigger @('domain', 'section_key', 'topic', 'section_content', 'section_data', 'plan_name', 'handoff_tasks')

    # "DB ist das Gesetz": agent.fn_advisor_save_section laeuft als Probelauf vor der Karte; derselbe Param-Satz geht nach dem
    # Gate in den echten Write. Sonst lehnt die fn erst nach dem Tipp ab, und das LLM schickt eine zweite Karte.
    $wg = New-FnWriteGate -Fn 'agent.fn_advisor_save_section' -DryPos @(220, 0) -WritePos @(1320, 0) `
        -WriteName 'Save section (atomic)' `
        -WriteSelect "(r->>'ok')::boolean AS ok, r->>'reason' AS reason, (r->>'plan_id')::int AS plan_id, (r->>'version')::int AS version, (r->>'draft_created')::boolean AS draft_created, (r->>'section_count')::int AS section_count, (r->'sections')::text AS sections, (r->'topics')::text AS topics, (r->>'topic_replaced')::boolean AS topic_replaced" `
        -Params ([ordered]@{
            domain          = '$(''Start'').item.json.domain'
            section_key     = '$(''Start'').item.json.section_key'
            topic           = '$(''Start'').item.json.topic'   # Thema im Abschnitt (leer = ganzer Abschnitt); Laengen-Gesetz und Ersetzen entscheidet die fn
            section_content = '$(''Start'').item.json.section_content'
            section_data    = '$(''Start'').item.json.section_data'
            plan_name       = '$(''Start'').item.json.plan_name'
            handoff_tasks   = '$(''Start'').item.json.handoff_tasks'   # vereinbarte Eintraege fuer den Buchhalter (JSON-String, leer = keine); Kartenzeilen liefert der Probelauf
            chat_id         = '$(''Start'').item.json.chat_id'   # Person + Permission (fn_check_write_permission; per_user->own_user_only, household->owner_only)
        })

    # Strukturiertes Summary (Textkatalog): Plan- und Abschnittsname aus dem Katalog des Plan-Pakets, der ganze Text ohne Markdown-Zeichen
    # (die Karte ist Klartext; bliebe davon nichts uebrig, zeigt sie den Rohtext statt einer leeren Karte).
    # -RepeatKey: das Modell formuliert den Text je Aufruf neu, gleich bleibt der Abschnitt.
    $S = "`$('Start').item.json"
    $summary = New-HitlSummary -Pos @(660, 0) -Title 'core.hitl.save_plan_section' -LinesExpr $wg.CardLinesExpr `
        -TitleParams @{ plan = (Get-PlanNameValue "$S.domain"); section = (Get-PlanSectionValue "$S.domain" "$S.section_key") } `
        -RepeatKey "String($S.domain || '') + ':' + String($S.section_key || '') + ':' + String($S.topic || '').trim().toLowerCase()" -Lines @(
        (New-HitlLine 'core.label.topic' "String($S.topic || '').replace(/[*_#``]/g, '').trim()" -OmitEmpty)
        (New-HitlLine 'core.label.plan' "$S.plan_name" -If "$S.plan_name")
        (New-HitlBody "(String($S.section_content || '').replace(/[*_#``]/g, '').trim() || String($S.section_content || ''))")
    )

    $reqApproval = Build-CallWorkflow 'Request Approval' @(880, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(1100, 0) '={{ $json.approved }}' 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1320, 200) 'the save_plan_section action'

    $ifOk = Build-If 'Write ok?' @(1540, 0) '={{ $json.ok }}' 'true' 'equals' 'boolean'

    $errWrite = Build-ToolError 'Save rejected' @(1760, 200) "={{ `$('Save section (atomic)').item.json.reason }}"

    $ret = Build-Return @(1760, 0) @(
        ,@('ok','true','boolean')
        ,@('plan_id', '={{ $json.plan_id }}', 'number')
        ,@('version', '={{ $json.version }}', 'number')
        ,@('draft_created', '={{ $json.draft_created }}', 'boolean')
        ,@('section_count', '={{ $json.section_count }}', 'number')
        ,@('sections', '={{ $json.sections }}', 'string')
        ,@('topics', '={{ $json.topics }}', 'string')
        ,@('topic_replaced', '={{ $json.topic_replaced }}', 'boolean')
    )

    $sticky = Build-Sticky 'Doc Save Section' @(120, -300) `
        'HITL + agent.fn_advisor_save_section (atomar)' `
        'Cross-agent (domain = fixer Binding-Input des Aufrufers, nie $fromAI). fn_advisor_save_section: findet/erzeugt den EINEN Draft je (Domain, Person) (Partial-UNIQUE NULLS NOT DISTINCT = DB-Gesetz; version = MAX+1, DB zählt) und upsertet die Sektion in interview_state. THEMEN: mit topic speichert die fn ein Thema im Abschnitt (topics[], gleiche Bezeichnung ohne Groß-/Kleinschreibung ersetzt; Abschnitts-data = Alt-data plus Themen-data, ein Block in zwei Themen -> abgelehnt; ein Alt-Gesamttext wandert beim ersten Thema nach legacy_content, die Karte trägt dann die Notiz „Ersetzt den bisherigen Gesamttext …“). Längen-Gesetz aus core.config <paket>.advisor.topic_max_chars (finance gesetzt, career nicht): ohne topic oder mit zu langem Text lehnt schon der Probelauf ab, keine Karte. P0c PERSON-SCOPE: household (finance) -> person_id NULL; per_user (career, core.context_scopes) -> person_id = Sender (own_user_only) aus chat_id (fn_resolve_sender, NIE LLM); Permission via fn_check_write_permission (owner_only delegiert byte-gleich an fn_sender_is_member). Dry run = dieselbe fn VOR der Karte, immer zurückgerollt (core.fn_dry_run). Korrigierbar (leerer key/content, invalides section_data-JSON, unaufgelöster per_user-Sender) -> {ok:false, reason} -> Dry run rejected: KEINE Karte, reason an den Berater. Leeres section_data zählt als nicht angegeben. Der echte Write prüft erneut, Write ok? reicht reason als Tool-Error. KARTE: erste Zeile „Thema: …“ (entfällt ohne Thema), Titel mit Plan- und Abschnittsname aus dem Textkatalog des Plan-Pakets (<domain>.plan.name, <domain>.plan_section.<section_key>; die E2E-Domain zeigt die Namen des echten Plans, ohne Eintrag der Schlüssel mit Leerzeichen, contract_lint 28), darunter der GANZE Text ohne die Zeichen * _ # und Backtick (Zeilenart body, lange Texte in Teilen, nichts gekürzt). Gespeichert wird der Text wie geliefert, er unterscheidet sich von der Karte nur um diese Zeichen; section_data (die Zahlen der Abschnitte mit Block) steht bewusst nicht auf der Karte. VEREINBARTES (handoff_tasks, nur Domains mit handoff_agent im Manifest): die fn prüft die Einträge im Probelauf, legt sie mit dem Abschnitt an (ersetzt mit Thema die offenen des Themas plus die themenlosen, ohne Thema alle offenen des Abschnitts) und liefert je Eintrag eine Kartenzeile „Danach einzutragen: …“ (card_lines) -> die Abschnitts-Karte ist zugleich die Bestätigung der Vormerkung; eingetragen wird erst über [Durchgehen] mit eigener Karte je Punkt. WIEDERHOL-SPERRE: repeat_key = Domain + Abschnitt + Thema (klein geschrieben), weil das Modell den Text je Aufruf neu formuliert; nach Abbrechen kommt für dasselbe Thema im selben Lauf keine Karte mehr (Gate), Return cancelled sagt dem Modell, dass es antworten soll.' 340 980

    $nodes = @($trig) + $wg.Nodes + @($summary, $reqApproval, $ifApproved, $retCancelled, $ifOk, $errWrite, $ret, $sticky)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Dry run' ) ) }
        'Dry run'                = @{ main = @( ,@( E 'Dry run ok?' ) ) }
        'Dry run ok?'            = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Dry run rejected' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Save section (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Save section (atomic)'  = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Return' ),
            @( E 'Save rejected' )
        ) }
    }
    return Build-Workflow 'agent.tool_save_plan_section' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
