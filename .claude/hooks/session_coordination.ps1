# SessionStart-Hook: Erinnerung an die Session-Koordination (Owner-Regel 2026-10-23, Skill /coordinate).
# Jede startende Session prueft, ob parallele Sessions laufen, und stimmt Leitung + Merge-Hoheit ab.
# Kein Lauf-Check hier (die Session-Liste kennt nur Claude via ListAgents) -> immer derselbe kurze Kontext.
# ASCII-only + Compact-JSON, damit kein BOM die stdout-JSON bricht. Nie ein Fehler-Exit.
try {
    $ctx = 'SESSION-KOORDINATION (Owner-Regel): Pruefe vor der Arbeit mit ListAgents, ob parallele Sessions in diesem Repo laufen, und folge dem Skill /coordinate (eine leitende Session mit Merge-Hoheit, 15-Minuten-Statusrunde per CronCreate, Sessions stimmen sich direkt ab und informieren die Leitung, Release-Umfang fragt die Leitung beim Owner ab). NIE im Bypass-Modus koordinieren: andere Sessions halten dann jede Nachricht zur Freigabe fest, bis sie verfaellt. Claude kann den Modus nicht selbst umstellen -> laeuft diese Session mit "Bypass permissions", ZUERST anhalten und den Owner bitten, auf "Auto" zu wechseln (der PreToolUse-Hook coordination_mode_guard.ps1 sperrt ListAgents/SendMessage sonst).'
    $out = @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $ctx } } | ConvertTo-Json -Compress -Depth 5
    Write-Output $out
} catch { }
exit 0
