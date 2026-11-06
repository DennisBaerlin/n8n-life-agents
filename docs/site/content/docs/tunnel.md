---
title: "Tunnel einrichten (empfohlen)"
---

Mit der [Start-App](start-app.html) erreicht Telegram deinen Rechner am einfachsten über einen **Tunnel**. Dein Rechner baut dabei selbst eine verschlüsselte Verbindung nach außen zu einem Dienst namens **Tailscale** auf (genauer: Tailscale Funnel). Telegram schickt deine Nachrichten an eine öffentliche Adresse bei Tailscale, und Tailscale reicht sie durch diese Verbindung an deinen Rechner weiter. An deiner FritzBox oder deinem Router änderst du nichts, und es klappt auch bei Anschlüssen ohne eigene IPv4-Adresse (DS-Lite).

{{< schema name="weg-tunnel" caption="Eigene Schema-Zeichnung: Telegram schickt an die öffentliche Tailscale-Adresse, von dort geht es durch den Tunnel und durch den unveränderten Router zum Mac. Dort lässt ein Türsteher nur die Telegram-Wege zum Bot durch." >}}

**Stand:** Der Tunnel-Weg ist noch im Bau. Bevor die App ihn anbietet, prüfen wir ihn mit einem Test-Bot. Wo hier „wird geprüft“ steht, ist das Ergebnis noch offen.

## Was du brauchst

- Die [Start-App](start-app.html), die bis zur Frage nach dem Weg ins Internet gekommen ist.
- Ein **Tailscale-Konto**. Tailscale hat keine eigenen Passwörter: Du meldest dich mit einem Konto an, das du schon hast, zum Beispiel bei Google, Microsoft oder Apple. Das legst du im nächsten Schritt an, falls du noch keins hast.

## Schritt für Schritt

1. **Tunnel wählen:** In der App bei der Frage nach dem Weg ins Internet **Tunnel (empfohlen)** wählen.

   *Erwartet:* Nach wenigen Sekunden zeigt die App einen Knopf zum Anmelden bei Tailscale.
2. **Anmelden:** Auf den Knopf klicken. Dein Browser öffnet die Anmeldeseite von Tailscale. Melde dich an oder leg dort ein Konto an.

   *Erwartet:* Tailscale fragt, ob du das neue Gerät mit deinem Konto verbinden willst. Bestätige das.
3. **Öffentliche Adresse erlauben:** Tailscale verlangt, dass du öffentliche Adressen (Funnel) und Zertifikate (HTTPS) für dein Konto erlaubst. Dabei weist Tailscale darauf hin, dass Rechnernamen öffentlich sichtbar werden. Das ist normal; warum dich das nicht stört, steht [unten](#neutraler-name).
   **Wird geprüft:** ob die App dich dafür direkt auf die richtige Seite bei Tailscale führt oder ob es von selbst klappt. Hier steht danach der genaue Weg.
4. **Zurück zur App:** Die App vergibt deinem Rechner bei Tailscale einen neutralen Namen und zeigt dir die neue Adresse. Sie endet auf `.ts.net`.

   *Erwartet:* Die App prüft, ob Telegram deinen Bot über diese Adresse erreicht. Bei einem neuen Konto kann es laut [Tailscale](https://tailscale.com/kb/1223/funnel) bis zu 10 Minuten dauern, bis die Adresse im Internet bekannt ist. Prüf in diesem Fall nach ein paar Minuten noch einmal.

Danach geht es in der App mit der Übersicht weiter. Die Adresse brauchst du dir nicht zu merken.

## Ein neutraler Name {#neutraler-name}

Für die verschlüsselte Verbindung bekommt jede Adresse ein Zertifikat. Zertifikate werden in öffentliche Protokolle eingetragen, die jeder durchsuchen kann. Tailscale schreibt dazu selbst, dass Rechnernamen und der Name deines Tailscale-Netzes öffentlich werden ([Tailscale zu HTTPS](https://tailscale.com/kb/1153/enabling-https)).

Darum gibt die App deinem Rechner bei Tailscale einen neutralen Namen, in dem weder dein Name noch dein Wohnort steht. Den Namen deines Tailscale-Netzes (der zweite Teil der Adresse) vergibt Tailscale zufällig. Änderst du ihn in deinem Tailscale-Konto, wähl nichts Persönliches. Dasselbe gilt für den [FritzBox-Weg](fritzbox.html#start-app).

## Was der Tunnel kostet

- Das Paket **Personal** von Tailscale kostet nichts, für bis zu 6 Nutzer und beliebig viele Geräte ([Tailscale-Preise](https://tailscale.com/pricing)).
- Funnel, also die öffentliche Adresse, gibt es laut Tailscale in allen Paketen ([Tailscale Funnel](https://tailscale.com/kb/1223/funnel)).
- Tailscale begrenzt die Datenmenge über Funnel, nennt aber keine Zahl. Durch den Tunnel laufen nur Telegrams kurze Benachrichtigungen und die [Übersicht](uebersicht-app.html); Fotos und Dateien holt der Bot selbst bei Telegram ab.

**Wird geprüft:** ob das kostenlose Paket den Dauerbetrieb ohne Einschränkung abdeckt. Bis dahin ist das eine Annahme.

## Grenzen

- **Du brauchst ein Konto bei Tailscale**, und Tailscale sieht, dass Verbindungen zu deinem Rechner laufen. Die Verschlüsselung endet erst auf deinem Rechner.
- **Fällt Tailscale aus**, erreicht Telegram deinen Bot so lange nicht. Telegram stellt verpasste Nachrichten danach eine Zeit lang nach.
- **Dein Rechner muss laufen**, sonst antwortet niemand (siehe [Dauerbetrieb](start-app.html#dauerbetrieb)).
- **Nur die Telegram-Wege gehen durch.** Die Verwaltungsoberfläche bleibt zu. **Wird geprüft:** dass sie auch aus deinem Tailscale-Netz heraus gesperrt ist.
- **Wird geprüft:** Tailscale lässt die Anmeldung eines Geräts nach einiger Zeit ablaufen. Ob die App das für deinen Rechner abschaltet oder dich rechtzeitig erinnert, steht nach dem Test hier.
- **Läuft Tailscale schon auf deinem Rechner**, bringt die App trotzdem ihren eigenen Tunnel-Teil mit; dein vorhandenes Tailscale bleibt, wie es ist. **Wird geprüft:** dass sich beide nicht stören.

## Rückgängig machen

- **Ganz entfernen:** In der App **Deinstallieren** wählen (siehe [Entfernen](start-app.html#entfernen)). Danach in deinem Tailscale-Konto in der Geräteliste den Rechner entfernen. Dein Tailscale-Konto selbst bleibt, bis du es dort löschst.
- **Zur FritzBox wechseln:** Den Weg ins Internet stellst du in der App um. **Wird geprüft:** wo die App diesen Punkt anbietet.
