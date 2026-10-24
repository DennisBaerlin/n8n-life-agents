---
title: "Wenn ein Update fehlschlägt"
---

Tippst du in der Update-Karte im Chat auf **Jetzt aktualisieren**, meldet sich der Bot danach immer mit dem Ergebnis. Geht etwas schief, beantwortet seine Nachricht drei Fragen: Was ist passiert? Läuft mein System noch? Was kann ich tun? Diese Seite erklärt jeden Fall etwas ausführlicher. Die Nachricht verlinkt direkt auf den passenden Abschnitt.

Zwei Dinge gelten immer:

- **Vor jedem Update wird gesichert.** Die ganze Datenbank liegt verschlüsselt unter `/var/backups/lifeagents/`, die letzten zwei Sicherungen bleiben liegen.
- **Das vollständige Protokoll** eines Updates aus dem Chat steht unter `/var/log/lifeagents/update-<zeit>.log`. Den genauen Pfad nennt die Nachricht.

Alle Befehle auf dieser Seite führst du auf dem Server als root aus (meist mit `sudo` davor).

## Nichts wurde geändert {#unchanged}

Das Update ist abgebrochen, **bevor** es etwas am System geändert hat. Dein System läuft unverändert auf der bisherigen Version. Die Nachricht nennt den Grund:

| Grund | Was du tun kannst |
|---|---|
| GitHub war nicht erreichbar | Internet-Verbindung des Servers prüfen, dann **Erneut versuchen** tippen. |
| GitHub hat zu viele Anfragen gemeldet | Etwa eine Stunde warten, dann **Erneut versuchen**. |
| Nicht genug Speicherplatz | Platz schaffen (`df -h` zeigt, wie voll der Server ist; alte Dateien in `/tmp` oder Container-Abbilder sind typische Platzfresser), dann **Erneut versuchen**. Das Update braucht etwa 2 GB frei. |
| Ein anderes Update läuft schon | Warten, bis es fertig ist, dann **Erneut versuchen**. |
| Die Datenbank war nicht erreichbar | `lifeagents doctor` zeigt, was mit der Datenbank los ist. |
| Die Sicherung ist fehlgeschlagen | Meist fehlt Speicherplatz unter `/var/backups/lifeagents/`. Ohne Sicherung wird bewusst nicht aktualisiert. |

Nach zwei vergeblichen Wiederholungen bietet der Bot keinen Knopf mehr an. Dann hilft [Problem melden](#melden).

## Sicherheitswarnung: nicht installiert {#security}

Das Update wurde **nicht** installiert, weil die heruntergeladene Datei keine gültige Unterschrift des Projekts trägt oder nicht zu ihrer Prüfsumme passt. Dein System läuft unverändert weiter.

**Bitte nichts weiter tun** und das Update auch nicht von Hand einspielen. Ein solcher Fall kann heißen, dass jemand eine veränderte Version untergeschoben hat. Melde es über den Knopf **Problem melden** (siehe [unten](#melden)). Der Bot bietet hier absichtlich keinen Wiederholen-Knopf an.

## Wartet auf eine Angabe {#held}

Die neue Version braucht eine Angabe, die noch fehlt, zum Beispiel einen neuen Pflicht-Schlüssel. Nichts wurde geändert, dein System läuft weiter. So geht es weiter:

1. Auf dem Server `lifeagents reconfigure` ausführen und die fehlende Angabe eintragen. Die Nachricht sagt, welche es ist.
2. Danach auf der Update-Karte im Chat noch einmal **Jetzt aktualisieren** tippen.

## Teilweise eingespielt {#partial}

Die neue Version läuft, aber ein Teil davon (zum Beispiel ein Paket wie Finanzen) ließ sich nicht einrichten. Dieser Teil funktioniert eventuell nicht.

1. **Erneut versuchen** tippen. Ein zweiter Lauf setzt dort an, wo es gehakt hat, und behebt kurze Netz- oder Zeitprobleme meistens.
2. Hilft das nicht: `lifeagents doctor` zeigt, was noch nicht stimmt.

## Mittendrin abgebrochen {#midway}

Das Update hat schon angefangen, das System umzubauen, und ist dann in einem Schritt abgebrochen. Die Nachricht nennt den Schritt. Dein System läuft, aber vielleicht nicht vollständig.

1. **Erneut versuchen** tippen. Das Update setzt an der Abbruchstelle fort und nutzt dieselbe Sicherung.
2. Klappt das nicht, kannst du zur vorherigen Version zurück, siehe [Zurück zur vorherigen Version](#rollback).

## Unterbrochen {#interrupted}

Das Update wurde mittendrin unterbrochen, zum Beispiel weil der Server neu gestartet ist. Der Bot merkt das beim nächsten Start und meldet sich. Weiter geht es wie bei [Mittendrin abgebrochen](#midway).

## Der Bot läuft nicht mehr {#bot-down}

Das Update ist abgebrochen, und der Bot selbst läuft gerade nicht richtig. Die Nachricht kommt trotzdem an, weil der Server sie direkt an Telegram schickt. Knöpfe im Chat würden aber niemanden erreichen. Deshalb nur im Terminal:

1. `lifeagents update` ausführen. Das setzt das Update an der Abbruchstelle fort.
2. Klappt das nicht: [Zurück zur vorherigen Version](#rollback).

## Zurück zur vorherigen Version {#rollback}

```bash
lifeagents rollback
```

Der Befehl zeigt dir zuerst, auf welche Version er zurückgeht und von wann die Sicherung ist, und fragt dann nach. **Alles, was seit dieser Sicherung gespeichert wurde, geht verloren** (meist sind das nur die wenigen Minuten des Updates). Danach stellt er die Datenbank aus der Sicherung her und spielt den vorherigen Stand ein. Am Ende meldet sich der Bot im Chat.

Zur Sicherheit wird die aktuelle Datenbank dabei nicht gelöscht, sondern erst beiseitegelegt. Scheitert das Herstellen, kommt sie unverändert zurück.

## Problem melden {#melden}

Der Knopf **Problem melden** öffnet auf GitHub eine vorausgefüllte Fehlermeldung an das Projekt. Sie enthält nur feste Angaben: von welcher auf welche Version, welcher Fall, welcher Schritt, welcher Grund. Persönliche Daten stehen nicht darin. Willst du das Protokoll anhängen, lies es vorher selbst durch: Es kann deine Internet-Adresse, Namen oder IP-Adressen enthalten.
