#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.tool_expert_panel (CROSS-AGENT, read-only, kein HITL) ------------
# Der aufrufende Advisor stellt das Dossier EINMAL zusammen (alle Personas sehen
# identische Fakten) und waehlt die Personas selbst. Die Personas werden per Index
# auf ZWEI Modell-Lanes verteilt (gerade -> Lane A, ungerade -> Lane B). Die Lane-Modelle
# kommen zur LAUFZEIT aus core.config (model.panel_a / model.panel_b, Load model config), Default Claude Sonnet + Claude
# Opus = zwei Modell-Stufen -> zwei unabhaengige Meinungen. Rueckgabe: Array {role, model, opinion} — KEIN Synthesizer im Tool,
# der (staerkere) Advisor synthetisiert selbst und benennt Dissens explizit.
# Lanes laufen SEQUENTIELL (kein Merge-Node-Risiko); jede Lane onError continue ->
# faellt eine aus, liefert die andere trotzdem.
function Build-ExpertPanel {
    # Lane-Modelle zur Laufzeit (model.panel_a / model.panel_b), Default Claude Sonnet + Claude Opus (zwei Modell-Stufen =
    # zwei unabhaengige Meinungen; Owner-Entscheid 2026-10: ohne Google). Wechsel: lifeagents config set model panel_a <key>.
    $trig = Build-Trigger @('question', 'dossier', 'personas')

    # Personas parsen + auf Lanes verteilen + Lane-Prompts bauen (deterministisch, kein LLM)
    $jsPrep = @'
const inp = $input.first().json;
let personas = inp.personas;
if (typeof personas === 'string') {
  try { personas = JSON.parse(personas); } catch (e) {
    return [{ json: { ok: false, error: 'personas is not valid JSON: ' + String(personas).slice(0, 120) } }];
  }
}
if (!Array.isArray(personas)) personas = personas ? [personas] : [];
personas = personas
  .map(p => (typeof p === 'string') ? { role: p, focus: '' } : { role: String(p.role || '').trim(), focus: String(p.focus || '').trim() })
  .filter(p => p.role);
if (!personas.length) {
  return [{ json: { ok: false, error: 'No personas given. Pass personas as a JSON array like [{"role":"tax advisor","focus":"German capital gains tax"}].' } }];
}
if (personas.length > 6) personas = personas.slice(0, 6);
const question = String(inp.question || '').trim();
const dossier  = String(inp.dossier  || '').trim();
if (!question) return [{ json: { ok: false, error: 'question must be non-empty.' } }];
const laneA = personas.filter((p, i) => i % 2 === 0);
const laneB = personas.filter((p, i) => i % 2 === 1);
const mkPrompt = (lane) => {
  if (!lane.length) return '';
  const plist = lane.map((p, i) => (i + 1) + '. ' + p.role + (p.focus ? ' (focus: ' + p.focus + ')' : '')).join('\n');
  return 'You simulate an INDEPENDENT expert panel. For EACH persona below, write one focused opinion (max 200 words) strictly from that persona\'s professional perspective. Disagree where the perspective warrants it; do not converge to consensus. Base yourself ONLY on the dossier facts and general professional knowledge.\n\nPERSONAS:\n' + plist + '\n\nDOSSIER (identical facts for all personas):\n' + (dossier || '(none provided)') + '\n\nQUESTION:\n' + question + '\n\nReturn ONLY a JSON array, no prose: [{"role":"<persona role>","opinion":"<their opinion>"}]';
};
return [{ json: { ok: true, prompt_a: mkPrompt(laneA), prompt_b: mkPrompt(laneB), personas_a: laneA, personas_b: laneB } }];
'@
    $prep = [ordered]@{
        parameters = [ordered]@{ jsCode = $jsPrep }
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(220, 0)
        id = (New-Id)
        name = 'Prepare lanes'
    }

    $ifValid = Build-If 'Input ok?' @(440, 0) '={{ $json.ok }}' 'true' 'equals' 'boolean'

    $errInput = Build-ToolError 'Invalid input' @(660, -200) "={{ `$('Prepare lanes').item.json.error }}"

    # Beide Lane-Modelle bei JEDEM Lauf aus core.config (Lane-Prompts lesen per Namen aus Prepare lanes -> der
    # eingeschobene Knoten aendert nichts an ihren Daten).
    $loadModel = New-ModelConfigNode -Position @(550, 160) -Keys @( @('core', 'panel_a'), @('core', 'panel_b') )

    # Lane A (chainLlm; leerer Prompt -> Modell liefert irrelevantes -> Assemble ignoriert leere Lanes)
    $laneA = [ordered]@{
        parameters = [ordered]@{
            promptType = 'define'
            text = "={{ `$('Prepare lanes').item.json.prompt_a || 'Reply with exactly: []' }}"
        }
        type = '@n8n/n8n-nodes-langchain.chainLlm'
        typeVersion = 1.7
        position = @(660, 0)
        id = (New-Id)
        name = 'Panel lane A'
        onError = 'continueRegularOutput'
        retryOnFail = $true
        maxTries = 2
        waitBetweenTries = 2000
    }
    # Lane-A-Umschalter (je Claude-Modell ein Knoten). -NamePrefix: zwei Umschalter in EINEM Workflow brauchen
    # eindeutige Knoten-Namen (n8n verdrahtet ueber den Namen). .first(): Config-Knoten hat genau eine Zeile.
    $selA = New-ModelSelectorBundle -ConfigField 'model.panel_a' -ConfigNodeName 'Load model config' -AgentNodeName 'Panel lane A' `
        -NamePrefix 'Lane A ' -FirstConfigItem -SelectorPos @(660, 220) -ModelRowPos @(500, 400) -Effort high

    $laneAOut = Build-Set 'Lane A out' @(880, 0) @(
        ,@('opinions_a', '={{ $json.text || "" }}', 'string')
    )

    # Lane B: zweite Modell-Stufe (Default Claude Opus) — zweite, unabhaengige Meinung
    $laneB = [ordered]@{
        parameters = [ordered]@{
            promptType = 'define'
            text = "={{ `$('Prepare lanes').item.json.prompt_b || 'Reply with exactly: []' }}"
        }
        type = '@n8n/n8n-nodes-langchain.chainLlm'
        typeVersion = 1.7
        position = @(1100, 0)
        id = (New-Id)
        name = 'Panel lane B'
        onError = 'continueRegularOutput'
        retryOnFail = $true
        maxTries = 2
        waitBetweenTries = 2000
    }
    # Lane-B-Umschalter (zweite Modell-Stufe, Default Claude Opus).
    $selB = New-ModelSelectorBundle -ConfigField 'model.panel_b' -ConfigNodeName 'Load model config' -AgentNodeName 'Panel lane B' `
        -NamePrefix 'Lane B ' -FirstConfigItem -SelectorPos @(1100, 220) -ModelRowPos @(940, 400) -Effort high

    # Beide Lane-Outputs deterministisch zu {role, model, opinion}[] zusammensetzen. Etikett = die zur Laufzeit gewaehlte
    # Modell-Id (Config-Wert ueber die eingebackene Zuordnung, dieselbe wie im Umschalter); der Hinweis an den Berater
    # nennt "zwei verschiedene Modelle" nur, wenn die Lanes wirklich verschiedene Modelle nutzen.
    $jsAssemble = @'
const MODEL_IDS = MODEL_ID_MAP;
const cfg = ($('Load model config').first().json.model) || {};
const MODEL_A = MODEL_IDS[cfg.panel_a] || String(cfg.panel_a || 'unknown');
const MODEL_B = MODEL_IDS[cfg.panel_b] || String(cfg.panel_b || 'unknown');
const prep = $('Prepare lanes').first().json;
const aRaw = $('Lane A out').first().json.opinions_a || '';
const bRaw = ($input.first().json && $input.first().json.text) || '';
function parse(raw, personas, model) {
  if (!personas || !personas.length) return [];
  try {
    const m = String(raw).match(/\[[\s\S]*\]/);
    const arr = JSON.parse(m ? m[0] : raw);
    return arr.filter(o => o && o.opinion).map((o, i) => ({
      role: String(o.role || (personas[i] && personas[i].role) || 'expert'),
      model,
      opinion: String(o.opinion).slice(0, 2500)
    }));
  } catch (e) {
    const t = String(raw).trim();
    return t ? [{ role: personas[0].role, model, opinion: t.slice(0, 2500) }] : [];
  }
}
const out = [...parse(aRaw, prep.personas_a, MODEL_A), ...parse(bRaw, prep.personas_b, MODEL_B)];
if (!out.length) {
  return [{ json: { ok: false, error: 'Both panel lanes failed - no expert opinions available. Proceed with your own analysis and tell the user the panel was unavailable.' } }];
}
const source = MODEL_A !== MODEL_B ? 'two different models' : 'the same model in two independent runs';
return [{ json: { ok: true, opinions: out, note: 'Independent opinions from ' + source + '. Synthesize yourself and surface disagreements explicitly - do not average them away.' } }];
'@
    $jsAssemble = $jsAssemble.Replace('MODEL_ID_MAP', (Get-ModelIdMapJs))
    $assemble = [ordered]@{
        parameters = [ordered]@{ jsCode = $jsAssemble }
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(1320, 0)
        id = (New-Id)
        name = 'Assemble panel'
    }

    $sticky = Build-Sticky 'Doc Expert Panel' @(120, -420) `
        'Cross-Agent Experten-Panel (2 Modell-Stufen)' `
        'Read-only, kein HITL. Der Advisor liefert question + dossier (EINMAL zusammengestellt, alle Personas sehen dieselben Fakten) + personas (JSON-Array, er wählt selbst). Prepare lanes verteilt Personas per Index auf 2 Lanes (Default Claude Sonnet / Claude Opus = zwei Modell-Stufen; Owner-Entscheid ohne Google) -> zwei unabhängige Meinungen. Load model config liest model.panel_a/panel_b bei JEDEM Lauf aus core.config (Wechsel: lifeagents config set model panel_a <key>); je Lane ein Umschalter mit einem Knoten je Claude-Modell — Präfix Lane A/Lane B, weil n8n eindeutige Knoten-Namen verlangt. Lanes laufen sequentiell, je onError continue (eine darf ausfallen). Assemble panel parst deterministisch zu {role, model, opinion}[] (model = zur Laufzeit gewählte Modell-Id; Hinweis nennt zwei verschiedene Modelle nur, wenn sie verschieden sind) - KEIN Synthesizer hier, der Advisor synthetisiert selbst mit explizitem Dissens.' 300 460

    $nodes = @($trig, $prep, $ifValid, $errInput, $loadModel, $laneA, $laneAOut, $laneB, $assemble, $sticky) +
             @($selA.Nodes) + @($selB.Nodes)
    $conns = [ordered]@{
        'Start'             = @{ main = @( ,@( E 'Prepare lanes' ) ) }
        'Prepare lanes'     = @{ main = @( ,@( E 'Input ok?' ) ) }
        'Input ok?'         = @{ main = @(
            @( E 'Load model config' ),
            @( E 'Invalid input' )
        ) }
        'Load model config' = @{ main = @( ,@( E 'Panel lane A' ) ) }
        'Panel lane A'      = @{ main = @( ,@( E 'Lane A out' ) ) }
        'Lane A out'        = @{ main = @( ,@( E 'Panel lane B' ) ) }
        'Panel lane B'      = @{ main = @( ,@( E 'Assemble panel' ) ) }
    }
    foreach ($k in $selA.Connections.Keys) { $conns[$k] = $selA.Connections[$k] }
    foreach ($k in $selB.Connections.Keys) { $conns[$k] = $selB.Connections[$k] }
    return Build-Workflow 'agent.tool_expert_panel' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
