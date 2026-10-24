# lifeagents: n8n-Port nur fuer vertraute Reverse Proxys (nftables-Tabelle inet @@FW_TABLE@@).
# Rendered by provisioning (lib/firewall.sh) — nicht von Hand aendern; Aendern: lifeagents proxy set <adresse>.
# Eigene Tabelle statt /etc/nftables.conf (dessen `flush ruleset` loescht fremde Tabellen); PartOf/
# ReloadPropagatedFrom: nach einem restart/reload von nftables.service wird die Tabelle neu geladen.
[Unit]
Description=lifeagents: n8n nur fuer den vertrauten Reverse Proxy freigeben (nftables)
After=nftables.service
PartOf=nftables.service
ReloadPropagatedFrom=nftables.service
Before=n8n.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f @@FW_FILE@@
ExecReload=/usr/sbin/nft -f @@FW_FILE@@
ExecStop=-/usr/sbin/nft delete table inet @@FW_TABLE@@

[Install]
WantedBy=multi-user.target
