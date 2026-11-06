---
title: "Tunnel einrichten (empfohlen)"
---

Mit der [Start-App](start-app.html) erreicht Telegram deinen Rechner am einfachsten über einen **Tunnel**. Dein Rechner baut dabei selbst eine verschlüsselte Verbindung nach außen zu einem Dienst namens **Tailscale** auf (genauer: Tailscale Funnel). Telegram schickt deine Nachrichten an eine öffentliche Adresse bei Tailscale, und Tailscale reicht sie durch diese Verbindung an deinen Rechner weiter. An deiner FritzBox oder deinem Router änderst du nichts, und der Weg ist auch bei Anschlüssen ohne eigene IPv4-Adresse (DS-Lite) möglich.

{{< schema name="weg-tunnel" caption="Eigene Schema-Zeichnung: Telegram schickt an die öffentliche Tailscale-Adresse, von dort geht es durch den Tunnel und durch den unveränderten Router zum Mac. Dort lässt ein Türsteher nur die Telegram-Wege zum Bot durch." >}}

## Was du brauchst

- Die [Start-App](start-app.html), die bis zur Frage „Wie soll Telegram deinen Rechner erreichen?“ gekommen ist.
- Ein **Tailscale-Konto**. Tailscale hat keine eigenen Passwörter: Du meldest dich mit einem Konto an, das du schon hast, zum Beispiel bei Google, Microsoft oder Apple. Das legst du im nächsten Schritt an, falls du noch keins hast.

## Schritt für Schritt

1. **Tunnel wählen:** In der App bei der Frage „Wie soll Telegram deinen Rechner erreichen?“ **Über einen sicheren Tunnel** wählen.

   *Erwartet:* Nach wenigen Sekunden zeigt die App einen Knopf zum Anmelden bei Tailscale.
2. **Anmelden:** Auf den Knopf klicken. Dein Browser öffnet die Anmeldeseite von Tailscale. Melde dich an oder leg dort ein Konto an.

   *Erwartet:* Tailscale fragt, ob du das neue Gerät mit deinem Konto verbinden willst. Bestätige das.
3. **Öffentliche Adresse erlauben:** Für eine öffentliche Adresse verlangt Tailscale, dass in deinem Konto Zertifikate (HTTPS) und Funnel erlaubt sind ([Tailscale Funnel](https://tailscale.com/kb/1223/funnel)). Fragt Tailscale dich danach, stimme zu. Dabei weist Tailscale darauf hin, dass Rechnernamen öffentlich sichtbar werden. Das ist normal; warum dich das nicht stört, steht [unten](#neutraler-name).
4. **Zurück zur App:** Die App vergibt deinem Rechner bei Tailscale einen neutralen Namen und zeigt dir die neue Adresse. Sie endet auf `.ts.net`.

   *Erwartet:* Die App prüft, ob Telegram deinen Bot über diese Adresse erreicht. Bei einem neuen Konto kann es laut Tailscale bis zu 10 Minuten dauern, bis die Adresse im Internet bekannt ist. Prüf in diesem Fall nach ein paar Minuten noch einmal.

Danach geht es in der App mit der Übersicht weiter. Die Adresse brauchst du dir nicht zu merken.

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

- **Ganz entfernen:** In der App **Deinstallieren** wählen (siehe [Entfernen](start-app.html#entfernen)). Danach in deinem Tailscale-Konto in der Geräteliste den Rechner entfernen. Dein Tailscale-Konto selbst bleibt, bis du es dort löschst.
- **Zur FritzBox wechseln:** Den Weg ins Internet stellst du in der App um und richtest dann die [FritzBox](fritzbox.html#start-app) ein.
