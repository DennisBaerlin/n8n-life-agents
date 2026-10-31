---
title: "Übersicht (Mini-App)"
---

Links neben dem Eingabefeld im Chat mit dem Bot sitzt der Knopf **„📊 Übersicht“**. Ein Tipp darauf öffnet direkt in Telegram eine kleine App (Telegram-Mini-App), die deine Finanzen auf einen Blick zeigt: ohne Frage an den Bot, ohne Warten auf eine Antwort.

![Die Übersicht im hellen Telegram-Design: Vermögen des Haushalts, Besitz nach Anlageart, Schulden und ein aufgeklapptes Kind (Beispielwerte)](/img/app-uebersicht-hell.png) ![Dieselbe Übersicht im dunklen Telegram-Design (Beispielwerte)](/img/app-uebersicht-dunkel.png)

*Beispielbilder mit erfundenen Werten. Hell oder dunkel folgt deiner Telegram-Einstellung.*

## Was du siehst

Unten wechselst du über Reiter zwischen den Bildschirmen. Ein Bildschirm, zu dem es für dich nichts gibt, erscheint gar nicht erst.

Steht irgendwo **„unvollständig – ein Kurs oder Wechselkurs fehlt“**, fehlt für einen Betrag der aktuelle Kurs. Die Summe ist dann zu niedrig, bis der Kurs da ist.

Zeilen mit einem kleinen Pfeil nach unten **klappen beim Antippen auf** und zeigen mehr Einzelheiten, ein zweiter Tipp klappt sie wieder zu. So bleibt die Liste kurz, und die Details sind trotzdem einen Tipp entfernt. Steht neben einer Überschrift „zusammen …“, ist das die Summe dieses Abschnitts.

Überall gilt dieselbe Bildsprache:

- **Rechts steht immer der Betrag**, um den es in der Zeile geht (Kontostand, Gespartes, Restschuld, Monatsbetrag).
- **Eine farbige Markierung heißt: hier gibt es etwas zu tun.** Gelb oder rot nennt immer, wie viel fehlt oder ab wann. Grau sagt, was fehlt und wer es beheben kann. Ist alles in Ordnung, steht gar nichts da; grün ist allein der Satz „Alles in Ordnung“ oben auf der Startseite.
- **Ein Balken zeigt den Weg zu einem Zielbetrag**, lila ohne Wertung; gelb oder rot nur zusammen mit einer Markierung. Ist das Ziel erreicht, entfällt er.
- **Ein kleiner Pfeil mit Betrag** (↑/↓) zeigt eine Veränderung, etwa den Gewinn seit dem Kauf. Er ist Information, keine Warnung.
- **Ein grauer Satz unter einer Überschrift** erklärt den ganzen Abschnitt, etwa warum es keine Vorschau gibt.
- **Daten in den nächsten Monaten stehen ohne Jahr** („23.11.“); weiter entfernte mit Jahr.

### Vermögen

Die Seite beantwortet: Was haben wir, was schulden wir? Kontostände stehen auf der Seite Konten.

- **Vermögen Haushalt:** alles, was dem Haushalt gehört, Kredite schon abgezogen. Darunter steht, wie viel Besitz und wie viel Schulden das sind. Das Vermögen der Kinder zählt hier **nicht** mit.
- **Schnell verfügbar:** woran du kurzfristig kommst: Konten, P2P und Wertpapiere, jeweils mit dem Anteil am gesamten Besitz als Zahl und Balken.
- **Langfristig gebunden:** was du nicht kurzfristig zu Geld machen kannst: Immobilien, Altersvorsorge und Festgeld.
- Neben einer dieser Überschriften steht „zusammen …“, sobald der Abschnitt mehrere Zeilen hat und die Summe nicht schon dieselbe Zahl wie oben ist.
- **Schulden:** die Kredite als positiver Betrag (dieselbe Zahl wie auf der Seite Kredite). Ein Tipp darauf öffnet die Seite Kredite. Ist ein Konto überzogen, steht es hier als „Überzogene Konten“.
- **Vermögen der Kinder:** für jedes Kind sein eigenes Vermögen. Aufgeklappt siehst du, woraus es besteht (Konten, Wertpapiere usw.).

### Konten

Die Seite beantwortet: Steht genug auf jedem Konto, und was bewegt sich in den nächsten 30 Tagen? Jedes Konto des Haushalts hat einen eigenen Abschnitt; Konten mit einem gelben oder roten Hinweis stehen oben, dann Girokonten, dann Sparkonten. Die Konten der Kinder stehen hier nicht (ihr Stand steht unter „Vermögen der Kinder“, ihre Sparpläne auf der Seite Ziele). Ein Konto ohne Geld und ohne Zahlungen erscheint nicht.

Je Konto stehen höchstens vier Zeilen:

- **Stand heute:** der Kontostand. Liegt auf dem Konto Geld für Sparziele, steht darunter „davon … frei“. Ist mehr für Ziele verplant, als auf dem Konto liegt, steht daneben gelb „… mehr verplant als vorhanden“. Aufgeklappt: wie viel für Ziele zurückgelegt ist, wem das Konto gehört („Gemeinsam“ für Haushaltskonten) und von wann der letzte Kontoauszug ist.
- **Tiefster Stand:** nur wenn vom Konto etwas abgeht.
  - Für Konten mit Kontoauszug (siehe [Monats-Check](monats-check.html)): der tiefste Stand vor dem nächsten Geldeingang, etwa „am 18.11., vor dem Geldeingang am 30.11.“. Gelb „knapp über dem Puffer (250 €)“ oder rot „… unter dem Puffer“, sonst nichts. Aufgeklappt steht die Rechnung, die genau den tiefsten Stand ergibt: Stand am …, gebucht seit …, feste Abgänge, feste Eingänge, Alltag geschätzt („≈ 62 € pro Tag × 29 Tage“), der Puffer, der nächste Geldeingang und bei einem roten Konto ein Umbuchungs-Vorschlag. Den Puffer stellst du je Konto im Chat ein: „Auf dem Girokonto sollen immer mindestens 400 € bleiben.“
  - Für Spar- und Verrechnungskonten, von denen Sparpläne oder Daueraufträge abgehen: der tiefste **freie** Stand in den nächsten zwei Jahren, darunter, was im Monat abgeht und reinkommt. Geld, das dort für Sparziele zurückliegt, zählt nicht als frei. Gelb „reicht bis 04.2027“ oder rot „Lücke ab …“, sonst nichts. Dasselbe Urteil steht auf der Seite Ziele am Sparplan, der von diesem Konto abbucht.
  - Ein Girokonto ohne Kontoauszug zeigt statt dieser Zeile den grauen Satz „Noch kein Kontoauszug – deshalb keine Vorschau. Schick einen Auszug im Chat.“
- **Gehen ab bis …** und **Kommen rein bis …:** die Summe der Zahlungen der nächsten 30 Tage und wie viele es sind. Aufgeklappt steht jede Zahlung mit Datum und Betrag; wiederholt sich dieselbe Zahlung (etwa ein Sparplan an vier festen Tagen), steht sie einmal da („4× 50 € · 02.11. – 23.11.“). Bei mehr als acht Zahlungen stehen die ersten sieben einzeln und der Rest als „weitere … Zahlungen“. Eine Umbuchung zwischen zwei eigenen Konten steht bei beiden: beim einen als Abgang, beim anderen als Eingang (+).

### Ziele

Die Seite beantwortet: Kommen wir mit dem Sparen voran, und was läuft automatisch? Eine Markierung steht nur da, wenn du etwas tun kannst; läuft alles nach Plan, ist die Zeile ruhig. Kontostände, freies Geld und Daueraufträge stehen auf der Seite Konten.

- **Zurückgelegt:** was in allen Sparzielen und Rücklagen zusammen steckt, darunter die Aufteilung „Sparziele … · Rücklagen …“.
- **Rücklagen:**
  - **Notreserve** (nur für Eltern sichtbar): wie viel deiner Notreserve gedeckt ist, darunter das Ziel. Solange etwas fehlt, steht daneben gelb „fehlen …“ und ein Balken zeigt den Fortschritt; ist sie voll, steht darunter „Ziel … erreicht“. Aufgeklappt siehst du, wie das Ziel zustande kommt (feste Zahlungen und Kreditraten plus geschätzter Alltag je Monat, mal die gewünschten Monate) und auf welchen Konten wie viel liegt. Gezählt wird nur Geld auf Giro- und Tagesgeldkonten, und nur so viel, wie nach den anderen Sparzielen auf dem Konto wirklich da ist.
  - **Instandhaltungsrücklage** einer Immobilie: der Stand, darunter die monatliche Rate („163 € im Monat“). Liegt die Rate unter dem Richtwert, steht daneben gelb „17 € im Monat unter Richtwert“. Einen Balken gibt es hier bewusst nicht: Eine Rücklage hat keinen Zielbetrag, sie wird für Reparaturen gebraucht und wieder aufgefüllt. Aufgeklappt siehst du, von welchem Konto die Rate abgeht und wann, den Richtwert nach der II. Berechnungsverordnung („180 € im Monat (98 m² × 22,04 € je m² im Jahr)“) und die Immobilie.
- **Sparziele:** jedes Ziel mit dem bisher Gesparten, darunter „von 40.000 € · bis 03.2040“ (erreicht: „2.500 € erreicht · geplant für 01.06.2027“) und ein Balken. Rote und gelbe Ziele stehen oben, erreichte unten. Aufgeklappt siehst du, **woher die Rate kommt** („Rate: 200 € im Monat aus Sparplänen ETF Welt, Aktie“ oder „Rate von Girokonto: 120 € · monatlich am 1.“ oder „keine laufende Rate“), auf welchen Konten das Gesparte liegt und das genaue Zieldatum. Markierungen:
  - **„hinter Plan · fehlen …“** (gelb): so viel fehlt heute zum Plan, wenn du gleichmäßig bis zum Zieldatum sparst. Wie viel du monatlich nachlegen müsstest, sagt dir der Chat.
  - **„Depot …: Kurswert … unter dem Zurückgelegten“** (rot): liegt das Geld eines Ziels im Depot und ist der Kurswert um mindestens 10 % unter das dafür Zurückgelegte gefallen. Kleinere Kursschwankungen zeigen nichts an.
  - **pausiert** (grau): die Sparrate oder der Sparplan des Ziels ist angehalten. Weitersparen oder das Ziel schließen geht im Chat.
  - **„nicht messbar: kein Konto zugeordnet“** (grau): die Sparrate geht ohne eigenes Sparkonto ab, dann lässt sich der Stand nicht verfolgen. Abhilfe: dem Ziel im Chat ein Sparkonto zuordnen.
- **Sparpläne:** was jeder Plan im Monat ausmacht, darunter die nächste Ausführung, bei festen Tagen etwa „4× monatlich je 50 € · nächste 02.11.“. Neben der Überschrift steht „zusammen … im Monat“ (ab zwei Plänen). Aufgeklappt siehst du Wertpapier, Depot, Abbuchungskonto, für wen der Plan ist, das Sparziel und eine geplante Änderung. Ein angehaltener Plan steht als „pausiert“ da. Reicht das Geld auf dem Abbuchungskonto nicht, steht am Plan dieselbe Markierung wie beim Konto auf der Seite Konten (etwa gelb „reicht bis 04.2027“, rot „Lücke ab …“ oder „… unter dem Puffer“); ist alles in Ordnung, steht dort nichts.

Ein Beispiel: Ziel „Urlaub“ über 3.000 € bis Juni, gespart sind 1.200 €. Ist bis heute schon deutlich mehr Zeit vergangen, als Geld zusammengekommen ist, steht dort etwa „hinter Plan · fehlen 600 €“.

### Kredite

- Jeder laufende oder pausierte Kredit mit Restschuld, darunter Zinssatz, Monatsrate und **„schuldenfrei 2039“**: in welchem Jahr der Kredit bei gleicher Rate und ohne Sondertilgung abbezahlt ist. Bleibt zum Laufzeitende noch etwas offen, steht dort stattdessen **„Schlussrate 18.000 € am 01.06.2028“**; eine Hochrechnung über das Vertragsende hinaus gibt es dann nicht. Kennst du den ursprünglichen Kreditbetrag, zeigt ein Balken, wie viel schon getilgt ist. Oben steht die Restschuld aller Haushalts-Kredite zusammen und darunter, wie viel du monatlich an Raten zahlst und wie viel davon Zinsen sind. Kredite der Kinder stehen im eigenen Abschnitt „Kredite der Kinder“ und zählen oben nicht mit.
- **Gelb „Zinsbindung endet …“** erscheint, wenn die Zinsbindung in weniger als zwölf Monaten endet. Dann ist Zeit, sich um die Anschlussfinanzierung zu kümmern. Ist das Datum schon vorbei, steht dort „Zinsbindung endete am …“.
- Ein pausierter Kredit trägt den grauen Hinweis „pausiert“.
- Aufgeklappt siehst du: die Bank, wer den Kredit hat, Kreditbetrag und Auszahlungstag, wie viel schon getilgt ist, wie sich die aktuelle Rate in Zins und Tilgung aufteilt, das Ende der Zinsbindung mit der Restschuld dann und, wenn der Kredit bis zum Laufzeitende abbezahlt ist, das voraussichtliche Datum „schuldenfrei“ und wie viel Zinsen bis dahin noch anfallen.

### Depot

- **Depotwert:** der aktuelle Wert der Wertpapiere und Kryptowerte des Haushalts, dieselbe Zahl wie „Wertpapiere & Krypto“ auf der Seite Vermögen. Darunter steht der Gewinn oder Verlust seit dem Kauf und das Datum der Kurse. Die Depots der Kinder zählen hier nicht mit; sie stehen unten in „Depots der Kinder“.
- **Rendite je Depot:** ganz oben steht rechts, wie viel jedes Depot pro Jahr gebracht hat („+6,2 % pro Jahr“), und zum Vergleich „Alle Depots“ (ab zwei solchen Depots). Die Zahl berücksichtigt, wann du wie viel gekauft, verkauft und an Dividenden bekommen hast (geldgewichtete Rendite, XIRR — dieselbe Methode wie der „interne Zinsfuß“ in Portfolio Performance). Ein Depot erscheint hier erst, wenn es ein volles Jahr läuft. Davor zeigt der Pfeil an den Positionen und beim Depotwert, wie viel du seit dem Kauf gewonnen oder verloren hast; die Seite rechnet so nur ab einem Zeitpunkt, deinem Kaufpreis. Auch Fonds zeigen unter einem Jahr keine Wertentwicklung. Positionen, die du mit ihrem alten Einstandskurs übernommen hast, zählen für die Jahres-Rendite ab ihrem Kurswert am Übernahme-Tag, weil der ursprüngliche Kauftag nicht bekannt ist. Fehlt ein Kurs oder Wechselkurs, steht dort keine Zahl, sondern was fehlt. Depot-Gebühren, die keiner Position zugeordnet sind, fließen nicht ein.
- **Je Depot** jede Position mit ihrem Wert in Euro. Unter dem Wert zeigt ein kleiner Pfeil mit Betrag und Prozent, wie viel die Position seit dem Kauf gewonnen (↑) oder verloren (↓) hat. Das ist Information, kein Alarm: Kurse schwanken. Neben dem Depotnamen steht „zusammen …“ nur, wenn das Depot mehrere Positionen hat und es mehrere Depots gibt (sonst wäre es dieselbe Zahl wie der Depotwert).
- **„Kurs veraltet (15.10.)“** heißt: der letzte Kurs ist von diesem Tag und schon länger nicht mehr aktualisiert worden. **„Kurs fehlt“** heißt: es gibt noch gar keinen. Im Depotwert zählt dann der Kaufwert, und er ist als unvollständig markiert.
- Aufgeklappt siehst du den Bestand (Stückzahl und Kurs, bei fremder Währung in dieser Währung), den durchschnittlichen Kaufkurs, den Kaufwert und die letzten Käufe, Verkäufe und Dividenden mit Datum, Stückzahl und Kurs (bis zu fünf Zeilen, ältere als „und 7 ältere Buchungen“).
- **Depots der Kinder:** eine Zeile je Kinderdepot mit Wert, dem Namen des Kindes und dem Gewinn seit dem Kauf. Aufgeklappt stehen die Positionen und, sobald das Depot ein volles Jahr läuft, seine Rendite pro Jahr.
- Wie viel im Depot für Sparziele zurückgelegt ist, steht auf der Seite Ziele beim jeweiligen Sparziel („liegt auf …“).

### Hinweise auf der Startseite

Was Aufmerksamkeit braucht, steht als Hinweis oben auf der Startseite, Rotes vor Gelbem. Ein Tipp auf einen Hinweis öffnet den passenden Bildschirm. Ein Beispiel: „Girokonto: Der tiefste Stand (140 € am 27.11.) liegt unter dem Puffer. Vorschlag: 150 € vom Tagesgeld bis 25.11. umbuchen.“ Oder: „Baufinanzierung: Die Zinsbindung endet am 30.06., Restschuld dann etwa 182.400 €.“ Weitere Beispiele: „Urlaub liegt hinter Plan“, „Tagesgeld: Das Geld für Sparpläne und Daueraufträge reicht nur bis 15.12.“ (nur bei einer Lücke in den nächsten drei Monaten) oder „Kurs fehlt oder ist veraltet in Depot X“. Wird das Taschengeldkonto eines Kindes für einen Sparplan oder Dauerauftrag knapp, sehen die Eltern denselben Hinweis ebenfalls; ein Tipp darauf öffnet die Seite Ziele, weil Kinder-Konten nicht auf der Seite Konten stehen.

Ist nichts zu tun, steht oben genau ein Satz: **„Alles in Ordnung“**. Ein dauerhafter Zustand wie „Notreserve noch nicht voll“ steht nur an seiner Zeile, nicht oben.

Die Übersicht spricht die Sprache, die du mit `/language` eingestellt hast.

## Nur anschauen, gebucht wird im Chat

Die Übersicht zeigt nur an. Buchen, Ändern und Löschen läuft wie gewohnt im Chat, mit der Bestätigungs-Karte davor (siehe [Chatten & Bestätigen](chatten-bestaetigen.html)). Alle Zahlen rechnet die Datenbank aus denselben Daten, die auch der Chat nutzt; die App selbst rechnet nichts.

## Befehle gehen jetzt über „/“

Der Knopf „📊 Übersicht“ sitzt an der Stelle, an der vorher der Menü-Knopf mit der Befehlsliste war. Die Befehle gibt es weiterhin: Tippe im Eingabefeld **„/“**, dann klappt die Liste auf (`/help`, `/reminders` usw., siehe [Befehle](befehle.html)).

## Wer was sieht

- **Du als Owner und dein Partner bzw. deine Partnerin** seht den ganzen Haushalt, auch das Vermögen und die Depots der Kinder. Sie stehen je Seite in einem eigenen Abschnitt „… der Kinder“ und zählen nicht in die Haushalts-Summen.
- **Kinder** sehen nur, was ihnen gehört: eigene Konten, das eigene Depot, Sparziele für sie selbst und Sparpläne für sie auf ihrem eigenen Depot. Gemeinsame Haushaltskonten und -ziele und die Konten der Eltern tauchen bei ihnen nicht auf, auch nicht als Name: Liegt Geld für ihr Sparziel auf einem Elternkonto, heißt es bei ihnen nur „Haushaltskonto“, und eine Rate von einem Elternkonto heißt „Rate von Haushaltskonto“. Zahlt ein Sparplan der Eltern mit in ihr Ziel, zählt sein Betrag in der Rate mit, sein Name erscheint nicht.
- Auf der Seite **Konten** sehen Kinder nur ihre eigenen Konten mit deren Zahlungen. Taschengeld vom Elternkonto erscheint als „Vom Haushalt“, ohne den Namen des Dauerauftrags oder des Elternkontos, und einen Umbuchungs-Vorschlag bekommen Kinder nie.
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

Wie weit „Gehen ab“ und „Kommen rein“ auf der Seite Konten reichen, ab wann ein Konto als knapp gilt und wie früh vor dem Ende einer Zinsbindung gewarnt wird, stellst du ebenfalls ein:

| Befehl | Wirkung |
|---|---|
| `lifeagents config set finance app_payments_days 30` | „Gehen ab“ / „Kommen rein“ auf der Seite Konten für so viele Tage im Voraus. |
| `lifeagents config set finance coverage_warn_factor 2` | Gelb, wenn der tiefste vorausgesagte Kontostand unter dem Doppelten des Puffers liegt; rot unter dem Puffer selbst (`coverage_buffer_eur`). |
| `lifeagents config set finance everyday_oneoff_eur 250` | Ab diesem Einzelbetrag gilt eine Ausgabe im Kontoauszug als einmalig und zählt nicht zu den geschätzten Alltagsausgaben (gilt ab dem nächsten Auszug). |
| `lifeagents config set finance fixed_rate_warn_months 12` | Hinweis, wenn die Zinsbindung eines Kredits in weniger als so vielen Monaten endet. |
| `lifeagents config set finance funding_horizon_months 24` | So viele Monate voraus prüft der Tab Konten, ob das Geld für Sparpläne und Daueraufträge reicht (sonst „reicht bis …“). |
| `lifeagents config set finance depot_cover_warn_pct 10` | Ab so viel Prozent unter dem Ziel-Geld bekommt ein Sparziel mit Geld im Depot auf der Seite Ziele die rote Markierung „Kurswert … unter dem Zurückgelegten“ (und der Berater meldet es); darunter zeigt die Seite nichts an. |
| `lifeagents config set finance funding_alert_months 3` | Rot „Lücke ab …“ und ein Hinweis auf der Startseite, wenn das Geld schon innerhalb so vieler Monate fehlt. |
