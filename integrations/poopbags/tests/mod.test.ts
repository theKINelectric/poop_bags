import { expect, mock, test } from 'claude-code/testing'

// PF-03 native-surface controls: the engine's own event calls drive the Mod —
// classic.PostToolUse marks the canonical root dirty, classic.Stop debounces,
// fingerprints real file contents, scans the (mocked) local service, and only
// ever returns additionalContext. Simulation receipt, not a real-service run.

const SRC = 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n'

function project() {
  const files: Record<string, string> = { '/proj/src/lib.rs': SRC }
  const onFs = (on: any) => {
    on('fs.stat', (_$: any, e: any) => ({ value: { kind: 'dir', size: 0, mtimeMs: 0, isLink: false, realPath: e.path } }))
    on('fs.exists', (_$: any, e: any) => ({ value: e.path in files }))
    on('fs.list', (_$: any, e: any) => {
      const prefix = `${e.path}/`
      const seen = new Map<string, any>()
      for (const k of Object.keys(files)) {
        if (!k.startsWith(prefix)) continue
        const rest = k.slice(prefix.length)
        const head = rest.split('/')[0]
        if (!seen.has(head)) seen.set(head, { name: head, kind: rest.includes('/') ? 'dir' : 'file', size: 4, mtimeMs: 0, isLink: false })
      }
      return { value: [...seen.values()] }
    })
    on('fs.read', (_$: any, e: any) => {
      if (e.path in files) return { value: files[e.path] }
      throw new Error(`ENOENT ${e.path}`)
    })
    on('fs.write', (_$: any, e: any) => { files[e.path] = e.text; return { value: undefined } })
  }
  return { files, onFs }
}

function service(on: any, svc: { scanId: number, diffBody: any, diffStatus: number }) {
  // Registered once, reads `svc` at call time — on() handlers cannot be
  // re-registered after $ is first used.
  const calls: string[] = []
  on('http.fetch', (_$: any, e: any) => {
    const url = e.url as string
    const method = e.init?.method || 'GET'
    calls.push(`${method} ${url}`)
    if (url.endsWith('/api/scans') && method === 'POST')
      return { value: { status: 202, ok: true, headers: {}, text: JSON.stringify({ id: svc.scanId, status: 'running' }) } }
    if (url.includes('/diff')) {
      if (svc.diffStatus !== 200) return { value: { status: svc.diffStatus, ok: false, headers: {}, text: JSON.stringify({ error: 'baseline scan details expired by retention' }) } }
      return { value: { status: 200, ok: true, headers: {}, text: svc.diffBody || JSON.stringify({ scan_id: svc.scanId, baseline_id: svc.scanId, threshold: 20, comparable: true, warnings: [], summary: { introduced: 0, removed: 0, regressed: 0, improved: 0, resolved: 0, unchanged: 7 }, gate_passed: true, rows: [] }) } }
    }
    if (/\/api\/scans\/\d+$/.test(url))
      return { value: { status: 200, ok: true, headers: {}, text: JSON.stringify({ id: svc.scanId, status: 'done', project_path: '/proj', functions_total: 7, violations: 1, threshold: 20, assumed_coverage: 0 }) } }
    return { value: { status: 404, ok: false, headers: {}, text: '{}' } }
  })
  return calls
}

const EDIT = { tool_name: 'Edit', tool_input: { file_path: '/proj/src/lib.rs' }, tool_response: { success: true }, tool_use_id: 't1', cwd: '/proj' }

test('an edit marks the root dirty and the stop boundary pins a baseline as an initial observation', async ($, on) => {
  on('classic.PostToolUse', (_$: any, e: any) => e)
  on('classic.Stop', () => ({}))
  mock.env(on, { POOPBAGS_MOD_STATE: '/pb-state' })
  on('session.id', () => ({ value: 's-1' }))
  const { onFs } = project()
  onFs(on)
  const calls = service(on, { scanId: 7, diffBody: null, diffStatus: 200 })
  await $.classic.PostToolUse(EDIT)
  const res: any = await $.classic.Stop({ cwd: '/proj' })
  expect((res.additionalContext || []).join('\n')).toContain('initial observation')
  expect((res.additionalContext || []).join('\n')).toContain('pinned to #7')
  expect(calls.some((c) => c.includes('/diff'))).toBe(false)
  expect((res.block || res.preventContinuation) ?? undefined).toBeUndefined()
})

test('a quiet boundary produces no notice and no service traffic', async ($, on) => {
  on('classic.PostToolUse', (_$: any, e: any) => e)
  on('classic.Stop', () => ({}))
  mock.env(on, { POOPBAGS_MOD_STATE: '/pb-state2' })
  on('session.id', () => ({ value: 's-2' }))
  project().onFs(on)
  const calls = service(on, { scanId: 1, diffBody: null, diffStatus: 200 })
  const res: any = await $.classic.Stop({ cwd: '/proj' })
  expect(res.additionalContext ?? []).toEqual([])
  expect(calls.length).toBe(0)
})

test('introduced violations report completed-actionable with names, still without blocking', async ($, on) => {
  on('classic.PostToolUse', (_$: any, e: any) => e)
  on('classic.Stop', () => ({}))
  mock.env(on, { POOPBAGS_MOD_STATE: '/pb-state3' })
  on('session.id', () => ({ value: 's-3' }))
  const { files, onFs } = project()
  onFs(on)
  // First boundary: initial observation pins baseline 9.
  const svc = { scanId: 9, diffBody: null as any, diffStatus: 200 }
  const calls = service(on, svc)
  await $.classic.PostToolUse(EDIT)
  await $.classic.Stop({ cwd: '/proj' })
  // Second boundary: source changed → rescan → diff against pinned 9.
  files['/proj/src/lib.rs'] = SRC + 'fn changed() {}\n'
  const diff = JSON.stringify({
    scan_id: 10, baseline_id: 9, threshold: 20, comparable: true, warnings: [],
    summary: { introduced: 1, removed: 0, regressed: 0, improved: 0, resolved: 0, unchanged: 6 },
    gate_passed: false,
    rows: [{ outcome: 'introduced', violation: true, language: 'rust', path: 'src/lib.rs', module: null, function: 'rotten/0', baseline_crap: null, current_crap: 47, delta_crap: 47, delta_complexity: 9, coverage: null, coverage_source: null }],
  })
  svc.scanId = 10
  svc.diffBody = diff
  await $.classic.PostToolUse(EDIT)
  const res: any = await $.classic.Stop({ cwd: '/proj' })
  const notice = (res.additionalContext || []).join('\n')
  expect(notice).toContain('completed-actionable')
  expect(notice).toContain('rotten/0')
  expect(notice).toContain('baseline #9')
  expect(res.block ?? undefined).toBeUndefined()
})

test('an unreachable service answers unknown once and never blocks', async ($, on) => {
  on('classic.PostToolUse', (_$: any, e: any) => e)
  on('classic.Stop', () => ({}))
  mock.env(on, { POOPBAGS_MOD_STATE: '/pb-state4' })
  on('session.id', () => ({ value: 's-4' }))
  project().onFs(on)
  on('http.fetch', () => { throw new Error('connection refused') })
  const logs: string[] = []
  on('ui.log', (_$: any, e: any) => { logs.push(e.text ?? String(e)); return { value: undefined } })
  await $.classic.PostToolUse(EDIT)
  const res: any = await $.classic.Stop({ cwd: '/proj' })
  const notice = (res.additionalContext || []).join('\n')
  expect(notice).toContain('unknown')
  expect(res.block ?? undefined).toBeUndefined()
})
