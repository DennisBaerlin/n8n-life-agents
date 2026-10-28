---
title: "Monats-Check"
---

Der Monats-Check hält deine Kontostände und regelmäßigen Zahlungen aktuell, ohne dass du einzelne Umsätze eintippst und ohne tägliche Rückfragen. Einmal im Monat schickst du je Konto deinen Kontoauszug. Den Rest erledigt der Buchhalter.

## So läuft es ab

1. **Erinnerung.** Am 3. des Monats meldet sich der Bot: „Monats-Check: Ich brauche den Kontoauszug für Sparkasse Giro, ING Tagesgeld." Fehlt am 17. noch ein Konto, erinnert er nur noch an dieses.
2. **Auszug schicken.** Im Online-Banking das Postfach bzw. die Dokumente öffnen, den Kontoauszug des letzten Monats als PDF herunterladen und an den Bot schicken. Eine Datei je Konto; die nächste erst, wenn du die Karte bestätigt hast.
3. **Eine Karte prüfen.** Der Bot zeigt dir alles auf einer Karte:
   - welche geplanten Zahlungen gekommen sind (Miete, Gehalt, Kreditrate, Sparrate …), mit dem tatsächlichen Betrag;
   - was sich geändert hat (z. B. Strom 92 € statt 85 €; beim zweiten gleichen Betrag passt er den Plan an);
   - was **nicht** im Auszug stand (das wird für diesen Monat übersprungen);
   - Lastschriften, die er noch nicht kennt;
   - den Rest als **eine** Summe „Alltagsausgaben" (Supermarkt, Tanken, Kleinkram).

   Ein Tipp auf „Übernehmen", fertig.
4. **Vorschau.** Danach sagt dir der Bot, ob das Geld auf dem Konto bis zum nächsten Geldeingang reicht. Wird es knapp, schlägt er eine Umbuchung vor: wie viel, bis wann und von welchem Konto.

## Woran der Bot das Konto erkennt

An der **IBAN** auf dem Auszug. Legst du ein neues Konto an, fragt der Buchhalter einmal danach. Hast du sie gerade nicht zur Hand, ist das kein Problem: Beim ersten Auszug fragt er, welches deiner Konten gemeint ist, und merkt sich die IBAN.

**Auszug eines Kontos, das der Bot noch nicht kennt** (z. B. das Konto deines Kindes): Sag einfach, wem es gehört, etwa „das ist das neue Trade-Republic-Konto von Lisa“. Der Buchhalter legt es in **einem** Schritt an, mit der IBAN und dem Endstand aus dem Auszug. Auf der Karte steht der Stichtag, zu dem dieser Stand gilt. Den Auszug selbst spielt er dafür nicht mehr ein: Der Endstand ist der Startpunkt, der Monats-Check beginnt mit dem nächsten Auszug. Geht die Rechenprobe des Auszugs nicht auf, legt er das Konto ohne Kontostand an und fragt dich danach.

Ein Dokument kannst du auch ohne Text schicken. Der Bot liest es zuerst selbst und erkennt, ob es ein Kontoauszug, ein Depotauszug oder ein anderes Dokument ist.

## Woran er die Zahlungen erkennt

Beim ersten Mal am Betrag, am Datum und am Namen des Empfängers. Danach merkt er sich die Kennung der Lastschrift (Gläubiger-ID und Mandatsreferenz) bzw. die IBAN des Empfängers. Ab dann erkennt er die Zahlung sicher, auch wenn sich der Betrag ändert. Wechselst du den Anbieter, ist das eine neue Kennung. Der Bot zeigt die Zahlung dann zuerst als „unbekannt" und fragt nach.

## Sicher gegen Fehler

- **Rechenprobe:** Anfangsstand plus alle Zeilen muss genau den Endstand ergeben. Stimmt das nicht (z. B. eine Seite fehlt), übernimmt der Bot nichts und sagt dir die Differenz.
- **Nichts doppelt:** Was schon gebucht ist, wird abgehakt statt neu gebucht. Derselbe Monat kann nicht zweimal eingespielt werden.
- **Zurücknehmen:** Falsches Konto erwischt? „Nimm den letzten Kontoauszug von Giro zurück" macht den letzten Monats-Check dieses Kontos komplett rückgängig.
- **Einzelumsätze werden nicht gespeichert.** Aus dem Auszug bleiben nur Zeitraum, Anfangs- und Endstand und die Summe der Alltagsausgaben.

## Was der Finanzberater daraus macht

- **Konto knapp:** Fällt ein Konto voraussichtlich unter deinen Puffer (Standard 250 €), warnt er dich und nennt die Umbuchung. Den Puffer stellst du mit `lifeagents config set finance coverage_buffer_eur 400` um.
- **Zahlung fehlt:** Kam ein Dauerauftrag zweimal in Folge nicht vom Konto, fragt er, ob du ihn gekündigt hast.

## CSV-Export statt Kontoauszug (Trade Republic)

Manche Banken bieten statt eines Monats-PDFs einen Umsatz-Export als CSV-Datei an, heute Trade Republic. Für so ein Konto lautet die Erinnerung anders:

1. In der App den Transaktions-Export für dieses Jahr erstellen und die CSV-Datei an den Bot schicken.
2. Dazu den Kontostand nennen, den die App **gerade** zeigt, z. B. „laut App 1.234,56 €". Der Export enthält keinen Kontostand. Ohne deine Zahl macht der Bot keine Karte; er rechnet sich nie selbst einen Stand aus.

Die Datei liest ein fester Leser im Bot, kein Sprachmodell. Sie geht also nicht an einen KI-Anbieter. Der Monats-Check umfasst die Tage nach dem zuletzt bestätigten Stand bis gestern. Umsätze von heute zählen erst beim nächsten Mal.

Zusätzlich zum normalen Ablauf:

- **Sparpläne mit echter Stückzahl:** Der Export nennt die genaue Stückzahl jeder Ausführung. Der Bot muss sie nicht aus dem Kurs schätzen.
- **Käufe, Verkäufe und Dividenden,** die noch nicht erfasst sind, bucht er mit den Werten aus dem Export. Was schon erfasst ist, hakt er ab.
- **Einzelkäufe statt einer Übernahme:** Hast du eine Position beim Einrichten als einen Bestand eingetragen, ersetzt der Bot sie auf Wunsch durch die echten Einzelkäufe aus dem Export. Dafür kommt vorher eine eigene Karte. Er ersetzt nur, wenn die Stückzahlen genau übereinstimmen. Käufe nach dem Tag deines bestätigten Kontostands werden dabei echte Käufe und mindern den Kontostand; die Karte zeigt diese Wirkung.
- **Unbekannte Zeilen** (eine neue Umsatzart, eine korrigierte Dividende) bucht er nicht automatisch. Die Karte nennt sie einzeln, ihr Betrag zählt zum Rest.

## Konten ohne Kontoauszug

Bargeld oder ein Konto ohne PDF-Auszug kannst du weiter per Chat abgleichen: „Auf dem Tagesgeld sind heute 5.230 €." Ein Depot gleichst du wie bisher mit dem Depotauszug ab (Foto oder PDF).
