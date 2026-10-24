# lifeagents: Konfiguration für deinen Reverse Proxy (Caddy). Von außen erreichbar sind nur die
# Telegram-/Webhook-Pfade, alles andere antwortet mit 404. Caddy holt das HTTPS-Zertifikat selbst.

@@SITE_ADDRESS@@ {
	# >>> lifeagents-webhooks (dieser Block ist zugleich der Einfüge-Baustein für einen bestehenden Proxy)
	# /webhook-waiting/* ist Pflicht für die Bestätigungs-Knöpfe (ohne hängt jede Bestätigung); mit /webhook-waiting-telegram
	# antworten sie direkt im Chat statt über eine Webseite (lifeagents doctor zeigt, ob es greift).
	@lifeagents path /webhook/* /webhook-test/* /webhook-waiting/* /webhook-waiting-telegram
	handle @lifeagents {
		reverse_proxy @@N8N_UPSTREAM@@
	}
	# <<< lifeagents-webhooks

	# Alles andere (n8n-Editor, /rest, /api) bleibt von außen gesperrt.
	handle {
		respond "Not Found" 404
	}
}
