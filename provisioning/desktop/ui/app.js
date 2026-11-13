// Bildschirme der Start-App. Texte aus dem Textkatalog (packages/core/locales, Schlüssel core.desktop.*, Block unten), eine
// Frage je Bildschirm, ein Hauptknopf, Zurück als Link. Alles Prüfen und Ändern macht die App (Rust,
// lifeagents-desktop-core); hier nur Anzeige. Werte aus dem System (Programmnamen) kommen nur über textContent ins Fenster,
// nie als HTML; `**fett**` im Katalog wird zu <b> als Knoten.
'use strict';

const T = window.__TAURI__;
const invoke = (cmd, args) => T.core.invoke(cmd, args || {});
const listen = (ev, fn) => T.event.listen(ev, (e) => fn(e.payload));

const $ = (id) => document.getElementById(id);
const main = $('screen');
const state = { os: 'mac', startup: null, sys: null, docker: null, power: null, powerYes: true, poll: null, step: null };

/** Kleines Element-Werkzeug: h('p', {class: 'lead'}, 'Text', kind, …) */
function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === false || v == null) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

// ------------------------------------------------------------------------------------------------ Texte

/* ui-locale:begin desktop (erzeugt von scripts/build_ui_tokens.ps1 aus packages/core/locales, nicht von Hand aendern) */
const UI_TEXT = {
  de: {
    "core.art.greeting.alt": "Dein Assistent meldet sich auf dem Handy von selbst mit einem Hinweis und fragt, bevor er etwas speichert. Er läuft auf deinem eigenen Rechner zu Hause, deine Daten liegen bei dir, und er hilft der ganzen Familie bei Finanzen, Karriere, Nachlass und Dokumenten.",
    "core.desktop.apply.busy_text": "Dein {machine} fragt dich gleich, ob die App die Energie-Einstellungen ändern darf.",
    "core.desktop.apply.busy_title": "Bestätige die Änderung",
    "core.desktop.backup_dir.busy_title": "Sicherungsordner wird geöffnet …",
    "core.desktop.backup_dir.title": "Sicherungsordner ändern",
    "core.desktop.backup_restore.area.career": "Karriere",
    "core.desktop.backup_restore.area.core": "Haushalt, Profil und Pläne",
    "core.desktop.backup_restore.area.estate": "Vorsorge & Nachlass",
    "core.desktop.backup_restore.area.finance": "Finanzen",
    "core.desktop.backup_restore.area.paperless": "Dokumente",
    "core.desktop.backup_restore.busy_check": "Sicherung wird geprüft …",
    "core.desktop.backup_restore.busy_list": "Sicherungen werden gesucht …",
    "core.desktop.backup_restore.card_dismiss": "Ausblenden",
    "core.desktop.backup_restore.card_go": "Sicherung wählen",
    "core.desktop.backup_restore.card_text": "Im Sicherungsordner liegen Sicherungen eines anderen Rechners. Hol deine Daten von dort zurück, bevor du neu anfängst.",
    "core.desktop.backup_restore.card_title": "Sicherung vom alten Rechner zurückholen",
    "core.desktop.backup_restore.choose_other": "Andere Sicherung wählen",
    "core.desktop.backup_restore.err.bundle_incomplete": "Diese Sicherung ist unvollständig. Wähle eine andere.",
    "core.desktop.backup_restore.err.busy": "Gerade läuft eine Sicherung, ein Update oder eine Wiederherstellung. Versuch es in ein paar Minuten noch einmal.",
    "core.desktop.backup_restore.err.corrupt": "Diese Sicherung ist beschädigt. Wähle eine andere.",
    "core.desktop.backup_restore.err.corrupt_stored": "Diese Sicherung ist beschädigt. Wähle eine andere.",
    "core.desktop.backup_restore.err.file_too_big": "Diese Datei ist zu groß für eine Sicherung. Wähle eine Datei, die auf „.nla.enc“ endet.",
    "core.desktop.backup_restore.err.folder": "Der Sicherungsordner ist gerade nicht erreichbar.",
    "core.desktop.backup_restore.err.format": "Diese Sicherung stammt aus einer zu alten Fassung und lässt sich nicht mehr lesen. Wähle eine andere.",
    "core.desktop.backup_restore.err.internal": "Etwas ist schiefgegangen.",
    "core.desktop.backup_restore.err.key_expired": "Die App vergisst das Notfallblatt nach 15 Minuten. Wähle oder tippe es bitte noch einmal.",
    "core.desktop.backup_restore.err.key_foreign": "Dieses Notfallblatt gehört nicht zu dieser Sicherung. Gesucht ist das Blatt mit dem Schlüssel {id}.",
    "core.desktop.backup_restore.err.key_format": "Das ist kein Notfallblatt. Wähle die Datei „Life-Agents-Notfallblatt-…“ oder tippe die vier Zeilen ab.",
    "core.desktop.backup_restore.err.key_line": "Zeile {n} stimmt nicht. Prüfe sie Zeichen für Zeichen.",
    "core.desktop.backup_restore.err.key_needed": "Diese Sicherung braucht das Notfallblatt eines anderen Rechners.",
    "core.desktop.backup_restore.err.key_no_open": "Kein Schlüssel auf diesem Blatt öffnet die Sicherung. Ist es das Blatt vom alten Rechner?",
    "core.desktop.backup_restore.err.needs_setup": "Die Sicherung enthält den Bereich „{pkg}“. Richte ihn zuerst ein, dann versuch es noch einmal.",
    "core.desktop.backup_restore.err.no_tables": "In dieser Installation ist nichts zum Zurückholen eingerichtet.",
    "core.desktop.backup_restore.err.nofolder": "Es sind schon eigene Daten da. Wähle zuerst einen Sicherungsordner (Menü › „Sicherungsordner ändern …“), damit vorher gesichert werden kann.",
    "core.desktop.backup_restore.err.package_unknown": "Diese Sicherung enthält einen Bereich, den diese Version nicht kennt. Aktualisiere zuerst.",
    "core.desktop.backup_restore.err.safety": "Die Sicherung deiner jetzigen Daten hat nicht geklappt, darum wurde nichts ersetzt. Prüfe den Sicherungsordner.",
    "core.desktop.backup_restore.err.setup": "Die Einrichtung ist noch nicht fertig.",
    "core.desktop.backup_restore.err.sheet_invalid": "Das ist kein Notfallblatt. Wähle die Datei „Life-Agents-Notfallblatt-…“ oder tippe die vier Zeilen ab.",
    "core.desktop.backup_restore.err.sheet_too_big": "Das ist kein Notfallblatt. Wähle die Datei „Life-Agents-Notfallblatt-…“ oder tippe die vier Zeilen ab.",
    "core.desktop.backup_restore.err.unfinished": "Die Wiederherstellung wurde unterbrochen (Rechner oder Docker aus).",
    "core.desktop.backup_restore.err.unreadable": "Diese Datei lässt sich nicht lesen. Wähle eine Datei, die auf „.nla.enc“ endet.",
    "core.desktop.backup_restore.err.version_newer": "Diese Sicherung stammt aus einer neueren Version ({release}). Aktualisiere zuerst, dann versuch es noch einmal.",
    "core.desktop.backup_restore.err.version_older": "Diese Sicherung stammt aus Version {release}. Sie lässt sich nur in genau diese Version zurückspielen. Die Anleitung zeigt, wie das geht.",
    "core.desktop.backup_restore.fail_title": "Das hat nicht geklappt",
    "core.desktop.backup_restore.go": "Wiederherstellen",
    "core.desktop.backup_restore.go_replace": "Ja, ersetzen",
    "core.desktop.backup_restore.guide": "Anleitung „Sicherung & neuer Rechner“",
    "core.desktop.backup_restore.key_check": "Prüfen",
    "core.desktop.backup_restore.key_file": "Notfallblatt-Datei wählen …",
    "core.desktop.backup_restore.key_lead": "Diese Sicherung stammt von einem anderen Rechner. Sie öffnet sich nur mit dem Schlüssel auf dessen Notfallblatt.",
    "core.desktop.backup_restore.key_line": "Zeile {n}",
    "core.desktop.backup_restore.key_or": "Oder tippe die vier Zeilen vom Papier ab:",
    "core.desktop.backup_restore.key_title": "Notfallblatt",
    "core.desktop.backup_restore.list_empty": "Im Sicherungsordner liegt noch keine Sicherung. Liegt sie woanders, wähle die Datei.",
    "core.desktop.backup_restore.list_folder": "Der Sicherungsordner ist gerade nicht erreichbar. Prüfe, ob er noch da ist, oder wähle die Datei direkt.",
    "core.desktop.backup_restore.list_lead": "Wähle die Sicherung, die du zurückholen willst.",
    "core.desktop.backup_restore.list_nofolder": "Es ist noch kein Sicherungsordner gewählt. Wähle die Sicherungs-Datei direkt.",
    "core.desktop.backup_restore.ok_foreign": "Ab jetzt öffnen sich deine Sicherungen mit dem Schlüssel vom alten Rechner. Das neue Notfallblatt unten enthält beide Schlüssel.",
    "core.desktop.backup_restore.ok_lead": "Die Daten vom {date} sind wiederhergestellt.",
    "core.desktop.backup_restore.ok_old_machine": "Lass den alten Rechner nicht mehr in diesen Ordner sichern, sonst räumen sich beide gegenseitig alte Sicherungen weg.",
    "core.desktop.backup_restore.ok_safety": "Die Daten von vorher liegen als Sicherung im Sicherungsordner.",
    "core.desktop.backup_restore.ok_title": "Deine Daten sind zurück",
    "core.desktop.backup_restore.other_file": "Andere Datei wählen …",
    "core.desktop.backup_restore.pick_file": "Sicherungsdatei wählen …",
    "core.desktop.backup_restore.pkg_activate": "wird wieder eingeschaltet",
    "core.desktop.backup_restore.pkg_install": "wird dazu eingerichtet",
    "core.desktop.backup_restore.preview_areas": "Diese Bereiche kommen zurück:",
    "core.desktop.backup_restore.preview_confirm": "Mir ist klar, dass meine jetzigen Daten ersetzt werden (vorher wird gesichert).",
    "core.desktop.backup_restore.preview_empty": "Hier sind noch keine eigenen Daten, es wird nichts überschrieben.",
    "core.desktop.backup_restore.preview_lead": "Sicherung vom {date}",
    "core.desktop.backup_restore.preview_replace": "Deine jetzigen Daten werden dabei ersetzt. Vorher legt die App automatisch eine Sicherung davon im Sicherungsordner an.",
    "core.desktop.backup_restore.preview_sheet": "Danach gilt das Notfallblatt vom alten Rechner.",
    "core.desktop.backup_restore.preview_title": "Das wird zurückgeholt",
    "core.desktop.backup_restore.running_text": "Das dauert meist unter einer Minute. Du kannst das Fenster schließen, es läuft weiter.",
    "core.desktop.backup_restore.running_title": "Wird wiederhergestellt …",
    "core.desktop.backup_restore.tag_other": "vom alten Rechner",
    "core.desktop.backup_restore.tag_version": "andere Version",
    "core.desktop.backup_restore.tag_version_text": "Passt nicht zu dieser Installation, das Zurückholen klappt vermutlich nicht.",
    "core.desktop.backup_restore.title": "Sicherung wiederherstellen",
    "core.desktop.backup_restore.unchanged": "Deine Daten sind unverändert.",
    "core.desktop.backup_restore.version": "Version {release}",
    "core.desktop.backup_restore.version_unknown": "Version unbekannt",
    "core.desktop.changes.install_docker": "Docker kommt dazu (rund {size} MB, direkt vom Hersteller)",
    "core.desktop.changes.journal": "Eine kleine Datei, in der sich die App ihre Schritte merkt, damit sie alles zurücknehmen kann",
    "core.desktop.changes.keep_docker": "Docker selbst: keine neue Version, kein Neustart",
    "core.desktop.changes.keep_files": "Deine Dateien und die Festplatten-Verschlüsselung",
    "core.desktop.changes.keep_power": "Die Energie-Einstellungen, bis du am Ende Ja sagst",
    "core.desktop.changes.keep_title": "Das bleibt, wie es ist",
    "core.desktop.changes.start_docker": "{engine} wird gestartet",
    "core.desktop.changes.title": "Das wird geändert",
    "core.desktop.changes.wizard": "Der Fragebogen, der dir gleich die Fragen stellt. Alles Weitere erst, wenn du am Ende des Fragebogens zustimmst",
    "core.desktop.check.backup": "Time Machine sichert gerade",
    "core.desktop.check.backup_need": "Besser danach weitermachen.",
    "core.desktop.check.battery": "Dein Rechner läuft gerade auf Akku",
    "core.desktop.check.battery_need": "Schließ ihn besser ans Netzteil an.",
    "core.desktop.check.disk": "Freier Platz: {value} GB",
    "core.desktop.check.disk_need": "Nötig sind mindestens {need} GB.",
    "core.desktop.check.os_mac": "macOS {value}",
    "core.desktop.check.os_mac_need": "Das Hilfsprogramm Docker braucht macOS {need} oder neuer.",
    "core.desktop.check.os_win": "Windows (Build {value})",
    "core.desktop.check.os_win_need": "Das Hilfsprogramm Docker braucht Windows 10 22H2 oder Windows 11.",
    "core.desktop.check.ram": "Arbeitsspeicher: {value} GB",
    "core.desktop.check.ram_need": "Das Hilfsprogramm Docker braucht mindestens {need} GB.",
    "core.desktop.check.virt": "Die Virtualisierung ist ausgeschaltet",
    "core.desktop.check.virt_need": "Docker braucht sie. Sie lässt sich in den Einstellungen beim Start des Rechners (BIOS) einschalten.",
    "core.desktop.check.wsl": "Windows richtet beim Einrichten von Docker noch einen Linux-Teil ein",
    "core.desktop.check.wsl_need": "Danach ist ein Neustart nötig.",
    "core.desktop.common.back": "Zurück",
    "core.desktop.common.changed_nothing": "Die App hat nichts geändert.",
    "core.desktop.common.check_again": "Noch einmal prüfen",
    "core.desktop.common.close_window": "Du kannst dieses Fenster schließen.",
    "core.desktop.common.come_back": "Komm hierher zurück.",
    "core.desktop.common.next": "Weiter",
    "core.desktop.common.open_telegram": "Telegram öffnen",
    "core.desktop.common.retry": "Noch einmal versuchen",
    "core.desktop.common.view_report": "Fehlerbericht ansehen",
    "core.desktop.core.busy_text": "Das dauert beim ersten Mal ein paar Minuten.",
    "core.desktop.core.busy_title": "Der Fragebogen wird vorbereitet",
    "core.desktop.docker.busy_text": "Ist Docker auf diesem {machine} schon da, und läuft es?",
    "core.desktop.docker.busy_title": "Docker wird geprüft",
    "core.desktop.done.backup": "Deine Daten werden ab jetzt jeden Tag in den gewählten Ordner gesichert.",
    "core.desktop.done.deviations": "Bei anderen Programmen in Docker hat sich während der Einrichtung etwas verändert ({n} Stellen). Schick bitte den Fehlerbericht.",
    "core.desktop.done.lead": "Dein Assistent läuft jetzt auf diesem Rechner.",
    "core.desktop.done.title": "Fertig. Schreib deinem Assistenten in Telegram",
    "core.desktop.done.updates": "Neue Versionen meldet dir dein Assistent im Chat. Du tippst auf **Jetzt aktualisieren**, das Update sichert vorher deine Daten.",
    "core.desktop.engine.colima": "Colima (ein anderes Programm für Docker)",
    "core.desktop.engine.docker_desktop": "Docker Desktop",
    "core.desktop.engine.homebrew_docker": "Docker aus Homebrew",
    "core.desktop.engine.orb_stack": "OrbStack",
    "core.desktop.engine.podman": "Podman",
    "core.desktop.engine.rancher_desktop": "Rancher Desktop",
    "core.desktop.engine.remote": "ein Docker, das auf einem anderen Rechner läuft",
    "core.desktop.engine.unknown": "ein Docker, das die App nicht kennt",
    "core.desktop.engine.wsl": "eine eigene Docker-Engine im Linux-Teil von Windows",
    "core.desktop.error.again": "Wenn es wieder passiert, schick den Fehlerbericht an die Person, die dir die App gegeben hat.",
    "core.desktop.error.compose_missing": "In dieser Test-Fassung fehlt noch ein Teil des Assistenten.",
    "core.desktop.error.docker_capability": "Deinem Docker fehlt etwas, das der Assistent braucht. Die App hat nichts gestartet. Bring Docker Desktop auf den neuesten Stand und versuche es noch einmal.",
    "core.desktop.error.docker_closed": "Docker Desktop hat sich wieder geschlossen, bevor es bereit war. Möglicherweise hast du im ersten Fenster die Nutzungsbedingungen von Docker abgelehnt. Öffne Docker Desktop selbst und stimme dort, falls gefragt, den Bedingungen zu. Versuche es dann noch einmal. Ohne Docker kann der Assistent nicht laufen.",
    "core.desktop.error.docker_credentials": "Docker findet sein eigenes Hilfsprogramm für die Anmeldung nicht. Die App hat nichts gestartet. Öffne Docker Desktop einmal selbst, warte, bis es läuft, und versuche es noch einmal.",
    "core.desktop.error.docker_disk": "Auf dem Rechner ist kein Platz mehr auf der Festplatte frei. Die App hat nichts gestartet. Lösche nicht benötigte Dateien oder Programme und versuche es noch einmal.",
    "core.desktop.error.docker_network": "Docker konnte etwas aus dem Internet nicht laden. Die App hat nichts gestartet. Prüfe die Internet-Verbindung und versuche es noch einmal.",
    "core.desktop.error.docker_start_timeout": "Docker antwortet nicht. Öffne Docker Desktop einmal selbst und warte, bis es läuft.",
    "core.desktop.error.docker_unsupported": "Docker ist hier in einer Form da, die die App nicht verändert.",
    "core.desktop.error.download_failed": "Docker ließ sich nicht laden. Prüfe die Internet-Verbindung und versuche es noch einmal.",
    "core.desktop.error.foreign_objects": "In Docker gibt es schon etwas mit dem Namen lifeagents, das nicht von dieser App stammt. Die App ändert daran nichts.",
    "core.desktop.error.install_cancelled": "Du hast die Passwort-Abfrage abgebrochen. Es wurde nichts installiert.",
    "core.desktop.error.install_failed": "Docker ließ sich nicht einrichten.",
    "core.desktop.error.journal_unreadable": "Die App kann ihre Notizen zur Einrichtung nicht lesen.",
    "core.desktop.error.no_free_port": "Auf diesem Rechner ist kein passender Anschluss frei (5880 bis 5899).",
    "core.desktop.error.power_cancelled": "Du hast die Abfrage abgebrochen. Die Einstellungen bleiben, wie sie waren.",
    "core.desktop.error.power_failed": "Die Energie-Einstellungen ließen sich nicht ändern.",
    "core.desktop.error.rollback_failed": "Nicht alles ließ sich zurücknehmen. Du kannst es gleich noch einmal versuchen.",
    "core.desktop.error.signature_failed": "Die geladene Datei ließ sich nicht als echte Datei von Docker bestätigen. Die App hat sie gelöscht und nichts installiert.",
    "core.desktop.error.start_failed": "Der Assistent ließ sich nicht starten.",
    "core.desktop.error.system_blocked": "Dieser Rechner reicht leider nicht.",
    "core.desktop.error.title": "Das hat nicht geklappt",
    "core.desktop.error.unknown": "Etwas ist schiefgegangen.",
    "core.desktop.error.wizard_unavailable": "Der Fragebogen antwortet nicht.",
    "core.desktop.fetch.download": "Docker laden",
    "core.desktop.fetch.download_progress": "Docker laden ({done} von rund {total} MB)",
    "core.desktop.fetch.lead": "Du kannst das Fenster offen lassen und etwas anderes tun, bis dein {machine} etwas von dir möchte.",
    "core.desktop.fetch.password_mac": "Dein Mac fragt nach deinem Passwort: eingeben und bestätigen",
    "core.desktop.fetch.password_win": "Windows fragt, ob die App etwas ändern darf: mit Ja bestätigen",
    "core.desktop.fetch.start": "Docker starten",
    "core.desktop.fetch.title": "Docker wird geholt",
    "core.desktop.fetch.verify": "Prüfen, ob die Datei wirklich vom Hersteller stammt",
    "core.desktop.finish.busy_text": "Start bei der Anmeldung eintragen und nachsehen, ob alles andere unverändert ist",
    "core.desktop.finish.busy_title": "Einen Moment",
    "core.desktop.help.lead": "Auf diesem {machine} gibt es schon {what}. Die App installiert nichts dazu und ändert daran nichts, damit nichts kaputtgeht.",
    "core.desktop.help.link": "Hilfe auf der Projekt-Seite lesen",
    "core.desktop.help.note": "Die App hat nichts geändert. Schick den Fehlerbericht an die Person, die dir die App gegeben hat.",
    "core.desktop.help.title": "Hier brauchst du kurz Hilfe",
    "core.desktop.home.lead_mac": "Oben in der Menüleiste siehst du am Symbol der App, ob alles läuft. Dieses Fenster kannst du schließen.",
    "core.desktop.home.lead_win": "Unten neben der Uhr siehst du am Symbol der App, ob alles läuft. Dieses Fenster kannst du schließen.",
    "core.desktop.home.title": "Dein Assistent ist eingerichtet",
    "core.desktop.kit.busy_title": "Notfallblatt wird gespeichert …",
    "core.desktop.kit.button": "Notfallblatt speichern",
    "core.desktop.kit.check": "Ich habe das Notfallblatt ausgedruckt oder sicher gespeichert.",
    "core.desktop.kit.close": "Fertig",
    "core.desktop.kit.file_name": "Life-Agents-Notfallblatt",
    "core.desktop.kit.lead": "Auf einem neuen Rechner öffnet sich eine Sicherung nur mit dem Schlüssel auf diesem Blatt. Drucke es aus oder lege es in deinen Passwort-Manager. Leg es nicht in den Sicherungsordner.",
    "core.desktop.kit.menu_title": "Notfallblatt",
    "core.desktop.kit.next_hint": "„{button}“ geht, sobald du das abgehakt hast.",
    "core.desktop.kit.saved": "Gespeichert in Downloads: {file}. Lösche diese Datei, sobald das Blatt ausgedruckt oder sicher gespeichert ist.",
    "core.desktop.kit.title": "Noch ein Schritt: Notfallblatt speichern",
    "core.desktop.kit.unavailable": "Docker läuft gerade nicht. Starte Docker und versuche es noch einmal.",
    "core.desktop.kit.write_failed": "Das Notfallblatt ließ sich nicht in „Downloads“ speichern.",
    "core.desktop.machine.mac": "Mac",
    "core.desktop.machine.pc": "PC",
    "core.desktop.memory.lead": "Frei sind {free} GB, der Assistent braucht {need} GB. Die App ändert daran nichts, weil sich die anderen Programme in Docker den Speicher teilen.",
    "core.desktop.memory.step_open": "Öffne **Docker Desktop** und dort die Einstellungen.",
    "core.desktop.memory.step_resources": "Unter **Resources** (so heißt der Punkt dort) gibst du Docker mehr Arbeitsspeicher.",
    "core.desktop.memory.title": "In Docker ist zu wenig Arbeitsspeicher frei",
    "core.desktop.missing.lead": "Es heißt **Docker** und hält deinen Assistenten sauber getrennt vom Rest deines Rechners. Du musst es nie selbst bedienen. Die App holt es direkt vom Hersteller und richtet es ein.",
    "core.desktop.missing.next": "Einverstanden, Docker holen",
    "core.desktop.missing.terms": "Für private Nutzung ist Docker kostenlos. Der Hersteller hat eigene Nutzungsbedingungen.",
    "core.desktop.missing.terms_link": "Hier kannst du sie lesen.",
    "core.desktop.missing.title": "Die App braucht ein Hilfsprogramm",
    "core.desktop.move.folder": "Programme",
    "core.desktop.move.lead": "Die App läuft gerade noch aus der geladenen Datei. So kann sie später nicht von selbst starten.",
    "core.desktop.move.step_drag": "Zieh im Fenster der geladenen Datei das Symbol lifeagents auf den Ordner Programme.",
    "core.desktop.move.step_open": "Öffne lifeagents dann aus dem Programme-Ordner.",
    "core.desktop.move.step_quit": "Beende die App.",
    "core.desktop.move.title": "Zieh die App zuerst in den Programme-Ordner",
    "core.desktop.need.card": "**Eine Kreditkarte.** Die KI von Anthropic rechnet nach Verbrauch direkt mit dir ab. Das Projekt selbst ist kostenlos.",
    "core.desktop.need.hint": "Ein Mac mini oder ein anderer Rechner, der immer am Strom hängt, passt am besten.",
    "core.desktop.need.intro": "Lege dir kurz diese drei Dinge bereit:",
    "core.desktop.need.machine": "**Diesen Rechner, und er bleibt an.** Dein Assistent läuft hier. Am Ende fragen wir dich, ob der Rechner dafür durchlaufen soll.",
    "core.desktop.need.next": "Rechner prüfen",
    "core.desktop.need.phone": "**Dein Handy.** Darüber sprichst du später mit deinem Assistenten. Falls Telegram noch fehlt, richten wir es unterwegs gemeinsam ein.",
    "core.desktop.need.title": "Das brauchst du dafür",
    "core.desktop.nowizard.lead": "Alles bis hierher war echt: Die App hat deinen {machine} und Docker geprüft. Den Fragebogen bringt eine spätere Fassung.",
    "core.desktop.nowizard.next": "Weiter zum Dauerbetrieb",
    "core.desktop.nowizard.note": "Die übrigen Schritte der App kannst du trotzdem ausprobieren.",
    "core.desktop.nowizard.title": "Der Fragebogen fehlt in dieser Test-Fassung noch",
    "core.desktop.old.lead": "Docker läuft schon auf deinem {machine}, aber die App braucht eine neuere Version. Die App aktualisiert es nicht selbst, weil dort vielleicht andere Programme laufen.",
    "core.desktop.old.step_open": "Öffne **Docker Desktop**.",
    "core.desktop.old.step_update": "Starte dort das Update.",
    "core.desktop.old.title": "Dein Docker ist zu alt",
    "core.desktop.other.lead": "Auf diesem {machine} ist {engine} installiert, aber gerade aus. Die App installiert kein zweites Docker daneben. Starte {engine} und komm hierher zurück.",
    "core.desktop.other.title": "Bitte starte zuerst {engine}",
    "core.desktop.power.laptop": "Dein Rechner hat einen Akku. Das gilt nur am Netzteil: Zugeklappt oder auf Akku schläft er trotzdem ein.",
    "core.desktop.power.lead_mac": "Der Bildschirm geht nach 10 Minuten aus, und der Mac arbeitet leise weiter. So antwortet dein Assistent jederzeit.",
    "core.desktop.power.lead_win": "Der Bildschirm geht nach 10 Minuten aus, und der PC arbeitet weiter. So antwortet dein Assistent jederzeit.",
    "core.desktop.power.next_confirm": "Weiter zur Bestätigung",
    "core.desktop.power.no_text": "Schläft dein Rechner, antwortet dein Assistent erst, wenn der Rechner wieder wach ist.",
    "core.desktop.power.no_title": "Nein, ich lasse alles, wie es ist",
    "core.desktop.power.recommended": "empfohlen",
    "core.desktop.power.title": "Soll dieser Rechner durchlaufen?",
    "core.desktop.power.yes_mac": "Er schläft nicht mehr ein und startet nach einem Stromausfall von selbst. Ein Mac mini kostet so rund 10 bis 20 € Strom im Jahr.",
    "core.desktop.power.yes_title": "Ja, er soll durchlaufen",
    "core.desktop.power.yes_win": "Er schläft nicht mehr ein. Ein PC braucht deutlich mehr Strom als ein Mac mini.",
    "core.desktop.ready.lead": "Du musst nichts installieren. Die App legt sich daneben und fasst nichts an, was schon läuft.",
    "core.desktop.ready.memory": "Genug freier Arbeitsspeicher auch für den Assistenten",
    "core.desktop.ready.next": "Einverstanden, weiter",
    "core.desktop.ready.programs_many": "In Docker laufen schon {n} Programme, zum Beispiel {name}. Sie bleiben, wie sie sind.",
    "core.desktop.ready.programs_none": "In Docker läuft gerade nichts anderes.",
    "core.desktop.ready.programs_one": "In Docker läuft schon {name}. Es bleibt, wie es ist.",
    "core.desktop.ready.running": "{engine} läuft und ist aktuell genug",
    "core.desktop.ready.title": "Docker ist schon da, wir nutzen es mit",
    "core.desktop.ready.untested": "Die App ist mit Docker Desktop getestet. {engine} sollte genauso gehen, sicher ist das nicht.",
    "core.desktop.report.copied": "Kopiert",
    "core.desktop.report.copy": "Kopieren",
    "core.desktop.report.lead": "Er enthält nur feste Angaben zum Rechner und zu Docker, keine Namen, keine Adressen und keine Daten. Kopiere ihn in eine Nachricht an die Person, die dir die App gegeben hat.",
    "core.desktop.report.title": "Fehlerbericht",
    "core.desktop.restore.done_title": "Die alten Einstellungen gelten wieder",
    "core.desktop.restore.lead": "Dein {machine} bekommt seine alten Energie-Einstellungen zurück. Danach schläft er wieder ein, und dein Assistent antwortet erst, wenn er wach ist.",
    "core.desktop.restore.next": "Alte Einstellungen wiederherstellen",
    "core.desktop.restore.title": "Dauerbetrieb zurückstellen?",
    "core.desktop.result.as_before": "Der Rechner schläft wie bisher, dein Assistent wartet dann",
    "core.desktop.result.autostart": "Nach deiner Anmeldung starten Docker und dein Assistent von selbst",
    "core.desktop.result.display_bad": "Der Bildschirm-Wert ließ sich nicht setzen",
    "core.desktop.result.display_ok": "Der Bildschirm geht nach 10 Minuten aus",
    "core.desktop.result.filevault": "**Eine Sache bleibt von Hand:** Dein Mac verschlüsselt seine Festplatte. Das schützt deine Daten, falls jemand ihn mitnimmt. Nach einem Stromausfall wartet er deshalb auf dein Passwort. Bis du dich angemeldet hast, schweigt dein Assistent, und er kann dir das auch nicht vorher sagen.",
    "core.desktop.result.next": "Fertig stellen",
    "core.desktop.result.restart_bad": "Der Start nach einem Stromausfall ließ sich nicht einschalten",
    "core.desktop.result.restart_ok": "Nach einem Stromausfall startet er von selbst",
    "core.desktop.result.restore_hint": "Das alte Verhalten kannst du jederzeit über das Symbol der App zurückholen.",
    "core.desktop.result.sleep_bad": "Der Rechner kann weiter einschlafen; die Einstellung hat nicht gegriffen",
    "core.desktop.result.sleep_ok": "Der Rechner schläft nicht mehr ein",
    "core.desktop.result.title": "So verhält sich dein Rechner jetzt",
    "core.desktop.result.windows_login": "**Eine Sache bleibt von Hand:** Nach einem Neustart, zum Beispiel durch ein Windows-Update, musst du dich einmal anmelden. Bis dahin schweigt dein Assistent.",
    "core.desktop.result.womp_bad": "Wecken übers Netz ließ sich nicht einschalten",
    "core.desktop.resume.lead": "Die App hat sich gemerkt, wie weit sie gekommen ist. Du kannst dort weitermachen oder alles zurücknehmen, was sie bisher geändert hat.",
    "core.desktop.resume.next": "Weiter einrichten",
    "core.desktop.resume.note": "Zurücknehmen lässt deine Daten und andere Programme in Ruhe. Docker selbst bleibt installiert.",
    "core.desktop.resume.rollback": "Alles zurücknehmen",
    "core.desktop.resume.title": "Die Einrichtung wurde unterbrochen",
    "core.desktop.rollback.busy_text": "Schritte der Einrichtung zurücknehmen",
    "core.desktop.rollback.busy_title": "Alles wird zurückgenommen",
    "core.desktop.rollback.lead": "Andere Programme und deine Dateien sind unberührt. Docker selbst bleibt auf deinem Rechner; entfernen kannst du es über „Deinstallieren“.",
    "core.desktop.rollback.restart": "Neu beginnen",
    "core.desktop.rollback.title": "Die Änderungen der App sind zurückgenommen",
    "core.desktop.stopped.lead": "Die App installiert nichts dazu. Sie startet Docker und nutzt es mit.",
    "core.desktop.stopped.next": "Einverstanden, Docker starten",
    "core.desktop.stopped.title": "Docker ist da, aber gerade aus",
    "core.desktop.sys.arm": "Mac mit Apple-Chip",
    "core.desktop.sys.busy_text": "Bauart, System, Speicher und freier Platz",
    "core.desktop.sys.busy_title": "Dein {machine} wird geprüft",
    "core.desktop.sys.hints_note": "Das ist kein Hindernis. Wenn du magst, mach später weiter: Bis hierher hat die App nichts verändert.",
    "core.desktop.sys.hints_title": "Fast alles passt",
    "core.desktop.sys.intel": "Mac mit Intel-Prozessor",
    "core.desktop.sys.next_anyway": "Trotzdem weiter",
    "core.desktop.sys.ok_title": "Dein {machine} passt",
    "core.desktop.sys.stop_title": "Dieser Rechner reicht leider nicht",
    "core.desktop.tidy.button": "Download wegräumen",
    "core.desktop.tidy.done_text": "Die Datei {file} liegt jetzt im Papierkorb. Dort kannst du sie bei Bedarf zurückholen.",
    "core.desktop.tidy.done_title": "Aufgeräumt",
    "core.desktop.tidy.text": "Die geladene Datei {file} brauchst du nicht mehr. Die App legt sie in den Papierkorb.",
    "core.desktop.tidy.title": "Zum Schluss: aufräumen",
    "core.desktop.tray.backup_dir": "Sicherungsordner ändern …",
    "core.desktop.tray.backup_kit": "Notfallblatt speichern …",
    "core.desktop.tray.backup_restore": "Sicherung wiederherstellen …",
    "core.desktop.tray.checking": "Wird geprüft …",
    "core.desktop.tray.open": "Fenster öffnen",
    "core.desktop.tray.power_restore": "Dauerbetrieb zurückstellen",
    "core.desktop.tray.quit": "App beenden",
    "core.desktop.tray.report": "Fehlerbericht",
    "core.desktop.tray.restoring": "Wiederherstellung läuft …",
    "core.desktop.tray.running": "Assistent läuft",
    "core.desktop.tray.stopped": "Assistent ist aus: Docker läuft nicht",
    "core.desktop.tray.telegram": "Telegram öffnen",
    "core.desktop.tray.uninstall": "Deinstallieren",
    "core.desktop.uninstall.autostart": "Nicht mehr bei der Anmeldung starten",
    "core.desktop.uninstall.autostart_text": "Ohne diesen Eintrag startet die App nur, wenn du sie öffnest.",
    "core.desktop.uninstall.busy_text": "Assistent anhalten und seine Teile entfernen",
    "core.desktop.uninstall.busy_title": "Wird entfernt",
    "core.desktop.uninstall.data": "Auch meine Daten löschen",
    "core.desktop.uninstall.data_text": "Gespräche, Belege und Einstellungen des Assistenten. Das lässt sich nicht rückgängig machen.",
    "core.desktop.uninstall.docker": "Docker Desktop entfernen",
    "core.desktop.uninstall.docker_text": "Nur sinnvoll, wenn kein anderes Programm Docker braucht.",
    "core.desktop.uninstall.lead": "Der Assistent wird angehalten, und seine Teile in Docker verschwinden. Andere Programme in Docker bleiben, wie sie sind. Alles Weitere wählst du hier.",
    "core.desktop.uninstall.next": "Jetzt deinstallieren",
    "core.desktop.uninstall.power": "Dauerbetrieb zurückstellen",
    "core.desktop.uninstall.power_text": "Dein Rechner bekommt seine alten Energie-Einstellungen und schläft wieder wie früher.",
    "core.desktop.uninstall.title": "Was soll beim Deinstallieren weg?",
    "core.desktop.uninstalled.autostart_bad": "Der Start bei der Anmeldung ließ sich nicht entfernen",
    "core.desktop.uninstalled.autostart_kept": "Die App startet weiter bei der Anmeldung",
    "core.desktop.uninstalled.autostart_ok": "Die App startet nicht mehr bei der Anmeldung",
    "core.desktop.uninstalled.data_bad": "Deine Daten ließen sich nicht ganz löschen",
    "core.desktop.uninstalled.data_kept": "Deine Daten sind noch da",
    "core.desktop.uninstalled.data_ok": "Deine Daten sind gelöscht",
    "core.desktop.uninstalled.deviations": "Bei anderen Programmen in Docker hat sich etwas verändert ({n} Stellen). Schick bitte den Fehlerbericht.",
    "core.desktop.uninstalled.docker_bad": "Docker ließ sich nicht entfernen",
    "core.desktop.uninstalled.docker_kept": "Docker bleibt installiert",
    "core.desktop.uninstalled.docker_ok": "Docker ist entfernt",
    "core.desktop.uninstalled.failed": "Nicht alles ließ sich entfernen. Der Fehlerbericht nennt die Stellen.",
    "core.desktop.uninstalled.others_ok": "Alle anderen Programme in Docker sind unverändert",
    "core.desktop.uninstalled.power_bad": "Die alten Energie-Einstellungen ließen sich nicht wiederherstellen",
    "core.desktop.uninstalled.power_kept": "Der Dauerbetrieb bleibt eingeschaltet",
    "core.desktop.uninstalled.power_ok": "Die alten Energie-Einstellungen gelten wieder",
    "core.desktop.uninstalled.stopped": "Der Assistent ist angehalten, seine Teile in Docker sind weg",
    "core.desktop.uninstalled.title": "Der Assistent ist entfernt",
    "core.desktop.uninstalled.title_partial": "Fast alles ist entfernt",
    "core.desktop.uninstalled.trash_app": "Die App selbst kannst du jetzt in den Papierkorb ziehen.",
    "core.desktop.wait.text": "Warten, bis Docker antwortet. Das dauert beim ersten Mal ein bis zwei Minuten. Gleich öffnet sich ein Fenster von Docker. Du kannst es einfach schließen, Docker läuft trotzdem weiter. Anmelden musst du dich dort nicht.",
    "core.desktop.wait.title": "Docker startet",
    "core.desktop.wait.title_fresh": "Docker wird gestartet",
    "core.desktop.welcome.lead": "Du beantwortest eine Frage nach der anderen. Am Ende schreibst du in Telegram mit deinem Assistenten (dort heißt er Bot), und deine Daten bleiben auf diesem Rechner.",
    "core.desktop.welcome.start": "Loslegen",
    "core.desktop.welcome.time": "Plane rund 30 Minuten ein. Du kannst jederzeit aufhören und später genau hier weitermachen.",
    "core.desktop.welcome.title": "Dein eigener Assistent, in ein paar Schritten",
    "core.wizard.step.about": "Über dich",
    "core.wizard.step.access": "Zugänge",
    "core.wizard.step.aria": "Schritte der Einrichtung",
    "core.wizard.step.check": "Prüfen",
    "core.wizard.step.connect": "Verbinden",
    "core.wizard.step.docker": "Docker",
    "core.wizard.step.done": "Fertig",
    "core.wizard.step.install": "Installation",
    "core.wizard.step.modules": "Module",
    "core.wizard.step.power": "Dauerbetrieb",
    "core.wizard.step.prepare": "Vorbereiten",
    "core.wizard.step.questions": "Fragen",
    "core.wizard.step.reach": "Erreichbarkeit",
    "core.wizard.step.short": "Schritt {n} von {total} · {name}",
  },
  en: {
    "core.art.greeting.alt": "Your assistant gets in touch on your phone by itself and asks before it saves anything. It runs on your own computer at home, your data lives with you, and it helps the whole family with finances, career, inheritance and documents.",
    "core.desktop.apply.busy_text": "Your {machine} will ask you in a moment whether the app may change the energy settings.",
    "core.desktop.apply.busy_title": "Confirm the change",
    "core.desktop.backup_dir.busy_title": "Opening the backup folder setting …",
    "core.desktop.backup_dir.title": "Change backup folder",
    "core.desktop.backup_restore.area.career": "Career",
    "core.desktop.backup_restore.area.core": "Household, profile and plans",
    "core.desktop.backup_restore.area.estate": "Provisions & estate",
    "core.desktop.backup_restore.area.finance": "Finances",
    "core.desktop.backup_restore.area.paperless": "Documents",
    "core.desktop.backup_restore.busy_check": "Checking the backup …",
    "core.desktop.backup_restore.busy_list": "Looking for backups …",
    "core.desktop.backup_restore.card_dismiss": "Hide",
    "core.desktop.backup_restore.card_go": "Choose backup",
    "core.desktop.backup_restore.card_text": "The backup folder contains backups from another computer. Bring your data back from there before you start afresh.",
    "core.desktop.backup_restore.card_title": "Bring back the backup from your old computer",
    "core.desktop.backup_restore.choose_other": "Choose another backup",
    "core.desktop.backup_restore.err.bundle_incomplete": "This backup is incomplete. Choose another one.",
    "core.desktop.backup_restore.err.busy": "A backup, an update or a restore is running right now. Try again in a few minutes.",
    "core.desktop.backup_restore.err.corrupt": "This backup is damaged. Choose another one.",
    "core.desktop.backup_restore.err.corrupt_stored": "This backup is damaged. Choose another one.",
    "core.desktop.backup_restore.err.file_too_big": "This file is too big for a backup. Choose a file that ends in “.nla.enc”.",
    "core.desktop.backup_restore.err.folder": "The backup folder cannot be reached right now.",
    "core.desktop.backup_restore.err.format": "This backup comes from a version that is too old and can no longer be read. Choose another one.",
    "core.desktop.backup_restore.err.internal": "Something went wrong.",
    "core.desktop.backup_restore.err.key_expired": "The app forgets the emergency sheet after 15 minutes. Please choose or type it again.",
    "core.desktop.backup_restore.err.key_foreign": "This emergency sheet does not belong to this backup. The sheet with the key {id} is needed.",
    "core.desktop.backup_restore.err.key_format": "That is not an emergency sheet. Choose the file “Life-Agents-Emergency-Sheet-…” or type the four lines.",
    "core.desktop.backup_restore.err.key_line": "Line {n} is not right. Check it character by character.",
    "core.desktop.backup_restore.err.key_needed": "This backup needs the emergency sheet of another computer.",
    "core.desktop.backup_restore.err.key_no_open": "No key on this sheet opens the backup. Is it the sheet of the old computer?",
    "core.desktop.backup_restore.err.needs_setup": "The backup contains the area “{pkg}”. Set it up first, then try again.",
    "core.desktop.backup_restore.err.no_tables": "Nothing is set up in this installation that could be brought back.",
    "core.desktop.backup_restore.err.nofolder": "There is already data of your own. Choose a backup folder first (menu › “Change backup folder …”) so that a backup can be made first.",
    "core.desktop.backup_restore.err.package_unknown": "This backup contains an area this version does not know. Update first.",
    "core.desktop.backup_restore.err.safety": "Backing up your current data did not work, so nothing was replaced. Check the backup folder.",
    "core.desktop.backup_restore.err.setup": "The setup is not finished yet.",
    "core.desktop.backup_restore.err.sheet_invalid": "That is not an emergency sheet. Choose the file “Life-Agents-Emergency-Sheet-…” or type the four lines.",
    "core.desktop.backup_restore.err.sheet_too_big": "That is not an emergency sheet. Choose the file “Life-Agents-Emergency-Sheet-…” or type the four lines.",
    "core.desktop.backup_restore.err.unfinished": "The restore was interrupted (computer or Docker switched off).",
    "core.desktop.backup_restore.err.unreadable": "This file cannot be read. Choose a file that ends in “.nla.enc”.",
    "core.desktop.backup_restore.err.version_newer": "This backup comes from a newer version ({release}). Update first, then try again.",
    "core.desktop.backup_restore.err.version_older": "This backup comes from version {release}. It can only be restored into exactly that version. The guide shows how.",
    "core.desktop.backup_restore.fail_title": "That did not work",
    "core.desktop.backup_restore.go": "Restore",
    "core.desktop.backup_restore.go_replace": "Yes, replace",
    "core.desktop.backup_restore.guide": "Guide “Backup & new computer”",
    "core.desktop.backup_restore.key_check": "Check",
    "core.desktop.backup_restore.key_file": "Choose emergency sheet file …",
    "core.desktop.backup_restore.key_lead": "This backup comes from another computer. It only opens with the key on that computer's emergency sheet.",
    "core.desktop.backup_restore.key_line": "Line {n}",
    "core.desktop.backup_restore.key_or": "Or type the four lines from the paper:",
    "core.desktop.backup_restore.key_title": "Emergency sheet",
    "core.desktop.backup_restore.list_empty": "There is no backup in the backup folder yet. If it is somewhere else, choose the file.",
    "core.desktop.backup_restore.list_folder": "The backup folder cannot be reached right now. Check that it is still there, or choose the file directly.",
    "core.desktop.backup_restore.list_lead": "Choose the backup you want to bring back.",
    "core.desktop.backup_restore.list_nofolder": "No backup folder is chosen yet. Choose the backup file directly.",
    "core.desktop.backup_restore.ok_foreign": "From now on your backups open with the key of the old computer. The new emergency sheet below contains both keys.",
    "core.desktop.backup_restore.ok_lead": "The data from {date} has been restored.",
    "core.desktop.backup_restore.ok_old_machine": "Don't let the old computer back up into this folder any more, otherwise both remove each other's old backups.",
    "core.desktop.backup_restore.ok_safety": "The data from before is in the backup folder as a backup.",
    "core.desktop.backup_restore.ok_title": "Your data is back",
    "core.desktop.backup_restore.other_file": "Choose another file …",
    "core.desktop.backup_restore.pick_file": "Choose backup file …",
    "core.desktop.backup_restore.pkg_activate": "will be switched on again",
    "core.desktop.backup_restore.pkg_install": "will be set up as well",
    "core.desktop.backup_restore.preview_areas": "These areas come back:",
    "core.desktop.backup_restore.preview_confirm": "I understand that my current data will be replaced (a backup is made first).",
    "core.desktop.backup_restore.preview_empty": "There is no data of your own here yet, nothing will be overwritten.",
    "core.desktop.backup_restore.preview_lead": "Backup from {date}",
    "core.desktop.backup_restore.preview_replace": "Your current data will be replaced. Before that, the app saves a backup of it in the backup folder.",
    "core.desktop.backup_restore.preview_sheet": "Afterwards the emergency sheet of the old computer applies.",
    "core.desktop.backup_restore.preview_title": "This will come back",
    "core.desktop.backup_restore.running_text": "This usually takes less than a minute. You can close the window, it keeps running.",
    "core.desktop.backup_restore.running_title": "Restoring …",
    "core.desktop.backup_restore.tag_other": "from the old computer",
    "core.desktop.backup_restore.tag_version": "different version",
    "core.desktop.backup_restore.tag_version_text": "Does not match this installation, restoring will probably not work.",
    "core.desktop.backup_restore.title": "Restore a backup",
    "core.desktop.backup_restore.unchanged": "Your data is unchanged.",
    "core.desktop.backup_restore.version": "Version {release}",
    "core.desktop.backup_restore.version_unknown": "Version unknown",
    "core.desktop.changes.install_docker": "Docker is added (about {size} MB, directly from the maker)",
    "core.desktop.changes.journal": "A small file in which the app notes its steps so it can undo everything",
    "core.desktop.changes.keep_docker": "Docker itself: no new version, no restart",
    "core.desktop.changes.keep_files": "Your files and the disk encryption",
    "core.desktop.changes.keep_power": "The energy settings, until you say yes at the end",
    "core.desktop.changes.keep_title": "What stays as it is",
    "core.desktop.changes.start_docker": "{engine} is started",
    "core.desktop.changes.title": "What will change",
    "core.desktop.changes.wizard": "The questionnaire that will ask you the questions in a moment. Everything else only once you agree at the end of the questionnaire",
    "core.desktop.check.backup": "Time Machine is backing up",
    "core.desktop.check.backup_need": "It's best to continue once it has finished.",
    "core.desktop.check.battery": "Your computer is running on battery",
    "core.desktop.check.battery_need": "It's best to plug it in.",
    "core.desktop.check.disk": "Free space: {value} GB",
    "core.desktop.check.disk_need": "At least {need} GB is needed.",
    "core.desktop.check.os_mac": "macOS {value}",
    "core.desktop.check.os_mac_need": "The helper program Docker needs macOS {need} or newer.",
    "core.desktop.check.os_win": "Windows (build {value})",
    "core.desktop.check.os_win_need": "The helper program Docker needs Windows 10 22H2 or Windows 11.",
    "core.desktop.check.ram": "Memory: {value} GB",
    "core.desktop.check.ram_need": "The helper program Docker needs at least {need} GB.",
    "core.desktop.check.virt": "Virtualization is turned off",
    "core.desktop.check.virt_need": "Docker needs it. You can turn it on in the settings that appear when the computer starts (BIOS).",
    "core.desktop.check.wsl": "Windows will set up a Linux part while installing Docker",
    "core.desktop.check.wsl_need": "A restart is needed afterwards.",
    "core.desktop.common.back": "Back",
    "core.desktop.common.changed_nothing": "The app has not changed anything.",
    "core.desktop.common.check_again": "Check again",
    "core.desktop.common.close_window": "You can close this window.",
    "core.desktop.common.come_back": "Then come back here.",
    "core.desktop.common.next": "Next",
    "core.desktop.common.open_telegram": "Open Telegram",
    "core.desktop.common.retry": "Try again",
    "core.desktop.common.view_report": "View error report",
    "core.desktop.core.busy_text": "The first time this takes a few minutes.",
    "core.desktop.core.busy_title": "Preparing the questionnaire",
    "core.desktop.docker.busy_text": "Is Docker already on this {machine}, and is it running?",
    "core.desktop.docker.busy_title": "Checking Docker",
    "core.desktop.done.backup": "From now on your data is backed up every day to the folder you chose.",
    "core.desktop.done.deviations": "Something changed in other programs in Docker during the setup ({n} places). Please send the error report.",
    "core.desktop.done.lead": "Your assistant is now running on this computer.",
    "core.desktop.done.title": "All done. Message your assistant in Telegram",
    "core.desktop.done.updates": "Your assistant tells you about new versions in the chat. You tap **Update now**, and the update backs up your data first.",
    "core.desktop.engine.colima": "Colima (another program for Docker)",
    "core.desktop.engine.docker_desktop": "Docker Desktop",
    "core.desktop.engine.homebrew_docker": "Docker from Homebrew",
    "core.desktop.engine.orb_stack": "OrbStack",
    "core.desktop.engine.podman": "Podman",
    "core.desktop.engine.rancher_desktop": "Rancher Desktop",
    "core.desktop.engine.remote": "a Docker that runs on another computer",
    "core.desktop.engine.unknown": "a Docker the app does not know",
    "core.desktop.engine.wsl": "a separate Docker engine in the Linux part of Windows",
    "core.desktop.error.again": "If it happens again, send the error report to the person who gave you the app.",
    "core.desktop.error.compose_missing": "This test version is still missing a part of the assistant.",
    "core.desktop.error.docker_capability": "Your Docker is missing something the assistant needs. The app has not started anything. Update Docker Desktop to the latest version and try again.",
    "core.desktop.error.docker_closed": "Docker Desktop closed again before it was ready. You may have declined Docker's terms in its first window. Open Docker Desktop yourself and, if asked, accept the terms there. Then try again. The assistant cannot run without Docker.",
    "core.desktop.error.docker_credentials": "Docker cannot find its own helper program for signing in. The app has not started anything. Open Docker Desktop once yourself, wait until it is running, and try again.",
    "core.desktop.error.docker_disk": "There is no space left on this computer's disk. The app has not started anything. Delete files or programs you no longer need and try again.",
    "core.desktop.error.docker_network": "Docker could not download something from the internet. The app has not started anything. Check your internet connection and try again.",
    "core.desktop.error.docker_start_timeout": "Docker is not responding. Open Docker Desktop once yourself and wait until it is running.",
    "core.desktop.error.docker_unsupported": "Docker is installed here in a form the app does not change.",
    "core.desktop.error.download_failed": "Docker could not be downloaded. Check your internet connection and try again.",
    "core.desktop.error.foreign_objects": "Docker already contains something named lifeagents that does not come from this app. The app leaves it alone.",
    "core.desktop.error.install_cancelled": "You cancelled the password prompt. Nothing was installed.",
    "core.desktop.error.install_failed": "Docker could not be set up.",
    "core.desktop.error.journal_unreadable": "The app cannot read its setup notes.",
    "core.desktop.error.no_free_port": "No suitable port is free on this computer (5880 to 5899).",
    "core.desktop.error.power_cancelled": "You cancelled the prompt. The settings stay as they were.",
    "core.desktop.error.power_failed": "The energy settings could not be changed.",
    "core.desktop.error.rollback_failed": "Not everything could be undone. You can try again right away.",
    "core.desktop.error.signature_failed": "The downloaded file could not be confirmed as a genuine file from Docker. The app deleted it and installed nothing.",
    "core.desktop.error.start_failed": "The assistant could not be started.",
    "core.desktop.error.system_blocked": "This computer does not meet the requirements.",
    "core.desktop.error.title": "That did not work",
    "core.desktop.error.unknown": "Something went wrong.",
    "core.desktop.error.wizard_unavailable": "The questionnaire is not responding.",
    "core.desktop.fetch.download": "Download Docker",
    "core.desktop.fetch.download_progress": "Download Docker ({done} of about {total} MB)",
    "core.desktop.fetch.lead": "You can leave the window open and do something else until your {machine} needs you.",
    "core.desktop.fetch.password_mac": "Your Mac asks for your password: enter it and confirm",
    "core.desktop.fetch.password_win": "Windows asks whether the app may make changes: confirm with Yes",
    "core.desktop.fetch.start": "Start Docker",
    "core.desktop.fetch.title": "Getting Docker",
    "core.desktop.fetch.verify": "Check that the file really comes from the maker",
    "core.desktop.finish.busy_text": "Register the start at login and check that everything else is unchanged",
    "core.desktop.finish.busy_title": "One moment",
    "core.desktop.help.lead": "This {machine} already has {what}. The app does not install anything extra and does not change it, so nothing breaks.",
    "core.desktop.help.link": "Read the help on the project page",
    "core.desktop.help.note": "The app has not changed anything. Send the error report to the person who gave you the app.",
    "core.desktop.help.title": "You need a little help here",
    "core.desktop.home.lead_mac": "The app's icon at the top in the menu bar shows whether everything is running. You can close this window.",
    "core.desktop.home.lead_win": "The app's icon at the bottom next to the clock shows whether everything is running. You can close this window.",
    "core.desktop.home.title": "Your assistant is set up",
    "core.desktop.kit.busy_title": "Saving the emergency sheet …",
    "core.desktop.kit.button": "Save emergency sheet",
    "core.desktop.kit.check": "I have printed the emergency sheet or stored it safely.",
    "core.desktop.kit.close": "Done",
    "core.desktop.kit.file_name": "Life-Agents-Emergency-Sheet",
    "core.desktop.kit.lead": "On a new computer a backup only opens with the key on this sheet. Print it or put it in your password manager. Don't put it in the backup folder.",
    "core.desktop.kit.menu_title": "Emergency sheet",
    "core.desktop.kit.next_hint": "“{button}” works once you have ticked this.",
    "core.desktop.kit.saved": "Saved in Downloads: {file}. Delete this file once the sheet is printed or stored safely.",
    "core.desktop.kit.title": "One more step: save the emergency sheet",
    "core.desktop.kit.unavailable": "Docker is not running right now. Start Docker and try again.",
    "core.desktop.kit.write_failed": "The emergency sheet could not be saved in “Downloads”.",
    "core.desktop.machine.mac": "Mac",
    "core.desktop.machine.pc": "PC",
    "core.desktop.memory.lead": "{free} GB are free, the assistant needs {need} GB. The app does not change this, because the other programs in Docker share the memory.",
    "core.desktop.memory.step_open": "Open **Docker Desktop** and its settings.",
    "core.desktop.memory.step_resources": "Under **Resources**, give Docker more memory.",
    "core.desktop.memory.title": "Docker does not have enough free memory",
    "core.desktop.missing.lead": "It is called **Docker** and keeps your assistant neatly separated from the rest of your computer. You never have to operate it yourself. The app gets it directly from the maker and sets it up.",
    "core.desktop.missing.next": "Agree, get Docker",
    "core.desktop.missing.terms": "Docker is free for personal use. The maker has its own terms of use.",
    "core.desktop.missing.terms_link": "You can read them here.",
    "core.desktop.missing.title": "The app needs a helper program",
    "core.desktop.move.folder": "Applications",
    "core.desktop.move.lead": "The app is still running from the downloaded file. That way it cannot start by itself later.",
    "core.desktop.move.step_drag": "In the window of the downloaded file, drag the lifeagents icon onto the Applications folder.",
    "core.desktop.move.step_open": "Then open lifeagents from the Applications folder.",
    "core.desktop.move.step_quit": "Quit the app.",
    "core.desktop.move.title": "First, drag the app into the Applications folder",
    "core.desktop.need.card": "**A credit card.** Anthropic's AI bills you directly for what you use. The project itself is free.",
    "core.desktop.need.hint": "A Mac mini or another computer that is always plugged in works best.",
    "core.desktop.need.intro": "Have these three things ready:",
    "core.desktop.need.machine": "**This computer, and it stays on.** Your assistant runs here. At the end we ask whether the computer should keep running for it.",
    "core.desktop.need.next": "Check this computer",
    "core.desktop.need.phone": "**Your phone.** That is where you will talk to your assistant later. If Telegram is not on it yet, we set it up together along the way.",
    "core.desktop.need.title": "What you need",
    "core.desktop.nowizard.lead": "Everything so far was real: the app checked your {machine} and Docker. A later version brings the questionnaire.",
    "core.desktop.nowizard.next": "On to always-on mode",
    "core.desktop.nowizard.note": "You can still try the remaining steps of the app.",
    "core.desktop.nowizard.title": "The questionnaire is not part of this test version yet",
    "core.desktop.old.lead": "Docker is already running on your {machine}, but the app needs a newer version. The app does not update it itself, because other programs may be running there.",
    "core.desktop.old.step_open": "Open **Docker Desktop**.",
    "core.desktop.old.step_update": "Start the update there.",
    "core.desktop.old.title": "Your Docker is too old",
    "core.desktop.other.lead": "{engine} is installed on this {machine}, but turned off. The app does not install a second Docker next to it. Start {engine} and come back here.",
    "core.desktop.other.title": "Please start {engine} first",
    "core.desktop.power.laptop": "Your computer has a battery. This only applies on the charger: closed or on battery, it still goes to sleep.",
    "core.desktop.power.lead_mac": "The screen turns off after 10 minutes, and the Mac keeps working quietly. That way your assistant always answers.",
    "core.desktop.power.lead_win": "The screen turns off after 10 minutes, and the PC keeps working. That way your assistant always answers.",
    "core.desktop.power.next_confirm": "Continue to confirmation",
    "core.desktop.power.no_text": "When your computer sleeps, your assistant only answers once the computer is awake again.",
    "core.desktop.power.no_title": "No, leave everything as it is",
    "core.desktop.power.recommended": "recommended",
    "core.desktop.power.title": "Should this computer keep running?",
    "core.desktop.power.yes_mac": "It no longer goes to sleep and starts by itself after a power cut. A Mac mini costs about €10–20 a year in electricity.",
    "core.desktop.power.yes_title": "Yes, keep it running",
    "core.desktop.power.yes_win": "It no longer goes to sleep. A PC uses much more electricity than a Mac mini.",
    "core.desktop.ready.lead": "You do not need to install anything. The app works alongside it and touches nothing that is already running.",
    "core.desktop.ready.memory": "Enough free memory for the assistant too",
    "core.desktop.ready.next": "Agree, continue",
    "core.desktop.ready.programs_many": "{n} programs are already running in Docker, for example {name}. They stay as they are.",
    "core.desktop.ready.programs_none": "Nothing else is running in Docker right now.",
    "core.desktop.ready.programs_one": "{name} is already running in Docker. It stays as it is.",
    "core.desktop.ready.running": "{engine} is running and recent enough",
    "core.desktop.ready.title": "Docker is already installed, so the app will use it too",
    "core.desktop.ready.untested": "The app is tested with Docker Desktop. {engine} should work the same way, but that is not certain.",
    "core.desktop.report.copied": "Copied",
    "core.desktop.report.copy": "Copy",
    "core.desktop.report.lead": "It only contains fixed details about the computer and Docker, no names, no addresses and no data. Copy it into a message to the person who gave you the app.",
    "core.desktop.report.title": "Error report",
    "core.desktop.restore.done_title": "The old settings apply again",
    "core.desktop.restore.lead": "Your {machine} gets its old energy settings back. After that it goes to sleep again, and your assistant only answers when it is awake.",
    "core.desktop.restore.next": "Restore old settings",
    "core.desktop.restore.title": "Turn off always-on mode?",
    "core.desktop.result.as_before": "The computer sleeps as before, your assistant waits then",
    "core.desktop.result.autostart": "After you log in, Docker and your assistant start by themselves",
    "core.desktop.result.display_bad": "The screen setting could not be applied",
    "core.desktop.result.display_ok": "The screen turns off after 10 minutes",
    "core.desktop.result.filevault": "**One thing stays manual:** Your Mac encrypts its disk. That protects your data if someone takes it. After a power cut it therefore waits for your password. Until you have logged in, your assistant stays silent, and it cannot tell you beforehand.",
    "core.desktop.result.next": "Finish",
    "core.desktop.result.restart_bad": "Starting after a power cut could not be turned on",
    "core.desktop.result.restart_ok": "It starts by itself after a power cut",
    "core.desktop.result.restore_hint": "You can bring back the old behavior at any time via the app's icon.",
    "core.desktop.result.sleep_bad": "The computer can still go to sleep; the setting did not take effect",
    "core.desktop.result.sleep_ok": "The computer no longer goes to sleep",
    "core.desktop.result.title": "This is how your computer behaves now",
    "core.desktop.result.windows_login": "**One thing stays manual:** After a restart, for example from a Windows update, you need to log in once. Until then your assistant stays silent.",
    "core.desktop.result.womp_bad": "Waking the computer from another device could not be turned on",
    "core.desktop.resume.lead": "The app remembered how far it got. You can continue from there or undo everything it has changed so far.",
    "core.desktop.resume.next": "Continue setup",
    "core.desktop.resume.note": "Undoing leaves your data and other programs alone. Docker itself stays installed.",
    "core.desktop.resume.rollback": "Undo everything",
    "core.desktop.resume.title": "The setup was interrupted",
    "core.desktop.rollback.busy_text": "Undo the setup steps",
    "core.desktop.rollback.busy_title": "Undoing everything",
    "core.desktop.rollback.lead": "Other programs and your files are untouched. Docker itself stays on your computer; you can remove it via “Uninstall”.",
    "core.desktop.rollback.restart": "Start over",
    "core.desktop.rollback.title": "The app's changes have been undone",
    "core.desktop.stopped.lead": "The app does not install anything extra. It starts Docker and uses it too.",
    "core.desktop.stopped.next": "Agree, start Docker",
    "core.desktop.stopped.title": "Docker is installed but not running",
    "core.desktop.sys.arm": "Mac with Apple chip",
    "core.desktop.sys.busy_text": "Chip type, system version, memory and free space",
    "core.desktop.sys.busy_title": "Checking your {machine}",
    "core.desktop.sys.hints_note": "This is not an obstacle. If you like, continue later: so far the app has not changed anything.",
    "core.desktop.sys.hints_title": "Almost everything fits",
    "core.desktop.sys.intel": "Mac with Intel processor",
    "core.desktop.sys.next_anyway": "Continue anyway",
    "core.desktop.sys.ok_title": "Your {machine} is ready",
    "core.desktop.sys.stop_title": "This computer does not meet the requirements",
    "core.desktop.tidy.button": "Remove download",
    "core.desktop.tidy.done_text": "The file {file} is now in the trash. You can restore it from there if needed.",
    "core.desktop.tidy.done_title": "Tidied up",
    "core.desktop.tidy.text": "You no longer need the downloaded file {file}. The app moves it to the trash.",
    "core.desktop.tidy.title": "Last step: tidy up",
    "core.desktop.tray.backup_dir": "Change backup folder …",
    "core.desktop.tray.backup_kit": "Save emergency sheet …",
    "core.desktop.tray.backup_restore": "Restore a backup …",
    "core.desktop.tray.checking": "Checking …",
    "core.desktop.tray.open": "Open window",
    "core.desktop.tray.power_restore": "Turn off always-on mode",
    "core.desktop.tray.quit": "Quit app",
    "core.desktop.tray.report": "Error report",
    "core.desktop.tray.restoring": "Restore running …",
    "core.desktop.tray.running": "Assistant is running",
    "core.desktop.tray.stopped": "Assistant is off: Docker is not running",
    "core.desktop.tray.telegram": "Open Telegram",
    "core.desktop.tray.uninstall": "Uninstall",
    "core.desktop.uninstall.autostart": "Stop starting at login",
    "core.desktop.uninstall.autostart_text": "Without this entry the app only starts when you open it.",
    "core.desktop.uninstall.busy_text": "Stop the assistant and remove its parts",
    "core.desktop.uninstall.busy_title": "Removing",
    "core.desktop.uninstall.data": "Also delete my data",
    "core.desktop.uninstall.data_text": "Conversations, receipts and settings of the assistant. This cannot be undone.",
    "core.desktop.uninstall.docker": "Remove Docker Desktop",
    "core.desktop.uninstall.docker_text": "Only useful if no other program needs Docker.",
    "core.desktop.uninstall.lead": "The assistant is stopped, and its parts in Docker disappear. Other programs in Docker stay as they are. You choose everything else here.",
    "core.desktop.uninstall.next": "Uninstall now",
    "core.desktop.uninstall.power": "Turn off always-on mode",
    "core.desktop.uninstall.power_text": "Your computer gets its old energy settings back and sleeps again as before.",
    "core.desktop.uninstall.title": "What should go when uninstalling?",
    "core.desktop.uninstalled.autostart_bad": "The start at login could not be removed",
    "core.desktop.uninstalled.autostart_kept": "The app still starts at login",
    "core.desktop.uninstalled.autostart_ok": "The app no longer starts at login",
    "core.desktop.uninstalled.data_bad": "Your data could not be deleted completely",
    "core.desktop.uninstalled.data_kept": "Your data is still there",
    "core.desktop.uninstalled.data_ok": "Your data is deleted",
    "core.desktop.uninstalled.deviations": "Something changed in other programs in Docker ({n} places). Please send the error report.",
    "core.desktop.uninstalled.docker_bad": "Docker could not be removed",
    "core.desktop.uninstalled.docker_kept": "Docker stays installed",
    "core.desktop.uninstalled.docker_ok": "Docker is removed",
    "core.desktop.uninstalled.failed": "Not everything could be removed. The error report names the places.",
    "core.desktop.uninstalled.others_ok": "All other programs in Docker are unchanged",
    "core.desktop.uninstalled.power_bad": "The old energy settings could not be restored",
    "core.desktop.uninstalled.power_kept": "Always-on mode stays on",
    "core.desktop.uninstalled.power_ok": "The old energy settings apply again",
    "core.desktop.uninstalled.stopped": "The assistant is stopped, its parts in Docker are gone",
    "core.desktop.uninstalled.title": "The assistant has been removed",
    "core.desktop.uninstalled.title_partial": "Almost everything has been removed",
    "core.desktop.uninstalled.trash_app": "You can now drag the app itself to the trash.",
    "core.desktop.wait.text": "Waiting until Docker responds. The first time this takes one or two minutes. A Docker window will open in a moment. You can simply close it, Docker keeps running. You do not need to sign in there.",
    "core.desktop.wait.title": "Docker is starting",
    "core.desktop.wait.title_fresh": "Starting Docker",
    "core.desktop.welcome.lead": "You answer one question after another. At the end you chat with your assistant in Telegram (it is called a bot there), and your data stays on this computer.",
    "core.desktop.welcome.start": "Get started",
    "core.desktop.welcome.time": "Allow about 30 minutes. You can stop at any time and pick up right here later.",
    "core.desktop.welcome.title": "Your own assistant, in a few steps",
    "core.wizard.step.about": "About you",
    "core.wizard.step.access": "Access",
    "core.wizard.step.aria": "Setup steps",
    "core.wizard.step.check": "Check",
    "core.wizard.step.connect": "Connect",
    "core.wizard.step.docker": "Docker",
    "core.wizard.step.done": "Done",
    "core.wizard.step.install": "Installation",
    "core.wizard.step.modules": "Modules",
    "core.wizard.step.power": "Always on",
    "core.wizard.step.prepare": "Prepare",
    "core.wizard.step.questions": "Questions",
    "core.wizard.step.reach": "Reachability",
    "core.wizard.step.short": "Step {n} of {total} · {name}",
  },
  ko: {
    "core.art.greeting.alt": "어시스턴트가 휴대폰으로 먼저 알려 주고, 저장하기 전에 물어봐요. 집에 있는 내 컴퓨터에서 실행되고 데이터는 내 컴퓨터에 보관되며, 재무·커리어·상속·문서 분야에서 온 가족을 도와요.",
    "core.desktop.apply.busy_text": "곧 {machine}에서 앱이 에너지 설정을 바꿔도 되는지 물어볼 거예요.",
    "core.desktop.apply.busy_title": "변경을 확인해 주세요",
    "core.desktop.backup_dir.busy_title": "백업 폴더 설정을 여는 중 …",
    "core.desktop.backup_dir.title": "백업 폴더 변경",
    "core.desktop.backup_restore.area.career": "커리어",
    "core.desktop.backup_restore.area.core": "가구, 프로필, 계획",
    "core.desktop.backup_restore.area.estate": "대비 & 유산",
    "core.desktop.backup_restore.area.finance": "재정",
    "core.desktop.backup_restore.area.paperless": "문서",
    "core.desktop.backup_restore.busy_check": "백업을 확인하는 중 …",
    "core.desktop.backup_restore.busy_list": "백업을 찾는 중 …",
    "core.desktop.backup_restore.card_dismiss": "숨기기",
    "core.desktop.backup_restore.card_go": "백업 선택",
    "core.desktop.backup_restore.card_text": "백업 폴더에 다른 컴퓨터의 백업이 있어요. 새로 시작하기 전에 거기서 데이터를 되살리세요.",
    "core.desktop.backup_restore.card_title": "이전 컴퓨터의 백업 되살리기",
    "core.desktop.backup_restore.choose_other": "다른 백업 선택",
    "core.desktop.backup_restore.err.bundle_incomplete": "이 백업은 완전하지 않아요. 다른 백업을 고르세요.",
    "core.desktop.backup_restore.err.busy": "지금 백업, 업데이트 또는 복원이 진행 중이에요. 몇 분 뒤에 다시 시도하세요.",
    "core.desktop.backup_restore.err.corrupt": "이 백업은 손상되었어요. 다른 백업을 고르세요.",
    "core.desktop.backup_restore.err.corrupt_stored": "이 백업은 손상되었어요. 다른 백업을 고르세요.",
    "core.desktop.backup_restore.err.file_too_big": "백업이라기엔 파일이 너무 커요. “.nla.enc”로 끝나는 파일을 고르세요.",
    "core.desktop.backup_restore.err.folder": "지금은 백업 폴더에 접근할 수 없어요.",
    "core.desktop.backup_restore.err.format": "이 백업은 너무 오래된 버전이라 더 이상 읽을 수 없어요. 다른 백업을 고르세요.",
    "core.desktop.backup_restore.err.internal": "문제가 생겼어요.",
    "core.desktop.backup_restore.err.key_expired": "앱은 15분이 지나면 비상 시트를 잊어요. 다시 고르거나 입력하세요.",
    "core.desktop.backup_restore.err.key_foreign": "이 비상 시트는 이 백업의 것이 아니에요. 키 {id}가 있는 시트가 필요해요.",
    "core.desktop.backup_restore.err.key_format": "비상 시트가 아니에요. “Life-Agents-Emergency-Sheet-…” 파일을 고르거나 네 줄을 입력하세요.",
    "core.desktop.backup_restore.err.key_line": "{n}번째 줄이 맞지 않아요. 한 글자씩 확인하세요.",
    "core.desktop.backup_restore.err.key_needed": "이 백업에는 다른 컴퓨터의 비상 시트가 필요해요.",
    "core.desktop.backup_restore.err.key_no_open": "이 시트의 어떤 키로도 백업이 열리지 않아요. 이전 컴퓨터의 시트가 맞나요?",
    "core.desktop.backup_restore.err.needs_setup": "백업에 “{pkg}” 영역이 들어 있어요. 먼저 설정한 뒤 다시 시도하세요.",
    "core.desktop.backup_restore.err.no_tables": "이 설치에는 되살릴 수 있는 것이 설정되어 있지 않아요.",
    "core.desktop.backup_restore.err.nofolder": "이미 내 데이터가 있어요. 먼저 백업할 수 있도록 백업 폴더를 고르세요 (메뉴 › “백업 폴더 변경 …”).",
    "core.desktop.backup_restore.err.package_unknown": "이 백업에는 이 버전이 모르는 영역이 있어요. 먼저 업데이트하세요.",
    "core.desktop.backup_restore.err.safety": "지금 데이터를 백업하지 못해서 아무것도 바꾸지 않았어요. 백업 폴더를 확인하세요.",
    "core.desktop.backup_restore.err.setup": "아직 설정이 끝나지 않았어요.",
    "core.desktop.backup_restore.err.sheet_invalid": "비상 시트가 아니에요. “Life-Agents-Emergency-Sheet-…” 파일을 고르거나 네 줄을 입력하세요.",
    "core.desktop.backup_restore.err.sheet_too_big": "비상 시트가 아니에요. “Life-Agents-Emergency-Sheet-…” 파일을 고르거나 네 줄을 입력하세요.",
    "core.desktop.backup_restore.err.unfinished": "복원이 중단되었어요 (컴퓨터나 Docker가 꺼졌어요).",
    "core.desktop.backup_restore.err.unreadable": "이 파일을 읽을 수 없어요. “.nla.enc”로 끝나는 파일을 고르세요.",
    "core.desktop.backup_restore.err.version_newer": "이 백업은 더 새로운 버전({release})에서 만들었어요. 먼저 업데이트한 뒤 다시 시도하세요.",
    "core.desktop.backup_restore.err.version_older": "이 백업은 버전 {release}에서 만들었어요. 정확히 그 버전으로만 복원할 수 있어요. 방법은 안내를 보세요.",
    "core.desktop.backup_restore.fail_title": "잘 되지 않았어요",
    "core.desktop.backup_restore.go": "복원",
    "core.desktop.backup_restore.go_replace": "네, 바꾸기",
    "core.desktop.backup_restore.guide": "안내 “백업 & 새 컴퓨터”",
    "core.desktop.backup_restore.key_check": "확인",
    "core.desktop.backup_restore.key_file": "비상 시트 파일 선택 …",
    "core.desktop.backup_restore.key_lead": "이 백업은 다른 컴퓨터에서 만들었어요. 그 컴퓨터의 비상 시트에 있는 키로만 열려요.",
    "core.desktop.backup_restore.key_line": "{n}번째 줄",
    "core.desktop.backup_restore.key_or": "또는 종이에 적힌 네 줄을 입력하세요:",
    "core.desktop.backup_restore.key_title": "비상 시트",
    "core.desktop.backup_restore.list_empty": "백업 폴더에 아직 백업이 없어요. 다른 곳에 있다면 파일을 고르세요.",
    "core.desktop.backup_restore.list_folder": "지금은 백업 폴더에 접근할 수 없어요. 폴더가 그대로 있는지 확인하거나 파일을 직접 고르세요.",
    "core.desktop.backup_restore.list_lead": "되살릴 백업을 고르세요.",
    "core.desktop.backup_restore.list_nofolder": "아직 백업 폴더를 고르지 않았어요. 백업 파일을 직접 고르세요.",
    "core.desktop.backup_restore.ok_foreign": "이제부터 백업은 이전 컴퓨터의 키로 열려요. 아래의 새 비상 시트에는 두 키가 모두 들어 있어요.",
    "core.desktop.backup_restore.ok_lead": "{date}의 데이터가 복원되었어요.",
    "core.desktop.backup_restore.ok_old_machine": "이전 컴퓨터가 더 이상 이 폴더에 백업하지 않게 하세요. 그렇지 않으면 서로의 오래된 백업을 지워요.",
    "core.desktop.backup_restore.ok_safety": "이전 데이터는 백업 폴더에 백업으로 남아 있어요.",
    "core.desktop.backup_restore.ok_title": "데이터가 돌아왔어요",
    "core.desktop.backup_restore.other_file": "다른 파일 선택 …",
    "core.desktop.backup_restore.pick_file": "백업 파일 선택 …",
    "core.desktop.backup_restore.pkg_activate": "다시 켜져요",
    "core.desktop.backup_restore.pkg_install": "함께 설정돼요",
    "core.desktop.backup_restore.preview_areas": "다음 영역이 되살아나요:",
    "core.desktop.backup_restore.preview_confirm": "지금 데이터가 바뀐다는 것을 알고 있어요 (먼저 백업돼요).",
    "core.desktop.backup_restore.preview_empty": "아직 내 데이터가 없어서 덮어쓰는 것은 없어요.",
    "core.desktop.backup_restore.preview_lead": "{date} 백업",
    "core.desktop.backup_restore.preview_replace": "지금 데이터는 바뀌어요. 그 전에 앱이 지금 데이터를 백업 폴더에 자동으로 백업해요.",
    "core.desktop.backup_restore.preview_sheet": "그다음에는 이전 컴퓨터의 비상 시트가 적용돼요.",
    "core.desktop.backup_restore.preview_title": "이렇게 되살아나요",
    "core.desktop.backup_restore.running_text": "보통 1분도 걸리지 않아요. 창을 닫아도 계속 진행돼요.",
    "core.desktop.backup_restore.running_title": "복원하는 중 …",
    "core.desktop.backup_restore.tag_other": "이전 컴퓨터",
    "core.desktop.backup_restore.tag_version": "다른 버전",
    "core.desktop.backup_restore.tag_version_text": "이 설치와 맞지 않아 복원이 안 될 가능성이 커요.",
    "core.desktop.backup_restore.title": "백업 복원",
    "core.desktop.backup_restore.unchanged": "데이터는 그대로예요.",
    "core.desktop.backup_restore.version": "버전 {release}",
    "core.desktop.backup_restore.version_unknown": "버전 알 수 없음",
    "core.desktop.changes.install_docker": "Docker 추가 (약 {size} MB, 제조사에서 직접)",
    "core.desktop.changes.journal": "앱이 모든 것을 되돌릴 수 있도록 진행 단계를 적어 두는 작은 파일",
    "core.desktop.changes.keep_docker": "Docker 자체: 새 버전도, 다시 시작도 없어요",
    "core.desktop.changes.keep_files": "내 파일과 디스크 암호화",
    "core.desktop.changes.keep_power": "에너지 설정: 마지막에 “네”라고 할 때까지 그대로예요",
    "core.desktop.changes.keep_title": "그대로인 것",
    "core.desktop.changes.start_docker": "{engine} 시작",
    "core.desktop.changes.title": "바뀌는 것",
    "core.desktop.changes.wizard": "곧 질문을 드릴 설정 화면. 나머지는 이 화면 마지막에 동의한 뒤에만 진행돼요",
    "core.desktop.check.backup": "Time Machine이 백업 중이에요",
    "core.desktop.check.backup_need": "백업이 끝난 뒤에 이어 하는 게 좋아요.",
    "core.desktop.check.battery": "지금 배터리로 실행 중이에요",
    "core.desktop.check.battery_need": "충전기에 연결하는 게 좋아요.",
    "core.desktop.check.disk": "여유 공간: {value} GB",
    "core.desktop.check.disk_need": "최소 {need} GB가 필요해요.",
    "core.desktop.check.os_mac": "macOS {value}",
    "core.desktop.check.os_mac_need": "보조 프로그램 Docker에는 macOS {need} 이상이 필요해요.",
    "core.desktop.check.os_win": "Windows (빌드 {value})",
    "core.desktop.check.os_win_need": "보조 프로그램 Docker에는 Windows 10 22H2 또는 Windows 11이 필요해요.",
    "core.desktop.check.ram": "메모리: {value} GB",
    "core.desktop.check.ram_need": "보조 프로그램 Docker에는 최소 {need} GB가 필요해요.",
    "core.desktop.check.virt": "가상화가 꺼져 있어요",
    "core.desktop.check.virt_need": "Docker에는 가상화가 필요해요. 컴퓨터를 켤 때 나오는 설정(BIOS)에서 켤 수 있어요.",
    "core.desktop.check.wsl": "Docker를 설정할 때 Windows가 Linux 영역도 함께 설정해요",
    "core.desktop.check.wsl_need": "그다음 다시 시작해야 해요.",
    "core.desktop.common.back": "이전",
    "core.desktop.common.changed_nothing": "앱은 아무것도 바꾸지 않았어요.",
    "core.desktop.common.check_again": "다시 확인",
    "core.desktop.common.close_window": "이 창은 닫아도 돼요.",
    "core.desktop.common.come_back": "그다음 여기로 돌아와 주세요.",
    "core.desktop.common.next": "다음",
    "core.desktop.common.open_telegram": "텔레그램 열기",
    "core.desktop.common.retry": "다시 시도",
    "core.desktop.common.view_report": "오류 보고서 보기",
    "core.desktop.core.busy_text": "처음에는 몇 분 걸려요.",
    "core.desktop.core.busy_title": "설정 질문을 준비하는 중",
    "core.desktop.docker.busy_text": "이 {machine}에 Docker가 이미 있고 실행 중인지 확인해요",
    "core.desktop.docker.busy_title": "Docker 확인 중",
    "core.desktop.done.backup": "이제부터 데이터가 매일 고른 폴더에 백업돼요.",
    "core.desktop.done.deviations": "설정하는 동안 Docker 안의 다른 프로그램에서 바뀐 것이 있어요({n}곳). 오류 보고서를 보내 주세요.",
    "core.desktop.done.lead": "이제 어시스턴트가 이 컴퓨터에서 실행되고 있어요.",
    "core.desktop.done.title": "끝났어요. 텔레그램에서 어시스턴트에게 말을 걸어 보세요",
    "core.desktop.done.updates": "새 버전이 나오면 어시스턴트가 채팅으로 알려 줘요. **지금 업데이트**를 누르면 업데이트 전에 데이터를 먼저 백업해요.",
    "core.desktop.engine.colima": "Colima(Docker용 다른 프로그램)",
    "core.desktop.engine.docker_desktop": "Docker Desktop",
    "core.desktop.engine.homebrew_docker": "Homebrew로 설치한 Docker",
    "core.desktop.engine.orb_stack": "OrbStack",
    "core.desktop.engine.podman": "Podman",
    "core.desktop.engine.rancher_desktop": "Rancher Desktop",
    "core.desktop.engine.remote": "다른 컴퓨터에서 실행되는 Docker",
    "core.desktop.engine.unknown": "앱이 모르는 Docker",
    "core.desktop.engine.wsl": "Windows의 Linux 영역에 따로 설치한 Docker 엔진",
    "core.desktop.error.again": "다시 이런 일이 생기면 이 앱을 준 사람에게 오류 보고서를 보내 주세요.",
    "core.desktop.error.compose_missing": "이 테스트 버전에는 어시스턴트의 일부가 아직 없어요.",
    "core.desktop.error.docker_capability": "어시스턴트에 필요한 기능이 지금 Docker에 없어요. 앱은 아무것도 시작하지 않았어요. Docker Desktop을 최신 버전으로 업데이트한 뒤 다시 시도해 주세요.",
    "core.desktop.error.docker_closed": "Docker Desktop이 준비되기 전에 다시 닫혔어요. 첫 창에서 Docker 이용 약관을 거절했을 수 있어요. Docker Desktop을 직접 열고, 약관을 묻는다면 동의해 주세요. 그런 다음 다시 시도해 주세요. Docker 없이는 어시스턴트가 실행되지 않아요.",
    "core.desktop.error.docker_credentials": "Docker가 로그인용 보조 프로그램을 찾지 못해요. 앱은 아무것도 시작하지 않았어요. Docker Desktop을 한 번 직접 열고 실행될 때까지 기다린 뒤 다시 시도해 주세요.",
    "core.desktop.error.docker_disk": "컴퓨터 디스크에 남은 공간이 없어요. 앱은 아무것도 시작하지 않았어요. 필요 없는 파일이나 프로그램을 지운 뒤 다시 시도해 주세요.",
    "core.desktop.error.docker_network": "Docker가 인터넷에서 무언가를 내려받지 못했어요. 앱은 아무것도 시작하지 않았어요. 인터넷 연결을 확인하고 다시 시도해 주세요.",
    "core.desktop.error.docker_start_timeout": "Docker가 응답하지 않아요. Docker Desktop을 한 번 직접 열고 실행될 때까지 기다려 주세요.",
    "core.desktop.error.docker_unsupported": "이 컴퓨터의 Docker는 앱이 손대지 않는 형태로 설치되어 있어요.",
    "core.desktop.error.download_failed": "Docker를 내려받지 못했어요. 인터넷 연결을 확인하고 다시 시도해 주세요.",
    "core.desktop.error.foreign_objects": "Docker 안에 이 앱이 만들지 않은 lifeagents라는 이름의 항목이 이미 있어요. 앱은 그것을 건드리지 않아요.",
    "core.desktop.error.install_cancelled": "비밀번호 입력을 취소했어요. 아무것도 설치되지 않았어요.",
    "core.desktop.error.install_failed": "Docker를 설정하지 못했어요.",
    "core.desktop.error.journal_unreadable": "앱이 설정 기록을 읽지 못해요.",
    "core.desktop.error.no_free_port": "이 컴퓨터에 쓸 수 있는 포트가 없어요(5880~5899).",
    "core.desktop.error.power_cancelled": "확인 창을 취소했어요. 설정은 그대로예요.",
    "core.desktop.error.power_failed": "에너지 설정을 바꾸지 못했어요.",
    "core.desktop.error.rollback_failed": "모두 되돌리지는 못했어요. 바로 다시 시도할 수 있어요.",
    "core.desktop.error.signature_failed": "내려받은 파일이 Docker의 진짜 파일인지 확인하지 못했어요. 앱이 파일을 지웠고 아무것도 설치하지 않았어요.",
    "core.desktop.error.start_failed": "어시스턴트를 시작하지 못했어요.",
    "core.desktop.error.system_blocked": "아쉽지만 이 컴퓨터로는 부족해요.",
    "core.desktop.error.title": "잘되지 않았어요",
    "core.desktop.error.unknown": "문제가 생겼어요.",
    "core.desktop.error.wizard_unavailable": "설정 질문 화면이 응답하지 않아요.",
    "core.desktop.fetch.download": "Docker 내려받기",
    "core.desktop.fetch.download_progress": "Docker 내려받기 (약 {total} MB 중 {done} MB)",
    "core.desktop.fetch.lead": "창을 열어 둔 채 다른 일을 해도 돼요. {machine}에서 확인이 필요하면 알려 줄게요.",
    "core.desktop.fetch.password_mac": "Mac이 비밀번호를 물어요. 입력하고 확인해 주세요",
    "core.desktop.fetch.password_win": "Windows가 앱이 변경해도 되는지 물어요. “예”를 눌러 주세요",
    "core.desktop.fetch.start": "Docker 시작",
    "core.desktop.fetch.title": "Docker를 내려받는 중",
    "core.desktop.fetch.verify": "파일이 정말 제조사에서 온 것인지 확인",
    "core.desktop.finish.busy_text": "로그인할 때 시작하도록 등록하고, 다른 것은 바뀌지 않았는지 확인하는 중",
    "core.desktop.finish.busy_title": "잠시만요",
    "core.desktop.help.lead": "이 {machine}에는 이미 다음이 있어요: {what}. 아무것도 망가지지 않도록 앱은 더 설치하지도, 바꾸지도 않아요.",
    "core.desktop.help.link": "프로젝트 페이지에서 도움말 읽기",
    "core.desktop.help.note": "앱은 아무것도 바꾸지 않았어요. 이 앱을 준 사람에게 오류 보고서를 보내 주세요.",
    "core.desktop.help.title": "여기서는 도움이 조금 필요해요",
    "core.desktop.home.lead_mac": "위쪽 메뉴 막대의 앱 아이콘에서 모든 것이 잘 실행되는지 볼 수 있어요. 이 창은 닫아도 돼요.",
    "core.desktop.home.lead_win": "아래쪽 시계 옆 앱 아이콘에서 모든 것이 잘 실행되는지 볼 수 있어요. 이 창은 닫아도 돼요.",
    "core.desktop.home.title": "어시스턴트 설정이 끝났어요",
    "core.desktop.kit.busy_title": "비상 시트를 저장하는 중 …",
    "core.desktop.kit.button": "비상 시트 저장",
    "core.desktop.kit.check": "비상 시트를 인쇄했거나 안전하게 보관했어요.",
    "core.desktop.kit.close": "완료",
    "core.desktop.kit.file_name": "Life-Agents-Emergency-Sheet",
    "core.desktop.kit.lead": "새 컴퓨터에서는 이 시트의 키가 있어야 백업을 열 수 있어요. 인쇄하거나 비밀번호 관리자에 넣어 주세요. 백업 폴더에는 넣지 마세요.",
    "core.desktop.kit.menu_title": "비상 시트",
    "core.desktop.kit.next_hint": "체크하면 “{button}”을 누를 수 있어요.",
    "core.desktop.kit.saved": "다운로드에 저장했어요: {file}. 시트를 인쇄하거나 안전하게 보관한 뒤 이 파일은 지워 주세요.",
    "core.desktop.kit.title": "한 단계 더: 비상 시트 저장",
    "core.desktop.kit.unavailable": "지금 Docker가 실행 중이 아니에요. Docker를 켜고 다시 시도해 주세요.",
    "core.desktop.kit.write_failed": "비상 시트를 “다운로드”에 저장할 수 없었어요.",
    "core.desktop.machine.mac": "Mac",
    "core.desktop.machine.pc": "PC",
    "core.desktop.memory.lead": "남은 메모리는 {free} GB인데, 어시스턴트에는 {need} GB가 필요해요. Docker 안의 다른 프로그램과 메모리를 나눠 쓰고 있어서 앱이 바꾸지는 않아요.",
    "core.desktop.memory.step_open": "**Docker Desktop**에서 설정을 열어요.",
    "core.desktop.memory.step_resources": "**Resources**(Docker Desktop에서는 이 항목이 영어로 표시돼요)에서 Docker에 메모리를 더 줘요.",
    "core.desktop.memory.title": "Docker에 남은 메모리가 부족해요",
    "core.desktop.missing.lead": "이름은 **Docker**예요. 어시스턴트를 컴퓨터의 나머지 부분과 깔끔하게 분리해 줘요. 직접 다룰 일은 없어요. 앱이 제조사에서 바로 받아 설정해요.",
    "core.desktop.missing.next": "동의해요, Docker 내려받기",
    "core.desktop.missing.terms": "개인적으로 쓰면 Docker는 무료예요. 제조사의 이용 약관이 따로 있어요.",
    "core.desktop.missing.terms_link": "여기서 읽어 보세요.",
    "core.desktop.missing.title": "보조 프로그램이 하나 필요해요",
    "core.desktop.move.folder": "응용 프로그램",
    "core.desktop.move.lead": "앱이 아직 내려받은 파일 안에서 실행되고 있어요. 이대로는 나중에 저절로 시작할 수 없어요.",
    "core.desktop.move.step_drag": "내려받은 파일의 창에서 lifeagents 아이콘을 응용 프로그램 폴더로 끌어다 놓아요.",
    "core.desktop.move.step_open": "그다음 응용 프로그램 폴더에서 lifeagents를 열어요.",
    "core.desktop.move.step_quit": "앱을 종료해요.",
    "core.desktop.move.title": "먼저 앱을 응용 프로그램 폴더로 옮겨 주세요",
    "core.desktop.need.card": "**신용카드.** AI 사용료는 쓴 만큼 Anthropic이 직접 청구해요. 이 프로젝트 자체는 무료예요.",
    "core.desktop.need.hint": "Mac mini처럼 늘 전원에 연결된 컴퓨터가 가장 좋아요.",
    "core.desktop.need.intro": "다음 세 가지를 준비해 주세요.",
    "core.desktop.need.machine": "**계속 켜 둘 이 컴퓨터.** 어시스턴트는 여기서 실행돼요. 마지막에 이 컴퓨터를 계속 켜 둘지 물어볼게요.",
    "core.desktop.need.next": "컴퓨터 확인",
    "core.desktop.need.phone": "**내 휴대폰.** 나중에 여기서 어시스턴트와 대화해요. 텔레그램이 아직 없다면 진행하면서 함께 설치해요.",
    "core.desktop.need.title": "이런 게 필요해요",
    "core.desktop.nowizard.lead": "여기까지는 모두 실제였어요. 앱이 {machine} 상태와 Docker를 확인했어요. 설정 질문은 다음 버전에 들어가요.",
    "core.desktop.nowizard.next": "상시 실행으로",
    "core.desktop.nowizard.note": "앱의 나머지 단계는 그래도 해 볼 수 있어요.",
    "core.desktop.nowizard.title": "이 테스트 버전에는 설정 질문이 아직 없어요",
    "core.desktop.old.lead": "{machine}에서 Docker가 이미 실행 중이지만, 앱에는 더 새로운 버전이 필요해요. 다른 프로그램이 거기서 실행 중일 수 있어서 앱이 직접 업데이트하지는 않아요.",
    "core.desktop.old.step_open": "**Docker Desktop**을 열어요.",
    "core.desktop.old.step_update": "거기서 업데이트를 시작해요.",
    "core.desktop.old.title": "Docker가 너무 오래됐어요",
    "core.desktop.other.lead": "이 {machine}에는 다음이 설치되어 있지만 지금 꺼져 있어요: {engine}. 앱은 그 옆에 Docker를 하나 더 설치하지 않아요. 먼저 켜 준 다음 여기로 돌아와 주세요: {engine}.",
    "core.desktop.other.title": "먼저 {engine}부터 켜 주세요",
    "core.desktop.power.laptop": "이 컴퓨터에는 배터리가 있어요. 충전기에 연결되어 있을 때만 적용돼요. 덮개를 닫거나 배터리로 쓰면 그래도 잠자기 모드로 들어가요.",
    "core.desktop.power.lead_mac": "화면은 10분 뒤에 꺼지고, Mac은 조용히 계속 일해요. 그래서 어시스턴트가 언제든 답할 수 있어요.",
    "core.desktop.power.lead_win": "화면은 10분 뒤에 꺼지고, PC는 계속 일해요. 그래서 어시스턴트가 언제든 답할 수 있어요.",
    "core.desktop.power.next_confirm": "확인으로",
    "core.desktop.power.no_text": "컴퓨터가 잠들면 다시 깨어난 뒤에야 어시스턴트가 답해요.",
    "core.desktop.power.no_title": "아니요, 지금 그대로 둘게요",
    "core.desktop.power.recommended": "추천",
    "core.desktop.power.title": "이 컴퓨터를 계속 켜 둘까요?",
    "core.desktop.power.yes_mac": "더 이상 잠자기 모드로 들어가지 않고, 정전 뒤에도 저절로 다시 켜져요. Mac mini 전기 요금은 1년에 10~20유로 정도예요.",
    "core.desktop.power.yes_title": "네, 계속 켜 둘게요",
    "core.desktop.power.yes_win": "더 이상 잠자기 모드로 들어가지 않아요. PC는 Mac mini보다 전기를 훨씬 많이 써요.",
    "core.desktop.ready.lead": "아무것도 설치하지 않아도 돼요. 앱은 옆에 자리를 잡고, 이미 실행 중인 것은 건드리지 않아요.",
    "core.desktop.ready.memory": "어시스턴트가 쓸 메모리도 충분해요",
    "core.desktop.ready.next": "동의해요, 다음",
    "core.desktop.ready.programs_many": "Docker에서 이미 프로그램 {n}개가 실행 중이에요(예: {name}). 모두 그대로 둘게요.",
    "core.desktop.ready.programs_none": "지금 Docker에서 다른 것은 실행되고 있지 않아요.",
    "core.desktop.ready.programs_one": "Docker에서 이미 실행 중인 프로그램: {name}. 그대로 둘게요.",
    "core.desktop.ready.running": "{engine} 실행 중, 버전도 충분해요",
    "core.desktop.ready.title": "Docker가 이미 있어요. 함께 쓸게요",
    "core.desktop.ready.untested": "이 앱은 Docker Desktop으로 테스트했어요. {engine}에서도 똑같이 될 것 같아요. 확실하지는 않아요.",
    "core.desktop.report.copied": "복사했어요",
    "core.desktop.report.copy": "복사",
    "core.desktop.report.lead": "컴퓨터와 Docker에 대한 정해진 정보만 들어 있어요. 이름, 주소, 데이터는 없어요. 이 앱을 준 사람에게 메시지로 복사해 보내 주세요.",
    "core.desktop.report.title": "오류 보고서",
    "core.desktop.restore.done_title": "예전 설정으로 돌아갔어요",
    "core.desktop.restore.lead": "{machine}의 에너지 설정을 예전대로 되돌려요. 그러면 다시 잠자기 모드로 들어가고, 어시스턴트는 컴퓨터가 깨어 있을 때만 답해요.",
    "core.desktop.restore.next": "예전 설정으로 되돌리기",
    "core.desktop.restore.title": "상시 실행을 끌까요?",
    "core.desktop.result.as_before": "컴퓨터는 지금처럼 잠자고, 그동안 어시스턴트는 기다려요",
    "core.desktop.result.autostart": "로그인하면 Docker와 어시스턴트가 저절로 시작돼요",
    "core.desktop.result.display_bad": "화면 설정을 적용하지 못했어요",
    "core.desktop.result.display_ok": "화면은 10분 뒤에 꺼져요",
    "core.desktop.result.filevault": "**한 가지는 직접 해야 해요.** Mac이 디스크를 암호화하고 있어요. 누가 Mac을 가져가도 데이터를 지켜 줘요. 그래서 정전 뒤에는 비밀번호를 기다려요. 로그인할 때까지 어시스턴트는 답하지 않고, 이것을 미리 알려 줄 수도 없어요.",
    "core.desktop.result.next": "마치기",
    "core.desktop.result.restart_bad": "정전 뒤 자동 시작을 켜지 못했어요",
    "core.desktop.result.restart_ok": "정전 뒤에도 저절로 다시 켜져요",
    "core.desktop.result.restore_hint": "예전 동작은 언제든 앱 아이콘에서 되돌릴 수 있어요.",
    "core.desktop.result.sleep_bad": "컴퓨터가 여전히 잠자기 모드로 들어갈 수 있어요. 설정이 적용되지 않았어요",
    "core.desktop.result.sleep_ok": "컴퓨터가 더 이상 잠자기 모드로 들어가지 않아요",
    "core.desktop.result.title": "이제 컴퓨터는 이렇게 동작해요",
    "core.desktop.result.windows_login": "**한 가지는 직접 해야 해요.** Windows 업데이트 같은 이유로 다시 시작되면 한 번 로그인해야 해요. 그때까지 어시스턴트는 답하지 않아요.",
    "core.desktop.result.womp_bad": "다른 기기에서 컴퓨터 깨우기를 켜지 못했어요",
    "core.desktop.resume.lead": "앱이 어디까지 했는지 기억하고 있어요. 거기서 이어 하거나, 지금까지 바꾼 것을 모두 되돌릴 수 있어요.",
    "core.desktop.resume.next": "설정 이어 하기",
    "core.desktop.resume.note": "되돌려도 내 데이터와 다른 프로그램은 그대로예요. Docker는 설치된 채로 남아요.",
    "core.desktop.resume.rollback": "모두 되돌리기",
    "core.desktop.resume.title": "설정이 중간에 멈췄어요",
    "core.desktop.rollback.busy_text": "설정 단계를 되돌리는 중",
    "core.desktop.rollback.busy_title": "모두 되돌리는 중",
    "core.desktop.rollback.lead": "다른 프로그램과 내 파일은 그대로예요. Docker는 컴퓨터에 남아 있어요. 지우려면 “제거”를 쓰세요.",
    "core.desktop.rollback.restart": "처음부터 시작",
    "core.desktop.rollback.title": "앱이 바꾼 것을 모두 되돌렸어요",
    "core.desktop.stopped.lead": "앱은 아무것도 더 설치하지 않아요. Docker를 켜서 함께 써요.",
    "core.desktop.stopped.next": "동의해요, Docker 켜기",
    "core.desktop.stopped.title": "Docker는 있지만 지금 꺼져 있어요",
    "core.desktop.sys.arm": "Apple 칩 Mac",
    "core.desktop.sys.busy_text": "종류, 시스템, 메모리, 여유 공간",
    "core.desktop.sys.busy_title": "{machine} 확인 중",
    "core.desktop.sys.hints_note": "걸림돌은 아니에요. 원하면 나중에 이어 해도 돼요. 지금까지 앱은 아무것도 바꾸지 않았어요.",
    "core.desktop.sys.hints_title": "거의 다 괜찮아요",
    "core.desktop.sys.intel": "Intel 프로세서 Mac",
    "core.desktop.sys.next_anyway": "그래도 계속",
    "core.desktop.sys.ok_title": "{machine} 준비 완료",
    "core.desktop.sys.stop_title": "아쉽지만 이 컴퓨터로는 부족해요",
    "core.desktop.tidy.button": "내려받은 파일 정리",
    "core.desktop.tidy.done_text": "파일({file})은 이제 휴지통에 있어요. 필요하면 거기서 되돌릴 수 있어요.",
    "core.desktop.tidy.done_title": "정리했어요",
    "core.desktop.tidy.text": "내려받은 파일({file})은 더 이상 필요 없어요. 앱이 휴지통으로 옮겨요.",
    "core.desktop.tidy.title": "마지막으로 정리하기",
    "core.desktop.tray.backup_dir": "백업 폴더 변경 …",
    "core.desktop.tray.backup_kit": "비상 시트 저장 …",
    "core.desktop.tray.backup_restore": "백업 복원 …",
    "core.desktop.tray.checking": "확인 중 …",
    "core.desktop.tray.open": "창 열기",
    "core.desktop.tray.power_restore": "상시 실행 끄기",
    "core.desktop.tray.quit": "앱 종료",
    "core.desktop.tray.report": "오류 보고서",
    "core.desktop.tray.restoring": "복원 진행 중 …",
    "core.desktop.tray.running": "어시스턴트 실행 중",
    "core.desktop.tray.stopped": "어시스턴트 꺼짐: Docker가 실행되지 않아요",
    "core.desktop.tray.telegram": "텔레그램 열기",
    "core.desktop.tray.uninstall": "제거",
    "core.desktop.uninstall.autostart": "로그인할 때 더 이상 시작하지 않기",
    "core.desktop.uninstall.autostart_text": "이 항목이 없으면 직접 열 때만 앱이 시작돼요.",
    "core.desktop.uninstall.busy_text": "어시스턴트를 멈추고 구성 요소를 지우는 중",
    "core.desktop.uninstall.busy_title": "제거하는 중",
    "core.desktop.uninstall.data": "내 데이터도 지우기",
    "core.desktop.uninstall.data_text": "어시스턴트의 대화, 영수증, 설정이에요. 되돌릴 수 없어요.",
    "core.desktop.uninstall.docker": "Docker Desktop 제거",
    "core.desktop.uninstall.docker_text": "다른 프로그램이 Docker를 쓰지 않을 때만 의미가 있어요.",
    "core.desktop.uninstall.lead": "어시스턴트를 멈추고 Docker 안의 어시스턴트 구성 요소를 지워요. Docker의 다른 프로그램은 그대로예요. 나머지는 여기서 골라요.",
    "core.desktop.uninstall.next": "지금 제거",
    "core.desktop.uninstall.power": "상시 실행 끄기",
    "core.desktop.uninstall.power_text": "컴퓨터가 예전 에너지 설정으로 돌아가고, 예전처럼 다시 잠자요.",
    "core.desktop.uninstall.title": "제거할 때 무엇을 지울까요?",
    "core.desktop.uninstalled.autostart_bad": "로그인할 때 시작하는 항목을 지우지 못했어요",
    "core.desktop.uninstalled.autostart_kept": "앱은 계속 로그인할 때 시작돼요",
    "core.desktop.uninstalled.autostart_ok": "앱이 로그인할 때 더 이상 시작되지 않아요",
    "core.desktop.uninstalled.data_bad": "내 데이터를 모두 지우지는 못했어요",
    "core.desktop.uninstalled.data_kept": "내 데이터는 아직 남아 있어요",
    "core.desktop.uninstalled.data_ok": "내 데이터를 지웠어요",
    "core.desktop.uninstalled.deviations": "Docker 안의 다른 프로그램에서 바뀐 것이 있어요({n}곳). 오류 보고서를 보내 주세요.",
    "core.desktop.uninstalled.docker_bad": "Docker를 제거하지 못했어요",
    "core.desktop.uninstalled.docker_kept": "Docker는 설치된 채로 남아요",
    "core.desktop.uninstalled.docker_ok": "Docker를 제거했어요",
    "core.desktop.uninstalled.failed": "모두 제거하지는 못했어요. 오류 보고서에 해당 위치가 나와요.",
    "core.desktop.uninstalled.others_ok": "Docker 안의 다른 프로그램은 모두 그대로예요",
    "core.desktop.uninstalled.power_bad": "예전 에너지 설정으로 되돌리지 못했어요",
    "core.desktop.uninstalled.power_kept": "상시 실행은 켜진 채로 있어요",
    "core.desktop.uninstalled.power_ok": "예전 에너지 설정으로 돌아갔어요",
    "core.desktop.uninstalled.stopped": "어시스턴트가 멈췄고, Docker 안의 구성 요소도 지웠어요",
    "core.desktop.uninstalled.title": "어시스턴트를 제거했어요",
    "core.desktop.uninstalled.title_partial": "거의 다 제거했어요",
    "core.desktop.uninstalled.trash_app": "이제 앱 자체를 휴지통으로 옮겨도 돼요.",
    "core.desktop.wait.text": "Docker가 응답할 때까지 기다리는 중이에요. 처음에는 1~2분 걸려요. 곧 Docker 창이 열려요. 그냥 닫아도 Docker는 계속 실행돼요. 거기서 로그인할 필요는 없어요.",
    "core.desktop.wait.title": "Docker가 시작되는 중",
    "core.desktop.wait.title_fresh": "Docker를 켜는 중",
    "core.desktop.welcome.lead": "질문에 하나씩 답하면 돼요. 마지막에는 텔레그램에서 어시스턴트(텔레그램에서는 봇이라고 해요)와 대화하고, 내 데이터는 이 컴퓨터에 그대로 남아요.",
    "core.desktop.welcome.start": "시작하기",
    "core.desktop.welcome.time": "30분 정도 걸려요. 언제든 멈추고 나중에 바로 여기서 이어 할 수 있어요.",
    "core.desktop.welcome.title": "몇 단계면 나만의 어시스턴트가 생겨요",
    "core.wizard.step.about": "나에 대해",
    "core.wizard.step.access": "접근",
    "core.wizard.step.aria": "설정 단계",
    "core.wizard.step.check": "확인",
    "core.wizard.step.connect": "연결",
    "core.wizard.step.docker": "Docker",
    "core.wizard.step.done": "완료",
    "core.wizard.step.install": "설치",
    "core.wizard.step.modules": "모듈",
    "core.wizard.step.power": "상시 실행",
    "core.wizard.step.prepare": "준비",
    "core.wizard.step.questions": "질문",
    "core.wizard.step.reach": "연결 방법",
    "core.wizard.step.short": "{total}단계 중 {n}단계 · {name}",
  },
};
/* ui-locale:end */

// Sprache der Seiten: Systemsprache, nach einer Wahl im Fragebogen diese (Rust: lang.rs, kommt mit `startup`).
let LANG = 'de';
const LOCALE = { de: 'de-DE', en: 'en-GB', ko: 'ko-KR' };

/** Text zu `key` mit Platzhaltern {name}; fehlt er in der Sprache, der deutsche, sonst der Schlüssel. */
function t(key, vars) {
  const s = (UI_TEXT[LANG] && UI_TEXT[LANG][key]) || UI_TEXT.de[key] || key;
  return vars ? s.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k]) : m)) : s;
}
/** Wie t, `**fett**` wird zu <b> (Knoten, kein HTML). */
const tb = (key, vars) => t(key, vars).split(/\*\*(.+?)\*\*/).map((part, i) => (i % 2 ? h('b', {}, part) : part));
const K = (code) => code.replace(/-/g, '_');
const has = (key) => key in UI_TEXT.de;

const mac = () => state.os === 'mac';
const machine = () => t(mac() ? 'core.desktop.machine.mac' : 'core.desktop.machine.pc');
const engine = (id) => t('core.desktop.engine.' + K(id || 'unknown'));
const errorText = (code) => (typeof code === 'string' && has('core.desktop.error.' + K(code)) ? t('core.desktop.error.' + K(code)) : t('core.desktop.error.unknown'));
const gb = (mb) => new Intl.NumberFormat(LOCALE[LANG], { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(mb / 1024);

// ------------------------------------------------------------------------------------------ Darstellung

/* ui-copy:begin ui.steps.js (kopiert von scripts/build_ui_tokens.ps1 aus config/ui.steps.js, nicht von Hand aendern) */
// Schritt-Leiste der Einrichtung, gemeinsam für Start-App und Fragebogen im selben Fenster: Jede Seite zeichnet sie selbst,
// mit derselben Reihenfolge und demselben Aussehen (config/ui.steps.css). Kopie per scripts/build_ui_tokens.ps1 als Block in
// die Datei jeder Oberfläche (so liegt sie auch im Release-Paket des Fragebogens), kein Nachladen zur Laufzeit.
// Die App zeichnet prepare, docker, power und done; der Fragebogen questions (mit Unterschritten), install und connect.
// Texte stehen hier keine: Der Aufrufer gibt sie mit (Fragebogen aus dem Textkatalog, Schlüssel core.wizard.step.<id>).
// Nur textContent, kein HTML, keine Abhängigkeit.
const UiSteps = {
  steps: [
    { id: 'prepare' },
    { id: 'docker' },
    { id: 'questions', sub: [{ id: 'about' }, { id: 'access' }, { id: 'modules' }, { id: 'reach' }, { id: 'check' }] },
    { id: 'install' },
    { id: 'connect' },
    { id: 'power' },
    { id: 'done' },
  ],

  /**
   * Leiste in `el` zeichnen. current = id aus steps, sub = id eines Unterschritts (nur bei questions) oder leer.
   * text = { step: (id) => Beschriftung, short: (n, total, name) => „Schritt 3 von 7 · Fragen“, aria: Name der Leiste }.
   * Davor = erledigt, danach = offen; Unterschritte stehen nur beim aktuellen Schritt (sonst wird es zu lang).
   * Unter 600 px Breite zeigt das CSS statt der Liste die kurze Zeile.
   */
  render(el, current, sub, text) {
    const mk = (tag, cls, txt) => {
      const e = document.createElement(tag);
      if (cls) e.className = cls;
      if (txt != null) e.textContent = txt;
      return e;
    };
    const at = this.steps.findIndex((s) => s.id === current);
    const last = this.steps.length - 1;
    const list = mk('ol', 'la-rail-list');
    this.steps.forEach((s, i) => {
      // Der letzte Schritt („Fertig“) ist erreicht = erledigt, daher dort das Häkchen statt des offenen Kreises.
      const state = i < at || (i === at && i === last) ? 'done' : i === at ? 'now' : 'todo';
      const li = mk('li', 'la-rail-step ' + state);
      if (i === at) li.setAttribute('aria-current', 'step');
      li.append(mk('i', null, state === 'done' ? '✓' : ''), mk('span', null, text.step(s.id)));
      if (state === 'now' && s.sub) {
        const subAt = s.sub.findIndex((x) => x.id === sub);
        const ul = mk('ul', 'la-rail-sub');
        s.sub.forEach((x, k) => {
          const sli = mk('li', k < subAt ? 'done' : k === subAt ? 'now' : 'todo', text.step(x.id));
          if (k === subAt) sli.setAttribute('aria-current', 'step');
          ul.append(sli);
        });
        li.append(ul);
      }
      list.append(li);
    });
    const short = mk('p', 'la-rail-short', at < 0 ? '' : text.short(at + 1, this.steps.length, text.step(this.steps[at].id)));
    el.setAttribute('aria-label', text.aria);
    el.replaceChildren(list, short);
  },
};
/* ui-copy:end */

/* ui-copy:begin ui.nudge.js (kopiert von scripts/build_ui_tokens.ps1 aus config/ui.nudge.js, nicht von Hand aendern) */
// Lese-Hinweis am Hauptknopf (Owner-Wunsch: erst lesen lassen, dann dezent auf „Weiter“ zeigen; Werte von der Leitung),
// gemeinsam für Fragebogen, Start-App und die Knöpfe in den Bildern. Kopie per scripts/build_ui_tokens.ps1 als Block in die
// Datei jeder Oberfläche (Get-UiCopies), Aussehen in config/ui.nudge.css. Keine Abhängigkeit, kein Inline-Stil (CSP).
//   UiNudge.start(getButton, isReady) beim Wechsel auf eine neue Seite; getButton() liefert den Hauptknopf (darf wechseln),
//   isReady() sagt, ob die Seite gerade gültig ist (keine Fehlermeldung, Pflichtfeld gefüllt, keine laufende Prüfung).
// Regeln: 12 s ohne Eingabe (keydown, input, pointerdown, scroll, wheel setzen die Uhr zurück) -> genau 2 Pulse von je 1,5 s,
// danach still; erneut erst nach weiteren 12 s Ruhe, höchstens 2-mal je Seite. Nicht bereit = kein Puls, es zählt nicht.
// Ohne Bewegung (prefers-reduced-motion) zeigt das CSS nur eine farbige Hervorhebung.
const UiNudge = {
  IDLE_MS: 12000,
  PULSE_MS: 3000,
  MAX: 2,
  CLS: 'la-nudge',
  _t: null,
  _n: 0,
  _get: null,
  _ready: null,
  _bound: false,

  start(getButton, isReady) {
    this.stop();
    this._get = getButton;
    this._ready = isReady || null;
    this._n = 0;
    if (!this._bound) {
      this._bound = true;
      for (const ev of ['keydown', 'input', 'pointerdown', 'scroll', 'wheel']) {
        document.addEventListener(ev, () => this._poke(), { capture: true, passive: true });
      }
    }
    this._arm();
  },
  stop() {
    clearTimeout(this._t);
    const b = this._get && this._get();
    if (b) b.classList.remove(this.CLS);
  },
  _arm() {
    clearTimeout(this._t);
    if (this._n >= this.MAX) return;
    this._t = setTimeout(() => this._fire(), this.IDLE_MS);
  },
  _fire() {
    const b = this._get && this._get();
    if (!b || b.disabled || (this._ready && !this._ready())) { this._arm(); return; }
    this._n += 1;
    b.classList.add(this.CLS);
    this._t = setTimeout(() => { b.classList.remove(this.CLS); this._arm(); }, this.PULSE_MS);
  },
  _poke() {
    if (!this._get) return;
    const b = this._get();
    if (b) b.classList.remove(this.CLS);
    this._arm();
  },
};
/* ui-copy:end */

// Schritt der Leiste je Bildschirm; Warte-Seiten nennen ihn selbst (`busy`), Fehler-Seiten behalten den vorigen. `null` = ohne
// Leiste (Seiten außerhalb der Einrichtung). Fragen, Installation und Verbinden zeichnet der Fragebogen selbst.
const STEP_OF = {
  move: 'prepare', welcome: 'prepare', need: 'prepare', sys: 'prepare', 'sys-stop': 'prepare',
  'dk-missing': 'docker', 'dk-fetch': 'docker', 'dk-stopped': 'docker', 'dk-ready': 'docker', 'dk-old': 'docker',
  'dk-memory': 'docker', 'dk-other': 'docker', 'dk-help': 'docker', 'wizard-missing': 'questions',
  power: 'power', 'power-result': 'power', done: 'done',
  resume: null, home: null, report: null, 'rolled-back': null, 'power-restore': null, 'power-restored': null, uninstall: null, uninstalled: null,
};
// Beschriftungen der Leiste: dieselben Schlüssel wie im Fragebogen (core.wizard.step.*).
const RAIL_TEXT = {
  step: (id) => t('core.wizard.step.' + id),
  short: (n, total, name) => t('core.wizard.step.short', { n, total, name }),
  get aria() {
    return t('core.wizard.step.aria');
  },
};
function drawRail(id, step) {
  if (step !== undefined) state.step = step;
  else if (id in STEP_OF) state.step = STEP_OF[id];
  const rail = $('rail');
  rail.hidden = !state.step;
  if (state.step) UiSteps.render(rail, state.step, null, RAIL_TEXT);
}

/**
 * Einen Bildschirm zeigen. s = {title, body: [Elemente], next: {label, run}, alt: {label, run}, back: bool, step: Leiste}
 */
function show(id, s) {
  clearInterval(state.poll);
  state.current = id;
  state.drawn = (state.drawn || 0) + 1;
  drawRail(id, s.step);
  main.replaceChildren(h('h1', {}, s.title), ...(s.body || []).filter((x) => x != null && x !== false));
  main.scrollTop = 0;
  const next = $('next');
  const alt = $('alt');
  const back = $('back');
  $('nav').hidden = !s.next && !s.alt && !s.back;
  next.hidden = !s.next;
  next.disabled = false;
  if (s.next) {
    next.textContent = s.next.label;
    next.onclick = () => run(next, s.next.run);
  }
  alt.hidden = !s.alt;
  if (s.alt) {
    alt.textContent = s.alt.label;
    alt.onclick = () => run(alt, s.alt.run);
  }
  const backFn = s.back === true ? BACKS[id] || boot : s.back;
  back.hidden = typeof backFn !== 'function';
  back.onclick = () => backFn();
  // Nach 12 s Ruhe dezent auf den Hauptknopf zeigen (gemeinsamer Baustein, Werte der Leitung); nur wenn es einen gibt.
  UiNudge.start(() => next, () => !next.hidden && !next.disabled);
}

// run(btn, fn) -> Knopf gesperrt, solange fn läuft. Zeichnet fn einen neuen Bildschirm, gehört der Knopf ihm (z. B. „Ja, ersetzen“
//   bleibt bis zum Haken gesperrt) und wird hier nicht wieder freigegeben.
async function run(btn, fn) {
  btn.disabled = true;
  const drawn = state.drawn;
  try {
    await fn();
  } finally {
    if (state.drawn === drawn) btn.disabled = false;
  }
}

const steps = (items) => h('ul', { class: 'steps' }, items.map(([cls, text, sub]) => h('li', { class: cls }, h('i', {}, cls === 'ok' ? '✓' : cls === 'bad' ? '!' : cls === 'warn' ? '!' : ''), h('span', {}, text, sub ? h('small', {}, sub) : null))));
/** Fortschrittsbalken. Breite über CSSOM, denn die Inhalts-Regel (CSP) verbietet style-Attribute. */
function bar(done, total) {
  const fill = h('span', {});
  fill.style.width = Math.min(100, Math.round((100 * done) / Math.max(1, total))) + '%';
  return h('div', { class: 'bar', role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': String(total), 'aria-valuenow': String(done) }, fill);
}
const note = (cls, ...kids) => h('div', { class: 'note ' + (cls || '') }, ...kids);
const link = (label, target) => h('a', { href: '#', onclick: (e) => { e.preventDefault(); invoke('open_link', { target }); } }, label);
const report = () => ({ label: t('core.desktop.common.view_report'), run: () => SCREENS.report() });

/** Warte-Seite; step = Schritt der Leiste (null = ohne Leiste). */
function busy(step, title, text) {
  show('busy', { step, title, body: [steps([['run', text]])] });
}

function failed(code, retry) {
  show('error', {
    title: t('core.desktop.error.title'),
    body: [note('bad', errorText(code)), h('p', { class: 'lead' }, t('core.desktop.error.again'))],
    next: retry ? { label: t('core.desktop.common.retry'), run: retry } : report(),
    alt: retry ? report() : null,
  });
}

// ---------------------------------------------------------------------------------------------- Bildschirme

const SCREENS = {
  move() {
    const folder = t('core.desktop.move.folder');
    show('move', {
      title: t('core.desktop.move.title'),
      body: [
        h('p', { class: 'lead' }, t('core.desktop.move.lead')),
        // Schema des Fensters der geladenen Datei; das App-Symbol ist dasselbe Zeichen wie oben im Kopf.
        h('div', { class: 'dmg' }, h('div', { class: 'ico' }, h('div', { class: 'app-ico' }, document.querySelector('.top svg').cloneNode(true)), 'lifeagents'), h('div', { class: 'arrow' }, '→'), h('div', { class: 'ico' }, h('div', { class: 'folder' }), folder)),
        h('ol', {}, h('li', {}, t('core.desktop.move.step_quit')), h('li', {}, t('core.desktop.move.step_drag')), h('li', {}, t('core.desktop.move.step_open'))),
      ],
    });
  },

  welcome() {
    // Begrüßung „Was ist lifeagents?“: dasselbe Bild wie in README und Anleitung, je Sprache eine fertige SVG mit Bewegung
    // im Bild (Quelle config/ui.art.greeting.svg, erzeugt von scripts/build_ui_tokens.ps1). Fehlt sie, bleibt nur der Text.
    const intro = h('img', { class: 'la-intro', src: `explain/greeting.${LANG}.svg`, alt: t('core.art.greeting.alt') });
    intro.addEventListener('error', () => intro.remove());
    show('welcome', {
      title: t('core.desktop.welcome.title'),
      body: [intro, h('p', { class: 'lead' }, t('core.desktop.welcome.lead')), h('p', {}, t('core.desktop.welcome.time'))],
      next: { label: t('core.desktop.welcome.start'), run: () => SCREENS.need() },
    });
  },

  need() {
    show('need', {
      title: t('core.desktop.need.title'),
      body: [
        h('p', {}, t('core.desktop.need.intro')),
        h('ul', {}, h('li', {}, tb('core.desktop.need.phone')), h('li', {}, tb('core.desktop.need.card')), h('li', {}, tb('core.desktop.need.machine'))),
        note('', t('core.desktop.need.hint')),
      ],
      next: { label: t('core.desktop.need.next'), run: () => SCREENS.sys() },
      back: true,
    });
  },

  resume() {
    show('resume', {
      title: t('core.desktop.resume.title'),
      body: [h('p', { class: 'lead' }, t('core.desktop.resume.lead')), note('', t('core.desktop.resume.note'))],
      next: { label: t('core.desktop.resume.next'), run: () => SCREENS.sys() },
      alt: { label: t('core.desktop.resume.rollback'), run: () => SCREENS.rollback() },
    });
  },

  async rollback() {
    busy('prepare', t('core.desktop.rollback.busy_title'), t('core.desktop.rollback.busy_text'));
    try {
      await invoke('rollback');
      show('rolled-back', {
        title: t('core.desktop.rollback.title'),
        body: [h('p', { class: 'lead' }, t('core.desktop.rollback.lead'))],
        next: { label: t('core.desktop.rollback.restart'), run: () => SCREENS.welcome() },
      });
    } catch (e) {
      failed(e, () => SCREENS.rollback());
    }
  },

  async sys() {
    busy('prepare', t('core.desktop.sys.busy_title', { machine: machine() }), t('core.desktop.sys.busy_text'));
    const r = await invoke('check_system');
    state.sys = r;
    const items = r.checks.map(checkLine).filter(Boolean);
    if (mac()) items.unshift(['ok', t(r.arch === 'arm64' ? 'core.desktop.sys.arm' : 'core.desktop.sys.intel')]);
    const stop = r.checks.filter((c) => c.level === 'stop');
    const hints = r.checks.filter((c) => c.level === 'hint');
    if (stop.length) {
      show('sys-stop', {
        title: t('core.desktop.sys.stop_title'),
        body: [steps(items), note('bad', t('core.desktop.common.changed_nothing'))],
        alt: report(),
        back: true,
      });
      return;
    }
    show('sys', {
      title: hints.length ? t('core.desktop.sys.hints_title') : t('core.desktop.sys.ok_title', { machine: machine() }),
      body: [steps(items), hints.length ? note('', t('core.desktop.sys.hints_note')) : null],
      next: { label: t(hints.length ? 'core.desktop.sys.next_anyway' : 'core.desktop.common.next'), run: () => SCREENS.docker() },
      back: true,
    });
  },

  async docker() {
    busy('docker', t('core.desktop.docker.busy_title'), t('core.desktop.docker.busy_text', { machine: machine() }));
    const o = await invoke('check_docker');
    state.docker = o;
    const v = o.finding.verdict;
    const go = {
      missing: SCREENS.dkMissing,
      'desktop-stopped': SCREENS.dkStopped,
      ready: SCREENS.dkReady,
      'too-old': SCREENS.dkOld,
      'low-memory': SCREENS.dkMemory,
      'other-stopped': SCREENS.dkOther,
      unsupported: SCREENS.dkHelp,
      'remote-context': SCREENS.dkHelp,
    }[v.kind];
    go(o);
  },

  dkMissing(o) {
    show('dk-missing', {
      title: t('core.desktop.missing.title'),
      body: [
        h('p', { class: 'lead' }, tb('core.desktop.missing.lead')),
        changeLists(o.changes),
        h('p', {}, t('core.desktop.missing.terms') + ' ', link(t('core.desktop.missing.terms_link'), 'docker-terms')),
      ],
      next: { label: t('core.desktop.missing.next'), run: () => SCREENS.dkFetch() },
      back: true,
    });
  },

  async dkFetch() {
    const labels = {
      download: () => t('core.desktop.fetch.download'),
      verify: () => t('core.desktop.fetch.verify'),
      password: () => t(mac() ? 'core.desktop.fetch.password_mac' : 'core.desktop.fetch.password_win'),
      start: () => t('core.desktop.fetch.start'),
    };
    const order = ['download', 'verify', 'password', 'start'];
    let stage = 'download';
    let mb = [0, state.os === 'mac' ? 573 : 624];
    const draw = () => {
      const i = order.indexOf(stage);
      const label = (s, k) => (s === 'download' && k === i ? t('core.desktop.fetch.download_progress', { done: mb[0], total: mb[1] }) : labels[s]());
      const items = order.map((s, k) => [k < i ? 'ok' : k === i ? 'run' : '', label(s, k)]);
      show('dk-fetch', {
        title: t('core.desktop.fetch.title'),
        body: [h('p', { class: 'lead' }, t('core.desktop.fetch.lead', { machine: machine() })), steps(items), stage === 'download' ? bar(mb[0], mb[1]) : null],
      });
    };
    const off = await listen('fetch-progress', (p) => {
      stage = p.stage;
      mb = [p.done_mb, p.total_mb];
      draw();
    });
    draw();
    try {
      await invoke('fetch_docker');
      stage = 'start';
      draw();
      await SCREENS.dkWait(true);
    } catch (e) {
      failed(e, () => SCREENS.docker());
    } finally {
      off();
    }
  },

  dkStopped(o) {
    show('dk-stopped', {
      title: t('core.desktop.stopped.title'),
      body: [h('p', { class: 'lead' }, t('core.desktop.stopped.lead')), changeLists(o.changes)],
      next: {
        label: t('core.desktop.stopped.next'),
        run: async () => {
          try {
            await invoke('start_docker');
            await SCREENS.dkWait(false);
          } catch (e) {
            failed(e, () => SCREENS.docker());
          }
        },
      },
      back: true,
    });
  },

  async dkWait(fresh) {
    busy('docker', t(fresh ? 'core.desktop.wait.title_fresh' : 'core.desktop.wait.title'), t('core.desktop.wait.text'));
    try {
      await invoke('wait_docker');
      const o = await invoke('check_docker');
      state.docker = o;
      if (o.finding.verdict.kind === 'ready') return SCREENS.coreStart();
      return SCREENS.docker();
    } catch (e) {
      failed(e, () => SCREENS.docker());
    }
  },

  dkReady(o) {
    const v = o.finding.verdict;
    if (o.own && o.own.kind === 'foreign') return failed('foreign-objects');
    const n = o.programs.length;
    const programs = n === 0
      ? t('core.desktop.ready.programs_none')
      : n === 1
        ? t('core.desktop.ready.programs_one', { name: o.programs[0] })
        : t('core.desktop.ready.programs_many', { n, name: o.programs[0] });
    show('dk-ready', {
      title: t('core.desktop.ready.title'),
      body: [
        h('p', { class: 'lead' }, t('core.desktop.ready.lead')),
        steps([
          ['ok', t('core.desktop.ready.running', { engine: v.engine === 'docker-desktop' ? 'Docker' : engine(v.engine) })],
          ['ok', t('core.desktop.ready.memory')],
          ['ok', programs],
        ]),
        v.tested ? null : note('warn', t('core.desktop.ready.untested', { engine: engine(v.engine) })),
        changeLists(o.changes),
      ],
      next: { label: t('core.desktop.ready.next'), run: () => SCREENS.coreStart() },
      back: true,
    });
  },

  dkOld() {
    show('dk-old', {
      title: t('core.desktop.old.title'),
      body: [
        h('p', { class: 'lead' }, t('core.desktop.old.lead', { machine: machine() })),
        h('ol', {}, h('li', {}, tb('core.desktop.old.step_open')), h('li', {}, t('core.desktop.old.step_update')), h('li', {}, t('core.desktop.common.come_back'))),
      ],
      next: { label: t('core.desktop.common.check_again'), run: () => SCREENS.docker() },
      back: true,
    });
  },

  dkMemory(o) {
    const v = o.finding.verdict;
    show('dk-memory', {
      title: t('core.desktop.memory.title'),
      body: [
        h('p', { class: 'lead' }, t('core.desktop.memory.lead', { free: gb(v.free_mb), need: gb(v.need_mb) })),
        h('ol', {}, h('li', {}, tb('core.desktop.memory.step_open')), h('li', {}, tb('core.desktop.memory.step_resources')), h('li', {}, t('core.desktop.common.come_back'))),
      ],
      next: { label: t('core.desktop.common.check_again'), run: () => SCREENS.docker() },
      back: true,
    });
  },

  dkOther(o) {
    const name = engine(o.finding.verdict.engine);
    show('dk-other', {
      title: t('core.desktop.other.title', { engine: name }),
      body: [h('p', { class: 'lead' }, t('core.desktop.other.lead', { machine: machine(), engine: name }))],
      next: { label: t('core.desktop.common.check_again'), run: () => SCREENS.docker() },
      back: true,
    });
  },

  dkHelp(o) {
    const v = o.finding.verdict;
    const what = v.kind === 'remote-context' ? t('core.desktop.engine.remote') : engine(v.engine);
    show('dk-help', {
      title: t('core.desktop.help.title'),
      body: [
        h('p', { class: 'lead' }, t('core.desktop.help.lead', { machine: machine(), what })),
        note('', t('core.desktop.help.note')),
        h('p', {}, link(t('core.desktop.help.link'), 'help')),
      ],
      next: report(),
      back: true,
    });
  },

  async coreStart() {
    busy('questions', t('core.desktop.core.busy_title'), t('core.desktop.core.busy_text'));
    try {
      await invoke('start_core');
    } catch (e) {
      if (e === 'compose-missing') return SCREENS.wizardMissing();
      return failed(e, () => SCREENS.coreStart());
    }
    return SCREENS.wizard();
  },

  async wizard() {
    let open = false;
    try {
      open = await invoke('open_wizard');
    } catch (e) {
      return failed(e, () => SCREENS.wizard());
    }
    // Der Fragebogen lädt jetzt in diesem Fenster. Zurück kommt die App von selbst (main.rs, `#power`).
    if (!open) return SCREENS.wizardMissing();
  },

  wizardMissing() {
    show('wizard-missing', {
      title: t('core.desktop.nowizard.title'),
      body: [h('p', { class: 'lead' }, t('core.desktop.nowizard.lead', { machine: machine() })), note('', t('core.desktop.nowizard.note'))],
      next: { label: t('core.desktop.nowizard.next'), run: () => SCREENS.power() },
    });
  },

  async power() {
    state.power = state.power || (await invoke('power_info'));
    const p = state.power;
    const choice = (val, title, sub, tag) =>
      h('button', { type: 'button', class: 'choice' + (state.powerYes === val ? ' sel' : ''), 'aria-pressed': String(state.powerYes === val), onclick: () => { state.powerYes = val; SCREENS.power(); } }, h('b', {}, title, tag ? h('span', { class: 'tag' }, tag) : null), h('small', {}, sub));
    show('power', {
      title: t('core.desktop.power.title'),
      body: [
        h('p', { class: 'lead' }, t(mac() ? 'core.desktop.power.lead_mac' : 'core.desktop.power.lead_win')),
        choice(true, t('core.desktop.power.yes_title'), t(mac() ? 'core.desktop.power.yes_mac' : 'core.desktop.power.yes_win'), t('core.desktop.power.recommended')),
        choice(false, t('core.desktop.power.no_title'), t('core.desktop.power.no_text')),
        p.laptop ? note('warn', t('core.desktop.power.laptop')) : null,
      ],
      next: { label: t(state.powerYes ? 'core.desktop.power.next_confirm' : 'core.desktop.common.next'), run: () => (state.powerYes ? SCREENS.powerApply() : SCREENS.powerResult(null)) },
    });
  },

  async powerApply() {
    busy('power', t('core.desktop.apply.busy_title'), t('core.desktop.apply.busy_text', { machine: machine() }));
    try {
      const r = await invoke('power_apply');
      await invoke('power_answer');
      SCREENS.powerResult(r);
    } catch (e) {
      failed(e, () => SCREENS.power());
    }
  },

  async powerResult(r) {
    if (!r) await invoke('power_answer');
    const p = state.power || (await invoke('power_info'));
    const holds = r ? r.holds : {};
    const line = (ok, yesKey, noKey) => (ok ? ['ok', t('core.desktop.result.' + yesKey)] : ['warn', t('core.desktop.result.' + noKey)]);
    const items = [];
    if (r) {
      if ('displaysleep' in holds || 'videoidle' in holds) items.push(line(holds.displaysleep ?? holds.videoidle, 'display_ok', 'display_bad'));
      items.push(line(holds.sleep ?? holds.standbyidle, 'sleep_ok', 'sleep_bad'));
      if ('autorestart' in holds) items.push(line(holds.autorestart, 'restart_ok', 'restart_bad'));
      if ('womp' in holds && !holds.womp) items.push(['warn', t('core.desktop.result.womp_bad')]);
    } else {
      items.push(['ok', t('core.desktop.result.as_before')]);
    }
    items.push(['ok', t('core.desktop.result.autostart')]);
    const hand = mac() ? (p.filevault === 'on' ? note('warn', tb('core.desktop.result.filevault')) : null) : note('warn', tb('core.desktop.result.windows_login'));
    show('power-result', {
      title: t('core.desktop.result.title'),
      body: [steps(items), hand, h('p', { class: 'lead' }, t('core.desktop.result.restore_hint'))],
      next: { label: t('core.desktop.result.next'), run: () => SCREENS.finish() },
    });
  },

  async finish() {
    busy('done', t('core.desktop.finish.busy_title'), t('core.desktop.finish.busy_text'));
    let f;
    try {
      f = await invoke('finish_setup');
    } catch (e) {
      return failed(e, () => SCREENS.finish());
    }
    show('done', {
      title: t('core.desktop.done.title'),
      body: [
        // „Tippe dort auf Haushalt einrichten“ steht schon auf der letzten Seite des Fragebogens (ein Zuhause je Fakt).
        h('p', { class: 'lead' }, t('core.desktop.done.lead')),
        h('ul', {}, h('li', {}, tb('core.desktop.done.updates')), h('li', {}, t('core.desktop.done.backup'))),
        f.deviations.length ? note('bad', t('core.desktop.done.deviations', { n: f.deviations.length })) : null,
        // Pflichtschritt: „Telegram öffnen“ erst nach dem Haken (die Begrüßung im Chat kam schon; der Schritt bleibt auf der
        // Startseite, bis er abgehakt ist).
        kitCard(() => { $('next').disabled = false; }, true),
        tidyCard(),
      ],
      next: { label: t('core.desktop.common.open_telegram'), run: () => invoke('open_link', { target: 'telegram' }) },
      alt: f.deviations.length ? report() : null,
    });
    const k = await invoke('kit_status').catch(() => ({ confirmed: false }));
    if (!k.confirmed) $('next').disabled = true;
    else document.querySelectorAll('.kit-hint').forEach((n) => n.remove());
    addRestoreCard();
  },

  async home() {
    const k = await invoke('kit_status').catch(() => ({ confirmed: true }));
    show('home', {
      title: t('core.desktop.home.title'),
      body: [h('p', { class: 'lead' }, t(mac() ? 'core.desktop.home.lead_mac' : 'core.desktop.home.lead_win')),
        k.confirmed ? null : kitCard(() => SCREENS.home())],
      next: { label: t('core.desktop.common.open_telegram'), run: () => invoke('open_link', { target: 'telegram' }) },
    });
    // Danach, ohne die Seite aufzuhalten: ein Lauf im Hintergrund oder ein Ergebnis, das noch niemand gesehen hat (Fenster
    // war zu), hat Vorrang; sonst ggf. die Karte zum alten Rechner.
    const drawn = state.drawn;
    const r = await invoke('restore_status').catch(() => null);
    const st = r && r.status;
    if (state.drawn !== drawn) return;
    if (st && st.state === 'running') return SCREENS.restoreRunning();
    if (st && !r.seen && ['ok', 'fail', 'unfinished'].includes(st.state)) return SCREENS.restoreResult(st);
    addRestoreCard();
  },

  // Symbol-Menü „Notfallblatt speichern …“: speichert sofort und zeigt das Ergebnis mit demselben Hinweis.
  async backupKit() {
    busy('done', t('core.desktop.kit.busy_title'), '');
    let text;
    try {
      const r = await invoke('save_backup_kit');
      text = [h('p', { class: 'lead' }, t('core.desktop.kit.saved', { file: r.file })), h('p', {}, t('core.desktop.kit.lead'))];
    } catch (e) {
      text = [note('bad', t(String(e) === 'kit-write' ? 'core.desktop.kit.write_failed' : 'core.desktop.kit.unavailable'))];
    }
    show('kit', { title: t('core.desktop.kit.menu_title'), body: text, next: { label: t('core.desktop.kit.close'), run: () => SCREENS.home() } });
  },

  // Symbol-Menü „Sicherungsordner ändern …“: die Fragebogen-Seite „Wohin sichern?“ öffnet sich im Fenster (commands.rs).
  async backupDir() {
    busy('done', t('core.desktop.backup_dir.busy_title'), '');
    let ok = false;
    try { ok = await invoke('change_backup_folder'); } catch (e) {
      // Einrichtung noch nicht fertig (Menü vor der nächsten Minuten-Prüfung): kein Docker-Hinweis, normaler Start.
      if (String(e) === 'setup-incomplete') { history.replaceState(null, '', location.pathname + location.search); return location.reload(); }
      ok = false;
    }
    if (!ok) {
      show('kit', { title: t('core.desktop.backup_dir.title'), body: [note('bad', t('core.desktop.kit.unavailable'))],
        next: { label: t('core.desktop.kit.close'), run: () => SCREENS.home() } });
    }
  },

  // --- Wiederherstellen (Plan restore-ohne-terminal; Kern core/src/restore.rs, Befehle commands.rs) ---------------------
  // Auswahl → (Notfallblatt) → Vorschau → läuft → Ergebnis. Der Schlüssel erreicht dieses Fenster nur beim Abtippen; die
  // Datei liest der Rust-Teil. Antworten kommen als feste Felder (Codes), nie als Text des master.
  async restoreList() {
    busy('done', t('core.desktop.backup_restore.busy_list'), '');
    await invoke('restore_forget').catch(() => {});
    const r = await invoke('restore_list').catch(() => ({ listing: { ok: false, code: 'docker' } }));
    const l = r.listing || {};
    const pickFile = { label: t('core.desktop.backup_restore.other_file'), run: async () => {
      let name = null;
      try { name = await invoke('restore_pick_file'); } catch (e) { return SCREENS.restoreProblem(e); }
      if (name) return SCREENS.restorePlan();
    } };
    if (!l.ok) {
      const key = { nofolder: 'core.desktop.backup_restore.list_nofolder', folder: 'core.desktop.backup_restore.list_folder', docker: 'core.desktop.kit.unavailable' }[l.code] || 'core.desktop.backup_restore.list_folder';
      return show('restore', { title: t('core.desktop.backup_restore.title'), body: [note(l.code === 'nofolder' ? '' : 'warn', t(key))], next: Object.assign({}, pickFile, { label: t('core.desktop.backup_restore.pick_file') }), back: () => SCREENS.home() });
    }
    const own = (l.backups || []).find((b) => b.own);
    const current = own && own.release;
    let chosen = null;
    const items = (l.backups || []).map((b) => {
      const tags = [];
      if (!b.own) tags.push(t('core.desktop.backup_restore.tag_other'));
      const otherVersion = current && b.release && b.release !== current;
      if (otherVersion) tags.push(t('core.desktop.backup_restore.tag_version'));
      const btn = h('button', { type: 'button', class: 'choice', 'aria-pressed': 'false', onclick: () => {
        chosen = b.name;
        document.querySelectorAll('.restore-list .choice').forEach((n) => { n.classList.toggle('sel', n === btn); n.setAttribute('aria-pressed', String(n === btn)); });
        $('next').disabled = false;
      } }, h('b', {}, b.date ? dateText(b.date) : b.name, ...tags.map((x) => h('span', { class: 'tag' }, x))),
      h('small', {}, b.release ? t('core.desktop.backup_restore.version', { release: b.release }) : t('core.desktop.backup_restore.version_unknown'),
        otherVersion ? [' · ', t('core.desktop.backup_restore.tag_version_text')] : null));
      return btn;
    });
    show('restore', {
      title: t('core.desktop.backup_restore.title'),
      body: [h('p', { class: 'lead' }, t(items.length ? 'core.desktop.backup_restore.list_lead' : 'core.desktop.backup_restore.list_empty')),
        items.length ? h('div', { class: 'restore-list' }, items) : null],
      next: items.length ? { label: t('core.desktop.common.next'), run: async () => {
        try { await invoke('restore_select', { name: chosen }); } catch (e) { return SCREENS.restoreProblem(e); }
        return SCREENS.restorePlan();
      } } : Object.assign({}, pickFile, { label: t('core.desktop.backup_restore.pick_file') }),
      alt: items.length ? pickFile : null,
      back: () => SCREENS.home(),
    });
    if (items.length) $('next').disabled = true;
  },

  // Probelauf: entscheidet, ob das Notfallblatt fehlt, ein Fehler zu zeigen ist oder die Vorschau kommt.
  async restorePlan() {
    busy('done', t('core.desktop.backup_restore.busy_check'), '');
    const p = await invoke('restore_plan').catch(() => ({ ok: false, code: 'docker' }));
    state.restorePlan = p;
    if (p.ok) return SCREENS.restorePreview(p);
    if (/^key_|^sheet_/.test(p.code || '')) return SCREENS.restoreKey(p);
    return SCREENS.restoreProblem(p.code, p);
  },

  restoreKey(p) {
    const lines = [1, 2, 3, 4].map((n) => h('input', { type: 'text', class: 'key-line', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', autocorrect: 'off', 'aria-label': t('core.desktop.backup_restore.key_line', { n }), placeholder: t('core.desktop.backup_restore.key_line', { n }) }));
    const problem = p && p.code && p.code !== 'key_needed' ? note('bad', restoreText(p.code, p)) : null;
    const check = async () => {
      const v = lines.map((i) => i.value);
      lines.forEach((i) => { i.value = ''; });
      try { await invoke('restore_type_sheet', { lines: v }); } catch (e) { return SCREENS.restoreKey({ code: String(e) }); }
      return SCREENS.restorePlan();
    };
    show('restore', {
      title: t('core.desktop.backup_restore.key_title'),
      body: [h('p', { class: 'lead' }, t('core.desktop.backup_restore.key_lead')), problem,
        h('button', { type: 'button', id: 'sheet-file', onclick: (e) => run(e.currentTarget, async () => {
          let ok = false;
          try { ok = await invoke('restore_pick_sheet'); } catch (err) { return SCREENS.restoreKey({ code: String(err) }); }
          if (ok) return SCREENS.restorePlan();
        }) }, t('core.desktop.backup_restore.key_file')),
        h('p', { class: 'key-or' }, t('core.desktop.backup_restore.key_or')),
        h('div', { class: 'key-lines' }, lines)],
      next: { label: t('core.desktop.backup_restore.key_check'), run: check },
      back: () => SCREENS.restoreList(),
    });
  },

  restorePreview(p) {
    const areas = (p.packages || []).map((x) => h('li', {}, has('core.desktop.backup_restore.area.' + x.name) ? t('core.desktop.backup_restore.area.' + x.name) : x.name,
      x.state === 'install' ? h('small', {}, t('core.desktop.backup_restore.pkg_install')) : x.state === 'activate' ? h('small', {}, t('core.desktop.backup_restore.pkg_activate')) : null));
    const box = h('input', { type: 'checkbox', id: 'restore-ok' });
    const body = [h('p', { class: 'lead' }, t('core.desktop.backup_restore.preview_lead', { date: p.created ? dateText(p.created) : '?' })),
      h('p', {}, t('core.desktop.backup_restore.preview_areas')), h('ul', {}, areas),
      p.adopt_key_id ? h('p', {}, t('core.desktop.backup_restore.preview_sheet')) : null];
    if (p.has_data) {
      body.push(note('warn', h('p', {}, t('core.desktop.backup_restore.preview_replace')),
        h('label', { class: 'kit-check' }, box, ' ', t('core.desktop.backup_restore.preview_confirm'))));
      box.addEventListener('change', () => { $('next').disabled = !box.checked; });
    } else {
      body.push(h('p', {}, t('core.desktop.backup_restore.preview_empty')));
    }
    show('restore', {
      title: t('core.desktop.backup_restore.preview_title'),
      body,
      next: { label: t(p.has_data ? 'core.desktop.backup_restore.go_replace' : 'core.desktop.backup_restore.go'), run: async () => {
        const r = await invoke('restore_run').catch(() => ({ ok: false, code: 'docker' }));
        if (!r.ok) return SCREENS.restoreProblem(r.code, r);
        return SCREENS.restoreRunning();
      } },
      back: () => SCREENS.restoreList(),
    });
    if (p.has_data) $('next').disabled = true;
  },

  restoreRunning() {
    show('restore', { title: t('core.desktop.backup_restore.running_title'), body: [steps([['run', t('core.desktop.backup_restore.running_text')]])] });
    state.poll = setInterval(async () => {
      const s = await invoke('restore_status').catch(() => null);
      const st = s && s.status;
      if (st && st.state !== 'running') { clearInterval(state.poll); SCREENS.restoreResult(st); }
    }, 2000);
  },

  async restoreResult(st) {
    await invoke('restore_seen', { started: st.started || 0 }).catch(() => {});
    if (st.state !== 'ok') return SCREENS.restoreProblem(st.state === 'unfinished' ? 'unfinished' : st.code, st);
    const p = state.restorePlan || {};
    const body = [h('p', { class: 'lead' }, t('core.desktop.backup_restore.ok_lead', { date: st.created ? dateText(st.created) : '?' }))];
    if (p.has_data) body.push(h('p', {}, t('core.desktop.backup_restore.ok_safety')));
    if (st.foreign) body.push(note('warn', h('p', {}, t('core.desktop.backup_restore.ok_foreign')), h('p', {}, t('core.desktop.backup_restore.ok_old_machine'))), kitCard(() => {}));
    state.restorePlan = null;
    show('restore', { title: t('core.desktop.backup_restore.ok_title'), body, next: { label: t('core.desktop.kit.close'), run: () => SCREENS.home() } });
  },

  restoreProblem(code, p) {
    const c = String(code || 'internal');
    const again = ['busy', 'unfinished', 'docker', 'folder', 'safety', 'nofolder'].includes(c);
    show('restore', {
      title: t('core.desktop.backup_restore.fail_title'),
      // Gelb, nicht rot: es ist nichts kaputtgegangen, die Daten sind unverändert (rot nur bei akutem Schaden).
      body: [note('warn', restoreText(c, p || {})), h('p', {}, t('core.desktop.backup_restore.unchanged')),
        c === 'version_older' ? h('p', {}, link(t('core.desktop.backup_restore.guide'), 'backup-guide')) : null],
      next: again ? { label: t('core.desktop.common.retry'), run: () => SCREENS.restoreList() } : { label: t('core.desktop.backup_restore.choose_other'), run: () => SCREENS.restoreList() },
      alt: { label: t('core.desktop.kit.close'), run: () => SCREENS.home() },
    });
  },

  async report() {
    const text = await invoke('error_report');
    show('report', {
      title: t('core.desktop.report.title'),
      body: [h('p', { class: 'lead' }, t('core.desktop.report.lead')), h('pre', { class: 'report' }, text)],
      next: { label: t('core.desktop.report.copy'), run: async () => { await navigator.clipboard.writeText(text); $('next').textContent = t('core.desktop.report.copied'); } },
      back: true,
    });
  },

  async powerRestore() {
    show('power-restore', {
      title: t('core.desktop.restore.title'),
      body: [h('p', { class: 'lead' }, t('core.desktop.restore.lead', { machine: machine() }))],
      next: {
        label: t('core.desktop.restore.next'),
        run: async () => {
          try {
            await invoke('power_restore');
            show('power-restored', { title: t('core.desktop.restore.done_title'), body: [h('p', { class: 'lead' }, t('core.desktop.common.close_window'))] });
          } catch (e) {
            failed(e, () => SCREENS.powerRestore());
          }
        },
      },
      back: true,
    });
  },

  async uninstall() {
    const p = await invoke('uninstall_plan');
    const opts = [];
    const opt = (key, name) => h('label', { class: 'opt' }, h('input', { type: 'checkbox', id: 'u-' + key }), h('span', {}, t('core.desktop.uninstall.' + name), h('small', {}, t('core.desktop.uninstall.' + name + '_text'))));
    if (p.data_volumes.length) opts.push(opt('delete_data', 'data'));
    if (p.power) opts.push(opt('restore_power', 'power'));
    if (p.autostart) opts.push(opt('remove_autostart', 'autostart'));
    if (p.docker_installed_by_us) opts.push(opt('remove_docker', 'docker'));
    show('uninstall', {
      title: t('core.desktop.uninstall.title'),
      body: [h('p', { class: 'lead' }, t('core.desktop.uninstall.lead')), ...opts],
      next: {
        label: t('core.desktop.uninstall.next'),
        run: async () => {
          const c = (k) => !!($('u-' + k) && $('u-' + k).checked);
          const choices = { delete_data: c('delete_data'), restore_power: c('restore_power'), remove_autostart: c('remove_autostart'), remove_docker: c('remove_docker') };
          busy(null, t('core.desktop.uninstall.busy_title'), t('core.desktop.uninstall.busy_text'));
          const o = await invoke('uninstall_run', { choices });
          // Je Auswahl eine Zeile, was jetzt gilt; ein fehlgeschlagener Schritt steht als Warnung (Codes aus uninstall.rs).
          const bad = (code) => o.failed.some((f) => f === code || f.startsWith(code + ':'));
          const u = (k) => t('core.desktop.uninstalled.' + k);
          const row = (chosen, code) => (chosen ? (bad(code) ? ['warn', u(code + '_bad')] : ['ok', u(code + '_ok')]) : ['ok', u(code + '_kept')]);
          const done = [['ok', u('stopped')]];
          if (p.data_volumes.length) done.push(row(choices.delete_data, 'data'));
          if (p.power) done.push(row(choices.restore_power, 'power'));
          if (p.autostart) done.push(row(choices.remove_autostart, 'autostart'));
          if (p.docker_installed_by_us) done.push(row(choices.remove_docker, 'docker'));
          if (!o.deviations.length) done.push(['ok', u('others_ok')]);
          const partial = o.failed.length || o.deviations.length;
          show('uninstalled', {
            title: u(partial ? 'title_partial' : 'title'),
            body: [
              steps(done),
              o.deviations.length ? note('bad', t('core.desktop.uninstalled.deviations', { n: o.deviations.length })) : null,
              o.failed.length ? note('warn', u('failed')) : null,
              h('p', { class: 'lead' }, u('trash_app')),
            ],
            next: partial ? report() : null,
          });
        },
      },
      back: true,
    });
  },
};

/**
 * Letzter Schritt auf der Fertig-Seite: die geladene Datei auf Wunsch in den Papierkorb (Owner: am Ende, nicht am Anfang;
 * nie ungefragt, nur bei genau einem Treffer). Das Auswerfen der DMG macht die App schon beim Start.
 */
// kitCard(onDone, nextHint) -> Schritt „Notfallblatt speichern“ (Fertig- und Startseite): Knopf legt eine neue Datei in
//   Downloads ab, der Haken wird erst danach frei und bleibt gemerkt (confirm_kit). Der Schlüssel erscheint nie im Fenster.
//   warn, solange offen: ohne den Schlüssel lassen sich Sicherungen auf einem neuen Rechner nicht öffnen. nextHint = die
//   Seite sperrt ihren Hauptknopf bis zum Haken und sagt das.
function kitCard(onDone, nextHint) {
  const card = h('div', { class: 'note warn kit' });
  const hint = nextHint ? h('p', { class: 'kit-hint' }, t('core.desktop.kit.next_hint', { button: t('core.desktop.common.open_telegram') })) : null;
  const msg = h('p', { class: 'kit-msg' });
  const box = h('input', { type: 'checkbox', id: 'kit-check', disabled: true });
  const save = async () => {
    try {
      const r = await invoke('save_backup_kit');
      msg.textContent = t('core.desktop.kit.saved', { file: r.file });
      box.disabled = false;
    } catch (e) {
      msg.textContent = t(String(e) === 'kit-write' ? 'core.desktop.kit.write_failed' : 'core.desktop.kit.unavailable');
    }
  };
  box.addEventListener('change', async () => {
    if (!box.checked) return;
    await invoke('confirm_kit');
    if (hint) hint.remove();
    if (onDone) onDone();
  });
  card.append(...[
    h('h2', {}, t('core.desktop.kit.title')),
    h('p', {}, t('core.desktop.kit.lead')),
    h('button', { type: 'button', id: 'kit-save', onclick: (e) => run(e.currentTarget, save) }, t('core.desktop.kit.button')),
    msg,
    h('label', { class: 'kit-check' }, box, ' ', t('core.desktop.kit.check')),
    hint].filter(Boolean));
  return card;
}

/** Datum + Uhrzeit einer Sicherung in der Sprache der App (Zeit im Dateinamen ist UTC). */
function dateText(iso) {
  const d = new Date(iso);
  if (isNaN(d)) return iso;
  return new Intl.DateTimeFormat(LOCALE[LANG], { dateStyle: 'medium', timeStyle: 'short' }).format(d);
}

/** Satz zu einem Code des Wiederherstellens (Katalog core.desktop.backup_restore.err.*), unbekannt = allgemeiner Satz. */
function restoreText(code, p) {
  const c = String(code || 'internal');
  const vars = { n: (p && p.line) || '?', id: (p && p.id) || '', release: (p && p.release) || '?', pkg: (p && p.pkg) || '?' };
  if (c === 'docker') return t('core.desktop.kit.unavailable');
  const key = 'core.desktop.backup_restore.err.' + K(c);
  return has(key) ? t(key, vars) : t('core.desktop.backup_restore.err.internal');
}

// restoreCard(listing) -> Karte „Sicherung vom alten Rechner zurückholen“ (Fertig-Seite vor dem Notfallblatt, Startseite),
//   solange fremde Sicherungen im Ordner liegen und die Karte nicht weggeklickt ist (restore::card_wanted).
function restoreCard() {
  return h('div', { class: 'note restore-card' },
    h('h2', {}, t('core.desktop.backup_restore.card_title')),
    h('p', {}, t('core.desktop.backup_restore.card_text')),
    h('button', { type: 'button', onclick: () => SCREENS.restoreList() }, t('core.desktop.backup_restore.card_go')),
    ' ',
    h('a', { href: '#', onclick: async (e) => { e.preventDefault(); await invoke('restore_dismiss_card').catch(() => {}); e.target.closest('.restore-card').remove(); } }, t('core.desktop.backup_restore.card_dismiss')));
}

/** Karte nachträglich einsetzen (die Liste braucht einen Docker-Aufruf): vor das Notfallblatt bzw. unter den Text. */
async function addRestoreCard() {
  const screen = state.current;
  const r = await invoke('restore_list').catch(() => null);
  if (!r || !r.card || state.current !== screen || document.querySelector('.restore-card')) return;
  const kit = document.querySelector('.note.kit');
  if (kit) kit.before(restoreCard()); else main.append(restoreCard());
}

function tidyCard() {
  const file = state.startup && state.startup.download;
  if (!file) return null;
  const card = h('div', { class: 'note tidy' });
  const draw = (done) => {
    card.replaceChildren(
      h('h2', {}, t(done ? 'core.desktop.tidy.done_title' : 'core.desktop.tidy.title')),
      h('p', {}, t(done ? 'core.desktop.tidy.done_text' : 'core.desktop.tidy.text', { file })),
      ...(done ? [] : [h('button', { type: 'button', id: 'trash', onclick: (e) => run(e.currentTarget, trash) }, t('core.desktop.tidy.button'))]));
  };
  const trash = async () => {
    try {
      await invoke('trash_download');
      state.startup.download = null;
      draw(true);
    } catch (e) {
      // Datei schon weg oder nicht zu bewegen: Karte verschwindet, nichts weiter zu tun.
      state.startup.download = null;
      card.remove();
    }
  };
  draw(false);
  return card;
}

// Ziel von „Zurück“ je Bildschirm; Hilfs-Bildschirme (Bericht, Entfernen) führen zum Start.
const BACKS = {
  need: () => SCREENS.welcome(),
  sys: () => SCREENS.need(),
  'sys-stop': () => SCREENS.need(),
  'dk-missing': () => SCREENS.sys(),
  'dk-stopped': () => SCREENS.sys(),
  'dk-ready': () => SCREENS.sys(),
  'dk-old': () => SCREENS.sys(),
  'dk-memory': () => SCREENS.sys(),
  'dk-other': () => SCREENS.sys(),
  'dk-help': () => SCREENS.sys(),
};

/** Seite „Das wird geändert“ (Prüfliste Nr. 8), eingebettet in die Zustimmungs-Seite. */
function changeLists(c) {
  if (!c) return null;
  const change = {
    'install-docker': (x) => t('core.desktop.changes.install_docker', { size: x.size_mb }),
    'start-docker': (x) => t('core.desktop.changes.start_docker', { engine: engine(x.engine) }),
    'wizard-containers': () => t('core.desktop.changes.wizard'),
    journal: () => t('core.desktop.changes.journal'),
  };
  const keep = {
    // Steht schon als Häkchen auf der Seite „Docker läuft“ (ein Zuhause je Fakt).
    'running-programs': () => null,
    'docker-itself': () => t('core.desktop.changes.keep_docker'),
    power: () => t('core.desktop.changes.keep_power'),
    'files-and-encryption': () => t('core.desktop.changes.keep_files'),
  };
  return h('div', {},
    h('h2', {}, t('core.desktop.changes.title')),
    h('ul', {}, c.changes.map((x) => h('li', {}, change[x.kind](x)))),
    h('h2', {}, t('core.desktop.changes.keep_title')),
    h('ul', {}, c.keeps.map((x) => keep[x.kind](x)).filter(Boolean).map((s) => h('li', {}, s))));
}

function checkLine(c) {
  const lvl = c.level === 'ok' ? 'ok' : c.level === 'stop' ? 'bad' : 'warn';
  const ok = c.level === 'ok';
  const k = (name, vars) => t('core.desktop.check.' + name, vars);
  switch (c.id) {
    case 'os-version':
      return mac()
        ? [lvl, k('os_mac', { value: c.value }), ok ? null : k('os_mac_need', { need: c.need })]
        : [lvl, k('os_win', { value: c.value }), ok ? null : k('os_win_need')];
    case 'ram':
      return [lvl, k('ram', { value: c.value }), ok ? null : k('ram_need', { need: c.need })];
    case 'disk':
      return [lvl, k('disk', { value: c.value }), ok ? null : k('disk_need', { need: c.need })];
    case 'virtualization':
      return ok ? null : [lvl, k('virt'), k('virt_need')];
    case 'wsl':
      return ok ? null : [lvl, k('wsl'), k('wsl_need')];
    case 'lanman-server':
      return null;
    case 'power-source':
      return ok ? null : [lvl, k('battery'), k('battery_need')];
    case 'backup-running':
      return ok ? null : [lvl, k('backup'), k('backup_need')];
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------------------------- Start

async function boot() {
  listen('show-screen', (id) => {
    const go = { report: SCREENS.report, uninstall: SCREENS.uninstall, 'power-restore': SCREENS.powerRestore, 'backup-kit': SCREENS.backupKit, 'backup-dir': SCREENS.backupDir, 'backup-restore': SCREENS.restoreList }[id];
    if (go) go();
  });
  const s = await invoke('startup');
  state.startup = s;
  state.os = s.os;
  LANG = UI_TEXT[s.lang] ? s.lang : 'de';
  document.documentElement.lang = LANG;
  $('back').textContent = t('core.desktop.common.back');
  if (s.location !== 'installed') return SCREENS.move();
  // Zurück aus dem Fragebogen (main.rs lädt die App mit `#power`): weiter mit dem Dauerbetrieb.
  if (location.hash === '#power') return SCREENS.power();
  // Aus dem Menü des Symbols, während der Fragebogen im Fenster stand (main.rs lädt dann mit `#…` neu).
  const fromTray = { '#report': SCREENS.report, '#uninstall': SCREENS.uninstall, '#power-restore': SCREENS.powerRestore, '#backup-kit': SCREENS.backupKit, '#backup-dir': SCREENS.backupDir, '#backup-restore': SCREENS.restoreList }[location.hash];
  if (fromTray) return fromTray();
  if (!s.journal) return failed('journal-unreadable');
  const k = s.journal.kind;
  if (k === 'complete') return SCREENS.home();
  if (k === 'interrupted' || k === 'in-progress') return SCREENS.resume();
  return SCREENS.welcome();
}

window.__lifeagents = { SCREENS, state };
boot();
