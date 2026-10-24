---
title: "Befehle"
---

Fast alles, was du im Chat mit dem Bot tust, tippst du ganz normal in eigenen Worten — „Buch mir 40 Euro Supermarkt vom Girokonto ab", „Wie steht's um mein Depot?", „Erinnere mich, wenn der DAX unter 15.000 fällt". Der Bot versteht das ohne feste Syntax (natürliche Sprache), weil im Hintergrund ein Verteiler (Orchestrator) jede Nachricht liest und an den passenden Fach-Agenten weiterreicht.

Nur eine kleine Handvoll Schrägstrich-Befehle (Slash-Commands) hat eine feste, immer gleiche Bedeutung — das sind reine Abkürzungen für Dinge, die man nicht erst erklären muss. Das ist die **gesamte** Befehls-Oberfläche des Systems. Es gibt keine weiteren versteckten Kommandos für Buchungen, Beratung, Trigger oder Karriere-Themen — die laufen ausschließlich über normale Sätze.

## Referenz-Tabelle

| Befehl | Wer sieht ihn | Was er tut |
|---|---|---|
| `/start` | jeder, der den Bot zum ersten Mal anschreibt | Wird automatisch von Telegram beim Erstkontakt ausgelöst (kein manueller Aufruf nötig) und startet den Einstieg ins System. |
| `/help` | alle (Owner und eingeladene Haushaltsmitglieder) | Zeigt die Funktionsübersicht: was der Bot alles kann, gegliedert nach Themen (Konten, Buchungen, Depot, Kredite, Versicherungen, Immobilien, Sparziele, Daueraufträge, Import, Erinnerungen/Monitoring, Beratung, Jobsuche & Karriere). |
| `/hilfe` | alle | Deutsches Alias von `/help` — macht exakt dasselbe, nur mit deutschem Wortlaut. |
| `/onboarding` | alle (Owner und eingeladene Haushaltsmitglieder) | Zeigt den Stand der Ersteinrichtung als Übersicht: je Bereich ein Knopf mit Fortschritt (Antippen zeigt die einzelnen Abschnitte) und ein „Weiter"-Knopf, der den empfohlenen nächsten Schritt startet. Die Reihenfolge folgt den Abhängigkeiten: was auf anderen Angaben aufbaut, kommt später. Den Haushalts-Teil (wer gehört dazu?) führt der Guide-Agent; die Fach-Abschnitte erfasst der jeweilige Spezialist selbst — Konten, Investments, Kredite, Versicherungen und Sparziele der Buchhalter, das Karriere-Profil der Karriere-Coach. |
| `/language` | alle (Owner und Haushaltsmitglieder) | Stellt die Sprache der festen Texte (Begrüßung, Knöpfe, Bestätigungs-Karten, Menüs, `/help`) für **dich selbst** um: Der Bot schickt eine Karte mit einem Knopf je Sprache (Deutsch, English, 한국어), dein Tipp speichert die Wahl. Jede Person ändert so nur ihre eigene Sprache. |
| `/sprache` | alle | Deutsches Alias von `/language` — macht exakt dasselbe. |
| `/persona` | alle | Wählt den **Charakter**, mit dem der Bot mit dir chattet: 🙂 Neutral (Standard), 🎩 Butler, 🎙️ Sportreporter oder 🧙 Weiser Meister. Der Bot schickt eine Karte mit einem Knopf je Charakter, dein Tipp speichert die Wahl — nur für dich. Der Charakter färbt nur Begrüßung, Smalltalk und Rückfragen und höchstens einen kurzen Satz um Fach-Antworten; Zahlen, Bestätigungs-Karten, Knöpfe und Erinnerungen bleiben immer neutral. |
| `/reminders` | alle (Owner und Haushaltsmitglieder) | Zeigt alles, was der Bot **von sich aus** schickt (Monats-Check, Zinsen, Plan-Wächter, Quartals-Bericht, Lern-Vorschläge, Job-Vorschläge, Nachlass-Prüfung, Erinnerung ans Einrichten …), jeweils mit Zeitplan und Stand. Ein Tipp auf einen Eintrag schaltet ihn an oder aus. Der Owner schaltet die Erinnerungen für den Haushalt; persönliche Erinnerungen (z. B. Job-Vorschläge) schaltet jede Person für sich selbst. Fristen im Todes- oder Vorsorgefall bleiben immer an. |
| `/erinnerungen` | alle | Deutsches Alias von `/reminders` — macht exakt dasselbe. |
| `/notfall` | alle (Owner und Haushaltsmitglieder) | Fester Einstieg für den Ereignisfall: startet den Nachlass-Assistenten direkt — ruft die **Notfallmappe** (das ganze Vorsorge-Register als ein weiterleitbares Dokument) ab oder beginnt die einfühlsame Begleitung im Todes- bzw. Vorsorgefall. Gedacht für den überlebenden Partner, damit er im Ernstfall nicht erst die richtigen Worte finden muss. |

„Wer sieht ihn" bezieht sich nur auf das Befehls-Menü in Telegram (es zeigt nur Befehle installierter, eingeschalteter Pakete — `/notfall` also nur mit dem Nachlass-Paket): dort sehen Owner und eingeladene Mitglieder `/help`, `/onboarding`, `/language`, `/persona`, `/reminders` und `/notfall`. Getippt funktionieren auch `/start`, `/hilfe`, `/sprache` und `/erinnerungen` für alle. Die Kurzbeschreibungen im Menü erscheinen in der Sprache, auf die das Telegram-Programm des jeweiligen Geräts eingestellt ist (Deutsch, Englisch oder Koreanisch; bei jeder anderen App-Sprache in der Sprache des Owners). Mitglieder richten über `/onboarding` ihre eigenen, persönlichen Bereiche ein (z. B. das Karriere-Profil) — ihr „Weiter"-Knopf führt nur dorthin; Haushaltsbereiche (wer gehört dazu, Finanzen, Nachlass) sind als „richtet der Owner ein" markiert.

## Was ausdrücklich KEIN Befehl ist

Alles Inhaltliche läuft über normale Sprache, nicht über Kommandos:

- **Buchungen** — „trag 30 Euro Rewe ein", „ich hab 200 Euro Miete überwiesen".
- **Fragen zu Zahlen** — „wie hoch ist mein Kontostand?", „was steht auf dem Sparkonto?".
- **Beratung** — „lohnt sich ein Fondssparplan?", „soll ich den Kredit vorzeitig ablösen?".
- **Erinnerungen/Trigger** — „sag mir Bescheid, wenn Bitcoin über 60.000 steigt", „welche Trigger laufen gerade?".
- **Karriere** — „ich überlege einen Jobwechsel", „wie sieht mein Skill-Gap für die Zielrolle aus?".

Wenn du unsicher bist, was der Bot kann: tipp einfach `/help`. Auf jede Frage antwortet er ohnehin in der Sprache, in der du schreibst — Befehle sind nur die festen Ausnahmen oben.

## Mehr dazu

Wie ein typisches Gespräch abläuft, zeigt [Beispiele](beispiele.html); wie du eine Buchung im Chat bestätigst oder ablehnst, erklärt [Chatten & Bestätigen](chatten-bestaetigen.html); die Ersteinrichtung im Detail steht unter [Erste Schritte](erste-schritte.html).
