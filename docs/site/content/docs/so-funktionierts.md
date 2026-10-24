---
title: "So funktioniert's"
---

Diese Seite zeigt dir das grobe Bild (das mentale Modell) hinter dem Assistenten — kein technisches Pflichtenheft, sondern die Stationen, die deine Nachricht durchläuft, bis etwas passiert. Wenn du tiefer einsteigen willst, findest du Details zu den einzelnen Agenten unter [Buchhalter](buchhalter.html), [Finanzberater](finanzberater.html), [Karriere-Coach](karriere-coach.html), [Nachlass & Vorsorge](nachlass-berater.html) und [Monitor & Guide](monitor-guide.html), sowie zum Bestätigen von Aktionen unter [Chatten & Bestätigen](chatten-bestaetigen.html).

## Der Weg deiner Nachricht

Alles läuft über **einen** Telegram-Bot — es gibt keine separaten Bots pro Thema. Von dort aus geht deine Nachricht mehrere Stationen entlang, bis eine Antwort oder eine Buchung zurückkommt:

1. **Telegram** schickt deine Nachricht als sogenannten Webhook (eine automatische Benachrichtigung an eine feste Adresse) an den Server.
2. **Dein Reverse Proxy** (z. B. Caddy) ist der Türsteher davor: er verwaltet die Verschlüsselung (HTTPS) und lässt **ausschließlich** die für Telegram bestimmten Adress-Pfade durch. Alles andere — insbesondere der direkte Zugriff auf die n8n-Oberfläche oder ihre Programmierschnittstelle (API) — wird von außen blockiert. So bleibt der Server nach außen praktisch unsichtbar, obwohl der Bot rund um die Uhr erreichbar ist. (Der Reverse Proxy wird nicht mitinstalliert — du bringst ihn selbst mit; der Installer liefert eine fertige Konfiguration dafür.)
3. **n8n** ist die Automatisierungs-Plattform, auf der der gesamte Assistent läuft — jeder Baustein (Orchestrator, Agenten, Werkzeuge) ist darin ein eigener, sichtbar verdrahteter Ablauf (Workflow).
4. Der **Orchestrator** ist die erste Anlaufstelle: Er liest, worum es in deiner Nachricht geht, und entscheidet, welcher Spezialist zuständig ist — Buchung/Fakten an den Buchhalter (auch das Nachschlagen des aktuellen Zinses deiner Konten), Meinung/Planung/Recherche an den Finanzberater, Trigger-Mechanik an den Monitor, Karrierefragen an den Karriere-Coach, Nachlass- und Vorsorgefragen an den Nachlass-Berater. Er beantwortet nichts selbst inhaltlich, sondern reicht nur weiter.
5. Der zuständige **Agent** übernimmt: er liest bei Bedarf deine gespeicherten Daten, denkt nach, und will er etwas verändern, bereitet er einen Vorschlag vor.
6. Bevor irgendetwas dauerhaft gespeichert wird, kommt das **Bestätigungs-Gate**: Du siehst die genauen Werte als Nachricht mit Tastenfeld (Bestätigen/Abbrechen) und musst aktiv zustimmen — nichts landet ungefragt in deinen Daten. Details dazu stehen unter [Chatten & Bestätigen](chatten-bestaetigen.html).
7. Erst nach deiner Bestätigung schreibt der jeweilige Agent in **PostgreSQL**, die Datenbank, in der alle deine Informationen liegen — Konten, Pläne, Gedächtnis-Einträge, alles an einem Ort.

## Wann sich der Bot von selbst meldet

Der Bot schreibt dir nicht wahllos, sondern folgt einem roten Faden in drei Phasen:

- **Ankommen:** Begrüßung, Sprache, Haushalt einrichten.
- **Einrichten:** Innerhalb eines Bereichs (z. B. Finanzen) führt dich der zuständige Agent Schritt für Schritt. Ist ein Bereich fertig, kommt sofort eine Karte mit dem nächsten Schritt und einem „Weiter"-Knopf. Bleibt das Einrichten liegen, erinnert dich der Bot nach 3 Tagen einmal und nach 10 Tagen ein letztes Mal. Danach ist Ruhe, und mit „Nicht mehr erinnern" schaltest du das auch vorher ab. Sobald der Owner den Haushalt fertig hat, bekommen die anderen im Haushalt einmal die Nachricht „Es kann losgehen". Wenn alles eingerichtet ist, fragt der Bot einmal, ob er aus euren Gesprächen dazulernen soll.
- **Begleiten:** Danach meldet sich der Bot nur noch, wenn es etwas Wichtiges gibt. Erinnerungen zu einem Bereich kommen erst, wenn du ihn begonnen hast: Solange du Nachlass & Vorsorge nicht angefangen hast, mahnt der Bot dort nichts an und lädt dich nur zum Einrichten ein.

Alles, was der Bot von sich aus schickt, siehst du mit **`/reminders`** (oder `/erinnerungen`): eine Liste mit Zeitplan und Stand, ein Tipp schaltet einen Eintrag an oder aus. Jede Erinnerungskarte lässt sich außerdem direkt an der Karte abschalten. Erinnerungen für den Haushalt schaltet der Owner, persönliche (z. B. Job-Vorschläge) jede Person für sich. Fristen im Todes- oder Vorsorgefall bleiben immer an.

Erinnerungen, die nicht eilen, kommen **nur zwischen 10 und 20 Uhr**. Was abends oder nachts fällig wird, wartet bis zum nächsten Morgen um 10. Sofort, auch nachts, melden sich nur die Wert-Wächter, die du selbst bestellt hast (z. B. „sag mir, wenn Bitcoin unter 50.000 fällt"). Nach einer Buchung oder einem Import nennt dir der Bot höchstens **einen** Hinweis, und zwar den wichtigsten: Wird das Geld knapp, geht das vor Ordnungs-Themen wie einer fehlenden Anlageklasse.

## Das Gedächtnis in vier Schichten

Der Assistent merkt sich Dinge auf vier verschiedenen Ebenen, die unterschiedlich „präsent" sind: erstens Instruktionen, die **jeder Agent bei jeder Nachricht automatisch mitbekommt** (sein grundlegendes Rollenverständnis); zweitens größere Wissens-Dokumente, die **nur bei Bedarf nachgeladen** werden, damit nicht jede Nachricht unnötig viel „mitschleppt"; drittens der **Chat-Verlauf**, den jeder Agent getrennt für sich führt — der Buchhalter erinnert sich nicht an das, was du dem Finanzberater erzählt hast, und umgekehrt; viertens deine **strukturierten Daten** — Konten, Ziele, Profile — die dauerhaft in eigenen Tabellen liegen und die eigentliche Grundlage für Antworten und Buchungen bilden.

## Welches KI-Modell wo arbeitet

Nicht jede Anfrage braucht das teuerste Sprachmodell. Alle Agenten laufen auf Claude von Anthropic, je nach Aufgabe in einer anderen Stufe: Die Weiterleitung (Routing) und kurze Erinnerungstexte übernimmt das sehr günstige Claude Haiku; Buchhaltung, Hilfe, Monitoring, Websuche und das Auslesen von Fotos/Belegen (Vision) Claude Sonnet. Nur Sprachnachrichten wandelt Googles Gemini in Text um, weil Claude kein Audio versteht. Nur die Berater-Agenten — Finanzberater, Karriere-Coach und Nachlass-Berater — laufen mit einem leistungsstärkeren, aber deutlich teureren Modell von Anthropic (Opus) — weil dort echtes Abwägen und Argumentieren gefragt ist, nicht nur strukturiertes Ausfüllen.

## Schutz vor Endlosschleifen

Ein technischer Zähler sorgt dafür, dass sich Agenten niemals gegenseitig oder sich selbst in einer Schleife aufrufen können und dadurch unkontrolliert Kosten verursachen.
