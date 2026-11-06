import { expect, mock, test } from 'claude-code/testing'

const PANE = {
  plugin: 'status-panel',
  component: 'Pane',
  requestId: 'status-panel',
  props: {
    title: 'Status',
    isFocused: false,
    bodyColumns: 40,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

// Die Testuhr startet am 02.11. um 10:00 UTC. Form wie im echten Lauf belegt.
const RATE_LIMITS = [
  { kind: 'five_hour', percentUsed: 41, resetsAt: '2026-11-02T12:59:00.000Z' },
  { kind: 'seven_day', percentUsed: 6, resetsAt: '2026-11-09T07:00:00.000Z' },
  { kind: 'spend_limit', percentUsed: 77 },
]

const CI_GREEN = 'ci           success   07f889c 02.11. 10:17  chore(dev): Beispiel\r\n'
const CI_RED = `${CI_GREEN}pages        failure   07f889c 02.11. 10:17  chore(dev): Beispiel\r\n`
const DOCKER = 'lifeagents-dbtest-w1|127.0.0.1:5600->5432/tcp|Up 1 minute\nlifeagents-dbtest-zz|127.0.0.1:5999->5432/tcp|Up 3 minutes\n'
const FUTURE = '2099-01-01T00:00:00.0000000Z\r\n# Kommentar'

const HOST_ID = 'local_00000000-0000-4000-8000-000000000001'
const HOME_FILE = 'C:/repo/.claude/status_panel_home.txt'
const CWD = 'C:/repo/.claude/worktrees/w1'
const MINUTE = 60_000

type Setup = {
  rateLimits?: unknown[]
  usageError?: string
  // Anfrage ohne Antwort: abgebrochen oder fehlgeschlagen, stopReason bleibt null.
  noResponse?: boolean
  ciOut?: string
  dockerExit?: number
  ownerGrantIn?: string
  grantBody?: string
  gitExit?: number
  // null = Datei fehlt; ohne Angabe ist diese Session eingetragen.
  home?: string | null
}

type Counts = { usage: number; mcp: number; docker: number; ci: number; open: number; close: number }

function engine($: any, on: any, setup: Setup = {}) {
  const counts: Counts = { usage: 0, mcp: 0, docker: 0, ci: 0, open: 0, close: 0 }
  on('command.register', () => ({ value: { command: 'status-panel' } }))
  on('ui.open', () => {
    counts.open += 1
    return { value: { isPlaced: true } }
  })
  on('ui.close', () => {
    counts.close += 1
    return { value: undefined }
  })
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: {} }))
  const clock = mock.clock(on, { now: Date.parse('2026-11-02T10:00:00Z') })
  mock.env(on, { CLAUDE_CODE_HOST_SESSION_ID: HOST_ID })
  on('session.usage', () => {
    counts.usage += 1
    if (setup.usageError) throw new Error(setup.usageError)
    return { value: { startedAt: 0, context: {}, rateLimits: setup.rateLimits ?? RATE_LIMITS } }
  })
  on('mcp.call', () => {
    counts.mcp += 1
    return { value: { isError: true, content: [] } }
  })
  on('turn.step', async function* (_: unknown, e: { turnId: string; index: number }) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: setup.noResponse ? null : 'end_turn', usage: null }
  })
  on('process.run', (_: unknown, e: { argv: string[] }) => {
    const tool = e.argv[0]
    if (tool === 'git') {
      return setup.gitExit
        ? { value: { exitCode: setup.gitExit, stdout: '', stderr: 'fatal: not a git repository' } }
        : { value: { exitCode: 0, stdout: 'C:/repo/.git\n', stderr: '' } }
    }
    if (tool === 'docker') {
      counts.docker += 1
      return setup.dockerExit
        ? { value: { exitCode: setup.dockerExit, stdout: '', stderr: 'docker daemon is not running' } }
        : { value: { exitCode: 0, stdout: DOCKER, stderr: '' } }
    }
    counts.ci += 1
    return { value: { exitCode: 0, stdout: setup.ciOut ?? CI_GREEN, stderr: '' } }
  })
  on('fs.exists', (_: unknown, e: { path: string }) => {
    const path = e.path.replace(/\\/g, '/')
    return { value: path === setup.ownerGrantIn || (path === HOME_FILE && setup.home !== null) }
  })
  on('fs.read', (_: unknown, e: { path: string }) => ({
    value: e.path.replace(/\\/g, '/') === HOME_FILE ? `${setup.home ?? HOST_ID}\r\n# Kommentar` : setup.grantBody ?? FUTURE,
  }))
  void $

  return { clock, counts }
}

// Eine Modellanfrage läuft durch die Hooks, wie in einer Session.
async function modelResponse($: any) {
  for await (const _ of $.turn.step({ turnId: 't1', index: 0, model: 'test-model', messageCount: 1 })) void _
}

async function draw($: any, surface: 'desktop' | 'terminal') {
  await $.session.start({ cwd: CWD, surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'PowerShell', command: "$env:DBTEST_CONTAINER='lifeagents-dbtest-w1'; docker ps" })
  await modelResponse($)
  const ui = await $.ui.mount({ ...PANE, surface })
  await ui.press({ key: 'refresh' })

  return ui
}

for (const surface of ['desktop', 'terminal'] as const) {
  test(`alle vier Quellen erscheinen (${surface})`, async ($, on) => {
    engine($, on)
    const ui = await draw($, surface)

    expect((await ui.find({ type: 'Text', text: /^5 Stunden$/ }))?.text).toBe('5 Stunden')
    expect((await ui.find({ type: 'Text', text: /^Woche$/ }))?.text).toBe('Woche')
    expect((await ui.find({ type: 'Text', text: /^41 %$/ }))?.text).toBe('41 %')
    expect((await ui.find({ type: 'Text', text: /^6 %$/ }))?.text).toBe('6 %')
    expect((await ui.find({ type: 'Text', text: /Reset in 2h 59m/ }))).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /Reset in 6d 21h/ }))).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /gerade eben/ }))).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^77 %$/ })).toBeUndefined()
    expect((await ui.find({ type: 'Text', text: /lifeagents-dbtest-w1/ }))?.text).toBe('lifeagents-dbtest-w1')
    expect((await ui.find({ type: 'Text', text: /^5600$/ }))?.text).toBe('5600')
    expect((await ui.find({ type: 'Text', text: /Andere Sessions: dbtest-zz \(5999\)/ }))).toBeDefined()
    expect((await ui.find({ type: 'Text', text: /grün \(ci\)/ }))).toBeDefined()
    await ui.unmount()
  })
}

for (const [name, home] of [['Datei fehlt', null], ['andere Session eingetragen', 'local_ffffffff-0000-4000-8000-000000000002']] as const) {
  test(`außerhalb der Leit-Session bleibt das Panel still: ${name}`, async ($, on) => {
    const { clock, counts } = engine($, on, { home })
    await $.session.start({ cwd: CWD, surface: 'desktop', isInteractive: true })
    await $.tool.call({ tool: 'PowerShell', command: "$env:DBTEST_CONTAINER='lifeagents-dbtest-w1'; docker ps" })
    await modelResponse($)
    await clock.advance(900_000)

    expect(counts).toEqual({ usage: 0, mcp: 0, docker: 0, ci: 0, open: 0, close: 1 })
    const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
    expect((await ui.find({ type: 'Text', text: /nur in der Leit-Session/ }))).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Kontingent/ })).toBeUndefined()
    await ui.unmount()
  })
}

test('/status-panel außerhalb der Leit-Session: Hinweis, keine Abfrage', async ($, on) => {
  const { clock, counts } = engine($, on, { home: null })
  await $.session.start({ cwd: CWD, surface: 'desktop', isInteractive: true })
  const reply = await $.command.run({ command: 'status-panel' })
  await clock.advance(900_000)

  expect(reply.text).toMatch(/nur in der Leit-Session/)
  expect(counts).toEqual({ usage: 0, mcp: 0, docker: 0, ci: 0, open: 0, close: 1 })
})

test('/status-panel in der Leit-Session öffnet und liest', async ($, on) => {
  const { clock, counts } = engine($, on)
  await $.session.start({ cwd: CWD, surface: 'desktop', isInteractive: true })
  await clock.advance(10)
  const reply = await $.command.run({ command: 'status-panel' })
  await clock.settle()

  expect(reply.text).toBe('Status-Panel geöffnet.')
  expect(counts.open).toBe(2)
  expect(counts.usage).toBe(2)
})

test('Leit-Session liest im Takt und ruft kein MCP-Tool mehr auf, also keine Freigabe-Frage', async ($, on) => {
  const { clock, counts } = engine($, on)
  await $.session.start({ cwd: CWD, surface: 'desktop', isInteractive: true })
  await clock.advance(10)
  expect(counts.usage).toBe(1)
  expect(counts.open).toBe(1)
  await clock.advance(30_000)
  expect(counts.usage).toBe(2)
  expect(counts.mcp).toBe(0)
})

test('vor der ersten Modellantwort: unbekannt, auch wenn die Engine schon Werte hätte', async ($, on) => {
  const { clock } = engine($, on)
  await $.session.start({ cwd: CWD, surface: 'desktop', isInteractive: true })
  await clock.advance(10)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  expect((await ui.find({ type: 'Text', text: /^unbekannt$/ }))).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^\d+ %$/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /Noch keine Modellantwort/ }))).toBeDefined()
  await ui.unmount()
})

test('Anfrage ohne Antwort zählt nicht als aktueller Stand', async ($, on) => {
  const { clock } = engine($, on, { noResponse: true })
  await $.session.start({ cwd: CWD, surface: 'desktop', isInteractive: true })
  await clock.advance(10)
  await modelResponse($)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  expect(await ui.find({ type: 'Text', text: /^\d+ %$/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /Noch keine Modellantwort/ }))).toBeDefined()
  await ui.unmount()
})

test('alte Zahlen verschwinden nach 10 Minuten, die nächste Antwort bringt sie zurück', async ($, on) => {
  const { clock } = engine($, on)
  const ui = await draw($, 'desktop')
  expect((await ui.find({ type: 'Text', text: /^41 %$/ }))).toBeDefined()

  await clock.advance(9 * MINUTE)
  expect((await ui.find({ type: 'Text', text: /^41 %$/ }))).toBeDefined()
  expect((await ui.find({ type: 'Text', text: /vor 9 Min/ }))).toBeDefined()

  await clock.advance(MINUTE)
  expect(await ui.find({ type: 'Text', text: /^\d+ %$/ })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: /Reset in/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /^unbekannt$/ }))).toBeDefined()
  expect((await ui.find({ type: 'Text', text: /vor 10 Min, zu alt/ }))).toBeDefined()

  await modelResponse($)
  expect((await ui.find({ type: 'Text', text: /^41 %$/ }))).toBeDefined()
  await ui.unmount()
})

test('Fenster nach seinem Reset: dieses unbekannt, das andere bleibt', async ($, on) => {
  const { clock } = engine($, on)
  const ui = await draw($, 'desktop')
  await clock.advance(180 * MINUTE)
  await modelResponse($)

  expect(await ui.find({ type: 'Text', text: /^41 %$/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /^unbekannt$/ }))).toBeDefined()
  expect((await ui.find({ type: 'Text', text: /^6 %$/ }))).toBeDefined()
  await ui.unmount()
})

test('leere Liste nach einer Antwort: unbekannt, keine Balken', async ($, on) => {
  engine($, on, { rateLimits: [] })
  const ui = await draw($, 'desktop')

  expect((await ui.find({ type: 'Text', text: /^unbekannt$/ }))).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^\d+ %$/ })).toBeUndefined()
  await ui.unmount()
})

for (const surface of ['desktop', 'terminal'] as const) {
  test(`Wert über 100 % ohne Reset-Zeit wird gezeichnet (${surface})`, async ($, on) => {
    engine($, on, { rateLimits: [{ kind: 'five_hour', percentUsed: 104 }] })
    const ui = await draw($, surface)

    expect((await ui.find({ type: 'Text', text: /^104 %$/ }))).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Reset in/ })).toBeUndefined()
    await ui.unmount()
  })
}

// Das Testgerüst fängt den Wurf selbst ab, der Wortlaut erreicht das Panel hier nicht; geprüft wird die Meldung statt Zahlen.
test('Lesefehler: Meldung, keine Zahlen', async ($, on) => {
  engine($, on, { usageError: 'boom' })
  const ui = await draw($, 'desktop')

  expect((await ui.find({ type: 'Text', text: /^Nicht lesbar: / }))).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^\d+ %$/ })).toBeUndefined()
  await ui.unmount()
})

test('rote CI und Docker-Fehler', async ($, on) => {
  engine($, on, { ciOut: CI_RED, dockerExit: 1 })
  const ui = await draw($, 'desktop')

  expect((await ui.find({ type: 'Text', text: /rot: pages \(failure, 07f889c\)/ }))).toBeDefined()
  expect((await ui.find({ type: 'Text', text: /Nicht lesbar: docker daemon/ }))).toBeDefined()
  await ui.unmount()
})

test('CI-Skript ohne Daten: Meldung statt grün', async ($, on) => {
  engine($, on, { ciOut: 'CI-Status nicht abrufbar: kein Token\r\n' })
  const ui = await draw($, 'desktop')

  expect((await ui.find({ type: 'Text', text: /Nicht lesbar: CI-Status nicht abrufbar/ }))).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /grün/ })).toBeUndefined()
  await ui.unmount()
})

for (const file of ['owner_grant.txt', 'app_grant.txt']) {
  test(`${file} im Haupt-Checkout gilt auch im Worktree`, async ($, on) => {
    engine($, on, { ownerGrantIn: `C:/repo/.claude/${file}` })
    const ui = await draw($, 'desktop')

    expect((await ui.find({ type: 'Text', text: /offen, noch \d+ Min/ }))).toBeDefined()
    await ui.unmount()
  })

  // Die App kopiert gitignorte Dateien in neue Worktrees mit; das sind Altstände, die der Hook nicht zählt.
  test(`${file} nur im Worktree zählt nicht`, async ($, on) => {
    engine($, on, { ownerGrantIn: `${CWD}/.claude/${file}` })
    const ui = await draw($, 'desktop')

    expect(await ui.find({ type: 'Text', text: /offen/ })).toBeUndefined()
    expect((await ui.find({ type: 'Text', text: /^zu$/ }))).toBeDefined()
    await ui.unmount()
  })

  test(`${file} abgelaufen: zu`, async ($, on) => {
    engine($, on, { ownerGrantIn: `C:/repo/.claude/${file}`, grantBody: '2020-01-01T00:00:00.0000000Z\r\n' })
    const ui = await draw($, 'desktop')

    expect(await ui.find({ type: 'Text', text: /offen/ })).toBeUndefined()
    expect((await ui.find({ type: 'Text', text: /^zu$/ }))).toBeDefined()
    await ui.unmount()
  })

  // Der Hook sagt hier nur „zu“; das Panel nennt den Grund, offen heißt es in keinem Fall.
  test(`${file} mit unlesbarer Zeile 1: nicht lesbar, nie offen`, async ($, on) => {
    engine($, on, { ownerGrantIn: `C:/repo/.claude/${file}`, grantBody: 'kein Zeitpunkt\r\n' })
    const ui = await draw($, 'desktop')

    expect(await ui.find({ type: 'Text', text: /offen/ })).toBeUndefined()
    expect((await ui.find({ type: 'Text', text: /nicht lesbar: .*kein Zeitpunkt/ }))).toBeDefined()
    await ui.unmount()
  })
}

test('git scheitert: Fenster nie offen, auch mit gültiger Datei im Ordner (wie der Hook)', async ($, on) => {
  engine($, on, { gitExit: 128, ownerGrantIn: 'C:/repo/.claude/owner_grant.txt' })
  await $.session.start({ cwd: 'C:/repo', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'refresh' })

  expect(await ui.find({ type: 'Text', text: /offen/ })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /kein Git-Repo, gilt als zu/ }))).toBeDefined()
  await ui.unmount()
})
