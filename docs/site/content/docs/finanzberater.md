---
title: "Finanzberater"
---

Neben dem [Buchhalter](buchhalter.html), der bucht und verwaltet, gibt es einen zweiten Finanz-Agenten: den Finanzberater. Er interviewt dich zu deinen Zielen, denkt strategisch mit, recherchiert und pflegt einen schriftlichen Finanzplan. Was er **nicht** tut: buchen. Das ist bewusst so gebaut, nicht nur eine Regel im Prompt.

## Bucht nie (technisch erzwungen)

Der Finanzberater bekommt gar keine Werkzeuge (Tools) in die Hand, mit denen er Kontostände, Buchungen oder Stammdaten verändern könnte. Er liest deine Finanzdaten und formuliert daraus einen Plan. Dauerhaft speichert er nur Plan-Abschnitte, die Veröffentlichung des fertigen Plans und Mess-Punkte für den Monitor. Einzige Ausnahme bei deinen Daten: Er ordnet deine Depot-Positionen den Bausteinen deines Plans zu (siehe unten). Für alles brauchst du jedes Mal zu bestätigen, über das Bestätigungs-Gate (siehe [Chatten & Bestätigen](chatten-bestaetigen.html)). Willst du tatsächlich etwas buchen, verweist er dich an den Buchhalter — das ist kein Zufall, sondern die Aufgabenteilung des Systems.

## Vom Ist zum Soll: das Interview

Deine tatsächlichen Zahlen (Konten, Einkommen, Kredite, Versicherungen, Vorsorge) kennt das System bereits aus deiner Erfassung. Der Finanzberater fragt sie deshalb nicht noch einmal komplett ab, sondern liest sie vor und lässt dich nur bestätigen oder korrigieren — seine eigentliche Arbeit ist die Strategie-Entscheidung obendrauf (das Soll). Er arbeitet dabei ein Thema nach dem anderen ab, fasst am Ende jeder Antwort kurz zusammen, was bisher erfasst ist, und spielt dir am Ende eines Themenblocks die komplette Zusammenfassung noch einmal zum Gegenlesen vor, bevor er sie speichert.

Die Reihenfolge der Themen folgt einer bewährten Beratungs-Logik (angelehnt an die DIN-Norm für Finanzanalysen): erst Absicherung (fehlt eine Berufsunfähigkeitsversicherung?), dann Vorsorge (Rentenlücken), dann erst Vermögensaufbau. Konkret geht er neun Abschnitte durch — Basisdaten, Risikoabsicherung, Notgroschen, Kredite, Altersvorsorge, dein Risikoprofil, Vermögensaufbau-Strategie, grenzüberschreitende Themen (falls relevant) und schließlich Ziele. Aus vier dieser Abschnitte entstehen strukturierte Kennzahlen, die die Datenbank später maschinell auswerten kann: dein Sparziel (Zielrente, Zielvermögen), dein Risikoprofil (wie viel Risiko du tragen willst und wie viel du dir finanziell leisten kannst), deine Ziel-Verteilung des Vermögens (z. B. wie viel Prozent Aktien, wie viel Festgeld — mit Toleranz-Korridor) und dein Notgroschen-Ziel.

## Monatsüberschuss: Konsum, Pflicht und Sparen getrennt

Der Berater rechnet deinen Monat in klar getrennten Teilen:
- Einnahmen;
- Konsum (inklusive Kreditzinsen);
- Tilgung;
- was danach frei bleibt;
- Sparen (Sparpläne, Sparziele, Vorsorge);
- die echte Veränderung deines Kontos.

Ein ETF-Sparplan ist damit keine Ausgabe mehr.

Er meldet sich auf zwei Arten:
- **Warnung vor einem Defizit:** nur dann, wenn Konsum und Kreditraten deine Einnahmen übersteigen.
- **Eigener Hinweis:** wenn deine Sparraten höher sind als das, was frei bleibt. Dann leert sich dein Girokonto wirklich.

Auch die Notgroschen-Prüfung rechnet ehrlich:
- Sie geht von den Pflichtausgaben aus (Konsum und Kreditraten), Sparraten zählen nicht.
- Als Notgroschen zählt nur freies Geld. Geld auf Kinderkonten und für Sparziele zurückgelegtes Geld zählen nicht mit.

## Abweichung vom Zielmix

Deine Ziel-Verteilung enthält oft auch Bausteine, die man nicht kurzfristig umschichten kann, etwa Festgeld oder eine Immobilie. Der Berater vergleicht Ist und Soll deshalb nur über die handelbaren Bausteine, auf derselben Basis. Ein Plan wie „Welt 50 %, Anleihen 20 %, Cash 10 %, Festgeld 20 %“, den du genau so hältst, löst also keinen Alarm aus. Wählst du als Zielgröße das Gesamtvermögen, zählt die Immobilie mit, und Haus und Hypothek heben sich auf.

## Positionen den Plan-Bausteinen zuordnen

Damit der Abgleich mit dem Zielmix funktioniert, muss jede Depot-Position wissen, zu welchem Baustein deines Plans sie gehört (ihre Anlageklasse). Das klärt der Berater in der Finanzplanung, nicht schon beim Erfassen:
- direkt nachdem ihr die Ziel-Verteilung festgelegt habt;
- bei jeder Plan-Überprüfung;
- wenn er meldet, dass Positionen keinem Baustein zugeordnet sind (die Meldung nennt sie mit Namen).

Er schlägt je Position einen Baustein vor, du bestätigst oder korrigierst im Chat, dann kommt **eine** Karte für alle. Positionen im Depot eines anderen Familienmitglieds (etwa eines Kinderdepots) fragt er ausdrücklich ab. Gehören sie nicht zu eurem Plan, markiert er sie als **bewusst außerhalb des Plans**: Sie zählen weiter zum Vermögen, lösen aber keine Erinnerung mehr aus.

```
Finanzberater: Drei Positionen haben noch keinen Baustein:
     • S&P 500 (Dist) im Trade Republic Depot → sp500
     • Bitcoin im Depot Mia → bewusst außerhalb des Plans?
     • Space Exploration Techs im Depot Mia → bewusst außerhalb des Plans?
     Passt das so?

Erika: Ja, Mias Depot gehört nicht zum Plan.

Bot: Anlageklassen zuordnen – bitte prüfen:
     • S&P 500 (Dist) (Trade Republic Depot) → sp500
     • Bitcoin (Depot Mia) → bewusst außerhalb des Plans
     • Space Exploration Techs (Depot Mia) → bewusst außerhalb des Plans
     [✅ Bestätigen]  [❌ Abbrechen]
```

## Veröffentlichen mit Bestätigung

Sind alle Abschnitte durchgesprochen, schreibt der Finanzberater den vollständigen Plan als Text zusammen und fasst die Änderungen zusammen. Auch das Veröffentlichen läuft über das Bestätigungs-Gate — erst nach deinem Tippen auf den Button wird der Plan aktiv und ab dann als dein „lebendes" Finanzdokument geführt. Nach der ersten Veröffentlichung bietet dir das System automatisch an, zwei Wächter einzuschalten: einen, der täglich prüft, ob deine Wirklichkeit vom Plan abweicht, und einen jährlichen Reminder für dein Risikoprofil und das neue Steuerjahr.

## Recherche mit Datum, Experten-Panel bei großen Fragen

Bei „Lohnt sich das?"-Fragen sucht der Finanzberater aktuelle Informationen im Web und nennt dir dabei immer das Datum der Quelle — wichtig etwa bei Steuerwerten, die sich jährlich ändern (Freibeträge, Basiszinssätze). Bei größeren oder schwer rückgängig zu machenden Entscheidungen holt er sich zusätzlich die Meinung eines simulierten Experten-Panels ein (mehrere unabhängige KI-Perspektiven) und legt dir Zustimmung wie Widerspruch offen vor, statt sie zu verwässern.

## Meldet sich nur bei echten Neuigkeiten

Der Finanzberater spammt dich nicht. Er meldet sich proaktiv nur, wenn sich etwas **neu** von deinem Plan entfernt hat (Abweichungs-Check), und fasst dir in regelmäßigem Abstand einen kompakten Überblick zusammen (Quartals-Digest). Konkrete Schwellenwerte aus dem Plan — etwa „bei Kurs X nachkaufen" oder „in sechs Monaten die koreanische Rente neu prüfen" — kann er als Mess-Punkt an den [Monitor](monitor-guide.html) übergeben, der sie dauerhaft im Hintergrund beobachtet. Ändern oder löschen kannst du einen solchen Mess-Punkt danach nur noch über den Monitor selbst.

Aus dem [Monats-Check](monats-check.html) kommen zwei Warnungen dazu: **Konto knapp**, wenn ein Konto bis zum nächsten Geldeingang voraussichtlich unter deinen Puffer (Standard 250 €) fällt, mit einem Umbuchungs-Vorschlag (Betrag, bis wann, von welchem Konto), und **Zahlung fehlt**, wenn ein Dauerauftrag zweimal in Folge nicht vom Konto ging.

## Beispiel (fiktiv)

```
Erika: Lohnt es sich, jetzt zusätzlich in Gold zu investieren?

Finanzberater: Kurzfassung: Nein, nicht als neue Position — dein Plan
sieht für "wealth_building" bereits einen Stabilitätsblock über
Festgeld vor, Gold würde ihn nur verdoppeln.

Begründung: Dein aktuelles Ziel-Portfolio (Stand 15.03.2026) sieht
70 % Aktien-ETF, 20 % Festgeld, 10 % Anleihen vor. Laut einer
Marktanalyse vom 28.06.2026 wird Gold aktuell als "fair bewertet"
eingestuft — kein klarer Kauf-Trigger.

Eine abweichende Expertenmeinung: Ein Panel-Mitglied hält 5 % Gold
als Inflationsschutz für sinnvoll, ein anderes widerspricht wegen
fehlender Erträge.

Soll ich das als neue Diskussion in deinen Plan aufnehmen, oder
reicht dir das für heute?
```

Der Finanzberater bucht in diesem Gespräch nichts — er berät nur. Eine tatsächliche Order würdest du anschließend beim [Buchhalter](buchhalter.html) beauftragen.
