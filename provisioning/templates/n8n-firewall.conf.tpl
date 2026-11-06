# lifeagents (lib/firewall.sh): FAIL-CLOSED — n8n lauscht hier im Heimnetz (0.0.0.0) und darf NUR mit
# geladener Firewall-Tabelle laufen. Requires: faellt die Firewall weg (stop/restart), stoppt n8n mit.
# ExecStartPre mit '+' laeuft als root (n8n selbst laeuft als User n8n, nft braucht CAP_NET_ADMIN).
[Unit]
Requires=@@FW_UNIT@@
After=@@FW_UNIT@@

[Service]
ExecStartPre=+/usr/sbin/nft list table inet @@FW_TABLE@@
