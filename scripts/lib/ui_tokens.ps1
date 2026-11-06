#Requires -Version 5.1
# ui_tokens.ps1 -- geteilte Mechanik der einen Farbquelle config/ui.tokens.json (DTCG-Format, Gruppen light/dark/shape).
# Verbraucher: scripts/build_ui_tokens.ps1 (schreibt die Bloecke), scripts/ui_token_lint.ps1 (prueft sie) und
# scripts/dev/build_ui_review.ps1 (Farben der Vorschau-Seite). Dot-sourcen; $RepoRoot wird als Parameter uebergeben.
#
# Warum markierte Bloecke statt Laufzeit-Datei: Mini-App und Wizard duerfen zur Laufzeit nichts nachladen, die Doku-Seite
# laeuft per file://. Der Block steht committet in der Oberflaechen-Datei, an keiner Auslieferung aendert sich etwas.
#
# Neue Oberflaeche = eine Zeile in Get-UiSurfaces (Block-Ausgabe) und ihre Wurzel in Get-UiScanRoots (Lint).

$script:UiTokensUtf8 = [System.Text.UTF8Encoding]::new($false)

# Oberflaechen mit Block. Rules: Selektor + Token-Gruppe je CSS-Regel, Media = optionale umschliessende Regel (Wizard: ':root' +
# '[data-theme="dark"]'); Tokens: die CSS-Variablen dieser Oberflaeche, Variablenname = Tokenname. Formen haengen nicht an Hell
# oder Dunkel und stehen nur in der ersten Regel. Mini-App: Telegrams Theme hat Vorrang, die Tokens sind ihre Ersatzfarben;
# dunkel gilt ueber die Geraete-Einstellung ODER Telegrams colorScheme (data-scheme), daher zwei Regeln.
function Get-UiSurfaces {
    @(
        [pscustomobject]@{
            Name   = 'site'
            File   = 'docs/site/static/css/site.css'
            Rules  = @([pscustomobject]@{ Selector = ':root'; Group = 'light' })
            Colors = @('ink', 'gray', 'hairline', 'accent', 'accent-hover', 'accent-mid', 'accent-pale', 'bg', 'bg-soft')
            Shape  = @('radius', 'font')
        }
        [pscustomobject]@{
            Name   = 'mini-app'
            File   = 'packages/core/build/app/index.html'
            Rules  = @(
                [pscustomobject]@{ Selector = ':root'; Group = 'light' }
                [pscustomobject]@{ Media = '@media (prefers-color-scheme: dark)'; Selector = ':root:not([data-scheme="light"])'; Group = 'dark' }
                [pscustomobject]@{ Selector = ':root[data-scheme="dark"]'; Group = 'dark' }
            )
            Colors = @('ink', 'gray', 'hairline', 'accent', 'ok', 'warn', 'alert', 'bg', 'bg-soft')
            Shape  = @('radius', 'font')
        }
        # Wizard im Fenster der Start-App: hell/dunkel nach der System-Einstellung. Der QR-Code steht immer auf der hellen
        # Flaeche (.qr = helle Gruppe): nicht jede Kamera-App liest einen invertierten Code.
        [pscustomobject]@{
            Name   = 'wizard'
            File   = 'provisioning/wizard/ui/app.css'
            Rules  = @(
                [pscustomobject]@{ Selector = ':root'; Group = 'light' }
                [pscustomobject]@{ Media = '@media (prefers-color-scheme: dark)'; Selector = ':root'; Group = 'dark' }
                # QR-Code und Nachzeichnungen fremder Oberflächen (di9: FritzBox u. a., die echte Oberfläche ist immer hell).
                [pscustomobject]@{ Selector = '.qr, .art-light'; Group = 'light' }
                # Handy-Bilder (ui/art/, di9): Rahmen immer dunkel, Bildschirm immer hell wie ein Telegram-Chat am Tag.
                [pscustomobject]@{ Selector = '.phone'; Group = 'dark' }
                [pscustomobject]@{ Selector = '.phone .screen'; Group = 'light' }
            )
            Colors = @('ink', 'gray', 'hairline', 'accent', 'accent-hover', 'accent-mid', 'accent-pale', 'accent-wash', 'ok', 'warn', 'warn-wash', 'alert', 'alert-wash', 'bg', 'bg-soft')
            Shape  = @('radius-sm', 'radius', 'radius-pill', 'font')
        }
        # Start-App (Tauri): folgt dem System; data-theme nur fuer die Vorschau (scripts/dev/serve_desktop_preview.ps1).
        [pscustomobject]@{
            Name   = 'desktop'
            File   = 'provisioning/desktop/ui/app.css'
            Rules  = @(
                [pscustomobject]@{ Selector = ':root'; Group = 'light' }
                [pscustomobject]@{ Media = '@media (prefers-color-scheme: dark)'; Selector = ':root:not([data-theme="light"])'; Group = 'dark' }
                [pscustomobject]@{ Selector = ':root[data-theme="dark"]'; Group = 'dark' }
            )
            Colors = @('ink', 'gray', 'hairline', 'accent', 'accent-hover', 'accent-mid', 'accent-pale', 'accent-wash', 'warn', 'warn-wash', 'alert', 'alert-wash', 'bg', 'bg-soft')
            Shape  = @('radius', 'radius-sm', 'radius-pill', 'font', 'font-mono')
        }
    )
}

# Geteilte Bausteine, die mehrere Oberflaechen gleich zeigen (Schritt-Leiste von Start-App und Fragebogen im selben Fenster):
# Quelle unter config/, wortgleich als markierter Block in jede Datei kopiert (gleicher Grund wie bei den Farben: kein Nachladen
# zur Laufzeit, der Fragebogen ist eine fremde Seite ohne Zugriff auf die Dateien der App). Neuer Verbraucher = Pfad in Files.
function Get-UiCopies {
    @(
        [pscustomobject]@{ Source = 'config/ui.steps.js'; Files = @('provisioning/desktop/ui/app.js', 'provisioning/wizard/ui/app.js') }
        [pscustomobject]@{ Source = 'config/ui.steps.css'; Files = @('provisioning/desktop/ui/app.css', 'provisioning/wizard/ui/app.css') }
        # Lese-Hinweis am Hauptknopf (Werte der Leitung, Referenz im Fragebogen).
        [pscustomobject]@{ Source = 'config/ui.nudge.js'; Files = @('provisioning/desktop/ui/app.js', 'provisioning/wizard/ui/app.js') }
        [pscustomobject]@{ Source = 'config/ui.nudge.css'; Files = @('provisioning/desktop/ui/app.css', 'provisioning/wizard/ui/app.css') }    )
}
function Get-UiCopyRegex([string]$Name) {
    [regex]::new('/\* ui-copy:begin ' + [regex]::Escape($Name) + '\b[^\n]*\*/\n[\s\S]*?/\* ui-copy:end \*/')
}
function Get-UiCopyText([string]$RepoRoot, $Copy) {
    $name = Split-Path $Copy.Source -Leaf
    $body = [System.IO.File]::ReadAllText((Join-Path $RepoRoot $Copy.Source), $script:UiTokensUtf8).Replace("`r`n", "`n").TrimEnd("`n")
    "/* ui-copy:begin $name (kopiert von scripts/build_ui_tokens.ps1 aus $($Copy.Source), nicht von Hand aendern) */`n$body`n/* ui-copy:end */"
}

# Texte aus dem Katalog packages/core/locales/<code>.json als Block in eine Oberflaeche ohne Bau-Schritt (Start-App,
# Leitung 2026-11-06: eine Uebersetzungs-Quelle mit Bot und Fragebogen). Je Sprache die Schluessel mit den genannten
# Praefixen, sortiert. Eigenes Serialisieren statt ConvertTo-Json: gleiche Ausgabe unter PowerShell 5.1 und 7.
function Get-UiLocaleBlocks {
    @([pscustomobject]@{ Name = 'desktop'; File = 'provisioning/desktop/ui/app.js'; Prefixes = @('core.art.greeting.', 'core.desktop.', 'core.wizard.step.') })
}
function Get-UiLocaleRegex([string]$Name) {
    [regex]::new('/\* ui-locale:begin ' + [regex]::Escape($Name) + '\b[^\n]*\*/\n[\s\S]*?/\* ui-locale:end \*/')
}
function ConvertTo-UiJsString([string]$Text) {
    $sb = [System.Text.StringBuilder]::new('"')
    foreach ($c in $Text.ToCharArray()) {
        $n = [int]$c
        if ($c -eq '"') { [void]$sb.Append('\"') }
        elseif ($c -eq '\') { [void]$sb.Append('\\') }
        elseif ($n -eq 10) { [void]$sb.Append('\n') }
        elseif ($n -lt 32 -or $n -eq 0x2028 -or $n -eq 0x2029) { [void]$sb.Append(('\u{0:x4}' -f $n)) }
        else { [void]$sb.Append($c) }
    }
    [void]$sb.Append('"')
    $sb.ToString()
}
function Get-UiLocaleText([string]$RepoRoot, $Block) {
    $dir = Join-Path (Join-Path (Join-Path $RepoRoot 'packages') 'core') 'locales'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("/* ui-locale:begin $($Block.Name) (erzeugt von scripts/build_ui_tokens.ps1 aus packages/core/locales, nicht von Hand aendern) */")
    $lines.Add('const UI_TEXT = {')
    foreach ($f in (Get-ChildItem $dir -Filter '*.json' | Sort-Object Name)) {
        $obj = [System.IO.File]::ReadAllText($f.FullName, $script:UiTokensUtf8) | ConvertFrom-Json
        $keys = [string[]]@($obj.PSObject.Properties.Name | Where-Object { $k = $_; @($Block.Prefixes | Where-Object { $k.StartsWith($_, [StringComparison]::Ordinal) }).Count -gt 0 })
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        $lines.Add("  $($f.BaseName): {")
        foreach ($k in $keys) { $lines.Add("    $(ConvertTo-UiJsString $k): $(ConvertTo-UiJsString ([string]$obj.$k)),") }
        $lines.Add('  },')
    }
    $lines.Add('};')
    $lines.Add('/* ui-locale:end */')
    $lines -join "`n"
}

# Wurzeln, unter denen der Lint Farb-Literale sucht. Eine UI-Datei ausserhalb dieser Wurzeln (und ausserhalb von
# Get-UiExcludedPrefixes) ist ein Fehler: so rutscht eine neue Oberflaeche nicht unbemerkt durch.
function Get-UiScanRoots {
    @('docs/site/static/', 'docs/site/layouts/', 'packages/core/build/app/', 'packages/core/build/stickers/', 'provisioning/desktop/ui/', 'provisioning/desktop/preview/', 'provisioning/wizard/ui/', 'config/ui.')
}
# public/ = Hugo-Output der Quellen oben; mods = Erweiterung des Entwickler-Werkzeugs, keine Projekt-Oberflaeche.
function Get-UiExcludedPrefixes { @('docs/site/public/', '.claude/mods/') }
function Get-UiFileExtensions { @('.css', '.html', '.htm', '.vue', '.svelte', '.tsx', '.jsx') }
function Get-UiScanExtensions { @('.css', '.html', '.htm', '.js', '.svg', '.vue', '.svelte', '.tsx', '.jsx') }

# Telegram-Profilbild des Bots: abgeleitet aus dem einen Zeichen und der Farbdatei (rendert scripts/dev/render_bot_profile.ps1,
# prueft scripts/ui_token_lint.ps1). Farben gegenueber der Website getauscht: helles Zeichen auf voller Akzentflaeche, weil die
# runde Anzeige eine volle Flaeche braucht und JPG keine Transparenz kennt. Das Zeichen fuellt knapp die Haelfte der Breite und
# bleibt so auch im kleinen Kreis frei stehen. Vom Zeichen zaehlt nur die Geometrie: jede Farbangabe darin wird hier gesetzt.
function Get-UiBotProfilePaths { @{ Mark = 'config/ui.mark.svg'; Dir = 'packages/core/build/bot_profile'; Jpg = 'bot_profile.jpg'; Sha = 'source.sha256' } }
function Get-UiBotProfileSvg([string]$MarkFile, $Tokens) {
    $size = 640; $markBox = 26; $markSize = 400
    $accent = Get-UiColorHex $Tokens 'light' 'accent'
    $bg = Get-UiColorHex $Tokens 'light' 'bg'
    $paths = @([regex]::Matches([System.IO.File]::ReadAllText($MarkFile, $script:UiTokensUtf8), '<path\s[^>]*/>') | ForEach-Object { $_.Value })
    # Zwei Rollen: Haekchen (var(--bg), var(--mark-check, ...)) in Flaechen-Farbe, alles andere (Koerper) hell.
    $inner = [regex]::Replace(($paths -join "`n"), '"var\(--[^"]*"', {
            param($m)
            if ($m.Value -match '^"var\(--(bg|mark-check)\b') { "`"$accent`"" } else { "`"$bg`"" }
        })
    if ($paths.Count -eq 0 -or -not $inner.Contains($accent) -or -not $inner.Contains($bg) -or $inner.Contains('var(')) {
        throw "Zeichen in $MarkFile nicht erkannt (erwartet: <path>-Zeilen mit Farben als var(--...) fuer Koerper und Haekchen)."
    }
    $offset = ($size - $markSize) / 2
    "<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$size`" height=`"$size`" viewBox=`"0 0 $size $size`"><rect width=`"$size`" height=`"$size`" fill=`"$accent`"/><svg x=`"$offset`" y=`"$offset`" width=`"$markSize`" height=`"$markSize`" viewBox=`"0 0 $markBox $markBox`">$inner</svg></svg>"
}
function Get-UiTextSha256([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { -join ($sha.ComputeHash($script:UiTokensUtf8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
}

# Das eine Zeichen des Projekts: config/ui.mark.svg. Jede Oberflaeche, die es zeigt, uebernimmt die <path>-Zeilen 1:1 (Geometrie,
# Strichbreite, Linienenden); nur die Farben duerfen abweichen (var(...)). Die Site bekommt ihr Partial erzeugt (Get-UiMarkPartialText),
# alle anderen Dateien prueft der Lint (Get-UiMarkProblems) -- ein altes oder abweichendes Zeichen laesst den Commit scheitern.
function Get-UiMarkSourcePath { 'config/ui.mark.svg' }
function Get-UiMarkPartialPath { 'docs/site/layouts/partials/mark.html' }
# Dateien mit einer 26er-SVG, die kein Projekt-Zeichen ist (Begruendung je Eintrag).
function Get-UiMarkExempt { @{ 'docs/site/layouts/partials/phone-frame-close.html' = 'Senden-Knopf des Telegram-Chat-Nachbaus, kein Projekt-Zeichen' } }
function Get-UiMarkPaths([string]$RepoRoot) {
    $svg = [System.IO.File]::ReadAllText((Join-Path $RepoRoot (Get-UiMarkSourcePath)), $script:UiTokensUtf8)
    $svg = [regex]::Replace($svg, '<!--[\s\S]*?-->', '')
    @([regex]::Matches($svg, '<path\s[^>]*/>') | ForEach-Object { $_.Value })
}
# Farben sind nicht Teil der Geometrie: fill/stroke="var(...)" -> "C"; Leerraum vereinheitlicht.
function ConvertTo-UiMarkNorm([string]$Text) {
    $t = [regex]::Replace($Text, '\b(fill|stroke)="var\((?:[^()"]|\([^()"]*\))*\)"', '$1="C"')
    [regex]::Replace($t, '\s+', ' ')
}
function Get-UiMarkPartialText([string[]]$MarkPaths) {
    $l = [System.Collections.Generic.List[string]]::new()
    $l.Add('{{/* Zeichen des Projekts, eine Adresse fuer Menue, Fusszeile und Chat-Nachbau: Sprechblase mit Giebeldach und Haekchen.')
    $l.Add('     Farben umkehrbar ueber --mark und --mark-check (.tg-avatar: weiss auf Petrol).')
    $l.Add('     ERZEUGT aus config/ui.mark.svg von scripts/build_ui_tokens.ps1, nicht von Hand aendern. */}}')
    $l.Add('<svg width="26" height="26" viewBox="0 0 26 26" aria-hidden="true">')
    foreach ($p in $MarkPaths) { $l.Add("  $p") }
    $l.Add('</svg>')
    ($l -join "`n") + "`n"
}
# Funde in einem Dateitext: jede inline-SVG im Zeichen-Kasten (viewBox 0 0 26 26) muss alle Pfade der Quelle tragen.
function Get-UiMarkProblems([string]$Text, [string[]]$MarkPaths) {
    $t = [regex]::Replace($Text, '/\*[\s\S]*?\*/', '')
    $t = [regex]::Replace($t, '<!--[\s\S]*?-->', '')
    $want = @($MarkPaths | ForEach-Object { ConvertTo-UiMarkNorm $_ })
    foreach ($m in [regex]::Matches($t, '<svg\b[^>]*\bviewBox="0 0 26 26"[^>]*>[\s\S]*?</svg>')) {
        $have = ConvertTo-UiMarkNorm $m.Value
        $missing = @($want | Where-Object { -not $have.Contains($_) })
        if ($missing.Count -gt 0) { $m.Value.Substring(0, [Math]::Min(70, $m.Value.Length)) -replace '\s+', ' ' }
    }
}
function Read-UiTokens([string]$RepoRoot) {
    [System.IO.File]::ReadAllText((Join-Path (Join-Path $RepoRoot 'config') 'ui.tokens.json'), $script:UiTokensUtf8) | ConvertFrom-Json
}

function Get-UiColorNames($Tokens, [string]$Group) {
    @($Tokens.$Group.PSObject.Properties | Where-Object { $_.Name -notlike '$*' } | ForEach-Object { $_.Name })
}
function Get-UiColorHex($Tokens, [string]$Group, [string]$Name) {
    $t = $Tokens.$Group.PSObject.Properties[$Name]
    if (-not $t) { throw "Farb-Token fehlt: $Group.$Name" }
    [string]$t.Value.'$value'.hex
}

function Get-UiLuminance([string]$Hex) {
    $h = $Hex.TrimStart('#')
    $channels = 0, 2, 4 | ForEach-Object {
        $c = [Convert]::ToInt32($h.Substring($_, 2), 16) / 255.0
        if ($c -le 0.04045) { $c / 12.92 } else { [Math]::Pow(($c + 0.055) / 1.055, 2.4) }
    }
    0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
}
# Kontrast nach WCAG 2.x (1..21)
function Get-UiContrast([string]$HexA, [string]$HexB) {
    $la = Get-UiLuminance $HexA
    $lb = Get-UiLuminance $HexB
    ([Math]::Max($la, $lb) + 0.05) / ([Math]::Min($la, $lb) + 0.05)
}

# Wert eines Form-Tokens als CSS-Text (dimension {value,unit} oder fontFamily-Liste)
function Get-UiShapeCss($Tokens, [string]$Name) {
    $t = $Tokens.shape.PSObject.Properties[$Name]
    if (-not $t) { throw "Form-Token fehlt: shape.$Name" }
    $v = $t.Value.'$value'
    switch ([string]$t.Value.'$type') {
        'dimension'  { return "$($v.value)$($v.unit)" }
        'fontFamily' { return (@($v) | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ', ' }
        default      { throw "Form-Token shape.$Name hat den unbekannten Typ '$($t.Value.'$type')'" }
    }
}

function Get-UiBlockBegin([string]$Surface) { "/* ui-tokens:begin $Surface (erzeugt von scripts/build_ui_tokens.ps1, nicht von Hand aendern) */" }
$script:UiBlockEnd = '/* ui-tokens:end */'
function Get-UiBlockRegex([string]$Surface) {
    [regex]::new('/\* ui-tokens:begin ' + [regex]::Escape($Surface) + '\b[^\n]*\*/\n[\s\S]*?/\* ui-tokens:end \*/')
}

# Der Block einer Oberflaeche, wie er in ihrer Datei stehen muss
function Get-UiBlockText($Tokens, $Surface) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Get-UiBlockBegin $Surface.Name))
    $first = $true
    foreach ($rule in $Surface.Rules) {
        $media = $rule.PSObject.Properties['Media']
        $pad = if ($media) { '  ' } else { '' }
        if ($media) { $lines.Add("$($media.Value) {") }
        $lines.Add("$pad$($rule.Selector) {")
        foreach ($c in $Surface.Colors) { $lines.Add("$pad  --${c}: $(Get-UiColorHex $Tokens $rule.Group $c);") }
        if ($first) { foreach ($s in $Surface.Shape) { $lines.Add("$pad  --${s}: $(Get-UiShapeCss $Tokens $s);") } }
        $lines.Add("$pad}")
        if ($media) { $lines.Add('}') }
        $first = $false
    }
    $lines.Add($script:UiBlockEnd)
    $lines -join "`n"
}

# Alle Variablen einer Token-Gruppe als CSS-Regel (Vorschau-Seite, ohne Marker)
function Get-UiAllColorsCss($Tokens, [string]$Group, [string]$Selector = ':root') {
    $vars = (Get-UiColorNames $Tokens $Group | ForEach-Object { "--${_}: $(Get-UiColorHex $Tokens $Group $_);" }) -join ' '
    "$Selector { $vars --radius: $(Get-UiShapeCss $Tokens 'radius'); --font: $(Get-UiShapeCss $Tokens 'font'); }"
}

# Feste Farbwerte in einem Text. Erzeugte Bloecke, CSS- und HTML-Kommentare zaehlen nicht; Sprungziele (href="#abc", url(#abc))
# und HTML-Entities (&#123;) sind keine Farben.
$script:UiHexRx = [regex]'(?<![\w&#/-])(?<!href=["''])(?<!url\()#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})(?![0-9a-zA-Z_-])'
$script:UiFuncRx = [regex]'\b(?:rgb|hsl)a?\([^)]*\)'
function Get-UiColorLiterals([string]$Text) {
    $t = [regex]::Replace($Text, '/\* ui-tokens:begin [\s\S]*?/\* ui-tokens:end \*/', '')
    $t = [regex]::Replace($t, '/\*[\s\S]*?\*/', '')
    $t = [regex]::Replace($t, '<!--[\s\S]*?-->', '')
    foreach ($m in $script:UiHexRx.Matches($t)) { $m.Value }
    foreach ($m in $script:UiFuncRx.Matches($t)) { $m.Value }
}
