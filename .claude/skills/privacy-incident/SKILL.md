---
name: privacy-incident
description: Ablauf, wenn ein persönlicher Wert oder Hinweis schon öffentlich ist oder gerade werden könnte (Datei, Commit-, Tag-, PR-, Release-Text, Site, CI-Log). Nicht reflexhaft bereinigen - ein Bereinigungs-Commit zeigt den Fund gebündelt im Diff. Nutzen, sobald so ein Fund auffällt.
---

# Persönlicher Wert im öffentlichen Repo (`/privacy-incident`)

Veröffentlichte Daten lassen sich nicht zurückholen. Laut [GitHub-Doku](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository) bleiben alte Commits per SHA im Cache, über Pull Requests und in Forks erreichbar, fremde Klone bleiben ohnehin. Personenangaben lassen sich anders als ein Passwort nicht austauschen. Ziel ist darum, den Schaden nicht zu vergrößern.

## Sofort

1. **Nichts pushen.** Auch keine Bereinigung: Ein öffentlicher Commit, der den Wert entfernt, zeigt ihn gebündelt im Diff und markiert ihn als echt.
2. **Leitung informieren,** nur mit Datei, Zeile und neutraler Art („Betrag“, „Wohnform“). Der Wert steht in keiner Nachricht, keinem Issue, keinem Commit-Text und keinem Artefakt, das geteilt wird.
3. **Push-Sperre:** Die Leitung setzt sie (`.\scripts\set_no_push.ps1 -On`). Aufheben kann sie nur der Owner im Terminal.
4. **Wert sperren:** Die Leitung trägt ihn in `.local/privacy_denylist.txt` im Haupt-Checkout ein, in allen Schreibweisen. Dann kommt er nicht wieder rein.

## Einordnen

Der Owner entscheidet, nicht die Session. Er braucht diese Angaben:

- **Was:** Art des Werts und wie sensibel er ist.
- **Wo:** nur im aktuellen Baum, in der Historie, in Tag- oder Release-Texten, auf der Site, in CI-Logs.
- **Seit wann:** erster öffentlicher Commit (`git log -S` lokal, das Ergebnis nicht zitieren).
- **Wer hat ihn vielleicht:** Forks, Stars, Klon-Zahlen (GitHub zeigt sie im Traffic-Bereich).

## Bereinigen

Der Weg richtet sich nach der Entscheidung des Owners:

| Lage | Weg |
|---|---|
| Noch nicht gepusht | Lokal korrigieren. Ist es schon im Commit: Commit neu schreiben, bevor er rausgeht. |
| Öffentlich, wenig sensibel | Bereinigung gebündelt im nächsten Release, ohne eigenen Commit, der darauf hinweist. Der Commit-Text bleibt neutral. |
| Öffentlich, sensibel | Historie neu schreiben oder Repo-Neustart, danach GitHub-Support für die Caches. Forks und fremde Klone bleiben; das sagst du dem Owner ausdrücklich. |
| In einer angewandten `V__`-Migration | Nur der Kommentar darf sich ändern, der ausführbare Teil bleibt byte-gleich. Bestands-Instanzen übernehmen die neue Prüfsumme per Hash-Vergleich in `packages/core/db/core.schema_version_init.sql`, mit Test wie `tests/db/core/test_schema_version_checksum_repair.sql`. |
| Release-Text | `gh release edit` mit neutralem Text. Der Hook `dev_cycle_guard` prüft ihn vorab; ältere Fassungen können im Cache bleiben. |

## Danach

- **Ursache:** Wie kam der Wert hinein, und warum hat keine Sperre gegriffen? Lässt sich das als Regel fassen, gehört sie in `scripts/owner_fact_lint.ps1`.
- **Ehrlich melden:** Was ist entfernt, und was bleibt erreichbar?
