#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_send_cost_report (/costs + /kosten, Owner-Wunsch 2026-10-25) --------------------------------------------
# Die KI-Kostenuebersicht: EINE Nachricht mit den Claude-Kosten der letzten 7 und 30 Tage, je Assistent (Workflow),
# Modell und Kostenart, plus regelbasierte Auffaelligkeiten. Deterministisch, kein LLM -> der Befehl kostet selbst nichts.
# Muster core.sub_send_reminders_menu (Texte in der Sprache des Betrachters, core_ro-Reads fail-open, Sub sendet selbst).
#
# Eingang: chat_id. Aufrufer: Orchestrator /costs|/kosten.
# Ablauf: Start -> Read texts (core_ro) -> Read cursor (core.fn_import_llm_usage rows:[] = nur der Cursor, + Rolle) -> Owner?
#   (Mitglied -> direkt Read report) -> Fetch usage
#   (GET 127.0.0.1:8090/__usage, blaettert per Pagination) -> Import usage (je Seite core.fn_import_llm_usage) -> Read report
#   (core.fn_get_llm_cost_report, core_ro, einmal) -> Build message (nur Formatierung) -> Send cost report (HTML, Tabellen <pre>).
# Rechnen tut nur die DB (Preise aus agent.ai_models); das Owner-Gate sitzt in der fn, ein Mitglied bekommt core.toast.owner_only.
# Versand: ein einzelner HTML-Send statt New-TelegramRelayChain — die Nachricht hat eine feste, kurze Form (hoechstens Top 5 +
# Sonstige, wenige Modelle, ~1.500 Zeichen << 3.500) und wird nie geteilt; die Relay-Kette escapt fuer LLM-Text und kann
# keine <pre>-Tabellen. Jeder Wert aus der DB wird in Build message HTML-escapt.
function Build-CoreSubSendCostReport {
    $CRED_PG_RO = $CRED_CORE_RO

    $msgKeys = @(
        'core.cost.title', 'core.cost.d7', 'core.cost.change', 'core.cost.d30', 'core.cost.coverage', 'core.cost.by_workflow',
        'core.cost.by_model', 'core.cost.col_7', 'core.cost.col_30', 'core.cost.other', 'core.cost.kinds',
        'core.cost.kind.input', 'core.cost.kind.cache_write', 'core.cost.kind.cache_read', 'core.cost.kind.output',
        'core.cost.kind.web_search', 'core.cost.kind.keepalive', 'core.cost.insights', 'core.cost.cold_starts',
        'core.cost.top_day', 'core.cost.cache_hit', 'core.cost.unpriced', 'core.cost.footer', 'core.cost.empty',
        'core.cost.load_failed', 'core.toast.owner_only'
    )

    $start = [ordered]@{
        parameters  = [ordered]@{ workflowInputs = [ordered]@{ values = @( [ordered]@{ name = 'chat_id' } ) } }
        type        = 'n8n-nodes-base.executeWorkflowTrigger'
        typeVersion = 1.1
        position    = @(-840, 0)
        id          = (New-Id)
        name        = 'Start'
    }

    # Texte + Locale in der Sprache des Betrachters (Sprach-Kette wie das Erinnerungs-Menue) + die Anzeige-Namen der
    # Workflows: jedes Paket darf in seinem Katalog <pkg>.wf.<kurzname> fuehren (kurzname = Workflow-Name ohne agent./core.,
    # Punkte -> _); fehlt er, zeigt die Nachricht den Kurznamen. Eigener Schritt, damit der Lesefehler-Hinweis lesbar bleibt.
    $readTexts = Build-Pg 'Read texts' @(-620, 0) `
        ("=SELECT core.fn_ui_texts(l.lang, $(Get-UiKeysSql $msgKeys)) AS t, " +
         "(SELECT u.locale FROM core.ui_languages u WHERE u.code = l.lang) AS locale, " +
         "(SELECT COALESCE(jsonb_object_agg(s.key, s.text), '{}'::jsonb) FROM (SELECT DISTINCT ON (x.key) x.key, x.text " +
         "FROM core.ui_texts x WHERE x.key LIKE '%.wf.%' AND x.lang IN (l.lang, 'en') ORDER BY x.key, (x.lang = l.lang) DESC) s) AS wf_labels " +
         "FROM (SELECT agent.fn_person_lang(agent.fn_resolve_sender(CASE WHEN (`$1::jsonb)->>'chat_id' ~ '^[0-9]{1,18}$' " +
         "THEN ((`$1::jsonb)->>'chat_id')::bigint END)->>'person_id')->>'lang' AS lang) l;") `
        ([ordered]@{ chat_id = "`$('Start').item.json.chat_id" })
    $readTexts.credentials = @{ postgres = $CRED_PG_RO }
    $readTexts['onError'] = 'continueRegularOutput'

    # Cursor fuer den Abruf: juengste Zeile minus 10 Min als 13-stellige ms (die fn rechnet; rows:[] importiert nichts) +
    # Vorab-Rolle: nur fuer den Owner lohnt Abruf + Import (das verbindliche Gate bleibt core.fn_get_llm_cost_report).
    $readCursor = Build-Pg 'Read cursor' @(-400, 0) `
        ("=SELECT core.fn_import_llm_usage('{`"rows`":[]}'::jsonb)->>'after' AS after, " +
         "COALESCE(agent.fn_resolve_sender(CASE WHEN (`$1::jsonb)->>'chat_id' ~ '^[0-9]{1,18}$' THEN ((`$1::jsonb)->>'chat_id')::bigint END)->>'role', '') = 'owner' AS is_owner;") `
        ([ordered]@{ chat_id = "`$('Start').item.json.chat_id" })
    $readCursor['onError'] = 'continueRegularOutput'
    $ifOwner = Build-If 'Owner?' @(-290, 0) '={{ $json.is_owner === true }}' 'true' 'equals' 'boolean'

    # Gateway-Mitschrift seitenweise (Seite = ein Item); faellt der Abruf aus, rechnet der Bericht mit dem DB-Stand.
    $fetch = [ordered]@{
        parameters = [ordered]@{
            url = 'http://127.0.0.1:8090/__usage'   # lokaler LLM-Gateway (provisioning/llm_gateway), nur 127.0.0.1
            sendQuery = $true
            queryParameters = [ordered]@{ parameters = @(
                [ordered]@{ name = 'after'; value = "={{ `$json.after || '' }}" },
                [ordered]@{ name = 'limit'; value = '5000' }
            ) }
            options = [ordered]@{
                timeout = 30000
                pagination = [ordered]@{ pagination = [ordered]@{
                    paginationMode = 'updateAParameterInEachRequest'
                    parameters = [ordered]@{ parameters = @( ,([ordered]@{ type = 'qs'; name = 'after'; value = '={{ $response.body.next_after }}' }) ) }
                    paginationCompleteWhen = 'other'
                    completeExpression = '={{ $response.body.has_more !== true }}'
                    limitPagesFetched = $true
                    maxRequests = 40
                } }
            }
        }
        type = 'n8n-nodes-base.httpRequest'; typeVersion = 4.2; position = @(-180, 0)
        id = (New-Id); name = 'Fetch usage'
        retryOnFail = $true; maxTries = 2; waitBetweenTries = 1000
        onError = 'continueRegularOutput'
    }

    # Je Seite einspielen (idempotent ueber id). Ein Fehl-Item (Gateway nicht erreichbar) traegt keine rows -> leeres Array
    # -> nichts importiert, der Bericht zeigt den DB-Stand (bewusst still: der Gateway-Ausfall meldet doctor, nicht /kosten).
    $import = Build-Pg 'Import usage' @(40, 0) "=SELECT core.fn_import_llm_usage(jsonb_build_object('rows', (`$1::jsonb)->'rows')) AS r;" `
        ([ordered]@{ rows = "(Array.isArray(`$json.rows) ? `$json.rows : [])" })
    $import['onError'] = 'continueRegularOutput'

    # Bericht einmal (Import liefert ein Item je Seite); DEFINER-Fenster mit Owner-Gate.
    $report = Build-Pg 'Read report' @(260, 0) "=SELECT core.fn_get_llm_cost_report(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id')) AS rep;" `
        ([ordered]@{ chat_id = "`$('Start').first().json.chat_id" })
    $report.credentials = @{ postgres = $CRED_PG_RO }
    $report['onError'] = 'continueRegularOutput'
    $report['executeOnce'] = $true

    # Nur Formatierung (Zahlen + Daten per Intl im Locale des Betrachters), jeder DB-Wert HTML-escapt. Emoji per
    # fromCodePoint (kein Emoji-Literal im .ps1): Geld = U+1F4B0, Gluehbirne = U+1F4A1.
    $buildJs = @'
const NL = String.fromCharCode(10);
const parse = (v) => { if (typeof v === 'string') { try { return JSON.parse(v); } catch (e) { return {}; } } return v || {}; };
const TX = $('Read texts').first().json || {};
const T = parse(TX.t);
const WL = parse(TX.wf_labels);
const loc = TX.locale || 'en-GB';
const tx = (k, p) => { let s = String(T[k] || k); for (const n of Object.keys(p || {})) { s = s.split('{' + n + '}').join(String(p[n])); } return s; };
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const chat = $('Start').first().json.chat_id;
const rep = parse($json.rep);
if (rep.ok !== true) {
  return [{ json: { text: esc(rep.reason === 'owner_only' ? tx('core.toast.owner_only') : tx('core.cost.load_failed')), chat_id: chat } }];
}
const usd = (v) => Number(v || 0).toLocaleString(loc, { style: 'currency', currency: 'USD', currencyDisplay: 'narrowSymbol', minimumFractionDigits: 2, maximumFractionDigits: 2 });
const num = (v) => Number(v || 0).toLocaleString(loc, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const day = (d) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(d || '')); return m ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])).toLocaleDateString(loc, { timeZone: 'UTC', year: 'numeric', month: '2-digit', day: '2-digit' }) : String(d || ''); };
const lines = [String.fromCodePoint(0x1F4B0) + ' <b>' + esc(tx('core.cost.title')) + '</b>', ''];
if (!rep.data_since) {
  lines.push(esc(tx('core.cost.empty')));
  return [{ json: { text: lines.join(NL), chat_id: chat } }];
}
const P7 = (rep.periods || {}).d7 || {}, P30 = (rep.periods || {}).d30 || {};
let l7 = tx('core.cost.d7', { total: usd(P7.total_usd), avg: usd(P7.avg_per_day_usd) });
if (typeof P7.change_pct === 'number') { l7 += ' · ' + tx('core.cost.change', { pct: (P7.change_pct > 0 ? '+' : '') + P7.change_pct }); }
lines.push(esc(l7));
lines.push(esc(tx('core.cost.d30', { total: usd(P30.total_usd), projected: usd(P30.projected_month_usd) })));
if (Number(P30.days_covered) < 30) { lines.push('<i>' + esc(tx('core.cost.coverage', { date: day(rep.data_since), days: P30.days_covered })) + '</i>'); }
// Tabellen in <pre> (Festbreite, Handy ~32 Zeichen): Name 15, 7 Tage 7, 30 Tage 8, je ein fester Abstand dazwischen
// (sonst kleben grosse Betraege aneinander)
const cut = (s, n) => { s = String(s); return s.length > n ? s.slice(0, n - 1) + '.' : s + ' '.repeat(n - s.length); };
const lp = (s, n) => { s = String(s); return ' '.repeat(Math.max(0, n - s.length)) + s; };
const row = (a, b, c) => cut(a, 15) + ' ' + lp(b, 7) + ' ' + lp(c, 8);
const table = (title, rows) => {
  const out = [row(title, tx('core.cost.col_7'), tx('core.cost.col_30'))];
  for (const r of rows) { out.push(row(r.label, num(r.d7), num(r.d30))); }
  return '<pre>' + esc(out.join(NL)) + '</pre>';
};
const WLS = {}; for (const k of Object.keys(WL)) { const i = k.indexOf('.wf.'); if (i > 0) { WLS[k.slice(i + 4)] = WL[k]; } }
const wfLabel = (w) => { const s = String(w || '').replace(/^(agent|core)\./, '').replace(/[.-]/g, '_'); return WLS[s] || s; };
const modelLabel = (m) => { const s = String(m || '').replace(/^claude-/, '').replace(/-(\d+)-(\d+)$/, ' $1.$2').replace(/-(\d+)$/, ' $1'); return s.charAt(0).toUpperCase() + s.slice(1); };
const wfRows = (Array.isArray(rep.by_workflow) ? rep.by_workflow : []).map((r) => ({ label: r.other ? tx('core.cost.other') : wfLabel(r.workflow), d7: r.usd_d7, d30: r.usd_d30 }));
const mRows = (Array.isArray(rep.by_model) ? rep.by_model : []).map((r) => ({ label: modelLabel(r.model), d7: r.usd_d7, d30: r.usd_d30 }));
if (wfRows.length) { lines.push('', table(tx('core.cost.by_workflow'), wfRows)); }
if (mRows.length) { lines.push(table(tx('core.cost.by_model'), mRows)); }
const kinds = (Array.isArray(rep.kinds_d7) ? rep.kinds_d7 : []).filter((k) => Number(k.usd) > 0);
if (kinds.length) {
  lines.push('<b>' + esc(tx('core.cost.kinds')) + '</b>');
  lines.push(esc(kinds.map((k) => tx('core.cost.kind.' + k.kind) + ' ' + k.pct + ' %').join(' · ')));
}
const I = rep.insights || {};
const ins = [];
if (Number(I.cold_starts_d7) > 0) { ins.push(tx('core.cost.cold_starts', { n: I.cold_starts_d7, usd: usd(I.cold_start_usd_d7) })); }
if (I.top_day) { ins.push(tx('core.cost.top_day', { date: day(I.top_day), usd: usd(I.top_day_usd) })); }
if (typeof I.cache_hit_pct_d7 === 'number') { ins.push(tx('core.cost.cache_hit', { pct: I.cache_hit_pct_d7 })); }
if (Number(P30.unpriced_requests) > 0) { ins.push(tx('core.cost.unpriced', { n: P30.unpriced_requests })); }
if (ins.length) {
  lines.push('', String.fromCodePoint(0x1F4A1) + ' <b>' + esc(tx('core.cost.insights')) + '</b>');
  for (const s of ins) { lines.push('• ' + esc(s)); }
}
lines.push('', '<i>' + esc(tx('core.cost.footer')) + '</i>');
return [{ json: { text: lines.join(NL), chat_id: chat } }];
'@
    $build = [ordered]@{
        parameters  = [ordered]@{ jsCode = $buildJs; mode = 'runOnceForAllItems' }
        type        = 'n8n-nodes-base.code'
        typeVersion = 2
        position    = @(480, 0)
        id          = (New-Id)
        name        = 'Build message'
    }

    # Text ist upstream fertig gebautes HTML (jeder DB-Wert escapt) -> -NoEscape + parse_mode HTML (workflow_lint-Allowlist).
    $send = New-TelegramSendNode 'Send cost report' @(700, 0) '={{ $json.text }}' -ChatIdExpr "={{ String(`$json.chat_id) }}" -NoEscape -ParseMode 'HTML'

    $sticky = Build-Sticky 'Überblick' @(-860, -420) -Header 'Ablauf' `
        'core.sub_send_cost_report — /costs + /kosten: KI-Kosten der letzten 7 und 30 Tage (deterministisch, kein LLM)' `
        'Start (chat_id) -> Read texts (Texte + Locale in der Sprache des Betrachters über core.fn_ui_texts + Sprach-Kette, dazu alle Anzeige-Namen <pkg>.wf.<kurzname>; core_ro, fail-open) -> Read cursor (core.fn_import_llm_usage mit rows:[] liefert nur den Cursor after = jüngste Zeile bis jetzt minus 10 Min, Überlappung gegen Uhr-Sprünge; dazu die Rolle des Absenders) -> Owner? (nur der Owner löst Abruf + Import aus; ein Mitglied geht direkt zu Read report und bekommt dort den Owner-only-Hinweis) -> Fetch usage (GET 127.0.0.1:8090/__usage?after=..&limit=5000 am lokalen LLM-Gateway, Pagination über next_after bis has_more=false, höchstens 40 Seiten; Gateway nicht erreichbar -> weiter mit dem DB-Stand) -> Import usage (je Seite core.fn_import_llm_usage: idempotent über id, ungültige Zeilen übersprungen, Retention 13 Monate) -> Read report (core.fn_get_llm_cost_report, einmal, core_ro: Owner-Gate in der DB, alle Beträge aus agent.ai_models.pricing_usd_per_mtok, Tage in Haushalts-Zeitzone, Kaltstarts, teuerster Tag, Cache-Trefferquote) -> Build message (nur Formatierung: Intl-Zahlen/-Daten im Locale, Tabellen je Assistent und Modell als <pre>, Kostenarten in Prozent, Auffälligkeiten; jeder DB-Wert HTML-escapt; Mitglied -> core.toast.owner_only, Lesefehler -> core.cost.load_failed, noch keine Daten -> core.cost.empty) -> Send cost report (ein HTML-Send; feste, kurze Form, daher keine Relay-Kette). Die Gateway-Mitschrift kennt den Workflow über eine konstante Kennzeile in der System-Nachricht (Add-LlmWorkflowTag) bzw. den Header x-lifeagents-workflow; der Gateway entfernt beides vor dem Weiterleiten.' 420 820

    $nodes = @($start, $readTexts, $readCursor, $ifOwner, $fetch, $import, $report, $build, $send, $sticky)
    $conns = [ordered]@{
        'Start'         = @{ main = @( ,@( E 'Read texts' ) ) }
        'Read texts'    = @{ main = @( ,@( E 'Read cursor' ) ) }
        'Read cursor'   = @{ main = @( ,@( E 'Owner?' ) ) }
        'Owner?'        = @{ main = @( @( E 'Fetch usage' ), @( E 'Read report' ) ) }
        'Fetch usage'   = @{ main = @( ,@( E 'Import usage' ) ) }
        'Import usage'  = @{ main = @( ,@( E 'Read report' ) ) }
        'Read report'   = @{ main = @( ,@( E 'Build message' ) ) }
        'Build message' = @{ main = @( ,@( E 'Send cost report' ) ) }
    }
    return Build-Workflow 'core.sub_send_cost_report' $nodes $conns
}
