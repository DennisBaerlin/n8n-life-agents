---
title: "FritzBox einrichten"
---

Diese Seite führt dich Schritt für Schritt durch die FritzBox, damit dein Bot von außen erreichbar ist: für Telegram **und** für Handy und Laptop (zum Beispiel die [Übersicht](uebersicht-app.html)). Du brauchst dafür kein Technikwissen. Die Menünamen stehen hier genau so, wie die FritzBox sie zeigt (gemessen mit FRITZ!OS 8.25; ältere Versionen können leicht abweichen).

Es gibt **einen** richtigen Weg: eine **MyFRITZ!-Freigabe** für den Rechner, auf dem dein Reverse Proxy läuft. Eine normale „Portfreigabe" reicht nicht, warum, steht [weiter unten](#warum-nicht-die-adresse-der-fritzbox).

**Du nutzt die [Start-App](start-app.html) auf einem Mac oder PC?** Dann ist dieser Rechner selbst der Proxy-Rechner, und für dich gilt der eigene Abschnitt [Mit der Start-App](#start-app). Er beginnt mit zwei Prüfungen, ob der FritzBox-Weg bei dir überhaupt geht. Die folgenden Abschnitte bis dahin sind für einen eigenen Server.

## Vorher wissen

- **Welcher Rechner ist gemeint?** Immer der Rechner mit deinem **Reverse Proxy** (zum Beispiel Caddy). Läuft der Proxy auf demselben Rechner wie der Bot, ist es dieser Rechner. Läuft er in einem eigenen Container, ist es dieser Container. Im Folgenden heißt er „Proxy-Rechner".
- **Feste Adresse im Heimnetz:** Der Proxy-Rechner sollte immer dieselbe IPv4-Adresse bekommen. In der FritzBox: *Heimnetz → Netzwerk → Stift beim Gerät → „Diesem Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen"*.
- **Anschluss ohne eigene IPv4 (DS-Lite):** Manche Kabel- und Glasfaser-Anschlüsse haben keine eigene öffentliche IPv4-Adresse (Fachwort „DS-Lite"). Telegram erreicht deinen Bot dann über die FritzBox gar nicht. Frag in diesem Fall deinen Anbieter nach einer eigenen IPv4-Adresse. Ob es dich betrifft, zeigt die FritzBox unter *Internet → Online-Monitor* („DS-Lite" steht dann dort).
- **Nichts zuerst löschen.** Hast du schon Freigaben für den Proxy-Rechner (zum Beispiel für Home Assistant), lösche sie **nicht** vorab. Sonst sind Chat und andere Dienste offline, bis die neue Freigabe steht. Die Reihenfolge unten hält die Lücke bei wenigen Sekunden.

## Schritt für Schritt

1. **MyFRITZ! einschalten:** *Internet → MyFRITZ!-Konto*. Ist dort schon ein Konto angemeldet, ist nichts zu tun. Sonst die Anmeldung durchklicken, wie die FritzBox sie vorschlägt.
2. **Zu den Freigaben:** *Internet → Freigaben → Reiter „Portfreigaben"*.
3. **Den Proxy-Rechner öffnen:**
   - Steht er schon in der Liste: rechts in seiner Zeile auf den **Stift** klicken. Achtung, die Seite „Gerät für Freigaben hinzufügen" sieht fast genauso aus, ist aber für einen **neuen** Rechner gedacht. Steht dein Rechner schon in der Liste, ist sie die falsche Seite.
   - Steht er noch nicht in der Liste: „Gerät für Freigaben hinzufügen" und den Proxy-Rechner auswählen.
   - Der Stift an einer **einzelnen bestehenden Freigabe** hilft hier nicht: Dort fehlt die MyFRITZ!-Wahl. Du brauchst den Stift beim **Gerät**.
4. **Neue Freigabe anlegen:** unten „**Neue Freigabe**" klicken. Ganz oben im Fenster „**MyFRITZ!-Freigabe**" wählen, **nicht** „Portfreigabe".
5. **Anwendung „HTTP-Server"** (Port 80) auswählen, Haken bei „**Freigabe aktivieren**" setzen, „OK". Port 80 braucht dein Proxy, um sein Zertifikat zu holen, und Caddy leitet ihn nur auf HTTPS um.
   - Meldet die FritzBox „Freigabe existiert bereits", gibt es auf diesem Rechner noch eine alte Portfreigabe für Port 80. Für denselben Port erlaubt die FritzBox nicht beides. Lösche die alte (Mülleimer in ihrer Zeile) und lege die MyFRITZ!-Freigabe sofort an. Über Port 80 läuft nur die Zertifikats-Erneuerung, die kurze Lücke schadet nicht.
6. **Noch einmal „Neue Freigabe" → „MyFRITZ!-Freigabe" → Anwendung „HTTPS-Server"** (Port 443), „Freigabe aktivieren" angehakt, „OK".
   - Meldet die FritzBox „Freigabe existiert bereits", gibt es noch eine alte Portfreigabe für Port 443. Erst **jetzt** löschst du sie und legst die MyFRITZ!-Freigabe **sofort** danach an. Dazwischen ist alles hinter deinem Proxy kurz offline, Telegram liefert verpasste Nachrichten danach nach. Weil der Rechner aus Schritt 5 schon seinen eigenen Namen hat, musst du nicht zusätzlich warten.
7. **Die drei IPv6-Haken nicht anhaken:** Auf der Geräteseite stehen oberhalb der Freigaben unter „**IPv6-Einstellungen**“ Haken für **PING6**, für **delegierte Präfixe** und für **Exposed Host**. Alle drei bleiben leer. Sie öffnen mehr als nötig, Exposed Host sogar alle Ports des Rechners.
8. **Speichern:** auf der Geräteseite unten „**Übernehmen**". Die FritzBox fragt eventuell eine Bestätigung am Gerät oder per Telefon ab.
9. **Den neuen Namen ablesen:** Er steht in der Freigabe im Feld „**MyFRITZ!-Adresse**" und in der Liste beim Proxy-Rechner, zum Beispiel `meinproxy.deine-domain.myfritz.net`. Das ist deine **Internet-Adresse** für den Bot. Sie hat vorne den Namen des Rechners, die Adresse der FritzBox selbst (`deine-domain.myfritz.net`) hat ihn nicht.
10. **Eine Minute warten.** Den IPv6-Teil des Namens trägt MyFRITZ! etwa eine Minute später nach. Prüfst du sofort, kann die IPv6-Prüfung noch fehlschlagen.
11. **Im Reverse Proxy eintragen:** den neuen Namen in die Konfiguration deines Proxys schreiben. Bei Caddy steht er vor der geschweiften Klammer, mehrere Namen trennst du mit Komma: `deine-domain.myfritz.net, meinproxy.deine-domain.myfritz.net {`. Dann `sudo systemctl reload caddy`. Caddy holt das Zertifikat für den neuen Namen selbst.

Den alten Namen (die Adresse der FritzBox) darfst du im Caddyfile behalten, zum Beispiel wenn Home Assistant oder Google Home ihn noch nutzen. Für den Bot nimmst du nur noch den neuen.

## Neu installieren

Gib dem Installer bei der Frage nach der **Internet-Adresse** den neuen Namen aus Schritt 9 an. Du kannst ihn auch als ganze Adresse einfügen (`https://meinproxy.deine-domain.myfritz.net/`), der Installer macht daraus selbst den Namen.

## Schon installiert? So stellst du um

1. Die Schritte oben durchgehen, bis du den neuen Namen hast und er im Reverse Proxy steht (Schritt 1 bis 11).
2. Auf dem Server `sudo lifeagents reconfigure core` ausführen, „Angaben ändern …" wählen, dann „**Internet-Adresse**", den neuen Namen eintragen und „**Fertig — speichern und anwenden**". Die anderen Angaben fragt der Befehl dabei nicht ab.
3. Der Befehl richtet alles neu ein. Der Chat und der Knopf „📊 Übersicht" ziehen automatisch mit um. Am Ende prüft er, ob Handy und Laptop unter dem neuen Namen ankommen (siehe unten).

## So sieht es richtig aus

- In der FritzBox stehen beim Proxy-Rechner zwei **MyFRITZ!-Freigaben**: „HTTP-Server" (Port 80) und „HTTPS-Server" (Port 443). Darüber steht sein eigener Name `<gerät>.<kennung>.myfritz.net`.
- Eine alte „Portfreigabe" für Port 443 auf diesen Rechner gibt es nicht mehr.
- Der Installer zeigt am Ende „**Erreichbarkeit für Handy und Laptop prüfen ✓ (IPv4 + IPv6)**".
- `lifeagents doctor` meldet „**Übersicht (Mini-App) lädt über … (IPv4 + IPv6)**".
- Die Übersicht öffnet sich auf dem Handy im WLAN **und** unterwegs (mobile Daten), immer dieselbe Seite, nie eine FritzBox-Seite.

## Was der Installer prüft

Nach der Telegram-Prüfung schaut der Installer, ob auch Handy und Laptop bei deinem Server ankommen. Er zeigt je Punkt ein Zeichen:

| Zeichen | Bedeutung |
|---|---|
| ✓ | in Ordnung |
| ✗ | hier ist etwas zu tun, darunter steht genau ein Handgriff |
| – | von diesem Server aus nicht prüfbar, kein Fehler |

Geprüft wird:

1. **IPv4:** Antwortet unter deinem Namen dein Reverse Proxy? Klappt das vom Server aus nicht, obwohl Telegram ankommt, leitet dein Router Anfragen aus dem Heimnetz nicht an die eigene Adresse zurück. Das ist harmlos und erscheint als „–".
2. **IPv6:** Landet IPv6 bei deinem Proxy? Hat der Name gar keinen IPv6-Eintrag, ist das auch in Ordnung, dann nehmen alle Geräte IPv4. Antwortet über IPv6 die FritzBox, zeigt der Installer den Handgriff „MyFRITZ!-Freigabe" von dieser Seite.
3. **Zertifikat:** Passt das HTTPS-Zertifikat zum Namen?

Bei einem ✗ wählst du „**Erneut prüfen**", sobald du die Einstellung geändert hast, oder „**Später**". Die Installation hält dafür nie an, der Chat funktioniert ohnehin. Bei einem normalen Update zeigt der Installer nur den Befund, ohne Rückfrage. `lifeagents doctor` prüft dasselbe jederzeit.

## Warum nicht die Adresse der FritzBox?

Die MyFRITZ!-Adresse der FritzBox (`deine-domain.myfritz.net`) zeigt über IPv6 auf die **FritzBox selbst**. Telegram stellt Nachrichten nur über IPv4 zu, dort fällt das nie auf. Handy und Laptop nehmen aber oft IPv6. Dann erscheint zufällig eine FritzBox-Seite statt deines Servers: im Heimnetz „Die angegebene URL ist nicht verfügbar", unterwegs die Anmeldung zum Fernzugang der FritzBox. Auch die Zertifikats-Erneuerung kann daran scheitern, denn Let's Encrypt fragt zuerst über IPv6 an ([Let's Encrypt zu IPv6](https://letsencrypt.org/docs/ipv6-support/)).

Erst die **MyFRITZ!-Freigabe** legt für den Proxy-Rechner einen eigenen Namen an, der über IPv4 auf deinen Anschluss und über IPv6 direkt auf den Proxy-Rechner zeigt. Eine normale Portfreigabe öffnet zwar Ports, legt aber keinen solchen Namen an. Eine andere Port-Nummer für den Fernzugang der FritzBox hilft auch nicht: Im Heimnetz antwortet die Box auf ihrer eigenen Adresse immer selbst. Dein Fernzugang zur FritzBox bleibt mit dem neuen Weg, wie er ist.

## Mit der Start-App (Mac oder PC) {#start-app}

Dieser Abschnitt ist für dich, wenn du den Bot mit der [Start-App](start-app.html) auf einem Mac oder PC betreibst und in der App bei der Frage „Wie soll Telegram deinen Rechner erreichen?“ die **FritzBox** wählst. Der Rechner mit der App ist dann zugleich der Proxy-Rechner: Die App bringt ihren Türsteher (Reverse Proxy) selbst mit und holt auch das Zertifikat selbst. Du richtest nur die FritzBox ein. Im Folgenden steht „Mac“; für einen Windows-PC gilt dasselbe.

{{< schema name="weg-fritzbox" caption="Eigene Schema-Zeichnung: Telegram schickt über das Internet an deine FritzBox, zwei MyFRITZ!-Freigaben für Port 80 und 443 leiten weiter zum Mac mit fester Adresse im Heimnetz. Dort lässt ein Türsteher nur die Telegram-Wege zum Bot durch." >}}

**Die Regel für diesen Weg: Du löschst nichts.** Ist in der FritzBox schon etwas für Port 80 oder 443 eingerichtet, gehört das zu einem anderen Gerät oder Programm, zum Beispiel Home Assistant. Löschst du es, ist dieses offline. Nimm in diesem Fall den [Tunnel](tunnel.html), er braucht keine Freigabe.

### Zuerst prüfen: Geht der FritzBox-Weg bei dir?

{{< schema name="fritzbox-entscheidung" caption="Eigene Schema-Zeichnung: Steht im Online-Monitor „DS-Lite“, nimm den Tunnel. Sind Port 80 oder 443 schon vergeben, nimm ebenfalls den Tunnel. Nur wenn beides nein ist, richtest du die FritzBox-Freigaben ein." >}}

Öffne die Oberfläche deiner FritzBox im Browser (meist `http://fritz.box`) und melde dich an.

1. **Hat dein Anschluss eine eigene IPv4-Adresse?** *Internet → Online-Monitor*.

   *Erwartet:* Bei IPv4 steht eine Adresse, und nirgends steht „DS-Lite“.
   - Steht dort „DS-Lite“, erreicht Telegram deinen Mac über die FritzBox nicht, denn Telegram stellt nur über IPv4 zu. Nimm den [Tunnel](tunnel.html).
   - Dasselbe gilt, wenn die IPv4-Adresse mit `100.` beginnt und die zweite Zahl zwischen 64 und 127 liegt: Dann teilst du dir die Adresse mit anderen Kunden deines Anbieters.
2. **Sind Port 80 und 443 noch frei?** *Internet → Freigaben → Reiter „Portfreigaben“*.

   *Erwartet:* Bei keinem Gerät in der Liste steht eine Freigabe „HTTP-Server“, „HTTPS-Server“, Port 80 oder Port 443.
   - Steht dort schon eine, ist der Port vergeben. **Nicht löschen**, nimm den [Tunnel](tunnel.html).
   - Auch auf dem Mac selbst müssen die beiden Ports frei sein. Das prüft die App; sind sie dort belegt, sagt sie es dir und empfiehlt den Tunnel.

### Einrichten

1. **Den Mac im Heimnetz festmachen:** *Heimnetz → Netzwerk → Stift beim Mac*. Deinen Mac erkennst du am Namen, den er unter *Systemeinstellungen → Allgemein → Info* zeigt.
   - Trag bei „**Name**“ einen neutralen Namen ein, zum Beispiel `heimserver`. Er wird Teil der Internet-Adresse, und die ist öffentlich sichtbar (warum, steht beim [Tunnel](tunnel.html#neutraler-name)). Ein Name wie „MacBook von …“ verrät sonst deinen Vornamen.
   - Setz den Haken bei „**Diesem Netzwerkgerät immer die gleiche IPv4-Adresse zuweisen**“ und klick „**Übernehmen**“.
   - *Erwartet:* In der Liste steht der Mac unter dem neuen Namen, mit derselben Adresse wie vorher.
   - Am zuverlässigsten hängt der Mac per **Netzwerkkabel** an der FritzBox. Im WLAN wechselt ein Mac sonst unter Umständen seine Geräte-Kennung und erscheint der FritzBox als neues Gerät. **Wird geprüft:** welche WLAN-Einstellung des Macs das verhindert.
2. **MyFRITZ! einschalten:** *Internet → MyFRITZ!-Konto*. Ist dort schon ein Konto angemeldet, ist nichts zu tun. Sonst die Anmeldung durchklicken, wie die FritzBox sie vorschlägt.

   *Erwartet:* Die Seite zeigt ein angemeldetes MyFRITZ!-Konto.
3. **Den Mac für Freigaben öffnen:** *Internet → Freigaben → Reiter „Portfreigaben“*. Unten „**Gerät für Freigaben hinzufügen**“ klicken und den Mac auswählen. Steht der Mac schon in der Liste, klick stattdessen rechts in seiner Zeile auf den **Stift**.

   *Erwartet:* Eine Seite mit dem Namen des Macs oben und dem Knopf „Neue Freigabe“ unten.
4. **Freigabe für Port 80:** „**Neue Freigabe**“ klicken, ganz oben „**MyFRITZ!-Freigabe**“ wählen (**nicht** „Portfreigabe“), als Anwendung „**HTTP-Server**“, Haken bei „**Freigabe aktivieren**“, „**OK**“. Über Port 80 holt die App ihr Zertifikat.

   *Erwartet:* Die Freigabe „HTTP-Server“ steht in der Liste des Macs.
   - Meldet die FritzBox, dass die Freigabe schon existiert oder der Port vergeben ist: „Abbrechen“, nichts löschen, und den [Tunnel](tunnel.html) nehmen.
5. **Freigabe für Port 443:** noch einmal „**Neue Freigabe**“ → „**MyFRITZ!-Freigabe**“ → Anwendung „**HTTPS-Server**“, „**Freigabe aktivieren**“ angehakt, „**OK**“. Über Port 443 kommen die Nachrichten von Telegram.

   *Erwartet:* Jetzt stehen „HTTP-Server“ und „HTTPS-Server“ in der Liste. Bei einer Meldung wie in Schritt 4 gilt dasselbe: abbrechen, Tunnel.
6. **Die drei IPv6-Haken leer lassen und speichern:** Unter „**IPv6-Einstellungen**“ bleiben **PING6**, **delegierte Präfixe** und **Exposed Host** ohne Haken. Dann unten „**Übernehmen**“. Die FritzBox fragt eventuell eine Bestätigung am Gerät oder per Telefon ab.

   *Erwartet:* In der Liste der Portfreigaben steht der Mac mit zwei MyFRITZ!-Freigaben.
7. **Die Adresse ablesen und in die App eintragen:** Die Adresse steht in der Freigabe im Feld „**MyFRITZ!-Adresse**“, zum Beispiel `heimserver.deine-domain.myfritz.net`. Vorne steht der Name aus Schritt 1. Warte eine Minute, denn den IPv6-Teil trägt MyFRITZ! etwas später nach. Dann trag die Adresse in der App ein.

   *Erwartet:* Die App nimmt die Adresse an und prüft die Verbindung. Ein Caddyfile oder einen anderen Eintrag brauchst du auf diesem Weg nicht.

### Prüfen, ob es klappt

- Die App prüft, ob Telegram deinen Mac erreicht und ob Handy und Laptop über IPv4 und IPv6 bei ihm ankommen. Das sind dieselben Punkte wie unter [Was der Installer prüft](#was-der-installer-prüft). Zeigt sie ein Problem, nennt sie den Handgriff; danach „Erneut prüfen“. Die genauen Texte der App folgen mit ihrer ersten Version.
- Nach dem Verbinden mit Telegram: Schalt am Handy das WLAN aus und schreib dem Bot über mobile Daten. Er antwortet. Auch die [Übersicht](uebersicht-app.html) öffnet sich dann im WLAN und unterwegs, nie eine FritzBox-Seite.

### Rückgängig machen

1. *Internet → Freigaben → Reiter „Portfreigaben“ → Stift beim Mac*.
2. Bei den beiden Freigaben „**HTTP-Server**“ und „**HTTPS-Server**“, die du in Schritt 4 und 5 angelegt hast, auf den **Mülleimer** klicken. Andere Freigaben nicht anfassen. Dann „**Übernehmen**“.
3. *Erwartet:* Beim Mac stehen keine Freigaben mehr. Die feste Adresse und der Name aus Schritt 1 schaden nicht und dürfen bleiben.
4. In der App auf den Tunnel umstellen oder die App über **Deinstallieren** entfernen (siehe [Start-App → Entfernen](start-app.html#entfernen)). Ohne diesen Schritt erreicht Telegram deinen Bot nicht mehr.

## Andere Router

Für jeden anderen Router gilt dieselbe Regel, nur mit anderen Menüs:

- Der Name zeigt über IPv4 (A-Eintrag) auf deinen Anschluss, und Port 443 (und 80) ist auf den Proxy-Rechner weitergeleitet.
- Hat der Name einen IPv6-Eintrag (AAAA), muss er auf den **Proxy-Rechner** zeigen, und die IPv6-Firewall des Routers muss Port 443 (und 80) zu ihm durchlassen. Sonst den IPv6-Eintrag beim DynDNS-Dienst **weglassen**.
- Ob es passt, zeigen der Installer am Ende und `lifeagents doctor`.
