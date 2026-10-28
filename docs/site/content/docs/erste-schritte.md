---
title: "Erste Schritte"
---

Du wurdest von der Person eingeladen, die den Assistenten für euren Haushalt betreibt (der "Owner" — der Verantwortliche mit vollem Zugriff). Hier erfährst du, wie du reinkommst und was direkt danach zu tun ist.

> **Du hast den Assistenten selbst installiert?** Dann begrüßt dich der Bot direkt nach der Installation mit dem Knopf „Haushalt einrichten" — dich kennt er da schon (Name, Geburtsdatum aus der Installation), er fragt nur noch nach den übrigen Personen. Der ganze Fahrplan steht unter [Installation → So geht's weiter](installation.html#so-gehts-weiter).

## Wie die Einladung entsteht

Bevor du irgendetwas tust, passiert etwas beim Owner: Er trägt dich zunächst als Person im Haushalt ein — Vorname, Nachname, Geburtsdatum und deine Rolle (Partner oder Kind; er selbst ist "Owner"). Das geht entweder direkt am Server über die Kommandozeile (`lifeagents household add`) oder während der Owner sein eigenes Setup durchläuft.

Danach bittet der Owner den Bot im Chat, dich einzuladen (z. B. "lade meine Partnerin ein"). Der Bot erzeugt daraufhin einen einmaligen Einladungslink der Form `https://t.me/<botname>?start=<code>` und schickt ihn dem Owner zurück — der Owner leitet ihn dir dann privat weiter (WhatsApp, SMS, persönlich).

```
Owner:  lade meinen Partner Max ein
Bot:    Einladungslink erstellt: https://t.me/unser_familienbot?start=k7x2p9qz
        Bitte teile ihn mit Max — gültig für begrenzte Zeit.
```

## Schritt 1: Link öffnen

Tippst du den Link an, sendet Telegram automatisch `/start k7x2p9qz` an den Bot — du kannst den Befehl auch von Hand tippen. Das bindet dich noch **nicht sofort**: Der Owner bekommt zuerst eine Nachricht mit zwei Knöpfen ("Bestätigen" / "Ablehnen") und muss deine Anfrage aktiv freigeben. Erst danach bist du mit deiner Rolle verknüpft und bekommst eine Willkommensnachricht — ab jetzt kannst du einfach drauflos schreiben.

## Schritt 2: `/onboarding`

Schick dem Bot `/onboarding` — er zeigt dir eine Übersicht: den Haushalt und je installiertem Modul (Paket) einen Bereich mit Fortschritt (z. B. „Finanzen (2/5)"; nicht installierte sind als „nicht installiert" markiert). Die Bereiche stehen in einer sinnvollen Reihenfolge — was auf anderen Angaben aufbaut, kommt später. Der Knopf **„👉 Weiter"** startet direkt den nächsten offenen Schritt; ein Tipp auf einen Bereich zeigt dessen einzelne Abschnitte. Nach jedem erledigten Abschnitt bietet dir der Bot den nächsten an. Ist ein ganzer Bereich fertig, schickt er dir von selbst eine Karte mit dem nächsten Schritt. Gehört zu einem Bereich ein Berater mit Plan (Finanzen: [Finanzplan](finanzberater.html), Karriere: Karriereplan), schlägt die Karte danach den Plan vor. Er ist freiwillig und blockiert keinen anderen Bereich. Bleibt etwas liegen, erinnert er dich nach 3 und nach 10 Tagen (abschaltbar mit „Nicht mehr erinnern"). Wann sich der Bot sonst noch meldet, steht unter [So funktioniert's](so-funktionierts.html#wann-sich-der-bot-von-selbst-meldet).

- Den **Haushalts-Teil** (wer gehört dazu) hat der Owner meist schon erledigt — für dich ist da nichts mehr zu tun. Ist er noch nicht fertig, sagt dir der Bot das ehrlich und meldet sich mit „Es kann losgehen", sobald der Owner so weit ist.
- **Eigene, persönliche Bereiche** — zum Beispiel dein Profil beim [Karriere-Coach](karriere-coach.html) — richtest du über die Buttons im Menü selbst ein; der zuständige Fachagent führt dich mit Fragen geführt hindurch. Gibt es solche Bereiche schon, wenn der Owner dich bestätigt, trägt die Bestätigung gleich den Knopf „Meine Bereiche“.
- Für **Finanzielles** (Konten, Ausgaben — sofern das Finanzen-Paket installiert ist) reicht es meist, dem Buchhalter einfach zu erzählen, was du hast, oder ein Foto von einem Kontoauszug zu schicken — er fragt bei Bedarf nach.

Mehr zu den einzelnen Fachagenten und was sie können, steht unter [Befehle](befehle.html) und [So funktioniert's](so-funktionierts.html).

## Mini-FAQ: "Es antwortet nicht?"

1. **Noch nicht verbunden:** Falscher oder abgelaufener Code — frag den Owner nach einem neuen Link.
2. **Bestätigung steht noch aus:** Der Owner muss deine Anfrage erst per Knopf bestätigen, bevor du loslegen kannst — kurz nachfragen hilft.
3. **Ein Vorgang wartet auf einen Knopfdruck:** Jede Buchung oder Änderung zeigt dir der Bot vor dem Speichern zur Bestätigung an (das "Gate") — solange dieser Knopf offen ist, reagiert er auf normalen Text **nicht**. Details dazu: [Chatten & Bestätigen](chatten-bestaetigen.html).
4. **Text löst kein wartendes Gate aus:** Willst du etwas an einer offenen Bestätigung ändern, musst du erst "Abbrechen" tippen — eine einfache Textnachricht startet stattdessen ein neues, unabhängiges Gespräch und erreicht die Bestätigung nicht.
5. **Unsicher, was der Bot überhaupt kann?** `/help` (oder `/hilfe`) zeigt jederzeit eine Übersicht aller Fähigkeiten.

Je nach Rolle kann es sein, dass manche Aktionen zusätzlich vom Owner gegengezeichnet werden müssen (Vier-Augen-Prinzip) — das ist normal und dient eurer gemeinsamen Kontrolle über die Daten.
