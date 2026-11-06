#Requires -Version 5.1
# wizard_preview.ps1 -- Vorschau des Einrichtungs-Wizards (provisioning/wizard) ohne echten Server im Browser: Verbraucher
# build_ui_review.ps1 (-Surface wizard, Bilder fuer die Freigabe) und serve_wizard_preview.ps1 (Browser-Bereich der App).
# Die Seiten-Modelle kommen vom ECHTEN Server, den tests/wizard/preview_dump.js im Wegwerf-Container mit den Attrappen
# durchlaeuft (nur erfundene Werte); die Seite selbst ist die echte ui/index.html mit ui/app.css + ui/app.js, nur API-Antworten
# kommen aus dem festgehaltenen Modell (window.WIZARD_PREVIEW). Dot-sourcen; $RepoRoot setzt der Aufrufer.

function Get-WizardPreviewCacheFile([string]$RepoRoot) { Join-Path $RepoRoot '.local\wizard_preview_pages.json' }

# Get-WizardPreviewDump -- Seiten-Modelle neu erzeugen (Docker, ~1 Min) und zwischenspeichern; gibt die Liste zurueck.
function Get-WizardPreviewDump([string]$RepoRoot, [string]$Container = '', [switch]$Cached) {
    $cache = Get-WizardPreviewCacheFile $RepoRoot
    $u8 = [System.Text.UTF8Encoding]::new($false)
    if ($Cached -and (Test-Path $cache)) { return ([System.IO.File]::ReadAllText($cache, $u8) | ConvertFrom-Json).pages }
    $image = @(docker images --format '{{.Repository}}:{{.Tag}}' | Where-Object { $_ -like 'lifeagents-substrate-base:*' } | Select-Object -First 1)[0]
    if (-not $image) { throw 'Kein Image mit Node 24 + bash + jq + curl: erst .\scripts\dev\bootstrap_test_n8n.ps1 -Reset (baut das Basis-Image).' }
    if (-not $Container) { $Container = if ($env:WIZARDTEST_CONTAINER) { "$($env:WIZARDTEST_CONTAINER)-preview" } else { "wizardpreview-$PID" } }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $json = docker run --rm --name $Container --entrypoint node -v "${RepoRoot}:/repo:ro" $image /repo/tests/wizard/preview_dump.js
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0 -or -not $json) { throw "preview_dump.js fehlgeschlagen (Exit $code)." }
    $text = ($json | Select-Object -Last 1)
    New-Item -ItemType Directory -Force -Path (Split-Path $cache) | Out-Null
    [System.IO.File]::WriteAllText($cache, $text, $u8)
    ($text | ConvertFrom-Json).pages
}

# Get-WizardPreviewHtml -- die echte Seite mit eingebettetem CSS/JS und dem festgehaltenen Modell eines Eintrags.
#   -PhoneWidth: Seite auf diese Breite setzen (Handy-Ansicht im 600-px-Fenster der Aufnahme); 0 = Fensterbreite.
#   -Scheme light|dark: Farbschema fest (Aufnahmen), auto = nach dem System (Browser-Bereich).
function Get-WizardPreviewHtml([string]$RepoRoot, $Entry, [int]$PhoneWidth = 0, [ValidateSet('light', 'dark', 'auto')][string]$Scheme = 'auto') {
    $u8 = [System.Text.UTF8Encoding]::new($false)
    $ui = Join-Path $RepoRoot 'provisioning\wizard\ui'
    $shell = [System.IO.File]::ReadAllText((Join-Path $ui 'index.html'), $u8)
    $css = [System.IO.File]::ReadAllText((Join-Path $ui 'app.css'), $u8)
    # Hell/Dunkel fest statt nach dem System (Headless-Chrome folgt sonst dem Windows-Design): die dunkle Regel gilt immer oder nie.
    if ($Scheme -ne 'auto') { $css = $css.Replace('@media (prefers-color-scheme: dark)', $(if ($Scheme -eq 'dark') { '@media all' } else { '@media not all' })) }
    $js = [System.IO.File]::ReadAllText((Join-Path $ui 'app.js'), $u8)
    $model = @{ page = $Entry.page; error = $Entry.error; value = $Entry.value } | ConvertTo-Json -Depth 20 -Compress
    $model = $model.Replace('</', '<\/')
    $stub = "window.WIZARD_PREVIEW = (function () { var m = $model; return { error: m.error, value: m.value, api: function (method, path) { return Promise.resolve(method === 'GET' && path === '/api/state' ? { csrf: 'vorschau', page: m.page } : { error: 'Vorschau: nichts wird gesendet.' }); } }; })();"
    $width = if ($PhoneWidth -gt 0) { "html { width: ${PhoneWidth}px; }" } else { '' }
    $shell = $shell.Replace('<link rel="stylesheet" href="/app.css">', "<style>$css`n$width</style>")
    $shell.Replace('<script src="/app.js"></script>', "<script>$stub</script><script>$js</script>")
}