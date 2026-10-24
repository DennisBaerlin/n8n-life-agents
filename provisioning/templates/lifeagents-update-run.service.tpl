[Unit]
Description=n8n-life-agents: Update-Auftraege aus dem Chat ausfuehren (root-Runner)
Documentation=https://github.com/@@REPO_SLUG@@/blob/main/docs/reference/provisioning.md
After=network-online.target postgresql.service
Wants=network-online.target
# Bewusst KEIN Requires=/PartOf=/BindsTo= auf n8n.service: das Update startet n8n neu und darf dabei nicht selbst
# gestoppt werden (systemd.unit: PartOf/Requires propagieren Stop/Restart). Gestartet nur vom Timer.

[Service]
Type=oneshot
ExecStart=@@CLI_BIN@@ update --run-requested
# Ein Update (n8n-npm-Install, Sicherung, Migrationen) dauert Minuten; Schutz gegen Haengen.
TimeoutStartSec=2h
Nice=5
# Minuetlicher Leerlauf ohne Journal-Rauschen (sonst ~6000 Zeilen/Tag Start/Stopp + runuser-PAM): nur notice und
# hoeher. Fehler und gestartete Updates schreibt der Runner mit Syslog-Praefix <4>/<5> (update_runner.sh _ur_alert/
# _ur_notice) -> sie bleiben sichtbar; die volle Ausgabe eines Updates steht in /var/log/lifeagents/update-<zeit>.log.
LogLevelMax=notice
