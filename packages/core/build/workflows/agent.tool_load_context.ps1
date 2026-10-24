#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- agent.tool_load_context (gemeinsamer System-Prompt-Bauer) --------------
# Deterministischer Sub (KEIN Agent/LLM): jeder Agent-Workflow ruft ihn VOR dem AI-Node. Inputs:
# agent_name, include_manifest. EINE Postgres-Query: static-concat der static-Docs aus
# agent.core_contexts (global zuerst, dann agent-spezifisch) + optional das Lazy-Manifest
# (Name+Description der lazy-Contexts). Rueckgabe: system_prompt. Von den Agenten per Name aus dem
# State referenziert ($LoadContextId, kein ID-Literal). Die Assembly-SQL lebt hier im Workflow,
# nicht in der DB (Verweis in packages/core/db/agent.core_init.sql).
#
# Start traegt NUR agent_name + include_manifest (KEIN chat_id) -> Build-Trigger passt nicht (das
# wuerde chat_id erzwingen); der Trigger wird inline konstruiert.
function Build-AgentToolLoadContext {
    $start = [ordered]@{
        parameters  = [ordered]@{
            inputSource    = 'workflowInputs'
            workflowInputs = [ordered]@{
                values = @(
                    [ordered]@{ name = 'agent_name' },
                    [ordered]@{ name = 'include_manifest' }
                )
            }
        }
        type        = 'n8n-nodes-base.executeWorkflowTrigger'
        typeVersion = 1.1
        position    = @(0, 0)
        id          = (New-Id)
        name        = 'Start'
    }

    # Assembly-SQL: $1 = jsonb { agent_name, include_manifest } (Build-Pg-Standard). Sichtbarkeit =
    # (load_strategy x agent_name): static+NULL/agent -> System-Prompt; lazy -> Manifest (nur wenn
    # include_manifest != 'false'; physische per_user-Zeilen nie — Security-Audit 2026-10).
    $sql = @'
WITH static_docs AS (
  SELECT string_agg(content, E'\n\n---\n\n'
                    ORDER BY CASE
                                WHEN name = 'global_instructions' THEN 1
                                WHEN agent_name IS NOT NULL THEN 2
                                ELSE 3 END,
                             name) AS static_part
    FROM agent.core_contexts
   WHERE load_strategy = 'static'
     AND (agent_name = (($1::jsonb)->>'agent_name') OR agent_name IS NULL)
),
manifest AS (
  SELECT E'\n\n# Available lazy contexts (load via `load_context` tool by name)\n\n'
       || string_agg('- **' || name || '**: ' || description, E'\n' ORDER BY name) AS manifest_part
    FROM agent.core_contexts
   WHERE load_strategy = 'lazy'
     AND (agent_name = (($1::jsonb)->>'agent_name') OR agent_name IS NULL)
     AND NOT agent.fn_is_per_user_row(name)
)
SELECT COALESCE((SELECT static_part FROM static_docs), '')
    || CASE WHEN (($1::jsonb)->>'include_manifest') = 'false' THEN '' ELSE COALESCE((SELECT manifest_part FROM manifest), '') END AS system_prompt;
'@
    $load = Build-Pg 'Load Static + Manifest' @(224, 0) $sql ([ordered]@{
        agent_name       = "`$('Start').item.json.agent_name"
        include_manifest = "`$('Start').item.json.include_manifest"
    })

    $return = Build-Set 'Return' @(448, 0) @(
        ,@('system_prompt', "={{ `$json.system_prompt }}", 'string')
    )

    $stickyManifest = [ordered]@{
        parameters  = [ordered]@{
            content = @'
## include_manifest

**Aufbau des system_prompt (Inputs: agent_name, include_manifest):**
- `false` -> nur Static-Docs (global + agent_instructions), KEIN Lazy-Manifest. Fuer Agenten OHNE load_context-Tool (Orchestrator/Router).
- sonst / `true` -> Static-Docs + Lazy-Manifest (z. B. finance).

Die Assembly-SQL lebt hier im Workflow, nicht in der DB (siehe Verweis in core_init.sql).
'@
            height  = 240
            width   = 380
            color   = 4
        }
        type        = 'n8n-nodes-base.stickyNote'
        typeVersion = 1
        position    = @(-40, 180)
        id          = (New-Id)
        name        = 'Doc: include_manifest'
    }

    $stickyOverview = [ordered]@{
        parameters  = [ordered]@{
            content = @'
## agent.tool_load_context

Gemeinsamer Sub-Workflow: baut den System-Prompt eines Agenten. Inputs: agent_name, include_manifest.
EINE Postgres-Query: static-concat der static-Docs aus agent.core_contexts (global zuerst, dann agent-spezifisch) + optional das Lazy-Manifest (Name+Description der lazy-Contexts; OHNE die physischen per_user-Zeilen '<base>__<person_id>' anderer Personen — agent.fn_is_per_user_row; gelesen wird per Basisname + eigener chat_id). Rueckgabe: system_prompt.
Wird von jedem Agent-Workflow VOR dem AI-Node aufgerufen. Sichtbarkeit = (load_strategy x agent_name) -> siehe CLAUDE.md Vier-Schichten-Memory.
'@
            height  = 240
            width   = 420
            color   = 4
        }
        type        = 'n8n-nodes-base.stickyNote'
        typeVersion = 1
        position    = @(-40, -180)
        id          = (New-Id)
        name        = 'Doc: Überblick'
    }

    $nodes = @($start, $load, $return, $stickyManifest, $stickyOverview)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Load Static + Manifest' ) ) }
        'Load Static + Manifest' = @{ main = @( ,@( E 'Return' ) ) }
    }

    $wf = Build-Workflow 'agent.tool_load_context' $nodes $conns
    $wf.settings = [ordered]@{
        availableInMCP = $false; binaryMode = 'separate'; callerPolicy = 'workflowsFromSameOwner'
        errorWorkflow = $ErrorNotifyId; executionOrder = 'v1'; timeSavedMode = 'fixed'
    }
    return $wf
}
