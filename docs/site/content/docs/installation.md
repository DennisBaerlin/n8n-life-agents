---
title: "Installation, Update & Betrieb"
---

Der Bot läuft auf einer eigenen Debian-12-Maschine (als Container/LXC oder als virtuelle Maschine, VM) — es gibt genau **einen** Installationsweg, keine Variantenauswahl. Ein einziger Befehl richtet PostgreSQL, n8n und das **Grundsystem** ein (Telegram-Bot, Hilfe, Einrichtungs-Assistent, Erinnerungen). Die Fach-Funktionen — Finanzen, Karriere, Nachlass, Dokumente — wählst du danach **einzeln** dazu (siehe [„Funktionen hinzufügen"](#funktionen-hinzufügen)). Den verschlüsselten Zugang von außen (HTTPS) stellst du über einen **Reverse Proxy** bereit — den bringst du selbst mit (die meisten Heim-Server haben ohnehin schon einen); der Installer gibt dir am Ende eine **fertige, direkt eintragbare Konfiguration** dafür aus.

## Bevor du startest

Diese Dinge brauchst du vorher:

- Einen **Telegram-Bot-Token** von @BotFather (dem offiziellen Telegram-Werkzeug zum Anlegen eines Bots — Schritt-für-Schritt weiter unten unter [„Telegram-Bot anlegen"](#telegram-bot-anlegen)).
- Eine **Domain, die auf den Server zeigt** (öffentlich erreichbar, z. B. über DynDNS/MyFRITZ!).
- **Öffentliche Erreichbarkeit:** eine Port-Weiterleitung (443) von deinem Router **und** einen HTTPS-Reverse-Proxy — auf dem Server selbst oder auf einem anderen Rechner im Heimnetz (z. B. ein zentraler Proxy-Container). Wie das zusammenspielt und wie du es einrichtest, steht unten unter [„Erreichbarkeit"](#erreichbarkeit) und [„Reverse Proxy"](#reverse-proxy).
- Einen **Anthropic-API-Key** (Pflicht) — alle Agenten denken mit Claude: Weiterleiten, Buchen, Hilfe, Belege lesen, Websuche und Beratung. Anthropic nutzt Daten aus der API nicht zum Training (mehr auf der Seite [Datenschutz](datenschutz.html)).
- Optional einen **Google-Gemini-API-Key im bezahlten Tarif** (nicht die kostenlose Stufe) — nur für Sprachnachrichten, weil Claude kein Audio versteht. Ohne ihn bittet der Bot bei einer Sprachnachricht, als Text zu schreiben; nachtragen geht später jederzeit.

Das Projekt selbst ist kostenlos (MIT-Lizenz) und braucht kein GitHub-Konto. Laufende Kosten entstehen nur für deinen Rechner und die KI-Nutzung nach Verbrauch, die Anthropic (und für Sprachnachrichten Google) direkt mit dir abrechnet.

## Der eine Installations-Befehl

Auf der frischen Debian-Maschine lädt dieser eine Befehl (als root, wie im frischen Container üblich) den Installer `install.sh` aus dem neuesten Release und startet ihn (mit `&&` verkettet, damit bei einem fehlgeschlagenen Download nichts Halbes ausgeführt wird):

```bash
curl -fsSL https://github.com/DennisBaerlin/n8n-life-agents/releases/latest/download/install.sh -o install.sh && bash install.sh --domain n8n.example.com

# oder eine bestimmte, fest gepinnte Version:
#   ... -o install.sh && bash install.sh --version vX.Y.Z --domain n8n.example.com
```

Der Start-Befehl (`install.sh`) lädt das passende Release herunter, prüft eine Prüfsumme (SHA256 — ein digitaler Fingerabdruck der Datei), bevor überhaupt etwas entpackt oder ausgeführt wird, und übergibt danach an den eigentlichen Einrichter (`provision.sh`). Bricht die Prüfsumme nicht auf, läuft nichts — so kann keine manipulierte Datei unbemerkt zur Ausführung kommen. (Eine normale Installation ist immer „release" — du musst dafür kein Profil angeben.)

Die eigentliche Einrichtung ist **geführt**, und **alle Fragen kommen zuerst**: Internet-Adresse → Anmeldung an der n8n-Oberfläche → Angaben über dich → Telegram-Bot, Anthropic- und (optional) Google-Schlüssel. Vor **jeder** Frage erklärt ein kurzer Kasten, wofür die Angabe gebraucht wird, wo du sie bekommst und was passiert, wenn du sie überspringst. Schlüssel prüft der Installer sofort online („prüfe …"); das selbst gewählte Passwort gibst du zur Sicherheit zweimal ein. **Pflicht** sind Vorname, Nachname, Geburtsdatum, das Telegram-Bot-Token und der Anthropic-Schlüssel — ohne sie kann der Bot nicht mit dir sprechen; ein versehentliches Enter fragt hier einfach noch einmal nach. Optionale Felder überspringst du mit Enter — das wird sichtbar bestätigt. Jede Antwort wird sofort gespeichert: Brichst du mit **Strg+C** ab, fragt ein neuer Aufruf nur noch den Rest; ein zweiter Lauf fragt nichts doppelt.

Nach der letzten Frage zeigt der Installer eine **Übersicht** aller Antworten (Geheimes nur als „gesetzt"). Hier wählst du **„Stimmt so — Installation starten"**, **„Eine Angabe ändern …"** (genau diese eine Frage kommt dann noch einmal; Enter behält den bisherigen Wert) oder **„Abbrechen"** (auch Esc) — dann wird nichts installiert, und deine Antworten bleiben gespeichert (nur Paket-Einstellungen wie das Bundesland fragt der nächste Aufruf noch einmal). Dieselbe Übersicht erscheint auch bei `lifeagents package install` und bei einem Update, das etwas Neues fragt. Etwas später ändern oder nachtragen (z. B. ein neues Bot-Token oder die Internet-Adresse) geht jederzeit mit `lifeagents reconfigure`.

Danach meldet der Installer „Ab hier läuft alles ohne Rückfrage" und zeigt nur noch **eine Zeile je Schritt** (✓ PostgreSQL eingerichtet, ✓ n8n installiert …). Die ausführliche technische Ausgabe landet in einer Protokolldatei unter `/var/log/lifeagents/install.log`; geht etwas schief, zeigt der Installer dir direkt die letzten Zeilen daraus. Wer alles live sehen möchte, startet mit `--verbose`.

Zum Schluss kommt der [Telegram-Schritt](#mit-telegram-verbinden), danach fasst eine Übersicht zusammen, was eingerichtet wurde, was du übersprungen hast (mit dem passenden Nachtrag-Weg) und welche Zusatz-Funktionen du noch installieren kannst. Ein vom Installer erzeugtes n8n-Passwort zeigt sie **einmalig** an; interne Datenbank-Passwörter druckt sie nicht aus — die liegen nur für Wartungszwecke geschützt unter `/etc/lifeagents/`.

## Was der Lauf installiert

Ein einziger Durchlauf richtet alles ein:

- **PostgreSQL 17** (die Datenbank) — die Hauptversion bleibt fest, Sicherheits-Updates innerhalb von 17 spielt `lifeagents update` ein.
- **Node.js 24** (die Laufzeit, auf der n8n läuft).
- **n8n 2.44.4** (die Workflow-Engine, auf der Orchestrator und alle Agenten laufen).
- **Nicht** installiert wird der HTTPS-Zugang selbst: den stellt **dein** Reverse Proxy bereit (bring your own — siehe [„Reverse Proxy"](#reverse-proxy)). Der Installer gibt dafür eine fertige Konfiguration aus, die nach außen ausschließlich den Telegram-Nachrichtenweg durchlässt und alles andere sperrt.
- Das komplette **Datenbank-Schema** samt Grunddaten (Modell-Liste, zentrale Einstellungen, die englischen Verhaltens-Anweisungen der Agenten — keine persönlichen Daten).
- Die **Owner-Einrichtung:** dein n8n-Zugang wird angelegt, ein interner Zugriffsschlüssel erzeugt, Lese-Rollen für die Datenbank eingerichtet und der Telegram-Bot vorbereitet.
- Die **Workflows des Grundsystems** (Orchestrator, Hilfe, Einrichtungs-Assistent, Erinnerungen, Werkzeuge) werden eingespielt und aktiviert.
- Die Betriebs-Befehlszeile **`lifeagents`** wird auf der Maschine bereitgestellt.
- Die **Fach-Funktionen** (Finanzen, Karriere, Nachlass & Vorsorge, Dokumente) sind eigene Pakete. Welche davon gleich mitkommen sollen, fragt der Installer bei der Erstinstallation zusammen mit den anderen Fragen — als Auswahl-Liste mit einem Satz je Funktion; „Nur Grundsystem" heißt: später. Das Grundsystem läuft auch ganz ohne sie: Fragst du den Bot nach etwas aus einem nicht installierten Bereich, sagt er dir freundlich, dass die Funktion fehlt, und (dir als Besitzer) mit welchem Befehl du sie nachinstallierst.

## Funktionen hinzufügen

Die Fach-Funktionen sind eigene **Pakete** (mehr dazu unter [Pakete](pakete.html)). Hast du bei der Installation „Nur Grundsystem" gewählt oder willst du später mehr, installierst du sie, wann du willst — einzeln oder mehrere auf einmal:

```bash
lifeagents package install
```

Es öffnet sich eine Auswahl-Liste (Leertaste markiert, Enter startet). Danach läuft es wie bei der Erstinstallation: **erst alle Fragen** der gewählten Pakete — zum Beispiel die Zugänge für die Job-Suche oder dein Bundesland für Fristen im Nachlass-Bereich, jeweils mit Erklärung —, dann die **Übersicht vor dem Installieren** (prüfen, einzeln ändern oder abbrechen), dann eine Zeile je Paket (✓ fertig / ✗ Problem) und zum Schluss eine Zusammenfassung. Dein Bot kennt die neue Funktion sofort; `/help` und das Telegram-Befehlsmenü passen sich automatisch an. Ein Paket lässt sich später vorübergehend ausschalten (`lifeagents package deactivate`) oder wieder entfernen (`lifeagents package uninstall`).

**Updates behalten deine Auswahl:** `lifeagents update` aktualisiert genau das Grundsystem und die Pakete, die du installiert hast — ein entferntes Paket kommt nicht zurück, ein ausgeschaltetes bleibt aus, und Einstellungen, die du selbst geändert hast, bleiben erhalten.

**Updates im Chat:** Du musst nicht selbst nach neuen Versionen schauen. Der Bot prüft jeden Tag um 10:20 Uhr, ob es eine neue Version gibt. Gibt es eine, bekommst du (nur der Owner) einmal eine Karte mit den wichtigsten Änderungen, einem Link zur vollen Liste und dem Knopf **Jetzt aktualisieren**. Tippst du darauf, startet das Update spätestens eine Minute später: Der Bot sagt Bescheid, dass er ein paar Minuten nicht erreichbar ist, sichert deine Daten, spielt die neue Version ein und meldet sich danach mit dem Ergebnis. Ohne Tippen passiert nichts, es wird nie von selbst aktualisiert. Installiert wird immer nur die neueste Version und nie eine ältere als deine. Klappt etwas nicht, erklärt die Nachricht, was passiert ist, ob dein System noch läuft und was du tun kannst (mehr dazu unter [Wenn ein Update fehlschlägt](update-hilfe.html)). Abschalten: `lifeagents config set feature update_check false`.

**Releases sind unterschrieben:** Jede neue Version wird vom Projekt digital unterschrieben. Deine Installation prüft diese Unterschrift vor jedem Update und spielt nichts ein, was nicht echt unterschrieben ist. So reicht ein gekapertes GitHub-Konto nicht aus, um fremden Code auf deinen Server zu bringen. Der Prüfschlüssel kommt einmal mit der Installation (bzw. mit dem ersten Update auf eine unterschriebene Version) und wird danach nie mehr durch ein Update ersetzt.

**Zeitzone des Haushalts:** Erinnerungen, Zeitpläne und „heute“ (zum Beispiel das Buchungsdatum, wenn du keins nennst) richten sich nach der Zeitzone **Europe/Berlin**, nicht nach der Uhr des Servers. Viele Container-Vorlagen laufen auf UTC; dort lagen Erinnerungen bisher ein bis zwei Stunden später, und kurz nach Mitternacht galt noch der Vortag. Bestehende Installationen stellen beim nächsten `lifeagents update` automatisch um. Wer woanders wohnt, setzt beim Installieren `HOUSEHOLD_TIMEZONE` (z. B. `HOUSEHOLD_TIMEZONE=Europe/Vienna` in der `--unattended`-Datei). Der Wert wird gespeichert und bleibt bei jedem Update erhalten.

**Jedes Update sichert vorher:** Wechselt ein Update die Version (eine neue Version des Projekts oder von n8n, Node.js bzw. PostgreSQL), wartet der Installer kurz laufende Agenten-Schritte ab, hält n8n an und legt eine **verschlüsselte Sicherung der ganzen Datenbank** unter `/var/backups/lifeagents/` an (die letzten zwei bleiben liegen). Erst danach wird getauscht; bei einer neuen n8n-Version stellt n8n seine Tabellen um, das kann einige Minuten dauern. Offene Bestätigungen bleiben erhalten. Bricht das Update ab, setzt ein erneutes `lifeagents update` mit derselben Sicherung fort, und `lifeagents doctor` weist darauf hin. Willst du zurück zur vorherigen Version, holt `lifeagents rollback` die Daten von vor dem Update zurück und spielt den vorherigen Stand ein (fragt vorher nach, weil alles seit der Sicherung verloren geht). Erneut dieselbe Version einspielen (z. B. `lifeagents reconfigure`) sichert nicht.

## Erreichbarkeit

Damit Telegram deinem Bot Nachrichten schicken kann, muss dein Server **von außen über HTTPS erreichbar** sein. Der Weg einer Nachricht:

**Telegram → deine Domain (öffentliches DNS/DynDNS) → Port-Weiterleitung am Router → HTTPS-Terminierung (Reverse Proxy) → n8n.**

Konkret sind das drei Bausteine:

- **Eine öffentliche Domain**, die auf deinen Internet-Anschluss zeigt. Zuhause ändert sich die IP-Adresse oft — dafür gibt es DynDNS-Dienste (die FritzBox bringt mit **MyFRITZ!** einen eigenen mit, siehe unten).
- **Eine Port-Weiterleitung** am Router: eingehende Verbindungen auf **Port 443** an deinen Server. (Telegram akzeptiert nur die Ports 443, 80, 88 oder 8443 — wir nutzen 443.)
- **Ein Reverse Proxy** — auf diesem Server oder auf einem anderen Rechner in deinem Heimnetz —, der HTTPS verschlüsselt und nur die Telegram-Adressen (`/webhook*`) an n8n weiterreicht. **Das ist Pflicht:** n8n selbst spricht kein HTTPS — eine reine Port-Weiterleitung ohne Reverse Proxy genügt nicht.

Antwortet der Bot nach der Installation nicht, fehlt fast immer einer dieser drei Punkte. Richte sie ein und führe dann — **warst du noch nie mit dem Bot verbunden** — `lifeagents household pair-owner` aus: der Befehl prüft die Erreichbarkeit (und zeigt dir dabei Telegrams eigene Fehlermeldung), meldet den Bot neu bei Telegram an und verbindet dich danach. **Warst du schon verbunden**, nimm stattdessen `lifeagents reconfigure` → Grundsystem → „Unverändert neu anwenden" — das richtet alles neu ein und meldet den Bot wieder bei Telegram an.

## Reverse Proxy

Der Reverse Proxy ist der „Türsteher" zwischen Internet und deinem Server: Er nimmt die verschlüsselten HTTPS-Verbindungen von Telegram an (dafür hat er das Zertifikat, z. B. von Let's Encrypt) und reicht **nur** die Telegram-Pfade an n8n weiter. Die n8n-Oberfläche bleibt so privat. Er wird **nicht mitinstalliert** — viele Heimserver haben ohnehin schon einen. Der Installer fragt deshalb, **wo** dein Proxy läuft, und gibt dir passend dazu die fertige Konfiguration aus (später erneut anzeigen oder ändern: `lifeagents proxy show` bzw. `lifeagents proxy set <IP>`).

**Für jeden Proxy gilt:**

- Leite **ausschließlich** diese Adress-Pfade an n8n weiter — alles andere soll der Proxy abweisen oder anderswohin schicken:
  - `/webhook/*`, `/webhook-test/*`, `/webhook-waiting/*`, `/webhook-waiting-telegram`
  - `/webhook-waiting/*` und `/webhook-waiting-telegram` sind **Pflicht** — darüber laufen die Bestätigungs-Knöpfe. Mit `/webhook-waiting-telegram` antworten die Knöpfe direkt im Chat (ein Tipp, kein Browserfenster); fehlt die Route, öffnen sie stattdessen eine Webseite. Ob alles passt, zeigt `lifeagents doctor`; hast du die Route nachträglich ergänzt, schaltet `lifeagents update` das Bestätigen im Chat ein.
- Reiche die Header `X-Forwarded-For`, `X-Forwarded-Host` und `X-Forwarded-Proto` an n8n durch (Caddy macht das automatisch).
- Sorge für ein gültiges HTTPS-Zertifikat (z. B. Let's Encrypt) auf deiner Domain.

### Fall 1: Proxy auf einem anderen Rechner (z. B. zentraler Proxy-Container)

Typisch bei Proxmox & Co.: Ein zentraler Caddy, Nginx Proxy Manager oder Traefik in einem eigenen Container bedient schon andere Dienste (etwa Home Assistant) unter **einer** Domain. Dann gibst du bei der Installation die IP-Adresse dieses Proxy-Rechners an. Was passiert:

- n8n nimmt Verbindungen aus dem Heimnetz an — aber eine **Firewall-Regel lässt nur deinen Proxy-Rechner** durch; alle anderen Geräte im Heimnetz werden abgewiesen. Lässt sich die Regel nicht einrichten, bleibt n8n aus Sicherheitsgründen nur lokal erreichbar, und der Installer sagt dir das deutlich.
- Du bekommst einen **Baustein zum Einfügen** in deine bestehende Proxy-Konfiguration (gespeichert auch in `/etc/lifeagents/reverse-proxy.caddyfile`). Beispiel für einen zentralen Caddy, der nach Pfad verteilt (Home Assistant bekommt alles andere):

```caddyfile
deine-domain.myfritz.net {
    @lifeagents path /webhook/* /webhook-test/* /webhook-waiting/* /webhook-waiting-telegram
    handle @lifeagents {
        reverse_proxy 192.168.178.20:5678    # IP des lifeagents-Rechners
    }
    handle {
        reverse_proxy 192.168.178.30:8123    # z. B. Home Assistant
    }
}
```

- **Feste IP-Adressen:** Die Firewall lässt genau die IP deines Proxy-Rechners zu, und der Proxy findet n8n über dessen IP. Vergib darum im Router **beiden** Rechnern eine feste Adresse (FRITZ!Box: *Heimnetz → Netzwerk → Gerät → „Diesem Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen"*). Ändert sich doch eine: `lifeagents proxy set <neue IP>`.
- Zwischen Proxy und n8n läuft der Verkehr im Heimnetz unverschlüsselt (normal für diesen Aufbau, wie bei Home Assistant hinter einem Proxy).
- Änderst du selbst etwas an der Firewall des Servers (z. B. alle Regeln neu laden), kann die Freigabe verloren gehen — dann bekommt der Proxy „502". `lifeagents doctor` zeigt dir das an, `lifeagents proxy set <IP>` stellt sie wieder her.

### Fall 2: Proxy auf diesem Rechner (oder noch keiner)

n8n bleibt nur auf diesem Rechner erreichbar (`127.0.0.1:5678`). **Mit Caddy (empfohlen, am einfachsten):** Caddy holt das Zertifikat automatisch. Der Installer gibt dir am Ende ein **komplettes, fertiges Caddyfile** aus (Domain und Adresse bereits eingesetzt); es liegt außerdem in `/etc/lifeagents/reverse-proxy.caddyfile`. Einrichten:

```bash
# Caddy installieren (Debian) — siehe https://caddyserver.com/docs/install
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy

# Das vom Installer ausgegebene Caddyfile eintragen und neu laden:
sudo cp /etc/lifeagents/reverse-proxy.caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

## FritzBox einrichten

Ist dein Router eine **FritzBox**, brauchst du zwei Einstellungen:

1. **Portfreigabe (Port-Weiterleitung):** *Internet → Freigaben → Portfreigaben → Gerät für Freigaben hinzufügen*. Wähle deinen Server, Anwendung „HTTPS-Server", Protokoll TCP, Port **443** (extern wie intern). Damit erreichen Anfragen aus dem Internet deinen Server.
2. **Öffentlicher Name (DynDNS):** Aktiviere unter *Internet → MyFRITZ!-Konto* den MyFRITZ!-Dienst — du bekommst eine feste Adresse (`….myfritz.net`), die immer auf deinen Anschluss zeigt, auch wenn sich deine IP-Adresse ändert. Diese Adresse (oder eine eigene Domain, die darauf zeigt) gibst du dem Installer als Domain an.

**IPv6 und die MyFRITZ!-Adresse:** Die Portfreigabe gilt nur für IPv4. Über IPv6 zeigt die MyFRITZ!-Adresse auf die FritzBox selbst — wer sie aus dem Heimnetz im Browser öffnet, landet auf einer FritzBox-Seite („Die angegebene URL ist nicht verfügbar"). Telegram nutzt IPv4 und ist nicht betroffen, und die Bestätigungs-Knöpfe im Chat brauchen keinen Browser. Damit der Server sich selbst über die Domain erreicht, trägt der Installer die Domain bei Bedarf in `/etc/hosts` auf deinen Reverse Proxy ein — nur, wenn eine Probe bestätigt, dass es so funktioniert. Nach außen (Telegram, Anthropic) spricht der Server bevorzugt IPv4: Ein kurzzeitig hängender IPv6-Weg im Heimnetz würde sonst jede Antwort um rund zwei Minuten verzögern.

Hinweis: Die Installation nimmt extern Port **443** an. Telegram erlaubt zwar auch 80, 88 oder 8443, ein anderer Port wird hier aber derzeit nicht unterstützt — eine Handänderung in `/etc/n8n/n8n.env` würde beim nächsten Update überschrieben.

## Telegram-Bot anlegen

Noch kein Bot-Token? So bekommst du eins:

1. Telegram öffnen, oben nach **@BotFather** suchen und den Chat öffnen.
2. **/newbot** senden.
3. Einen **Anzeige-Namen** wählen (frei), dann einen **Usernamen**, der auf `bot` endet (z. B. `mein_agent_bot`).
4. BotFather antwortet mit dem **Token** (Form `123456:ABC-DEF…`) — den kopierst du und gibst ihn beim Installer ein. Der Installer prüft ihn sofort gegen Telegram.

## Mit Telegram verbinden

Am Ende der Installation verbindet der Installer dich als Owner (Besitzer) mit deinem Bot — in drei Schritten, ohne dass du etwas abtippen musst:

1. **Erreichbarkeit prüfen.** Der Installer fragt Telegram direkt, ob dein Server von außen erreichbar ist. Wenn nicht, zeigt er dir das fertige Caddyfile, die Anforderungen an deinen Reverse Proxy und Telegrams eigene Fehlermeldung. Richte den Proxy ein und wähle „Erneut prüfen" — oder „Später einrichten".
2. **Verbindungs-Link öffnen.** Du bekommst einen Link der Form `https://t.me/<dein-bot>?start=<code>`. Öffne ihn auf dem Handy, Telegram startet den Chat mit deinem Bot und schickt den Code mit. (Alternativ tippst du `/start <code>` von Hand.) Der Code steht **nur im Terminal**, nie im Chat — so kann sich niemand, der zufällig Zugriff auf den Chat hätte, selbst als Besitzer eintragen. Er gilt 10 Minuten; danach bietet der Installer dir einen neuen an.
3. **Warten, fertig.** Der Installer wartet, bis deine Nachricht angekommen ist (der Bot antwortet kurz „Verbunden! Einen Moment …"), und stellt den Bot dann selbst fertig auf dich ein (Befehlsmenü, Benachrichtigungen an dich). Ein zweiter Lauf ist nicht nötig. Mit `s` (oder Strg+C) überspringst du das Warten.
4. **Begrüßung.** Sobald alles bereit ist, schreibt dir der Bot in Telegram: mit deinem Vornamen, welche Funktionen installiert sind, und einem Knopf **„Haushalt einrichten"** als nächstem Schritt. Kommt die Nachricht nicht, schreib ihm einfach `/start`.

Hast du den Schritt übersprungen oder kommt ein neues Telegram-Konto dazu: `lifeagents household pair-owner` startet genau denselben Ablauf jederzeit neu. Fehlte für die Verbindung noch eine Angabe (z. B. die Internet-Adresse), trägst du sie mit `lifeagents reconfigure` nach — danach läuft die Verbindung von selbst an. Neuer Bot? Ebenfalls `lifeagents reconfigure`; schreib dem neuen Bot danach einmal `/start`.

## So geht's weiter

Die Abschluss-Übersicht im Terminal endet mit einem kurzen Fahrplan — dasselbe hier zum Nachlesen:

1. **In Telegram:** auf „Haushalt einrichten" tippen (jederzeit wieder: `/onboarding`). Dich kennt der Bot schon aus der Installation (Name, Geburtsdatum) — er fragt nur noch, wer sonst zum Haushalt gehört.
2. **Funktionen dazunehmen**, wann immer du willst: `lifeagents package install` zeigt eine Auswahl-Liste mit einem Satz je Funktion. Neue Bereiche erscheinen danach sofort in `/onboarding` und `/help`. Eine ausgeschaltete Funktion schaltest du mit `lifeagents package activate <paket>` wieder ein.
3. **Überblick:** `/help` im Chat zeigt, was der Bot kann — inklusive der Funktionen, die du noch dazunehmen könntest. Den technischen Zustand prüft `lifeagents doctor`.

Was eingeladene Haushaltsmitglieder tun, steht auf [Erste Schritte](erste-schritte.html).

## Betrieb danach: die `lifeagents`-Befehlszeile

Nach der Installation steht dir auf der Maschine eine kleine Befehlszeile (CLI) für den laufenden Betrieb zur Verfügung. **Du musst dir die Befehle nicht merken:** tippst du nur `lifeagents` (ohne alles), öffnet sich ein Menü, durch das du mit den **Pfeiltasten** navigierst und mit **Enter** auswählst — und lässt du bei einem Befehl das Argument weg (z. B. den Paketnamen bei `package install`), bietet dir die CLI eine Auswahl-Liste an; bei Mehrfachwahl markierst du Einträge mit der **Leertaste**. In Skripten und ohne Terminal verhält sich alles exakt wie eine klassische CLI (kein Menü). Die Tabelle hier ist nur der grobe Überblick — die **vollständige, immer aktuelle Referenz** (alle Befehle, Unterbefehle und Optionen) zeigt dir `lifeagents help` und je Bereich `lifeagents <befehl> help` direkt auf der Maschine; diese Hilfe-Ausgabe wird automatisch gegen den Code geprüft und kann nicht veralten:

| Befehl | Wofür |
|---|---|
| `lifeagents` (ohne Befehl) | Öffnet auf einem Terminal das interaktive Menü (Pfeiltasten + Enter); Abbruch mit ESC zeigt die klassische Hilfe. |
| `lifeagents update` | Holt die neueste Version, spielt sie ein und wendet nötige Datenbank-Änderungen automatisch mit an — für das Grundsystem und genau die Pakete, die du installiert hast. Führt eine neue Version neue Einstellungen ein, fragt das Update genau diese einmalig nach — bereits Beantwortetes nie wieder. Dasselbe passiert, wenn du in der Update-Karte im Chat auf **Jetzt aktualisieren** tippst. |
| `lifeagents rollback` | Nach einem gescheiterten Update zurück zur vorherigen Version: holt die Daten aus der Sicherung von direkt vor dem Update zurück und spielt den vorherigen Stand ein. Fragt vorher nach, denn was seit der Sicherung gespeichert wurde, geht verloren. Mehr unter [Wenn ein Update fehlschlägt](update-hilfe.html). |
| `lifeagents package …` | Fach-Pakete wie Finanzen oder Karriere anzeigen, nachinstallieren oder entfernen; ohne Paketnamen öffnet sich eine Auswahl-Liste (bei `install` mit Leertasten-Mehrfachwahl, erst alle Fragen, dann eine Übersicht zum Prüfen, dann die Installation); `reconfigure` trägt übersprungene Zugangsdaten eines Pakets (z. B. die Job-Quellen des Karriere-Pakets) später nach (mehr dazu unter [Pakete](pakete.html)). |
| `lifeagents reconfigure` | Angaben nach der Installation ändern oder nachtragen — mit Auswahl-Liste: **Grundsystem** (Internet-Adresse, Telegram-Bot-Token, Anthropic- und Google-Schlüssel; Enter behält den bisherigen Wert) oder die Zugangsdaten eines Pakets. Danach richtet es alles neu ein, wie ein Update ohne Download. „Unverändert neu anwenden" repariert z. B. eine verlorene Telegram-Verbindung. |
| `lifeagents config …` | Zentrale Einstellungen ansehen oder ändern, z. B. welches Modell ein Agent nutzt oder ob ein Zeitplan aktiv ist. `list` zeigt je Paket alle Einstellungen mit einem Satz, was sie bewirken, und markiert selbst geänderte Werte mit `*` (sie überleben Updates); `set` zeigt diesen Satz vor der Eingabe noch einmal und prüft den neuen Wert (ein falscher Zeitplan oder eine Zahl außerhalb des erlaubten Bereichs wird mit Erklärung abgelehnt); `reset` holt den Standardwert zurück. Jede Änderung wirkt ohne Neuinstallation: ein geänderter Zeitplan sofort, z. B. `lifeagents config set schedule score_jobs '0 7 * * 1-5'` (werktags 7 Uhr), ein anderes KI-Modell beim nächsten Einsatz, z. B. `lifeagents config set model web_search claude-haiku-latest`. |
| `lifeagents proxy show\|set …` | Zeigt, wo dein Reverse Proxy läuft und wem n8n geöffnet ist, und gibt die passende Proxy-Konfiguration erneut aus; `set <IP>` stellt auf einen Proxy auf einem anderen Rechner um (`set 127.0.0.1` = wieder dieser Rechner). |
| `lifeagents household …` | Haushaltsmitglieder einladen, verbinden, entfernen oder sperren. |
| `lifeagents backup export\|restore` | Ein verschlüsseltes Voll-Backup deiner Daten erstellen oder zurückspielen, optional als Datei an deinen eigenen Telegram-Chat. |
| `lifeagents doctor` | Prüft den Zustand der Installation, ohne etwas zu verändern (nur lesend). |
| `lifeagents uninstall` | Baut die Installation sauber zurück; mit einer Zusatz-Option auch inklusive aller Daten. |
| `lifeagents version` | Zeigt, welche Version gerade installiert ist. |
| `lifeagents help` | Die vollständige Befehls-Referenz (je Bereich: `lifeagents <befehl> help`). |

## Etwas stimmt nicht?

Der erste Schritt bei jedem Problem ist immer derselbe: `lifeagents doctor` ausführen. Er prüft Dienste, Datenbank und Verbindungen (auch, ob Telegram deinen Server wirklich erreicht), verändert dabei nichts, und zeigt dir mit einer Ampel-Übersicht genau, welcher Teil klemmt. Ist bei der Installation etwas schiefgegangen, steht das vollständige Protokoll in `/var/log/lifeagents/install.log`.
