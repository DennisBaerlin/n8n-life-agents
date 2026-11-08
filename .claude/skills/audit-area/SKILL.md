---
name: audit-area
description: Vierteljährliches Audit als Session – Sonnet-Unteragenten prüfen je einen Bereich (DB-Funktionen, Workflows, Installer, Mini-App, Testfälle, Doku) gegen eine feste Prüfliste; Ergebnis ist eine Vorschlagsliste für den Owner. Nutzen auf Zuruf „Audit“, „Quartalsprüfung“. Args = Bereich oder leer.
---

# Bereichs-Audit (`/audit-area`)

Quartalsweise Sichtprüfung gegen die geschriebenen Gesetze des Repos, getrennt von Feature-Reviews (`/code-review` prüft einen Diff, dieses Audit den Bestand). Eine Session mit dem Owner, kein Cron: Der Lauf kostet viel Kontingent, der Owner startet ihn bewusst. Du schlägst vor, nichts wird ohne Freigabe geändert; ein Fund mit Blast-Radius geht danach durch `/feature`.

## Ablauf

1. **Bereiche wählen:** Args nennen einen Bereich (`db`, `workflows`, `installer`, `app`, `tests`, `docs`) oder alle sechs. Eine geplante Erinnerung schlägt den Lauf nur vor: Er bleibt eine Owner-Session (kostet Kontingent). Dem Owner vorher in einem Satz sagen, wie viele Unteragenten laufen (Kontingent).
2. **Je Bereich ein Unteragent** vom Typ `Explore` (Sonnet, nur lesend). Der Prompt enthält die Prüfliste unten wörtlich plus „nur lesen, nichts ändern; jeder Fund mit Datei:Zeile und dem Gesetz, gegen das er verstößt; Funde ohne Beleg verwerfen“. Parallel starten nur, wenn der Owner dem Kontingent zustimmt; sonst nacheinander.
3. **Auswertung im Haupt-Loop:** Funde gegen das Gesetz gegenprüfen (Stichprobe: die schwersten Funde selbst öffnen), Doppelte zusammenfassen, Schwere vergeben (hoch = Daten-/Geldfehler, Sicherheit, Privatsphäre · mittel = bricht Konvention, still falsch möglich · niedrig = Stil/Drift). Bewusst akzeptierte Ausnahmen (stehen in den Sub-`CLAUDE.md` als „bei uns anders“) sind keine Funde.
4. **Bericht** als privates Artefakt `Audit <Bereich> <Quartal>` (nie ins Repo, Ablage wie bei `/live-findings`; keine Live-Werte): Kurzfazit je Bereich, Tabelle {Bereich, Schwere, Fund, Beleg, Gesetz, Vorschlag, Aufwand}, Teil „geprüft, ohne Befund“, Teil „nicht geprüft“. Der Owner gibt Vorschläge frei; freigegebene gehen als Plan oder als Punkt im privaten Backlog in die Entwicklung.

Für das Regelwerk selbst (CLAUDE.md, Regeln, Skills) gibt es das eingebaute `/doctor prompt-audit`; nur der Owner kann es tippen, darum ist es kein Teil dieses Laufs.

**Falle:** Ein Hook sperrt jeden Shell-Befehl, in dem der Dateiname einer bezahlten Test-Suite steht (auch beim Suchen); die Unteragenten bekommen den Hinweis mit und suchen mit dem Grep-Tool.

## Prüflisten

**DB-Funktionen** (`packages/*/db/`, Gesetze `.claude/rules/sql.md`, `packages/CLAUDE.md`)
- Jede Write-`fn` kapselt alle Writes eines Tools in einer Transaktion; nutzerkorrigierbare Fehler als `{ok:false, reason}` ohne `RAISE`; Erfolg liefert nur Handles, Post-State, DB-berechnete Größen (*Post-State-Vertrag*).
- Integrität als Constraint/Trigger zuerst; Multi-Row-Invarianten nicht über Gate-Trigger (MVCC); `NULLS NOT DISTINCT` bei Partial-UNIQUEs mit NULL.
- `SECURITY DEFINER`: `search_path` gepinnt, voll-qualifizierte Namen, kein dynamisches SQL, `REVOKE … FROM public` und gezielte `GRANT`s; Rollen ohne Zugriff auf fremde Schemas.
- Das LLM rechnet nicht: keine abgeleiteten Größen als Tool-Input; Datums-Keys über `core.fn_resolve_input_dates`.
- Zu jeder `fn_*` und jeder Invariante ein Test in `tests/db/<pkg>/`; `docs/fn_catalog.md` ist generiert, nicht von Hand geändert.
- Migrations-Modell: eine Function je `R__`-Datei, Init und `R__` synchron.

**Workflows** (`packages/*/build/workflows/`, Gesetze `packages/CLAUDE.md` *Workflow-Bau*, *Build-Gotchas*)
- Überblicks-Sticky je Workflow, Sticky an nicht-offensichtlichen Stellen, deutsch, gegen den heutigen Graphen gelesen.
- `settings.errorWorkflow` gesetzt (außer Test-Harness und der Notify selbst); `maxIterations` an jedem Agent-Node; Depth-Gate am Agent-Eingang.
- HITL-Gate vor jedem persistenten Write; Karte als Struktur, Beträge/Daten nur als `money`/`date`; keine festen Nutzertexte als Literal.
- Nodes nur über die Helper; Credentials nur als `__CRED_*__`; keine hartcodierten Workflow-IDs; `typeVersion`s bewusst.
- Prompts: Tool-Spezifisches in der Tool-Description, nichts doppelt; die „Not yet available“-Liste stimmt mit den vorhandenen Tools überein; wechselnde Prompt-Teile nur am Ende (Cache).

**Installer** (`provisioning/`, `scripts/`, Gesetze `provisioning/CLAUDE.md`, `.claude/rules/powershell.md`)
- Bash-Libs werden gesourct (keine `set -e`-Annahmen); Idempotenz: ein zweiter Lauf ändert nichts; UTF-8 überall (Referenz-Umgebung `LANG="C"`).
- Keine Secrets in Logs, Prozesslisten oder Befehlszeilen; Dateirechte der Env-Dateien; Firewall-/Proxy-Bind wie dokumentiert (nur `/webhook*`).
- Update-Pfad: Backup vor Schema-Änderung, Plattenplatz-Prüfung, kein Überschreiben von Owner-Werten.
- PowerShell-Skripte UTF-8 mit BOM, Daten-I/O explizit UTF-8, Scripts-Only-Policy eingehalten.

**Mini-App** (laut `docs/reference/core.md` *Mini-App*; nur lesen — Änderungen brauchen laut Root-`CLAUDE.md` Owner-Zustimmung und einen eigenen Plan)
- Eine Frage je Abschnitt; jeder Fakt hat ein Zuhause über alle Tabs; Pille nur, wenn eine Handlung nötig ist; Summen sichtbar als Summe beschriftet.
- Laien-Test: jedes Wort verständlich für Laien im Haushalt, kein Jargon ohne Grund.
- Sichtbarkeit nur in der Bildschirm-fn (`core.fn_app_sees_household`), Mitglieder sehen keine Haushaltsdaten, `core.fn_app_screen` wirft nie.
- Keine Live-Werte im Code oder in Tests; Texte aus dem Katalog.

**Testfälle** (`tests/agent/`, `tests/mock_llm/`, Gesetze `tests/CLAUDE.md`; nur Vorschläge, gestrichen wird erst nach Owner-Freigabe)
- Veraltete Fälle: Tool oder Regel, die der Fall erwartet, gibt es nicht mehr; je Vorschlag der Beleg und die Begründung.
- Doppelte Fälle: zwei Fälle prüfen dieselbe Eigenschaft; je Vorschlag, welcher bleibt.
- Quarantäne ohne Grund oder mit erfülltem Re-Evaluierungs-Trigger.

**Doku-Faktencheck gegen den Code** (`docs/reference/*.md`, Sub-`CLAUDE.md`, `docs/site/content/` = Nutzer-Doku; nur Vorschläge)
- Jede Behauptung gegen den Code prüfen: Namen von Funktionen, Tabellen, Workflows, Skripten, Schaltern sowie Zahlen. Existiert es, heißt es so, verhält es sich so?
- Fund = Datei:Zeile, Behauptung, Code-Stand (mit Beleg-Datei). Generierte Dateien (`docs/fn_catalog.md`, `docs/site/public/`) sind nicht von Hand zu ändern: dort Drift der Quelle melden.
- Nutzer-Doku zusätzlich: Aussagen über Bedienung, die der Code nicht (mehr) hergibt.
