---
title: "Übersicht (Mini-App)"
---

Links neben dem Eingabefeld im Chat mit dem Bot sitzt der Knopf **„📊 Übersicht“**. Ein Tipp darauf öffnet direkt in Telegram eine kleine App (Telegram-Mini-App), die deine Finanzen auf einen Blick zeigt: ohne Frage an den Bot, ohne Warten auf eine Antwort.

![Die Übersicht im hellen Telegram-Design: Vermögen gesamt, Aufteilung nach Anlageart und die Konten (Beispielwerte)](/img/app-uebersicht-hell.png) ![Dieselbe Übersicht im dunklen Telegram-Design (Beispielwerte)](/img/app-uebersicht-dunkel.png)

*Beispielbilder mit erfundenen Werten. Hell oder dunkel folgt deiner Telegram-Einstellung.*

## Was du siehst

Zum Start gibt es den Bildschirm **Vermögen**:

- **Vermögen gesamt:** alles zusammen, Kredite schon abgezogen.
- **Nach Anlageart:** wie viel auf Konten, in Wertpapieren, Immobilien, Altersvorsorge und so weiter liegt. Der Balken zeigt den Anteil am Ganzen, Kredite stehen als Minus-Betrag darunter.
- **Konten:** jedes Konto mit seinem Kontostand in der eigenen Währung und dem Datum, an dem du den letzten Kontoauszug bestätigt hast (siehe [Monats-Check](monats-check.html)).

Steht irgendwo **„unvollständig – ein Kurs oder Wechselkurs fehlt“**, fehlt für einen Betrag der aktuelle Kurs. Die Summe ist dann zu niedrig, bis der Kurs da ist.

Weitere Bildschirme sind in Vorbereitung: Sparziele, kommende Zahlungen mit Vorschau, ob das Geld auf dem Konto reicht, Kredite und Depot. Sobald es mehr als einen gibt, wechselst du unten über Reiter zwischen ihnen.

Die Übersicht spricht die Sprache, die du mit `/language` eingestellt hast.

## Nur anschauen, gebucht wird im Chat

Die Übersicht zeigt nur an. Buchen, Ändern und Löschen läuft wie gewohnt im Chat, mit der Bestätigungs-Karte davor (siehe [Chatten & Bestätigen](chatten-bestaetigen.html)). Alle Zahlen rechnet die Datenbank aus denselben Daten, die auch der Chat nutzt; die App selbst rechnet nichts.

## Befehle gehen jetzt über „/“

Der Knopf „📊 Übersicht“ sitzt an der Stelle, an der vorher der Menü-Knopf mit der Befehlsliste war. Die Befehle gibt es weiterhin: Tippe im Eingabefeld **„/“**, dann klappt die Liste auf (`/help`, `/reminders` usw., siehe [Befehle](befehle.html)).

## Wer was sieht

- **Du als Owner und dein Partner bzw. deine Partnerin** seht den ganzen Haushalt, auch die Konten und Depots der Kinder.
- **Kinder** sehen nur, was ihnen gehört: eigene Konten und das eigene Depot. Gemeinsame Haushaltskonten und die Konten der Eltern tauchen bei ihnen nicht auf, auch nicht als Name.
- **Fremde Telegram-Nutzer** bekommen den Knopf nie zu sehen.

Zum Start bekommt **nur der Owner** den Knopf, als Probelauf. Für die ganze Familie schaltet ihn der Admin frei (siehe unten).

## Nach einer Stunde neu öffnen

Aus Sicherheitsgründen gilt ein Aufruf eine Stunde lang. Bleibt die Übersicht länger offen, erscheint der Hinweis, dass sie abgelaufen ist. Dann schließen und über den Knopf neu öffnen.

Ohne Internetverbindung zeigt die Übersicht nur ⚠ und den Knopf ↻ zum erneuten Laden.

## Datenschutz

- **Die Zahlen kommen direkt von deinem Server auf dein Handy.** Telegram öffnet nur das Fenster; die Inhalte laufen nicht über die Telegram-Server. Aus dem Internet lädt die Seite nur ein kleines Hilfsprogramm von Telegram (für Farben, Zurück-Knopf und Anmeldung), keine deiner Daten.
- **Jeder Abruf wird geprüft.** Telegram gibt der App einen unterschriebenen Ausweis mit, wer sie geöffnet hat. Dein Server prüft diese Unterschrift bei jedem Abruf, und die Datenbank entscheidet anhand deiner Rolle im Haushalt, was du sehen darfst. Ein gefälschter oder abgelaufener Ausweis bekommt keine Daten.
- **Nichts bleibt liegen.** Die App speichert auf dem Handy nichts, und dein Server legt von diesen Abrufen keine Protokolle mit Inhalten an.
- Der Weg ins Internet ist derselbe wie für den Chat: Dein Türsteher (Reverse Proxy) braucht dafür keine neue Regel. Mehr dazu unter [Datenschutz & Sicherheit](datenschutz.html).

## Für Admins: an- und abschalten

Die Übersicht stellst du auf dem Server mit zwei Einstellungen ein, danach jeweils `lifeagents update` ausführen:

| Befehl | Wirkung |
|---|---|
| `lifeagents config set app audience household` | Alle gekoppelten Haushaltsmitglieder bekommen den Knopf (Kinder sehen nur Eigenes). |
| `lifeagents config set app audience owner` | Nur der Owner bekommt den Knopf (Probelauf, so ist es nach der Installation eingestellt). |
| `lifeagents config set app enabled false` | Schaltet die Übersicht ganz ab: Der Knopf verschwindet, an seiner Stelle ist wieder der Menü-Knopf mit den Befehlen. |
| `lifeagents config set app enabled true` | Schaltet sie wieder ein. |

Wird jemand neu mit dem Bot gekoppelt oder wechselt jemand die Sprache, kommt der Knopf bzw. die neue Beschriftung mit dem nächsten `lifeagents update`.
