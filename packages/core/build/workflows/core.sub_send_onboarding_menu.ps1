#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_send_onboarding_menu (WS-2 Onboarding-UX, arch-challenge R4 Candidate D) -------
# Wiederverwendbare, DETERMINISTISCHE Menue-Render-Mechanik (KEIN LLM, gratis) in zwei Ebenen: UEBERSICHT
# (Haushalt + ein Knopf je Bereich mit Fortschritt + "Weiter" auf den naechsten offenen Abschnitt) bzw. BEREICH
# (nur dessen Abschnitte). Sendet EINMAL an chat_id. Aufgerufen NUR an deterministischen Eintrittspunkten des
# Orchestrators (/onboarding-Command, Bereichs-Knopf onboarding:_area:<package>) bzw. von core.sub_onboarding_progress
# (Roter Faden: nach einem geschlossenen Bereich, DB-gelatcht genau einmal je Uebergang) -> Folge-Turns erreichen diese
# Node nie -> Knopf-Spam strukturell unmoeglich (vgl. ConversationHandler.entry_points;
# Sub statt Guide-intern, weil ein 'sub' eigene Telegram-Sends haben darf — Praezedenz core.sub_error_notify).
#
# Eingang: chat_id, area (leer = Uebersicht). Ablauf:
#   Start -> Read onboarding status (core.fn_onboarding_overview(chat_id) + Menue-Texte in der Sprache des
#            Betrachters, core_ro, fail-open)
#         -> Build menu (Code: Status, Fortschritt, naechster Schritt, Text)
#         -> Which menu? (Switch auf area) -> Send overview | Send area <package> (statisches Inline-Grid je Ansicht).
#
# P1 (Generisches Paket-Onboarding): KEIN finance-Hardcode mehr.
#   - STATUS runtime ueber EINE fn core.fn_onboarding_overview(chat_id) (Core-Haushalt + ALLE aktiven Pakete;
#     loest core_literal #5 ab — fruehere core.fn_onboarding_status('finance')). P2b-1: chat_id durchgereicht ->
#     per_user-Pakete (career) zeigen den Status der TAPPENDEN Person (DEFINER loest sie intern auf, nie LLM).
#   - Button-STRUKTUR build-time generisch ueber ALLE Pakete: Core-Haushalt + packages/<pkg>/onboarding/
#     sections.json in $OnboardingPackageOrder (abgeleitete Abhaengigkeits-Reihenfolge; ein neues Onboarding-Paket
#     erscheint ohne Edit).
#     n8n-Inline-Keyboard = statische fixedCollection (Button-ANZAHL nicht laufzeit-dynamisch) -> die Struktur ist
#     build-time (alle Pakete sind build-time bekannt), STATUS + TEXT sind runtime. callback_data =
#     onboarding:<package>:<key> (P1-Encoding; der Orchestrator routet auf das <package>-Glied).
#   - TEXTE (Textkatalog Phase B, docs/package-contract.md §3.11): Abschnitts-Labels <pkg>.onboarding.<key> (Haushalt
#     core.onboarding.household), Bereichsnamen <pkg>.package.name und alle Menue-Saetze core.onboarding.menu.* kommen
#     als t-Map in der Sprache des Betrachters (Person -> Owner -> en); build-time steht nur die Key-Liste fest.
function Build-CoreSubSendOnboardingMenu {
    $CRED_PG_RO = $CRED_CORE_RO

    # --- Sektions-Liste (build-time): Core-Haushalt zuerst, dann die Pakete in Onboarding-Reihenfolge
    # ($OnboardingPackageOrder aus build.ps1 = abgeleitet aus den consumes-Abhaengigkeiten: wer Daten eines anderen
    # Pakets liest, kommt danach), je Paket nach ord. groupKey = Katalog-Key des Paketnamens (Ueberschrift im
    # Menue-Text); der Haushalt hat keine Gruppe (eine Zeile, immer vorn).
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $SECTIONS = @( [ordered]@{ package = 'core'; key = 'household'; labelKey = 'core.onboarding.household'; groupKey = '' } )
    foreach ($op in $OnboardingPackageOrder) {
        $sf   = Join-Path $RepoRoot "packages\$($op.Package)\onboarding\sections.json"
        $secs = ([System.IO.File]::ReadAllText($sf, $u8) | ConvertFrom-Json) | Sort-Object ord
        foreach ($s in $secs) {
            $SECTIONS += [ordered]@{ package = "$($op.Package)"; key = "$($s.key)"; labelKey = "$($op.Package).onboarding.$($s.key)"; groupKey = "$($op.Package).package.name" }
        }
    }
    $menuKeys = @(
        'core.onboarding.menu.owner_note', 'core.onboarding.menu.not_installed', 'core.onboarding.menu.progress',
        'core.onboarding.menu.install_hint', 'core.onboarding.menu.owner_area', 'core.onboarding.menu.wait_household_area',
        'core.onboarding.menu.next', 'core.onboarding.menu.tap_section', 'core.onboarding.menu.area_done',
        'core.onboarding.menu.title', 'core.onboarding.menu.next_in_area', 'core.onboarding.menu.tap_next',
        'core.onboarding.menu.wait_household', 'core.onboarding.menu.all_done', 'core.onboarding.menu.footer_not_installed',
        'core.onboarding.menu.btn_next', 'core.onboarding.menu.btn_wait', 'core.onboarding.menu.btn_all_done',
        'core.onboarding.menu.btn_overview', 'core.onboarding.menu.done_area', 'core.onboarding.menu.skipped_area',
        'core.onboarding.menu.done_everything'
    )
    $textKeys = @($SECTIONS | ForEach-Object { $_.labelKey }) + @($OnboardingPackageOrder | ForEach-Object { "$($_.Package).package.name" }) + $menuKeys

    # --- Start (typisierter Sub-Eingang: chat_id) ---
    $start = [ordered]@{
        parameters  = [ordered]@{ workflowInputs = [ordered]@{ values = @( [ordered]@{ name = 'chat_id' }, [ordered]@{ name = 'area' },
            [ordered]@{ name = 'done_area' }, [ordered]@{ name = 'done_mode' } ) } }
        type        = 'n8n-nodes-base.executeWorkflowTrigger'
        typeVersion = 1.1
        position    = @(-840, 0)
        id          = (New-Id)
        name        = 'Start'
    }

    # --- Read onboarding status (core_ro; fail-open: Lesefehler -> Code zeigt alles offen) ---
    # P2b-1: chat_id durchreichen -> fn_onboarding_overview rendert per_user-Pakete (career) mit dem Status der
    # TAPPENDEN Person (jeder sieht SEINE career-Sektionen; household-Pakete unveraendert). Die DEFINER-fn loest
    # die Person intern aus chat_id auf (NIE LLM). Ohne chat_id wuerden alle per_user-Sektionen 'unknown' zeigen.
    # Textkatalog Phase B: dieselbe Abfrage holt die Menue-Texte (t) in der Sprache des Betrachters (chat_id ->
    # Person -> agent.fn_person_lang; nicht-numerische/Gruppen-chat_id -> Owner-Sprache).
    $read = Build-Pg 'Read onboarding status' @(-620, 0) `
        ("=SELECT core.fn_onboarding_overview((`$1::jsonb)->>'chat_id') AS overview, " +
         "core.fn_ui_texts(agent.fn_person_lang(agent.fn_resolve_sender(CASE WHEN (`$1::jsonb)->>'chat_id' ~ '^[0-9]{1,18}$' " +
         "THEN ((`$1::jsonb)->>'chat_id')::bigint END)->>'person_id')->>'lang', $(Get-UiKeysSql $textKeys)) AS t;") `
        ([ordered]@{ chat_id = "`$('Start').item.json.chat_id" })
    $read.credentials = @{ postgres = $CRED_PG_RO }
    $read['onError'] = 'continueRegularOutput'

    # --- Build menu (Code; runOnceForEachItem -> EIN Objekt, kein Array) ---
    # Zwei Ebenen (Progressive Disclosure statt eines 16-Knopf-Grids): area leer -> UEBERSICHT (Haushalt + ein Knopf
    # je Bereich mit Fortschritt + "Weiter"-Knopf auf den naechsten offenen Abschnitt); area=<package> -> BEREICH
    # (nur dessen Abschnitte + "Zur Uebersicht"). "Als Naechstes" = erster offener, nutzbarer Abschnitt in
    # Menue-Reihenfolge ($SECTIONS) -> der gefuehrte Pfad folgt der abgeleiteten Abhaengigkeits-Reihenfolge.
    # Emoji via String.fromCharCode/fromCodePoint (KEIN Emoji-Literal im .ps1 -> PS-5.1-Encoding-Falle):
    # completed=U+2705, skipped=U+23ED, unknown=U+25FB, naechster Schritt=U+1F449. Status-Map aus
    # overview.sections, gekeyt auf '<package>:<key>'; fehlt der Status (Read-Fehler/Paket inaktiv) -> 'unknown'.
    $buildJs = @'
const SECTIONS = __SECTIONS_JSON__;
const AREAS = __AREAS_JSON__;
const NL = String.fromCharCode(10);
let ov = $json.overview;
if (typeof ov === 'string') { try { ov = JSON.parse(ov); } catch (e) { ov = {}; } }
ov = ov || {};
// Textkatalog Phase B: alle Texte aus der t-Map in der Sprache des Betrachters (Read onboarding status); fehlt ein Key
// (Lesefehler), steht der Key selbst da (sichtbar, kein Crash). Platzhalter {name} wie core.fn_ui_text.
let T = $json.t;
if (typeof T === 'string') { try { T = JSON.parse(T); } catch (e) { T = {}; } }
T = T || {};
const tx = (k, p) => { let s = String(T[k] || k); for (const n of Object.keys(p || {})) { s = s.split('{' + n + '}').join(String(p[n])); } return s; };
const label = (s) => tx(s.labelKey);
const group = (a) => (a && a.groupKey) ? tx(a.groupKey) : '';
const list = Array.isArray(ov.sections) ? ov.sections : [];
const st = {};
for (const s of list) { st[s.package + ':' + s.key] = s.status; }
const EMOJI = {
  completed: String.fromCharCode(0x2705),
  skipped: String.fromCharCode(0x23ED),
  unknown: String.fromCharCode(0x25FB)
};
const POINT = String.fromCodePoint(0x1F449);
// Install-UX-Phase 4: Knoepfe sind build-time (alle Pakete), aber nur aktive Pakete sind nutzbar. Liefert die fn
// active_packages, bekommen Sektionen nicht aktiver Pakete den Zusatz 'nicht installiert' (Tipp -> freundliche
// Antwort ueber agent.sub_dispatch_agent). Lesefehler (kein active_packages) -> KEIN Zusatz (fail-open wie bisher).
const active = (ov.ok === true && Array.isArray(ov.active_packages)) ? ov.active_packages : null;
const usable = (pkg) => pkg === 'core' || active === null || active.includes(pkg);
const statusOf = (s) => st[s.package + ':' + s.key] || 'unknown';
// Mitglieder-Menue: viewer_role (fn_onboarding_overview) != owner -> nur persoenliche Bereiche (per_user) sind 'fuer dich';
// Haushalts-Bereiche richtet der Owner ein (ein Tipp darauf gibt einen Toast, core.fn_handle_onboarding_cb).
// Nur der positiv erkannte Owner bekommt die Owner-Sicht; ein unbekannter Betrachter (z. B. /onboarding in einer
// Gruppe: negative chat_id -> viewer_role null) die eingeschraenkte. Lesefehler (ov.ok fehlt) -> Owner-Sicht wie
// bisher (fail-open; die Rechte prueft ohnehin die DB beim Tipp).
const member = (ov.ok === true) && ov.viewer_role !== 'owner';
const pu = {}; for (const s of list) { if (s.per_user === true) pu[s.package] = true; }
const mine = (pkg) => !member || pu[pkg] === true;
const OWNER_NOTE = ' ' + tx('core.onboarding.menu.owner_note');
const NOT_INST = ' - ' + tx('core.onboarding.menu.not_installed');
// Haushalt-zuerst gilt auch fuer Mitglieder (Core-first-Gate der Paket-Agenten): solange der Owner den Haushalt
// nicht abgeschlossen hat, ist fuer ein Mitglied NICHTS offen -> kein Weiter auf einen Bereich, der sofort mit
// "erst Haushalt" antworten wuerde (sonst Kreis Menue <-> Agent).
const coreOpen = SECTIONS.some(s => s.package === 'core' && statusOf(s) === 'unknown');
const waitOwner = member && coreOpen;
const isOpen = (s) => !waitOwner && usable(s.package) && mine(s.package) && statusOf(s) === 'unknown';
const prog = (pkg) => { const ss = SECTIONS.filter(s => s.package === pkg); return { done: ss.filter(s => statusOf(s) !== 'unknown').length, total: ss.length }; };
const next = SECTIONS.find(isOpen) || null;
const reqArea = String($('Start').item.json.area || '');
const area = AREAS.some(a => a.package === reqArea) ? reqArea : '';
// Der Marker sitzt auf dem Knopf, den der Text als "Als Naechstes" nennt: Uebersicht = global naechster Abschnitt,
// Bereich = naechster offener Abschnitt DIESES Bereichs.
const mark = area ? (SECTIONS.find(s => s.package === area && isOpen(s)) || null) : next;
const btn = {};
for (const s of SECTIONS) {
  btn[s.package + ':' + s.key] = (s === mark ? POINT + ' ' : '') + label(s) + (usable(s.package) ? (mine(s.package) ? '' : OWNER_NOTE) : NOT_INST);
}
const abtn = {};
for (const a of AREAS) {
  const p = prog(a.package);
  abtn[a.package] = !usable(a.package) ? (group(a) + NOT_INST) : (mine(a.package) ? (group(a) + ' (' + p.done + '/' + p.total + ')') : (group(a) + OWNER_NOTE));
}
const lines = [];
if (area) {
  const a = AREAS.find(x => x.package === area);
  const p = prog(area);
  const inst = usable(area);
  lines.push(group(a) + (inst ? ' - ' + tx('core.onboarding.menu.progress', { done: p.done, total: p.total }) : NOT_INST), '');
  for (const s of SECTIONS.filter(x => x.package === area)) { lines.push((EMOJI[statusOf(s)] || EMOJI.unknown) + ' ' + label(s)); }
  lines.push('');
  const n = mark;
  if (!inst) { lines.push(tx('core.onboarding.menu.install_hint')); }
  else if (!mine(area)) { lines.push(tx('core.onboarding.menu.owner_area')); }
  else if (waitOwner) { lines.push(tx('core.onboarding.menu.wait_household_area')); }
  else if (n) { lines.push(POINT + ' ' + tx('core.onboarding.menu.next', { label: label(n) }), tx('core.onboarding.menu.tap_section')); }
  else { lines.push(tx('core.onboarding.menu.area_done')); }
} else {
  // Roter Faden: Aufruf aus core.sub_onboarding_progress nach einem geschlossenen Bereich -> Kopfzeile vor der Uebersicht
  // (done_mode done|skipped|all; Bereichsname aus dem Katalog, Haushalt = Abschnitts-Label). Sonst (/onboarding) ohne.
  const doneArea = String($('Start').item.json.done_area || '');
  const doneMode = String($('Start').item.json.done_mode || '');
  if (doneMode === 'all') {
    lines.push(tx('core.onboarding.menu.done_everything'), '');
  } else if (doneArea) {
    const da = AREAS.find(x => x.package === doneArea);
    const daName = da ? group(da) : (SECTIONS.filter(s => s.package === doneArea).map(label)[0] || doneArea);
    lines.push(tx(doneMode === 'skipped' ? 'core.onboarding.menu.skipped_area' : 'core.onboarding.menu.done_area', { area: daName }), '');
  }
  const use = SECTIONS.filter(s => usable(s.package) && mine(s.package));
  const done = use.filter(s => statusOf(s) !== 'unknown').length;
  lines.push(tx('core.onboarding.menu.title', { done: done, total: use.length }), '');
  for (const s of SECTIONS.filter(x => x.package === 'core')) { lines.push((EMOJI[statusOf(s)] || EMOJI.unknown) + ' ' + label(s) + (mine('core') ? '' : OWNER_NOTE)); }
  let missing = 0;
  for (const a of AREAS) {
    const p = prog(a.package);
    if (!usable(a.package)) { missing++; lines.push(EMOJI.unknown + ' ' + abtn[a.package]); continue; }
    lines.push((p.done >= p.total ? EMOJI.completed : EMOJI.unknown) + ' ' + abtn[a.package]);   // Mitglied: Haushalts-Status nur zur Info
  }
  lines.push('');
  if (next) {
    const ng = group(AREAS.find(x => x.package === next.package));
    lines.push(POINT + ' ' + (ng ? tx('core.onboarding.menu.next_in_area', { label: label(next), area: ng }) : tx('core.onboarding.menu.next', { label: label(next) })));
    lines.push(tx('core.onboarding.menu.tap_next'));
  } else if (waitOwner) {
    lines.push(tx('core.onboarding.menu.wait_household'));
  } else {
    lines.push(tx('core.onboarding.menu.all_done'));
  }
  // Install-UX-Phase 6: ausblenden geht nicht (n8n-Tastatur ist build-time, Issue #19955) -> wenigstens sagen,
  // wie ein 'nicht installiert'-Bereich dazukommt.
  if (missing > 0) {
    lines.push('');
    lines.push(tx('core.onboarding.menu.footer_not_installed'));
  }
}
// Weiter-Knopf (nur Uebersicht): Ziel = naechster offener Abschnitt; alles erledigt -> zurueck zur Uebersicht
// (callback_data darf nicht leer sein, die Knopf-Anzahl ist build-time fest).
const next_text = next ? (POINT + ' ' + tx('core.onboarding.menu.btn_next', { label: label(next) })) : (waitOwner ? tx('core.onboarding.menu.btn_wait') : (EMOJI.completed + ' ' + tx('core.onboarding.menu.btn_all_done')));
const next_cb = next ? ('onboarding:' + next.package + ':' + next.key) : 'onboarding:_area:';
const back_text = tx('core.onboarding.menu.btn_overview');
return { json: { text: lines.join(NL), btn, abtn, next_text, next_cb, back_text, area, chat_id: $('Start').item.json.chat_id } };
'@
    # PS-5.1 ConvertTo-Json kollabiert ein 1-Element-Array zum Objekt -> immer manuell klammern.
    function ConvertTo-JsArray($objs) { $objs = @($objs); if ($objs.Count -eq 0) { return '[]' }; if ($objs.Count -eq 1) { return '[' + ($objs | ConvertTo-Json -Compress) + ']' }; return ($objs | ConvertTo-Json -Compress) }
    $secObjs  = @($SECTIONS | ForEach-Object { [ordered]@{ package = $_.package; key = $_.key; labelKey = $_.labelKey; groupKey = $_.groupKey } })
    $areaObjs = @($OnboardingPackageOrder | ForEach-Object { [ordered]@{ package = $_.Package; groupKey = "$($_.Package).package.name" } })
    $buildJs = $buildJs.Replace('__SECTIONS_JSON__', (ConvertTo-JsArray $secObjs)).Replace('__AREAS_JSON__', (ConvertTo-JsArray $areaObjs))
    $build = [ordered]@{
        parameters  = [ordered]@{ jsCode = $buildJs; mode = 'runOnceForEachItem' }
        type        = 'n8n-nodes-base.code'
        typeVersion = 2
        position    = @(-400, 0)
        id          = (New-Id)
        name        = 'Build menu'
    }

    # --- Which menu? (Switch auf area): je Bereich ein Ausgang -> sein Send, Fallback (extra, ZULETZT) = Uebersicht.
    # Ein Send je Ansicht, weil das n8n-Inline-Keyboard eine statische fixedCollection ist (Knopf-ANZAHL build-time).
    $areaCases = @($OnboardingPackageOrder | ForEach-Object {
        @{ Left = "={{ String(`$json.area || '') }}"; Type = 'string'; Op = 'equals'; Right = $_.Package; OutputKey = $_.Package }
    })
    $switch = Build-Switch 'Which menu?' @(-180, 0) $areaCases

    # --- Send-Nodes (New-TelegramInlineKeyboardSendNode -Rows, ein Knopf je Reihe) ---
    # Text = Ausdruck auf $json.text (der Helfer escapt ihn). Knopf-TEXT = Ausdruck auf die von 'Build menu'
    # berechnete Beschriftung (Marker naechster Schritt, Fortschritt, Zusatz 'nicht installiert'); Ersatz = der
    # Katalog-Key (kein fest deutscher Text). callback_data build-time, nur der Weiter-Knopf ist ein Ausdruck (Ziel =
    # naechster offener Abschnitt). '_area' ist reserviert: ein Paketname beginnt nie mit '_'.
    $chatExpr = "={{ `$('Start').item.json.chat_id }}"
    $sectionBtn = { param($s) $id = "$($s.package):$($s.key)"; @{ Text = "={{ (`$json.btn || {})['$id'] || '$($s.labelKey)' }}"; Data = "onboarding:$id" } }
    $ovRows = @( ,@( @{ Text = '={{ $json.next_text }}'; Data = '={{ $json.next_cb }}' } ) )
    foreach ($s in @($SECTIONS | Where-Object { $_.package -eq 'core' })) { $ovRows += ,@( (& $sectionBtn $s) ) }
    foreach ($op in $OnboardingPackageOrder) {
        $ovRows += ,@( @{ Text = "={{ (`$json.abtn || {})['$($op.Package)'] || '$($op.Package).package.name' }}"; Data = "onboarding:_area:$($op.Package)" } )
    }
    $sendNodes = @()
    $switchOuts = @()
    $y = 200
    foreach ($op in $OnboardingPackageOrder) {
        $rows = @()
        foreach ($s in @($SECTIONS | Where-Object { $_.package -eq $op.Package })) { $rows += ,@( (& $sectionBtn $s) ) }
        $rows += ,@( @{ Text = '={{ $json.back_text }}'; Data = 'onboarding:_area:' } )
        $n = "Send area $($op.Package)"
        $sendNodes += New-TelegramInlineKeyboardSendNode $n @(40, $y) '={{ $json.text }}' -Rows $rows -ChatIdExpr $chatExpr
        $switchOuts += ,@( E $n )
        $y += 200
    }
    $sendNodes += New-TelegramInlineKeyboardSendNode 'Send overview' @(40, 0) '={{ $json.text }}' -Rows $ovRows -ChatIdExpr $chatExpr
    $switchOuts += ,@( E 'Send overview' )   # extra (Fallback ZULETZT) = Uebersicht

    $sticky = Build-Sticky 'Doc: Überblick' @(-860, -360) -Header 'Ablauf' `
        'core.sub_send_onboarding_menu — Onboarding-Menü in zwei Ebenen (deterministisch, KEIN LLM)' `
        'Start (chat_id, area; optional done_area + done_mode aus core.sub_onboarding_progress = Kopfzeile <Bereich> eingerichtet / übersprungen / alles eingerichtet vor der Übersicht, Roter Faden) -> Read onboarding status (core.fn_onboarding_overview(chat_id) + Menütexte als t-Map in der Sprache des Betrachters, core_ro, fail-open) -> Build menu (Code: Status je Abschnitt U+2705 erledigt / U+23ED übersprungen / U+25FB offen, gekeyt auf <package>:<key>; nächster Schritt = erster offener, nutzbarer Abschnitt in Menü-Reihenfolge, markiert mit U+1F449) -> Which menu? (Switch auf area) -> Send overview (area leer: Weiter-Knopf auf den nächsten Abschnitt + Haushalt + ein Knopf je Bereich mit Fortschritt, callback onboarding:_area:<package>) bzw. Send area <package> (nur dessen Abschnitte, callback onboarding:<package>:<key>, plus Zur Übersicht). TEXTE aus dem Textkatalog (Phase B): Abschnitte <pkg>.onboarding.<key> (Haushalt core.onboarding.household), Bereichsnamen <pkg>.package.name, Menüsätze core.onboarding.menu.*; Sprache = die des Betrachters (Person -> Owner -> en). REIHENFOLGE build-time: Haushalt zuerst, dann $OnboardingPackageOrder (Get-OnboardingPackageOrder, lib/agent_routing.ps1: wer per consumes Daten eines anderen Onboarding-Pakets liest, kommt danach; Gleichstand haushaltsweit vor persönlich, dann Name). Aufrufer: /onboarding-Command (area leer), der Orchestrator-Callback onboarding:_area:<package> und core.sub_onboarding_progress (nach einem geschlossenen Bereich, DB-Latch: genau einmal je Übergang) -> nur deterministische Eintrittspunkte, kein Knopf-Spam. Abschnitts-Tap -> Orchestrator-Switch auf das <package>-Glied: core -> agent.guide, Paket -> sein Onboarding-Agent. per_user-Pakete (career) zeigen den Status der TAPPENDEN Person (DEFINER-fn löst sie aus chat_id auf, nie LLM). Knopf-STRUKTUR build-time (n8n-Inline-Keyboard = statische fixedCollection -> ein Send je Ansicht); Knopf-TEXT Ausdruck auf $json.btn/abtn/next_text/back_text -> nicht aktive Pakete (fn active_packages) tragen den Zusatz nicht installiert, eine Fusszeile nennt den Server-Befehl (ausblenden geht nicht, Issue #19955). MITGLIEDER: viewer_role != owner -> nur persönliche Bereiche (per_user je Sektion aus der fn) zählen als offen (Weiter/Als Nächstes/Zähler), Haushalts-Bereiche tragen (richtet der Owner ein); ihre Taps laufen über core.fn_handle_onboarding_cb (Registry, member_permeable) und geben dort einen Toast.' 380 860

    $nodes = @($start, $read, $build, $switch) + $sendNodes + @($sticky)
    $conns = [ordered]@{
        'Start'                  = @{ main = @( ,@( E 'Read onboarding status' ) ) }
        'Read onboarding status' = @{ main = @( ,@( E 'Build menu' ) ) }
        'Build menu'             = @{ main = @( ,@( E 'Which menu?' ) ) }
        'Which menu?'            = @{ main = $switchOuts }
    }

    return Build-Workflow 'core.sub_send_onboarding_menu' $nodes $conns
}
