# PreToolUse-Hook (ListAgents|SendMessage): keine Session-Koordination im Bypass-Modus (Owner-Regel 2026-10-23,
# Skill /coordinate Schritt 1). Laeuft eine Session mit bypassPermissions, die anderen aber mit "prompting"/auto,
# halten die Empfaenger Nachrichten zur Freigabe fest, bis sie ablaufen - die Koordination steht still, ohne dass
# es jemand merkt (2026-10-23: drei Anmeldungen von 7d verfielen ungelesen).
# Claude kann den eigenen Modus nicht umstellen (kein Tool; ein SessionStart-Hook bekommt permission_mode nicht
# und kann ihn nicht setzen, Doku code.claude.com/docs/en/hooks) -> deny mit Anweisung: anhalten, Owner bitten.
# deny statt ask: 'ask' wird unter bypassPermissions in der VS-Code-Erweiterung still durchgewinkt (GH #77212).
# Fehlt permission_mode in der Eingabe -> fail-open (kein Block). ASCII-only + Compact-JSON (kein BOM in stdout).
$ErrorActionPreference = 'Stop'
$raw = [Console]::In.ReadToEnd()
try { $j = $raw | ConvertFrom-Json } catch { exit 0 }
if ([string]$j.permission_mode -ne 'bypassPermissions') { exit 0 }
$reason = 'KOORDINATION IM BYPASS-MODUS GESPERRT: Diese Session laeuft mit "Bypass permissions". Andere Sessions halten Nachrichten an/von ihr zur Freigabe fest, bis sie ablaufen - die Abstimmung kommt nie an. Claude kann den Modus nicht selbst umstellen. ANHALTEN und den Owner bitten, diese Session auf "Auto" umzustellen (Shift+Tab bzw. Modus-Auswahl in VS Code); danach ListAgents/SendMessage wiederholen (Skill /coordinate Schritt 1).'
$out = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason } } | ConvertTo-Json -Compress -Depth 5
Write-Output $out
exit 0
