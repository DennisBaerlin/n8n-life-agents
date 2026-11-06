// Status-Panel neben dem Chat: Kontingent, Test-Container, Owner-/App-Fenster, CI-Ampel.
// Nur lesend. Lässt sich eine Quelle nicht lesen, steht das im Panel; es gibt keine Ersatzquelle und keine Schätzwerte.
// Läuft nur in der eingetragenen Leit-Session (scripts/set_status_panel_home.ps1, Owner-Entscheidung); in jeder anderen
// Session bleibt es ganz still, dort startet es weder Docker noch die CI-Abfrage.
// Das Kontingent kommt aus $.session.usage(): kostenlos und ohne Freigabe-Frage, aber nur so aktuell wie die letzte Modellantwort.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionRateLimit } from 'claude-code'

import type { Ci, CiRun, Container, Containers, Grant, Grants, Quota, QuotaWindow } from '../types'

const PANE = 'status-panel'
const TITLE = 'Status'

// Kontingent und Lokales alle 30 s (Alter und Reset sollen weiterlaufen), CI alle 5 Min (GitHub-API, startet PowerShell).
const QUOTA_MS = 30_000
const LOCAL_MS = 30_000
const CI_MS = 300_000
// Die Werte tragen keine eigene Uhrzeit, und andere Sessions verbrauchen dasselbe Kontingent. Ab diesem Alter der
// letzten Modellantwort zeigt das Panel deshalb „unbekannt“ statt der alten Zahl.
const FRESH_MINUTES = 10

const WINDOWS = [
  { kind: 'five_hour', label: '5 Stunden' },
  { kind: 'seven_day', label: 'Woche' },
]

const quota = atom({ plugin: 'status-panel', key: 'quota' } as const, null, { shape: 'quota-3' })
const containers = atom({ plugin: 'status-panel', key: 'containers' } as const, null, { shape: 'containers-1' })
const own = atom({ plugin: 'status-panel', key: 'own' } as const, [], { shape: 'own-1' })
const grants = atom({ plugin: 'status-panel', key: 'grants' } as const, null, { shape: 'grants-2' })
const ci = atom({ plugin: 'status-panel', key: 'ci' } as const, null, { shape: 'ci-1' })

const message = (err: unknown) => (err instanceof Error ? err.message : String(err))

// Zeile 1 der gitignorierten Datei im Haupt-Checkout = Host-Session-ID der Leit-Session; übersteht Neustart und Umbenennen.
async function isHomeSession($: EngineInterface, checkout: string): Promise<boolean> {
  try {
    const id = await $.env.get('CLAUDE_CODE_HOST_SESSION_ID')
    const file = `${checkout}/.claude/status_panel_home.txt`
    if (!id || !(await $.fs.exists(file))) return false

    return (await $.fs.read(file)).split(/\r?\n/)[0]?.trim() === id
  } catch {
    return false
  }
}

function resetsInLabel(minutes: number): string {
  const days = Math.floor(minutes / 1440)
  const hours = Math.floor((minutes % 1440) / 60)
  if (days > 0) return `${days}d ${hours}h`

  return hours > 0 ? `${hours}h ${minutes % 60}m` : `${minutes % 60}m`
}

// Ein Fenster nach seinem Reset hat keinen gültigen Wert mehr, egal wie jung die letzte Antwort ist.
function toWindow(label: string, reading: SessionRateLimit | undefined, now: number): QuotaWindow {
  if (!reading) return { label }
  const resetsAt = Date.parse(reading.resetsAt ?? '')
  if (Number.isNaN(resetsAt)) return { label, percentUsed: reading.percentUsed }
  if (resetsAt <= now) return { label }

  return { label, percentUsed: reading.percentUsed, resetsAt, resetsIn: resetsInLabel(Math.round((resetsAt - now) / 60_000)) }
}

async function readQuota($: EngineInterface, lastResponse: number | undefined): Promise<Quota> {
  try {
    const { rateLimits } = await $.session.usage()
    const now = await $.clock.now()
    const ageMinutes = lastResponse === undefined ? undefined : Math.floor((now - lastResponse) / 60_000)
    const isFresh = ageMinutes !== undefined && ageMinutes < FRESH_MINUTES
    const windows = WINDOWS.map(({ kind, label }) => toWindow(label, isFresh ? rateLimits.find(limit => limit.kind === kind) : undefined, now))

    return { windows, ageMinutes }
  } catch (err) {
    return { windows: [], error: message(err) }
  }
}

async function readContainers($: EngineInterface): Promise<Containers> {
  try {
    const run = await $.process.run([
      'docker', 'ps', '--filter', 'name=lifeagents-', '--format', '{{.Names}}|{{.Ports}}|{{.Status}}',
    ])
    if (run.exitCode !== 0) return { rows: [], error: run.stderr.trim() || `docker ps: Exit ${run.exitCode}` }
    const rows = run.stdout.split(/\r?\n/).filter(Boolean).map((line): Container => {
      const [name = '', ports = '', status = ''] = line.split('|')
      const published = [...ports.matchAll(/:(\d+)->/g)].map(hit => hit[1] ?? '')

      return { name, ports: [...new Set(published)], status }
    })

    return { rows: rows.sort((a, b) => a.name.localeCompare(b.name)) }
  } catch (err) {
    return { rows: [], error: message(err) }
  }
}

// Zeile 1 der Grant-Datei = UTC-Ablauf. Eine abgelaufene Datei räumt erst der Hook weg, sie zählt hier als zu.
async function minutesLeft($: EngineInterface, file: string): Promise<number | undefined> {
  if (!(await $.fs.exists(file))) return undefined
  const until = Date.parse((await $.fs.read(file)).split(/\r?\n/)[0]?.trim() ?? '')
  if (Number.isNaN(until)) throw new Error(`${file}: Zeile 1 ist kein Zeitpunkt`)
  const left = (until - (await $.clock.now())) / 60_000

  return left > 0 ? Math.ceil(left) : undefined
}

// Dieselbe Suche wie Test-GrantWindow in .claude/hooks/lib/grant_window.ps1: nur die Datei im Haupt-Checkout zählt, eine Kopie
// im Worktree ist ein Altstand, und ohne Git-Repo gilt das Fenster als zu. Ändert sich die Suche dort, muss sie hier mit.
async function readGrant($: EngineInterface, name: string, root: string): Promise<Grant> {
  if (!root) return { error: 'kein Git-Repo, gilt als zu' }
  try {
    return { minutes: await minutesLeft($, `${root}/.claude/${name}`) }
  } catch (err) {
    return { error: message(err) }
  }
}

async function readGrants($: EngineInterface, root: string): Promise<Grants> {
  return {
    owner: await readGrant($, 'owner_grant.txt', root),
    app: await readGrant($, 'app_grant.txt', root),
  }
}

async function readCi($: EngineInterface, here: string): Promise<Ci> {
  try {
    const run = await $.process.run(
      ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', `${here}/scripts/check_ci_status.ps1`],
      { timeoutMs: 30_000 },
    )
    const lines = run.stdout.split(/\r?\n/).filter(Boolean)
    const rows = lines.flatMap((line): CiRun[] => {
      const hit = /^(\S+)\s+(\S+)\s+([0-9a-f]{7}) (\d\d\.\d\d\. \d\d:\d\d) {2}(.*)$/.exec(line)

      return hit ? [{ workflow: hit[1] ?? '', conclusion: hit[2] ?? '', sha: hit[3] ?? '', when: hit[4] ?? '', title: hit[5] ?? '' }] : []
    })
    if (rows.length === 0) return { rows, error: lines.join(' ') || run.stderr.trim() || 'Skript ohne Ausgabe' }

    return { rows }
  } catch (err) {
    return { rows: [], error: message(err) }
  }
}

const isGreen = (run: CiRun) => ['success', 'skipped', 'neutral'].includes(run.conclusion)

const percentLabel = (value: number) => `${Math.round(value)} %`

function resetLabel(resetsAt: number, resetsIn: string): string {
  // Auf die Minute runden: der Anbieter meldet 12:29:59 oder 12:30:00, die Anzeige soll nicht springen.
  const at = new Date(Math.round(resetsAt / 60_000) * 60_000)
  const days = ['So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa']
  const clock = `${String(at.getHours()).padStart(2, '0')}:${String(at.getMinutes()).padStart(2, '0')}`

  return `Reset in ${resetsIn} · ${days[at.getDay()]} ${clock}`
}

function readingLine(ageMinutes: number | undefined): string {
  if (ageMinutes === undefined) return 'Noch keine Modellantwort seit dem Start.'
  if (ageMinutes >= FRESH_MINUTES) return `Letzte Modellantwort vor ${ageMinutes} Min, zu alt für eine Aussage.`

  return ageMinutes === 0 ? 'Stand: letzte Modellantwort, gerade eben.' : `Stand: letzte Modellantwort vor ${ageMinutes} Min.`
}

function barSource(percent: number, width: number): string {
  const filled = Math.round((Math.min(100, Math.max(0, percent)) / 100) * width)

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="6" viewBox="0 0 ${width} 6">`
    + `<rect width="${width}" height="6" rx="3" fill="#8e8e8e" fill-opacity="0.28"/>`
    + `<rect width="${filled}" height="6" rx="3" fill="#3b82f6"/></svg>`
}

function grantLine(grant: Grant): { text: string; color?: string; isDim: boolean } {
  if (grant.error) return { text: `nicht lesbar: ${grant.error}`, color: 'error', isDim: false }
  if (grant.minutes !== undefined) return { text: `offen, noch ${grant.minutes} Min`, color: 'success', isDim: false }

  return { text: 'zu', isDim: true }
}

let here = ''
let main = ''
// Bleibt leer, wenn git scheitert: main fällt dann für den Eintrag der Leit-Session auf here zurück, für die Fenster nie.
let grantRoot = ''
let active = false
// Bleibt bewusst nur im Speicher: nach Neuladen oder Neustart ist die Herkunft der Werte unbelegt, also „unbekannt“.
let lastResponse: number | undefined

async function refreshQuota($: EngineInterface) {
  const value = await readQuota($, lastResponse)
  await update($, quota, () => value)
}

async function refreshLocal($: EngineInterface) {
  const rows = await readContainers($)
  await update($, containers, () => rows)
  if (!here) return
  const value = await readGrants($, grantRoot)
  await update($, grants, () => value)
}

async function refreshCi($: EngineInterface) {
  if (!here) return
  const value = await readCi($, here)
  await update($, ci, () => value)
}

async function refreshAll($: EngineInterface) {
  await Promise.all([refreshQuota($), refreshLocal($), refreshCi($)])
}

function activate($: EngineInterface) {
  if (active) return
  active = true
  $.clock.after(10, () => void refreshAll($))
  $.clock.every(QUOTA_MS, () => void refreshQuota($))
  $.clock.every(LOCAL_MS, () => void refreshLocal($))
  $.clock.every(CI_MS, () => void refreshCi($))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    here = e.cwd.replace(/\\/g, '/')
    main = here
    grantRoot = ''
    const common = await $.process.run(['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], { cwd: e.cwd })
    if (common.exitCode === 0) {
      main = common.stdout.trim().replace(/\\/g, '/').replace(/\/\.git$/, '')
      grantRoot = main
    }

    await $.command.register({ name: 'status-panel', description: 'Status-Panel neben dem Chat öffnen (nur Leit-Session)' })
    if (await isHomeSession($, main)) {
      void $.ui.open({ id: PANE, title: TITLE })
      activate($)
    } else {
      // Ein Neuladen trifft auch Sessions, die das Panel aus der Zeit vor dieser Regel noch offen haben.
      void $.ui.close({ id: PANE })
    }

    return next(e)
  })

  on('command.run', { command: 'status-panel' }, async $ => {
    if (!(await isHomeSession($, main))) return { text: 'Das Status-Panel läuft nur in der Leit-Session (scripts/set_status_panel_home.ps1).' }
    activate($)
    await $.ui.open({ id: PANE, title: TITLE })
    void refreshAll($)

    return { text: 'Status-Panel geöffnet.' }
  })

  // Einziger Beleg für das Alter der Werte: stopReason ist null, wenn keine Antwort kam (abgebrochen, fehlgeschlagen).
  on('turn.step', async function* ($, e, next) {
    const response = yield* next(e)
    if (active && response.stopReason !== null) {
      lastResponse = await $.clock.now()
      await refreshQuota($)
    }

    return response
  })

  // „Eigen“ = Container, die diese Session in ihren Befehlen selbst benannt hat (Root-CLAUDE.md: je Aufruf gesetzt).
  for (const tool of ['PowerShell', 'Bash'] as const) {
    on('tool.call', { tool }, async ($, e, next) => {
      const names = active ? [...String(e.command ?? '').matchAll(/(?:N8NTEST|DBTEST)_CONTAINER\s*=\s*['"]?([\w.-]+)/g)].map(hit => hit[1] ?? '') : []
      if (names.length > 0) await update($, own, list => [...new Set([...list, ...names])])

      return next(e)
    })
  }

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const table = $.ui.resolve(e)
    const { Box, Text, Button } = table
    if (!active) return <Text dimColor>Läuft nur in der Leit-Session.</Text>
    const Svg = 'Svg' in table ? table.Svg : undefined
    const [q, c, mine, g, runs] = await Promise.all([read($, quota), read($, containers), read($, own), read($, grants), read($, ci)])
    const barWidth = Math.max(120, Math.min((e.props.bodyColumns ?? 40) * 7, 420))
    const isOwn = (row: Container) => mine.some(name => row.name === name || row.name === `${name}-b`)
    const ownRows = (c?.rows ?? []).filter(isOwn)
    const otherRows = (c?.rows ?? []).filter(row => !isOwn(row))
    const red = (runs?.rows ?? []).filter(run => !isGreen(run))
    const owner = g ? grantLine(g.owner) : undefined
    const app = g ? grantLine(g.app) : undefined

    return (
      <Box flexDirection="column" gap="sm">
        <Text weight="semibold">Kontingent</Text>
        {q === null && <Text dimColor>wird gelesen …</Text>}
        {q?.error && <Text color="error">Nicht lesbar: {q.error}</Text>}
        {q?.windows.map(window => {
          const { label, percentUsed, resetsAt, resetsIn } = window
          if (percentUsed === undefined) {
            return (
              <Box flexDirection="row" justifyContent="space-between">
                <Text>{label}</Text>
                <Text dimColor>unbekannt</Text>
              </Box>
            )
          }
          const filled = Math.round(Math.min(100, percentUsed) / 5)

          return (
            <Box flexDirection="column">
              <Box flexDirection="row" justifyContent="space-between">
                <Text>{label}</Text>
                <Text tabular>{percentLabel(percentUsed)}</Text>
              </Box>
              {Svg
                ? <Svg source={barSource(percentUsed, barWidth)} alt={`${label}: ${percentLabel(percentUsed)}`} />
                : <Text color="suggestion">{'█'.repeat(filled)}<Text dimColor>{'░'.repeat(20 - filled)}</Text></Text>}
              {resetsAt !== undefined && resetsIn !== undefined && <Text dimColor size="footnote">{resetLabel(resetsAt, resetsIn)}</Text>}
            </Box>
          )
        })}
        {q && !q.error && <Text dimColor size="footnote">{readingLine(q.ageMinutes)}</Text>}

        <Text weight="semibold">Test-Container</Text>
        {c === null && <Text dimColor>wird gelesen …</Text>}
        {c?.error && <Text color="error">Nicht lesbar: {c.error}</Text>}
        {c && !c.error && ownRows.length === 0 && <Text dimColor>Keine eigenen.</Text>}
        {ownRows.map(row => (
          <Box flexDirection="row" justifyContent="space-between">
            <Text mono>{row.name}</Text>
            <Text tabular>{row.ports.join(', ') || 'kein Port'}</Text>
          </Box>
        ))}
        {otherRows.length > 0 && (
          <Text dimColor size="footnote">
            Andere Sessions: {otherRows.map(row => `${row.name.replace('lifeagents-', '')} (${row.ports.join(', ') || 'kein Port'})`).join(' · ')}
          </Text>
        )}

        <Text weight="semibold">Fenster</Text>
        {!g && <Text dimColor>wird gelesen …</Text>}
        {owner && <Text>Owner: <Text color={owner.color} dimColor={owner.isDim}>{owner.text}</Text></Text>}
        {app && <Text>App: <Text color={app.color} dimColor={app.isDim}>{app.text}</Text></Text>}

        <Text weight="semibold">CI auf main</Text>
        {runs === null && <Text dimColor>wird gelesen …</Text>}
        {runs?.error && <Text color="error">Nicht lesbar: {runs.error}</Text>}
        {runs && !runs.error && (
          red.length === 0
            ? <Text><Text color="success">●</Text> grün ({runs.rows.map(run => run.workflow).join(', ')})</Text>
            : <Text><Text color="error">●</Text> rot: {red.map(run => `${run.workflow} (${run.conclusion}, ${run.sha})`).join(', ')}</Text>
        )}

        <Button key="refresh" label="Aktualisieren" onPress={() => void refreshAll($)} />
      </Box>
    )
  })
}
