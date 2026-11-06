---
name: test-task
description: Brief für eine Unter-Session, die Agent-Tests aus echten Fehlern überarbeitet, nur für vom Owner freigegebene Befunde oder einen gemeldeten Fehler – Golden-Cases und Rubrics abgleichen, neue Fälle ableiten, veraltete mit Begründung vorschlagen. Args = die Befunde oder der Fehler.
---

# Testüberarbeitung (`/test-task`)

Du bist eine von der Leitung gestartete Unter-Session. Dieses Dokument ist dein vollständiger Brief. Du startest nur für vom Owner freigegebene Befunde oder einen von ihm gemeldeten Fehler, nie nach Kalender; das Aufräumen im Quartal macht `/audit-area`. Befunde und Umfang (Paket, Agent, Tier) stehen in den Args; fehlen sie, frag die Leitung, statt alles anzufassen. Root-`CLAUDE.md` gilt, Doku ist deutsch, das Repo ist öffentlich.

Ziel: Die Agent-Tests prüfen das, was im Alltag tatsächlich schiefgeht — nicht das, was einmal wichtig war. Ein Test, der nichts mehr fangen kann, ist Rauschen; eine Lücke, durch die ein Live-Fehler lief, ist ein Befund.

## 1. Regeln, die immer gelten (nicht verhandelbar)

- **Ein Testfall wird nie geändert, nur damit er wieder grün wird.** Entweder wird der Code repariert, oder der Fall ist nachweislich veraltet und dein Vorschlag nennt die Begründung.
- **Bezahlte Suiten nie selbst starten.** `n8n_test`, `orch_test`, `e2e_test`, `judge_eval`, `multiturn_test` kosten API-Credits (Owner-Fenster, Root-`CLAUDE.md` *Scripts*). Der Hook sperrt jeden Shell-Befehl, in dem der Dateiname einer Suite steht, auch `grep`/`cat`: Suite-Dateien nur mit Read/Grep/Glob öffnen und den Dateinamen auch in Commit-Messages, Notizen und Befehlen vermeiden („die Routing-Suite“, „der Bewerter“). Du empfiehlst die Suite mit dem exakten Kommando (Tabelle `docs/reference/tests.md`, Empfehlung auch `scripts/llm_suite_advice.ps1`), der Owner bzw. die Leitung startet sie.
- **Gratis läuft immer:** `db_test.ps1` und `infra_test.ps1`, der Mock-LLM-Tier (`scripts/dev/mock_route_test.ps1`, `enable_mock_*`), alle freien Gates gebündelt `scripts/dev/run_free_gates.ps1 -Reset -Parallel` (nur auf Anweisung der Leitung, mit eigenen Containern). Mock-LLM ändert den Gateway-Upstream — nach jedem Neustart prüfen die Suiten ihn selbst.
- **Testdaten nur erfunden, Vorrat und Regeln in `tests/fixtures/README.md`.** Du bekommst nur die Eigenschaft eines Befunds (Rundungsfall, Mehrdeutigkeit, fehlendes Konto, Formulierung), nie den Originaltext, und erfindest alle Werte neu. Liest du selbst vom Live-System, gilt dasselbe. Notizen und Kommentare nennen nur die Eigenschaft: keine Person, keine Bank, kein Betrag, kein Haushaltsbezug. `privacy_lint` prüft gegen die lokale Denylist.
- **Kein Test-Theater** (Root-`CLAUDE.md` *Testing*): Stickies, Doku, Refactor mit identischem Output brauchen keinen neuen Test. Pro Fall muss klar sein, welche Regression er fangen würde.
- Mechanik und Konventionen: `tests/CLAUDE.md` (Layout, Quarantäne, Golden-Regeln, E2E-Regeln); Dateien, Harness, Judge: `docs/reference/tests.md`. Die zählen, nicht dein Gedächtnis.

## 2. Befunde sammeln (nur lesen)

Quellen, in dieser Reihenfolge:

1. Die Befund-Liste aus den Args bzw. der Leitung (z. B. Bericht der Routine `live-findings`, ein privates Dokument im Konto des Owners — nie ins Repo kopieren, nur lesen und neu erfinden).
2. Privates Backlog .local/BACKLOG.md im Haupt-Checkout (offene Fehler/Fehlrouten), `git log --oneline` des Bereichs seit dem letzten Abgleich (Fix-Commits ohne Test).
3. Lesender Zugriff auf das Live-System nur, wenn die Leitung ihn freigegeben hat (Memory `live-system-read-permission`, Rezept `owner-instance-ssh-access`): Gespräche, Fehler-Alerts, Ausführungsfehler. Nie schreiben, nie Roh-Auszüge in Chat/Commit.
4. Fehlschläge der Gratis-Gates (CI-Ampel `scripts/check_ci_status.ps1`).

Halte je Befund in einem Satz fest: Nutzer-Äußerung (sinngemäß), erwartetes Verhalten, tatsächliches Verhalten, betroffene Schicht (Routing / Prompt / Tool-Description / DB-Gesetz / Workflow). Erfundene Beispielwerte, nie Live-Werte, nie der Originaltext des Gesprächs.

## 3. Bestand prüfen

Für jede Datei im Umfang (`tests/agent/<pkg>/*_cases.json`, `tests/agent/cross/*`, `tests/fixtures/fixtures.json`, `tests/mock_llm/scenarios.json`; Zählungen immer per `(Get-Content … | ConvertFrom-Json).Count`, nie hartcodiert in Doku):

| Prüfung | Frage | Konsequenz |
|---|---|---|
| Tool existiert | Gibt es `expected_tool` noch (`packages/<pkg>/build/workflows/tools/<tool>.ps1`)? | Weg oder umbenennen |
| Args aktuell | `expected_tool_args`-Feldnamen = `Build-Trigger`/`$fromAI`-Namen des Tools? | angleichen; dynamische Werte (IDs) nie asserten |
| Prompt-Pflicht | Verlangt der Fall etwas, das der Prompt/die Tool-Description/das Manifest heute **anders** regelt (Regel umgedreht, Tool entfernt, „Not yet available“-Liste gekürzt)? | Fall oder `expected_behavior` anpassen; Notiz mit Datum |
| Rubric-Qualität | Prüft die Rubric **Output-Substanz** (Antwort nennt Saldo, fragt nach Zinssatz) statt `read_tools`? Der Action-Log ist unvollständig. | umschreiben |
| Fixture-Defekt | `set_*`/`close_*`/`delete_*` als Routing-Golden ohne dauerhafte Entität? | durch DB-Test + E2E ersetzen (`tests/CLAUDE.md` *Golden-Cases*) |
| Self-contained | `create_*` mit **neuen** Namen, sonst fragt der Agent nach (Dedup-Treffer ⟹ FAIL)? | Namen erfinden |
| Mock-Szenario | Hat jeder Golden ein Szenario in `tests/mock_llm/scenarios.json` mit allen Pflicht-`$fromAI`-Feldern? | `mock_lint.ps1` prüft es |
| Quarantäne | `quarantined: true` ohne Grund/Re-Evaluierungs-Trigger? Trigger erfüllt? | Grund nachtragen oder wieder scharf schalten |
| Doppelung | Prüfen zwei Fälle dieselbe Eigenschaft? | einen streichen |
| Zu schwach | Fängt der Fall den dokumentierten Fehler wirklich? Mutations-Gedanke: würde er rot, wenn die Regel fehlte? | schärfen |

**Streichen** schlägst du vor, wenn ein Fall nichts mehr fangen kann, mit Begründung im Bericht; gestrichen wird erst nach Owner-Freigabe (kein stilles Löschen). Unsichere Fälle kommen mit Grund in die Quarantäne statt in die Löschliste.

## 4. Neue Fälle aus echten Fehlern ableiten

- Wähle die billigste Schicht, die den Fehler fängt (Root-`CLAUDE.md` *Testing*): Daten-Korrektheit ⟹ DB-Test `tests/db/<pkg>/test_fn_*.sql` (hart, gratis, bevorzugt); Routing/Prompt ⟹ Golden-Case + Mock-Szenario; Schreib-Schema/Payload ⟹ E2E-Case; mehrere Gesprächsrunden ⟹ `multiturn_cases.json`; Injection/Excessive Agency ⟹ `security_cases.json`.
- Golden: `id` fortlaufend aus dem Bestand ablesen (nicht raten), `name`, `task` (so formuliert, wie ein Laie schreibt, mit der Mehrdeutigkeit des Befunds), `chat_id`, `expected_tool` (oder `null` bei „kein Write“), `expected_behavior` als Rubric, `notes` mit Datum und Befund in einem Satz (erfunden, ohne Live-Werte). Onboarding-Vorzustand per `"onboarding"`/`"package_onboarding"`.
- E2E: Voraussetzungen per `setup_sql` über die `<pkg>.fn_*` anlegen, der Agent macht nur den geprüften Schritt; Entitäten mit `__E2E__` im Namen; neue löschbare Entität ⟹ `<pkg>.fn_clear_e2e_data` erweitern; jeder Fall endet `status=success`.
- Wurde der Befund durch einen Fix behoben, gehört der Test zum Fix (rot vor grün). Gibt es den Fix noch nicht: Test als `quarantined` mit Trigger „bis Fix X“ ablegen und der Leitung den Fix melden — Bugs werden sofort gefixt (Root-`CLAUDE.md` *Arbeitsweise*), nicht ins Backlog geparkt.
- Die Bewerter-Eichung (`tests/agent/cross/judge_labels.json`, Agreement/Kappa) nur ändern, wenn sich Bewerter-Modell oder Rubric-Stil ändert; eine neue Kalibrierung ist ein bezahlter Lauf ⟹ empfehlen, nicht starten.

## 5. Prüfen und abschließen

- Gratis, selbst fahren: `db_test.ps1 -Filter '*<subject>*'` (bei DB-Tests), `mock_lint.ps1`, `contract_lint`/`doc_lint` (`doc_lint` erzwingt Manifest ⊆ Seed für Fixtures), JSON-Validität (`ConvertFrom-Json`), Mock-Tier bei Szenario-Änderung. Eigene Container: Namen/Ports aus dem Brief der Leitung, vorher `docker ps`, nie geteilte Defaults.
- Bezahlt, nur empfehlen (Kommando + Grund + erwartete Kosten-Größe): welche Suite(n), auf welchem Stand, ob `-CasesFile`/`-TargetWorkflow` nötig sind (Tabelle `docs/reference/tests.md`). Sage ehrlich, was ohne den Lauf ungeprüft bleibt (neue Goldens sind bis dahin nicht gegen das echte Modell bestätigt).
- Läuft eine Suite im Owner-Fenster (Owner oder Leitung startet sie): lies das Ergebnis, trenne Infra-Flake (ERROR, Timeout, Quota — zuerst Modell-Quota prüfen) von inhaltlichem FAIL; ein einzelner Routing-FAIL beweist keine Regression (weiches Gate). Echte Fails ⟹ Ursache in Prompt, Description oder Code beheben, den Fall nur bei nachweislich veralteter Erwartung und mit Begründung ändern.
- Commit: Conventional Commit `test(<pkg>): …`, englisch, ohne Live-Werte. Kein Push, kein Tag: das macht die Leitung.
- Eigene Container abbauen (`scripts/dev/stop_test_containers.ps1` mit deinen Namen); Mocks nach dem Lauf deaktivieren.

**Ergebnis an die Leitung: Branch, Stand, offene Fragen.** Nenne im Bericht: Branch und Commit-Hashes; Tabelle der Befunde (Einzeiler) mit der gewählten Schicht und dem Fall bzw. Test; gestrichene/umgeschriebene/quarantänisierte Fälle mit Grund; welche bezahlten Suiten du mit welchem Kommando empfiehlst; was ungeprüft ist; Fixes, die der Befund verlangt und die nicht in diesem Paket liegen.
