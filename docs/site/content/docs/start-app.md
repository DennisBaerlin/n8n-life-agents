---
title: "Installation mit der Start-App"
---

Dieser Weg ist für dich, wenn du **keinen eigenen Server** hast, aber einen Mac oder Windows-PC, der durchlaufen kann (zum Beispiel einen Mac mini). Du lädst eine Datei, öffnest die Start-App, und sie führt dich Frage für Frage durch alles. Ein Terminal brauchst du nicht, und du musst nicht wissen, wie die Technik dahinter heißt. Der Bot kann danach genau dasselbe wie bei der [Installation auf einem eigenen Server](installation.html).

**Stand:** Die Start-App ist noch im Bau. Der Mac ist der erste Weg; Windows folgt aus derselben App und wird erst geprüft, wenn der Mac läuft. Wo hier „wird geprüft“ steht, bestätigt das erst der Test auf einem echten Mac.

## Bevor du startest

- **Ein Rechner, der an bleiben darf**, am Netzteil. Docker (die Technik, in der der Bot auf deinem Rechner läuft) verlangt mindestens 4 GB Arbeitsspeicher beim Mac und 8 GB bei Windows. Die App prüft das selbst und sagt dir, wenn etwas fehlt.
- **Die Zugänge für den Bot:** ein Telegram-Bot-Token und ein Anthropic-Schlüssel (Pflicht), ein Google-Schlüssel nur für Sprachnachrichten (freiwillig). Was das ist und wo du es bekommst, steht unter [Bevor du startest](installation.html#bevor-du-startest) und [Telegram-Bot anlegen](installation.html#telegram-bot-anlegen). Eine eigene Domain und einen Reverse Proxy brauchst du auf diesem Weg **nicht**.
- **Für den Weg ins Internet** (siehe [unten](#tunnel-oder-fritzbox)): ein kostenloses Tailscale-Konto, das du im Wizard anlegst, oder Zugang zur Oberfläche deiner FritzBox.

Docker musst du nicht vorher installieren, das erledigt die App. **Ist Docker schon da**, zum Beispiel weil dort Paperless läuft, nutzt die App es mit. Sie installiert es nie ein zweites Mal, ändert nie seine Version, und deine anderen Programme darin bleiben, wie sie sind.

Docker Desktop ist für private Nutzung kostenlos. Wer es beruflich in einer größeren Firma nutzt, braucht laut Docker ein Abo ([Docker-Preise](https://www.docker.com/pricing/faq/), keine Rechtsberatung).

## Schritt 1: Datei laden

- **Mac:** [lifeagents.dmg](https://github.com/DennisBaerlin/n8n-life-agents/releases/latest/download/lifeagents.dmg)
- **Windows:** [lifeagents-setup.exe](https://github.com/DennisBaerlin/n8n-life-agents/releases/latest/download/lifeagents-setup.exe)

Beide Dateien kommen direkt aus der Release-Seite des Projekts auf GitHub. Ein Konto brauchst du dafür nicht.

## Schritt 2: In den Programme-Ordner ziehen

**Mac:** Doppelklick auf die geladene Datei. Es öffnet sich ein Fenster mit dem Symbol der App, dem Programme-Ordner und einem Pfeil dazwischen. Zieh das Symbol auf den Ordner. Danach das Fenster schließen.

*Erwartet:* Im Finder unter **Programme** liegt jetzt die App. Öffne sie immer von dort. Startest du sie aus dem Fenster der Datei, bittet sie dich zuerst, sie in den Ordner zu ziehen.

**Windows:** Doppelklick auf die Setup-Datei. Der nächste Schritt erklärt die Warnung, die dabei erscheint.

## Schritt 3: Die Sperre beim ersten Öffnen lösen

Der Mac und Windows warnen beim ersten Öffnen, weil die App nicht über ein kostenpflichtiges Entwicklerkonto bei Apple bzw. Microsoft registriert ist. Der Quelltext ist öffentlich, und du lädst die Datei nur von der Release-Seite oben. Das Lösen ist **einmal** nötig.

**Mac** (so beschreibt es [Apple](https://support.apple.com/de-de/102445)):

1. Die App im Ordner **Programme** doppelt anklicken. Der Mac meldet, dass er die App nicht öffnen kann, weil er sie nicht prüfen konnte. Klick auf **Fertig**, nicht auf „In den Papierkorb legen“.
2. Apple-Menü (oben links) → **Systemeinstellungen** → **Datenschutz und Sicherheit**.
3. Nach unten scrollen bis zum Bereich **Sicherheit**. Dort steht ein Hinweis zur App mit dem Knopf **Dennoch öffnen**. Klick darauf.
4. Es kommt noch einmal eine Warnung. Klick auf **Öffnen** und gib, falls gefragt, das Passwort deines Macs ein.

*Erwartet:* Die App öffnet sich mit ihrem Willkommen-Bildschirm. Ab jetzt startet sie ohne Warnung.

Erscheint der Knopf **Dennoch öffnen** nicht, öffne die App noch einmal aus dem Ordner Programme und schau direkt danach erneut in den Systemeinstellungen nach. **Wird geprüft:** Ob der Knopf auf jedem Mac erscheint und ob der Mac statt der Warnung „beschädigt“ meldet, klärt der Test auf einem echten Mac. Danach steht hier, was in diesem Fall zu tun ist.

**Windows:** Es erscheint ein blaues Fenster „Der Computer wurde durch Windows geschützt“. Klick auf **Weitere Informationen** und dann auf **Trotzdem ausführen**.

## Schritt 4: Die App führt dich durch den Rest

Ab hier fragt die App, und du antwortest. Jede Antwort wird sofort gespeichert; brichst du ab, verlierst du nichts. Die Reihenfolge:

1. **Rechner prüfen**, ohne Frage: Bauart, System-Version, Arbeitsspeicher, freier Platz.
2. **Docker:** Fehlt es, erklärt die App in zwei Sätzen, was das ist, zeigt die Bedingungen von Docker und fragt dich. Erst nach deinem **Einverstanden** lädt sie Docker direkt beim Hersteller (gut ein halbes Gigabyte) und prüft dessen Unterschrift. Dein Rechner fragt dabei einmal nach seinem Passwort.
3. **„Das wird geändert“:** Bevor irgendetwas passiert, zeigt die App eine Liste, was sie auf deinem Rechner einrichtet. Ohne dein Ja ändert sie nichts.
4. **Deine Angaben**, eine Frage je Seite: Sprache, Name, Geburtsdatum, Charakter des Bots, Telegram-Bot, Anthropic, Google (freiwillig), welche Funktionen du willst, und der Weg ins Internet (Tunnel oder FritzBox).
5. **Übersicht:** alle Antworten noch einmal zum Prüfen, bevor installiert wird.
6. **Installation** mit Fortschrittsanzeige. Die App lädt dabei die Bausteine des Bots, gut ein halbes Gigabyte.
7. **Mit Telegram verbinden** per QR-Code: mit dem Handy scannen, Telegram öffnet den Chat mit deinem Bot.
8. **Dauerbetrieb:** ob der Rechner durchlaufen soll (siehe [unten](#dauerbetrieb)).

Die Fragen und Prüfregeln sind dieselben wie bei der Installation auf einem Server. Die genauen Texte der App können sich bis zur ersten Version noch ändern.

## Tunnel oder FritzBox? {#tunnel-oder-fritzbox}

Damit Telegram deinem Bot Nachrichten zustellen kann, muss dein Rechner aus dem Internet erreichbar sein. Die App bietet dafür zwei Wege an:

- **Tunnel (empfohlen):** Du brauchst ein kostenloses Tailscale-Konto. Am Router änderst du nichts, und es klappt auch bei Anschlüssen ohne eigene IPv4-Adresse (DS-Lite). Anleitung: [Tunnel einrichten](tunnel.html).
- **FritzBox-Freigabe:** Du brauchst eine FritzBox mit eigener IPv4-Adresse, auf der Port 80 und 443 noch frei sind, und richtest zwei Freigaben auf deinen Rechner ein. Dafür kommst du ohne fremdes Konto aus. Anleitung: [FritzBox einrichten → Mit der Start-App](fritzbox.html#start-app).

Der Tunnel ist empfohlen, weil du am Router nichts änderst und er auch dort funktioniert, wo die FritzBox-Freigabe nicht geht.

## Dauerbetrieb {#dauerbetrieb}

Der Bot antwortet nur, solange dein Rechner läuft. Am Ende fragt die App darum: „Soll dieser Rechner durchlaufen?“ Bei **Ja** fragt dein Rechner nach seinem Passwort, bei **Nein** ändert sich nichts.

Auf dem **Mac** stellt die App bei Ja ein:

- Der Mac schläft am Netzteil nicht mehr ein.
- Der Bildschirm geht nach 10 Minuten trotzdem aus.
- Nach einem Stromausfall startet der Mac von selbst.
- Er lässt sich über das Heimnetz wecken.

Vorher merkt sich die App deine bisherigen Einstellungen und kann sie jederzeit zurückstellen. Ein **MacBook** schläft auf Akku und mit zugeklapptem Deckel trotzdem; dort gilt das nur am Netzteil.

**Nach einem Stromausfall:** Der Mac fährt von selbst hoch, wartet dann aber auf dein Passwort, wenn die Festplatten-Verschlüsselung (FileVault) an ist. Erst nach der Anmeldung starten App und Bot. Bis dahin schweigt der Bot. Lass die Verschlüsselung trotzdem an: Sie schützt deine Daten, falls der Rechner gestohlen wird.

Auf **Windows** legt die App ein eigenes Energieschema an (kein Standby, Bildschirm nach 10 Minuten aus); dein bisheriges Schema bleibt unberührt. Ob der PC nach einem Stromausfall von selbst startet, stellst du dort im BIOS ein, das macht die App nicht.

**Wird geprüft:** wie viel Strom der Rechner mit dem laufenden Bot braucht und ob ein Mac mini mit diesen Einstellungen wirklich wach bleibt.

## Im Alltag

Nach der Einrichtung sitzt ein kleines Symbol in der Menüleiste (Mac) bzw. neben der Uhr (Windows). Es zeigt, ob alles läuft oder Docker aus ist, und bietet: Telegram öffnen, Dauerbetrieb zurückstellen, Fehlerbericht und Deinstallieren. Die App startet bei jeder Anmeldung von selbst und bringt Docker und den Bot hoch.

Updates kommen wie bei jeder Installation als Karte im Chat; ein Tipp auf **Jetzt aktualisieren** sichert vorher deine Daten ([mehr zu Updates](installation.html#funktionen-hinzufügen)). Eine neue Fassung der Start-App selbst meldet der Bot im Chat, sie lädst du dann wie in Schritt 1.

## Wenn etwas nicht klappt

Der Knopf **Fehlerbericht** im Symbol erstellt einen Bericht aus festen Angaben (zum Beispiel Version und welcher Schritt hakt). Chat-Inhalte und Schlüssel stehen nie darin. Schick ihn an die Person, die dir beim Einrichten hilft.

## Entfernen

Nimm im Symbol **Deinstallieren**. Die App entfernt nur, was sie selbst eingerichtet hat, stellt die Energie-Einstellungen zurück und fragt, ob deine Daten gelöscht werden sollen. Docker bleibt, wenn es schon vorher da war.

Zieh die App **nicht einfach in den Papierkorb**: Dann läuft der Bot im Hintergrund weiter, und nichts wird zurückgestellt.
