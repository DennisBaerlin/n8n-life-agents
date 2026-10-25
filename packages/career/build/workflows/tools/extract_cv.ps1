#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- tool_extract_cv (WS-1b) -------------------------------------------------
# CV-VISION-Pfad des Career-Advisors: Telegram-file_id -> agent.tool_fetch_telegram_file (INLINE,
# generischer Download-/base64-Baustein, WS-4) -> Claude-Vision aufs BILD/PDF (bezahlte API, trainiert
# nicht: ein Lebenslauf ist sensible PII -> nie ueber einen Free-Tier-Zugang) -> rohe career_profile-Felder.
# READ-ONLY BY CONSTRUCTION: KEIN DB-Write, KEIN HITL-Gate,
# KEIN Staging — die Extraktion liefert die Rohfelder nur ZURUECK; der Advisor spielt jede Zeile im Chat
# zurueck und schreibt das bestaetigte Feld getrennt via tool_set_profile_facts (Per-Eintrag-HITL,
# owner_only). Strukturell analog finance.tool_extract_finance_document, aber ohne den Staging-/Commit-
# Pfad (Finanz-Vision schreibt; CV-Vision schlaegt nur vor). Modell via config model.cv_extract (career,
# bei JEDEM Lauf gelesen, Muster vision_extract) — eigener Config-Key (finance besitzt model.vision_extract,
# UNIQUE(category,key)). Das Plumbing (Download/Validierung/base64) lebt im Core-Baustein; die CV-Vision
# bleibt HIER, der Claude-Aufruf ueber den geteilten Baustein New-AnthropicMessagesNode (lib/build_helpers.ps1).
function Build-ExtractCv {
    # WS-4: generischen Download-/base64-Baustein inline rufen (D9-Core-Service-Alias). Liefert { ok, b64, mime, error }.
    $idFetch = Get-RequiredWorkflowId (Resolve-CoreServiceAlias 'core:fetch_telegram_file' $CoreServiceMap) 'Build-ExtractCv'

    # Extraktions-Vertrag (EN, Layer 1): NUR Rohwerte, EIN JSON-Objekt, die career_profile-Felder.
    # KEINE Apostrophe verwenden (JS-Single-Quote-String im jsonBody). "LLM rechnet NICHT" (WP3): Daten werden
    # abgelesen, nie verrechnet — career_start_date = Beginn der fruehesten Berufstaetigkeit wie gedruckt (nie Jahre
    # summieren), Genauigkeit wie gedruckt (2014 / 2014-03 / Tag); die DB leitet alle Zeitspannen beim Anzeigen ab.
    $sysText = 'You extract a structured career profile from a photographed or scanned CV / resume / Lebenslauf. Output ONLY a JSON object, no prose. All fields are optional - omit any field that is not clearly printed or readable; never invent. Output RAW printed values only - never compute or estimate. Fields: current_title = the current or most recent job title (string); industry = the sector of the current or most recent role (string); career_start_date = the start of the EARLIEST professional role listed, read off as printed (never add up durations; the database derives time spans); skills = array of objects {name, level one of beginner|intermediate|advanced|expert only if the document grades it else omit level, since = the year the skill was first used only if printed} - only clearly evidenced skills, at most 20; last_job_change_date = the start date of the current or most recent role. Dates keep the precision printed: a full German date DD.MM.YYYY becomes YYYY-MM-DD, a month-year like 03/2021 becomes 2021-03, a bare year stays 2014. If the document is not a CV or resume, return {}.'

    # Trigger-Inputs: file_id (aus dem [attachment ...]-Marker), doc_hint (optionaler Nutzer-Kontext),
    # chat_id (vom Advisor-Binder immer durchgereicht — hier ungelesen, nur Vertrags-Symmetrie/Input-an-ZWEI-Stellen).
    $trig = Build-Trigger @('file_id', 'doc_hint', 'chat_id')

    # WS-4: generischer Download-/base64-Baustein inline -> { ok, b64, mime, error } (leere/unbrauchbare file_id -> ok:false).
    $fetch = Build-CallWorkflow 'Fetch telegram file' @(420, 60) $idFetch 'agent.tool_fetch_telegram_file' `
        ([ordered]@{ file_id = "={{ `$('Start').item.json.file_id }}" })
    $ifB64 = Build-If 'File ok?' @(860, 60) "={{ `$('Fetch telegram file').item.json.ok }}" 'true' 'equals' 'boolean'
    $errB64 = Build-ToolError 'File unusable' @(1080, 240) "={{ `$('Fetch telegram file').item.json.error }}"

    # Claude-Vision: Bild als image-Block, PDF als document-Block + Kontext-Text. JSON-Objekt per Prompt-Vertrag
    # (alle Felder optional -> kein festes Structured-Output-Schema); der Parse toleriert Zaeune.
    $fileBlock = Get-AnthropicFileBlockJs -B64Expr "`$('Fetch telegram file').item.json.b64" -MimeExpr "`$('Fetch telegram file').item.json.mime"
    $contentJs = "[ $fileBlock, { type: 'text', text: 'Document context from the user: ' + (`$('Start').item.json.doc_hint || 'none') + '. Extract the career profile now.' } ]"
    # Modell zur Laufzeit (model.cv_extract via core.fn_config_get).
    $loadModel = New-ModelConfigNode -Position @(1080, -100) -Keys @( ,@('career', 'cv_extract') )
    $http = New-AnthropicMessagesNode -Name 'Vision extract' -Position @(1080, 60) -ConfigModelKey 'cv_extract' -System $sysText `
        -ContentJs $contentJs -Effort low -TimeoutMs 180000

    $jsShape = (Get-AnthropicResultJs) + @'
const r = $input.first().json;
const fail = (m) => [{ json: { ok: false, error: 'CV extraction failed (' + m + ') - ask the user for a sharper photo or to dictate the facts instead.' } }];
const res = anthropicText(r);
if (!res.ok) return fail(res.error);
const txt = stripFences(res.text);
const a = txt.indexOf('{'), z = txt.lastIndexOf('}');
let prof;
try { prof = JSON.parse(a >= 0 && z > a ? txt.slice(a, z + 1) : txt); }
catch (e) { return fail('unparseable model output'); }
if (!prof || typeof prof !== 'object' || Array.isArray(prof)) return fail('model did not return an object');
if (Array.isArray(prof.skills)) prof.skills = prof.skills.slice(0, 20).filter(s => s && typeof s === 'object' && s.name);
const keys = Object.keys(prof).filter(k => prof[k] !== null && prof[k] !== '' && !(Array.isArray(prof[k]) && prof[k].length === 0));
if (keys.length === 0) return [{ json: { ok: false, error: 'No CV data recognized - is this really a CV/resume? Ask the user, then capture by asking if needed.' } }];
return [{ json: { ok: true, profile: JSON.stringify(prof), field_count: keys.length } }];
'@
    $shape = [ordered]@{
        parameters = [ordered]@{ jsCode = $jsShape }
        type = 'n8n-nodes-base.code'
        typeVersion = 2
        position = @(1300, 60)
        id = (New-Id)
        name = 'Shape profile'
    }
    $ifShaped = Build-If 'Profile ok?' @(1520, 60) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errShape = Build-ToolError 'Extraction failed' @(1740, 240) "={{ `$('Shape profile').item.json.error }}"

    # READ-ONLY: nur die Rohfelder zurueckgeben (KEIN Write). Der Advisor spielt jedes Feld im Chat zurueck
    # und schreibt das bestaetigte Feld getrennt via tool_set_profile_facts (Per-Eintrag-HITL, owner_only).
    $ret = Build-Return @(1740, 60) @(
        ,@('ok', 'true', 'boolean')
        ,@('profile', "={{ `$('Shape profile').item.json.profile }}", 'string')
        ,@('field_count', "={{ `$('Shape profile').item.json.field_count }}", 'number')
    )

    $sticky = Build-Sticky 'CV-Vision (paid-key Pflicht, read-only)' @(420, -420) `
        'Fetch telegram file (Core-Baustein: Download/base64) -> Load model config -> Claude-Vision aufs Bild/PDF (model.cv_extract, Denk-Tiefe niedrig) -> Rohfelder zurück' `
        'PRIVACY: ein Lebenslauf ist sensible PII -> geht NUR über die bezahlte Anthropic-API (anthropicApi-Credential; trainiert laut Commercial Terms nicht auf Kundeninhalten) — nie über einen Free-Tier-Zugang. Der Download/die base64-Wandlung kommt aus dem generischen Baustein agent.tool_fetch_telegram_file (kein Key dort; Allow-List jpeg/png/gif/webp/pdf, Bild <= 5 MB); die CV-Vision bleibt HIER, der Aufruf über den geteilten Baustein New-AnthropicMessagesNode (Bild = image-Block, PDF = document-Block; abgeschnittene Antwort/Ablehnung -> ok:false). READ-ONLY BY CONSTRUCTION: KEIN DB-Write, KEIN HITL-Gate, KEIN Staging — die Extraktion liefert NUR die rohen career_profile-Felder (current_title/industry/experience_years/skills/last_job_change_date) als JSON-Objekt zurück (Prompt-Vertrag, Parse toleriert Zäune). Der Advisor spielt jede Zeile im Chat zurück und schreibt das bestätigte Feld getrennt via tool_set_profile_facts (Per-Eintrag-HITL, owner_only). "LLM rechnet NICHT": experience_years nur wenn explizit gedruckt — NIE aus Job-Datumsangaben summiert (die DB leitet "Jahre seit Wechsel" aus last_job_change_date ab). Modell: Load model config liest bei JEDEM Lauf core.config model.cv_extract (Wechsel: lifeagents config set model cv_extract <key>, wirkt sofort).' 320 560

    $nodes = @($trig, $fetch, $ifB64, $errB64,
               $loadModel, $http, $shape, $ifShaped, $errShape, $ret, $sticky)

    $conns = [ordered]@{
        'Start'              = @{ main = @( ,@( E 'Fetch telegram file' ) ) }
        'Fetch telegram file' = @{ main = @( ,@( E 'File ok?' ) ) }
        'File ok?'           = @{ main = @(
            @( E 'Load model config' ),
            @( E 'File unusable' )
        ) }
        'Load model config' = @{ main = @( ,@( E 'Vision extract' ) ) }
        'Vision extract' = @{ main = @( ,@( E 'Shape profile' ) ) }
        'Shape profile'  = @{ main = @( ,@( E 'Profile ok?' ) ) }
        'Profile ok?'    = @{ main = @(
            @( E 'Return' ),
            @( E 'Extraction failed' )
        ) }
    }

    return Build-Workflow 'agent.career.tool_extract_cv' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
