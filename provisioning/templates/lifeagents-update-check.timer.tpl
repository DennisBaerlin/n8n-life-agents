[Unit]
Description=n8n-life-agents: taeglicher Release-Check

[Timer]
# 10:20 Uhr in der HAUSHALTS-Zeitzone (HOUSEHOLD_TIMEZONE, nie die Container-Zeitzone) — im Erinnerungs-Fenster,
# nie nachts. Kein Persistent=: ein verpasster Tag holt der naechste nach (kein Nachhol-Lauf beim Booten um 3 Uhr).
OnCalendar=*-*-* 10:20:00 @@TIMEZONE@@
Unit=lifeagents-update-check.service

[Install]
WantedBy=timers.target
