// Vorschau der Start-App im Browser ohne Tauri und ohne Docker: ersetzt window.__TAURI__ durch feste, erfundene
// Antworten. Wird nur von scripts/dev/serve_desktop_preview.ps1 vor app.js eingefügt, nie in die App gebaut.
//   ?state=<fall>   missing (Standard), stopped, ready, ready-orbstack, old, memory, other, colima, remote, foreign,
//                   blocked, hints, interrupted, dmg, complete, wizard, laptop
//   ?lang=en|ko     Sprache der Seiten (Standard de)
//   ?os=win         Windows statt Mac      ?screen=<name>  direkt zu einem Bildschirm (z. B. power, report, uninstall)
//   ?hold=1         Laden bzw. Starten bleibt stehen (Fortschritt aufnehmen)   ?fail=<code>  Docker holen scheitert
//   ?waitfail=<code>  Warten auf Docker scheitert (z. B. docker-closed)   ?corefail=<code>  Start des Verbunds scheitert (z. B. docker-network)
//   ?kit=1         Notfallblatt schon abgehakt   ?kitfail=kit-write|kit-unavailable  Speichern scheitert (Bildschirme backupKit, backupDir)
//   ?click=<id>    nach dem Bildschirm einmal den Knopf mit dieser id drücken, z. B. next (Hauptknopf) oder trash
//                   (Download wegräumen auf der Fertig-Seite), um Ergebnis-Seiten aufzunehmen
'use strict';
(function () {
  // Aufnahme ohne Server (build_ui_review.ps1 -Surface desktop) setzt die Parameter vorab, sonst die Adresse.
  const q = new URLSearchParams(window.__previewParams || location.search);
  const fall = q.get('state') || 'missing';
  const os = q.get('os') === 'win' ? 'windows' : 'mac';
  const handlers = {};
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const emit = (ev, payload) => (handlers[ev] || []).forEach((fn) => fn({ payload }));

  const check = (id, level, value, need) => ({ id, level, value: String(value), need: String(need) });
  const sys = {
    os,
    arch: 'arm64',
    os_version: os === 'mac' ? '15.1' : 'Microsoft Windows 11 Home (26100)',
    ram_gb: fall === 'blocked' ? 2 : 16,
    free_gb: 240,
    laptop: fall === 'laptop' || fall === 'hints',
    checks: [
      os === 'mac' ? check('os-version', 'ok', '15.1', 14) : check('os-version', 'ok', 26100, 19045),
      check('ram', fall === 'blocked' ? 'stop' : 'ok', fall === 'blocked' ? 2 : 16, os === 'mac' ? 4 : 8),
      check('disk', 'ok', 240, 10),
      check('virtualization', 'ok', true, true),
      check('power-source', fall === 'hints' ? 'hint' : 'ok', fall === 'hints' ? 'battery' : 'ac', 'ac'),
    ].concat(os === 'mac' ? [check('backup-running', fall === 'hints' ? 'hint' : 'ok', fall === 'hints', false)] : []),
  };

  const verdicts = {
    missing: { kind: 'missing' },
    stopped: { kind: 'desktop-stopped' },
    ready: { kind: 'ready', engine: 'docker-desktop', tested: true, containers_running: 3 },
    'ready-orbstack': { kind: 'ready', engine: 'orb-stack', tested: false, containers_running: 1 },
    old: { kind: 'too-old', api: '1.43', need: '1.45' },
    memory: { kind: 'low-memory', free_mb: 2048, need_mb: 2500 },
    other: { kind: 'other-stopped', engine: 'orb-stack' },
    colima: { kind: 'unsupported', engine: 'colima' },
    remote: { kind: 'remote-context', endpoint: 'ssh://beispiel@nas.example' },
    foreign: { kind: 'ready', engine: 'docker-desktop', tested: true, containers_running: 2 },
  };
  let dockerUp = !['missing', 'stopped'].includes(fall);
  const verdict = () => (dockerUp ? verdicts[fall] || verdicts.ready : verdicts[fall] || verdicts.missing);

  const changes = () => {
    const v = verdict();
    const c = [];
    const k = [];
    if (v.kind === 'missing') c.push({ kind: 'install-docker', size_mb: os === 'mac' ? 573 : 624 }, { kind: 'start-docker', engine: 'docker-desktop' });
    else if (v.kind === 'desktop-stopped') c.push({ kind: 'start-docker', engine: 'docker-desktop' }), k.push({ kind: 'docker-itself' });
    else if (v.kind === 'ready') k.push({ kind: 'docker-itself' }, { kind: 'running-programs', names: ['paperless'] });
    else return null;
    c.push({ kind: 'wizard-containers', port: 5881 }, { kind: 'journal' });
    k.push({ kind: 'power' }, { kind: 'files-and-encryption' });
    return { changes: c, keeps: k };
  };

  let polls = 0;
  const api = {
    startup: () => ({
      os,
      location: fall === 'dmg' ? 'from-disk-image' : 'installed',
      journal: { kind: fall === 'interrupted' ? 'interrupted' : fall === 'complete' ? 'complete' : 'fresh', step: { step: 'core-started' } },
      version: '0.1.0',
      compose_ready: fall === 'wizard',
      download: ['missing', 'wizard'].includes(fall) ? (os === 'mac' ? 'lifeagents.dmg' : 'lifeagents-setup.exe') : null,
      lang: q.get('lang') || 'de',
    }),
    trash_download: async () => wait(300),
    // Notfallblatt (?kit=1 = schon abgehakt, ?kitfail=kit-write|kit-unavailable = Speichern scheitert); erfundener Dateiname.
    kit_status: async () => ({ setup: true, confirmed: q.get('kit') === '1' }),
    save_backup_kit: async () => {
      await wait(400);
      if (q.get('kitfail')) throw q.get('kitfail');
      return { file: ((q.get('lang') || 'de') === 'de' ? 'Life-Agents-Notfallblatt' : 'Life-Agents-Emergency-Sheet') + '-2026-11-12.txt' };
    },
    confirm_kit: async () => wait(100),
    change_backup_folder: async () => (await wait(600), q.get('kitfail') !== 'kit-unavailable'),
    // Wiederherstellen (?restore=<fall>): own | foreign (Standard) | empty | nofolder | folder | keyline | keyformat |
    //   keyforeign | expired | older | newer | needs_setup | corrupt | busy | install | data | fail | unfinished | running |
    //   card (Karte auf Fertig/Start). Namen, Datum und IDs erfunden.
    ...(() => {
      const rf = q.get('restore') || 'foreign';
      const B = (d, kid, own, rel) => ({ name: `lifeagents-backup-${d}033000-${kid}-${rel}.nla.enc`, date: `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}T03:30:00Z`, release: rel, key_id: kid, own });
      const listing = () => {
        if (rf === 'nofolder') return { ok: false, code: 'nofolder' };
        if (rf === 'folder') return { ok: false, code: 'folder' };
        if (rf === 'empty') return { ok: true, folder: '/Users/erika/Library/Mobile Documents/com~apple~CloudDocs/Life Agents Sicherungen', backups: [] };
        const own = [B('20261113', 'k1a2b3c4d', true, 'v0.44.0')];
        const other = rf === 'own' || rf === 'data' ? [] : [B('20261110', 'k9f8e7d6c', false, 'v0.44.0'), B('20261109', 'k9f8e7d6c', false, 'v0.43.1')];
        return { ok: true, folder: '/Users/erika/…/Life Agents Sicherungen', backups: other.concat(own) };
      };
      let sheetGiven = rf === 'own' || rf === 'data';
      const plan = () => {
        const fails = { older: { code: 'version_older', release: 'v0.41.0' }, newer: { code: 'version_newer', release: 'v0.45.0' }, needs_setup: { code: 'needs_setup', pkg: 'paperless' }, corrupt: { code: 'corrupt' }, busy: { code: 'busy' } };
        if (fails[rf]) return Object.assign({ ok: false }, fails[rf]);
        if (!sheetGiven) return { ok: false, code: 'key_needed', id: 'k9f8e7d6c' };
        if (rf === 'keyline' && sheetGiven === 'typed') { sheetGiven = false; return { ok: false, code: 'key_line', line: 3 }; }
        if (rf === 'keyformat') { sheetGiven = false; return { ok: false, code: 'key_format' }; }
        if (rf === 'keyforeign') { sheetGiven = false; return { ok: false, code: 'key_foreign', id: 'k9f8e7d6c' }; }
        if (rf === 'expired') { sheetGiven = false; return { ok: false, code: 'key_expired' }; }
        const pk = [{ name: 'core', version: '0.44.0', state: 'ok' }, { name: 'finance', version: '1.20.0', state: 'ok' }];
        if (rf === 'install') pk.push({ name: 'estate', version: '0.9.0', state: 'install' });
        return { ok: true, created: '2026-11-10T03:30:00Z', release: 'v0.44.0', packages: pk, has_data: rf === 'data', adopt_key_id: rf === 'own' || rf === 'data' ? null : 'k9f8e7d6c' };
      };
      let started = 0;
      return {
        restore_list: async () => (await wait(300), { listing: listing(), card: rf === 'card' || rf === 'foreign' }),
        restore_dismiss_card: async () => wait(100),
        restore_select: async () => wait(50),
        restore_forget: async () => {},
        restore_pick_file: async () => (await wait(300), 'lifeagents-backup-20261101033000-k9f8e7d6c-v0.44.0.nla.enc'),
        restore_pick_sheet: async () => { await wait(300); sheetGiven = 'file'; return true; },
        restore_type_sheet: async () => { await wait(100); sheetGiven = 'typed'; },
        restore_plan: async () => (await wait(500), plan()),
        restore_run: async () => { await wait(400); started = 1794571200; return { ok: true }; },
        restore_status: async () => {
          if (rf === 'running') return { status: { state: 'running', started: 1 }, seen: false };
          if (rf === 'unfinished' || rf === 'fail') return { status: { state: rf === 'fail' ? 'fail' : 'unfinished', code: rf === 'fail' ? 'safety' : null, started: 1 }, seen: false };
          if (!started) return { status: { state: 'idle', started: 0 }, seen: true };
          await wait(200);
          return { status: { state: 'ok', created: '2026-11-10T03:30:00Z', foreign: rf !== 'own' && rf !== 'data', started }, seen: false };
        },
        restore_seen: async () => { started = 0; },
      };
    })(),
    check_system: async () => (await wait(500), sys),
    check_docker: async () => {
      await wait(500);
      return {
        finding: { installed: [], docker: null, endpoint: null, running: null, verdict: verdict() },
        programs: verdict().kind === 'ready' ? ['paperless'] : [],
        own: fall === 'foreign' ? { kind: 'foreign', names: ['lifeagents-db'] } : { kind: 'none' },
        port: 5881,
        changes: changes(),
      };
    },
    fetch_docker: async () => {
      const total = os === 'mac' ? 573 : 624;
      for (let mb = 0; mb <= total; mb += 97) {
        emit('fetch-progress', { stage: 'download', done_mb: mb, total_mb: total });
        await wait(250);
        if (q.get('hold') && mb >= 291) await new Promise(() => {});
      }
      if (q.get('fail')) throw q.get('fail');
      for (const stage of ['verify', 'password', 'start']) {
        emit('fetch-progress', { stage, done_mb: total, total_mb: total });
        await wait(700);
      }
      dockerUp = true;
    },
    start_docker: async () => { await wait(300); dockerUp = true; },
    wait_docker: async () => {
      await wait(800);
      if (q.get('waitfail')) throw q.get('waitfail');
      return { verdict: verdict() };
    },
    start_core: async () => {
      await wait(700);
      if (q.get('hold')) await new Promise(() => {});
      if (q.get('corefail')) throw q.get('corefail');
      if (fall !== 'wizard') throw 'compose-missing';
      return 5881;
    },
    open_wizard: async () => fall === 'wizard',
    wizard_status: async () => ({ phase: ++polls > 2 ? 'power' : 'running', bot: 'erika_helfer_bot' }),
    power_info: () => ({ os, laptop: sys.laptop, filevault: 'on', changed: false }),
    power_apply: async () => {
      await wait(900);
      const holds = os === 'mac' ? { sleep: true, displaysleep: true, autorestart: true, womp: true } : { 'active-scheme': true, standbyidle: true, videoidle: true };
      return { backup: {}, holds, unsupported: [] };
    },
    power_answer: () => null,
    power_restore: async () => wait(500),
    finish_setup: async () => (await wait(600), { autostart: true, deviations: [] }),
    rollback: async () => wait(800),
    uninstall_plan: () => ({ data_volumes: ['lifeagents_pgdata', 'lifeagents_n8n'], power: { os: 'mac', ac: {} }, autostart: { kind: 'mac-launch-agent', path: '' }, docker_installed_by_us: fall === 'missing' }),
    uninstall_run: async () => (await wait(900), { failed: [], deviations: [] }),
    error_report: () =>
      'lifeagents Fehlerbericht\napp: 0.1.0\nsystem: ' + os + ' 15.1 arm64\narbeitsspeicher: 16 GB, freier platz: 240 GB\npruefungen: os-version=ok, ram=ok, disk=ok\ndocker: ready docker-desktop 27.3.1 (API 1.47)\njournal: inventory:done, core-started:done\nfilevault: on\nletzter fehler: keiner\n',
    open_link: () => null,
  };

  window.__TAURI__ = {
    core: {
      invoke: async (cmd, args) => {
        if (!api[cmd]) throw 'unbekannter Befehl ' + cmd;
        return api[cmd](args);
      },
    },
    event: {
      listen: async (ev, fn) => {
        (handlers[ev] = handlers[ev] || []).push(fn);
        return () => (handlers[ev] = handlers[ev].filter((f) => f !== fn));
      },
    },
  };

  const screen = q.get('screen');
  if (screen) {
    window.addEventListener('load', () =>
      setTimeout(() => {
        window.__lifeagents.SCREENS[screen]();
        // Knopf drücken, sobald er da ist (Bildschirme mit Warten davor erscheinen später)
        const id = q.get('click');
        let tries = 0;
        const press = () => {
          const b = document.getElementById(id);
          if (b && !b.hidden) return b.click();
          if (++tries < 30) setTimeout(press, 100);
        };
        if (id) setTimeout(press, 400);
      }, 50)
    );
  }
})();
