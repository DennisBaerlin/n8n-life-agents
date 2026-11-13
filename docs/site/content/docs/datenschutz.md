---
title: "Datenschutz & Sicherheit"
---

Deine Finanz-, Karriere- und Vorsorgedaten sind sensibel. Diese Seite erklärt, wo sie liegen, wann sie das Haus verlassen und welche Sicherungen eingebaut sind — ohne Technik-Vorwissen verständlich.

## Alles läuft bei dir zuhause

Der ganze Assistent läuft auf einer eigenen, selbst betriebenen kleinen Servermaschine (self-hosted n8n auf einer Debian-VM im eigenen Netzwerk) oder, mit der Start-App, auf deinem eigenen Mac oder PC, jeweils mit einer eigenen Datenbank (PostgreSQL). Es gibt keinen fremden Cloud-Dienst, der deine Daten dauerhaft speichert. Nach außen ist die Maschine bewusst eng abgeriegelt: ein vorgeschalteter Web-Türsteher (dein Reverse Proxy, z. B. Caddy, oder beim Tunnel Tailscale) lässt ausschließlich die Telegram-Nachrichtenwege durch — jeder andere Zugriffsversuch, etwa auf die Verwaltungsoberfläche, wird abgewiesen.

## Nach draußen geht nur, was für eine Antwort nötig ist

Damit ein Agent überhaupt „denken" kann, schickt er deine Anfrage an ein Sprachmodell (Claude von Anthropic; nur Sprachnachrichten wandelt Googles Gemini in Text um) — das ist technisch unvermeidbar. Das passiert aber **gezielt und nur für die eine Anfrage**, die du gerade stellst, nicht als Hintergrund-Abgleich oder Dauerübertragung. Deine gespeicherten Kontostände, Verläufe und Dokumente liegen dauerhaft nur in der eigenen Datenbank; an Claude geht nur, was für die eine Antwort gebraucht wird (fragst du nach deinem Kontostand, gehört er dazu). Laut [Anthropic](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data) werden Anfragen und Antworten nach spätestens 30 Tagen gelöscht; länger nur bei Verdacht auf Regelverstöße (bis zu 2 Jahre) oder wenn ein Gesetz es verlangt.

Auf dem Weg zu Anthropic gibt es einen kleinen **Zwischenschritt auf deinem eigenen Server**: Er markiert den immer gleichen Anfang jeder Anfrage (Anweisungen und Werkzeug-Beschreibungen des Agenten), damit Anthropic ihn zwischenspeichert und nicht jedes Mal voll berechnet (Prompt-Caching — spart den Großteil der Kosten). Dieser Zwischenschritt reicht deine Anfrage nur weiter; er notiert nur Zahlen: wie viel Text verarbeitet wurde und welcher Assistent die Anfrage geschickt hat, nie was darin stand. Diese Zahlen legt er für 62 Tage in einer Datei auf deinem Server ab, und übernimmt sie jede Nacht sowie bei `/costs` in deine Datenbank (dort 13 Monate) — daraus entsteht die Kostenübersicht. Damit der Zwischenspeicher bei Anthropic nicht nach einer Stunde verfällt, behält er den immer gleichen Anfang (Anweisungen und Werkzeug-Beschreibungen, nie deine Gespräche) bis zu 24 Stunden nach der letzten Nutzung im Arbeitsspeicher und schickt ihn knapp jede Stunde (alle 55 Minuten) kurz an Anthropic. Abschalten: `LLM_GATEWAY_KEEPALIVE_HOURS=0` in `/etc/lifeagents/core.env`, dann `lifeagents update`. Deine Daten gehen dadurch an niemanden zusätzlich.

**Mit der [Start-App](start-app.html)** kommen beim Einrichten diese Abfragen dazu:

- **FritzBox-Weg:** Die App fragt einmal den Dienst `api.ipify.org` nach der öffentlichen IPv4-Adresse deines Anschlusses. Sie braucht die Antwort nur, um DS-Lite zu erkennen. Der Dienst gibt nur diese Adresse zurück, eine Anmeldung gibt es nicht, und die App wartet höchstens 4 Sekunden. Wie bei jedem Aufruf einer Webseite sieht der Dienst dabei deine öffentliche Adresse.
- **MyFRITZ!-Kennung:** Die App liest sie aus dem Zertifikat deiner FritzBox, im Heimnetz. Dabei geht nichts nach draußen.
- **Paperless:** Die App sucht ein vorhandenes Paperless nur in deinem eigenen Heimnetz.
- **Tunnel-Weg:** Tailscale sieht, dass Verbindungen zu deinem Rechner laufen (siehe [Tunnel → Grenzen](tunnel.html#grenzen)).

## Dokumente und Lebensläufe: nur über den bezahlten Tarif

Fotos von Kontoauszügen, hochgeladene Dokumente, deine Paperless-Dokumente und Lebensläufe sind besonders sensibel. Für deren Auswertung wird ausschließlich ein **bezahlter** Zugang verwendet (die Anthropic-Schnittstelle für alle Agenten — Belege, Lebensläufe, Dokumenten-Assistent und Gedächtnis-Vorschläge —, der kostenpflichtige Google-Gemini-Zugang nur für Sprachnachrichten), nie eine kostenlose Variante. Der Grund: Die Anbieter sichern für den bezahlten Zugang vertraglich zu (bei Anthropic in den [Commercial Terms](https://www.anthropic.com/legal/commercial-terms)), die eingereichten Daten **nicht** zum Trainieren ihrer Modelle zu verwenden — bei Gratis-Varianten gilt diese Zusage nicht. Eine Ausnahme liegt außerhalb dieses Systems: Fragen an die KI *in* Paperless (siehe [Dokumente](dokumente.html)) nutzen den Anbieter, den du in Paperless selbst eingestellt hast.

Paperless-Dokumente darf außerdem nur ein **erwachsenes** Haushaltsmitglied abfragen; was der Bot dort überhaupt sieht, bestimmen die Rechte des Paperless-Nutzers, mit dem er liest.

## Bestätigungsstufen im Haushalt

Jede Änderung an deinen Daten — eine neue Buchung, ein geändertes Konto, ein gelöschter Eintrag — muss erst per Knopfdruck (Inline-Button in Telegram) bestätigt werden, bevor sie wirklich gespeichert wird (Bestätigungs-Gate). Bei mehreren Haushaltsmitgliedern gibt es dabei drei Stufen, abgestuft nach Risiko:

- **Nur der Owner** darf es überhaupt anstoßen (z. B. Berater-Pläne ändern) — andere Mitglieder werden hart blockiert.
- **Vier-Augen-Prinzip:** ein Mitglied stößt es an, der Owner muss zusätzlich zustimmen (z. B. ein Konto ändern oder löschen).
- **Owner wird informiert:** ein Mitglied bestätigt selbst, der Owner bekommt nur eine Nachricht (z. B. eine neue Buchung anlegen).

```
Erika: Bitte lösch das Konto "Tagesgeld".
Bot:   Konto löschen – bitte prüfen:
       • Konto: Tagesgeld
       [Bestätigen] [Abbrechen]
(Erika bestätigt → geht zusätzlich an den Owner zur Freigabe)
```

Wichtig: Eine einfache Textantwort erreicht eine wartende Bestätigung **nicht** — erst abbrechen, dann neu und klarer formulieren (mehr dazu auf [Chatten & Bestätigen](chatten-bestaetigen.html)).

## Wer darf welche Knöpfe drücken?

Auch die Karten, die der Assistent von sich aus schickt, haben Knöpfe: Job-Vorschläge des Karriere-Coachs mit 👍/👎, im Ernstfall die Aufgaben-Erinnerungen des Nachlass-Beraters mit „Erledigt/Entfällt". Diese Knöpfe an den **eigenen** Karten darf jedes eingeladene Haushaltsmitglied selbst bedienen — die Job-Bewertung nur an der eigenen Karte, eine Notfall-Aufgabe jeder Erwachsene im Haushalt (damit der überlebende Partner im Ernstfall nicht blockiert ist; ein Kind ist von diesen Erwachsenen-Aktionen ausgeschlossen). Die **Verwaltungsknöpfe des Owners** dagegen — Einladungen bestätigen oder ablehnen, jemanden sperren, die Erinnerungs-Automatik an- und ausschalten — bleiben allein beim Owner und sind für Mitglieder gar nicht erreichbar. Wer getippt hat, ermittelt das System dabei immer selbst neu; es verlässt sich nie auf eine mitgeschickte Angabe — so kann niemand einen fremden Knopf in fremdem Namen auslösen.

## Alles oder nichts beim Speichern

Jede Änderung läuft als **eine einzige, unteilbare Datenbank-Operation** (atomare Transaktion): entweder werden alle zugehörigen Schritte einer Buchung gespeichert, oder keiner. Ein halb geschriebener, kaputter Zustand ist damit ausgeschlossen — etwa bei einem Abbruch mittendrin.

## Backups sind doppelt verschlüsselt

Ein Backup ist mit einem etablierten Standardverfahren verschlüsselt (GPG, AES256) und lässt sich nur mit seinem Schlüssel öffnen. Den Schlüssel gibt es an zwei Stellen: in deiner eigenen Datenbank, damit die tägliche Sicherung von selbst läuft, und auf dem **Notfallblatt**, das du ausdruckst oder in deinem Passwort-Manager aufbewahrst, also außerhalb des Rechners. Nur damit öffnet sich eine Sicherung auf einem neuen Rechner. Im Chat und im Code steht er nie. Ein Wiederherstellen prüft vorher, welche Pakete/Tabellen überschrieben würden, und verlangt eine ausdrückliche Bestätigung, bevor irgendetwas gelöscht wird. Mehr unter [Sicherung & neuer Rechner](sicherung.html).

## Nur bekannte Personen kommen durch

Der Bot reagiert nicht auf jeden, der ihm schreibt. Nur Telegram-Konten, die zuvor per Einladungscode mit dem Haushalt verknüpft wurden (gepairt), erreichen die Agenten überhaupt. Schreibt jemand Unbekanntes, bekommt ausschließlich der Owner eine Benachrichtigung — die Nachricht selbst geht nirgendwo weiter.

## Eine Sicherheitslücke gefunden?

Melde sie bitte nicht öffentlich, sondern über den privaten Meldeweg, der in der Datei `SECURITY.md` im Projekt-Repository (auf Englisch) beschrieben ist — dort steht auch, welche Bereiche besonders sicherheitsrelevant sind.
