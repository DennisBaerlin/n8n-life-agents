#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Helper + Script-Scope-Creds/$FactsDisplayJson im Parent-Scope).

# --- agent.tool_set_own_context_facts (Mitglieder-Selbstpflege, HITL-Stufe self) ----
# Schreibweg fuer die EIGENEN per_user-Kontexte der fragenden Person (Career-Coach: Profil + Job-Vorlieben).
# Gleicher Graph wie agent.tool_set_context_facts (New-ContextFactsToolGraph in tools/set_context_facts.ps1),
# aber -Own: ruft agent.fn_set_own_context_facts (scope='per_user' fest in der fn), KEIN scope-/persons-/household-
# Eingang. Gate-Stufe self (approval_matrix des core-Manifests): die Person bestaetigt selbst, kein Owner-Send.
function Build-SetOwnContextFacts { New-ContextFactsToolGraph -WorkflowName 'agent.tool_set_own_context_facts' -Own }
