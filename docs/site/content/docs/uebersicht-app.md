---
title: "Übersicht (Mini-App)"
---

Links neben dem Eingabefeld im Chat mit dem Bot sitzt der Knopf **„📊 Übersicht“**. Ein Tipp darauf öffnet direkt in Telegram eine kleine App (Telegram-Mini-App), die deine Finanzen auf einen Blick zeigt: ohne Frage an den Bot, ohne Warten auf eine Antwort.

![Die Übersicht im hellen Telegram-Design: Vermögen des Haushalts, Besitz nach Anlageart, ein aufgeklapptes Kind und die Konten (Beispielwerte)](/img/app-uebersicht-hell.png) ![Dieselbe Übersicht im dunklen Telegram-Design (Beispielwerte)](/img/app-uebersicht-dunkel.png)

*Beispielbilder mit erfundenen Werten. Hell oder dunkel folgt deiner Telegram-Einstellung.*

## Was du siehst

Unten wechselst du über Reiter zwischen den Bildschirmen. Ein Bildschirm, zu dem es für dich nichts gibt, erscheint gar nicht erst.

Steht irgendwo **„unvollständig – ein Kurs oder Wechselkurs fehlt“**, fehlt für einen Betrag der aktuelle Kurs. Die Summe ist dann zu niedrig, bis der Kurs da ist.

Zeilen mit einem kleinen Pfeil nach unten **klappen beim Antippen auf** und zeigen mehr Einzelheiten, ein zweiter Tipp klappt sie wieder zu. So bleibt die Liste kurz, und die Details sind trotzdem einen Tipp entfernt. Steht neben einer Überschrift ein Betrag, ist das die Summe dieses Abschnitts.

Überall gilt dieselbe Bildsprache:

- **Rechts steht immer der Betrag**, um den es in der Zeile geht (Kontostand, Gespartes, Restschuld, Monatsbetrag).
- **Eine farbige Markierung ist ein Urteil.** Grün beantwortet die Hauptfrage der Zeile („im Plan“, „erreicht“, „reicht“). Gelb oder rot nennt, wie viel fehlt oder ab wann. Ist bei einer Nebenfrage alles in Ordnung, steht gar nichts da.
- **Ein Balken zeigt den Weg zu einem Zielbetrag**, in der Farbe der Markierung. Bei Anteilen (etwa am Besitz) ist er lila ohne Wertung; ist das Ziel erreicht, entfällt er.
- **Ein kleiner Pfeil mit Betrag** (↑/↓) zeigt eine Veränderung, etwa den Gewinn seit dem Kauf. Er ist Information, keine Warnung.
- **Ein grauer Satz unter einer Überschrift** erklärt den ganzen Abschnitt, etwa warum es keine Vorschau gibt.
- **Daten in den nächsten Monaten stehen ohne Jahr** („23.11.“); weiter entfernte mit Jahr.

### Vermögen

- **Vermögen Haushalt:** alles, was dem Haushalt gehört, Kredite schon abgezogen. Darunter steht, wie viel Besitz und wie viel Schulden das sind. Das Vermögen der Kinder zählt hier **nicht** mit.
- **Liquide:** woran du schnell kommst, mit der Summe neben der Überschrift. Darin stehen Konten, P2P und Wertpapiere, jeweils mit dem Anteil am gesamten Besitz als Zahl und Balken. Darunter steht, wie sich der Wert verhält:
  - **fester Wert:** Kontoguthaben.
  - **fester Wert, Auszahlung nicht garantiert:** P2P. Der Betrag schwankt nicht mit der Börse, es gibt aber keine Einlagensicherung, und die Plattform kann Auszahlungen verzögern.
  - **Wert schwankt:** Wertpapiere und Krypto. Der heutige Wert kann morgen höher oder niedriger sein.
- **Gebunden:** was du nicht kurzfristig zu Geld machen kannst, mit Summe: Immobilien, Altersvorsorge und Festgeld (fester Wert, aber bis zur Fälligkeit festgelegt).
- **Schulden:** die Kredite als Minus-Betrag. Ein Tipp darauf öffnet die Seite Kredite.
- **Kinder · nicht in der Summe:** für jedes Kind sein eigenes Vermögen. Aufgeklappt siehst du, woraus es besteht (Konten, Wertpapiere usw.).
- **Konten:** jedes Konto des Haushalts mit Kontostand in der eigenen Währung, wem es gehört („Gemeinsam“ für Haushaltskonten) und dem Datum, an dem du den letzten Kontoauszug bestätigt hast (siehe [Monats-Check](monats-check.html)).

### Ziele

- **Zurückgelegt:** was in allen Sparzielen und Rücklagen zusammen steckt, darunter die Aufteilung „Sparziele … · Rücklagen …“.
- **Rücklagen** (mit Summe neben der Überschrift):
  - **Notreserve** (nur für Eltern sichtbar): wie viel deiner Notreserve gedeckt ist, darunter das Ziel. Daneben steht „vollständig“ oder gelb „fehlen …“; solange etwas fehlt, zeigt ein Balken den Fortschritt. Aufgeklappt siehst du, wie das Ziel zustande kommt (feste Zahlungen und Kreditraten plus geschätzter Alltag je Monat, mal die gewünschten Monate) und auf welchen Konten wie viel liegt. Gezählt wird nur Geld auf Giro- und Tagesgeldkonten, und nur so viel, wie nach den anderen Sparzielen auf dem Konto wirklich da ist.
  - **Instandhaltungsrücklage** einer Immobilie: der Stand, darunter die monatliche Rate und die Empfehlung („163 € im Monat · wie empfohlen“ oder „· empfohlen 180 €“). Daneben „ausreichend“ oder gelb „17 € im Monat unter Empfehlung“. Einen Balken gibt es hier bewusst nicht: Eine Rücklage hat keinen Zielbetrag, sie wird für Reparaturen gebraucht und wieder aufgefüllt. Aufgeklappt siehst du, wie die Empfehlung zustande kommt: Wohnfläche, Baujahr und Alter, der Satz je m² und Jahr nach der II. Berechnungsverordnung und daraus der Jahres- und Monatsbetrag.
- **Sparziele** (mit Summe): jedes Ziel mit dem bisher Gesparten, dem Zielbetrag und der Restzeit („noch 16 J. 5 Mon.“) und einem Balken. Ziele, die hinter dem Plan liegen, stehen oben, erreichte unten. Aufgeklappt siehst du das Zieldatum, die monatliche Sparrate mit dem Konto, von dem sie abgeht, und auf welchen Konten das Gesparte liegt. Daneben steht, wie es läuft:
  - **im Plan:** du liegst gut in der Zeit.
  - **„… hinter Plan“** (gelb): so viel fehlt heute zum Plan, wenn du gleichmäßig bis zum Zieldatum sparst. Wie viel du monatlich nachlegen müsstest, sagt dir der Chat.
  - **erreicht:** der Zielbetrag ist da (ohne Balken).
  - **pausiert:** die Sparrate oder der Sparplan des Ziels ist angehalten.
  - **nicht messbar:** die Sparrate geht ohne eigenes Sparkonto ab, dann lässt sich der Stand nicht verfolgen. Abhilfe: dem Ziel im Chat ein Sparkonto zuordnen.
- **Sparpläne:** was jeder Plan im Monat ausmacht, darunter die nächste Ausführung (und der Betrag je Ausführung, wenn der Plan öfter als einmal im Monat läuft). Neben der Überschrift steht die Summe aller laufenden Pläne. Aufgeklappt siehst du Wertpapier, Depot, Abbuchungskonto, für wen der Plan ist, das Sparziel, eine geplante Änderung und was die Position heute wert ist. Ein angehaltener Plan steht als „pausiert“ da. Reicht das Geld auf dem Abbuchungskonto nicht, steht das am Plan (siehe Konten); ist alles in Ordnung, steht dort nichts.
- **Konten:** jedes Konto und Depot, auf dem Geld für Ziele liegt, von dem Daueraufträge abgehen oder das Sparpläne bezahlt. Rechts der Kontostand (beim Depot der Kurswert), darunter „für Ziele … · frei …“ bzw. die Daueraufträge im Monat. Eine Markierung erscheint nur, wenn etwas nicht stimmt, Konten mit Problemen stehen oben:
  - **Lücke ab …** (rot): das Konto fällt in den nächsten drei Monaten unter null.
  - **fehlen …** (gelb): auf dem Konto liegt weniger, als für die Ziele zurückgelegt sein sollte. Bei einem Depot erst, wenn der Kurswert um mindestens 10 % unter dem Ziel-Geld liegt.
  - **reicht bis …** (gelb): an diesem Tag ist das Konto leer, wenn nichts dazukommt (in den nächsten zwei Jahren).
  - **„… Kursminus“** (grau): das Depot liegt nur durch eine kleine Kursschwankung unter dem Ziel-Geld. Das ist normal und kein Grund zum Handeln.
  - **nicht ermittelbar** (grau): ein Kurs fehlt, oder es fehlen die Alltagsausgaben eines Kontos, von dem auch Miete oder Strom abgehen (dafür braucht es einen Kontoauszug, siehe [Monats-Check](monats-check.html)).

  Aufgeklappt steht jeder Dauerauftrag zum Abtippen da, etwa „→ Tagesgeld · 150 € · monatlich am 1. · ab 01.11.“. Ist für eine Rate noch kein fester Tag hinterlegt, steht dort „Tag frei (gerechnet: 1.)“: Du wählst den Tag bei der Bank, die Übersicht rechnet bis dahin mit dem genannten. Eine geplante Änderung („Änderung ab …“) steht direkt darunter, Spar-Lastschriften ohne Zielkonto (etwa ein Vorsorge-Beitrag) mit ihrem Namen. Danach **„Geld kommt von …“** für jeden Zufluss (Konto bzw. Name der Zahlung, etwa ein monatliches Geldgeschenk der Großeltern) und zuletzt **„Konto …“** mit Eingängen und Abgängen im Monat und dem tiefsten Stand. Gehen jeden Monat mehr ab als ankommen, ist das kein Fehler, solange das Guthaben reicht.

Ein Beispiel: Ziel „Urlaub“ über 3.000 € bis Juni, gespart sind 1.200 €. Ist bis heute schon deutlich mehr Zeit vergangen, als Geld zusammengekommen ist, steht dort etwa „600 € hinter Plan“.

### Zahlungen

Oben steht die Summe dessen, was in den nächsten 30 Tagen abgeht (ohne Umbuchungen zwischen eigenen Konten). Darunter hat **jedes Konto einen eigenen Abschnitt**, Konten mit Problemen zuerst.

Für jedes Konto, zu dem du schon einen Kontoauszug eingespielt hast (siehe [Monats-Check](monats-check.html)), steht ganz oben der **tiefste Stand** vor dem nächsten Geldeingang mit Ampel. Reicht das Geld (grün), stehen darunter nur noch **„Zahlungen bis …“** (alle Zahlungen der nächsten 30 Tage zum Aufklappen); die Rechnung zum tiefsten Stand klappt beim Antippen der ersten Zeile auf. Ist es knapp oder rot, bleibt die Rechnung offen stehen. Jede Zeile kannst du nachrechnen, sie ergeben zusammen genau den tiefsten Stand:

- **Stand am …:** der bestätigte Stand aus dem letzten Kontoauszug oder Abgleich (und, falls seitdem gebucht wurde, „Gebucht seit …“).
- **Feste Abgänge / feste Eingänge bis …:** die Daueraufträge bis zum Tief. Antippen zeigt jede einzelne Zahlung mit Datum und Betrag.
- **Alltagsausgaben (geschätzt):** Einkauf, Karte und Bargeld, geschätzt aus deinen Kontoauszügen, etwa „≈ 62 € pro Tag × 29 Tage“. Antippen zeigt den Wert je Auszug. Dein **erster** Kontoauszug zählt nicht mehr, sobald ein zweiter da ist: Er stammt meist aus der Zeit, bevor deine Daueraufträge erfasst waren, und würde Gehalt oder Überweisungen als „Alltag“ mitzählen. Gibt es erst einen Auszug, steht „vorläufig“ dabei. Einzelne Ausgaben ab 250 € (etwa ein größerer Online-Einkauf) gelten als **einmalig** und zählen nicht zum Tageswert; aufgeklappt steht je Auszug „davon einmalig, zählt nicht“ mit der Summe. Überweisungen auf deine eigenen Konten zählen nie als Alltag, auch wenn sie sich nicht als Umbuchung verbuchen ließen.
- **Tiefster Stand** mit Datum und Ampel: **rot „unter Puffer“**, **gelb „knapp“** (über dem Puffer, aber unter dem Doppelten), **grün „reicht“**. Fehlt für ein Konto in Fremdwährung der Wechselkurs, steht dort grau „Kurs fehlt“.
- **Puffer:** wie viel mindestens auf dem Konto bleiben soll, mit dem Hinweis „Standardwert (nicht selbst festgelegt)“ (250 €) oder „für dieses Konto festgelegt“ und ab welchem Stand das Konto gelb wird. Den Puffer stellst du je Konto im Chat ein: „Auf dem Girokonto sollen immer mindestens 400 € bleiben.“
- **Nächster Geldeingang**, bei rotem Konto ein **Umbuchungs-Vorschlag**, und darunter **weitere Zahlungen** bis zum Ende der 30 Tage.

Konten ohne Kontoauszug zeigen ihre Zahlungen der nächsten 30 Tage mit dem grauen Hinweis „Keine Vorschau – für dieses Konto gibt es noch keinen Kontoauszug“; neben der Überschrift steht die Summe dieser Zahlungen. P2P-Konten, Festgeld und Depots haben nie eine Vorschau („die gibt es nur für Giro- und Tagesgeldkonten“), ihre Zahlungen stehen trotzdem da. Eine Umbuchung zwischen zwei eigenen Konten steht bei beiden: beim einen als Abgang, beim anderen als Eingang (+). Wiederholt sich dieselbe Zahlung im Monat (etwa ein Sparplan an vier festen Tagen), steht sie einmal da, zum Beispiel „4× · 02.11. – 23.11.“ mit der Summe; aufgeklappt stehen die einzelnen Termine.

### Kredite

- Jeder laufende oder pausierte Kredit mit Restschuld, darunter Zinssatz, Monatsrate und **„schuldenfrei 2039“**: in welchem Jahr der Kredit bei gleicher Rate und ohne Sondertilgung abbezahlt ist. Bleibt zum Laufzeitende noch etwas offen, steht dort stattdessen **„Schlussrate …“** mit dem Datum; den Betrag zeigt das Aufklappen. Kennst du den ursprünglichen Kreditbetrag, zeigt ein Balken, wie viel schon getilgt ist. Oben steht die Restschuld aller Haushalts-Kredite zusammen und darunter, wie viel du monatlich an Raten zahlst und wie viel davon Zinsen sind. Kredite der Kinder stehen in einem eigenen Abschnitt und zählen nicht mit.
- **Gelb „Zinsbindung bis …“** erscheint, wenn die Zinsbindung in weniger als zwölf Monaten endet. Dann ist Zeit, sich um die Anschlussfinanzierung zu kümmern. Ist das Datum schon vorbei, steht dort „Zinsbindung endete am …“.
- Ein pausierter Kredit trägt den grauen Hinweis „pausiert“.
- Aufgeklappt siehst du: die Bank, wer den Kredit hat, Kreditbetrag und Auszahlungstag, wie viel schon getilgt ist, wie sich die aktuelle Rate in Zins und Tilgung aufteilt, die Restschuld zum Ende der Zinsbindung und zum Laufzeitende, das voraussichtliche Datum „schuldenfrei“ und wie viel Zinsen bis dahin noch anfallen.

### Depot

- **Depotwert:** der aktuelle Wert der Wertpapiere und Kryptowerte des Haushalts, dieselbe Zahl wie „Wertpapiere & Krypto“ auf der Seite Vermögen. Darunter steht der Gewinn oder Verlust seit dem Kauf und das Datum der Kurse. Depots der Kinder stehen weiter unten mit dem Zusatz „nicht in der Summe“.
- **Rendite je Depot:** ganz oben steht rechts, wie viel jedes Depot pro Jahr gebracht hat („+6,2 % pro Jahr“), und zum Vergleich „Alle Depots“ (ab zwei solchen Depots). Die Zahl berücksichtigt, wann du wie viel gekauft, verkauft und an Dividenden bekommen hast (geldgewichtete Rendite, XIRR — dieselbe Methode wie der „interne Zinsfuß“ in Portfolio Performance). Ein Depot erscheint hier erst, wenn es ein volles Jahr läuft. Davor zeigt „seit Kauf“ an den Positionen und beim Depotwert, wie viel du gewonnen oder verloren hast; die Seite rechnet so nur ab einem Zeitpunkt, deinem Kaufpreis. Auch Fonds zeigen unter einem Jahr keine Wertentwicklung. Positionen, die du mit ihrem alten Einstandskurs übernommen hast, zählen für die Jahres-Rendite ab ihrem Kurswert am Übernahme-Tag, weil der ursprüngliche Kauftag nicht bekannt ist. Fehlt ein Kurs oder Wechselkurs, steht dort keine Zahl, sondern was fehlt. Kinderdepots stehen einzeln da und zählen nicht in „Alle Depots“. Depot-Gebühren, die keiner Position zugeordnet sind, fließen nicht ein.
- **Je Depot** (mit seiner Summe neben dem Namen) jede Position mit ihrem Wert in Euro und der Stückzahl. Bei Wertpapieren in fremder Währung steht der Kurs in dieser Währung klein darunter (z. B. „Kurs 148,60 $“). Unter dem Wert zeigt ein kleiner Pfeil mit Betrag und Prozent, wie viel die Position seit dem Kauf gewonnen (↑) oder verloren (↓) hat. Das ist Information, kein Alarm: Kurse schwanken.
- **„Kurs veraltet“** heißt: der letzte Kurs ist schon länger nicht mehr aktualisiert worden. **„Kurs fehlt“** heißt: es gibt noch gar keinen. In der Summe zählt dann der Kaufwert, und sie ist als unvollständig markiert.
- Aufgeklappt siehst du den durchschnittlichen Kaufkurs, den Kaufwert und die letzten zwölf Käufe, Verkäufe und Dividenden mit Datum, Stückzahl und Kurs.
- Wie viel im Depot für Sparziele zurückgelegt ist, steht auf der Seite Ziele unter „Konten“.

### Hinweise auf der Startseite

Was Aufmerksamkeit braucht, steht als Hinweis oben auf der Startseite, Rotes vor Gelbem. Ein Tipp darauf öffnet den passenden Bildschirm. Ein Beispiel: „Girokonto: Der tiefste Stand (140 € am 27.11.) liegt unter dem Puffer. Vorschlag: 150 € vom Tagesgeld bis 25.11. umbuchen.“ Oder: „Baufinanzierung: Die Zinsbindung endet am 30.06., Restschuld dann etwa 182.400 €.“ Weitere Beispiele: „Urlaub liegt hinter Plan“, „Tagesgeld: Das Geld für Sparpläne und Daueraufträge reicht nur bis 15.12.“ (nur bei einer Lücke in den nächsten drei Monaten) oder „Kurs fehlt oder ist veraltet in Depot X“.

Die Übersicht spricht die Sprache, die du mit `/language` eingestellt hast.

## Nur anschauen, gebucht wird im Chat

Die Übersicht zeigt nur an. Buchen, Ändern und Löschen läuft wie gewohnt im Chat, mit der Bestätigungs-Karte davor (siehe [Chatten & Bestätigen](chatten-bestaetigen.html)). Alle Zahlen rechnet die Datenbank aus denselben Daten, die auch der Chat nutzt; die App selbst rechnet nichts.

## Befehle gehen jetzt über „/“

Der Knopf „📊 Übersicht“ sitzt an der Stelle, an der vorher der Menü-Knopf mit der Befehlsliste war. Die Befehle gibt es weiterhin: Tippe im Eingabefeld **„/“**, dann klappt die Liste auf (`/help`, `/reminders` usw., siehe [Befehle](befehle.html)).

## Wer was sieht

- **Du als Owner und dein Partner bzw. deine Partnerin** seht den ganzen Haushalt, auch die Konten und Depots der Kinder. Sie stehen getrennt und zählen nicht in die Haushalts-Summen.
- **Kinder** sehen nur, was ihnen gehört: eigene Konten, das eigene Depot, Sparziele für sie selbst und Sparpläne für sie auf ihrem eigenen Depot. Gemeinsame Haushaltskonten und -ziele und die Konten der Eltern tauchen bei ihnen nicht auf, auch nicht als Name: Liegt Geld für ihr Sparziel auf einem Elternkonto, heißt es bei ihnen nur „Haushaltskonto“. Bei ihrem eigenen Konto oder Depot sieht ein Kind, wie viel darin für Ziele verplant ist. Kommt Geld für ihren Sparplan vom Elternkonto, steht dort „Geld kommt von Haushaltskonto“; ein eigener Dauerauftrag an ein Elternkonto heißt „→ Haushaltskonto“, ohne dessen Stand.
- Bei den **Zahlungen** sehen Kinder nur Daueraufträge von ihren eigenen Konten und Kredite, die auf ihren Namen laufen. Taschengeld vom Elternkonto erscheint als „Vom Haushalt“, ohne den Namen des Dauerauftrags oder des Elternkontos, und einen Umbuchungs-Vorschlag bekommen Kinder nie.
- **Fremde Telegram-Nutzer** bekommen den Knopf nie zu sehen.

Alle gekoppelten Haushaltsmitglieder bekommen den Knopf. Wer neu gekoppelt wird, entkoppelt wird oder die Sprache wechselt, sieht den Knopf bzw. die neue Beschriftung nach etwa einer Minute, ohne Update. Soll ihn nur der Owner haben, stellt der Admin das um (siehe unten).

## Nach einer Stunde neu öffnen

Aus Sicherheitsgründen gilt ein Aufruf eine Stunde lang. Bleibt die Übersicht länger offen, erscheint der Hinweis, dass sie abgelaufen ist. Dann schließen und über den Knopf neu öffnen.

Ohne Internetverbindung zeigt die Übersicht nur ⚠ und den Knopf ↻ zum erneuten Laden.

Erscheint statt der Übersicht manchmal eine **FritzBox-Seite** (Anmeldung oder „URL nicht verfügbar“), zeigt deine Domain über IPv6 auf die FritzBox selbst. Der Chat funktioniert trotzdem. Abhilfe steht Schritt für Schritt unter [FritzBox einrichten](fritzbox.html), und `lifeagents doctor` zeigt, ob es behoben ist.

## Datenschutz

- **Die Zahlen kommen direkt von deinem Server auf dein Handy.** Telegram öffnet nur das Fenster; die Inhalte laufen nicht über die Telegram-Server. Aus dem Internet lädt die Seite nur ein kleines Hilfsprogramm von Telegram (für Farben, Zurück-Knopf und Anmeldung), keine deiner Daten.
- **Jeder Abruf wird geprüft.** Telegram gibt der App einen unterschriebenen Ausweis mit, wer sie geöffnet hat. Dein Server prüft diese Unterschrift bei jedem Abruf, und die Datenbank entscheidet anhand deiner Rolle im Haushalt, was du sehen darfst. Ein gefälschter oder abgelaufener Ausweis bekommt keine Daten.
- **Nichts bleibt liegen.** Die App speichert auf dem Handy nichts, und dein Server legt von diesen Abrufen keine Protokolle mit Inhalten an.
- Der Weg ins Internet ist derselbe wie für den Chat: Dein Türsteher (Reverse Proxy) braucht dafür keine neue Regel. Mehr dazu unter [Datenschutz & Sicherheit](datenschutz.html).

## Für Admins: an- und abschalten

Die Übersicht stellst du auf dem Server mit zwei Einstellungen ein. Die Knöpfe folgen nach etwa einer Minute von selbst, ein Update ist nicht nötig:

| Befehl | Wirkung |
|---|---|
| `lifeagents config set app audience household` | Alle gekoppelten Haushaltsmitglieder bekommen den Knopf, Kinder sehen nur Eigenes (so ist es eingestellt). |
| `lifeagents config set app audience owner` | Nur der Owner bekommt den Knopf. |
| `lifeagents config set app enabled false` | Schaltet die Übersicht ganz ab. Die Übersicht ist sofort gesperrt, der Knopf verschwindet nach etwa einer Minute; an seiner Stelle ist dann wieder der Menü-Knopf mit den Befehlen. |
| `lifeagents config set app enabled true` | Schaltet sie wieder ein. |

Kopplung, Entkoppeln und Sprachwechsel zieht der Server genauso nach. Klappt das wiederholt nicht (etwa weil Telegram nicht erreichbar ist), versucht er es alle zehn Minuten erneut, und `lifeagents doctor` meldet es nach einer halben Stunde.

Wie weit die Liste der kommenden Zahlungen reicht, ab wann ein Konto als knapp gilt und wie früh vor dem Ende einer Zinsbindung gewarnt wird, stellst du ebenfalls ein:

| Befehl | Wirkung |
|---|---|
| `lifeagents config set finance app_payments_days 30` | Kommende Zahlungen für so viele Tage im Voraus. |
| `lifeagents config set finance coverage_warn_factor 2` | Gelb, wenn der tiefste vorausgesagte Kontostand unter dem Doppelten des Puffers liegt; rot unter dem Puffer selbst (`coverage_buffer_eur`). |
| `lifeagents config set finance everyday_oneoff_eur 250` | Ab diesem Einzelbetrag gilt eine Ausgabe im Kontoauszug als einmalig und zählt nicht zu den geschätzten Alltagsausgaben (gilt ab dem nächsten Auszug). |
| `lifeagents config set finance fixed_rate_warn_months 12` | Hinweis, wenn die Zinsbindung eines Kredits in weniger als so vielen Monaten endet. |
| `lifeagents config set finance funding_horizon_months 24` | So viele Monate voraus prüft die Seite Ziele, ob das Geld für Sparpläne und Daueraufträge reicht (sonst „reicht bis …“). |
| `lifeagents config set finance depot_cover_warn_pct 10` | Ab so viel Prozent unter dem Ziel-Geld wird ein Depot auf der Seite Ziele gelb „fehlen …“ (und der Berater meldet es); darunter steht grau „… Kursminus“. |
| `lifeagents config set finance funding_alert_months 3` | Rot „Lücke ab …“ und ein Hinweis auf der Startseite, wenn das Geld schon innerhalb so vieler Monate fehlt. |
