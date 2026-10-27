#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds im Parent-Scope).
#
# --- core.main_app_serve (Mini-App „Übersicht“, docs/package-contract.md §3.12) -------------------------------------
# Der eine HTTP-Eingang der read-only Telegram-Mini-App. Der Menue-Knopf (deploy_workflows.sh _set_bot_menu_buttons)
# oeffnet <WEBHOOK_URL>/webhook/<__APP_PATH__>:
#   GET  -> die Seite packages/core/build/app/index.html (statisch, ohne Daten; der Renderer Get-UiRenderLibJs wird an
#           der Stelle /*__UI_RENDER_LIB__*/ eingesetzt -> EIN Renderer fuer Karten, Berichte und App);
#   POST -> core.fn_app_screen(<Body als Text>): initData-Pruefung, Person, Schalter, Bildschirm — alles in der DB.
# Der Workflow prueft und rechnet nichts. Kein Caddy-Eintrag noetig: /webhook/* leitet der Proxy schon weiter.
function Build-CoreMainAppServe {
    $html = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\build\app\index.html'), $Utf8NoBom)
    $marker = '/*__UI_RENDER_LIB__*/'
    if (-not $html.Contains($marker)) { throw "core.main_app_serve: index.html traegt die Stelle $marker nicht (Renderer)." }
    $html = $html.Replace($marker, (Get-UiRenderLibJs))

    $hook = New-WebhookNode 'App request' @(-620, 200) -Path '__APP_PATH__' -Methods @('GET', 'POST')
    $page = New-RespondNode 'Send page' @(-360, 60) -Kind text -Body $html -Headers ([ordered]@{
        'Content-Type' = 'text/html; charset=utf-8'; 'Cache-Control' = 'no-store'; 'Referrer-Policy' = 'no-referrer' })
    $screen = Build-Pg 'App screen' @(-360, 340) `
        "SELECT core.fn_app_screen((`$1::jsonb)->>'body') AS r;" `
        ([ordered]@{ body = "(typeof `$json.body === 'string' ? `$json.body : JSON.stringify(`$json.body || ''))" })
    # Ein DB-Fehler darf keinen Owner-Alert je Anfrage aus dem Internet ausloesen -> weiter, die Seite zeigt „nicht
    # verfuegbar“ (Send data faellt auf {ok:false, code:'error'} zurueck).
    $screen['onError'] = 'continueRegularOutput'
    $data = New-RespondNode 'Send data' @(-100, 340) -Kind json `
        -Body "={{ (`$json.r && typeof `$json.r === 'object') ? `$json.r : { ok: false, code: 'error' } }}" `
        -Headers ([ordered]@{ 'Content-Type' = 'application/json; charset=utf-8'; 'Cache-Control' = 'no-store' })

    $sticky = Build-Sticky 'Doc: Überblick' @(-660, -300) -Header 'Ablauf' `
        'core.main_app_serve — Mini-App „Übersicht“' `
        'Eingang der read-only Telegram-Mini-App (Knopf „📊 Übersicht“ neben dem Eingabefeld). GET liefert die Seite (index.html, ohne Daten). Die Seite schickt per POST {init_data, screen?, params?} als text/plain; App screen reicht den Body als Text an core.fn_app_screen. Dort passiert alles: Telegram-initData per HMAC prüfen (Schlüssel core.app_secret), Person auflösen, Schalter app.enabled/app.audience, Bildschirm aus core.app_screens aufrufen. Der Workflow prüft und rechnet nichts. Der Pfad ist ein Deploy-Platzhalter, deploy_workflows.sh setzt je Instanz eine geheime Adresse ein (INGRESS_ID_KEY). Kein Caddy-Eintrag nötig: /webhook/* ist schon freigegeben.' 420 420
    $stickySec = Build-Sticky 'Doc: Sicherheit' @(-180, -300) -Header 'Achtung' `
        'Öffentlicher Eingang aus dem Internet' `
        'Jede Anfrage kommt ungeprüft aus dem Internet. Daher: (1) Daten gibt es nur nach bestandener initData-Prüfung in der DB, bei JEDEM Abruf, höchstens 1 h alt. (2) Kein Alarm je Müll-Anfrage: core.fn_app_screen wirft nie, App screen läuft bei einem DB-Fehler weiter (onError), Send data antwortet dann {ok:false}. (3) Keine Ausführungsdaten speichern (saveData*Execution none): initData und Finanzzahlen sollen nicht in der n8n-Historie liegen. (4) Kinder-Sicht und Rollen entscheidet allein die Bildschirm-fn in der DB, nie diese Seite.' 420 380
    $stickySandbox = Build-Sticky 'Doc: Sandkasten' @(300, -300) -Header 'n8n-Eigenheit' `
        'HTML aus einem Webhook läuft im CSP-Sandkasten' `
        'n8n setzt auf jede Webhook-Antwort den Header Content-Security-Policy: sandbox (allow-scripts, aber ohne allow-same-origin; nicht abschaltbar je Workflow). Die Seite hat dadurch einen opaken Ursprung: kein localStorage/Cookie, und ihr fetch an dieselbe Adresse gilt als fremder Ursprung (Origin: null). Darum POST mit Content-Type text/plain (einfache Anfrage ohne Preflight); n8n spiegelt den Origin per Standard-CORS. Den Sandkasten global abzuschalten ist verworfen (CVE-2026-25051). Getestet vom freien App-HTTP-Test.' 420 380

    $nodes = @($hook, $page, $screen, $data, $sticky, $stickySec, $stickySandbox)
    $conns = [ordered]@{
        'App request' = @{ main = @(
            @( E 'Send page' ),    # [0] GET  -> Seite
            @( E 'App screen' )    # [1] POST -> Daten
        ) }
        'App screen'  = @{ main = @( ,@( E 'Send data' ) ) }
    }
    $wf = Build-Workflow 'core.main_app_serve' $nodes $conns
    $wf.settings['saveDataSuccessExecution'] = 'none'
    $wf.settings['saveDataErrorExecution'] = 'none'
    $wf.settings['saveManualExecutions'] = $false
    return $wf
}
