# poop_bags 💩🛍️

A standalone web service that takes a local project directory and **bags the CRAP** — **C**hange **R**isk **A**nti-**P**atterns — function by function. Then it tells you whether your refactor actually cleaned anything up.

Built with **Phoenix** + **[FlowExtra](https://codeberg.org/kin_electric/flow_extra)** (the Flowex fork's GenStage railway pipelines) + **SQLite**. Works on **Elixir, Zig, Kotlin, Swift, and Rust**. Developed by **🛸🕳️ iStellar~iModal**.

```
CRAP(m) = complexity(m)² × (1 − coverage(m))³ + complexity(m)
```

High complexity with nothing pinning it down (no tests) is change risk. poop_bags does static analysis only — it never builds, runs, or modifies the project it scans.

## Run it

```console
$ mix setup          # deps + sqlite db (migrations auto-run on boot)
$ mix phx.server     # http://localhost:4100 (PORT= to move it)
```

Paste an absolute path to a project directory and press **Bag it**. The scan page polls live progress; when the belts stop you get every function ranked worst-first, with stench bands:

| band       | CRAP      | meaning                        |
|------------|-----------|--------------------------------|
| fresh      | ≤ 5       | nothing rotting here           |
| whiffy     | ≤ 20      | hold your nose, consider a refactor |
| foul       | ≤ 50      | the bag is straining           |
| biohazard  | > 50      | evacuate the area              |

## Phase 2: coverage, diffs, CI, and explanations

### Project configuration — `.poopbags.json`

A JSON file at the project root (parsed strictly — scanned projects are untrusted input, nothing is ever evaluated):

```json
{
  "exclude": ["experiments/**", "**/*.gen.zig"],
  "coverage_report": "cover/lcov.info",
  "threshold": 30,
  "languages": ["zig", "elixir"],
  "hotspot_depth": 2
}
```

Precedence: built-in defaults < project file < invocation overrides (web form / CLI flags). Exclusions apply before descending; the effective config and its digest are persisted with every scan, and diffs flag when two scans used different exclusion sets.

### Real coverage ingestion

Name a report in `.poopbags.json` (or pass `--coverage-report`) and CRAP stops being a guess: **LCOV** (`SF:`/`DA:` — gcov, llvm-cov, kcov, …) and **ExCoveralls JSON** (`mix coveralls.json`) are parsed, never executed. Report lines are attributed to the innermost function span that contains them, and a function's coverage is covered ÷ executable lines *owned by it* — nested functions don't inflate their hosts. Paths are aligned onto the project's files (absolute CI paths suffix-match, ambiguity is left alone), and functions the report never mentions are **unknown**, not measured-zero: they fall back to the scan's assumed coverage with the provenance recorded on every finding row (`measured` / `assumed`). A broken report fails a CI scan but only warns (and records the reason) on a web scan.

### Scan-to-scan diffing

The scan page links **diff vs previous** (or any baseline via `?against=<id>`). Findings match on stable identity — language + path + module + function (Elixir's `(clause n)` suffixes are presentation, not identity) — never line numbers. Outcomes:

- **introduced** — new function (⚠️ when it lands above the threshold)
- **regressed** / **improved** — matched, CRAP moved
- **resolved** — was above the threshold, no longer is
- **removed** — gone since baseline (a separate outcome; excluded or missing code never counts as resolved)

Rows show ΔCRAP, Δcomplexity, and baseline → current together. Guards warn when the two scans aren't comparable (different projects, analyzer policies, exclusion sets, or a baseline newer than the comparison).

### CI gate

```console
$ mix poop_bags.ci --path /abs/project
$ mix poop_bags.ci --path . --against latest --threshold 30 --format json --out report.json
```

Scans synchronously (same SQLite ledger as the web UI — a CI run and a web run produce the same explained result), diffs against the latest finished baseline of the same project (`--against <id>|latest|none`), prints a markdown or JSON report, and exits `1` when new violations or above-threshold regressions appeared (`2` if the scan itself failed). Coverage reports are strict here: an unusable report fails the run instead of degrading to assumed.

### Explain this score

Every CRAP in the findings table links to an explanation: the arithmetic (complexity, the coverage actually used and its provenance, threshold), the function's line span, and a breakdown of exactly which constructs produced the complexity (`if ×2`, `case arm ×3`, `boolean op ×1`, …) — recomputed from the file on demand, so it also tells you when the file has drifted since the scan.

## Phase 3: directory hotspots, trends, and retention

### Directory hotspots

Every scan aggregates its findings into per-directory rows — `files`, `functions`, `violations` (CRAP strictly above the threshold, the same rule as the gate), `worst CRAP`, and **CRAP-excess** (`Σ max(CRAP − threshold, 0)`, the above-threshold burden and the default sort), plus the measured/assumed coverage mix, since a coverage import going missing raises CRAP without any code changing. Excess deliberately grows with directory size; the **violation rate** column is what makes a 10-function and a 20,000-function directory comparable.

Groups use the first two path segments by default (`experiments/hb003_s3_user_journey`, `apps/amrita`), with `src/(direct files)` for files directly under a segment that also has subdirectories and `(root)` for repo-root files — every bagged function belongs to exactly one group per depth. Set `"hotspot_depth": 1–4` in `.poopbags.json` to change how deep the aggregates go; the scan page's `1-level`/`2-level` chips switch the view.

### Per-project trends

Each scan page links **trends**: a timeline of the project's done scans (files, functions, violations, worst, average, threshold, coverage provenance — assumed and measured stay visibly separate) and a hotspot matrix showing the top directories' CRAP-excess across the last scans, with bars scaled to the worst cell.

Changes in threshold, scoring policy, scope (exclusions/languages/depth), or coverage provenance are drawn as **boundaries** — ⚠ rows marking that the series is not comparable across that line, not a regression.

### Retention: the ledger outlives the findings

A 99k-finding scan accumulates fast. The app keeps detailed findings for the **latest 3 successful scans of each project** (configure with `config :poop_bags, :retention_keep: 3`) plus anything you **pin** (📌 on the scan page — pinning is the only protection; diffing against a scan pins nothing). Older done scans keep their summary, directory aggregates, and file manifest, and are marked **details expired**:

- the trends timeline still lists them (that's the point — the trend outlives the findings),
- findings listings, diffs, and explanations against them return a clear **unavailable** (HTTP 410 for the API), never a misleading empty result,
- the CI task falls back to the latest usable baseline when `--against` names an expired one.

Sweeps run after every successful commit and at boot, outside the commit transaction, idempotently — a sweep problem is logged and never disturbs a finished scan. Failed scans never displace successful history. Expiry is one-way: pinning an expired scan cannot resurrect its details.

## How a scan works

```
walker ──▶ Engine ──▶ FlowExtra pipeline (GenStage belts, admission-gated)
                        load_file ×6 → analyze_file ×6 → attach_coverage ×3 → score_findings ×3
                                                        └── any raise → error_pipe: bag_the_mess
```

- `PoopBags.Walker` collects source files (extension whitelist: `.ex .exs .zig .kt .kts .swift .rs`; skips `.git`, `deps`, `node_modules`, `_build`, caches, `vendor`, …; 30k-file and 1.5MB-per-file caps, everything skipped is counted) — now with `.poopbags.json` exclusions and language filters.
- `PoopBags.Engine` is the one place a scan happens: config resolution, walker, coverage ingestion and alignment, the FlowExtra belt driven from an unlinked task pool (one bad file is one failed file, never a dead runner), per-file content hashing, and an all-or-nothing transaction committing findings + file manifest + directory aggregates + summary. The web `ScanRunner` and the CI task are both thin shells over it.
- Findings carry line spans, per-function coverage + provenance, and the manifest records every file's sha256 — the snapshot identity coverage attribution and future caching lean on.
- `PoopBags.Retention` expires old scans' details after each commit and at boot; `PoopBags.Hotspots` builds the durable per-directory aggregates that survive expiry.

## How complexity is measured

**Elixir** gets the real AST (`Code.string_to_quoted/2`):
- One finding per `def`/`defp`/`defmacro`/`defmacrop`/`defguard`/`defguardp` clause (multi-clause functions get `(clause n)` suffixes).
- Counted: `if`/`unless` (+1), `cond` conditions, `case` arms, `with` steps + `else` arms, `receive` arms + `after`, `fn` arms past the first (lambda bodies count into their parent), `and`/`or`/`&&`/`||` (including guards), `try` rescue/catch/else arms.
- `quote` blocks are pruned (that's generated code, not this code).
- Parsing is **atom-safe** (`static_atoms_encoder`): scanning foreign projects for months cannot grow the atom table.

**Zig / Kotlin / Swift / Rust** get a token analyzer, since no resident compiler exists for them:
1. `PoopBags.SourceCleaner` blanks comments and string/char literals with **byte-length and newline preservation** — handles Zig multiline `\\` literals, Kotlin `"""` + nested block comments + `${}` interpolation, Swift `"""`, `#"raw"#` strings and `\()` interpolation, and Rust `r#"raw"#` strings (the close is `"` plus the opening count of `#`s), nested block comments, and multiline `"..."` literals. Rust `'a`-style lifetimes/labels are told apart from `'x'` char literals by whether the identifier run ends at a closing quote.
2. Function declarations are regex-located; body spans come from brace matching, **bounded by the next declaration** so bodyless declarations (Swift protocol requirements, `extern fn`, `external fun`, Rust trait signatures, inline Zig error sets) never borrow a neighbor's body. Kotlin expression bodies (`fun f() = expr`) span to the statement end.
3. Branch tokens (`if`, `while`, `for`, `loop`, `catch`, `orelse`/`?:`/`??`, `&&`, `||`, switch prongs / `when` arms / `case:` arms / `match` arms, Swift `guard`/`where`/ternary, Rust `?`) are matched once and attributed to the **innermost** function span — nested/local functions never double-count.
4. `complexity = 1 + tokens`. Exhaustive choices count one per arm (not the keyword), matching the Elixir `case` policy.

Known approximations (consistent and documented, not claimed to be exact): Kotlin `->` after a `)` is read as a function type rather than a `when` arm (and a lambda's `->` counts as a branch); Swift `case` inside enum declarations nested in functions counts, and `try? f(x: 1)` can masquerade as a ternary; Rust `=>` counts `macro_rules!` arms alongside `match` arms, `||` after `=`/`(`/`,`/`{`/`=>`/`return`/`move` is read as empty-parameter closure syntax rather than boolean-or (and a `||` whose left operand was a blanked literal is missed), and `?` in `?Sized` bounds does not count; accessors (`get`/`set`), Kotlin `init` blocks, and Zig `test` blocks are not reported as functions. Elixir reports one finding per clause (clause-heavy functions read hotter), and `def`/`defmacro` of the same name share a clause-number series. The five languages share one policy for exhaustive choices and conditional fallbacks, so cross-language rankings are comparable in spirit, not numerically identical.

## Verifying it works

```console
$ mix test          # 153 tests: formula, cleaner, analyzers, walker, pipeline, web, diff, coverage, CI,
                    # hotspots, retention, trends — and the full acceptance scenario:
                    # config+coverage scan → refactor → diff → CI agreement
```

The integration tests scan `priv/fixtures/subject_project` (all four languages + a junk dir) through the real runner, pipeline, and database. The acceptance test builds a project with a `.poopbags.json` and an LCOV report, refactors its hotspot, and asserts the whole loop: measured coverage lowers the baseline CRAP, the split function resolves under the threshold, the new helper is introduced-but-clean, the web diff tells that story, and the CI gate passes — while a version that rots a new violation into the code fails with exit 1.

Reality check against the development subject (`honey_badger`, a ~7.4k-file Zig-dominant repo): 7,381 files bagged in ~5s with zero failures, 99,292 functions measured, 39,067 violations at threshold 20; the top specimen is a hand-verified 119-branch `integrity` function (CRAP 14,280 at 0% coverage) — verified by an independent token count of its source. The hotspots cut is real too: `experiments/hb003_s3_user_journey` carries 95k functions (CRAP-excess 17.6M) while `apps/amrita` hides a 14,280-worst in just 82 files — burden and rate, side by side.

## Configuration notes

- Dev server defaults to **port 4100**; `PORT=` overrides.
- SQLite runs in WAL mode with a 5s busy timeout (scan-runner writes and web reads coexist).
- Scans interrupted by a server restart are marked `error` at boot, before the endpoint accepts requests.
- Deleting a running scan is rejected; a crashed runner never restarts (one attempt, explicit terminal state).
- Detail retention keeps the latest `:retention_keep` (default 3) done scans per project plus pinned ones; summaries, hotspots, and manifests always survive.

## For agents 🤖

This service is built agent-first: a stable JSON contract, a machine-readable
discovery endpoint, an MCP server, and a skill.

**Discovery:** `GET /api` returns the whole contract — endpoints, quickstart,
semantics (violation rules, gate behavior, retention), and MCP wiring — so an
agent can learn the service with one request.

```console
$ curl -s http://localhost:4100/api
```

**The loop** (also on the front page, copy-pasteable):

```console
$ curl -s $URL/api/scans -H 'content-type: application/json' \
    -d '{"project_path": "/abs/path/to/project", "coverage": 0}'   # → 202 + id
$ curl -s $URL/api/scans/$ID                                       # poll → done
$ curl -s "$URL/api/scans/$ID/findings?limit=20"                   # worst-first
$ curl -s "$URL/api/scans/$ID/diff?against=latest"                 # outcomes + gate
```

**MCP server:** `bin/poop_bags_mcp` (committed escript — runs anywhere with
Erlang/Elixir on PATH, no build step) speaks Model Context Protocol over
stdio with four tools — `bag_project` (the one-call scan-and-wait loop),
`scan_status`, `top_findings`, `diff_latest`. Point it at the service with
`POOP_BAGS_URL` (default `http://localhost:4100`):

```json
{ "mcpServers": { "poop_bags": {
    "command": "/path/to/poop_bags/bin/poop_bags_mcp",
    "env": { "POOP_BAGS_URL": "http://localhost:4100" } } } }
```

**Skill:** `skills/poopbags/SKILL.md` is an agent-skill (frontmatter +
usage + semantics + honest limits) ready to drop into an agent's skills
directory.

**Inside a checkout:** `mix poop_bags.ci --path . --against latest` scans,
diffs, gates, and exits `1` on new violations — CI without the service.

## JSON API

```console
$ curl -X POST localhost:4100/api/scans -H 'content-type: application/json' \
    -d '{"project_path": "/abs/path/to/project", "coverage": 0}'
{"id":1,"status":"running","show_url":"http://localhost:4100/scans/1"}

$ curl localhost:4100/api/scans/1
$ curl 'localhost:4100/api/scans/1/findings?language=zig&limit=20'
$ curl 'localhost:4100/api/scans/1/diff?against=latest'
```
