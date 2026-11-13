#Requires -Version 5.1
# Career-Test-Harness-Eintraege (Paket-Beitrag zur Engine-Registry $script:Harnesses; init in lib/harness.ps1).
# Dot-gesourct von build.ps1 ueber den packages/*/build/workflows/*.ps1-Glob.
$script:Harnesses += @(
    [ordered]@{ name='agent.career_advisor.test_harness'; targetName='agent.career_advisor'; path='career-test'; inputMap=$null }
    # Mehrfach-Leser ohne Agent davor (infra_cases): fremde Datei -> ignored_files.
    [ordered]@{ name='agent.career.tool_extract_cv.test_harness'; targetName='agent.career.tool_extract_cv'; path='extract-cv-test'; inputMap=[ordered]@{ file_id='body.file_id'; more_file_ids='body.more_file_ids'; doc_hint='body.doc_hint'; chat_id='body.chat_id' } }
    # Treffer-Karte deterministisch testbar (cron_text_test); die Stellen-Suche holt live.
    [ordered]@{ name='agent.career.sub_send_job_card.test_harness'; targetName='agent.career.sub_send_job_card'; path='job-card-test'
                inputMap=[ordered]@{ chat_id='body.chat_id'; job_match_id='body.job_match_id'; is_serendipity='body.is_serendipity'
                                     score='body.score'; title='body.title'; employer='body.employer'; location='body.location'
                                     board='body.board'; url='body.url'; reasoning='body.reasoning' } }
)
