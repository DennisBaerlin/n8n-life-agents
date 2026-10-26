#Requires -Version 5.1
# Engine-Teil der Test-Harness-Aggregation (Toolchain, dot-gesourct von build.ps1 VOR allen Paketen).
# Die Registry $script:Harnesses wird hier LEER initialisiert; JEDES Paket steuert seine Eintraege in
# packages/<pkg>/build/workflows/harnesses.ps1 per `$script:Harnesses += @(...)` bei. Init in der Engine ->
# Paket-Lade-Reihenfolge ist irrelevant (kein "core muss zuerst"-Zwang). Build-Harness + Get-HarnessWorkflow
# sind generisch/paket-agnostisch. Nutzt $WorkflowsDir/Get-WorkflowIdByName/New-Id/E aus dem build.ps1-Scope.
# Harnesses sind Test-Eingaenge: KEIN errorWorkflow (laufen manuell), daher NICHT Build-Workflow. Die
# Header-Auth-Credential referenziert ein lesbarer Platzhalter (__CRED_HARNESS__); inject_credentials legt
# sie aus TEST_HARNESS_SECRET an + remappt den Platzhalter.

$script:Harnesses = @()

function Build-Harness {
    param($H)
    $cred    = $CRED_HARNESS   # Host-Deskriptor (build.ps1-Host-Block)
    $target  = Get-RequiredWorkflowId $H.targetName "Harness '$($H.name)'"
    $runName = "Run $($H.targetName)"

    # responseMode=lastNode: der POST blockiert bis zum Ende des Laufs und liefert die 'Run Info'
    # (harness_execution_id) zurueck als Sync-Punkt; die Harness-Skripte korrelieren danach ueber die
    # monotone Exec-id (Get-MaxExecId vor dem Feuern) -- Weg C/Phase 8, da die am HITL-Gate suspendierte
    # Execution keine subExecution-Metadata mehr liefert.
    $webhook = [ordered]@{
        parameters = [ordered]@{
            httpMethod = 'POST'; path = $H.path; authentication = 'headerAuth'; responseMode = 'lastNode'; options = @{}
        }
        type = 'n8n-nodes-base.webhook'; typeVersion = 2; position = @(0, 0); id = (New-Id); name = 'Test Webhook'
        webhookId = (New-Id); credentials = @{ httpHeaderAuth = $cred }
    }

    $inputValue = [ordered]@{}
    if ($null -ne $H.inputMap) {
        foreach ($key in $H.inputMap.Keys) { $inputValue[$key] = "={{ `$('Test Webhook').item.json.$($H.inputMap[$key]) }}" }
    } else {
        $inputValue['task']       = "={{ `$('Test Webhook').item.json.body.task }}"
        $inputValue['chat_id']    = "={{ `$('Test Webhook').item.json.body.chat_id }}"
        $inputValue['call_depth'] = "={{ `$('Test Webhook').item.json.body.call_depth }}"
    }
    $run = [ordered]@{
        parameters = [ordered]@{
            workflowId = [ordered]@{ __rl = $true; value = $target; mode = 'list'; cachedResultUrl = "/workflow/$target"; cachedResultName = $H.targetName }
            workflowInputs = [ordered]@{
                mappingMode = 'defineBelow'; value = $inputValue
                matchingColumns = @(); schema = @(); attemptToConvertTypes = $false; convertFieldsToString = $true
            }
            options = @{}
        }
        type = 'n8n-nodes-base.executeWorkflow'; typeVersion = 1.2; position = @(280, 0); id = (New-Id); name = $runName
        # Ziel-Fehler nicht zum Harness-Fehler machen: Run Info antwortet trotzdem (die Skripte
        # lesen den Ziel-Status aus der Ziel-Execution selbst).
        onError = 'continueRegularOutput'
    }

    # Letzter Node = Webhook-Response (responseMode=lastNode): liefert die eigene Execution-ID des
    # Harness zurueck als Sync-Punkt; korreliert wird ueber die monotone Exec-id (Get-MaxExecId; Weg C).
    $runInfo = [ordered]@{
        parameters = [ordered]@{
            jsCode = 'return { json: { harness_execution_id: $execution.id } };'
            mode   = 'runOnceForEachItem'
        }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(560, 0); id = (New-Id); name = 'Run Info'
    }

    $bodyDesc = if ($null -eq $H.inputMap) { 'task, chat_id, call_depth' } `
                elseif ($H.inputMap.Count -eq 0) { '(passthrough)' } `
                else { ($H.inputMap.Keys -join ', ') }
    $gateNote = if ($null -eq $H.inputMap) { "`nnumerische chat_id (per Get-TestChatId) + Gate-Resolve ueber Mock-Telegram; kein test_-Bypass mehr." } else { '' }
    $sticky = [ordered]@{
        parameters = [ordered]@{
            content = @"
## $($H.name)
**Test-Eingang.** Kein Produktiv-Workflow.

Webhook (POST, Header-Auth, responseMode=lastNode) -> Execute Workflow ruft $($H.targetName)
ueber dessen executeWorkflowTrigger auf -> Run Info antwortet mit der Harness-Execution-ID
(Skripte korrelieren darueber deterministisch zur Sub-Execution). Body: $bodyDesc.$gateNote
Bei Nichtbenutzung deaktivieren (Webhook-Pfad dann nicht registriert).
"@
            height = 250; width = 480; color = 7
        }
        type = 'n8n-nodes-base.stickyNote'; typeVersion = 1; position = @(-40, -260); id = (New-Id); name = 'Doc Overview'
    }

    $nodes = @($webhook, $run, $runInfo, $sticky)
    $conns = [ordered]@{
        'Test Webhook' = @{ main = @( ,@( E $runName ) ) }
        $runName       = @{ main = @( ,@( E 'Run Info' ) ) }
    }
    # KEIN errorWorkflow (Test-Harness) -> eigenes settings, nicht Build-Workflow.
    return [ordered]@{ name = $H.name; nodes = $nodes; connections = $conns; settings = [ordered]@{ executionOrder = 'v1' } }
}

# Generischer Cron-Test-Eingang (2026-10-26, schnellere freie Gates): startet den Workflow mit der workflow_id aus dem
# Body ueber dessen 'Test run'-Einstieg (Build-Workflow ergaenzt ihn an jedem Cron). cron_text_test wartet damit nicht
# mehr auf die volle Minute eines umgestellten Zeitplans (vorher je Fall 2 Redeploys + bis zu 60 s Warten).
function Build-CronRunHarness {
    $webhook = [ordered]@{
        parameters = [ordered]@{
            httpMethod = 'POST'; path = 'cron-run-test'; authentication = 'headerAuth'; responseMode = 'lastNode'; options = @{}
        }
        type = 'n8n-nodes-base.webhook'; typeVersion = 2; position = @(0, 0); id = (New-Id); name = 'Test Webhook'
        webhookId = (New-Id); credentials = @{ httpHeaderAuth = $CRED_HARNESS }
    }
    $run = [ordered]@{
        parameters = [ordered]@{
            workflowId = [ordered]@{ __rl = $true; value = "={{ `$('Test Webhook').item.json.body.workflow_id }}"; mode = 'id' }
            workflowInputs = [ordered]@{
                mappingMode = 'defineBelow'; value = [ordered]@{}
                matchingColumns = @(); schema = @(); attemptToConvertTypes = $false; convertFieldsToString = $true
            }
            # nicht auf den Cron warten: ein Cron mit Bestaetigungs-Frage (sendAndWait) hielte den POST sonst bis zum Tipp
            # fest; cron_text_test verfolgt die Ziel-Execution selbst (monotone Exec-id).
            options = [ordered]@{ waitForSubWorkflow = $false }
        }
        type = 'n8n-nodes-base.executeWorkflow'; typeVersion = 1.2; position = @(280, 0); id = (New-Id); name = 'Run cron'
        onError = 'continueRegularOutput'   # Ziel-Fehler liest das Skript aus der Ziel-Execution selbst
    }
    $runInfo = [ordered]@{
        parameters = [ordered]@{ jsCode = 'return { json: { harness_execution_id: $execution.id } };'; mode = 'runOnceForEachItem' }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(560, 0); id = (New-Id); name = 'Run Info'
    }
    $sticky = [ordered]@{
        parameters = [ordered]@{
            content = @"
## core.cron_run.test_harness
**Test-Eingang.** Kein Produktiv-Workflow (nur Test-Instanzen).

Webhook (POST, Header-Auth, responseMode=lastNode) mit Body {workflow_id} -> Execute Workflow startet diesen Cron ueber
seinen 'Test run'-Einstieg (passthrough, Build-Workflow) -> Run Info antwortet mit der Harness-Execution-ID. Ersetzt in
cron_text_test das Umstellen des Zeitplans auf jede Minute (2 Redeploys + Warten je Fall).
"@
            height = 250; width = 480; color = 7
        }
        type = 'n8n-nodes-base.stickyNote'; typeVersion = 1; position = @(-40, -260); id = (New-Id); name = 'Doc Overview'
    }
    $conns = [ordered]@{
        'Test Webhook' = @{ main = @( ,@( E 'Run cron' ) ) }
        'Run cron'     = @{ main = @( ,@( E 'Run Info' ) ) }
    }
    return [ordered]@{ name = 'core.cron_run.test_harness'; nodes = @($webhook, $run, $runInfo, $sticky); connections = $conns
                       settings = [ordered]@{ executionOrder = 'v1' } }
}

# Liefert alle Harness-Workflow-Objekte (ohne id) als Array -- die Union aller Paket-Beitraege.
function Get-HarnessWorkflow {
    foreach ($H in $script:Harnesses) { Build-Harness $H }
    Build-CronRunHarness
}
