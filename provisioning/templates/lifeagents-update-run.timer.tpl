[Unit]
Description=n8n-life-agents: jede Minute nach Update-Auftraegen aus dem Chat sehen

[Timer]
# Ein Auftrag entsteht, wenn der Owner auf der Release-Karte [Jetzt aktualisieren] tippt (core.update_requests);
# ohne Auftrag kostet ein Lauf eine DB-Abfrage. Laeuft der Dienst noch, startet systemd ihn nicht doppelt.
OnCalendar=*:*:00
AccuracySec=5s
Unit=lifeagents-update-run.service

[Install]
WantedBy=timers.target
