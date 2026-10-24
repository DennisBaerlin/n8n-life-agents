#Requires -Version 5.1
# Geteilter Bau-Helfer der generischen Core-Advisor-Engine-Crons (WS2). Dot-gesourct von build.ps1.
# Die ZWEI Crons (agent.advisor.cron_drift_check + agent.advisor.cron_review) teilen denselben Schwanz:
#   F9-Gate -> iterate core.advisors via core.fn_advisor_review_evaluate -> Build message (Code, det.)
#   -> Anything to report? -> Phrase (model.advisor_review, onError continue) -> Choose text -> Telegram.
# Faktorisiert (wie New-TelegramSendNode), damit die zwei Cron-Builder NICHT driften; der Phrasing-Schwanz
# (Load model config + Phrase + Umschalter + Choose text) ist seit Festwert-Phase 2 der geteilte
# New-AdvisorPhrasingTail (lib/build_helpers.ps1), den auch der estate-Jahres-Review nutzt.
# Unterschied der beiden Crons = NUR (a) Cadence/Enable-Key, (b) die Evaluate-Query, (c) die Build-JS,
# (d) der Send-Node-Name. Alles andere identisch.
#
# GENERIK: der Cron kennt KEINE finance-Felder — er rendert die paket-gelieferte Struktur (alert.msg / digest.lines,
#   Textkatalog Phase C) mit dem geteilten Renderer in Owner-Sprache, das LLM formuliert in dieser Sprache um. Ein 2. Advisor
#   (Career-Advisor) fliesst ohne Cron-Aenderung durch (Registry-Iteration).
# ROLLE: laeuft unter dem Haupt-RW-Credential (Build-Pg-Default = WRITE) — die Evaluate-fn SCHREIBT
#   Latch-State (Praezedenz cron_monitor_check_triggers; die SQL ist entwickler-geschrieben + deterministisch,
#   kein LLM-formuliertes SELECT -> kein core_ro/DEFINER-Fenster noetig).
# P2b-2 Per-Person-Faecherung: geteilter CTE-Kopf BEIDER Advisor-Crons (drift_check + review). Faechert
# core.advisors generisch ueber die Personen: per_user-Domains (career, scope='per_user' in core.context_scopes)
# ueber agent.fn_context_persons(plan_context) je Person; household-Domains (finance) mit person_id=NULL
# (byte-gleich heute -> v_source 'advisor:'||domain, kein Suffix). Die VOLATILE Eval-fn faecherte sonst nur
# am Owner (1-arg). Nur die ev-Projektion DANACH unterscheidet die beiden Crons (alerts vs. digest) -> der
# Kopf lebt hier EINMAL (DRY), beide Crons prefixen ihn. Edge: per_user-Domain mit 0 Plaenen -> 0 pids-Zeilen
# -> die Domain wird nicht evaluiert (verhaltens-korrekt: kein Plan = kein Alert); ein verwaister Person-Latch
# beim Plan-Loeschen wird im Person-Purge (fn_remove_household_person) geraeumt.
# Roter Faden: Domaenen mit EIGENEM Review-Cron (core.advisors.own_review_cron, estate) laufen hier NICHT mit —
# sonst latchte der geteilte Drift-Waechter ihre Alerts unter falschem Rahmen und der eigene Cron fand den Latch leer.
# person_name (Vorname; NULL bei household) liefert die EINE Stelle fuer beide Crons (Person im Alert/Digest nennen).
function Get-AdvisorFanoutCte {
    @'
adv AS (
  SELECT a.domain, a.plan_context, COALESCE(cs.scope, 'household') AS scope
  FROM core.advisors a
  LEFT JOIN core.context_scopes cs ON cs.context_name = a.plan_context
  WHERE NOT a.own_review_cron
),
pids AS (
  SELECT a.domain, p.person_id,
         (SELECT split_part(ap.full_name, ' ', 1) FROM agent.persons ap WHERE ap.person_id = p.person_id) AS person_name
  FROM adv a
  CROSS JOIN LATERAL (
    SELECT person_id FROM agent.fn_context_persons(a.plan_context) WHERE a.scope = 'per_user'
    UNION ALL
    SELECT NULL::text WHERE a.scope <> 'per_user'
  ) p
)
'@
}

# Geteilter Rahmen der Berater-Crons (Fusszeile, Abschalten-Knopf, Prompt-Label der Sprache) — EINE Adresse fuer
# drift_check + review. Keys fuer die Eval-Query ($AdvisorChromeKeys); das JS setzt im Build-Code U (uiRender) und
# ui (Text-Buendel aus core.fn_ui_texts_for) voraus und definiert `chrome`.
$script:AdvisorChromeKeys = @('core.advisor.footer_off', 'core.advisor.btn_off')
function Get-AdvisorChromeJs {
    "const chrome = { footer: U.t('core.advisor.footer_off'), btn_off: U.t('core.advisor.btn_off'),`n" +
    "  language_label: ui.language_label || 'en' };`n"
}

function New-AdvisorCron {
    param(
        [Parameter(Mandatory)][string]$WorkflowName,    # agent.advisor.cron_drift_check
        [Parameter(Mandatory)][string]$ScheduleKey,     # core schedule.<key>  (drift_check | plan_review)
        [Parameter(Mandatory)][string]$CronEnableKey,   # core cron_enable.<key> (drift_check | plan_review)
        [Parameter(Mandatory)][string]$EvalSql,         # Pg-Query: EINE Zeile, jsonb-Spalte als Build-Input
        [Parameter(Mandatory)][string]$BuildJs,         # Code-JS: return [{ json: { det_text, report:bool, language_label, footer, btn_off } }]
        [Parameter(Mandatory)][string]$SendNodeName,    # 'Send drift' | 'Send review'
        [Parameter(Mandatory)][string]$StickyBody       # Ueberblicks-Sticky-Text (cron-spezifisch)
    )
    $trig = Build-ScheduleTrigger @(-1100, 0) -ScheduleKey $ScheduleKey

    # F9 Cron-Gating (WS-1/Phase 4a): nur wenn Paket aktiv UND cron_enable -> sonst No-op (fail-closed).
    # DB entscheidet. Toggle: lifeagents config set cron_enable <key> true (kein Rebuild).
    $gate = Build-Pg 'Cron enabled?' @(-880, 0) `
        "=SELECT core.fn_package_active('core') AND COALESCE(core.fn_config_get('core','cron_enable','$CronEnableKey') = 'true', false) AS enabled" `
        $null
    $ifEnabled = Build-If 'Cron on?' @(-660, 0) '={{ $json.enabled }}' 'true' 'equals' 'boolean'
    $off = Build-NoOp 'Disabled' @(-440, 200)

    # Generischer Eval-Pass: iteriert core.advisors, ruft je Domain core.fn_advisor_review_evaluate
    # (Registry-Dispatch + Latch). MATERIALIZED CTE -> die VOLATILE Eval-fn laeuft EXAKT 1x je Advisor.
    $evaluate = Build-Pg 'Evaluate advisors' @(-440, 0) $EvalSql $null

    # Deterministischer Message-Text (Fallback + LLM-Input) — Code, kein LLM. report=false -> Quiet run.
    $build = [ordered]@{
        parameters = [ordered]@{ jsCode = $BuildJs }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(-220, 0)
        id = (New-Id); name = 'Build message'
    }

    # Stiller Lauf (drift: keine neuen Breaches) -> keine Message.
    $ifReport = Build-If 'Anything to report?' @(0, 0) '={{ $json.report }}' 'true' 'equals' 'boolean'
    $quiet = Build-NoOp 'Quiet run' @(180, 200)

    # LLM formuliert NUR um (Zahlen unveraendert); Fehler -> deterministischer Text (Choose text). Geteilter Schwanz
    # (lib/build_helpers.ps1): Load model config (model.advisor_review bei JEDEM Lauf, Denk-Tiefe niedrig) + Phrase +
    # Umschalter + Choose text. Load model config sitzt VOR Evaluate (Latch-Write erst nach erfolgreichem Laden).
    $tail = New-AdvisorPhrasingTail -ConfigPackage 'core' -ConfigKey 'advisor_review' -Effort low `
        -PromptLead 'Rewrite the following periodic advisor check-in as a short, friendly Telegram message, written in the language {language}. PLAIN TEXT only (no markdown, no asterisks). Keep EVERY number, amount and date EXACTLY as written (do not reformat them) and keep every warning or hint sentence. Maximum 16 lines. Text:\n\n'

    # Escape an (Helper-Default): der Phrase-Prompt erzwingt PLAIN TEXT, aber Modell-Output ist keine
    # Garantie — ein ungepaartes _/*/[ haette den Send gecrasht ("can't parse entities").
    # WS-3 Phase A: Inline-Button "Abschalten" (callback_data cron_off:<ScheduleKey>) -> der Owner schaltet
    # diesen Waechter-Cron mit einem Tipp ab (Orchestrator-Callback -> core.fn_set_cron_enable). Fusszeile
    # nennt das. Re-Aktivieren per /reminders (Roter Faden Paket B). Reitet nur auf echten
    # Nudges mit (Send feuert nur bei report=true). ScheduleKey = drift_check|plan_review (whitelisted).
    $send = New-TelegramInlineKeyboardSendNode $SendNodeName @(620, 0) `
        "={{ `$json.message + '\n\n' + `$('Build message').first().json.footer }}" `
        @( @{ Text = "={{ `$('Build message').first().json.btn_off }}"; Data = "cron_off:$ScheduleKey" } )

    $stickyOverview = Build-Sticky 'Überblick' @(-1140, -360) `
        'Generische Core-Advisor-Engine (Latch entscheidet DB, LLM nur Phrasing)' `
        ($StickyBody + " WS-3 Phase A: der Send trägt einen Abschalten-Inline-Button (callback_data cron_off:$ScheduleKey) -> der Owner schaltet diesen Wächter-Cron per Tipp ab (Orchestrator-Callback -> core.fn_set_cron_enable, core.config cron_enable); Re-Aktivieren per /reminders (Roter Faden Paket B).") 340 760

    $stickyEval = Build-Sticky 'Doc Engine' @(-480, -360) `
        'core.fn_advisor_review_evaluate (Registry-Dispatch + Latch, off-canvas)' `
        ('Evaluate advisors FÄCHERT core.advisors x Personen (P2b-2 Get-AdvisorFanoutCte: per_user-Domains wie career je Person via agent.fn_context_persons(plan_context), household-Domains wie finance mit person_id=NULL) und ruft je (Domain, Person) core.fn_advisor_review_evaluate(domain, person_id) (MATERIALIZED CTE -> die VOLATILE Eval-fn läuft EXAKT 1x je (Advisor, Person)). Der Core-Wrapper: Registry-Lookup domain->review_fn (z. B. finance.fn_advisor_review), dyn. EXECUTE, dann LATCH gegen die geteilte core.notification_state (source=advisor:domain[:person_id]) über core.fn_should_notify/fn_notify_reconcile (Erst-/Re-Breach -> send=true; bereits fired -> still; wieder im Band -> Re-Arm via Reconcile-GC räumt stale metric_keys; person_id=NULL byte-gleich heute). Läuft unter dem Haupt-RW-Credential (Build-Pg-Default) — die fn SCHREIBT Latch-State (Präzedenz cron_monitor_check_triggers). GENERIK: der Cron kennt keine Paket-Felder, er rendert die paket-gelieferte Struktur (alert.msg / digest.lines) in Owner-Sprache, die Texte kommen aus derselben Anweisung wie der Latch (core.fn_ui_texts_for); model.advisor_review formuliert in dieser Sprache um (jede Zahl wörtlich) (Load model config liest es bei JEDEM Lauf VOR Evaluate -> ein Ladefehler stoppt den Lauf, bevor ein Latch geschrieben ist; Umschalter mit einem Knoten je Claude-Modell), onError continue -> Fallback = der deterministische Text (Choose text). Build message setzt report=false -> Quiet run (keine Message).') 360 700

    $nodes = @($trig, $gate, $ifEnabled, $off, $tail.LoadNode, $evaluate, $build, $ifReport, $quiet) +
             @($tail.Nodes) + @($send, $stickyOverview, $stickyEval)
    $conns = [ordered]@{
        'Schedule (cron from config)' = @{ main = @( ,@( E 'Cron enabled?' ) ) }
        'Cron enabled?'               = @{ main = @( ,@( E 'Cron on?' ) ) }
        'Cron on?'                    = @{ main = @(
            @( E 'Load model config' ),
            @( E 'Disabled' )
        ) }
        'Load model config'           = @{ main = @( ,@( E 'Evaluate advisors' ) ) }
        'Evaluate advisors'           = @{ main = @( ,@( E 'Build message' ) ) }
        'Build message'               = @{ main = @( ,@( E 'Anything to report?' ) ) }
        'Anything to report?'         = @{ main = @(
            @( E 'Phrase message' ),
            @( E 'Quiet run' )
        ) }
        'Choose text'                 = @{ main = @( ,@( E $SendNodeName ) ) }
    }
    foreach ($k in $tail.Connections.Keys) { $conns[$k] = $tail.Connections[$k] }
    return Build-Workflow $WorkflowName $nodes $conns
}
