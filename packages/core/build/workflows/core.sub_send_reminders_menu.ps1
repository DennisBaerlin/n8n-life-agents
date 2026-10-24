#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_send_reminders_menu (Roter Faden Paket B, Owner-Entscheid 2026-10-23) -------
# Das /reminders-Menue: EINE Nachricht mit allem, was der Bot von sich aus schickt, samt Zeitplan in Klartext und
# Stand (an/aus), plus je Erinnerung ein Schalt-Knopf. Deterministisch, kein LLM. Muster core.sub_send_onboarding_menu:
# Knopf-STRUKTUR build-time (n8n-Inline-Keyboard = statische fixedCollection, Issue #19955 -> ein Send je Ansicht),
# STAND + TEXTE zur Laufzeit in der Sprache des Betrachters.
#
# Eingang: chat_id. Aufrufer: Orchestrator /reminders|/erinnerungen und der Callback-Zweig nach einem Menue-Tipp
# (rem:on|off:<key>:m -> core.fn_handle_reminder_cb -> route 'reminders' -> dieses Menue neu, mit neuem Stand).
# Ablauf: Start -> Read texts (Texte + Fenster) -> Read reminders (core.fn_reminders_overview(chat_id)); beide core_ro, fail-open
#   -> Build menu (Code) -> Which view? (Owner | Mitglied) -> Send owner menu | Send member menu.
# Sichtbarkeit: der Owner sieht alle Erinnerungen der Registry (Haushalt + Person + Pflicht), ein Mitglied nur die
# Person-Erinnerungen (Haushalt schaltet und bekommt der Owner). Pflicht-Erinnerungen (mandatory) und nicht
# installierte Pakete tragen einen Knopf, den der Handler mit einem Toast ablehnt (Knopf-Anzahl ist build-time).
# Registry-Liste build-time aus den Manifest-cron_labels-Bloecken (list/person/mandatory) aller Pakete, Core zuerst.
function Build-CoreSubSendRemindersMenu {
    $CRED_PG_RO = $CRED_CORE_RO

    $u8 = New-Object System.Text.UTF8Encoding($false)
    $ITEMS = @()
    $mfs = @(Get-ChildItem (Join-Path $RepoRoot 'packages\*\manifest.json') | ForEach-Object {
        [pscustomobject]@{ Name = (Split-Path (Split-Path $_.FullName -Parent) -Leaf); Path = $_.FullName } } |
        Sort-Object @{ Expression = { if ($_.Name -eq 'core') { 0 } else { 1 } } }, Name)
    foreach ($m in $mfs) {
        $mj = [System.IO.File]::ReadAllText($m.Path, $u8) | ConvertFrom-Json
        if (-not $mj.cron_labels) { continue }
        $pkg = [string]$mj.name
        foreach ($k in @($mj.cron_labels.list)) { if ($k) { $ITEMS += [ordered]@{ key = [string]$k; package = $pkg; scope = 'household'; mandatory = $false } } }
        if ($mj.cron_labels.person) {
            foreach ($p in $mj.cron_labels.person.PSObject.Properties) {
                if ($p.Name -ne '_comment') { $ITEMS += [ordered]@{ key = $p.Name; package = $pkg; scope = 'person'; mandatory = $false } }
            }
        }
        foreach ($k in @($mj.cron_labels.mandatory)) { if ($k) { $ITEMS += [ordered]@{ key = [string]$k; package = $pkg; scope = 'household'; mandatory = $true } } }
    }
    $labelKeys = @($ITEMS | ForEach-Object { "$($_.package).cron.$($_.key).label" })
    $menuKeys = @(
        'core.reminders.title', 'core.reminders.intro_owner', 'core.reminders.intro_member', 'core.reminders.state_on',
        'core.reminders.state_off', 'core.reminders.mandatory', 'core.reminders.not_installed', 'core.reminders.for_you',
        'core.reminders.window', 'core.reminders.monitor_note', 'core.reminders.empty', 'core.reminders.sched_daily',
        'core.reminders.sched_weekdays', 'core.reminders.sched_monthly', 'core.reminders.sched_quarterly',
        'core.reminders.sched_custom', 'core.reminders.load_failed'
    )

    $start = [ordered]@{
        parameters  = [ordered]@{ workflowInputs = [ordered]@{ values = @( [ordered]@{ name = 'chat_id' } ) } }
        type        = 'n8n-nodes-base.executeWorkflowTrigger'
        typeVersion = 1.1
        position    = @(-840, 0)
        id          = (New-Id)
        name        = 'Start'
    }

    # Texte in der Sprache des Betrachters + Erinnerungs-Fenster, getrennt vom Stand: scheitert nur der Stand, bleibt
    # der Lesefehler-Hinweis lesbar. Muster core.sub_send_onboarding_menu (core.fn_ui_texts + Sprach-Kette;
    # core.fn_ui_texts_for ist für core_ro nicht freigegeben). fail-open.
    $readTexts = Build-Pg 'Read texts' @(-620, 0) `
        ("=SELECT core.fn_ui_texts(agent.fn_person_lang(agent.fn_resolve_sender(CASE WHEN (`$1::jsonb)->>'chat_id' ~ '^[0-9]{1,18}$' " +
         "THEN ((`$1::jsonb)->>'chat_id')::bigint END)->>'person_id')->>'lang', $(Get-UiKeysSql ($labelKeys + $menuKeys))) AS t, " +
         "COALESCE((SELECT value FROM core.config WHERE category = 'general' AND key = 'reminders_from'), '10') AS win_from, " +
         "COALESCE((SELECT value FROM core.config WHERE category = 'general' AND key = 'reminders_until'), '20') AS win_until;") `
        ([ordered]@{ chat_id = "`$('Start').item.json.chat_id" })
    $readTexts.credentials = @{ postgres = $CRED_PG_RO }
    $readTexts['onError'] = 'continueRegularOutput'

    # Stand (DEFINER-Fenster, Sicht des Betrachters); fail-open.
    $read = Build-Pg 'Read reminders' @(-400, 0) `
        "=SELECT core.fn_reminders_overview((`$1::jsonb)->>'chat_id') AS ov;" `
        ([ordered]@{ chat_id = "`$('Start').item.json.chat_id" })
    $read.credentials = @{ postgres = $CRED_PG_RO }
    $read['onError'] = 'continueRegularOutput'

    # Text + Knopf-Beschriftungen + Callback je Erinnerung. Emoji per fromCodePoint (kein Emoji-Literal im .ps1):
    # an = U+1F514, aus = U+1F515, Pflicht = U+1F512. Zeitplan-Klartext aus dem Cron-Ausdruck (m h dom mon dow).
    $buildJs = @'
const ITEMS = __ITEMS_JSON__;
const NL = String.fromCharCode(10);
let ov = $json.ov; if (typeof ov === 'string') { try { ov = JSON.parse(ov); } catch (e) { ov = {}; } } ov = ov || {};
const TX = $('Read texts').item.json;
let T = TX.t; if (typeof T === 'string') { try { T = JSON.parse(T); } catch (e) { T = {}; } } T = T || {};
const tx = (k, p) => { let s = String(T[k] || k); for (const n of Object.keys(p || {})) { s = s.split('{' + n + '}').join(String(p[n])); } return s; };
const ON = String.fromCodePoint(0x1F514), OFF = String.fromCodePoint(0x1F515), LOCK = String.fromCodePoint(0x1F512);
const owner = ov.viewer_role === 'owner';
const rec = {}; for (const r of (Array.isArray(ov.reminders) ? ov.reminders : [])) { rec[r.key] = r; }
const pad = (n) => (String(n).length < 2 ? '0' : '') + String(n);
const sched = (expr) => {
  const f = String(expr || '').trim().split(/\s+/);
  if (f.length !== 5 || !/^\d+$/.test(f[0]) || !/^\d+$/.test(f[1])) { return expr ? tx('core.reminders.sched_custom', { expr }) : ''; }
  const time = pad(f[1]) + ':' + pad(f[0]);
  if (f[2] === '*' && f[3] === '*' && f[4] === '*') return tx('core.reminders.sched_daily', { time });
  if (f[2] === '*' && f[3] === '*' && f[4] === '1-5') return tx('core.reminders.sched_weekdays', { time });
  if (f[2] !== '*' && f[3] === '*' && f[4] === '*') return tx('core.reminders.sched_monthly', { days: f[2].split(',').join('./'), time });
  if (f[2] !== '*' && /^(1,4,7,10|2,5,8,11|3,6,9,12)$/.test(f[3]) && f[4] === '*') return tx('core.reminders.sched_quarterly', { days: f[2].split(',').join('./'), time });
  return tx('core.reminders.sched_custom', { expr });
};
// Lesefehler (fail-open): ehrlicher Hinweis statt einer falschen Sicht (sonst saehe der Owner die Mitglieder-Ansicht
// mit lauter "nicht installiert").
if (ov.ok !== true) {
  return { json: { text: tx('core.reminders.title') + NL + NL + tx('core.reminders.load_failed'), failed: true, btn: {}, cb: {}, owner: false, chat_id: $('Start').item.json.chat_id } };
}
const lines = [tx('core.reminders.title'), '', tx(owner ? 'core.reminders.intro_owner' : 'core.reminders.intro_member'), ''];
const btn = {}, cb = {};
let shown = 0;
for (const it of ITEMS) {
  const r = rec[it.key];
  const label = tx(it.package + '.cron.' + it.key + '.label') + ((owner && it.scope === 'person') ? ' (' + tx('core.reminders.for_you') + ')' : '');
  cb[it.key] = 'rem:' + ((r && r.enabled) ? 'off' : 'on') + ':' + it.key + ':m';
  if (!owner && it.scope !== 'person') { continue; }
  if (!r || r.active === false) {
    btn[it.key] = label + ' - ' + tx('core.reminders.not_installed');
    lines.push(OFF + ' ' + btn[it.key]);
    continue;
  }
  shown++;
  const s = sched(r.schedule);
  if (r.mandatory) {
    btn[it.key] = LOCK + ' ' + label + ': ' + tx('core.reminders.mandatory');
    lines.push(LOCK + ' ' + label + (s ? ' - ' + s : '') + ' - ' + tx('core.reminders.mandatory'));
  } else {
    const st = r.enabled ? tx('core.reminders.state_on') : tx('core.reminders.state_off');
    btn[it.key] = (r.enabled ? ON : OFF) + ' ' + label + ': ' + st;
    lines.push((r.enabled ? ON : OFF) + ' ' + label + (s ? ' - ' + s : '') + ' - ' + st);
  }
}
if (shown === 0) { lines.push(tx('core.reminders.empty')); }
lines.push('', tx('core.reminders.window', { from: TX.win_from || '10', until: TX.win_until || '20' }));
if (owner) { lines.push(tx('core.reminders.monitor_note')); }
return { json: { text: lines.join(NL), btn, cb, owner, chat_id: $('Start').item.json.chat_id } };
'@
    function ConvertTo-JsArray($objs) { $objs = @($objs); if ($objs.Count -eq 0) { return '[]' }; if ($objs.Count -eq 1) { return '[' + ($objs | ConvertTo-Json -Compress) + ']' }; return ($objs | ConvertTo-Json -Compress) }
    $buildJs = $buildJs.Replace('__ITEMS_JSON__', (ConvertTo-JsArray $ITEMS))
    $build = [ordered]@{
        parameters  = [ordered]@{ jsCode = $buildJs; mode = 'runOnceForEachItem' }
        type        = 'n8n-nodes-base.code'
        typeVersion = 2
        position    = @(-180, 0)
        id          = (New-Id)
        name        = 'Build menu'
    }

    $chatExpr = "={{ String(`$('Start').item.json.chat_id) }}"
    # Lesefehler -> nur der ehrliche Hinweis (ohne Knoepfe), keine falsche Sicht.
    $ifFailed = Build-If 'Load failed?' @(40, 0) '={{ $json.failed === true }}' 'true' 'equals' 'boolean'
    $sendFailed = New-TelegramSendNode 'Send load failed' @(260, 220) '={{ $json.text }}' -ChatIdExpr $chatExpr
    $ifOwner = Build-If 'Owner view?' @(260, 0) '={{ $json.owner === true }}' 'true' 'equals' 'boolean'
    $btnFor = { param($it) @{ Text = "={{ (`$json.btn || {})['$($it.key)'] || '$($it.package).cron.$($it.key).label' }}"; Data = "={{ (`$json.cb || {})['$($it.key)'] || 'rem:on:$($it.key):m' }}" } }
    $ownerRows = @($ITEMS | ForEach-Object { ,@( (& $btnFor $_) ) })
    $memberRows = @($ITEMS | Where-Object { $_.scope -eq 'person' } | ForEach-Object { ,@( (& $btnFor $_) ) })
    $sendOwner = New-TelegramInlineKeyboardSendNode 'Send owner menu' @(480, -120) '={{ $json.text }}' -Rows $ownerRows -ChatIdExpr $chatExpr
    $sendMember = New-TelegramInlineKeyboardSendNode 'Send member menu' @(480, 120) '={{ $json.text }}' -Rows $memberRows -ChatIdExpr $chatExpr

    $sticky = Build-Sticky 'Überblick' @(-860, -380) -Header 'Ablauf' `
        'core.sub_send_reminders_menu — /reminders: alle Erinnerungen mit Zeitplan und Schalter (deterministisch, kein LLM)' `
        'Start (chat_id) -> Read texts (Texte in der Sprache des Betrachters über core.fn_ui_texts + Sprach-Kette wie das Onboarding-Menü, dazu das Erinnerungs-Fenster general.reminders_from..until; eigener Schritt, damit der Lesefehler-Hinweis lesbar bleibt) -> Read reminders (core.fn_reminders_overview = Sicht des Betrachters: Owner alle Erinnerungen, Mitglied nur die eigenen Person-Erinnerungen; enabled = Notschalter cron_enable bzw. für Person-Erinnerungen core.fn_reminder_allowed; schedule = core.config schedule.<key>); beide core_ro, fail-open -> Build menu (Zeile je Erinnerung: Glocke an/aus bzw. Schloss = Pflicht, Name aus <pkg>.cron.<key>.label, Zeitplan in Klartext aus dem Cron-Ausdruck (täglich/werktags/monatlich/vierteljährlich, sonst der Ausdruck selbst), Stand; Knopf-Callback rem:off|on:<key>:m je nach Stand) -> Load failed? (Lesefehler -> Send load failed: nur Hinweis core.reminders.load_failed) -> Owner view? -> Send owner menu (Knopf je Registry-Eintrag, build-time aus den Manifest-cron_labels list/person/mandatory) bzw. Send member menu (nur Person-Erinnerungen). Ein Tipp läuft über den Registry-Handler core.fn_handle_reminder_cb (Haushalt nur Owner -> core.fn_set_cron_enable, Person -> eigene agent.reminder_prefs, Pflicht -> Toast) und liefert route reminders -> der Orchestrator sendet dieses Menü mit dem neuen Stand erneut (bei uns anders: neu senden statt editMessageText, Muster Onboarding-Menü). Knopf-Anzahl build-time (n8n #19955): nicht installierte Pakete zeigen nicht installiert, ihr Tipp gibt einen Toast.' 400 820

    $nodes = @($start, $readTexts, $read, $build, $ifFailed, $sendFailed, $ifOwner, $sendOwner, $sendMember, $sticky)
    $conns = [ordered]@{
        'Start'          = @{ main = @( ,@( E 'Read texts' ) ) }
        'Read texts'     = @{ main = @( ,@( E 'Read reminders' ) ) }
        'Read reminders' = @{ main = @( ,@( E 'Build menu' ) ) }
        'Build menu'     = @{ main = @( ,@( E 'Load failed?' ) ) }
        'Load failed?'   = @{ main = @( @( E 'Send load failed' ), @( E 'Owner view?' ) ) }
        'Owner view?'    = @{ main = @( @( E 'Send owner menu' ), @( E 'Send member menu' ) ) }
    }
    return Build-Workflow 'core.sub_send_reminders_menu' $nodes $conns
}
