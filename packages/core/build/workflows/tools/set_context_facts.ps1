#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds/$FactsDisplayJson im Parent-Scope).

# --- agent.tool_set_context_facts (Phase A: der EINE HITL-Fakten-Schreibweg) ----
# HITL-Write eines facts-Sidecars in die HOST-Tabelle agent.core_contexts ueber agent.fn_set_context_facts
# (loest agent.guide.tool_set_household_facts + agent.tool_set_profile_facts ab; die id dieses Workflows ist die
# des frueheren tool_set_profile_facts -> import:workflow ersetzt ihn in place). EIN Workflow, mehrere Bindings
# (Muster career): der Guide bindet ihn als KI-Tool tool_set_household_facts (persons/household/context_name,
# scope='household' FEST), der career_advisor als tool_set_profile_facts/tool_set_career_preferences (facts,
# context_name + scope='per_user' FEST). Der Pg-Node komponiert facts aus facts + persons + household; die fn
# entscheidet Gate/Zeilen-Regel/Merge (reservierte Core-Form-Keys persons/household). Approval-Stufe owner_only
# (approval_matrix-Block des core-Manifests); die fn traegt den Permission-Backstop (family hart owner_only, sonst context_scopes).
# Beschriftungen: Katalog-Keys <pkg>.facts.<ctx>.<feld>; die Kontext->Paket-Zuordnung kommt build-time aus den
# context_validators-Bloecken ($FactsDisplayJson, build.ps1) — der Core nennt kein Paket.
# Der Graph lebt in New-ContextFactsToolGraph und baut ZWEI Workflows (eine Build-* je tools/-Datei):
#   agent.tool_set_context_facts     (hier, owner_only; Haushalts-Kontexte, scope fest aus der Bindung)
#   agent.tool_set_own_context_facts (tools/set_own_context_facts.ps1, Stufe self; -Own: ruft
#     agent.fn_set_own_context_facts, die scope='per_user' selbst setzt, KEIN scope-/persons-/household-Eingang).
function Build-SetContextFacts { New-ContextFactsToolGraph -WorkflowName 'agent.tool_set_context_facts' }

function New-ContextFactsToolGraph {
    param([Parameter(Mandatory)][string]$WorkflowName, [switch]$Own)
    $trig = if ($Own) { Build-Trigger @('context_name', 'facts', 'content') } `
            else      { Build-Trigger @('context_name', 'facts', 'persons', 'household', 'content', 'scope') }

    # Approval-Summary (Textkatalog, HITL-Bestaetigungs-Format): strukturierte Zeilen, das Gate rendert sie in der
    # Sprache des Empfaengers. Feld-Labels = <pkg>.facts.<ctx>.<feld> im Katalog des besitzenden Pakets ($FactsDisplayJson
    # = {ctx: pkg} aus den context_validators-Bloecken; family = core), ein offenes Feld ohne Key zeigt label_fallback
    # (lesbarer Feldname). Werte typisiert: Datum (ISO) -> date, role -> enum core.enum.role, language -> Eigenname,
    # bool -> ja/nein, null -> 'wird entfernt'. KEINE rohen key=value-Dumps, keine DB-Spaltennamen (person_id intern).
    $ctxPrefix = "(((c) => (c === 'family' ? 'core' : (__FACTS_PKG__[c] || 'core')) + '.facts.' + c + '.')(`$('Start').item.json.context_name || 'family'))"
    $linesExpr = @'
(() => {
  const S = $('Start').item.json;
  const pre = __CTX_PREFIX__;
  const parse = (s, d) => { try { return s ? JSON.parse(s) : d; } catch (e) { return d; } };
  __FACTS_SOURCE__
  const ORDER = ['role', 'birth_date', 'employment_status', 'citizenships', 'language', 'persona'];
  const SKIP = ['person_id', 'first_name', 'last_name', 'as_of', '_meta'];
  const human = k => (k.charAt(0).toUpperCase() + k.slice(1)).replace(/_/g, ' ');
  const one = it => {
    if (it === null || it === undefined) return '?';
    if (typeof it === 'object') {
      const nm = it.name || it.title || JSON.stringify(it);
      const sub = it.level || (it.salary_expectation_eur != null ? ('~' + it.salary_expectation_eur + ' €') : '');
      return sub ? (nm + ' (' + sub + ')') : nm;
    }
    return String(it);
  };
  const line = (k, v) => {
    const b = { label: pre + k, label_fallback: human(k) };
    if (v === null) return Object.assign(b, { kind: 'removed', value: null });
    if (k === 'role') return Object.assign(b, { kind: 'enum', enum: 'core.enum.role', value: v });
    if (k === 'language') return Object.assign(b, { kind: 'language', value: v });
    if (k === 'persona') return Object.assign(b, { kind: 'enum', enum: 'core.persona.name', value: v });
    if (typeof v === 'boolean') return Object.assign(b, { kind: 'bool', value: v });
    if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v)) return Object.assign(b, { kind: 'date', value: v });
    if (Array.isArray(v)) return Object.assign(b, { kind: 'text', value: v.map(one).join(', ') });
    if (v !== undefined && typeof v === 'object') return Object.assign(b, { kind: 'text', value: JSON.stringify(v) });
    return Object.assign(b, { kind: 'text', value: v });
  };
  const sorted = o => Object.keys(o).filter(k => !SKIP.includes(k)).sort((a, b) => {
    const ia = ORDER.indexOf(a), ib = ORDER.indexOf(b); return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib); });
  const L = [];
  for (const p of persons) {
    const nm = [p.first_name, p.last_name].filter(Boolean).join(' ') || p.person_id || '?';
    L.push({ kind: 'heading', label: 'core.label.person', value: nm });
    for (const k of sorted(p)) L.push(line(k, p[k]));
  }
  const hk = sorted(hh);
  if (hk.length) { L.push({ kind: 'heading', label: 'core.facts.family.household', value: '' });
    for (const k of hk) L.push(line(k, hh[k])); }
  for (const k of sorted(facts).filter(k => k !== 'persons' && k !== 'household')) L.push(line(k, facts[k]));
  if ((S.content || '').trim()) L.push({ kind: 'note', value: 'core.hitl.note.prose_replaced' });
  if (!L.length) L.push({ kind: 'note', value: 'core.hitl.note.no_facts' });
  return L;
})()
'@
    # -Own: KEIN 'family'-Default (der Weg schreibt nie family) -> fehlt context_name, zeigt die Vorschau ehrlich '?'
    # (Titel-fallback = roher Kontextname, Labels = label_fallback).
    if ($Own) { $ctxPrefix = $ctxPrefix.Replace("context_name || 'family'", "context_name || '?'") }
    # Fakten-Quelle der Karte: Haushalts-Weg = das von der DB aufgeloeste Objekt (Resolve dates: relative Daten wie
    # "-3 days" -> Datum, Karte = Speicher); -Own (Stufe self, approval_lint (e): genau EIN Postgres-Node) liest die
    # Eingabe roh, dort loest agent.fn_set_context_facts beim Speichern auf (Jahres-/Monats-Genauigkeit, kein Versatz).
    $factsSource = if ($Own) {
        "const facts = parse(S.facts, {});`n  const persons = Array.isArray(facts.persons) ? facts.persons : [];`n  const hh = (facts.household && typeof facts.household === 'object') ? facts.household : {};"
    } else {
        "const R = parse(`$('Resolve dates').item.json.facts_resolved, {});`n  const facts = (R && typeof R === 'object' && !Array.isArray(R)) ? R : {};`n  const persons = Array.isArray(facts.persons) ? facts.persons : [];`n  const hh = (facts.household && typeof facts.household === 'object') ? facts.household : {};"
    }
    $linesExpr = $linesExpr.Replace('__FACTS_SOURCE__', $factsSource)
    $linesExpr = $linesExpr.Replace('__CTX_PREFIX__', $ctxPrefix).Replace('__FACTS_PKG__', $FactsDisplayJson).Trim()
    $summary = New-HitlSummary -Pos @(220, 0) -Title 'core.hitl.set_context_facts' `
        -TitleParams @{ context = "{ kind: 'key', value: $($ctxPrefix.Replace('__FACTS_PKG__', $FactsDisplayJson)) + 'title', fallback: String(`$('Start').item.json.context_name || '?') }" } `
        -LinesExpr $linesExpr

    $gate = Build-CallWorkflow 'Request Approval' @(440, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })

    $ifApproved = Build-If 'Approved?' @(660, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'

    $retCancelled = Build-ToolCancelled 'Return cancelled' @(880, 200) 'the set_context_facts action'

    # Atomarer Write via fn. facts = facts-Objekt + persons/household der Guide-Bindung zusammengesetzt; leer ->
    # undefined (JSON.stringify droppt den Key) -> die fn liefert ein korrigierbares {ok:false} statt eines leeren Writes.
    # Ungueltiges JSON vom Modell -> try/catch liefert den Nicht-Objekt-Sentinel '__invalid_json__' -> die fn lehnt mit
    # {ok:false, 'facts must be a JSON object'} ab (Tool-Fehler als DATEN, kein Execution-Abbruch + Owner-Alert).
    # -Own: nur facts/content, die fn setzt scope='per_user' selbst (approval_lint (e) prueft: nur diese fn, kein scope-Eingang).
    $fnName = if ($Own) { 'agent.fn_set_own_context_facts' } else { 'agent.fn_set_context_facts' }
    $payload = if ($Own) {
        [ordered]@{
            context_name = '$(''Start'').item.json.context_name'
            facts        = (Get-GuardedJsonExpr '(o => Object.keys(o).length ? o : undefined)($(''Start'').item.json.facts ? JSON.parse($(''Start'').item.json.facts) : {})')
            content      = '$(''Start'').item.json.content || '''''
            chat_id      = '$(''Start'').item.json.chat_id'   # Identitaet: die fn schreibt NUR den Kontext dieser Person (NIE LLM)
        }
    } else {
        [ordered]@{
            context_name = '$(''Start'').item.json.context_name || ''family'''
            # das in "Resolve dates" EINMAL aufgeloeste Objekt (Karte = Speicher); fehlt es -> undefined -> {ok:false}
            facts        = '(x => x ? JSON.parse(x) : undefined)($(''Resolve dates'').item.json.facts_resolved)'
            content      = '$(''Start'').item.json.content || '''''
            scope        = '$(''Start'').item.json.scope || undefined'   # FEST aus der Bindung (household|per_user), nie $fromAI
            chat_id      = '$(''Start'').item.json.chat_id'   # Identitaet fuer den Permission-Backstop (NIE LLM)
        }
    }
    # Haushalts-Weg: relative Daten ("-3 days", "last monday") VOR der Karte von der DB aufloesen lassen
    # (core.fn_resolve_fact_dates, Genauigkeit folgt der Angabe) — die Karte zeigt und der Write schreibt dasselbe.
    # Eingabe = dasselbe zusammengesetzte facts-Objekt wie frueher direkt im Write (kaputtes JSON -> Sentinel -> fn {ok:false}).
    $resolve = Build-Pg 'Resolve dates' @(0, 160) `
        "=SELECT core.fn_resolve_fact_dates((`$1::jsonb)->'facts')::text AS facts_resolved;" `
        ([ordered]@{
            facts = (Get-GuardedJsonExpr '(o => Object.keys(o).length ? o : undefined)(Object.assign({}, $(''Start'').item.json.facts ? JSON.parse($(''Start'').item.json.facts) : {}, $(''Start'').item.json.persons ? { persons: JSON.parse($(''Start'').item.json.persons) } : {}, $(''Start'').item.json.household ? { household: JSON.parse($(''Start'').item.json.household) } : {}))')
        })
    $stickyResolve = Build-Sticky 'Doc Relative Daten' @(-40, 320) `
        'Resolve dates — die DB rechnet relative Angaben' `
        'core.fn_resolve_fact_dates löst Werte unter *_date/since auf, die keine absoluten Daten sind ("-3 days", "last monday", "-5 years"). Genauigkeit folgt der Angabe: Jahre -> YYYY, Monate -> YYYY-MM, sonst der Tag (aus "mein Sohn ist 5" wird kein erfundener Geburtstag; der Validator verlangt dort einen Tag und lehnt ab). Karte und Write nutzen dasselbe aufgelöste Objekt, die fn löst zusätzlich auf (idempotent).' 300 300

    $write = Build-Pg 'Set context facts (atomic)' @(880, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'context_name' AS context_name, (r->>'created')::boolean AS created, (r->>'persons_count')::int AS persons_count, r->>'last_confirmed_at' AS last_confirmed_at, COALESCE(r->'language_missing', '[]'::jsonb) AS language_missing FROM $fnName(`$1::jsonb) AS r;" `
        $payload

    $ifOk = Build-If 'Write ok?' @(1100, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $err = Build-ToolError 'Write failed' @(1320, 200) "={{ `$('Set context facts (atomic)').item.json.reason }}"

    # Sprach-Picker (Textkatalog): fn liefert language_missing = in DIESEM Write neu angelegte family-Personen ohne
    # Sprache -> je Person eine Knopf-Karte an den Owner (core.sub_send_language_picker). Der Sub-Aufruf ist fail-open
    # (onError continue): der Write ist schon gespeichert, ein fehlgeschlagener Picker darf ihn nicht als Fehler melden
    # (Sprache bleibt per Chat/CLI setzbar, Laufzeit-Fallback = Owner-Sprache).
    $W = "`$('Set context facts (atomic)').first().json"
    $ifLang = Build-If 'Language missing?' @(1320, -120) "={{ ($W.language_missing || []).length }}" '0' 'gt' 'number'
    $pickItems = [ordered]@{
        parameters = [ordered]@{ mode = 'runOnceForAllItems'
            jsCode = "return ($W.language_missing || []).map(pid => ({ json: { person_id: String(pid) } }));" }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(1540, -220)
        id = (New-Id); name = 'Language picker items'
    }
    $pickerId = Get-RequiredWorkflowId 'core.sub_send_language_picker' 'Build-SetContextFacts'
    $sendPicker = Build-CallWorkflow 'Send language picker' @(1760, -220) $pickerId 'core.sub_send_language_picker' `
        ([ordered]@{ person_id = "={{ `$json.person_id }}"; chat_id = $OWNER_CHAT_ID })
    $sendPicker['onError'] = 'continueRegularOutput'

    # Return einmal (executeOnce): nach dem Picker-Zweig kaemen sonst N Items an; Werte direkt aus dem Write-Knoten.
    $ret = Build-Return @(1980, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('context_name', "={{ $W.context_name }}", 'string')
        ,@('created', "={{ $W.created }}", 'boolean')
        ,@('persons_count', "={{ $W.persons_count }}", 'number')
        ,@('last_confirmed_at', "={{ $W.last_confirmed_at }}", 'string')
    )
    $ret['executeOnce'] = $true

    $stickyOverview = if ($Own) {
        Build-Sticky 'Doc Überblick' @(-260, -300) `
            'agent.tool_set_own_context_facts — eigene persönliche Fakten (HITL-Stufe self)' `
            'Schreibweg für die EIGENEN per_user-Kontexte der fragenden Person (heute Career-Coach: tool_set_profile_facts / tool_set_career_preferences, context_name fest je Bindung). Gate-Stufe self: die Person bestätigt selbst, KEIN Owner-Send (eine Info trüge private Profildaten zum Owner). Die Strenge kommt aus der DB: agent.fn_set_own_context_facts setzt scope=per_user fest -> nur <base>__<eigene person_id>; household/family/Plan-Kontexte sind gesperrt. Eingang: context_name, facts (JSON-String), content, chat_id — bewusst KEIN scope/persons/household (approval_lint (e)). Ausgang wie agent.tool_set_context_facts. Graph geteilt über New-ContextFactsToolGraph (tools/set_context_facts.ps1); die Bestätigungs-Labels kommen aus dem Textkatalog des besitzenden Pakets (<pkg>.facts.<ctx>.*).' 240 560
    } else {
        Build-Sticky 'Doc Überblick' @(-260, -300) `
            'agent.tool_set_context_facts — Fakten-Schreibweg für Haushalts-Kontexte (HITL, owner_only)' `
            'Der Guide ruft ihn als tool_set_household_facts (persons/household, scope=household fest). Persönliche per_user-Kontexte laufen über agent.tool_set_own_context_facts (Stufe self, gleicher Graph via New-ContextFactsToolGraph). Eingang: context_name, facts | persons | household (JSON-Strings), content, scope, chat_id. Ausgang: {ok, context_name, created, persons_count, last_confirmed_at} bzw. {ok:false, reason} / cancelled. Die Bestätigungs-Labels kommen aus dem Textkatalog des besitzenden Pakets (<pkg>.facts.<ctx>.*, Paket-Zuordnung build-time aus den context_validators-Blöcken).' 240 520
    }
    $stickyHitl = if ($Own) {
        Build-Sticky 'Doc HITL + DB-Validierung' @(440, -300) `
            'HITL-Gate (Stufe self) + fn_set_own_context_facts' `
            'Vor dem Write: Playback-Summary -> agent.tool_human_approval mit Stufe self: Owner -> normaler Owner-Tap; Mitglied -> nur das Mitglied bestätigt, KEIN Owner-Send (auch keine Info). Approve -> agent.fn_set_own_context_facts (setzt scope=per_user fest) -> agent.fn_set_context_facts schreibt NUR <base>__<person_id> der aus chat_id aufgelösten Person (INSERT-on-first-write); household-/family-/Plan-Kontexte (core.advisors.plan_context) und fremde Suffix-Namen -> ok:false ohne Write. Validierung Core-Validator + Paket-Validator -> ok:false ohne Write. Decline -> cancelled, nichts geschrieben.' 280 600
    } else {
        Build-Sticky 'Doc HITL + DB-Validierung' @(440, -300) `
            'HITL-Gate + fn_set_context_facts' `
            'Vor dem Write: Playback-Summary -> agent.tool_human_approval (Approve/Decline). Approve -> agent.fn_set_context_facts: family = hart owner_only (zuerst); household-Kontexte (family + registrierte household-Kontexte AKTIVER Pakete) MÜSSEN als Installer-Skelett existieren (fehlt die Zeile -> ok:false, kein Insert); per_user-Kontexte -> Zeile <base>__<person_id> beim ersten Write (Person aus der chat_id, nie LLM). Merge: persons per person_id (as_of-Stempel), household flach, sonst ersetzen; null löscht den Key; persons:null/household:null/_meta -> ok:false. Validierung Core-Validator + Paket-Validator -> ok:false ohne Write; Trigger trg_validate_household_facts ist der strukturelle Backstop. Decline -> cancelled, nichts geschrieben.' 280 600
    }

    $stickyLang = Build-Sticky 'Doc Sprach-Picker' @(1300, -560) `
        'Sprache neuer Personen per Knopf' `
        'fn_set_context_facts liefert language_missing = Personen, die DIESER Write in family neu angelegt hat und die keine Sprache tragen (Handles). Language missing? -> Language picker items (je Person ein Item) -> Send language picker (core.sub_send_language_picker, an den Owner): eine Karte mit je einem Knopf pro unterstützter Sprache; der Tipp setzt die Sprache über agent.fn_set_person_language. Fail-open (onError continue): der Write ist schon gespeichert. Return läuft genau einmal (executeOnce) und liest die Werte aus dem Write-Knoten.' 300 560

    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Build Approval Summary' ) ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Set context facts (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Set context facts (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
    }
    if ($Own) {
        # -Own legt nie eine family-Person an (language_missing bleibt leer) UND Stufe self darf ausser dem Gate keinen
        # Workflow rufen (approval_lint (e)) -> kein Picker-Zweig, Write ok? geht direkt auf Return.
        $nodes = @($trig, $summary, $gate, $ifApproved, $retCancelled, $write, $ifOk, $err, $ret, $stickyOverview, $stickyHitl)
        $conns['Write ok?'] = @{ main = @( @( E 'Return' ), @( E 'Write failed' ) ) }
    } else {
        $nodes = @($trig, $resolve, $summary, $gate, $ifApproved, $retCancelled, $write, $ifOk, $err, $ifLang, $pickItems, $sendPicker, $ret, $stickyOverview, $stickyHitl, $stickyLang, $stickyResolve)
        $conns['Start']         = @{ main = @( ,@( E 'Resolve dates' ) ) }
        $conns['Resolve dates'] = @{ main = @( ,@( E 'Build Approval Summary' ) ) }
        $conns['Write ok?'] = @{ main = @(
            @( E 'Language missing?' ),
            @( E 'Write failed' )
        ) }
        $conns['Language missing?'] = @{ main = @(
            @( E 'Language picker items' ),   # [0] neue Person(en) ohne Sprache -> Picker
            @( E 'Return' )                   # [1] nichts offen
        ) }
        $conns['Language picker items'] = @{ main = @( ,@( E 'Send language picker' ) ) }
        $conns['Send language picker']  = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow $WorkflowName $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
