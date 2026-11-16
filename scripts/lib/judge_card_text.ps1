#Requires -Version 5.1
# Bot-Ausgaben einer Durchspiel-Runde: aus den abgefangenen Telegram-Anfragen (Mock-Telegram-Log) bis zum Text fuer Pruefungen und
# Bewerter-Buendel (scripts/conversation_test.ps1). Die Bestaetigungs-Karte baut das Werkzeug aus seinem Probelauf, nicht der Agent;
# im Buendel steht sie darum getrennt (card_text -> Abschnitt CONFIRMATION_CARD, scripts/lib/judge_prompt.ps1). Sonst liest der
# Bewerter Karten-Knoepfe als erneute Rueckfrage und einen von der Datenbank aufgeloesten Namen als erfunden. Per Dot-Sourcing laden;
# Selbsttest scripts/dev/judge_card_text_test.ps1 (schickt aufgezeichnete Anfragen durch ConvertTo-BotOutputs).

# Sichtbare Telegram-Aufrufe; alles andere (Tipp-Anzeige, Menue-Setup ...) wird nur gezaehlt.
$script:BotVisibleMethods = @('sendMessage', 'sendSticker', 'sendAnimation', 'sendPhoto', 'sendDocument', 'setMessageReaction',
                              'answerCallbackQuery', 'editMessageText', 'editMessageReplyMarkup', 'deleteMessage')

# n8n schickt reply_markup teils als JSON-String.
function Get-ButtonList($Markup) {
    if ($Markup -is [string]) { try { $Markup = $Markup | ConvertFrom-Json } catch { return @() } }
    $out = @()
    foreach ($row in @($Markup.inline_keyboard)) {
        foreach ($b in @($row)) {
            $target = if ($b.callback_data) { "cb:$($b.callback_data)" } elseif ($b.url) { "url:$($b.url)" } elseif ($b.web_app) { 'web_app' } else { '' }
            $out += [pscustomobject]@{ label = "$($b.text)"; target = $target }
        }
    }
    return $out
}

# HITL-Karte: Knoepfe mit Freigabe-Callback (Bestaetigen im Chat, test_n8n_state.ps1) oder Resume-Link (webhook-waiting).
function Test-HitlCardButtons($Buttons) {
    return [bool](@($Buttons | Where-Object { $_.target -match '^cb:nhitl1\|' -or $_.target -match 'webhook-waiting' }).Count)
}

function ConvertTo-BotOutputs($Reqs) {
    $outs = @(); $other = 0
    foreach ($r in @($Reqs)) {
        $m = "$($r.method)"
        if ($m -eq '__start' -or $m -eq '') { continue }
        if ($script:BotVisibleMethods -notcontains $m) { $other++; continue }
        $b = $r.body
        $o = [ordered]@{ method = $m; chat = "$($b.chat_id)"; text = ''; buttons = @(); sticker = ''; reaction = ''; card = $false }
        $t = if ($b.text) { "$($b.text)" } elseif ($b.caption) { "$($b.caption)" } else { '' }
        # Die Send-Knoten escapen & < > einmal und senden mit parse_mode HTML; Telegram zeigt den Klartext. Der Judge
        # soll lesen, was die Person sieht, nicht "Depot &amp; Sparplaene" (&amp; zuletzt, sonst doppelt entschluesselt).
        if ("$($b.parse_mode)" -eq 'HTML') { $t = $t.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&amp;', '&') }
        $o.text = $t
        if ($b.reply_markup) { $o.buttons = @(Get-ButtonList $b.reply_markup) }
        # Persona-Sticker kommen als Upload (body.sticker_file = Dateiname) oder per file_id (body.sticker).
        if ($b.sticker_file) { $o.sticker = "$($b.sticker_file)" } elseif ($b.sticker) { $o.sticker = "$($b.sticker)" }
        if ($m -eq 'setMessageReaction') { $o.reaction = (@($b.reaction | ForEach-Object { "$($_.emoji)" }) -join ' ') }
        if ($m -eq 'answerCallbackQuery') { $o.text = "$($b.text)" }
        $o.card = Test-HitlCardButtons $o.buttons
        $outs += [pscustomobject]$o
    }
    return [pscustomobject]@{ outputs = $outs; other = $other }
}

# Alle Texte und Knopf-Beschriftungen, Karten eingeschlossen (expect/forbid pruefen, was die Person sieht).
function Get-OutputText($Outs) {
    (@(foreach ($o in $Outs) { $o.text; foreach ($b in $o.buttons) { $b.label } }) | Where-Object { $_ }) -join "`n"
}

# DB-Pruefungen einer Runde (expect_sql, Form $rd.sql_checks) als Beleg fuers Bewerter-Buendel: Den Werkzeug-Aufruf liest das
# Durchspiel nicht (er laeuft in einer Unter-Ausfuehrung des Agenten), den Zustand danach schon. Eine Zeile je Pruefung.
function Format-JudgeDbChecks($Checks) {
    (@(foreach ($c in @($Checks)) {
        if (-not $c) { continue }
        if ($c.ok) { "ok: $($c.sql) = $($c.got)" } else { "FAIL: $($c.sql) = $($c.got) (erwartet $($c.equals))" }
    }) -join "`n")
}

# Rueckgabe @{ reply; card }: reply = Ausgaben ohne Karte (die Antwort des Agenten), card = nur die Karten (Feld card = true).
function Split-JudgeCardOutput($Outs) {
    $cards = @($Outs | Where-Object { $_.card }); $rest = @($Outs | Where-Object { -not $_.card })
    return @{ reply = (Get-OutputText $rest); card = (Get-OutputText $cards) }
}