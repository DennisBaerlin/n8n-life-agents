#Requires -Version 5.1
# headless_shot.ps1 -- Bildschirmfoto einer lokalen Seite per Headless-Chrome (sonst Edge). Verbraucher:
# render_app_screenshots.ps1 (Doku-Bilder) und build_ui_review.ps1 (Vorschau-Seite fuer den Owner). Kein Netz, keine DB.
# Headless-Chrome hat eine Mindest-Fensterbreite (~500 px): die Seite wird per CSS auf Handybreite gesetzt und das Bild danach
# zugeschnitten. Dunkel braucht zusaetzlich prefers-color-scheme (-Dark).
Add-Type -AssemblyName System.Drawing

function Get-HeadlessBrowser {
    $b = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
           "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
           "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $b) { throw 'Kein Chrome/Edge gefunden (Headless-Aufnahme).' }
    $b
}

function Get-HeadlessBaseArg([string]$ProfileDir) {
    @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', "--user-data-dir=$ProfileDir", '--virtual-time-budget=3000')
}

# -File: lokale HTML-Datei. -WidthPx/-HeightPx: Ausschnitt in CSS-px. -TrimBottom: gleichfarbigen Rest unter dem Inhalt abschneiden
# (lange Seiten: -HeightPx ist dann die Obergrenze).
function Invoke-HeadlessShot {
    param([Parameter(Mandatory)][string]$File, [Parameter(Mandatory)][string]$Out, [int]$WidthPx = 390, [int]$HeightPx = 790,
          [double]$Scale = 2, [switch]$Dark, [switch]$TrimBottom, [switch]$AllowCut)
    $raw = "$Out.raw.png"
    $profileDir = Join-Path $env:TEMP ('lifeagents_shot_' + [guid]::NewGuid().ToString('N'))
    $scaleText = $Scale.ToString([Globalization.CultureInfo]::InvariantCulture)
    $chromeArgs = @(Get-HeadlessBaseArg $profileDir) + @("--force-device-scale-factor=$scaleText", "--window-size=$([Math]::Max(600, $WidthPx)),$HeightPx", "--screenshot=$raw")
    if ($Dark) { $chromeArgs += '--force-dark-mode' }
    $chromeArgs += ('file:///' + $File.Replace('\', '/'))
    $p = Start-Process -FilePath (Get-HeadlessBrowser) -ArgumentList $chromeArgs -Wait -PassThru -WindowStyle Hidden
    Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -or -not (Test-Path $raw)) { throw "Aufnahme fehlgeschlagen: $Out (Exit $($p.ExitCode))" }
    $src = [System.Drawing.Bitmap]::FromFile($raw)
    try {
        $w = [Math]::Min([int][Math]::Round($Scale * $WidthPx), $src.Width)
        $h = [Math]::Min([int][Math]::Round($Scale * $HeightPx), $src.Height)
        if ($TrimBottom) {
            $base = $src.GetPixel(1, $h - 1).ToArgb()
            $last = $h - 1
            :scan while ($last -gt 0) {
                foreach ($x in 1, [int]($w / 4), [int]($w / 2), [int](3 * $w / 4), ($w - 2)) {
                    if ($src.GetPixel($x, $last).ToArgb() -ne $base) { break scan }
                }
                $last--
            }
            if ($last -ge $h - 1) {
                if (-not $AllowCut) { throw "Seite laenger als $HeightPx px, das Bild waere abgeschnitten: $Out" }
                Write-Host "  [Hinweis] Seite laenger als $HeightPx px, Bild zeigt nur den oberen Teil: $Out" -ForegroundColor Yellow
            }
            $h = [Math]::Min($h, $last + [int](16 * $Scale))
        }
        $dst = $src.Clone([System.Drawing.Rectangle]::new(0, 0, $w, $h), $src.PixelFormat)
        $dst.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
        $dst.Dispose()
    } finally { $src.Dispose() }
    Remove-Item $raw -Force -ErrorAction SilentlyContinue
}

# Sichtbarer Text der Seite nach dem Rendern (fuer den Pruef-Agenten: Jargon, Dopplungen)
function Get-HeadlessText([Parameter(Mandatory)][string]$File) {
    $profileDir = Join-Path $env:TEMP ('lifeagents_shot_' + [guid]::NewGuid().ToString('N'))
    $dump = "$profileDir.dom.txt"   # nie neben der Quelle: die kann im getrackten docs/site/public liegen
    $chromeArgs = @(Get-HeadlessBaseArg $profileDir) + @('--dump-dom', ('file:///' + $File.Replace('\', '/')))
    $noise = "$dump.err"   # Chrome meldet dort Harmloses (Erweiterungen in der Registry), das nur stoert
    $p = Start-Process -FilePath (Get-HeadlessBrowser) -ArgumentList $chromeArgs -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $dump -RedirectStandardError $noise
    Remove-Item $profileDir, $noise -Recurse -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -ne 0 -or -not (Test-Path $dump)) { throw "Text-Aufnahme fehlgeschlagen: $File (Exit $($p.ExitCode))" }
    $dom = [System.IO.File]::ReadAllText($dump, [System.Text.UTF8Encoding]::new($false))
    Remove-Item $dump -Force -ErrorAction SilentlyContinue
    $t = [regex]::Replace($dom, '<(script|style)\b[\s\S]*?</\1>', ' ', 'IgnoreCase')
    $t = [regex]::Replace($t, '</(div|p|li|h[1-6]|section|button|tr|summary|details)>', "`n", 'IgnoreCase')
    $t = [regex]::Replace($t, '<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    (($t -split "`n") | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { $_ }) -join "`n"
}
