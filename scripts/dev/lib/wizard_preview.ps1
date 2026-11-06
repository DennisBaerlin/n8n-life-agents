#Requires -Version 5.1
# wizard_preview.ps1 -- Vorschau des Einrichtungs-Wizards (provisioning/wizard) ohne echten Server im Browser: Verbraucher
# build_ui_review.ps1 (-Surface wizard, Bilder fuer die Freigabe) und serve_wizard_preview.ps1 (Browser-Bereich der App).
# Die Seiten-Modelle kommen vom ECHTEN Server, den tests/wizard/preview_dump.js im Wegwerf-Container mit den Attrappen
# durchlaeuft (nur erfundene Werte); die Seite selbst ist die echte ui/index.html mit ui/app.css + ui/app.js, nur API-Antworten
# kommen aus dem festgehaltenen Modell (window.WIZARD_PREVIEW). Dot-sourcen; $RepoRoot setzt der Aufrufer.

function Get-WizardPreviewCacheFile([string]$RepoRoot) { Join-Path $RepoRoot '.local\wizard_preview_pages.json' }

# Get-WizardTestImage -- das schlanke Test-Bild (tests/wizard/Dockerfile: Node 24 + bash/jq/curl, kein n8n, belegt keinen
#   Testplatz). Der Name traegt den Hash des Dockerfiles: aendert es sich, wird neu gebaut; sonst nie (kein Netz noetig).
function Get-WizardTestImage([string]$RepoRoot) {
    $df = Join-Path $RepoRoot 'tests\wizard\Dockerfile'
    $hash = (Get-FileHash -Algorithm SHA256 $df).Hash.Substring(0, 12).ToLower()
    # Name je Session (WIZARDTEST_CONTAINER, z. B. di4-wizardtest), damit Aufraeumen nie ein fremdes Bild trifft.
    $repo = if ($env:WIZARDTEST_CONTAINER -match '^[a-z0-9][a-z0-9_.-]*$') { $env:WIZARDTEST_CONTAINER } else { 'lifeagents-wizardtest' }
    $name = "${repo}:$hash"
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    docker image inspect $name *> $null
    $have = $LASTEXITCODE -eq 0
    if (-not $have) {
        Write-Host "  Baue Test-Bild $name (einmalig) ..." -ForegroundColor DarkGray
        docker build -q -t $name -f $df (Split-Path $df) | Out-Null
        $have = $LASTEXITCODE -eq 0
    }
    $ErrorActionPreference = $prev
    if (-not $have) { throw "Test-Bild $name liess sich nicht bauen (Netz fuer apt noetig, einmalig)." }
    $name
}

# Invoke-WizardContainer -- docker run im eigenen Netz (Name = Container + "-net", danach entfernt). Grund: die
#   Paperless-Suche (provisioning/wizard/scan.js) tastet das Netz des Containers ab; im geteilten Standard-Netz fand sie die
#   Paperless-Attrappen paralleler Wizard-Tests anderer Sessions (Ports 8000/8010), der Fall „keiner gefunden“ wurde rot.
#   Gibt die Ausgabe zurueck; $LASTEXITCODE ist der des Containers.
function Invoke-WizardContainer([string]$Container, [string[]]$DockerArgs) {
    $net = "$Container-net"
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        docker network rm $net *> $null
        docker network create $net *> $null
        docker run --rm --name $Container --network $net @DockerArgs
        $code = $LASTEXITCODE
        docker network rm $net *> $null
        $global:LASTEXITCODE = $code
    } finally { $ErrorActionPreference = $prev }
}

# Get-WizardPreviewDump -- Seiten-Modelle neu erzeugen (Docker, ~1 Min) und zwischenspeichern; gibt die Liste zurueck.
function Get-WizardPreviewDump([string]$RepoRoot, [string]$Container = '', [switch]$Cached) {
    $cache = Get-WizardPreviewCacheFile $RepoRoot
    $u8 = [System.Text.UTF8Encoding]::new($false)
    if ($Cached -and (Test-Path $cache)) { return ([System.IO.File]::ReadAllText($cache, $u8) | ConvertFrom-Json).pages }
    $image = Get-WizardTestImage $RepoRoot
    if (-not $Container) { $Container = if ($env:WIZARDTEST_CONTAINER) { "$($env:WIZARDTEST_CONTAINER)-preview" } else { "wizardpreview-$PID" } }
    $json = Invoke-WizardContainer $Container @('--entrypoint', 'node', '-v', "${RepoRoot}:/repo:ro", $image, '/repo/tests/wizard/preview_dump.js')
    $code = $LASTEXITCODE
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
    $model = @{ page = $Entry.page; error = $Entry.error; value = $Entry.value; live = $Entry.live; open = $Entry.open } | ConvertTo-Json -Depth 20 -Compress
    $model = $model.Replace('</', '<\/')
    $stub = "window.WIZARD_PREVIEW = (function () { var m = $model; return { error: m.error, value: m.value, open: m.open, api: function (method, path) { return Promise.resolve(method === 'GET' && path === '/api/state' ? { csrf: 'vorschau', page: m.page } : path === '/api/check' && m.live ? { live: m.live } : { error: 'Vorschau: nichts wird gesendet.' }); } }; })();"
    $width = if ($PhoneWidth -gt 0) { "html { width: ${PhoneWidth}px; }" } else { '' }
    # Bilder (di9, ui/art/): eingebettet wie app.*, fehlen sie, bleibt die Stelle leer
    $artCss = ''; $artJs = ''
    if (Test-Path (Join-Path $ui 'art\art.css')) { $artCss = [System.IO.File]::ReadAllText((Join-Path $ui 'art\art.css'), $u8) }
    if (Test-Path (Join-Path $ui 'art\art.js')) { $artJs = [System.IO.File]::ReadAllText((Join-Path $ui 'art\art.js'), $u8) }
    if ($Scheme -ne 'auto') { $artCss = $artCss.Replace('@media (prefers-color-scheme: dark)', $(if ($Scheme -eq 'dark') { '@media all' } else { '@media not all' })) }
    # Zeichen wie server.js indexHtml(): Kommentar der Datei weg, an jede Stelle <!--mark--> einsetzen
    $mark = [regex]::Replace([System.IO.File]::ReadAllText((Join-Path $ui 'mark.html'), $u8), '^<!--[\s\S]*?-->\s*', '').Trim()
    $shell = $shell.Replace('<!--mark-->', $mark)
    $shell = $shell.Replace('<link rel="stylesheet" href="/app.css">', "<style>$css`n$width</style>")
    $shell = $shell.Replace('<link rel="stylesheet" href="/art.css">', "<style>$artCss</style>")
    $shell = $shell.Replace('<script src="/art.js"></script>', "<script>$artJs</script>")
    $shell.Replace('<script src="/app.js"></script>', "<script>$stub</script><script>$js</script>")
}