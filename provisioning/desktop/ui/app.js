// Bildschirme der Start-App. Texte aus dem Prototyp (Plan docker-installer-freunde), eine Frage je Bildschirm,
// ein Hauptknopf, Zurück als Link. Alles Prüfen und Ändern macht die App (Rust, lifeagents-desktop-core); hier nur
// Anzeige. Werte aus dem System (Programmnamen) kommen nur über textContent ins Fenster, nie als HTML.
'use strict';

const T = window.__TAURI__;
const invoke = (cmd, args) => T.core.invoke(cmd, args || {});
const listen = (ev, fn) => T.event.listen(ev, (e) => fn(e.payload));

const $ = (id) => document.getElementById(id);
const main = $('screen');
const state = { os: 'mac', startup: null, sys: null, docker: null, power: null, powerYes: true, poll: null };

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
const mac = () => state.os === 'mac';
const machine = () => (mac() ? 'Mac' : 'PC');

const ENGINE = {
  'docker-desktop': 'Docker Desktop',
  "orb-stack": "OrbStack",
  'rancher-desktop': 'Rancher Desktop',
  colima: "Colima, ein anderes Programm für Docker,",
  podman: 'Podman',
  'homebrew-docker': 'Docker aus Homebrew',
  wsl: 'eine eigene Docker-Engine im Linux-Teil von Windows',
  unknown: 'ein Docker, das die App nicht kennt',
};

const ERRORS = {
  'system-blocked': 'Dieser Rechner reicht leider nicht.',
  'docker-unsupported': 'Docker ist hier in einer Form da, die die App nicht verändert.',
  'download-failed': 'Docker ließ sich nicht laden. Prüfe die Internet-Verbindung und versuche es noch einmal.',
  'signature-failed': 'Die geladene Datei stammt nicht nachweislich von Docker. Die App hat sie gelöscht und nichts installiert.',
  'install-failed': 'Docker ließ sich nicht einrichten.',
  'install-cancelled': 'Du hast die Passwort-Abfrage abgebrochen. Es wurde nichts installiert.',
  'docker-capability': 'Deinem Docker fehlt etwas, das der Assistent braucht. Die App hat nichts gestartet. Bring Docker Desktop auf den neuesten Stand und versuche es noch einmal.',
  'docker-start-timeout': 'Docker antwortet nicht. Öffne Docker Desktop einmal selbst und warte, bis es läuft.',
  'foreign-objects': 'In Docker gibt es schon etwas mit dem Namen lifeagents, das nicht von dieser App stammt. Die App ändert daran nichts.',
  'no-free-port': 'Auf diesem Rechner ist kein passender Anschluss frei (5880 bis 5899).',
  'compose-missing': 'In dieser Test-Fassung fehlt noch ein Teil des Assistenten.',
  'start-failed': 'Der Assistent ließ sich nicht starten.',
  'wizard-unavailable': 'Der Fragebogen antwortet nicht.',
  'power-failed': 'Die Energie-Einstellungen ließen sich nicht ändern.',
  'power-cancelled': 'Du hast die Abfrage abgebrochen. Die Einstellungen bleiben, wie sie waren.',
  'journal-unreadable': 'Die App kann ihre Notizen zur Einrichtung nicht lesen.',
  'rollback-failed': 'Nicht alles ließ sich zurücknehmen. Du kannst es gleich noch einmal versuchen.',
};

// ------------------------------------------------------------------------------------------ Darstellung

/**
 * Einen Bildschirm zeigen. s = {title, body: [Elemente], next: {label, run}, alt: {label, run}, back: bool}
 */
function show(id, s) {
  clearInterval(state.poll);
  state.current = id;
  main.replaceChildren(h("h1", {}, s.title), ...(s.body || []).filter((x) => x != null && x !== false));
  main.scrollTop = 0;
  const next = $('next');
  const alt = $('alt');
  const back = $('back');
  $("nav").hidden = !s.next && !s.alt && !s.back;
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
  back.hidden = typeof backFn !== "function";
  back.onclick = () => backFn();
}

async function run(btn, fn) {
  btn.disabled = true;
  try {
    await fn();
  } finally {
    btn.disabled = false;
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

function busy(title, text) {
  show("busy", { title, body: [steps([["run", text]])] });
}

function failed(code, retry) {
  show('error', {
    title: 'Das hat nicht geklappt',
    body: [note('bad', ERRORS[code] || 'Etwas ist schiefgegangen.'), h('p', { class: 'lead' }, 'Wenn es wieder passiert, schick den Fehlerbericht an die Person, die dir die App gegeben hat. Er enthält keine Namen und keine Daten.')],
    next: retry ? { label: 'Noch einmal versuchen', run: retry } : { label: 'Fehlerbericht ansehen', run: () => SCREENS.report() },
    alt: retry ? { label: 'Fehlerbericht ansehen', run: () => SCREENS.report() } : null,
  });
}

// ---------------------------------------------------------------------------------------------- Bildschirme

const SCREENS = {
  move() {
    show('move', {
      title: 'Zieh die App zuerst in den Programme-Ordner',
      body: [
        h('p', { class: 'lead' }, 'Die App läuft gerade noch aus der geladenen Datei. So kann sie später nicht von selbst starten.'),
        h('div', { class: 'dmg' }, h('div', { class: 'ico' }, h('div', { class: 'app-ico' }, '●'), 'lifeagents'), h('div', { class: 'arrow' }, '→'), h('div', { class: 'ico' }, h('div', { class: 'folder' }), 'Programme')),
        h('ol', {}, h('li', {}, 'Beende die App.'), h('li', {}, 'Zieh das Symbol im Fenster der Datei auf den Ordner Programme.'), h('li', {}, 'Öffne lifeagents dann aus dem Programme-Ordner.')),
      ],
    });
  },

  welcome() {
    show('welcome', {
      title: 'Dein eigener Assistent, in ein paar Schritten',
      body: [
        h('p', { class: 'lead' }, 'Du beantwortest eine Frage nach der anderen. Am Ende schreibst du mit deinem Bot in Telegram, und deine Daten bleiben auf diesem Rechner.'),
        h('p', {}, 'Plane rund 30 Minuten ein. Du kannst jederzeit aufhören und später genau hier weitermachen.'),
      ],
      next: { label: 'Was brauche ich?', run: () => SCREENS.need() },
      // Owner-Entscheid: Die geladene Datei auf Wunsch in den Papierkorb, nie ungefragt (nur bei genau einem Treffer).
      alt: state.startup && state.startup.download ? { label: 'Download wegräumen', run: () => SCREENS.trashDownload() } : null,
    });
  },

  async trashDownload() {
    try {
      await invoke('trash_download');
      state.startup.download = null;
      SCREENS.welcome();
      main.append(note('', 'Die geladene Datei liegt jetzt im Papierkorb.'));
    } catch (e) {
      state.startup.download = null;
      SCREENS.welcome();
    }
  },

  need() {
    show('need', {
      title: 'Das brauchst du dafür',
      body: [
        h('p', {}, 'Lege dir kurz diese drei Dinge bereit:'),
        h('ul', {},
          h('li', {}, h('b', {}, 'Dein Handy mit Telegram.'), ' Darüber sprichst du später mit dem Bot.'),
          h('li', {}, h('b', {}, 'Eine Kreditkarte.'), ' Die KI von Anthropic rechnet nach Verbrauch direkt mit dir ab. Das Projekt selbst ist kostenlos.'),
          h('li', {}, h('b', {}, 'Diesen Rechner, und er bleibt an.'), ' Der Bot läuft hier. Am Ende fragen wir dich, ob der Rechner dafür durchlaufen soll.')),
        note('', 'Ein Mac mini oder ein anderer Rechner, der immer am Strom hängt, passt am besten. Ein Laptop, der oft zugeklappt ist, antwortet entsprechend oft nicht.'),
      ],
      next: { label: 'Los geht es', run: () => SCREENS.sys() },
      back: true,
    });
  },

  resume() {
    show('resume', {
      title: 'Die Einrichtung wurde unterbrochen',
      body: [
        h('p', { class: 'lead' }, 'Die App hat sich gemerkt, wie weit sie gekommen ist. Du kannst dort weitermachen oder alles zurücknehmen, was sie bisher geändert hat.'),
        note('', 'Zurücknehmen lässt deine Daten und andere Programme in Ruhe. Docker selbst bleibt installiert.'),
      ],
      next: { label: 'Weiter einrichten', run: () => SCREENS.sys() },
      alt: { label: 'Alles zurücknehmen', run: () => SCREENS.rollback() },
    });
  },

  async rollback() {
    busy('Alles wird zurückgenommen', 'Schritte der Einrichtung zurücknehmen');
    try {
      await invoke('rollback');
      show('rolled-back', {
        title: 'Alles ist zurückgenommen',
        body: [h('p', { class: 'lead' }, 'Die App hat ihre Änderungen rückgängig gemacht. Andere Programme und deine Dateien sind unberührt.')],
        next: { label: 'Neu beginnen', run: () => SCREENS.welcome() },
      });
    } catch (e) {
      failed(e, () => SCREENS.rollback());
    }
  },

  async sys() {
    busy('Dein ' + machine() + ' wird geprüft', 'Bauart, System, Speicher und freier Platz');
    const r = await invoke('check_system');
    state.sys = r;
    const items = r.checks.map(checkLine).filter(Boolean);
    if (mac()) items.unshift(["ok", r.arch === "arm64" ? "Mac mit Apple-Chip" : "Mac mit Intel-Prozessor"]);
    const stop = r.checks.filter((c) => c.level === 'stop');
    const hints = r.checks.filter((c) => c.level === 'hint');
    if (stop.length) {
      show('sys-stop', {
        title: 'Dieser Rechner reicht leider nicht',
        body: [steps(items), note('bad', 'Die App hat nichts geändert.')],
        alt: { label: 'Fehlerbericht ansehen', run: () => SCREENS.report() },
        back: true,
      });
      return;
    }
    show('sys', {
      title: hints.length ? 'Fast alles passt' : 'Dein ' + machine() + ' passt',
      body: [steps(items), hints.length ? note('', 'Das ist kein Hindernis. Wenn du magst, mach später weiter: Bis hierher hat die App nichts verändert.') : null],
      next: { label: hints.length ? 'Trotzdem weiter' : 'Weiter zu Docker', run: () => SCREENS.docker() },
      back: true,
    });
  },

  async docker() {
    busy('Docker wird geprüft', 'Ist Docker auf diesem ' + machine() + ' schon da, und läuft es?');
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
      title: 'Die App braucht ein Hilfsprogramm',
      body: [
        h('p', { class: 'lead' }, 'Es heißt ', h('b', {}, 'Docker'), ' und hält deinen Assistenten sauber getrennt vom Rest deines Rechners. Du musst es nie selbst bedienen. Die App holt es direkt vom Hersteller und richtet es ein.'),
        changeLists(o.changes),
        h('p', {}, 'Für private Nutzung ist Docker kostenlos. Der Hersteller hat eigene Nutzungsbedingungen. ', link('Hier kannst du sie lesen.', 'docker-terms')),
      ],
      next: { label: 'Einverstanden, Docker holen', run: () => SCREENS.dkFetch() },
      back: true,
    });
  },

  async dkFetch() {
    const labels = {
      download: 'Docker laden',
      verify: 'Prüfen, ob die Datei wirklich vom Hersteller stammt',
      password: mac() ? 'Dein Passwort bestätigen' : 'Die Frage von Windows bestätigen',
      start: 'Docker starten',
    };
    const order = ['download', 'verify', 'password', 'start'];
    let stage = 'download';
    let mb = [0, state.os === 'mac' ? 573 : 624];
    const draw = () => {
      const i = order.indexOf(stage);
      const items = order.map((s, k) => [k < i ? 'ok' : k === i ? 'run' : '', labels[s] + (s === 'download' && k === i ? ' (' + mb[0] + ' von rund ' + mb[1] + ' MB)' : '')]);
      show('dk-fetch', {
        title: 'Docker wird geholt',
        body: [
          h('p', { class: 'lead' }, 'Du kannst das Fenster offen lassen und etwas anderes tun, bis dein ' + machine() + ' etwas von dir möchte.'),
          steps(items),
          stage === 'download' ? bar(mb[0], mb[1]) : null,
        ],
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
      title: 'Docker ist da, aber gerade aus',
      body: [
        h('p', { class: 'lead' }, 'Die App installiert nichts dazu. Sie startet Docker und nutzt es mit.'),
        changeLists(o.changes),
      ],
      next: {
        label: 'Einverstanden, Docker starten',
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
    busy(fresh ? 'Docker wird gestartet' : 'Docker startet', 'Warten, bis Docker antwortet. Das dauert beim ersten Mal ein bis zwei Minuten.');
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
      ? 'In Docker läuft gerade nichts anderes.'
      : n === 1
        ? 'Dort läuft schon ' + o.programs[0] + '. Es bleibt, wie es ist.'
        : 'Dort laufen schon ' + n + ' Programme, zum Beispiel ' + o.programs[0] + '. Sie bleiben, wie sie sind.';
    show('dk-ready', {
      title: 'Docker ist schon da, wir nutzen es mit',
      body: [
        h('p', { class: 'lead' }, 'Du musst nichts installieren. Die App legt sich daneben und fasst nichts an, was schon läuft.'),
        steps([
          ['ok', (v.engine === 'docker-desktop' ? 'Docker' : ENGINE[v.engine]) + ' läuft und ist aktuell genug'],
          ['ok', 'Genug freier Speicher auch für den Assistenten'],
          ['ok', programs],
        ]),
        v.tested ? null : note('warn', 'Die App ist mit Docker Desktop getestet. ' + ENGINE[v.engine] + ' sollte genauso gehen, sicher ist das nicht.'),
        changeLists(o.changes),
      ],
      next: { label: 'Einverstanden, weiter', run: () => SCREENS.coreStart() },
      back: true,
    });
  },

  dkOld(o) {
    show('dk-old', {
      title: 'Dein Docker ist zu alt',
      body: [
        h('p', { class: 'lead' }, 'Docker läuft schon auf deinem ' + machine() + ', aber die App braucht eine neuere Version. Die App aktualisiert es nicht selbst, weil dort vielleicht andere Programme laufen.'),
        h('ol', {}, h('li', {}, 'Öffne ', h('b', {}, 'Docker Desktop'), '.'), h('li', {}, 'Starte dort das Update.'), h('li', {}, 'Komm hierher zurück.')),
      ],
      next: { label: 'Noch einmal prüfen', run: () => SCREENS.docker() },
      back: true,
    });
    void o;
  },

  dkMemory(o) {
    const v = o.finding.verdict;
    const gb = (mbv) => (mbv / 1024).toFixed(1).replace('.', ',');
    show('dk-memory', {
      title: "In Docker ist zu wenig Arbeitsspeicher frei",
      body: [
        h('p', { class: 'lead' }, 'Frei sind ' + gb(v.free_mb) + ' GB, der Assistent braucht ' + gb(v.need_mb) + ' GB. Die App ändert daran nichts, weil sich die anderen Programme in Docker den Speicher teilen.'),
        h('ol', {}, h('li', {}, 'Öffne ', h('b', {}, 'Docker Desktop'), ' und dort die Einstellungen.'), h("li", {}, "Unter ", h("b", {}, "Resources"), " (so heißt der Punkt dort) gibst du Docker mehr Arbeitsspeicher."), h('li', {}, 'Komm hierher zurück.')),
      ],
      next: { label: 'Noch einmal prüfen', run: () => SCREENS.docker() },
      back: true,
    });
  },

  dkOther(o) {
    const name = ENGINE[o.finding.verdict.engine];
    show('dk-other', {
      title: 'Bitte starte zuerst ' + name,
      body: [h('p', { class: 'lead' }, 'Auf diesem ' + machine() + ' ist ' + name + ' installiert, aber gerade aus. Die App installiert kein zweites Docker daneben. Starte ' + name + ' und komm hierher zurück.')],
      next: { label: 'Noch einmal prüfen', run: () => SCREENS.docker() },
      back: true,
    });
  },

  dkHelp(o) {
    const v = o.finding.verdict;
    const what = v.kind === 'remote-context' ? 'ein Docker, das auf einem anderen Rechner läuft' : ENGINE[v.engine];
    show('dk-help', {
      title: 'Hier brauchst du kurz Hilfe',
      body: [
        h('p', { class: 'lead' }, 'Auf diesem ' + machine() + ' gibt es schon ' + what + '. Die App installiert nichts dazu und ändert daran nichts, damit nichts kaputtgeht.'),
        note('', 'Die App hat nichts geändert. Schick den Fehlerbericht an die Person, die dir die App gegeben hat. ', link('Hilfe auf der Projekt-Seite', 'help')),
      ],
      next: { label: 'Fehlerbericht ansehen', run: () => SCREENS.report() },
      back: true,
    });
  },

  async coreStart() {
    busy('Der Fragebogen wird vorbereitet', 'Das dauert beim ersten Mal ein paar Minuten, weil die App zwei kleine Programmteile lädt.');
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
      title: 'Der Fragebogen fehlt in dieser Test-Fassung noch',
      body: [
        h('p', { class: 'lead' }, 'Alles bis hierher war echt: Die App hat deinen ' + machine() + ' und Docker geprüft. Den Fragebogen bringt eine spätere Fassung.'),
        note('', 'Die übrigen Schritte der App kannst du trotzdem ausprobieren.'),
      ],
      next: { label: 'Weiter zum Dauerbetrieb', run: () => SCREENS.power() },
    });
  },

  async power() {
    state.power = state.power || (await invoke('power_info'));
    const p = state.power;
    const yes = mac()
      ? 'Er schläft nicht mehr ein und startet nach einem Stromausfall von selbst. Ein Mac mini kostet so rund 10 bis 20 € Strom im Jahr.'
      : 'Er schläft nicht mehr ein. Ein PC braucht deutlich mehr Strom als ein Mac mini.';
    const choice = (val, title, sub, tag) =>
      h('button', { type: 'button', class: 'choice' + (state.powerYes === val ? ' sel' : ''), 'aria-pressed': String(state.powerYes === val), onclick: () => { state.powerYes = val; SCREENS.power(); } }, h('b', {}, title, tag ? h('span', { class: 'tag' }, tag) : null), h('small', {}, sub));
    show('power', {
      title: 'Soll dieser Rechner durchlaufen?',
      body: [
        h('p', { class: 'lead' }, mac() ? 'Der Bildschirm geht nach 10 Minuten aus, und der Mac arbeitet leise weiter. So antwortet dein Bot jederzeit.' : 'Der Bildschirm geht nach 10 Minuten aus, und der PC arbeitet weiter. So antwortet dein Bot jederzeit.'),
        choice(true, 'Ja, er soll durchlaufen', yes, 'empfohlen'),
        choice(false, 'Nein, ich lasse alles, wie es ist', 'Schläft dein Rechner, antwortet der Bot erst, wenn er wieder wach ist.'),
        p.laptop ? note('warn', 'Dein Rechner hat einen Akku. Das gilt nur am Netzteil: Zugeklappt oder auf Akku schläft er trotzdem ein.') : null,
      ],
      next: { label: state.powerYes ? 'Weiter zur Bestätigung' : 'Weiter', run: () => (state.powerYes ? SCREENS.powerApply() : SCREENS.powerResult(null)) },
    });
  },

  async powerApply() {
    busy('Bestätige die Änderung', 'Dein ' + machine() + ' fragt dich gleich, ob die App die Energie-Einstellungen ändern darf.');
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
    const line = (ok, yesText, noText) => (ok ? ['ok', yesText] : ['warn', noText]);
    const items = [];
    if (r) {
      if ('displaysleep' in holds || 'videoidle' in holds) items.push(line(holds.displaysleep ?? holds.videoidle, 'Der Bildschirm geht nach 10 Minuten aus', 'Der Bildschirm-Wert ließ sich nicht setzen'));
      items.push(line(holds.sleep ?? holds.standbyidle, 'Der Rechner schläft nicht mehr ein', 'Der Rechner kann weiter einschlafen; die Einstellung hat nicht gegriffen'));
      if ('autorestart' in holds) items.push(line(holds.autorestart, 'Nach einem Stromausfall startet er von selbst', 'Der Start nach einem Stromausfall ließ sich nicht einschalten'));
      if ('womp' in holds && !holds.womp) items.push(['warn', 'Wecken übers Netz ließ sich nicht einschalten']);
    } else {
      items.push(['ok', 'Der Rechner schläft wie bisher, der Bot wartet dann']);
    }
    items.push(['ok', 'Nach deiner Anmeldung starten Docker und der Bot von selbst']);
    const hand = mac()
      ? (p.filevault === 'on' ? note('warn', h('b', {}, 'Eine Sache bleibt von Hand: '), 'Dein Mac verschlüsselt seine Festplatte. Das schützt deine Daten, falls jemand ihn mitnimmt. Nach einem Stromausfall wartet er deshalb auf dein Passwort. Bis du dich angemeldet hast, schweigt der Bot, und er kann dir das auch nicht vorher sagen.') : null)
      : note('warn', h('b', {}, 'Eine Sache bleibt von Hand: '), 'Nach einem Neustart, zum Beispiel durch ein Windows-Update, musst du dich einmal anmelden. Bis dahin schweigt der Bot.');
    show('power-result', {
      title: 'So verhält sich dein Rechner jetzt',
      body: [steps(items), hand, h('p', { class: 'lead' }, 'Das alte Verhalten kannst du jederzeit über das Symbol der App zurückholen.')],
      next: { label: 'Fertig stellen', run: () => SCREENS.finish() },
    });
  },

  async finish() {
    busy('Einen Moment', 'Start bei der Anmeldung eintragen und nachsehen, ob alles andere unverändert ist');
    let f;
    try {
      f = await invoke('finish_setup');
    } catch (e) {
      return failed(e, () => SCREENS.finish());
    }
    show('done', {
      title: 'Fertig. Schreib deinem Bot etwas',
      body: [
        h('p', { class: 'lead' }, 'Dein Bot ist eingerichtet und hat dir in Telegram geschrieben. Tippe dort auf ', h('b', {}, 'Haushalt einrichten'), '.'),
        h('ul', {},
          h('li', {}, 'Neue Versionen meldet dir der Bot im Chat. Du tippst auf ', h('b', {}, 'Jetzt aktualisieren'), ', das Update sichert vorher deine Daten.'),
          h('li', {}, 'Deine Daten liegen nur auf diesem Rechner. Mach ab und zu eine Sicherung, der Bot erklärt dir, wie.')),
        f.deviations.length ? note('bad', 'Bei anderen Programmen in Docker hat sich während der Einrichtung etwas verändert (' + f.deviations.length + ' Stellen). Schick bitte den Fehlerbericht.') : null,
      ],
      next: { label: 'Telegram öffnen', run: () => invoke('open_link', { target: 'telegram' }) },
      alt: f.deviations.length ? { label: 'Fehlerbericht ansehen', run: () => SCREENS.report() } : null,
    });
  },

  home() {
    show('home', {
      title: 'Dein Assistent ist eingerichtet',
      body: [h('p', { class: 'lead' }, (mac() ? 'Oben in der Menüleiste' : 'Unten neben der Uhr') + ' siehst du am Symbol der App, ob alles läuft. Dieses Fenster kannst du schließen.')],
      next: { label: 'Telegram öffnen', run: () => invoke('open_link', { target: 'telegram' }) },
    });
  },

  async report() {
    const text = await invoke('error_report');
    show('report', {
      title: 'Fehlerbericht',
      body: [
        h('p', { class: 'lead' }, 'Er enthält nur feste Angaben zum Rechner und zu Docker, keine Namen, keine Adressen und keine Daten. Kopiere ihn in eine Nachricht an die Person, die dir die App gegeben hat.'),
        h('pre', { class: 'report' }, text),
      ],
      next: { label: 'Kopieren', run: async () => { await navigator.clipboard.writeText(text); $('next').textContent = 'Kopiert'; } },
      back: true,
    });
  },

  async powerRestore() {
    show('power-restore', {
      title: 'Dauerbetrieb zurückstellen?',
      body: [h('p', { class: 'lead' }, 'Dein ' + machine() + ' bekommt seine alten Energie-Einstellungen zurück. Danach schläft er wieder ein, und der Bot antwortet erst, wenn er wach ist.')],
      next: {
        label: 'Zurückstellen',
        run: async () => {
          try {
            await invoke('power_restore');
            show('power-restored', { title: 'Die alten Einstellungen gelten wieder', body: [h('p', { class: 'lead' }, 'Du kannst dieses Fenster schließen.')] });
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
    const opt = (key, title, sub) => h('label', { class: 'opt' }, h('input', { type: 'checkbox', id: 'u-' + key }), h('span', {}, title, h('small', {}, sub)));
    if (p.data_volumes.length) opts.push(opt('delete_data', 'Auch meine Daten löschen', 'Gespräche, Belege und Einstellungen des Assistenten. Das lässt sich nicht rückgängig machen.'));
    if (p.power) opts.push(opt('restore_power', 'Alte Energie-Einstellungen zurückholen', 'Der Rechner schläft danach wieder wie früher.'));
    if (p.autostart) opts.push(opt('remove_autostart', 'Nicht mehr bei der Anmeldung starten', 'Ohne diesen Eintrag startet die App nur, wenn du sie öffnest.'));
    if (p.docker_installed_by_us) opts.push(opt('remove_docker', 'Docker Desktop entfernen', 'Nur sinnvoll, wenn kein anderes Programm Docker braucht.'));
    show('uninstall', {
      title: 'Was soll entfernt werden?',
      body: [
        h('p', { class: 'lead' }, 'Der Assistent wird angehalten, und seine Teile in Docker verschwinden. Andere Programme in Docker bleiben, wie sie sind. Alles Weitere wählst du hier.'),
        ...opts,
      ],
      next: {
        label: 'Entfernen',
        run: async () => {
          const c = (k) => !!($('u-' + k) && $('u-' + k).checked);
          const choices = { delete_data: c('delete_data'), restore_power: c('restore_power'), remove_autostart: c('remove_autostart'), remove_docker: c('remove_docker') };
          busy('Wird entfernt', 'Assistent anhalten und seine Teile entfernen');
          const o = await invoke('uninstall_run', { choices });
          show('uninstalled', {
            title: o.failed.length || o.deviations.length ? 'Fast alles ist entfernt' : 'Der Assistent ist entfernt',
            body: [
              o.deviations.length ? note('bad', 'Bei anderen Programmen in Docker hat sich etwas verändert (' + o.deviations.length + ' Stellen). Schick bitte den Fehlerbericht.') : steps([['ok', 'Alle anderen Programme in Docker sind unverändert']]),
              o.failed.length ? note('warn', 'Nicht alles ließ sich entfernen. Der Fehlerbericht nennt die Stellen.') : null,
              h('p', { class: 'lead' }, 'Die App selbst kannst du jetzt in den Papierkorb ziehen.'),
            ],
            next: o.failed.length || o.deviations.length ? { label: 'Fehlerbericht ansehen', run: () => SCREENS.report() } : null,
          });
        },
      },
      back: true,
    });
  },
};

/** Seite „Das wird geändert“ (Prüfliste Nr. 8), eingebettet in die Zustimmungs-Seite. */
// Ziel von „Zurück“ je Bildschirm; Hilfs-Bildschirme (Bericht, Entfernen) führen zum Start.
const BACKS = {
  need: () => SCREENS.welcome(),
  sys: () => SCREENS.need(),
  "sys-stop": () => SCREENS.need(),
  "dk-missing": () => SCREENS.sys(),
  "dk-stopped": () => SCREENS.sys(),
  "dk-ready": () => SCREENS.sys(),
  "dk-old": () => SCREENS.sys(),
  "dk-memory": () => SCREENS.sys(),
  "dk-other": () => SCREENS.sys(),
  "dk-help": () => SCREENS.sys(),
};

function changeLists(c) {
  if (!c) return null;
  const change = {
    'install-docker': (x) => 'Docker kommt dazu (rund ' + x.size_mb + ' MB, direkt vom Hersteller)',
    'start-docker': (x) => ENGINE[x.engine] + ' wird gestartet',
    'wizard-containers': () => 'Zwei kleine Hintergrund-Programme, die dir gleich die Fragen stellen. Mehr erst, wenn du am Ende noch einmal zustimmst',
    journal: () => 'Eine kleine Datei, in der sich die App ihre Schritte merkt, damit sie alles zurücknehmen kann',
  };
  const keep = {
    // Steht schon als Häkchen auf der Seite „Docker läuft“ (ein Zuhause je Fakt).
    'running-programs': () => null,
    'docker-itself': () => 'Docker selbst: keine neue Version, kein Neustart',
    power: () => 'Die Energie-Einstellungen, bis du am Ende Ja sagst',
    'files-and-encryption': () => 'Deine Dateien und die Festplatten-Verschlüsselung',
  };
  return h('div', {},
    h('h2', {}, 'Das wird geändert'),
    h('ul', {}, c.changes.map((x) => h('li', {}, change[x.kind](x)))),
    h('h2', {}, 'Das bleibt, wie es ist'),
    h('ul', {}, c.keeps.map((x) => keep[x.kind](x)).filter(Boolean).map((t) => h('li', {}, t))));
}

function checkLine(c) {
  const lvl = c.level === 'ok' ? 'ok' : c.level === 'stop' ? 'bad' : 'warn';
  switch (c.id) {
    case 'os-version':
      return mac()
        ? [lvl, 'macOS ' + c.value, c.level === 'ok' ? null : 'Docker braucht macOS ' + c.need + ' oder neuer.']
        : [lvl, 'Windows (Build ' + c.value + ')', c.level === 'ok' ? null : 'Docker braucht Windows 10 22H2 oder Windows 11.'];
    case 'ram':
      return [lvl, 'Arbeitsspeicher: ' + c.value + ' GB', c.level === 'ok' ? null : 'Docker braucht mindestens ' + c.need + ' GB.'];
    case 'disk':
      return [lvl, 'Freier Platz: ' + c.value + ' GB', c.level === 'ok' ? null : 'Nötig sind mindestens ' + c.need + ' GB.'];
    case 'virtualization':
      return c.level === 'ok' ? null : [lvl, 'Die Virtualisierung ist ausgeschaltet', 'Docker braucht sie. Sie lässt sich in den Einstellungen beim Start des Rechners (BIOS) einschalten.'];
    case 'wsl':
      return c.level === 'ok' ? null : [lvl, 'Windows richtet beim Einrichten von Docker noch einen Linux-Teil ein', 'Danach ist ein Neustart nötig.'];
    case 'lanman-server':
      return null;
    case 'power-source':
      return c.level === 'ok' ? null : [lvl, 'Dein Rechner läuft gerade auf Akku', 'Schließ ihn besser ans Netzteil an.'];
    case 'backup-running':
      return c.level === 'ok' ? null : [lvl, 'Time Machine sichert gerade', 'Besser danach weitermachen.'];
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------------------------- Start

async function boot() {
  listen('show-screen', (id) => {
    const go = { report: SCREENS.report, uninstall: SCREENS.uninstall, 'power-restore': SCREENS.powerRestore }[id];
    if (go) go();
  });
  const s = await invoke('startup');
  state.startup = s;
  state.os = s.os;
  if (s.location !== 'installed') return SCREENS.move();
  // Zurück aus dem Fragebogen (main.rs lädt die App mit `#power`): weiter mit dem Dauerbetrieb.
  if (location.hash === '#power') return SCREENS.power();
  // Aus dem Menü des Symbols, während der Fragebogen im Fenster stand (main.rs lädt dann mit `#…` neu).
  const fromTray = { '#report': SCREENS.report, '#uninstall': SCREENS.uninstall, '#power-restore': SCREENS.powerRestore }[location.hash];
  if (fromTray) return fromTray();
  if (!s.journal) return failed('journal-unreadable');
  const k = s.journal.kind;
  if (k === 'complete') return SCREENS.home();
  if (k === 'interrupted' || k === 'in-progress') return SCREENS.resume();
  return SCREENS.welcome();
}

window.__lifeagents = { SCREENS, state };
boot();
