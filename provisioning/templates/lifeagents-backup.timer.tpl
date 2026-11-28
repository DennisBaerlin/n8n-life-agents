[Unit]
Description=n8n-life-agents: taegliche Sicherung (ab @@HOUR@@:@@MINUTE@@, bei Fehlschlag stuendlich neu)

[Timer]
# Ab BACKUP_AUTO_AT stuendlich zur selben Minute bis 23 Uhr, in der Haushalts-Zeitzone (nie die Container-Zeitzone). Die Entscheidung "heute
# schon gesichert?" trifft `backup auto --scheduled` aus backup.state (LAST_OK) — ein Lauf nach dem Erfolg kostet nichts; so holt der
# naechste Lauf eine belegte Update-Sperre oder eine abwesende Platte nach, wie der Tick im Docker-Verbund.
# Persistent=: war der Rechner zur Zeit aus, laeuft die Sicherung beim Hochfahren.
OnCalendar=*-*-* @@HOUR@@..23:@@MINUTE@@:00 @@TIMEZONE@@
Persistent=true
Unit=lifeagents-backup.service

[Install]
WantedBy=timers.target
