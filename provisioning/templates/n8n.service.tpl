[Unit]
Description=n8n workflow automation (life-agents)
Documentation=https://docs.n8n.io
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=@@N8N_USER@@
Group=@@N8N_USER@@
EnvironmentFile=@@N8N_ENV_FILE@@
# Optional owner/identity overlay, written by bootstrap_owner.sh (Phase 4). The leading
# '-' makes it tolerated-if-absent, so a schema-only Phase 1/2 install still boots.
EnvironmentFile=-@@N8N_OWNER_ENV_FILE@@
WorkingDirectory=@@N8N_HOME@@
# Outbound calls (Telegram, Anthropic) prefer IPv4: n8n resolves hostnames through its own SSRF lookup, which
# follows Node's default order (IPv6 first) and cannot fall back — a stalled IPv6 path in a home network
# (FritzBox prefix renewal, provider peering) then blocks every reply for the full 127 s TCP timeout.
# Node CLI docs: --dns-result-order is allowed in NODE_OPTIONS; the env file may still override it.
Environment=NODE_OPTIONS=--dns-result-order=ipv4first
ExecStart=@@N8N_BIN@@ start
Restart=on-failure
RestartSec=5
# Give n8n room: first boot runs DB migrations.
TimeoutStartSec=120
# Light hardening (n8n needs to read its env file + write to N8N_USER_FOLDER).
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
