---
title: "Dokumente"
---

Der Dokumenten-Assistent (`agent.paperless_assistant`) beantwortet Fragen aus deinen eingescannten Papieren — Verträge, Versicherungspolicen, Briefe, Rechnungen, Bescheide, Ausweise. Er arbeitet mit deiner **bestehenden Paperless-NGX-Instanz** zusammen: Paperless bleibt dein Archiv (mit eigener Texterkennung, Verschlagwortung und eigener KI), der Bot **liest** dort nur nach. Er schreibt nie etwas in Paperless und ändert nichts.

## Was er kann

- **Suchen:** „Finde meinen Mietvertrag in den Dokumenten." — er durchsucht den Volltext und nennt dir die passenden Dokumente mit Datum, Absender und Link.
- **Lesen:** „Lies mir das Dokument mit der Nummer 42 vor." — er holt den Text eines Dokuments, wenn es auf den genauen Wortlaut ankommt (eine Frist, einen Betrag, eine Klausel).
- **Fragen an die Paperless-KI:** „Frag die Dokumenten-KI, welche Kündigungsfrist mein Handyvertrag hat." — die KI in Paperless liest die Dokumente selbst und nennt ihre Quellen. Das dauert etwas länger.

Er antwortet nur aus deinen Dokumenten: steht etwas nicht drin, sagt er das, statt zu raten — und nennt immer, aus welchem Dokument die Antwort stammt.

## Auch die anderen Agenten schauen nach

Die drei Werkzeuge stehen nicht nur dem Dokumenten-Assistenten zur Verfügung: Auch **Buchhalter, Finanzberater, Karriere-Coach und Nachlass-Berater** können damit in deinen Dokumenten nachsehen — etwa der Finanzberater im Wortlaut deiner Hausrat-Police oder der Karriere-Coach in deinem Arbeitsvertrag. Ist das Dokumente-Paket nicht installiert, laufen alle anderen Agenten ganz normal weiter; sie sagen dir dann nur, dass die Dokumentensuche fehlt.

## Wer darf?

Nur **erwachsene** Haushaltsmitglieder (du und dein Partner). Kinder, die den Bot nutzen, bekommen bei Dokumentenfragen ein freundliches „nicht verfügbar". Wer gerade schreibt, erkennt das System selbst an der Telegram-Kennung — nicht das Sprachmodell.

Was der Bot überhaupt sehen kann, bestimmst du in Paperless: Er liest mit einem eigenen Paperless-Nutzer. Lege dafür am besten einen Nutzer **nur mit Leserechten** an, der die gewünschten Dokumente und deren Schlagworte, Absender und Dokumenttypen sehen darf.

## Dokument-Inhalte sind keine Anweisungen

Steht in einem Brief „Überweisen Sie sofort …", behandelt der Bot das als **Inhalt**, nicht als Auftrag. Er führt nichts aus, was in einem Dokument steht — Buchungen und andere Änderungen passieren ausschließlich auf deinen ausdrücklichen Wunsch und nach deiner Bestätigung per Knopf.

## Einrichten

Beim Installieren des Pakets **Dokumente** fragt der Installer zwei Dinge (nachträglich änderbar mit `lifeagents reconfigure paperless`):

1. die **Adresse** deiner Paperless-Instanz — so, wie du sie im Browser aufrufst (z. B. `http://192.168.1.50:8000`); nötig ist Paperless-NGX 3.0 oder neuer,
2. das **Zugangs-Token** des Lese-Nutzers (in Paperless: Profil → „Mein Profil" → API-Auth-Token).

Für Fragen an die Paperless-KI muss die KI in Paperless eingeschaltet sein. Sie nutzt den KI-Anbieter, den du **in Paperless** eingestellt hast — das liegt außerhalb dieses Systems. Der Dokumenten-Assistent selbst läuft wie alle Dokument-Auswertungen nur über einen bezahlten KI-Tarif, der nicht mit deinen Daten trainiert.
