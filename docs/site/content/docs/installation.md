---
title: "Installation, Update & Betrieb"
---

## Welcher Weg passt zu dir? {#weg}

Es gibt zwei gleichwertige Wege. Der Bot kann danach in beiden dasselbe. Die Frage ist: **Hast du einen eigenen Server?**

- **Ja, ich habe einen eigenen Linux-Server** (am besten eine virtuelle Maschine) und etwas Technik-Wissen: **Einrichter für Linux.** Ein Befehl im Terminal startet ihn, die Fragen beantwortest du in einem Fragebogen im Browser deines Laptops. Ins Internet kommt der Bot per Tunnel (empfohlen) oder FritzBox-Freigabe. Anleitung: [Auf einem Linux-Server](linux.html).
- **Nein, ich habe einen Mac oder Windows-PC**, der durchlaufen kann, und kein Technik-Wissen: **Start-App.** Datei laden, App öffnen, die Fragen kommen im Fenster. Ins Internet kommt der Bot per Tunnel (empfohlen) oder FritzBox-Freigabe. Anleitung: [Installation mit der Start-App](start-app.html).

Diese Seite sammelt, was für beide Wege gilt: was du vorher brauchst, wie der Bot ins Internet kommt, wie du Telegram verbindest, wie du Funktionen dazunimmst und welche Befehle es danach gibt. Den Ablauf der Einrichtung selbst beschreiben die Seiten der beiden Wege. Der Bot läuft auf beiden in Docker. Die Einrichtung bringt das **Grundsystem** mit (Telegram-Bot, Hilfe, Einrichtungs-Assistent, Erinnerungen); die Fach-Funktionen — Finanzen, Karriere, Nachlass, Dokumente — wählst du **einzeln** dazu (siehe [„Funktionen hinzufügen"](#funktionen-hinzufügen)). Wie Telegram deinen Rechner erreicht, ist eine der Fragen (siehe [„Erreichbarkeit"](#erreichbarkeit)): am einfachsten über einen **Tunnel**, den die Einrichtung selbst einrichtet.

## Bevor du startest

Diese Dinge brauchst du vorher:

- Einen **Telegram-Bot-Token** von @BotFather (dem offiziellen Telegram-Werkzeug zum Anlegen eines Bots — Schritt-für-Schritt weiter unten unter [„Telegram-Bot anlegen"](#telegram-bot-anlegen)).
- **Einen Weg ins Internet**, eins von beiden:
  - ein kostenloses **Tailscale-Konto** für den Tunnel (empfohlen, geht mit jedem Anschluss, am Router ist nichts einzustellen). Das Konto kannst du auch erst während der Installation anlegen.
  - oder eine **FritzBox** mit eigener IPv4-Adresse, in der du zwei Freigaben einrichtest (siehe [FritzBox einrichten](fritzbox.html)).

  Wie das zusammenspielt, steht unten unter [„Erreichbarkeit"](#erreichbarkeit).
- Einen **Anthropic-API-Key** (Pflicht) — alle Agenten denken mit Claude: Weiterleiten, Buchen, Hilfe, Belege lesen, Websuche und Beratung. Anthropic nutzt Daten aus der API nicht zum Training (mehr auf der Seite [Datenschutz](datenschutz.html)).
- Optional einen **Google-Gemini-API-Key im bezahlten Tarif** (nicht die kostenlose Stufe) — nur für Sprachnachrichten, weil Claude kein Audio versteht. Ohne ihn bittet der Bot bei einer Sprachnachricht, als Text zu schreiben; nachtragen geht später jederzeit.

Das Projekt selbst ist kostenlos (MIT-Lizenz) und braucht kein GitHub-Konto. Laufende Kosten entstehen nur für deinen Rechner und die KI-Nutzung nach Verbrauch, die Anthropic (und für Sprachnachrichten Google) direkt mit dir abrechnet.

## So läuft die Einrichtung

Auf beiden Wegen kommen **alle Fragen zuerst**, in einem Fragebogen (auf dem Linux-Server im Browser deines Laptops, bei der Start-App im Fenster): Weg ins Internet, Angaben über dich, Telegram-Bot, Anthropic- und (optional) Google-Schlüssel, welche Funktionen du willst und wohin gesichert wird. Vor jeder Frage erklärt ein kurzer Text, wofür die Angabe gebraucht wird, wo du sie bekommst und was passiert, wenn du sie überspringst. **Pflicht** sind Vorname, Nachname, Geburtsdatum, das Telegram-Bot-Token und der Anthropic-Schlüssel — ohne sie kann der Bot nicht mit dir sprechen. Jede Antwort wird sofort gespeichert: Brichst du ab, verlierst du nichts und machst beim nächsten Mal dort weiter.

Nach der letzten Frage zeigt eine **Übersicht** alle Antworten (Geheimes nur als „gesetzt"). Erst mit deinem Ja geht die Installation los, vorher kannst du einzelne Angaben ändern oder abbrechen. Etwas später ändern oder nachtragen (z. B. ein neues Bot-Token) geht jederzeit mit `lifeagents reconfigure`.

Hast du den Tunnel gewählt, richtet die Installation Tailscale ein und zeigt dir den Anmelde-Link (siehe [„Weg 1: Tunnel"](#tunnel)). Zum Schluss kommt der [Telegram-Schritt](#mit-telegram-verbinden).

## Was eingerichtet wird

Ein einziger Durchlauf richtet alles ein:

- **PostgreSQL 17** (die Datenbank) — die Hauptversion bleibt fest.
- **n8n 2.45.7** (die Workflow-Engine, auf der Orchestrator und alle Agenten laufen).
- Beim **Tunnel**: **Tailscale**. Es lässt nach außen ausschließlich den Telegram-Nachrichtenweg durch.
- Beim **FritzBox-Weg** bringt der Verbund seinen eigenen Türsteher (HTTPS-Zugang) mit; er lässt nach außen ausschließlich den Telegram-Nachrichtenweg durch und sperrt alles andere.
- Das komplette **Datenbank-Schema** samt Grunddaten (Modell-Liste, zentrale Einstellungen, die englischen Verhaltens-Anweisungen der Agenten — keine persönlichen Daten).
- Die **Owner-Einrichtung:** dein n8n-Zugang wird angelegt, ein interner Zugriffsschlüssel erzeugt, Lese-Rollen für die Datenbank eingerichtet und der Telegram-Bot vorbereitet.
- Die **Workflows des Grundsystems** (Orchestrator, Hilfe, Einrichtungs-Assistent, Erinnerungen, Werkzeuge) werden eingespielt und aktiviert.
- Die Betriebs-Befehlszeile **`lifeagents`** (siehe [unten](#betrieb-danach-die-lifeagents-befehlszeile)).
- Die **Fach-Funktionen** (Finanzen, Karriere, Nachlass & Vorsorge, Dokumente) sind eigene Pakete. Welche davon gleich mitkommen sollen, fragt der Fragebogen bei der Erstinstallation — als Auswahl-Liste mit einem Satz je Funktion; „Nur Grundsystem" heißt: später. Das Grundsystem läuft auch ganz ohne sie: Fragst du den Bot nach etwas aus einem nicht installierten Bereich, sagt er dir freundlich, dass die Funktion fehlt, und (dir als Besitzer) mit welchem Befehl du sie nachinstallierst.

## Funktionen hinzufügen

Die Fach-Funktionen sind eigene **Pakete** (mehr dazu unter [Pakete](pakete.html)). Hast du bei der Installation „Nur Grundsystem" gewählt oder willst du später mehr, installierst du sie, wann du willst — einzeln oder mehrere auf einmal:

```bash
lifeagents package install
```

Es öffnet sich eine Auswahl-Liste (Leertaste markiert, Enter startet). Danach läuft es wie bei der Erstinstallation: **erst alle Fragen** der gewählten Pakete — zum Beispiel die Zugänge für die Job-Suche oder dein Bundesland für Fristen im Nachlass-Bereich, jeweils mit Erklärung —, dann die **Übersicht vor dem Installieren** (prüfen, einzeln ändern oder abbrechen), dann eine Zeile je Paket (✓ fertig / ✗ Problem) und zum Schluss eine Zusammenfassung. Dein Bot kennt die neue Funktion sofort; `/help` und das Telegram-Befehlsmenü passen sich automatisch an. Ein Paket lässt sich später vorübergehend ausschalten (`lifeagents package deactivate`) oder wieder entfernen (`lifeagents package uninstall`).

**Updates behalten deine Auswahl:** `lifeagents update` aktualisiert genau das Grundsystem und die Pakete, die du installiert hast — ein entferntes Paket kommt nicht zurück, ein ausgeschaltetes bleibt aus, und Einstellungen, die du selbst geändert hast, bleiben erhalten.

**Updates im Chat:** Du musst nicht selbst nach neuen Versionen schauen. Der Bot prüft alle zwei Stunden, ob es eine neue Version gibt, und meldet sich nur zwischen 10 und 20 Uhr (dein Erinnerungs-Fenster). Gibt es eine neue Version, bekommst du (nur der Owner) einmal eine Karte in deiner Sprache mit den wichtigsten Änderungen, einem Link zur vollen Liste und dem Knopf **Jetzt aktualisieren**. Tippst du darauf, startet das Update spätestens eine Minute später: Der Bot sagt Bescheid, dass er ein paar Minuten nicht erreichbar ist, sichert deine Daten, spielt die neue Version ein und meldet sich danach mit dem Ergebnis. Ohne Tippen passiert nichts, es wird nie von selbst aktualisiert. Installiert wird immer nur die neueste Version und nie eine ältere als deine. Klappt etwas nicht, erklärt die Nachricht, was passiert ist, ob dein System noch läuft und was du tun kannst (mehr dazu unter [Wenn ein Update fehlschlägt](update-hilfe.html)). Abschalten: `lifeagents config set feature update_check false`.

**Releases sind unterschrieben:** Jede neue Version wird vom Projekt digital unterschrieben. Deine Installation prüft diese Unterschrift vor jedem Update und spielt nichts ein, was nicht echt unterschrieben ist. So reicht ein gekapertes GitHub-Konto nicht aus, um fremden Code auf deinen Server zu bringen. Der Prüfschlüssel kommt einmal mit der Installation (bzw. mit dem ersten Update auf eine unterschriebene Version) und wird danach nie mehr durch ein Update ersetzt.

**Zeitzone des Haushalts:** Erinnerungen, Zeitpläne und „heute“ (zum Beispiel das Buchungsdatum, wenn du keins nennst) richten sich nach der Zeitzone **Europe/Berlin**, nicht nach der Uhr des Servers. Viele Container-Vorlagen laufen auf UTC; dort lagen Erinnerungen bisher ein bis zwei Stunden später, und kurz nach Mitternacht galt noch der Vortag. Bestehende Installationen stellen beim nächsten `lifeagents update` automatisch um. Wer woanders wohnt, setzt beim Installieren `HOUSEHOLD_TIMEZONE` (z. B. `HOUSEHOLD_TIMEZONE=Europe/Vienna` in der `--unattended`-Datei). Der Wert wird gespeichert und bleibt bei jedem Update erhalten.

**Jedes Update sichert vorher:** Wechselt ein Update die Version (eine neue Version des Projekts oder von n8n, Node.js bzw. PostgreSQL), wartet der Installer kurz laufende Agenten-Schritte ab, hält n8n an und legt eine **verschlüsselte Sicherung der ganzen Datenbank** unter `/var/backups/lifeagents/` an (die letzten zwei bleiben liegen). Erst danach wird getauscht; bei einer neuen n8n-Version stellt n8n seine Tabellen um, das kann einige Minuten dauern. Offene Bestätigungen bleiben erhalten. Bricht das Update ab, setzt ein erneutes `lifeagents update` mit derselben Sicherung fort, und `lifeagents doctor` weist darauf hin. Willst du zurück zur vorherigen Version, holt `lifeagents rollback` die Daten von vor dem Update zurück und spielt den vorherigen Stand ein (fragt vorher nach, weil alles seit der Sicherung verloren geht). Erneut dieselbe Version einspielen (z. B. `lifeagents reconfigure`) sichert nicht.

## Erreichbarkeit

Damit Telegram deinem Bot Nachrichten schicken kann, muss dein Rechner **von außen über HTTPS erreichbar** sein. Darum fragt der Fragebogen als Erstes: „Wie soll Telegram deinen Rechner erreichen?“ Es gibt zwei Wege. Den nötigen Türsteher (HTTPS-Zugang) bringt die Einrichtung selbst mit; du brauchst keine eigene Domain und keinen eigenen Reverse Proxy.

| Weg | Für wen | Was du brauchst |
|---|---|---|
| **Tunnel (Tailscale)**, empfohlen | jeden Anschluss, auch ohne eigene IPv4-Adresse (DS-Lite) | ein kostenloses Tailscale-Konto, sonst nichts |
| **FritzBox** | FritzBox mit eigener IPv4-Adresse, ohne fremdes Konto | zwei MyFRITZ!-Freigaben in der FritzBox; Port 80 und 443 müssen noch frei sein |

Ändern geht später jederzeit: `lifeagents reconfigure core` → „Weg ins Internet“. Hast du früher mit `install.sh` installiert und einen eigenen Reverse Proxy mit eigener Domain, gilt der Hinweis unter [Reverse Proxy (bestehende Installationen)](#reverse-proxy).

### Weg 1: Tunnel (empfohlen) {#tunnel}

Dein Rechner baut selbst eine verschlüsselte Verbindung zu **Tailscale** auf (genauer: Tailscale Funnel). Telegram schickt an eine öffentliche Adresse bei Tailscale (`<name>.<tailnet>.ts.net`), Tailscale reicht durch diese Verbindung weiter. Am Router stellst du nichts ein. Hintergrund, Kosten und Grenzen: [Tunnel einrichten](tunnel.html).

So läuft es:

1. Im Fragebogen bei der ersten Frage **Über einen sicheren Tunnel** wählen (vorausgewählt). Weitere Fragen zur Erreichbarkeit gibt es nicht.
2. Nach der Übersicht und der Installation kommt der Schritt „Verbinden“. Er zeigt einen **Anmelde-Link**. Öffne ihn im Browser, melde dich bei Tailscale an (oder leg dort ein Konto an) und bestätige das neue Gerät.
3. Verlangt Tailscale die Freigabe für Nachrichten von außen (Funnel), zeigt der Fragebogen auch dafür einen Link. Einmal zustimmen, dann auf **Noch einmal prüfen**.
4. Steht der Tunnel, geht es mit dem [Telegram-Schritt](#mit-telegram-verbinden) weiter. Bei einem neuen Tailscale-Konto kann es laut Tailscale bis zu 10 Minuten dauern, bis die Adresse im Internet bekannt ist.

Was der Tunnel freigibt: nur die Telegram-Pfade aus der Liste unter [Reverse Proxy](#reverse-proxy) und die [Übersicht](uebersicht-app.html), alles andere antwortet mit 404. Die n8n-Oberfläche ist von außen nicht erreichbar. Den Stand zeigen `lifeagents proxy show` und `lifeagents doctor`. Läuft die Geräte-Anmeldung bei Tailscale einmal ab, schweigt der Bot danach; im Tailscale-Konto unter *Machines* beim Gerät „Disable key expiry“ wählen, dann läuft sie nicht ab.

### Weg 2: FritzBox

Wählst du **Über meine FritzBox**, prüft die Einrichtung zuerst, ob dein Anschluss eine eigene IPv4-Adresse hat (bei DS-Lite geht dieser Weg nicht, dann bietet sie den Tunnel an; lässt sich das nicht automatisch prüfen, fragt sie nach dem Online-Monitor der FritzBox). Sind Port 80 oder 443 auf dem Rechner oder in der FritzBox schon vergeben, nimm den Tunnel: Du löschst keine fremden Freigaben. Danach zeigt der Fragebogen die Schritte für die zwei MyFRITZ!-Freigaben und nimmt die MyFRITZ!-Adresse erst an, wenn sie nachweislich auf deinen Anschluss zeigt. Den HTTPS-Zugang bringt die Einrichtung selbst mit. Die Schritte in der FritzBox stehen auf der Seite [FritzBox einrichten](fritzbox.html).

## Reverse Proxy (bestehende Installationen) {#reverse-proxy}

Die neue Einrichtung bietet keinen eigenen Reverse Proxy an: Den Türsteher bringt sie mit (Tunnel oder FritzBox-Weg). Dieser Abschnitt gilt nur für eine **bestehende Installation**, die früher mit `install.sh` und einem eigenen Reverse Proxy (zum Beispiel Caddy) eingerichtet wurde. Der Proxy ist der „Türsteher“ zwischen Internet und deinem Server: Er nimmt die verschlüsselten HTTPS-Verbindungen von Telegram an und reicht **nur** die Telegram-Pfade an n8n weiter. Die n8n-Oberfläche bleibt so privat.

- Leite **ausschließlich** diese Adress-Pfade an n8n weiter, alles andere soll der Proxy abweisen:
  - `/webhook/*`, `/webhook-waiting/*`, `/webhook-waiting-telegram`
  - `/webhook-waiting/*` und `/webhook-waiting-telegram` sind **Pflicht**: Darüber laufen die Bestätigungs-Knöpfe. Mit `/webhook-waiting-telegram` antworten die Knöpfe direkt im Chat (ein Tipp, kein Browserfenster); fehlt die Route, öffnen sie stattdessen eine Webseite. Ob alles passt, zeigt `lifeagents doctor`.
- Reiche die Header `X-Forwarded-For`, `X-Forwarded-Host` und `X-Forwarded-Proto` an n8n durch (Caddy macht das automatisch).
- Sorge für ein gültiges HTTPS-Zertifikat (zum Beispiel Let's Encrypt) auf deiner Domain.

Die fertige Konfiguration für deinen Proxy zeigt `lifeagents proxy show` (sie liegt auch in `/etc/lifeagents/reverse-proxy.caddyfile`); steht dein Proxy auf einem anderen Rechner, stellst du mit `lifeagents proxy set <IP>` um. Läuft der Bot nach einer Änderung nicht, prüft `lifeagents doctor`.

## FritzBox einrichten

Die Schritte in der FritzBox stehen auf der Seite **[FritzBox einrichten](fritzbox.html)**. Kurz: Beim Rechner mit dem Bot legst du eine **MyFRITZ!-Freigabe** an (keine normale Portfreigabe) und nimmst dessen eigene MyFRITZ!-Adresse (`<gerät>.<kennung>.myfritz.net`) als Adresse, **nicht** die Adresse der FritzBox selbst. Sonst landen Handy und Laptop über IPv6 zufällig auf einer FritzBox-Seite. Der Fragebogen prüft vorher DS-Lite und nach der Eingabe, ob die Adresse auf deinen Anschluss zeigt; `lifeagents doctor` prüft später auch Handy und Laptop und nennt dir den Handgriff. Die Adresse ist öffentlich sichtbar: Gib dem Rechner in der FritzBox einen neutralen Namen (warum, steht beim [Tunnel](tunnel.html#neutraler-name)).

## Telegram-Bot anlegen

Noch kein Bot-Token? So bekommst du eins:

1. Telegram öffnen, oben nach **@BotFather** suchen und den Chat öffnen.
2. **/newbot** senden.
3. Einen **Anzeige-Namen** wählen (frei), dann einen **Usernamen**, der auf `bot` endet (z. B. `mein_agent_bot`).
4. BotFather antwortet mit dem **Token** (Form `123456:ABC-DEF…`) — den kopierst du und gibst ihn beim Installer ein. Der Installer prüft ihn sofort gegen Telegram.

**Ein Bot gehört zu genau einem System.** Merkt der Installer, dass dein Bot schon mit einem anderen Programm oder Rechner verbunden ist, ändert er nichts, bevor du es erlaubt hast: Er fragt nach (die Start-App zeigt dafür eine eigene Seite), und ohne dein Ja bricht er ab. Mit deinem Ja wird die alte Verbindung überschrieben, und das andere System bekommt keine Nachrichten mehr. Der sichere Weg ist ein eigener, neuer Bot für diese Installation.

## Mit Telegram verbinden

Am Ende der Einrichtung verbindet der Fragebogen dich als Owner (Besitzer) mit deinem Bot, ohne dass du etwas abtippen musst:

1. **Erreichbarkeit prüfen.** Der Fragebogen wartet, bis Telegram deinen Rechner von außen erreicht: Er holt sich sein Sicherheitszertifikat, und die Adresse muss sich im Internet herumsprechen, das dauert meist ein paar Minuten. Erreicht Telegram ihn noch nicht, sagt er das; erledige, was fehlt (beim Tunnel die Anmeldung bei Tailscale, beim FritzBox-Weg die Schritte aus [FritzBox einrichten](fritzbox.html)), und wähle „Noch einmal prüfen“.
2. **QR-Code scannen.** Der Fragebogen zeigt einen QR-Code und einen Link der Form `https://t.me/<dein-bot>?start=<code>`. Scanne den Code mit dem Handy: Telegram startet den Chat mit deinem Bot und schickt den Code mit. (Alternativ öffnest du den Link auf einem Rechner mit Telegram oder tippst `/start <code>` von Hand.) Der Code steht nur im Fragebogen, nie im Chat — so kann sich niemand, der zufällig Zugriff auf den Chat hätte, selbst als Besitzer eintragen. Er gilt 10 Minuten; danach bietet der Fragebogen dir einen neuen an.
3. **Warten, fertig.** Der Fragebogen wartet, bis deine Nachricht angekommen ist (der Bot antwortet kurz „Verbunden! Einen Moment …“), und stellt den Bot dann selbst fertig auf dich ein (Befehlsmenü, Benachrichtigungen an dich). Ein zweiter Lauf ist nicht nötig.
4. **Begrüßung.** Sobald alles bereit ist, schreibt dir der Bot in Telegram: mit deinem Vornamen, welche Funktionen installiert sind, und einem Knopf **„Haushalt einrichten“** als nächstem Schritt. Kommt die Nachricht nicht, schreib ihm einfach `/start`.

Hat dein Bot noch kein Profilbild, bekommt er beim Installieren oder beim nächsten Update einmal das Zeichen des Projekts. Ein eigenes Bild bleibt unverändert. Gefällt dir das Zeichen nicht, lösch es bei @BotFather oder setz dort ein eigenes; ein gelöschtes Bild kommt nicht zurück. Für ein Update, das gar nicht erst nachsehen soll: `BOT_PROFILE_PHOTO=0` in `/etc/lifeagents/core.env`.

Hast du den Schritt übersprungen oder kommt ein neues Telegram-Konto dazu: `lifeagents household pair-owner` startet den Ablauf jederzeit neu (der Verbindungs-Link steht dann im Terminal). Fehlte für die Verbindung noch eine Angabe (z. B. die Internet-Adresse), trägst du sie mit `lifeagents reconfigure` nach — danach läuft die Verbindung von selbst an. Neuer Bot? Ebenfalls `lifeagents reconfigure`; schreib dem neuen Bot danach einmal `/start`.

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
| `lifeagents reconfigure` | Angaben nach der Installation ändern oder nachtragen — mit Auswahl-Liste: **Grundsystem** (Weg ins Internet samt Internet-Adresse, Telegram-Bot-Token, Anthropic- und Google-Schlüssel; Enter behält den bisherigen Wert) oder die Zugangsdaten eines Pakets. Danach richtet es alles neu ein, wie ein Update ohne Download. „Unverändert neu anwenden" repariert z. B. eine verlorene Telegram-Verbindung. |
| `lifeagents config …` | Zentrale Einstellungen ansehen oder ändern, z. B. welches Modell ein Agent nutzt oder ob ein Zeitplan aktiv ist. `list` zeigt je Paket alle Einstellungen mit einem Satz, was sie bewirken, und markiert selbst geänderte Werte mit `*` (sie überleben Updates); `set` zeigt diesen Satz vor der Eingabe noch einmal und prüft den neuen Wert (ein falscher Zeitplan oder eine Zahl außerhalb des erlaubten Bereichs wird mit Erklärung abgelehnt); `reset` holt den Standardwert zurück. Jede Änderung wirkt ohne Neuinstallation: ein geänderter Zeitplan sofort, z. B. `lifeagents config set schedule score_jobs '0 7 * * 1-5'` (werktags 7 Uhr), ein anderes KI-Modell beim nächsten Einsatz, z. B. `lifeagents config set model web_search claude-haiku-latest`. |
| `lifeagents proxy show` | Zeigt den Weg nach außen (Stand des Tunnels bzw. des FritzBox-Wegs). `proxy set <IP>` gibt es nur für eine ältere Installation mit eigenem Reverse Proxy (siehe [Reverse Proxy](#reverse-proxy)). |
| `lifeagents household …` | Haushaltsmitglieder einladen, verbinden, entfernen oder sperren. |
| `lifeagents backup export\|restore\|key` | Ein verschlüsseltes Backup deiner Nutzerdaten erstellen oder zurückspielen (Programm, Abläufe und Zugangsdaten stellt der Installer wieder her), optional als Datei an deinen eigenen Telegram-Chat; `key` zeigt das Notfallblatt mit dem Schlüssel. Mehr unter [Sicherung & neuer Rechner](sicherung.html). |
| `lifeagents doctor` | Prüft den Zustand der Installation, ohne etwas zu verändern (nur lesend). |
| Entfernen | Nicht über `lifeagents`: Auf dem Linux-Server `bash setup.sh --uninstall` (siehe [Entfernen](linux.html#entfernen)), mit der Start-App der Menüpunkt **Deinstallieren**. Daten werden nur nach Rückfrage gelöscht. Nur eine ältere Installation mit `install.sh` entfernt `lifeagents uninstall`. |
| `lifeagents version` | Zeigt, welche Version gerade installiert ist. |
| `lifeagents help` | Die vollständige Befehls-Referenz (je Bereich: `lifeagents <befehl> help`). |

## Etwas stimmt nicht?

Der erste Schritt bei jedem Problem ist immer derselbe: `lifeagents doctor` ausführen. Er prüft Dienste, Datenbank und Verbindungen (auch, ob Telegram deinen Server wirklich erreicht), verändert dabei nichts, und zeigt dir mit einer Ampel-Übersicht genau, welcher Teil klemmt. Ist bei der Installation etwas schiefgegangen, steht das vollständige Protokoll in `/var/log/lifeagents/install.log`.
