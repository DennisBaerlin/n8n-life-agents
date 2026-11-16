[Unit]
Description=n8n-life-agents: Release-Check alle 2 Stunden

[Timer]
# Gerade Stunden :20 in der HAUSHALTS-Zeitzone (HOUSEHOLD_TIMEZONE, nie die Container-Zeitzone). Ob eine Karte kommt,
# entscheidet core.fn_release_card zur Laufzeit (Erinnerungs-Fenster aus der DB) — hier nichts davon einbacken.
# Kein Persistent=: kein Nachhol-Lauf beim Booten um 3 Uhr; OnBootSec/OnUnitActiveSec wuerde an der Bootzeit driften.
# Sekunde 30 mit enger Genauigkeit: lifeagents-update-run haelt zu jeder vollen Minute kurz die Update-Sperre. Der Check
# wartet zwar auf sie (update_check), der Abstand haelt den Normalfall aber ganz aus dem Rennen.
OnCalendar=*-*-* 00/2:20:30 @@TIMEZONE@@
AccuracySec=1s
Unit=lifeagents-update-check.service

[Install]
WantedBy=timers.target
