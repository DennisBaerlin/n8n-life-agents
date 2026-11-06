#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_load_config (zentraler Config-Loader) -------------------------
# Deterministischer Sub (KEIN Agent/LLM): jeder Agent ruft ihn als ersten Schritt ('Load Config'/
# 'Load core.config'). Liest core.config (category/key/value) und pivotet die Zeilen zu EINEM
# verschachtelten Objekt { model:{...}, transcription:{...}, ... }. Loest die alte ENV-Var-Injection
# ab. Von den Agenten + dem Voice-Tool per Name aus dem State referenziert ($LoadConfigId, kein ID-Literal).
#
# Start ist ein PASSTHROUGH-Trigger (KEINE getypten Inputs) -> Build-Trigger passt nicht (das wuerde
# chat_id-Inputs erzwingen); der Trigger wird inline konstruiert.
function Build-CoreSubLoadConfig {
    $start = [ordered]@{
        parameters  = [ordered]@{ inputSource = 'passthrough' }
        type        = 'n8n-nodes-base.executeWorkflowTrigger'
        typeVersion = 1.1
        position    = @(-832, 320)
        id          = (New-Id)
        name        = 'Start'
    }

    # Reiner SELECT (kein queryReplacement) -> Build-Pg ohne $Params (options = {}).
    $load = Build-Pg 'Load core.config' @(-624, 320) `
        'SELECT category, key, value FROM core.config ORDER BY category, key;'

    $pivotJs = @'
// Pivot category/key/value rows into one nested object the agents consume,
// e.g. { model: { orchestrator: 'claude-haiku-latest', finance: 'claude-sonnet-latest' },
//        transcription: { provider: 'google' } }.
const out = {};
for (const item of $input.all()) {
  const { category, key, value } = item.json;
  if (!out[category]) out[category] = {};
  out[category][key] = value;
}
return [{ json: out }];
'@
    $build = [ordered]@{
        parameters  = [ordered]@{ jsCode = $pivotJs; mode = 'runOnceForAllItems' }
        type        = 'n8n-nodes-base.code'
        typeVersion = 2
        position    = @(-416, 320)
        id          = (New-Id)
        name        = 'Build Config Object'
    }

    $sticky = [ordered]@{
        parameters  = [ordered]@{
            content = @'
## core.sub_load_config

Zentraler Config-Loader fuer alle Agenten (Sub-Workflow, passthrough; als erster Schritt aufgerufen). Loest die alte ENV-Var-Injection ab.

**Ablauf:** Load core.config (SELECT category,key,value) -> Build Config Object (pivotet die Zeilen zu einem verschachtelten Objekt).

**Rueckgabe:** ein Item, json = { model: { orchestrator, finance }, transcription: { provider }, ... }. Aufrufer lesen z. B. $('Load Config').item.json.model.finance.

**Quelle:** core.config (Schema core) = generischer Config-Store; Zeilen kommen paket-skopiert aus den .config-Bloecken aller packages/*/manifest.json via seed_data.sh (_seed_package_config). model.*-Werte sind per Trigger gegen agent.ai_models (Enum) abgesichert. Neue Config = neuer Manifest-Eintrag, kein Workflow-Edit.
'@
            height  = 320
            width   = 480
            color   = 4
        }
        type        = 'n8n-nodes-base.stickyNote'
        typeVersion = 1
        position    = @(-832, -20)
        id          = (New-Id)
        name        = 'Doc: Überblick'
    }

    $nodes = @($start, $load, $build, $sticky)
    $conns = [ordered]@{
        'Start'            = @{ main = @( ,@( E 'Load core.config' ) ) }
        'Load core.config' = @{ main = @( ,@( E 'Build Config Object' ) ) }
    }

    $wf = Build-Workflow 'core.sub_load_config' $nodes $conns
    $wf.settings = [ordered]@{ availableInMCP = $false; binaryMode = 'separate'; errorWorkflow = $ErrorNotifyId; executionOrder = 'v1' }
    return $wf
}
