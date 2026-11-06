#Requires -Version 5.1
# ui_art.ps1 -- Erklär-Bilder: eine Quelle je Bild (config/ui.art.<name>.svg), daraus selbstständige SVG-Dateien je Sprache und
# Hell/Dunkel für alle Verbraucher (README, Doku-Seite, Start-App, Wizard). Schreiben: scripts/build_ui_tokens.ps1,
# Prüfen: scripts/ui_token_lint.ps1 (8). Dot-sourcen nach scripts/lib/ui_tokens.ps1.
#
# Warum Dateien statt Inline-SVG: Alle Verbraucher zeigen das Bild per <img>. So gilt die CSP der Seite (style-src 'self') nicht
# für das <style> im Bild, GitHub zeigt es in der README, und „Bewegung reduzieren" wirkt im Bild selbst. Folge: Farben und
# Texte stehen fest im Bild, also eine Datei je Sprache und Thema.
#
# Quell-Format (nur, was der Generator auswertet):
#   <svg data-scenes="N" data-scene-s="S">  Szenen-Takt; erzeugt die Klassen .in<k> (ab Szene k sichtbar) und .on<k> (nur in
#                                           Szene k). Ohne Bewegung (reduced-motion) gilt das Schlussbild: alle .in<k> sichtbar,
#                                           von den .on<k> nur die letzte Szene.
#   <style>                                 eigene Bewegung, Farben nur var(--token); der Generator setzt Takt- und Farb-Regeln davor.
#   <text data-t="greeting.s1" data-wrap="40" data-lh="20" data-max="2" data-valign="middle">
#                                           Text aus dem Katalog core.art.greeting.s1; Umbruch nach geschätzter Breite (Zeichen,
#                                           Hangul/CJK zählt 1.6), mehr als data-max Zeilen = Fehler (nichts läuft über).
#   <g data-mark="">                        bekommt die <path>-Zeilen aus config/ui.mark.svg (Zeichen nie von Hand kopieren).
#   <image data-sticker="neutral_yay">      echter Persona-Sticker packages/core/build/stickers/<name>.webp als data:-URI (ein <img>-SVG
#                                           darf nichts von außen laden; data: ist erlaubt). Nie nachzeichnen.
#   data-variant="tunnel"                   Element nur in der Variante tunnel (Dateiname <name>-<variante>.<sprache>...).
#   data-font=""                            (nur am Wurzel-Element) nicht nötig: die Schrift kommt als --font aus den Tokens.

# Ziel-Ordner sind komplett erzeugt (der Lint meldet fremde Dateien darin). Thema auto = folgt dem System per Media-Query.
function Get-UiArtDirs { @{ Site = 'docs/site/static/explain'; Wizard = 'provisioning/wizard/ui/explain'; Desktop = 'provisioning/desktop/ui/explain' } }
function Get-UiArts {
    $d = Get-UiArtDirs
    @(
        # Begrüßung: Start-App Seite 1 (auto), Doku-Startseite (de hell, die Site kennt kein Dunkel), README (en hell + dunkel).
        [pscustomobject]@{ Name = 'greeting'; Variants = @(''); Targets = @(
                @{ Dir = $d.Desktop; Langs = @('de', 'en', 'ko'); Themes = @('auto') }
                @{ Dir = $d.Site; Langs = @('de'); Themes = @('light') }
                @{ Dir = $d.Site; Langs = @('en'); Themes = @('light', 'dark') }) }
        # Warum Telegram: Wizard-Seite vor dem Bot-Token.
        [pscustomobject]@{ Name = 'telegram'; Variants = @(''); Targets = @(
                @{ Dir = $d.Wizard; Langs = @('de', 'en', 'ko'); Themes = @('auto') }) }
        # Wege ins Internet: Wizard-Seite reach (Bild wechselt mit der Auswahl) und die Weg-Seiten der Anleitung.
        [pscustomobject]@{ Name = 'reach'; Variants = @('tunnel', 'fritzbox', 'proxy'); Targets = @(
                @{ Dir = $d.Wizard; Langs = @('de', 'en', 'ko'); Themes = @('auto') }
                @{ Dir = $d.Site; Langs = @('de'); Themes = @('light') }) }
    )
}
function Get-UiArtStickerDir { 'packages/core/build/stickers' }
function Get-UiArtSourcePath([string]$Name) { "config/ui.art.$Name.svg" }
function Get-UiArtFileName([string]$Name, [string]$Variant, [string]$Lang, [string]$Theme) {
    $n = if ($Variant) { "$Name-$Variant" } else { $Name }
    if ($Theme -eq 'auto') { "$n.$Lang.svg" } else { "$n.$Lang.$Theme.svg" }
}

# Alle erzeugten Dateien: Liste aus @{ Path; Text }
function Get-UiArtOutputs([string]$RepoRoot, $Tokens) {
    $script:UiArtRepoRoot = $RepoRoot
    $u8 = [System.Text.UTF8Encoding]::new($false)
    $markPaths = @(Get-UiMarkPaths $RepoRoot)
    $cat = @{}
    foreach ($f in (Get-ChildItem (Join-Path $RepoRoot 'packages/core/locales') -Filter '*.json')) {
        $cat[$f.BaseName] = [System.IO.File]::ReadAllText($f.FullName, $u8) | ConvertFrom-Json
    }
    foreach ($a in (Get-UiArts)) {
        $src = [System.IO.File]::ReadAllText((Join-Path $RepoRoot (Get-UiArtSourcePath $a.Name)), $u8).Replace("`r`n", "`n")
        foreach ($t in $a.Targets) {
            foreach ($lang in $t.Langs) {
                foreach ($theme in $t.Themes) {
                    foreach ($v in $a.Variants) {
                        $text = ConvertTo-UiArtSvg $src $v $cat[$lang] $lang $theme $Tokens $markPaths "$(Get-UiArtSourcePath $a.Name)"
                        [pscustomobject]@{ Path = "$($t.Dir)/$(Get-UiArtFileName $a.Name $v $lang $theme)"; Text = $text }
                    }
                }
            }
        }
    }
}

# Geschätzte Breite in „Zeichen": Hangul/CJK breiter als lateinische Buchstaben.
function Get-UiArtTextWidth([string]$s) {
    $w = 0.0
    foreach ($c in $s.ToCharArray()) { $n = [int]$c; if (($n -ge 0x1100 -and $n -le 0x11FF) -or ($n -ge 0x2E80 -and $n -le 0x9FFF) -or ($n -ge 0xAC00 -and $n -le 0xD7AF)) { $w += 1.6 } else { $w += 1 } }
    $w
}
function Split-UiArtLines([string]$s, [double]$Wrap) {
    if ($Wrap -le 0) { return $s }
    $lines = [System.Collections.Generic.List[string]]::new()
    $cur = ''
    foreach ($word in ($s -split ' ')) {
        $try = if ($cur) { "$cur $word" } else { $word }
        if ($cur -and (Get-UiArtTextWidth $try) -gt $Wrap) { $lines.Add($cur); $cur = $word } else { $cur = $try }
    }
    if ($cur) { $lines.Add($cur) }
    $lines.ToArray()
}

# Takt-Regeln aus data-scenes/data-scene-s. Grundzustand = Schlussbild (gilt bei reduced-motion und falls CSS-Animation fehlt).
function Get-UiArtSceneCss([int]$N, [double]$SceneS) {
    $T = $N * $SceneS
    $f = [Math]::Round(0.4 / $T * 100, 2)
    $p = { param($x) ([Math]::Round($x, 2)).ToString([Globalization.CultureInfo]::InvariantCulture) + '%' }
    $l = [System.Collections.Generic.List[string]]::new()
    for ($k = 1; $k -le $N; $k++) {
        $a = ($k - 1) / $N * 100; $b = $k / $N * 100
        $fin = if ($k -eq 1) { '0%' } else { "0%, $(& $p $a)" }
        $onStart = if ($k -eq 1) { '0%' } else { "0%, $(& $p $a)" }
        $l.Add("@keyframes in$k { $fin { opacity: 0 } $(& $p ($a + $f)), 97% { opacity: 1 } 100% { opacity: 0 } }")
        $end = if ($k -eq $N) { '97%' } else { & $p ($b - $f) }
        $off = if ($k -eq $N) { '100%' } else { "$(& $p $b), 100%" }
        $l.Add("@keyframes on$k { $onStart { opacity: 0 } $(& $p ($a + $f)), $end { opacity: 1 } $off { opacity: 0 } }")
        $l.Add(".on$k { opacity: $(if ($k -eq $N) { 1 } else { 0 }) }")
        $l.Add("@media (prefers-reduced-motion: no-preference) { .in$k { animation: in$k ${T}s linear infinite } .on$k { animation: on$k ${T}s linear infinite } }")
    }
    $l -join "`n"
}
function Get-UiArtTokenCss($Tokens, [string]$Theme) {
    $one = { param($g) (Get-UiColorNames $Tokens $g | ForEach-Object { "--${_}: $(Get-UiColorHex $Tokens $g $_);" }) -join ' ' }
    $font = "--font: $(Get-UiShapeCss $Tokens 'font');"
    switch ($Theme) {
        'light' { ":root { $(& $one 'light') $font }" }
        'dark' { ":root { $(& $one 'dark') $font }" }
        'auto' { ":root { $(& $one 'light') $font }`n@media (prefers-color-scheme: dark) { :root { $(& $one 'dark') } }" }
        default { throw "Unbekanntes Thema '$Theme'" }
    }
}

function ConvertTo-UiArtSvg([string]$Src, [string]$Variant, $Catalog, [string]$Lang, [string]$Theme, $Tokens, [string[]]$MarkPaths, [string]$SrcName) {
    $doc = [xml]::new()
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($Src)
    $ns = 'http://www.w3.org/2000/svg'
    $root = $doc.DocumentElement
    # Kommentare raus (Entwickler-Text der Quelle gehört nicht ins ausgelieferte Bild)
    foreach ($c in @($doc.SelectNodes('//comment()'))) { [void]$c.ParentNode.RemoveChild($c) }
    # Varianten
    foreach ($e in @($doc.SelectNodes('//*[@data-variant]'))) {
        if ($e.GetAttribute('data-variant') -ne $Variant) { [void]$e.ParentNode.RemoveChild($e) } else { $e.RemoveAttribute('data-variant') }
    }
    # Zeichen
    $markXml = ($MarkPaths | ForEach-Object { $_ -replace '<path ', "<path xmlns=`"$ns`" " })
    foreach ($g in @($doc.SelectNodes('//*[@data-mark]'))) {
        foreach ($p in $markXml) { $frag = [xml]::new(); $frag.LoadXml($p); [void]$g.AppendChild($doc.ImportNode($frag.DocumentElement, $true)) }
        $g.RemoveAttribute('data-mark')
    }
    # Sticker
    foreach ($e in @($doc.SelectNodes('//*[@data-sticker]'))) {
        $name = $e.GetAttribute('data-sticker')
        if ($name -notmatch '^[a-z]+_[a-z]+$') { throw "${SrcName}: Sticker-Name '$name' ungültig" }
        $file = Join-Path (Join-Path $script:UiArtRepoRoot (Get-UiArtStickerDir)) "$name.webp"
        if (-not (Test-Path $file)) { throw "${SrcName}: Sticker $name.webp fehlt in $(Get-UiArtStickerDir)" }
        $e.SetAttribute('href', 'data:image/webp;base64,' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file)))
        $e.RemoveAttribute('data-sticker')
    }
    # Texte
    foreach ($e in @($doc.SelectNodes('//*[@data-t]'))) {
        $key = "core.art.$($e.GetAttribute('data-t'))"
        $val = [string]$Catalog.$key
        if (-not $val) { throw "${SrcName}: Text '$key' fehlt im Katalog ($Lang)" }
        $wrap = if ($e.HasAttribute('data-wrap')) { [double]$e.GetAttribute('data-wrap') } else { 0 }
        $lh = if ($e.HasAttribute('data-lh')) { [double]$e.GetAttribute('data-lh') } else { 0 }
        $max = if ($e.HasAttribute('data-max')) { [int]$e.GetAttribute('data-max') } else { 1 }
        $lines = @(Split-UiArtLines $val $wrap)
        if ($wrap -gt 0) { foreach ($ln in $lines) { if ((Get-UiArtTextWidth $ln) -gt $wrap) { throw "${SrcName}: Wort in '$key' ($Lang) breiter als data-wrap=$wrap" } } }
        if ($lines.Count -gt $max) { throw "${SrcName}: '$key' ($Lang) braucht $($lines.Count) Zeilen, erlaubt $max -- Text kürzen oder Platz schaffen" }
        $e.InnerText = ''
        if ($lines.Count -eq 1) { $e.InnerText = $lines[0] }
        else {
            $x = $e.GetAttribute('x')
            $first = if ($e.GetAttribute('data-valign') -eq 'middle') { - ($lines.Count - 1) * $lh / 2 } else { 0 }
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $ts = $doc.CreateElement('tspan', $ns)
                $ts.SetAttribute('x', $x)
                $dy = if ($i -eq 0) { $first } else { $lh }
                $ts.SetAttribute('dy', ([double]$dy).ToString([Globalization.CultureInfo]::InvariantCulture))
                $ts.InnerText = $lines[$i]
                [void]$e.AppendChild($ts)
            }
        }
        foreach ($at in 'data-t', 'data-wrap', 'data-lh', 'data-max', 'data-valign') { $e.RemoveAttribute($at) }
    }
    # Stil: Farben + Takt vor den eigenen Regeln der Quelle
    $style = $doc.GetElementsByTagName('style', $ns) | Select-Object -First 1
    if (-not $style) { throw "${SrcName}: <style> fehlt" }
    $n = [int]$root.GetAttribute('data-scenes'); $s = [double]::Parse($root.GetAttribute('data-scene-s'), [Globalization.CultureInfo]::InvariantCulture)
    if ($n -lt 1 -or $s -le 0) { throw "${SrcName}: data-scenes/data-scene-s fehlen" }
    $own = $style.InnerText.Trim("`n", ' ')
    $style.InnerText = "`n" + (Get-UiArtTokenCss $Tokens $Theme) + "`n" + (Get-UiArtSceneCss $n $s) + "`n" + $own + "`n"
    $root.RemoveAttribute('data-scenes'); $root.RemoveAttribute('data-scene-s')
    $root.SetAttribute('lang', $Lang)
    $out = $root.OuterXml
    # Leerzeilen, die das Entfernen hinterlässt, zusammenziehen
    $out = [regex]::Replace($out, '\n[ \t]*(?=\n)', '')
    "<!-- Erzeugt von scripts/build_ui_tokens.ps1 aus $SrcName, nicht von Hand ändern. -->`n" + $out + "`n"
}
