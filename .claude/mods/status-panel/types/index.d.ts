// Jede Quelle trägt ihren Fehler als Text mit: das Panel zeigt „nicht lesbar“, nie einen Ersatzwert.
// percentUsed fehlt = unbekannt: kein Wert aus einer aktuellen Modellantwort. resetsAt in Millisekunden wie $.clock.now().
export type QuotaWindow = { label: string; percentUsed?: number; resetsAt?: number; resetsIn?: string }
// ageMinutes = Alter der letzten Modellantwort; fehlt, solange dieser Prozess noch keine gesehen hat.
export type Quota = { windows: QuotaWindow[]; ageMinutes?: number; error?: string }

export type Container = { name: string; ports: string[]; status: string }
export type Containers = { rows: Container[]; error?: string }

// minutes = Restzeit des Fensters; fehlt, wenn es zu ist.
export type Grant = { minutes?: number; error?: string }
export type Grants = { owner: Grant; app: Grant }

export type CiRun = { workflow: string; conclusion: string; sha: string; when: string; title: string }
export type Ci = { rows: CiRun[]; error?: string }

declare module 'claude-code' {
  interface PluginState {
    'status-panel': {
      quota: Shaped<Quota | null>
      containers: Shaped<Containers | null>
      own: Shaped<string[]>
      grants: Shaped<Grants | null>
      ci: Shaped<Ci | null>
    }
  }
}
