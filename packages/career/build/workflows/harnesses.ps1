#Requires -Version 5.1
# Career-Test-Harness-Eintraege (Paket-Beitrag zur Engine-Registry $script:Harnesses; init in lib/harness.ps1).
# Dot-gesourct von build.ps1 ueber den packages/*/build/workflows/*.ps1-Glob.
$script:Harnesses += @(
    [ordered]@{ name='agent.career_advisor.test_harness'; targetName='agent.career_advisor'; path='career-test'; inputMap=$null }
    # Textkatalog Phase C: die Treffer-Karte deterministisch testbar (cron_text_test; die Stellen-Suche holt live).
    [ordered]@{ name='agent.career.sub_send_job_card.test_harness'; targetName='agent.career.sub_send_job_card'; path='job-card-test'
                inputMap=[ordered]@{ chat_id='body.chat_id'; job_match_id='body.job_match_id'; is_serendipity='body.is_serendipity'
                                     score='body.score'; title='body.title'; employer='body.employer'; location='body.location'
                                     board='body.board'; url='body.url'; reasoning='body.reasoning' } }
)
