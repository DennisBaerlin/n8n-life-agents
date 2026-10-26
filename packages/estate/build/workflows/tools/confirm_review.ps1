#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.estate.tool_confirm_review (WS-2, Fortschritts-Flag-Klasse — KEIN HITL) -----------
# Stempelt estate.person_records.last_reviewed_at = now() fuer EINE Person: die Bestaetigung
# "Register durchgesehen, Stand aktuell" (re-armt den WS-4-Jahres-Review). KEIN HITL-Gate:
# reiner Fortschritts-/Bestaetigungs-Flag ohne Daten-/PII-Write (Praezedenz
# tool_set_onboarding_section) -> ruft KEIN agent.tool_human_approval -> KEIN
# approval_matrix-Eintrag (approval_lint greift nur fuer Gate-Aufrufer). Der adults_only-DB-
# Backstop bleibt (Kind -> {ok:false}) — die einzige Absicherung ohne Gate. Cred = estate_rw.
function Build-EstateConfirmReview {
    $CRED_POSTGRES = $CRED_ESTATE_RW
    $trig = Build-Trigger @('person')

    $resPerson = Build-ResolvePerson 'Resolve Person' @(220, 0) 'person'
    $ifBad = Build-If 'Person unique?' @(440, 0) "={{ `$('Resolve Person').item.json.hit_count }}" '1'
    $errBad = Build-ToolError 'Person unresolved' @(660, 200) `
        "=The person '{{ `$('Start').item.json.person }}' could not be uniquely resolved ({{ `$('Resolve Person').item.json.hit_count }} match(es)). Name the household member clearly."

    $confirm = Build-Pg 'Confirm review (atomic)' @(660, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'person_id' AS person_id, r->>'last_reviewed_at' AS last_reviewed_at FROM estate.fn_confirm_review(`$1::jsonb) AS r;" `
        ([ordered]@{
            chat_id   = '$(''Start'').item.json.chat_id'
            person_id = '$(''Resolve Person'').item.json.person_id'
        })
    $ifWriteOk = Build-If 'Write ok?' @(880, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errWrite = Build-ToolError 'Confirm rejected' @(1100, 200) "={{ `$('Confirm review (atomic)').item.json.reason }}"
    $ret = Build-Return @(1100, 0) @(
        ,@('ok','true','boolean')
        ,@('person_id', "={{ `$('Confirm review (atomic)').item.json.person_id }}", 'string')
        ,@('last_reviewed_at', "={{ `$('Confirm review (atomic)').item.json.last_reviewed_at }}", 'string')
    )
    $stickyFn = Build-Sticky 'Fortschritts-Flag (KEIN HITL) + adults_only-Backstop' @(660, -280) `
        'estate.fn_confirm_review (Stempel last_reviewed_at, re-armt Jahres-Review)' `
        'Person (Pflicht) -> Slug via core.fn_resolve_person -> Person unique?. estate.fn_confirm_review UPSERTet den Zeitstempel estate.person_records.last_reviewed_at=now() (Zeile entsteht bei Bedarf) -> re-armt den WS-4-Jahres-Review (advisor.estate_review_days). KEIN HITL-Gate (Fortschritts-Flag-Klasse wie set_onboarding_section — kein Daten-/PII-Write, nur ein Zeitstempel; darum KEIN approval_matrix-Eintrag). Der adults_only-DB-Backstop (Kind -> {ok:false}) ist die einzige Absicherung ohne Gate.' 260 580
    $nodes = @($trig, $resPerson, $ifBad, $errBad, $confirm, $ifWriteOk, $errWrite, $ret, $stickyFn)
    $conns = [ordered]@{
        'Start'                   = @{ main = @( ,@( E 'Resolve Person' ) ) }
        'Resolve Person'          = @{ main = @( ,@( E 'Person unique?' ) ) }
        'Person unique?'          = @{ main = @(
            @( E 'Confirm review (atomic)' ),
            @( E 'Person unresolved' )
        ) }
        'Confirm review (atomic)' = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'               = @{ main = @(
            @( E 'Return' ),
            @( E 'Confirm rejected' )
        ) }
    }
    return Build-Workflow 'agent.estate.tool_confirm_review' $nodes $conns `
        @{ Category = 'register' }
}
