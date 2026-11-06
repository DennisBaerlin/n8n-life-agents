# SessionStart-Hook: Erinnerung an die Session-Koordination (Skill /coordinate).
# Jede startende Session prueft, ob parallele Sessions laufen, und stimmt Leitung + Merge-Hoheit ab.
# Kein Lauf-Check hier (die Session-Liste kennt nur Claude via ListAgents) -> immer derselbe kurze Kontext.
# ASCII-only + Compact-JSON, damit kein BOM die stdout-JSON bricht. Nie ein Fehler-Exit.
try {
    $ctx = 'SESSION-KOORDINATION: Pruefe vor der Arbeit mit ListAgents, ob parallele Sessions in diesem Repo laufen, und folge dem Skill /coordinate; eine von der Leitung gestartete Session fragt nicht herum (Abschnitt 5). Laeuft diese Session mit "Bypass permissions", zuerst anhalten und den Owner bitten, auf "Auto" zu wechseln: im Bypass-Modus bleiben Nachrichten anderer Sessions haengen.'
    $out = @{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $ctx } } | ConvertTo-Json -Compress -Depth 5
    Write-Output $out
} catch { }
exit 0
