[Unit]
Description=LLM-Gateway (life-agents): Prompt-Caching + Nutzungs-Messung fuer Claude
Documentation=https://platform.claude.com/docs/en/build-with-claude/prompt-caching
After=network-online.target
Wants=network-online.target
# n8n ruft Claude ueber diesen Dienst (Anthropic-Credential url -> 127.0.0.1) — vor n8n starten.
Before=n8n.service

[Service]
Type=simple
# Keine Dateien/Secrets auf Platte (der API-Key kommt je Anfrage im Header) -> fluechtiger System-User.
DynamicUser=yes
Environment=LLM_GATEWAY_PORT=@@GATEWAY_PORT@@
# Cache-Keep-Alive: Stunden nach der letzten Nutzung eines Agenten-Anfangs (0 = aus; install_llm_gateway.sh).
Environment=LLM_GATEWAY_KEEPALIVE_HOURS=@@KEEPALIVE_HOURS@@
# Ausgehend IPv4 bevorzugen (api.anthropic.com hat AAAA): ein haengender IPv6-Pfad im Heimnetz kostete sonst
# den vollen TCP-Timeout je Claude-Aufruf — dieselbe Massnahme wie in n8n.service.tpl.
Environment=NODE_OPTIONS=--dns-result-order=ipv4first
ExecStart=@@NODE_BIN@@ @@GATEWAY_JS@@
Restart=on-failure
RestartSec=2
# Haertung: lauscht nur auf 127.0.0.1, spricht nur HTTPS nach aussen, schreibt nichts.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
MemoryMax=256M

[Install]
WantedBy=multi-user.target
