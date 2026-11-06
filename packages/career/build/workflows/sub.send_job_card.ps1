#Requires -Version 5.1
# Definition agent.career.sub_send_job_card -> Build-CareerSubSendJobCard. Dot-gesourct von build.ps1.
#
# --- agent.career.sub_send_job_card (Treffer-Karte des Job-Scans, Textkatalog Phase C) -------
# Schickt EINE Stellen-Karte an die EIGENE chat_id der Person (score 1..4 oder "Blick ueber den Tellerrand"),
# mit 👍/👎 (job:up|down:<job_match_id> -> generischer Callback-Dispatch -> career.fn_handle_job_feedback) und
# Abschalten (rem:off:score_jobs = NUR die eigenen Karten der Person, Roter Faden Paket B). Alle festen Texte in der Sprache des EMPFAENGERS (chat_id -> Person -> Kette
# Person -> Owner -> en, core.fn_ui_texts_for unter career_ro); Titel/Arbeitgeber/Ort/Begruendung = Daten.
# Aufrufer: agent.career.cron_score_jobs (je gesurftem Treffer ein Item). Eigener Sub (Muster
# core.sub_send_language_picker), damit die Karte deterministisch testbar ist (Harness, cron_text_test) — die
# Stellen-Suche selbst holt live von BA/Adzuna/JSearch.
# Eingang: chat_id, job_match_id, is_serendipity, score, title, employer, location, board, url, reasoning.
function Build-CareerSubSendJobCard {
    $trig = Build-Trigger @('job_match_id', 'is_serendipity', 'score', 'title', 'employer', 'location', 'board', 'url', 'reasoning')

    $load = Build-Pg 'Load card texts' @(220, 0) `
        ("=SELECT core.fn_ui_texts_for(jsonb_build_object('chat_id', (`$1::jsonb)->>'chat_id', 'keys', to_jsonb(" +
         (Get-UiKeysSql @('career.jobcard.match', 'career.jobcard.stretch', 'career.jobcard.via',
                          'career.jobcard.feedback_hint', 'career.jobcard.btn_off')) + ")))->'t' AS t;") `
        ([ordered]@{ chat_id = "String(`$('Start').item.json.chat_id || '')" })
    $load.credentials = @{ postgres = $CRED_CAREER_RO }

    $s = "`$('Start').item.json"
    $T = '$json.t'
    $headJs = "(String($s.is_serendipity) === 'true' ? " + (Get-UiTextJs $T 'career.jobcard.stretch') + ' : ' +
              (Get-UiTextJs $T 'career.jobcard.match' @{ score = "$s.score" }) + ')'
    $cardText = '={{ ' + $headJs + " + '\n' + $s.title + ($s.employer ? ' – ' + $s.employer : '')" +
        " + ($s.location ? '\n📍 ' + $s.location : '')" +
        " + ($s.board ? '\n' + " + (Get-UiTextJs $T 'career.jobcard.via' @{ board = "$s.board" }) + " : '')" +
        " + ($s.url ? '\n' + $s.url : '') + ($s.reasoning ? '\n' + $s.reasoning : '')" +
        " + '\n\n' + " + (Get-UiTextJs $T 'career.jobcard.feedback_hint') + ' }}'
    $card = New-TelegramInlineKeyboardSendNode 'Send card' @(440, 0) $cardText `
        @(
            @{ Text = '👍'; Data = "={{ 'job:up:' + $s.job_match_id }}" },
            @{ Text = '👎'; Data = "={{ 'job:down:' + $s.job_match_id }}" },
            @{ Text = (Get-UiTextExpr $T 'career.jobcard.btn_off'); Data = 'rem:off:score_jobs' }
        ) `
        -ChatIdExpr "={{ $s.chat_id }}"

    $sticky = Build-Sticky 'Doc: Überblick' @(-40, -300) -Header 'Ablauf' `
        'agent.career.sub_send_job_card — Treffer-Karte in der Sprache der Person' `
        'Deterministisch, kein LLM. Start (job_match_id, is_serendipity, score, title, employer, location, board, url, reasoning, chat_id) -> Load card texts (core.fn_ui_texts_for unter career_ro: Sprache der Person hinter chat_id, Kette Person -> Owner -> en) -> Send card an die EIGENE chat_id: Kopf (Passende Stelle n/4 bzw. Blick über den Tellerrand), Titel/Arbeitgeber/Ort, "via <board>" nur wenn ein Board offengelegt ist (jsearch), Link, Begründung des Scorers (in der Sprache der Person), Feedback-Hinweis. Knöpfe 👍/👎 -> job:up|down:<job_match_id> (generischer Callback-Dispatch -> career.fn_handle_job_feedback) und Abschalten -> rem:off:score_jobs (core.fn_handle_reminder_cb: schaltet NUR die Job-Vorschläge dieser Person ab, agent.reminder_prefs; der Notschalter für alle bleibt Konsole). Aufrufer: agent.career.cron_score_jobs; eigener Sub, damit die Karte über den Harness deterministisch testbar ist.' 320 560

    $nodes = @($trig, $load, $card, $sticky)
    $conns = [ordered]@{
        'Start'           = @{ main = @( ,@( E 'Load card texts' ) ) }
        'Load card texts' = @{ main = @( ,@( E 'Send card' ) ) }
    }
    return Build-Workflow 'agent.career.sub_send_job_card' $nodes $conns
}
