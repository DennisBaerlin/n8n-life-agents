// Vorschau der Start-App im Browser ohne Tauri und ohne Docker: ersetzt window.__TAURI__ durch feste, erfundene
// Antworten. Wird nur von scripts/dev/serve_desktop_preview.ps1 vor app.js eingefügt, nie in die App gebaut.
//   ?state=<fall>   missing (Standard), stopped, ready, ready-orbstack, old, memory, other, colima, remote, foreign,
//                   blocked, hints, interrupted, dmg, complete, wizard, laptop
//   ?os=win         Windows statt Mac       ?screen=<name>  direkt zu einem Bildschirm (z. B. power, report, uninstall)
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
      download: fall === 'missing' ? (os === 'mac' ? 'lifeagents.dmg' : 'lifeagents-setup.exe') : null,
    }),
    trash_download: async () => wait(300),
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
      }
      for (const stage of ['verify', 'password', 'start']) {
        emit('fetch-progress', { stage, done_mb: total, total_mb: total });
        await wait(700);
      }
      dockerUp = true;
    },
    start_docker: async () => { await wait(300); dockerUp = true; },
    wait_docker: async () => (await wait(800), { verdict: verdict() }),
    start_core: async () => {
      await wait(700);
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
    window.addEventListener('load', () => setTimeout(() => window.__lifeagents.SCREENS[screen](), 50));
  }
})();
