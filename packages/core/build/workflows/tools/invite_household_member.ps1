#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- agent.guide.tool_invite_household_member (WS-5a, owner-only Member-Einladung) ----
# Der Owner sagt im Chat "lade meine Tochter Lisa ein". Das Tool stellt eine Einladung aus:
#   Check invite (READ, Owner-Gate + Person existiert & ungepairt -> ToolError VOR dem HITL)
#   -> Approval-Summary -> HITL-Gate -> Run invite (fn_invite_household_member: re-validiert atomar
#   + generiert Einmal-Code + armt die Challenge) -> Deep-Link t.me/<bot>?start=<code> zurueck.
# AUTH ist NICHT $fromAI: chat_id wird deterministisch aus dem Guide-Start durchgereicht (wie alle
# guide-Tools); fn_check/fn_invite leiten die Owner-Identitaet aus der numerischen chat_id ab
# (Privatchat: chat.id == from.id). Der bot_username kommt zur LAUFZEIT aus core.config (deployment-
# spezifisch -> nicht build-gebacken). Das eigentliche Binden passiert spaeter ueber den callback_query-
# Owner-Confirm im Orchestrator (Member loest ein -> Stage -> Owner-Tap committet).
function Build-InviteHouseholdMember {
    $trig = Build-Trigger @('person_name')

    # Pre-Gate (READ, kein Write): Owner-Check + Person-Aufloesung. {ok:false} -> ToolError vor dem HITL.
    $check = Build-Pg 'Check invite' @(220, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'person_id' AS person_id, r->>'role' AS role, r->>'full_name' AS full_name FROM agent.fn_check_household_invite(`$1::jsonb) AS r;" `
        ([ordered]@{
            chat_id     = '$(''Start'').item.json.chat_id'
            person_name = '$(''Start'').item.json.person_name'
        })
    $ifValid = Build-If 'Invite valid?' @(440, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errInvalid = Build-ToolError 'Invite invalid' @(660, 200) "={{ `$('Check invite').item.json.reason }}"

    # Strukturiertes Summary (Textkatalog): Person, Rolle als freundlicher Begriff (core.enum.role), Hinweis zum Link.
    $C = "`$('Check invite').item.json"
    $summary = New-HitlSummary -Pos @(660, 0) -Title 'core.hitl.invite_household_member' -Lines @(
        (New-HitlLine 'core.label.person' "$C.full_name")
        (New-HitlLine 'core.label.role'   "$C.role" -Kind enum -Enum 'core.enum.role')
        (New-HitlNote -Key 'core.note.invite_link')
    )

    $gate = Build-CallWorkflow 'Request Approval' @(880, 0) $GateId 'agent.tool_human_approval' `
        ([ordered]@{ summary = "={{ `$('Build Approval Summary').item.json.summary }}"; chat_id = "={{ `$('Start').item.json.chat_id }}" })
    $ifApproved = Build-If 'Approved?' @(1100, 0) "={{ `$json.approved }}" 'true' 'equals' 'boolean'
    $retCancelled = Build-ToolCancelled 'Return cancelled' @(1320, 200) 'the invite_household_member action'

    # Write: fn_invite_household_member re-validiert atomar + armt die Challenge (gibt den Code zurueck).
    $write = Build-Pg 'Run invite (atomic)' @(1320, 0) `
        "=SELECT (r->>'ok')::boolean AS ok, r->>'reason' AS reason, r->>'person_id' AS person_id, r->>'role' AS role, r->>'full_name' AS full_name, r->>'challenge' AS challenge, r->>'expires_at' AS expires_at FROM agent.fn_invite_household_member(`$1::jsonb) AS r;" `
        ([ordered]@{
            chat_id     = '$(''Start'').item.json.chat_id'
            person_name = '$(''Start'').item.json.person_name'
        })
    $ifOk = Build-If 'Write ok?' @(1540, 0) "={{ `$json.ok }}" 'true' 'equals' 'boolean'
    $errFail = Build-ToolError 'Invite failed' @(1760, 200) "={{ `$('Run invite (atomic)').item.json.reason }}"

    # Deep-Link: bot_username zur LAUFZEIT aus core.config (deployment-spezifisch, nicht build-gebacken).
    $botCfg = Build-Pg 'Load bot username' @(1760, 0) `
        "=SELECT value AS bot FROM core.config WHERE category = 'telegram' AND key = 'bot_username';"
    $ret = Build-Return @(1980, 0) @(
        ,@('ok', 'true', 'boolean')
        ,@('person', "={{ `$('Run invite (atomic)').item.json.full_name }}", 'string')
        ,@('role', "={{ `$('Run invite (atomic)').item.json.role }}", 'string')
        ,@('deep_link', "={{ 'https://t.me/' + (`$('Load bot username').item.json.bot || 'your_bot') + '?start=' + `$('Run invite (atomic)').item.json.challenge }}", 'string')
        ,@('expires_at', "={{ `$('Run invite (atomic)').item.json.expires_at }}", 'string')
    )

    $stickyHitl = Build-Sticky 'Doc HITL + Owner-Gate' @(660, -300) `
        'Owner-only Member-Einladung (HITL) + fn_invite_household_member' `
        'Check invite (fn_check_household_invite, READ): Owner-Gate (fn_resolve_sender(chat_id).role==owner) + Person existiert genau einmal im household & ist ungepairt -> sonst ToolError VOR dem HITL (kein Write). Approve -> Run invite (fn_invite_household_member): re-validiert atomar (TOCTOU-sicher) + generiert >=8-alphanum Einmal-Code + ruft fn_arm_pairing_challenge(person_id, role, code). Rückgabe = Deep-Link t.me/<bot>?start=<code> (bot_username zur Laufzeit aus core.config). Decline -> cancelled. Das eigentliche Binden committet später der Owner per callback_query (Member löst ein -> Stage -> Owner-Tap).' 320 560

    $nodes = @($trig, $check, $ifValid, $errInvalid, $summary, $gate, $ifApproved, $retCancelled,
               $write, $ifOk, $errFail, $botCfg, $ret, $stickyHitl)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Check invite' ) ) }
        'Check invite'           = @{ main = @( ,@( E 'Invite valid?' ) ) }
        'Invite valid?'          = @{ main = @(
            @( E 'Build Approval Summary' ),
            @( E 'Invite invalid' )
        ) }
        'Build Approval Summary' = @{ main = @( ,@( E 'Request Approval' ) ) }
        'Request Approval'       = @{ main = @( ,@( E 'Approved?' ) ) }
        'Approved?'              = @{ main = @(
            @( E 'Run invite (atomic)' ),
            @( E 'Return cancelled' )
        ) }
        'Run invite (atomic)'    = @{ main = @( ,@( E 'Write ok?' ) ) }
        'Write ok?'              = @{ main = @(
            @( E 'Load bot username' ),
            @( E 'Invite failed' )
        ) }
        'Load bot username'      = @{ main = @( ,@( E 'Return' ) ) }
    }
    return Build-Workflow 'agent.guide.tool_invite_household_member' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}
