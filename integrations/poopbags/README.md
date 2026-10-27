# poopbags — advisory Claude Mod

A native Claude Code Mod (same form as `licorice/integrations/being-memory`):
`.claude-plugin/plugin.json` + `hooks/hooks.json` (`{"modules": ["./register.mjs"]}`)
+ `hooks/register.mjs` exporting `register(on)`.

## What it does

1. `classic.PostToolUse` — a successful `Edit`/`Write`/`MultiEdit` marks the
   **canonical project root** dirty for this session. No per-path tracking:
   the scanned-source identity is re-derived at the boundary.
2. `classic.Stop` — if dirty: fingerprint the real tree (source contents +
   `.poopbags.json` + the coverage report it names + tool identity), submit
   `POST /api/scans` to the local service, diff against the **pinned baseline
   scan ID**, and append one advisory notice (≤ 2000 bytes) via
   `additionalContext`. Evidence JSON lands on disk under the state dir.

## Verdicts — three, kept distinct

| Verdict | Meaning |
|---|---|
| `completed-clean` | scan done, diff vs pinned baseline, no new violations |
| `completed-actionable` | introduced/regressed violations, top-3 named |
| `unknown` | service down / scan pending past bound / baseline missing or expired / scope too big to fingerprint / malformed response / scan failed |

A first scan with no pinned baseline is an **initial observation** — the scan
is pinned as baseline and the notice says so. It is never a passed gate.
Failed baselines (410/expired) re-pin to the fresh scan and say *that* too.

Advisory means **advisory**: the hook never returns `block`, never sets
`preventContinuation`, never retries in a loop. A failed service or a
malformed reply degrades to one `unknown` notice plus an evidence file.

## Behavioural bounds

- Same fingerprint at a Stop boundary = **same-revision replay**: the stored
  verdict answers, nothing is resubmitted.
- A scan still running when the Stop budget ends is stored as `pending` and
  resumed at the next boundary — never submitted twice.
- The SDK has no request abort: a scan POST that outlives its deadline is an
  **uncertain submission** — it may still complete server-side. The Mod keeps
  the reservation (persisted flag + retained promise), refuses to submit a
  second scan, and reconciles at later boundaries: a late response adopting a
  landed scan becomes `pending`; a server-side failure or the orphan window
  (`scan budget + pending bound + 60 s`) clears it. A stray scan is
  non-mutating garbage, never promoted.
- HTTP requests race a per-request bound inside the boundary deadline;
  response bodies over **256 KiB bytes** (UTF-8 counted, post-buffering — the
  SDK delivers whole bodies) are `over-cap` and terminate the poll as
  unreadable, never spun out to the deadline.
- State files live in `$POOPBAGS_MOD_STATE` (default
  `~/.local/state/poopbags-mod/<sha256(root)>/`): `state.json` +
  `report-<scan>.json` / `last-unknown.json` evidence envelopes
  (`schema: poopbags-mod/1`).
- Fingerprint bounds: ≤ 512 source files, ≤ 8 MiB of content. Past that the
  verdict is `unknown` — never a pretend gate.

## Configuration

| Env | Default | Purpose |
|---|---|---|
| `POOPBAGS_API` | `http://127.0.0.1:4100` | service base URL |
| `POOPBAGS_MOD_STATE` | `~/.local/state/poopbags-mod` | state + evidence root |
| `POOPBAGS_SCAN_BUDGET_MS` | `20000` | per-boundary poll budget |
| `POOPBAGS_PENDING_MAX_MS` | `120000` | total pending bound across boundaries |

`/poopbags` command reports baseline/last-scan/pending/dirty and the state dir.

## Limitations that travel with every notice

`advisory only — static analyzer (AST/token policy varies by language); coverage
assumed N% unless .poopbags.json names a report; never blocks.`

## Validation

```bash
node --test tests/mod_test.mjs                    # contract controls (SDK sim) — 12/12
claude plugin validate <plugin-dir> --strict      # native interface check — pass
claude plugin test <plugin-dir>                   # native surface tests (tests/mod.test.ts) — 4/4
claude --plugin-dir <plugin-dir>                  # real session, real edit→Stop — DEFERRED
```

Receipt classes are kept separate: SDK simulation ≠ real service ≠ real Claude
CLI execution. Current receipts: strict validation pass, 12/12 contract
controls, 4/4 native-surface tests. The real local CLI edit/boundary
transcript is outstanding — it needs a paid-model `claude` session, which the
portfolio plan lists as a reserved call.


### JavaScript / TypeScript source changes

Mod `poopbags-mod@0.3.0` includes `.js`, `.jsx`, `.mjs`, `.cjs`, `.ts`, `.tsx`,
`.mts` and `.cts` in the content fingerprint, excluding TypeScript declaration
files. Notices show the scan's recorded analyzer policy when supplied, and a
generic AST/token description otherwise. This extends advisory source detection;
it does not claim a new native CLI/SDK qualification beyond the recorded tests.
