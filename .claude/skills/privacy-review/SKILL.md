---
name: privacy-review
description: Vor jedem Push (auch Branches) – ein Modell liest, was der Push öffentlich macht (Commits, Commit-/Tag-Texte, Branch-Namen) auf persönliche Hinweise; meldet Datei, Zeile, Art, nie den Wert; dann setzt scripts/privacy_review_stamp.ps1 den Stempel. Nutzen bei gesperrtem Push oder „Privacy-Prüfung“.
---

# Modell-Prüfung vor dem Push (`/privacy-review`)

Eine Liste findet feste Wörter. Sachverhalte findet sie nicht: „wohnt zur Miete“, ein Beruf, ein Plan mit Jahreszahl. Dafür gibt es diese Prüfung. Sie ist nicht deterministisch und übersieht einen Teil. Deshalb ergänzt sie die festen Sperren und ersetzt sie nie.

Der Stempel gilt für genau einen Hash. Ein neuer Commit, ein geänderter Commit-Text oder ein anderer Zielname verlangen eine neue Prüfung. Beiträge von außen und die CI brauchen weder Stempel noch private Listen.

## Harte Grenzen

- **Nie ein Wert im Text:** Weder Bericht, Commit noch Nachricht nennen den Fund. Erlaubt sind Datei, Zeile und eine Art wie „Wohnform“ oder „Betrag“.
- **Nichts veröffentlichen:** Diese Prüfung pusht und taggt nicht.

## Ablauf

1. **Stand festlegen:** Die Sperr-Meldung nennt den Aufruf für den Stempel (`-Ref`, `-Remote`, `-DestRef`, bei `--tags` auch `-AllTags`). Dieselben Angaben gelten für die folgenden Schritte. Der Arbeitsbaum ist sauber; nur ungestagte Vorschau-Einträge in `.claude/launch.json` dürfen bleiben. Ein Tag-Push ist ein eigener Push mit eigenem Stempel (`-DestRef <tag>`), der erst NACH dem `main`-Push gesetzt wird: Der Hash hängt am Ausgehenden gegen den Remote-Stand, ein früher Stempel enthält den Pin-Commit noch und passt danach nicht mehr. `-Ref` darf Commit-Hash, Branch oder Tag-Name sein (das Skript löst zum Commit auf, der Test `privacy_review_hook_test.ps1` belegt Gleichheit mit der Hash-Form); bei einem Tag-Push den Aufruf der Sperr-Meldung wörtlich übernehmen, inklusive `-DestRef`.
2. **Text erzeugen:** `.\scripts\privacy_outgoing.ps1 <Angaben> -OutFile <Scratchpad>\outgoing.txt`. Der Text liegt nur im Scratchpad, nie im Repo. Er enthält jeden neuen Commit einzeln, auch wenn ein späterer Commit die Stelle wieder entfernt, denn öffentlich wäre beides. Generierte Dateien fehlen darin, ihre Quellen sind enthalten.
3. **Feste Sperren zuerst:** `.\scripts\privacy_lint.ps1` und `.\scripts\owner_fact_lint.ps1`. Rot wird zuerst behoben.
4. **Steckbrief:** Lies `.local/privacy_profile.md` im Haupt-Checkout (gitignored). Dort steht in Stichworten, was beim Owner als persönlich gilt: Wohnform, Familie, Beruf, Pläne, Länderbezüge, Banken. Fehlt die Datei, frag die Leitung, und erfinde nichts.
5. **Prüflauf:** Ein Unteragent mit `model: "sonnet"`. Ab etwa 300 KB Text teilst du nach Commits auf mehrere Unteragenten auf. Du liest den Text nicht selbst.
6. **Auftrag an den Unteragenten, wörtlich:** „Prüfe nur hinzugefügte Zeilen (`+`), Commit- und Tag-Texte, Branch- und Tag-Namen. Melde jede Stelle, die auf das Leben einer echten Person schließen lässt: Name, Ort, Beruf, Familie, Wohnform, Pläne, Beträge, Konten, Versicherer, Herkunft, auch als Umschreibung, Übersetzung oder als ‚echter Fall‘ markiert. Maßstab ist der Steckbrief. Allgemeine Produkt-Funktionen und offensichtlich erfundene Beispiele sind kein Fund. Antworte je Fund mit Commit, Datei, Zeile und Art (ein bis drei Wörter wie „Wohnform“ oder „Betrag“). Keine Einzelheit aus der Stelle: kein Ort, kein Verwandtschaftsgrad, keine Zahl, auch nicht umschrieben. Zitiere nichts.“
7. **Bewerten:** Echte Funde bereinigst du. Der Text wird allgemein, der Wert wird erfunden, die geprüfte Eigenschaft bleibt. Steckt der Fund in einem früheren, noch nicht öffentlichen Commit, schreibst du diesen Commit neu; ein weiterer Commit obendrauf hilft nicht. Neue echte Werte meldest du der Leitung nur mit Datei und Zeile, damit sie in die lokale Liste kommen. Unklare Fälle entscheidet der Owner über die Leitung. Wird etwas schon öffentlich gefunden: `/privacy-incident`.
8. **Stempel:** Erst wenn nichts offen ist: `.\scripts\privacy_review_stamp.ps1 <Angaben>`. Stempel und `git push` in getrennten Aufrufen: Die Sperre prüft vor dem Befehl, ein Stempel im selben Aufruf zählt noch nicht.

## Bericht

An die Leitung: geprüfter Stand und Hash, Anzahl der Funde je Art, was bereinigt wurde und was der Owner entscheiden soll. Nenne ausdrücklich, was nicht geprüft wurde: Binärdateien erscheinen im Text nur als Vermerk, generierte Dateien fehlen. Der Text einer Release-Notiz läuft nur durch `privacy_lint`; das Modell liest ihn erst die Tiefenprüfung. Bleibt ein Fund offen, gibt es keinen Stempel.
