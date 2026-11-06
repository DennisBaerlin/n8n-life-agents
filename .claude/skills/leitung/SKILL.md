---
name: leitung
description: Macht diese Session zur Leit-Session – liest die private Stand-Datei, verteilt Arbeit auf Unter-Sessions, führt zusammen, entwickelt die Arbeitsweise weiter. Nutzen, sobald der Owner „du bist die Leitung“, „übernimm die Leitung“ oder „du leitest“ sagt oder /leitung aufruft. Nicht für Unter-Sessions.
---

# Leit-Session (`/leitung`)

Der Satz „du bist die Leitung“ reicht; alles Weitere steht hier, der Owner muss keine Datei nennen.

| Was | Wo |
|---|---|
| Arbeitsweise der Leitung (dauerhaft) | dieser Skill |
| Zusammenspiel mehrerer Sessions, Merge-Hoheit | `/coordinate`, gilt zusätzlich |
| Aktueller Stand: Offenes, Sessions, Container, Owner-Entscheide | `.claude/plans/leitung-stand.md` (gitignored, nur Haupt-Checkout) |

Das Repo ist öffentlich: Stand und private Anlässe gehören nie in diesen Skill.

## 1. Beim Start

1. **Modus:** Läuft die Session im Bypass-Modus, anhalten und den Owner um „Auto“ bitten (`/coordinate` §1).
2. **Ort:** Die Leitung arbeitet im Haupt-Checkout. Läuft die Session in einem Worktree, das dem Owner sagen; die Stand-Datei liegt trotzdem dort.
3. **Sichtbar machen:** Session anpinnen (`set_pinned`, session_id „self“) und „Leitung“ nennen (`set_session_title`).
   **Status-Panel:** `.\scripts\set_status_panel_home.ps1` einmal selbst fahren. Es wirkt beim nächsten Start dieser Session oder per `/status-panel`; das dem Owner sagen.
4. **Stand lesen:** `.claude/plans/leitung-stand.md`. Fehlt die Datei, aus der Vorlage in §5 anlegen.
5. **Lage prüfen:** `ListAgents`, `ReadNotifications`, `list_sessions {linked:true}`, `git status`, `.\scripts\check_ci_status.ps1`. Läuft noch eine andere Leitung, übergibt sie an diese (`/coordinate` §2).
6. **Melden:** in wenigen Sätzen an den Owner: was offen ist, was als Nächstes dran ist, was der Owner entscheiden muss. Nichts aus dem Stand ohne Auftrag beginnen.

## 2. Während der Arbeit

- **Hauptüberlegung bei jedem Arbeitspaket (neue Aufgabe, Fix-Welle, Sprint-Nachbereitung, Retro-Punkte), an jeder Stelle:** zuerst die Aufgabe klären, dann ausdrücklich prüfen, wie sie sich auf mehrere Unter-Sessions verteilen lässt, um schneller zu werden. Der Schnitt folgt den Dateigruppen, damit keine zwei Sessions dieselben Dateien anfassen. Eine einzige Session braucht eine Begründung (z. B. alles liegt in denselben Dateien). Beispiel: Acht unabhängige Retro-Punkte gingen an eine Session statt an drei (Regeln und Texte, Skripte, Hooks).
- **Verteilen:** Was wenige Tool-Aufrufe braucht, macht die Leitung selbst. Eigenständige Aufgaben bekommen je eine Unter-Session (`start_session`, „fresh“, eigener Worktree). Sessions ohne gemeinsame Dateien dürfen parallel laufen.
- **Direkt nach jedem `start_session`:** `.\scripts\register_sub_session.ps1 -Id <local_…>`. Dann lehnt der Hook direkte Fragen dieser Session an den Owner ab (`.claude/hooks/enforce_sub_session_questions.ps1`). Das wirkt nur in Sessions, die den Hook beim Start schon in ihrem Checkout hatten.
- **Jeder Brief enthält:**
  - Aufgabe, betroffene Dateien, woran „fertig“ erkennbar ist
  - Session-ID der Leitung und die Regel *Fragen an den Owner laufen über die Leitung* (`/coordinate` §5)
  - eigene Container mit Session-Kürzel, freie Ports nach `docker ps`
  - n8n-Test-Substrat nur nach Reservierung durch die Leitung, die die Plätze verteilt (`scripts/reserve_substrate_slot.ps1`); kalte Läufe standardmäßig auf GitHub-Runnern; Compose- und andere Probe-Container kurz halten.
  - Repo öffentlich, nur erfundene Werte, auch in Commits und Kommentaren
  - Testfälle nie ändern, nur damit sie grün werden; Streichen erst nach Owner-Freigabe
  - bezahlte Suiten und Mini-App nur im jeweiligen Owner-Fenster
  - Bericht am Zug-Ende: Branch, Hash, Gates, offene Punkte
  - Berechtigungs-Karten gebündelt: Die Unter-Session legt Auslöser für Karten ans Blockende und meldet den Befehl, statt einzeln zu blockieren.
  - Notizordner als Rückfall: Sperrt die App Nachrichten nach 10 Sitzungs-Nachrichten ohne Owner-Eingabe, schreibt die Session ihren Bericht als Datei dorthin.
  - passender Skill als Rahmen: `/feature`, `/test-task`, `/docs-task`, `/mini-app-task`, `/ui-task`
- **Wartende Sessions nennen:** Die Leitung führt in jeder Antwort an den Owner alle Sessions auf, die auf ihn warten (Karte, Plan-Freigabe, Entscheidung), gebündelt statt verstreut.
- **Modell sparsam:** Mechanische Pakete (Doku, Tests, Werkzeug) laufen als Unter-Session auf Sonnet (`model` im `start_session`), Opus nur für Design und Architektur; die Zahl paralleler Opus-Sessions bleibt klein. **Beobachtungs-Auftrag** (Owner-Wunsch: beobachten, ob die Qualität abnimmt oder die Geschwindigkeit zunimmt): Die Leitung notiert je Sprint Qualität (Nacharbeit, rote Gates) und Tempo der Sonnet-Pakete in der Stand-Datei; die Auswertung erfolgt zusammen mit dem Memory `effort-medium-probe`.
- **Prüfläufe vor dem Merge:** `ci` und `genericity` laufen sonst nur auf main/PR und melden Fehler erst nach dem Merge. Vor dem Bewegen von `main` fährt die Leitung auf dem Integrations-Branch `gh workflow run genericity.yml --ref <branch>` und `gh workflow run ci.yml --ref <branch>` und wartet per `gh run watch` (`/coordinate` §3).
- **Schlank bleiben:** Große Dateien und lange Protokolle lesen Unter-Sessions, die Leitung bekommt das Ergebnis.
- **Stand sofort festhalten:** Session-ID, Branch, Container und jede Owner-Entscheidung im Wortlaut kommen gleich in die Stand-Datei, nicht erst am Ende. Erledigtes fliegt raus; die Datei beschreibt nur das Jetzt. Geändert wird sie nur mit dem Edit-Werkzeug, nie per Zeilennummer oder `Add-Content`.
- **Entscheidungen als Karte:** Offene Punkte und Entscheidungen für den Owner stellt die Leitung immer als Karte, mit kurzer Erläuterung der Folgen und Empfehlung.
- **Freigaben:** Merge, Push und Release nur auf das eigene Wort des Owners im Chat der Leitung (`/coordinate` §5 *Owner-Freigaben*). Prüfungen werden nicht übersprungen.
- **Push-Sperre:** Soll nichts nach GitHub (z. B. vor einem Repo-Neustart), setzt die Leitung `.\scripts\set_no_push.ps1 -On`, noch bevor ein Brief das Pushen erwähnt. Aufheben kann nur der Owner im Terminal (`-Off`).
- **Warten:** Auf GitHub-Läufe per `gh run watch` im Hintergrund, der Owner soll nicht nachfragen müssen (`/coordinate` §5 *Offene Läufe*).
- **Über Remote Control:** Der Owner sieht keine Seitenfenster, Bilder und Diffs darum als Datei in den Chat. Die App verweigert dann den Start einer Session; das sagt die Leitung sofort, der Owner tippt die Nachricht in der Desktop-App.
- **Plan-Freigabe:** Bei einer weitergeleiteten Plan-Karte sagt die Leitung dem Owner, das schlichte „Akzeptieren“ zu wählen; die Option „mit Bearbeitungsrecht“ stellt die Session von Auto um. Danach prüft sie `permissionMode` und stellt im selben Schritt die Denkstufe laut Plan-Zeile ein: für eine neue bauende Session per `start_session` `effort`, für die planende Session per `set_session_effort`. Liegt die Stufe über der eigenen, fragt die App den Owner; die Leitung kündigt das in derselben Nachricht wie die Plan-Abnahme an, damit kein eigener Termin entsteht.
- **Nur Belegtes behaupten:** Eine Regel oder Zusage erst schreiben, wenn sie ausprobiert ist. Was nicht geprüft wurde, steht als ungeprüft im Bericht.

## 3. Arbeitsweise weiterentwickeln

Diese Anleitung soll mit jedem Sprint besser werden. Auslöser: Der Owner korrigiert die Arbeitsweise, dieselbe Reibung tritt zweimal auf oder eine Regel erweist sich als falsch.

1. **Festhalten und vorschlagen:** die Regel im genauen Wortlaut in ein bis zwei Sätzen als Zeile unter `## Verbesserungen` festhalten (Verbesserungs-Liste unten). Dem Owner zeigt die Leitung sie gebündelt am Sprint-Ende; was sich im selben Sprint wiederholen würde, sofort.
2. **Richtige Adresse wählen (ein Fakt, eine Adresse):**
   - Alltag der Leitung → hier
   - Zusammenspiel der Sessions → `/coordinate`
   - Ablauf einer Aufgabenart → deren Skill
   - gilt für jede Session → Root-`CLAUDE.md`
   - hartes Verbot → Hook, nur nach ausdrücklicher Owner-Freigabe
3. **Umbauen statt anhängen:** Die Regel ersetzt, was ihr widerspricht. Anlass nur nennen, wenn die Regel sonst unverständlich wäre, und dann ohne Privates.
4. **Sichern:** auf das Ja des Owners committen, unabhängig von laufenden Paketen. Laufende Unter-Sessions bekommen die Regel per `SendMessage`.

**Verbesserungs-Liste:** Jede Reibung, jeder eigene Fehler und jede Owner-Korrektur kommt sofort als Zeile in die Stand-Datei unter `## Verbesserungen`: was passiert ist, die Ursache und ein Vorschlag mit Ziel-Adresse (Skill, Hook, Skript). Am Sprint-Ende legt die Leitung alle offenen Zeilen dem Owner gebündelt als Karten vor, jede mit Empfehlung. Was sich sonst im selben Sprint wiederholen würde, schlägt sie sofort vor.

Leitfragen dafür: Wo stand die Arbeit still? Was musste der Owner zweimal sagen oder selbst bemerken? Was hat Kontingent gekostet, ohne zu helfen? Daraus höchstens drei Vorschläge, einzeln zur Entscheidung.

## 4. Sprint-Ende und Übergabe

- Nach dem Merge die fertigen Unter-Sessions gesammelt zum Archivieren vorschlagen und auf das Ja des Owners archivieren (`archive_session`: stoppt die Session, räumt ihren Worktree ab, wiederherstellbar). Vorher muss alles aus ihnen gemerged und ihr Nachlauf erledigt sein. Löschen (`delete_session`) nur auf ausdrücklichen Wunsch des Owners. Danach per `docker ps` die Container fertiger Sessions abräumen, auch `db_test`-Container (die bleiben nach dem Session-Ende stehen), und `.\scripts\register_sub_session.ps1 -Clear`.
- Stand-Datei und Memory aktualisieren, sodass eine neue Session ohne dieses Gespräch weitermachen kann.
- Auf neue Session oder `/clear` hinweisen (Root-`CLAUDE.md` *Entwicklungszyklus*). Die neue Leitung startet der Owner mit dem einen Satz.

## 5. Vorlage der Stand-Datei

```markdown
# Stand der Leitung (<Datum>)

## Offen, der Reihe nach
## Owner-Entscheide (Wortlaut)
## Verbesserungen (was passiert ist, Ursache, Vorschlag + Ziel-Adresse)
## Unter-Sessions (ID, Branch, Stand)
## Container (Name, Port, Halter)
```
