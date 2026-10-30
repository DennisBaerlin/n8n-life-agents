---
title: "Chatten & Bestätigen"
---

Du unterhältst dich mit deinem Assistenten wie mit einem Menschen: ganz normaler Fließtext, keine Befehls-Syntax, kein Auswendiglernen von Kommandos nötig (eine Handvoll fester Befehle wie `/start` gibt es trotzdem, dazu mehr auf der Seite [Befehle](befehle.html)). Du schreibst zum Beispiel „ich habe 50 Euro für Lebensmittel ausgegeben" oder „was hältst du von einer zweiten ETF-Sparrate?" — der Assistent leitet das automatisch an den passenden Spezialisten weiter (mehr dazu unter [So funktioniert's](so-funktionierts.html)).

## Jede Datenänderung zeigt vorher eine Bestätigungs-Karte

Sobald eine Nachricht wirklich etwas in deiner Datenbank verändern würde — eine neue Buchung, ein neues Konto, eine geänderte Sparrate — schreibt der Assistent **nicht sofort**. Er legt dir zuerst eine Karte mit allen aufgelösten Werten vor, inklusive automatisch ergänzter Standardwerte, und wartet auf deine Bestätigung. Das ist bewusst so gebaut (technisch: ein Bestätigungs-Gate mit Maker-Checker-Prinzip) — niemand, auch keine Fehlinterpretation des Assistenten, bucht ungefragt etwas.

```
Assistent: Neue Ausgabe buchen – bitte prüfen:
• Konto: Girokonto Erika
• Betrag: 50,00 €
• Kategorie: Lebensmittel
• Datum: 12.03.2026 (heute, Standard)

           [ ✅ Bestätigen ]  [ ❌ Abbrechen ]
```

Tippst du auf ✅, wird alles in einem einzigen, unteilbaren Schritt gebucht (technisch: eine Datenbank-Transaktion) — entweder passiert alles oder nichts, nie ein halb gebuchter Zustand. Tippst du auf ❌, bricht der Vorgang sauber ab, es wird nichts gespeichert.

Der Tipp geht direkt über Telegram an deinen Server — es öffnet sich kein Browserfenster, und es klappt im WLAN genauso wie unterwegs. Danach verschwinden die Knöpfe; die Antwort des Assistenten bestätigt, was gespeichert wurde. Nur die Person, an die die Karte ging, kann sie beantworten. Voraussetzung ist die Proxy-Weiterleitung `/webhook-waiting-telegram` (siehe [Installation](installation.html)); fehlt sie, öffnen die Knöpfe stattdessen eine Webseite (diese Ersatz-Seite zeigt n8n auf Englisch).

## Feste Texte in deiner Sprache

Der Assistent antwortet immer in der Sprache, in der du schreibst. Die **festen** Texte — Begrüßung, Bestätigungs-Karten, Knöpfe und ihre kurzen Rückmeldungen, die Übersicht unter `/help`, das `/onboarding`-Menü, Verbindungs- und Einladungs-Nachrichten, die Schalter für Erinnerungen — kommen dagegen in der Sprache, die für dich eingestellt ist: heute **Deutsch, English oder 한국어 (Koreanisch)**. Jede Person hat ihre eigene Einstellung. Schreibt zum Beispiel deine Partnerin auf Koreanisch und bucht etwas, bekommt sie die Karte auf Koreanisch, und du bekommst dieselbe Buchung zur Freigabe auf Deutsch. Beträge und Daten werden passend formatiert („1.234,50 €" bzw. „€1,234.50", „31.12.2026" bzw. „2026. 12. 31.").

Deine eigene Sprache wählst du bei der Installation (Vorauswahl Deutsch). Legst du im Chat eine neue Person an, schickt dir der Assistent danach eine Karte mit einem Knopf je Sprache; am Server geht es mit `lifeagents household add` (Auswahl am Ende). Jede Person kann ihre eigene Sprache jederzeit mit `/language` (oder `/sprache`) umstellen; du als Owner kannst sie für jede Person setzen. Verbindet sich ein Mitglied, das noch keine Sprache hat, bekommt es nach deiner Bestätigung die Auswahl-Karte; die Sprache seines Telegram-Programms ist darauf mit 👉 als Vorschlag markiert, gespeichert wird aber erst sein Tipp.

Das gilt auch für alles, was der Assistent **von sich aus** schickt: Erinnerungen (Daueraufträge, Zinsen, Saldo-Abgleich, Nachlass-Aufgaben), Berater-Hinweise und Quartals-Berichte, Trigger-Meldungen, Lern-Vorschläge, Job-Karten und die Fehler-Warnung an den Owner. Jede kommt in der Sprache der Person, an die sie geht. Bei Berater-Hinweisen formuliert der Assistent den Text in deiner Sprache, Zahlen und Daten setzt aber immer das Programm ein — so kann sich dabei nichts verrechnen. Die Notfallmappe bekommt, wer sie anfordert, in der eigenen Sprache; deutsche Rechtsbegriffe (z. B. „Vorsorgevollmacht") bleiben deutsch, in English und 한국어 mit kurzer Erklärung in Klammern.

Die Knöpfe einer Erinnerung sagen direkt, was sie tun, z. B. „✅ Ja, so buchen" / „✏️ Nein, anders". Nach deinem Tipp verschwinden sie, und eine kurze Ergebnis-Zeile bestätigt, was passiert ist (z. B. „Gebucht: Miete" oder „Miete war schon gebucht") — klappt etwas nicht, sagt sie das, und du kannst im Chat nach dem Stand fragen.

Eine Ausnahme: Das Befehls-Menü von Telegram (die Liste hinter „/") folgt der Sprache, auf die das Telegram-Programm eingestellt ist — Telegram lässt dieses Menü nur so steuern.

## Ein Charakter für den Bot

Mit `/persona` gibst du dem Bot einen Charakter: **🎩 Butler** (sehr höflich, siezt dich), **🎙️ Sportreporter** (aufgedreht wie im Live-Kommentar) oder **🧙 Weiser Meister** (ruhig, mit kleinen Weisheiten). Standard ist **🤖 Standard** ohne Charakter; im Menü führt der Knopf „↩️ Standard (ohne Charakter)" jederzeit dorthin zurück. Den Owner fragt schon die Installation danach; jede Person wählt ihren Charakter selbst, Haushaltsmitglieder starten im Standard. Der Charakter klingt in jeder Sprache passend, auf Koreanisch zum Beispiel als besonders förmlicher 집사 (Butler) oder als 도사 mit altertümlicher Sprache.

Jeder Charakter hat außerdem ein gezeichnetes Sticker-Set, der Standard einen kleinen Roboter. Ab und zu schickt der Bot einen davon vor seiner Antwort: „Hallo" auf eine reine Begrüßung, „Daumen hoch" nach einer bestätigten und gespeicherten Buchung, „Hmm" zu einer Datei und „Jubel", wenn die Einrichtung fertig ist. Höchstens ein Sticker alle 4 Stunden, bei ernsten Themen (Mahnung, Krankheit, Todesfall, Fehler, Abbruch) nie. Abschalten oder die Pause ändern: `lifeagents config set persona stickers_enabled false` bzw. `lifeagents config set persona sticker_cooldown_hours <Stunden>`.

Auf ein reines „Danke" (auch „Vielen Dank", „Thanks", ❤️) antwortet der Bot mit einem ❤️ an deiner Nachricht statt mit Text — dafür läuft keine KI. „Nein danke", „ja danke" oder eine Antwort auf eine Frage des Bots laufen ganz normal.

Der Charakter ist bewusst nur ein **Rahmen**: Begrüßung, Smalltalk und Rückfragen spricht der Bot ganz in seinem Stil, vor einer Fach-Antwort steht höchstens ein fester kurzer Satz wie „Sehr wohl, ich habe nachgesehen." Die Antwort selbst — Beträge, Daten, Namen, Warnungen — gibt der Bot immer Wort für Wort so weiter, wie der zuständige Assistent sie geschrieben hat; kein Sprachmodell formuliert sie unterwegs um, und der Rahmensatz bewertet sie nicht. Bei ernsten Themen (Trauer, Erbe, Gesundheit, Zahlungsnot, Warnungen, Fehler, Ablehnungen) lässt der Bot den Charakter weg; ein normaler Kredit zählt nicht dazu. Feste Texte wie Bestätigungs-Karten, Knöpfe und Erinnerungen bleiben immer neutral, und was gespeichert wird, ist nie im Charakter-Ton geschrieben.

## „Denkt nach …" während längerer Antworten

Geht deine Nachricht an den Assistenten — Text, Sprachnachricht, Foto oder Dokument —, zeigt Telegram in deinem privaten Chat eine kleine „Thinking…"-Blase, bis die Antwort da ist. So siehst du, dass gearbeitet wird, auch wenn eine ausführliche Beratung etwas dauert. Feste Befehle wie `/help` antworten sofort und brauchen sie nicht. Der Assistent frischt die Blase alle paar Sekunden auf, sodass sie durchgehend stehen bleibt, bis die Antwort kommt — auch wenn das eine Minute oder länger dauert. Liegt eine Bestätigungs-Karte offen vor dir, pausiert die Blase, damit sie nicht über der Karte steht; nach deinem Tipp kommt sie zurück, bis der Assistent fertig ist. Mit der Antwort verschwindet sie.

## Die Schlüsselregel: erst abbrechen, dann neu formulieren

**Eine Textantwort erreicht eine wartende Bestätigungs-Karte nicht.** Solange eine Karte offen ist, nimmt der Bot deshalb keine neue Nachricht an: Schreibst du stattdessen „nein, 60 Euro" (oder schickst eine Sprachnachricht), antwortet er nur mit dem Hinweis, erst auf der Karte zu tippen. Willst du etwas an der vorgeschlagenen Buchung ändern, tippe zuerst **❌ Abbrechen** und schick deine Korrektur danach noch einmal — dann kennt der Assistent alle Angaben der abgebrochenen Karte und muss nichts neu erfragen. Warte nach dem Tipp kurz meine Antwort ab, bevor du weiterschreibst. Ohne Tipp läuft eine Karte nach einigen Minuten von selbst ab (dann gilt sie als abgebrochen).

## Weitere Button-Arten

Nicht jeder Button ist eine Buchungs-Bestätigung:

- **👍 / 👎** unter einem vorgeschlagenen Job (vom Karriere-Coach, siehe [Karriere-Coach](karriere-coach.html)) — reines Feedback, mit dem der Assistent lernt, welche Stellen zu dir passen.
- **Cron ein/aus** — ein Knopf zum Abschalten einer wiederkehrenden Erinnerung oder eines automatischen Checks (z. B. „Plan-Erinnerung deaktivieren"). Wieder anschalten geht mit `/reminders`: Das Menü zeigt alle Erinnerungen mit Zeitplan und einem An/Aus-Knopf.
- **Lern-Loop-Einzelbestätigung** — schlägt der optionale tägliche Lern-Check (siehe [Monitor & Guide](monitor-guide.html)) etwas vor, das er sich dauerhaft merken will, bestätigst du das Stück für Stück per Knopf, nie im Block.

## Anhänge: Foto, PDF und Sprachnachricht

Schickst du ein Foto oder PDF, entscheidet der Assistent anhand des Inhalts, wer es bekommt: ein Kontoauszug oder eine Versicherungspolice geht an den Buchhalter, ein Lebenslauf an den Karriere-Coach. Sprachnachrichten werden zuerst automatisch in Text umgewandelt (transkribiert) und dann ganz normal wie eine getippte Nachricht behandelt.

Leitest du eine Datei **mit Kommentar** weiter, schickt Telegram Datei und Kommentar als zwei getrennte Nachrichten. Der Assistent wartet deshalb nach jeder Nachricht kurz (etwa 1,5 Sekunden) und behandelt Text und Datei, die zusammen ankommen, als **eine** Nachricht: Der Kommentar wird zur Bildunterschrift. So gibt es eine Antwort und höchstens eine Bestätigungskarte. Schickst du mehrere Dateien auf einmal, bearbeitet er jede für sich, und der Kommentar gehört zur ersten. Befehle wie `/help` und Sprachnachrichten warten nicht.
