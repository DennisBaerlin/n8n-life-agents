#Requires -Version 5.1
# Core-Test-Harness-Eintraege (Paket-Beitrag zur Engine-Registry $script:Harnesses; init in lib/harness.ps1).
# Dot-gesourct von build.ps1 ueber den packages/*/build/workflows/*.ps1-Glob. Build-Harness/Get-HarnessWorkflow
# leben generisch in der Engine (scripts/build/lib/harness.ps1).
#
# KEIN orchestrator.test_harness (Teststrategie Phase 8 -- Weg C): nach Entfernen des Test-Sonderknotens
# "Test entry" hat der Orchestrator nur noch den echten Telegram-Trigger als Eingang. Orchestrator-Tests
# (orch_test, mock_route_test-Default) feuern am ECHTEN Telegram-Webhook (real_ingress-Muster, numerische
# chat_id + Gate ueber Mock-Telegram) statt ueber einen Harness.
$script:Harnesses += @(
    [ordered]@{ name='agent.tool_load_context.test_harness';    targetName='agent.tool_load_context';   path='load-ctx-test';    inputMap=[ordered]@{ agent_name='body.agent_name'; include_manifest='body.include_manifest' } }
    [ordered]@{ name='core.sub_load_config.test_harness';       targetName='core.sub_load_config';       path='load-config-test'; inputMap=[ordered]@{} }
    [ordered]@{ name='agent.tool_human_approval.test_harness';  targetName='agent.tool_human_approval';  path='gate-test';        inputMap=[ordered]@{ summary='body.summary'; chat_id='body.chat_id'; approval_tier='body.approval_tier' } }
    [ordered]@{ name='agent.tool_web_search.test_harness';      targetName='agent.tool_web_search';      path='websearch-test';   inputMap=[ordered]@{ query='body.query'; chat_id='body.chat_id' } }
    [ordered]@{ name='agent.tool_expert_panel.test_harness';    targetName='agent.tool_expert_panel';    path='panel-test';       inputMap=[ordered]@{ question='body.question'; dossier='body.dossier'; personas='body.personas'; chat_id='body.chat_id' } }
    [ordered]@{ name='agent.monitor.test_harness';              targetName='agent.monitor';              path='monitor-test';     inputMap=$null }
    [ordered]@{ name='agent.guide.test_harness';                targetName='agent.guide';                path='guide-test';       inputMap=$null }
    # Install-UX-Phase 4: Core-Verteiler zu Paket-Agenten (infra_cases ic16/ic17: Tiefen-Schutz durchgereicht + nicht installiert).
    [ordered]@{ name='agent.sub_dispatch_agent.test_harness';   targetName='agent.sub_dispatch_agent';   path='dispatch-test';    inputMap=[ordered]@{ workflow_id='body.workflow_id'; package='body.package'; task='body.task'; chat_id='body.chat_id'; call_depth='body.call_depth' } }
    # paperless Phase 2: Core-Vermittler zu Paket-WERKZEUGEN (infra_cases: Durchreichen, package_unavailable, unknown_service, not_permitted).
    [ordered]@{ name='agent.sub_dispatch_tool.test_harness';    targetName='agent.sub_dispatch_tool';    path='dispatch-tool-test'; inputMap=[ordered]@{ service='body.service'; args='body.args'; chat_id='body.chat_id' } }
    # Phase A: der EINE Fakten-Schreibweg — hitl_gate_test fuehrt den APPROVE-Zweig bis in die DB (Schema-Fidelity
    # Payload->fn->Zeile, kostenlos; kein anderer freier Tier faehrt den Write-Zweig dieses Tools).
    [ordered]@{ name='agent.tool_set_context_facts.test_harness'; targetName='agent.tool_set_context_facts'; path='facts-test'; inputMap=[ordered]@{ context_name='body.context_name'; facts='body.facts'; persons='body.persons'; household='body.household'; content='body.content'; scope='body.scope'; chat_id='body.chat_id' } }
    # Sprachnachricht: Erfolgs- und Fehlerwege des Transkriptions-Tools (infra_cases, target agent.tool_transcribe_telegram_voice).
    [ordered]@{ name='agent.tool_transcribe_telegram_voice.test_harness'; targetName='agent.tool_transcribe_telegram_voice'; path='voice-test'; inputMap=[ordered]@{ file_id='body.file_id' } }
    # Roter Faden: die Karten nach einem Onboarding-Schritt deterministisch testbar (cron_text_test ctk06-ctk08: Bereich
    # fertig, alles fertig + Lern-Angebot, "Es kann losgehen" an ein Mitglied) — ohne LLM-Agent davor.
    [ordered]@{ name='core.sub_onboarding_progress.test_harness'; targetName='core.sub_onboarding_progress'; path='onboarding-progress-test'; inputMap=[ordered]@{ chat_id='body.chat_id'; package='body.package'; area_completed_now='body.area_completed_now'; area_all_skipped='body.area_all_skipped' } }
    # Roter Faden Paket B: das /reminders-Menue deterministisch testbar (cron_text_test ctk09/ctk10: Owner- und Mitglieder-Sicht).
    [ordered]@{ name='core.sub_send_reminders_menu.test_harness'; targetName='core.sub_send_reminders_menu'; path='reminders-menu-test'; inputMap=[ordered]@{ chat_id='body.chat_id' } }
    # Schnellere freie Gates: startet einen Cron sofort ueber seinen 'Test run'-Einstieg (Build-Workflow), statt den Zeitplan
    # auf jede Minute zu stellen (cron_text_test, hitl_gate_test hitlC4). Ziel = workflow_id aus dem Body; nicht warten, weil
    # ein Cron mit Bestaetigungs-Frage den POST bis zum Tipp festhielte.
    [ordered]@{ name='core.cron_run.test_harness'; targetIdField='body.workflow_id'; path='cron-run-test'; inputMap=[ordered]@{}; noWait=$true }
)
