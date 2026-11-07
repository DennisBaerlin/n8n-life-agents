[Unit]
Description=n8n-life-agents: Release-Check alle 2 Stunden

[Timer]
# Gerade Stunden :20 in der HAUSHALTS-Zeitzone (HOUSEHOLD_TIMEZONE, nie die Container-Zeitzone). Ob eine Karte kommt,
# entscheidet core.fn_release_card zur Laufzeit (Erinnerungs-Fenster aus der DB) — hier nichts davon einbacken.
# Kein Persistent=: kein Nachhol-Lauf beim Booten um 3 Uhr; OnBootSec/OnUnitActiveSec wuerde an der Bootzeit driften.
OnCalendar=*-*-* 00/2:20:00 @@TIMEZONE@@
Unit=lifeagents-update-check.service

[Install]
WantedBy=timers.target
