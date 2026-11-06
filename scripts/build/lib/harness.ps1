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
    # Ziel fest (targetName, beim Build aufgeloest) oder dynamisch (targetIdField: workflow_id aus dem Body, Modus id).
    $dynamic = [bool]$H.targetIdField
    $target  = if ($dynamic) { $null } else { Get-RequiredWorkflowId $H.targetName "Harness '$($H.name)'" }
    $runName = if ($dynamic) { 'Run target' } else { "Run $($H.targetName)" }
    $runRl   = if ($dynamic) { [ordered]@{ __rl = $true; value = "={{ `$('Test Webhook').item.json.$($H.targetIdField) }}"; mode = 'id' } } `
               else { [ordered]@{ __rl = $true; value = $target; mode = 'list'; cachedResultUrl = "/workflow/$target"; cachedResultName = $H.targetName } }
    # noWait: nicht auf das Ziel warten (z. B. ein Cron mit Bestaetigungs-Frage hielte den POST sonst bis zum Tipp fest);
    # das Skript verfolgt die Ziel-Execution selbst (monotone Exec-id).
    $runOpts = if ($H.noWait) { [ordered]@{ waitForSubWorkflow = $false } } else { @{} }

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
            workflowId = $runRl
            workflowInputs = [ordered]@{
                mappingMode = 'defineBelow'; value = $inputValue
                matchingColumns = @(); schema = @(); attemptToConvertTypes = $false; convertFieldsToString = $true
            }
            options = $runOpts
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
            # noWait: Startfehler des Ziels (kein Einstieg, unbekannte id) mitliefern, sonst schluckt onError ihn still.
            jsCode = if ($H.noWait) { 'return { json: { harness_execution_id: $execution.id, error: $json.error ?? null } };' } `
                     else { 'return { json: { harness_execution_id: $execution.id } };' }
            mode   = 'runOnceForEachItem'
        }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(560, 0); id = (New-Id); name = 'Run Info'
    }

    $bodyDesc = if ($null -eq $H.inputMap) { 'task, chat_id, call_depth' } `
                elseif ($dynamic) { ($H.targetIdField -replace '^body.', '') } `
                elseif ($H.inputMap.Count -eq 0) { '(passthrough)' } `
                else { ($H.inputMap.Keys -join ', ') }
    $targetDesc = if ($dynamic) { "den Workflow mit der id aus $($H.targetIdField)" } else { $H.targetName }
    $waitNote = if ($H.noWait) { "`nwaitForSubWorkflow=false: antwortet sofort nach dem Start; das Skript verfolgt die Ziel-Execution." } else { '' }
    $gateNote = if ($null -eq $H.inputMap) { "`nnumerische chat_id (per Get-TestChatId) + Gate-Resolve ueber Mock-Telegram; kein test_-Bypass mehr." } else { '' }
    $sticky = [ordered]@{
        parameters = [ordered]@{
            content = @"
## $($H.name)
**Test-Eingang.** Kein Produktiv-Workflow.

Webhook (POST, Header-Auth, responseMode=lastNode) -> Execute Workflow ruft $($targetDesc)
ueber dessen executeWorkflowTrigger auf -> Run Info antwortet mit der Harness-Execution-ID
(Skripte korrelieren darueber deterministisch zur Sub-Execution). Body: $bodyDesc.$gateNote$waitNote
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


# Liefert alle Harness-Workflow-Objekte (ohne id) als Array -- die Union aller Paket-Beitraege.
function Get-HarnessWorkflow {
    foreach ($H in $script:Harnesses) { Build-Harness $H }
}
