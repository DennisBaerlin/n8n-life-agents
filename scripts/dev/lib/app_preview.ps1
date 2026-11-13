#Requires -Version 5.1
# app_preview.ps1 -- baut die Mini-App-Seite (packages/core/build/app/index.html) ohne Server als eigenstaendige HTML-Seite:
# echter Renderer (Get-UiRenderLibJs), Texte aus dem Katalog (packages/*/locales/de.json), fetch-Stub, der wie
# core.fn_app_screen antwortet (Navigation + Startseite, dann jeder Bildschirm einzeln) -- aus dem erfundenen Datenmodell
# scripts/dev/lib/app_preview_data.json (Form der echten Handler-Antworten, alle Zustaende, nie echte Daten; Repo
# oeffentlich). Das Telegram-Skript entfaellt (window.Telegram wird gestubbt). Kein Netz, keine DB, kein Container.
# Verbraucher: render_app_screenshots.ps1 (Doku-Bilder) und serve_app_preview.ps1
# (Live-Vorschau im Browser der Claude-Desktop-App). Dot-sourcen nach build_helpers.ps1 (Get-UiRenderLibJs);
# $RepoRoot muss gesetzt sein. Katalog, Datenmodell und Seite werden bei jedem Aufruf frisch gelesen.
# Die Text-Map (ui.t) entsteht wie in agent.fn_ui_texts_for: jeder {kind:'tpl'}-Key im Dokument + jeder Enum-Wert-Key
# <enum>.<wert> + die Shell-Keys des Dispatchers; ein Key, den der Katalog nicht kennt, bricht ab (Tippfehler im Modell).
#   Get-AppPreviewPage -Scheme light|dark [-Width 390] [-ExpandKids] [-NoTransitions]  -> HTML-String
#     -Width         feste CSS-Breite des body in px (Headless-Chrome-Mindestbreite ~500 px), 0 = natuerlich
#     -ExpandKids    klappt die letzte aufklappbare Zeile der Startseite auf (Kinder-Zeile; zeigt das Aufklappen)
#     -NoTransitions keine CSS-Uebergaenge (deterministische Aufnahme)
#     -CalmHome      Startseite ohne Hinweise, nur das gruene "Alles in Ordnung" (Doku-Bild: der Sollzustand, nicht die Alarme)
#     -Screen        oeffnet diesen Reiter (Name aus screens im Datenmodell) statt der Startseite
#     -FullHeight    Tab-Leiste fliesst am Seitenende statt fixiert (Aufnahme ganzer Bildschirme)
# Dunkel gilt unabhaengig vom Geraet: ohne Telegram-Theme haengen die Flaechen an prefers-color-scheme, auf einem hell
# eingestellten Geraet waere sonst nur der Akzent dunkel. Der Stub schaltet die Media-Query dauerhaft ein,
# ohne Farbwerte zu kopieren.

$script:AppPreviewUtf8NoBom = [System.Text.UTF8Encoding]::new($false)
# Shell-Keys wie v_shell in core.fn_app_screen (Titel, Neu laden, Luecke, leer, Summe, Formate) + das ok-Banner (-CalmHome)
$script:AppPreviewShellKeys = @('core.app.title', 'core.app.reload', 'core.app.ask_chat', 'core.app.gap', 'core.app.nothing', 'core.app.sum',
                                'core.fmt.empty', 'core.fmt.default_suffix', 'core.fmt.yes', 'core.fmt.no', 'core.fmt.removed',
                                'core.app.all_good')

function Get-AppPreviewDataText {
    [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'app_preview_data.json'), $script:AppPreviewUtf8NoBom)
}

# Alle Katalog-Keys eines geparsten Dokuments (rekursiv): tpl-Werte und Enum-Wert-Keys
function Get-AppPreviewDocKeys($Node, [System.Collections.Generic.HashSet[string]]$Keys) {
    if ($null -eq $Node) { return }
    if ($Node -is [System.Collections.IList]) { foreach ($x in $Node) { Get-AppPreviewDocKeys $x $Keys }; return }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $kind = $Node.PSObject.Properties['kind']
        if ($kind) {
            if ($kind.Value -eq 'tpl' -and $Node.value -is [string]) { [void]$Keys.Add($Node.value) }
            if ($kind.Value -eq 'enum' -and $Node.enum -is [string] -and $Node.value -is [string]) {
                [void]$Keys.Add($Node.enum + '.' + ([regex]::Replace($Node.value.ToLowerInvariant(), '[^a-z0-9_]+', '_')))
            }
        }
        foreach ($p in $Node.PSObject.Properties) { Get-AppPreviewDocKeys $p.Value $Keys }
    }
}

# Text-Map der Vorschau (eine Adresse: der Katalog) fuer alle Keys des Datenmodells + Shell-Keys
function Get-AppPreviewTexts {
    $cat = @{}
    foreach ($f in 'packages\core\locales\de.json', 'packages\finance\locales\de.json') {
        $j = [System.IO.File]::ReadAllText((Join-Path $RepoRoot $f), $script:AppPreviewUtf8NoBom) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $cat[$p.Name] = $p.Value }
    }
    $keys = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($k in $script:AppPreviewShellKeys) { [void]$keys.Add($k) }
    Get-AppPreviewDocKeys (Get-AppPreviewDataText | ConvertFrom-Json) $keys
    $t = [ordered]@{}
    foreach ($k in ($keys | Sort-Object)) {
        if (-not $cat.ContainsKey($k)) { throw "Text-Key fehlt im Katalog: $k (scripts/dev/lib/app_preview_data.json)" }
        $t[$k] = $cat[$k]
    }
    $t
}

# ui-Block wie der Dispatcher: Sprache, Locale, Texte, Datums-Kurzform [heute - 3 Monate, heute + 9 Monate)
function Get-AppPreviewUiJson {
    $ui = [ordered]@{ lang = 'de'; locale = 'de-DE'; t = (Get-AppPreviewTexts)
                      date_short = [ordered]@{ from = (Get-Date).AddMonths(-3).ToString('yyyy-MM-dd'); to = (Get-Date).AddMonths(9).ToString('yyyy-MM-dd') } }
    $ui | ConvertTo-Json -Depth 10 -Compress
}

function Get-AppPreviewPage {
    param([ValidateSet('light', 'dark')][string]$Scheme = 'light', [int]$Width = 0, [switch]$ExpandKids, [switch]$NoTransitions, [switch]$CalmHome,
          [string]$Screen = '', [switch]$FullHeight)
    $ui = Get-AppPreviewUiJson
    $data = Get-AppPreviewDataText
    # Seite wie im Build (core.main_app_serve) + fetch-Stub statt Server, ohne Telegram-Skript. Hell/Dunkel fest ueber
    # Telegrams colorScheme (data-scheme) statt ueber die Betriebssystem-Einstellung.
    $html = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'packages\core\build\app\index.html'), $script:AppPreviewUtf8NoBom)
    $html = $html.Replace('/*__UI_RENDER_LIB__*/', (Get-UiRenderLibJs))
    $html = [regex]::Replace($html, '<script src="https://telegram\.org/[^"]*"></script>', '')
    if ($Scheme -eq 'dark') {
        if (-not $html.Contains('@media (prefers-color-scheme: dark)')) { throw 'Vorschau: Dunkel-Regel in der Seite nicht gefunden (Get-AppPreviewPage anpassen).' }
        $html = $html.Replace('@media (prefers-color-scheme: dark)', '@media all')
    }
    $css = ''
    # feste Breite: auch die fixierte Tab-Leiste (#tabs: left 0 / right 0 = Fensterbreite) auf die Seitenbreite begrenzen
    if ($Width -gt 0) { $css += "body { width: ${Width}px; } #tabs { right: auto; width: ${Width}px; box-sizing: border-box; } " }
    if ($NoTransitions) { $css += '* { transition: none !important; } ' }
    if ($FullHeight) { $css += '#tabs { position: static; } body.has-tabs { padding-bottom: 12px; } ' }
    $screenIndex = -1
    if ($Screen) {
        $names = @(($data | ConvertFrom-Json).screens | ForEach-Object { $_.screen })
        $screenIndex = [array]::IndexOf($names, $Screen)
        if ($screenIndex -lt 0) { throw "Vorschau: unbekannter Reiter '$Screen' (vorhanden: $($names -join ', '))" }
    }
    $stub = ''
    if ($css) { $stub += "<style>$css</style>" }
    # Antwort-Formen wie core.fn_app_screen: ohne screen {ok, ui, screens, first:{screen, view+banners}}; mit screen
    # {ok, ui, view}; die Startseite traegt die Hinweise, jede andere Seite []; unbekannter Bildschirm -> {ok:false}.
    $stub += "<script>window.Telegram = { WebApp: { colorScheme: '$Scheme', initData: '', openTelegramLink: function () {}, close: function () {}, isVersionAtLeast: function () { return true; } } };" +
             "window.__APP_PREVIEW__ = $data;" +
             "window.__APP_PREVIEW__.ui = $ui;" +
             $(if ($CalmHome) { "window.__APP_PREVIEW__.banners = [{ state: 'ok', icon: 'check', target: null, text: { kind: 'tpl', value: 'core.app.all_good', params: {} } }];" } else { '' }) +
             "window.fetch = function (url, opts) {" +
             "  var D = window.__APP_PREVIEW__, body = {}, resp;" +
             "  try { body = JSON.parse((opts && opts.body) || '{}'); } catch (e) { body = {}; }" +
             "  var home = D.screens[0].screen;" +
             "  var withBanners = function (s) { return Object.assign({}, D.views[s], { banners: s === home ? D.banners : [] }); };" +
             "  if (!body.screen) { resp = { ok: true, ui: D.ui, screens: D.screens, bot: D.bot, first: { screen: home, view: withBanners(home) } }; }" +
             "  else if (D.views[body.screen]) { resp = { ok: true, ui: D.ui, view: withBanners(body.screen) }; }" +
             "  else { resp = { ok: false, code: 'unknown_screen' }; }" +
             "  return Promise.resolve({ ok: true, json: function () { return Promise.resolve(resp); } });" +
             "};"
    # Kinder-Zeile = letzter Toggle der Startseite (der Abschnitt Vermoegen der Kinder steht zuletzt)
    if ($ExpandKids) { $stub += "window.addEventListener('load', function () { setTimeout(function () { var t = document.querySelectorAll('.toggle'); if (t.length) t[t.length - 1].click(); }, 200); });" }
    if ($screenIndex -ge 0) { $stub += "window.addEventListener('load', function () { setTimeout(function () { var t = document.querySelectorAll('.tab'); if (t[$screenIndex]) t[$screenIndex].click(); }, 200); });" }
    $stub += '</script>'
    $html.Replace('<main id="app"', "$stub`n<main id=""app""")
}
