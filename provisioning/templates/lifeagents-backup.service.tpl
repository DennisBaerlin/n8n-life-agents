[Unit]
Description=n8n-life-agents: taegliche verschluesselte Sicherung der Nutzerdaten
Documentation=https://github.com/@@REPO_SLUG@@/blob/main/docs/reference/provisioning.md
After=network-online.target postgresql.service
Wants=network-online.target
# Bewusst KEIN Requires=/PartOf=/BindsTo= auf n8n.service: die Sicherung liest nur die Datenbank. Gestartet nur vom Timer.

[Service]
Type=oneshot
ExecStart=@@CLI_BIN@@ backup auto --scheduled
TimeoutStartSec=30min
Nice=10
