[Unit]
Description=n8n-life-agents: alle 2 Stunden nach neuen Releases sehen und dem Owner eine Update-Karte schicken
Documentation=https://github.com/@@REPO_SLUG@@/blob/main/docs/reference/provisioning.md
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=@@CLI_BIN@@ update --check --scheduled
TimeoutStartSec=5min
Nice=10
