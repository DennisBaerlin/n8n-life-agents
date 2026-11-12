---
title: "Sicherung & neuer Rechner"
---

Dein Assistent sichert deine Daten verschlüsselt. Diese Seite erklärt, was gesichert wird, wozu das **Notfallblatt** dient und wie du alles auf einem neuen Rechner zurückholst.

## Was gesichert wird {#was}

Gesichert werden deine **Nutzerdaten**: Finanzen, Haushalt und Profil, Pläne, Erinnerungen und was die Agenten über dich wissen. Nicht in der Sicherung stehen das Programm selbst und deine Zugangsdaten (Telegram-Bot, Anthropic- und Google-Schlüssel). Beides fragt eine neue Einrichtung wieder ab.

Jede Sicherung ist eine Datei mit einem Namen wie `lifeagents-backup-20261112033000-k1a2b3c4d-v0.44.0.nla.enc`:

- `20261112033000` ist der Zeitpunkt (Jahr, Monat, Tag, Uhrzeit in UTC),
- `k1a2b3c4d` ist die Kennung des Schlüssels, mit dem sie verschlossen ist,
- `v0.44.0` ist die Version, mit der sie geschrieben wurde.

## Das Notfallblatt {#notfallblatt}

Jede Sicherung ist mit einem Schlüssel verschlossen, der nur in deiner Datenbank liegt. Geht der Rechner kaputt, ist auch dieser Schlüssel weg. **Ohne den Schlüssel lässt sich keine Sicherung öffnen, auch nicht von uns.** Darum gibt es das Notfallblatt: Darauf steht der Schlüssel in vier Zeilen. Die zwei Zeichen am Ende jeder Zeile sind Prüfzeichen und zeigen einen Tippfehler sofort an.

- **Ausdrucken oder im Passwort-Manager speichern.** Lege das Blatt nicht in den Sicherungsordner, sonst liegen Schloss und Schlüssel zusammen.
- **Wieder holen:** in der Start-App über das Symbol in der Menüleiste bzw. neben der Uhr, Menüpunkt **Notfallblatt speichern**. Auf einem Server im Terminal: `lifeagents backup key`.
- **Gilt weiter:** Nach einer Wiederherstellung auf einem neuen Rechner gilt der Schlüssel deines Notfallblatts weiter. Druckst du später ein neues Blatt, steht der ältere Schlüssel darauf unter „Für ältere Sicherungen“. Bewahre das alte Blatt trotzdem auf.

## Mit der Start-App (Mac, Windows) {#start-app}

Bei der Einrichtung fragt der Fragebogen, **wohin gesichert werden soll**. Am besten wählst du einen Ordner in deiner Cloud (iCloud Drive, OneDrive, Dropbox): Dann liegt die Sicherung auch dann noch vor, wenn der Rechner kaputtgeht. Darin entsteht der Ordner „Life Agents Sicherungen“. Jede Nacht um halb vier legt dein Assistent dort eine neue Sicherung ab und behält die letzten 14. Klappt das nicht (Platte abgezogen, Ordner verschoben), versucht er es jede Stunde wieder und schreibt dir nach zwei Tagen im Chat.

**Ordner ändern:** Öffne ein Terminal (Mac: Programm „Terminal“, Windows: „PowerShell“) und gib ein, mit deinem Ordner statt des Beispiels:

```bash
docker exec -it lifeagents-master lifeagents backup host-dir "/Users/erika/Library/Mobile Documents/com~apple~CloudDocs" --create
```

Unter Windows sieht der Ordner zum Beispiel so aus: `"D:\Sicherungen"`. Den genauen Pfad bekommst du, wenn du den Ordner im Finder mit gedrückter Wahltaste (⌥) rechts anklickst und „… als Pfadname kopieren“ wählst, unter Windows mit Umschalttaste + Rechtsklick und „Als Pfad kopieren“.

## Auf einem eigenen Server (LXC) {#server}

Auf einem Server sicherst du selbst:

```bash
lifeagents backup export --notify-telegram
```

Das legt die Sicherung in den aktuellen Ordner und schickt eine verschlüsselte Kopie an deinen Telegram-Chat. Kopiere die Datei regelmäßig vom Server weg. Täglich automatisch geht es mit einer Zeile in der root-crontab (`lifeagents backup help` zeigt sie). `lifeagents doctor` warnt, wenn die letzte Sicherung älter als zwei Tage ist.

## Neuer Rechner: Schritt für Schritt {#neuer-rechner}

1. **Die Version aus dem Dateinamen installieren.** Eine Sicherung lässt sich nur in genau die Version zurückspielen, mit der sie geschrieben wurde (sie steht am Ende des Dateinamens, z. B. `v0.44.0`).
   - Start-App: Lade die App dieser Version, `https://github.com/DennisBaerlin/n8n-life-agents/releases/download/v0.44.0/lifeagents.dmg` (Mac) bzw. `…/lifeagents-setup.exe` (Windows), Version im Link anpassen. Richte sie ein wie beim ersten Mal und wähle im Fragebogen bei „Wohin sichern?“ den Ordner mit deinen alten Sicherungen. Das Notfallblatt der Neuinstallation brauchst du danach nicht.
   - Server: `curl -fsSL https://github.com/DennisBaerlin/n8n-life-agents/releases/latest/download/install.sh -o install.sh && bash install.sh --version v0.44.0`, dann die Sicherungsdatei auf den Server kopieren.
2. **Wiederherstellen starten.**
   - Start-App: Terminal bzw. PowerShell öffnen und `docker exec -it lifeagents-master lifeagents backup restore` eingeben. Die Liste zeigt die Sicherungen im Ordner, die deines alten Rechners stehen oben („braucht das Notfallblatt eines anderen Rechners“). Wähle die mit dem Datum deines alten Rechners.
   - Server: `lifeagents backup restore` (Auswahl aus dem aktuellen Ordner) oder `lifeagents backup restore <datei>`.
3. **Schlüssel vom Notfallblatt eintippen.** Die Eingabe bleibt unsichtbar; Leerzeichen und Bindestriche sind egal. Stimmt eine Zeile nicht, sagt der Assistent sofort, welche. Statt zu tippen kannst du die gespeicherte Notfallblatt-Datei mitgeben: `docker exec -i lifeagents-master lifeagents backup restore <datei> --key-stdin < Notfallblatt.txt` (Server: ohne `docker exec -i lifeagents-master`).
4. **Bestätigen.** Vorher zeigt der Assistent, was überschrieben wird, und fragt nach. Danach sind deine Daten zurück, und dein Notfallblatt gilt weiter.

## Wenn es nicht klappt {#hilfe}

| Meldung | Was du tun kannst |
|---|---|
| „Dieser Schlüssel gehört nicht zu dieser Sicherung“ | Das Blatt gehört zu einem anderen Rechner. Die Meldung nennt beide Kennungen; nimm das Blatt mit der Kennung der Sicherung. |
| „Zeile 3 stimmt nicht“ | Diese Zeile noch einmal genau abtippen (0 und o, 1 und l verwechselt?). |
| „Die Datei ist beschädigt“ | Eine ältere Sicherung wählen. |
| „Versions-Konflikt … die Sicherung ist älter“ | Ein Update hilft hier nicht. Installiere die Version aus dem Dateinamen neu (Schritt 1). |
| „Versions-Konflikt … die Sicherung ist neuer“ | Erst `lifeagents update`, dann noch einmal wiederherstellen. |

Es wird bei jedem dieser Fehler nichts geändert: Eine Wiederherstellung gelingt ganz oder gar nicht.
