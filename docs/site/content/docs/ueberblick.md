---
title: "Überblick"
---

## Was ist das?

Ein persönlicher Assistent, mit dem du ganz normal auf Telegram schreibst — und der im Hintergrund auf eigener Infrastruktur läuft, nicht bei einem fremden Cloud-Anbieter. Alles läuft über **einen** Telegram-Bot. Ein Orchestrator (ein steuernder Software-Baustein, der jede Nachricht zuerst liest) entscheidet, welcher Spezialist zuständig ist, und reicht die Nachricht weiter. Egal ob du eine Ausgabe erwähnst, nach deiner Ziel-Allokation fragst oder ein Foto deines Lebenslaufs schickst — du musst nicht wissen, „mit wem" du gerade sprichst.

Das Wichtigste zuerst: **nichts wird einfach so gespeichert.** Bevor irgendetwas in deine Daten geschrieben wird (eine Buchung, eine Plan-Änderung, ein gemerkter Fakt), zeigt dir der Bot erst genau, was er vorhat, und du bestätigst per Knopfdruck (Inline-Button) — oder lehnst ab. Mehr dazu auf der Seite [Chatten & Bestätigen](chatten-bestaetigen.html).

## Wo willst du hin?

- 🙋 **Ich will es nutzen** → [Erste Schritte](erste-schritte.html) · [Chatten & Bestätigen](chatten-bestaetigen.html) · [Datenschutz & Sicherheit](datenschutz.html)
- 🔧 **Ich will verstehen, wie es gebaut ist** → [So funktioniert's](so-funktionierts.html) · [Pakete & Erweiterbarkeit](pakete.html) · [Mitwirken](mitwirken.html)

Betreiben statt nutzen? → [Installation & Betrieb](installation.html).

## Die Agenten auf einen Blick

- 📒 [**Buchhalter**](buchhalter.html) (`agent.finance`) — bucht Konten, Ausgaben, Überweisungen, Wertpapiere, Zinsen, Kredite und mehr; pflegt Salden automatisch.
- 🧭 [**Finanzberater**](finanzberater.html) (`agent.finance_advisor`) — interviewt dich, pflegt deinen Finanzplan, recherchiert und meldet Abweichungen. Bucht selbst nie etwas — er hat dafür gar keine Werkzeuge. Einzige Ausnahme: In der Finanzplanung ordnet er deine Depot-Positionen den Bausteinen deines Plans zu (eine Karte zum Bestätigen).
- 🔭 [**Monitor**](monitor-guide.html) (`agent.monitor`) — überwacht von dir angelegte Schwellwerte (z. B. einen Kurs oder eine Fälligkeit) und meldet sich, wenn einer auslöst. Gibt selbst keine Ratschläge.
- 🚪 [**Guide**](monitor-guide.html) (`agent.guide`) — begleitet dich durch die Ersteinrichtung, beantwortet `/help` und schlägt (nur wenn du es einschaltest) täglich merkenswerte Fakten vor.
- 💼 [**Karriere-Coach**](karriere-coach.html) (`agent.career_advisor`) — liest deinen Lebenslauf, pflegt Profil und Karriereplan, scannt regelmäßig Stellenangebote und lernt aus deinem Feedback.
- 🗂️ [**Nachlass-Berater**](nachlass-berater.html) (`agent.estate_advisor`) — pflegt dein Vorsorge-Register (nur Fundorte, nie Passwörter), erstellt die Notfallmappe als weiterreichbares Dokument und begleitet einfühlsam durch den Todes- oder Vorsorgefall.
- 📄 [**Dokumenten-Assistent**](dokumente.html) (`agent.paperless_assistant`) — findet, liest und befragt deine eingescannten Papiere in deiner Paperless-Instanz (nur lesend, nur für Erwachsene); dieselben Werkzeuge nutzen auch Buchhalter, Finanzberater, Karriere-Coach und Nachlass-Berater.

## Ein Kern, mehrere Pakete

Unter der Haube ist das System als **Paket-Plattform** gebaut: ein gemeinsamer Kern (Core) kümmert sich um Orchestrator, Bestätigungs-Gates, Gedächtnis und Ersteinrichtung — unabhängig davon, worüber du gerade sprichst. Darauf setzen installierbare **Domänen-Pakete** auf, heute Finanzen, Karriere und Vorsorge/Nachlass; ein neues Lebensthema kann als eigenes Paket mit eigenem Datenbereich andocken, ohne den Kern anzufassen. Mehr dazu auf der Seite [Pakete](pakete.html).

## Ein Beispiel

```
Du:  Ich habe heute 45,90 € bei Rewe für Lebensmittel bezahlt, vom Girokonto.
Bot: Ausgabe buchen – bitte prüfen:
     • Konto: Girokonto · Betrag: 45,90 € · Kategorie: Lebensmittel · Datum: 02.07.2026
     [✅ Bestätigen] [❌ Abbrechen]
Du:  (tippst ✅)
Bot: Gebucht. Neuer Saldo Girokonto: 1.234,56 €
```

Weitere Beispiel-Dialoge für alle Agenten findest du auf der Seite [Beispiele](beispiele.html).

## Weiterlesen

Wenn du direkt loslegen willst: [Erste Schritte](erste-schritte.html). Wie die Installation auf einer eigenen Maschine abläuft, steht auf der Seite [Installation](installation.html). Wie Bestätigungen, Datenschutz und die Technik im Detail funktionieren, erklären [Chatten & Bestätigen](chatten-bestaetigen.html), [Datenschutz](datenschutz.html) und [So funktioniert's](so-funktionierts.html).
