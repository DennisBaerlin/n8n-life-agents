---
title: "Finanzberater"
---

Neben dem [Buchhalter](buchhalter.html), der bucht und verwaltet, gibt es einen zweiten Finanz-Agenten: den Finanzberater. Er interviewt dich zu deinen Zielen, denkt strategisch mit, recherchiert und pflegt einen schriftlichen Finanzplan. Was er **nicht** tut: buchen. Das ist bewusst so gebaut, nicht nur eine Regel im Prompt.

## Bucht nie (technisch erzwungen)

Der Finanzberater bekommt gar keine Werkzeuge (Tools) in die Hand, mit denen er Kontostände, Buchungen oder Stammdaten verändern könnte. Er liest deine Finanzdaten und formuliert daraus einen Plan. Dauerhaft speichert er nur Plan-Abschnitte, die Veröffentlichung des fertigen Plans und Mess-Punkte für den Monitor. Einzige Ausnahme bei deinen Daten: Er ordnet deine Depot-Positionen den Bausteinen deines Plans zu (siehe unten). Für alles brauchst du jedes Mal zu bestätigen, über das Bestätigungs-Gate (siehe [Chatten & Bestätigen](chatten-bestaetigen.html)). Willst du tatsächlich etwas buchen, verweist er dich an den Buchhalter — das ist kein Zufall, sondern die Aufgabenteilung des Systems.

## Vom Ist zum Soll: das Interview

Deine tatsächlichen Zahlen (Konten, Einkommen, Kredite, Versicherungen, Vorsorge) kennt das System bereits aus deiner Erfassung. Der Finanzberater fragt sie deshalb nicht noch einmal komplett ab, sondern liest sie vor und lässt dich nur bestätigen oder korrigieren — seine eigentliche Arbeit ist die Strategie-Entscheidung obendrauf (das Soll). Er arbeitet dabei ein Thema nach dem anderen ab, fasst am Ende jeder Antwort kurz zusammen, was bisher erfasst ist, und spielt dir am Ende eines Themenblocks die komplette Zusammenfassung noch einmal zum Gegenlesen vor, bevor er sie speichert.

Die Reihenfolge der Themen folgt einer bewährten Beratungs-Logik (angelehnt an die DIN-Norm für Finanzanalysen): erst Absicherung (fehlt eine Berufsunfähigkeitsversicherung?), dann Vorsorge (Rentenlücken), dann erst Vermögensaufbau. Für die Rentenlücke nutzt er deine neueste Renteninformation: die beiden Szenarien der Rentenversicherung (1 % und 2 % jährliche Anpassung) rechnet die Datenbank mit der Inflationsannahme deines Plans in heutige Kaufkraft um, und der Berater nennt das Ergebnis als Spanne – mit dem Hinweis, dass die Beträge brutto sind (vor Kranken- und Pflegeversicherung und Steuer). Konkret geht er neun Abschnitte durch — Basisdaten, Risikoabsicherung, Notgroschen, Kredite, Altersvorsorge, dein Risikoprofil, Vermögensaufbau-Strategie, grenzüberschreitende Themen (falls relevant) und schließlich Ziele. Aus vier dieser Abschnitte entstehen strukturierte Kennzahlen, die die Datenbank später maschinell auswerten kann: dein Sparziel (Zielrente, Zielvermögen), dein Risikoprofil (wie viel Risiko du tragen willst und wie viel du dir finanziell leisten kannst), deine Ziel-Verteilung des Vermögens (z. B. wie viel Prozent Aktien, wie viel Festgeld — mit Toleranz-Korridor) und dein Notgroschen-Ziel.

Hast du schon einen Plan, der aber noch Lücken hat (etwa weil du ihn importiert hast oder ein Gespräch abgebrochen wurde), merkt der Berater das selbst: Die Datenbank prüft, welche Abschnitte nie im Gespräch bestätigt wurden und welche Kennzahlen fehlen, zum Beispiel das Notgroschen-Ziel. Der Berater beantwortet zuerst deine eigentliche Frage und bietet dir dann einmal an, die fehlenden Teile nacheinander zu ergänzen, das Wichtigste zuerst. Bereits bestätigte Abschnitte fragt er nicht noch einmal ab.

Ist die Einstiegs-Pflicht eingeschaltet (Standard), muss der Einstieg im Finanzbereich (`/onboarding`) dafür erledigt oder übersprungen sein. Nur der Monats-Check sperrt den Berater nicht.

**Der Weg zum Plan im Onboarding:** Sobald du die Finanzen eingerichtet hast, zeigt dir die Abschluss-Karte den Finanzplan als nächsten Schritt, mit dem Hinweis, dass er freiwillig ist, aber hilft. Auch im Bereich Finanzen von `/onboarding` steht er als eigene Zeile. Der Knopf passt sich deinem Stand an: „Finanzplan erstellen“ (noch keiner da), „Finanzplan fortsetzen“ (Entwurf angefangen), „Finanzplan vervollständigen (3 offen)“ (Lücken wie oben beschrieben) oder „Finanzplan überprüfen“. Ein Tipp holt den Berater, und er legt sofort los, ohne erst noch einmal zu fragen. Der Plan-Schritt ist kein Pflicht-Abschnitt: Du kannst trotzdem mit den anderen Bereichen weitermachen, und es gibt keine Erinnerungen dafür.

Damit ein Plan sinnvoll wird, prüft die Datenbank vorher die Mindestdaten: ein Geld-Konto mit Kontostand, ein regelmäßiges Einkommen und regelmäßige Ausgaben (z. B. Miete, Versicherungen, Abos). Fehlt davon etwas, zum Beispiel weil du einen Bereich übersprungen hast, zeigt dir der Bot statt des Plan-Knopfs, was noch fehlt, und einen Knopf „Zuerst: …“, der genau diesen Abschnitt beim Buchhalter öffnet. Versicherungen, Rente oder Depots sind keine Voraussetzung, denn Lücken dort findet gerade das Interview. Den Plan speichert und ändert nur der Haushalts-Owner; andere Mitglieder können sich trotzdem beraten lassen.

**Erwachsene über einen neuen Plan informieren:** Hast du als Owner einen neuen Finanzplan veröffentlicht, fragt dich der Bot mit einem Knopf, ob die anderen Erwachsenen im Haushalt informiert werden sollen. Gemeint sind Partner, Kinder nie. Ohne deinen Tipp passiert nichts. Tippst du, bekommt jede erwachsene Person einmal je Planversion eine kurze Nachricht in ihrer Sprache. Sprecht ihr dieselbe Sprache, steht deine Änderungs-Zusammenfassung dabei; sonst steht dort, dass der Berater die Änderungen in ihrer Sprache erklärt (dein Text wird nie automatisch übersetzt). Die Nachricht hat drei Knöpfe: „Plan erklären lassen“ (der Berater erklärt den Plan in einfacher Sprache und beantwortet Fragen, ändert aber nichts), „Wunsch an den Owner“ (der Berater fragt nach dem Wunsch, die Person bestätigt ihn, und du bekommst ihn wörtlich als Nachricht – am Plan ändert sich nichts, du entscheidest) und „Nicht mehr informieren“ (wieder einschalten über `/reminders`).

## Monatsüberschuss: Konsum, Pflicht und Sparen getrennt

Der Berater rechnet deinen Monat in klar getrennten Teilen:
- Einnahmen;
- Konsum (inklusive Kreditzinsen);
- Tilgung;
- was danach frei bleibt;
- Sparen (Sparpläne, Sparziele, Vorsorge);
- die echte Veränderung deines Kontos.

Ein ETF-Sparplan ist damit keine Ausgabe mehr.

Die Monatsübersicht selbst kennt nur deine regelmäßigen Zahlungen. Für „was frei bleibt“ rechnet der Berater deshalb die Alltagsausgaben (Einkauf, Karte, Bargeld) dazu, die aus deinen Kontoauszügen geschätzt werden, und sagt bei jeder Warnung, womit er gerechnet hat. Ohne Kontoauszug sagt er, dass diese Zahl noch fehlt und in Wirklichkeit weniger frei bleibt.

Er meldet sich auf zwei Arten:
- **Warnung vor einem Defizit:** wenn feste Zahlungen, Kreditraten und geschätzter Alltag deine Einnahmen übersteigen.
- **Eigener Hinweis:** wenn deine Sparraten höher sind als das, was danach frei bleibt. Dann leert sich dein Girokonto wirklich.

## Notreserve

Deine Notreserve ist eine eigene Rücklage, keine Zahl im Finanzplan:
- **Ziel:** ein fester Betrag oder eine Zahl von Monatsausgaben, etwa „3 Monatsausgaben“. Die Monatsausgaben sind feste Zahlungen und Kreditraten (ohne Sparraten) plus der geschätzte Alltag; das Ziel passt sich an, wenn sich deine Ausgaben ändern.
- **Wo das Geld liegt:** Du ordnest Beträge auf einem oder mehreren Giro- oder Tagesgeldkonten zu, ohne Geld zu bewegen. P2P, Festgeld und Depots zählen nicht, weil das Geld dort nicht sofort und nicht einlagengesichert verfügbar ist.
- **Anlegen:** beim Onboarding im Schritt „Notreserve“ oder jederzeit im Chat („Leg meine Notreserve an: drei Monatsausgaben, 6.000 € liegen auf dem Tagesgeld“). Hast du schon ein Sparziel für den Notgroschen, wird es umgewidmet statt doppelt angelegt.
- **Prüfung:** Der Berater meldet sich, wenn weniger zugeordnet ist als das Ziel. Notreserve-Geld schlägt er nie für Umbuchungen vor.

Drei Begriffe, die oft verwechselt werden: Der **Puffer** ist, was auf einem Zahlungskonto immer bleiben soll (je Konto). Die **Notreserve** sind Monate an Ausgaben für Notfälle. Ein **Sparziel** ist Geld für einen bestimmten Zweck.

## Reicht das Geld für deine Sparpläne?

Fragst du, ob du einen Sparplan erhöhen kannst oder ob das Geld auf einem Konto reicht, liest der Berater dieselbe Vorausschau, die auch die [Übersicht](uebersicht-app.html) im Tab Konten zeigt. Für jedes Konto, von dem ein Sparplan oder ein Dauerauftrag abgeht, rechnet die Datenbank voraus; Geld, das dort für Sparziele zurückliegt, zählt nicht als frei (standardmäßig zwei Jahre): gedeckt, reicht bis zu einem bestimmten Tag, oder wird in den nächsten Monaten knapp. Der Berater rechnet das nie selbst nach. Wo die Datenbank es nicht weiß (etwa ohne Kontoauszug), sagt er, was fehlt. Ob ein Sparziel hinter Plan liegt, entscheidet ebenfalls dieselbe Regel wie in der Übersicht, damit Bot und App nie Verschiedenes sagen.

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

Aus dem [Monats-Check](monats-check.html) kommen zwei Warnungen dazu: **Konto knapp**, wenn ein Konto bis zum nächsten Geldeingang voraussichtlich unter deinen Puffer (Standard 250 €) fällt, mit einem Umbuchungs-Vorschlag (Betrag, bis wann, von welchem Konto; nie von einem Kinderkonto), und **Zahlung fehlt**, wenn ein Dauerauftrag zweimal in Folge nicht vom Konto ging.

Für Immobilien meldet er sich, wenn die **Instandhaltungsrücklage** unter der Empfehlung nach II. BV liegt (zum Beispiel, weil das Haus in eine ältere Altersstufe gerutscht ist oder die Sätze angepasst wurden) oder wenn eine Immobilie noch gar keine Rücklage hat. Jeder dieser Hinweise kommt nur einmal, bis sich etwas ändert.

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
