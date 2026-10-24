---
title: "Pakete & Erweiterbarkeit"
---

Der Assistent ist nicht ein einziger großer Block, sondern aus **Paketen** zusammengesetzt. Ein Paket bündelt alles, was ein Lebensbereich braucht: einen oder mehrere Chat-Agenten, die dazugehörigen Datenbank-Tabellen, wiederkehrende Hintergrund-Aufgaben (Crons) und die Texte, die die Agenten steuern. Diese Bauweise ist der Grund, warum aus dem Finanz-Werkzeug später ein Karriere-Coach dazukommen konnte, ohne dass am Finanz-Teil etwas angefasst werden musste — und warum künftig weitere Bereiche denselben Weg gehen können.

## Core — das immer vorhandene Fundament

**Core** ist kein Lebensbereich, sondern der Unterbau, auf dem alle anderen Pakete stehen. Er bringt den Telegram-Bot-Eingang mit, das Bestätigen-vor-jedem-Schreiben (technisch: HITL-Gate mit Inline-Buttons), das geteilte Gedächtnis (Datenbank-Kontexte, Chat-Verlauf), den Watchdog `agent.monitor` und den Einrichtungs-Helfer `agent.guide`. Core wird bei der Installation immer mitgebracht und lässt sich nicht abschalten — jedes andere Paket baut auf ihm auf. Und Core ist **allein lauffähig**: Die Standard-Installation bringt nur Core mit, alle anderen Pakete wählst du danach selbst. Dafür verweist Core nie direkt auf ein Paket, sondern ruft Paket-Agenten über einen kleinen Verteiler auf, der vorher nachsieht, ob das Paket da und eingeschaltet ist — fehlt es, antwortet der Bot freundlich „nicht installiert" statt zu verstummen. Auch `/help`, das Onboarding-Menü und das Telegram-Befehlsmenü zeigen nur, was wirklich installiert ist.

## Finance, Career und Estate — eigenständige Lebensbereiche

**Finance** (Buchhalter + Finanzberater), **Career** (Karriere-Coach) und **Estate** (Nachlass-Berater) sind **Domänen-Pakete**: jedes hat seinen eigenen Bereich in der Datenbank (technisch: eigenes Schema) und seine eigenen Zugriffsrechte (technisch: getrennte Lese-/Schreib-Rollen je Paket). Das Career- oder Estate-Paket kann also strukturell gar nicht in die Finanz-Tabellen schreiben, außer über einen Weg, der extra dafür freigegeben wurde (mehr dazu unten). Diese Trennung macht jedes Paket **unabhängig installier- und deinstallierbar** — über das Kommandozeilen-Werkzeug `lifeagents package install <paket>` bzw. `uninstall <paket>`; lässt du den Paketnamen weg, öffnet sich auf dem Terminal eine Auswahl-Liste (bei `install` markierst du mehrere Pakete mit der Leertaste). Die Installation stellt erst alle Fragen der gewählten Pakete (Zugangsdaten und Einstellungen, jeweils mit Erklärung), zeigt sie dir in einer Übersicht zum Prüfen (einzeln ändern oder abbrechen) und richtet dann alles ohne Unterbrechung ein (mehr: [Installation](installation.html#funktionen-hinzufügen)). Ein Paket lässt sich außerdem vorübergehend abschalten, ohne es zu entfernen — dann bleiben seine Daten erhalten, nur seine Agenten und Hintergrund-Aufgaben pausieren.

Das jüngste Domänen-Paket ist **Estate** — der [Nachlass-Berater](nachlass-berater.html) mit dem Vorsorge-Register und der einfühlsamen Ereignisfall-Begleitung. Es zeigt die Bauweise besonders schön: Sein Register liegt in einem eigenen Datenbereich mit eigenen Rechten, und die nachlass-relevanten Angaben zu deinen Versicherungen und Konten liest es — falls das Finanz-Paket installiert ist — nur über ein bewusst freigegebenes Lesefenster mit. Ohne das Finanz-Paket funktioniert es trotzdem, dann eben ohne diese Felder.

Das Paket **Dokumente** (Paperless) ist ein Sonderfall: Es hat gar keine eigenen Daten, sondern ist ein reiner Lese-Zugang auf deine bestehende Paperless-Instanz — mit dem [Dokumenten-Assistenten](dokumente.html) und drei Werkzeugen (suchen, lesen, die Paperless-KI fragen).

## Werkzeuge über Paket-Grenzen hinweg

Ein Paket kann seine **Werkzeuge** auch den Agenten anderer Pakete anbieten — so können Buchhalter, Finanzberater, Karriere-Coach und Nachlass-Berater in deinen Dokumenten nachsehen. Das Herkunfts-Paket beschreibt jedes Werkzeug in seinem Manifest (was es tut, welche Angaben es braucht, **wer** es benutzen darf); die anderen Pakete melden sich ausdrücklich dafür an. Jeder Aufruf läuft über eine zentrale Prüfstelle im Grundsystem: Ist das Paket installiert und eingeschaltet? Darf die Person, die gerade schreibt, das Werkzeug benutzen (bei Dokumenten: nur Erwachsene)? Nur dann wird das Werkzeug ausgeführt — sonst bekommt der Agent eine freundliche Absage und arbeitet ohne weiter.

## Das Manifest — der Vertrag eines Pakets

Jedes Paket beschreibt sich selbst in einer Art Beipackzettel (technisch: `manifest.json`). Darin steht genau, was das Paket mitbringt: welchen Chat-Agenten es hinzufügt, welche Werkzeuge dieser Agent benutzen darf, welche Hintergrund-Aufgaben es einplant, welche Einstellungen es kennt und welche Chat-Befehle es anbietet. Diese Selbstbeschreibung ist verbindlich (ein „Vertrag") — der Rest des Systems verlässt sich darauf, statt Paket-Eigenheiten fest einzuprogrammieren. Genau deswegen konnte der Karriere-Coach dem Router beitreten, ohne dass der zentrale Verteiler-Code geändert werden musste: Er hat sich einfach über sein Manifest angemeldet.

## Kreuz-Lesen nur mit ausdrücklicher Freigabe

Ein Paket kann nicht einfach in den Daten eines anderen Pakets stöbern. Wenn ein Paket etwas aus einem anderen wirklich braucht, muss das **Herkunfts-Paket** ein bewusst dafür gebautes Lesefenster veröffentlichen — eine Art Durchreiche mit genau definiertem Inhalt, kein offener Zugang. Ein Beispiel: Der Karriere-Coach kann dir sagen, ob du dir einen Jobwechsel finanziell leisten kannst (die „Runway"-Frage). Dafür liest er einen einzigen, eng umrissenen Wert aus dem Finanz-Bereich — deine aktuelle Liquidität — über genau so ein freigegebenes Fenster. Ist das Finanz-Paket gar nicht installiert, bekommt der Karriere-Coach einfach keinen Wert zurück und rechnet ohne ihn weiter, statt abzustürzen.

## Warum das für dich zählt

Diese Bauweise ist der Grund, warum aus deinem persönlichen Assistenten mit der Zeit mehr werden kann, ohne dass die bestehenden Bereiche instabiler werden. Ein künftiger neuer Lebensbereich — etwa Gesundheit oder Haushalt — würde als eigenes Paket ergänzt: eigene Datenbank-Ecke, eigene Rechte, eigenes Manifest, angedockt an dasselbe Fundament. Der Buchhalter und der Karriere-Coach müssten dafür nicht umgebaut werden. Mehr zu den heute verfügbaren Bereichen findest du unter [Überblick](ueberblick.html), [Buchhalter](buchhalter.html), [Finanzberater](finanzberater.html), [Karriere-Coach](karriere-coach.html), [Nachlass & Vorsorge](nachlass-berater.html) und [Dokumente](dokumente.html).
