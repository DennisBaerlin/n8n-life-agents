---
title: "Auf einem Linux-Server"
---

Dieser Weg ist für dich, wenn du **einen eigenen Linux-Server** hast, zum Beispiel einen kleinen Heimserver oder eine virtuelle Maschine (VM), und dich im Terminal ein wenig auskennst. Du startest einen Einrichter, der dir den Rest abnimmt: Er prüft deinen Server, richtet bei Bedarf Docker ein (die Technik, in der der Bot läuft) und startet alles. Die Fragen beantwortest du danach **in einem Fragebogen im Browser** deines Laptops, nicht im Terminal. Der Bot kann danach genau dasselbe wie auf den anderen Wegen (siehe [Welcher Weg passt zu dir?](installation.html#weg)).

## Bevor du startest {#voraussetzungen}

- **Ein Server, der durchlaufen darf:** Debian 12 oder 13 oder Ubuntu 22.04 oder 24.04, 64-Bit (Intel/AMD oder ARM). Du brauchst Zugriff als **root** (oder einen Benutzer, der mit `sudo` arbeiten darf). 4 GB Arbeitsspeicher sind empfohlen, 10 GB freier Platz sind Pflicht.
- **Ein Laptop oder PC** mit Browser und einem SSH-Zugang zum Server. Warum, steht in [Schritt 2](#fragebogen).
- **Docker** musst du nicht vorher einrichten. Läuft es schon, nimmt der Einrichter es mit. Fehlt es, fragt der Einrichter vorher und holt es aus Dockers offizieller Paketquelle. Steht dabei ein Paket aus der Debian- oder Ubuntu-Paketquelle im Weg (zum Beispiel `docker.io`, `containerd` oder `runc`), bricht er ab und nennt dir das Paket, das du vorher entfernen musst. Nicht unterstützt sind Docker aus dem Snap-Paket und Docker ohne root-Rechte: Der FritzBox-Weg braucht die Ports 80 und 443, und die gibt Docker ohne root nicht ohne Weiteres frei.
- **Die Zugänge für den Bot:** ein Telegram-Bot-Token und ein Anthropic-Schlüssel (Pflicht), ein Google-Schlüssel nur für Sprachnachrichten (freiwillig). Was das ist und wo du es bekommst, steht unter [Bevor du startest](installation.html#bevor-du-startest) und [Telegram-Bot anlegen](installation.html#telegram-bot-anlegen).
- **Für den Weg ins Internet** ein kostenloses Tailscale-Konto (der Tunnel, empfohlen) oder Zugang zur FritzBox. Der Fragebogen bietet genau diese zwei Wege an; einen eigenen Reverse Proxy mit eigener Domain bietet er nicht an (siehe [unten](#internet)).

**Läuft auf dem Server schon eine ältere Installation** (n8n als Systemdienst), richtet der Einrichter nichts ein und ändert nichts. Er meldet das und bricht ab.

## Schritt 1: Einrichter laden und starten {#einzeiler}

Auf dem Server, als root, lädt dieser eine Befehl den Einrichter `setup.sh` aus dem neuesten Release und startet ihn. Die zwei Teile sind mit `&&` verkettet, damit bei einem fehlgeschlagenen Download nichts Halbes ausgeführt wird:

```bash
curl -fsSL https://github.com/DennisBaerlin/n8n-life-agents/releases/latest/download/setup.sh -o setup.sh && bash setup.sh
```

Fehlt auf dem Server `curl`, installierst du es vorher mit `apt-get install -y curl`. Arbeitest du nicht als root, setz bei `bash` ein `sudo` davor: `... && sudo bash setup.sh`. Den Einrichter lädst du bewusst **erst in eine Datei**, statt ihn direkt in `bash` zu leiten: Bricht der Download ab, läuft nichts Halbes.

**Die Prüfsumme von Hand prüfen (freiwillig):** Zu jedem Release gehört eine Liste mit den Prüfsummen der Dateien (SHA256, ein digitaler Fingerabdruck). Willst du vor dem Start wissen, ob die Datei vollständig und unverändert angekommen ist, lade die Liste und vergleiche:

```bash
curl -fsSL https://github.com/DennisBaerlin/n8n-life-agents/releases/latest/download/SHA256SUMS -o SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

*Erwartet:* Eine Zeile `setup.sh: OK`. Steht dort `FAILED`, starte die Datei nicht, sondern lade sie neu. Die Prüfsumme erkennt einen beschädigten Download. Dass ein Release echt vom Projekt kommt, prüft dein Assistent später bei jedem Update selbst über die digitale Unterschrift (siehe [Installation](installation.html#funktionen-hinzufügen)).

Danach passiert Folgendes:

1. Der Einrichter **prüft deinen Server**, bevor er etwas ändert: Betriebssystem, Rechte, Docker.
2. Fehlt Docker, **fragt er vorher** („Jetzt aus Dockers offizieller Paketquelle einrichten?“). Ohne dein Ja geht es nicht weiter. Mit `bash setup.sh --yes` beantwortest du solche Fragen gleich mit Ja, etwa auf einem Server ohne Tastatur.
3. Er **startet den Bot-Verbund** und lädt dabei die Bausteine herunter. Das dauert beim ersten Mal ein paar Minuten.
4. Er legt auf dem Server zwei Dinge an: den Befehl `lifeagents` (für alles, was du danach brauchst, siehe [unten](#befehle)) und eine Systemdienst-Einheit, die den Bot nach einem Neustart wieder hochholt (siehe [Start beim Hochfahren](#autostart)).
5. Er zeigt dir, wie du den Fragebogen öffnest.

Du kannst `setup.sh` jederzeit noch einmal starten. Läuft alles schon, meldet er „Nichts zu tun“ und ändert nichts.

## Schritt 2: Den Fragebogen am Laptop öffnen {#fragebogen}

Der Fragebogen läuft auf dem Server und ist **von außen nicht erreichbar**: Er lauscht nur auf dem Server selbst. Damit du ihn trotzdem an deinem Laptop sehen kannst, baust du eine verschlüsselte SSH-Verbindung auf, die den Fragebogen zu deinem Laptop „weiterleitet“ (Fachwort: Port-Weiterleitung). Der Einrichter druckt dir beides fertig aus, ungefähr so (Adresse, Name und Port sind hier erfunden, bei dir stehen deine):

```
So öffnest du den Fragebogen (am eigenen Laptop):
  1. Verbindung aufbauen und das Terminal offen lassen:
       ssh -L 5881:127.0.0.1:5881 erika@192.168.178.20
  2. Im Browser am Laptop öffnen:
       http://127.0.0.1:5881/start?t=…
Der Link gilt 10 Minuten. Einen neuen Link gibt es mit: lifeagents wizard-url
```

1. **Terminal am Laptop öffnen** (Mac: Programm „Terminal“, Windows: „PowerShell“) und den `ssh`-Befehl **genau so einfügen**, mit demselben Port. Der Fragebogen prüft die Adresse, über die du ihn aufrufst; mit einem anderen Port am Laptop lehnt er dich ab. Melde dich mit deinem Server-Passwort bzw. Schlüssel an. **Lass dieses Fenster offen**, solange du den Fragebogen benutzt. Als Benutzername druckt der Einrichter den Benutzer, der ihn mit `sudo` gestartet hat (sonst `root`). Ist die SSH-Anmeldung als root bei dir gesperrt, was oft so ist, nimm deinen eigenen Benutzernamen.
2. **Den Link im Browser öffnen.** Der Link steht in der Ausgabe. Er gilt **10 Minuten**. Ist er abgelaufen oder verloren, gibt dir `lifeagents wizard-url` auf dem Server einen neuen.
3. **Die Fragen beantworten**, eine je Seite. Es sind dieselben wie bei der [Start-App](start-app.html#schritt-4-die-app-führt-dich-durch-den-rest): Name, Geburtsdatum, Telegram-Bot, Anthropic-Schlüssel, welche Funktionen du willst, der Weg ins Internet und wohin gesichert wird. Jede Antwort wird sofort gespeichert, brichst du ab, geht nichts verloren. Am Ende zeigt eine Übersicht alle Antworten; erst mit dem Ja darauf geht die Installation los. Zum Schluss verbindest du Telegram mit deinem Bot.

Ist die Einrichtung abgeschlossen, endet der Fragebogen von selbst. Einen Link gibt es dann nicht mehr, und das ist normal.

### Der Weg ins Internet {#internet}

Damit Telegram deinem Bot Nachrichten zustellen kann, muss dein Server aus dem Internet erreichbar sein. Der Fragebogen bietet zwei Wege an:

- **Über einen sicheren Tunnel (empfohlen, vorausgewählt):** ein kostenloses Tailscale-Konto, am Router änderst du nichts. Anleitung: [Tunnel einrichten](tunnel.html).
- **Über meine FritzBox:** Du richtest zwei Freigaben in der FritzBox ein, dafür brauchst du kein fremdes Konto. Anleitung: [FritzBox einrichten](fritzbox.html).

Hast du bisher einen eigenen Reverse Proxy mit eigener Domain benutzt: Diesen Weg bietet der neue Fragebogen nicht an.

## Wenn der Einrichter abbricht {#abbruch}

Der Einrichter sagt in einfachen Worten, woran es liegt, und hat bis dahin nichts Halbes hinterlassen. Die häufigsten Gründe:

- **Docker aus dem Snap-Paket:** Entferne das Snap, dann nimmt der Einrichter Docker aus der Paketquelle.
- **Ein Paket steht im Weg** (zum Beispiel `docker.io`): Entferne es mit dem Befehl, den der Einrichter nennt.
- **Zu wenig Platz oder Docker zu alt:** Platz schaffen bzw. Docker aus der offiziellen Paketquelle aktualisieren.
- **Von den Ports 5880 bis 5899 sind nicht zwei frei:** Beende, was dort lauscht, und starte noch einmal.

Dann `bash setup.sh` einfach noch einmal ausführen.

## Der Sicherungs-Ordner auf einer anderen Platte {#sicherung}

Jede Nacht legt dein Assistent eine verschlüsselte Sicherung deiner Daten ab. Der Fragebogen fragt darum: „Wohin sollen deine Daten jeden Tag gesichert werden?“ Auf einem Server gibt es dafür nur die Antwort **Anderer Ordner**; danach tippst du den **vollen Pfad** auf dem Server ein.

**Wähle einen Ordner auf einer anderen Platte als der des Servers**, zum Beispiel auf einer zweiten Festplatte, einer USB-Platte oder einer eingebundenen Netzwerk-Freigabe (NAS). Dann ist die Sicherung auch dann noch da, wenn die Platte des Servers kaputtgeht. Zwei Dinge sind wichtig:

- Die Platte muss **auf dem Server eingebunden** sein, und der Ordner muss **schon existieren**, zum Beispiel `/mnt/sicherung`. Sonst meldet der Fragebogen: „Diesen Ordner gibt es auf dem Rechner nicht.“
- In diesem Ordner legt der Assistent selbst einen Unterordner „Life Agents Sicherungen“ an und sichert dorthin.

Ist die Platte einmal nicht eingebunden oder voll, versucht der Assistent es jede Stunde wieder und schreibt dir nach zwei Tagen im Chat. Den **Schlüssel** zum Öffnen der Sicherung bekommst du am Ende auf einem Notfallblatt. Heb ihn getrennt von der Sicherung auf. Wie du auf einem neuen Rechner zurückholst, steht unter [Sicherung & neuer Rechner](sicherung.html).

**Ordner später ändern:** Auf dem Server, mit deinem Ordner statt des Beispiels:

```bash
lifeagents backup host-dir /mnt/sicherung --create
```

Neue Sicherungen gehen danach in den neuen Ordner, die bisherigen bleiben im alten liegen.

## Das Steuer-Programm hat volle Rechte über Docker {#rechte}

Der Bot besteht aus mehreren Teilen, die in Docker laufen. Ein **Steuer-Programm** (der Container `lifeagents-master`) hält sie zusammen: Es startet und stoppt sie und spielt Updates ein. Dafür bekommt es den **Docker-Anschluss des Servers** (den „Socket“), und **wer Docker steuern darf, hat auf dem Server praktisch Administrator-Rechte (root)**. Das ist bei jedem Programm so, das Docker verwaltet.

Für dich heißt das:

- Du vertraust dem Steuer-Programm wie einem Administrator deines Servers. Updates spielt es nur ein, wenn sie digital vom Projekt unterschrieben sind (siehe [Installation](installation.html#funktionen-hinzufügen)).
- Beim Abbau entfernt der Einrichter nur, was er selbst angelegt hat. Andere Docker-Programme auf demselben Server, zum Beispiel Paperless, bleiben unberührt.
- Wie das Steuer-Programm zusammenspielt, steht unter [So funktioniert’s](so-funktionierts.html).

## Proxmox: besser eine VM {#proxmox}

Läuft dein Server unter Proxmox: **Proxmox empfiehlt für Docker eine virtuelle Maschine (VM).** Ein Debian-LXC-Container geht, aber **auf eigene Verantwortung**, und nur mit den Container-Eigenschaften `nesting=1,keyctl=1` (in Proxmox: Container → Optionen → Features). Erkennt der Einrichter einen LXC und Docker kommt dort nicht zurecht, nennt er dir dieselben Zeilen. Einen eigenen Proxmox-Weg gibt es nicht.

## Die Befehle danach {#befehle}

Nach der Einrichtung steht auf dem Server der Befehl `lifeagents`. Er reicht deine Eingaben an das Steuer-Programm weiter, du tippst sie wie gewohnt:

| Befehl | Wofür |
|---|---|
| `lifeagents wizard-url` | Einen neuen Link zum Fragebogen, wenn der alte abgelaufen ist (nur solange die Einrichtung noch nicht abgeschlossen ist). |
| `lifeagents update` | Holt die neueste Version und spielt sie ein, mit Sicherung vorher. Dasselbe passiert, wenn du im Chat auf **Jetzt aktualisieren** tippst. |
| `lifeagents doctor` | Prüft den Zustand der Installation, ohne etwas zu verändern. Der erste Schritt bei jedem Problem. |
| `lifeagents backup …` | Sicherung ansehen, anlegen oder zurückspielen, auch das Notfallblatt (`lifeagents backup key`). |

Tippst du nur `lifeagents`, öffnet sich ein Menü. Die vollständige Liste zeigt `lifeagents help`; was die Befehle genau tun, steht unter [Installation → Betrieb danach](installation.html#betrieb-danach-die-lifeagents-befehlszeile).

## Start beim Hochfahren {#autostart}

Der Einrichter legt die Systemdienst-Einheit **`lifeagents-stack.service`** an. Sie startet nach jedem Hochfahren des Servers und nach jedem Neustart von Docker einmal alle Teile des Bots. Das ist nötig, weil Docker die Teile nach einem Neustart manchmal in der falschen Reihenfolge hochholt und einzelne dann stehen bleiben.

Ob die Einheit da ist, zeigt:

```bash
systemctl status lifeagents-stack.service
```

*Erwartet:* `active (exited)`. Das ist richtig, die Einheit startet den Verbund einmal und beendet sich dann. Wenn etwas hakt, zeigt `journalctl -u lifeagents-stack.service` das Protokoll. Läuft auf dem Server kein systemd, weist der Einrichter darauf hin; dann holst du den Bot nach einem Neustart von Hand mit `lifeagents boot-start` hoch.

## Entfernen {#entfernen}

Den Bot entfernst du mit demselben Einrichter. Lade ihn wie in [Schritt 1](#einzeiler), starte ihn aber so:

```bash
bash setup.sh --uninstall
```

Das entfernt den Bot-Verbund, den Befehl `lifeagents` und die Einheit. **Deine Daten bleiben erhalten**, und Docker bleibt installiert. Startest du `setup.sh` später wieder, findet der Bot seine Daten wieder.

```bash
bash setup.sh --uninstall --delete-data
```

Das löscht **zusätzlich alle Daten** (Datenbank, Dokumente, Schlüssel) und die Docker-Abbilder, die der Einrichter selbst geladen hat. Es lässt sich nicht rückgängig machen, darum fragt der Einrichter vorher („Wirklich löschen?“). Dein Sicherungs-Ordner liegt außerhalb von Docker und bleibt unberührt. Vorher löst der Einrichter noch die Verbindung deines Bots zu Telegram. Mit `--yes` entfällt die Rückfrage.

## Für Fortgeschrittene: ohne Fragebogen {#answers}

Wer den Fragebogen nicht nutzen will, etwa zum Automatisieren, übergibt eine fertige Antwort-Datei: `bash setup.sh --answers antworten.env`. Sie hat dieselbe Form wie die Datei für `--unattended`. Dieser Weg ist noch wenig erprobt, im Zweifel nimm den Fragebogen.
