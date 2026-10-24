---
name: reset-dev
description: Dev-Instanz (realer LXC im LAN) clean machen und den aktuellen lokalen Repo-Stand (inkl. uncommitteter Aenderungen) als frischen Install-Baum bereitlegen, damit der Owner den CLI-Installationsprozess interaktiv durchklickt. Nutzen NUR auf Owner-Aufforderung ("mach wieder clean", "neu bereitlegen", /reset-dev) — typischerweise nachdem eine vom Owner gemeldete Install-/CLI-Auffaelligkeit im Code behoben wurde.
---

# Dev-Instanz zuruecksetzen (`/reset-dev`)

Iterations-Schleife fuer den **hands-on Install-Test** des Owners: Owner meldet eine Auffaelligkeit im
Installations-/CLI-Ablauf → Code aendern → **`/reset-dev`** → Owner installiert erneut interaktiv.
Der Owner faehrt die Installation **selbst** (TTY-Dialog, Prompts, gum-Menues) — Claude startet sie **nie**.

## Ablauf

1. **Vorbedingung pruefen:** wurden Build-Defs (`packages/*/build/**`) geaendert → vorher
   `.\scripts\build\build.ps1` (sonst sind die getrackten Workflow-JSONs veraltet). Sonst nicht bauen: ohne Def-Aenderung
   aendert ein Build nichts (deterministische IDs), er ist nur unnoetig.
2. **Ausfuehren** (PowerShell-Tool, ein Aufruf): `.\scripts\reset_dev_instance.ps1`
   (`-Verbose` = volles Abbau-Log). Zerstoert die Instanz-Daten bewusst (Owner-Entscheid: kein Backup) —
   deshalb nur im **Owner-Fenster**: der Hook `.claude/hooks/enforce_owner_window.ps1` weist den Aufruf sonst ab;
   dann den Owner bitten, im Terminal `.\scripts\grant_owner_window.ps1` auszufuehren (30 Min), und erneut starten.
   `-KeepInstance` (nichts wird abgebaut) ist vom Fenster ausgenommen.
   **Update-Pfad testen** (z. B. „die bestehende Instanz soll das neu fragen"): `-KeepInstance` legt denselben Stand
   bereit, baut aber NICHTS ab (kein Abbau, kein Rest-Check) — `install-dev.sh` laeuft dann als Bestands-Lauf.
3. **Auswerten:**
   - **OK** → dem Owner knapp melden: Stand (`dev-<sha>[-dirty]`), was sich seit dem letzten Durchlauf
     geaendert hat (1–3 Saetze, Owner-Sprache), und den Startbefehl im Container:
     `bash /root/lifeagents-dev/install-dev.sh` (Default `--profile release`, wie `install.sh`).
   - **FEHLER** → Ursache suchen, nicht raten: die `[x]`/`[!]`-Zeilen der Ausgabe lesen; bei Abbau-Fehlern
     read-only per SSH `/root/lifeagents-dev/uninstall.log` ansehen (Ziel/Key aus `.env` `DEV_INSTANCE_*`).
     Exit-Codes: 10 = Upload korrupt · 11 = Shell-Syntaxfehler im Baum · 12 = Abbau gescheitert ·
     13 = Reste nach dem Abbau. Fix im Repo → erneut `/reset-dev`.
4. **Wenn der Owner danach einen Fehler meldet:** Logs read-only pruefen (`journalctl -u n8n`,
   `lifeagents doctor`, Installer-Ausgabe, die der Owner einfuegt), Ursache im Code beheben, wieder Schritt 1.

## Grenzen

- Nur der **lokale Baum** wird getestet: der Download-/Token-Teil von `install.sh` laeuft dabei nicht
  (der Wrapper ersetzt genau diesen Schritt). Den echten Release-Pfad testet ein getaggtes Release.
- Die bisherigen Installer-Eingaben liegen einmalig gerettet unter `/root/lifeagents-dev/saved-env/`
  (root-only, verlassen den Server nie) — **nie** ausgeben oder herunterladen.
- LLM-Suiten werden hier nicht gestartet (Root-CLAUDE.md *Scripts*).
