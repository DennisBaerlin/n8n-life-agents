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
                [pscustomobject]@{ Selector = '.qr'; Group = 'light' }
                # Handy-Bilder (ui/art/, di9): Rahmen immer dunkel, Bildschirm immer hell wie ein Telegram-Chat am Tag.
                [pscustomobject]@{ Selector = '.phone'; Group = 'dark' }
                [pscustomobject]@{ Selector = '.phone .screen'; Group = 'light' }
            )
            Colors = @('ink', 'gray', 'hairline', 'accent', 'accent-hover', 'accent-mid', 'accent-pale', 'accent-wash', 'warn', 'warn-wash', 'alert', 'alert-wash', 'bg', 'bg-soft')
            Shape  = @('radius-sm', 'radius', 'radius-pill', 'font')
        }
    )
}

# Wurzeln, unter denen der Lint Farb-Literale sucht. Eine UI-Datei ausserhalb dieser Wurzeln (und ausserhalb von
# Get-UiExcludedPrefixes) ist ein Fehler: so rutscht eine neue Oberflaeche nicht unbemerkt durch.
function Get-UiScanRoots {
    @('docs/site/static/', 'docs/site/layouts/', 'packages/core/build/app/', 'packages/core/build/stickers/', 'provisioning/wizard/ui/')
}
# public/ = Hugo-Output der Quellen oben; mods = Erweiterung des Entwickler-Werkzeugs, keine Projekt-Oberflaeche.
function Get-UiExcludedPrefixes { @('docs/site/public/', '.claude/mods/') }
function Get-UiFileExtensions { @('.css', '.html', '.htm', '.vue', '.svelte', '.tsx', '.jsx') }
function Get-UiScanExtensions { @('.css', '.html', '.htm', '.js', '.svg', '.vue', '.svelte', '.tsx', '.jsx') }

# Telegram-Profilbild des Bots: abgeleitet aus dem einen Zeichen und der Farbdatei (rendert scripts/dev/render_bot_profile.ps1,
# prueft scripts/ui_token_lint.ps1). Farben gegenueber der Website getauscht: helles Zeichen auf voller Akzentflaeche, weil die
# runde Anzeige eine volle Flaeche braucht und JPG keine Transparenz kennt. Das Zeichen fuellt knapp die Haelfte der Breite und
# bleibt so auch im kleinen Kreis frei stehen. Vom Zeichen zaehlt nur die Geometrie: jede Farbangabe darin wird hier gesetzt.
function Get-UiBotProfilePaths { @{ Mark = 'docs/site/layouts/partials/mark.html'; Dir = 'packages/core/build/bot_profile'; Jpg = 'bot_profile.jpg'; Sha = 'source.sha256' } }
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
