---
title: "Tunnel einrichten (empfohlen)"
---

Mit der [Start-App](start-app.html) erreicht Telegram deinen Rechner am einfachsten über einen **Tunnel**. Dein Rechner baut dabei selbst eine verschlüsselte Verbindung nach außen zu einem Dienst namens **Tailscale** auf (genauer: Tailscale Funnel). Telegram schickt deine Nachrichten an eine öffentliche Adresse bei Tailscale, und Tailscale reicht sie durch diese Verbindung an deinen Rechner weiter. An deiner FritzBox oder deinem Router änderst du nichts, und der Weg ist auch bei Anschlüssen ohne eigene IPv4-Adresse (DS-Lite) möglich.

{{< explain name="reach-tunnel" width="280" height="560" alt="Deine Nachricht geht vom Handy über Telegram und einen Tunnel durch deinen Router zu deinem Rechner zu Hause." >}}

**Du installierst per Befehl auf einem eigenen Server (Debian, LXC)?** Dann bietet dir der Installer denselben Tunnel als ersten Weg an; der Ablauf steht unter [Installation → Weg 1: Tunnel](installation.html#tunnel). Kosten, der neutrale Name und die Grenzen unten gelten genauso.

## Was du brauchst

- Die [Start-App](start-app.html), die bis zur Frage „Wie soll Telegram deinen Rechner erreichen?“ gekommen ist.
- Ein **Tailscale-Konto**. Tailscale hat keine eigenen Passwörter: Du meldest dich mit einem Konto an, das du schon hast, zum Beispiel bei Google, Microsoft oder Apple. Das legst du im nächsten Schritt an, falls du noch keins hast.

## Schritt für Schritt

1. **Tunnel wählen:** In der App bei der Frage „Wie soll Telegram deinen Rechner erreichen?“ **Über einen sicheren Tunnel** wählen. Diese Wahl ist schon vorausgewählt.

   *Erwartet:* Die App fragt die restlichen Angaben ab und installiert. Die Anmeldung bei Tailscale kommt erst danach, im Schritt „Verbinden“.
2. **Anmelden:** Im Schritt „Verbinden“ zeigt die App „Melde dich bei Tailscale an“. Klick auf **Tailscale-Anmeldung öffnen**. Dein Browser öffnet die Anmeldeseite von Tailscale. Melde dich an oder leg dort ein Konto an.

   *Erwartet:* Tailscale fragt, ob du das neue Gerät mit deinem Konto verbinden willst. Bestätige das.
3. **Empfang erlauben:** Die App zeigt „Erlaube deinem Rechner den Empfang“. Klick auf **Freigabe-Seite öffnen**. Für eine öffentliche Adresse verlangt Tailscale, dass in deinem Konto Zertifikate (HTTPS) und Funnel erlaubt sind ([Tailscale Funnel](https://tailscale.com/kb/1223/funnel)). Stimme auf dieser Seite zu. Dabei weist Tailscale darauf hin, dass Rechnernamen öffentlich sichtbar werden. Das ist normal; warum dich das nicht stört, steht [unten](#neutraler-name).
4. **Zurück zur App:** Die App gibt deinem Rechner bei Tailscale einen neutralen Namen. Seine öffentliche Adresse endet auf `.ts.net`.

   *Erwartet:* Die App prüft, ob Telegram deinen Bot über diese Adresse erreicht. Bei einem neuen Konto kann es laut Tailscale bis zu 10 Minuten dauern, bis die Adresse im Internet bekannt ist. Kommt Telegram nicht durch, warte ein paar Minuten und klick auf **Noch einmal prüfen**.

Die Adresse brauchst du dir nicht zu merken.

## Ein neutraler Name {#neutraler-name}

Für die verschlüsselte Verbindung bekommt jede Adresse ein Zertifikat. Zertifikate werden in öffentliche Protokolle eingetragen, die jeder durchsuchen kann. Tailscale schreibt dazu selbst, dass Rechnernamen und der Name deines Tailscale-Netzes öffentlich werden ([Tailscale zu HTTPS](https://tailscale.com/kb/1153/enabling-https)).

Darum gibt die App deinem Rechner bei Tailscale einen neutralen Namen, in dem weder dein Name noch dein Wohnort steht. Den Namen deines Tailscale-Netzes (der zweite Teil der Adresse) vergibt Tailscale zufällig. Änderst du ihn in deinem Tailscale-Konto, wähl nichts Persönliches. Dasselbe gilt für den [FritzBox-Weg](fritzbox.html#start-app).

## Was der Tunnel kostet

- Das Paket **Personal** von Tailscale kostet nichts, für bis zu 6 Nutzer und beliebig viele Geräte ([Tailscale-Preise](https://tailscale.com/pricing)).
- Funnel, also die öffentliche Adresse, gibt es laut Tailscale in allen Paketen ([Tailscale Funnel](https://tailscale.com/kb/1223/funnel)).
- Tailscale begrenzt die Datenmenge über Funnel und nennt dafür keine Zahl.

Preise und Bedingungen legt Tailscale fest und kann sie ändern. Maßgeblich sind die verlinkten Seiten.

## Grenzen

- **Du brauchst ein Konto bei Tailscale**, und Tailscale sieht, dass Verbindungen zu deinem Rechner laufen.
- **Fällt Tailscale aus**, erreicht Telegram deinen Bot so lange nicht.
- **Dein Rechner muss laufen**, sonst antwortet niemand (siehe [Dauerbetrieb](start-app.html#dauerbetrieb)).
- **Nur die Telegram-Wege und die Übersicht sind von außen erreichbar.** Den Rest, etwa die Verwaltungsoberfläche, lässt der Türsteher der App nicht durch.

## Rückgängig machen

In der App **Deinstallieren** wählen (siehe [Entfernen](start-app.html#entfernen)). Danach in deinem Tailscale-Konto in der Geräteliste den Rechner entfernen. Dein Tailscale-Konto selbst bleibt, bis du es dort löschst.
