#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.sub_import_llm_usage ---------------------------------------------------------------------------------------
# Holt die Gateway-Mitschrift (usage.jsonl via GET 127.0.0.1:8090/__usage) ab dem Cursor und spielt sie in core.llm_usage
# ein. EINE Adresse fuer den Abruf: Aufrufer sind core.cron_import_llm_usage (nachts) und core.sub_send_cost_report (/costs).
# Ablauf: Start -> Read cursor (core.fn_import_llm_usage mit rows:[] liefert nur den Cursor) -> Fetch usage (Pagination)
#   -> Import usage (je Seite, idempotent ueber id) -> Summarize ({ok, pages, imported, skipped}).
# Fehlerbehandlung liegt beim Aufrufer: Gateway nicht erreichbar -> der Sub scheitert NICHT (ein Sub-Fehler loeste ueber
# dessen eigenen errorWorkflow einen zweiten Alarm aus, auch bei /costs), sondern liefert {ok:false, reason}. Der Cron macht daraus
# einen Fehler (Stop and Error, ein Alarm), /costs ignoriert es und zeigt den DB-Stand.
function Build-CoreSubImportLlmUsage {
    $start = Build-Trigger @() -Pos @(-840, 0)

    $readCursor = Build-Pg 'Read cursor' @(-620, 0) `
        "=SELECT core.fn_import_llm_usage('{`"rows`":[]}'::jsonb)->>'after' AS after;" `
        $null

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
        type = 'n8n-nodes-base.httpRequest'; typeVersion = 4.2; position = @(-400, 0)
        id = (New-Id); name = 'Fetch usage'
        retryOnFail = $true; maxTries = 3; waitBetweenTries = 2000
        onError = 'continueRegularOutput'
    }

    $import = Build-Pg 'Import usage' @(-180, 0) "=SELECT core.fn_import_llm_usage(jsonb_build_object('rows', (`$1::jsonb)->'rows')) AS r;" `
        ([ordered]@{ rows = "(Array.isArray(`$json.rows) ? `$json.rows : [])" })

    $sumJs = @'
const parse = (v) => { if (typeof v === 'string') { try { return JSON.parse(v); } catch (e) { return {}; } } return v || {}; };
const items = $input.all();
const failed = $('Fetch usage').all().some((i) => i.json && i.json.error);
let imported = 0, skipped = 0;
for (const it of items) { const r = parse(it.json.r); imported += Number(r.imported || 0); skipped += Number(r.skipped || 0); }
if (failed) { return [{ json: { ok: false, reason: 'gateway_unreachable', imported, skipped } }]; }
return [{ json: { ok: true, pages: items.length, imported, skipped } }];
'@
    $sum = [ordered]@{
        parameters = [ordered]@{ jsCode = $sumJs; mode = 'runOnceForAllItems' }
        type = 'n8n-nodes-base.code'; typeVersion = 2; position = @(40, 0)
        id = (New-Id); name = 'Summarize'
    }

    $sticky = Build-Sticky 'Überblick' @(-860, -380) -Header 'Ablauf' `
        'core.sub_import_llm_usage — Gateway-Mitschrift nach core.llm_usage übernehmen' `
        'Start -> Read cursor (core.fn_import_llm_usage mit rows:[] importiert nichts und liefert nur den Cursor after = jüngste Zeile minus 10 Min, Überlappung gegen Uhr-Sprünge) -> Fetch usage (GET 127.0.0.1:8090/__usage?after=..&limit=5000 am lokalen LLM-Gateway, Pagination über next_after bis has_more=false, höchstens 40 Seiten, 3 Versuche; Gateway nicht erreichbar -> onError=continue, der Fehler-Eintrag wandert durch und Summarize meldet ok:false) -> Import usage (je Seite core.fn_import_llm_usage: idempotent über id, ungültige Zeilen übersprungen, Retention 13 Monate) -> Summarize ({ok, pages, imported, skipped} bzw. {ok:false, reason:gateway_unreachable}). Der Sub scheitert bewusst nie selbst: ein Sub-Fehler löste über seinen eigenen Fehler-Workflow einen zweiten Alarm aus, auch bei /costs. Aufrufer: core.cron_import_llm_usage (macht aus ok:false einen Fehler und damit genau einen Alarm) und core.sub_send_cost_report (/costs ignoriert ok:false: bei Gateway-Ausfall zeigt der Bericht den DB-Stand). Die Mitschrift hebt der Gateway nur 62 Tage auf; deshalb der nächtliche Lauf.' 420 640

    $nodes = @($start, $readCursor, $fetch, $import, $sum, $sticky)
    $conns = [ordered]@{
        'Start'       = @{ main = @( ,@( E 'Read cursor' ) ) }
        'Read cursor' = @{ main = @( ,@( E 'Fetch usage' ) ) }
        'Fetch usage' = @{ main = @( ,@( E 'Import usage' ) ) }
        'Import usage' = @{ main = @( ,@( E 'Summarize' ) ) }
    }
    return Build-Workflow 'core.sub_import_llm_usage' $nodes $conns
}
