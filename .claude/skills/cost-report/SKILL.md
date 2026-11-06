---
name: cost-report
description: Monatliche Routine am 1. – KI-Kostenbericht des Vormonats mit der Rechenmechanik von /costs, Cache-Trefferquote und Trend. Nur lesend auf dem Live-LXC, Bericht als privates Artefakt. Nutzen für den geplanten Lauf oder auf Zuruf „was hat die KI im Monat gekostet“.
---

# KI-Kostenbericht (`/cost-report`)

Der Telegram-Befehl `/costs` zeigt 7 und 30 Tage. Diese Routine liefert volle Kalendermonate mit Trend und Cache-Trefferquote. Gerechnet wird mit derselben Formel wie `core.fn_get_llm_cost_report` (`packages/core/db/migrations/R__fn_get_llm_cost_report.sql`; den Kopf lesen, falls sie sich geändert hat — die fn ist die Wahrheit, dieser Skill folgt ihr).

## Harte Grenzen

- **Nur lesend**, wie bei `/live-findings`: Zugang aus der `.env` des Haupt-Checkouts (`DEV_INSTANCE_*`), Rezept und Dauer-Erlaubnis in den Memory-Notizen `owner-instance-ssh-access` und `live-system-read-permission`; `SET default_transaction_read_only = on;`. Kein Import (`core.fn_import_llm_usage` schreibt) und keine Änderung am System.
- Der Bericht ist privat (Beträge): nie ins Repo, nur privates Artefakt/Dokument im Konto des Owners. Host und Zugangsdaten nie in den Bericht.

## Kosten-Politik

Die Fleißarbeit macht ein Sonnet-Unteragent (`Explore`): Datenstand prüfen, SQL bzw. Mitschrift lesen und die Summen je Monat/Workflow/Modell liefern. Du prüfst die Summen stichprobenartig nach (z. B. Gesamtsumme gegen die Teilsummen), ordnest ein und schreibst den Bericht.

## Ablauf

1. **Datenstand prüfen:** `SELECT min(ts), max(ts), count(*) FROM core.llm_usage;`. Der Import passiert nur, wenn jemand `/costs` aufruft. Ist `max(ts)` älter als der letzte Tag des Berichtsmonats (oder die Tabelle leer), ist der Monat unvollständig:
   - im Bericht ganz oben benennen und den Owner bitten, einmal `/costs` in Telegram zu senden (danach den Lauf wiederholen). Nicht selbst importieren.
   - **Ersatzquelle für einen vorläufigen Bericht:** die Gateway-Mitschrift per GET `127.0.0.1:8090/__usage?after=<id>&limit=5000` auf dem Server (nur lesen, seitenweise über `next_after`, solange `has_more` wahr ist). Gleiche Formel anwenden und den Bericht ausdrücklich „vorläufig, aus der Gateway-Mitschrift“ nennen. Zeilen ohne gültige id lassen sich später nicht in die Datenbank importieren (`core.fn_import_llm_usage` überspringt sie): die Summen weichen nach dem Import ab, das im Bericht sagen.
   - **Dauerhaft leere oder veraltete Tabelle (älter als 7 Tage) ist selbst ein Befund:** Der Import hängt am manuellen `/costs`, die Mitschrift-Datei des Gateways rotiert und verliert dann die ältesten Zeilen. Frist (ältester Zeitstempel der Datei plus Aufbewahrung laut `docs/reference/provisioning.md` *LLM-Gateway*) im Bericht nennen und „täglicher automatischer Import“ als Backlog-Vorschlag aufnehmen, falls er noch nicht im privaten Backlog steht.
2. **Monatssummen** (Vormonat M und der Monat davor M-1; Kalendermonat in der Datenbank-Zeitzone). Gleiche Preislogik wie die fn: Preise über `agent.ai_models.n8n_model_id = core.llm_usage.model`, `pricing_usd_per_mtok` mit den Schlüsseln `input`, `cache_write_5m`, `cache_write_1h`, `cache_read`, `output`, `web_search_usd_per_request`; Langkontext-Stufe (`long_context.above_input_tokens`) und Warmhalte-Zeilen (`keepalive`) wie in der fn. Je Monat, je Workflow (`wf`) und je Modell: Kosten, Anzahl echter Anfragen (ohne `keepalive`), aufgeteilt nach Kostenart. Zeilen ohne Preis zählen nicht in die Summe, werden aber gezählt und genannt.
3. **Cache-Trefferquote** je Monat und je Workflow: `sum(cache_read_input_tokens) / sum(input_tokens + cache_creation_input_tokens + cache_read_input_tokens)` über echte Anfragen. Kaltstarts (1h-Cache-Write ≥ `core.config` `cost.cold_start_min_tokens`) je Monat zählen und mit Kosten nennen.
4. **Trend:** M gegen M-1 absolut und in Prozent, je Workflow und je Modell. Nur vergleichen, wenn beide Monate volle Daten haben (`min(ts)` vor dem Monatsersten von M-1); sonst „kein Vergleich möglich“ mit Grund.
5. **Einordnung:** die größten drei Posten und was den Trend erklärt (neues Modell, mehr Gespräche, schlechtere Trefferquote, Kaltstarts nach Updates). Nur belegte Aussagen; Vermutungen als solche kennzeichnen.
6. **Vorschläge** (kein Umbau auf eigene Faust): Kostentreiber, die man mit Modell-Politik, Prompt-Länge oder Cache-Verhalten senken könnte; je Vorschlag Wirkung grob in USD/Monat und Risiko. Aufnehmen ins private Backlog tut eine Session auf das Wort des Owners. Das Artefakt ist eine statische Seite ohne Knopf: Nummeriere die Vorschläge und schreibe am Ende den Satz, den der Owner in einer neuen Sitzung im Repo sagt (z. B. „Nimm Vorschlag 2 aus dem Bericht KI-Kosten <Monat> ins Backlog auf“).

## Bericht

Privates Artefakt `KI-Kosten <Monat Jahr>`, einfache deutsche Sprache. Aufbau: Kurzfazit (Gesamtkosten, Trend in einem Satz) · Tabelle je Workflow (M, M-1, Änderung) · Tabelle je Modell · Kostenarten in Prozent · Cache-Trefferquote und Kaltstarts · Vorschläge · Datenstand und Lücken. Link ausgeben, die Zahlen nicht in die Chat-Antwort kopieren.
