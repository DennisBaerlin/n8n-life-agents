---
title: "Karriere-Coach"
---

Der Karriere-Coach (`agent.career_advisor`) begleitet einen geplanten Jobwechsel: er führt ein Karriere-Profil (Lebenslauf-Daten), erarbeitet mit dir einen Karriereplan, sucht werktäglich passende Stellenanzeigen, zeigt dir, welche Fähigkeiten dir für deine Zielrolle noch fehlen, ordnet Gehalt und Arbeitsmarkt ein und rechnet dir aus, ob du dir den Wechsel finanziell leisten kannst. Er berät nur — er bewirbt sich nicht für dich und trackt keine laufenden Bewerbungen, das ist (Stand heute) nicht Teil des Systems.

## Profil per Lebenslauf-Foto

Schickst du ein Foto oder PDF deines Lebenslaufs, liest der Coach die Angaben automatisch aus (aktuelle Rolle, Branche, Berufserfahrung, Fähigkeiten) — über ein bezahltes KI-Modell, das deine Daten nicht zu Trainingszwecken weiterverwendet. Das Ergebnis ist ein **Vorschlag**, keine automatische Speicherung: der Coach spielt dir die erkannten Angaben im Chat zurück, du korrigierst was nicht stimmt, und erst nach deinem OK werden die Fakten übernommen. Genauso kannst du dein Profil auch einfach im Gespräch erzählen, Stück für Stück.

## Karriereplan — Entwurf, dann Veröffentlichen

Der Plan entsteht nach demselben Prinzip wie der [Finanzplan](finanzberater.html): der Coach interviewt dich abschnittsweise (aktuelle Situation, Zielrolle(n) samt benötigter Fähigkeiten, Übergangsplan mit Meilensteinen), fasst jeden Abschnitt zum Gegenlesen zusammen und veröffentlicht erst nach deiner Bestätigung — das ist dein gültiger, gespeicherter Karriereplan, aus dem sich Skill-Lücken, Markttrend und Runway-Zahl automatisch speisen. Ein späterer Interview-Durchgang aktualisiert ihn.

## Stellen-Scan mit Bewertung (opt-in)

Auf Wunsch durchsucht der Coach werktags vormittags mehrere Jobbörsen nach deinen Zielorten — die Jobbörse der Bundesagentur für Arbeit immer (kostenlos, ohne Schlüssel), dazu optional Adzuna (bringt zuverlässig auch StepStone-Stellen mit) und JSearch (bringt LinkedIn-Stellen stark). Die beiden optionalen Quellen brauchen je einen kostenlosen API-Schlüssel, den die Installation abfragt (Adzuna braucht App-ID und App-Key zusammen — lässt du die ID leer, fragt der Installer den Key gar nicht erst) — übersprungen läuft der Scan einfach nur über die Bundesagentur, nachtragen geht jederzeit per `lifeagents package reconfigure career`. Er schickt dir nur Treffer, die zu deinem Profil passen — dazu eine bewusst breitere Wahl "über den Tellerrand". Zu jedem Treffer gibt es 👍/👎-Knöpfe. Bewertest du eine Stelle mit Begründung ("zu viel Reisetätigkeit", "genau mein Bereich"), merkt sich der Coach diese Vorliebe und trifft künftig treffsicherere Auswahl. Der Scan ist standardmäßig ausgeschaltet und gilt für jede Person einzeln: Jede Person schaltet ihre eigenen Job-Vorschläge per Knopf an der Karte oder in `/reminders` an oder aus, ohne die der anderen zu berühren.

```
🎯 Neuer Treffer (Score 4/4)

Scrum Master (m/w/d)
Beispielsoft GmbH · Hamburg
Vollzeit · Homeoffice-Anteil möglich

👍  👎
```

## Wo fehlen dir noch Fähigkeiten?

Für jede Zielrolle in deinem Plan vergleicht das System automatisch, welche Fähigkeiten die Rolle braucht (die du beim Planen hinterlegst) mit den Fähigkeiten in deinem Profil — nicht der Coach persönlich, sondern eine feste Berechnung in der Datenbank, damit das Ergebnis immer stimmt. Fehlende, zu schwach ausgeprägte oder überschüssige Fähigkeiten erscheinen als Zeile im veröffentlichten Plan; dein Übergangsplan-Abschnitt beschreibt dann, wie du die Lücke schließt.

## Marktlage einschätzen

Drei Blickwinkel: wie stark die Nachfrage nach deiner Zielrolle in deiner Region ist (ein wöchentlich aktualisierter Zähler offener Stellen, im Plan sichtbar), was die Rolle typischerweise verdient (auf Nachfrage per Web-Recherche mit Quellenangabe, weil die offizielle Gehaltsdatenbank keinen automatisierten Zugriff erlaubt), und wie es um einen konkreten Arbeitgeber steht (Kurzarbeit, Stellenabbau, Wachstum — ebenfalls per Web-Recherche, nur zu öffentlichen Firmennamen, nie in Kombination mit deinen persönlichen Daten).

## "Kann ich mir den Wechsel leisten?"

Die sogenannte Runway-Frage: wie viele Monate trägt dein Geldpolster, falls die neue Stelle in der Probezeit endet? Dafür liest der Coach — rein lesend — deinen aktuellen Kontostand und deine monatlichen Ausgaben beim [Buchhalter](buchhalter.html) und rechnet die Dauer deiner Probezeit dagegen. Das Ergebnis erscheint als Zeile im Plan. Ist das Finanzpaket nicht eingerichtet, sagt der Coach das offen statt zu raten.

## Jede Person im Haushalt hat ihr eigenes Profil

Profil, Karriereplan und gelernte Vorlieben gehören **einer Person**, nicht dem Haushalt — jeder, der beim System angemeldet ist, bekommt seinen eigenen Stand, den nur er selbst bearbeiten darf. Profil und Job-Vorlieben bestätigt jede Person selbst; der Owner bekommt dafür keine Nachricht und muss nichts freigeben. Einen Karriereplan veröffentlichen kann nur der Owner. Bevor der Coach berät, führt er dich einmalig durch ein kurzes Onboarding (Grundangaben, Fähigkeiten, Ziele); danach ist er einsatzbereit.

Jeder Schreibvorgang läuft — wie überall im System — über eine [Bestätigung per Knopf](chatten-bestaetigen.html), bevor etwas dauerhaft gespeichert wird.
