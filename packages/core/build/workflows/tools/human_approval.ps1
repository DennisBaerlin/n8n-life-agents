#Requires -Version 5.1
# Dot-gesourct von build_finance_tools.ps1 (Helper + Script-Scope-Creds im Parent-Scope).

# --- 0. tool_human_approval (cross-agent HITL gate) ----------
# Generic Human-in-the-Loop approval gate. Any write-tool calls this BEFORE writing:
# it posts the value summary to the owner via Telegram "Send and Wait for Response"
# (Approve/Disapprove) and returns { approved: bool }. Workflow name has NO .finance —
# it is general agent infrastructure (scope `agent`, like agent.tool_load_context).
# WS-5b — Maker-Checker / Dual-Control. Das Gate ist nicht mehr Owner-only, sondern rollen-bewusst:
# Inputs summary + chat_id (= deterministische, nicht-spoofbare Sender-uid) + approval_tier
# (owner_only|owner_approval|owner_info|self, aus dem approval_matrix-Block des Paket-Manifests je Aufrufer). DREI Zweige
# (s. Overview-Sticky). Member-Pfad NUR bei positiv verifiziertem Nicht-Owner; jeder andere Ausgang sendet
# fix an den Owner ODER blockiert (Sicherheits-Invariante). Resolve-DB-Fehler = harter Stop (kein onError ->
# errorWorkflow alarmiert den Owner, kein Write = fail-closed). limitWaitTime begrenzt den Telegram-Hang.
# Textkatalog: summary ist ein STRUKTUR-Objekt (New-HitlSummary im Tool; ein String nur aus Test-Harnesses), das
# Gate rendert es je Empfaenger in dessen Sprache (Render texts + Compose messages, Sticky 'Doc Texte je Sprache').
function Build-HumanApproval {
    $trig = Build-Trigger @('summary', 'approval_tier')   # chat_id wird von Build-Trigger immer ergaenzt

    $CRED_PG_RO = $CRED_CORE_RO
    $WAIT_MIN   = 10   # limitWaitTime je sendAndWait (Minuten) -> Timeout resumed ohne Approval -> fail-closed

    # --- Texte je Empfaenger (Textkatalog): 'Render texts' holt Sprache/Locale/Texte fuer Owner + ggf. Mitglied
    # (core.fn_hitl_texts, core_ro), 'Compose messages' rendert Summary + Hinweis + Knoepfe je Sprache
    # (Get-HitlComposeJs). Beide OHNE onError -> ein Fehler stoppt das Gate fail-closed (kein Write), wie Resolve.
    # Sie liefern NUR Texte — chatId/approverIds bleiben unten an Resolve sender/$OWNER_CHAT_ID gebunden
    # (New-TelegramSendAndWaitNode bricht den Build, wenn ein Ziel-Ausdruck die Text-Knoten referenziert).
    $render = Build-Pg 'Render texts' @(240, -720) `
        "=SELECT core.fn_hitl_texts(`$1::jsonb) AS r;" `
        ([ordered]@{ summary = '$(''Start'').item.json.summary'; chat_id = 'String($(''Start'').item.json.chat_id || '''')' })
    $render.credentials.postgres = $CRED_PG_RO
    $compose = [ordered]@{
        parameters = [ordered]@{ mode = 'runOnceForEachItem'; jsCode = (Get-HitlComposeJs) }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(460, -720)
        id = (New-Id); name = 'Compose messages'
    }
    $T = "`$('Compose messages').first().json"
    $ownerTxt = @{ Msg = "={{ $T.owner.text }}"; Yes = "={{ $T.owner.approve }}"; No = "={{ $T.owner.cancel }}"; Unauth = "={{ $T.owner.unauthorized }}" }
    $memberTxt = @{ Msg = "={{ $T.member.text }}"; Yes = "={{ $T.member.approve }}"; No = "={{ $T.member.cancel }}"; Unauth = "={{ $T.member.unauthorized }}" }

    # WP-5c: der Member-Send adressiert die KANONISCHE chat_id der via fn_resolve_sender VERIFIZIERTEN Person
    # (sender.chat_id = deren telegram_user_id), nicht die roh eingehende chat_id -> Send-Ziel ist an die
    # aufgeloeste Identitaet ruecksichert (dieser Zweig laeuft nur nach positiver Member-Verifikation).
    # .first() statt .item: zwischen Resolve und Send liegt der Pg-Knoten 'Open pending' (Item-Paarung).
    $memberChat   = "={{ String(`$('Resolve sender').first().json.sender.chat_id) }}"
    # Wer am Member-Send tippen darf: NUR die verifizierte Person (approverIds; leer hiesse jeder). Im Webhook-
    # Kontext ohne Item-Index ausgewertet -> .first(); '-1' (keine echte uid) statt leer = fail-closed.
    $memberApprover = "={{ String(`$('Resolve sender').first().json.sender.chat_id || '-1') }}"
    # Ergebnis eines Sends EXPLIZIT per Name lesen: nach dem Send laeuft 'Close pending', $json ist dann dessen
    # Ausgabe. Defensiv: Timeout -> data leer -> false.
    # Get-ApprovedJs = der EINE approved-Ausdruck (auch fuer Mark approved unten), Get-ApprovedExpr = derselbe als n8n-Ausdruck.
    function Get-ApprovedJs([string]$SendName) { "((`$('$SendName').first().json.data || {}).approved === true)" }
    function Get-ApprovedExpr([string]$SendName) { "={{ $(Get-ApprovedJs $SendName) }}" }

    # --- Karte-offen-Sperre (Fix C, agent.hitl_pending): je Send 'Open pending' davor + 'Close pending' danach.
    # Zeile fuer den URSPRUNGS-Chat der Anfrage (Start.chat_id = message.chat.id des Orchestrators), nicht fuer den
    # Karten-Empfaenger: gesperrt wird die geparkte Unterhaltung. TTL = WAIT_MIN + 6 (Puffer fuer den bekannten
    # Telegram-Send-Haenger). Close LOESCHT NICHT, sondern gibt frei (released + Gnadenfrist $GRACE_MIN): die
    # Kette dahinter antwortet erst noch und schreibt ihr Gedaechtnis; der Orchestrator loescht die Zeile nach
    # seiner Antwort. $OwnExpr = JS-Ausdruck: liegt die Karte im Ursprungs-Chat (true) oder wartet sie auf die
    # Freigabe eines anderen (false -> anderer Hinweistext). Beide onError=continue -> fail-open (Komfort-Sperre).
    $GRACE_MIN = 2
    function New-PendingGuard([string]$SendName, [int[]]$SendPos, [string]$OwnExpr) {
        $open = Build-Pg "Open pending ($SendName)" @(($SendPos[0] - 110), ($SendPos[1] - 150)) `
            "=SELECT agent.fn_create_hitl_pending(`$1::jsonb) AS r;" `
            ([ordered]@{ chat_id = 'String($(''Start'').first().json.chat_id || '''')'; execution_id = '$execution.id'; ttl_minutes = "$($WAIT_MIN + 6)"; own_card = $OwnExpr })
        $open['onError'] = 'continueRegularOutput'
        $close = Build-Pg "Close pending ($SendName)" @(($SendPos[0] + 110), ($SendPos[1] - 150)) `
            "=SELECT agent.fn_set_hitl_pending_released(`$1::jsonb) AS r;" `
            ([ordered]@{ execution_id = '$execution.id'; grace_minutes = "$GRACE_MIN" })
        $close['onError'] = 'continueRegularOutput'
        @{ Open = $open; Close = $close; OpenName = $open.name; CloseName = $close.name }
    }

    # --- Endgueltig bestaetigt (Bot mit Gesicht 2026-10-30): je Erfolgs-Ausgang VOR dem Return ein 'Mark approved (<Return>)'
    # -> agent.fn_set_hitl_pending_approved setzt approved=true fuer ALLE Zeilen dieser Execution (Vier-Augen: Mitglieds- und
    # Owner-Zeile), aber nur, wenn das Ergebnis wirklich approved ist (Ablehnung/Timeout -> kein Aufruf). Leser: der
    # Orchestrator (agent.fn_claim_persona_sticker, Daumen-hoch-Sticker). Vor dem Return, damit dessen Ausgabe der
    # Rueckgabewert des Gates bleibt. onError continue (kosmetisch, nie ein Gate-Abbruch).
    function New-ApprovedMark([string]$ReturnName, [int[]]$Pos, [string]$ApprovedJs) {
        $n = Build-Pg "Mark approved ($ReturnName)" $Pos `
            "=SELECT CASE WHEN (`$1::jsonb)->>'approved' = 'true' THEN agent.fn_set_hitl_pending_approved(`$1::jsonb) END AS r;" `
            ([ordered]@{ execution_id = '$execution.id'; approved = $ApprovedJs })
        $n['onError'] = 'continueRegularOutput'
        $n
    }

    # --- Lange Karten (Telegram-Limit 4096): Compose messages liefert je Text pre = die vorderen Teile ("Teil n/N").
    # Je Send-Pfad VOR dem Karten-Send (und NACH Open pending -> die Sperre steht schon, waehrend die Teile laufen):
    # Has parts? -> Split parts (ein Item je Teil, Items tragen NUR den Text, nie ein Ziel) -> Send parts (sendMessage je
    # Item, Ziel = EXAKT der Ziel-Ausdruck des Karten-Sends) -> Parts sent (Limit 1: die Karte geht genau einmal) -> Karte.
    # Kein onError: scheitert ein Teil, stoppt das Gate (keine Karte, kein Write; die Sperre gibt core.sub_error_notify
    # bzw. die TTL frei). Bekannt: retryOnFail sendet bei einem Telegram-Haenger alle Teile erneut (Doppel moeglich).
    function New-HitlPreSend([string]$SendName, [int[]]$SendPos, [string]$PreExpr, [string]$ChatIdExpr) {
        if ($ChatIdExpr -match 'Render texts|Compose messages') { throw "New-HitlPreSend '$SendName': Ziel darf nie aus den Text-Knoten kommen (Sicherheits-Invariante)" }
        $x = $SendPos[0]; $y = $SendPos[1] + 170
        $has = Build-If "Has parts ($SendName)" @(($x - 330), $y) "={{ (($PreExpr) || []).length > 0 }}" 'true' 'equals' 'boolean'
        $split = [ordered]@{
            parameters = [ordered]@{ mode = 'runOnceForAllItems'; jsCode = "return (($PreExpr) || []).map((part) => ({ json: { part } }));" }
            type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(($x - 220), ($y + 60))
            id = (New-Id); name = "Split parts ($SendName)"
        }
        $send = New-TelegramSendNode "Send parts ($SendName)" @(($x - 110), ($y + 60)) '={{ $json.part }}' -ChatIdExpr $ChatIdExpr
        $limit = [ordered]@{
            parameters = [ordered]@{ maxItems = 1 }
            type = 'n8n-nodes-base.limit'; typeVersion = 1; position = @($x, ($y + 60))
            id = (New-Id); name = "Parts sent ($SendName)"
        }
        @{ Nodes = @($has, $split, $send, $limit); EntryName = $has.name
           Conns = [ordered]@{
               ($has.name)   = @{ main = @( @( E $split.name ), @( E $SendName ) ) }
               ($split.name) = @{ main = @( ,@( E $send.name ) ) }
               ($send.name)  = @{ main = @( ,@( E $limit.name ) ) }
               ($limit.name) = @{ main = @( ,@( E $SendName ) ) }
           } }
    }

    # --- Zweig-Weiche: numerisch? -> Resolve; sonst (Test-Sentinel) -> Owner-Pfad -----------------------
    $numeric = Build-If 'Sender numeric?' @(240, 0) "={{ `$('Start').item.json.chat_id }}" '^[0-9]+$' 'regex' 'string'

    # Resolve unter core_ro; KEIN onError -> DB-Fehler stoppt hart (fail-closed) + errorWorkflow-Alert (B0).
    $resolve = Build-Pg 'Resolve sender' @(460, 120) `
        "=SELECT agent.fn_resolve_sender(((`$1::jsonb)->>'uid')::bigint) AS sender;" `
        ([ordered]@{ uid = '$(''Start'').item.json.chat_id' })
    $resolve.credentials.postgres = $CRED_PG_RO

    $isMember = Build-If 'Is member?' @(680, 120) `
        "={{ `$('Resolve sender').item.json.sender.found === true && `$('Resolve sender').item.json.sender.role !== 'owner' }}" `
        'true' 'equals' 'boolean'

    # --- OWNER-PFAD (Zweig A + B-owner + found:false): ein Tap an den Owner = heutiges Verhalten ---------
    # Gemeinsame Send-Parameter: Katalog-Texte, removeButtons (n8n haengt sonst die fest englische Zeile
    # "✅ Approved by ..." an — die Agent-Antwort nach dem Write ist die Bestaetigung).
    $ownerSend = New-TelegramSendAndWaitNode 'Owner approval' @(680, -160) $ownerTxt.Msg -ChatIdExpr $OWNER_CHAT_ID `
        -ApproveLabel $ownerTxt.Yes -DisapproveLabel $ownerTxt.No -UnauthorizedReply $ownerTxt.Unauth `
        -LimitWaitMinutes $WAIT_MIN
    $retOwner  = Build-Set 'Return owner' @(900, -160) @( ,@('approved', (Get-ApprovedExpr 'Owner approval'), 'boolean') )

    # --- MEMBER-PFAD (Zweig C, nur aus positiver B1-Verifikation), nach approval_tier ------------------
    $tierSwitch = Build-Switch 'Tier switch' @(900, 120) @(
        @{ Left = "={{ `$('Start').item.json.approval_tier }}"; Type = 'string'; Op = 'equals'; Right = 'owner_only';     OutputKey = 'owner_only' }
        @{ Left = "={{ `$('Start').item.json.approval_tier }}"; Type = 'string'; Op = 'equals'; Right = 'owner_approval'; OutputKey = 'owner_approval' }
        @{ Left = "={{ `$('Start').item.json.approval_tier }}"; Type = 'string'; Op = 'equals'; Right = 'owner_info';     OutputKey = 'owner_info' }
        @{ Left = "={{ `$('Start').item.json.approval_tier }}"; Type = 'string'; Op = 'equals'; Right = 'self';           OutputKey = 'self' }
    )
    # owner_only: HARTER BLOCK, kein Send (Plan-/Haushalts-/Einladungs-Tools haben zusaetzlich den DB-Backstop)
    $retBlocked = Build-Set 'Return blocked' @(1140, 0) @(
        ,@('approved', 'false', 'boolean')
        ,@('reason', 'owner_only', 'string')
    )
    # owner_approval (Vier-Augen): Stufe 1 Member bestaetigt -> Stufe 2 Owner gibt frei
    $memberSend = New-TelegramSendAndWaitNode 'Member approval' @(1140, 160) $memberTxt.Msg -ChatIdExpr $memberChat -ApproverIdsExpr $memberApprover `
        -ApproveLabel $memberTxt.Yes -DisapproveLabel $memberTxt.No -UnauthorizedReply $memberTxt.Unauth `
        -LimitWaitMinutes $WAIT_MIN
    $memberOk   = Build-If 'Member approved?' @(1360, 160) (Get-ApprovedExpr 'Member approval') 'true' 'equals' 'boolean'
    $ownerCo    = New-TelegramSendAndWaitNode 'Owner co-approval' @(1580, 120) "={{ $T.owner.stage2 }}" -ChatIdExpr $OWNER_CHAT_ID `
        -ApproveLabel $ownerTxt.Yes -DisapproveLabel $ownerTxt.No -UnauthorizedReply $ownerTxt.Unauth `
        -LimitWaitMinutes $WAIT_MIN
    $retCo      = Build-Set 'Return co-approval' @(1800, 120) @(
        ,@('approved', (Get-ApprovedExpr 'Owner co-approval'), 'boolean')
    )
    # owner_info: Stufe 1 Member bestaetigt -> Einweg-Info an den Owner, approved:true
    $memberSendInfo = New-TelegramSendAndWaitNode 'Member info' @(1140, 380) $memberTxt.Msg -ChatIdExpr $memberChat -ApproverIdsExpr $memberApprover `
        -ApproveLabel $memberTxt.Yes -DisapproveLabel $memberTxt.No -UnauthorizedReply $memberTxt.Unauth `
        -LimitWaitMinutes $WAIT_MIN
    $memberOkInfo   = Build-If 'Member approved (info)?' @(1360, 380) (Get-ApprovedExpr 'Member info') 'true' 'equals' 'boolean'
    $ownerInfo      = New-TelegramSendNode 'Owner info' @(1580, 380) "={{ $T.owner.info }}" -ChatIdExpr $OWNER_CHAT_ID
    $retInfo        = Build-Set 'Return info' @(1800, 380) @( ,@('approved', 'true', 'boolean') )
    # Member lehnt Stufe 1 ab (beide Member-Pfade) -> cancelled, kein Owner-Bother
    $retDeclined = Build-Set 'Return declined' @(1580, 280) @( ,@('approved', 'false', 'boolean') )
    # self: die Person bestaetigt ihre EIGENEN Daten, KEIN Owner-Send (eine Info truege private per_user-Daten zum
    # Owner). Nur fuer Workflows, die ausschliesslich agent.fn_set_own_context_facts rufen (approval_lint (e)).
    $memberSendSelf = New-TelegramSendAndWaitNode 'Member self' @(1140, 600) $memberTxt.Msg -ChatIdExpr $memberChat -ApproverIdsExpr $memberApprover `
        -ApproveLabel $memberTxt.Yes -DisapproveLabel $memberTxt.No -UnauthorizedReply $memberTxt.Unauth `
        -LimitWaitMinutes $WAIT_MIN
    $retSelf        = Build-Set 'Return self' @(1360, 600) @( ,@('approved', (Get-ApprovedExpr 'Member self'), 'boolean') )

    # Karte-offen-Sperre je Send (Positionen relativ zum Send; Verdrahtung unten: Vorgaenger -> Open -> Send -> Close).
    # own_card: Member-Sends gehen an den Ursprungs-Chat (true); 'Owner co-approval' liegt beim Owner, das Mitglied
    # wartet (false); 'Owner approval' ist eigen, wenn der Absender der Owner ist (unbekannter Absender / Sentinel ->
    # false bzw. ohnehin keine Zeile; Resolve sender lief im Sentinel-Zweig nicht -> try/catch).
    $ownIfOwner = '(() => { try { return $(''Resolve sender'').first().json.sender.role === ''owner''; } catch (e) { return false; } })()'
    $pgOwner = New-PendingGuard 'Owner approval'    @(680, -160) $ownIfOwner
    $pgMem   = New-PendingGuard 'Member approval'   @(1140, 160) 'true'
    $pgCo    = New-PendingGuard 'Owner co-approval' @(1580, 120) 'false'
    $pgInfo  = New-PendingGuard 'Member info'       @(1140, 380) 'true'
    $pgSelf  = New-PendingGuard 'Member self'       @(1140, 600) 'true'
    $guards  = @($pgOwner, $pgMem, $pgCo, $pgInfo, $pgSelf)
    # Erfolgs-Ausgaenge: approved-Ausdruck = derselbe wie im Return (Get-ApprovedJs)
    $markOwner = New-ApprovedMark 'Return owner'       @(900, -300) (Get-ApprovedJs 'Owner approval')
    $markCo    = New-ApprovedMark 'Return co-approval' @(1800, -20) (Get-ApprovedJs 'Owner co-approval')
    $markInfo  = New-ApprovedMark 'Return info'        @(1800, 500) 'true'
    $markSelf  = New-ApprovedMark 'Return self'        @(1360, 740) (Get-ApprovedJs 'Member self')

    # Vor-Nachrichten langer Karten je Send (Ziel = dieselbe Variable wie beim Karten-Send).
    $preSends = [ordered]@{
        'Owner approval'    = New-HitlPreSend 'Owner approval'    @(680, -160) "$T.owner.pre"        $OWNER_CHAT_ID
        'Member approval'   = New-HitlPreSend 'Member approval'   @(1140, 160) "$T.member.pre"       $memberChat
        'Owner co-approval' = New-HitlPreSend 'Owner co-approval' @(1580, 120) "$T.owner.stage2_pre" $OWNER_CHAT_ID
        'Member info'       = New-HitlPreSend 'Member info'       @(1140, 380) "$T.member.pre"       $memberChat
        'Member self'       = New-HitlPreSend 'Member self'       @(1140, 600) "$T.member.pre"       $memberChat
        'Owner info'        = New-HitlPreSend 'Owner info'        @(1580, 380) "$T.owner.info_pre"   $OWNER_CHAT_ID
    }

    $stOverview = Build-Sticky 'Doc HITL Dual-Control' @(60, -380) -Header 'Ablauf' `
        'Maker-Checker HITL-Gate (WS-5b)' `
        'Cross-agent. Jeder Write ruft dieses Gate VOR dem Write (Inputs: summary, chat_id, approval_tier). DREI Zweige: (A) chat_id nicht-numerisch [Test-Sentinel] -> OWNER-Pfad. (B) numerisch -> Resolve sender (core_ro, fn_resolve_sender); DB-Fehler = harter Stop (KEIN onError -> errorWorkflow alarmiert den Owner, kein Write = fail-closed). found:true UND role!=owner = VERIFIZIERTES MITGLIED -> Member-Pfad; sonst (owner / found:false) -> OWNER-Pfad (ein Tap, heutiges Verhalten). MEMBER-PFAD nach approval_tier: owner_only -> sofort {approved:false} (KEIN Send; tool_save_plan_section/tool_publish_plan/tool_set_context_facts/tool_invite_household_member haben zusätzlich den DB-Backstop in der fn); owner_approval -> Member bestätigt, DANN Owner gibt frei (Vier-Augen); owner_info -> Member bestätigt + Owner-Info-Send; self -> Member bestätigt seine EIGENEN Daten, KEIN Owner-Send (nur agent.tool_set_own_context_facts: die fn setzt per_user fest, approval_lint (e) prüft es). SICHERHEITS-INVARIANTE: ein Send an einen NICHT-Owner passiert NUR im positiv verifizierten Member-Pfad; jeder andere Ausgang sendet fix an $OWNER_CHAT_ID ODER blockiert. Single-User heute: nur Owner gepairt -> fn_resolve_sender liefert role=owner -> immer OWNER-Pfad (No-Op). approval_tier-Quelle: approval_matrix-Block im Manifest des aufrufenden Pakets (fail-closed-Lint). KNÖPFE: Bestätigen im Chat (chatApproval, beim Deploy entschieden) = callback_data, der Tipp kommt über Telegram -> Orchestrator-Trigger -> /webhook-waiting-telegram (HMAC an diese Execution gebunden); sonst Link-Knöpfe. approverIds je Send = NUR dessen Empfänger (Owner-Sends: Owner-chat_id, Member-Sends: die verifizierte Person) -> ein fremder Tipp setzt nicht fort (Hinweis-Popup), und im Vier-Augen-Pfad beantwortet ein wiederholter Member-Tipp die Owner-Stufe nicht. TEXTE: alle Nachrichten, Knöpfe und das Popup kommen aus Compose messages in der Sprache des jeweiligen Empfängers (Sticky Texte je Sprache); sie bestimmen nie den Empfänger. KARTE-OFFEN-SPERRE: jeder Send ist von Open/Close pending umrahmt (Sticky Karte-offen-Sperre). LANGE KARTEN: vor jedem Send ggf. die Teile 1..N-1 (Sticky Lange Karten).' 420 880

    $stStage2 = Build-Sticky 'Doc Zwei-Send-Risiko' @(1540, -60) -Header 'Ablauf' `
        'Zwei sequentielle Send-and-Wait (owner_approval)' `
        'Der Vier-Augen-Pfad sendet ZWEI sendAndWait nacheinander (Member -> Owner) in EINER Execution -> das bekannte ~3-5min Telegram-Socket-Hang-Fenster (Memory telegram-socket-fix-watch, GH #24007) verdoppelt sich. Mitigation: limitWaitTime=10min an JEDEM sendAndWait -> Timeout resumed OHNE Approval -> data.approved leer -> approved=FALSE (fail-closed, kein Write). Kein Datenverlust (Write erst nach beiden Freigaben). Ein Tipp NACH dem Timeout bewirkt nichts mehr (n8n antwortet 409, der Knopf dreht kurz). Freitext statt Knopf / Karte per Text ersetzen: BACKLOG "Konversationelle HITL-Bestätigung" (Trigger dort).' 360 460

    $stPending = Build-Sticky 'Doc Karte-offen-Sperre' @(-420, -380) -Header 'Ablauf' `
        'Karte-offen-Sperre (agent.hitl_pending, Fix C)' `
        'Problem: solange eine Karte offen ist, parkt n8n die ganze Kette Orchestrator -> Agent -> Tool -> dieses Gate; das Chat-Gedächtnis entsteht erst am Lauf-Ende. Eine Text-/Sprachnachricht startete einen zweiten Lauf ohne die Kartenrunde ("vergessene" Werte, 2026-10-22). Lösung: vor JEDEM sendAndWait legt "Open pending (<Send>)" eine Zeile für den URSPRUNGS-Chat der Anfrage an (agent.fn_create_hitl_pending; Start.chat_id, nicht der Karten-Empfänger: im Vier-Augen-Pfad ist der Mitglieds-Chat gesperrt, nicht der Owner; own_card=false bei der Owner-Stufe -> das Mitglied bekommt "wartet auf Freigabe" statt "tippe dort"). "Close pending (<Send>)" löscht NICHT, sondern gibt nach Tipp/Timeout frei (fn_set_hitl_pending_released: Gnadenfrist 2 Min) - die Kette dahinter antwortet erst noch und schreibt ihr Gedächtnis; der Orchestrator löscht die Zeile nach seiner Antwort (Finish card lock). Der Orchestrator-Pre-Router (Card open check, fn_get_hitl_pending_state) antwortet bei offener Zeile mit festem Hinweis statt einen Agenten zu starten. Ablauf (expires_at = jetzt + WAIT_MIN + 6) ist die Wahrheit: gestoppte/gescheiterte Läufe räumt die TTL bzw. core.sub_error_notify (Freigabe mit Gnadenfrist 0 per execution.id). Beide Knoten onError=continue = fail-open (Effizienz-Sperre, schützt keinen Write). Test-Sentinel (nicht-numerische chat_id) -> keine Zeile. Bekannt: die Sperre greift schon, bevor die Karte sichtbar ist (Telegram-Send-Hänger), und Text in der Sekunde vor dem Insert läuft normal durch. Bewusst OHNE Sperre: sendAndWait-Karten der Finanz-Crons (remind_interest) - hinter ihnen ist keine Unterhaltung geparkt. ENDGÜLTIG BESTÄTIGT (Bot mit Gesicht): vor jedem Erfolgs-Return (owner/co-approval/info/self) setzt Mark approved (<Return>) per agent.fn_set_hitl_pending_approved approved=true für alle Zeilen dieser Execution — nur wenn das Ergebnis approved ist; ein Mitglieds-Tipp mit späterer Owner-Ablehnung, Ablehnung oder Timeout lassen approved leer. Der Orchestrator wählt damit den Daumen-hoch-Sticker (agent.fn_claim_persona_sticker), onError continue. Nach dem Send liest jeder Nachfolger das Ergebnis per Name ($(''<Send>'').first()), weil $json dann die Close-Ausgabe ist.' 420 520

    $stTexts = Build-Sticky 'Doc Texte je Sprache' @(180, -1180) -Header 'Ablauf' `
        'Texte in der Sprache des Empfängers (Textkatalog)' `
        'Render texts (core_ro, core.fn_hitl_texts) liefert je MÖGLICHEM Empfänger Sprache, Intl-Locale und alle Texte: Owner-Sprache über fn_owner_person_id, Mitglied nur bei numerischer chat_id, die zu einem Nicht-Owner auflöst (dieselbe Quelle wie Is member?). Compose messages (Get-HitlComposeJs) rendert daraus das strukturierte Summary des Tools (New-HitlSummary: Keys + typisierte Rohwerte; Beträge/Daten per Intl im Locale) + Hinweis + Knöpfe; ein String-Summary (Test-Harness) geht unverändert durch (über dem Telegram-Limit an Zeilen in Teile geteilt, Sticky Lange Karten). Mitglied bekommt seine Sprache, der Owner (Stufe 2 / Info) seine. Beide Knoten OHNE onError (Fehler = harter Stop, kein Write). SICHERHEIT: die Texte entscheiden NIE über Empfänger oder Tipp-Berechtigung — chatId/approverIds hängen nur an Resolve sender bzw. $OWNER_CHAT_ID (der Builder bricht sonst ab). Nach dem Tipp: removeButtons (n8n schriebe sonst fest englisch "Approved by ..."); die Bestätigung ist die Antwort des Agenten.' 420 420

    $stParts = Build-Sticky 'Doc Lange Karten' @(-420, 180) -Header 'Ablauf' `
        'Lange Karten in Teilen (Telegram-Limit 4096)' `
        'Eine Karte über ~4000 Zeichen (z. B. ein Import mit vielen Einträgen, je Eintrag alle Felder) packt Compose messages in Teile "Teil n/N": Kopf (Titel bzw. "Mitglied X beantragt") in Teil 1, Hinweise + Knopf-Hinweis komplett im letzten Teil; getrennt an Eintrags-Grenzen, notfalls an Zeilen, eine überlange Einzelzeile wird gekürzt. Je Send-Pfad nach Open pending: Has parts? -> Split parts -> Send parts (sendMessage, dasselbe Ziel wie die Karte) -> Parts sent (Limit 1) -> Karte mit den Knöpfen. So wird nie ein Teil ungesehen mitbestätigt. Kurze Karten: Has parts? = nein, alles wie bisher. Scheitert ein Teil: Gate-Stopp (kein Write). Bekannt: bei einem Telegram-Hänger kann retryOnFail Teile doppelt senden.' 380 420

    $nodes = @($trig, $render, $compose, $stTexts, $numeric, $resolve, $isMember,
               $ownerSend, $retOwner,
               $tierSwitch, $retBlocked,
               $memberSend, $memberOk, $ownerCo, $retCo,
               $memberSendInfo, $memberOkInfo, $ownerInfo, $retInfo, $retDeclined,
               $memberSendSelf, $retSelf,
               $markOwner, $markCo, $markInfo, $markSelf,
               $stOverview, $stStage2, $stPending, $stParts) + @($guards | ForEach-Object { $_.Open; $_.Close }) +
             @($preSends.Values | ForEach-Object { $_.Nodes })
    $conns = [ordered]@{
        'Start'            = @{ main = @( ,@( E 'Render texts' ) ) }
        'Render texts'     = @{ main = @( ,@( E 'Compose messages' ) ) }
        'Compose messages' = @{ main = @( ,@( E 'Sender numeric?' ) ) }
        'Sender numeric?'  = @{ main = @(
            @( E 'Resolve sender' ),          # [0] numerisch -> Resolve
            @( E $pgOwner.OpenName )          # [1] nicht-numerisch (Test) -> Owner-Pfad (Open legt fuer den Sentinel keine Zeile an)
        ) }
        'Resolve sender'   = @{ main = @( ,@( E 'Is member?' ) ) }
        'Is member?'       = @{ main = @(
            @( E 'Tier switch' ),             # [0] verifiziertes Mitglied -> Member-Pfad
            @( E $pgOwner.OpenName )          # [1] owner / found:false -> Owner-Pfad
        ) }
        'Owner approval'   = @{ main = @( ,@( E $pgOwner.CloseName ) ) }
        ($pgOwner.CloseName) = @{ main = @( ,@( E $markOwner.name ) ) }
        ($markOwner.name)    = @{ main = @( ,@( E 'Return owner' ) ) }
        'Tier switch'      = @{ main = @(
            @( E 'Return blocked' ),          # [0] owner_only
            @( E $pgMem.OpenName ),           # [1] owner_approval
            @( E $pgInfo.OpenName ),          # [2] owner_info
            @( E $pgSelf.OpenName ),          # [3] self (eigene per_user-Daten, kein Owner-Send)
            @( E 'Return blocked' )           # [4] extra (unbekannter Tier) -> fail-closed Block
        ) }
        'Member self'       = @{ main = @( ,@( E $pgSelf.CloseName ) ) }
        ($pgSelf.CloseName)   = @{ main = @( ,@( E $markSelf.name ) ) }
        ($markSelf.name)      = @{ main = @( ,@( E 'Return self' ) ) }
        'Member approval'  = @{ main = @( ,@( E $pgMem.CloseName ) ) }
        ($pgMem.CloseName)   = @{ main = @( ,@( E 'Member approved?' ) ) }
        'Member approved?' = @{ main = @(
            @( E $pgCo.OpenName ),            # [0] Member ok -> Owner-Stufe 2
            @( E 'Return declined' )          # [1] Member lehnt ab
        ) }
        'Owner co-approval' = @{ main = @( ,@( E $pgCo.CloseName ) ) }
        ($pgCo.CloseName)     = @{ main = @( ,@( E $markCo.name ) ) }
        ($markCo.name)        = @{ main = @( ,@( E 'Return co-approval' ) ) }
        'Member info'       = @{ main = @( ,@( E $pgInfo.CloseName ) ) }
        ($pgInfo.CloseName)   = @{ main = @( ,@( E 'Member approved (info)?' ) ) }
        'Member approved (info)?' = @{ main = @(
            @( E $preSends['Owner info'].EntryName ),   # [0] Member ok -> (Teile) -> Owner-Info + approved:true
            @( E 'Return declined' )                    # [1] Member lehnt ab
        ) }
        'Owner info'        = @{ main = @( ,@( E $markInfo.name ) ) }
        ($markInfo.name)      = @{ main = @( ,@( E 'Return info' ) ) }
    }
    # Open -> (Teile) -> Send je Guard (Name-Suffix = Send-Name).
    foreach ($g in $guards) {
        $send = $g.OpenName -replace '^Open pending \((.+)\)$', '$1'
        $conns[$g.OpenName] = @{ main = @( ,@( E $preSends[$send].EntryName ) ) }
    }
    foreach ($ps in $preSends.Values) { foreach ($k in $ps.Conns.Keys) { $conns[$k] = $ps.Conns[$k] } }
    return Build-Workflow 'agent.tool_human_approval' $nodes $conns @{ Internal = $true }   # intern (Infra/Agent): keine Nutzer-Capability -> kein Katalog-Eintrag
}

