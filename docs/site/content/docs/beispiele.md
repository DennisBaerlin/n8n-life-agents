---
title: "Beispiele"
---

Die beste Art, das System zu verstehen, ist es in Aktion zu sehen. Hier sind elf typische Unterhaltungen mit dem Bot — alle Namen, Beträge und Treffer sind erfunden. Wie das Bestätigen per Knopf genau funktioniert, erklärt [Chatten & Bestätigen](chatten-bestaetigen.html); die einzelnen Fähigkeiten im Detail stehen bei [Buchhalter](buchhalter.html), [Finanzberater](finanzberater.html), [Monitor & Guide](monitor-guide.html), [Karriere-Coach](karriere-coach.html) und [Nachlass & Vorsorge](nachlass-berater.html).

## Eine Ausgabe buchen

Eine kurze Nachricht reicht — der Buchhalter (`agent.finance`) löst Konto und Betrag auf und legt dir die fertige Buchung zur Prüfung vor, bevor irgendetwas gespeichert wird.

```
Erika: Habe eben 45 Euro für Lebensmittel bei Rewe bezahlt

Bot: Ausgabe buchen – bitte prüfen:
     • Konto: Girokonto
     • Betrag: -45,00 €
     • Kategorie: Sonstiges
     • Datum: 02.07.2026
     [✅ Bestätigen]  [❌ Abbrechen]

Erika: [tippt ✅ Bestätigen]

Bot: Gebucht: -45,00 € auf Girokonto.
     Neuer Saldo: 1.205,00 €.
```

## Depotauszug fotografieren → Sammel-Import

Statt jedes Konto einzeln zu diktieren, kann Erika ein Foto oder PDF schicken, etwa einen Depotauszug, eine Police oder eine Renteninformation (einen Kontoauszug gleicht der [Monats-Check](monats-check.html) ab, siehe unten). Der Buchhalter liest die Werte per Bilderkennung heraus (Vision) und schickt sofort **eine** Bestätigungs-Karte für das ganze Paket. Darauf steht jeder Eintrag mit allen Feldern, genau wie beim einzelnen Anlegen.

```
Erika: [sendet Foto "Depotauszug_Oktober.pdf"]

Bot: Import – bitte prüfen:

     • Einträge: 2

     Depot-Position: VWCE
     • Wertpapier: VWCE (ISIN IE00BK5BQT80)
     • Bezeichnung: Vanguard FTSE All-World
     • Depot: Trade Republic Depot
     • Verrechnungskonto: Trade Republic Cashkonto
     • Stück: 42
     • Kurs: 98,10 €
     • Order-Gebühr: 0,00 €
     • Anlageklasse: —
     • Buchung: Bestandsübernahme (keine Abbuchung, Verrechnungskonto unverändert)
     • Datum: 22.10.2026

     Depot-Position: …

     Alles-oder-nichts: bei Fehlern wird NICHTS gebucht.
     [✅ Bestätigen]  [❌ Abbrechen]

Erika: [tippt ❌ Abbrechen] Bei VWCE sind es 44 Stück, nicht 42

Bot: Korrigiert. Import – bitte prüfen: … (neue Karte mit 44 Stück)

Erika: [tippt ✅ Bestätigen]

Bot: 2 Depot-Positionen übernommen. Kurs gefunden: VWCE 98,10 € (Stand heute).
     Für die zweite Position finde ich noch keinen Kurs – soll ich die Börse heraussuchen?
```

Ob ein Kurs gefunden wurde, sagt der Bot nach jedem Kauf, jeder Korrektur, jedem Import und jeder Sparplan-Ausführung. Bleibt eine Position ohne Kurs (oder kommt seit über einer Woche keiner mehr), meldet sich der **Kurs-Check** von selbst, auch ohne Finanzplan:

```
Bot: 📉 Für S&P 500 (Trade Republic Depot) finde ich keinen Kurs (abgefragt: SPX5).

     Gefunden: SPX5.DE – Beispiel S&P 500 UCITS ETF, GER, aktuell 12,40 €. Als Kursquelle übernehmen?
     [✅ Übernehmen]  [Nicht jetzt]

Erika: [tippt ✅ Übernehmen]

Bot: Kursquelle für S&P 500 ist jetzt SPX5.DE. Aktueller Kurs: 12,40 € (Stand 27.10.2026).
```

Vorgeschlagen wird nur eine Notierung, deren Kurs zum bisherigen Kurs bzw. zum Einstand passt. Findet Yahoo über die ISIN nichts Passendes, sucht der Bot per Websuche nach dem Börsen-Kürzel und prüft jeden Fund, bevor er ihn anbietet. Ohne Tipp meldet er sich nach 7 Tagen wieder; abschalten lässt sich der Kurs-Check unter `/reminders`.

Bei sehr vielen Einträgen passt die Karte nicht in eine Telegram-Nachricht. Dann kommt sie in mehreren Teilen („Teil 1/3 …“), die Knöpfe hängen am letzten Teil.

**Vermögensübersicht ohne Kürzel und Einstand.** Manche Übersichten (z. B. von Trade Republic) drucken je Position nur die ISIN und den heutigen Kurs. Das reicht: Die ISIN ist dann die Kennung, und den Kurs holt sich das System selbst. Nur den Einstand (was du bezahlt hast) kann das Dokument nicht liefern. Dann fragt der Bot einmal für alle Positionen nach:

```
Bot: Bei beiden Positionen fehlt der Einstand: Space Exploration Techs (1,343429 Stück)
     und S&P 500 (Dist) (42,731759 Stück). Wie hoch war jeweils dein Einstand, je Stück oder gesamt?

Erika: SpaceX 150 € gesamt, S&P 55,10 je Stück
```

Danach kommt die Karte. Das Depot ordnet der Bot über die gedruckte Depotnummer bzw. den Depot-Inhaber zu, nicht über den Namen. Kennt ein Depot seine Nummer noch nicht, speichert der Import sie mit, und die Karte sagt das ausdrücklich. Steht dort ein falsches Depot, tippe „Abbrechen“.

**Kurs nur in Fremdwährung.** Findet die Kurssuche für eine ISIN keine Euro-Notierung (etwa eine Aktie, die nur an der Nasdaq in US-Dollar gehandelt wird), nimmt sie die Fremdwährungs-Notierung, sofern der Kurs zu deinem Einstand passt. Die Karte sagt es dazu („der Kurs kommt in USD und wird für die Übersicht in € umgerechnet“). Deine Position bleibt in Euro, der Wechselkurs wird sofort mit abgeholt.

**Cash-Stand der Übersicht.** Druckt die Übersicht auch das Guthaben des Verrechnungskontos („Cash … zum 23.10.“), wird es nicht als neues Konto angelegt. Nach der Import-Karte kommt eine zweite Karte, die den Saldo dieses Kontos zum gedruckten Datum abgleicht:

```
Bot: Kontoabgleich buchen – bitte prüfen:
     • Konto: Cashkonto Mia
     • Saldo laut System: 3.104,97 €
     • Bestätigter Saldo: 3.054,97 €
     • Differenz: −50,00 € (Korrekturbuchung wird angelegt)
     • Datum: 23.10.2026
     [✅ Bestätigen]  [❌ Abbrechen]
```

Würde der Abgleich offene Sparplan- oder Dauerauftrags-Ausführungen bis zu diesem Datum als erledigt markieren, steht die Anzahl als Hinweis auf der Karte. Ist das Konto im selben Import neu, gehört der Stand als Eröffnungssaldo in die Konto-Zeile.
## Monats-Check: Kontoauszug statt Einzelbuchungen

Einmal im Monat erinnert der Bot an den Kontoauszug. Erika schickt das PDF aus dem Online-Banking; der Buchhalter erkennt das Konto an der IBAN, hakt die geplanten Zahlungen ab und bucht den Rest als eine Summe. Einzelumsätze werden nicht gespeichert.

```
Bot: Monats-Check für Oktober: Ich brauche den Kontoauszug für
     • Girokonto (bestätigt bis 30.09.2026)
     So geht's: Online-Banking → Postfach → Kontoauszug als PDF → hier schicken.

Erika: [sendet "Kontoauszug_Oktober.pdf"]

Bot: Monats-Check Girokonto – bitte prüfen:
     • Zeitraum: 01.10.–31.10.2026
     • Anfang: 1.250,00 € · Ende: 1.410,00 €
     Abgehakt: Gehalt +2.800,00 € · Miete -950,00 € · Strom -92,00 € (Plan 85,00 €)
     Nicht im Auszug: Fitnessstudio -29,00 € (wird übersprungen)
     Alltagsausgaben: -1.598,00 €
     [✅ Übernehmen]  [❌ Abbrechen]

Erika: [tippt ✅ Übernehmen]

Bot: Übernommen, Girokonto steht auf 1.410,00 €. Bis zum Gehalt am 01.12.
     reicht es: tiefster Stand etwa 310 € am 30.11.
     Fitnessstudio kam diesen Monat nicht – gekündigt?
```

## Frage an den Finanzberater: Allokations-Drift

Der Finanzberater (`agent.finance_advisor`) bucht nichts selbst — er liest den echten Depot-Stand aus der Datenbank und vergleicht ihn mit dem hinterlegten Plan (Ziel-Aufteilung, "target allocation").

```
Max: Wie sieht meine Aktienquote gerade im Vergleich zum Plan aus?

Bot: Dein Plan sieht 60 % Aktien-ETF vor (Korridor 55–65 %).
     Aktuell liegt der Anteil bei 68 % — außerhalb des Korridors,
     weil die Kurse zuletzt gestiegen sind.
     Empfehlung: einen Teil in Festgeld oder Anleihen umschichten,
     um wieder in den Zielkorridor zu kommen. Ich buche das nicht
     selbst — sag Bescheid, dann übernimmt der Buchhalter das.
```

## Sparziel-Tempo prüfen

Ob ein Sparziel im Plan liegt, rechnet die Datenbank aus (erwarteter Fortschritt vs. tatsächlicher, "pace drift") — der Finanzberater liest das Ergebnis nur vor.

```
Erika: Schaffe ich mein Sparziel "Weltreise" bis Ende 2027 noch?

Bot: Ziel: 6.000,00 € bis 31.12.2027. Aktueller Stand: 2.100,00 €.
     Nach Zeitplan solltest du bei 2.600,00 € stehen — du liegst
     also leicht zurück. Bei gleichbleibender Sparrate wäre das
     Ziel erst im März 2028 erreicht.
     Um wieder im Plan zu sein, müsstest du die monatliche Rate
     um rund 35,00 € erhöhen. Sag Bescheid, dann passt der
     Buchhalter die Rate an.
```

## Einen Monitor-Trigger anlegen — und einen Alarm erleben

Der Monitor (`agent.monitor`) überwacht einen einzelnen Wert und meldet sich, sobald eine Schwelle erreicht ist. Anlegen läuft im Dialog (Werte/Einheit klären, dann Bestätigung mit Live-Wert); ausgelöst wird später automatisch.

```
Max: Sag mir Bescheid, wenn der Goldpreis unter 1.900 Euro
     pro Feinunze fällt

Bot: Verstanden: Goldpreis in Euro pro Feinunze, Alarm bei
     Unterschreiten von 1.900,00 €, Prüfung einmal täglich.
     Trigger anlegen – bitte prüfen:
     • Bezeichnung: Goldpreis-Alarm
     • Aktueller Wert: 1.978,40 €
     • Schwelle: 1.900,00 € (unterschritten)
     [✅ Bestätigen]  [❌ Abbrechen]

Max: [tippt ✅ Bestätigen]

Bot: Trigger "Goldpreis-Alarm" ist scharf. Nächste Prüfung: morgen.

— einige Wochen später —

Bot: 🔔 Goldpreis-Alarm ausgelöst: 1.892,50 € (Schwelle 1.900,00 €
     unterschritten).

Max: Lohnt sich jetzt ein Kauf?

Bot: (der Finanzberater übernimmt) Dein Plan sieht 5 % Rohstoffe vor,
     aktuell hältst du 3 % — ein Kauf würde die Lücke schließen.
     Nenn mir einen Betrag, dann rechne ich ihn für dich durch.
```

Beachte den nahtlosen Wechsel: Die Nachfrage geht automatisch an den [Finanzberater](finanzberater.html) — du musst niemanden „anrufen", der Verteiler erkennt, dass jetzt Beratung gefragt ist.

## Onboarding starten

Nach der Einrichtung führt der Guide (`agent.guide`) Schritt für Schritt durch die Grunddaten — Details zu allen Befehlen stehen bei [Befehle](befehle.html).

```
Erika: /onboarding

Bot: Dein Onboarding - 0 von 9 erledigt
     ◻ Haushalt & Personen
     ◻ Finanzen (0/5)
     ◻ Karriere (0/3)
     👉 Als Naechstes: Haushalt & Personen
     [👉 Weiter: Haushalt & Personen]
     [👉 Haushalt & Personen] [Finanzen (0/5)] [Karriere (0/3)]

Erika: [tippt "Weiter"]

Bot: Los geht's mit den Haushalts-Basisdaten. Wie heißt du?

Erika: Erika

Bot: Wann bist du geboren?

Erika: 12.03.1985

Bot: Danke! Als Nächstes: dein monatliches Netto-Einkommen?
```

## Job-Match-Karte mit Feedback

Der werktägliche Stellen-Scan des Karriere-Coachs (`agent.career_advisor`) schickt passende Treffer als Karte mit 👍/👎 — ein Daumen-runter mit Begründung schärft künftige Treffer.

```
Bot: 🎯 Neuer Treffer (4/4 Punkte): Scrum Master (m/w/d)
     bei Beispiel GmbH, Hamburg
     [👍]  [👎]

Max: [tippt 👎]

Bot: Magst du kurz sagen, warum sie nicht passt?

Max: Zu viel Reisetätigkeit

Bot: Verstanden, ich merke mir: möglichst reisearme Stellen.
     Das fließt in die nächsten Treffer mit ein.
```

## Vorsorge-Register: Lücken sehen und schließen

Der Nachlass-Berater (`agent.estate_advisor`) führt das Notfall-Register des Haushalts. Er stützt sich immer auf das, was schon erfasst ist, benennt offene Lücken von selbst (nur bei Erwachsenen) und speichert erst nach deiner Bestätigung — niemals Passwörter, nur den Fundort.

```
Erika: Welche Vorsorge-Dokumente fehlen uns eigentlich noch?

Bot: Stand deines Notfall-Registers:
     ✅ Patientenverfügung (Erika, notariell, im Ordner „Vorsorge")
     ⬜ Vorsorgevollmacht — noch offen
     ⬜ Testament — noch offen
     Am wichtigsten wäre die Vorsorgevollmacht: Ohne sie darf im
     Ernstfall nicht automatisch dein Partner für dich entscheiden —
     dann bestellt das Gericht einen Betreuer.

Erika: Stimmt. Trag schon mal ein: Mein Testament liegt notariell
       vor, im Zentralen Testamentsregister eingetragen, im Ordner
       „Vorsorge" im Arbeitszimmer.

Bot: Vorsorge-Dokument eintragen – bitte prüfen:
     • Typ: Testament
     • Form: notariell
     • Register: Zentrales Testamentsregister (ZTR)
     • Fundort: Ordner „Vorsorge", Arbeitszimmer
     [✅ Bestätigen]  [❌ Abbrechen]

Erika: [tippt ✅ Bestätigen]

Bot: Eingetragen. Offen bleibt jetzt noch die Vorsorgevollmacht —
     sag Bescheid, wenn du sie hast.
```

## Im Ernstfall begleitet werden

Stirbt ein Mensch im Haushalt oder wird er handlungsunfähig, wechselt der Nachlass-Berater in den Ereignisfall-Modus: erst Mitgefühl, dann **eine** nächste Aufgabe — mit Fristen, die die Datenbank taggenau berechnet (nie das Sprachmodell). Direkt erreichbar ist er dafür auch über den Befehl `/notfall`.

```
Erika: Mein Mann ist heute gestorben.

Bot: Das tut mir sehr leid, Erika. Lass es uns gemeinsam angehen —
     einen Schritt nach dem anderen, du musst dir nichts merken.
     Der erste und wichtigste Schritt: die ärztliche
     Todesbescheinigung (den Totenschein) ausstellen lassen — ohne
     sie geht es nicht weiter. Habt ihr schon einen Arzt gerufen?

Erika: Ja, der Hausarzt war da.

Bot: Gut. Dann als Nächstes — und das ist zeitkritisch: Eure
     Unfallversicherung hat laut Register eine Meldefrist von
     48 Stunden. Den Kontakt habe ich hinterlegt. Soll ich dir die
     nötigen Angaben heraussuchen?
     (Die Sterbefallanzeige beim Standesamt ist bis zum 3. Werktag
     fällig — die übernimmt meist der Bestatter. Darum kümmern wir
     uns gleich danach.)
```

## Sprachnachricht statt Tippen

Sprachnachrichten werden zuerst automatisch in Text umgewandelt (Transkription) und dann wie eine normale Nachricht behandelt.

```
Erika: [sendet Sprachnachricht, 4 Sekunden]

Bot: 🎙 "Ich hab grad 12 Euro für den Bus bezahlt"
     Ausgabe buchen – bitte prüfen:
     • Konto: Girokonto
     • Betrag: -12,00 €
     • Kategorie: Sonstiges
     • Datum: 02.07.2026
     [✅ Bestätigen]  [❌ Abbrechen]
```
